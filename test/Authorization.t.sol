// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError }               from "../lib/forge-std/src/StdError.sol";
import { stdStorage, StdStorage } from "../lib/forge-std/src/StdStorage.sol";

import { IAccessControl } from "../lib/oz/contracts/access/IAccessControl.sol";
import { IERC1967 }       from "../lib/oz/contracts/interfaces/IERC1967.sol";

import { TestBase } from "./TestBase.t.sol";

import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

contract AuthorizationTestBase is TestBase {

    uint256 public constant RAY = 1e27;

    uint256 internal constant ONE_PCT_VSR  = 1.000000000315522921573372069e27;
    uint256 internal constant FOUR_PCT_VSR = 1.000000001243680656318820312e27;
    uint256 internal constant FIVE_PCT_VSR = 1.000000001547125957863212448e27;

    address internal user        = makeAddr("user");
    address internal unauthorized = makeAddr("unauthorized");

    function setUp() public virtual override {
        super.setUp();

        // NOTE: This file tests all auth'ed functions except the rebalancer
        vm.startPrank(admin);
        vault.grantRole(GUARDIAN_ROLE,          guardian);
        vault.grantRole(REDEEM_FEE_SETTER_ROLE, redeemFeeSetter);
        vault.grantRole(VSR_SETTER_ROLE,        vsrSetter);
        vault.grantRole(TAKER_ROLE,             taker);
        vault.setCapacity(1_000_000e6);
        vm.stopPrank();

        deal(address(usdc), user, 1_000_000e6);
    }

    function _notAuthorized(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            account,
            role
        );
    }

    function _requestDeposit(address user_, uint256 assets_) internal returns (uint256 requestId) {
        vm.startPrank(user_);
        usdc.approve(address(vault), assets_);

        requestId = vault.requestDeposit(assets_, user_, 0);
        vm.stopPrank();
    }

}

contract GrantRoleTests is AuthorizationTestBase {

    // Failure tests

    function test_grantRole_notAdmin() public {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.grantRole(REBALANCER_ROLE, rebalancer);
    }

    // Success tests

    function test_grantRole() public {
        assertEq(vault.hasRole(REBALANCER_ROLE, rebalancer), false);

        vm.expectEmit(address(vault));
        emit IAccessControl.RoleGranted(REBALANCER_ROLE, rebalancer, admin);

        vm.prank(admin);
        vault.grantRole(REBALANCER_ROLE, rebalancer);

        assertEq(vault.hasRole(REBALANCER_ROLE, rebalancer), true);
    }

}

contract RevokeRoleTests is AuthorizationTestBase {

    // Failure tests

    function test_revokeRole_notAdmin() public {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.revokeRole(GUARDIAN_ROLE, guardian);
    }

    // Success tests

    function test_revokeRole() public {
        assertEq(vault.hasRole(GUARDIAN_ROLE, guardian), true);

        vm.expectEmit(address(vault));
        emit IAccessControl.RoleRevoked(GUARDIAN_ROLE, guardian, admin);

        vm.prank(admin);
        vault.revokeRole(GUARDIAN_ROLE, guardian);

        assertEq(vault.hasRole(GUARDIAN_ROLE, guardian), false);
    }

}

contract UpgradeToAndCallTests is AuthorizationTestBase {

    // Failure tests

    function test_upgradeToAndCall_notAdmin() public {
        address newImplementation = address(new SparkPrimeVault());

        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.upgradeToAndCall(newImplementation, "");
    }

    // Success tests

    function test_upgradeToAndCall() public {
        address newImplementation = address(new SparkPrimeVault());

        assertNotEq(vault.implementation(), newImplementation);

        vm.expectEmit(address(vault));
        emit IERC1967.Upgraded(newImplementation);

        vm.prank(admin);
        vault.upgradeToAndCall(newImplementation, "");

        assertEq(vault.implementation(), newImplementation);
    }
}

