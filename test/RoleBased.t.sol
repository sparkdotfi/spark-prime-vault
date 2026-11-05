// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl } from "../lib/oz/contracts/access/IAccessControl.sol";
import { IERC1967 }       from "../lib/oz/contracts/interfaces/IERC1967.sol";

import { TestBase } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../src/SparkPrimeVault.sol";

contract RoleBasedTests is TestBase {

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
        spPrime.grantRole(OPERATOR_ROLE, operator);
    }

    function test_grantRole() external {
        address account = makeAddr("account");

        assertEq(spPrime.hasRole(OPERATOR_ROLE, account), false);

        vm.expectEmit(address(spPrime));
        emit IAccessControl.RoleGranted(OPERATOR_ROLE, account, admin);

        vm.prank(admin);
        spPrime.grantRole(OPERATOR_ROLE, account);

        assertEq(spPrime.hasRole(OPERATOR_ROLE, account), true);
    }

    /**********************************************************************************************/
    /*** revokeRole tests                                                                       ***/
    /**********************************************************************************************/

    function test_revokeRole_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        spPrime.revokeRole(PAUSER_ROLE, pauser);
    }

    function test_revokeRole() external {
        assertEq(spPrime.hasRole(PAUSER_ROLE, pauser), true);

        vm.expectEmit(address(spPrime));
        emit IAccessControl.RoleRevoked(PAUSER_ROLE, pauser, admin);

        vm.prank(admin);
        spPrime.revokeRole(PAUSER_ROLE, pauser);

        assertEq(spPrime.hasRole(PAUSER_ROLE, pauser), false);
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
    /*** impairTotalAssets tests                                                                ***/
    /**********************************************************************************************/

    function test_impairTotalAssets_notLossManager() external {
        vm.expectRevert(_notAuthorized(unauthorized, LOSS_MANAGER_ROLE));
        vm.prank(unauthorized);
        spPrime.impairTotalAssets(0);
    }

    function test_impairTotalAssets_isNotPaused() external {
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vm.prank(lossManager);
        spPrime.impairTotalAssets(0);
    }

    function test_impairTotalAssets_zeroImpairment() external {
        _pause();

        vm.expectRevert(ISparkPrimeVault.ZeroImpairment.selector);
        vm.prank(lossManager);
        spPrime.impairTotalAssets(0);
    }

    function test_impairTotalAssets_impairmentTooLargeBoundary() external {
        _requestDeposit(user, 1_000_000e6);
        _pause();

        assertEq(spPrime.totalAssets(), 1_000_000e6 - 1);  // Rounding

        vm.expectRevert(ISparkPrimeVault.ImpairmentTooLarge.selector);
        vm.prank(lossManager);
        spPrime.impairTotalAssets(1_000_000e6);

        vm.prank(lossManager);
        spPrime.impairTotalAssets(1_000_000e6 - 1);
    }

    function test_impairTotalAssets() external {
        uint256 impairment = 100_000e6;

        _requestDeposit(user, 1_000_000e6);
        _pause();

        skip(365 days);

        uint192 chiBefore    = spPrime.nowChi();
        uint256 assetsBefore = spPrime.totalAssets();
        uint256 supply       = spPrime.totalSupply();

        // Drip is pending, impairTotalAssets must settle it before writing chi down.
        assertEq(chiBefore,    1.049999999999999999961070145e27);  // ~5% APY
        assertEq(assetsBefore, 1_050_000e6 - 2);  // 5% yield accrued
        assertEq(supply,       1_000_000e6 - 1);

        assertEq(spPrime.rho(),          vm.getBlockTimestamp() - 365 days);
        assertEq(spPrime.assetsOf(user), assetsBefore);

        uint192 expectedChi = uint192(((assetsBefore - impairment) * RAY) / supply);

        assertEq(expectedChi, 0.949999999998949999999998949e27);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.TotalAssetsImpaired(lossManager, expectedChi, impairment);

        vm.prank(lossManager);
        spPrime.impairTotalAssets(impairment);

        assertEq(spPrime.chi(),          expectedChi);
        assertEq(spPrime.rho(),          vm.getBlockTimestamp());
        assertEq(spPrime.totalAssets(),  950_000e6 - 3);  // 100k impairment incurred
        assertEq(spPrime.assetsOf(user), 950_000e6 - 3);  // 100k impairment incurred

        assertEq(spPrime.totalAssets(), assetsBefore - impairment - 1);

        // Accrual continues from new chi.

        skip(365 days);

        spPrime.drip();

        // 5% APY over one year, compounding on the new chi
        assertEq(spPrime.chi(),          0.997499999998897499963015534e27);
        assertEq(spPrime.rho(),          vm.getBlockTimestamp());
        assertEq(spPrime.totalAssets(),  997_500e6 - 3);  // 5% yield on 950k
        assertEq(spPrime.assetsOf(user), 997_500e6 - 3);  // 5% yield on 950k

        assertEq(spPrime.chi(), 1.049999999999999999961070145e27 * expectedChi / RAY);

        // Redeem reflects loss.

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
        assertEq(usdc.balanceOf(user),          997_500e6 - 4);
    }

    /**********************************************************************************************/
    /*** setCapacity tests                                                                      ***/
    /**********************************************************************************************/

    function test_setCapacity_notOperator() external {
        vm.expectRevert(_notAuthorized(unauthorized, OPERATOR_ROLE));
        vm.prank(unauthorized);
        spPrime.setCapacity(2_000_000e6);
    }

    function test_setCapacity_capacityTooHighBoundary() external {
        vm.expectRevert(ISparkPrimeVault.CapacityTooHigh.selector);
        vm.prank(operator);
        spPrime.setCapacity(uint256(type(uint128).max) + 1);

        vm.prank(operator);
        spPrime.setCapacity(type(uint128).max);
    }

    function test_setCapacity() external {
        assertEq(spPrime.maxCapacity(),       100_000_000e6);
        assertEq(spPrime.availableCapacity(), 100_000_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.CapacitySet(operator, 2_000_000e6);

        vm.prank(operator);
        spPrime.setCapacity(2_000_000e6);

        assertEq(spPrime.maxCapacity(),       2_000_000e6);
        assertEq(spPrime.availableCapacity(), 2_000_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.CapacitySet(operator, type(uint128).max);

        vm.prank(operator);
        spPrime.setCapacity(type(uint128).max);

        assertEq(spPrime.maxCapacity(),       type(uint128).max);
        assertEq(spPrime.availableCapacity(), type(uint128).max);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.CapacitySet(operator, 0);

        vm.prank(operator);
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

    function test_setMaxRedeemFeeRate_maxFeeTooHighBoundary() external {
        vm.expectRevert(ISparkPrimeVault.MaxFeeTooHigh.selector);
        vm.prank(admin);
        spPrime.setMaxRedeemFeeRate(0.01e18 + 1);

        vm.prank(admin);
        spPrime.setMaxRedeemFeeRate(0.01e18);  // MAX_REDEEM_FEE is 1%
    }

    function test_setMaxRedeemFeeRate() external {
        assertEq(spPrime.maxRedeemFeeRate(), 0);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MaxRedeemFeeRateSet(admin, 0.01e18);

        vm.prank(admin);
        spPrime.setMaxRedeemFeeRate(0.01e18);

        assertEq(spPrime.maxRedeemFeeRate(), 0.01e18);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MaxRedeemFeeRateSet(admin, 0);

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

    function test_setMinDeposit_zeroMinDeposit() external {
        vm.expectRevert(ISparkPrimeVault.ZeroMinDeposit.selector);
        vm.prank(admin);
        spPrime.setMinDeposit(0);
    }

    function test_setMinDeposit() external {
        assertEq(spPrime.minDeposit(), MINIMUM_DEPOSIT);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MinDepositSet(admin, 100e6);

        vm.prank(admin);
        spPrime.setMinDeposit(100e6);

        assertEq(spPrime.minDeposit(), 100e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MinDepositSet(admin, 1);

        vm.prank(admin);
        spPrime.setMinDeposit(1);

        assertEq(spPrime.minDeposit(), 1);
    }

    /**********************************************************************************************/
    /*** setMinDepositCancellation tests                                                        ***/
    /**********************************************************************************************/

    function test_setMinDepositCancellation_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        spPrime.setMinDepositCancellation(100e6);
    }

    function test_setMinDepositCancellation_zeroMinDepositCancellation() external {
        vm.expectRevert(ISparkPrimeVault.ZeroMinDepositCancellation.selector);
        vm.prank(admin);
        spPrime.setMinDepositCancellation(0);
    }

    function test_setMinDepositCancellation() external {
        assertEq(spPrime.minDepositCancellation(), MINIMUM_DEPOSIT_CANCELLATION);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MinDepositCancellationSet(admin, 200e6);

        vm.prank(admin);
        spPrime.setMinDepositCancellation(200e6);

        assertEq(spPrime.minDepositCancellation(), 200e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MinDepositCancellationSet(admin, 1);

        vm.prank(admin);
        spPrime.setMinDepositCancellation(1);

        assertEq(spPrime.minDepositCancellation(), 1);
    }

    /**********************************************************************************************/
    /*** setMinRedeem tests                                                                     ***/
    /**********************************************************************************************/

    function test_setMinRedeem_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        spPrime.setMinRedeem(100e6);
    }

    function test_setMinRedeem_zeroMinRedeem() external {
        vm.expectRevert(ISparkPrimeVault.ZeroMinRedeem.selector);
        vm.prank(admin);
        spPrime.setMinRedeem(0);
    }

    function test_setMinRedeem() external {
        assertEq(spPrime.minRedeem(), MINIMUM_REDEEM);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MinRedeemSet(admin, 100e6);

        vm.prank(admin);
        spPrime.setMinRedeem(100e6);

        assertEq(spPrime.minRedeem(), 100e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.MinRedeemSet(admin, 1);

        vm.prank(admin);
        spPrime.setMinRedeem(1);

        assertEq(spPrime.minRedeem(), 1);
    }

    /**********************************************************************************************/
    /*** setVSRBounds tests                                                                     ***/
    /**********************************************************************************************/

    function test_setVSRBounds_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        spPrime.setVSRBounds({ minVSR_ : RAY, maxVSR_ : FOUR_PCT_VSR });
    }

    function test_setVSRBounds_minVSRTooLowBoundary() external {
        vm.expectRevert(ISparkPrimeVault.MinVSRTooLow.selector);
        vm.prank(admin);
        spPrime.setVSRBounds({ minVSR_ : RAY - 1, maxVSR_ : FOUR_PCT_VSR });

        vm.prank(admin);
        spPrime.setVSRBounds({ minVSR_ : RAY, maxVSR_ : FOUR_PCT_VSR });
    }

    function test_setVSRBounds_maxVSRTooHighBoundary() external {
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
        emit ISparkPrimeVault.VSRBoundsSet(admin, ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.prank(admin);
        spPrime.setVSRBounds({ minVSR_ : ONE_PCT_VSR, maxVSR_ : FOUR_PCT_VSR });

        assertEq(spPrime.minVSR(), ONE_PCT_VSR);
        assertEq(spPrime.maxVSR(), FOUR_PCT_VSR);
    }

    /**********************************************************************************************/
    /*** unpause tests                                                                          ***/
    /**********************************************************************************************/

    function test_unpause_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, UNPAUSER_ROLE));
        vm.prank(unauthorized);
        spPrime.unpause();
    }

    function test_unpause_pauserCannotUnpause() external {
        vm.expectRevert(_notAuthorized(pauser, UNPAUSER_ROLE));
        vm.prank(pauser);
        spPrime.unpause();
    }

    function test_unpause() external {
        _pause();

        assertEq(spPrime.paused(), true);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Unpaused(unpauser);

        vm.prank(unpauser);
        spPrime.unpause();

        assertEq(spPrime.paused(), false);
    }

    /**********************************************************************************************/
    /*** setVSR tests                                                                           ***/
    /**********************************************************************************************/

    function test_setVSR_notSetter() external {
        vm.expectRevert(_notAuthorized(unauthorized, OPERATOR_ROLE));
        vm.prank(unauthorized);
        spPrime.setVSR(ONE_PCT_VSR);
    }

    function test_setVSR_vsrTooLowBoundary() external {
        vm.prank(admin);
        spPrime.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.expectRevert(ISparkPrimeVault.VSRTooLow.selector);
        vm.prank(operator);
        spPrime.setVSR(ONE_PCT_VSR - 1);

        vm.prank(operator);
        spPrime.setVSR(ONE_PCT_VSR);
    }

    function test_setVSR_vsrTooHighBoundary() external {
        vm.prank(admin);
        spPrime.setVSRBounds(RAY, FOUR_PCT_VSR);

        vm.expectRevert(ISparkPrimeVault.VSRTooHigh.selector);
        vm.prank(operator);
        spPrime.setVSR(FOUR_PCT_VSR + 1);

        vm.prank(operator);
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
        emit ISparkPrimeVault.VSRSet(operator, FOUR_PCT_VSR);

        vm.prank(operator);
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
        emit ISparkPrimeVault.Take(taker, expectedSavingsShares);

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
        emit ISparkPrimeVault.RedeemFeeRateSet(redeemFeeSetter, 0.01e18);

        vm.prank(redeemFeeSetter);
        spPrime.setRedeemFeeRate(0.01e18);

        assertEq(spPrime.redeemFeeRate(), 0.01e18);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.RedeemFeeRateSet(redeemFeeSetter, 0);

        vm.prank(redeemFeeSetter);
        spPrime.setRedeemFeeRate(0);

        assertEq(spPrime.redeemFeeRate(), 0);
    }

    /**********************************************************************************************/
    /*** pause tests                                                                            ***/
    /**********************************************************************************************/

    function test_pause_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, PAUSER_ROLE));
        vm.prank(unauthorized);
        spPrime.pause();
    }

    function test_pause() external {
        assertEq(spPrime.paused(), false);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Paused(pauser);

        vm.prank(pauser);
        spPrime.pause();

        assertEq(spPrime.paused(), true);
    }

    /**********************************************************************************************/
    /*** drip tests                                                                             ***/
    /**********************************************************************************************/

    function test_drip_earlyExit() external {
        _requestDeposit(user, 1_000_000e6);

        assertEq(spPrime.chi(), 1.000000000000000000000000000e27);
        assertEq(spPrime.rho(), vm.getBlockTimestamp());

        uint192 chi = spPrime.drip();

        assertEq(chi, 1.000000000000000000000000000e27);

        assertEq(spPrime.chi(), 1.000000000000000000000000000e27);
        assertEq(spPrime.rho(), vm.getBlockTimestamp());
    }

    function test_drip_oneYear() external {
        _requestDeposit(user, 1_000_000e6);

        assertEq(spPrime.chi(), 1.000000000000000000000000000e27);
        assertEq(spPrime.rho(), vm.getBlockTimestamp());

        skip(365 days);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Drip(uint192(1.049999999999999999961070145e27), 50_000e6 - 1);

        uint192 chi = spPrime.drip();

        assertEq(chi, 1.049999999999999999961070145e27);

        assertEq(spPrime.chi(), 1.049999999999999999961070145e27);
        assertEq(spPrime.rho(), vm.getBlockTimestamp());
    }

}
