// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError }               from "../lib/forge-std/src/StdError.sol";
import { stdStorage, StdStorage } from "../lib/forge-std/src/StdStorage.sol";

import { IAccessControl } from "../lib/oz/contracts/access/IAccessControl.sol";

import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

import { TestBase } from "./TestBase.t.sol";

contract AdjustTotalAssetsTests is TestBase {

    using stdStorage for StdStorage;

    address internal user = makeAddr("user");

    /**********************************************************************************************/
    /*** Failure tests                                                                          ***/
    /**********************************************************************************************/

    function test_adjustTotalAssets_notAdmin() external {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        spPRIME.adjustTotalAssets(-1e6);
    }

    function test_adjustTotalAssets_notPaused() external {
        vm.expectRevert("SparkPrimeVault/not-paused");
        vm.prank(admin);
        spPRIME.adjustTotalAssets(-1e6);
    }

    function test_adjustTotalAssets_zeroDeltaTotalAssets() external {
        _pause();

        vm.expectRevert("SparkPrimeVault/delta-total-assets-zero");
        vm.prank(admin);
        spPRIME.adjustTotalAssets(0);
    }

    function test_adjustTotalAssets_lossTooHighBoundary() external {
        _requestDeposit(user, 1_000_000e6);
        _pause();

        assertEq(spPRIME.totalAssets(), 1_000_000e6 - 1);  // Rounding

        vm.expectRevert("SparkPrimeVault/loss-too-high");
        vm.prank(admin);
        spPRIME.adjustTotalAssets(-(1_000_000e6 - 1));

        vm.prank(admin);
        spPRIME.adjustTotalAssets(-(1_000_000e6 - 2));
    }

    function test_adjustTotalAssets_zeroSupply() external {
        _pause();

        vm.expectRevert(stdError.divisionError);
        vm.prank(admin);
        spPRIME.adjustTotalAssets(1e6);
    }

    function test_adjustTotalAssets_invalidChiBoundary() external {
        _pause();

        // Inflate supply so that `totalAssets * RAY / totalSupply` can round down to zero.
        uint256 supply = 1e28;

        stdstore.target(address(spPRIME)).sig("totalSupply()").checked_write(supply);

        int256 totalAssets = int256(spPRIME.totalAssets());

        assertEq(uint256(totalAssets), supply);  // chi == RAY

        // totalAssets -> 9: chi = 9e27 / 1e28 = 0
        vm.expectRevert("SparkPrimeVault/chi-too-low");
        vm.prank(admin);
        spPRIME.adjustTotalAssets(-(totalAssets - 9));

        // totalAssets -> 10: chi = 10e27 / 1e28 = 1
        vm.prank(admin);
        spPRIME.adjustTotalAssets(-(totalAssets - 10));

        assertEq(spPRIME.chi(), 1);
    }

    /**********************************************************************************************/
    /*** Success tests                                                                          ***/
    /**********************************************************************************************/

    function test_adjustTotalAssets_loss() external {
        uint256 loss = 100_000e6;

        _requestDeposit(user, 1_000_000e6);
        _pause();

        skip(365 days);

        uint192 chiBefore    = spPRIME.nowChi();
        uint256 assetsBefore = spPRIME.totalAssets();
        uint256 supply       = spPRIME.totalSupply();

        // Drip is pending, adjustTotalAssets must settle it before writing chi down.
        assertEq(chiBefore,    1.049999999999999999961070145e27);  // ~5% APY
        assertEq(supply,       1_000_000e6 - 1);  // Rounding
        assertEq(assetsBefore, 1_050_000e6 - 2);  // Rounding, 5% yield accrued

        assertEq(spPRIME.rho(),          block.timestamp - 365 days);
        assertEq(spPRIME.assetsOf(user), assetsBefore);

        uint192 expectedChi = uint192(((assetsBefore - loss) * RAY) / supply);

        assertEq(expectedChi, 0.949999999998949999999998949e27);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.TotalAssetsAdjusted(expectedChi, -int256(loss));

        vm.prank(admin);
        spPRIME.adjustTotalAssets(-int256(loss));

        assertEq(spPRIME.chi(),          expectedChi);
        assertEq(spPRIME.rho(),          block.timestamp);
        assertEq(spPRIME.totalAssets(),  950_000e6 - 3);  // Rounding, 100k loss incurred
        assertEq(spPRIME.assetsOf(user), 950_000e6 - 3);  // Rounding, 100k loss incurred

        assertEq(spPRIME.totalAssets(), assetsBefore - loss - 1);  // Rounding
    }

    function test_adjustTotalAssets_gain() external {
        uint256 gain = 100_000e6;

        _requestDeposit(user, 1_000_000e6);
        _pause();

        skip(365 days);

        uint192 chiBefore    = spPRIME.nowChi();
        uint256 assetsBefore = spPRIME.totalAssets();
        uint256 supply       = spPRIME.totalSupply();

        // Drip is pending, adjustTotalAssets must settle it before writing chi up.
        assertEq(chiBefore,    1.049999999999999999961070145e27);  // ~5% APY
        assertEq(supply,       1_000_000e6 - 1);  // Rounding
        assertEq(assetsBefore, 1_050_000e6 - 2);  // Rounding, 5% yield accrued

        assertEq(spPRIME.rho(),          block.timestamp - 365 days);
        assertEq(spPRIME.assetsOf(user), assetsBefore);

        uint192 expectedChi = uint192(((assetsBefore + gain) * RAY) / supply);

        assertEq(expectedChi, 1.149999999999149999999999149e27);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.TotalAssetsAdjusted(expectedChi, int256(gain));

        vm.prank(admin);
        spPRIME.adjustTotalAssets(int256(gain));

        assertEq(spPRIME.chi(),          expectedChi);
        assertEq(spPRIME.rho(),          block.timestamp);
        assertEq(spPRIME.totalAssets(),  1_150_000e6 - 3);  // Rounding, 100k gain realized
        assertEq(spPRIME.assetsOf(user), 1_150_000e6 - 3);  // Rounding, 100k gain realized

        assertEq(spPRIME.totalAssets(), assetsBefore + gain - 1);  // Rounding
    }

    function test_adjustTotalAssets_accrualContinuesFromNewChi() external {
        uint256 loss = 100_000e6;

        _requestDeposit(user, 1_000_000e6);
        _pause();

        uint192 chiBefore    = spPRIME.nowChi();
        uint256 assetsBefore = spPRIME.totalAssets();
        uint256 supply       = spPRIME.totalSupply();

        // No time has passed, nothing to drip.
        assertEq(chiBefore,    1e27);
        assertEq(supply,       1_000_000e6 - 1);  // Rounding
        assertEq(assetsBefore, 1_000_000e6 - 1);  // Rounding

        assertEq(spPRIME.rho(),          block.timestamp);
        assertEq(spPRIME.assetsOf(user), assetsBefore);

        uint192 expectedChi = uint192(((assetsBefore - loss) * RAY) / supply);

        assertEq(expectedChi, 0.899999999999899999999999899e27);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.TotalAssetsAdjusted(expectedChi, -int256(loss));

        vm.prank(admin);
        spPRIME.adjustTotalAssets(-int256(loss));

        assertEq(spPRIME.chi(),          expectedChi);
        assertEq(spPRIME.rho(),          block.timestamp);
        assertEq(spPRIME.totalAssets(),  900_000e6 - 2);  // Rounding, 100k loss incurred
        assertEq(spPRIME.assetsOf(user), 900_000e6 - 2);  // Rounding, 100k loss incurred

        skip(365 days);

        spPRIME.drip();

        // 5% APY over one year, compounding on the new chi
        assertEq(spPRIME.chi(),          0.944999999999894999964963024e27);
        assertEq(spPRIME.rho(),          block.timestamp);
        assertEq(spPRIME.totalAssets(),  945_000e6 - 2);  // Rounding, 5% yield on 900k
        assertEq(spPRIME.assetsOf(user), 945_000e6 - 2);  // Rounding, 5% yield on 900k

        assertEq(spPRIME.chi(), 1.049999999999999999961070145e27 * expectedChi / RAY);
    }

    function test_adjustTotalAssets_redeemReflectsLoss() external {
        uint256 loss = 100_000e6;

        vm.prank(admin);
        spPRIME.grantRole(REBALANCER_ROLE, rebalancer);

        _requestDeposit(user, 1_000_000e6);
        _pause();

        uint192 chiBefore    = spPRIME.nowChi();
        uint256 assetsBefore = spPRIME.totalAssets();
        uint256 supply       = spPRIME.totalSupply();

        // No time has passed, nothing to drip.
        assertEq(chiBefore,    1e27);
        assertEq(supply,       1_000_000e6 - 1);  // Rounding
        assertEq(assetsBefore, 1_000_000e6 - 1);  // Rounding

        assertEq(spPRIME.rho(),          block.timestamp);
        assertEq(spPRIME.assetsOf(user), assetsBefore);

        uint192 expectedChi = uint192(((assetsBefore - loss) * RAY) / supply);

        assertEq(expectedChi, 0.899999999999899999999999899e27);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.TotalAssetsAdjusted(expectedChi, -int256(loss));

        vm.prank(admin);
        spPRIME.adjustTotalAssets(-int256(loss));

        assertEq(spPRIME.chi(),          expectedChi);
        assertEq(spPRIME.rho(),          block.timestamp);
        assertEq(spPRIME.totalAssets(),  900_000e6 - 2);  // Rounding, 100k loss incurred
        assertEq(spPRIME.assetsOf(user), 900_000e6 - 2);  // Rounding, 100k loss incurred

        vm.prank(admin);
        spPRIME.unpause();

        assertEq(spPRIME.balanceOf(user),       supply);
        assertEq(spPRIME.pendingRedeemShares(), 0);
        assertEq(usdc.balanceOf(user),          0);

        vm.prank(user);
        spPRIME.requestRedeem(supply, user);

        assertEq(spPRIME.balanceOf(user),       0);
        assertEq(spPRIME.pendingRedeemShares(), supply);
        assertEq(usdc.balanceOf(user),          0);

        vm.prank(rebalancer);
        spPRIME.processPendingRedeems(type(uint256).max, 1);

        // User receives the post-loss value of their shares, not the 1M deposited.
        assertEq(spPRIME.balanceOf(user),       0);
        assertEq(spPRIME.pendingRedeemShares(), 0);
        assertEq(spPRIME.totalSupply(),         0);
        assertEq(spPRIME.totalAssets(),         0);
        assertEq(usdc.balanceOf(user),          900_000e6 - 2);  // Rounding, 100k loss incurred
    }

}