contract AdjustTotalAssetsTests is AuthorizationTestBase {

    using stdStorage for StdStorage;

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setVSRBounds(RAY, FIVE_PCT_VSR);

        vm.prank(vsrSetter);
        vault.setVSR(FIVE_PCT_VSR);
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _depositAndPause(uint256 assets) internal {
        _requestDeposit(user, assets);

        vm.prank(guardian);
        vault.pause();
    }

    /**********************************************************************************************/
    /*** Failure tests                                                                          ***/
    /**********************************************************************************************/

    function test_adjustTotalAssets_notAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        vault.adjustTotalAssets(-1e6);
    }

    function test_adjustTotalAssets_notPaused() public {
        vm.expectRevert("SparkPrimeVault/not-paused");
        vm.prank(admin);
        vault.adjustTotalAssets(-1e6);
    }

    function test_adjustTotalAssets_zeroDeltaTotalAssets() public {
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert("SparkPrimeVault/delta-total-assets-zero");
        vm.prank(admin);
        vault.adjustTotalAssets(0);
    }

    function test_adjustTotalAssets_lossTooHighBoundary() public {
        _depositAndPause(1_000_000e6);

        assertEq(vault.totalAssets(), 1_000_000e6 - 1);  // Rounding

        vm.expectRevert("SparkPrimeVault/loss-too-high");
        vm.prank(admin);
        vault.adjustTotalAssets(-(1_000_000e6 - 1));

        vm.prank(admin);
        vault.adjustTotalAssets(-(1_000_000e6 - 2));
    }

    function test_adjustTotalAssets_zeroSupply() public {
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert(stdError.divisionError);
        vm.prank(admin);
        vault.adjustTotalAssets(1e6);
    }

    function test_adjustTotalAssets_invalidChiBoundary() public {
        vm.prank(guardian);
        vault.pause();

        // Inflate supply so that `totalAssets * RAY / totalSupply` can round down to zero.
        uint256 supply = 1e28;

        stdstore.target(address(vault)).sig("totalSupply()").checked_write(supply);

        int256 totalAssets = int256(vault.totalAssets());

        assertEq(uint256(totalAssets), supply);  // chi == RAY

        // totalAssets -> 9: chi = 9e27 / 1e28 = 0
        vm.expectRevert("SparkPrimeVault/chi-too-low");
        vm.prank(admin);
        vault.adjustTotalAssets(-(totalAssets - 9));

        // totalAssets -> 10: chi = 10e27 / 1e28 = 1
        vm.prank(admin);
        vault.adjustTotalAssets(-(totalAssets - 10));

        assertEq(vault.chi(), 1);
    }

    /**********************************************************************************************/
    /*** Success tests                                                                          ***/
    /**********************************************************************************************/

    function test_adjustTotalAssets_loss() public {
        uint256 loss = 100_000e6;

        _depositAndPause(1_000_000e6);

        skip(365 days);

        uint192 chiBefore    = vault.nowChi();
        uint256 assetsBefore = vault.totalAssets();
        uint256 supply       = vault.totalSupply();

        // Drip is pending, adjustTotalAssets must settle it before writing chi down.
        assertEq(chiBefore,    1.049999999999999999961070145e27);  // ~5% APY
        assertEq(supply,       1_000_000e6 - 1);  // Rounding
        assertEq(assetsBefore, 1_050_000e6 - 2);  // Rounding, 5% yield accrued

        assertEq(vault.rho(),          block.timestamp - 365 days);
        assertEq(vault.assetsOf(user), assetsBefore);

        uint192 expectedChi = uint192(((assetsBefore - loss) * RAY) / supply);

        assertEq(expectedChi, 0.949999999998949999999998949e27);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.TotalAssetsAdjusted(expectedChi, -int256(loss));

        vm.prank(admin);
        vault.adjustTotalAssets(-int256(loss));

        assertEq(vault.chi(),          expectedChi);
        assertEq(vault.rho(),          block.timestamp);
        assertEq(vault.totalAssets(),  950_000e6 - 3);  // Rounding, 100k loss incurred
        assertEq(vault.assetsOf(user), 950_000e6 - 3);  // Rounding, 100k loss incurred

        assertEq(vault.totalAssets(), assetsBefore - loss - 1);  // Rounding
    }

    function test_adjustTotalAssets_gain() public {
        uint256 gain = 100_000e6;

        _depositAndPause(1_000_000e6);

        skip(365 days);

        uint192 chiBefore    = vault.nowChi();
        uint256 assetsBefore = vault.totalAssets();
        uint256 supply       = vault.totalSupply();

        // Drip is pending, adjustTotalAssets must settle it before writing chi up.
        assertEq(chiBefore,    1.049999999999999999961070145e27);  // ~5% APY
        assertEq(supply,       1_000_000e6 - 1);  // Rounding
        assertEq(assetsBefore, 1_050_000e6 - 2);  // Rounding, 5% yield accrued

        assertEq(vault.rho(),          block.timestamp - 365 days);
        assertEq(vault.assetsOf(user), assetsBefore);

        uint192 expectedChi = uint192(((assetsBefore + gain) * RAY) / supply);

        assertEq(expectedChi, 1.149999999999149999999999149e27);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.TotalAssetsAdjusted(expectedChi, int256(gain));

        vm.prank(admin);
        vault.adjustTotalAssets(int256(gain));

        assertEq(vault.chi(),          expectedChi);
        assertEq(vault.rho(),          block.timestamp);
        assertEq(vault.totalAssets(),  1_150_000e6 - 3);  // Rounding, 100k gain realized
        assertEq(vault.assetsOf(user), 1_150_000e6 - 3);  // Rounding, 100k gain realized

        assertEq(vault.totalAssets(), assetsBefore + gain - 1);  // Rounding
    }

    function test_adjustTotalAssets_accrualContinuesFromNewChi() public {
        uint256 loss = 100_000e6;

        _depositAndPause(1_000_000e6);

        uint192 chiBefore    = vault.nowChi();
        uint256 assetsBefore = vault.totalAssets();
        uint256 supply       = vault.totalSupply();

        // No time has passed, nothing to drip.
        assertEq(chiBefore,    1e27);
        assertEq(supply,       1_000_000e6 - 1);  // Rounding
        assertEq(assetsBefore, 1_000_000e6 - 1);  // Rounding

        assertEq(vault.rho(),          block.timestamp);
        assertEq(vault.assetsOf(user), assetsBefore);

        uint192 expectedChi = uint192(((assetsBefore - loss) * RAY) / supply);

        assertEq(expectedChi, 0.899999999999899999999999899e27);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.TotalAssetsAdjusted(expectedChi, -int256(loss));

        vm.prank(admin);
        vault.adjustTotalAssets(-int256(loss));

        assertEq(vault.chi(),          expectedChi);
        assertEq(vault.rho(),          block.timestamp);
        assertEq(vault.totalAssets(),  900_000e6 - 2);  // Rounding, 100k loss incurred
        assertEq(vault.assetsOf(user), 900_000e6 - 2);  // Rounding, 100k loss incurred

        skip(365 days);

        vault.drip();

        // 5% APY over one year, compounding on the new chi
        assertEq(vault.chi(),          0.944999999999894999964963024e27);
        assertEq(vault.rho(),          block.timestamp);
        assertEq(vault.totalAssets(),  945_000e6 - 2);  // Rounding, 5% yield on 900k
        assertEq(vault.assetsOf(user), 945_000e6 - 2);  // Rounding, 5% yield on 900k

        assertEq(vault.chi(), 1.049999999999999999961070145e27 * expectedChi / RAY);
    }

    function test_adjustTotalAssets_redeemReflectsLoss() public {
        uint256 loss = 100_000e6;

        vm.prank(admin);
        vault.grantRole(REBALANCER_ROLE, rebalancer);

        _depositAndPause(1_000_000e6);

        uint192 chiBefore    = vault.nowChi();
        uint256 assetsBefore = vault.totalAssets();
        uint256 supply       = vault.totalSupply();

        // No time has passed, nothing to drip.
        assertEq(chiBefore,    1e27);
        assertEq(supply,       1_000_000e6 - 1);  // Rounding
        assertEq(assetsBefore, 1_000_000e6 - 1);  // Rounding

        assertEq(vault.rho(),          block.timestamp);
        assertEq(vault.assetsOf(user), assetsBefore);

        uint192 expectedChi = uint192(((assetsBefore - loss) * RAY) / supply);

        assertEq(expectedChi, 0.899999999999899999999999899e27);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.TotalAssetsAdjusted(expectedChi, -int256(loss));

        vm.prank(admin);
        vault.adjustTotalAssets(-int256(loss));

        assertEq(vault.chi(),          expectedChi);
        assertEq(vault.rho(),          block.timestamp);
        assertEq(vault.totalAssets(),  900_000e6 - 2);  // Rounding, 100k loss incurred
        assertEq(vault.assetsOf(user), 900_000e6 - 2);  // Rounding, 100k loss incurred

        vm.prank(admin);
        vault.unpause();

        assertEq(vault.balanceOf(user),       supply);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(usdc.balanceOf(user),        0);

        vm.prank(user);
        vault.requestRedeem(supply, user);

        assertEq(vault.balanceOf(user),       0);
        assertEq(vault.pendingRedeemShares(), supply);
        assertEq(usdc.balanceOf(user),        0);

        vm.prank(rebalancer);
        vault.processPendingRedeems(type(uint256).max, 1);

        // User receives the post-loss value of their shares, not the 1M deposited.
        assertEq(vault.balanceOf(user),       0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.totalSupply(),         0);
        assertEq(vault.totalAssets(),         0);
        assertEq(usdc.balanceOf(user),        900_000e6 - 2);  // Rounding, 100k loss incurred
    }

}

