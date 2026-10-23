// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { LocalTestBase }    from "./LocalTestBase.t.sol";
import { ISparkPrimeVault } from "src/ISparkPrimeVault.sol";

/// @dev Deposit-queue tests for `SparkPrimeVault` (round 6, `master` @ c512609; older comments
///      may still quote 0ebb452 / bf93b0d line numbers, the round-6 ones are below).
///
///      Round-6 semantics under test (src lines on c512609):
///        - `requestDeposit` (374-403): zero / vault recipient rejected (380-381), `minDeposit`
///          (382, non-zero since init), pushes the entry and fills instantly iff
///          `pendingDepositSavingsShares == savingsShares_` after the push (400), i.e. every
///          other open entry is zero; it then runs `_processPendingDeposits(max, max)` (401).
///        - `_processPendingDeposits` (858-900) walks from `firstPendingDepositId`: a zero entry
///          is `continue`d BEFORE the `remaining_ == 0` check (875, 878), so a walk with budget 0
///          still advances the head past cancelled entries and stops at the first live one;
///          fills up to `convertToShares(convertToAssets(availableCapacity()))` (862-865),
///          breaks on a partial fill (894), deletes full fills (896), writes the head (899).
///        - `requestDepositCancellation(id, recipient, savingsShares)` (405-446): zero / vault
///          recipient (414-415), `id < length` (416), `NoRequest` (420), owner only (421),
///          `savingsShares >= minDepositCancellation` (422) and `<= request.shares` (423);
///          partial cancels leave the remainder with the same owner/recipient (437), full
///          cancels delete (435); NOT pause-gated; ends with `_processPendingDeposits(0, max)`
///          (445), the "self-skip" walk.
///        - `updateDepositRecipient` (482-493) is owner-only and rejects the vault (484).
///        - `adjustTotalAssets` (262-283, LOSS_MANAGER_ROLE) requires `paused`.
///
///      Harness indexes (frozen at RAY after setUp):
///        spUSDC  chi_s = 1.047633055711877768967605062e27
///        spPRIME chi_p = 1.009687768242461209408770821e27
///
///      Reference conversions at those indexes (all floor):
///        1_000_000e6 USDC -> 954_532_691_143 spUSDC shares
///                         -> fill: assets 999_999_999_999, spPRIME 990_405_184_109
///          100_000e6 USDC ->  95_453_269_114 spUSDC shares
///                         -> fill: assets  99_999_999_999, spPRIME  99_040_518_410
///
///      `maxCapacity` is in spPRIME shares. Capacity -> fillable spUSDC shares is
///        remaining = floor(floor(cap * chi_p / RAY) * RAY / chi_s)
contract DepositQueueTest is LocalTestBase {

    event Transfer(address indexed from, address indexed to, uint256 value);

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave  = makeAddr("dave");
    address eve   = makeAddr("eve");

    uint256 constant ONE_M     = 1_000_000e6;
    uint256 constant HUNDRED_K = 100_000e6;

    // spUSDC shares minted for ONE_M / HUNDRED_K USDC at the harness index.
    uint256 constant S_1M   = 954_532_691_143;
    uint256 constant S_100K = 95_453_269_114;

    // spPRIME shares minted when S_1M / S_100K spUSDC shares are filled in one go.
    uint256 constant SH_1M   = 990_405_184_109;
    uint256 constant SH_100K = 99_040_518_410;

    uint256 constant A_1M   = 999_999_999_999;  // USDC value of S_1M at fill
    uint256 constant A_100K = 99_999_999_999;

    // Storage slots of the three request arrays (pinned by `forge inspect`).
    uint256 constant DEPOSIT_SLOT = 0;
    uint256 constant CANCEL_SLOT  = 1;

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    // Raw array reads (ids below the head revert in the public getter).
    function _rawLength(uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(address(vault), bytes32(slot)));
    }

    function _rawShares(uint256 slot, uint256 i) internal view returns (uint256) {
        uint256 base = uint256(keccak256(abi.encode(slot)));
        return uint256(vm.load(address(vault), bytes32(base + 3 * i + 2)));
    }

    function _rawEntry(uint256 slot, uint256 i)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        uint256 base = uint256(keccak256(abi.encode(slot)));
        owner     = address(uint160(uint256(vm.load(address(vault), bytes32(base + 3 * i)))));
        recipient = address(uint160(uint256(vm.load(address(vault), bytes32(base + 3 * i + 1)))));
        shares    = uint256(vm.load(address(vault), bytes32(base + 3 * i + 2)));
    }

    // What a fill of `savingsShares` spUSDC shares produces right now (same math as src 883-884).
    function _fillOf(uint256 savingsShares) internal view returns (uint256 assets, uint256 shares) {
        assets = spUsdc.convertToAssets(savingsShares);
        shares = vault.convertToShares(assets);
    }

    // spUSDC shares fillable by `cap` spPRIME shares of free capacity (same math as src 862-865).
    function _remainingForCapacity(uint256 cap) internal view returns (uint256) {
        return spUsdc.convertToShares(vault.convertToAssets(cap));
    }

    function _queueLength() internal view returns (uint256) {
        return _rawLength(DEPOSIT_SLOT);
    }

    function _cancelledQueueLength() internal view returns (uint256) {
        return _rawLength(CANCEL_SLOT);
    }

    function _sumOpenEntries() internal view returns (uint256 sum) {
        uint256 n = _queueLength();
        for (uint256 i = vault.firstPendingDepositId(); i < n; ++i) sum += _rawShares(DEPOSIT_SLOT, i);
    }

    function _sumOpenCancelledEntries() internal view returns (uint256 sum) {
        uint256 n = _cancelledQueueLength();
        for (uint256 i = vault.firstPendingDepositCancellationId(); i < n; ++i) {
            sum += _rawShares(CANCEL_SLOT, i);
        }
    }

    function _shares(uint256 id) internal view returns (uint256) {
        return _rawShares(DEPOSIT_SLOT, id);
    }

    function _cancelledShares(uint256 id) internal view returns (uint256) {
        return _rawShares(CANCEL_SLOT, id);
    }

    // Puts `who`'s whole deposit in the queue: freeze capacity at current supply first.
    function _queue(address who, uint256 amt) internal returns (uint256 id) {
        _setCapacity(vault.totalSupply());
        id = _deposit(who, amt);
    }

    // 1 wei of USDC mints 0 spUSDC shares (R5-15): a zero-share "ghost" entry.
    function _ghost(address who) internal returns (uint256 id) {
        _fund(who, 1);
        vm.prank(who);
        id = vault.requestDeposit(1, who, 0);
    }

    // Owner cancels the whole remainder to themselves without settling the refund.
    function _cancel(address who, uint256 id) internal returns (uint256 cancelId) {
        uint256 s = _shares(id);
        vm.prank(who);
        cancelId = vault.requestDepositCancellation(id, who, s);
    }

    // Owner cancels `s` shares to `recipient` without settling the refund.
    function _cancelPart(address who, uint256 id, address recipient, uint256 s)
        internal returns (uint256 cancelId)
    {
        vm.prank(who);
        cancelId = vault.requestDepositCancellation(id, recipient, s);
    }

    // True iff every open entry is zero, i.e. the next request will satisfy the instant-fill
    // predicate `pendingDepositSavingsShares == savingsShares_` (src 400) after its push.
    function _nextRequestIsInstant() internal view returns (bool) {
        return vault.pendingDepositSavingsShares() == 0;
    }

    // Same thing read off the array, to cross-check the counter against the entries.
    function _everyOpenEntryIsZero() internal view returns (bool) {
        uint256 len = _queueLength();
        for (uint256 i = vault.firstPendingDepositId(); i < len; ++i) {
            if (_shares(i) != 0) return false;
        }
        return true;
    }

    function _assertQueueConsistent() internal view {
        assertEq(vault.pendingDepositSavingsShares(), _sumOpenEntries(), "pending != sum(open)");
        assertEq(
            vault.pendingCancelledDepositSavingsShares(),
            _sumOpenCancelledEntries(),
            "pendingCancelled != sum(open cancelled)"
        );

        uint256 head = vault.firstPendingDepositId();
        uint256 len  = _queueLength();
        assertLe(head, len, "head > length");
        for (uint256 i; i < head; ++i) {
            assertEq(_shares(i), 0, "open entry behind head");
        }

        uint256 cHead = vault.firstPendingDepositCancellationId();
        uint256 cLen  = _cancelledQueueLength();
        assertLe(cHead, cLen, "cancelled head > length");
        for (uint256 i; i < cHead; ++i) {
            assertEq(_cancelledShares(i), 0, "open cancelled entry behind head");
        }

        assertLe(vault.totalSupply(), vault.maxCapacity(), "supply > capacity");

        // The predicate's counter and the array agree on whether the next request is instant.
        assertEq(_nextRequestIsInstant(), _everyOpenEntryIsZero(), "predicate != array");
    }

    // After a cancel's self-skip walk the head sits on a live entry or at the length.
    function _assertHeadOnLiveOrEnd() internal view {
        uint256 head = vault.firstPendingDepositId();
        if (head < _queueLength()) assertGt(_shares(head), 0, "head on a dead slot");
    }

    function setUp() public override {
        super.setUp();
        assertEq(spUsdc.nowChi(), 1.047633055711877768967605062e27);
        assertEq(vault.nowChi(),  1.009687768242461209408770821e27);
        assertEq(spUsdc.convertToShares(ONE_M), S_1M);
        assertEq(spUsdc.convertToShares(HUNDRED_K), S_100K);
    }

    /**********************************************************************************************/
    /*** H0: requestDeposit reverts                                                             ***/
    /**********************************************************************************************/

    function test_requestDeposit_zeroRecipient() public {
        _fund(alice, ONE_M);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.requestDeposit(ONE_M, address(0), 7);
    }

    // Round 5 (DQ-4 fixed): the vault is rejected as a deposit recipient (src 381) and as a
    // repoint target (484), so spPRIME can no longer be minted to the vault's own address through
    // the deposit queue. `transfer`/`transferFrom` reject it too (558, 570). Nothing is pulled.
    function test_fixed_requestDeposit_vaultIsRecipient() public {
        _fund(alice, ONE_M);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDeposit(ONE_M, address(vault), 0);

        assertEq(usdc.balanceOf(alice),           ONE_M);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(_queueLength(),                  0);

        uint256 id = _queue(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositRecipient(id, address(vault));

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transfer(address(vault), 1);
        assertEq(vault.balanceOf(address(vault)), 0);
    }

    function test_requestDeposit_belowMinDepositBoundary() public {
        _setMinDeposit(HUNDRED_K);
        _fund(alice, HUNDRED_K);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(HUNDRED_K - 1, alice, 0);

        vm.prank(alice);
        vault.requestDeposit(HUNDRED_K, alice, 0);
        assertEq(vault.balanceOf(alice), SH_100K);
    }

    // Round 6 (R5-9 ghosts, partially fixed): a zero-asset request is impossible since
    // `minDeposit` is non-zero from `initialize` (src 184) and `setMinDeposit` (225); with the
    // harness minimum of 1 wei the only remaining "ghost" is the 1-wei dust deposit below.
    function test_fixed_requestDeposit_zeroAssetsRejected() public {
        _fund(alice, 0);
        assertEq(vault.minDeposit(), 1);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(0, alice, 0);

        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.ZeroMinDeposit.selector);
        vault.setMinDeposit(0);

        assertEq(_queueLength(), 0);
    }

    function test_requestDeposit_isPaused() public {
        _fund(bob, HUNDRED_K);
        _pause();

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDeposit(HUNDRED_K, bob, 0);
    }

    // A blacklisted recipient still receives spPRIME: `requestDeposit` has no blacklist check
    // (the fill mints shares, not USDC). Only the owner's USDC pull is subject to the asset's
    // own blacklist. Info.
    function test_requestDeposit_blacklistedRecipientStillReceivesShares() public {
        _blacklist(bob);
        _fund(alice, HUNDRED_K);

        vm.prank(alice);
        vault.requestDeposit(HUNDRED_K, bob, 0);
        assertEq(vault.balanceOf(bob), SH_100K);

        _fund(alice, 1);
        _blacklist(alice);
        vm.prank(alice);
        vm.expectRevert(BLACKLISTED);
        vault.requestDeposit(1, alice, 0);
    }

    /**********************************************************************************************/
    /*** H1: instant vs queued                                                                  ***/
    /**********************************************************************************************/

    function test_requestDeposit_instantFillWhenNobodyQueued() public {
        _fund(alice, ONE_M);

        assertEq(vault.totalSupply(),                 0);
        assertEq(vault.balanceOf(alice),              0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),       0);
        assertEq(_vaultSpUsdc(),                      0);
        assertEq(usdc.balanceOf(alice),               ONE_M);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositRequest(0, alice, alice, ONE_M, S_1M);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(0, alice, alice, S_1M, A_1M, SH_1M);

        vm.prank(alice);
        uint256 id = vault.requestDeposit(ONE_M, alice, 0);

        // The entry is created even for an instant fill and then deleted by the fill (src 896).
        assertEq(id, 0);
        (address owner, address recipient, uint256 shares) = _rawEntry(DEPOSIT_SLOT, 0);
        assertEq(owner,     address(0));
        assertEq(recipient, address(0));
        assertEq(shares,    0);

        assertEq(vault.totalSupply(),                 SH_1M);
        assertEq(vault.balanceOf(alice),              SH_1M);
        assertEq(vault.assetsOf(alice),               999_999_999_998);  // R1 + R3 + R12 rounding
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),       1);
        assertEq(_vaultSpUsdc(),                      S_1M);
        assertEq(usdc.balanceOf(alice),               0);
        assertEq(usdc.balanceOf(address(spUsdc)),     ONE_M);

        // The filled id is below the head: the public getter rejects it.
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(0);
    }

    function test_requestDeposit_secondDepositorQueuedBehindPendingEvenWithFreeCapacity() public {
        uint256 aliceId = _queue(alice, ONE_M);
        assertEq(aliceId, 0);
        assertEq(vault.pendingDepositSavingsShares(), S_1M);
        assertEq(vault.firstPendingDepositId(), 0);

        // Open plenty of capacity; alice is still queued because nobody processed the queue.
        _setCapacity(type(uint128).max);
        assertGt(vault.availableCapacity(), SH_1M * 10);
        assertFalse(_nextRequestIsInstant());

        uint256 bobId = _deposit(bob, HUNDRED_K);

        assertEq(bobId, 1);
        assertEq(vault.balanceOf(bob),                0);
        assertEq(vault.balanceOf(alice),              0);
        assertEq(vault.totalSupply(),                 0);
        assertEq(_shares(0),                          S_1M);
        assertEq(_shares(1),                          S_100K);
        assertEq(vault.pendingDepositSavingsShares(), S_1M + S_100K);
        assertEq(vault.firstPendingDepositId(),       0);
        assertEq(_vaultSpUsdc(),                      S_1M + S_100K);
        _assertQueueConsistent();
    }

    function test_requestDeposit_instantFillResumesAfterQueueDrains() public {
        _queue(alice, ONE_M);
        _deposit(bob, HUNDRED_K);
        _setCapacity(type(uint128).max);

        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice),              SH_1M);
        assertEq(vault.balanceOf(bob),                SH_100K);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),       2);

        uint256 carolId = _deposit(carol, HUNDRED_K);

        assertEq(carolId,                             2);
        assertEq(vault.balanceOf(carol),              SH_100K);
        assertEq(_shares(2),                          0);
        assertEq(vault.firstPendingDepositId(),       3);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.totalSupply(),                 SH_1M + 2 * SH_100K);
        _assertQueueConsistent();
    }

    // Round 6: the cancel's self-skip walk (src 445) clears the cancelled head immediately, so
    // the next depositor's instant fill walks nothing.
    function test_requestDeposit_instantFillResumesAfterCancelDrainsQueue() public {
        uint256 aliceId = _queue(alice, ONE_M);
        _setCapacity(type(uint128).max);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRequest(aliceId, 0, alice, S_1M);

        uint256 cancelId = _cancel(alice, aliceId);

        assertEq(cancelId,                                     0);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
        assertEq(vault.firstPendingDepositId(),                1);  // self-skip: head past the dead slot
        assertEq(_shares(aliceId),                             0);
        assertEq(_cancelledShares(cancelId),                   S_1M);
        assertEq(usdc.balanceOf(alice),                        0);   // refund not paid yet
        assertEq(_vaultSpUsdc(),                               S_1M);
        assertTrue(_nextRequestIsInstant());
        _assertHeadOnLiveOrEnd();

        uint256 bobId = _deposit(bob, HUNDRED_K);

        assertEq(bobId,                         1);
        assertEq(vault.balanceOf(bob),          SH_100K);
        assertEq(vault.firstPendingDepositId(), 2);
        _assertQueueConsistent();

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice),                        A_1M);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),    1);
        assertEq(_vaultSpUsdc(),                               S_100K);
        _assertQueueConsistent();
    }

    // Cancel at the head of a capacity-0 queue: the walk runs with `remaining_ == 0` and still
    // clears the dead slot (src 875 before 878), then open capacity.
    function test_requestDeposit_instantFillAfterHeadEntryCancelled() public {
        _setCapacity(0);

        uint256 aliceId = _deposit(alice, ONE_M);
        assertEq(aliceId,                       0);
        assertEq(vault.firstPendingDepositId(), 0);

        _cancel(alice, aliceId);
        assertEq(vault.firstPendingDepositId(), 1);  // cleared at capacity 0

        _setCapacity(type(uint128).max);

        uint256 bobId = _deposit(bob, HUNDRED_K);
        assertEq(bobId,                         1);
        assertEq(vault.balanceOf(bob),          SH_100K);
        assertEq(vault.firstPendingDepositId(), 2);
        _assertQueueConsistent();
    }

    /**********************************************************************************************/
    /*** H1b: self-skip walk, budget-0 walk, live head frozen at capacity 0 (R5-9)              ***/
    /**********************************************************************************************/

    // Round 6 (R5-9 partially fixed): cancelling the head walks every dead slot behind it until
    // the first live entry, at capacity 0 too. Dead slots behind a LIVE head are not walked by
    // the cancel (the walk stops at the live head immediately).
    function test_fixed_requestDepositCancellation_selfSkipWalksDeadRunBehindCancelledHead() public {
        _setCapacity(0);
        uint256 a = _deposit(alice, HUNDRED_K);  // 0 live head
        uint256 b = _deposit(bob,   HUNDRED_K);  // 1
        uint256 c = _deposit(carol, HUNDRED_K);  // 2
        uint256 d = _deposit(dave,  HUNDRED_K);  // 3 live

        _cancel(bob, b);
        assertEq(vault.firstPendingDepositId(), 0);  // alice is live: the walk stops at once
        _cancel(carol, c);
        assertEq(vault.firstPendingDepositId(), 0);
        _assertQueueConsistent();

        // Cancelling the head skips 0, 1, 2 and stops on dave (live) even with no capacity.
        _cancel(alice, a);
        assertEq(vault.firstPendingDepositId(),       3);
        assertEq(_shares(d),                          S_100K);
        assertEq(vault.pendingDepositSavingsShares(), S_100K);
        assertEq(vault.balanceOf(dave),               0);  // budget 0: dave is not filled
        _assertHeadOnLiveOrEnd();
        _assertQueueConsistent();

        // Cancelling the last live entry walks to the length.
        _cancel(dave, d);
        assertEq(vault.firstPendingDepositId(),       4);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertTrue(_nextRequestIsInstant());
        assertEq(vault.getPendingDepositRequests().length, 0);
        _assertQueueConsistent();

        // Everyone is refunded minus the 1-wei floor each.
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), A_100K);
        assertEq(usdc.balanceOf(bob),   A_100K);
        assertEq(usdc.balanceOf(carol), A_100K);
        assertEq(usdc.balanceOf(dave),  A_100K);
        assertEq(vault.firstPendingDepositCancellationId(), 4);
        _assertQueueConsistent();
    }

    // Round 6 (new path): `processPendingDeposits(0, N)` walks N dead slots at any capacity,
    // including 0 (src 875 `continue` before the 878 `break`), and never touches a live entry
    // (budget 0 breaks on it). Round 5 needed at least 2 shares of capacity and risked a dust
    // fill on the live entry behind the dead run.
    function test_fixed_processPendingDeposits_budgetZeroWalksCancelledEntriesAtCapacityZero() public {
        _setCapacity(0);
        uint256 a = _deposit(alice, HUNDRED_K);  // 0 live head
        uint256 n = 20;
        uint256[] memory ids = new uint256[](n);
        _fund(eve, n * HUNDRED_K);
        for (uint256 i; i < n; ++i) {
            vm.prank(eve);
            ids[i] = vault.requestDeposit(HUNDRED_K, eve, 0);
        }
        uint256 live = _deposit(bob, HUNDRED_K);  // id 21 live
        for (uint256 i; i < n; ++i) _cancel(eve, ids[i]);
        assertEq(vault.firstPendingDepositId(), 0);

        // Fill alice only: the head lands on the first dead slot.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(alice),        SH_100K);
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(_shares(a),                    0);

        // No free capacity, budget 0: walks exactly the n dead slots and stops before bob.
        _setCapacity(vault.totalSupply());
        assertEq(vault.availableCapacity(), 0);
        _processDeposits(0, n);
        assertEq(vault.firstPendingDepositId(), n + 1);
        assertEq(_shares(live),                 S_100K);
        assertEq(vault.balanceOf(bob),          0);
        assertEq(vault.totalSupply(),           SH_100K);

        // One request too many is harmless now: budget 0 breaks on the live entry.
        _processDeposits(0, 1);
        assertEq(vault.firstPendingDepositId(), n + 1);
        assertEq(_shares(live),                 S_100K);
        _assertHeadOnLiveOrEnd();
        _assertQueueConsistent();
    }

    // With capacity 0 a LIVE head is still frozen: the walk breaks on it (src 878) and
    // `firstPendingDepositId = i_` (899) rewrites the same value.
    function test_processPendingDeposits_capacityZeroFreezesLiveHead() public {
        _setCapacity(0);
        uint256 a = _deposit(alice, HUNDRED_K);
        _deposit(bob, HUNDRED_K);

        _processDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(_shares(a),                    S_100K);
        assertEq(vault.totalSupply(),           0);

        _processDeposits(0, 10);
        assertEq(vault.firstPendingDepositId(), 0);

        // Capacity 1 share -> remaining_ 0 (src 864 double floor): still frozen.
        _setCapacity(1);
        assertEq(_remainingForCapacity(1), 0);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(vault.totalSupply(),           0);
        _assertQueueConsistent();
    }

    // Round 6 (R5-9 fixed for the self-cancel shape): the round-5 griefing of queueing N
    // minimum-sized requests behind one's own live head, cancelling them all and then the head
    // no longer taxes anybody: the last cancel walks all N+1 dead slots on the griefer's dime and
    // the next depositor's instant fill is at baseline gas.
    function test_fixed_cancelledSlotsBehindOwnHeadAreWalkedByTheHeadCancel() public {
        _setMinDeposit(HUNDRED_K);
        _setCapacity(0);
        uint256 n = 200;
        _fund(eve, (n + 1) * HUNDRED_K);

        vm.prank(eve);
        uint256 head = vault.requestDeposit(HUNDRED_K, eve, 0);  // live head, queued
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            vm.prank(eve);
            ids[i] = vault.requestDeposit(HUNDRED_K, eve, 0);
        }
        for (uint256 i; i < n; ++i) _cancel(eve, ids[i]);
        assertEq(vault.firstPendingDepositId(), 0);

        vm.cool(address(vault));
        uint256 g0 = gasleft();
        _cancel(eve, head);
        uint256 gasHeadCancel = g0 - gasleft();

        assertEq(vault.firstPendingDepositId(),       n + 1);  // walked all 201 dead slots
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertTrue(_nextRequestIsInstant());
        _assertQueueConsistent();

        _setCapacity(type(uint128).max);
        _fund(bob, HUNDRED_K);

        uint256 gasBaseline;
        {
            uint256 snap = vm.snapshotState();
            _deposit(carol, HUNDRED_K);  // fresh entry at the tail, nothing to walk
            vm.cool(address(vault));
            vm.cool(address(spUsdc));
            vm.cool(address(usdc));
            vm.prank(bob);
            uint256 g1 = gasleft();
            vault.requestDeposit(HUNDRED_K, bob, 0);
            gasBaseline = g1 - gasleft();
            vm.revertToState(snap);
        }

        vm.cool(address(vault));
        vm.cool(address(spUsdc));
        vm.cool(address(usdc));
        vm.prank(bob);
        uint256 g2 = gasleft();
        vault.requestDeposit(HUNDRED_K, bob, 0);
        uint256 gasAfterGrief = g2 - gasleft();

        assertEq(vault.balanceOf(bob),          SH_100K);
        assertEq(vault.firstPendingDepositId(), n + 2);
        assertEq(_queueLength(),                n + 2);  // bob's walk started at his own entry
        // Bob pays nothing per dead slot: the difference to a fresh fill is storage-shape noise
        // (a few cold/warm slots), nowhere near the 2.4k per slot of the residual below.
        assertLt(gasAfterGrief, gasBaseline + 20_000);
        assertLt(gasAfterGrief, gasBaseline + n * 1_000);
        // The griefer paid ~2.4k per dead slot (one cold SLOAD + loop) in the head cancel.
        assertGt(gasHeadCancel, n * 2_100);
        emit log_named_uint("head cancel gas, 200 dead slots behind", gasHeadCancel);
        emit log_named_uint("victim instant fill gas, baseline", gasBaseline);
        emit log_named_uint("victim instant fill gas, after grief", gasAfterGrief);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(eve), (n + 1) * A_100K);
        _assertQueueConsistent();
    }

    // LOW (R5-9 residual): the self-skip only runs from the head, so a dead run behind an HONEST
    // live head is not cleared by the griefer's cancels. If the operator then fills the head
    // with `maxRequests_ == 1` (or the head owner cancels nothing), the dead run sits at the new
    // head and the NEXT depositor whose request satisfies the predicate (src 400) walks it on
    // its own dime (src 401). Measures the per-slot cost on the victim's instant fill. Mitigation
    // on this master: `processPendingDeposits(0, N)` clears it for free beforehand (new path).
    function test_BUG_cancelledRunBehindLiveHeadTaxesNextInstantFill() public {
        _setMinDeposit(HUNDRED_K);
        _setCapacity(0);
        uint256 n = 200;

        uint256 a = _deposit(alice, HUNDRED_K);  // honest live head
        _fund(eve, n * HUNDRED_K);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            vm.prank(eve);
            ids[i] = vault.requestDeposit(HUNDRED_K, eve, 0);
        }
        for (uint256 i; i < n; ++i) _cancel(eve, ids[i]);  // each walk stops at alice at once
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(vault.pendingDepositSavingsShares(), S_100K);

        // Operator fills alice alone: the head lands on the dead run.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);
        assertEq(_shares(a),                    0);
        assertEq(vault.firstPendingDepositId(), 1);
        assertTrue(_nextRequestIsInstant());
        _fund(bob, HUNDRED_K);

        uint256 gasBaseline;
        {
            uint256 snap = vm.snapshotState();
            _processDeposits(0, n);  // operator clears the run first (budget-0 walk)
            assertEq(vault.firstPendingDepositId(), n + 1);
            vm.cool(address(vault));
            vm.prank(bob);
            uint256 g0 = gasleft();
            vault.requestDeposit(HUNDRED_K, bob, 0);
            gasBaseline = g0 - gasleft();
            vm.revertToState(snap);
        }

        vm.cool(address(vault));
        vm.prank(bob);
        uint256 g1 = gasleft();
        vault.requestDeposit(HUNDRED_K, bob, 0);
        uint256 gasTaxed = g1 - gasleft();

        assertEq(vault.balanceOf(bob),          SH_100K);
        assertEq(vault.firstPendingDepositId(), n + 2);

        uint256 perSlot = (gasTaxed - gasBaseline) / n;
        assertGt(perSlot, 2_100);   // one cold SLOAD per slot plus loop overhead
        assertLt(perSlot, 2_800);
        emit log_named_uint("gas per dead slot on the victim's instant fill (cold)", perSlot);
        emit log_named_uint("slots to exceed 30M", 30_000_000 / perSlot);
        emit log_named_uint("instant fill gas, baseline", gasBaseline);
        emit log_named_uint("instant fill gas, 200 dead slots", gasTaxed);

        // Eve is made whole minus 1 wei per entry by the cancellation queue.
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(eve), n * A_100K);
        _assertQueueConsistent();
    }

    // Cost side of the residual above: one request-then-cancel pair at `minDeposit`, cold.
    function test_requestDepositCancellation_griefCostPerDeadSlot() public {
        _setMinDeposit(HUNDRED_K);
        _setCapacity(0);
        _deposit(alice, HUNDRED_K);  // live head
        _fund(eve, 2 * HUNDRED_K);
        vm.prank(eve);
        uint256 warm = vault.requestDeposit(HUNDRED_K, eve, 0);
        _cancel(eve, warm);

        vm.cool(address(vault));
        vm.cool(address(spUsdc));
        vm.cool(address(usdc));
        vm.prank(eve);
        uint256 g0 = gasleft();
        uint256 id = vault.requestDeposit(HUNDRED_K, eve, 0);
        uint256 gasRequest = g0 - gasleft();

        vm.cool(address(vault));
        vm.cool(address(spUsdc));
        vm.cool(address(usdc));
        vm.prank(eve);
        uint256 g1 = gasleft();
        vault.requestDepositCancellation(id, eve, S_100K);
        uint256 gasCancel = g1 - gasleft();

        assertGt(gasRequest + gasCancel, 150_000);
        assertLt(gasRequest + gasCancel, 400_000);
        emit log_named_uint("griefer gas per dead slot: request", gasRequest);
        emit log_named_uint("griefer gas per dead slot: cancel", gasCancel);
        // Plus the settlement the operator pays per entry (~27k, see the cancelled-queue file)
        // and 1 wei of USDC lost per entry; the float returns through the cancellation queue.
    }

    // Dust deposits are ghosts (R5-15, still open): 1 wei of USDC mints 0 spUSDC shares, the wei
    // stays in spUSDC, the entry is a zero-share slot that cannot be cancelled. Behind a live
    // head it is a dead slot for 1 wei and one transaction, cheaper than request-then-cancel.
    function test_BUG_oneWeiDepositIsAGhostAndDonatesToSpUsdc() public {
        _queue(alice, HUNDRED_K);  // someone live ahead so the ghost does not even run the walk
        assertEq(spUsdc.convertToShares(1), 0);
        uint256 spUsdcUsdcBefore = usdc.balanceOf(address(spUsdc));

        _fund(bob, 1);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositRequest(1, bob, bob, 1, 0);
        vm.prank(bob);
        uint256 id = vault.requestDeposit(1, bob, 0);

        assertEq(_shares(id),                         0);
        assertEq(usdc.balanceOf(bob),                 0);
        assertEq(usdc.balanceOf(address(spUsdc)),     spUsdcUsdcBefore + 1);
        assertEq(_vaultSpUsdc(),                      S_100K);  // nothing minted for bob
        assertEq(vault.pendingDepositSavingsShares(), S_100K);
        assertEq(vault.firstPendingDepositId(),       0);

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, bob, 1);
        _assertQueueConsistent();

        // With nobody live ahead the ghost satisfies the predicate and is walked past at once.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(), 2);
        uint256 id2 = _ghost(carol);
        assertEq(id2,                           2);
        assertEq(vault.firstPendingDepositId(), 3);
        _assertQueueConsistent();
    }

    // A partially filled head is live: neither a cancel elsewhere nor a new request moves it.
    function test_requestDepositCancellation_partiallyFilledHeadNotAdvanced() public {
        uint256 a = _queue(alice, ONE_M);
        uint256 b = _deposit(bob, HUNDRED_K);
        _setCapacity(type(uint128).max);

        _processDeposits(400e9, 1);
        assertEq(_shares(a),                    554_532_691_143);
        assertEq(vault.firstPendingDepositId(), 0);

        _cancel(bob, b);                       // tail cancel
        assertEq(vault.firstPendingDepositId(), 0);

        uint256 c = _deposit(carol, HUNDRED_K);
        assertEq(c,                             2);
        assertEq(vault.balanceOf(carol),        0);   // queued behind alice's remainder
        assertEq(vault.firstPendingDepositId(), 0);
        _assertQueueConsistent();

        // Finishing alice walks over bob's cancelled slot and fills carol.
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(alice),        990_405_184_108);
        assertEq(vault.balanceOf(carol),        SH_100K);
        assertEq(vault.firstPendingDepositId(), 3);
        _assertQueueConsistent();
    }

    /**********************************************************************************************/
    /*** H2: partial fills                                                                      ***/
    /**********************************************************************************************/

    function test_requestDeposit_partialInstantFillLeavesRemainderAtHead() public {
        // Capacity for half of alice's shares.
        uint256 cap = SH_1M / 2;  // 495_202_592_054
        _setCapacity(cap);
        assertEq(_remainingForCapacity(cap), 477_266_345_570);

        _fund(alice, ONE_M);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(
            0, alice, alice, 477_266_345_570, 499_999_999_997, 495_202_592_052
        );

        vm.prank(alice);
        uint256 id = vault.requestDeposit(ONE_M, alice, 0);

        assertEq(id,                                  0);
        assertEq(vault.balanceOf(alice),              495_202_592_052);
        assertEq(vault.totalSupply(),                 495_202_592_052);
        assertEq(vault.availableCapacity(),           2);  // rounding leaves 2 shares unused
        assertEq(_shares(0),                          S_1M - 477_266_345_570);
        assertEq(_shares(0),                          477_266_345_573);
        assertEq(vault.pendingDepositSavingsShares(), 477_266_345_573);
        assertEq(vault.firstPendingDepositId(),       0);
        assertEq(_vaultSpUsdc(),                      S_1M);
        _assertQueueConsistent();
    }

    function test_processPendingDeposits_partialThenCompleteFill() public {
        uint256 id = _queue(alice, ONE_M);
        _setCapacity(type(uint128).max);

        // Fill exactly 400e9 spUSDC shares via maxSavingsShares_.
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(id, alice, alice, 400e9, 419_053_222_284, 415_032_483_768);

        _processDeposits(400e9, 10);

        assertEq(vault.balanceOf(alice),              415_032_483_768);
        assertEq(_shares(id),                         S_1M - 400e9);
        assertEq(_shares(id),                         554_532_691_143);
        assertEq(vault.pendingDepositSavingsShares(), 554_532_691_143);
        assertEq(vault.firstPendingDepositId(),       0);
        _assertQueueConsistent();

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(
            id, alice, alice, 554_532_691_143, 580_946_777_714, 575_372_700_340
        );

        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice),              415_032_483_768 + 575_372_700_340);
        assertEq(vault.balanceOf(alice),              990_405_184_108);  // 1 wei below SH_1M
        assertEq(_shares(id),                         0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),       1);
        assertEq(_vaultSpUsdc(),                      S_1M);  // fills never move spUSDC
        _assertQueueConsistent();
    }

    function test_processPendingDeposits_partialFillFromCapacityThenRaise() public {
        uint256 id = _queue(alice, ONE_M);
        _setCapacity(SH_1M / 2);

        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice),        495_202_592_052);
        assertEq(_shares(id),                   477_266_345_573);
        assertEq(vault.availableCapacity(),     2);
        assertEq(vault.firstPendingDepositId(), 0);

        // Available capacity of 2 shares converts to 1 spUSDC share: see test_BUG_dustFill...
        // Raise capacity and finish.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice),              495_202_592_052 + 495_202_592_056);
        assertEq(_shares(id),                         0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),       1);
        _assertQueueConsistent();
    }

    /**********************************************************************************************/
    /*** H3: capacity below totalSupply                                                         ***/
    /**********************************************************************************************/

    function test_processPendingDeposits_capacityBelowTotalSupplyIsNoop() public {
        _deposit(alice, ONE_M);  // instant, supply = SH_1M
        uint256 bobId = _queue(bob, HUNDRED_K);

        _setCapacity(SH_1M - 1);
        assertEq(vault.availableCapacity(), 0);
        assertEq(vault.totalSupply(),       SH_1M);

        _processDeposits(type(uint256).max, 10);  // no revert

        assertEq(vault.balanceOf(bob),                0);
        assertEq(_shares(bobId),                      S_100K);
        assertEq(vault.pendingDepositSavingsShares(), S_100K);
        assertEq(vault.firstPendingDepositId(),       1);
        assertEq(vault.totalSupply(),                 SH_1M);

        // Capacity must exceed the fill by 2 shares because of the double rounding on src 864
        // (see test_BUG_exactFitCapacityLeavesDustThatBlocksInstantFills).
        _setCapacity(SH_1M + SH_100K + 2);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(bob),                SH_100K);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),       2);
        assertEq(vault.availableCapacity(),           2);
        _assertQueueConsistent();
    }

    function test_requestDeposit_capacityBelowTotalSupplyQueuesWholeDeposit() public {
        _deposit(alice, ONE_M);
        _setCapacity(1);

        uint256 bobId = _deposit(bob, HUNDRED_K);

        assertEq(bobId,                               1);
        assertEq(vault.balanceOf(bob),                0);
        assertEq(_shares(bobId),                      S_100K);
        assertEq(vault.pendingDepositSavingsShares(), S_100K);
        assertEq(vault.firstPendingDepositId(),       1);
        assertEq(vault.totalSupply(),                 SH_1M);
        assertEq(_vaultSpUsdc(),                      S_1M + S_100K);
    }

    /**********************************************************************************************/
    /*** H4: requestDepositCancellation: reverts, partial and full cancels, head bookkeeping    ***/
    /**********************************************************************************************/

    function _queueThree() internal returns (uint256 a, uint256 b, uint256 c) {
        a = _queue(alice, ONE_M);
        b = _deposit(bob,   HUNDRED_K);
        c = _deposit(carol, HUNDRED_K);
        assertEq(vault.pendingDepositSavingsShares(), S_1M + 2 * S_100K);
        assertEq(vault.firstPendingDepositId(), 0);
    }

    function test_requestDepositCancellation_zeroRecipient() public {
        uint256 id = _queue(alice, ONE_M);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.requestDepositCancellation(id, address(0), S_1M);
    }

    // Round 6 (V2-13 fixed for the vault): the vault is rejected as a cancellation recipient at
    // request (src 415) and at repoint (500). spUSDC is still accepted: see the cancelled-queue
    // file (`test_BUG_cancellationRecipientSpUsdcDonatesRefund`).
    function test_fixed_requestDepositCancellation_vaultIsRecipient() public {
        uint256 id = _queue(alice, ONE_M);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDepositCancellation(id, address(vault), S_1M);

        uint256 cancelId = _cancel(alice, id);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositCancellationRecipient(cancelId, address(vault));

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice),          A_1M);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // `requestId_ < length` (src 416): the id at the length reverts `InvalidRequestId` (round 5
    // panicked with an index-out-of-bounds), an id below the head is `NoRequest`.
    function test_requestDepositCancellation_invalidRequestIdBoundary() public {
        uint256 id = _queue(alice, ONE_M);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.requestDepositCancellation(id + 1, alice, S_1M);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.requestDepositCancellation(type(uint256).max, alice, S_1M);

        vm.prank(alice);
        vault.requestDepositCancellation(id, alice, S_1M);
    }

    function test_requestDepositCancellation_noRequest_filledCancelledAndBelowHead() public {
        uint256 filled = _deposit(alice, ONE_M);  // instant fill deletes the entry, head 1
        assertEq(_shares(filled), 0);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(filled, alice, 1);

        uint256 id = _queue(alice, ONE_M);
        _cancel(alice, id);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, alice, 1);

        vm.prank(pauser);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, pauser, 1);
    }

    function test_requestDepositCancellation_notRequestOwner() public {
        uint256 id = _queue(alice, ONE_M);

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id, bob, S_1M);

        // No role has cancel power either, whoever they name as recipient.
        address[6] memory roles = [pauser, unpauser, operator, admin, taker, lossManager];
        for (uint256 i; i < 6; ++i) {
            vm.prank(roles[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.requestDepositCancellation(id, alice, S_1M);

            vm.prank(roles[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.requestDepositCancellation(id, roles[i], S_1M);
        }

        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    S_1M);
        assertEq(_cancelledQueueLength(), 0);
    }

    // The share recipient of a deposit is not its owner and cannot cancel.
    function test_requestDepositCancellation_notRequestOwner_recipient() public {
        _setCapacity(0);
        _fund(alice, ONE_M);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(ONE_M, bob, 0);

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id, bob, S_1M);

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id, alice, S_1M);

        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);
    }

    function test_requestDepositCancellation_belowMinDepositCancellationBoundary() public {
        uint256 id = _queue(alice, ONE_M);
        _setMinDepositCancellation(S_100K);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, S_100K - 1);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, 0);

        vm.prank(alice);
        vault.requestDepositCancellation(id, alice, S_100K);
        assertEq(_shares(id), S_1M - S_100K);

        // The minimum applies to the cancelled amount, not to the remainder: a remainder below
        // the minimum is stranded until it can be cancelled in full (>= minimum) or filled.
        _setMinDepositCancellation(S_1M);
        uint256 left = _shares(id);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, left);
    }

    function test_requestDepositCancellation_savingsSharesTooHighBoundary() public {
        uint256 id = _queue(alice, ONE_M);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, alice, S_1M + 1);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, alice, type(uint256).max);

        vm.prank(alice);
        vault.requestDepositCancellation(id, alice, S_1M);
        assertEq(_shares(id), 0);
    }

    // Round 6 (new): a partial cancel moves `savingsShares_` to a new cancellation entry and
    // leaves the remainder with the same owner and recipient (src 437); counters move exactly.
    function test_requestDepositCancellation_partial() public {
        _setCapacity(0);
        _fund(alice, ONE_M);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(ONE_M, bob, 0);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRequest(id, 0, carol, 400e9);
        vm.prank(alice);
        uint256 cancelId = vault.requestDepositCancellation(id, carol, 400e9);

        assertEq(cancelId, 0);
        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M - 400e9);
        assertEq(shares,    554_532_691_143);

        (address cOwner, address cRecipient, uint256 cShares) = _cancelledDepositRequest(cancelId);
        assertEq(cOwner,     alice);
        assertEq(cRecipient, carol);
        assertEq(cShares,    400e9);

        assertEq(vault.pendingDepositSavingsShares(),          554_532_691_143);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 400e9);
        assertEq(vault.firstPendingDepositId(),                0);  // the remainder is live
        assertEq(_vaultSpUsdc(),                               S_1M);
        _assertQueueConsistent();

        // A second partial cancel to a different recipient, then the rest.
        vm.prank(alice);
        uint256 cancelId2 = vault.requestDepositCancellation(id, dave, 100e9);
        assertEq(cancelId2,  1);
        assertEq(_shares(id), 454_532_691_143);
        assertEq(vault.firstPendingDepositId(), 0);

        vm.prank(alice);
        uint256 cancelId3 = vault.requestDepositCancellation(id, alice, 454_532_691_143);
        assertEq(cancelId3, 2);
        (owner, recipient, shares) = _rawEntry(DEPOSIT_SLOT, id);
        assertEq(owner,     address(0));  // fully cancelled: deleted (src 435)
        assertEq(recipient, address(0));
        assertEq(shares,    0);
        assertEq(vault.firstPendingDepositId(),                1);  // self-skip
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
        _assertQueueConsistent();

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(0, alice, carol, 400e9, 419_053_222_284);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(1, alice, dave, 100e9, 104_763_305_571);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(
            2, alice, alice, 454_532_691_143, 476_183_472_143
        );
        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(carol), 419_053_222_284);
        assertEq(usdc.balanceOf(dave),  104_763_305_571);
        assertEq(usdc.balanceOf(alice), 476_183_472_143);
        assertEq(usdc.balanceOf(bob),   0);
        // Three floors lose 1 wei more than one here (at most 2).
        assertEq(419_053_222_284 + 104_763_305_571 + 476_183_472_143, A_1M - 1);
        assertEq(_vaultSpUsdc(), 0);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
        _assertQueueConsistent();
    }

    // A partial cancel of a live head keeps it live: the walk stops on it and later depositors
    // stay queued; the operator fills the remainder in order.
    function test_requestDepositCancellation_partialAtHeadKeepsHeadLive() public {
        (uint256 a, , ) = _queueThree();

        _cancelPart(alice, a, alice, S_1M / 2);
        assertEq(_shares(a),                          S_1M - S_1M / 2);
        assertEq(vault.firstPendingDepositId(),       0);
        assertEq(vault.pendingDepositSavingsShares(), S_1M - S_1M / 2 + 2 * S_100K);
        assertFalse(_nextRequestIsInstant());
        _assertHeadOnLiveOrEnd();

        uint256 d = _deposit(dave, HUNDRED_K);
        assertEq(d, 3);
        assertEq(vault.balanceOf(dave), 0);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        (, uint256 aliceShares) = _fillOf(S_1M - S_1M / 2);
        assertEq(vault.balanceOf(alice), aliceShares);
        assertEq(vault.balanceOf(bob),   SH_100K);
        assertEq(vault.balanceOf(carol), SH_100K);
        assertEq(vault.balanceOf(dave),  SH_100K);
        assertEq(vault.firstPendingDepositId(), 4);
        _assertQueueConsistent();
    }

    function test_requestDepositCancellation_atHead() public {
        (uint256 a, , ) = _queueThree();

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRequest(a, 0, alice, S_1M);

        uint256 cancelId = _cancel(alice, a);

        // Intermediate state: entry moved, counters moved, nothing paid, head walked to bob.
        assertEq(cancelId,                                     0);
        assertEq(_shares(a),                                   0);
        (address cOwner, address cRecipient, uint256 cShares) = _cancelledDepositRequest(cancelId);
        assertEq(cOwner,     alice);
        assertEq(cRecipient, alice);
        assertEq(cShares,    S_1M);
        assertEq(vault.pendingDepositSavingsShares(),          2 * S_100K);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
        assertEq(vault.firstPendingDepositCancellationId(),    0);
        assertEq(vault.firstPendingDepositId(),                1);  // self-skip to bob (live)
        assertEq(vault.balanceOf(bob),                         0);  // budget 0: bob not filled
        assertEq(usdc.balanceOf(alice),                        0);
        assertEq(_vaultSpUsdc(),                               S_1M + 2 * S_100K);
        _assertHeadOnLiveOrEnd();
        _assertQueueConsistent();

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(0, alice, alice, S_1M, A_1M);

        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),                        A_1M);  // 1 wei lost to R10
        assertEq(_cancelledShares(cancelId),                   0);     // deleted after refund
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),    1);
        assertEq(_vaultSpUsdc(),                               2 * S_100K);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice),        0);
        assertEq(vault.balanceOf(bob),          SH_100K);
        assertEq(vault.balanceOf(carol),        SH_100K);
        assertEq(vault.firstPendingDepositId(), 3);
        _assertQueueConsistent();
    }

    function test_requestDepositCancellation_inMiddle() public {
        (, uint256 b, ) = _queueThree();

        _cancelDepositAndSettle(bob, b);

        assertEq(usdc.balanceOf(bob),                 A_100K);
        assertEq(_shares(b),                          0);
        assertEq(vault.pendingDepositSavingsShares(), S_1M + S_100K);
        assertEq(vault.firstPendingDepositId(),       0);  // head is live, not moved

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice),        SH_1M);
        assertEq(vault.balanceOf(bob),          0);
        assertEq(vault.balanceOf(carol),        SH_100K);
        assertEq(vault.firstPendingDepositId(), 3);
        _assertQueueConsistent();
    }

    function test_requestDepositCancellation_atTail() public {
        (, , uint256 c) = _queueThree();

        _cancelDepositAndSettle(carol, c);

        assertEq(usdc.balanceOf(carol),               A_100K);
        assertEq(vault.pendingDepositSavingsShares(), S_1M + S_100K);
        assertEq(vault.firstPendingDepositId(),       0);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice),        SH_1M);
        assertEq(vault.balanceOf(bob),          SH_100K);
        assertEq(vault.balanceOf(carol),        0);
        assertEq(vault.firstPendingDepositId(), 3);  // the loop walks past the zeroed tail entry
        _assertQueueConsistent();
    }

    function test_requestDepositCancellation_afterPartialFillRefundsRemainderOnly() public {
        uint256 id = _queue(alice, ONE_M);
        _setCapacity(type(uint128).max);
        _processDeposits(400e9, 10);

        assertEq(vault.balanceOf(alice), 415_032_483_768);
        assertEq(_shares(id),            554_532_691_143);

        // Cancelling more than the remainder is rejected; the remainder itself is fine.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, alice, S_1M);

        _cancelDepositAndSettle(alice, id);

        // Refund = spUSDC.redeem(554_532_691_143) = floor(554_532_691_143 * chi_s / RAY)
        assertEq(usdc.balanceOf(alice),               580_946_777_714);
        assertEq(vault.balanceOf(alice),              415_032_483_768);  // filled part stays
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(),                      400e9);
        assertEq(vault.firstPendingDepositId(),       1);  // self-skip past the dead slot

        assertTrue(_nextRequestIsInstant());
        _deposit(bob, HUNDRED_K);
        assertEq(vault.balanceOf(bob),          SH_100K);
        assertEq(vault.firstPendingDepositId(), 2);
        _assertQueueConsistent();
    }

    // Round 6 (new): cancellations are not pause-gated (src 405-446 has no `whenNotPaused`), and
    // the self-skip walk runs while paused too (only the external `processPendingDeposits` is
    // gated). The refund settles while paused as well.
    function test_fixed_requestDepositCancellation_worksWhilePaused() public {
        (uint256 a, uint256 b, ) = _queueThree();
        _pause();

        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingDeposits(type(uint256).max, 10);

        _cancelPart(bob, b, bob, S_100K / 2);
        assertEq(_shares(b), S_100K - S_100K / 2);

        uint256 cancelId = _cancel(alice, a);
        assertEq(cancelId,                            1);
        assertEq(vault.firstPendingDepositId(),       1);  // walk ran while paused
        assertEq(vault.pendingDepositSavingsShares(), S_100K - S_100K / 2 + S_100K);
        assertTrue(vault.paused());

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob),   spUsdc.convertToAssets(S_100K / 2));
        assertEq(usdc.balanceOf(alice), A_1M);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        _assertQueueConsistent();

        _unpause();
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(carol), SH_100K);
        assertEq(vault.firstPendingDepositId(), 3);
        _assertQueueConsistent();
    }

    function test_processPendingDeposits_skipsRunOfCancelledEntries() public {
        (uint256 a, uint256 b, ) = _queueThree();

        _cancel(alice, a);
        assertEq(vault.firstPendingDepositId(), 1);
        _cancel(bob, b);
        assertEq(vault.firstPendingDepositId(), 2);

        assertEq(vault.pendingDepositSavingsShares(),          S_100K);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M + S_100K);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(carol),        SH_100K);
        assertEq(vault.firstPendingDepositId(), 3);
        _assertQueueConsistent();

        // Cancelled refunds settle in order, ids 0 then 1.
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), A_1M);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),   A_100K);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        _assertQueueConsistent();
    }

    // INFO (DQ-3): dead slots behind a live head (cancelled entries, 1-wei ghosts) count toward
    // `maxRequests_` (src 870 budgets by index, 875 `continue` does not refund the slot).
    function test_processPendingDeposits_ghostsAndCancelledEntriesConsumeMaxRequests() public {
        _setCapacity(0);
        uint256 a = _deposit(alice, HUNDRED_K);   // 0 live
        _ghost(bob);                              // 1 dead (0 shares)
        uint256 c = _deposit(carol, HUNDRED_K);   // 2
        _cancel(carol, c);                        // 2 dead
        uint256 d = _deposit(dave, HUNDRED_K);    // 3 live
        assertEq(vault.firstPendingDepositId(), 0);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 3);   // alice, then the budget is spent on 1 and 2

        assertEq(vault.balanceOf(alice),        SH_100K);
        assertEq(vault.balanceOf(dave),         0);
        assertEq(_shares(a),                    0);
        assertEq(_shares(d),                    S_100K);
        assertEq(vault.firstPendingDepositId(), 3);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(dave),         SH_100K);
        assertEq(vault.firstPendingDepositId(), 4);
        _assertQueueConsistent();
    }

    function test_processPendingDeposits_cancelledEntriesConsumeMaxRequests() public {
        (, uint256 b, ) = _queueThree();

        _cancel(bob, b);
        assertEq(vault.firstPendingDepositId(), 0);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 2);

        // Budget of 2: alice filled, bob's zeroed slot consumed the second, carol untouched.
        assertEq(vault.balanceOf(alice),        SH_1M);
        assertEq(vault.balanceOf(carol),        0);
        assertEq(vault.firstPendingDepositId(), 2);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(carol),        SH_100K);
        assertEq(vault.firstPendingDepositId(), 3);
        _assertQueueConsistent();
    }

    /**********************************************************************************************/
    /*** H5: FIFO fairness                                                                      ***/
    /**********************************************************************************************/

    function test_processPendingDeposits_fifoFiveDepositorsCapacityForTwoAndAHalf() public {
        uint256 a = _queue(alice,   HUNDRED_K);
        uint256 b = _deposit(bob,   HUNDRED_K);
        uint256 c = _deposit(carol, HUNDRED_K);
        uint256 d = _deposit(dave,  HUNDRED_K);
        uint256 e = _deposit(eve,   HUNDRED_K);

        assertEq(vault.pendingDepositSavingsShares(), 5 * S_100K);

        uint256 cap = 2 * SH_100K + SH_100K / 2;  // 247_601_296_025
        _setCapacity(cap);
        assertEq(_remainingForCapacity(cap), 238_633_172_783);
        assertEq(238_633_172_783 - 2 * S_100K, 47_726_634_555);

        _processDeposits(type(uint256).max, 100);

        assertEq(vault.balanceOf(alice), SH_100K);
        assertEq(vault.balanceOf(bob),   SH_100K);
        assertEq(vault.balanceOf(carol), 49_520_259_202);  // fill of 47_726_634_555 spUSDC shares
        assertEq(vault.balanceOf(dave),  0);
        assertEq(vault.balanceOf(eve),   0);

        assertEq(_shares(a), 0);
        assertEq(_shares(b), 0);
        assertEq(_shares(c), S_100K - 47_726_634_555);
        assertEq(_shares(c), 47_726_634_559);
        assertEq(_shares(d), S_100K);
        assertEq(_shares(e), S_100K);

        assertEq(vault.firstPendingDepositId(),       2);
        assertEq(vault.pendingDepositSavingsShares(), 47_726_634_559 + 2 * S_100K);
        assertEq(vault.totalSupply(),                 2 * SH_100K + 49_520_259_202);
        assertEq(vault.availableCapacity(),           cap - vault.totalSupply());
        assertEq(vault.availableCapacity(),           3);
        _assertQueueConsistent();

        // Even a later generous call cannot fill dave before carol: raise capacity for exactly
        // carol's remainder and see dave/eve untouched.
        (, uint256 carolRest) = _fillOf(47_726_634_559);
        assertEq(carolRest, 49_520_259_206);
        assertEq(_remainingForCapacity(carolRest),     47_726_634_557);  // 2 short (src 864)
        assertEq(_remainingForCapacity(carolRest + 2), 47_726_634_559);
        _setCapacity(vault.totalSupply() + carolRest + 2);
        _processDeposits(type(uint256).max, 100);

        assertEq(vault.balanceOf(carol),        49_520_259_202 + 49_520_259_206);
        assertEq(vault.balanceOf(dave),         0);
        assertEq(vault.balanceOf(eve),          0);
        assertEq(vault.firstPendingDepositId(), 3);
        _assertQueueConsistent();
    }

    /**********************************************************************************************/
    /*** H6: yield while queued                                                                 ***/
    /**********************************************************************************************/

    function test_processPendingDeposits_queuedDepositorReceivesSpUsdcYield() public {
        uint256 id = _queue(alice, ONE_M);
        assertEq(_shares(id), S_1M);

        _setSpUsdcVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);

        // spPRIME index is frozen; spUSDC index grew ~5%.
        assertEq(vault.nowChi(), 1.009687768242461209408770821e27);
        uint256 grownAssets = spUsdc.convertToAssets(S_1M);
        assertEq(spUsdc.nowChi(), 1.100014708497471657375201112e27);
        assertEq(grownAssets, 1_049_999_999_998);  // 999_999_999_999 * 1.05 - rounding

        uint256 expectedShares = vault.convertToShares(grownAssets);
        assertEq(expectedShares, 1_039_925_443_313);

        uint256 spUsdcBefore = _vaultSpUsdc();
        _setCapacity(type(uint128).max);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(id, alice, alice, S_1M, grownAssets, expectedShares);

        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice),              expectedShares);
        assertEq(vault.balanceOf(alice) - SH_1M,      49_520_259_204);  // yield captured in spPRIME
        assertEq(vault.assetsOf(alice),               1_049_999_999_997);
        assertEq(_vaultSpUsdc(),                      spUsdcBefore);
        assertEq(_vaultSpUsdc(),                      S_1M);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        _assertQueueConsistent();
    }

    function test_requestDepositCancellation_refundsWithSpUsdcYield() public {
        uint256 id = _queue(alice, ONE_M);

        _setSpUsdcVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);
        assertEq(spUsdc.nowChi(), 1.100014708497471657375201112e27);

        uint256 cancelId = _cancel(alice, id);
        assertEq(_cancelledShares(cancelId), S_1M);  // the entry is in spUSDC shares, so the
                                                     // grown value travels with it

        // spUSDC holds only the 1_000_000e6 principal. The settlement budget is
        // `spUSDC.maxRedeem(vault)` (src 908) = floor(1_000_000e6 * RAY / chi_s) =
        // 909_078_753_470 shares, so it pays what the liquidity allows and the remainder waits at
        // the cancelled head.
        assertEq(spUsdc.maxRedeem(address(vault)), 909_078_753_470);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(
            cancelId, alice, alice, 909_078_753_470, 999_999_999_999
        );

        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),                        999_999_999_999);
        assertEq(usdc.balanceOf(address(spUsdc)),              1);
        assertEq(_cancelledShares(cancelId),                   45_453_937_673);
        assertEq(vault.firstPendingDepositCancellationId(),    cancelId);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 45_453_937_673);
        assertEq(_vaultSpUsdc(),                               45_453_937_673);
        _assertQueueConsistent();

        // 1 wei of USDC converts to 0 shares: a second pass is a silent no-op.
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice),      999_999_999_999);
        assertEq(_cancelledShares(cancelId), 45_453_937_673);

        _returnSpUsdcLiquidity(60_000e6);  // spUSDC needs USDC to pay the grown value

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(
            cancelId, alice, alice, 45_453_937_673, 49_999_999_999
        );

        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),                        1_049_999_999_998);  // = one payout
        assertEq(_cancelledShares(cancelId),                   0);
        assertEq(vault.firstPendingDepositCancellationId(),    cancelId + 1);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(),                               0);
        _assertQueueConsistent();
    }

    // Round 5 (R3-1 fixed): `adjustTotalAssets` (src 262-283, LOSS_MANAGER_ROLE) requires
    // `paused` (267) and sets chi = (totalAssets + delta) * RAY / totalSupply. While paused no
    // deposit can be requested (377), so the instant-fill sandwich inside the pause is closed.
    // Queued spUSDC is not in `totalAssets` (no shares minted yet), so a gain adjusted while a
    // deposit is queued goes to the holders only: the queued depositor is filled later at the
    // higher chi and gets fewer spPRIME for the same spUSDC, worth exactly what he brought.
    //
    // Residual (R5-2, open): `pause` is a separate PAUSER tx, so a deposit instant-filled one
    // block BEFORE the pause (carol) is a holder and captures the gain: +5_000_000_000 on
    // 100_000e6 for a 10_000e6 gain over 200k of supply, the full pro-rata share, for one block
    // of exposure.
    function test_fixed_adjustTotalAssetsRequiresPause_queuedDepositorExcludedFromGain() public {
        _deposit(alice, HUNDRED_K);           // holder
        _warp(12);
        _deposit(carol, HUNDRED_K);           // instant fill one block before the pause
        uint256 id = _queue(bob, HUNDRED_K);  // queued: capacity frozen at totalSupply

        assertEq(vault.totalSupply(),   2 * SH_100K);
        assertEq(vault.totalAssets(),   199_999_999_997);
        assertEq(vault.assetsOf(alice), 99_999_999_998);
        assertEq(vault.assetsOf(carol), 99_999_999_998);
        assertEq(_shares(id),           S_100K);

        _warp(12);

        // Unpaused: the adjustment is refused.
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(10_000e6);

        _pause();

        // Paused: no deposit request, so nobody can front-run the adjustment inside the pause.
        _fund(dave, HUNDRED_K);
        vm.prank(dave);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDeposit(HUNDRED_K, dave, 0);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.TotalAssetsAdjusted(
            uint192(1.060172156650366224592543507e27), 10_000e6
        );
        vm.prank(lossManager);
        vault.adjustTotalAssets(10_000e6);

        _unpause();

        // chi = (199_999_999_997 + 10_000e6) * RAY / 198_081_036_820
        assertEq(vault.nowChi(),        1.060172156650366224592543507e27);
        assertEq(vault.totalAssets(),   209_999_999_996);
        assertEq(vault.assetsOf(alice), 104_999_999_998);  // +5_000_000_000 each
        assertEq(vault.assetsOf(carol), 104_999_999_998);
        assertEq(_shares(id),           S_100K);           // bob's entry is untouched

        _setCapacity(type(uint128).max);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(id, bob, bob, S_100K, A_100K, 94_324_303_248);

        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(bob),           94_324_303_248);
        assertEq(SH_100K - vault.balanceOf(bob), 4_716_215_162);   // fewer shares than alice/carol
        assertEq(vault.assetsOf(bob),            99_999_999_998);  // worth his deposit, no gain
        assertEq(vault.assetsOf(alice),          104_999_999_998);
        assertEq(vault.assetsOf(carol),          104_999_999_998);
        assertEq(vault.totalAssets(),            309_999_999_995);

        // The backing has not grown: 300k USDC of spUSDC against 310k of claims until the gain
        // actually arrives (same notional-index gap as RQ-5).
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 299_999_999_998);
        _assertQueueConsistent();
    }

    /**********************************************************************************************/
    /*** H7: recipient edge cases                                                               ***/
    /**********************************************************************************************/

    function test_requestDeposit_recipientNotOwnerInstant() public {
        _fund(alice, ONE_M);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(0, alice, bob, S_1M, A_1M, SH_1M);

        vm.prank(alice);
        vault.requestDeposit(ONE_M, bob, 0);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob),   SH_1M);
    }

    function test_requestDeposit_recipientNotOwnerQueuedFillAndCancel() public {
        _setCapacity(0);
        _fund(alice, 2 * ONE_M);

        vm.prank(alice);
        uint256 id1 = vault.requestDeposit(ONE_M, bob, 0);
        vm.prank(alice);
        uint256 id2 = vault.requestDeposit(ONE_M, bob, 0);

        (address owner, address recipient, ) = _depositRequest(id1);
        assertEq(owner,     alice);
        assertEq(recipient, bob);

        // Fill the first: shares go to the recipient (capacity + 2 for the src 864 rounding).
        _setCapacity(SH_1M + 2);
        _processDeposits(type(uint256).max, 1);

        assertEq(vault.balanceOf(bob),   SH_1M);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(_shares(id1),           0);
        assertEq(_shares(id2),           S_1M);

        // Bob (the recipient) cannot cancel the second.
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id2, bob, S_1M);

        // Owner cancels and picks the refund address, here carol.
        vm.prank(alice);
        uint256 cancelId = vault.requestDepositCancellation(id2, carol, S_1M);

        (address cOwner, address cRecipient, uint256 cShares) = _cancelledDepositRequest(cancelId);
        assertEq(cOwner,     alice);
        assertEq(cRecipient, carol);
        assertEq(cShares,    S_1M);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(cancelId, alice, carol, S_1M, A_1M);

        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(carol), A_1M);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(_vaultSpUsdc(),        S_1M);
        _assertQueueConsistent();
    }

    // Round 5 (V2-2 / F-1 / DQ-7 fixed): the guardian cancel path is gone. The pauser naming the
    // owner, itself, the share recipient or a stranger gets `NotRequestOwner`, and the entry is
    // untouched by every failed attempt. Only the owner can, to any non-zero non-vault address.
    function test_fixed_requestDepositCancellation_pauserCannotCancel() public {
        _setCapacity(0);
        _fund(alice, ONE_M);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(ONE_M, bob, 0);

        address[4] memory named = [alice, pauser, bob, carol];
        for (uint256 i; i < 4; ++i) {
            vm.prank(pauser);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.requestDepositCancellation(id, named[i], S_1M);
        }

        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);
        assertEq(vault.pendingDepositSavingsShares(),          S_1M);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_cancelledQueueLength(), 0);
        assertEq(vault.firstPendingDepositId(), 0);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRequest(id, 0, carol, S_1M);
        vm.prank(alice);
        uint256 cancelId = vault.requestDepositCancellation(id, carol, S_1M);

        (address cOwner, address cRecipient, uint256 cShares) = _cancelledDepositRequest(cancelId);
        assertEq(cOwner,     alice);
        assertEq(cRecipient, carol);
        assertEq(cShares,    S_1M);
        assertEq(_shares(id), 0);
        assertEq(vault.firstPendingDepositId(), 1);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(cancelId, alice, carol, S_1M, A_1M);
        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(carol),  A_1M);
        assertEq(usdc.balanceOf(alice),  0);
        assertEq(usdc.balanceOf(bob),    0);
        assertEq(usdc.balanceOf(pauser), 0);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(), 0);
        _assertQueueConsistent();
    }

    // The owner keeps free choice of the refund address and can repoint it afterwards because
    // the cancelled entry's `owner` is the depositor (src 428). Nobody else can (V2-1 fixed).
    function test_fixed_updateDepositCancellationRecipient_ownerOnly_andRepoints() public {
        _setCapacity(0);
        _fund(alice, 2 * ONE_M);
        vm.prank(alice);
        uint256 id1 = vault.requestDeposit(ONE_M, bob, 0);
        vm.prank(alice);
        uint256 id2 = vault.requestDeposit(ONE_M, bob, 0);

        vm.prank(alice);
        uint256 c1 = vault.requestDepositCancellation(id1, carol, S_1M);
        (, address r1, ) = _cancelledDepositRequest(c1);
        assertEq(r1, carol);

        vm.prank(alice);
        uint256 c2 = vault.requestDepositCancellation(id2, alice, S_1M);

        address[4] memory strangers = [pauser, bob, admin, operator];
        for (uint256 i; i < 4; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.updateDepositCancellationRecipient(c2, strangers[i]);
        }

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.updateDepositCancellationRecipient(c2, address(0));

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.updateDepositCancellationRecipient(c2 + 1, dave);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRecipientUpdated(c2, dave);
        vm.prank(alice);
        vault.updateDepositCancellationRecipient(c2, dave);
        (address o2, address r2, uint256 s2) = _cancelledDepositRequest(c2);
        assertEq(o2, alice);
        assertEq(r2, dave);
        assertEq(s2, S_1M);

        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(carol), A_1M);
        assertEq(usdc.balanceOf(dave),  A_1M);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        _assertQueueConsistent();
    }

    // The recipient is read at every fill (src 890), so a repoint between a partial fill and the
    // rest sends the remainder to the new recipient; the first part stays with the old one.
    function test_updateDepositRecipient_afterPartialFillRedirectsRemainder() public {
        _setCapacity(0);
        _fund(alice, ONE_M);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(ONE_M, bob, 0);

        // Capacity for exactly SH_100K shares: fills S_100K-ish spUSDC shares.
        _setCapacity(SH_100K);
        uint256 part = _remainingForCapacity(SH_100K);
        (uint256 partAssets, uint256 partShares) = _fillOf(part);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(id, alice, bob, part, partAssets, partShares);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(bob), partShares);
        assertEq(_shares(id), S_1M - part);
        assertEq(vault.firstPendingDepositId(), 0);  // partial fill keeps the head (src 894)

        vm.prank(alice);
        vault.updateDepositRecipient(id, carol);

        _setCapacity(type(uint128).max);
        (uint256 restAssets, uint256 restShares) = _fillOf(S_1M - part);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(id, alice, carol, S_1M - part, restAssets, restShares);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(bob),   partShares);
        assertEq(vault.balanceOf(carol), restShares);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(_shares(id), 0);
        assertEq(vault.firstPendingDepositId(), 1);
        assertLe(SH_1M - (partShares + restShares), 2);  // DQ-6 chunk loss
        _assertQueueConsistent();
    }

    // The owner can redirect a queued entry's fill (src 482-493, owner-only).
    function test_updateDepositRecipient_ownerRedirectsQueuedFill() public {
        uint256 id = _queue(alice, ONE_M);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositRecipientUpdated(id, carol);

        vm.prank(alice);
        vault.updateDepositRecipient(id, carol);

        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, carol);
        assertEq(shares,    S_1M);

        _setCapacity(type(uint128).max);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(id, alice, carol, S_1M, A_1M, SH_1M);

        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(carol), SH_1M);
        assertEq(vault.balanceOf(alice), 0);
        _assertQueueConsistent();
    }

    // A stranger, the current recipient and the pauser cannot repoint a queued deposit
    // (`NotRequestOwner`, src 490); the owner cannot repoint to zero or the vault.
    function test_updateDepositRecipient_revertsNotOwner() public {
        _setCapacity(0);
        _fund(alice, ONE_M);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(ONE_M, bob, 0);

        address[3] memory callers = [carol, bob, pauser];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.updateDepositRecipient(id, callers[i]);
        }

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.updateDepositRecipient(id, address(0));

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositRecipient(id, address(vault));

        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);
        assertEq(vault.balanceOf(bob), 0);
    }

    // A filled or cancelled (deleted) entry reverts `NoRequest` (src 489) for everyone, its
    // former owner included; an index at or past the length is `InvalidRequestId` (485). The
    // cancelled copy lives in the cancellation queue and is owner-only there as well (495-512).
    function test_updateDepositRecipient_revertsDeadEntryAndOutOfRange() public {
        uint256 filled = _deposit(alice, HUNDRED_K);  // instant fill: entry deleted (src 896)
        uint256 queued = _queue(bob, HUNDRED_K);
        uint256 cancelId = _cancel(bob, queued);      // cancelled: entry deleted (src 435)

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositRecipient(filled, carol);

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositRecipient(queued, carol);

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.updateDepositRecipient(queued + 1, carol);

        vm.prank(carol);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(cancelId, carol);

        vm.prank(bob);
        vault.updateDepositCancellationRecipient(cancelId, carol);
        (address cOwner, address cRecipient, uint256 cShares) = _cancelledDepositRequest(cancelId);
        assertEq(cOwner,     bob);
        assertEq(cRecipient, carol);
        assertEq(cShares,    S_100K);

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(carol), A_100K);
        assertEq(usdc.balanceOf(bob),   0);
        _assertQueueConsistent();
    }

    // Every event of an instant fill with exact arguments and in order (src 396-397, 892, 1031).
    function test_requestDeposit_instantFillEventsInOrder() public {
        _fund(alice, HUNDRED_K);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Referral(42, 0, alice, bob, HUNDRED_K);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositRequest(0, alice, bob, HUNDRED_K, S_100K);
        vm.expectEmit(address(vault));
        emit Transfer(address(0), bob, SH_100K);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(0, alice, bob, S_100K, A_100K, SH_100K);

        vm.prank(alice);
        vault.requestDeposit(HUNDRED_K, bob, 42);

        assertEq(vault.balanceOf(bob), SH_100K);
    }

    /**********************************************************************************************/
    /*** H8: pause                                                                              ***/
    /**********************************************************************************************/

    // Round 6: pause gates `requestDeposit` and `processPendingDeposits` only. Cancellations,
    // their settlement and `take()` all run while paused (R5-B wanted the first two).
    function test_pause_blocksRequestAndFillButNotCancelSettleOrTake() public {
        uint256 id = _queue(alice, ONE_M);
        uint256 c  = _deposit(carol, HUNDRED_K);
        _setCapacity(type(uint128).max);
        _fund(bob, HUNDRED_K);

        _pause();

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDeposit(HUNDRED_K, bob, 0);

        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingDeposits(type(uint256).max, 10);

        // Cancel (owner only, still) and settle both work while paused.
        vm.prank(pauser);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(c, pauser, S_100K);

        uint256 cancelId = _cancel(carol, c);
        assertEq(_cancelledShares(cancelId), S_100K);
        assertEq(vault.firstPendingDepositId(), 0);  // alice is live at the head

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(carol), A_100K);

        // take() is not gated: the queued depositor's backing can leave during a pause (F-7).
        _take(S_1M);
        assertEq(_vaultSpUsdc(),          0);
        assertEq(spUsdc.balanceOf(taker), S_1M);
        assertEq(_shares(id),             S_1M);

        _unpause();
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(alice), SH_1M);
        _assertQueueConsistent();
    }

    /**********************************************************************************************/
    /*** H9: bounds                                                                             ***/
    /**********************************************************************************************/

    function test_processPendingDeposits_maxRequestsHonouredExactly() public {
        (uint256 a, uint256 b, uint256 c) = _queueThree();
        _setCapacity(type(uint128).max);

        _processDeposits(type(uint256).max, 2);

        assertEq(vault.balanceOf(alice),        SH_1M);
        assertEq(vault.balanceOf(bob),          SH_100K);
        assertEq(vault.balanceOf(carol),        0);
        assertEq(_shares(a),                    0);
        assertEq(_shares(b),                    0);
        assertEq(_shares(c),                    S_100K);
        assertEq(vault.firstPendingDepositId(), 2);
        _assertQueueConsistent();

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(carol),        SH_100K);
        assertEq(vault.firstPendingDepositId(), 3);

        // maxRequests_ larger than the queue is clamped: head == length, no revert.
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingDepositId(), 3);
        _assertQueueConsistent();
    }

    function test_processPendingDeposits_maxSavingsSharesHonouredExactlyAcrossEntries() public {
        (uint256 a, uint256 b, uint256 c) = _queueThree();
        _setCapacity(type(uint128).max);

        // Exactly alice + 10 wei of bob.
        _processDeposits(S_1M + 10, 10);

        (uint256 dustAssets, uint256 dustShares) = _fillOf(10);
        assertEq(dustAssets, 10);
        assertEq(dustShares, 9);

        assertEq(vault.balanceOf(alice),              SH_1M);
        assertEq(vault.balanceOf(bob),                9);
        assertEq(_shares(a),                          0);
        assertEq(_shares(b),                          S_100K - 10);
        assertEq(_shares(c),                          S_100K);
        assertEq(vault.pendingDepositSavingsShares(), 2 * S_100K - 10);
        assertEq(vault.firstPendingDepositId(),       1);
        _assertQueueConsistent();
    }

    function test_processPendingDeposits_maxSavingsSharesZeroIsNoopOnLiveHead() public {
        _queueThree();
        _setCapacity(type(uint128).max);

        _processDeposits(0, 10);

        assertEq(vault.totalSupply(),                 0);
        assertEq(vault.pendingDepositSavingsShares(), S_1M + 2 * S_100K);
        assertEq(vault.firstPendingDepositId(),       0);
    }

    function test_processPendingDeposits_maxRequestsZeroIsNoop() public {
        (uint256 a, , ) = _queueThree();
        _cancel(alice, a);  // head on bob (live)... but also dead slot behind nothing to walk
        _setCapacity(type(uint128).max);

        _processDeposits(type(uint256).max, 0);

        assertEq(vault.totalSupply(),                 0);
        assertEq(vault.pendingDepositSavingsShares(), 2 * S_100K);
        assertEq(vault.firstPendingDepositId(),       1);
    }

    function test_processPendingDeposits_emptyQueueIsNoop() public {
        _processDeposits(type(uint256).max, 10);
        _processDeposits(0, 0);

        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(vault.totalSupply(),           0);

        // Fully drained queue is a no-op too.
        _deposit(alice, ONE_M);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(vault.totalSupply(), SH_1M);
    }

    function test_processPendingDeposits_notOperator() public {
        _queue(alice, ONE_M);
        address[3] memory callers = [alice, admin, pauser];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", callers[i], OPERATOR_ROLE
            ));
            vault.processPendingDeposits(type(uint256).max, 10);
        }
    }

    /**********************************************************************************************/
    /*** H10: dust boundary (R5-15 / F-4, open)                                                 ***/
    /**********************************************************************************************/

    // At the harness indexes a fill of exactly 1 spUSDC share converts to assets_ = floor(1 *
    // chi_s / RAY) = 1, then shares_ = floor(1 * RAY / chi_p) = 0 (src 883-884). 2 spUSDC shares
    // already mint 1 spPRIME share, so remaining_ == 1 is the only dust value. Reachable via
    // maxSavingsShares_ == 1 or via availableCapacity() == 2 (-> remaining_ == 1). The test
    // asserts the open behaviour: spUSDC deducted from the head request, 0 shares minted.
    function test_BUG_dustFillMintsZeroShares() public {
        uint256 id = _queue(alice, ONE_M);
        _setCapacity(type(uint128).max);

        (uint256 a1, uint256 s1) = _fillOf(1);
        (uint256 a2, uint256 s2) = _fillOf(2);
        assertEq(a1, 1); assertEq(s1, 0);  // boundary: 1 share -> 0 spPRIME
        assertEq(a2, 2); assertEq(s2, 1);  // 2 shares -> 1 spPRIME

        // Path 1: maxSavingsShares_ == 1.
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(id, alice, alice, 1, 1, 0);

        _processDeposits(1, 10);

        assertEq(vault.balanceOf(alice),              0);
        assertEq(vault.totalSupply(),                 0);
        assertEq(_shares(id),                         S_1M - 1);
        assertEq(vault.pendingDepositSavingsShares(), S_1M - 1);
        assertEq(vault.firstPendingDepositId(),       0);

        // Path 2: availableCapacity() == 2 -> remaining_ == 1. Repeatable every call.
        _setCapacity(2);
        assertEq(_remainingForCapacity(2), 1);
        assertEq(_remainingForCapacity(1), 0);  // capacity 1 is a no-op

        _processDeposits(type(uint256).max, 10);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice),              0);
        assertEq(vault.totalSupply(),                 0);
        assertEq(_shares(id),                         S_1M - 3);
        assertEq(vault.pendingDepositSavingsShares(), S_1M - 3);

        // The 3 spUSDC shares (3 wei USDC, ~3.14e-6 USD) stay in the vault as unbacked equity.
        assertEq(_vaultSpUsdc(), S_1M);

        // The depositor's eventual fill is 4 spPRIME shares short of an instant fill (SH_1M).
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        (, uint256 rest) = _fillOf(S_1M - 3);
        assertEq(rest, 990_405_184_105);
        assertEq(vault.balanceOf(alice), SH_1M - 4);
        _assertQueueConsistent();
    }

    /**********************************************************************************************/
    /*** H12: take() and refund settlement (R5-5 / F-2, open)                                   ***/
    /**********************************************************************************************/

    // Fills never move spUSDC, so the queue processes fine after take() removed its backing and
    // mints shares against backing that already left. The cancel itself always succeeds; the
    // refund settlement is clamped to the vault's spUSDC balance (src 908) and is a silent no-op
    // while the balance is 0.
    function test_BUG_processPendingDeposits_fillsAfterTakeRemovedBacking() public {
        uint256 a = _queue(alice, ONE_M);
        uint256 b = _deposit(bob, HUNDRED_K);

        _takeAll();
        assertEq(_vaultSpUsdc(), 0);
        assertEq(spUsdc.balanceOf(taker), S_1M + S_100K);

        // Bob can cancel; the settlement pays nothing and does not revert.
        uint256 cancelId = _cancel(bob, b);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_100K);

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob),                          0);
        assertEq(_cancelledShares(cancelId),                   S_100K);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_100K);
        assertEq(vault.firstPendingDepositCancellationId(),    0);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);  // no revert

        assertEq(vault.balanceOf(alice),              SH_1M);
        assertEq(vault.totalSupply(),                 SH_1M);
        assertEq(vault.totalAssets(),                 999_999_999_998);  // notional, nothing backs it
        assertEq(_vaultSpUsdc(),                      0);
        assertEq(vault.availableLiquidAssets(),       0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(_shares(a), 0);
        assertEq(_shares(b), 0);
        _assertQueueConsistent();

        // A redeem by alice cannot be paid until the taker returns spUSDC.
        _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.pendingRedeemShares(), SH_1M);

        _returnToVault(S_1M + S_100K);
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), A_1M - 1);  // R8 + R9 rounding
        assertEq(vault.pendingRedeemShares(), 0);

        // Bob's refund settles once backing is back.
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob),                          A_100K);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),    1);
        _assertQueueConsistent();
    }

    // Partial processing after a take: fill proceeds even when the vault holds fewer spUSDC than
    // pendingDepositSavingsShares (nothing checks the balance).
    function test_processPendingDeposits_partialTakeStillFillsFully() public {
        _queue(alice, ONE_M);
        _take(S_1M / 2);
        _setCapacity(type(uint128).max);

        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice), SH_1M);
        assertEq(_vaultSpUsdc(),         S_1M - S_1M / 2);
    }

    // Settling an earlier cancel after a take is paid with a later depositor's backing (F-2);
    // the later depositor's own refund then waits for the taker.
    function test_BUG_earlyCancelAfterTakeStrandsLaterDepositor() public {
        uint256 a = _queue(alice, HUNDRED_K);
        uint256 b = _deposit(bob, HUNDRED_K);

        _take(S_100K);  // one depositor's worth leaves
        assertEq(_vaultSpUsdc(), S_100K);

        _cancelDepositAndSettle(alice, a);  // alice is made whole with bob's spUSDC

        assertEq(usdc.balanceOf(alice), A_100K);
        assertEq(_vaultSpUsdc(),        0);
        assertEq(_shares(b),            S_100K);

        uint256 bobCancel = _cancelDepositAndSettle(bob, b);  // no revert, nothing paid

        assertEq(usdc.balanceOf(bob),                          0);
        assertEq(_cancelledShares(bobCancel),                  S_100K);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_100K);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.firstPendingDepositCancellationId(),    1);
        _assertQueueConsistent();

        _returnToVault(S_100K);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob),                          A_100K);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),    2);
    }

    // The refund settlement is bounded by the vault's spUSDC balance and pays partially, leaving
    // the remainder open at the cancelled head.
    function test_processPendingDepositCancellations_partialRefundWhenBackingShort() public {
        uint256 a = _queue(alice, HUNDRED_K);
        _take(S_100K / 2);
        assertEq(_vaultSpUsdc(), 47_726_634_557);

        uint256 cancelId = _cancel(alice, a);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(
            cancelId, alice, alice, 47_726_634_557, 49_999_999_999
        );

        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),                        49_999_999_999);
        assertEq(_cancelledShares(cancelId),                   47_726_634_557);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 47_726_634_557);
        assertEq(vault.firstPendingDepositCancellationId(),    0);
        assertEq(_vaultSpUsdc(),                               0);
        _assertQueueConsistent();

        // A second call with nothing in the vault is a no-op, not a revert.
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 49_999_999_999);

        _returnToVault(47_726_634_557);
        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),                        2 * 49_999_999_999);  // 1 wei < A_100K
        assertEq(_cancelledShares(cancelId),                   0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),    1);
        _assertQueueConsistent();
    }

    // Capacity -> spUSDC conversion (src 864) rounds down twice, so filling S spUSDC shares needs
    // capacity for their spPRIME value + 2. With +2 everything fills.
    function test_requestDeposit_instantFillCapacityBoundary() public {
        assertEq(_remainingForCapacity(SH_1M + 2), S_1M);
        assertEq(_remainingForCapacity(SH_1M + 1), S_1M - 1);
        assertEq(_remainingForCapacity(SH_1M),     S_1M - 1);

        _setCapacity(SH_1M + 2);
        uint256 id = _deposit(alice, ONE_M);

        assertEq(vault.balanceOf(alice),              SH_1M);
        assertEq(_shares(id),                         0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.availableCapacity(),           2);
        assertEq(vault.firstPendingDepositId(),       1);

        // The 2 leftover capacity shares convert to 1 spUSDC share: bob's deposit of 2 USDC
        // (1 spUSDC share) is filled with 0 spPRIME (F-4) and bob's entry is deleted.
        assertEq(spUsdc.convertToShares(2), 1);
        uint256 bobId = _deposit(bob, 2);
        assertEq(vault.balanceOf(bob),          0);
        assertEq(_shares(bobId),                0);
        assertEq(usdc.balanceOf(bob),           0);
        assertEq(_vaultSpUsdc(),                S_1M + 1);
        assertEq(vault.firstPendingDepositId(), 2);

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(bobId, bob, 1);
        _assertQueueConsistent();
    }

    // LOW (DQ-1, open): a deposit sized to exactly fit the capacity is 1 spUSDC share short
    // because of the src 864 double rounding. That 1-share remainder is non-zero, so the walk
    // stops on it and every later depositor is queued regardless of free capacity until the
    // operator processes the dust, which mints 0 (F-4).
    function test_BUG_exactFitCapacityLeavesDustThatBlocksInstantFills() public {
        _setCapacity(SH_1M);
        uint256 aliceId = _deposit(alice, ONE_M);

        assertEq(vault.balanceOf(alice),              SH_1M - 2);
        assertEq(_shares(aliceId),                    1);
        assertEq(vault.pendingDepositSavingsShares(), 1);
        assertEq(vault.availableCapacity(),           2);
        assertEq(vault.firstPendingDepositId(),       0);

        // Open capacity for everyone; bob is still fully queued behind 1 wei of alice's dust.
        _setCapacity(type(uint128).max);
        assertFalse(_nextRequestIsInstant());
        uint256 bobId = _deposit(bob, HUNDRED_K);

        assertEq(vault.balanceOf(bob),          0);
        assertEq(_shares(bobId),                S_100K);
        assertEq(vault.firstPendingDepositId(), 0);

        // Operator clears it: alice's 1 share mints 0, bob fills.
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(aliceId, alice, alice, 1, 1, 0);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice),              SH_1M - 2);
        assertEq(vault.balanceOf(bob),                SH_100K);
        assertEq(vault.firstPendingDepositId(),       2);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        _assertQueueConsistent();
    }

    // Same jam, user-triggered (V2-14, open): at full capacity a 4-wei deposit leaves 2 spUSDC
    // shares at the head. The owner cancelling the dust or the operator's fill are the only ways
    // out; on this master the owner's cancel self-skips to the next live entry, so later
    // depositors are still queued behind bob until the operator fills him.
    function test_BUG_fourWeiDepositAtFullCapacityJamsInstantPath() public {
        _setCapacity(SH_1M + 2);
        _deposit(alice, ONE_M);
        assertEq(vault.availableCapacity(),     2);
        assertEq(vault.firstPendingDepositId(), 1);

        // 4 USDC wei -> 3 spUSDC shares; remaining_ for capacity 2 is 1 share -> 2 shares left.
        assertEq(spUsdc.convertToShares(4), 3);
        uint256 evilId = _deposit(eve, 4);
        assertEq(_shares(evilId),               2);
        assertEq(vault.balanceOf(eve),          0);  // the 1-share fill minted 0 (F-4)
        assertEq(vault.firstPendingDepositId(), 1);

        _setCapacity(type(uint128).max);
        uint256 bobId = _deposit(bob, HUNDRED_K);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(_shares(bobId),       S_100K);

        // The pauser cannot clear the jam (owner-only cancel). Eve cancels her own dust: the
        // self-skip walk (budget 0) moves the head onto bob but does not fill him.
        vm.prank(pauser);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(evilId, eve, 2);

        vm.prank(eve);
        vault.requestDepositCancellation(evilId, eve, 2);
        assertEq(vault.firstPendingDepositId(),       2);
        assertEq(vault.pendingDepositSavingsShares(), S_100K);
        assertEq(vault.balanceOf(bob),                0);

        uint256 carolId = _deposit(carol, HUNDRED_K);
        assertEq(carolId, 3);
        assertEq(vault.balanceOf(carol), 0);  // still queued behind bob
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(bob),          SH_100K);
        assertEq(vault.balanceOf(carol),        SH_100K);
        assertEq(vault.firstPendingDepositId(), 4);
        _assertQueueConsistent();

        // Eve's refund for the 2 dust shares: floor(2 * chi_s / RAY) = 2 wei of her 4.
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(eve), 2);
    }

    /**********************************************************************************************/
    /*** H13: getters, fills with no backing                                                    ***/
    /**********************************************************************************************/

    // `getPendingDepositRequest(id)` (src 669-683) requires `firstPendingDepositId <= id <
    // length`: ids below the head (filled or walked) revert even though the array still holds a
    // zeroed slot there, dead slots above the head return zeros, `length` reverts. The range
    // getter (700-714) rejects `startId` below the head and a length past the end.
    function test_getPendingDepositRequest_rangeFollowsHead() public {
        uint256 a = _deposit(alice, HUNDRED_K);   // 0, instant, head 1
        uint256 b = _queue(bob, HUNDRED_K);       // 1 live
        uint256 c = _deposit(carol, HUNDRED_K);   // 2 queued
        _cancel(carol, c);                        // 2 dead, above the live head

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(a);

        (address o, address r, uint256 s) = vault.getPendingDepositRequest(b);
        assertEq(o, bob); assertEq(r, bob); assertEq(s, S_100K);

        (o, r, s) = vault.getPendingDepositRequest(c);
        assertEq(o, address(0)); assertEq(r, address(0)); assertEq(s, 0);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(3);

        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingDepositRequests(0, 1);
        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingDepositRequests(1, 3);
        ISparkPrimeVault.Request[] memory reqs = vault.getPendingDepositRequests(1, 2);
        assertEq(reqs.length,    2);
        assertEq(reqs[0].owner,  bob);
        assertEq(reqs[0].shares, S_100K);
        assertEq(reqs[1].shares, 0);
        assertEq(vault.getPendingDepositRequests().length, 2);

        // After bob is filled the head walks over carol's dead slot: both ids are now out of range.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(), 3);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(b);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(c);
        assertEq(vault.getPendingDepositRequests().length, 0);
        assertEq(vault.getPendingDepositRequests(3, 0).length, 0);
    }

    // F-2 on the instant path: after `take()` emptied the vault's spUSDC, a new request still
    // deposits into spUSDC and instant-fills against it; nothing compares the balance with the
    // pending counters, and the new depositor's spUSDC immediately backs everyone else's claims.
    function test_BUG_requestDeposit_instantFillAfterTakeAllStillMints() public {
        _deposit(alice, ONE_M);
        _takeAll();
        assertEq(_vaultSpUsdc(), 0);
        assertEq(vault.totalAssets(), 999_999_999_998);

        uint256 id = _deposit(bob, HUNDRED_K);

        assertEq(_shares(id),            0);
        assertEq(vault.balanceOf(bob),   SH_100K);
        assertEq(_vaultSpUsdc(),         S_100K);
        assertEq(vault.totalSupply(),    SH_1M + SH_100K);
        assertEq(vault.availableLiquidAssets(), A_100K);  // bob's spUSDC is all the backing left

        // Alice can now exit with bob's backing.
        _requestRedeem(alice, SH_100K);
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 99_999_999_998);
        assertLe(_vaultSpUsdc(), 1);
        _assertQueueConsistent();
    }

    /**********************************************************************************************/
    /*** H11: fuzz                                                                              ***/
    /**********************************************************************************************/

    function testFuzz_requestDeposit_instantFillNeverExceedsCapacity(
        uint256 cap, uint256 amt1, uint256 amt2, uint256 amt3
    ) public {
        cap  = bound(cap,  0, 5_000_000e6);
        amt1 = bound(amt1, 1, 2_000_000e6);
        amt2 = bound(amt2, 1, 2_000_000e6);
        amt3 = bound(amt3, 1, 2_000_000e6);

        _setCapacity(cap);

        address[3] memory users = [alice, bob, carol];
        uint256[3] memory amts  = [amt1, amt2, amt3];

        for (uint256 i; i < 3; ++i) _depositAndCheckCapacity(users[i], amts[i], cap);
    }

    function _depositAndCheckCapacity(address who, uint256 amt, uint256 cap) internal {
        bool    instant   = _nextRequestIsInstant();
        uint256 fillable  = _remainingForCapacity(vault.availableCapacity());
        uint256 s         = spUsdc.convertToShares(amt);
        uint256 supplyBef = vault.totalSupply();
        uint256 headBef   = vault.firstPendingDepositId();

        uint256 id = _deposit(who, amt);

        uint256 filled = instant ? (s < fillable ? s : fillable) : 0;
        (, uint256 expShares) = _fillOf(filled);

        assertEq(_shares(id),           s - filled);
        assertEq(vault.balanceOf(who),  expShares);
        assertEq(vault.totalSupply(),   supplyBef + expShares);
        assertLe(vault.totalSupply(),   cap);
        // Instant: the walk skips every zero entry (there is none live) and either deletes the
        // own entry (fully filled or 0 shares) -> head id+1, or breaks on its remainder -> head id.
        if (instant && s - filled == 0) assertEq(vault.firstPendingDepositId(), id + 1);
        if (instant && s - filled != 0) assertEq(vault.firstPendingDepositId(), id);
        if (!instant)                   assertEq(vault.firstPendingDepositId(), headBef);
        _assertQueueConsistent();
    }

    // Capacity is never exceeded by a fill at any pair of indexes: random spUSDC and spPRIME
    // rates, random elapsed time, random capacity and amounts, instant and operator fills.
    // `remaining_` (src 862-865) floors twice and the fill math (883-884) floors twice more, all
    // in the same direction, so `totalSupply` never passes `maxCapacity` through a fill. The
    // operator can still set capacity below supply (304-306), in which case fills are no-ops.
    function testFuzz_processPendingDeposits_capacityNeverExceededAtUglyIndexes(
        uint256 spVsr, uint256 primeVsr, uint256 secs, uint256 cap, uint256 amt1, uint256 amt2
    ) public {
        spVsr    = bound(spVsr,    RAY, MAX_VSR);
        primeVsr = bound(primeVsr, RAY, MAX_VSR);
        secs     = bound(secs,     0, 3 * 365 days);
        cap      = bound(cap,      0, 20_000_000e6);
        amt1     = bound(amt1,     1, 10_000_000e6);
        amt2     = bound(amt2,     1, 10_000_000e6);

        _setSpUsdcVsr(spVsr);
        _setPrimeVsr(primeVsr);
        _warpAndDrip(secs);
        _setCapacity(cap);

        _deposit(alice, amt1);  // instant (predicate true on an empty queue), capped by `cap`
        assertLe(vault.totalSupply(), cap);

        uint256 id = _deposit(bob, amt2);
        assertLe(vault.totalSupply(), cap);

        _warpAndDrip(secs / 3);
        _processDeposits(type(uint256).max, 10);
        assertLe(vault.totalSupply(), cap);

        // Supply equals capacity minus at most the conversion dust whenever something is queued.
        if (_shares(id) != 0 || vault.pendingDepositSavingsShares() != 0) {
            uint256 dust = spUsdc.convertToAssets(1) + 2;  // one spUSDC share plus two floors
            assertLe(vault.availableCapacity(), vault.convertToShares(dust) + 2);
        }
        _assertQueueConsistent();
    }

    // Two live requests can never both be instant: the first is instant only on an empty (all
    // zero) queue; if it is fully filled the queue is empty again and the second is instant
    // too, but then nobody is owed. If it is partially filled, `pendingDepositSavingsShares` is
    // its remainder and the second is queued behind it: the predicate (src 400) is exactly
    // "nobody is owed".
    function testFuzz_requestDeposit_secondRequestInstantIffFirstFullyFilled(
        uint256 cap, uint256 amt1, uint256 amt2
    ) public {
        cap  = bound(cap,  2, 5_000_000e6);
        amt1 = bound(amt1, 2, 2_000_000e6);
        amt2 = bound(amt2, 2, 2_000_000e6);
        _setCapacity(cap);

        uint256 id1 = _deposit(alice, amt1);
        bool firstFullyFilled = _shares(id1) == 0;
        assertEq(_nextRequestIsInstant(), firstFullyFilled);

        uint256 bobBef = vault.balanceOf(bob);
        uint256 id2 = _deposit(bob, amt2);
        uint256 s2 = spUsdc.convertToShares(amt2);

        if (firstFullyFilled) {
            // Instant: bob got whatever capacity allows.
            uint256 fillable = _remainingForCapacity(cap - vault.balanceOf(alice));
            (, uint256 exp) = _fillOf(s2 < fillable ? s2 : fillable);
            assertEq(vault.balanceOf(bob) - bobBef, exp);
        } else {
            // Queued: bob got nothing, alice's remainder is still at the head.
            assertEq(vault.balanceOf(bob), bobBef);
            assertEq(_shares(id2), s2);
            assertEq(vault.firstPendingDepositId(), id1);
        }
        _assertQueueConsistent();
    }

    // Random deposits (including 1-wei ghosts), full and partial cancels, refund settlements,
    // fills (including budget-0 walks) and capacity changes. Checks after every step:
    // pendingDepositSavingsShares == sum(open), the same for the cancelled queue, every entry
    // before each head is zero, heads never exceed lengths or decrease, after a cancel the head
    // sits on a live entry or at the length, supply <= capacity, USDC refunded == spUSDC value
    // of settled shares (within one floor per entry), fills never move spUSDC, FIFO: a fill
    // never touches an entry while an earlier live one has a remainder.
    function testFuzz_processPendingDeposits_pendingEqualsSumOfOpenEntries(uint256 seed) public {
        uint256 cap = bound(uint256(keccak256(abi.encode(seed, "cap"))), 0, 3_000_000e6);
        _setCapacity(cap);

        address[5] memory users = [alice, bob, carol, dave, eve];
        for (uint256 i; i < 5; ++i) _fund(users[i], 0);

        uint256 len;

        for (uint256 step; step < 20; ++step) {
            uint256 r  = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 7;

            if (op == 0 || op == 1) {
                address who = users[(r >> 8) % 5];
                uint256 amt = (r >> 16) % 7 == 0 ? 1 : bound(r >> 16, 2, 800_000e6);
                bool    instant  = _nextRequestIsInstant();
                uint256 balBef   = vault.balanceOf(who);
                uint256 headBef  = vault.firstPendingDepositId();
                uint256 id       = _deposit(who, amt);
                len++;
                assertEq(id, len - 1);
                if (!instant) {
                    assertEq(vault.balanceOf(who), balBef);  // queued, nothing minted
                    assertEq(vault.firstPendingDepositId(), headBef);
                }
                if (instant && _shares(id) == 0) assertEq(vault.firstPendingDepositId(), id + 1);
                if (instant && _shares(id) != 0) assertEq(vault.firstPendingDepositId(), id);
            } else if (op == 2 && len != 0) {
                uint256 id = (r >> 8) % len;
                (address owner, address recipient, uint256 s) = _rawEntry(DEPOSIT_SLOT, id);
                if (s != 0) {
                    uint256 part     = (r >> 72) % 3 == 0 ? s : bound(r >> 80, 1, s);
                    uint256 pendBef  = vault.pendingDepositSavingsShares();
                    uint256 cPendBef = vault.pendingCancelledDepositSavingsShares();
                    uint256 headBef  = vault.firstPendingDepositId();
                    uint256 cLenBef  = _cancelledQueueLength();
                    vm.prank(owner);
                    uint256 cancelId = vault.requestDepositCancellation(id, owner, part);
                    assertEq(cancelId, cLenBef);
                    assertEq(_cancelledShares(cancelId), part);
                    assertEq(_shares(id), s - part);
                    if (part != s) {
                        (address o2, address r2, ) = _rawEntry(DEPOSIT_SLOT, id);
                        assertEq(o2, owner);
                        assertEq(r2, recipient);
                    }
                    assertEq(vault.pendingDepositSavingsShares(), pendBef - part);
                    assertEq(vault.pendingCancelledDepositSavingsShares(), cPendBef + part);
                    assertGe(vault.firstPendingDepositId(), headBef);
                    _assertHeadOnLiveOrEnd();
                }
            } else if (op == 3) {
                uint256 maxSS  = bound(r >> 8,  0, 2_000_000e6);
                uint256 maxReq = bound(r >> 72, 0, 6);
                uint256 cHeadBef = vault.firstPendingDepositCancellationId();
                uint256 cPendBef = vault.pendingCancelledDepositSavingsShares();
                uint256 usdcBef  = _usersUsdc(users);
                uint256 spBef    = _vaultSpUsdc();
                _processCancelledDeposits(maxSS, maxReq);
                assertGe(vault.firstPendingDepositCancellationId(), cHeadBef);
                uint256 settled = cPendBef - vault.pendingCancelledDepositSavingsShares();
                assertEq(spBef - _vaultSpUsdc(), settled);
                // Each entry floors separately: total refund is within maxReq wei of the value.
                uint256 paid = _usersUsdc(users) - usdcBef;
                assertLe(paid, spUsdc.convertToAssets(settled));
                assertGe(paid + _min(maxReq, 6), spUsdc.convertToAssets(settled));
            } else {
                uint256 maxSS  = op == 6 ? 0 : bound(r >> 8, 0, 2_000_000e6);
                uint256 maxReq = bound(r >> 72, 0, 6);
                if ((r >> 80) % 3 == 0) {
                    cap = bound(r >> 88, 0, 3_000_000e6);
                    if (cap >= vault.totalSupply()) _setCapacity(cap);  // never below supply here
                    else cap = vault.maxCapacity();
                }
                uint256 headBef = vault.firstPendingDepositId();
                uint256 spBef   = _vaultSpUsdc();
                uint256[] memory sharesBef = _snapshotShares(len);
                _processDeposits(maxSS, maxReq);
                assertGe(vault.firstPendingDepositId(), headBef);
                assertEq(_vaultSpUsdc(), spBef);  // fills never move spUSDC
                _assertFifo(sharesBef, len);
                if (maxSS == 0) assertEq(_sumFilled(sharesBef, len), 0);  // budget 0 fills nothing
            }

            _assertQueueConsistent();
        }
    }

    function _snapshotShares(uint256 len) internal view returns (uint256[] memory s) {
        s = new uint256[](len);
        for (uint256 i; i < len; ++i) s[i] = _shares(i);
    }

    function _sumFilled(uint256[] memory before, uint256 len) internal view returns (uint256 sum) {
        for (uint256 i; i < len; ++i) sum += before[i] - _shares(i);
    }

    // FIFO: once an entry keeps a remainder after a fill, no later entry was touched by it.
    function _assertFifo(uint256[] memory before, uint256 len) internal view {
        bool stopped;
        for (uint256 i; i < len; ++i) {
            uint256 now_ = _shares(i);
            if (stopped) assertEq(now_, before[i], "fill skipped a live remainder");
            if (now_ != 0 && now_ != before[i]) stopped = true;  // partial fill here
            if (now_ != 0 && now_ == before[i] && before[i] != 0 && i >= vault.firstPendingDepositId()) {
                stopped = true;  // untouched live entry: nothing after it may have moved
            }
        }
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256) { return x < y ? x : y; }

    function _usersUsdc(address[5] memory users) internal view returns (uint256 sum) {
        for (uint256 i; i < 5; ++i) sum += usdc.balanceOf(users[i]);
    }

    // With both VSRs frozen, a queued depositor filled in one go receives exactly the instant
    // amount; filled in k chunks they receive at most 2*(k-1) spPRIME shares fewer, never more.
    function testFuzz_requestDeposit_queuedDepositorGetsAtLeastAsManySharesAsInstant(
        uint256 amt, uint256 k, uint256 seed
    ) public {
        amt = bound(amt, 1, 10_000_000e6);
        k   = bound(k, 1, 5);

        uint256 instantShares;
        {
            _deposit(alice, amt);
            instantShares = vault.balanceOf(alice);
        }

        uint256 id = _queue(bob, amt);
        uint256 s  = _shares(id);
        assertEq(s, spUsdc.convertToShares(amt));
        _setCapacity(type(uint128).max);

        // Split s into k chunks (last chunk takes the rest).
        uint256 left = s;
        for (uint256 i; i + 1 < k && left > 1; ++i) {
            uint256 chunk = bound(uint256(keccak256(abi.encode(seed, i))), 1, left - 1);
            _processDeposits(chunk, 1);
            left -= chunk;
            assertEq(_shares(id), left);
        }
        _processDeposits(type(uint256).max, 1);

        assertEq(_shares(id),                         0);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        uint256 queuedShares = vault.balanceOf(bob);

        assertLe(queuedShares, instantShares);
        assertLe(instantShares - queuedShares, 2 * (k - 1));
        if (k == 1) assertEq(queuedShares, instantShares);
    }

    // Partial cancels: any split of a request into cancels and fills conserves spUSDC shares
    // exactly (fills never move spUSDC, settlements move exactly the cancelled shares) and the
    // cancelled parts refund within one floor each.
    function testFuzz_requestDepositCancellation_partialSplitsConserveShares(
        uint256 amt, uint256 c1, uint256 c2, uint256 fill
    ) public {
        amt = bound(amt, 10, 5_000_000e6);
        uint256 id = _queue(alice, amt);
        uint256 s  = _shares(id);
        assertGt(s, 0);

        c1 = bound(c1, 1, s);
        uint256 cancelId1 = _cancelPart(alice, id, bob, c1);
        assertEq(_shares(id), s - c1);

        uint256 left = s - c1;
        if (left != 0) {
            fill = bound(fill, 0, left);
            _setCapacity(type(uint128).max);
            _processDeposits(fill, 1);
            assertEq(_shares(id), left - fill);
            left -= fill;
        } else {
            fill = 0;
        }
        uint256 cancelled = c1;
        if (left != 0) {
            c2 = bound(c2, 1, left);
            _cancelPart(alice, id, carol, c2);
            assertEq(_shares(id), left - c2);
            left      -= c2;
            cancelled += c2;
        } else {
            c2 = 0;
        }
        assertEq(vault.pendingDepositSavingsShares(), left);
        if (left == 0) assertEq(vault.firstPendingDepositId(), 1);
        else           assertEq(vault.firstPendingDepositId(), 0);
        assertEq(s, cancelled + fill + left);
        _assertQueueConsistent();

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob),   spUsdc.convertToAssets(c1));
        assertEq(usdc.balanceOf(carol), spUsdc.convertToAssets(c2));
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_cancelledShares(cancelId1), 0);
        assertEq(_vaultSpUsdc(), fill + left);
        _assertQueueConsistent();
    }

}
