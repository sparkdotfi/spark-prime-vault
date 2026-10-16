// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../../lib/forge-std/src/StdError.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

/// @dev Cancelled-deposit queue tests for `SparkPrimeVault` (round 5, `master` @ 0ebb452).
///
///      Round-5 semantics under test (src lines on 0ebb452):
///        - `requestDepositCancellation` (419-444): owner-only (430), recipient must be non-zero
///          (424) and not blacklisted (425); the entry is deleted and pushed to the cancellation
///          queue; the deposit head is NOT moved (no walk any more).
///        - `_processPendingDepositCancellations` (864-898): budget `min(max, spUSDC.maxRedeem
///          (vault))` (869-870), pays through `_redeemSavings` (934-945): to the recipient when it
///          can receive USDC, otherwise `redeem` to the vault itself and credit
///          `claimableAssets[recipient]` (942-944); `claim(recipient)` (524-534) pays it out.
///        - `updateDepositCancellationRecipient` (491-504): owner-only, blacklist-checked.
///
///      Harness indexes (frozen at RAY after setUp):
///        spUSDC  chi_s = 1.047633055711877768967605062e27
///        spPRIME chi_p = 1.009687768242461209408770821e27
///
///      Reference conversions at those indexes (all floor):
///        1_000_000e6 USDC -> 954_532_691_143 spUSDC shares -> redeem: 999_999_999_999 USDC
///          100_000e6 USDC ->  95_453_269_114 spUSDC shares -> redeem:  99_999_999_999 USDC
contract CancelledDepositQueueTest is LocalTestBase {

    event DepositCancellationRequest(
        uint256 indexed depositRequestId,
        uint256 indexed cancelRequestId,
        address indexed recipient
    );

    event ClaimableAssetsIncreased(address indexed recipient, uint256 increase);

    event Claim(address indexed recipient, uint256 assets);

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
        cid = vault.requestDepositCancellation(id, recipient);
    }

    function _cancelledLength() internal view returns (uint256) {
        return _cancelledDepositQueueLength();
    }

    function _depositLength() internal view returns (uint256) {
        return _depositQueueLength();
    }

    function _sumOpenCancelled() internal view returns (uint256 sum) {
        uint256 n = _cancelledDepositQueueLength();
        for (uint256 i = 0; i < n; ++i) { ( , , uint256 s) = _cancelledDepositRequest(i); sum += s; }
    }

    function _sumOpenDeposits() internal view returns (uint256 sum) {
        uint256 n = _depositQueueLength();
        for (uint256 i = 0; i < n; ++i) { ( , , uint256 s) = _depositRequest(i); sum += s; }
    }

    /**********************************************************************************************/
    /*** 1. Happy path                                                                          ***/
    /**********************************************************************************************/

    function test_requestDepositCancellation_queuesRefundAndSettleIsExact() public {
        uint256 id = _deposit(alice, ONE_M);

        assertEq(id,                                           0);
        assertEq(_vaultSpUsdc(),                               S_1M);
        assertEq(vault.pendingDepositSavingsShares(),          S_1M);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),                          0);
        assertEq(vault.firstPendingDepositCancellationId(),                 0);
        assertEq(usdc.balanceOf(alice),                        0);

        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(0, 0, alice);
        vm.prank(alice);
        uint256 cancelId = vault.requestDepositCancellation(id, alice);

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
        assertEq(vault.firstPendingDepositId(),                          0);   // head stays: no walk on master
        assertEq(vault.firstPendingDepositCancellationId(),                 0);

        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, S_1M, A_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(alice),                        A_1M);  // 1 wei floor loss vs ONE_M
        assertEq(_vaultSpUsdc(),                               0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),                 1);

        ( owner, recipient, shares ) = _cancelledDepositRequest(0);
        assertEq(owner,     address(0));
        assertEq(recipient, address(0));
        assertEq(shares,    0);
    }

    /**********************************************************************************************/
    /*** 2. FIFO, partial settlement, limits, no-ops                                            ***/
    /**********************************************************************************************/

    function test_processPendingDepositCancellations_partialThenComplete() public {
        uint256 idA = _deposit(alice, ONE_M);
        uint256 idB = _deposit(bob,   HUNDRED_K);

        assertEq(_cancel(alice, idA, alice), 0);
        assertEq(_cancel(bob,   idB, bob),   1);

        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M + S_100K);
        assertEq(vault.firstPendingDepositId(),                          0);  // head frozen on the dead slot

        uint256 half = S_1M / 2;  // 477_266_345_571
        uint256 halfAssets = spUsdc.convertToAssets(half);
        assertEq(halfAssets, 499_999_999_998);

        _processCancelledDeposits(half, type(uint256).max);

        assertEq(usdc.balanceOf(alice),                        halfAssets);
        assertEq(usdc.balanceOf(bob),                          0);
        assertEq(vault.firstPendingDepositCancellationId(),                 0);  // partial: head stays
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
        assertEq(vault.firstPendingDepositCancellationId(),                 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(),                               0);
    }

    function test_processPendingDepositCancellations_maxRequestsHonoured() public {
        _cancel(alice, _deposit(alice, HUNDRED_K), alice);
        _cancel(bob,   _deposit(bob,   HUNDRED_K), bob);
        _cancel(carol, _deposit(carol, HUNDRED_K), carol);

        _processCancelledDeposits(type(uint256).max, 2);

        assertEq(usdc.balanceOf(alice),                        A_100K);
        assertEq(usdc.balanceOf(bob),                          A_100K);
        assertEq(usdc.balanceOf(carol),                        0);
        assertEq(vault.firstPendingDepositCancellationId(),                 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_100K);

        _processCancelledDeposits(type(uint256).max, 0);  // maxRequests 0: no-op
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(usdc.balanceOf(carol),        0);

        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(carol),        A_100K);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
    }

    function test_processPendingDepositCancellations_emptyQueueNoOp() public {
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingDepositCancellationId(), 0);
        assertEq(_cancelledLength(),           0);

        // Queue fully settled, call again: no-op, head unchanged.
        _cancelDepositAndSettle(alice, _deposit(alice, HUNDRED_K));
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        assertEq(usdc.balanceOf(alice),        A_100K);
    }

    // Zero entries at or after `cancelledDepositHead` are unreachable: a cancel always pushes
    // `shares != 0` and an entry is only deleted once fully paid, after which the head passes it.
    function test_processPendingDepositCancellations_zeroEntriesOnlyBehindHead() public {
        _cancel(alice, _deposit(alice, HUNDRED_K), alice);
        _cancel(bob,   _deposit(bob,   HUNDRED_K), bob);
        _processCancelledDeposits(type(uint256).max, 1);

        ( ,, uint256 s0 ) = _cancelledDepositRequest(0);
        ( ,, uint256 s1 ) = _cancelledDepositRequest(1);
        assertEq(s0, 0);
        assertEq(s1, S_100K);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
    }

    /**********************************************************************************************/
    /*** 3. Budget is spUSDC's maxRedeem (V2-6 fixed at ff828d2)                                ***/
    /**********************************************************************************************/

    // `_processPendingDepositCancellations` (line 784) now budgets by `spUSDC.maxRedeem(vault)` =
    // min(floor(liquidity * RAY / chi_s), vault balance). When spUSDC's USDC is deployed
    // elsewhere the head entry is paid as far as the liquidity goes, stays at the head, and is
    // completed once liquidity returns.
    function test_processPendingDepositCancellations_paysWhatLiquidityAllows() public {
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
        assertEq(vault.firstPendingDepositCancellationId(),                 0);   // partial: head stays
        ( ,, uint256 left ) = _cancelledDepositRequest(0);
        assertEq(left, 477_266_345_572);

        // No liquidity, no payment, no revert.
        _drainAllSpUsdcLiquidity();
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),        499_999_999_998);
        assertEq(vault.firstPendingDepositCancellationId(), 0);

        // Liquidity returns: the remainder is paid and the entry closes.
        _returnSpUsdcLiquidity(500_000e6 + 2);
        assertGe(spUsdc.maxRedeem(address(vault)), left);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(alice),                        499_999_999_998 + 500_000_000_000);
        assertGe(usdc.balanceOf(alice),                        A_1M - 1);  // two floors, <= 1 wei
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),                 1);
        assertEq(_vaultSpUsdc(),                               0);
    }

    function test_processPendingDepositCancellations_batchPaysFirstFullyAndSecondPartially() public {
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
        assertEq(vault.firstPendingDepositCancellationId(),                 1);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_100K - bobShares);
        ( ,, uint256 bobLeft ) = _cancelledDepositRequest(1);
        assertEq(bobLeft, S_100K - bobShares);

        _returnSpUsdcLiquidity(60_000e6);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),          40_000_000_000 + spUsdc.convertToAssets(bobLeft));
        assertGe(usdc.balanceOf(bob),          A_100K - 1);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // The planner's own cap still applies on top of the liquidity clamp.
    function test_processPendingDepositCancellations_budgetIsMinOfCapAndMaxRedeem() public {
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
        assertEq(vault.firstPendingDepositCancellationId(), 0);
    }

    // Residual floor mismatch (same family as C-1 on the redeem queue, benign here): maxRedeem
    // floors liquidity into shares, so when the liquidity equals the exact assets owed the clamp
    // comes out one share short. Each fill then pays floor(s * chi_s / RAY) and
    // sum(floor) <= floor(sum) <= liquidity, so a batch can never revert. Direction is the safe
    // one: the queue under-pays by dust and needs one more call, never a revert.
    function testFuzz_processPendingDepositCancellations_neverRevertsOnLiquidity(
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
        assertEq(vault.firstPendingDepositCancellationId(), 6);
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
        assertEq(vault.firstPendingDepositCancellationId(),                 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);

        // Partial return: pays exactly what came back.
        _returnToVault(S_100K);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),                        A_100K);
        assertEq(vault.firstPendingDepositCancellationId(),                 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M - S_100K);

        _returnToVault(S_1M - S_100K);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),                        A_100K + 899_999_999_999);
        assertEq(vault.firstPendingDepositCancellationId(),                 1);
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
        assertEq(vault.firstPendingRedeemId(), 0);

        uint256 left = _vaultSpUsdc();
        assertLe(left, 1);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertLe(usdc.balanceOf(bob), 1);  // bob gets at most the dust
        assertEq(vault.firstPendingDepositCancellationId(), 0);
    }

    function test_priority_cancelledFirstStarvesRedeemQueue() public {
        _setupShortfall();

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),          A_100K);  // bob paid in full
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        assertEq(_vaultSpUsdc(),               S_1M - 2 * S_100K);

        uint256 liquid = vault.availableLiquidAssets();
        assertEq(liquid, 799_999_999_999);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), 799_999_999_998);
        assertEq(vault.firstPendingRedeemId(),    0);  // alice partially paid, still queued
        assertGt(vault.pendingRedeemShares(), 0);
    }

    /**********************************************************************************************/
    /*** 6. Yield accrues to the canceller                                                      ***/
    /**********************************************************************************************/

    function test_processPendingDepositCancellations_yieldWhileQueuedGoesToCanceller() public {
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
        assertEq(vault.firstPendingDepositCancellationId(),                 0);
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
        assertEq(vault.firstPendingDepositCancellationId(), 1);
    }

    /**********************************************************************************************/
    /*** 7. Pause                                                                               ***/
    /**********************************************************************************************/

    function test_requestDepositCancellation_revertsWhenPaused() public {
        uint256 id = _deposit(alice, ONE_M);
        _pause();
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDepositCancellation(id, alice);
    }

    function test_processPendingDepositCancellations_revertsWhenPaused() public {
        _cancel(alice, _deposit(alice, ONE_M), alice);
        _pause();
        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);
        _unpause();
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), A_1M);
    }

    /**********************************************************************************************/
    /*** 8. Guardian cancel path removed (V2-2 / F-1 fixed on master)                          ***/
    /**********************************************************************************************/

    function test_fixed_requestDepositCancellation_guardianCannotCancel() public {
        uint256 id = _deposit(alice, ONE_M);

        address[3] memory named = [guardian, bob, alice];
        for (uint256 i; i < 3; ++i) {
            vm.prank(guardian);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.requestDepositCancellation(id, named[i]);
        }

        ( address owner, address recipient, uint256 shares ) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    S_1M);
        assertEq(_cancelledLength(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);

        // The owner can, and the pause guard sits before the ownership check.
        _pause();
        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDepositCancellation(id, alice);
        _unpause();

        uint256 cid = _cancel(alice, id, alice);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(cid, 0);
        assertEq(usdc.balanceOf(guardian), 0);
        assertEq(usdc.balanceOf(alice),    A_1M);
    }

    /**********************************************************************************************/
    /*** 9. Reverts                                                                             ***/
    /**********************************************************************************************/

    function test_requestDepositCancellation_doubleCancelReverts() public {
        uint256 id = _deposit(alice, ONE_M);
        _cancel(alice, id, alice);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(id, alice);
    }

    function test_requestDepositCancellation_filledEntryReverts() public {
        _setCapacity(type(uint128).max);
        uint256 id = _deposit(alice, ONE_M);  // instant fill, entry deleted
        assertEq(id, 0);
        assertEq(vault.balanceOf(alice), SH_1M);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(id, alice);
    }

    function test_requestDepositCancellation_zeroRecipientReverts() public {
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/zero-recipient");
        vault.requestDepositCancellation(id, address(0));
    }

    function test_requestDepositCancellation_notOwnerReverts() public {
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(mallory);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(id, mallory);
    }

    function test_requestDepositCancellation_outOfRangeIdPanics() public {
        vm.prank(alice);
        vm.expectRevert(stdError.indexOOBError);
        vault.requestDepositCancellation(7, alice);
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
                // cancel a random open deposit entry: only its owner can (master), the guardian
                // and a non-owner user get `not-authorized`
                uint256 len = _depositLength();
                if (len == 0) continue;
                uint256 id = amt % len;
                ( address o,, uint256 s ) = _depositRequest(id);
                if (s == 0) continue;
                vm.prank(guardian);
                vm.expectRevert("SparkPrimeVault/not-authorized");
                vault.requestDepositCancellation(id, o);
                if (o != u) {
                    vm.prank(u);
                    vm.expectRevert("SparkPrimeVault/not-authorized");
                    vault.requestDepositCancellation(id, u);
                }
                uint256 headBef = vault.firstPendingDepositId();
                vm.prank(o);
                vault.requestDepositCancellation(id, o);
                assertEq(vault.firstPendingDepositId(), headBef, "cancel moved the head");
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
            assertLe(vault.firstPendingDepositCancellationId(), _cancelledLength(), "cancelled head <= len");
            assertLe(vault.firstPendingDepositId(),          _depositLength(),   "deposit head <= len");

            for (uint256 i; i < vault.firstPendingDepositCancellationId(); ++i) {
                ( ,, uint256 s ) = _cancelledDepositRequest(i);
                assertEq(s, 0, "zero behind cancelled head");
            }
            for (uint256 i; i < vault.firstPendingDepositId(); ++i) {
                ( ,, uint256 s ) = _depositRequest(i);
                assertEq(s, 0, "zero behind deposit head");
            }
        }
    }

    /**********************************************************************************************/
    /*** 11. Blacklist: request-time check, settlement fallback to claimableAssets (R4-B fixed) ***/
    /**********************************************************************************************/

    // The recipient is blacklist-checked at request (src 425) and at repoint (493); the OWNER is
    // not: a blacklisted owner can still cancel to a clean address and be paid there.
    function test_requestDepositCancellation_blacklistCheckedOnRecipientNotOwner() public {
        uint256 id = _deposit(alice, ONE_M);
        _blacklist(carol);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestDepositCancellation(id, carol);

        uint256 cid = _cancel(alice, id, alice);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.updateDepositCancellationRecipient(cid, carol);

        // Blacklisted owner: repoint to bob is fine, and so is a fresh cancel by a blacklisted owner.
        _blacklist(alice);
        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cid, bob);
        ( address o, address r, uint256 sh ) = _cancelledDepositRequest(cid);
        assertEq(o, alice); assertEq(r, bob); assertEq(sh, S_1M);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),           A_1M);
        assertEq(usdc.balanceOf(alice),         0);
        assertEq(vault.claimableAssets(alice),  0);
        assertEq(vault.claimableAssets(bob),    0);
    }

    // R4-B fixed: a recipient blacklisted AFTER the cancel no longer blocks the queue. Settlement
    // redeems to the vault itself (src 942) and credits `claimableAssets[recipient]` (944); the
    // entry closes, the next entry is paid directly, the USDC sits in the vault untouched by
    // deposits and `take()`, `claim` reverts in USDC while blacklisted and pays after.
    function test_fixed_blacklistedRecipientAtSettlement_fallsBackToClaimable() public {
        uint256 ca = _cancel(alice, _deposit(alice, ONE_M),     alice);
        uint256 cb = _cancel(bob,   _deposit(bob,   HUNDRED_K), bob);
        assertEq(ca, 0); assertEq(cb, 1);

        _blacklist(alice);

        vm.expectEmit(address(vault));
        emit ClaimableAssetsIncreased(alice, A_1M);
        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, S_1M, A_1M);
        vm.expectEmit(address(vault));
        emit DepositCancellation(bob, bob, S_100K, A_100K);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(address(vault)),               A_1M);
        assertEq(vault.claimableAssets(alice),                 A_1M);
        assertEq(usdc.balanceOf(alice),                        0);
        assertEq(usdc.balanceOf(bob),                          A_100K);   // queue kept moving
        assertEq(vault.claimableAssets(bob),                   0);
        assertEq(vault.firstPendingDepositCancellationId(),    2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(),                               0);
        ( ,, uint256 left ) = _cancelledDepositRequest(ca);
        assertEq(left, 0);

        // Still blacklisted: claim reverts inside USDC, the credit is untouched.
        vm.expectRevert(BLACKLISTED);
        vault.claim(alice);
        assertEq(vault.claimableAssets(alice), A_1M);

        // Nothing else moves the vault's USDC: a deposit pulls and deposits exactly `assets_`
        // (src 400-402), `take()` moves spUSDC only (346), `totalAssets` ignores it.
        _setCapacity(type(uint128).max);
        _deposit(carol, HUNDRED_K);
        _takeAll();
        assertEq(usdc.balanceOf(address(vault)), A_1M);
        assertEq(vault.totalAssets(),            99_999_999_998);

        // Un-blacklisted: anyone can trigger the claim, the USDC goes to alice only.
        _unblacklist(alice);
        vm.expectEmit(address(vault));
        emit Claim(alice, A_1M);
        vm.prank(mallory);
        uint256 paid = vault.claim(alice);

        assertEq(paid,                           A_1M);
        assertEq(usdc.balanceOf(alice),          A_1M);
        assertEq(usdc.balanceOf(mallory),        0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.claimableAssets(alice),   0);

        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(alice);
    }

    // Partial settlements accumulate in `claimableAssets` while blacklisted; a settlement after
    // un-blacklisting pays directly and leaves the earlier credit intact. Exact wei: the two
    // halves sum to the same as the existing single-recipient split (499_999_999_998 +
    // 500_000_000_000).
    function test_fixed_blacklistedRecipient_partialSettlementsAccumulateClaimable() public {
        uint256 cid = _cancel(alice, _deposit(alice, ONE_M), alice);
        _drainSpUsdcLiquidity(500_000e6);
        _blacklist(alice);

        vm.expectEmit(address(vault));
        emit ClaimableAssetsIncreased(alice, 499_999_999_998);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(alice),                 499_999_999_998);
        assertEq(usdc.balanceOf(address(vault)),               499_999_999_998);
        assertEq(vault.firstPendingDepositCancellationId(),    0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 477_266_345_572);

        _returnSpUsdcLiquidity(500_000e6 + 2);

        // Second half while still blacklisted: credit accumulates.
        uint256 snap = vm.snapshotState();
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(alice),   499_999_999_998 + 500_000_000_000);
        assertEq(usdc.balanceOf(address(vault)), 999_999_999_998);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        _unblacklist(alice);
        vault.claim(alice);
        assertEq(usdc.balanceOf(alice), 999_999_999_998);
        vm.revertToState(snap);

        // Second half after un-blacklisting: paid directly, the first credit still claimable.
        _unblacklist(alice);
        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, 477_266_345_572, 500_000_000_000);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),          500_000_000_000);
        assertEq(vault.claimableAssets(alice),   499_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), 499_999_999_998);
        vault.claim(alice);
        assertEq(usdc.balanceOf(alice),          999_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), 0);
        ( ,, uint256 left ) = _cancelledDepositRequest(cid);
        assertEq(left, 0);
    }

    // The repoint is read at each settlement (src 888): after a partial payout the owner can
    // redirect the remainder; the first part stays with the old recipient.
    function test_updateDepositCancellationRecipient_afterPartialSettlementRedirectsRemainder()
        public
    {
        uint256 cid = _cancel(alice, _deposit(alice, ONE_M), alice);
        _drainSpUsdcLiquidity(500_000e6);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), 499_999_999_998);

        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cid, bob);

        _returnSpUsdcLiquidity(500_000e6 + 2);
        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, bob, 477_266_345_572, 500_000_000_000);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(alice), 499_999_999_998);
        assertEq(usdc.balanceOf(bob),   500_000_000_000);
        assertEq(vault.firstPendingDepositCancellationId(), 1);

        // Closed entry: no repoint any more.
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateDepositCancellationRecipient(cid, carol);
    }

    /**********************************************************************************************/
    /*** 12. Ordering: cancel then re-deposit                                                   ***/
    /**********************************************************************************************/

    // Cancelling the head and re-depositing does not keep the place in line: the new request is
    // pushed at the tail and, with bob live, is queued behind him (predicate false). With nobody
    // live the re-deposit is instant.
    function test_requestDepositCancellation_thenRedepositGoesToTail() public {
        uint256 a = _deposit(alice, HUNDRED_K);  // 0
        _deposit(bob, HUNDRED_K);                // 1
        _cancel(alice, a, alice);
        assertEq(vault.firstPendingDepositId(), 0);

        uint256 a2 = _deposit(alice, HUNDRED_K); // 2, queued behind bob
        assertEq(a2, 2);
        assertEq(vault.balanceOf(alice), 0);
        ( ,, uint256 s2 ) = _depositRequest(a2);
        assertEq(s2, S_100K);

        _setCapacity(type(uint128).max);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), A_100K);

        _processDeposits(type(uint256).max, 1);  // budget 1 is spent on dead slot 0 (DQ-3)
        assertEq(vault.balanceOf(bob),   0);
        assertEq(vault.firstPendingDepositId(), 1);

        _processDeposits(type(uint256).max, 1);  // bob only
        assertEq(vault.balanceOf(bob),   99_040_518_410);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.firstPendingDepositId(), 2);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(alice), 99_040_518_410);
        assertEq(vault.firstPendingDepositId(), 3);

        // Nobody live: cancel-then-redeposit is instant.
        _setCapacity(vault.totalSupply());
        uint256 c = _deposit(carol, HUNDRED_K);  // 3, queued (no capacity)
        _cancel(carol, c, carol);
        _setCapacity(type(uint128).max);
        uint256 c2 = _deposit(carol, HUNDRED_K); // 4, instant, walks dead slot 3
        assertEq(c2, 4);
        assertEq(vault.balanceOf(carol), 99_040_518_410);
        assertEq(vault.firstPendingDepositId(), 5);
    }

    /**********************************************************************************************/
    /*** 13. 2-wei bloat (V2-11, still open)                                                    ***/
    /**********************************************************************************************/

    // LOW (V2-11): with `minDeposit == 0` a 2-wei deposit mints 1 spUSDC share (floor of
    // 2 / 1.0476), is queued behind any live entry and can be cancelled into a 1-share
    // cancellation entry. Each one consumes a `maxRequests_` slot and a full `spUSDC.redeem`
    // (src 882-894) paying 1 wei, so a griefer delays every later refund by N planner slots for
    // 2 wei + gas each. Measures the planner cost per bloat entry and shows carol's real refund
    // waits behind them.
    function test_BUG_twoWeiCancellationsBloatQueue() public {
        _deposit(alice, HUNDRED_K);  // live head keeps the predicate false for the dust
        assertEq(spUsdc.convertToShares(2), 1);

        uint256 n = 50;
        _fund(mallory, 2 * n);
        for (uint256 i; i < n; ++i) {
            vm.prank(mallory);
            uint256 id = vault.requestDeposit(2, mallory, 0);
            ( ,, uint256 sh ) = _depositRequest(id);
            assertEq(sh, 1);
            _cancel(mallory, id, mallory);
        }
        assertEq(_cancelledLength(), n);
        assertEq(vault.pendingCancelledDepositSavingsShares(), n);

        uint256 cc = _cancel(carol, _deposit(carol, ONE_M), carol);  // the real refund, id 50
        assertEq(cc, n);

        vm.cool(address(vault));
        vm.cool(address(spUsdc));
        vm.cool(address(usdc));
        vm.prank(rebalancer);
        uint256 g0 = gasleft();
        vault.processPendingDepositCancellations(type(uint256).max, n);
        uint256 gasBloat = g0 - gasleft();

        assertEq(usdc.balanceOf(mallory),                      n);   // 1 wei each: 2 -> 1
        assertEq(usdc.balanceOf(carol),                        0);   // still waiting
        assertEq(vault.firstPendingDepositCancellationId(),    n);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);

        uint256 perEntry = gasBloat / n;
        assertGt(perEntry, 15_000);
        assertLt(perEntry, 60_000);
        emit log_named_uint("planner gas per 1-share cancellation entry", perEntry);
        emit log_named_uint("wei refunded per entry", 1);

        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(carol), A_1M);
    }

}