contract SetCapacityTests is AuthorizationTestBase {

    // Failure tests

    function test_setCapacity_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.setCapacity(2_000_000e6);
    }

    // Success tests

    function test_setCapacity() external {
        assertEq(vault.maxCapacity(),       1_000_000e6);
        assertEq(vault.availableCapacity(), 1_000_000e6);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.CapacitySet(2_000_000e6);

        vm.prank(admin);
        vault.setCapacity(2_000_000e6);

        assertEq(vault.maxCapacity(),       2_000_000e6);
        assertEq(vault.availableCapacity(), 2_000_000e6);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.CapacitySet(type(uint256).max);

        vm.prank(admin);
        vault.setCapacity(type(uint256).max);

        assertEq(vault.maxCapacity(),       type(uint256).max);
        assertEq(vault.availableCapacity(), type(uint256).max);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.CapacitySet(0);

        vm.prank(admin);
        vault.setCapacity(0);

        assertEq(vault.maxCapacity(),       0);
        assertEq(vault.availableCapacity(), 0);
    }

}

contract SetMaxRedeemFeeTests is AuthorizationTestBase {

    // Failure tests

    function test_setMaxRedeemFeeRate_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.setMaxRedeemFeeRate(0.01e18);
    }

    function test_setMaxRedeemFee_feeTooHighBoundary() external {
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.01e18 + 1);

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.01e18);  // MAX_REDEEM_FEE is 1%
    }

    // Success tests

    function test_setMaxRedeemFeeRate() external {
        assertEq(vault.maxRedeemFeeRate(), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MaxRedeemFeeRateSet(0.01e18);

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.01e18);

        assertEq(vault.maxRedeemFeeRate(), 0.01e18);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MaxRedeemFeeRateSet(0);

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0);

        assertEq(vault.maxRedeemFeeRate(), 0);
    }

}

