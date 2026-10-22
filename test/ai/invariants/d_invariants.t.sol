// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import "./c_flows_admin.sol";

import { LocalTestBase } from "../LocalTestBase.t.sol";

// Invariant campaign (round 5, `master` @ 0ebb452) for `SparkPrimeVault` over the local harness
// (real spUSDC code, 6-decimal mock USDC with a Circle-style blacklist). Run with:
//   FOUNDRY_OFFLINE=true FOUNDRY_INVARIANT_RUNS=200 FOUNDRY_INVARIANT_DEPTH=500 \
//     forge test --match-path 'test/ai/invariants/d_invariants.t.sol' -vv
// Default config below: 100 runs x depth 500. Invariant functions may mutate state (G drips, Z
// settles everything): forge evaluates them on a non-committing call, so the sequence never sees
// those changes.
contract SparkPrimeVaultInvariantTest is LocalTestBase {

    FlowsAdmin handler;

    function setUp() public override {
        super.setUp();

        handler = new FlowsAdmin(address(vault));

        targetContract(address(handler));
    }

    function _holders() internal view returns (uint256 n) { return handler.N(); }

    /**********************************************************************************************/
    /*** Shares                                                                                 ***/
    /**********************************************************************************************/

    // A. Share balances of every holder (users + fresh recipients + vault escrow) sum to totalSupply.
    function invariant_A_sumOfBalancesEqualsTotalSupply() public view {
        uint256 sum = vault.balanceOf(address(vault));
        for (uint256 i = 0; i < _holders(); i++) sum += vault.balanceOf(handler.users(i));
        assertEq(sum, vault.totalSupply(), "A: sum of balances != totalSupply");
    }

    // B. The vault's own balance is exactly the escrowed redeem shares (transfers to the vault are
    //    rejected by the contract; the handler never donates).
    function invariant_B_vaultBalanceEqualsPendingRedeemShares() public view {
        if (handler.vaultDonations()) return;
        assertEq(vault.balanceOf(address(vault)), vault.pendingRedeemShares(), "B: escrow mismatch");
    }

    // J. Each holder's balance equals minted + transfers in - transfers out - escrowed. Mints are
    //    attributed to whoever held the entry's `recipient` at fill time (the owner can repoint
    //    it). Escrowed shares never come back (no redeem cancel).
    function invariant_J_balanceProvenance() public view {
        for (uint256 i = 0; i < _holders(); i++) {
            address user = handler.users(i);
            uint256 expected =
                handler.ghostMinted(user)
                + handler.ghostTransferIn(user)
                - handler.ghostTransferOut(user)
                - handler.ghostEscrowed(user);
            assertEq(vault.balanceOf(user), expected, "J: balance provenance mismatch");
        }
    }

    // U. The redeem escrow (balanceOf(vault)) only leaves through fills: across every handler
    //    call other than processPendingRedeems the vault's own balance never decreased.
    function invariant_U_redeemEscrowOnlyLeavesThroughFills() public view {
        assertFalse(
            handler.escrowFellOutsideRedeemFill(),
            string.concat("U: vault share balance fell in ", handler.escrowFellIn())
        );
    }

    /**********************************************************************************************/
    /*** Queues                                                                                 ***/
    /**********************************************************************************************/

    // C. pendingDepositSavingsShares is the sum of every open deposit entry.
    function invariant_C_pendingDepositEqualsSumOfOpenDepositEntries() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.depositQueueLength(); i++) {
            (, , uint256 shares) = _depositRequest(i);
            sum += shares;
        }
        assertEq(sum, vault.pendingDepositSavingsShares(), "C: pending deposit mismatch");
    }

    // D. pendingRedeemShares is the sum of every open redeem entry.
    function invariant_D_pendingRedeemEqualsSumOfOpenRedeemEntries() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.redeemQueueLength(); i++) {
            (, , uint256 shares) = _redeemRequest(i);
            sum += shares;
        }
        assertEq(sum, vault.pendingRedeemShares(), "D: pending redeem mismatch");
    }

    // Q. pendingCancelledDepositSavingsShares is the sum of every open cancelled-deposit entry.
    function invariant_Q_pendingCancelledEqualsSumOfOpenCancelledEntries() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.cancelledQueueLength(); i++) {
            (, , uint256 shares) = _cancelledDepositRequest(i);
            sum += shares;
        }
        assertEq(sum, vault.pendingCancelledDepositSavingsShares(), "Q: pending cancelled mismatch");
    }

    // E. Every entry strictly before a head is closed (filled or cancelled); heads never pass the
    //    queue length; the handler's lengths match the contract's. Covers all three queues.
    function invariant_E_headBookkeeping() public view {
        uint256 depositHead   = vault.firstPendingDepositId();
        uint256 cancelledHead = vault.firstPendingDepositCancellationId();
        uint256 redeemHead    = vault.firstPendingRedeemId();

        assertEq(_depositQueueLength(),          handler.depositQueueLength(),   "E: deposit length");
        assertEq(_cancelledDepositQueueLength(), handler.cancelledQueueLength(), "E: cancelled length");
        assertEq(_redeemQueueLength(),           handler.redeemQueueLength(),    "E: redeem length");

        assertLe(depositHead,   handler.depositQueueLength(),   "E: depositHead past length");
        assertLe(cancelledHead, handler.cancelledQueueLength(), "E: cancelledDepositHead past length");
        assertLe(redeemHead,    handler.redeemQueueLength(),    "E: redeemHead past length");

        for (uint256 i = 0; i < depositHead; i++) {
            (, , uint256 shares) = _depositRequest(i);
            assertEq(shares, 0, "E: open deposit entry before depositHead");
        }
        for (uint256 i = 0; i < cancelledHead; i++) {
            (, , uint256 shares) = _cancelledDepositRequest(i);
            assertEq(shares, 0, "E: open cancelled entry before cancelledDepositHead");
        }
        for (uint256 i = 0; i < redeemHead; i++) {
            (, , uint256 shares) = _redeemRequest(i);
            assertEq(shares, 0, "E: open redeem entry before redeemHead");
        }
    }

    // V. No head ever moved backwards across any handler call.
    function invariant_V_headsNeverMoveBackwards() public view {
        assertFalse(
            handler.headMovedBackwards(),
            string.concat("V: a queue head moved backwards in ", handler.headMovedBackwardsIn())
        );
    }

    /**********************************************************************************************/
    /*** Capacity and index                                                                     ***/
    /**********************************************************************************************/

    // F. No mint ever pushed totalSupply above maxCapacity as it stood at the time of the mint.
    function invariant_F_totalSupplyNeverExceedsCapacityViaMint() public view {
        assertFalse(handler.mintedAboveCapacity(), "F: mint exceeded capacity");
    }

    // X. totalSupply <= maxCapacity unless the admin lowered the capacity below the supply.
    function invariant_X_totalSupplyWithinCapacityUnlessLowered() public view {
        if (handler.capacityLoweredBelowSupply()) return;
        assertLe(vault.totalSupply(), vault.maxCapacity(), "X: totalSupply above maxCapacity");
    }

    // G. chi only moves in the sanctioned places (down in a negative adjustTotalAssets, up in warp
    //    and a positive adjustTotalAssets; the handler flags any other change), is never zero,
    //    and drip() lands exactly on nowChi().
    function invariant_G_chiMonotonicAndDripConsistent() public {
        assertFalse(handler.chiDecreasedOutsideLoss(),  "G: chi decreased outside adjustTotalAssets(<0)");
        assertFalse(handler.chiRoseOutsideWarpOrGain(), "G: chi rose outside warp / adjustTotalAssets(>0)");

        uint256 nowChi_ = vault.nowChi();
        assertEq(nowChi_, handler.lastChi(), "G: chi moved since the last handler call");
        assertGe(nowChi_, vault.chi(),       "G: nowChi below stored chi");
        assertGt(nowChi_, 0,                 "G: chi is zero");

        uint256 dripped = vault.drip();
        assertEq(dripped,     nowChi_, "G: drip != nowChi");
        assertEq(vault.chi(), nowChi_, "G: stored chi != nowChi after drip");
        assertEq(vault.rho(), block.timestamp, "G: rho not updated");
    }

    // L. availableCapacity() == max(0, maxCapacity - totalSupply).
    function invariant_L_availableCapacityFormula() public view {
        uint256 cap    = vault.maxCapacity();
        uint256 supply = vault.totalSupply();
        uint256 expected = cap > supply ? cap - supply : 0;
        assertEq(vault.availableCapacity(), expected, "L: availableCapacity formula");
    }

    /**********************************************************************************************/
    /*** Value                                                                                  ***/
    /**********************************************************************************************/

    // H. Solvency: while spUSDC's VSR has never been below spPRIME's and the taker holds nothing,
    //    the spUSDC value held by the vault net of what is owed to queued depositors and to
    //    queued cancels covers the notional totalAssets() minus the deficit the fictitious
    //    adjustTotalAssets calls created, up to a rounding epsilon. USDC parked in the vault for
    //    blacklisted recipients is owed (claimable), not backing, and is not counted.
    //
    //    Deficit ledger (handler `ghostDeficitUsdc`, an upper bound on totalAssets() - backing):
    //    +delta on a positive adjust, -|delta| on a negative one (both move totalAssets() by
    //    exactly the amount, see T, and no backing moves). Between events, with N = notional,
    //    B = backing, D = N - B, r_s >= r_p: if D > 0 then D grows at most at r_s (N grows at
    //    r_p <= r_s and -B grows at most at r_s whatever B's sign), if D < 0 then B > N >= 0 and
    //    D grows at most at r_p. The warp handler scales the ledger by the matching index,
    //    rounding towards the bound. Every other action moves N and B together up to the
    //    rounding below.
    //
    //    Epsilon: deposit fills round in the vault's favour (double floor) and totalAssets() is a
    //    single floor, so the deposit side contributes at most 1 wei in total. Each redeem fill
    //    withdraws `assets` from spUSDC by burning ceil(assets*RAY/chi_s) spUSDC shares, up to one
    //    share more than the exact amount; that share is worth ceil(chi_s/RAY) USDC wei today.
    //    Cancelled-deposit refunds use spUSDC `redeem` (exact share burn, floor payout) and add
    //    nothing. Index drift between the two `_rpow` chains is below 1e-20 relative and is
    //    absorbed by +2.
    function invariant_H_solvencyWhenSpUsdcRateGePrimeRate() public view {
        if (handler.rateOrderBroken())              return;
        if (handler.takerOutstandingSpUsdc() != 0)  return;

        uint256 held      = spUsdc.balanceOf(address(vault));
        uint256 pending   = vault.pendingDepositSavingsShares();
        uint256 cancelled = vault.pendingCancelledDepositSavingsShares();

        int256 backing =
            int256(spUsdc.convertToAssets(held))
            - int256(spUsdc.convertToAssets(pending))
            - int256(spUsdc.convertToAssets(cancelled));

        uint256 chiS    = spUsdc.nowChi();
        uint256 epsilon = handler.redeemFills() * ((chiS + RAY - 1) / RAY) + 2;

        int256 notional = int256(vault.totalAssets()) - handler.ghostDeficitUsdc();

        assertGe(backing + int256(epsilon), notional, "H: notional exceeds real backing + deficit ledger");
    }

    // I. Users never extract more USDC than they deposited plus the USDC that entered spUSDC as
    //    yield or as taker top-ups (no value is created inside the vault). Every USDC a holder
    //    holds or can claim was paid either by a redeem fill or by a cancelled-deposit refund.
    function invariant_I_usersNeverExtractMoreThanDepositsPlusYield() public view {
        uint256 received;
        uint256 claimable;
        for (uint256 i = 0; i < _holders(); i++) {
            received  += usdc.balanceOf(handler.users(i));
            claimable += vault.claimableAssets(handler.users(i));
        }

        uint256 sources =
            handler.usersDepositedUsdc() + handler.spUsdcYieldMinted() + handler.takerInjectedUsdc();

        assertLe(received + claimable, sources, "I: users extracted more than every USDC source");
        assertEq(
            received + claimable,
            handler.usersRedeemedUsdc() + handler.usersRefundedUsdc(),
            "I: holder USDC + claimable not explained by redeem fills and cancel refunds"
        );
        assertEq(
            handler.claimableCreditedUsdc() - handler.usersClaimedUsdc(),
            claimable,
            "I: claimable ledger (credited - claimed) != sum of claimableAssets"
        );
    }

    // K. USDC conservation: every USDC wei ever minted sits in spUSDC, with the spUSDC taker, with
    //    holders (redeem payouts, cancelled-deposit refunds, claims), with the vault, or with the
    //    spPRIME taker. The USDC held by the vault is EXACTLY the sum of claimableAssets.
    function invariant_K_backingExistsSomewhereAndVaultUsdcIsClaimable() public view {
        uint256 sum =
            usdc.balanceOf(address(spUsdc))
            + usdc.balanceOf(handler.spTaker())
            + usdc.balanceOf(address(vault))
            + usdc.balanceOf(handler.taker());
        uint256 claimable;
        for (uint256 i = 0; i < _holders(); i++) {
            sum       += usdc.balanceOf(handler.users(i));
            claimable += vault.claimableAssets(handler.users(i));
        }

        assertEq(sum, handler.totalUsdcMinted(), "K: USDC not conserved");
        assertEq(usdc.balanceOf(address(vault)), claimable, "K: vault USDC != sum of claimableAssets");
    }

    // N. spUSDC share conservation: the vault plus the spPRIME taker hold every spUSDC share.
    function invariant_N_spUsdcSharesHeldByVaultAndTaker() public view {
        uint256 sum = spUsdc.balanceOf(address(vault)) + spUsdc.balanceOf(handler.taker());
        assertEq(sum, spUsdc.totalSupply(), "N: spUSDC shares leaked");
        assertEq(spUsdc.balanceOf(handler.taker()), handler.takerOutstandingSpUsdc(), "N: taker ledger");
    }

    // W. The vault's spUSDC covers the two spUSDC-denominated queues (pending deposits + pending
    //    cancels) unless `take()` (F-2) or `processPendingRedeems` (R5-1: its budget is the whole
    //    spUSDC balance, queue backing included) opened the gap; no other flow ever does. The
    //    handler keeps the largest gap seen and which flow opened each one for the report.
    function invariant_W_spUsdcCoversQueuesUnlessTakenOrRedeemed() public view {
        assertFalse(
            handler.gapOpenedElsewhere(),
            string.concat("W: a backing gap was opened by ", handler.gapOpenedIn())
        );
        if (handler.takeCalled() || handler.gapOpenedByRedeems() != 0) return;
        uint256 owed = vault.pendingDepositSavingsShares() + vault.pendingCancelledDepositSavingsShares();
        assertGe(spUsdc.balanceOf(address(vault)), owed, "W: vault spUSDC below queued spUSDC without take() / redeem fill");
        assertEq(handler.maxBackingGapSpUsdc(), 0, "W: backing gap recorded without take() / redeem fill");
    }

    // M. Zero-share fills (F-4) are counted, not asserted; see afterInvariant().
    function invariant_M_noMintOfZeroSharesExceptDust() public view {
        handler.zeroShareFills();
    }

    // O. processPendingRedeems only ever reverted with spUSDC's insufficient-balance (ceil burn).
    function invariant_O_processPendingRedeemsRevertsOnlyOnCeilBurn() public view {
        assertEq(handler.redeemProcessRevertsOther(), 0, "O: unexpected processPendingRedeems revert");
    }

    // P. processPendingDepositCancellations never reverts: its budget is spUSDC.maxRedeem(vault),
    //    which caps at both the vault's spUSDC balance and spUSDC's USDC liquidity.
    function invariant_P_processPendingDepositCancellationsNeverReverts() public view {
        assertEq(
            handler.cancelProcessReverts(), 0,
            string.concat("P: processPendingDepositCancellations reverted: ", handler.lastCancelProcessRevert())
        );
    }

    // Y. Payout exactness: every processing call paid (to recipients directly plus into
    //    claimableAssets) exactly the sum over touched entries of the floor conversion of the
    //    shares consumed: `convertToAssets` for redeems, `spUSDC.convertToAssets` for refunds.
    //    Nobody ever received more than that (the task's "+1 wei per fill" bound holds with 0).
    function invariant_Y_payoutsExactlyConvertedShares() public view {
        assertEq(handler.redeemPayoutMaxExcess(), 0, "Y: a redeem fill paid more than convertToAssets(burned)");
        assertEq(handler.cancelPayoutMaxExcess(), 0, "Y: a refund paid more than spUSDC.convertToAssets(burned)");
        assertEq(handler.redeemPayoutMismatches(), 0, "Y: redeem payout != exact conversion");
        assertEq(handler.cancelPayoutMismatches(), 0, "Y: refund payout != exact conversion");
    }

    // R. Recipient updates move nothing: totals, pendings, heads, every balance (shares, USDC,
    //    claimable) and every entry's owner/shares are byte-identical before and after; only
    //    future fills are redirected.
    function invariant_R_recipientUpdatesNeverChangeTotals() public view {
        assertFalse(handler.recipientUpdateChangedState(), "R: recipient update moved state");
    }

    // S. Every recipient update attempted by someone who is not the entry's owner reverted (with
    //    `not-authorized`, or `recipient-cannot-receive` when the blacklist guard runs first).
    function invariant_S_recipientUpdateByNonOwnerAlwaysReverts() public view {
        assertEq(
            handler.recipientUpdateStrangerReverts(),
            handler.recipientUpdateStrangerAttempts(),
            string.concat("S: non-owner recipient update did not revert as expected: ", handler.lastStrangerUpdateRevert())
        );
    }

    // T. adjustTotalAssets moves totalAssets() by exactly the delta, within 1 wei (the new chi is
    //    a single floor; totalSupply * frac(chi) / RAY < 1 wei at any sane supply).
    function invariant_T_adjustTotalAssetsAccounting() public view {
        assertEq(handler.gainLossOutOfBound(), 0, "T: adjustTotalAssets moved totalAssets by more than delta +/- 1");
        assertLe(handler.maxGainLossError(),   1, "T: adjustTotalAssets accounting error above 1 wei");
        assertEq(handler.adjustZeroSupplyProbes(), handler.adjustZeroSupplyPanics(), "T: zero-supply adjust did not panic 0x12");
    }

    /**********************************************************************************************/
    /*** Blacklist, claim, reverts                                                              ***/
    /**********************************************************************************************/

    // AA. `claim` never paid a blacklisted recipient and never moved state while reverting; every
    //     request / update naming a blacklisted recipient reverted `recipient-cannot-receive`;
    //     every claim of nothing reverted `nothing-to-claim`.
    function invariant_AA_claimNeverPaysWhileBlacklisted() public view {
        assertFalse(handler.claimPaidWhileBlacklisted(),         "AA: claim paid a blacklisted recipient");
        assertFalse(handler.claimChangedStateWhileBlacklisted(), "AA: claim moved state while blacklisted");
        assertEq(handler.claimWhileBlacklistedReverts(), handler.claimWhileBlacklistedAttempts(), "AA: claim while blacklisted did not revert in USDC");
        assertEq(handler.claimNothingProbeReverts(),     handler.claimNothingProbes(),            "AA: claim of nothing did not revert nothing-to-claim");
        assertEq(
            handler.blacklistRecipientProbeReverts(), handler.blacklistRecipientProbes(),
            string.concat("AA: blacklisted recipient accepted: ", handler.lastBlacklistProbeRevert())
        );
    }

    // AB. No handler call hit a revert outside its allow-list (every caught revert is classified
    //     by reason in the handler; the uncaught ones fail the run through fail_on_revert).
    function invariant_AB_noUnexpectedReverts() public view {
        assertEq(
            handler.unexpectedReverts(), 0,
            string.concat("AB: unexpected revert: ", handler.lastUnexpectedRevert())
        );
    }

    /**********************************************************************************************/
    /*** Terminal: settle everything                                                            ***/
    /**********************************************************************************************/

    // Z. From any reachable state: unpause, un-blacklist every holder, bring every taken spUSDC
    //    share back, make spUSDC fully liquid, open the capacity, drain the three queues, then
    //    claim for every holder. Afterwards no claimable is left, the vault holds zero USDC and
    //    the deposit queue is empty. While the rate order held, what the cancellation and redeem
    //    queues are still owed is at most the deficit ledger (fictitious gains, invariant H) plus
    //    the C-1 strand bound; with no fictitious gain both queues are empty up to that bound.
    //    (R5-1: redeem fills spend the cancellation-queue backing, so the unpaid part can sit in
    //    either queue.) Runs on a non-committing call after every handler call, so it never
    //    leaks into the run.
    function invariant_Z_settleEverythingPaysEveryClaimable() public {
        uint256 n = _holders();

        if (vault.paused()) _unpause();

        for (uint256 i = 0; i < n; i++) _unblacklist(handler.users(i));

        uint256 out = spUsdc.balanceOf(handler.taker());
        if (out != 0) {
            vm.prank(handler.taker());
            spUsdc.transfer(address(vault), out);
        }

        _returnSpUsdcLiquidity(spUsdc.assetsOutstanding() + 1_000_000e6);
        _setCapacity(type(uint128).max);

        // Deposits: one full walk; ghosts are skipped because remaining_ != 0 with open capacity.
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.pendingDepositSavingsShares(), 0,                              "Z: deposit queue not drained");
        assertEq(vault.firstPendingDepositId(),       handler.depositQueueLength(),   "Z: deposit head not at end");

        // Cancellations: budget is maxRedeem(vault) == vault balance once spUSDC is liquid.
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        // Redeems: one batched walk, falling back to one entry per call if the C-1 ceil-burn
        // revert fires, until the head stops moving.
        uint256 localFills = _drainRedeems();

        // Claims: every claimable is payable now that nobody is blacklisted.
        for (uint256 i = 0; i < n; i++) {
            address who = handler.users(i);
            uint256 amt = vault.claimableAssets(who);
            if (amt == 0) continue;
            uint256 before = usdc.balanceOf(who);
            uint256 paid   = vault.claim(who);
            assertEq(paid, amt,                            "Z: claim paid wrong amount");
            assertEq(usdc.balanceOf(who), before + amt,    "Z: claim did not land");
            assertEq(vault.claimableAssets(who), 0,        "Z: claimable left after claim");
        }
        assertEq(usdc.balanceOf(address(vault)), 0, "Z: vault still holds USDC after settling");

        // Unpaid remainder (USDC): cancellation shares at spUSDC's index plus redeem shares at the
        // vault's index. Bounded by the deficit ledger plus the ceil-burn strand of every fill.
        if (handler.rateOrderBroken()) return;
        uint256 unpaid =
            spUsdc.convertToAssets(vault.pendingCancelledDepositSavingsShares())
            + vault.convertToAssets(vault.pendingRedeemShares());
        uint256 chiS    = spUsdc.nowChi();
        uint256 epsilon = (handler.redeemFills() + localFills) * ((chiS + RAY - 1) / RAY) + 2;
        int256  deficit = handler.ghostDeficitUsdc();
        if (deficit <= 0) {
            assertEq(vault.pendingCancelledDepositSavingsShares(), 0,                            "Z: cancellation queue not drained without a fictitious gain");
            assertEq(vault.firstPendingDepositCancellationId(),    handler.cancelledQueueLength(), "Z: cancellation head not at end");
            assertLe(unpaid, epsilon, "Z: redeem queue not payable after settling");
        } else {
            assertLe(unpaid, uint256(deficit) + epsilon, "Z: unpaid remainder exceeds the deficit ledger");
        }
    }

    function _drainRedeems() internal returns (uint256 fills) {
        uint256 length = handler.redeemQueueLength();
        vm.prank(operator);
        try vault.processPendingRedeems(type(uint256).max, type(uint256).max) {
            fills = 1;
        } catch Error(string memory r) {
            assertEq(r, "SparkVault/insufficient-balance", "Z: unexpected batched redeem revert");
        }
        uint256 head = vault.firstPendingRedeemId();
        for (uint256 guard = 0; guard <= length && head < length; guard++) {
            uint256 pendingBefore = vault.pendingRedeemShares();
            _processRedeems(type(uint256).max, 1);
            uint256 newHead = vault.firstPendingRedeemId();
            if (vault.pendingRedeemShares() != pendingBefore) fills++;
            if (newHead == head && vault.pendingRedeemShares() == pendingBefore) break;
            head = newHead;
        }
    }

    /**********************************************************************************************/
    /*** Bug reproductions and pins                                                             ***/
    /**********************************************************************************************/

    // C-1 (round 1, still present at 0ebb452). `_processPendingRedeems` (`:903`) bounds
    // `remaining_` by `convertToShares(maxWithdraw(vault))` but pays each entry with spUSDC
    // `withdraw(assets_)` (`:952`), which burns ceil(assets_*RAY/chi_s) shares. When the vault's
    // spUSDC *balance* (not spUSDC liquidity) is the binding limit, the per-entry ceilings add up
    // past the balance and the call reverts inside spUSDC.
    //
    // Concrete numbers (harness: chi_s = 1.0476e27, chi_p = 1.0097e27): vault holds 100 spUSDC,
    // maxWithdraw = 104 USDC-wei, remaining_ = 103 spPRIME shares; 110 one-share entries each pay
    // 1 USDC-wei and burn 1 spUSDC share, so the 101st fill reverts. The same call with
    // `maxRequests_ = 1` succeeds 99 times and then does nothing (1 share is left stranded).
    //
    // This test PASSES by asserting the revert; it is a proof, not a regression.
    function test_BUG_processPendingRedeemsRevertsOnCeilBurnWhenBalanceBinds() public {
        address alice = makeAddr("alice");

        _deposit(alice, 100e6);
        for (uint256 i; i < 110; i++) _requestRedeem(alice, 1);

        _take(_vaultSpUsdc() - 100);

        assertEq(_vaultSpUsdc(), 100);
        assertEq(spUsdc.maxWithdraw(address(vault)), 104);
        assertEq(vault.convertToShares(spUsdc.maxWithdraw(address(vault))), 103);

        vm.prank(operator);
        vm.expectRevert("SparkVault/insufficient-balance");
        vault.processPendingRedeems(type(uint256).max, 110);

        // Workaround: one entry per call never reverts, but strands the last share.
        for (uint256 i; i < 110; i++) _processRedeems(type(uint256).max, 1);

        assertEq(vault.firstPendingRedeemId(), 99);
        assertEq(usdc.balanceOf(alice),        99);
        assertEq(_vaultSpUsdc(),               1);
        assertEq(vault.pendingRedeemShares(),  11);
    }

    // R5-1 (round 5, new). `_processPendingRedeems` (`:900`) budgets `remaining_` by
    // `convertToShares(availableLiquidAssets())` (`:903`), i.e. `spUSDC.maxWithdraw(vault)`
    // (`:789`): the vault's WHOLE spUSDC balance, including the shares that back queued deposits
    // (`pendingDepositSavingsShares`) and queued cancellations
    // (`pendingCancelledDepositSavingsShares`). Nothing is ring-fenced, so whenever the notional
    // `totalAssets()` exceeds the real backing (a positive `adjustTotalAssets`, spPRIME VSR above
    // the spUSDC VSR, or capital out with `take`), redeemers are paid with the cancellers' and
    // depositors' spUSDC and the cancellation queue can no longer be paid in full.
    //
    // Concrete numbers (harness indexes): alice deposits 1,000 USDC (instant fill, 990,405,183
    // shares backed by 954,532,691 spUSDC worth 999,999,999 USDC). The admin pauses and calls
    // `adjustTotalAssets(+100e6)` (totalAssets 1,099,999,997; no USDC arrives). alice queues a
    // redeem of all her shares. Capacity is set to totalSupply, so bob's 500 USDC deposit queues
    // (477,266,345 spUSDC); bob cancels it. `processPendingRedeems`: budget = 1,350,552,523
    // shares (maxWithdraw 1,499,999,999 USDC, the whole balance), alice is paid 1,099,999,997
    // USDC and the vault keeps 381,813,078 spUSDC against 477,266,345 owed to bob.
    // `processPendingDepositCancellations` pays bob 400,000,001 USDC and stops with 95,453,267
    // spUSDC still pending at the head: bob is short 99,999,997 USDC and the vault holds 0 spUSDC.
    // The fictitious 100 USDC gain was paid to alice out of bob's refund.
    //
    // This test PASSES by asserting the shortfall; it is a proof, not a regression.
    function test_BUG_processPendingRedeemsSpendsCancellationQueueBacking() public {
        address alice = makeAddr("alice");
        address bob   = makeAddr("bob");

        _deposit(alice, 1_000e6);
        assertEq(vault.balanceOf(alice), 990_405_183);
        assertEq(_vaultSpUsdc(),         954_532_691);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 999_999_999);

        _adjustTotalAssetsWhilePaused(int256(100e6));
        assertEq(vault.totalAssets(), 1_099_999_997);

        _requestRedeem(alice, vault.balanceOf(alice));

        _setCapacity(vault.totalSupply());
        uint256 id = _deposit(bob, 500e6);
        assertEq(vault.pendingDepositSavingsShares(), 477_266_345);
        vm.prank(bob);
        vault.requestDepositCancellation(id, bob);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 477_266_345);
        assertEq(_vaultSpUsdc(), 1_431_799_036);

        // The redeem budget is the whole balance, bob's backing included.
        assertEq(spUsdc.maxWithdraw(address(vault)), 1_499_999_999);
        assertEq(vault.convertToShares(spUsdc.maxWithdraw(address(vault))), 1_350_552_523);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),       1_099_999_997);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(_vaultSpUsdc(),              381_813_078);
        assertLt(_vaultSpUsdc(), vault.pendingCancelledDepositSavingsShares());

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),                          400_000_001);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 95_453_267);
        assertEq(vault.firstPendingDepositCancellationId(),    0);
        assertEq(_vaultSpUsdc(),                               0);
        assertEq(spUsdc.convertToAssets(vault.pendingCancelledDepositSavingsShares()), 99_999_997);
    }

    // N-2 (round 2) stays fixed: `_processPendingDepositCancellations` sizes `remaining_` by
    // `spUSDC.maxRedeem(vault)` (`:870`), which caps at spUSDC's USDC liquidity, so with 150 USDC
    // of liquidity and two 100 USDC refunds queued the batch pays alice in full, bob partially,
    // and stops; the rest is paid once liquidity is back. The second call with no liquidity left
    // is a no-op instead of a revert.
    function test_processPendingDepositCancellationsPaysUpToSpUsdcLiquidity() public {
        address alice = makeAddr("alice");
        address bob   = makeAddr("bob");

        _setCapacity(0);  // everything queues
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);

        vm.prank(alice);
        vault.requestDepositCancellation(idA, alice);
        vm.prank(bob);
        vault.requestDepositCancellation(idB, bob);

        uint256 queued = vault.pendingCancelledDepositSavingsShares();
        assertEq(queued, _vaultSpUsdc());

        // Leave 150 USDC of liquidity in spUSDC: enough for alice's refund, not for both.
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 150e6);

        uint256 budget = spUsdc.maxRedeem(address(vault));
        assertLt(budget, queued);

        _processCancelledDeposits(type(uint256).max, 2);

        assertEq(usdc.balanceOf(alice), 100e6 - 1);  // 1-wei deposit/redeem floor round trip
        assertEq(usdc.balanceOf(bob),   49_999_999);
        assertEq(usdc.balanceOf(address(spUsdc)), 150e6 - (100e6 - 1) - 49_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 1);  // bob's partial entry stays at the head
        assertEq(vault.pendingCancelledDepositSavingsShares(), queued - budget);

        // Nothing left in spUSDC: the call is a no-op, no revert.
        _drainAllSpUsdcLiquidity();
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob), 49_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 1);

        // Once liquidity is back the remainder goes through.
        _returnSpUsdcLiquidity(100e6);
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob), 99_999_999);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
    }

    /**********************************************************************************************/
    /*** Coverage                                                                               ***/
    /**********************************************************************************************/

    function afterInvariant() public view {
        console.log("--- handler call counts ---");
        for (uint256 i = 0; i < handler.callNamesLength(); i++) {
            string memory name_ = handler.callNames(i);
            console.log(name_, handler.calls(name_));
        }
        console.log("--- caught reverts by reason ---");
        for (uint256 i = 0; i < handler.revertReasonsLength(); i++) {
            string memory reason = handler.revertReasons(i);
            console.log(reason, handler.revertsByReason(reason));
        }
        console.log("--- ghost counters ---");
        console.log("depositQueueLength           ", handler.depositQueueLength());
        console.log("cancelledQueueLength         ", handler.cancelledQueueLength());
        console.log("redeemQueueLength            ", handler.redeemQueueLength());
        console.log("depositFills                 ", handler.depositFills());
        console.log("cancelledFills               ", handler.cancelledFills());
        console.log("redeemFills                  ", handler.redeemFills());
        console.log("fillsToBlacklisted           ", handler.fillsToBlacklisted());
        console.log("escrowDecreases (U)          ", handler.escrowDecreases());
        console.log("zeroShareFills (F-4)         ", handler.zeroShareFills());
        console.log("ghostDepositEntries (F-5)    ", handler.ghostDepositEntries());
        console.log("ghostRedeemEntries (F-5)     ", handler.ghostRedeemEntries());
        console.log("recipientUpdates             ", handler.recipientUpdates());
        console.log("recipientUpdatesToBlacklisted", handler.recipientUpdatesToBlacklisted());
        console.log("recipientUpdatesToFresh      ", handler.recipientUpdatesToFresh());
        console.log("strangerUpdateAttempts       ", handler.recipientUpdateStrangerAttempts());
        console.log("strangerUpdateReverts        ", handler.recipientUpdateStrangerReverts());
        console.log("blacklistSets                ", handler.blacklistSets());
        console.log("blacklistClears              ", handler.blacklistClears());
        console.log("blacklistRecipientProbes     ", handler.blacklistRecipientProbes());
        console.log("blacklistRecipientProbeRevs  ", handler.blacklistRecipientProbeReverts());
        console.log("skippedBlacklistedDepositors ", handler.skippedBlacklistedDepositors());
        console.log("claims                       ", handler.claims());
        console.log("usersClaimedUsdc             ", handler.usersClaimedUsdc());
        console.log("claimableCreditedUsdc        ", handler.claimableCreditedUsdc());
        console.log("claimNothingProbes           ", handler.claimNothingProbes());
        console.log("claimWhileBlacklistedAttempts", handler.claimWhileBlacklistedAttempts());
        console.log("claimWhileBlacklistedReverts ", handler.claimWhileBlacklistedReverts());
        console.log("adjustNegatives              ", handler.adjustNegatives());
        console.log("adjustedLossUsdc             ", handler.adjustedLossUsdc());
        console.log("adjustPositives              ", handler.adjustPositives());
        console.log("adjustedGainUsdc             ", handler.adjustedGainUsdc());
        console.log("adjustNotPausedProbes        ", handler.adjustNotPausedProbes());
        console.log("adjustZeroSupplyProbes       ", handler.adjustZeroSupplyProbes());
        console.log("adjustZeroSupplyPanics       ", handler.adjustZeroSupplyPanics());
        console.log("maxGainLossError (T)         ", handler.maxGainLossError());
        console.log("ghostDeficitUsdc (H)         ", handler.ghostDeficitUsdc());
        console.log("redeemProcessReverts (C-1)   ", handler.redeemProcessReverts());
        console.log("cancelProcessReverts (P)     ", handler.cancelProcessReverts());
        console.log("redeemPayoutMaxExcess (Y)    ", handler.redeemPayoutMaxExcess());
        console.log("cancelPayoutMaxExcess (Y)    ", handler.cancelPayoutMaxExcess());
        console.log("usersRedeemedUsdc            ", handler.usersRedeemedUsdc());
        console.log("usersRefundedUsdc            ", handler.usersRefundedUsdc());
        console.log("rateOrderBroken              ", handler.rateOrderBroken());
        console.log("takes                        ", handler.takes());
        console.log("takerOutstandingSpUsdc       ", handler.takerOutstandingSpUsdc());
        console.log("maxBackingGapSpUsdc (W)      ", handler.maxBackingGapSpUsdc());
        console.log("gapOpenedByTake (W)          ", handler.gapOpenedByTake());
        console.log("gapOpenedByRedeems (W, R5-1) ", handler.gapOpenedByRedeems());
        console.log("capacityBelowSupplyEvents (X)", handler.capacityBelowSupplyEvents());
        console.log("unexpectedReverts (AB)       ", handler.unexpectedReverts());
        console.log("totalSupply                  ", vault.totalSupply());
        console.log("chi                          ", vault.chi());
    }

}
