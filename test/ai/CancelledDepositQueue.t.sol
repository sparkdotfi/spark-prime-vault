// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { LocalTestBase }    from "./LocalTestBase.t.sol";
import { ISparkPrimeVault } from "src/ISparkPrimeVault.sol";

/// @dev Cancelled-deposit queue tests for `SparkPrimeVault` (round 6, `master` @ c512609).
///
///      Round-6 semantics under test (src lines on c512609):
///        - `requestDepositCancellation(id, recipient, savingsShares)` (405-446): owner-only
///          (421), recipient non-zero (414) and not the vault (415), `id < length` (416),
///          `NoRequest` (420), `minDepositCancellation <= savingsShares <= request.shares`
///          (422-423); pushes `(owner, recipient, savingsShares)` (427-429); deletes the deposit
///          entry only when fully cancelled (434-438); NOT pause-gated; ends with the self-skip
///          walk `_processPendingDeposits(0, max)` (445).
///        - `processPendingDepositCancellations` (326-332): OPERATOR_ROLE, NOT pause-gated.
///        - `_processPendingDepositCancellations` (902-940): budget `min(max,
///          spUSDC.maxRedeem(vault))` (907-908), pays through `_redeemSavings` (978-995): `try`
///          `redeem(shares, recipient, vault)` (982), on ANY revert `redeem(shares, vault,
///          vault)` (992) and credit `claimableAssets[recipient]` + `totalClaimable` (994,
///          1100-1105); `claim(recipient)` (531-543) pays it out and decrements `totalClaimable`.
///        - `updateDepositCancellationRecipient` (495-512): owner-only, zero / vault rejected.
///          There is no blacklist check anywhere any more.
///
///      Harness indexes (frozen at RAY after setUp):
///        spUSDC  chi_s = 1.047633055711877768967605062e27
///        spPRIME chi_p = 1.009687768242461209408770821e27
///
///      Reference conversions at those indexes (all floor):
///        1_000_000e6 USDC -> 954_532_691_143 spUSDC shares -> redeem: 999_999_999_999 USDC
///          100_000e6 USDC ->  95_453_269_114 spUSDC shares -> redeem:  99_999_999_999 USDC
contract CancelledDepositQueueTest is LocalTestBase {

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

    uint256 constant DEPOSIT_SLOT = 0;
    uint256 constant CANCEL_SLOT  = 1;

    function setUp() public override {
        super.setUp();
        _setCapacity(0);  // everything queues unless a test opens capacity
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _rawLength(uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(address(vault), bytes32(slot)));
    }

    function _rawShares(uint256 slot, uint256 i) internal view returns (uint256) {
        uint256 base = uint256(keccak256(abi.encode(slot)));
        return uint256(vm.load(address(vault), bytes32(base + 3 * i + 2)));
    }

    // Full cancel of the remainder to `recipient`, no settlement.
    function _cancel(address who, uint256 id, address recipient) internal returns (uint256 cid) {
        uint256 s = _rawShares(DEPOSIT_SLOT, id);
        vm.prank(who);
        cid = vault.requestDepositCancellation(id, recipient, s);
    }

    function _cancelledLength() internal view returns (uint256) {
        return _rawLength(CANCEL_SLOT);
    }

    function _depositLength() internal view returns (uint256) {
        return _rawLength(DEPOSIT_SLOT);
    }

    function _sumOpenCancelled() internal view returns (uint256 sum) {
        uint256 n = _cancelledLength();
        for (uint256 i; i < n; ++i) sum += _rawShares(CANCEL_SLOT, i);
    }

    function _sumOpenDeposits() internal view returns (uint256 sum) {
        uint256 n = _depositLength();
        for (uint256 i; i < n; ++i) sum += _rawShares(DEPOSIT_SLOT, i);
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
        assertEq(vault.firstPendingDepositId(),                0);
        assertEq(vault.firstPendingDepositCancellationId(),    0);
        assertEq(usdc.balanceOf(alice),                        0);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRequest(0, 0, alice, S_1M);
        vm.prank(alice);
        uint256 cancelId = vault.requestDepositCancellation(id, alice, S_1M);

        assertEq(cancelId, 0);

        // The deposit entry is deleted and the head walked past it (self-skip).
        assertEq(_rawShares(DEPOSIT_SLOT, 0), 0);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(0);

        ( address owner, address recipient, uint256 shares ) = _cancelledDepositRequest(0);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    S_1M);

        // Nothing paid yet: spUSDC still in the vault, alice still has no USDC.
        assertEq(_vaultSpUsdc(),                               S_1M);
        assertEq(usdc.balanceOf(alice),                        0);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
        assertEq(vault.firstPendingDepositId(),                1);
        assertEq(vault.firstPendingDepositCancellationId(),    0);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(0, alice, alice, S_1M, A_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(alice),                        A_1M);  // 1 wei floor loss vs ONE_M
        assertEq(_vaultSpUsdc(),                               0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),    1);
        assertEq(vault.totalClaimable(),                       0);

        assertEq(_rawShares(CANCEL_SLOT, 0), 0);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositCancellationRequest(0);
    }

    /**********************************************************************************************/
    /*** 2. FIFO, partial settlement, limits, no-ops                                            ***/
    /**********************************************************************************************/

    function test_processPendingDepositCancellations_partialThenComplete() public {
        uint256 idA = _deposit(alice, ONE_M);
        uint256 idB = _deposit(bob,   HUNDRED_K);

        assertEq(_cancel(alice, idA, alice), 0);
        assertEq(vault.firstPendingDepositId(), 1);  // self-skip stops on bob (live)
        assertEq(_cancel(bob,   idB, bob),   1);
        assertEq(vault.firstPendingDepositId(), 2);

        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M + S_100K);

        uint256 half = S_1M / 2;  // 477_266_345_571
        uint256 halfAssets = spUsdc.convertToAssets(half);
        assertEq(halfAssets, 499_999_999_998);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(0, alice, alice, half, halfAssets);
        _processCancelledDeposits(half, type(uint256).max);

        assertEq(usdc.balanceOf(alice),                        halfAssets);
        assertEq(usdc.balanceOf(bob),                          0);
        assertEq(vault.firstPendingDepositCancellationId(),    0);  // partial: head stays
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M - half + S_100K);
        assertEq(_vaultSpUsdc(),                               S_1M - half + S_100K);

        ( address o, address r, uint256 shares ) = _cancelledDepositRequest(0);
        assertEq(o,      alice);  // owner and recipient untouched by the partial settlement
        assertEq(r,      alice);
        assertEq(shares, S_1M - half);

        uint256 secondAssets = spUsdc.convertToAssets(S_1M - half);
        assertEq(secondAssets, 500_000_000_000);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        // Two floor redeems lose at most 1 wei more than one redeem of the whole.
        assertEq(usdc.balanceOf(alice),                        halfAssets + secondAssets);
        assertEq(usdc.balanceOf(alice),                        A_1M - 1);
        assertEq(usdc.balanceOf(bob),                          A_100K);
        assertEq(vault.firstPendingDepositCancellationId(),    2);
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
        assertEq(vault.firstPendingDepositCancellationId(),    2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_100K);

        _processCancelledDeposits(type(uint256).max, 0);  // maxRequests 0: no-op
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(usdc.balanceOf(carol),                     0);

        _processCancelledDeposits(0, 1);  // maxSavingsShares 0: no-op
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(usdc.balanceOf(carol),                     0);

        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(carol),                     A_100K);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
    }

    function test_processPendingDepositCancellations_emptyQueueNoOp() public {
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingDepositCancellationId(), 0);
        assertEq(_cancelledLength(),                        0);

        // Queue fully settled, call again: no-op, head unchanged.
        _cancelDepositAndSettle(alice, _deposit(alice, HUNDRED_K));
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        assertEq(usdc.balanceOf(alice),                     A_100K);
    }

    function test_processPendingDepositCancellations_notOperator() public {
        _cancel(alice, _deposit(alice, HUNDRED_K), alice);
        address[3] memory callers = [alice, admin, taker];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", callers[i], OPERATOR_ROLE
            ));
            vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);
        }
    }

    // Zero entries at or after the cancelled head are unreachable: a cancel always pushes
    // `shares != 0` (>= minDepositCancellation >= 1) and an entry is only deleted once fully
    // paid, after which the head passes it.
    function test_processPendingDepositCancellations_zeroEntriesOnlyBehindHead() public {
        _cancel(alice, _deposit(alice, HUNDRED_K), alice);
        _cancel(bob,   _deposit(bob,   HUNDRED_K), bob);
        _processCancelledDeposits(type(uint256).max, 1);

        assertEq(_rawShares(CANCEL_SLOT, 0), 0);
        assertEq(_rawShares(CANCEL_SLOT, 1), S_100K);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
    }

    /**********************************************************************************************/
    /*** 3. Budget is spUSDC's maxRedeem                                                        ***/
    /**********************************************************************************************/

    // `_processPendingDepositCancellations` (src 907-908) budgets by `spUSDC.maxRedeem(vault)` =
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
        emit ISparkPrimeVault.DepositCancellation(0, alice, alice, payable_, 499_999_999_998);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(alice),                        499_999_999_998);
        assertEq(usdc.balanceOf(address(spUsdc)),              2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M - payable_);
        assertEq(vault.firstPendingDepositCancellationId(),    0);   // partial: head stays
        ( ,, uint256 left ) = _cancelledDepositRequest(0);
        assertEq(left, 477_266_345_572);

        // No liquidity, no payment, no revert.
        _drainAllSpUsdcLiquidity();
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),                     499_999_999_998);
        assertEq(vault.firstPendingDepositCancellationId(), 0);

        // Liquidity returns: the remainder is paid and the entry closes.
        _returnSpUsdcLiquidity(500_000e6 + 2);
        assertGe(spUsdc.maxRedeem(address(vault)), left);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(alice),                        499_999_999_998 + 500_000_000_000);
        assertEq(usdc.balanceOf(alice),                        A_1M - 1);  // two floors
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),    1);
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
        assertEq(vault.firstPendingDepositCancellationId(),    1);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_100K - bobShares);
        ( ,, uint256 bobLeft ) = _cancelledDepositRequest(1);
        assertEq(bobLeft, S_100K - bobShares);

        _returnSpUsdcLiquidity(60_000e6);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),          40_000_000_000 + spUsdc.convertToAssets(bobLeft));
        assertEq(usdc.balanceOf(bob),          A_100K);  // the two floors happen to sum exactly
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // The operator's own cap still applies on top of the liquidity clamp.
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
    /*** 4. take() drains the cancelled queue's backing (R5-5 / F-2, open)                      ***/
    /**********************************************************************************************/

    // The cancelled queue is not ring-fenced from `take()`. Settlement then silently pays
    // nothing (budget = min(max, balance) = 0; no revert), and the refund waits until spUSDC
    // is returned.
    function test_BUG_take_afterCancel_settleIsNoOpUntilSpUsdcReturned() public {
        _cancel(alice, _deposit(alice, ONE_M), alice);

        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
        assertEq(_vaultSpUsdc(),                               S_1M);

        _take(S_1M);  // taker can take 100% of the refund's backing
        assertEq(_vaultSpUsdc(),          0);
        assertEq(spUsdc.balanceOf(taker), S_1M);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);  // no revert, no payment
        assertEq(usdc.balanceOf(alice),                        0);
        assertEq(vault.firstPendingDepositCancellationId(),    0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);

        // Partial return: pays exactly what came back.
        _returnToVault(S_100K);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),                        A_100K);
        assertEq(vault.firstPendingDepositCancellationId(),    0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M - S_100K);

        _returnToVault(S_1M - S_100K);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),                        A_100K + 899_999_999_999);
        assertEq(vault.firstPendingDepositCancellationId(),    1);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    /**********************************************************************************************/
    /*** 5. Priority: cancelled-deposit queue vs redeem queue                                   ***/
    /**********************************************************************************************/

    // Both queues draw from the same spUSDC balance; neither reserves anything for the other.
    // Whoever the operator processes first is paid first.
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
        assertEq(usdc.balanceOf(bob),                       A_100K);  // bob paid in full
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        assertEq(_vaultSpUsdc(),                            S_1M - 2 * S_100K);

        uint256 liquid = vault.availableLiquidAssets();
        assertEq(liquid, 799_999_999_999);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), 799_999_999_998);
        assertEq(vault.firstPendingRedeemId(), 0);  // alice partially paid, still queued
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
        assertEq(expected, 1_099_999_999_998);

        // spUSDC needs the USDC to exist locally to pay the yield out. With liquidity equal to
        // the exact assets owed, `maxRedeem` = floor(expected * RAY / chi_s) is one share short
        // of S_1M (the product S_1M * chi_s / RAY is not an integer), so the clamp (src 908)
        // pays expected - 1 and leaves 1 spUSDC share (1 wei) queued.
        _returnSpUsdcLiquidity(expected - ONE_M);
        assertEq(usdc.balanceOf(address(spUsdc)), expected);
        assertEq(spUsdc.maxRedeem(address(vault)), S_1M - 1);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),                        expected - 1);
        assertEq(_vaultSpUsdc(),                               1);
        assertEq(vault.firstPendingDepositCancellationId(),    0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 1);

        // 1 wei of liquidity is left but floor(1 * RAY / chi_s) == 0 shares: still nothing.
        assertEq(usdc.balanceOf(address(spUsdc)), 1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), expected - 1);

        // One more wei of liquidity closes it: the canceller ends with exactly `expected`.
        _returnSpUsdcLiquidity(1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),                     expected);
        assertEq(_vaultSpUsdc(),                            0);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
    }

    /**********************************************************************************************/
    /*** 7. Pause does not gate cancellations nor their settlement (R5-B fixed)                 ***/
    /**********************************************************************************************/

    function test_fixed_requestDepositCancellation_worksWhilePaused() public {
        uint256 id = _deposit(alice, ONE_M);
        _pause();

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRequest(id, 0, bob, S_100K);
        vm.prank(alice);
        uint256 cid = vault.requestDepositCancellation(id, bob, S_100K);  // partial, while paused
        assertEq(cid, 0);
        assertEq(_rawShares(DEPOSIT_SLOT, id), S_1M - S_100K);

        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cid, carol);  // repoint while paused too

        _cancel(alice, id, alice);  // the rest, still paused: self-skip walks the dead head
        assertEq(vault.firstPendingDepositId(), 1);
        assertTrue(vault.paused());
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
    }

    function test_fixed_processPendingDepositCancellations_worksWhilePaused() public {
        _cancel(alice, _deposit(alice, ONE_M), alice);
        _pause();

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(0, alice, alice, S_1M, A_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertTrue(vault.paused());
        assertEq(usdc.balanceOf(alice),                     A_1M);
        assertEq(vault.firstPendingDepositCancellationId(), 1);

        // The other two processors stay gated.
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);
    }

    /**********************************************************************************************/
    /*** 8. Pauser cancel path removed (V2-2 / F-1 fixed)                                       ***/
    /**********************************************************************************************/

    function test_fixed_requestDepositCancellation_pauserCannotCancel() public {
        uint256 id = _deposit(alice, ONE_M);

        address[3] memory named = [pauser, bob, alice];
        for (uint256 i; i < 3; ++i) {
            vm.prank(pauser);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.requestDepositCancellation(id, named[i], S_1M);
        }

        ( address owner, address recipient, uint256 shares ) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    S_1M);
        assertEq(_cancelledLength(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);

        // Paused changes nothing for the pauser; the owner can cancel either way.
        _pause();
        vm.prank(pauser);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id, alice, S_1M);

        uint256 cid = _cancel(alice, id, alice);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(cid, 0);
        assertEq(usdc.balanceOf(pauser), 0);
        assertEq(usdc.balanceOf(alice),  A_1M);
    }

    /**********************************************************************************************/
    /*** 9. Reverts                                                                             ***/
    /**********************************************************************************************/

    function test_requestDepositCancellation_doubleCancelReverts() public {
        uint256 id = _deposit(alice, ONE_M);
        _cancel(alice, id, alice);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, alice, 1);
    }

    function test_requestDepositCancellation_filledEntryReverts() public {
        _setCapacity(type(uint128).max);
        uint256 id = _deposit(alice, ONE_M);  // instant fill, entry deleted
        assertEq(id, 0);
        assertEq(vault.balanceOf(alice), SH_1M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, alice, 1);
    }

    function test_requestDepositCancellation_zeroRecipientReverts() public {
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.requestDepositCancellation(id, address(0), S_1M);
    }

    function test_requestDepositCancellation_vaultIsRecipientReverts() public {
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDepositCancellation(id, address(vault), S_1M);
    }

    function test_requestDepositCancellation_notOwnerReverts() public {
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id, mallory, S_1M);
    }

    function test_requestDepositCancellation_invalidRequestIdReverts() public {
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.requestDepositCancellation(0, alice, 1);

        _deposit(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.requestDepositCancellation(1, alice, 1);
    }

    function test_requestDepositCancellation_belowMinAndTooHighReverts() public {
        uint256 id = _deposit(alice, ONE_M);
        _setMinDepositCancellation(2);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, 1);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, alice, S_1M + 1);

        // Check order: the minimum is checked before the upper bound.
        _setMinDepositCancellation(S_1M + 2);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, S_1M + 1);
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
            uint256 a   = actions[k] % 7;
            uint256 amt = uint256(amounts[k]);
            address u   = users[k % 3];

            if (a == 0) {
                // queue a deposit (capacity is 0, nothing fills)
                _deposit(u, bound(amt, 2, 1_000_000e6));
            } else if (a == 1 || a == 6) {
                // cancel a random open deposit entry, fully (1) or partially (6): only its
                // owner can, the pauser and a non-owner user get `NotRequestOwner`
                uint256 len = _depositLength();
                if (len == 0) continue;
                uint256 id = amt % len;
                uint256 s  = _rawShares(DEPOSIT_SLOT, id);
                if (s == 0) continue;
                ( address o, address r, ) = _depositRequest(id);
                uint256 part = a == 1 ? s : bound(amt >> 8, 1, s);
                vm.prank(pauser);
                vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
                vault.requestDepositCancellation(id, o, part);
                if (o != u) {
                    vm.prank(u);
                    vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
                    vault.requestDepositCancellation(id, u, part);
                }
                uint256 headBef = vault.firstPendingDepositId();
                vm.prank(o);
                vault.requestDepositCancellation(id, o, part);
                assertGe(vault.firstPendingDepositId(), headBef, "cancel moved the head back");
                assertEq(_rawShares(DEPOSIT_SLOT, id), s - part, "remainder");
                if (part != s) {
                    ( address o2, address r2, ) = _depositRequest(id);
                    assertEq(o2, o, "owner changed");
                    assertEq(r2, r, "recipient changed");
                }
                uint256 head = vault.firstPendingDepositId();
                if (head < _depositLength()) {
                    assertGt(_rawShares(DEPOSIT_SLOT, head), 0, "head on a dead slot after cancel");
                }
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
            assertLe(vault.firstPendingDepositId(),             _depositLength(),   "deposit head <= len");

            for (uint256 i; i < vault.firstPendingDepositCancellationId(); ++i) {
                assertEq(_rawShares(CANCEL_SLOT, i), 0, "zero behind cancelled head");
            }
            for (uint256 i; i < vault.firstPendingDepositId(); ++i) {
                assertEq(_rawShares(DEPOSIT_SLOT, i), 0, "zero behind deposit head");
            }
            assertEq(vault.totalClaimable(), 0, "no fallback credited");
        }
    }

    /**********************************************************************************************/
    /*** 11. try/catch fallback (R4-A / R4-B fixed): both branches                              ***/
    /**********************************************************************************************/

    // Round 6: there is no blacklist check at request (src 414-423) nor at repoint (499-506): a
    // blacklisted recipient is accepted, and a blacklisted OWNER can cancel and repoint as well.
    // The settlement falls back to `claimableAssets` for the blacklisted recipient.
    function test_requestDepositCancellation_blacklistedRecipientAndOwnerAccepted() public {
        uint256 id = _deposit(alice, ONE_M);
        _blacklist(carol);

        vm.prank(alice);
        uint256 cid = vault.requestDepositCancellation(id, carol, S_100K);  // accepted
        ( , address r0, ) = _cancelledDepositRequest(cid);
        assertEq(r0, carol);

        _blacklist(alice);  // blacklisted owner: cancel and repoint still work (no USDC moves)
        uint256 cid2 = _cancel(alice, id, alice);
        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cid2, bob);
        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cid, carol);  // repoint to a blacklisted one
        ( address o, address r, uint256 sh ) = _cancelledDepositRequest(cid2);
        assertEq(o, alice); assertEq(r, bob); assertEq(sh, S_1M - S_100K);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),            spUsdc.convertToAssets(S_1M - S_100K));
        assertEq(usdc.balanceOf(carol),          0);
        assertEq(vault.claimableAssets(carol),   A_100K);  // fallback for the blacklisted one
        assertEq(vault.claimableAssets(alice),   0);
        assertEq(vault.claimableAssets(bob),     0);
        assertEq(vault.totalClaimable(),         A_100K);
        assertEq(usdc.balanceOf(address(vault)), A_100K);
    }

    // R4-B fixed, catch branch: a recipient blacklisted at settlement no longer blocks the queue.
    // The `try redeem(shares, recipient, vault)` (src 982) reverts inside USDC, the catch
    // redeems to the vault (992) and credits `claimableAssets[recipient]` + `totalClaimable`
    // (994); the entry closes, the next entry is paid directly, the USDC sits in the vault
    // untouched by deposits and `take()`, `claim` reverts in USDC while blacklisted and pays
    // after, decrementing `totalClaimable`.
    function test_fixed_blacklistedRecipientAtSettlement_fallsBackToClaimable() public {
        uint256 ca = _cancel(alice, _deposit(alice, ONE_M),     alice);
        uint256 cb = _cancel(bob,   _deposit(bob,   HUNDRED_K), bob);
        assertEq(ca, 0); assertEq(cb, 1);

        _blacklist(alice);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(alice, A_1M);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(0, alice, alice, S_1M, A_1M);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(1, bob, bob, S_100K, A_100K);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(address(vault)),               A_1M);
        assertEq(vault.claimableAssets(alice),                 A_1M);
        assertEq(vault.totalClaimable(),                       A_1M);
        assertEq(usdc.balanceOf(alice),                        0);
        assertEq(usdc.balanceOf(bob),                          A_100K);   // queue kept moving
        assertEq(vault.claimableAssets(bob),                   0);
        assertEq(vault.firstPendingDepositCancellationId(),    2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(),                               0);
        assertEq(_rawShares(CANCEL_SLOT, ca),                  0);

        // Still blacklisted: claim reverts inside USDC, the credit is untouched.
        vm.expectRevert(BLACKLISTED);
        vault.claim(alice);
        assertEq(vault.claimableAssets(alice), A_1M);

        // Nothing else moves the vault's USDC: a deposit pulls and deposits exactly `assets_`
        // (src 386-388), `take()` moves spUSDC only (295), `totalAssets` ignores it.
        _setCapacity(type(uint128).max);
        _deposit(carol, HUNDRED_K);
        _takeAll();
        assertEq(usdc.balanceOf(address(vault)), A_1M);
        assertEq(vault.totalAssets(),            99_999_999_998);

        // Un-blacklisted: anyone can trigger the claim, the USDC goes to alice only.
        _unblacklist(alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Claim(alice, A_1M);
        vm.prank(mallory);
        uint256 paid = vault.claim(alice);

        assertEq(paid,                           A_1M);
        assertEq(usdc.balanceOf(alice),          A_1M);
        assertEq(usdc.balanceOf(mallory),        0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.claimableAssets(alice),   0);
        assertEq(vault.totalClaimable(),         0);

        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
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
        emit ISparkPrimeVault.ClaimableAssetsIncreased(alice, 499_999_999_998);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(alice),                 499_999_999_998);
        assertEq(vault.totalClaimable(),                       499_999_999_998);
        assertEq(usdc.balanceOf(address(vault)),               499_999_999_998);
        assertEq(vault.firstPendingDepositCancellationId(),    0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 477_266_345_572);

        _returnSpUsdcLiquidity(500_000e6 + 2);

        // Second half while still blacklisted: credit accumulates.
        uint256 snap = vm.snapshotState();
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(alice),   499_999_999_998 + 500_000_000_000);
        assertEq(vault.totalClaimable(),         999_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), 999_999_999_998);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        _unblacklist(alice);
        vault.claim(alice);
        assertEq(usdc.balanceOf(alice),  999_999_999_998);
        assertEq(vault.totalClaimable(), 0);
        vm.revertToState(snap);

        // Second half after un-blacklisting: paid directly, the first credit still claimable.
        _unblacklist(alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(cid, alice, alice, 477_266_345_572, 500_000_000_000);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),          500_000_000_000);
        assertEq(vault.claimableAssets(alice),   499_999_999_998);
        assertEq(vault.totalClaimable(),         499_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), 499_999_999_998);
        vault.claim(alice);
        assertEq(usdc.balanceOf(alice),          999_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalClaimable(),         0);
        assertEq(_rawShares(CANCEL_SLOT, cid),   0);
    }

    // Catch branch, non-recipient revert: if the fallback `redeem(shares, vault, vault)` (src
    // 992) reverts too, nothing catches it and the settlement reverts. Genuine case: the VAULT
    // is blacklisted in USDC (every payout to it reverts); the queue is then stuck for everyone
    // whose direct payout fails, and moves again once the recipient is clean.
    function test_processPendingDepositCancellations_fallbackRevertPropagates_vaultBlacklisted()
        public
    {
        _cancel(alice, _deposit(alice, ONE_M),     alice);
        _cancel(bob,   _deposit(bob,   HUNDRED_K), bob);
        _blacklist(alice);
        _blacklist(address(vault));

        vm.prank(operator);
        vm.expectRevert(BLACKLISTED);
        vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);

        assertEq(vault.firstPendingDepositCancellationId(),    0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M + S_100K);
        assertEq(vault.totalClaimable(),                       0);

        // Bob's direct payout does not touch the vault's USDC balance: with maxRequests 1 it is
        // alice's entry at the head that blocks, so bob waits behind her.
        _unblacklist(alice);  // direct payout succeeds again, the vault never receives USDC
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), A_1M);
        assertEq(usdc.balanceOf(bob),   A_100K);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
    }

    // Catch branch, simulated liquidity revert: `maxRedeem` (src 908) is liquidity-aware, so a
    // real `SparkVault/insufficient-liquidity` cannot be reached through the budget (the fuzz
    // above proves it). Mocking exactly the fallback call to revert with that reason shows the
    // revert propagates instead of being swallowed or credited.
    function test_processPendingDepositCancellations_fallbackRevertPropagates_mockedLiquidity()
        public
    {
        _cancel(alice, _deposit(alice, ONE_M), alice);
        _blacklist(alice);  // first try fails -> fallback is attempted

        vm.mockCallRevert(
            address(spUsdc),
            abi.encodeCall(spUsdc.redeem, (S_1M, address(vault), address(vault))),
            "SparkVault/insufficient-liquidity"
        );

        vm.prank(operator);
        vm.expectRevert("SparkVault/insufficient-liquidity");
        vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);

        vm.clearMockedCalls();
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(alice), A_1M);  // real fallback works
    }

    // A recipient that is a contract: USDC has no receive hook, so a contract recipient (here a
    // contract with no code to receive anything) is paid like an EOA; the try branch succeeds.
    function test_processPendingDepositCancellations_contractRecipientPaidDirectly() public {
        address contractRecipient = address(this);
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        vault.requestDepositCancellation(id, contractRecipient, S_1M);

        uint256 before = usdc.balanceOf(contractRecipient);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(contractRecipient) - before, A_1M);
        assertEq(vault.claimableAssets(contractRecipient),   0);
        assertEq(vault.totalClaimable(),                     0);
    }

    // LOW (V2-13 residual, open): spUSDC itself is still accepted as a recipient (src 415 only
    // rejects the vault). `spUSDC.redeem(shares, spUSDC, vault)` pays USDC from spUSDC to itself:
    // the index does not move, the USDC is unaccounted liquidity, a donation to spUSDC's
    // withdrawers. Self-inflicted. The vault as recipient is rejected (`test_fixed_` in the
    // deposit-queue file).
    function test_BUG_cancellationRecipientSpUsdcDonatesRefund() public {
        uint256 id = _deposit(carol, HUNDRED_K);
        vm.prank(carol);
        uint256 c = vault.requestDepositCancellation(id, address(spUsdc), S_100K);

        uint256 spUsdcLiq = usdc.balanceOf(address(spUsdc));
        uint256 spUsdcChi = spUsdc.nowChi();
        uint256 supplyBef = spUsdc.totalSupply();

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(c, carol, address(spUsdc), S_100K, A_100K);
        _processCancelledDeposits(type(uint256).max, 10);

        assertEq(usdc.balanceOf(address(spUsdc)), spUsdcLiq);          // paid USDC back to itself
        assertEq(spUsdc.nowChi(),                 spUsdcChi);          // index unchanged
        assertEq(spUsdc.totalSupply(),            supplyBef - S_100K); // shares burned: donation
        assertEq(usdc.balanceOf(carol),           0);
        assertEq(vault.claimableAssets(address(spUsdc)), 0);
        assertEq(_rawShares(CANCEL_SLOT, c),      0);
        assertEq(vault.firstPendingDepositCancellationId(), 1);

        // Repointing to spUSDC is accepted as well.
        uint256 id2 = _deposit(carol, HUNDRED_K);
        uint256 c2  = _cancel(carol, id2, carol);
        vm.prank(carol);
        vault.updateDepositCancellationRecipient(c2, address(spUsdc));
        ( , address r, ) = _cancelledDepositRequest(c2);
        assertEq(r, address(spUsdc));
    }

    // The repoint is read at each settlement (src 924): after a partial payout the owner can
    // redirect the remainder; the first part stays with the old recipient.
    function test_updateDepositCancellationRecipient_afterPartialSettlementRedirectsRemainder()
        public
    {
        uint256 cid = _cancel(alice, _deposit(alice, ONE_M), alice);
        _drainSpUsdcLiquidity(500_000e6);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), 499_999_999_998);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRecipientUpdated(cid, bob);
        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cid, bob);

        _returnSpUsdcLiquidity(500_000e6 + 2);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(cid, alice, bob, 477_266_345_572, 500_000_000_000);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(alice), 499_999_999_998);
        assertEq(usdc.balanceOf(bob),   500_000_000_000);
        assertEq(vault.firstPendingDepositCancellationId(), 1);

        // Closed entry: no repoint any more; past the length: InvalidRequestId.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositCancellationRecipient(cid, carol);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.updateDepositCancellationRecipient(cid + 1, carol);
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
        assertEq(vault.firstPendingDepositId(), 1);  // self-skip onto bob

        uint256 a2 = _deposit(alice, HUNDRED_K); // 2, queued behind bob
        assertEq(a2, 2);
        assertEq(vault.balanceOf(alice), 0);
        ( ,, uint256 s2 ) = _depositRequest(a2);
        assertEq(s2, S_100K);

        _setCapacity(type(uint128).max);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), A_100K);

        _processDeposits(type(uint256).max, 1);  // bob only
        assertEq(vault.balanceOf(bob),          99_040_518_410);
        assertEq(vault.balanceOf(alice),        0);
        assertEq(vault.firstPendingDepositId(), 2);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(alice),        99_040_518_410);
        assertEq(vault.firstPendingDepositId(), 3);

        // Nobody live: cancel-then-redeposit is instant.
        _setCapacity(vault.totalSupply());
        uint256 c = _deposit(carol, HUNDRED_K);  // 3, queued (no capacity)
        _cancel(carol, c, carol);
        assertEq(vault.firstPendingDepositId(), 4);
        _setCapacity(type(uint128).max);
        uint256 c2 = _deposit(carol, HUNDRED_K); // 4, instant
        assertEq(c2, 4);
        assertEq(vault.balanceOf(carol),        99_040_518_410);
        assertEq(vault.firstPendingDepositId(), 5);
    }

    /**********************************************************************************************/
    /*** 13. 1-share bloat (V2-11 / R5-14, open)                                                ***/
    /**********************************************************************************************/

    // LOW (V2-11): with `minDeposit == 1` a 2-wei deposit mints 1 spUSDC share (floor of
    // 2 / 1.0476), is queued behind any live entry and can be cancelled into a 1-share
    // cancellation entry (`minDepositCancellation == 1`). Each one consumes a `maxRequests_`
    // slot and a full `spUSDC.redeem` (src 918-936) paying 1 wei, so a griefer delays every
    // later refund by N operator slots for 2 wei + gas each. Launch minimums bound this to
    // `minDepositCancellation` shares per entry, which raises the float, not the cost per slot.
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
        vm.prank(operator);
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
        emit log_named_uint("operator gas per 1-share cancellation entry", perEntry);
        emit log_named_uint("wei refunded per entry", 1);

        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(carol), A_1M);
    }

}