contract SetMinDepositTests is AuthorizationTestBase {

    function test_setMinDeposit_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.setMinDeposit(100e6);
    }

    function test_setMinDeposit() external {
        assertEq(vault.minDeposit(), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MinDepositSet(100e6);

        vm.prank(admin);
        vault.setMinDeposit(100e6);

        assertEq(vault.minDeposit(), 100e6);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MinDepositSet(0);

        vm.prank(admin);
        vault.setMinDeposit(0);

        assertEq(vault.minDeposit(), 0);
    }

}

contract SetMinRedeemTests is AuthorizationTestBase {

    function test_setMinRedeem_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.setMinRedeem(100e6);
    }

    function test_setMinRedeem() external {
        assertEq(vault.minRedeem(), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MinRedeemSet(100e6);

        vm.prank(admin);
        vault.setMinRedeem(100e6);

        assertEq(vault.minRedeem(), 100e6);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MinRedeemSet(0);

        vm.prank(admin);
        vault.setMinRedeem(0);

        assertEq(vault.minRedeem(), 0);
    }

}

contract SetVSRBoundsTests is AuthorizationTestBase {

    // Failure tests

    function test_setVSRBounds_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.setVSRBounds({ minVSR_ : RAY, maxVSR_ : FOUR_PCT_VSR });
    }

    function test_setVSRBounds_vsrTooLowBoundary() external {
        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : RAY - 1, maxVSR_ : FOUR_PCT_VSR });

        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : RAY, maxVSR_ : FOUR_PCT_VSR });
    }

    function test_setVSRBounds_vsrTooHighBoundary() external {
        uint256 maxVsr = vault.MAX_VSR();

        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : RAY, maxVSR_ : maxVsr + 1 });

        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : RAY, maxVSR_ : maxVsr });
    }

    function test_setVSRBounds_minVSRGtMaxVSRBoundary() external {
        vm.expectRevert("SparkPrimeVault/min-vsr-gt-max-vsr");
        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : FOUR_PCT_VSR + 1, maxVSR_ : FOUR_PCT_VSR });

        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : FOUR_PCT_VSR, maxVSR_ : FOUR_PCT_VSR });
    }

    // Success tests

    function test_setVSRBounds() external {
        assertEq(vault.minVSR(), RAY);
        assertEq(vault.maxVSR(), RAY);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.VSRBoundsSet(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : ONE_PCT_VSR, maxVSR_ : FOUR_PCT_VSR });

        assertEq(vault.minVSR(), ONE_PCT_VSR);
        assertEq(vault.maxVSR(), FOUR_PCT_VSR);
    }

}

