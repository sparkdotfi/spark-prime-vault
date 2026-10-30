// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { LocalTestBase } from "./LocalTestBase.t.sol";

// Smoke test for the local harness.
contract LocalSmokeTest is LocalTestBase {

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function test_smoke_depositRedeemRoundTrip() public {
        _setSpUsdcVsr(FIVE_PCT_VSR);
        _setPrimeVsr(FOUR_PCT_VSR);

        _deposit(alice, 1_000_000e6);
        assertApproxEqAbs(vault.assetsOf(alice), 1_000_000e6, 2);  // indexes are ugly, not 1:1
        assertApproxEqAbs(spUsdc.convertToAssets(_vaultSpUsdc()), 1_000_000e6, 1);

        _warpAndDrip(365 days);
        assertGt(vault.assetsOf(alice), 1_039_000e6);

        _setRedeemFeeRate(0.001e18);
        uint256 id = _requestRedeem(alice, vault.balanceOf(alice));
        (, , uint256 queued) = _redeemRequest(id);
        assertGt(queued, 0);

        // spUSDC has no liquidity: nothing can be paid.
        _drainAllSpUsdcLiquidity();
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 0);

        // Liquidity returns, redeem fills.
        _returnSpUsdcLiquidity(2_000_000e6);
        _processRedeems(type(uint256).max, 10);
        assertGt(usdc.balanceOf(alice), 1_038_000e6);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    function test_smoke_takeAndReturn() public {
        _deposit(alice, 100e6);
        uint256 bal = _vaultSpUsdc();
        _takeAll();
        assertEq(_vaultSpUsdc(), 0);
        _returnToVault(bal);
        assertEq(_vaultSpUsdc(), bal);
    }
}
