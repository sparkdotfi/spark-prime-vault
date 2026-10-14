// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../../lib/forge-std/src/StdError.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

/// @dev Deposit-queue stress tests for `SparkPrimeVault` (round 3, `refactor/more-simplifying`
///      @ ff828d2).
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
///
///      Round-3 changes under test: `updateDepositRecipient` is owner-only on a live entry
///      (src 416-425); the refund settlement budget is `spUSDC.maxRedeem(vault)` (src 784), so a
///      cancelled entry is paid partially when spUSDC lacks USDC instead of reverting;
///      `realizeGain` (src 297-309) moves chi up for holders only.
///
///      Round-2 semantics under test:
///        - `_requestDeposit` walks `depositHead` over zero-share entries and fills instantly iff
///          the head lands on the new entry (src 728-735).
///        - a full fill `delete`s the entry (src 775); a cancel `delete`s it, pushes it to
///          `cancelledDepositQueue` and walks the head if it was the head (src 446-460); refunds
///          are paid by `processPendingDepositCancellations` (src 781-815).
contract DepositQueueTest is LocalTestBase {

    event DepositRequest(
        address indexed owner,
        address indexed recipient,
        uint256 indexed requestId,
        uint256         assets,
        uint256         savingsShares
    );
    event Deposit(address indexed owner, address indexed recipient, uint256 assets, uint256 shares);
    event DepositCancellation(
        address indexed owner,
        address indexed recipient,
        uint256         savingsShares,
        uint256         assets
    );
    event DepositCancellationRequest(uint256 indexed depositRequestId, uint256 cancelRequestId);
    event DepositRecipientUpdated(uint256 indexed requestId, address indexed recipient);
    event GainRealized(uint192 chi, uint256 gain);

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave  = makeAddr("dave");
    address eve   = makeAddr("eve");

    uint256 constant ONE_M = 1_000_000e6;
    uint256 constant HUNDRED_K = 100_000e6;

    // spUSDC shares minted for ONE_M / HUNDRED_K USDC at the harness index.
    uint256 constant S_1M   = 954_532_691_143;
    uint256 constant S_100K = 95_453_269_114;

    // spPRIME shares minted when S_1M / S_100K spUSDC shares are filled in one go.
    uint256 constant SH_1M   = 990_405_184_109;
    uint256 constant SH_100K = 99_040_518_410;

    uint256 constant A_1M   = 999_999_999_999;  // USDC value of S_1M at fill
    uint256 constant A_100K = 99_999_999_999;

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    // What a fill of `savingsShares` spUSDC shares produces right now (same math as src 762-763).
    function _fillOf(uint256 savingsShares) internal view returns (uint256 assets, uint256 shares) {
        assets = spUsdc.convertToAssets(savingsShares);
        shares = vault.convertToShares(assets);
    }

    // spUSDC shares fillable by `cap` spPRIME shares of free capacity (same math as src 742-745).
    function _remainingForCapacity(uint256 cap) internal view returns (uint256) {
        return spUsdc.convertToShares(vault.convertToAssets(cap));
    }

    // The public array getters have no length view; probe until the index reverts.
    function _queueLength() internal view returns (uint256) {
        return _depositQueueLength();
    }

    function _cancelledQueueLength() internal view returns (uint256) {
        return _cancelledDepositQueueLength();
    }

    function _sumOpenEntries() internal view returns (uint256 sum) {
        uint256 n = _depositQueueLength();
        for (uint256 i = 0; i < n; ++i) { ( , , uint256 s) = _depositRequest(i); sum += s; }
    }

    function _sumOpenCancelledEntries() internal returns (uint256 sum) {
        uint256 len = _cancelledQueueLength();
        for (uint256 i; i < len; ++i) {
            (, , uint256 s) = _cancelledDepositRequest(i);
            sum += s;
        }
    }

    function _shares(uint256 id) internal view returns (uint256 s) {
        (, , s) = _depositRequest(id);
    }

    function _cancelledShares(uint256 id) internal view returns (uint256 s) {
        (, , s) = _cancelledDepositRequest(id);
    }

    // Puts `who`'s whole deposit in the queue: freeze capacity at current supply first.
    function _queue(address who, uint256 amt) internal returns (uint256 id) {
        _setCapacity(vault.totalSupply());
        id = _deposit(who, amt);
    }

    // Zero-asset request (F-5 ghost) by `who`.
    function _ghost(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.requestDeposit(0, who);
    }

    // Owner cancels without settling the refund.
    function _cancel(address who, uint256 id) internal returns (uint256 cancelId) {
        vm.prank(who);
        cancelId = vault.requestDepositCancellation(id, who);
    }

    // True iff every entry from `depositHead` to the tail is zero, i.e. the next request would be
    // filled instantly (src 728-733).
    function _nextRequestIsInstant() internal returns (bool) {
        uint256 len = _queueLength();
        for (uint256 i = vault.firstPendingDepositId(); i < len; ++i) {
            if (_shares(i) != 0) return false;
        }
        return true;
    }

    function _assertQueueConsistent() internal {
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
    }

    function setUp() public override {
        super.setUp();
        assertEq(spUsdc.nowChi(), 1.047633055711877768967605062e27);
        assertEq(vault.nowChi(),  1.009687768242461209408770821e27);
        assertEq(spUsdc.convertToShares(ONE_M), S_1M);
        assertEq(spUsdc.convertToShares(HUNDRED_K), S_100K);
    }

    /**********************************************************************************************/
    /*** H1: instant vs queued                                                                  ***/
    /**********************************************************************************************/

    function test_requestDeposit_instantFillWhenNobodyQueued() public {
        _fund(alice, ONE_M);

        assertEq(vault.totalSupply(),                 0);
        assertEq(vault.balanceOf(alice),              0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),                 0);
        assertEq(_vaultSpUsdc(),                      0);
        assertEq(usdc.balanceOf(alice),               ONE_M);

        vm.expectEmit(address(vault));
        emit DepositRequest(alice, alice, 0, ONE_M, S_1M);
        vm.expectEmit(address(vault));
        emit Deposit(alice, alice, A_1M, SH_1M);

        vm.prank(alice);
        uint256 id = vault.requestDeposit(ONE_M, alice);

        // The entry is created even for an instant fill and then deleted by the fill (src 775).
        assertEq(id, 0);
        (address owner, address recipient, uint256 shares) = _depositRequest(0);
        assertEq(owner,     address(0));
        assertEq(recipient, address(0));
        assertEq(shares,    0);

        assertEq(vault.totalSupply(),                 SH_1M);
        assertEq(vault.balanceOf(alice),              SH_1M);
        assertEq(vault.assetsOf(alice),               999_999_999_998);  // R1 + R3 + R12 rounding
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),                 1);
        assertEq(_vaultSpUsdc(),                      S_1M);
        assertEq(usdc.balanceOf(alice),               0);
        assertEq(usdc.balanceOf(address(spUsdc)),     ONE_M);
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
        assertEq(vault.firstPendingDepositId(),                 0);
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
        assertEq(vault.firstPendingDepositId(),                 2);

        uint256 carolId = _deposit(carol, HUNDRED_K);

        assertEq(carolId,                             2);
        assertEq(vault.balanceOf(carol),              SH_100K);
        assertEq(_shares(2),                          0);
        assertEq(vault.firstPendingDepositId(),                 3);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.totalSupply(),                 SH_1M + 2 * SH_100K);
        _assertQueueConsistent();
    }

    function test_requestDeposit_instantFillResumesAfterCancelDrainsQueue() public {
        uint256 aliceId = _queue(alice, ONE_M);
        _setCapacity(type(uint128).max);

        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(aliceId, 0);

        uint256 cancelId = _cancel(alice, aliceId);

        // The cancel moves the entry and, because it was the head, walks the head to the tail.
        assertEq(cancelId,                                     0);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
        assertEq(vault.firstPendingDepositId(),                          1);
        assertEq(_shares(aliceId),                             0);
        assertEq(_cancelledShares(cancelId),                   S_1M);
        assertEq(usdc.balanceOf(alice),                        0);   // refund not paid yet
        assertEq(_vaultSpUsdc(),                               S_1M);

        uint256 bobId = _deposit(bob, HUNDRED_K);

        assertEq(bobId,                1);
        assertEq(vault.balanceOf(bob), SH_100K);
        assertEq(vault.firstPendingDepositId(),  2);
        _assertQueueConsistent();

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice),                        A_1M);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),                 1);
        assertEq(_vaultSpUsdc(),                               S_100K);
        _assertQueueConsistent();
    }

    // QueueAudit-style: cancel at the head of a capacity-0 queue, then open capacity.
    function test_requestDeposit_instantFillAfterHeadEntryCancelled() public {
        _setCapacity(0);

        uint256 aliceId = _deposit(alice, ONE_M);
        assertEq(aliceId,             0);
        assertEq(vault.firstPendingDepositId(), 0);

        _cancel(alice, aliceId);
        assertEq(vault.firstPendingDepositId(), 1);  // advanced past slot 0 by the cancel

        _setCapacity(type(uint128).max);

        uint256 bobId = _deposit(bob, HUNDRED_K);
        assertEq(bobId,                1);
        assertEq(vault.balanceOf(bob), SH_100K);
        assertEq(vault.firstPendingDepositId(),  2);
        _assertQueueConsistent();
    }

    /**********************************************************************************************/
    /*** H1b: head walk (new in round 2)                                                        ***/
    /**********************************************************************************************/

    // Ghost entries sitting at the head are walked over by the next request, which then fills.
    function test_requestDeposit_headWalkSkipsGhostsAtHead() public {
        _setCapacity(0);
        _fund(alice, 0);

        // Each ghost is "instant" (head lands on it) but there is no capacity: entry stays zero.
        assertEq(_ghost(alice), 0);
        assertEq(vault.firstPendingDepositId(), 0);  // process() with remaining_ == 0 never moves the head
        assertEq(_ghost(alice), 1);
        assertEq(vault.firstPendingDepositId(), 1);  // the walk skipped ghost 0 before the (no-op) fill
        assertEq(_ghost(alice), 2);
        assertEq(vault.firstPendingDepositId(), 2);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        _setCapacity(type(uint128).max);
        assertTrue(_nextRequestIsInstant());

        uint256 bobId = _deposit(bob, HUNDRED_K);

        assertEq(bobId,                3);
        assertEq(vault.balanceOf(bob), SH_100K);
        assertEq(vault.firstPendingDepositId(),  4);
        _assertQueueConsistent();
    }

    // Ghosts and cancelled entries between the head and the tail are walked over too, but only
    // once the live head is gone.
    function test_requestDeposit_headWalkStopsAtLiveEntry() public {
        uint256 a = _queue(alice, HUNDRED_K);
        _fund(bob, 0);
        _ghost(bob);                                   // id 1
        uint256 c = _deposit(carol, HUNDRED_K);        // id 2
        _cancel(carol, c);                             // middle cancel, head stays
        assertEq(vault.firstPendingDepositId(), 0);

        _setCapacity(type(uint128).max);

        // alice is live at the head: dave is queued, head does not move.
        uint256 d = _deposit(dave, HUNDRED_K);
        assertEq(d,                     3);
        assertEq(vault.balanceOf(dave), 0);
        assertEq(vault.firstPendingDepositId(),   0);

        // alice cancels: the head walks over her slot, bob's ghost and carol's cancelled slot and
        // stops on dave.
        _cancel(alice, a);
        assertEq(vault.firstPendingDepositId(), 3);
        assertEq(_shares(3),          S_100K);
        _assertQueueConsistent();

        // Next request is still queued behind dave.
        uint256 e = _deposit(eve, HUNDRED_K);
        assertEq(e,                    4);
        assertEq(vault.balanceOf(eve), 0);
        assertEq(vault.firstPendingDepositId(),  3);
        _assertQueueConsistent();
    }

    // Cancelling the head walks to the tail when everything behind it is zero; the next request
    // fills instantly and the head ends at length.
    function test_requestDepositCancellation_atHeadAdvancesToLengthWhenRestIsZero() public {
        uint256 a = _queue(alice, HUNDRED_K);
        _fund(bob, 0);
        _ghost(bob);                                // 1
        uint256 c = _deposit(carol, HUNDRED_K);     // 2
        _cancel(carol, c);                          // tail cancel, head stays
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(_queueLength(),      3);

        _cancel(alice, a);
        assertEq(vault.firstPendingDepositId(), 3);           // == length
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 2 * S_100K);
        _assertQueueConsistent();

        _setCapacity(type(uint128).max);
        uint256 d = _deposit(dave, HUNDRED_K);
        assertEq(d,                     3);
        assertEq(vault.balanceOf(dave), SH_100K);
        assertEq(vault.firstPendingDepositId(),   4);
        _assertQueueConsistent();
    }

    // A partially filled head is live: neither a cancel elsewhere nor a new request moves it.
    function test_requestDepositCancellation_partiallyFilledHeadNotAdvanced() public {
        uint256 a = _queue(alice, ONE_M);
        uint256 b = _deposit(bob, HUNDRED_K);
        _setCapacity(type(uint128).max);

        _processDeposits(400e9, 1);
        assertEq(_shares(a),          554_532_691_143);
        assertEq(vault.firstPendingDepositId(), 0);

        _cancel(bob, b);                       // tail cancel
        assertEq(vault.firstPendingDepositId(), 0);

        uint256 c = _deposit(carol, HUNDRED_K);
        assertEq(c,                      2);
        assertEq(vault.balanceOf(carol), 0);   // queued behind alice's remainder
        assertEq(vault.firstPendingDepositId(),    0);
        _assertQueueConsistent();

        // Finishing alice walks over bob's cancelled slot and fills carol.
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(alice), 990_405_184_108);
        assertEq(vault.balanceOf(carol), SH_100K);
        assertEq(vault.firstPendingDepositId(),    3);
        _assertQueueConsistent();
    }

    // LOW (new): the head walk in cancel (src 457) is unbounded. With capacity 0 the planner cannot
    // move the head (remaining_ == 0 skips the loop, src 752), so the head depositor's cancel must
    // walk every ghost behind it in one transaction. Measures the per-ghost cost.
    function test_requestDepositCancellation_headWalkGasGrowsWithGhosts() public {
        _setCapacity(0);
        uint256 a = _deposit(alice, HUNDRED_K);
        _fund(bob, 0);

        uint256 gasNoGhosts;
        {
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            uint256 g0 = gasleft();
            vault.requestDepositCancellation(a, alice);
            gasNoGhosts = g0 - gasleft();
            vm.revertToState(snap);
        }

        uint256 n = 500;
        for (uint256 i; i < n; ++i) _ghost(bob);
        assertEq(vault.firstPendingDepositId(), 0);

        vm.cool(address(vault));  // the ghosts' slots are cold in a real transaction
        vm.prank(alice);
        uint256 g1 = gasleft();
        vault.requestDepositCancellation(a, alice);
        uint256 gasWithGhosts = g1 - gasleft();

        assertEq(vault.firstPendingDepositId(), n + 1);

        uint256 perGhost = (gasWithGhosts - gasNoGhosts) / n;
        assertGt(perGhost, 2_000);   // one cold SLOAD per ghost plus the head increment
        assertLt(perGhost, 3_500);
        // At ~2.9k gas per ghost, ~10_000 ghosts behind the head push the cancel past 30M gas.
        assertGt(30_000_000 / perGhost, 8_000);
        assertLt(30_000_000 / perGhost, 15_000);
        emit log_named_uint("gas per ghost (cold)", perGhost);
        emit log_named_uint("ghosts to exceed 30M", 30_000_000 / perGhost);
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
        emit Deposit(alice, alice, 499_999_999_997, 495_202_592_052);

        vm.prank(alice);
        uint256 id = vault.requestDeposit(ONE_M, alice);

        assertEq(id,                                  0);
        assertEq(vault.balanceOf(alice),              495_202_592_052);
        assertEq(vault.totalSupply(),                 495_202_592_052);
        assertEq(vault.availableCapacity(),           2);  // rounding leaves 2 shares unused
        assertEq(_shares(0),                          S_1M - 477_266_345_570);
        assertEq(_shares(0),                          477_266_345_573);
        assertEq(vault.pendingDepositSavingsShares(), 477_266_345_573);
        assertEq(vault.firstPendingDepositId(),                 0);
        assertEq(_vaultSpUsdc(),                      S_1M);
        _assertQueueConsistent();
    }

    function test_processPendingDeposits_partialThenCompleteFill() public {
        uint256 id = _queue(alice, ONE_M);
        _setCapacity(type(uint128).max);

        // Fill exactly 400e9 spUSDC shares via maxSavingsShares_.
        vm.expectEmit(address(vault));
        emit Deposit(alice, alice, 419_053_222_284, 415_032_483_768);

        _processDeposits(400e9, 10);

        assertEq(vault.balanceOf(alice),              415_032_483_768);
        assertEq(_shares(id),                         S_1M - 400e9);
        assertEq(_shares(id),                         554_532_691_143);
        assertEq(vault.pendingDepositSavingsShares(), 554_532_691_143);
        assertEq(vault.firstPendingDepositId(),                 0);
        _assertQueueConsistent();

        vm.expectEmit(address(vault));
        emit Deposit(alice, alice, 580_946_777_714, 575_372_700_340);

        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice),              415_032_483_768 + 575_372_700_340);
        assertEq(vault.balanceOf(alice),              990_405_184_108);  // 1 wei below SH_1M
        assertEq(_shares(id),                         0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),                 1);
        assertEq(_vaultSpUsdc(),                      S_1M);  // fills never move spUSDC
        _assertQueueConsistent();
    }

    function test_processPendingDeposits_partialFillFromCapacityThenRaise() public {
        uint256 id = _queue(alice, ONE_M);
        _setCapacity(SH_1M / 2);

        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice),    495_202_592_052);
        assertEq(_shares(id),               477_266_345_573);
        assertEq(vault.availableCapacity(), 2);
        assertEq(vault.firstPendingDepositId(),       0);

        // Available capacity of 2 shares converts to 1 spUSDC share: see test_BUG_dustFill...
        // Raise capacity and finish.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice),              495_202_592_052 + 495_202_592_056);
        assertEq(_shares(id),                         0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),                 1);
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
        assertEq(vault.firstPendingDepositId(),                 1);
        assertEq(vault.totalSupply(),                 SH_1M);

        // Capacity must exceed the fill by 2 shares because of the double rounding on src 744
        // (see test_BUG_exactFitCapacityLeavesDustThatBlocksInstantFills).
        _setCapacity(SH_1M + SH_100K + 2);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(bob),                SH_100K);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),                 2);
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
        assertEq(vault.firstPendingDepositId(),                 1);
        assertEq(vault.totalSupply(),                 SH_1M);
        assertEq(_vaultSpUsdc(),                      S_1M + S_100K);
    }

    /**********************************************************************************************/
    /*** H4: head / cancel bookkeeping                                                          ***/
    /**********************************************************************************************/

    function _queueThree() internal returns (uint256 a, uint256 b, uint256 c) {
        a = _queue(alice, ONE_M);
        b = _deposit(bob,   HUNDRED_K);
        c = _deposit(carol, HUNDRED_K);
        assertEq(vault.pendingDepositSavingsShares(), S_1M + 2 * S_100K);
        assertEq(vault.firstPendingDepositId(), 0);
    }

    function test_requestDepositCancellation_atHead() public {
        (uint256 a, , ) = _queueThree();

        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(a, 0);

        uint256 cancelId = _cancel(alice, a);

        // Intermediate state: entry moved, counters moved, nothing paid, head on bob.
        assertEq(cancelId,                                     0);
        assertEq(_shares(a),                                   0);
        (address cOwner, address cRecipient, uint256 cShares) = _cancelledDepositRequest(cancelId);
        assertEq(cOwner,     alice);
        assertEq(cRecipient, alice);
        assertEq(cShares,    S_1M);
        assertEq(vault.pendingDepositSavingsShares(),          2 * S_100K);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
        assertEq(vault.firstPendingDepositCancellationId(),                 0);
        assertEq(vault.firstPendingDepositId(),                          1);  // walked onto bob
        assertEq(usdc.balanceOf(alice),                        0);
        assertEq(_vaultSpUsdc(),                               S_1M + 2 * S_100K);
        _assertQueueConsistent();

        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, S_1M, A_1M);

        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),                        A_1M);  // 1 wei lost to R10
        assertEq(_cancelledShares(cancelId),                   0);     // deleted after refund
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),                 1);
        assertEq(_vaultSpUsdc(),                               2 * S_100K);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob),   SH_100K);
        assertEq(vault.balanceOf(carol), SH_100K);
        assertEq(vault.firstPendingDepositId(),    3);
        _assertQueueConsistent();
    }

    function test_requestDepositCancellation_inMiddle() public {
        (, uint256 b, ) = _queueThree();

        _cancelDepositAndSettle(bob, b);

        assertEq(usdc.balanceOf(bob),                 A_100K);
        assertEq(_shares(b),                          0);
        assertEq(vault.pendingDepositSavingsShares(), S_1M + S_100K);
        assertEq(vault.firstPendingDepositId(),                 0);  // head is live, not moved

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice), SH_1M);
        assertEq(vault.balanceOf(bob),   0);
        assertEq(vault.balanceOf(carol), SH_100K);
        assertEq(vault.firstPendingDepositId(),    3);
        _assertQueueConsistent();
    }

    function test_requestDepositCancellation_atTail() public {
        (, , uint256 c) = _queueThree();

        _cancelDepositAndSettle(carol, c);

        assertEq(usdc.balanceOf(carol),               A_100K);
        assertEq(vault.pendingDepositSavingsShares(), S_1M + S_100K);
        assertEq(vault.firstPendingDepositId(),                 0);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice), SH_1M);
        assertEq(vault.balanceOf(bob),   SH_100K);
        assertEq(vault.balanceOf(carol), 0);
        assertEq(vault.firstPendingDepositId(),    3);  // the loop walks past the zeroed tail entry
        _assertQueueConsistent();
    }

    function test_requestDepositCancellation_afterPartialFillRefundsRemainderOnly() public {
        uint256 id = _queue(alice, ONE_M);
        _setCapacity(type(uint128).max);
        _processDeposits(400e9, 10);

        assertEq(vault.balanceOf(alice), 415_032_483_768);
        assertEq(_shares(id),            554_532_691_143);

        _cancelDepositAndSettle(alice, id);

        // Refund = spUSDC.redeem(554_532_691_143) = floor(554_532_691_143 * chi_s / RAY)
        assertEq(usdc.balanceOf(alice),               580_946_777_714);
        assertEq(vault.balanceOf(alice),              415_032_483_768);  // filled part stays
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(),                      400e9);
        assertEq(vault.firstPendingDepositId(),                 1);  // head cancel walks to length

        // Next depositor fills instantly.
        _deposit(bob, HUNDRED_K);
        assertEq(vault.balanceOf(bob), SH_100K);
        assertEq(vault.firstPendingDepositId(),  2);
        _assertQueueConsistent();
    }

    function test_requestDepositCancellation_revertsSecondCancel() public {
        uint256 id = _queue(alice, ONE_M);

        _cancel(alice, id);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(id, alice);

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(id, guardian);
    }

    function test_requestDepositCancellation_revertsFilledEntry() public {
        uint256 id = _deposit(alice, ONE_M);  // instant fill deletes the entry
        assertEq(_shares(id), 0);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(id, alice);
    }

    function test_requestDepositCancellation_revertsNotAuthorized() public {
        uint256 id = _queue(alice, ONE_M);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(id, bob);

        // Rebalancer, admin and riskManager have no cancel power either.
        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(id, rebalancer);

        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(id, admin);
    }

    function test_requestDepositCancellation_revertsZeroRecipient() public {
        uint256 id = _queue(alice, ONE_M);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.requestDepositCancellation(id, address(0));

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.requestDepositCancellation(id, address(0));
    }

    function test_requestDepositCancellation_revertsOutOfBounds() public {
        _queue(alice, ONE_M);

        vm.prank(alice);
        vm.expectRevert(stdError.indexOOBError);
        vault.requestDepositCancellation(1, alice);
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

        assertEq(vault.balanceOf(carol), SH_100K);
        assertEq(vault.firstPendingDepositId(),    3);
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

    // INFO: cancelled entries behind a live head still count toward `maxRequests_` (src 750
    // budgets by index, src 757 `continue` does not refund the slot). Head cancels no longer do,
    // because the cancel itself walks the head.
    function test_processPendingDeposits_cancelledEntriesConsumeMaxRequests() public {
        (, uint256 b, ) = _queueThree();

        _cancel(bob, b);
        assertEq(vault.firstPendingDepositId(), 0);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 2);

        // Budget of 2: alice filled, bob's zeroed slot consumed the second, carol untouched.
        assertEq(vault.balanceOf(alice), SH_1M);
        assertEq(vault.balanceOf(carol), 0);
        assertEq(vault.firstPendingDepositId(),    2);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(carol), SH_100K);
        assertEq(vault.firstPendingDepositId(),    3);
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

        assertEq(vault.firstPendingDepositId(),                 2);
        assertEq(vault.pendingDepositSavingsShares(), 47_726_634_559 + 2 * S_100K);
        assertEq(vault.totalSupply(),                 2 * SH_100K + 49_520_259_202);
        assertEq(vault.availableCapacity(),           cap - vault.totalSupply());
        assertEq(vault.availableCapacity(),           3);
        _assertQueueConsistent();

        // Even a later generous call cannot fill dave before carol: raise capacity for exactly
        // carol's remainder and see dave/eve untouched.
        (, uint256 carolRest) = _fillOf(47_726_634_559);
        assertEq(carolRest, 49_520_259_206);
        assertEq(_remainingForCapacity(carolRest),     47_726_634_557);  // 2 short (src 744)
        assertEq(_remainingForCapacity(carolRest + 2), 47_726_634_559);
        _setCapacity(vault.totalSupply() + carolRest + 2);
        _processDeposits(type(uint256).max, 100);

        assertEq(vault.balanceOf(carol), 49_520_259_202 + 49_520_259_206);
        assertEq(vault.balanceOf(dave),  0);
        assertEq(vault.balanceOf(eve),   0);
        assertEq(vault.firstPendingDepositId(),    3);
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
        emit Deposit(alice, alice, grownAssets, expectedShares);

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
        // `spUSDC.maxRedeem(vault)` (src 784) = floor(1_000_000e6 * RAY / chi_s) =
        // 909_078_753_470 shares, so it pays what the liquidity allows and the remainder waits at
        // the cancelled head (round 2 reverted `SparkVault/insufficient-liquidity` here).
        assertEq(spUsdc.maxRedeem(address(vault)), 909_078_753_470);

        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, 909_078_753_470, 999_999_999_999);

        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),                        999_999_999_999);
        assertEq(usdc.balanceOf(address(spUsdc)),              1);
        assertEq(_cancelledShares(cancelId),                   45_453_937_673);
        assertEq(vault.firstPendingDepositCancellationId(),                 cancelId);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 45_453_937_673);
        assertEq(_vaultSpUsdc(),                               45_453_937_673);
        _assertQueueConsistent();

        // 1 wei of USDC converts to 0 shares: a second pass is a silent no-op.
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice),      999_999_999_999);
        assertEq(_cancelledShares(cancelId), 45_453_937_673);

        _returnSpUsdcLiquidity(60_000e6);  // spUSDC needs USDC to pay the grown value

        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, 45_453_937_673, 49_999_999_999);

        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),                        1_049_999_999_998);  // = one payout
        assertEq(_cancelledShares(cancelId),                   0);
        assertEq(vault.firstPendingDepositCancellationId(),                 cancelId + 1);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(),                               0);
        _assertQueueConsistent();
    }

    // Round 3: `realizeGain` (src 297-309, DEFAULT_ADMIN, no pause required) sets
    // chi = (totalAssets + gain) * RAY / totalSupply. Queued spUSDC is not in `totalAssets` (no
    // shares minted yet), so a gain realised while a deposit is queued goes to the holders only:
    // the queued depositor is filled later at the higher chi and gets fewer spPRIME for the same
    // spUSDC, worth exactly what he brought. The depositor filled instantly one block earlier is a
    // holder and shares the gain.
    function test_processPendingDeposits_queuedDepositorDoesNotShareRealizedGain() public {
        _deposit(alice, HUNDRED_K);           // holder
        _warp(12);
        _deposit(carol, HUNDRED_K);           // instant fill one block before the gain
        uint256 id = _queue(bob, HUNDRED_K);  // queued: capacity frozen at totalSupply

        assertEq(vault.totalSupply(),   2 * SH_100K);
        assertEq(vault.totalAssets(),   199_999_999_997);
        assertEq(vault.assetsOf(alice), 99_999_999_998);
        assertEq(vault.assetsOf(carol), 99_999_999_998);
        assertEq(_shares(id),           S_100K);

        _warp(12);
        vm.expectEmit(address(vault));
        emit GainRealized(uint192(1.060172156650366224592543507e27), 10_000e6);
        vm.prank(admin);
        vault.realizeGain(10_000e6);

        // chi = (199_999_999_997 + 10_000e6) * RAY / 198_081_036_820
        assertEq(vault.nowChi(),        1.060172156650366224592543507e27);
        assertEq(vault.totalAssets(),   209_999_999_996);
        assertEq(vault.assetsOf(alice), 104_999_999_998);  // +5_000_000_000 each
        assertEq(vault.assetsOf(carol), 104_999_999_998);
        assertEq(_shares(id),           S_100K);           // bob's entry is untouched

        _setCapacity(type(uint128).max);

        vm.expectEmit(address(vault));
        emit Deposit(bob, bob, A_100K, 94_324_303_248);

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
        emit Deposit(alice, bob, A_1M, SH_1M);

        vm.prank(alice);
        vault.requestDeposit(ONE_M, bob);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob),   SH_1M);
    }

    function test_requestDeposit_recipientNotOwnerQueuedFillAndCancel() public {
        _setCapacity(0);
        _fund(alice, 2 * ONE_M);

        vm.prank(alice);
        uint256 id1 = vault.requestDeposit(ONE_M, bob);
        vm.prank(alice);
        uint256 id2 = vault.requestDeposit(ONE_M, bob);

        (address owner, address recipient, ) = _depositRequest(id1);
        assertEq(owner,     alice);
        assertEq(recipient, bob);

        // Fill the first: shares go to the recipient (capacity + 2 for the src 744 rounding).
        _setCapacity(SH_1M + 2);
        _processDeposits(type(uint256).max, 1);

        assertEq(vault.balanceOf(bob),   SH_1M);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(_shares(id1),           0);
        assertEq(_shares(id2),           S_1M);

        // Bob (the recipient) cannot cancel the second.
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(id2, bob);

        // Owner cancels and picks the refund address, here carol.
        vm.prank(alice);
        uint256 cancelId = vault.requestDepositCancellation(id2, carol);

        (address cOwner, address cRecipient, uint256 cShares) = _cancelledDepositRequest(cancelId);
        assertEq(cOwner,     alice);
        assertEq(cRecipient, carol);
        assertEq(cShares,    S_1M);

        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, carol, S_1M, A_1M);

        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(carol), A_1M);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(_vaultSpUsdc(),        S_1M);
        _assertQueueConsistent();
    }

    // HIGH (regression of F-1): the guardian's `recipient_` is written into the cancelled entry
    // (src 450), so a guardian cancel pays whoever the guardian names, not the owner.
    function test_BUG_guardianCancelRefundsToArbitraryRecipient() public {
        _setCapacity(0);
        _fund(alice, ONE_M);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(ONE_M, bob);

        vm.prank(guardian);
        uint256 cancelId = vault.requestDepositCancellation(id, guardian);

        (address cOwner, address cRecipient, uint256 cShares) = _cancelledDepositRequest(cancelId);
        assertEq(cOwner,     alice);
        assertEq(cRecipient, guardian);
        assertEq(cShares,    S_1M);

        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(guardian), A_1M);
        assertEq(usdc.balanceOf(alice),    0);
        assertEq(usdc.balanceOf(bob),      0);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // The owner can redirect a queued entry's fill (src 416-425, owner-only since ff828d2).
    function test_updateDepositRecipient_ownerRedirectsQueuedFill() public {
        uint256 id = _queue(alice, ONE_M);

        vm.expectEmit(address(vault));
        emit DepositRecipientUpdated(id, carol);

        vm.prank(alice);
        vault.updateDepositRecipient(id, carol);

        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, carol);
        assertEq(shares,    S_1M);

        _setCapacity(type(uint128).max);

        vm.expectEmit(address(vault));
        emit Deposit(alice, carol, A_1M, SH_1M);

        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(carol), SH_1M);
        assertEq(vault.balanceOf(alice), 0);
        _assertQueueConsistent();
    }

    // Round 3: a stranger, the current recipient and the guardian cannot repoint a queued
    // deposit (`SparkPrimeVault/not-authorized`, src 422); the owner cannot repoint to zero.
    function test_updateDepositRecipient_revertsNotOwner() public {
        _setCapacity(0);
        _fund(alice, ONE_M);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(ONE_M, bob);

        address[3] memory callers = [carol, bob, guardian];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.updateDepositRecipient(id, callers[i]);
        }

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateDepositRecipient(id, address(0));

        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);
        assertEq(vault.balanceOf(bob), 0);
    }

    // Round 3: a filled or cancelled (deleted) entry reverts `no-request` (src 421) for everyone,
    // its former owner included; an index past the array panics. The cancelled copy lives in
    // `cancelledDepositQueue` and is owner-only there as well (src 465-477).
    function test_updateDepositRecipient_revertsDeadEntryAndOutOfRange() public {
        uint256 filled = _deposit(alice, HUNDRED_K);  // instant fill: entry deleted (src 775)
        uint256 queued = _queue(bob, HUNDRED_K);
        uint256 cancelId = _cancel(bob, queued);      // cancelled: entry deleted (src 446)

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateDepositRecipient(filled, carol);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateDepositRecipient(queued, carol);

        vm.prank(bob);
        vm.expectRevert(stdError.indexOOBError);
        vault.updateDepositRecipient(queued + 1, carol);

        vm.prank(carol);
        vm.expectRevert("SparkPrimeVault/not-authorized");
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

    // LOW: shares minted to the vault's own address are unrecoverable (no function moves them)
    // and permanently occupy capacity.
    function test_requestDeposit_recipientIsVaultSharesAreStuck() public {
        _fund(alice, ONE_M);

        vm.prank(alice);
        vault.requestDeposit(ONE_M, address(vault));

        assertEq(vault.balanceOf(address(vault)), SH_1M);
        assertEq(vault.balanceOf(alice),          0);
        assertEq(vault.totalSupply(),             SH_1M);
        assertEq(vault.pendingRedeemShares(),     0);  // not escrow: nothing will ever burn them

        // Nothing can get them out: no request/cancel is tied to them; redeem queue is empty.
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.balanceOf(address(vault)), SH_1M);

        // And they take capacity from everyone else for good.
        _setCapacity(SH_1M);
        assertEq(vault.availableCapacity(), 0);
        uint256 bobId = _deposit(bob, HUNDRED_K);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(_shares(bobId),       S_100K);
    }

    function test_requestDeposit_revertsZeroRecipient() public {
        _fund(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.requestDeposit(ONE_M, address(0));

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.requestDeposit(ONE_M, address(0), 7);
    }

    function test_requestDeposit_revertsBelowMinimumBoundary() public {
        _setMinDeposit(HUNDRED_K);
        _fund(alice, HUNDRED_K);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(HUNDRED_K - 1, alice);

        vm.prank(alice);
        vault.requestDeposit(HUNDRED_K, alice);
        assertEq(vault.balanceOf(alice), SH_100K);
    }

    /**********************************************************************************************/
    /*** H8: pause                                                                              ***/
    /**********************************************************************************************/

    function test_pause_blocksRequestCancelProcessButNotTake() public {
        uint256 id = _queue(alice, ONE_M);
        uint256 c  = _deposit(carol, HUNDRED_K);
        _cancel(carol, c);  // leaves a cancelled entry to settle
        _setCapacity(type(uint128).max);
        _fund(bob, HUNDRED_K);

        _pause();

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(HUNDRED_K, bob);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(HUNDRED_K, bob, 1);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDepositCancellation(id, alice);

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDepositCancellation(id, guardian);

        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processPendingDeposits(type(uint256).max, 10);

        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processPendingDepositCancellations(type(uint256).max, 10);

        // take() is not gated: the queued depositor's backing can leave during a pause (F-7).
        _take(S_1M + S_100K);
        assertEq(_vaultSpUsdc(),          0);
        assertEq(spUsdc.balanceOf(taker), S_1M + S_100K);
        assertEq(_shares(id),             S_1M);

        _unpause();
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(alice), SH_1M);
    }

    /**********************************************************************************************/
    /*** H9: bounds                                                                             ***/
    /**********************************************************************************************/

    function test_processPendingDeposits_maxRequestsHonouredExactly() public {
        (uint256 a, uint256 b, uint256 c) = _queueThree();
        _setCapacity(type(uint128).max);

        _processDeposits(type(uint256).max, 2);

        assertEq(vault.balanceOf(alice), SH_1M);
        assertEq(vault.balanceOf(bob),   SH_100K);
        assertEq(vault.balanceOf(carol), 0);
        assertEq(_shares(a),             0);
        assertEq(_shares(b),             0);
        assertEq(_shares(c),             S_100K);
        assertEq(vault.firstPendingDepositId(),    2);
        _assertQueueConsistent();

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(carol), SH_100K);
        assertEq(vault.firstPendingDepositId(),    3);

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
        assertEq(vault.firstPendingDepositId(),                 1);
        _assertQueueConsistent();
    }

    function test_processPendingDeposits_maxSavingsSharesZeroIsNoop() public {
        _queueThree();
        _setCapacity(type(uint128).max);

        _processDeposits(0, 10);

        assertEq(vault.totalSupply(),                 0);
        assertEq(vault.pendingDepositSavingsShares(), S_1M + 2 * S_100K);
        assertEq(vault.firstPendingDepositId(),                 0);
    }

    function test_processPendingDeposits_maxRequestsZeroIsNoop() public {
        _queueThree();
        _setCapacity(type(uint128).max);

        _processDeposits(type(uint256).max, 0);

        assertEq(vault.totalSupply(),                 0);
        assertEq(vault.pendingDepositSavingsShares(), S_1M + 2 * S_100K);
        assertEq(vault.firstPendingDepositId(),                 0);
    }

    function test_processPendingDeposits_emptyQueueIsNoop() public {
        _processDeposits(type(uint256).max, 10);
        _processDeposits(0, 0);

        assertEq(vault.firstPendingDepositId(),  0);
        assertEq(vault.totalSupply(),  0);

        // Fully drained queue is a no-op too.
        _deposit(alice, ONE_M);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(vault.totalSupply(), SH_1M);
    }

    function test_processPendingDeposits_revertsNotRebalancer() public {
        _queue(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", alice, REBALANCER_ROLE
        ));
        vault.processPendingDeposits(type(uint256).max, 10);
    }

    /**********************************************************************************************/
    /*** H10: dust boundary (known F-4)                                                         ***/
    /**********************************************************************************************/

    // Known F-4 (src 759-771). At the harness indexes a fill of exactly 1 spUSDC share converts to
    // assets_ = floor(1 * chi_s / RAY) = 1, then shares_ = floor(1 * RAY / chi_p) = 0.
    // 2 spUSDC shares already mint 1 spPRIME share, so remaining_ == 1 is the only dust value.
    // Reachable via maxSavingsShares_ == 1 or via availableCapacity() == 2 (-> remaining_ == 1).
    // The test asserts the buggy behaviour: spUSDC deducted from the head request, 0 shares minted.
    function test_BUG_dustFillMintsZeroShares() public {
        uint256 id = _queue(alice, ONE_M);
        _setCapacity(type(uint128).max);

        (uint256 a1, uint256 s1) = _fillOf(1);
        (uint256 a2, uint256 s2) = _fillOf(2);
        assertEq(a1, 1); assertEq(s1, 0);  // boundary: 1 share -> 0 spPRIME
        assertEq(a2, 2); assertEq(s2, 1);  // 2 shares -> 1 spPRIME

        // Path 1: maxSavingsShares_ == 1.
        vm.expectEmit(address(vault));
        emit Deposit(alice, alice, 1, 0);

        _processDeposits(1, 10);

        assertEq(vault.balanceOf(alice),              0);
        assertEq(vault.totalSupply(),                 0);
        assertEq(_shares(id),                         S_1M - 1);
        assertEq(vault.pendingDepositSavingsShares(), S_1M - 1);
        assertEq(vault.firstPendingDepositId(),                 0);

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
    /*** H12: take() and refund settlement                                                      ***/
    /**********************************************************************************************/

    // Fills never move spUSDC, so the queue processes fine after take() removed its backing and
    // mints shares against backing that already left (known F-2). The cancel itself now always
    // succeeds; the refund settlement is clamped to the vault's spUSDC balance (src 784) and is a
    // silent no-op while the balance is 0.
    function test_processPendingDeposits_fillsAfterTakeRemovedBacking() public {
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
        assertEq(vault.firstPendingDepositCancellationId(),                 0);

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
        assertEq(vault.firstPendingDepositCancellationId(),                 1);
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

    // Settling an earlier cancel after a take is paid with a later depositor's backing (known
    // F-2); the later depositor's own refund then waits for the taker.
    function test_requestDepositCancellation_earlyCancelAfterTakeStrandsLaterDepositor() public {
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
        assertEq(vault.firstPendingDepositCancellationId(),                 1);
        _assertQueueConsistent();

        _returnToVault(S_100K);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob),                          A_100K);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),                 2);
    }

    // The refund settlement is bounded by the vault's spUSDC balance and pays partially, leaving
    // the remainder open at the cancelled head.
    function test_processPendingDepositCancellations_partialRefundWhenBackingShort() public {
        uint256 a = _queue(alice, HUNDRED_K);
        _take(S_100K / 2);
        assertEq(_vaultSpUsdc(), 47_726_634_557);

        uint256 cancelId = _cancel(alice, a);

        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, 47_726_634_557, 49_999_999_999);

        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),                        49_999_999_999);
        assertEq(_cancelledShares(cancelId),                   47_726_634_557);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 47_726_634_557);
        assertEq(vault.firstPendingDepositCancellationId(),                 0);
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
        assertEq(vault.firstPendingDepositCancellationId(),                 1);
        _assertQueueConsistent();
    }

    // Capacity -> spUSDC conversion (src 744) rounds down twice, so filling S spUSDC shares needs
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
        assertEq(vault.firstPendingDepositId(),                 1);

        // The 2 leftover capacity shares convert to 1 spUSDC share: bob's deposit of 2 USDC
        // (1 spUSDC share) is filled with 0 spPRIME (F-4) and bob's entry is deleted.
        assertEq(spUsdc.convertToShares(2), 1);
        uint256 bobId = _deposit(bob, 2);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(_shares(bobId),       0);
        assertEq(usdc.balanceOf(bob),  0);
        assertEq(_vaultSpUsdc(),       S_1M + 1);
        assertEq(vault.firstPendingDepositId(),  2);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(bobId, bob);
        _assertQueueConsistent();
    }

    // LOW (DQ-1, still present): a deposit sized to exactly fit the capacity is 1 spUSDC share short
    // because of the src 744 double rounding. That 1-share remainder is non-zero, so the head walk
    // (src 728) stops on it and every later depositor is queued regardless of free capacity until
    // the rebalancer processes the dust, which mints 0 (F-4).
    function test_BUG_exactFitCapacityLeavesDustThatBlocksInstantFills() public {
        _setCapacity(SH_1M);
        uint256 aliceId = _deposit(alice, ONE_M);

        assertEq(vault.balanceOf(alice),              SH_1M - 2);
        assertEq(_shares(aliceId),                    1);
        assertEq(vault.pendingDepositSavingsShares(), 1);
        assertEq(vault.availableCapacity(),           2);
        assertEq(vault.firstPendingDepositId(),                 0);

        // Open capacity for everyone; bob is still fully queued behind 1 wei of alice's dust.
        _setCapacity(type(uint128).max);
        assertFalse(_nextRequestIsInstant());
        uint256 bobId = _deposit(bob, HUNDRED_K);

        assertEq(vault.balanceOf(bob), 0);
        assertEq(_shares(bobId),       S_100K);
        assertEq(vault.firstPendingDepositId(),  0);

        // Rebalancer clears it: alice's 1 share mints 0, bob fills.
        vm.expectEmit(address(vault));
        emit Deposit(alice, alice, 1, 0);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice), SH_1M - 2);
        assertEq(vault.balanceOf(bob),   SH_100K);
        assertEq(vault.firstPendingDepositId(),    2);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        _assertQueueConsistent();
    }

    // Same jam, user-triggered: at full capacity a 2-wei deposit leaves 1 spUSDC share at the head.
    // Cancelling the dust (owner or guardian) is the only way out besides the planner.
    function test_BUG_twoWeiDepositAtFullCapacityJamsInstantPath() public {
        _setCapacity(SH_1M + 2);
        _deposit(alice, ONE_M);
        assertEq(vault.availableCapacity(), 2);
        assertEq(vault.firstPendingDepositId(),       1);

        // 4 USDC wei -> 3 spUSDC shares; remaining_ for capacity 2 is 1 share -> 2 shares left.
        assertEq(spUsdc.convertToShares(4), 3);
        uint256 evilId = _deposit(eve, 4);
        assertEq(_shares(evilId),           2);
        assertEq(vault.balanceOf(eve),      0);  // the 1-share fill minted 0 (F-4)
        assertEq(vault.firstPendingDepositId(),       1);

        _setCapacity(type(uint128).max);
        uint256 bobId = _deposit(bob, HUNDRED_K);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(_shares(bobId),       S_100K);

        // Guardian clears the jam by cancelling the dust: the head walks onto bob, who is then
        // filled by the planner only (requests already made never re-check).
        vm.prank(guardian);
        vault.requestDepositCancellation(evilId, eve);
        assertEq(vault.firstPendingDepositId(), 2);

        uint256 carolId = _deposit(carol, HUNDRED_K);
        assertEq(carolId, 3);
        assertEq(vault.balanceOf(carol), 0);  // still queued behind bob
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(bob),   SH_100K);
        assertEq(vault.balanceOf(carol), SH_100K);
        _assertQueueConsistent();
    }

    // Zero-asset request (known F-5): a ghost entry while someone is queued ahead.
    function test_requestDeposit_zeroAssetsCreatesGhostEntry() public {
        _queue(alice, ONE_M);
        _fund(bob, 0);

        vm.expectEmit(address(vault));
        emit DepositRequest(bob, bob, 1, 0, 0);

        uint256 id = _ghost(bob);

        assertEq(id, 1);
        assertEq(_shares(id), 0);
        assertEq(vault.pendingDepositSavingsShares(), S_1M);
        assertEq(vault.firstPendingDepositId(), 0);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(id, bob);
    }

    /**********************************************************************************************/
    /*** H11: fuzz                                                                              ***/
    /**********************************************************************************************/

    function testFuzz_requestDeposit_instantFillNeverExceedsCapacity(
        uint256 cap, uint256 amt1, uint256 amt2, uint256 amt3
    ) public {
        cap  = bound(cap,  0, 5_000_000e6);
        amt1 = bound(amt1, 0, 2_000_000e6);
        amt2 = bound(amt2, 0, 2_000_000e6);
        amt3 = bound(amt3, 0, 2_000_000e6);

        _setCapacity(cap);

        address[3] memory users = [alice, bob, carol];
        uint256[3] memory amts  = [amt1, amt2, amt3];

        for (uint256 i; i < 3; ++i) {
            bool    instant   = _nextRequestIsInstant();
            uint256 fillable  = _remainingForCapacity(vault.availableCapacity());
            uint256 s         = spUsdc.convertToShares(amts[i]);
            uint256 supplyBef = vault.totalSupply();

            uint256 id = _deposit(users[i], amts[i]);

            uint256 filled = instant ? (s < fillable ? s : fillable) : 0;
            (, uint256 expShares) = _fillOf(filled);

            assertEq(_shares(id),                  s - filled);
            assertEq(vault.balanceOf(users[i]),    expShares);
            assertEq(vault.totalSupply(),          supplyBef + expShares);
            assertLe(vault.totalSupply(),          cap);
            // The fill loop only runs with capacity (src 752): then a fully filled or ghost entry
            // moves the head past itself; with no capacity the head is left where it was.
            if (instant && s - filled == 0 && fillable != 0) assertEq(vault.firstPendingDepositId(), id + 1);
            if (instant && fillable == 0) assertEq(vault.firstPendingDepositId(), id);
            _assertQueueConsistent();
        }
    }

    // Random deposits (including ghosts), cancels, refund settlements, fills and capacity raises.
    // Checks after every step: pendingDepositSavingsShares == sum(open), the same for the
    // cancelled queue, every entry before each head is zero, heads never exceed lengths, head
    // never decreases, supply <= capacity, and USDC refunded == spUSDC value of settled shares.
    function testFuzz_processPendingDeposits_pendingEqualsSumOfOpenEntries(uint256 seed) public {
        uint256 cap = bound(uint256(keccak256(abi.encode(seed, "cap"))), 0, 3_000_000e6);
        _setCapacity(cap);

        address[5] memory users = [alice, bob, carol, dave, eve];
        for (uint256 i; i < 5; ++i) _fund(users[i], 0);

        uint256 len;

        for (uint256 step; step < 16; ++step) {
            uint256 r  = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 6;

            if (op == 0 || op == 1) {
                address who = users[(r >> 8) % 5];
                uint256 amt = (r >> 16) % 7 == 0 ? 0 : bound(r >> 16, 1, 800_000e6);
                bool    instant  = _nextRequestIsInstant();
                uint256 fillable = _remainingForCapacity(vault.availableCapacity());
                uint256 balBef   = vault.balanceOf(who);
                uint256 id       = _deposit(who, amt);
                len++;
                assertEq(id, len - 1);
                if (!instant) assertEq(vault.balanceOf(who), balBef);  // queued, nothing minted
                if (instant && _shares(id) == 0 && fillable != 0) {
                    assertEq(vault.firstPendingDepositId(), id + 1);
                }
                if (instant && fillable == 0) assertEq(vault.firstPendingDepositId(), id);
            } else if (op == 2 && len != 0) {
                uint256 id = (r >> 8) % len;
                (address owner, , uint256 s) = _depositRequest(id);
                if (s != 0) {
                    uint256 pendBef  = vault.pendingDepositSavingsShares();
                    uint256 cPendBef = vault.pendingCancelledDepositSavingsShares();
                    uint256 headBef  = vault.firstPendingDepositId();
                    uint256 cLenBef  = _cancelledQueueLength();
                    vm.prank(owner);
                    uint256 cancelId = vault.requestDepositCancellation(id, owner);
                    assertEq(cancelId, cLenBef);
                    assertEq(_cancelledShares(cancelId), s);
                    assertEq(vault.pendingDepositSavingsShares(), pendBef - s);
                    assertEq(vault.pendingCancelledDepositSavingsShares(), cPendBef + s);
                    if (id == headBef) assertGt(vault.firstPendingDepositId(), headBef);
                    else assertEq(vault.firstPendingDepositId(), headBef);
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
                uint256 maxSS  = bound(r >> 8,  0, 2_000_000e6);
                uint256 maxReq = bound(r >> 72, 0, 6);
                if ((r >> 80) % 3 == 0) {
                    cap = bound(r >> 88, 0, 3_000_000e6);
                    if (cap >= vault.totalSupply()) _setCapacity(cap);  // never below supply here
                    else cap = vault.maxCapacity();
                }
                uint256 headBef = vault.firstPendingDepositId();
                uint256 spBef   = _vaultSpUsdc();
                _processDeposits(maxSS, maxReq);
                assertGe(vault.firstPendingDepositId(), headBef);
                assertEq(_vaultSpUsdc(), spBef);  // fills never move spUSDC
            }

            _assertQueueConsistent();
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

}