contract UnpauseTests is AuthorizationTestBase {

    // Failure tests

    function test_unpause_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.unpause();
    }

    function test_unpause_guardianCannotUnpause() external {
        vm.expectRevert(_notAuthorized(guardian, DEFAULT_ADMIN_ROLE));
        vm.prank(guardian);
        vault.unpause();
    }

    // Success tests

    function test_unpause() external {
        vm.prank(guardian);
        vault.pause();

        assertEq(vault.paused(), true);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Unpaused();

        vm.prank(admin);
        vault.unpause();

        assertEq(vault.paused(), false);
    }

}

contract SetVSRTests is AuthorizationTestBase {

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);
    }

    // Failure tests

    function test_setVSR_notSetter() external {
        vm.expectRevert(_notAuthorized(unauthorized, VSR_SETTER_ROLE));
        vm.prank(unauthorized);
        vault.setVSR(ONE_PCT_VSR);
    }

    function test_setVSR_vsrTooLowBoundary() external {
        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vm.prank(vsrSetter);
        vault.setVSR(ONE_PCT_VSR - 1);

        vm.prank(vsrSetter);
        vault.setVSR(ONE_PCT_VSR);
    }

    function test_setVSR_vsrTooHighBoundary() external {
        vm.prank(vsrSetter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVSR(FOUR_PCT_VSR + 1);

        vm.prank(vsrSetter);
        vault.setVSR(FOUR_PCT_VSR);
    }

    // Success tests

    function test_setVSR() external {
        uint256 deployTimestamp = block.timestamp;

        skip(10 days);

        assertEq(uint256(vault.chi()), RAY);
        assertEq(uint256(vault.rho()), deployTimestamp);
        assertEq(vault.vsr(),          RAY);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Drip(uint192(RAY), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.VSRSet(FOUR_PCT_VSR);

        vm.prank(vsrSetter);
        vault.setVSR(FOUR_PCT_VSR);

        assertEq(uint256(vault.chi()), RAY);
        assertEq(uint256(vault.rho()), block.timestamp);
        assertEq(vault.vsr(),          FOUR_PCT_VSR);
    }

}

contract TakeTests is AuthorizationTestBase {

    // Failure tests

    function test_take_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, TAKER_ROLE));
        vm.prank(unauthorized);
        vault.take(1_000_000e6);
    }

    function test_take_insufficientSharesBoundary() external {
        _requestDeposit(user, 1_000_000e6);  // Instant fill

        uint256 vaultBalance = spUsdc.balanceOf(address(vault));

        vm.expectRevert("SparkPrimeVault/insufficient-shares");
        vm.prank(taker);
        vault.take(vaultBalance + 1);

        vm.prank(taker);
        vault.take(vaultBalance);
    }

    // Success tests

    function test_take() external {
        uint256 expectedSavingsShares = spUsdc.convertToShares(1_000_000e6);

        _requestDeposit(user, 1_000_000e6); // Instant fill

        assertEq(spUsdc.balanceOf(address(vault)), expectedSavingsShares);
        assertEq(spUsdc.balanceOf(taker),          0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Take(expectedSavingsShares);

        vm.prank(taker);
        vault.take(expectedSavingsShares);

        assertEq(spUsdc.balanceOf(address(vault)), 0);
        assertEq(spUsdc.balanceOf(taker),          expectedSavingsShares);
    }

}

contract SetRedeemFeeRateTests is AuthorizationTestBase {

    // Failure tests

    function test_setRedeemFeeRate_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, REDEEM_FEE_SETTER_ROLE));
        vm.prank(unauthorized);
        vault.setRedeemFeeRate(0.005e18);
    }

    function test_setRedeemFeeRate_feeTooHighBoundary() external {
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(1);  // Can't set a fee until admin sets the max fee

        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0);  // Max is 0 on deployment

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.005e18);

        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.005e18 + 1);

        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.005e18);
    }

    // Success tests

    function test_setRedeemFeeRate() external {
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.01e18);

        assertEq(vault.redeemFeeRate(), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.RedeemFeeRateSet(0.01e18);

        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.01e18);

        assertEq(vault.redeemFeeRate(), 0.01e18);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.RedeemFeeRateSet(0);

        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0);

        assertEq(vault.redeemFeeRate(), 0);
    }

}

contract PauseTests is AuthorizationTestBase {

    // Failure tests

    function test_pause_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, GUARDIAN_ROLE));
        vm.prank(unauthorized);
        vault.pause();
    }

    // Success tests

    function test_pause() external {
        assertEq(vault.paused(), false);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Paused();

        vm.prank(guardian);
        vault.pause();

        assertEq(vault.paused(), true);
    }

}
