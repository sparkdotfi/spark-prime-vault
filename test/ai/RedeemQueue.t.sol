// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { VmSafe } from "../../lib/forge-std/src/Vm.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

/// @dev Redeem-queue campaign: `requestRedeem`, `updateRedeemRecipient`, `processPendingRedeems`.
///
///      Harness state after setUp (both VSRs frozen at RAY):
///        chi_s (spUSDC)  = 1.047633055711877768967605062e27
///        chi_p (spPRIME) = 1.009687768242461209408770821e27
///      A 1_000_000e6 deposit gives the vault 954_532_691_143 spUSDC and mints 990_405_184_109
///      spPRIME; a 100_000e6 deposit gives 95_453_269_114 spUSDC / 99_040_518_410 spPRIME.
///
///      Notation in comments: L = USDC held by spUSDC, S = spUSDC held by the vault,
///      A = spUSDC.maxWithdraw(vault) = min(L, floor(S * chi_s / RAY)),
///      rem = floor(A * RAY / chi_p) (the share budget `_processPendingRedeems` computes once).
///
///      Round 2: ported to upstream `refactor/more-simplifying` (`minRedeem` in shares, no
///      `shares_ != 0` check, entries are `delete`d after a full fill, `realizeLoss` instead of
///      `setChi`, `Redeem(owner, recipient, shares, assets)`).
///      Round 3 (ff828d2): `updateRedeemRecipient` became owner-only on a live entry;
///      `realizeLoss` / `realizeGain` (both replaced on master, see round 5).
///      Round 4 (bf93b0d): `cancelRedeemRequest` is removed. A redeem request is final: the
///      escrow leaves only through `_processPendingRedeems` and the only user action on a queued
///      entry is `updateRedeemRecipient` (owner only). The redeem head never walks, so every dead
///      entry costs one `maxRequests_` slot. Section 12 proves finality.
///      Round 5 (`master` @ 0ebb452): line numbers below are on 0ebb452. `requestRedeem` :446-473
///      (zero recipient :451, blacklist check :452, `minRedeem` :453, escrow transfer :457, fee
///      :460-462, push :468); `updateRedeemRecipient` :506-516 (blacklist :508, `no-request`
///      :512, owner :513); `claim` :524-534; `_processPendingRedeems` :900-932 (budget :903,
///      loop :908-929, `continue` :911, `_burn` :920, `_withdrawSavings` :922, `delete` :928);
///      `_withdrawSavings` :947-958 (blacklist fallback :955-957); `_incrementClaimableAssets`
///      :1044-1048; `_canReceiveAsset` :1051-1053; `adjustTotalAssets` :278-295; `take` :340-349.
///      The round-4 permanent blacklist jam (RQ-10 / R4-A) is FIXED: a blacklisted recipient is
///      rejected at request time and, if blacklisted after queueing, paid into
///      `claimableAssets` (section 14, `test_fixed_*`). `realizeLoss` / `realizeGain` are
///      replaced by `adjustTotalAssets` (paused only), sections 15-16.
contract RedeemQueueTest is LocalTestBase {

    event Redeem(
        address indexed owner,
        address indexed recipient,
        uint256         sharesBurned,
        uint256         savingsSharesBurned,
        uint256         assetsReceived
    );

    event RedeemRequest(
        address indexed owner,
        address indexed recipient,
        uint256 indexed requestId,
        uint256         sharesToBurn,
        uint256         feeSharesBurned
    );

    event RedeemRecipientUpdated(uint256 indexed requestId, address indexed recipient);

    event TotalAssetsAdjusted(uint192 chi, int256 deltaTotalAssets);

    event ClaimableAssetsIncreased(address indexed recipient, uint256 increase);

    event Claim(address indexed recipient, uint256 assets);

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

    // A zero-share request: pushes a dead entry (RQ-7) without moving shares. Used in place of
    // the removed cancel wherever a hole in the queue is needed.
    function _ghost(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.requestRedeem(0, who);
    }

    // The removed `cancelRedeemRequest(uint256,address)` selector.
    bytes4 constant CANCEL_REDEEM_SELECTOR = bytes4(keccak256("cancelRedeemRequest(uint256,address)"));

    function _tryCancel(address who, uint256 id, address to) internal returns (bool ok) {
        vm.prank(who);
        (ok, ) = address(vault).call(abi.encodeWithSelector(CANCEL_REDEEM_SELECTOR, id, to));
    }

    /**********************************************************************************************/
    /*** 1. Batch fills over-burn spUSDC (ceil per fill, budget computed once)                  ***/
    /**********************************************************************************************/

    // BUG (C-1, re-confirmed on refactor/more-simplifying): `_processPendingRedeems` sizes the share
    // budget once from `spUSDC.maxWithdraw(vault)` (src/SparkPrimeVault.sol:903) but each fill calls
    // `spUSDC.withdraw(assets_)` (:922 via `_withdrawSavings` :952/:955), which burns ceil(assets * RAY / chi_s) spUSDC. Across
    // N fills the burned total can exceed the vault's spUSDC balance by up to N-1 wei, so the last
    // fill reverts inside spUSDC with "SparkVault/insufficient-balance" and the batch rolls back.
    //
    // Scenario (vault-share bound): the vault holds S = 1_002_833 spUSDC, worth
    // A = 1_050_601 USDC; rem = 1_040_520 shares. Two queued requests of 520_260 shares each
    // are paid 525_300 USDC each (sum 1_050_600 <= A) but burn 501_417 + 501_417 = 1_002_834
    // spUSDC, one more than the vault holds.
    function test_BUG_processPendingRedeems_batchRevertsOnCeilRounding_vaultSharesBound() public {
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
        vault.processPendingRedeems(type(uint256).max, 2);

        // Nothing moved.
        assertEq(usdc.balanceOf(alice),       0);
        assertEq(usdc.balanceOf(bob),         0);
        assertEq(vault.pendingRedeemShares(), 1_040_520);
        assertEq(vault.firstPendingRedeemId(),          0);
        assertEq(_vaultSpUsdc(),              1_002_833);

        // Workaround: one request per call re-reads maxWithdraw and is always safe (single-fill
        // bound, see testFuzz_processPendingRedeems_singleFillNeverReverts).
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
    function test_BUG_processPendingRedeems_batchRevertsOnCeilRounding_liquidityBound() public {
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
        vault.processPendingRedeems(type(uint256).max, 3);

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
    function testFuzz_processPendingRedeems_singleFillNeverReverts(
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
    function testFuzz_processPendingRedeems_batchOverburnBoundedByFillsMinusOne(
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
        try vault.processPendingRedeems(type(uint256).max, n) {
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
    function test_processPendingRedeems_partialFill_spUsdcLiquidityBound() public {
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
    function test_processPendingRedeems_partialFill_vaultSharesBound() public {
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
    /*** 3. FIFO, dead entries, maxRequests_, maxShares_                                        ***/
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

    // The only dead entries left in the redeem queue are zero-share ghosts (RQ-7) and fully
    // filled slots; both are `continue`d (src/SparkPrimeVault.sol:911).
    function test_processPendingRedeems_fifo_skipsGhosts() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _deposit(carol, 100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idB = _ghost(bob);
        uint256 idC = _requestRedeem(carol, DEPOSIT_100K_SHARES);
        assertEq(idA, 0);
        assertEq(idB, 1);
        assertEq(idC, 2);

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

    function test_processPendingRedeems_maxRequests() public {
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

    function test_processPendingRedeems_maxShares() public {
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

    function test_processPendingRedeems_maxSharesZero_noop() public {
        _threeDepositorsQueued();
        uint256 spBefore = _vaultSpUsdc();

        _processRedeems(0, 10);

        assertEq(vault.firstPendingRedeemId(),          0);
        assertEq(vault.pendingRedeemShares(), 3 * DEPOSIT_100K_SHARES);
        assertEq(_vaultSpUsdc(),              spBefore);
        assertEq(usdc.balanceOf(alice),       0);
    }

    function test_processPendingRedeems_emptyQueue_noop() public {
        _deposit(alice, 100_000e6);
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(),          0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(_vaultSpUsdc(),              DEPOSIT_100K_SPUSDC);
    }

    // A big head request blocks a small later one even when the small one would fit.
    function test_processPendingRedeems_headBlocksLaterSmallerRequests() public {
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
    function test_processPendingRedeems_primeYieldAccruesWhileQueued() public {
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
    function test_processPendingRedeems_spUsdcYieldStaysInVault() public {
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

        // The burned wei is gone: there is no cancel, and the dead entry rejects the only updater.
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateRedeemRecipient(id, alice);

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

    // BUG (V2-13, still open on 0ebb452): `requestRedeem` / `updateRedeemRecipient` only
    // blacklist-check the recipient (:452, :508), so `address(vault)` is accepted. The vault is
    // not blacklisted, so `_withdrawSavings` takes the direct branch (:952) and spUSDC pays the
    // USDC to the vault with NO `claimableAssets` credit: the USDC is stranded next to the
    // claimable pool, and `claim(vault)` has nothing to pay. Low: self-inflicted, but it is one
    // address check away from the blacklist fallback that would have made it claimable.
    function test_BUG_processPendingRedeems_recipientIsVault_usdcStranded_V2_13() public {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeemTo(alice, DEPOSIT_100K_SHARES, address(vault));

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(address(vault)), 99_999_999_998);
        assertEq(vault.claimableAssets(address(vault)), 0);  // no credit, unlike the blacklist path
        assertEq(vault.claimableAssets(alice),          0);
        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(address(vault));
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

    // BUG (V2-13, spUSDC variant): recipient == spUSDC is accepted too; spUSDC transfers the
    // USDC to itself, so the vault's spUSDC is burned and the value is donated to spUSDC holders.
    function test_BUG_processPendingRedeems_recipientIsSpUsdc_donatesToSpUsdc_V2_13() public {
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
        vm.expectRevert("SparkPrimeVault/zero-recipient");
        vault.requestRedeem(1, address(0));
    }

    /**********************************************************************************************/
    /*** 7. Pause + take                                                                        ***/
    /**********************************************************************************************/

    function test_processPendingRedeems_pausedBlocksRedeemsNotTake() public {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        _pause();

        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processPendingRedeems(type(uint256).max, 10);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestRedeem(1, alice);

        // `updateRedeemRecipient` (src/SparkPrimeVault.sol:506-516) is not pause-gated: the
        // owner can still repoint during a pause.
        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);
        (, address r, ) = _redeemRequest(id);
        assertEq(r, bob);
        vm.prank(alice);
        vault.updateRedeemRecipient(id, alice);

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

    function testFuzz_processPendingRedeems_singleFillRoundingBounds(
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

    function test_processPendingRedeems_200UsersIn4BatchesOf50() public {
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

    function test_processPendingRedeems_zeroLiquidity_noop() public {
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

    function test_processPendingRedeems_afterFullTake_noop() public {
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

    // BUG (Low, RQ-7): the `shares_ != 0` check is gone (src/SparkPrimeVault.sol:453 only requires
    // `shares_ >= minRedeem`). With `minRedeem == 0` (the initial value) `requestRedeem(0)` succeeds,
    // moves nothing, burns no fee and pushes a 0-share ghost entry that rejects the updater and
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
        vault.updateRedeemRecipient(ghost, alice);

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

    // `minRedeem` is denominated in SHARES (src/SparkPrimeVault.sol:207, 453): minRedeem - 1
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

    // Dead entries (RQ-7 ghosts, F-5 fee ghosts) are skipped but still consume `maxRequests_`
    // (src/SparkPrimeVault.sol:906 sizes `end_` by index, :911 `continue`s past them). Since
    // bf93b0d nothing walks the redeem head (on 0ebb452 no queue walks outside `_processPending*`), so a ghost AT the head also costs a slot: the
    // round-3 "head cancel is free" contrast is gone with the cancel.
    function test_processPendingRedeems_ghostEntryCountsTowardMaxRequests() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _deposit(carol, 100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idB = _ghost(bob);  // non-head hole at index 1
        uint256 idC = _requestRedeem(carol, DEPOSIT_100K_SHARES);

        assertEq(vault.balanceOf(bob),            DEPOSIT_100K_SHARES);
        assertEq(vault.balanceOf(address(vault)), 2 * DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(),     2 * DEPOSIT_100K_SHARES);
        assertEq(_queued(idB),                    0);
        assertEq(vault.firstPendingRedeemId(),    0);

        _processRedeems(type(uint256).max, 2);  // slot 1: alice, slot 2: the hole

        assertEq(usdc.balanceOf(alice), 99_999_999_998);
        assertEq(usdc.balanceOf(carol), 0);
        assertEq(_queued(idA),          0);
        assertEq(vault.firstPendingRedeemId(), 2);

        _processRedeems(type(uint256).max, 1);  // fills carol

        assertEq(usdc.balanceOf(carol), 99_999_999_998);
        assertEq(_queued(idC),          0);
        assertEq(vault.firstPendingRedeemId(), 3);

        // Ghosts at the head cost a slot each: two ghosts then bob; (max, 2) pays nobody.
        _ghost(carol);
        _ghost(carol);
        uint256 idB2 = _requestRedeem(bob, DEPOSIT_100K_SHARES);
        assertEq(idB2, 5);
        assertEq(vault.firstPendingRedeemId(), 3);

        _processRedeems(type(uint256).max, 2);
        assertEq(usdc.balanceOf(bob),          0);
        assertEq(vault.firstPendingRedeemId(), 5);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),          99_999_999_998);
        assertEq(vault.firstPendingRedeemId(), 6);
    }

    /**********************************************************************************************/
    /*** 11. Invariant-style fuzz                                                               ***/
    /**********************************************************************************************/

    // Random sequence of deposits, requests (own and third-party recipient), ghosts, owner
    // repoints (strangers and dead entries assert the revert), calls to the removed cancel
    // selector (must fail and move nothing), drains, takes and partial processing.
    // After every step: balanceOf(vault) == pendingRedeemShares == sum of open request shares,
    // every entry before the head is settled or a ghost, and shares only ever leave escrow
    // through a fill (the escrow is monotone outside of `processPendingRedeems`).
    function testFuzz_processPendingRedeems_balanceOfVaultEqualsPendingRedeemShares(uint256 seed)
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
                // Request to a third-party recipient, then prove the escrow cannot be undone:
                // the removed selector fails and the escrow is unchanged.
                uint256 bal = vault.balanceOf(u);
                if (bal != 0) {
                    uint256 id = _requestRedeemTo(u, bound(amt, 1, bal), users[(r >> 72) % 3]);
                    uint256 escrow = vault.balanceOf(address(vault));
                    assertFalse(_tryCancel(u, id, u));
                    assertFalse(_tryCancel(guardian, id, u));
                    assertEq(vault.balanceOf(address(vault)), escrow);
                }
            } else if (action == 3) {
                uint256 escrowBefore = vault.balanceOf(address(vault));
                uint256 maxShares = (r >> 40) % 2 == 0 ? type(uint256).max : amt;
                vm.prank(rebalancer);
                try vault.processPendingRedeems(maxShares, (r >> 48) % 4) {}
                catch Error(string memory reason) {
                    assertEq(reason, "SparkVault/insufficient-balance");  // known over-burn (C-1)
                }
                assertLe(vault.balanceOf(address(vault)), escrowBefore);  // fills only shrink it
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
    function testFuzz_processPendingRedeems_neverPaysMoreThanSharesTimesChi(uint256 seed) public {
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
        try vault.processPendingRedeems(maxShares, maxReq) {}
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
    /*** 12. Finality: a redeem request cannot be undone (cancelRedeemRequest removed)           ***/
    /**********************************************************************************************/

    // The selector is gone from the ABI: the proxy forwards to an implementation with no
    // matching function and the call fails for the owner, the guardian and the admin. On
    // 0ebb452 the dead `CancelRedeemRequest` event declaration is gone too; a full request /
    // repoint / fill lifecycle emits no log with its topic.
    function test_cancelRedeemRequest_selectorRemovedAndEventDead() public {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        vm.recordLogs();

        assertFalse(_tryCancel(alice,    id, alice));
        assertFalse(_tryCancel(guardian, id, alice));
        assertFalse(_tryCancel(admin,    id, alice));

        assertEq(vault.balanceOf(address(vault)), DEPOSIT_100K_SHARES);
        assertEq(vault.balanceOf(alice),          0);
        assertEq(_queued(id),                     DEPOSIT_100K_SHARES);

        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob), 99_999_999_998);

        bytes32 cancelTopic = keccak256("CancelRedeemRequest(uint256,uint256)");
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) assertTrue(logs[i].topics[0] != cancelTopic);
    }

    // Design property (closes E-2 "free option" and C-10 "free capacity hog"): once queued, the
    // shares sit at `address(vault)` and nothing but a fill moves them. The owner has no
    // function, no allowance and no signature that reaches them; the guardian and the admin
    // have none either; pause does not release them; time does not release them. Exits are
    // 100% planner-dependent.
    function test_requestRedeem_isFinal_noPathRecoversEscrow() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        assertEq(vault.balanceOf(address(vault)), DEPOSIT_100K_SHARES);
        assertEq(vault.balanceOf(alice),          0);

        // ERC20 paths: the vault never approves anyone, and nobody can sign for it.
        assertEq(vault.allowance(address(vault), alice), 0);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/insufficient-allowance");
        vault.transferFrom(address(vault), alice, 1);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/insufficient-allowance");
        vault.transferFrom(address(vault), alice, DEPOSIT_100K_SHARES);

        // permit(owner = vault): ecrecover cannot yield the proxy address and the proxy has no
        // `isValidSignature`, so the ERC-1271 staticcall fails -> `invalid-permit`.
        (uint8 v, bytes32 r_, bytes32 s) = vm.sign(1, keccak256("anything"));
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(address(vault), alice, type(uint256).max, block.timestamp + 1, v, r_, s);
        assertEq(vault.allowance(address(vault), alice), 0);

        // The updater moves the recipient, never the shares.
        vm.prank(alice);
        vault.updateRedeemRecipient(id, alice);
        assertEq(vault.balanceOf(address(vault)), DEPOSIT_100K_SHARES);

        // Roles: no function on the vault moves escrowed shares. `take` moves spUSDC only.
        _takeAll();
        assertEq(vault.balanceOf(address(vault)), DEPOSIT_100K_SHARES);
        _returnToVault(2 * DEPOSIT_100K_SPUSDC);
        _pause();
        assertEq(vault.balanceOf(address(vault)), DEPOSIT_100K_SHARES);
        _unpause();

        // Time: a year without a planner call leaves the escrow in place (and accruing).
        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);
        assertEq(vault.balanceOf(address(vault)),            DEPOSIT_100K_SHARES);
        assertEq(_queued(id),                                DEPOSIT_100K_SHARES);
        assertEq(vault.convertToAssets(DEPOSIT_100K_SHARES), 104_999_999_998);
        assertEq(usdc.balanceOf(alice),                      0);

        // Only the planner releases it, and it pays floor(shares * chi / RAY) at fill time.
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice),           104_999_999_998);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(_queued(id),                     0);
    }

    // E-2 closed: the request is a commitment on the downside too. A loss realised after the
    // request (`adjustTotalAssets`, :278-295) is taken by the escrow and the owner cannot step
    // out of the queue to avoid it.
    function test_requestRedeem_isFinal_cannotStepOutOfARealizedLoss() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        _adjustTotalAssetsWhilePaused(-10_000e6);

        assertFalse(_tryCancel(alice, id, alice));
        assertEq(vault.balanceOf(alice),          0);
        assertEq(vault.balanceOf(address(vault)), DEPOSIT_100K_SHARES);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 94_999_999_998);  // same as section 15, no way around it
    }

    // C-10 closed: escrowed shares stay in `totalSupply` (src/SparkPrimeVault.sol:457 transfers,
    // :462 burns only the fee), so a redeem request keeps the capacity it occupies until the
    // fill burns it (:920). The owner cannot release it, so queueing a redeem costs the exit
    // itself: no free hold on capacity.
    function test_requestRedeem_capacityStaysOccupiedUntilFill() public {
        _deposit(alice, 100_000e6);
        _setCapacity(vault.totalSupply());
        assertEq(vault.availableCapacity(), 0);

        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        assertEq(vault.totalSupply(),       DEPOSIT_100K_SHARES);
        assertEq(vault.availableCapacity(), 0);

        // bob is queued behind the occupied capacity.
        uint256 did = _deposit(bob, 100_000e6);
        assertEq(vault.balanceOf(bob), 0);
        (, , uint256 bobQueued) = _depositRequest(did);
        assertEq(bobQueued, DEPOSIT_100K_SPUSDC);

        // alice cannot give the capacity back without exiting.
        assertFalse(_tryCancel(alice, id, alice));
        assertEq(vault.availableCapacity(), 0);

        // The fill burns the escrow and frees the capacity for bob.
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice),     99_999_999_998);
        assertEq(vault.totalSupply(),       0);
        assertEq(vault.availableCapacity(), DEPOSIT_100K_SHARES);

        _processDeposits(type(uint256).max, 1);
        // The capacity round-trip (shares -> USDC -> spUSDC, two floors) admits 2 spUSDC wei
        // less than bob's request; the 2 wei stay queued (deposit-side rounding, not this area).
        assertEq(vault.balanceOf(bob), 99_040_518_408);
        (, , uint256 bobLeft) = _depositRequest(did);
        assertEq(bobLeft, 2);
    }

    // Partial fill (liquidity bound) leaves the entry at the head with owner, recipient and the
    // remainder; the remainder cannot be withdrawn from the queue. The owner can still repoint
    // the remainder mid-fill: the part already paid stays with the old recipient, the rest goes
    // to the new one, and the two parts sum to one full fill to the wei.
    function test_requestRedeem_afterPartialFill_remainderStaysQueued_repointMidFill() public {
        _deposit(alice, 1_000_000e6);
        _deposit(carol, 100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_1M_SHARES);  // 0
        _ghost(bob);                                              // 1
        uint256 idC = _requestRedeem(carol, DEPOSIT_100K_SHARES); // 2
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 300_000e6);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),        299_999_999_999);
        assertEq(_queued(idA),                 693_283_628_876);
        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(vault.pendingRedeemShares(),  693_283_628_876 + DEPOSIT_100K_SHARES);

        (address o, address r, ) = _redeemRequest(idA);
        assertEq(o, alice);
        assertEq(r, alice);

        // No way out for the remainder.
        assertFalse(_tryCancel(alice, idA, alice));
        assertEq(vault.balanceOf(alice),          0);
        assertEq(vault.balanceOf(address(vault)), 693_283_628_876 + DEPOSIT_100K_SHARES);

        // Repoint the live head mid-fill.
        vm.expectEmit(true, true, true, true, address(vault));
        emit RedeemRecipientUpdated(idA, bob);
        vm.prank(alice);
        vault.updateRedeemRecipient(idA, bob);

        _returnSpUsdcLiquidity(800_000e6);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(alice, bob, 693_283_628_876, 668_172_883_799, 699_999_999_998);
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(bob),          699_999_999_998);
        assertEq(usdc.balanceOf(alice),        299_999_999_999);
        assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob), 999_999_999_997);
        assertEq(_queued(idA),                 0);
        assertEq(vault.firstPendingRedeemId(), 1);  // the ghost at 1 is not walked

        _processRedeems(type(uint256).max, 2);  // slot for the ghost, slot for carol
        assertEq(usdc.balanceOf(carol),        99_999_999_998);
        assertEq(_queued(idC),                 0);
        assertEq(vault.firstPendingRedeemId(), 3);
    }

    // Same partial / resume shape across many small planner calls (`maxShares_` chunks). Each
    // piece pays floor(piece * chi_p / RAY) and burns ceil(paid * RAY / chi_s) spUSDC, so the sum
    // of the pieces never exceeds the single-fill floor, loses at most one wei per call, and the
    // per-piece ceil burns (RQ-1 shape) eat the backing of the last shares: after 13 chunks the
    // vault's spUSDC is worth 0 shares and the final 2 shares stay queued with nothing behind
    // them until new backing arrives. One fill would have left 1 wei of spUSDC instead.
    function test_processPendingRedeems_manyPartialFills_sumNeverExceedsOneFill() public {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        uint256 piece = 7_777_777_777;  // shares per call, not a divisor of the request
        for (uint256 calls; calls < 13; ++calls) {
            assertEq(_queued(id), DEPOSIT_100K_SHARES - calls * piece);
            _processRedeems(piece, 1);
        }

        uint256 oneFill = DEPOSIT_100K_SHARES * CHI_P / RAY;
        assertEq(oneFill, 99_999_999_998);
        assertLe(usdc.balanceOf(alice), oneFill);
        assertGe(usdc.balanceOf(alice), oneFill - 13);
        assertEq(usdc.balanceOf(alice), 99_999_999_990);  // 6 wei of floors, 2 shares (2 wei) unpaid

        // Stranded: 2 shares queued, the spUSDC left converts to 0 shares, calls are no-ops.
        assertEq(_queued(id),                   2);
        assertEq(vault.firstPendingRedeemId(),  0);
        assertEq(_vaultSpUsdc(),                1);
        assertEq(vault.availableLiquidAssets(), 1);
        assertEq(vault.convertToShares(1),      0);
        _processRedeems(type(uint256).max, 1);
        assertEq(_queued(id), 2);

        // New backing completes it.
        _returnToVault(2);
        _processRedeems(type(uint256).max, 1);
        assertEq(_queued(id),                  0);
        assertEq(usdc.balanceOf(alice),        99_999_999_992);  // 2 shares -> 2 wei
        assertEq(vault.firstPendingRedeemId(), 1);
    }

    // A fully filled entry is `delete`d (src/SparkPrimeVault.sol:928): the getter returns zeros,
    // a partial fill keeps owner and recipient.
    function test_processPendingRedeems_fullFillDeletesEntry() public {
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

        // The deleted entry is dead for the updater; the slot still exists in the array.
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateRedeemRecipient(idA, alice);
        assertEq(_queueLength(), 2);
    }

    // Event on 0ebb452 (src/SparkPrimeVault.sol:115-121, emitted :924):
    // Redeem(owner, recipient, sharesBurned, savingsSharesBurned, assetsReceived).
    function test_processPendingRedeems_emitsRedeemSharesThenAssets() public {
        _deposit(alice, 100_000e6);
        _requestRedeemTo(alice, DEPOSIT_100K_SHARES, bob);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(alice, bob, DEPOSIT_100K_SHARES, 95_453_269_113, 99_999_999_998);
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
        vm.expectRevert("SparkPrimeVault/zero-recipient");
        vault.updateRedeemRecipient(id, address(0));

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),   99_999_999_998);
        assertEq(usdc.balanceOf(alice), 0);
    }

    // Repointing a dead (filled or ghost) entry reverts `no-request` (src/SparkPrimeVault.sol:512)
    // for everyone, the former owner included; an index past the array reverts with an
    // out-of-bounds panic.
    function test_updateRedeemRecipient_deadEntryAndOutOfRange() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 filled = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 ghost  = _ghost(bob);
        _processRedeems(type(uint256).max, 1);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateRedeemRecipient(filled, carol);

        vm.prank(carol);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateRedeemRecipient(filled, carol);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateRedeemRecipient(ghost, carol);

        (address o, address r, uint256 sh) = _redeemRequest(filled);
        assertEq(o,  address(0));
        assertEq(r,  address(0));
        assertEq(sh, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x32));
        vault.updateRedeemRecipient(ghost + 1, carol);

        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(carol), 0);
        assertEq(vault.firstPendingRedeemId(), 2);
    }

    /**********************************************************************************************/
    /*** 14. Blacklist handling (R4-A / RQ-10 fixed on 0ebb452)                                 ***/
    /**********************************************************************************************/

    // FIXED (was RQ-10 High): `requestRedeem` (src/SparkPrimeVault.sol:452) and
    // `updateRedeemRecipient` (:508) require `_canReceiveAsset(recipient_)` (:1051-1053), so a
    // request can no longer be aimed at a blacklisted address, not even a 0-share ghost.
    function test_fixed_requestRedeem_rejectsBlacklistedRecipient() public {
        address attacker    = makeAddr("attacker");
        address blacklisted = makeAddr("blacklisted");
        _blacklist(blacklisted);

        _deposit(attacker, 1e6);
        assertEq(vault.balanceOf(attacker), 990_404);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestRedeem(1, blacklisted);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestRedeem(0, blacklisted);  // no ghost either

        uint256 id = _requestRedeem(attacker, 1);
        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.updateRedeemRecipient(id, blacklisted);

        (, address r, uint256 sh) = _redeemRequest(id);
        assertEq(r,  attacker);
        assertEq(sh, 1);
        assertEq(_queueLength(),              1);
        assertEq(vault.balanceOf(attacker),   990_403);
        assertEq(vault.pendingRedeemShares(), 1);

        // The zero-recipient check comes first, the blacklist check second, minimum third.
        _setMinRedeem(2);
        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/zero-recipient");
        vault.requestRedeem(1, address(0));
        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestRedeem(1, blacklisted);
        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(1, attacker);
    }

    // FIXED (R4-A): a recipient blacklisted AFTER queueing no longer jams the queue. The fill
    // burns the shares (:920), withdraws the USDC to the vault itself (:955) and credits
    // `claimableAssets[recipient]` (:1044-1048); the queue moves on and bob behind is paid.
    // `claim` (:524-534) reverts in USDC while the recipient is still blacklisted and pays the
    // exact credit once un-blacklisted, callable by anyone.
    function test_fixed_blacklistedAfterRequest_queueKeepsMoving_claimableExact() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idB = _requestRedeem(bob,   DEPOSIT_100K_SHARES);

        _blacklist(alice);

        assertEq(vault.claimableAssets(alice),    0);
        assertEq(usdc.balanceOf(address(vault)),  0);
        assertEq(_vaultSpUsdc(),                  2 * DEPOSIT_100K_SPUSDC);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ClaimableAssetsIncreased(alice, 99_999_999_998);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(alice, alice, DEPOSIT_100K_SHARES, 95_453_269_113, 99_999_999_998);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(bob, bob, DEPOSIT_100K_SHARES, 95_453_269_113, 99_999_999_998);
        _processRedeems(type(uint256).max, 10);

        // Alice's payout sits in the vault as USDC, credited to her; bob paid directly.
        assertEq(vault.claimableAssets(alice),    99_999_999_998);
        assertEq(usdc.balanceOf(address(vault)),  99_999_999_998);
        assertEq(usdc.balanceOf(alice),           0);
        assertEq(usdc.balanceOf(bob),             99_999_999_998);
        assertEq(_queued(idA),                    0);
        assertEq(_queued(idB),                    0);
        assertEq(vault.firstPendingRedeemId(),    2);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(),             0);
        assertEq(_vaultSpUsdc(),                  2);  // two ceil-burn wei left
        assertEq(vault.availableLiquidAssets(),   2);  // the parked USDC is not vault backing
        assertEq(vault.totalAssets(),             0);  // nor is it counted as assets

        // Still blacklisted: `claim` reverts inside USDC, the credit is intact.
        vm.expectRevert(BLACKLISTED);
        vault.claim(alice);
        assertEq(vault.claimableAssets(alice), 99_999_999_998);

        // Nothing to claim for anyone else.
        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(bob);
        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(address(vault));

        _unblacklist(alice);

        // Permissionless: carol triggers it, alice is paid the exact credit.
        vm.expectEmit(true, true, true, true, address(vault));
        emit Claim(alice, 99_999_999_998);
        vm.prank(carol);
        uint256 claimed = vault.claim(alice);

        assertEq(claimed,                         99_999_999_998);
        assertEq(usdc.balanceOf(alice),           99_999_999_998);
        assertEq(usdc.balanceOf(carol),           0);
        assertEq(usdc.balanceOf(address(vault)),  0);
        assertEq(vault.claimableAssets(alice),    0);

        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(alice);
    }

    // FIXED (round-4 latent jam): a blacklisted recipient in the middle of a batch no longer
    // rolls the batch back; (max, 10) pays everyone in one transaction.
    function test_fixed_blacklistedRecipient_midBatch_noRollback() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _deposit(carol, 100_000e6);
        _requestRedeem(alice, DEPOSIT_100K_SHARES);  // 0
        _requestRedeem(bob,   DEPOSIT_100K_SHARES);  // 1
        _requestRedeem(carol, DEPOSIT_100K_SHARES);  // 2
        _blacklist(bob);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),          99_999_999_998);
        assertEq(usdc.balanceOf(bob),            0);
        assertEq(vault.claimableAssets(bob),     99_999_999_998);
        assertEq(usdc.balanceOf(carol),          99_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), 99_999_999_998);
        assertEq(vault.firstPendingRedeemId(),   3);
        assertEq(vault.pendingRedeemShares(),    0);
        assertEq(_vaultSpUsdc(),                 3);
    }

    // Credits accumulate (`+=` at :1045): two entries of alice's, chunked into three partial
    // fills, plus a third-party entry paid to carol, both blacklisted. The vault's USDC equals
    // the sum of credits at every step and each claim pays its exact total.
    function test_fixed_blacklistedRecipients_accumulateAcrossPartialFillsAndEntries() public {
        _deposit(alice, 100_000e6);
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _requestRedeem(alice, DEPOSIT_100K_SHARES);                   // 0
        _requestRedeem(alice, DEPOSIT_100K_SHARES);                   // 1
        _requestRedeemTo(bob, DEPOSIT_100K_SHARES, carol);            // 2
        _blacklist(alice);
        _blacklist(carol);

        // Chunk 1: 50_000_000_000 shares of entry 0.
        _processRedeems(50_000_000_000, 10);
        assertEq(vault.claimableAssets(alice),   50_484_388_412);
        assertEq(usdc.balanceOf(address(vault)), 50_484_388_412);
        assertEq(_vaultSpUsdc(),                 3 * DEPOSIT_100K_SPUSDC - 48_188_999_132);
        assertEq(vault.firstPendingRedeemId(),   0);

        // Chunk 2: the rest of entry 0 (49_040_518_410 shares) plus entry 1 and entry 2.
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.claimableAssets(alice),   50_484_388_412 + 49_515_611_586 + 99_999_999_998);
        assertEq(vault.claimableAssets(alice),   199_999_999_996);
        assertEq(vault.claimableAssets(carol),   99_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), 199_999_999_996 + 99_999_999_998);
        assertEq(_vaultSpUsdc(),                 3);
        assertEq(vault.firstPendingRedeemId(),   3);
        assertEq(vault.pendingRedeemShares(),    0);
        assertEq(vault.totalSupply(),            0);

        // Here the two chunks of entry 0 happen to sum to exactly one fill (no floor loss).
        assertEq(uint256(50_484_388_412 + 49_515_611_586), 99_999_999_998);

        _unblacklist(alice);
        vault.claim(alice);
        assertEq(usdc.balanceOf(alice),          199_999_999_996);
        assertEq(usdc.balanceOf(address(vault)), 99_999_999_998);
        assertEq(vault.claimableAssets(carol),   99_999_999_998);  // untouched by alice's claim

        _unblacklist(carol);
        vault.claim(carol);
        assertEq(usdc.balanceOf(carol),          99_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // A blacklisted recipient's fill is still bounded by the same single-fill math: the
    // fallback `withdraw(assets_, vault, vault)` (:955) burns the same ceil amount as a direct
    // payout, under random indexes, liquidity and take().
    function testFuzz_processPendingRedeems_blacklistFallback_sameMathAsDirectPayout(
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
        _blacklist(alice);

        drain = bound(drain, 0, usdc.balanceOf(address(spUsdc)));
        take_ = bound(take_, 0, _vaultSpUsdc());
        _drainSpUsdcLiquidity(drain);
        _take(take_);

        uint256 spUsdcBefore = _vaultSpUsdc();
        uint256 liqBefore    = usdc.balanceOf(address(spUsdc));
        uint256 rem          = vault.convertToShares(vault.availableLiquidAssets());
        uint256 fill         = rem < shares ? rem : shares;
        (uint256 assets, uint256 burned) = _fillMath(fill);

        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice),           0);
        assertEq(vault.claimableAssets(alice),    assets);
        assertEq(usdc.balanceOf(address(vault)),  assets);
        assertEq(_vaultSpUsdc(),                  spUsdcBefore - burned);
        assertEq(usdc.balanceOf(address(spUsdc)), liqBefore - assets);
        assertEq(vault.pendingRedeemShares(),     shares - fill);

        if (assets != 0) {
            _unblacklist(alice);
            assertEq(vault.claim(alice), assets);
            assertEq(usdc.balanceOf(alice), assets);
            assertEq(usdc.balanceOf(address(vault)), 0);
        }
    }

    // The parked USDC is inert: `adjustTotalAssets` reprices shares, not credits; `take` moves
    // spUSDC only; `requestDeposit` pulls and deposits the same amount; `claim` works while
    // paused. A 99% loss after the credit leaves the credit at 99_999_999_998 to the wei.
    function test_fixed_claimableAssets_unaffectedByAdjustTotalAssetsTakeDepositsAndPause() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _blacklist(alice);
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.claimableAssets(alice),   99_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), 99_999_999_998);
        assertEq(vault.totalAssets(),            99_999_999_998);  // bob only

        _pause();
        _adjustTotalAssets(-99_000_000_000);
        assertEq(vault.totalAssets(),            999_999_997);
        assertEq(vault.assetsOf(bob),            999_999_997);
        assertEq(vault.claimableAssets(alice),   99_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), 99_999_999_998);

        // `take` during the pause empties the spUSDC, not the USDC.
        _takeAll();
        assertEq(_vaultSpUsdc(),                 0);
        assertEq(usdc.balanceOf(address(vault)), 99_999_999_998);
        _unpause();

        // A deposit passes through the vault's USDC balance without touching the credit.
        _deposit(carol, 100_000e6);
        assertEq(usdc.balanceOf(address(vault)), 99_999_999_998);
        assertEq(vault.claimableAssets(alice),   99_999_999_998);

        _pause();
        _unblacklist(alice);
        assertEq(vault.claim(alice), 99_999_999_998);  // not pause-gated
        assertEq(usdc.balanceOf(alice),          99_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // The owner is never blacklist-checked: a blacklisted owner can still repoint a live entry
    // to a clean address and get paid directly, or leave it and be credited. Repointing to a
    // blacklisted address is rejected; repointing a partially filled head mid-fill after the
    // first chunk was credited pays the rest directly to the new recipient.
    function test_updateRedeemRecipient_blacklistedOwnerRepoints_mixedCreditAndDirectPayout() public {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _blacklist(alice);

        _processRedeems(50_000_000_000, 1);  // first chunk credited to alice
        assertEq(vault.claimableAssets(alice), 50_484_388_412);
        assertEq(_queued(id),                  49_040_518_410);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.updateRedeemRecipient(id, alice);  // herself, still blacklisted

        vm.expectEmit(true, true, true, true, address(vault));
        emit RedeemRecipientUpdated(id, bob);
        vm.prank(alice);  // blacklisted owner, allowed
        vault.updateRedeemRecipient(id, bob);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(alice, bob, 49_040_518_410, 47_264_269_981, 49_515_611_586);
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(bob),            49_515_611_586);
        assertEq(vault.claimableAssets(alice),   50_484_388_412);
        assertEq(vault.claimableAssets(bob),     0);
        assertEq(usdc.balanceOf(address(vault)), 50_484_388_412);
        assertEq(_queued(id),                    0);
        assertEq(vault.firstPendingRedeemId(),   1);
        assertEq(uint256(50_484_388_412 + 49_515_611_586), 99_999_999_998);
    }

    // Un-blacklisted before the fill: no credit, paid directly, `claim` has nothing.
    function test_fixed_blacklistedThenUnblacklistedBeforeFill_paidDirectly() public {
        _deposit(alice, 100_000e6);
        _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _blacklist(alice);
        _unblacklist(alice);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),          99_999_999_998);
        assertEq(vault.claimableAssets(alice),   0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(alice);
    }

    // If the VAULT itself is blacklisted, direct payouts still work (USDC moves spUSDC ->
    // recipient, the vault is not a party), but the fallback (`withdraw` to the vault, :955)
    // reverts in USDC, so a blacklisted recipient at the head is a jam again until the owner
    // repoints. Deposits are dead too (`safeTransferFrom` to the vault, :400). Info: requires
    // Circle to blacklist the vault, at which point the product is over anyway.
    function test_processPendingRedeems_vaultBlacklisted_directPayoutWorks_fallbackJams() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _requestRedeem(bob, DEPOSIT_100K_SHARES);
        _blacklist(address(vault));

        vm.prank(carol);
        vm.expectRevert(BLACKLISTED);
        vault.requestDeposit(1, carol, 0);

        _processRedeems(type(uint256).max, 1);  // alice paid directly
        assertEq(usdc.balanceOf(alice),        99_999_999_998);
        assertEq(vault.firstPendingRedeemId(), 1);

        _blacklist(bob);
        vm.prank(rebalancer);
        vm.expectRevert(BLACKLISTED);
        vault.processPendingRedeems(type(uint256).max, 1);
        assertEq(vault.firstPendingRedeemId(), 1);

        vm.prank(bob);
        vault.updateRedeemRecipient(1, carol);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(carol),        99_999_999_998);
        assertEq(vault.firstPendingRedeemId(), 2);
        assertEq(_queued(idA), 0);
    }

    // The removed round-4 jam, step by step on 0ebb452: the honest victim variant. Alice is
    // blacklisted after queueing, bob behind her is paid on the first pass, no role is needed,
    // alice's credit waits for her.
    function test_fixed_blacklistedOwnerNoLongerNeedsToSelfRescue() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idB = _requestRedeem(bob,   DEPOSIT_100K_SHARES);
        _blacklist(alice);

        _pause();
        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processPendingRedeems(type(uint256).max, 10);
        _unpause();

        _processRedeems(type(uint256).max, 1);
        assertEq(vault.claimableAssets(alice), 99_999_999_998);
        assertEq(usdc.balanceOf(bob),          0);
        assertEq(vault.firstPendingRedeemId(), 1);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),          99_999_999_998);
        assertEq(vault.firstPendingRedeemId(), 2);
        assertEq(_queued(idA), 0);
        assertEq(_queued(idB), 0);

        _warpAndDrip(365 days);
        _unblacklist(alice);
        assertEq(vault.claim(alice), 99_999_999_998);  // no yield on a USDC credit
    }

    // Random ops with blacklist toggles and claims: the vault's USDC balance equals the sum of
    // credits after every step; escrow == pendingRedeemShares; credits only ever grow outside
    // of `claim`; `claim` pays exactly the credit.
    function testFuzz_blacklistFallback_vaultUsdcEqualsSumOfClaimable(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        _setSpUsdcVsr(FOUR_PCT_VSR);
        _setPrimeVsr(ONE_PCT_VSR);
        _setRedeemFeeRate(0.001e18);

        for (uint256 step; step < 24; ++step) {
            uint256 r      = uint256(keccak256(abi.encode(seed, step)));
            address u      = users[r % 3];
            address to     = users[(r >> 72) % 3];
            uint256 action = (r >> 8) % 8;
            uint256 amt    = (r >> 16) % 1_000_000e6 + 1;

            if (action == 0) {
                if (!usdc.isBlacklisted(u)) _deposit(u, amt);
            } else if (action == 1) {
                uint256 bal = vault.balanceOf(u);
                if (bal != 0) {
                    bool toBlacklisted = usdc.isBlacklisted(to);
                    uint256 req = bound(amt, 1, bal);
                    vm.prank(u);
                    if (toBlacklisted) vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
                    vault.requestRedeem(req, to);
                }
            } else if (action == 2) {
                uint256[3] memory credit;
                for (uint256 i; i < 3; ++i) credit[i] = vault.claimableAssets(users[i]);
                vm.prank(rebalancer);
                try vault.processPendingRedeems((r >> 40) % 2 == 0 ? type(uint256).max : amt, (r >> 48) % 4) {}
                catch Error(string memory reason) {
                    assertEq(reason, "SparkVault/insufficient-balance");  // C-1
                }
                for (uint256 i; i < 3; ++i) {
                    assertGe(vault.claimableAssets(users[i]), credit[i]);
                    if (!usdc.isBlacklisted(users[i])) assertEq(vault.claimableAssets(users[i]), credit[i]);
                }
            } else if (action == 3) {
                usdc.setBlacklisted(u, !usdc.isBlacklisted(u));
            } else if (action == 4) {
                uint256 credit = vault.claimableAssets(u);
                uint256 before = usdc.balanceOf(u);
                if (credit == 0) {
                    vm.expectRevert("SparkPrimeVault/nothing-to-claim");
                    vault.claim(u);
                } else if (usdc.isBlacklisted(u)) {
                    vm.expectRevert(BLACKLISTED);
                    vault.claim(u);
                    assertEq(vault.claimableAssets(u), credit);
                } else {
                    assertEq(vault.claim(u), credit);
                    assertEq(usdc.balanceOf(u), before + credit);
                    assertEq(vault.claimableAssets(u), 0);
                }
            } else if (action == 5) {
                uint256 liq = usdc.balanceOf(address(spUsdc));
                if (liq != 0) _drainSpUsdcLiquidity(bound(amt, 1, liq));
            } else if (action == 6) {
                _returnSpUsdcLiquidity(amt);
            } else {
                uint256 held = _vaultSpUsdc();
                if (held != 0) _take(bound(amt, 1, held));
            }
            _warpAndDrip((r >> 64) % 7 days);

            uint256 credits;
            for (uint256 i; i < 3; ++i) credits += vault.claimableAssets(users[i]);
            assertEq(usdc.balanceOf(address(vault)), credits);
            assertEq(vault.balanceOf(address(vault)), vault.pendingRedeemShares());
        }
    }

    /**********************************************************************************************/
    /*** 15. adjustTotalAssets (loss) while queued                                               ***/
    /**********************************************************************************************/

    // `adjustTotalAssets` (src/SparkPrimeVault.sol:278-295, DEFAULT_ADMIN, paused only) sets
    // chi = floor((totalAssets + delta) * RAY / totalSupply) for everyone, escrowed shares
    // included: a queued redeemer is paid at the reduced chi and takes the loss pro rata.
    function test_processPendingRedeems_lossWhileQueued_escrowTakesLossProRata() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        assertEq(vault.convertToAssets(DEPOSIT_100K_SHARES), 99_999_999_998);
        assertEq(vault.totalAssets(),                        199_999_999_997);

        _pause();
        vm.expectEmit(true, true, true, true, address(vault));
        emit TotalAssetsAdjusted(uint192(0.959203379825079411152892409e27), -10_000e6);
        _adjustTotalAssets(-10_000e6);  // 5% of the book
        _unpause();

        // chi = floor((199_999_999_997 - 10_000e6) * RAY / 198_081_036_820)
        uint256 chiAfter = vault.nowChi();
        assertEq(chiAfter, (199_999_999_997 - 10_000e6) * RAY / (2 * DEPOSIT_100K_SHARES));
        assertEq(chiAfter, 0.959203379825079411152892409e27);
        assertEq(vault.totalAssets(), 189_999_999_996);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(alice, alice, DEPOSIT_100K_SHARES, 90_680_605_657, 94_999_999_998);
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

    // BUG (C-3, still open on 0ebb452): the only floor is `totalAssets_ > 0` (:286) and
    // `updatedChi_ != 0` (:291). `adjustTotalAssets(-(totalAssets - 1))` sets chi to
    // 5_048_438_841_264_340 (5.05e-12 of RAY). A queued redeemer with 99_040_518_410 shares
    // escrowed is then "filled" for 0 USDC: the shares are burned (:920), `withdraw(0)` burns 0
    // spUSDC and the entry is deleted (:928); the holder behind is worth 0 wei too. The full
    // backing (199_999_999_999 USDC of spUSDC) is left unassigned and `take` removes it all.
    function test_BUG_adjustTotalAssets_wipesQueuedRedeemer_C3() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        assertEq(vault.totalAssets(), 199_999_999_997);

        _pause();
        vm.expectEmit(true, true, true, true, address(vault));
        emit TotalAssetsAdjusted(uint192(5_048_438_841_264_340), -199_999_999_996);
        _adjustTotalAssets(-199_999_999_996);
        _unpause();

        assertEq(vault.nowChi(),                             5_048_438_841_264_340);
        assertEq(vault.totalAssets(),                        0);  // floor(198_081_036_820 * chi / RAY)
        assertEq(vault.convertToAssets(DEPOSIT_100K_SHARES), 0);
        assertEq(vault.assetsOf(bob),                        0);

        // Budget is huge (chi tiny), the fill pays 0 and burns the escrow.
        assertEq(vault.convertToShares(vault.availableLiquidAssets()), 39_616_207_363_801_924_236_374);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(alice, alice, DEPOSIT_100K_SHARES, 0, 0);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),           0);
        assertEq(_queued(id),                     0);
        assertEq(vault.firstPendingRedeemId(),    1);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(),             DEPOSIT_100K_SHARES);
        assertEq(_vaultSpUsdc(),                  2 * DEPOSIT_100K_SPUSDC);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 199_999_999_999);

        // Alice can never get back in line for the backing: her shares are gone.
        _takeAll();
        assertEq(spUsdc.balanceOf(taker), 2 * DEPOSIT_100K_SPUSDC);

        // A gain of the same size does not restore her: chi is recomputed on bob's supply only,
        // so bob now owns the whole book.
        _pause();
        _adjustTotalAssets(199_999_999_996);
        _unpause();
        assertEq(vault.assetsOf(bob),   199_999_999_995);
        assertEq(vault.balanceOf(alice), 0);
    }

    // Asymmetry: the redeem escrow is in spPRIME shares and takes the loss; a queued deposit is
    // in spUSDC shares and does not. After a 10% loss the capacity (in shares) shrinks in USD
    // terms, so the same queued spUSDC fills fewer USD of capacity and some of it stays queued.
    function test_adjustTotalAssets_queuedRedeemTakesLoss_queuedDepositDoesNot() public {
        _deposit(alice, 100_000e6);
        _setCapacity(DEPOSIT_100K_SHARES);
        uint256 idR = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idD = _deposit(bob, 100_000e6);  // queued: capacity is full
        (, , uint256 bobQueued) = _depositRequest(idD);
        assertEq(bobQueued,                  DEPOSIT_100K_SPUSDC);
        assertEq(vault.balanceOf(bob),       0);
        assertEq(vault.totalAssets(),        99_999_999_998);  // alice's escrow only

        _pause();
        _adjustTotalAssets(-10_000e6);
        _unpause();

        assertEq(vault.nowChi(), 908_718_991_407_387_565_591_802_519);

        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice),       89_999_999_997);  // alice bore the whole loss
        assertEq(_queued(idR),                0);
        assertEq(vault.totalSupply(),         0);
        assertEq(_vaultSpUsdc(),              2 * DEPOSIT_100K_SPUSDC - 85_907_942_201);

        // Capacity: 99_040_518_410 shares, now worth 89_999_999_997 USDC = 85_907_942_200 spUSDC.
        assertEq(vault.availableCapacity(), DEPOSIT_100K_SHARES);
        _processDeposits(type(uint256).max, 10);

        (, , uint256 bobLeft) = _depositRequest(idD);
        assertEq(vault.balanceOf(bob), 99_040_518_407);
        assertEq(vault.assetsOf(bob),  89_999_999_995);
        assertEq(bobLeft,              9_545_326_914);  // worth 10_000_000_002 USDC, still queued
        assertEq(spUsdc.convertToAssets(bobLeft), 10_000_000_002);

        // bob's queued spUSDC did not lose anything; without the loss he would have been filled
        // in full (99_040_518_410 shares for 99_999_999_999 USDC).
        assertEq(spUsdc.convertToAssets(DEPOSIT_100K_SPUSDC), 99_999_999_999);
    }

    /**********************************************************************************************/
    /*** 16. adjustTotalAssets (gain) while queued, pause gating                                 ***/
    /**********************************************************************************************/

    // A positive delta sets chi = floor((totalAssets + gain) * RAY / totalSupply) for everyone,
    // escrowed shares included: a queued redeemer is paid MORE after a gain, pro rata with the
    // holders. Unlike round 3's `realizeGain`, it requires `paused` (:279), so no new redeem
    // request can be placed in the same block as the adjustment (R3-1).
    function test_processPendingRedeems_gainWhileQueued_escrowSharesGainProRata() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        assertEq(vault.convertToAssets(DEPOSIT_100K_SHARES), 99_999_999_998);
        assertEq(vault.totalAssets(),                        199_999_999_997);

        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/not-paused");
        vault.adjustTotalAssets(10_000e6);

        _pause();

        // Nobody can queue a redeem (or deposit) against the pending gain.
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestRedeem(1, bob);
        _fund(carol, 1e6);
        vm.prank(carol);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(1e6, carol, 0);

        vm.expectEmit(true, true, true, true, address(vault));
        emit TotalAssetsAdjusted(uint192(1.060172156650366224592543507e27), 10_000e6);
        _adjustTotalAssets(10_000e6);  // 5% of the book
        _unpause();

        uint256 chiAfter = vault.nowChi();
        assertEq(chiAfter, (199_999_999_997 + 10_000e6) * RAY / (2 * DEPOSIT_100K_SHARES));
        assertEq(chiAfter, 1.060172156650366224592543507e27);
        assertEq(vault.totalAssets(), 209_999_999_996);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(alice, alice, DEPOSIT_100K_SHARES, 100_225_932_569, 104_999_999_998);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),       104_999_999_998);
        assertEq(_queued(id),                 0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.assetsOf(bob),         104_999_999_998);

        // The backing did not grow (spUSDC VSR is RAY): alice's extra 5_000e6 was paid out of the
        // common spUSDC, so bob's 104_999_999_998 claim is backed by 95_000_000_000 USDC until
        // the realised gain actually arrives.
        assertEq(_vaultSpUsdc(),                         90_680_605_659);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 95_000_000_000);
    }

    // R3-1 residual: the admin payload is public before the guardian pauses. A redeem request
    // placed in that window is NOT a way to capture a gain early (the fill happens after the
    // adjustment anyway), but a holder who sees a LOSS coming cannot exit either: the request
    // is final and the escrow takes the loss. Queue position buys nothing in either direction.
    function test_adjustTotalAssets_queueingBeforePauseCapturesNothing() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _requestRedeem(alice, DEPOSIT_100K_SHARES);  // alice front-runs the pause

        _pause();
        _adjustTotalAssets(-10_000e6);
        _unpause();
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice), 94_999_999_998);
        assertEq(vault.assetsOf(bob),   94_999_999_998);  // identical outcome
    }

    /**********************************************************************************************/
    /*** 17. getPendingRedeemRequest(id)                                                        ***/
    /**********************************************************************************************/

    // The single-entry getter (src/SparkPrimeVault.sol:736-749) requires
    // `firstPendingRedeemId <= id < length`: a filled id below the head reverts even though the
    // slot still exists; a partially filled head is readable; past-the-end reverts.
    function test_getPendingRedeemRequest_rangeAndContents() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeemTo(alice, DEPOSIT_100K_SHARES, carol);
        uint256 idB = _requestRedeem(bob, DEPOSIT_100K_SHARES);

        (address o, address r, uint256 sh) = vault.getPendingRedeemRequest(idA);
        assertEq(o,  alice);
        assertEq(r,  carol);
        assertEq(sh, DEPOSIT_100K_SHARES);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingRedeemRequest(2);

        _processRedeems(DEPOSIT_100K_SHARES + 1, 10);  // alice full, bob 1 share

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingRedeemRequest(idA);  // below the head now
        (o, r, sh) = vault.getPendingRedeemRequest(idB);
        assertEq(o,  bob);
        assertEq(r,  bob);
        assertEq(sh, DEPOSIT_100K_SHARES - 1);

        // The range getter still reads the deleted slot.
        (o, r, sh) = _redeemRequest(idA);
        assertEq(o, address(0));
        assertEq(sh, 0);
    }

}
