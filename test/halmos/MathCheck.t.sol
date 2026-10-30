// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { HalmosTestBase } from "./HalmosTestBase.t.sol";

// Run with --solver cvc5-int (and HALMOS_ALLOW_DOWNLOAD=1 once): bitvector solvers
// time out on the mulDiv chains.
contract MathCheck is HalmosTestBase {

    function check_conversionRoundTrip() external frozenTime {
        _symbolicRates();

        uint256 assets_ = svm.createUint(64, "assets");
        uint256 shares_ = svm.createUint(64, "shares");

        assertLe(vault.convertToAssets(vault.convertToShares(assets_)), assets_);
        assertLe(vault.convertToShares(vault.convertToAssets(shares_)), shares_);
    }

    function check_conversionAdditivity() external frozenTime {
        _symbolicRates();

        uint256 assets1 = svm.createUint(64, "assets1");
        uint256 assets2 = svm.createUint(64, "assets2");

        uint256 split    = vault.convertToShares(assets1) + vault.convertToShares(assets2);
        uint256 together = vault.convertToShares(assets1 + assets2);

        assertLe(split,    together);
        assertLe(together, split + 1);
    }

    function check_redeemFee() external frozenTime {
        uint256 feeRate = _gridFeeRate(svm.createUint(8, "feeIdx"));
        _setRedeemFeeRate(feeRate);
        _deposit(userA, 1_000_000e6);

        uint256 shares_ = svm.createUint(64, "shares");

        uint256 supplyBefore  = vault.totalSupply();
        uint256 pendingBefore = vault.pendingRedeemShares();

        vm.prank(userA);
        vault.requestRedeem(shares_, userA);

        uint256 fee    = supplyBefore - vault.totalSupply();
        uint256 queued = vault.pendingRedeemShares() - pendingBefore;

        assertEq(fee + queued, shares_);
        assertGe(fee * WAD, shares_ * feeRate);
        assertLe(fee * WAD, shares_ * feeRate + WAD - 1);
    }

    function check_adjustTotalAssetsPrecision() external frozenTime {
        _deposit(userA, 1_000_000e6);
        _symbolicRates();
        _pause();

        int256 delta = svm.createInt(64, "delta");

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 supply            = vault.totalSupply();

        vm.prank(lossManager);
        vault.adjustTotalAssets(delta);

        uint256 expected = uint256(int256(totalAssetsBefore) + delta);

        assertLe(vault.totalAssets(), expected);
        assertLe(expected - vault.totalAssets(), supply / RAY + 1);
        assertGt(vault.chi(), 0);
    }

    // Expected counterexample: any capacity above maxUint256 / chi overflows in
    // availableCapacity() * chi and bricks processing.
    function check_processPendingDepositsLiveness(uint256 capacity) external frozenTime {
        _deposit(userA, 1_000_000e6);
        _setCapacity(vault.totalSupply());
        _deposit(userB, 1_000_000e6);

        _setCapacity(capacity);

        vm.prank(operator);
        ( bool success, ) = address(vault).call(
            abi.encodeCall(vault.processPendingDeposits, (type(uint256).max, type(uint256).max))
        );

        assertTrue(success);
    }

}
