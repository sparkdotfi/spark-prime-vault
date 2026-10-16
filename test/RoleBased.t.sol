// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError }               from "../lib/forge-std/src/StdError.sol";
import { stdStorage, StdStorage } from "../lib/forge-std/src/StdStorage.sol";

import { IAccessControl } from "../lib/oz/contracts/access/IAccessControl.sol";
import { IERC1967 }       from "../lib/oz/contracts/interfaces/IERC1967.sol";

import { TestBase } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../src/SparkPrimeVault.sol";

contract RoleBasedTests is TestBase {

    using stdStorage for StdStorage;

    address internal user         = makeAddr("user");
    address internal unauthorized = makeAddr("unauthorized");

    function _notAuthorized(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            account,
            role
        );
    }

    /**********************************************************************************************/
    /*** grantRole tests                                                                        ***/
    /**********************************************************************************************/

    function test_grantRole_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        spPrime.grantRole(PROCESSOR_ROLE, processor);
    }

    function test_grantRole() external {
        address account = makeAddr("account");

        assertEq(spPrime.hasRole(PROCESSOR_ROLE, account), false);

        vm.expectEmit(address(spPrime));
        emit IAccessControl.RoleGranted(PROCESSOR_ROLE, account, admin);

        vm.prank(admin);
        spPrime.grantRole(PROCESSOR_ROLE, account);

        assertEq(spPrime.hasRole(PROCESSOR_ROLE, account), true);
    }

    /**********************************************************************************************/
    /*** revokeRole tests                                                                       ***/
    /**********************************************************************************************/

    function test_revokeRole_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        spPrime.revokeRole(GUARDIAN_ROLE, guardian);
    }

    function test_revokeRole() external {
        assertEq(spPrime.hasRole(GUARDIAN_ROLE, guardian), true);

        vm.expectEmit(address(spPrime));
        emit IAccessControl.RoleRevoked(GUARDIAN_ROLE, guardian, admin);

        vm.prank(admin);
        spPrime.revokeRole(GUARDIAN_ROLE, guardian);

        assertEq(spPrime.hasRole(GUARDIAN_ROLE, guardian), false);
    }

    /**********************************************************************************************/
    /*** upgradeToAndCall tests                                                                 ***/
    /**********************************************************************************************/

    function test_upgradeToAndCall_notAdmin() external {
        address newImplementation = address(new SparkPrimeVault());

        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        spPrime.upgradeToAndCall(newImplementation, "");
    }

    function test_upgradeToAndCall() external {
        address newImplementation = address(new SparkPrimeVault());

        assertNotEq(spPrime.implementation(), newImplementation);

        vm.expectEmit(address(spPrime));
        emit IERC1967.Upgraded(newImplementation);

        vm.prank(admin);
        spPrime.upgradeToAndCall(newImplementation, "");

        assertEq(spPrime.implementation(), newImplementation);
    }

    /**********************************************************************************************/
    /*** adjustTotalAssets tests                                                                ***/
    /**********************************************************************************************/

    function test_adjustTotalAssets_notAdmin() external {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        spPrime.adjustTotalAssets(-1e6);
    }

    function test_adjustTotalAssets_notPaused() external {
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vm.prank(admin);
        spPrime.adjustTotalAssets(-1e6);
    }

    function test_adjustTotalAssets_zeroDeltaTotalAssets() external {
        _pause();

        vm.expectRevert(ISparkPrimeVault.ZeroDeltaTotalAssets.selector);
        vm.prank(admin);
        spPrime.adjustTotalAssets(0);
    }

    function test_adjustTotalAssets_lossTooHighBoundary() external {
        _requestDeposit(user, 1_000_000e6);
        _pause();

        assertEq(spPrime.totalAssets(), 1_000_000e6 - 1);  // Rounding

        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vm.prank(admin);
        spPrime.adjustTotalAssets(-(1_000_000e6 - 1));

        vm.prank(admin);
        spPrime.adjustTotalAssets(-(1_000_000e6 - 2));
    }

    function test_adjustTotalAssets_zeroSupply() external {
        _pause();

        vm.expectRevert(stdError.divisionError);
        vm.prank(admin);
        spPrime.adjustTotalAssets(1e6);
    }

    function test_adjustTotalAssets_invalidChiBoundary() external {
        _pause();

        // Inflate supply so that `totalAssets * RAY / totalSupply` can round down to zero.
        uint256 supply = 1e28;

        stdstore.target(address(spPrime)).sig("totalSupply()").checked_write(supply);

        int256 totalAssets = int256(spPrime.totalAssets());

        assertEq(uint256(totalAssets), supply);  // chi == RAY

        // totalAssets -> 9: chi = 9e27 / 1e28 = 0
        vm.expectRevert(ISparkPrimeVault.ChiTooLow.selector);
        vm.prank(admin);
        spPrime.adjustTotalAssets(-(totalAssets - 9));

        // totalAssets -> 10: chi = 10e27 / 1e28 = 1
        vm.prank(admin);
        spPrime.adjustTotalAssets(-(totalAssets - 10));

        assertEq(spPrime.chi(), 1);
    }

    function test_adjustTotalAssets_loss() external {
        uint256 loss = 100_000e6;

        _requestDeposit(user, 1_000_000e6);
        _pause();

        skip(365 days);

        uint192 chiBefore    = spPrime.nowChi();
        uint256 assetsBefore = spPrime.totalAssets();
        uint256 supply       = spPrime.totalSupply();

        // Drip is pending, adjustTotalAssets must settle it before writing chi down.
        assertEq(chiBefore,    1.049999999999999999961070145e27);  // ~5% APY
        assertEq(supply,       1_000_000e6 - 1);  // Rounding
        assertEq(assetsBefore, 1_050_000e6 - 2);  // Rounding, 5% yield accrued

        assertEq(spPrime.rho(),          vm.getBlockTimestamp() - 365 days);
        assertEq(spPrime.assetsOf(user), assetsBefore);

        uint192 expectedChi = uint192(((assetsBefore - loss) * RAY) / supply);

        assertEq(expectedChi, 0.949999999998949999999998949e27);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.TotalAssetsAdjusted(expectedChi, -int256(loss));

        vm.prank(admin);
        spPrime.adjustTotalAssets(-int256(loss));

        assertEq(spPrime.chi(),          expectedChi);
        assertEq(spPrime.rho(),          vm.getBlockTimestamp());
        assertEq(spPrime.totalAssets(),  950_000e6 - 3);  // Rounding, 100k loss incurred
        assertEq(spPrime.assetsOf(user), 950_000e6 - 3);  // Rounding, 100k loss incurred

        assertEq(spPrime.totalAssets(), assetsBefore - loss - 1);  // Rounding
    }

    function test_adjustTotalAssets_gain() external {
        uint256 gain = 100_000e6;

        _requestDeposit(user, 1_000_000e6);
        _pause();

        skip(365 days);

        uint192 chiBefore    = spPrime.nowChi();
        uint256 assetsBefore = spPrime.totalAssets();
        uint256 supply       = spPrime.totalSupply();

        // Drip is pending, adjustTotalAssets must settle it before writing chi up.
        assertEq(chiBefore,    1.049999999999999999961070145e27);  // ~5% APY
        assertEq(supply,       1_000_000e6 - 1);  // Rounding
        assertEq(assetsBefore, 1_050_000e6 - 2);  // Rounding, 5% yield accrued

        assertEq(spPrime.rho(),          vm.getBlockTimestamp() - 365 days);
        assertEq(spPrime.assetsOf(user), assetsBefore);

        uint192 expectedChi = uint192(((assetsBefore + gain) * RAY) / supply);

        assertEq(expectedChi, 1.149999999999149999999999149e27);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.TotalAssetsAdjusted(expectedChi, int256(gain));

        vm.prank(admin);
        spPrime.adjustTotalAssets(int256(gain));

        assertEq(spPrime.chi(),          expectedChi);
        assertEq(spPrime.rho(),          vm.getBlockTimestamp());
        assertEq(spPrime.totalAssets(),  1_150_000e6 - 3);  // Rounding, 100k gain realized
        assertEq(spPrime.assetsOf(user), 1_150_000e6 - 3);  // Rounding, 100k gain realized

        assertEq(spPrime.totalAssets(), assetsBefore + gain - 1);  // Rounding
    }

    function test_adjustTotalAssets_accrualContinuesFromNewChi() external {
        uint256 loss = 100_000e6;

        _requestDeposit(user, 1_000_000e6);
        _pause();

        uint192 chiBefore    = spPrime.nowChi();
        uint256 assetsBefore = spPrime.totalAssets();
        uint256 supply       = spPrime.totalSupply();

        // No time has passed, nothing to drip.
        assertEq(chiBefore,    1e27);
        assertEq(supply,       1_000_000e6 - 1);  // Rounding
        assertEq(assetsBefore, 1_000_000e6 - 1);  // Rounding

        assertEq(spPrime.rho(),          vm.getBlockTimestamp());
        assertEq(spPrime.assetsOf(user), assetsBefore);

        uint192 expectedChi = uint192(((assetsBefore - loss) * RAY) / supply);

        assertEq(expectedChi, 0.899999999999899999999999899e27);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.TotalAssetsAdjusted(expectedChi, -int256(loss));

        vm.prank(admin);
        spPrime.adjustTotalAssets(-int256(loss));

        assertEq(spPrime.chi(),          expectedChi);
        assertEq(spPrime.rho(),          vm.getBlockTimestamp());
        assertEq(spPrime.totalAssets(),  900_000e6 - 2);  // Rounding, 100k loss incurred
        assertEq(spPrime.assetsOf(user), 900_000e6 - 2);  // Rounding, 100k loss incurred

        skip(365 days);

        spPrime.drip();

        // 5% APY over one year, compounding on the new chi
        assertEq(spPrime.chi(),          0.944999999999894999964963024e27);
        assertEq(spPrime.rho(),          vm.getBlockTimestamp());
        assertEq(spPrime.totalAssets(),  945_000e6 - 2);  // Rounding, 5% yield on 900k
        assertEq(spPrime.assetsOf(user), 945_000e6 - 2);  // Rounding, 5% yield on 900k

        assertEq(spPrime.chi(), 1.049999999999999999961070145e27 * expectedChi / RAY);
    }

    function test_adjustTotalAssets_redeemReflectsLoss() external {
        uint256 loss = 100_000e6;

        _requestDeposit(user, 1_000_000e6);
        _pause();

        uint192 chiBefore    = spPrime.nowChi();
        uint256 assetsBefore = spPrime.totalAssets();
        uint256 supply       = spPrime.totalSupply();

        // No time has passed, nothing to drip.
        assertEq(chiBefore,    1e27);
        assertEq(supply,       1_000_000e6 - 1);  // Rounding
        assertEq(assetsBefore, 1_000_000e6 - 1);  // Rounding

        assertEq(spPrime.rho(),          vm.getBlockTimestamp());
        assertEq(spPrime.assetsOf(user), assetsBefore);

        uint192 expectedChi = uint192(((assetsBefore - loss) * RAY) / supply);

        assertEq(expectedChi, 0.899999999999899999999999899e27);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.TotalAssetsAdjusted(expectedChi, -int256(loss));

        vm.prank(admin);
        spPrime.adjustTotalAssets(-int256(loss));

        assertEq(spPrime.chi(),          expectedChi);
        assertEq(spPrime.rho(),          vm.getBlockTimestamp());
        assertEq(spPrime.totalAssets(),  900_000e6 - 2);  // Rounding, 100k loss incurred
        assertEq(spPrime.assetsOf(user), 900_000e6 - 2);  // Rounding, 100k loss incurred

        _unpause();

        assertEq(spPrime.balanceOf(user),       supply);
        assertEq(spPrime.pendingRedeemShares(), 0);
        assertEq(usdc.balanceOf(user),          0);

        _requestRedeem(user, supply);

        assertEq(spPrime.balanceOf(user),       0);
        assertEq(spPrime.pendingRedeemShares(), supply);
        assertEq(usdc.balanceOf(user),          0);

        _processPendingRedeems();

        // User receives the post-loss value of their shares, not the 1M deposited.
        assertEq(spPrime.balanceOf(user),       0);
        assertEq(spPrime.pendingRedeemShares(), 0);
        assertEq(spPrime.totalSupply(),         0);
        assertEq(spPrime.totalAssets(),         0);
        assertEq(usdc.balanceOf(user),          900_000e6 - 2);  // Rounding, 100k loss incurred
    }

    /**********************************************************************************************/
    /*** setCapacity tests                                                                      ***/
    /**********************************************************************************************/

    function test_setCapacity_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        spPrime.setCapacity(2_000_000e6);
    }

    function test_setCapacity() external {
        assertEq(spPrime.maxCapacity(),       100_000_000e6);
        assertEq(spPrime.availableCapacity(), 100_000_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.CapacitySet(2_000_000e6);

        vm.prank(admin);
        spPrime.setCapacity(2_000_000e6);

        assertEq(spPrime.maxCapacity(),       2_000_000e6);
        assertEq(spPrime.availableCapacity(), 2_000_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.CapacitySet(type(uint256).max);

        vm.prank(admin);
        spPrime.setCapacity(type(uint256).max);

        assertEq(spPrime.maxCapacity(),       type(uint256).max);
        assertEq(spPrime.availableCapacity(), type(uint256).max);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.CapacitySet(0);

        vm.prank(admin);
        spPrime.setCapacity(0);

        assertEq(spPrime.maxCapacity(),       0);
        assertEq(spPrime.availableCapacity(), 0);
    }

    /**********************************************************************************************/
    /*** setMaxRedeemFeeRate tests                                                              ***/
    /**********************************************************************************************/

    function test_setMaxRedeemFeeRate_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        spPrime.setMaxRedeemFeeRate(0.01e18);
    }

    function test_setMaxRedeemFee_feeTooHighBoundary() external {
        vm.expectRevert(ISparkPrimeVault.MaxFeeTooHigh.selector);
        vm.prank(admin);
        spPrime.setMaxRedeemFeeRate(0.01e18 + 1);

        vm.prank(admin);
        spPrime.setMaxRedeemFeeRate(0.01e18);  // MAX_REDEEM_FEE is 1%
    }

    function test_setMaxRedeemFeeRate() external {
        assertEq(spPrime.maxRedeemFeeRate(), 0);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MaxRedeemFeeRateSet(0.01e18);

        vm.prank(admin);
        spPrime.setMaxRedeemFeeRate(0.01e18);

        assertEq(spPrime.maxRedeemFeeRate(), 0.01e18);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MaxRedeemFeeRateSet(0);

        vm.prank(admin);
        spPrime.setMaxRedeemFeeRate(0);

        assertEq(spPrime.maxRedeemFeeRate(), 0);
    }

    /**********************************************************************************************/
    /*** setMinDeposit tests                                                                    ***/
    /**********************************************************************************************/

    function test_setMinDeposit_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        spPrime.setMinDeposit(100e6);
    }

    function test_setMinDeposit() external {
        assertEq(spPrime.minDeposit(), MINIMUM_DEPOSIT);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MinDepositSet(100e6);

        vm.prank(admin);
        spPrime.setMinDeposit(100e6);

        assertEq(spPrime.minDeposit(), 100e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MinDepositSet(0);

        vm.prank(admin);
        spPrime.setMinDeposit(0);

        assertEq(spPrime.minDeposit(), 0);
    }

    /**********************************************************************************************/
    /*** setMinRedeem tests                                                                     ***/
    /**********************************************************************************************/

    function test_setMinRedeem_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        spPrime.setMinRedeem(100e6);
    }

    function test_setMinRedeem() external {
        assertEq(spPrime.minRedeem(), MINIMUM_REDEEM);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MinRedeemSet(100e6);

        vm.prank(admin);
        spPrime.setMinRedeem(100e6);

        assertEq(spPrime.minRedeem(), 100e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MinRedeemSet(0);

        vm.prank(admin);
        spPrime.setMinRedeem(0);

        assertEq(spPrime.minRedeem(), 0);
    }

    /**********************************************************************************************/
    /*** setVSRBounds tests                                                                     ***/
    /**********************************************************************************************/

    function test_setVSRBounds_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        spPrime.setVSRBounds({ minVSR_ : RAY, maxVSR_ : FOUR_PCT_VSR });
    }

    function test_setVSRBounds_vsrTooLowBoundary() external {
        vm.expectRevert(ISparkPrimeVault.MinVSRTooLow.selector);
        vm.prank(admin);
        spPrime.setVSRBounds({ minVSR_ : RAY - 1, maxVSR_ : FOUR_PCT_VSR });

        vm.prank(admin);
        spPrime.setVSRBounds({ minVSR_ : RAY, maxVSR_ : FOUR_PCT_VSR });
    }

    function test_setVSRBounds_vsrTooHighBoundary() external {
        uint256 maxVsr = spPrime.MAX_VSR();

        vm.expectRevert(ISparkPrimeVault.MaxVSRTooHigh.selector);
        vm.prank(admin);
        spPrime.setVSRBounds({ minVSR_ : RAY, maxVSR_ : maxVsr + 1 });

        vm.prank(admin);
        spPrime.setVSRBounds({ minVSR_ : RAY, maxVSR_ : maxVsr });
    }

    function test_setVSRBounds_minVSRGtMaxVSRBoundary() external {
        vm.expectRevert(ISparkPrimeVault.MinVSRGtMaxVSR.selector);
        vm.prank(admin);
        spPrime.setVSRBounds({ minVSR_ : FOUR_PCT_VSR + 1, maxVSR_ : FOUR_PCT_VSR });

        vm.prank(admin);
        spPrime.setVSRBounds({ minVSR_ : FOUR_PCT_VSR, maxVSR_ : FOUR_PCT_VSR });
    }

    function test_setVSRBounds() external {
        assertEq(spPrime.minVSR(), RAY);
        assertEq(spPrime.maxVSR(), spPrime.MAX_VSR());

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.VSRBoundsSet(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.prank(admin);
        spPrime.setVSRBounds({ minVSR_ : ONE_PCT_VSR, maxVSR_ : FOUR_PCT_VSR });

        assertEq(spPrime.minVSR(), ONE_PCT_VSR);
        assertEq(spPrime.maxVSR(), FOUR_PCT_VSR);
    }

    /**********************************************************************************************/
    /*** unpause tests                                                                          ***/
    /**********************************************************************************************/

    function test_unpause_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        spPrime.unpause();
    }

    function test_unpause_guardianCannotUnpause() external {
        vm.expectRevert(_notAuthorized(guardian, DEFAULT_ADMIN_ROLE));
        vm.prank(guardian);
        spPrime.unpause();
    }

    function test_unpause() external {
        _pause();

        assertEq(spPrime.paused(), true);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Unpaused();

        vm.prank(admin);
        spPrime.unpause();

        assertEq(spPrime.paused(), false);
    }

    /**********************************************************************************************/
    /*** setVSR tests                                                                           ***/
    /**********************************************************************************************/

    function test_setVSR_notSetter() external {
        vm.expectRevert(_notAuthorized(unauthorized, VSR_SETTER_ROLE));
        vm.prank(unauthorized);
        spPrime.setVSR(ONE_PCT_VSR);
    }

    function test_setVSR_vsrTooLowBoundary() external {
        vm.prank(admin);
        spPrime.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.expectRevert(ISparkPrimeVault.VSRTooLow.selector);
        vm.prank(vsrSetter);
        spPrime.setVSR(ONE_PCT_VSR - 1);

        vm.prank(vsrSetter);
        spPrime.setVSR(ONE_PCT_VSR);
    }

    function test_setVSR_vsrTooHighBoundary() external {
        vm.prank(admin);
        spPrime.setVSRBounds(RAY, FOUR_PCT_VSR);

        vm.expectRevert(ISparkPrimeVault.VSRTooHigh.selector);
        vm.prank(vsrSetter);
        spPrime.setVSR(FOUR_PCT_VSR + 1);

        vm.prank(vsrSetter);
        spPrime.setVSR(FOUR_PCT_VSR);
    }

    function test_setVSR() external {
        uint256 deployTimestamp = vm.getBlockTimestamp();

        skip(10 days);

        assertEq(uint256(spPrime.chi()), RAY);
        assertEq(uint256(spPrime.rho()), deployTimestamp);
        assertEq(spPrime.vsr(),          1.000000001547125957863212448e27);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Drip(uint192(1.001337610630706965934046250e27), 0);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.VSRSet(FOUR_PCT_VSR);

        vm.prank(vsrSetter);
        spPrime.setVSR(FOUR_PCT_VSR);

        assertEq(uint256(spPrime.chi()), 1.001337610630706965934046250e27);
        assertEq(uint256(spPrime.rho()), vm.getBlockTimestamp());
        assertEq(spPrime.vsr(),          FOUR_PCT_VSR);
    }

    /**********************************************************************************************/
    /*** take tests                                                                             ***/
    /**********************************************************************************************/

    function test_take_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, TAKER_ROLE));
        vm.prank(unauthorized);
        spPrime.take(1_000_000e6);
    }

    function test_take_insufficientSharesBoundary() external {
        _requestDeposit(user, 1_000_000e6);  // Instant fill

        uint256 vaultBalance = spUSDC.balanceOf(address(spPrime));

        vm.expectRevert(ISparkPrimeVault.InsufficientShares.selector);
        vm.prank(taker);
        spPrime.take(vaultBalance + 1);

        vm.prank(taker);
        spPrime.take(vaultBalance);
    }

    function test_take() external {
        uint256 expectedSavingsShares = spUSDC.convertToShares(1_000_000e6);

        _requestDeposit(user, 1_000_000e6);  // Instant fill

        assertEq(spUSDC.balanceOf(address(spPrime)), expectedSavingsShares);
        assertEq(spUSDC.balanceOf(taker),            0);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Take(expectedSavingsShares);

        vm.prank(taker);
        spPrime.take(expectedSavingsShares);

        assertEq(spUSDC.balanceOf(address(spPrime)), 0);
        assertEq(spUSDC.balanceOf(taker),            expectedSavingsShares);
    }

    /**********************************************************************************************/
    /*** setRedeemFeeRate tests                                                                 ***/
    /**********************************************************************************************/

    function test_setRedeemFeeRate_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, REDEEM_FEE_SETTER_ROLE));
        vm.prank(unauthorized);
        spPrime.setRedeemFeeRate(0.005e18);
    }

    function test_setRedeemFeeRate_feeTooHighBoundary() external {
        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
        vm.prank(redeemFeeSetter);
        spPrime.setRedeemFeeRate(1);  // Can't set a fee until admin sets the max fee

        vm.prank(redeemFeeSetter);
        spPrime.setRedeemFeeRate(0);  // Max is 0 on deployment

        vm.prank(admin);
        spPrime.setMaxRedeemFeeRate(0.005e18);

        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
        vm.prank(redeemFeeSetter);
        spPrime.setRedeemFeeRate(0.005e18 + 1);

        vm.prank(redeemFeeSetter);
        spPrime.setRedeemFeeRate(0.005e18);
    }

    function test_setRedeemFeeRate() external {
        vm.prank(admin);
        spPrime.setMaxRedeemFeeRate(0.01e18);

        assertEq(spPrime.redeemFeeRate(), 0);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.RedeemFeeRateSet(0.01e18);

        vm.prank(redeemFeeSetter);
        spPrime.setRedeemFeeRate(0.01e18);

        assertEq(spPrime.redeemFeeRate(), 0.01e18);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.RedeemFeeRateSet(0);

        vm.prank(redeemFeeSetter);
        spPrime.setRedeemFeeRate(0);

        assertEq(spPrime.redeemFeeRate(), 0);
    }

    /**********************************************************************************************/
    /*** pause tests                                                                            ***/
    /**********************************************************************************************/

    function test_pause_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, GUARDIAN_ROLE));
        vm.prank(unauthorized);
        spPrime.pause();
    }

    function test_pause() external {
        assertEq(spPrime.paused(), false);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Paused();

        vm.prank(guardian);
        spPrime.pause();

        assertEq(spPrime.paused(), true);
    }

}
