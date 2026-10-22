// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import "./b_flows_user.sol";

// Admin / role / environment flows: capacity (including below totalSupply), max fee and fee,
// minimums, both VSRs, pause/unpause, `adjustTotalAssets` with positive and negative deltas while
// paused (plus probes of its guards), the three queue processors, take/return, spUSDC liquidity
// drains and returns, time.
contract FlowsAdmin is FlowsUser {

    constructor(address vault_) FlowsUser(vault_) {}

    /**********************************************************************************************/
    /*** Parameters                                                                             ***/
    /**********************************************************************************************/

    // `setCapacity` does not bound the value; the handler keeps it <= uint128.max because a
    // larger capacity overflows `convertToAssets(availableCapacity())` and bricks deposits.
    // 2 of 10 calls set it at or below totalSupply (invariant X tracks that).
    function setCapacity(uint256 capacity, uint256 seed) public counted("setCapacity") {
        uint256 supply = vault.totalSupply();
        uint256 kind   = seed % 10;

        if      (kind < 5) capacity = type(uint128).max;                       // wide open
        else if (kind < 8) capacity = _bound(capacity, supply, supply + 1e18); // some headroom
        else               capacity = _bound(capacity, 0, supply);             // at or below supply

        vm.startPrank(admin);
        vault.setCapacity(capacity);
        vm.stopPrank();

        if (capacity < supply) {
            capacityLoweredBelowSupply = true;
            capacityBelowSupplyEvents++;
        }
    }

    // Admin bound on the fee; may land below the live `redeemFeeRate` (C-7, not clamped).
    function setMaxRedeemFeeRate(uint256 maxFee) public counted("setMaxRedeemFeeRate") {
        maxFee = _bound(maxFee, 0, vault.MAX_REDEEM_FEE());

        vm.startPrank(admin);
        vault.setMaxRedeemFeeRate(maxFee);
        vm.stopPrank();
    }

    function setRedeemFeeRate(uint256 fee) public counted("setRedeemFee") {
        fee = _bound(fee, 0, vault.maxRedeemFeeRate());

        vm.startPrank(redeemFeeSetter);
        vault.setRedeemFeeRate(fee);
        vm.stopPrank();
    }

    // Half of the calls clear the minimum so zero-amount requests stay reachable.
    function setMinDeposit(uint256 minDeposit, uint256 seed) public counted("setMinDeposit") {
        minDeposit = seed % 2 == 0 ? 0 : _bound(minDeposit, 1, 10e6);

        vm.startPrank(admin);
        vault.setMinDeposit(minDeposit);
        vm.stopPrank();
    }

    // `minRedeem` is denominated in shares.
    function setMinRedeem(uint256 minRedeem, uint256 seed) public counted("setMinRedeem") {
        minRedeem = seed % 2 == 0 ? 0 : _bound(minRedeem, 1, 10e6);

        vm.startPrank(admin);
        vault.setMinRedeem(minRedeem);
        vm.stopPrank();
    }

    // spPRIME VSR; kept at or below the spUSDC VSR except in ~1 of 8 calls (flagged for H).
    function setPrimeVsr(uint256 vsr_, uint256 seed) public counted("setPrimeVsr") {
        uint256 spVsr = spUsdc.vsr();

        if (seed % 8 == 0) vsr_ = _bound(vsr_, vault.minVSR(), vault.maxVSR());
        else               vsr_ = _bound(vsr_, vault.minVSR(), _min(vault.maxVSR(), spVsr));

        vm.startPrank(operator);
        vault.setVSR(vsr_);
        vm.stopPrank();

        if (vsr_ > spVsr) rateOrderBroken = true;
    }

    // spUSDC VSR; kept at or above the spPRIME VSR except in ~1 of 8 calls (flagged for H).
    function setSpUsdcVsr(uint256 vsr_, uint256 seed) public counted("setSpUsdcVsr") {
        uint256 primeVsr = vault.vsr();

        if (seed % 8 == 0) vsr_ = _bound(vsr_, spUsdc.minVsr(), spUsdc.maxVsr());
        else               vsr_ = _bound(vsr_, _max(spUsdc.minVsr(), primeVsr), spUsdc.maxVsr());

        vm.startPrank(spSetter);
        spUsdc.setVsr(vsr_);
        vm.stopPrank();

        if (vsr_ < primeVsr) rateOrderBroken = true;
    }

    /**********************************************************************************************/
    /*** Pause and total-assets adjustments                                                     ***/
    /**********************************************************************************************/

    // Pauses in ~1 of 4 calls so the vault is not paused half of the time (PAUSER_ROLE).
    function pause(uint256 seed) public counted("pause") {
        if (seed % 4 != 0) return;

        vm.startPrank(pauser);
        vault.pause();
        vm.stopPrank();
    }

    function unpause() public counted("unpause") {
        vm.startPrank(admin);
        vault.unpause();
        vm.stopPrank();
    }

    // `adjustTotalAssets(delta)`: admin only, requires `paused`, drips, then sets
    // `chi = (totalAssets + delta) * RAY / totalSupply`. Deltas are bounded to
    // `1 <= |delta| <= totalAssets / 10`; negative deltas are skipped when the resulting chi would
    // be 0, positive ones when it would pass 1e30 (keeps every conversion far from overflow).
    // The guards are probed: not paused -> `not-paused`; totalSupply == 0 -> panic 0x12.
    // Records the per-call accounting error (invariant T) and moves the deficit ledger (H).
    function adjustTotalAssets(uint256 magnitude, uint256 seed) public counted("adjustTotalAssets") {
        bool negative = seed % 2 == 0;

        // The vault is rarely paused when this flow is drawn, so 3 of 4 unpaused draws pause it
        // first (pauser), adjust, and leave it paused in 1 of 4 of those; the remaining draw
        // probes the `not-paused` guard instead.
        bool pausedHere;
        if (!vault.paused()) {
            if (seed / 2 % 4 == 0) { _probeAdjustNotPaused(); return; }
            vm.startPrank(pauser);
            vault.pause();
            vm.stopPrank();
            pausedHere = seed / 8 % 4 != 0;
        }

        uint256 supply = vault.totalSupply();
        if (supply == 0) { _probeAdjustZeroSupply(); _unpauseIf(pausedHere); return; }

        uint256 assetsBefore = vault.totalAssets();
        if (assetsBefore < 10) { _unpauseIf(pausedHere); return; }

        magnitude = _bound(magnitude, 1, assetsBefore / 10);

        if (negative  && ((assetsBefore - magnitude) * RAY) / supply == 0)   { _unpauseIf(pausedHere); return; }
        if (!negative && ((assetsBefore + magnitude) * RAY) / supply > 1e30) { _unpauseIf(pausedHere); return; }

        uint256 chiBefore = vault.nowChi();

        int256 delta = negative ? -int256(magnitude) : int256(magnitude);

        vm.startPrank(admin);
        vault.adjustTotalAssets(delta);
        vm.stopPrank();

        uint256 assetsAfter = vault.totalAssets();

        if (negative) {
            assertLt(vault.nowChi(), chiBefore,            "handler: negative adjust did not lower chi");
            assertGt(vault.nowChi(), 0,                    "handler: negative adjust zeroed chi");
            assertLe(assetsAfter + magnitude, assetsBefore, "handler: loss under-applied");
            adjustNegatives++;
            adjustedLossUsdc += magnitude;
            ghostDeficitUsdc -= int256(magnitude);
        } else {
            assertGe(vault.nowChi(), chiBefore,            "handler: positive adjust lowered chi");
            assertLe(assetsAfter, assetsBefore + magnitude, "handler: gain over-applied");
            adjustPositives++;
            adjustedGainUsdc += magnitude;
            ghostDeficitUsdc += int256(magnitude);
        }

        _recordGainLossError(assetsBefore, assetsAfter, magnitude, !negative);

        lastChi = vault.nowChi();  // sanctioned chi move (invariant G)

        _unpauseIf(pausedHere);
    }

    function _unpauseIf(bool yes) internal {
        if (!yes) return;
        vm.startPrank(admin);
        vault.unpause();
        vm.stopPrank();
    }

    function _probeAdjustNotPaused() internal {
        adjustNotPausedProbes++;
        vm.startPrank(admin);
        try vault.adjustTotalAssets(1) {
            vm.stopPrank();
            _recordRevert("<no revert: adjustTotalAssets while not paused>", false);
        } catch Error(string memory r) {
            vm.stopPrank();
            _recordRevert(r, _eq(r, abi.encodeWithSelector(ISparkPrimeVault.IsNotPaused.selector)));
        } catch {
            vm.stopPrank();
            _recordRevert("<non-string revert: adjustTotalAssets while not paused>", false);
        }
    }

    // With totalSupply == 0 the contract divides by zero (`:289`, NOTE at `:288`).
    function _probeAdjustZeroSupply() internal {
        adjustZeroSupplyProbes++;
        vm.startPrank(admin);
        try vault.adjustTotalAssets(1) {
            vm.stopPrank();
            _recordRevert("<no revert: adjustTotalAssets at zero supply>", false);
        } catch Error(string memory r) {
            vm.stopPrank();
            _recordRevert(r, false);
        } catch Panic(uint256 code) {
            vm.stopPrank();
            if (_recordRevert("<panic: adjustTotalAssets at zero supply>", code == 0x12)) adjustZeroSupplyPanics++;
        } catch {
            vm.stopPrank();
            _recordRevert("<non-string revert: adjustTotalAssets at zero supply>", false);
        }
    }

    /**********************************************************************************************/
    /*** Queue processing                                                                       ***/
    /**********************************************************************************************/

    function processPendingDeposits(uint256 maxSavingsShares, uint256 maxRequests, uint256 seed)
        public counted("processPendingDeposits")
    {
        if (vault.paused()) return;

        uint256 kind = seed % 4;
        if (kind == 0) maxSavingsShares = type(uint256).max;
        else           maxSavingsShares = _bound(maxSavingsShares, 0, vault.pendingDepositSavingsShares() + 1e12);

        maxRequests = kind == 1 ? type(uint256).max : _bound(maxRequests, 0, 8);

        uint256          head         = vault.firstPendingDepositId();
        uint256[] memory sharesBefore = _snapshotDepositQueue(head);
        uint256[N] memory balsBefore  = _balances();
        uint256          supplyBefore = vault.totalSupply();

        vm.startPrank(operator);
        vault.processPendingDeposits(maxSavingsShares, maxRequests);
        vm.stopPrank();

        _countDepositFills(head, sharesBefore, supplyBefore);
        _attributeMints(balsBefore);
        _capacityCheck(supplyBefore);
    }

    // Pays cancelled deposits by spUSDC `redeem` with a budget of min(max, spUSDC.maxRedeem(vault)),
    // which caps at both the vault's spUSDC balance and spUSDC's USDC liquidity, so the call must
    // never revert. A blacklisted recipient's USDC is redeemed to the vault and credited to
    // `claimableAssets` instead; both are "paid" for invariants I and Y.
    function processPendingDepositCancellations(uint256 maxSavingsShares, uint256 maxRequests, uint256 seed)
        public counted("processPendingDepositCancellations")
    {
        if (vault.paused()) return;

        uint256 kind = seed % 4;
        if (kind == 0) maxSavingsShares = type(uint256).max;
        else           maxSavingsShares = _bound(maxSavingsShares, 0, vault.pendingCancelledDepositSavingsShares() + 1e12);

        maxRequests = kind == 1 ? type(uint256).max : _bound(maxRequests, 0, 8);

        uint256          head            = vault.firstPendingDepositCancellationId();
        uint256[] memory sharesBefore    = _snapshotCancelledQueue(head);
        uint256          usersUsdcBefore = _usersUsdc();
        uint256          vaultUsdcBefore = usdc.balanceOf(address(vault));
        uint256          claimableBefore = _usersClaimable();
        uint256          supplyBefore    = vault.totalSupply();

        vm.startPrank(operator);
        try vault.processPendingDepositCancellations(maxSavingsShares, maxRequests) {
            vm.stopPrank();
            uint256 expected = _countCancelledFills(head, sharesBefore);
            uint256 toUsers  = _usersUsdc() - usersUsdcBefore;
            uint256 toVault  = usdc.balanceOf(address(vault)) - vaultUsdcBefore;
            usersRefundedUsdc     += toUsers + toVault;
            claimableCreditedUsdc += toVault;
            if (toVault != 0) fillsToBlacklisted++;
            assertEq(_usersClaimable() - claimableBefore, toVault, "handler: claimable credit != USDC kept by vault");
            assertEq(vault.totalSupply(), supplyBefore, "handler: refund changed totalSupply");
            _recordPayout(toUsers + toVault, expected, false);
        } catch Error(string memory reason) {
            vm.stopPrank();
            cancelProcessReverts++;
            lastCancelProcessRevert = reason;
            _recordRevert(reason, false);
        } catch {
            vm.stopPrank();
            cancelProcessReverts++;
            lastCancelProcessRevert = "<non-string revert>";
            _recordRevert("<non-string revert: processPendingDepositCancellations>", false);
        }
    }

    function processPendingRedeems(uint256 maxShares, uint256 maxRequests, uint256 seed)
        public counted("processPendingRedeems")
    {
        if (vault.paused()) return;

        uint256 kind = seed % 4;
        if (kind == 0) maxShares = type(uint256).max;
        else           maxShares = _bound(maxShares, 0, vault.pendingRedeemShares() + 1e12);

        maxRequests = kind == 1 ? type(uint256).max : _bound(maxRequests, 0, 8);

        uint256          head            = vault.firstPendingRedeemId();
        uint256[] memory sharesBefore    = _snapshotRedeemQueue(head);
        uint256          usersUsdcBefore = _usersUsdc();
        uint256          vaultUsdcBefore = usdc.balanceOf(address(vault));
        uint256          claimableBefore = _usersClaimable();

        // The call is wrapped: spUSDC's `withdraw` burns ceil(assets*RAY/chi_s) shares per fill,
        // so a multi-entry fill bounded by the vault's spUSDC *balance* (not spUSDC liquidity) can
        // exceed the balance by up to one share per entry and revert (C-1). Observed, not asserted.
        vm.startPrank(operator);
        try vault.processPendingRedeems(maxShares, maxRequests) {
            vm.stopPrank();
            uint256 expected = _countRedeemFills(head, sharesBefore);
            uint256 toUsers  = _usersUsdc() - usersUsdcBefore;
            uint256 toVault  = usdc.balanceOf(address(vault)) - vaultUsdcBefore;
            usersRedeemedUsdc     += toUsers + toVault;
            claimableCreditedUsdc += toVault;
            if (toVault != 0) fillsToBlacklisted++;
            assertEq(_usersClaimable() - claimableBefore, toVault, "handler: claimable credit != USDC kept by vault");
            _recordPayout(toUsers + toVault, expected, true);
        } catch Error(string memory reason) {
            vm.stopPrank();
            lastRedeemProcessRevert = reason;
            if (_recordRevert(reason, _eq(reason, "SparkVault/insufficient-balance"))) {
                redeemProcessReverts++;
            } else {
                redeemProcessRevertsOther++;
            }
        } catch {
            vm.stopPrank();
            lastRedeemProcessRevert = "<non-string revert>";
            redeemProcessRevertsOther++;
            _recordRevert("<non-string revert: processPendingRedeems>", false);
        }
    }

    // Invariant Y bookkeeping: what a processing call paid vs the per-entry floor conversions.
    function _recordPayout(uint256 paid, uint256 expected, bool redeem) internal {
        uint256 excess = paid > expected ? paid - expected : 0;
        if (redeem) {
            if (paid != expected) redeemPayoutMismatches++;
            if (excess > redeemPayoutMaxExcess) redeemPayoutMaxExcess = excess;
        } else {
            if (paid != expected) cancelPayoutMismatches++;
            if (excess > cancelPayoutMaxExcess) cancelPayoutMaxExcess = excess;
        }
    }

    /**********************************************************************************************/
    /*** TAKER_ROLE: spUSDC out of and back into the vault                                      ***/
    /**********************************************************************************************/

    // `take` is not pause-gated and not ring-fenced: it can move the backing of queued deposits
    // and queued cancels out of the vault (F-2). Invariant W only tolerates the gap after this.
    function take(uint256 savingsShares, uint256 seed) public counted("take") {
        uint256 balance = spUsdc.balanceOf(address(vault));
        if (balance == 0) return;

        savingsShares = seed % 4 == 0 ? balance : _bound(savingsShares, 0, balance);
        if (savingsShares == 0) return;

        vm.startPrank(taker);
        vault.take(savingsShares);
        vm.stopPrank();

        takerOutstandingSpUsdc += savingsShares;
        takeCalled = true;
        takes++;
    }

    // Returns taken spUSDC by plain transfer. The taker mints what it does not hold (USDC minted
    // from thin air, tracked as `takerInjectedUsdc`). ~1 in 4 calls returns everything outstanding.
    function returnToVault(uint256 savingsShares, uint256 seed) public counted("returnToVault") {
        if (takerOutstandingSpUsdc == 0) return;

        savingsShares = seed % 4 == 0
            ? takerOutstandingSpUsdc
            : _bound(savingsShares, 0, takerOutstandingSpUsdc);
        if (savingsShares == 0) return;

        uint256 held = spUsdc.balanceOf(taker);

        vm.startPrank(taker);
        if (held < savingsShares) {
            uint256 assets = spUsdc.previewMint(savingsShares - held);
            usdc.mint(taker, assets);
            totalUsdcMinted   += assets;
            takerInjectedUsdc += assets;
            usdc.approve(address(spUsdc), assets);
            spUsdc.mint(savingsShares - held, taker);
        }
        spUsdc.transfer(address(vault), savingsShares);
        vm.stopPrank();

        takerOutstandingSpUsdc -= savingsShares;
        takerReturnedSpUsdc    += savingsShares;
    }

    /**********************************************************************************************/
    /*** spUSDC liquidity                                                                       ***/
    /**********************************************************************************************/

    function drainSpUsdcLiquidity(uint256 amount, uint256 seed) public counted("drainSpUsdcLiquidity") {
        uint256 liquidity = usdc.balanceOf(address(spUsdc));
        if (liquidity == 0) return;

        amount = seed % 4 == 0 ? liquidity : _bound(amount, 0, liquidity);

        vm.startPrank(spTaker);
        spUsdc.take(amount);
        vm.stopPrank();
    }

    // USDC minted straight into spUSDC: the spUSDC taker's capital (plus yield) coming home.
    function returnSpUsdcLiquidity(uint256 amount, uint256 seed) public counted("returnSpUsdcLiquidity") {
        uint256 owed = spUsdc.assetsOutstanding();

        amount = seed % 4 == 0 ? owed : _bound(amount, 0, owed + 1_000e6);
        if (amount == 0) return;

        usdc.mint(address(spUsdc), amount);
        totalUsdcMinted   += amount;
        spUsdcYieldMinted += amount;
    }

    /**********************************************************************************************/
    /*** Time                                                                                   ***/
    /**********************************************************************************************/

    // The only handler that moves time. Scales the deficit ledger (invariant H) by the index the
    // bound follows: spUSDC's while the ledger is positive, spPRIME's while it is negative.
    function warp(uint256 secs) public counted("warp") {
        secs = _bound(secs, 1, 30 days);

        uint256 chiSBefore = spUsdc.nowChi();
        uint256 chiPBefore = vault.nowChi();

        vm.warp(block.timestamp + secs);
        spUsdc.drip();
        vault.drip();

        uint256 chiSAfter = spUsdc.nowChi();
        uint256 chiPAfter = vault.nowChi();

        assertGe(chiPAfter, chiPBefore, "handler: warp lowered chi");

        if (ghostDeficitUsdc > 0) _scaleDeficit(chiSBefore, chiSAfter);
        else                      _scaleDeficit(chiPBefore, chiPAfter);

        lastChi = chiPAfter;  // sanctioned chi increase (invariant G)
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }
    function _max(uint256 a, uint256 b) internal pure returns (uint256) { return a > b ? a : b; }

}
