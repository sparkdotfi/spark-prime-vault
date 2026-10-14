// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { LocalTestBase } from "./LocalTestBase.t.sol";

/// @dev Redeem-queue campaign: `requestRedeem`, `cancelRedeemRequest`, `processRedeemQueue`.
///
///      Harness state after setUp (both VSRs frozen at RAY):
///        chi_s (spUSDC)  = 1.047633055711877768967605062e27
///        chi_p (spPRIME) = 1.009687768242461209408770821e27
///      A 1_000_000e6 deposit gives the vault 954_532_691_143 spUSDC and mints 990_405_184_109
///      spPRIME; a 100_000e6 deposit gives 95_453_269_114 spUSDC / 99_040_518_410 spPRIME.
///
///      Notation in comments: L = USDC held by spUSDC, S = spUSDC held by the vault,
///      A = spUSDC.maxWithdraw(vault) = min(L, floor(S * chi_s / RAY)),
///      rem = floor(A * RAY / chi_p) (the share budget `_processRedeemQueue` computes once).
///
///      Round 2: ported to upstream `refactor/more-simplifying` (`minRedeem` in shares, no
///      `shares_ != 0` check, `cancelRedeemRequest` advances the head and requires a recipient,
///      entries are `delete`d after a full fill, `realizeLoss` instead of `setChi`,
///      `Redeem(owner, recipient, shares, assets)`).
///      Round 3 (ff828d2): `updateRedeemRecipient` is owner-only on a live entry
///      (src/SparkPrimeVault.sol:537-546); `realizeLoss` requires 0 < loss < totalAssets
///      (:369-385); new `realizeGain` (:297-309) mirrored in section 16.
contract RedeemQueueTest is LocalTestBase {

    event Redeem(address indexed owner, address indexed recipient, uint256 shares, uint256 assets);

    event RedeemRequest(
        address indexed owner,
        address indexed recipient,
        uint256 indexed requestId,
        uint256         shares,
        uint256         fee
    );

    event CancelRedeemRequest(uint256 indexed requestId, uint256 shares);

    event RedeemRecipientUpdated(uint256 indexed requestId, address indexed recipient);

    event GainRealized(uint192 chi, uint256 gain);

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant CHI_S = 1.047633055711877768967605062e27;
    uint256 constant CHI_P = 1.009687768242461209408770821e27;

    uint256 constant DEPOSIT_100K_SPUSDC = 95_453_269_114;
    uint256 constant DEPOSIT_100K_SHARES = 99_040_518_410;
    uint256 constant DEPOSIT_1M_SPUSDC   = 954_532_691_143;
    uint256 constant DEPOSIT_1M_SHARES   = 990_405_184_109;

    function setUp() public override {
        super.setUp();
        assertEq(spUsdc.nowChi(), CHI_S, "harness chi_s drifted");
        assertEq(vault.nowChi(),  CHI_P, "harness chi_p drifted");
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _requestRedeemTo(address who, uint256 shares, address to)
        internal returns (uint256 id)
    {
        vm.prank(who);
        id = vault.requestRedeem(shares, to);
    }

    function _queued(uint256 id) internal view returns (uint256 shares) {
        (, , shares) = _redeemRequest(id);
    }

    function _divUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / y + 1;
    }

    // Replicates one fill's arithmetic at the current indexes: USDC paid and spUSDC burned.
    function _fillMath(uint256 shares) internal view returns (uint256 assets, uint256 burned) {
        assets = shares * vault.nowChi() / RAY;
        burned = _divUp(assets * RAY, spUsdc.nowChi());
    }

    // redeemQueue has no length getter; probe by index.
    function _queueLength() internal view returns (uint256) {
        return _redeemQueueLength();
    }

    /**********************************************************************************************/
    /*** 1. Batch fills over-burn spUSDC (ceil per fill, budget computed once)                  ***/
    /**********************************************************************************************/

    // BUG (C-1, re-confirmed on refactor/more-simplifying): `_processRedeemQueue` sizes the share
    // budget once from `spUSDC.maxWithdraw(vault)` (src/SparkPrimeVault.sol:822) but each fill calls
    // `spUSDC.withdraw(assets_)` (line 845), which burns ceil(assets * RAY / chi_s) spUSDC. Across
    // N fills the burned total can exceed the vault's spUSDC balance by up to N-1 wei, so the last
    // fill reverts inside spUSDC with "SparkVault/insufficient-balance" and the batch rolls back.
    //
    // Scenario (vault-share bound): the vault holds S = 1_002_833 spUSDC, worth
    // A = 1_050_601 USDC; rem = 1_040_520 shares. Two queued requests of 520_260 shares each
    // are paid 525_300 USDC each (sum 1_050_600 <= A) but burn 501_417 + 501_417 = 1_002_834
    // spUSDC, one more than the vault holds.
    function test_BUG_processRedeemQueue_batchRevertsOnCeilRounding_vaultSharesBound() public {
        _deposit(alice, 1_000_000e6);
        _take(DEPOSIT_1M_SPUSDC - 1_002_833);

        assertEq(_vaultSpUsdc(),                   1_002_833);
        assertEq(vault.availableLiquidAssets(),    1_050_601);
        assertEq(vault.convertToShares(1_050_601), 1_040_520);

        uint256 id1 = _requestRedeemTo(alice, 520_260, alice);
        uint256 id2 = _requestRedeemTo(alice, 520_260, bob);

        assertEq(id1, 0);
        assertEq(id2, 1);
        assertEq(vault.pendingRedeemShares(), 1_040_520);

        (uint256 assets1, uint256 burn1) = _fillMath(520_260);
        assertEq(assets1,   525_300);
        assertEq(burn1,     501_417);
        assertEq(burn1 * 2, 1_002_834);  // > 1_002_833 held

        // The batch of two reverts: the second spUSDC withdraw needs 501_417 spUSDC, 501_416 left.
        vm.prank(rebalancer);
        vm.expectRevert("SparkVault/insufficient-balance");
        vault.processRedeemQueue(type(uint256).max, 2);

        // Nothing moved.
        assertEq(usdc.balanceOf(alice),       0);
        assertEq(usdc.balanceOf(bob),         0);
        assertEq(vault.pendingRedeemShares(), 1_040_520);
        assertEq(vault.firstPendingRedeemId(),          0);
        assertEq(_vaultSpUsdc(),              1_002_833);

        // Workaround: one request per call re-reads maxWithdraw and is always safe (single-fill
        // bound, see testFuzz_processRedeemQueue_singleFillNeverReverts).
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice),         525_300);
        assertEq(_vaultSpUsdc(),                501_416);
        assertEq(vault.availableLiquidAssets(), 525_299);
        assertEq(vault.firstPendingRedeemId(),            1);
        assertEq(vault.pendingRedeemShares(),   520_260);

        _processRedeems(type(uint256).max, 1);

        // Second request only partially fills now: budget is 520_258 shares, not 520_260.
        assertEq(usdc.balanceOf(bob),         525_298);
        assertEq(_vaultSpUsdc(),              1);
        assertEq(_queued(id2),                2);
        assertEq(vault.pendingRedeemShares(), 2);
        assertEq(vault.firstPendingRedeemId(),          1);
    }

    // Same bug with the USDC-liquidity constraint binding: spUSDC holds L = 999_999_999_998 USDC
    // (2 wei drained), one wei below the vault's claim of 999_999_999_999. Three requests that
    // together equal rem = 990_405_184_108 shares are paid 999_999_999_997 USDC in total (fits the
    // liquidity) but burn 954_532_691_144 spUSDC against a balance of 954_532_691_143.
    function test_BUG_processRedeemQueue_batchRevertsOnCeilRounding_liquidityBound() public {
        _deposit(alice, 1_000_000e6);
        _drainSpUsdcLiquidity(2);

        assertEq(usdc.balanceOf(address(spUsdc)),         999_999_999_998);
        assertEq(_vaultSpUsdc(),                          954_532_691_143);
        assertEq(spUsdc.convertToAssets(954_532_691_143), 999_999_999_999);
        assertEq(vault.availableLiquidAssets(),           999_999_999_998);
        assertEq(vault.convertToShares(999_999_999_998),  990_405_184_108);

        _requestRedeemTo(alice, 22_947_880_715,  alice);
        _requestRedeemTo(alice, 299_586_688_493, bob);
        _requestRedeemTo(alice, 667_870_614_900, carol);

        assertEq(vault.pendingRedeemShares(), 990_405_184_108);
        assertEq(vault.balanceOf(alice),      1);

        (uint256 a1, uint256 b1) = _fillMath(22_947_880_715);
        (uint256 a2, uint256 b2) = _fillMath(299_586_688_493);
        (uint256 a3, uint256 b3) = _fillMath(667_870_614_900);

        assertEq(a1 + a2 + a3, 999_999_999_997);  // <= L, liquidity is fine
        assertEq(b1 + b2 + b3, 954_532_691_144);  // > S by exactly 1 wei

        vm.prank(rebalancer);
        vm.expectRevert("SparkVault/insufficient-balance");
        vault.processRedeemQueue(type(uint256).max, 3);

        assertEq(vault.firstPendingRedeemId(),          0);
        assertEq(vault.pendingRedeemShares(), 990_405_184_108);

        // Split 2 + 1: the budget is re-derived on the second call, so it works.
        _processRedeems(type(uint256).max, 2);

        assertEq(usdc.balanceOf(alice), a1);
        assertEq(usdc.balanceOf(bob),   a2);
        assertEq(_vaultSpUsdc(),        954_532_691_143 - b1 - b2);
        assertEq(vault.firstPendingRedeemId(),    2);

        _processRedeems(type(uint256).max, 1);

        // Carol is paid two wei less than the batch would have (budget re-derived from the
        // vault's claim of 674_340_790_632 instead of the liquidity), 2 shares stay queued.
        assertEq(usdc.balanceOf(carol),       a3 - 2);
        assertEq(usdc.balanceOf(carol),       674_340_790_631);
        assertEq(_vaultSpUsdc(),              1);
        assertEq(_queued(2),                  2);
        assertEq(vault.pendingRedeemShares(), 2);
        assertEq(vault.firstPendingRedeemId(),          2);
    }

    // Single-fill bound: for ONE fill, assets = floor(shares * chi_p / RAY) <= A and
    // ceil(assets * RAY / chi_s) <= S whenever assets <= floor(S * chi_s / RAY). So a call with
    // maxRequests_ = 1 never reverts, under random indexes, random liquidity and random take().
    function testFuzz_processRedeemQueue_singleFillNeverReverts(
        uint256 vsrS, uint256 vsrP, uint256 warp, uint256 depositAmt, uint256 drain, uint256 take_
    ) public {
        vsrS       = bound(vsrS, RAY, MAX_VSR);
        vsrP       = bound(vsrP, RAY, MAX_VSR);
        warp       = bound(warp, 0, 5 * 365 days);
        depositAmt = bound(depositAmt, 1, 1_000_000_000e6);

        _setSpUsdcVsr(vsrS);
        _setPrimeVsr(vsrP);
        _deposit(alice, depositAmt);
        _warpAndDrip(warp);

        uint256 shares = vault.balanceOf(alice);
        vm.assume(shares != 0);
        _requestRedeem(alice, shares);

        drain = bound(drain, 0, usdc.balanceOf(address(spUsdc)));
        take_ = bound(take_, 0, _vaultSpUsdc());
        _drainSpUsdcLiquidity(drain);
        _take(take_);

        uint256 spUsdcBefore = _vaultSpUsdc();
        uint256 liqBefore    = usdc.balanceOf(address(spUsdc));
        uint256 a            = vault.availableLiquidAssets();
        uint256 rem          = vault.convertToShares(a);
        uint256 fill         = rem < shares ? rem : shares;
        (uint256 assets, uint256 burned) = _fillMath(fill);

        _processRedeems(type(uint256).max, 1);  // must not revert

        assertEq(usdc.balanceOf(alice),           assets);
        assertEq(_vaultSpUsdc(),                  spUsdcBefore - burned);
        assertEq(usdc.balanceOf(address(spUsdc)), liqBefore - assets);
        assertEq(vault.pendingRedeemShares(),     shares - fill);
        assertLe(assets, a);
        assertLe(burned, spUsdcBefore);
    }

    // Quantifies the over-burn: across N fills the spUSDC burned exceeds the aggregate
    // ceil(sum(assets) * RAY / chi_s) by at most N - 1 wei. When the batch does not revert it
    // leaves the vault with up to N - 1 fewer spUSDC than one aggregate withdraw would have.
    function testFuzz_processRedeemQueue_batchOverburnBoundedByFillsMinusOne(
        uint256 vsrS, uint256 vsrP, uint256 warp, uint256 n, uint256 seed
    ) public {
        vsrS = bound(vsrS, RAY, MAX_VSR);
        vsrP = bound(vsrP, RAY, MAX_VSR);
        warp = bound(warp, 0, 5 * 365 days);
        n    = bound(n, 1, 20);

        _setSpUsdcVsr(vsrS);
        _setPrimeVsr(vsrP);
        _deposit(alice, 10_000_000e6);
        _returnSpUsdcLiquidity(100_000_000e6);  // liquidity never binds here
        _warpAndDrip(warp);

        uint256 left = vault.balanceOf(alice);
        uint256 sumAssets;
        for (uint256 i; i < n; ++i) {
            uint256 s = i == n - 1
                ? left
                : bound(uint256(keccak256(abi.encode(seed, i))), 1, left - (n - 1 - i));
            left -= s;
            _requestRedeem(alice, s);
            (uint256 a_, ) = _fillMath(s);
            sumAssets += a_;
        }

        uint256 spUsdcBefore  = _vaultSpUsdc();
        uint256 aggregateBurn = _divUp(sumAssets * RAY, spUsdc.nowChi());
        bool    budgetCoversAll = vault.convertToShares(vault.availableLiquidAssets()) >= vault.pendingRedeemShares();

        vm.prank(rebalancer);
        try vault.processRedeemQueue(type(uint256).max, n) {
            if (budgetCoversAll) {
                uint256 burned = spUsdcBefore - _vaultSpUsdc();
                assertEq(usdc.balanceOf(alice), sumAssets);
                assertGe(burned, aggregateBurn);
                assertLe(burned, aggregateBurn + n - 1);
                assertEq(vault.pendingRedeemShares(), 0);
                assertEq(vault.firstPendingRedeemId(), n);
            }
        } catch Error(string memory reason) {
            // The over-burn hit the balance: the bug above.
            assertEq(reason, "SparkVault/insufficient-balance");
            assertGt(aggregateBurn + n - 1, spUsdcBefore);
            assertEq(vault.firstPendingRedeemId(), 0);
        }
    }

    /**********************************************************************************************/
    /*** 2. Liquidity-limited fills                                                             ***/
    /**********************************************************************************************/

    // (a) spUSDC has 300_000e6 USDC against the vault's 999_999_999_999 claim.
    function test_processRedeemQueue_partialFill_spUsdcLiquidityBound() public {
        _deposit(alice, 1_000_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_1M_SHARES);
        _drainSpUsdcLiquidity(700_000e6);

        assertEq(usdc.balanceOf(address(spUsdc)),  300_000e6);
        assertEq(vault.availableLiquidAssets(),    300_000e6);
        assertEq(vault.convertToShares(300_000e6), 297_121_555_233);
        assertEq(vault.balanceOf(address(vault)),  DEPOSIT_1M_SHARES);
        assertEq(vault.pendingRedeemShares(),      DEPOSIT_1M_SHARES);
        assertEq(vault.totalSupply(),              DEPOSIT_1M_SHARES);
        assertEq(_vaultSpUsdc(),                   DEPOSIT_1M_SPUSDC);
        assertEq(vault.firstPendingRedeemId(),               0);

        _processRedeems(type(uint256).max, 10);

        // 297_121_555_233 shares -> 299_999_999_999 USDC (1 wei short of liquidity by floor).
        assertEq(usdc.balanceOf(alice),           299_999_999_999);
        assertEq(usdc.balanceOf(address(spUsdc)), 1);
        assertEq(_vaultSpUsdc(),                  DEPOSIT_1M_SPUSDC - 286_359_807_343);
        assertEq(_queued(id),                     693_283_628_876);
        assertEq(vault.pendingRedeemShares(),     693_283_628_876);
        assertEq(vault.balanceOf(address(vault)), 693_283_628_876);
        assertEq(vault.totalSupply(),             693_283_628_876);
        assertEq(vault.firstPendingRedeemId(),              0);  // partial entry stays at the head

        // Liquidity returns; the remainder is paid, but now the vault's spUSDC claim binds
        // (668_172_883_800 spUSDC = 699_999_999_999 USDC < 700_000_000_001 liquidity).
        _returnSpUsdcLiquidity(700_000e6);

        assertEq(vault.availableLiquidAssets(), 699_999_999_999);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),           999_999_999_997);
        assertEq(_vaultSpUsdc(),                  1);
        assertEq(_queued(id),                     0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(),             0);
        assertEq(vault.firstPendingRedeemId(),              1);

        // Nothing left to do.
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), 1);
    }

    // (b) spUSDC is fully liquid, but the vault only holds 300_000e6 spUSDC after take().
    function test_processRedeemQueue_partialFill_vaultSharesBound() public {
        _deposit(alice, 1_000_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_1M_SHARES);
        _take(DEPOSIT_1M_SPUSDC - 300_000e6);

        assertEq(_vaultSpUsdc(),                         300_000e6);
        assertEq(usdc.balanceOf(address(spUsdc)),        1_000_000e6);
        assertEq(vault.availableLiquidAssets(),          314_289_916_713);
        assertEq(vault.convertToShares(314_289_916_713), 311_274_362_826);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),           314_289_916_712);
        assertEq(_vaultSpUsdc(),                  1);  // 299_999_999_999 burned
        assertEq(usdc.balanceOf(address(spUsdc)), 1_000_000e6 - 314_289_916_712);
        assertEq(_queued(id),                     679_130_821_283);
        assertEq(vault.pendingRedeemShares(),     679_130_821_283);
        assertEq(vault.balanceOf(address(vault)), 679_130_821_283);
        assertEq(vault.firstPendingRedeemId(),              0);

        // 1 wei of spUSDC is worth 1 wei USDC, which converts to 0 prime shares: no-op.
        assertEq(vault.availableLiquidAssets(), 1);
        assertEq(vault.convertToShares(1),      0);

        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 314_289_916_712);

        // Capital comes back; the rest is paid in one go.
        _returnToVault(DEPOSIT_1M_SPUSDC - 300_000e6);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),       314_289_916_712 + 685_710_083_285);
        assertEq(_queued(id),                 0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.firstPendingRedeemId(),          1);
    }

    /**********************************************************************************************/
    /*** 3. FIFO, cancelled entries, maxRequests_, maxShares_                                   ***/
    /**********************************************************************************************/

    function _threeDepositorsQueued() internal returns (uint256 idA, uint256 idB, uint256 idC) {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _deposit(carol, 100_000e6);
        idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        idB = _requestRedeem(bob,   DEPOSIT_100K_SHARES);
        idC = _requestRedeem(carol, DEPOSIT_100K_SHARES);
        assertEq(idA, 0);
        assertEq(idB, 1);
        assertEq(idC, 2);
        assertEq(vault.pendingRedeemShares(), 3 * DEPOSIT_100K_SHARES);
        assertEq(_vaultSpUsdc(),              3 * DEPOSIT_100K_SPUSDC);
    }

    function test_processRedeemQueue_fifo_skipsCancelled() public {
        (uint256 idA, uint256 idB, uint256 idC) = _threeDepositorsQueued();

        vm.prank(bob);
        vault.cancelRedeemRequest(idB, bob);

        assertEq(_queued(idB),                0);
        assertEq(vault.balanceOf(bob),        DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(), 2 * DEPOSIT_100K_SHARES);

        _drainSpUsdcLiquidity(150_000e6);
        assertEq(vault.convertToShares(150_000e6), 148_560_777_616);

        _processRedeems(type(uint256).max, 10);

        // Alice full (99_040_518_410 shares -> 99_999_999_998 USDC), bob skipped, carol partial
        // with the 49_520_259_206 shares left in the budget -> exactly 50_000_000_000 USDC.
        assertEq(usdc.balanceOf(alice),           99_999_999_998);
        assertEq(usdc.balanceOf(bob),             0);
        assertEq(usdc.balanceOf(carol),           50_000_000_000);
        assertEq(usdc.balanceOf(address(spUsdc)), 2);
        assertEq(_queued(idA),                    0);
        assertEq(_queued(idC),                    49_520_259_204);
        assertEq(vault.pendingRedeemShares(),     49_520_259_204);
        assertEq(vault.balanceOf(address(vault)), 49_520_259_204);
        assertEq(vault.firstPendingRedeemId(),              idC);
        assertEq(_vaultSpUsdc(), 3 * DEPOSIT_100K_SPUSDC - 95_453_269_113 - 47_726_634_558);

        _returnSpUsdcLiquidity(150_000e6);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(carol),           99_999_999_998);
        assertEq(_queued(idC),                    0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.firstPendingRedeemId(),              3);
        assertEq(_vaultSpUsdc(),                  95_453_269_115);     // bob's backing + 1 wei
        assertEq(vault.totalSupply(),             DEPOSIT_100K_SHARES);  // bob's shares
    }

    function test_processRedeemQueue_maxRequests() public {
        (uint256 idA, uint256 idB, uint256 idC) = _threeDepositorsQueued();

        _processRedeems(type(uint256).max, 0);
        assertEq(vault.firstPendingRedeemId(),    0);
        assertEq(usdc.balanceOf(alice), 0);

        _processRedeems(type(uint256).max, 2);

        assertEq(usdc.balanceOf(alice),       99_999_999_998);
        assertEq(usdc.balanceOf(bob),         99_999_999_998);
        assertEq(usdc.balanceOf(carol),       0);
        assertEq(_queued(idA),                0);
        assertEq(_queued(idB),                0);
        assertEq(_queued(idC),                DEPOSIT_100K_SHARES);
        assertEq(vault.firstPendingRedeemId(),          2);
        assertEq(vault.pendingRedeemShares(), DEPOSIT_100K_SHARES);

        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(carol),       99_999_999_998);
        assertEq(vault.firstPendingRedeemId(),          3);
        assertEq(vault.pendingRedeemShares(), 0);

        // maxRequests_ beyond the queue length is clamped.
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingRedeemId(), 3);
    }

    function test_processRedeemQueue_maxShares() public {
        (uint256 idA, uint256 idB, uint256 idC) = _threeDepositorsQueued();

        // One share short of alice's request: alice partial, head stays.
        _processRedeems(DEPOSIT_100K_SHARES - 1, 10);

        assertEq(usdc.balanceOf(alice),       99_999_999_997);
        assertEq(_queued(idA),                1);
        assertEq(vault.firstPendingRedeemId(),          0);
        assertEq(vault.pendingRedeemShares(), 2 * DEPOSIT_100K_SHARES + 1);
        assertEq(_vaultSpUsdc(),              3 * DEPOSIT_100K_SPUSDC - 95_453_269_112);

        // 1 + 10 shares: alice's last share, then 10 of bob's.
        _processRedeems(11, 10);

        assertEq(usdc.balanceOf(alice),       99_999_999_998);  // 1 share -> 1 wei USDC
        assertEq(usdc.balanceOf(bob),         10);
        assertEq(_queued(idA),                0);
        assertEq(_queued(idB),                DEPOSIT_100K_SHARES - 10);
        assertEq(_queued(idC),                DEPOSIT_100K_SHARES);
        assertEq(vault.firstPendingRedeemId(),          1);
        assertEq(vault.pendingRedeemShares(), 2 * DEPOSIT_100K_SHARES - 10);
        assertEq(_vaultSpUsdc(),              3 * DEPOSIT_100K_SPUSDC - 95_453_269_112 - 1 - 10);
    }

    function test_processRedeemQueue_maxSharesZero_noop() public {
        _threeDepositorsQueued();
        uint256 spBefore = _vaultSpUsdc();

        _processRedeems(0, 10);

        assertEq(vault.firstPendingRedeemId(),          0);
        assertEq(vault.pendingRedeemShares(), 3 * DEPOSIT_100K_SHARES);
        assertEq(_vaultSpUsdc(),              spBefore);
        assertEq(usdc.balanceOf(alice),       0);
    }

    function test_processRedeemQueue_emptyQueue_noop() public {
        _deposit(alice, 100_000e6);
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(),          0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(_vaultSpUsdc(),              DEPOSIT_100K_SPUSDC);
    }

    // A big head request blocks a small later one even when the small one would fit.
    function test_processRedeemQueue_headBlocksLaterSmallerRequests() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idB = _requestRedeem(bob,   1_000e6);
        _drainSpUsdcLiquidity(150_000e6);  // 50_000e6 left: fits bob, not alice

        assertEq(vault.convertToShares(50_000e6), 49_520_259_205);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),       49_999_999_999);
        assertEq(usdc.balanceOf(bob),         0);
        assertEq(_queued(idA),                49_520_259_205);
        assertEq(_queued(idB),                1_000e6);
        assertEq(vault.firstPendingRedeemId(),          0);
        assertEq(vault.pendingRedeemShares(), 49_520_259_205 + 1_000e6);
    }

    /**********************************************************************************************/
    /*** 4. Yield while queued                                                                  ***/
    /**********************************************************************************************/

    // Escrowed shares keep accruing at the prime VSR; the redeemer is paid at fill-time chi.
    function test_processRedeemQueue_primeYieldAccruesWhileQueued() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);  // extra backing so alice's accrued claim is payable
        _setPrimeVsr(FIVE_PCT_VSR);

        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 payoutAtRequest = vault.convertToAssets(DEPOSIT_100K_SHARES);
        assertEq(payoutAtRequest, 99_999_999_998);

        _warpAndDrip(365 days);

        uint256 chiAfter = vault.nowChi();
        assertEq(chiAfter, 1.060172156654584269839902363e27);
        uint256 payoutAtFill = DEPOSIT_100K_SHARES * chiAfter / RAY;
        assertEq(payoutAtFill, 104_999_999_998);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),       104_999_999_998);
        assertEq(payoutAtFill - payoutAtRequest, 5_000_000_000);  // extra USDC from queue-time yield
        assertEq(_queued(id),                 0);
        assertEq(vault.pendingRedeemShares(), 0);

        // Paid out of the common backing: bob's notional claim (104_999_999_998) is now backed by
        // 95_000_000_000 USDC worth of spUSDC (spUSDC VSR was RAY, so the backing did not grow).
        assertEq(vault.assetsOf(bob),                    104_999_999_998);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 95_000_000_000);
    }

    // spUSDC yields while the prime index is flat: the redeemer gets the prime value only; the
    // surplus stays in the vault as unassigned backing.
    function test_processRedeemQueue_spUsdcYieldStaysInVault() public {
        _deposit(alice, 100_000e6);
        _setSpUsdcVsr(FIVE_PCT_VSR);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        _warpAndDrip(365 days);

        assertEq(vault.nowChi(), CHI_P);  // flat
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 104_999_999_999);
        assertEq(vault.availableLiquidAssets(), 100_000e6);  // USDC liquidity binds, not the claim

        _returnSpUsdcLiquidity(5_000e6);  // fund spUSDC's yield
        assertEq(vault.availableLiquidAssets(), 104_999_999_999);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),       99_999_999_998);
        assertEq(_queued(id),                 0);
        assertEq(vault.totalSupply(),         0);
        assertEq(vault.pendingRedeemShares(), 0);

        // Surplus left with zero shares outstanding: 5_000_000_000 USDC worth of spUSDC.
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 5_000_000_000);
        assertEq(vault.totalAssets(),                    0);
    }

    /**********************************************************************************************/
    /*** 5. Fee interplay                                                                       ***/
    /**********************************************************************************************/

    function test_requestRedeem_feeOnePercent_exactAmounts() public {
        _deposit(alice, 1_100_000e6);
        assertEq(vault.balanceOf(alice), 1_089_445_702_520);
        _setRedeemFeeRate(0.01e18);

        uint256 id = _requestRedeem(alice, 1_000_000e6);

        assertEq(vault.balanceOf(alice),          89_445_702_520);
        assertEq(vault.balanceOf(address(vault)), 990_000_000_000);
        assertEq(vault.totalSupply(),             1_079_445_702_520);  // 10_000_000_000 burned
        assertEq(_queued(id),                     990_000_000_000);
        assertEq(vault.pendingRedeemShares(),     990_000_000_000);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),           999_590_890_560);
        assertEq(_vaultSpUsdc(),                  1_049_985_960_258 - 954_142_182_810);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.totalSupply(),             89_445_702_520);
    }

    // Fee rounds up: 999_999_999_999 * 1% = 9_999_999_999.99 -> 10_000_000_000.
    function test_requestRedeem_feeRoundsUp() public {
        _deposit(alice, 1_100_000e6);
        _setRedeemFeeRate(0.01e18);

        uint256 id = _requestRedeem(alice, 999_999_999_999);

        assertEq(_queued(id),         989_999_999_999);
        assertEq(vault.totalSupply(), 1_089_445_702_520 - 10_000_000_000);

        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 999_590_890_559);
    }

    // Known F-5: a 1-wei request with any fee burns the wei and leaves a 0-share ghost entry.
    function test_requestRedeem_oneWeiWithFee_ghostEntry_F5() public {
        _deposit(alice, 100_000e6);
        _setRedeemFeeRate(0.01e18);

        uint256 id = _requestRedeem(alice, 1);

        assertEq(_queued(id),                 0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.totalSupply(),         DEPOSIT_100K_SHARES - 1);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(id, alice);

        // The ghost is skipped by processing and the head moves past it.
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), 1);
    }

    // The fee is burned from escrow, so a request of the full balance with a 1% fee is accepted.
    function test_requestRedeem_fullBalanceWithFee() public {
        _deposit(alice, 100_000e6);
        _setRedeemFeeRate(0.01e18);

        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(_queued(id),            DEPOSIT_100K_SHARES - 990_405_185);  // fee 990_405_185
        assertEq(vault.totalSupply(),    DEPOSIT_100K_SHARES - 990_405_185);
    }

    /**********************************************************************************************/
    /*** 6. Recipients                                                                          ***/
    /**********************************************************************************************/

    // recipient == vault: spUSDC pays the USDC to the vault contract, where nothing can move it.
    function test_processRedeemQueue_recipientIsVault_usdcStuck() public {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeemTo(alice, DEPOSIT_100K_SHARES, address(vault));

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(address(vault)), 99_999_999_998);
        assertEq(usdc.balanceOf(alice),          0);
        assertEq(_queued(id),                    0);
        assertEq(vault.totalSupply(),            0);
        assertEq(_vaultSpUsdc(),                 1);
        assertEq(vault.availableLiquidAssets(),  1);  // the USDC is invisible to the vault

        // take() moves spUSDC only.
        _takeAll();
        assertEq(usdc.balanceOf(address(vault)), 99_999_999_998);
        assertEq(vault.availableLiquidAssets(),  0);

        // No deposit path recycles it either: a later redeem cannot be paid from it.
        _deposit(bob, 100_000e6);
        _requestRedeem(bob, DEPOSIT_100K_SHARES);
        _drainAllSpUsdcLiquidity();
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob),            0);
        assertEq(usdc.balanceOf(address(vault)), 99_999_999_998);
    }

    // recipient == spUSDC: spUSDC transfers the USDC to itself, so the vault's spUSDC is burned
    // and the value is donated to spUSDC holders.
    function test_processRedeemQueue_recipientIsSpUsdc_donatesToSpUsdc() public {
        _deposit(alice, 100_000e6);
        _requestRedeemTo(alice, DEPOSIT_100K_SHARES, address(spUsdc));

        uint256 spUsdcLiq = usdc.balanceOf(address(spUsdc));
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(address(spUsdc)), spUsdcLiq);  // unchanged
        assertEq(_vaultSpUsdc(),                  1);
        assertEq(spUsdc.totalSupply(),            1);
        assertEq(usdc.balanceOf(alice),           0);
    }

    function test_requestRedeem_revertsRecipientZero() public {
        _deposit(alice, 100_000e6);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.requestRedeem(1, address(0));
    }

    /**********************************************************************************************/
    /*** 7. Pause + take                                                                        ***/
    /**********************************************************************************************/

    function test_processRedeemQueue_pausedBlocksRedeemsNotTake() public {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        _pause();

        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processRedeemQueue(type(uint256).max, 10);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelRedeemRequest(id, alice);

        // The taker drains the whole backing while alice is frozen.
        assertEq(_vaultSpUsdc(), DEPOSIT_100K_SPUSDC);
        _takeAll();
        assertEq(_vaultSpUsdc(),                0);
        assertEq(spUsdc.balanceOf(taker),       DEPOSIT_100K_SPUSDC);
        assertEq(vault.availableLiquidAssets(), 0);

        _unpause();
        _processRedeems(type(uint256).max, 10);

        // Alice's claim (99_999_999_998 USDC) is intact but nothing can be paid.
        assertEq(usdc.balanceOf(alice),                      0);
        assertEq(_queued(id),                                DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(),                DEPOSIT_100K_SHARES);
        assertEq(vault.convertToAssets(DEPOSIT_100K_SHARES), 99_999_999_998);
    }

    /**********************************************************************************************/
    /*** 8. Rounding bounds for a single fill                                                   ***/
    /**********************************************************************************************/

    function testFuzz_processRedeemQueue_singleFillRoundingBounds(
        uint256 vsrS, uint256 vsrP, uint256 warp, uint256 depositAmt, uint256 sharesFrac
    ) public {
        vsrS       = bound(vsrS, RAY, MAX_VSR);
        vsrP       = bound(vsrP, RAY, MAX_VSR);
        warp       = bound(warp, 0, 3 * 365 days);
        depositAmt = bound(depositAmt, 2, 100_000_000e6);

        _setSpUsdcVsr(vsrS);
        _setPrimeVsr(vsrP);
        _deposit(alice, depositAmt);
        _deposit(bob,   depositAmt);              // extra backing for prime yield
        _returnSpUsdcLiquidity(depositAmt * 10);  // keep liquidity off the critical path
        _warpAndDrip(warp);

        vm.assume(vault.balanceOf(alice) != 0);  // dust deposits can mint 0 shares (F-4)
        uint256 shares = bound(sharesFrac, 1, vault.balanceOf(alice));
        _requestRedeem(alice, shares);

        uint256 chiP     = vault.nowChi();
        uint256 chiS     = spUsdc.nowChi();
        uint256 spBefore = _vaultSpUsdc();

        // Prime yield can outgrow the backing (notional index), so the fill may be partial.
        uint256 rem  = vault.convertToShares(vault.availableLiquidAssets());
        uint256 fill = rem < shares ? rem : shares;

        _processRedeems(type(uint256).max, 1);

        uint256 paid   = usdc.balanceOf(alice);
        uint256 burned = spBefore - _vaultSpUsdc();

        assertEq(vault.pendingRedeemShares(), shares - fill);

        // |paid - fill * chi_p / RAY| < 1 wei, rounded down.
        assertLe(paid * RAY, fill * chiP);
        assertLt(fill * chiP - paid * RAY, RAY);

        // burned = ceil(paid * RAY / chi_s): at most 1 wei above the exact value.
        assertGe(burned * chiS, paid * RAY);
        assertLt(burned * chiS - paid * RAY, chiS);
        assertEq(burned, _divUp(paid * RAY, chiS));

        // What the vault gave up in spUSDC is worth less than paid + chi_s/RAY (1 wei spUSDC).
        assertLe(spUsdc.convertToAssets(burned), paid + chiS / RAY + 1);
    }

    /**********************************************************************************************/
    /*** 9. Large queue, batched processing, gas                                                ***/
    /**********************************************************************************************/

    function test_processRedeemQueue_200UsersIn4BatchesOf50() public {
        uint256 n = 200;
        address[] memory users = new address[](n);
        for (uint256 i; i < n; ++i) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
            _deposit(users[i], 5_000e6);
            assertEq(vault.balanceOf(users[i]), 4_952_025_919);
            _requestRedeem(users[i], 4_952_025_919);
        }

        assertEq(vault.pendingRedeemShares(),     n * 4_952_025_919);
        assertEq(vault.balanceOf(address(vault)), n * 4_952_025_919);
        assertEq(_vaultSpUsdc(),                  n * 4_772_663_455);
        assertEq(_queueLength(),                  n);

        uint256 totalGas;
        for (uint256 b; b < 4; ++b) {
            uint256 g = gasleft();
            _processRedeems(type(uint256).max, 50);
            totalGas += g - gasleft();
            assertEq(vault.firstPendingRedeemId(), (b + 1) * 50);
        }
        emit log_named_uint("gas for 200 fills (4 calls of 50)", totalGas);
        emit log_named_uint("gas per fill",                      totalGas / n);
        assertLt(totalGas / n, 60_000);

        for (uint256 i; i < n; ++i) {
            assertEq(usdc.balanceOf(users[i]), 4_999_999_998);
            assertEq(_queued(i),               0);
        }
        assertEq(vault.firstPendingRedeemId(),              200);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(),             0);
        assertEq(_vaultSpUsdc(),                  n * (4_772_663_455 - 4_772_663_454));  // 200 wei
        assertEq(usdc.balanceOf(address(spUsdc)), n * 5_000e6 - n * 4_999_999_998);
    }

    /**********************************************************************************************/
    /*** 10. Edge cases                                                                         ***/
    /**********************************************************************************************/

    function test_processRedeemQueue_zeroLiquidity_noop() public {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _drainAllSpUsdcLiquidity();

        assertEq(vault.availableLiquidAssets(), 0);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),       0);
        assertEq(_queued(id),                 DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(), DEPOSIT_100K_SHARES);
        assertEq(vault.firstPendingRedeemId(),          0);
    }

    function test_processRedeemQueue_afterFullTake_noop() public {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _takeAll();

        assertEq(_vaultSpUsdc(),                0);
        assertEq(vault.availableLiquidAssets(), 0);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),       0);
        assertEq(_queued(id),                 DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(), DEPOSIT_100K_SHARES);
        assertEq(vault.firstPendingRedeemId(),          0);

        // 1 spUSDC share back: worth 1 wei USDC, converts to 0 prime shares, still a no-op.
        _returnToVault(1);
        assertEq(vault.availableLiquidAssets(), 1);
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(_vaultSpUsdc(),        1);
    }

    function test_requestRedeem_revertsInsufficientBalanceBoundary() public {
        _deposit(alice, 100_000e6);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.requestRedeem(DEPOSIT_100K_SHARES + 1, alice);

        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        assertEq(_queued(id),            DEPOSIT_100K_SHARES);
        assertEq(vault.balanceOf(alice), 0);
    }

    // BUG (Low): the `shares_ != 0` check is gone (src/SparkPrimeVault.sol:487 only requires
    // `shares_ >= minRedeem`). With `minRedeem == 0` (the initial value) `requestRedeem(0)` succeeds,
    // moves nothing, burns no fee and pushes a 0-share ghost entry that cannot be cancelled and
    // consumes a `maxRequests_` slot on every pass until the head moves past it.
    function test_BUG_requestRedeem_zeroSharesCreatesGhostEntry() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _setRedeemFeeRate(0.01e18);  // fee on 0 is 0, no deterrent
        assertEq(vault.minRedeem(), 0);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RedeemRequest(alice, alice, 0, 0, 0);
        vm.prank(alice);
        uint256 ghost = vault.requestRedeem(0, alice);

        assertEq(ghost,                       0);
        assertEq(_queued(ghost),              0);
        assertEq(_queueLength(),              1);
        assertEq(vault.balanceOf(alice),      DEPOSIT_100K_SHARES);  // nothing moved
        assertEq(vault.totalSupply(),         2 * DEPOSIT_100K_SHARES);  // no fee burned
        assertEq(vault.pendingRedeemShares(), 0);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(ghost, alice);

        // Anyone can push ghosts for gas only: 10 more from carol, who holds no shares at all.
        for (uint256 i; i < 10; ++i) {
            vm.prank(carol);
            vault.requestRedeem(0, carol);
        }
        assertEq(_queueLength(), 11);

        // A real request behind them needs 12 `maxRequests_` slots to be reached in one call.
        uint256 idB = _requestRedeem(bob, DEPOSIT_100K_SHARES);
        assertEq(idB, 11);

        _processRedeems(type(uint256).max, 11);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(vault.firstPendingRedeemId(),  11);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob), 98_999_999_998);  // 1% fee on bob's real request
        assertEq(vault.firstPendingRedeemId(),  12);

        // `minRedeem = 1` share is enough to close the path.
        _setMinRedeem(1);
        vm.prank(carol);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(0, carol);
    }

    // `minRedeem` is denominated in SHARES (src/SparkPrimeVault.sol:199, 487): minRedeem - 1
    // reverts, exactly minRedeem passes, independent of chi.
    function test_requestRedeem_minRedeemBoundary_inShares() public {
        _deposit(alice, 100_000e6);
        _setMinRedeem(1_000e6);
        assertEq(vault.minRedeem(), 1_000e6);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(1_000e6 - 1, alice);

        uint256 id = _requestRedeem(alice, 1_000e6);
        assertEq(_queued(id), 1_000e6);

        // In asset terms the floor is chi-dependent: 1_000e6 shares = 1_009_687_768 USDC today.
        assertEq(vault.convertToAssets(1_000e6), 1_009_687_768);

        // With a 1% fee the queued amount is below the minimum (minimum is gross of fee).
        _setRedeemFeeRate(0.01e18);
        uint256 id2 = _requestRedeem(alice, 1_000e6);
        assertEq(_queued(id2), 990_000_000);
    }

    // The share-denominated minimum drifts in asset terms as chi grows: after a year at 5% the
    // same `minRedeem` of 1_000e6 shares is worth 1_060_172_156 USDC (+5.0%), and a request that
    // was worth 1_050e6 USDC at request time is still rejected.
    function test_requestRedeem_minRedeemDriftsInAssetTerms() public {
        _deposit(alice, 100_000e6);
        _setMinRedeem(1_000e6);
        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);

        assertEq(vault.nowChi(),                  1.060172156654584269839902363e27);
        assertEq(vault.convertToAssets(1_000e6),  1_060_172_156);
        assertEq(vault.convertToShares(1_050e6),  990_405_184);  // 1_050 USDC worth of shares

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(990_405_184, alice);  // 1_050e6 USDC worth, below 1_000e6 shares

        uint256 id = _requestRedeem(alice, 1_000e6);
        assertEq(_queued(id), 1_000e6);
    }

    // Non-head cancelled (and F-5 ghost) entries are skipped but still consume `maxRequests_`
    // (src/SparkPrimeVault.sol:825 sizes `end_` by index, line 832 `continue`s past them). A
    // cancelled HEAD entry no longer costs a slot because the cancel advances the head (line 527).
    function test_processRedeemQueue_cancelledEntryCountsTowardMaxRequests() public {
        (uint256 idA, uint256 idB, uint256 idC) = _threeDepositorsQueued();

        vm.prank(bob);
        vault.cancelRedeemRequest(idB, bob);  // non-head hole at index 1

        assertEq(vault.balanceOf(bob),            DEPOSIT_100K_SHARES);
        assertEq(vault.balanceOf(address(vault)), 2 * DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(),     2 * DEPOSIT_100K_SHARES);
        assertEq(_queued(idB),                    0);
        assertEq(vault.firstPendingRedeemId(),              0);

        _processRedeems(type(uint256).max, 2);  // slot 1: alice, slot 2: the hole

        assertEq(usdc.balanceOf(alice), 99_999_999_998);
        assertEq(usdc.balanceOf(carol), 0);
        assertEq(_queued(idA),          0);
        assertEq(vault.firstPendingRedeemId(),    2);

        _processRedeems(type(uint256).max, 1);  // fills carol

        assertEq(usdc.balanceOf(carol), 99_999_999_998);
        assertEq(_queued(idC),          0);
        assertEq(vault.firstPendingRedeemId(),    3);

        // Contrast: a head cancel is free for the planner. alice re-queues, bob re-queues, alice
        // cancels at the head; one slot reaches bob.
        _deposit(alice, 100_000e6);
        uint256 idA2 = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _requestRedeem(bob, DEPOSIT_100K_SHARES);
        vm.prank(alice);
        vault.cancelRedeemRequest(idA2, alice);
        assertEq(vault.firstPendingRedeemId(), 4);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob), 99_999_999_998);
        assertEq(vault.firstPendingRedeemId(),  5);
    }

    /**********************************************************************************************/
    /*** 11. Invariant-style fuzz                                                               ***/
    /**********************************************************************************************/

    // Random sequence of deposits, requests, ghosts, cancels, owner repoints (strangers and dead
    // entries assert the revert), drains, takes and partial processing.
    // After every step: balanceOf(vault) == pendingRedeemShares == sum of open request shares,
    // and every entry before redeemHead is settled or cancelled.
    function testFuzz_processRedeemQueue_balanceOfVaultEqualsPendingRedeemShares(uint256 seed)
        public
    {
        address[3] memory users = [alice, bob, carol];
        _setSpUsdcVsr(FOUR_PCT_VSR);
        _setPrimeVsr(ONE_PCT_VSR);
        _setRedeemFeeRate(0.001e18);

        for (uint256 step; step < 24; ++step) {
            uint256 r      = uint256(keccak256(abi.encode(seed, step)));
            address u      = users[r % 3];
            uint256 action = (r >> 8) % 9;
            uint256 amt    = (r >> 16) % 1_000_000e6 + 1;

            if (action == 0) {
                _deposit(u, amt);
            } else if (action == 7) {
                vm.prank(u);
                vault.requestRedeem(0, u);  // zero-share ghost (new, minRedeem == 0)
            } else if (action == 8) {
                uint256 qlen = _queueLength();
                if (qlen != 0) {
                    uint256 id = (r >> 40) % qlen;
                    address to = users[(r >> 72) % 3];
                    (address owner, , uint256 sh) = _redeemRequest(id);
                    if (sh == 0) {
                        vm.prank(u);
                        vm.expectRevert("SparkPrimeVault/no-request");  // dead entry
                        vault.updateRedeemRecipient(id, to);
                    } else {
                        if (u != owner) {
                            vm.prank(u);
                            vm.expectRevert("SparkPrimeVault/not-authorized");  // owner-only
                            vault.updateRedeemRecipient(id, to);
                        }
                        vm.prank(owner);
                        vault.updateRedeemRecipient(id, to);
                    }
                }
            } else if (action == 1) {
                uint256 bal = vault.balanceOf(u);
                if (bal != 0) _requestRedeem(u, bound(amt, 1, bal));
            } else if (action == 2) {
                uint256 qlen = _queueLength();
                if (qlen != 0) {
                    uint256 id = (r >> 40) % qlen;
                    (address owner, , uint256 sh) = _redeemRequest(id);
                    if (sh != 0) { vm.prank(owner); vault.cancelRedeemRequest(id, owner); }
                }
            } else if (action == 3) {
                uint256 maxShares = (r >> 40) % 2 == 0 ? type(uint256).max : amt;
                vm.prank(rebalancer);
                try vault.processRedeemQueue(maxShares, (r >> 48) % 4) {}
                catch Error(string memory reason) {
                    assertEq(reason, "SparkVault/insufficient-balance");  // known over-burn (C-1)
                }
            } else if (action == 4) {
                uint256 liq = usdc.balanceOf(address(spUsdc));
                if (liq != 0) _drainSpUsdcLiquidity(bound(amt, 1, liq));
            } else if (action == 5) {
                _returnSpUsdcLiquidity(amt);
            } else {
                uint256 held = _vaultSpUsdc();
                if (held != 0) _take(bound(amt, 1, held));
            }
            _warpAndDrip((r >> 64) % 7 days);

            uint256 open;
            uint256 qlen2 = _queueLength();
            for (uint256 i; i < qlen2; ++i) open += _queued(i);
            assertEq(vault.balanceOf(address(vault)), vault.pendingRedeemShares());
            assertEq(vault.pendingRedeemShares(),     open);
            assertLe(vault.firstPendingRedeemId(),              qlen2);
            for (uint256 i; i < vault.firstPendingRedeemId(); ++i) assertEq(_queued(i), 0);
            assertEq(vault.balanceOf(address(vault)) + _sumUserBalances(users), vault.totalSupply());
        }
    }

    function _sumUserBalances(address[3] memory users) internal view returns (uint256 sum) {
        for (uint256 i; i < 3; ++i) sum += vault.balanceOf(users[i]);
    }

    // Every fill pays exactly floor(filled * chi / RAY) to its recipient, burns exactly the
    // filled shares, and the spUSDC given up is worth at most 1 wei USDC per fill above what was
    // paid.
    function testFuzz_processRedeemQueue_neverPaysMoreThanSharesTimesChi(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        _setSpUsdcVsr(FIVE_PCT_VSR);
        _setPrimeVsr(FOUR_PCT_VSR);

        for (uint256 step; step < 16; ++step) {
            uint256 r   = uint256(keccak256(abi.encode(seed, step)));
            address u   = users[r % 3];
            uint256 amt = (r >> 16) % 1_000_000e6 + 1;

            if (step % 2 == 0) {
                _deposit(u, amt);
                _requestRedeem(u, bound(r >> 40, 1, vault.balanceOf(u)));
                if ((r >> 80) % 3 == 0) {
                    _drainSpUsdcLiquidity(bound(r >> 96, 0, usdc.balanceOf(address(spUsdc))));
                }
                if ((r >> 120) % 3 == 0) _take(bound(r >> 136, 0, _vaultSpUsdc()));
                continue;
            }

            _warpAndDrip((r >> 64) % 30 days);
            _processAndCheckPayouts(users, amt, 5);
        }
    }

    struct Snap {
        uint256 chiP;
        uint256 supply;
        uint256 spBefore;
        uint256 liqBefore;
        uint256 qlen;
    }

    function _processAndCheckPayouts(address[3] memory users, uint256 maxShares, uint256 maxReq)
        internal
    {
        Snap memory s = Snap(
            vault.nowChi(), vault.totalSupply(), _vaultSpUsdc(),
            usdc.balanceOf(address(spUsdc)), _queueLength()
        );
        uint256[]  memory before = new uint256[](s.qlen);
        address[]  memory rcpts  = new address[](s.qlen);  // entries are deleted on full fill
        uint256[3] memory balBefore;
        for (uint256 i; i < s.qlen; ++i) (, rcpts[i], before[i]) = _redeemRequest(i);
        for (uint256 i; i < 3; ++i) balBefore[i] = usdc.balanceOf(users[i]);

        vm.prank(rebalancer);
        try vault.processRedeemQueue(maxShares, maxReq) {}
        catch Error(string memory reason) {
            assertEq(reason, "SparkVault/insufficient-balance");  // known over-burn (C-1)
            return;
        }

        (uint256[3] memory expected, uint256 filledTotal, uint256 fills) =
            _expectedPayouts(users, before, rcpts, s.chiP);

        uint256 paidTotal;
        for (uint256 i; i < 3; ++i) {
            assertEq(usdc.balanceOf(users[i]) - balBefore[i], expected[i]);
            paidTotal += expected[i];
        }
        assertEq(s.supply - vault.totalSupply(),                 filledTotal);
        assertLe(filledTotal,                                    maxShares);
        assertEq(s.liqBefore - usdc.balanceOf(address(spUsdc)),  paidTotal);
        assertLe(spUsdc.convertToAssets(s.spBefore - _vaultSpUsdc()), paidTotal + fills);
    }

    function _expectedPayouts(
        address[3] memory users, uint256[] memory before, address[] memory rcpts, uint256 chiP
    )
        internal view returns (uint256[3] memory expected, uint256 filledTotal, uint256 fills)
    {
        for (uint256 i; i < before.length; ++i) {
            uint256 filled = before[i] - _queued(i);
            if (filled == 0) continue;
            uint256 idx = rcpts[i] == users[0] ? 0 : rcpts[i] == users[1] ? 1 : 2;
            expected[idx] += filled * chiP / RAY;
            filledTotal   += filled;
            ++fills;
        }
    }


    /**********************************************************************************************/
    /*** 12. Cancel: head advance, zero recipient, delete-after-fill                             ***/
    /**********************************************************************************************/

    // Cancelling the head entry advances `redeemHead` past it AND past every zero-share entry
    // behind it (src/SparkPrimeVault.sol:527-532), so the next pass starts at the first live one.
    function test_cancelRedeemRequest_headCancelSkipsGhostsBehindIt() public {
        _deposit(alice, 100_000e6);
        _deposit(carol, 100_000e6);

        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);  // 0
        vm.prank(bob);  vault.requestRedeem(0, bob);                 // 1, ghost (no shares needed)
        vm.prank(bob);  vault.requestRedeem(0, bob);                 // 2, ghost
        uint256 idC = _requestRedeem(carol, DEPOSIT_100K_SHARES);  // 3
        assertEq(idA, 0);
        assertEq(idC, 3);
        assertEq(vault.firstPendingRedeemId(), 0);

        vm.expectEmit(true, true, true, true, address(vault));
        emit CancelRedeemRequest(idA, DEPOSIT_100K_SHARES);
        vm.prank(alice);
        vault.cancelRedeemRequest(idA, alice);

        assertEq(vault.firstPendingRedeemId(),          3);  // jumped over 0, 1, 2
        assertEq(vault.balanceOf(alice),      DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(), DEPOSIT_100K_SHARES);

        // The cancelled entry is fully zeroed (owner too), so it reads as "no request".
        (address o, address r, uint256 sh) = _redeemRequest(idA);
        assertEq(o,  address(0));
        assertEq(r,  address(0));
        assertEq(sh, 0);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(idA, alice);

        // One slot is now enough to reach carol (the ghosts no longer cost `maxRequests_`).
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(carol), 99_999_999_998);
        assertEq(vault.firstPendingRedeemId(),    4);
    }

    // Cancelling a non-head entry leaves the head alone; the hole is skipped later (and still
    // costs a `maxRequests_` slot, RQ-3).
    function test_cancelRedeemRequest_nonHeadCancelLeavesHead() public {
        (uint256 idA, uint256 idB, uint256 idC) = _threeDepositorsQueued();

        vm.prank(idB == 1 ? bob : bob);
        vault.cancelRedeemRequest(idB, bob);
        assertEq(vault.firstPendingRedeemId(), 0);

        vm.prank(carol);
        vault.cancelRedeemRequest(idC, carol);
        assertEq(vault.firstPendingRedeemId(), 0);

        _processRedeems(type(uint256).max, 1);  // pays alice, head lands on the hole at 1
        assertEq(usdc.balanceOf(alice), 99_999_999_998);
        assertEq(_queued(idA),          0);
        assertEq(vault.firstPendingRedeemId(),    1);

        _processRedeems(type(uint256).max, 10);  // walks over the two holes
        assertEq(vault.firstPendingRedeemId(),          3);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    // Cancelling the only (last) entry leaves head == queue length; a later request is at the
    // head immediately.
    function test_cancelRedeemRequest_lastEntryCancelMovesHeadToLength() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        vm.prank(alice);
        vault.cancelRedeemRequest(idA, alice);

        assertEq(_queueLength(),              1);
        assertEq(vault.firstPendingRedeemId(),          1);
        assertEq(vault.pendingRedeemShares(), 0);

        _processRedeems(type(uint256).max, 10);  // nothing to do, no revert
        assertEq(vault.firstPendingRedeemId(), 1);

        uint256 idB = _requestRedeem(bob, DEPOSIT_100K_SHARES);
        assertEq(idB, 1);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob), 99_999_999_998);
        assertEq(vault.firstPendingRedeemId(),  2);
    }

    // Partial fill (liquidity bound) leaves the entry at the head; the owner cancels the
    // remainder, gets exactly the unfilled shares back and the head advances (past a ghost too).
    function test_cancelRedeemRequest_afterPartialFill_refundsRemainderAndAdvancesHead() public {
        _deposit(alice, 1_000_000e6);
        _deposit(carol, 100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_1M_SHARES);  // 0
        vm.prank(bob); vault.requestRedeem(0, bob);                // 1, ghost
        uint256 idC = _requestRedeem(carol, DEPOSIT_100K_SHARES); // 2
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 300_000e6);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),       299_999_999_999);
        assertEq(_queued(idA),                693_283_628_876);
        assertEq(vault.firstPendingRedeemId(),          0);
        assertEq(vault.pendingRedeemShares(), 693_283_628_876 + DEPOSIT_100K_SHARES);

        vm.prank(alice);
        vault.cancelRedeemRequest(idA, alice);

        assertEq(vault.balanceOf(alice),          693_283_628_876);
        assertEq(vault.balanceOf(address(vault)), DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(),     DEPOSIT_100K_SHARES);
        assertEq(vault.firstPendingRedeemId(),              2);  // past 0 (cancelled) and 1 (ghost)
        assertEq(_queued(idA),                    0);

        _returnSpUsdcLiquidity(100_000e6);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(carol), 99_999_999_998);
        assertEq(_queued(idC),          0);
        assertEq(vault.firstPendingRedeemId(),    3);
    }

    function test_cancelRedeemRequest_revertsRecipientZero() public {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.cancelRedeemRequest(id, address(0));
    }

    // A fully filled entry is `delete`d (src/SparkPrimeVault.sol:849): the getter returns zeros,
    // a partial fill keeps owner and recipient.
    function test_processRedeemQueue_fullFillDeletesEntry() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeemTo(alice, DEPOSIT_100K_SHARES, carol);
        uint256 idB = _requestRedeem(bob, DEPOSIT_100K_SHARES);

        _processRedeems(DEPOSIT_100K_SHARES + 1, 10);  // alice full, bob 1 share

        (address o, address r, uint256 sh) = _redeemRequest(idA);
        assertEq(o,  address(0));
        assertEq(r,  address(0));
        assertEq(sh, 0);
        assertEq(usdc.balanceOf(carol), 99_999_999_998);

        (o, r, sh) = _redeemRequest(idB);
        assertEq(o,  bob);
        assertEq(r,  bob);
        assertEq(sh, DEPOSIT_100K_SHARES - 1);
        assertEq(usdc.balanceOf(bob), 1);
        assertEq(vault.firstPendingRedeemId(),  1);

        // The deleted entry is dead for cancel; the slot still exists in the array.
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(idA, alice);
        assertEq(_queueLength(), 2);
    }

    // Event argument order on refactor/more-simplifying: Redeem(owner, recipient, shares, assets).
    function test_processRedeemQueue_emitsRedeemSharesThenAssets() public {
        _deposit(alice, 100_000e6);
        _requestRedeemTo(alice, DEPOSIT_100K_SHARES, bob);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(alice, bob, DEPOSIT_100K_SHARES, 99_999_999_998);
        _processRedeems(type(uint256).max, 1);
    }

    /**********************************************************************************************/
    /*** 13. updateRedeemRecipient                                                              ***/
    /**********************************************************************************************/

    // Intended path: the owner repoints a queued redeem and the fill pays the new recipient.
    function test_updateRedeemRecipient_ownerRepointsAndFillPaysNewRecipient() public {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RedeemRecipientUpdated(id, bob);
        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);

        (address o, address r, uint256 sh) = _redeemRequest(id);
        assertEq(o,  alice);  // owner (refund target) unchanged
        assertEq(r,  bob);
        assertEq(sh, DEPOSIT_100K_SHARES);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateRedeemRecipient(id, address(0));

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),   99_999_999_998);
        assertEq(usdc.balanceOf(alice), 0);
    }

    // C-2 unblock path since ff828d2: `updateRedeemRecipient` (src/SparkPrimeVault.sol:537-546)
    // is owner-only, so a stranger cannot repoint a blacklisted head. The queue stays blocked for
    // everyone behind it; the only third-party unblock left is the guardian cancel. Here alice is
    // an honest user blacklisted after queueing 100k, bob is stuck behind her.
    function test_updateRedeemRecipient_strangerCannotRepointBlacklistedHead() public {
        address mallory = makeAddr("mallory");
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idB = _requestRedeem(bob,   DEPOSIT_100K_SHARES);

        // alice gets blacklisted while queued.
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(usdc.transfer.selector, alice),
            "Blacklistable: account is blacklisted"
        );

        vm.prank(rebalancer);
        vm.expectRevert("Blacklistable: account is blacklisted");
        vault.processRedeemQueue(type(uint256).max, 10);

        // Neither an outsider, nor the stuck redeemer behind her, nor the guardian can repoint.
        address[3] memory callers = [mallory, bob, guardian];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.updateRedeemRecipient(idA, callers[i]);
        }

        (address o, address r, uint256 sh) = _redeemRequest(idA);
        assertEq(o,  alice);
        assertEq(r,  alice);
        assertEq(sh, DEPOSIT_100K_SHARES);

        // Still blocked.
        vm.prank(rebalancer);
        vm.expectRevert("Blacklistable: account is blacklisted");
        vault.processRedeemQueue(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(vault.firstPendingRedeemId(),  0);

        // Guardian cancel (shares back to the owner) remains the planner's unblock for C-2.
        vm.prank(guardian);
        vault.cancelRedeemRequest(idA, alice);
        assertEq(vault.balanceOf(alice), DEPOSIT_100K_SHARES);
        assertEq(vault.firstPendingRedeemId(),     1);

        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob),         99_999_999_998);
        assertEq(usdc.balanceOf(mallory),     0);
        assertEq(_queued(idB),                0);
        assertEq(vault.firstPendingRedeemId(),          2);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    // The owner of a blacklisted head can self-rescue by repointing to a clean address: the queue
    // flows again and the payout lands where the owner says.
    function test_updateRedeemRecipient_ownerSelfRescuesBlacklistedHead() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idB = _requestRedeem(bob,   DEPOSIT_100K_SHARES);

        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(usdc.transfer.selector, alice),
            "Blacklistable: account is blacklisted"
        );

        vm.prank(rebalancer);
        vm.expectRevert("Blacklistable: account is blacklisted");
        vault.processRedeemQueue(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob), 0);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RedeemRecipientUpdated(idA, carol);
        vm.prank(alice);
        vault.updateRedeemRecipient(idA, carol);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(alice, carol, DEPOSIT_100K_SHARES, 99_999_999_998);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(carol),       99_999_999_998);  // alice's payout, her choice
        assertEq(usdc.balanceOf(alice),       0);
        assertEq(usdc.balanceOf(bob),         99_999_999_998);  // queue unblocked
        assertEq(_queued(idA),                0);
        assertEq(_queued(idB),                0);
        assertEq(vault.firstPendingRedeemId(),          2);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    // Repointing a dead (filled or cancelled) entry reverts `no-request` (src/SparkPrimeVault.sol:542)
    // for everyone, the former owner included; an index past the array reverts with an
    // out-of-bounds panic.
    function test_updateRedeemRecipient_deadEntryAndOutOfRange() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 filled    = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 cancelled = _requestRedeem(bob,   DEPOSIT_100K_SHARES);
        _processRedeems(type(uint256).max, 1);
        vm.prank(bob);
        vault.cancelRedeemRequest(cancelled, bob);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateRedeemRecipient(filled, carol);

        vm.prank(carol);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateRedeemRecipient(filled, carol);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateRedeemRecipient(cancelled, carol);

        (address o, address r, uint256 sh) = _redeemRequest(filled);
        assertEq(o,  address(0));
        assertEq(r,  address(0));
        assertEq(sh, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x32));
        vault.updateRedeemRecipient(cancelled + 1, carol);

        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(carol), 0);
        assertEq(vault.firstPendingRedeemId(),    2);
    }

    /**********************************************************************************************/
    /*** 14. C-2: blacklisted recipient blocks the queue (re-confirmed)                          ***/
    /**********************************************************************************************/

    // BUG (C-2, re-confirmed): src/SparkPrimeVault.sol:845 pays inside the strict FIFO loop with
    // no skip-on-failure. Mainnet USDC reverts transfers to blacklisted addresses, so one 1-share
    // request to such an address at the head reverts every `processRedeemQueue` call.
    function test_BUG_blacklistedRecipientBlocksRedeemQueue() public {
        address attacker    = makeAddr("attacker");
        address blacklisted = makeAddr("blacklisted");
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(usdc.transfer.selector, blacklisted),
            "Blacklistable: account is blacklisted"
        );

        _deposit(attacker, 1e6);
        _deposit(alice, 1_000_000e6);
        uint256 attackerShares = vault.balanceOf(attacker);

        vm.prank(attacker);
        uint256 jamId = vault.requestRedeem(1, blacklisted);
        _requestRedeem(alice, DEPOSIT_1M_SHARES);

        vm.prank(rebalancer);
        vm.expectRevert("Blacklistable: account is blacklisted");
        vault.processRedeemQueue(type(uint256).max, 10);

        // No way to skip: maxShares/maxRequests cannot jump over the head entry.
        vm.prank(rebalancer);
        vm.expectRevert("Blacklistable: account is blacklisted");
        vault.processRedeemQueue(type(uint256).max, 1);
        vm.prank(rebalancer);
        vm.expectRevert("Blacklistable: account is blacklisted");
        vault.processRedeemQueue(1, 1);

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.firstPendingRedeemId(),    0);

        // Guardian cancel (refund to the owner) unblocks; the attacker is made whole and can
        // re-jam for gas only. The head now advances on cancel, so alice is reachable with 1 slot.
        vm.prank(guardian);
        vault.cancelRedeemRequest(jamId, attacker);
        assertEq(vault.balanceOf(attacker), attackerShares);
        assertEq(vault.firstPendingRedeemId(),        1);

        vm.prank(attacker);
        vault.requestRedeem(1, blacklisted);  // id 2, behind alice

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 999_999_999_998);
        assertEq(vault.firstPendingRedeemId(),    2);

        // The next honest redeemer is stuck behind the new jam again.
        _deposit(bob, 10e6);
        _requestRedeem(bob, vault.balanceOf(bob));
        vm.prank(rebalancer);
        vm.expectRevert("Blacklistable: account is blacklisted");
        vault.processRedeemQueue(type(uint256).max, 10);
    }

    /**********************************************************************************************/
    /*** 15. realizeLoss while queued (mirror of RQ-5)                                          ***/
    /**********************************************************************************************/

    // `realizeLoss` (src/SparkPrimeVault.sol:369-385, paused only, 0 < loss < totalAssets since
    // ff828d2) sets chi = floor((totalAssets - loss) * RAY / totalSupply) for everyone, escrowed
    // shares included: a queued redeemer is paid at the reduced chi and takes the loss pro rata.
    function test_processRedeemQueue_realizeLossWhileQueued_escrowTakesLossProRata() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        assertEq(vault.convertToAssets(DEPOSIT_100K_SHARES), 99_999_999_998);
        assertEq(vault.totalAssets(),                        199_999_999_997);

        _pause();
        _realizeLoss(10_000e6);  // 5% of the book
        _unpause();

        // chi = floor((199_999_999_997 - 10_000e6) * RAY / 198_081_036_820)
        uint256 chiAfter = vault.nowChi();
        assertEq(chiAfter, (199_999_999_997 - 10_000e6) * RAY / (2 * DEPOSIT_100K_SHARES));
        assertEq(chiAfter, 0.959203379825079411152892409e27);
        assertEq(vault.totalAssets(), 189_999_999_996);

        _processRedeems(type(uint256).max, 10);

        // alice is paid 94_999_999_998 instead of 99_999_999_998: the escrow absorbed exactly
        // half of the 10_000 USDC loss (5_000_000_000).
        assertEq(usdc.balanceOf(alice),       94_999_999_998);
        assertEq(_queued(id),                 0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.assetsOf(bob),         94_999_999_998);  // bob took the other half

        // The backing did not shrink here (spUSDC is intact), so 105_000_000_000 USDC worth of
        // spUSDC backs bob's 94_999_999_998 claim: a loss realized before the capital actually
        // disappears leaves a surplus that `take` can remove and chi never gives back.
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 105_000_000_000);
    }


    /**********************************************************************************************/
    /*** 16. realizeGain while queued (mirror of RQ-5, new at ff828d2)                          ***/
    /**********************************************************************************************/

    // `realizeGain` (src/SparkPrimeVault.sol:297-309, DEFAULT_ADMIN, no pause required) sets
    // chi = floor((totalAssets + gain) * RAY / totalSupply) for everyone, escrowed shares included:
    // a queued redeemer is paid MORE after a gain, pro rata with the holders.
    function test_processRedeemQueue_realizeGainWhileQueued_escrowSharesGainProRata() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        assertEq(vault.convertToAssets(DEPOSIT_100K_SHARES), 99_999_999_998);
        assertEq(vault.totalAssets(),                        199_999_999_997);
        assertFalse(vault.paused());

        vm.expectEmit(true, true, true, true, address(vault));
        emit GainRealized(uint192(1.060172156650366224592543507e27), 10_000e6);
        vm.prank(admin);
        vault.realizeGain(10_000e6);  // 5% of the book

        // chi = floor((199_999_999_997 + 10_000e6) * RAY / 198_081_036_820)
        uint256 chiAfter = vault.nowChi();
        assertEq(chiAfter, (199_999_999_997 + 10_000e6) * RAY / (2 * DEPOSIT_100K_SHARES));
        assertEq(chiAfter, 1.060172156650366224592543507e27);
        assertEq(vault.totalAssets(), 209_999_999_996);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(alice, alice, DEPOSIT_100K_SHARES, 104_999_999_998);
        _processRedeems(type(uint256).max, 10);

        // alice is paid 104_999_999_998 instead of 99_999_999_998: the escrow received exactly
        // half of the 10_000 USDC gain (5_000_000_000); bob's claim grew by the other half.
        assertEq(usdc.balanceOf(alice),       104_999_999_998);
        assertEq(_queued(id),                 0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.assetsOf(bob),         104_999_999_998);

        // The backing did not grow (spUSDC VSR is RAY): alice's extra 5_000e6 was paid out of the
        // common spUSDC, so bob's 104_999_999_998 claim is backed by 95_000_000_000 USDC until
        // the realised gain actually arrives (RQ-5 yield case, same shape).
        assertEq(_vaultSpUsdc(),                         90_680_605_659);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 95_000_000_000);
    }

}
