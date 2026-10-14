// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../lib/forge-std/src/StdError.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

/// @dev Cancelled-deposit queue tests for `SparkPrimeVault` (refactor/more-simplifying @ ff828d2).
///
///      Harness indexes (frozen at RAY after setUp):
///        spUSDC  chi_s = 1.047633055711877768967605062e27
///        spPRIME chi_p = 1.009687768242461209408770821e27
///
///      Reference conversions at those indexes (all floor):
///        1_000_000e6 USDC -> 954_532_691_143 spUSDC shares -> redeem: 999_999_999_999 USDC
///          100_000e6 USDC ->  95_453_269_114 spUSDC shares -> redeem:  99_999_999_999 USDC
contract CancelledDepositQueueTest is LocalTestBase {

    event CancelDepositRequest(uint256 indexed depositRequestId, uint256 cancelRequestId);

    event DepositCancellation(
        address indexed owner,
        address indexed recipient,
        uint256         savingsShares,
        uint256         assets
    );

    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address carol   = makeAddr("carol");
    address mallory = makeAddr("mallory");

    uint256 constant ONE_M     = 1_000_000e6;
    uint256 constant HUNDRED_K = 100_000e6;

    uint256 constant S_1M   = 954_532_691_143;  // spUSDC shares for ONE_M
    uint256 constant S_100K = 95_453_269_114;   // spUSDC shares for HUNDRED_K

    uint256 constant A_1M   = 999_999_999_999;  // USDC paid when S_1M is redeemed (floor)
    uint256 constant A_100K = 99_999_999_999;

    uint256 constant SH_1M = 990_405_184_109;   // spPRIME shares minted for S_1M on fill

    function setUp() public override {
        super.setUp();
        _setCapacity(0);  // everything queues unless a test opens capacity
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _cancel(address who, uint256 id, address recipient) internal returns (uint256 cid) {
        vm.prank(who);
        cid = vault.cancelDepositRequest(id, recipient);
    }

    function _cancelledLength() internal view returns (uint256 len) {
        while (true) {
            try vault.cancelledDepositQueue(len) { len++; } catch { return len; }
        }
    }

    function _depositLength() internal view returns (uint256 len) {
        while (true) {
            try vault.depositQueue(len) { len++; } catch { return len; }
        }
    }

    function _sumOpenCancelled() internal view returns (uint256 sum) {
        uint256 len = _cancelledLength();
        for (uint256 i; i < len; ++i) {
            ( ,, uint256 shares ) = vault.cancelledDepositQueue(i);
            sum += shares;
        }
    }

    function _sumOpenDeposits() internal view returns (uint256 sum) {
        uint256 len = _depositLength();
        for (uint256 i; i < len; ++i) {
            ( ,, uint256 shares ) = vault.depositQueue(i);
            sum += shares;
        }
    }

    /**********************************************************************************************/
    /*** 1. Happy path                                                                          ***/
    /**********************************************************************************************/

    function test_cancelDepositRequest_queuesRefundAndSettleIsExact() public {
        uint256 id = _deposit(alice, ONE_M);

        assertEq(id,                                           0);
        assertEq(_vaultSpUsdc(),                               S_1M);
        assertEq(vault.pendingDepositSavingsShares(),          S_1M);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.depositHead(),                          0);
        assertEq(vault.cancelledDepositHead(),                 0);
        assertEq(usdc.balanceOf(alice),                        0);

        vm.expectEmit(address(vault));
        emit CancelDepositRequest(0, 0);
        vm.prank(alice);
        uint256 cancelId = vault.cancelDepositRequest(id, alice);

        assertEq(cancelId, 0);

        ( address owner, address recipient, uint256 shares ) = _depositRequest(0);
        assertEq(owner,     address(0));
        assertEq(recipient, address(0));
        assertEq(shares,    0);

        ( owner, recipient, shares ) = _cancelledDepositRequest(0);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    S_1M);

        // Nothing paid yet: spUSDC still in the vault, alice still has no USDC.
        assertEq(_vaultSpUsdc(),                               S_1M);
        assertEq(usdc.balanceOf(alice),                        0);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
        assertEq(vault.depositHead(),                          1);   // advanced past the cancelled head
        assertEq(vault.cancelledDepositHead(),                 0);

        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, S_1M, A_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(alice),                        A_1M);  // 1 wei floor loss vs ONE_M
        assertEq(_vaultSpUsdc(),                               0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.cancelledDepositHead(),                 1);

        ( owner, recipient, shares ) = _cancelledDepositRequest(0);
        assertEq(owner,     address(0));
        assertEq(recipient, address(0));
        assertEq(shares,    0);
    }

    /**********************************************************************************************/
    /*** 2. FIFO, partial settlement, limits, no-ops                                            ***/
    /**********************************************************************************************/

    function test_processCancelledDepositQueue_partialThenComplete() public {
        uint256 idA = _deposit(alice, ONE_M);
        uint256 idB = _deposit(bob,   HUNDRED_K);

        assertEq(_cancel(alice, idA, alice), 0);
        assertEq(_cancel(bob,   idB, bob),   1);

        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M + S_100K);
        assertEq(vault.depositHead(),                          2);

        uint256 half = S_1M / 2;  // 477_266_345_571
        uint256 halfAssets = spUsdc.convertToAssets(half);
        assertEq(halfAssets, 499_999_999_998);

        _processCancelledDeposits(half, type(uint256).max);

        assertEq(usdc.balanceOf(alice),                        halfAssets);
        assertEq(usdc.balanceOf(bob),                          0);
        assertEq(vault.cancelledDepositHead(),                 0);  // partial: head stays
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M - half + S_100K);
        assertEq(_vaultSpUsdc(),                               S_1M - half + S_100K);

        ( ,, uint256 shares ) = _cancelledDepositRequest(0);
        assertEq(shares, S_1M - half);

        uint256 secondAssets = spUsdc.convertToAssets(S_1M - half);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        // Two floor redeems lose at most 1 wei more than one redeem of the whole.
        assertEq(usdc.balanceOf(alice),                        halfAssets + secondAssets);
        assertGe(usdc.balanceOf(alice),                        A_1M - 1);
        assertEq(usdc.balanceOf(bob),                          A_100K);
        assertEq(vault.cancelledDepositHead(),                 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(),                               0);
    }

    function test_processCancelledDepositQueue_maxRequestsHonoured() public {
        _cancel(alice, _deposit(alice, HUNDRED_K), alice);
        _cancel(bob,   _deposit(bob,   HUNDRED_K), bob);
        _cancel(carol, _deposit(carol, HUNDRED_K), carol);

        _processCancelledDeposits(type(uint256).max, 2);

        assertEq(usdc.balanceOf(alice),                        A_100K);
        assertEq(usdc.balanceOf(bob),                          A_100K);
        assertEq(usdc.balanceOf(carol),                        0);
        assertEq(vault.cancelledDepositHead(),                 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_100K);

        _processCancelledDeposits(type(uint256).max, 0);  // maxRequests 0: no-op
        assertEq(vault.cancelledDepositHead(), 2);
        assertEq(usdc.balanceOf(carol),        0);

        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(carol),        A_100K);
        assertEq(vault.cancelledDepositHead(), 3);
    }

    function test_processCancelledDepositQueue_emptyQueueNoOp() public {
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.cancelledDepositHead(), 0);
        assertEq(_cancelledLength(),           0);

        // Queue fully settled, call again: no-op, head unchanged.
        _cancelDepositAndSettle(alice, _deposit(alice, HUNDRED_K));
        assertEq(vault.cancelledDepositHead(), 1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.cancelledDepositHead(), 1);
        assertEq(usdc.balanceOf(alice),        A_100K);
    }

    // Zero entries at or after `cancelledDepositHead` are unreachable: a cancel always pushes
    // `shares != 0` and an entry is only deleted once fully paid, after which the head passes it.
    function test_processCancelledDepositQueue_zeroEntriesOnlyBehindHead() public {
        _cancel(alice, _deposit(alice, HUNDRED_K), alice);
        _cancel(bob,   _deposit(bob,   HUNDRED_K), bob);
        _processCancelledDeposits(type(uint256).max, 1);

        ( ,, uint256 s0 ) = _cancelledDepositRequest(0);
        ( ,, uint256 s1 ) = _cancelledDepositRequest(1);
        assertEq(s0, 0);
        assertEq(s1, S_100K);
        assertEq(vault.cancelledDepositHead(), 1);
    }

    /**********************************************************************************************/
    /*** 3. Budget is spUSDC's maxRedeem (V2-6 fixed at ff828d2)                                ***/
    /**********************************************************************************************/

    // `_processCancelledDepositQueue` (line 784) now budgets by `spUSDC.maxRedeem(vault)` =
    // min(floor(liquidity * RAY / chi_s), vault balance). When spUSDC's USDC is deployed
    // elsewhere the head entry is paid as far as the liquidity goes, stays at the head, and is
    // completed once liquidity returns.
    function test_processCancelledDepositQueue_paysWhatLiquidityAllows() public {
        _cancel(alice, _deposit(alice, ONE_M), alice);

        // spUSDC holds exactly alice's 1M USDC; its taker deploys half of it.
        assertEq(usdc.balanceOf(address(spUsdc)), ONE_M);
        _drainSpUsdcLiquidity(500_000e6);

        uint256 payable_ = spUsdc.maxRedeem(address(vault));
        assertEq(payable_, 477_266_345_571);          // < S_1M = 954_532_691_143
        assertEq(spUsdc.convertToAssets(payable_), 499_999_999_998);

        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, payable_, 499_999_999_998);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(alice),                        499_999_999_998);
        assertEq(usdc.balanceOf(address(spUsdc)),              2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M - payable_);
        assertEq(vault.cancelledDepositHead(),                 0);   // partial: head stays
        ( ,, uint256 left ) = _cancelledDepositRequest(0);
        assertEq(left, 477_266_345_572);

        // No liquidity, no payment, no revert.
        _drainAllSpUsdcLiquidity();
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),        499_999_999_998);
        assertEq(vault.cancelledDepositHead(), 0);

        // Liquidity returns: the remainder is paid and the entry closes.
        _returnSpUsdcLiquidity(500_000e6 + 2);
        assertGe(spUsdc.maxRedeem(address(vault)), left);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(alice),                        499_999_999_998 + 500_000_000_000);
        assertGe(usdc.balanceOf(alice),                        A_1M - 1);  // two floors, <= 1 wei
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.cancelledDepositHead(),                 1);
        assertEq(_vaultSpUsdc(),                               0);
    }

    function test_processCancelledDepositQueue_batchPaysFirstFullyAndSecondPartially() public {
        _cancel(alice, _deposit(alice, ONE_M),     alice);
        _cancel(bob,   _deposit(bob,   HUNDRED_K), bob);

        // Liquidity 1_040_000e6 covers alice (999_999_999_999) but not alice + bob.
        _drainSpUsdcLiquidity(60_000e6);
        assertEq(usdc.balanceOf(address(spUsdc)), 1_040_000e6);

        uint256 budget = spUsdc.maxRedeem(address(vault));
        assertEq(budget, 992_713_998_789);
        uint256 bobShares = budget - S_1M;
        assertEq(bobShares, 38_181_307_646);
        assertEq(spUsdc.convertToAssets(bobShares), 40_000_000_000);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(alice),                        A_1M);
        assertEq(usdc.balanceOf(bob),                          40_000_000_000);
        assertEq(A_1M + 40_000_000_000,                        1_039_999_999_999);  // <= liquidity
        assertEq(usdc.balanceOf(address(spUsdc)),              1);
        assertEq(vault.cancelledDepositHead(),                 1);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_100K - bobShares);
        ( ,, uint256 bobLeft ) = _cancelledDepositRequest(1);
        assertEq(bobLeft, S_100K - bobShares);

        _returnSpUsdcLiquidity(60_000e6);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),          40_000_000_000 + spUsdc.convertToAssets(bobLeft));
        assertGe(usdc.balanceOf(bob),          A_100K - 1);
        assertEq(vault.cancelledDepositHead(), 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // The planner's own cap still applies on top of the liquidity clamp.
    function test_processCancelledDepositQueue_budgetIsMinOfCapAndMaxRedeem() public {
        _cancel(alice, _deposit(alice, ONE_M), alice);
        _drainSpUsdcLiquidity(500_000e6);
        uint256 maxRedeem = spUsdc.maxRedeem(address(vault));  // 477_266_345_571

        _processCancelledDeposits(S_100K, type(uint256).max);
        assertEq(usdc.balanceOf(alice), A_100K);

        // The clamp is recomputed from the liquidity left after the first payment.
        uint256 budget = spUsdc.maxRedeem(address(vault));
        assertEq(budget, spUsdc.convertToShares(500_000e6 - A_100K));
        // The first floor left 1 wei of liquidity behind, worth at most one extra share.
        assertGe(budget, maxRedeem - S_100K);
        assertLe(budget, maxRedeem - S_100K + 1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), A_100K + spUsdc.convertToAssets(budget));
        assertLe(usdc.balanceOf(alice), 500_000e6);
        assertEq(vault.cancelledDepositHead(), 0);
    }

    // Residual floor mismatch (same family as C-1 on the redeem queue, benign here): maxRedeem
    // floors liquidity into shares, so when the liquidity equals the exact assets owed the clamp
    // comes out one share short. Each fill then pays floor(s * chi_s / RAY) and
    // sum(floor) <= floor(sum) <= liquidity, so a batch can never revert. Direction is the safe
    // one: the queue under-pays by dust and needs one more call, never a revert.
    function testFuzz_processCancelledDepositQueue_neverRevertsOnLiquidity(
        uint64[6] calldata amounts,
        uint256   liquidityKept,
        uint8     maxRequests,
        uint32    warpSecs
    ) public {
        address[3] memory users = [alice, bob, carol];
        uint256 owed;
        for (uint256 i; i < 6; ++i) {
            uint256 amt = bound(uint256(amounts[i]), 2, 2_000_000e6);  // 1 wei -> 0 spUSDC shares
            address u   = users[i % 3];
            _cancel(u, _deposit(u, amt), u);
            owed += amt;
        }
        assertEq(usdc.balanceOf(address(spUsdc)), owed);

        _setSpUsdcVsr(TEN_PCT_VSR);
        _warpAndDrip(bound(uint256(warpSecs), 0, 365 days));

        uint256 keep = bound(liquidityKept, 0, owed);
        _drainSpUsdcLiquidity(owed - keep);

        uint256 budget = spUsdc.maxRedeem(address(vault));
        assertLe(spUsdc.convertToAssets(budget), keep);

        uint256 before = usdc.balanceOf(alice) + usdc.balanceOf(bob) + usdc.balanceOf(carol);
        _processCancelledDeposits(type(uint256).max, bound(uint256(maxRequests), 0, 8));  // must not revert
        uint256 paid = usdc.balanceOf(alice) + usdc.balanceOf(bob) + usdc.balanceOf(carol) - before;

        assertLe(paid, keep);
        assertLe(paid, spUsdc.convertToAssets(budget));
        assertEq(vault.pendingCancelledDepositSavingsShares(), _sumOpenCancelled());

        // Whatever is left can be paid once liquidity (plus the accrued yield) is back.
        _returnSpUsdcLiquidity(2 * owed);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.cancelledDepositHead(), 6);
    }

    /**********************************************************************************************/
    /*** 4. take() drains the cancelled queue's backing                                         ***/
    /**********************************************************************************************/

    // The cancelled queue is not ring-fenced from `take()`. Settlement then silently pays
    // nothing (budget = min(max, balance) = 0; no revert), and the refund waits until spUSDC
    // is returned.
    function test_take_afterCancel_settleIsNoOpUntilSpUsdcReturned() public {
        _cancel(alice, _deposit(alice, ONE_M), alice);

        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
        assertEq(_vaultSpUsdc(),                               S_1M);

        _take(S_1M);  // taker can take 100% of the refund's backing
        assertEq(_vaultSpUsdc(),          0);
        assertEq(spUsdc.balanceOf(taker), S_1M);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);  // no revert, no payment
        assertEq(usdc.balanceOf(alice),                        0);
        assertEq(vault.cancelledDepositHead(),                 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);

        // Partial return: pays exactly what came back.
        _returnToVault(S_100K);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),                        A_100K);
        assertEq(vault.cancelledDepositHead(),                 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M - S_100K);

        _returnToVault(S_1M - S_100K);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),                        A_100K + 899_999_999_999);
        assertEq(vault.cancelledDepositHead(),                 1);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    /**********************************************************************************************/
    /*** 5. Priority: cancelled-deposit queue vs redeem queue                                   ***/
    /**********************************************************************************************/

    // Both queues draw from the same spUSDC balance; neither reserves anything for the other.
    // Whoever the planner processes first is paid first.
    function _setupShortfall() internal returns (uint256 redeemShares) {
        _setCapacity(type(uint128).max);
        _deposit(alice, ONE_M);                       // instant: alice holds SH_1M
        _setCapacity(vault.totalSupply());            // close capacity
        _cancel(bob, _deposit(bob, HUNDRED_K), bob);  // bob queued then cancelled
        redeemShares = vault.balanceOf(alice);
        assertEq(redeemShares, SH_1M);
        _requestRedeem(alice, redeemShares);

        assertEq(_vaultSpUsdc(), S_1M + S_100K);
        _take(S_100K + S_100K);                       // shortfall: 100k short of paying both
        assertEq(_vaultSpUsdc(), S_1M - S_100K);
    }

    function test_priority_redeemsFirstStarvesCancelledQueue() public {
        _setupShortfall();

        uint256 liquid = vault.availableLiquidAssets();  // maxWithdraw(vault) in USDC
        assertEq(liquid, 899_999_999_999);

        _processRedeems(type(uint256).max, type(uint256).max);
        uint256 alicePaid = usdc.balanceOf(alice);
        assertEq(alicePaid, 899_999_999_998);  // alice partially paid, 1 wei spUSDC floor
        assertEq(vault.redeemHead(), 0);

        uint256 left = _vaultSpUsdc();
        assertLe(left, 1);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertLe(usdc.balanceOf(bob), 1);  // bob gets at most the dust
        assertEq(vault.cancelledDepositHead(), 0);
    }

    function test_priority_cancelledFirstStarvesRedeemQueue() public {
        _setupShortfall();

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),          A_100K);  // bob paid in full
        assertEq(vault.cancelledDepositHead(), 1);
        assertEq(_vaultSpUsdc(),               S_1M - 2 * S_100K);

        uint256 liquid = vault.availableLiquidAssets();
        assertEq(liquid, 799_999_999_999);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), 799_999_999_998);
        assertEq(vault.redeemHead(),    0);  // alice partially paid, still queued
        assertGt(vault.pendingRedeemShares(), 0);
    }

    /**********************************************************************************************/
    /*** 6. Yield accrues to the canceller                                                      ***/
    /**********************************************************************************************/

    function test_processCancelledDepositQueue_yieldWhileQueuedGoesToCanceller() public {
        _cancel(alice, _deposit(alice, ONE_M), alice);

        _setSpUsdcVsr(TEN_PCT_VSR);
        _warpAndDrip(365 days);

        uint256 expected = spUsdc.convertToAssets(S_1M);
        assertGt(expected, 1_099_000e6);
        assertLt(expected, 1_101_000e6);

        // spUSDC needs the USDC to exist locally to pay the yield out. With liquidity equal to
        // the exact assets owed, `maxRedeem` = floor(expected * RAY / chi_s) is one share short
        // of S_1M (the product S_1M * chi_s / RAY is not an integer), so the clamp (line 784)
        // pays expected - 1 and leaves 1 spUSDC share (1 wei) queued.
        _returnSpUsdcLiquidity(expected - ONE_M);
        assertEq(usdc.balanceOf(address(spUsdc)), expected);
        assertEq(spUsdc.maxRedeem(address(vault)), S_1M - 1);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),                        expected - 1);
        assertEq(_vaultSpUsdc(),                               1);
        assertEq(vault.cancelledDepositHead(),                 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 1);

        // 1 wei of liquidity is left but floor(1 * RAY / chi_s) == 0 shares: still nothing.
        assertEq(usdc.balanceOf(address(spUsdc)), 1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), expected - 1);

        // One more wei of liquidity closes it: the canceller ends with exactly `expected`.
        _returnSpUsdcLiquidity(1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),        expected);
        assertEq(_vaultSpUsdc(),               0);
        assertEq(vault.cancelledDepositHead(), 1);
    }

    /**********************************************************************************************/
    /*** 7. Pause                                                                               ***/
    /**********************************************************************************************/

    function test_cancelDepositRequest_revertsWhenPaused() public {
        uint256 id = _deposit(alice, ONE_M);
        _pause();
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelDepositRequest(id, alice);
    }

    function test_processCancelledDepositQueue_revertsWhenPaused() public {
        _cancel(alice, _deposit(alice, ONE_M), alice);
        _pause();
        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processCancelledDepositQueue(type(uint256).max, type(uint256).max);
        _unpause();
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), A_1M);
    }

    /**********************************************************************************************/
    /*** 8. Guardian cancel (F-1 persists; owned by CANCEL-FEES)                                ***/
    /**********************************************************************************************/

    function test_cancelDepositRequest_guardianChoosesRecipient() public {
        uint256 id = _deposit(alice, ONE_M);

        vm.prank(guardian);
        uint256 cid = vault.cancelDepositRequest(id, guardian);

        ( address owner, address recipient, uint256 shares ) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, guardian);
        assertEq(shares,    S_1M);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(guardian), A_1M);
        assertEq(usdc.balanceOf(alice),    0);
    }

    /**********************************************************************************************/
    /*** 9. Reverts                                                                             ***/
    /**********************************************************************************************/

    function test_cancelDepositRequest_doubleCancelReverts() public {
        uint256 id = _deposit(alice, ONE_M);
        _cancel(alice, id, alice);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelDepositRequest(id, alice);
    }

    function test_cancelDepositRequest_filledEntryReverts() public {
        _setCapacity(type(uint128).max);
        uint256 id = _deposit(alice, ONE_M);  // instant fill, entry deleted
        assertEq(id, 0);
        assertEq(vault.balanceOf(alice), SH_1M);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelDepositRequest(id, alice);
    }

    function test_cancelDepositRequest_zeroRecipientReverts() public {
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.cancelDepositRequest(id, address(0));
    }

    function test_cancelDepositRequest_notOwnerReverts() public {
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(mallory);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelDepositRequest(id, mallory);
    }

    function test_cancelDepositRequest_outOfRangeIdPanics() public {
        vm.prank(alice);
        vm.expectRevert(stdError.indexOOBError);
        vault.cancelDepositRequest(7, alice);
    }

    /**********************************************************************************************/
    /*** 10. Fuzz: counters track open entries                                                  ***/
    /**********************************************************************************************/

    function testFuzz_cancelledQueue_countersTrackOpenEntries(
        uint8[24]  calldata actions,
        uint64[24] calldata amounts
    ) public {
        address[3] memory users = [alice, bob, carol];
        uint256 taken;

        for (uint256 k; k < 24; ++k) {
            uint256 a   = actions[k] % 6;
            uint256 amt = uint256(amounts[k]);
            address u   = users[k % 3];

            if (a == 0) {
                // queue a deposit (capacity is 0, nothing fills)
                _deposit(u, bound(amt, 1, 1_000_000e6));
            } else if (a == 1) {
                // cancel a random open deposit entry owned by anyone (guardian path)
                uint256 len = _depositLength();
                if (len == 0) continue;
                uint256 id = amt % len;
                ( ,, uint256 s ) = _depositRequest(id);
                if (s == 0) continue;
                vm.prank(guardian);
                vault.cancelDepositRequest(id, u);
            } else if (a == 2) {
                _processCancelledDeposits(bound(amt, 0, 2_000_000e6), amt % 4);
            } else if (a == 3) {
                uint256 bal = _vaultSpUsdc();
                if (bal == 0) continue;
                uint256 t = bound(amt, 0, bal);
                _take(t);
                taken += t;
            } else if (a == 4) {
                if (taken == 0) continue;
                uint256 r = bound(amt, 0, taken);
                _returnToVault(r);
                taken -= r;
            } else {
                _warpAndDrip(bound(amt, 0, 1 days));
            }

            uint256 pendingC = vault.pendingCancelledDepositSavingsShares();
            uint256 pendingD = vault.pendingDepositSavingsShares();

            assertEq(pendingC, _sumOpenCancelled(), "cancelled counter");
            assertEq(pendingD, _sumOpenDeposits(),  "deposit counter");
            assertEq(_vaultSpUsdc() + taken, pendingC + pendingD, "spUSDC conservation");
            assertLe(vault.cancelledDepositHead(), _cancelledLength(), "cancelled head <= len");
            assertLe(vault.depositHead(),          _depositLength(),   "deposit head <= len");

            for (uint256 i; i < vault.cancelledDepositHead(); ++i) {
                ( ,, uint256 s ) = _cancelledDepositRequest(i);
                assertEq(s, 0, "zero behind cancelled head");
            }
            for (uint256 i; i < vault.depositHead(); ++i) {
                ( ,, uint256 s ) = _depositRequest(i);
                assertEq(s, 0, "zero behind deposit head");
            }
        }
    }

}
