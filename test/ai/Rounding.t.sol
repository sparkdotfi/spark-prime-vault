// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError, Vm } from "../../lib/forge-std/src/Test.sol";
import { console2 }     from "../../lib/forge-std/src/console2.sol";

import { ERC1967Proxy } from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkPrimeVault } from "../../src/SparkPrimeVault.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";
import { DripTable }     from "./tables/DripTable.sol";

// Exposes the pure math helpers (same pattern as spark-vaults-v2 test/Math.t.sol).
contract SparkPrimeVaultMathHarness is SparkPrimeVault {

    function divUp(uint256 x, uint256 y) external pure returns (uint256) {
        return _divUp(x, y);
    }

    function rpow(uint256 x, uint256 n) external pure returns (uint256) {
        return _rpow(x, n);
    }

}

/// @dev Rounding campaign for `SparkPrimeVault`, round 3 (src = `refactor/more-simplifying` @
///      ff828d2). Every rounding site R1..R14 gets a direction proof against the
///      exact rational value, computed in the test with cross-multiplication so nothing is
///      rounded on the reference side. Indexes are randomised (VSR in bounds, random warp, drip)
///      unless a test says "harness chis", which means the ugly setUp values chi_s ~1.0476e27
///      and chi_p ~1.0097e27. Section headers pin each site to its `src/SparkPrimeVault.sol` line.
///
///      Notation: c_s = chi_s / RAY, c_p = chi_p / RAY (real numbers >= 1), S = totalSupply.
contract RoundingTest is LocalTestBase {

    uint256 constant TEN_YEARS = 10 * 365 days;

    bytes32 constant DEPOSIT_TOPIC = keccak256("Deposit(address,address,uint256,uint256)");

    SparkPrimeVaultMathHarness internal math;

    address internal alice = makeAddr("alice");
    address internal bob   = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        math = new SparkPrimeVaultMathHarness();
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    /// @dev Puts both indexes at random values: VSRs anywhere in [RAY, MAX_VSR], up to ten years
    ///      of accrual, then drips so `chi == nowChi()` for the rest of the test.
    function _randomChis(uint256 vsrS, uint256 vsrP, uint256 secs)
        internal returns (uint256 chiS, uint256 chiP)
    {
        vsrS = bound(vsrS, RAY, MAX_VSR);
        vsrP = bound(vsrP, RAY, MAX_VSR);
        secs = bound(secs, 0, TEN_YEARS);

        _setSpUsdcVsr(vsrS);
        _setPrimeVsr(vsrP);
        _warpAndDrip(secs);

        chiS = spUsdc.nowChi();
        chiP = vault.nowChi();

        assertEq(spUsdc.chi(), chiS, "helper: spUSDC not dripped");
        assertEq(vault.chi(),  chiP, "helper: spPRIME not dripped");
    }

    /// @dev `value == floor(num / den)` checked by cross-multiplication: value <= num/den and
    ///      num/den - value < 1.
    function _assertFloor(uint256 value, uint256 num, uint256 den, string memory site) internal pure {
        assertLe(value * den, num,       string.concat(site, ": not <= exact"));
        assertLt(num - value * den, den, string.concat(site, ": more than 1 below exact"));
    }

    /// @dev `value == ceil(num / den)`: value >= num/den and value - num/den < 1.
    function _assertCeil(uint256 value, uint256 num, uint256 den, string memory site) internal pure {
        assertGe(value * den, num,       string.concat(site, ": not >= exact"));
        assertLt(value * den - num, den, string.concat(site, ": more than 1 above exact"));
    }

    function _divUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / y + 1;
    }

    /// @dev Reads (assets, shares) from the last `Deposit` event the vault emitted.
    function _lastDepositEvent(Vm.Log[] memory logs) internal view returns (uint256 assets, uint256 shares) {
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory log = logs[i - 1];
            if (log.emitter == address(vault) && log.topics[0] == DEPOSIT_TOPIC) {
                return abi.decode(log.data, (uint256, uint256));
            }
        }
        revert("no Deposit event");
    }

    function _depositShares(uint256 id) internal view returns (uint256 shares) {
        (,, shares) = _depositRequest(id);
    }

    function _redeemShares(uint256 id) internal view returns (uint256 shares) {
        (,, shares) = _redeemRequest(id);
    }

    /// @dev Splits `total` into `k` pseudo-random positive parts (seed `split`) and returns them.
    function _parts(uint256 total, uint256 k, uint256 split) internal pure returns (uint256[] memory parts) {
        parts = new uint256[](k);
        uint256 remaining = total;
        for (uint256 i = 0; i + 1 < k; ++i) {
            uint256 room = remaining - (k - 1 - i);          // leave >= 1 per later part
            parts[i]     = 1 + uint256(keccak256(abi.encode(split, i))) % room;
            remaining   -= parts[i];
        }
        parts[k - 1] = remaining;
    }

    /// @dev Settles cancelled entry `cancelId` (size `s`) in `k` chunks, checking the chunk budget
    ///      is applied exactly in spUSDC shares.
    function _settleInChunks(uint256 cancelId, uint256 s, uint256 k, uint256 split) internal {
        uint256[] memory parts = _parts(s, k, split);
        uint256 remaining = s;
        for (uint256 i = 0; i < k; ++i) {
            _processCancelledDeposits(parts[i], 1);
            remaining -= parts[i];
            (,, uint256 left) = _cancelledDepositRequest(cancelId);
            assertEq(left, remaining, "chunk budget is exact in spUSDC shares");
        }
    }

    function _realizeInParts(uint256 total, uint256 k, uint256 split) internal {
        uint256[] memory parts = _parts(total, k, split);
        for (uint256 i = 0; i < k; ++i) _realizeLoss(parts[i]);
    }

    function _realizeGain(uint256 gain) internal {
        vm.prank(admin);
        vault.realizeGain(gain);
    }

    function _realizeGainInParts(uint256 total, uint256 k, uint256 split) internal {
        uint256[] memory parts = _parts(total, k, split);
        for (uint256 i = 0; i < k; ++i) _realizeGain(parts[i]);
    }

    /// @dev Leaves alice holding exactly `n` spPRIME shares (harness chis): deposits enough for
    ///      them and redeems the rest.
    function _trimSupplyTo(uint256 n) internal {
        uint256 x = _divUp(n * vault.nowChi() * _divUp(spUsdc.nowChi(), RAY), RAY) + 2;
        _deposit(alice, x);
        uint256 extra = vault.balanceOf(alice) - n;
        if (extra != 0) {
            _requestRedeem(alice, extra);
            _processRedeems(type(uint256).max, 1);
        }
        assertEq(vault.totalSupply(), n, "trim: supply");
    }

    /// @dev Fresh spPRIME proxy over the harness spUSDC, chi == RAY, VSR bounds [RAY, MAX_VSR].
    function _freshVault(address impl) internal returns (SparkPrimeVault fresh) {
        fresh = SparkPrimeVault(address(new ERC1967Proxy(
            impl,
            abi.encodeCall(SparkPrimeVault.initialize, (address(spUsdc), "fresh", "fresh", admin))
        )));
        vm.startPrank(admin);
        fresh.grantRole(SETTER_ROLE, setter);
        fresh.setVSRBounds(RAY, MAX_VSR);
        vm.stopPrank();
    }

    /**********************************************************************************************/
    /*** R1  _requestDeposit:717  spUSDC.deposit  floor(assets * RAY / chi_s)                     ***/
    /**********************************************************************************************/

    function testFuzz_R1_spUsdcDeposit_roundsInFavourOfSpUsdc(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (uint256 chiS,) = _randomChis(vsrS, vsrP, secs);

        uint256 spUsdcBefore = _vaultSpUsdc();
        uint256 usdcBefore   = usdc.balanceOf(address(spUsdc));

        _deposit(alice, assets);

        uint256 received = _vaultSpUsdc() - spUsdcBefore;

        // The vault pays `assets` in full and gets floor(assets / c_s) spUSDC shares: at most one
        // spUSDC share (worth c_s USDC wei) below exact. spUSDC keeps the remainder.
        assertEq(usdc.balanceOf(address(spUsdc)) - usdcBefore, assets);
        assertEq(received, assets * RAY / chiS);
        _assertFloor(received, assets * RAY, chiS, "R1");
    }

    /// @dev Harness chis: any deposit below c_s USDC wei (here: exactly 1 wei) buys 0 spUSDC
    ///      shares. The USDC is donated to spUSDC, the queue entry is a 0-share ghost and cannot
    ///      be cancelled (`no-request`). Only `minDeposit >= ceil(c_s)` prevents it (F-5 family).
    function test_R1_dustDeposit_belowOneSpUsdcShare_isLostToSpUsdc() public {
        assertGt(spUsdc.nowChi(), RAY);

        uint256 id = _deposit(alice, 1);

        assertEq(_vaultSpUsdc(),             0);
        assertEq(vault.balanceOf(alice),     0);
        assertEq(_depositShares(id),         0);
        assertEq(usdc.balanceOf(alice),      0);
        assertEq(usdc.balanceOf(address(spUsdc)), 1);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(id, alice);
    }

    /**********************************************************************************************/
    /*** R2  _processPendingDeposits:744  spUSDC.convertToShares(convertToAssets(capacity))         ***/
    /**********************************************************************************************/

    /// @dev The admitted spUSDC amount is floor(floor(A * c_p) / c_s): at most 1 + 1/c_s below
    ///      the exact A * c_p / c_s, i.e. at most 2 spUSDC shares. Fewer spUSDC admitted means
    ///      fewer spPRIME minted, so this favours the vault (capacity under-used, never exceeded).
    function testFuzz_R2_capacityToSavingsShares_roundsInFavourOfVault(
        uint256 capacity, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        capacity = bound(capacity, 0, 1e12);
        (uint256 chiS, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        _setCapacity(capacity);

        // Large enough that the capacity, not the request, is the binding limit for any chis.
        uint256 assets = 4e15;
        uint256 id     = _deposit(alice, assets);

        uint256 requested = assets * RAY / chiS;
        uint256 admitted  = requested - _depositShares(id);

        uint256 expected = (capacity * chiP / RAY) * RAY / chiS;

        assertLt(expected, requested, "setup: request must exceed capacity");
        assertEq(admitted, expected);

        // admitted <= A * c_p / c_s  and  A * c_p / c_s - admitted < 1 + RAY / chi_s <= 2
        assertLe(admitted * chiS, capacity * chiP, "R2: not <= exact");
        assertLt(capacity * chiP - admitted * chiS, chiS + RAY, "R2: more than 1 + 1/c_s below exact");

        assertLe(vault.totalSupply(), capacity, "R2: capacity exceeded");
    }

    /**********************************************************************************************/
    /*** R3  _processPendingDeposits:762  spUSDC.convertToAssets  floor(s * chi_s / RAY)            ***/
    /*** R4  _processPendingDeposits:763  convertToShares         floor(assets * RAY / chi_p)       ***/
    /**********************************************************************************************/

    function testFuzz_R3_R4_fillConversion_roundsInFavourOfVault(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (uint256 chiS, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        uint256 savingsShares = assets * RAY / chiS;  // R1, proven above

        vm.recordLogs();
        _deposit(alice, assets);

        if (savingsShares == 0) {
            // below one spUSDC share: 0-share entry is skipped as cancelled, nothing is minted
            assertEq(vault.balanceOf(alice), 0);
            assertEq(vault.totalSupply(), 0);
            return;
        }

        (uint256 eventAssets, uint256 eventShares) = _lastDepositEvent(vm.getRecordedLogs());

        // R3: the USDC value credited is floor(s * c_s), <= exact, < 1 wei below.
        assertEq(eventAssets, savingsShares * chiS / RAY);
        _assertFloor(eventAssets, savingsShares * chiS, RAY, "R3");

        // R4: the shares minted are floor(assets / c_p), <= exact, < 1 share below.
        assertEq(eventShares, eventAssets * RAY / chiP);
        assertEq(vault.balanceOf(alice), eventShares);
        _assertFloor(eventShares, eventAssets * RAY, chiP, "R4");

        // The vault keeps s spUSDC worth >= the assets credited: never under-backed by a fill.
        assertGe(spUsdc.convertToAssets(_vaultSpUsdc()), vault.convertToAssets(eventShares));
    }

    /**********************************************************************************************/
    /*** R5  requestRedeem:487  shares_ >= minRedeem  (minRedeem in SHARES: no rounding)        ***/
    /**********************************************************************************************/

    /// @dev The minimum is now compared in shares, so the check is exact: `minRedeem` passes,
    ///      `minRedeem - 1` reverts, for any chi. `shares_ != 0` is no longer required.
    function testFuzz_R5_minRedeem_checkIsExactInShares(
        uint256 shares, uint256 minRedeem, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        _randomChis(vsrS, vsrP, secs);

        _deposit(alice, 1e15);
        uint256 balance = vault.balanceOf(alice);
        vm.assume(balance != 0);

        shares    = bound(shares, 0, balance);
        minRedeem = bound(minRedeem, 0, 2e15);

        _setMinRedeem(minRedeem);

        if (shares < minRedeem) vm.expectRevert("SparkPrimeVault/below-minimum");
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
    }

    /// @dev `minRedeem` is fixed in shares, so its value in assets is `convertToAssets(minRedeem)`
    ///      = floor(minRedeem * c_p) and grows with chi. Harness: 1000e6 shares are worth
    ///      1_009_687_768 USDC today; after 365 days at 5% the same minimum is worth
    ///      1_060_172_156 USDC (+5.0%, the floor costs < 1 wei); after 10 years at 5%,
    ///      1_644_674_980 USDC. The share-denominated check itself does not move.
    function test_R5_minRedeem_assetValueDriftsUpWithChi() public {
        uint256 minRedeem = 1_000e6;
        _setMinRedeem(minRedeem);
        _deposit(alice, 1e15);

        uint256 chi0 = vault.nowChi();
        uint256 v0   = vault.convertToAssets(minRedeem);
        assertEq(v0, 1_009_687_768);
        _assertFloor(v0, minRedeem * chi0, RAY, "R5 value");

        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);

        uint256 chi1 = vault.nowChi();
        uint256 v1   = vault.convertToAssets(minRedeem);
        assertEq(v1, 1_060_172_156);
        assertEq(chi1, chi0 * math.rpow(FIVE_PCT_VSR, 365 days) / RAY);
        _assertFloor(v1, minRedeem * chi1, RAY, "R5 value 365d");
        // v1 / v0 == c_p1 / c_p0 up to the two floors: |v1 * chi0 - v0 * chi1| < chi0 + chi1
        int256 cross = int256(v1 * chi0) - int256(v0 * chi1);
        assertLt(cross < 0 ? uint256(-cross) : uint256(cross), chi0 + chi1);

        // The check does not move: minRedeem - 1 shares reverts at either chi, minRedeem passes,
        // although minRedeem - 1 shares is now worth more USDC than minRedeem was a year ago.
        assertGt(vault.convertToAssets(minRedeem - 1), v0);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(minRedeem - 1, alice);
        vm.prank(alice);
        vault.requestRedeem(minRedeem, alice);

        _warpAndDrip(TEN_YEARS - 365 days);
        assertEq(vault.convertToAssets(minRedeem), 1_644_674_980);
    }

    /// @dev `shares_ != 0` was dropped: with `minRedeem == 0` a zero-share request is accepted,
    ///      pushes a 0-share entry (treated as cancelled by the queue), moves nothing. Also from a
    ///      caller with no balance.
    function test_R5_zeroShareRequest_isAcceptedWhenMinRedeemIsZero() public {
        assertEq(vault.minRedeem(), 0);

        vm.prank(bob);
        uint256 id = vault.requestRedeem(0, bob);

        assertEq(id, 0);
        assertEq(_redeemShares(id), 0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.totalSupply(), 0);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(id, bob);
    }

    /**********************************************************************************************/
    /*** R6  requestRedeem:494  _divUp(shares * redeemFee, WAD)                                  ***/
    /**********************************************************************************************/

    /// @dev With `minRedeem` now in shares (and 0 by default) the ceil has a visible edge: for
    ///      any fee > 0 a request of `s < WAD / fee` shares pays exactly 1 share, an effective
    ///      rate of 1 / s. At s == 1 the whole request is fee: 0 shares are queued, the entry is
    ///      dead (`no-request` on cancel) and the share is burned.
    function test_R6_feeCeil_oneShareRequest_isEntirelyFee() public {
        _setRedeemFeeRate(1);                         // 1e-18, the smallest non-zero fee
        _deposit(alice, 1_000e6);
        uint256 supplyBefore = vault.totalSupply();

        uint256 id = _requestRedeem(alice, 1);

        assertEq(vault.totalSupply(), supplyBefore - 1);
        assertEq(_redeemShares(id), 0);
        assertEq(vault.pendingRedeemShares(), 0);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(id, alice);

        // At the 1% cap: 99 shares pay 1 (1.01%), 100 shares pay 1 (1%), 101 shares pay 2 (1.98%).
        _setRedeemFeeRate(0.01e18);
        assertEq(math.divUp(99  * 0.01e18, WAD), 1);
        assertEq(math.divUp(100 * 0.01e18, WAD), 1);
        assertEq(math.divUp(101 * 0.01e18, WAD), 2);
    }

    function testFuzz_R6_redeemFee_roundsInFavourOfVault(
        uint256 shares, uint256 fee, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        _randomChis(vsrS, vsrP, secs);
        fee = bound(fee, 0, vault.MAX_REDEEM_FEE());
        _setRedeemFeeRate(fee);

        _deposit(alice, 1e15);
        uint256 balance = vault.balanceOf(alice);
        vm.assume(balance != 0);
        shares = bound(shares, 1, balance);

        uint256 supplyBefore = vault.totalSupply();

        uint256 id = _requestRedeem(alice, shares);

        uint256 burned = supplyBefore - vault.totalSupply();

        assertEq(burned, _divUp(shares * fee, WAD));
        assertEq(_redeemShares(id), shares - burned);
        assertEq(vault.balanceOf(address(vault)), shares - burned);
        assertEq(vault.pendingRedeemShares(),     shares - burned);

        if (fee == 0) {
            assertEq(burned, 0);
        } else {
            assertGe(burned, 1, "R6: non-zero fee rounded to zero");
            _assertCeil(burned, shares * fee, WAD, "R6");
        }
    }

    function testFuzz_fee_isCeilAndAtMostOneWeiAbove(uint256 shares, uint256 fee) public view {
        shares = bound(shares, 0, type(uint128).max);
        fee    = bound(fee, 0, 0.01e18);

        uint256 ceilFee = math.divUp(shares * fee, WAD);

        assertGe(ceilFee * WAD, shares * fee);
        assertLt(ceilFee * WAD - shares * fee, WAD);
        assertLe(ceilFee, shares * fee / WAD + 1);
    }

    /**********************************************************************************************/
    /*** R7  _processPendingRedeems:822  convertToShares(availableLiquidAssets())  floor            ***/
    /**********************************************************************************************/

    function testFuzz_R7_liquidityClamp_roundsInFavourOfVault(
        uint256 assets, uint256 liquidity, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (uint256 chiS, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 shares = vault.balanceOf(alice);
        vm.assume(shares != 0);
        uint256 id = _requestRedeem(alice, shares);

        // Leave `liquidity` USDC inside spUSDC (the vault is the only depositor).
        liquidity = bound(liquidity, 0, assets);
        _drainSpUsdcLiquidity(assets - liquidity);

        uint256 maxWithdraw = spUsdc.maxWithdraw(address(vault));
        assertLe(maxWithdraw, liquidity);
        assertEq(vault.availableLiquidAssets(), maxWithdraw);

        uint256 usdcBefore = usdc.balanceOf(alice);
        _processRedeems(type(uint256).max, type(uint256).max);

        uint256 burned = shares - _redeemShares(id);
        uint256 paid   = usdc.balanceOf(alice) - usdcBefore;

        uint256 clamp = maxWithdraw * RAY / chiP;
        assertEq(burned, clamp < shares ? clamp : shares);

        // The clamp is <= the exact liquidity in shares, < 1 share below; what is paid never
        // exceeds the liquidity measured.
        _assertFloor(clamp, maxWithdraw * RAY, chiP, "R7");
        assertEq(paid, burned * chiP / RAY);
        assertLe(paid, maxWithdraw);
        assertLe(paid, liquidity);
        assertEq(spUsdc.balanceOf(address(vault)) * chiS / RAY, spUsdc.assetsOf(address(vault)));
    }

    /**********************************************************************************************/
    /*** R8  _processPendingRedeems:835  convertToAssets(shares)  floor                             ***/
    /*** R9  _processPendingRedeems:845  spUSDC.withdraw(assets)  burns ceil(assets * RAY / chi_s)  ***/
    /**********************************************************************************************/

    function testFuzz_R8_R9_redeemFill_floorPayoutCeilBurn(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (uint256 chiS, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 shares = vault.balanceOf(alice);
        vm.assume(shares != 0);
        _requestRedeem(alice, shares);

        uint256 spUsdcBefore = _vaultSpUsdc();
        uint256 usdcBefore   = usdc.balanceOf(alice);

        _processRedeems(type(uint256).max, 1);

        uint256 paid   = usdc.balanceOf(alice) - usdcBefore;
        uint256 burned = spUsdcBefore - _vaultSpUsdc();

        // R8: user gets floor(shares * c_p), <= exact, < 1 wei below, never 0 for shares >= 1.
        assertEq(paid, shares * chiP / RAY);
        _assertFloor(paid, shares * chiP, RAY, "R8");
        assertGe(paid, 1);
        assertGe(paid, shares);  // chi_p >= RAY

        // R9: the vault burns ceil(paid / c_s) spUSDC shares: >= exact, < 1 share above.
        assertEq(burned, _divUp(paid * RAY, chiS));
        _assertCeil(burned, paid * RAY, chiS, "R9");
        assertLe(burned, spUsdcBefore, "R9: single fill never exceeds vault spUSDC");

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    /// @dev NEW BUG (R9 batch). `remaining_` is clamped with `convertToShares(maxWithdraw)`, where
    ///      `maxWithdraw` = floor(bal_s * c_s); each fill then burns ceil(paid_i / c_s) spUSDC. The
    ///      sum of n ceilings can exceed `bal_s` by up to n - 1 shares, so the n-th `withdraw`
    ///      reverts with `SparkVault/insufficient-balance` and the whole batch is undone.
    ///      Harness chis: vault holds 3548 spUSDC (maxWithdraw 3717 USDC, clamp 3681 shares),
    ///      two requests of 2396 + 1285 = 3681 shares burn 2310 + 1239 = 3549 > 3548.
    ///      This test asserts the intended behaviour (both paid) and therefore FAILS.
    function test_BUG_processPendingRedeems_batchCeilBurnsExceedSpUsdcBalance() public {
        _deposit(alice, 1_000_000e6);

        _take(_vaultSpUsdc() - 3548);
        assertEq(_vaultSpUsdc(), 3548);
        assertEq(spUsdc.maxWithdraw(address(vault)), 3717);
        assertEq(vault.convertToShares(3717), 3681);

        uint256 id1 = _requestRedeem(alice, 2396);
        uint256 id2 = _requestRedeem(alice, 1285);

        uint256 usdcBefore = usdc.balanceOf(alice);

        _processRedeems(type(uint256).max, 2);  // reverts: SparkVault/insufficient-balance

        assertEq(_redeemShares(id1), 0);
        assertEq(_redeemShares(id2), 0);
        assertEq(usdc.balanceOf(alice) - usdcBefore, 2419 + 1297);
    }

    /// @dev Same state: the operator can work around it with one request per call, because the
    ///      clamp is recomputed from the reduced balance each time.
    function test_processPendingRedeems_batchCeilBurn_oneRequestPerCallSucceeds() public {
        _deposit(alice, 1_000_000e6);
        _take(_vaultSpUsdc() - 3548);

        uint256 id1 = _requestRedeem(alice, 2396);
        uint256 id2 = _requestRedeem(alice, 1285);

        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(rebalancer);
        vm.expectRevert("SparkVault/insufficient-balance");
        vault.processPendingRedeems(type(uint256).max, 2);

        _processRedeems(type(uint256).max, 1);
        assertEq(_redeemShares(id1), 0);
        assertEq(_vaultSpUsdc(), 3548 - 2310);

        // Second call: maxWithdraw = floor(1238 * c_s) = 1296 USDC -> clamp 1283 shares, so the
        // second request is only partially filled (1283 of 1285) and 2 shares stay queued.
        _processRedeems(type(uint256).max, 1);
        assertEq(_redeemShares(id2), 2);
        assertEq(_vaultSpUsdc(), 1);
        assertEq(usdc.balanceOf(alice) - usdcBefore, 2419 + 1295);
    }

    /**********************************************************************************************/
    /*** R10 _processPendingDepositCancellations:805  spUSDC.redeem(shares)  floor(s * chi_s / RAY)   ***/
    /***     budget :784  min(maxSavingsShares, spUSDC.maxRedeem(vault))                        ***/
    /***     maxRedeem = min(floor(L * RAY / chi_s), bal_s), L = USDC held by spUSDC            ***/
    /**********************************************************************************************/

    /// @dev The refund moved from `requestDepositCancellation` to the settlement call, same floor, same
    ///      direction. deposit -> cancel -> settle in one shot: refund = floor(floor(X / c_s) c_s),
    ///      loss < 1 + c_s wei.
    function testFuzz_R10_cancelDepositAndSettle_roundsAgainstCancellingUser(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (uint256 chiS,) = _randomChis(vsrS, vsrP, secs);

        _setCapacity(0);                         // everything queues
        uint256 id = _deposit(alice, assets);

        uint256 savingsShares = _depositShares(id);
        assertEq(savingsShares, assets * RAY / chiS);
        vm.assume(savingsShares != 0);           // else `no-request` (see test_R1_dustDeposit)

        vm.prank(alice);
        uint256 cancelId = vault.requestDepositCancellation(id, alice);
        assertEq(usdc.balanceOf(alice), 0, "cancel itself pays nothing");
        assertEq(vault.pendingCancelledDepositSavingsShares(), savingsShares);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        uint256 refund = usdc.balanceOf(alice);

        assertEq(refund, savingsShares * chiS / RAY);
        _assertFloor(refund, savingsShares * chiS, RAY, "R10");

        // Round trip through spUSDC: user gets back <= assets, loses < 1 + c_s wei.
        assertLe(refund, assets);
        assertLt((assets - refund) * RAY, RAY + chiS, "R10: cancel loss exceeds 1 + c_s");
        assertEq(_vaultSpUsdc(), 0);
        (,, uint256 left) = _cancelledDepositRequest(cancelId);
        assertEq(left, 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    /// @dev Settling a cancelled entry in k chunks applies the floor k times: the user gets
    ///      sum floor(s_i c_s) >= floor(s c_s) - (k - 1), so at most k - 1 wei less than one shot
    ///      and the total loss vs the deposit is < c_s + k wei. The dust stays in spUSDC.
    function testFuzz_R10_cancelDepositSettledInChunks_losesAtMostKMinusOneMore(
        uint256 assets, uint256 k, uint256 split, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        k      = bound(k, 1, 6);
        (uint256 chiS,) = _randomChis(vsrS, vsrP, secs);

        _setCapacity(0);
        uint256 id = _deposit(alice, assets);
        uint256 s  = _depositShares(id);
        vm.assume(s >= k);

        vm.prank(alice);
        uint256 cancelId = vault.requestDepositCancellation(id, alice);

        uint256 snapshot = vm.snapshotState();
        _processCancelledDeposits(type(uint256).max, 1);
        uint256 oneShot = usdc.balanceOf(alice);
        vm.revertToState(snapshot);

        _settleInChunks(cancelId, s, k, split);

        uint256 chunked = usdc.balanceOf(alice);

        assertLe(chunked, oneShot);
        assertLe(oneShot - chunked, k - 1, "R10 chunks: lost more than k - 1 wei vs one shot");
        assertLt((assets - chunked) * RAY, chiS + k * RAY, "R10 chunks: loss >= c_s + k");
        assertEq(_vaultSpUsdc(), 0);
        (,, uint256 finalLeft) = _cancelledDepositRequest(cancelId);
        assertEq(finalLeft, 0);
    }

    /// @dev Harness chis, exact: 1000e6 USDC -> 954_532_691 spUSDC shares. One shot refunds
    ///      999_999_999 (loss 1). Settled 1 share at a time for the first 18 shares then the rest:
    ///      each 1-share chunk refunds floor(1.0476) = 1 USDC and leaves 0.0476 in spUSDC; 18
    ///      chunks accumulate 0.857 of dust, enough to tip the remainder's floor, and the total
    ///      refund is 999_999_998 (17 one-share chunks still refund 999_999_999 in total).
    function test_R10_chunkedSettlement_example() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, 1_000e6);
        assertEq(_depositShares(id), 954_532_691);

        vm.prank(alice);
        vault.requestDepositCancellation(id, alice);

        uint256 snapshot = vm.snapshotState();
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 999_999_999);
        vm.revertToState(snapshot);

        for (uint256 i = 0; i < 17; ++i) _processCancelledDeposits(1, 1);
        assertEq(usdc.balanceOf(alice), 17);                    // 17 x floor(1 * 1.0476)
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 999_999_999);           // 17 extra floors: still 1 lost
        vm.revertToState(snapshot);

        for (uint256 i = 0; i < 18; ++i) _processCancelledDeposits(1, 1);
        assertEq(usdc.balanceOf(alice), 18);
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 999_999_998);           // 18 extra floors: 2 lost
    }

    /// @dev The settlement budget is `min(maxSavingsShares, spUSDC.balanceOf(vault))`, in spUSDC
    ///      shares with no conversion: when the vault holds fewer spUSDC than the entry (taken
    ///      out by the taker), exactly the balance is settled, nothing is rounded.
    function test_R10_budgetIsVaultSpUsdcBalance_noConversion() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, 1_000e6);
        uint256 s  = _depositShares(id);

        vm.prank(alice);
        uint256 cancelId = vault.requestDepositCancellation(id, alice);

        _take(s - 12_345);
        assertEq(_vaultSpUsdc(), 12_345);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        (,, uint256 left) = _cancelledDepositRequest(cancelId);
        assertEq(left, s - 12_345);
        assertEq(_vaultSpUsdc(), 0);
        assertEq(usdc.balanceOf(alice), 12_345 * spUsdc.nowChi() / RAY);
        assertEq(vault.firstPendingDepositCancellationId(), 0);  // partial fill, entry stays at the head
    }


    /// @dev Round 3: the budget is `spUSDC.maxRedeem(vault)` = min(floor(L RAY / chi_s), bal_s),
    ///      L = USDC held by spUSDC. When liquidity binds the settled amount is the floor of the
    ///      liquidity in spUSDC shares: M <= L / c_s, less than 1 share below; bal_s - M shares stay
    ///      queued, within 1 share of the exact bal_s - L / c_s.
    function testFuzz_R10_budget_liquidityBinds_isFloorOfLiquidityInShares(
        uint256 assets, uint256 liquidity, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (uint256 chiS,) = _randomChis(vsrS, vsrP, secs);

        _setCapacity(0);
        uint256 id = _deposit(alice, assets);
        uint256 s  = _depositShares(id);
        vm.assume(s != 0);

        vm.prank(alice);
        uint256 cancelId = vault.requestDepositCancellation(id, alice);

        liquidity = bound(liquidity, 0, assets);
        _drainSpUsdcLiquidity(assets - liquidity);

        uint256 m      = liquidity * RAY / chiS;
        uint256 budget = m < s ? m : s;
        assertEq(spUsdc.maxRedeem(address(vault)), budget);
        _assertFloor(m, liquidity * RAY, chiS, "R10 budget");

        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        (,, uint256 left) = _cancelledDepositRequest(cancelId);
        assertEq(left, s - budget);
        assertEq(_vaultSpUsdc(), s - budget);
        assertEq(usdc.balanceOf(alice), budget * chiS / RAY);
        assertLe(usdc.balanceOf(alice), liquidity, "R10: paid more than spUSDC holds");
        if (budget == 0) assertEq(vault.firstPendingDepositCancellationId(), 0);
    }

    /// @dev Batch safety (contrast with C-1 on the redeem queue). Every fill redeems s_i shares for
    ///      floor(s_i chi_s / RAY) USDC and sum s_i <= M = floor(L RAY / chi_s). Since
    ///      sum floor(x_i) <= floor(sum x_i) and M chi_s / RAY <= L, the n fills of one call pay at
    ///      most floor(M chi_s / RAY) <= L: spUSDC is never asked for more USDC than it holds and
    ///      no batch size reverts. Stranded liquidity per call when liquidity binds:
    ///      L - paid < c_s + n (one floor per fill plus the budget floor). Repeating the call
    ///      drains it down to < c_s wei (less than one spUSDC share), which is only recoverable
    ///      when more liquidity arrives.
    function testFuzz_R10_batchSettle_neverExceedsSpUsdcLiquidity(
        uint256 seed, uint256 n, uint256 liquidity, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        n = bound(n, 1, 6);
        (uint256 chiS,) = _randomChis(vsrS, vsrP, secs);

        (uint256[] memory sizes, uint256 bal) = _queueCancelledDeposits(seed, n);

        // the vault is spUSDC's only depositor
        liquidity = bound(liquidity, 0, usdc.balanceOf(address(spUsdc)));
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - liquidity);

        uint256 m      = liquidity * RAY / chiS;
        uint256 budget = m < bal ? m : bal;
        assertEq(spUsdc.maxRedeem(address(vault)), budget);

        (uint256 expectedPaid, uint256 fills) = _expectedFifoPaid(sizes, budget, chiS);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);   // never reverts

        uint256 paid = usdc.balanceOf(alice);
        assertEq(paid, expectedPaid);
        assertLe(paid, liquidity, "R10 batch: paid more than spUSDC liquidity");
        assertEq(_vaultSpUsdc(), bal - budget);
        assertEq(vault.pendingCancelledDepositSavingsShares(), bal - budget);
        assertEq(usdc.balanceOf(address(spUsdc)), liquidity - paid);

        if (m >= bal) return;                                 // liquidity did not bind

        // liquidity binds: stranded < c_s + fills, in wei
        assertLt((liquidity - paid) * RAY, chiS + fills * RAY, "R10 batch: stranded >= c_s + n");

        _settleUntilBudgetIsZero(liquidity, chiS);
    }

    /// @dev Queues `n` deposits of pseudo-random size with capacity 0 and cancels them all.
    function _queueCancelledDeposits(uint256 seed, uint256 n)
        internal returns (uint256[] memory sizes, uint256 bal)
    {
        _setCapacity(0);
        sizes = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 amt = 1e6 + uint256(keccak256(abi.encode(seed, i))) % 1e12;
            uint256 id  = _deposit(alice, amt);
            sizes[i]    = _depositShares(id);
            bal        += sizes[i];
            vm.prank(alice);
            vault.requestDepositCancellation(id, alice);
        }
        assertEq(_vaultSpUsdc(), bal);
    }

    /// @dev FIFO fills of `budget` spUSDC shares over `sizes`, each paying floor(s_i chi_s / RAY).
    function _expectedFifoPaid(uint256[] memory sizes, uint256 budget, uint256 chiS)
        internal pure returns (uint256 paid, uint256 fills)
    {
        uint256 rem = budget;
        for (uint256 i = 0; i < sizes.length && rem != 0; ++i) {
            uint256 part = sizes[i] < rem ? sizes[i] : rem;
            paid += part * chiS / RAY;
            rem  -= part;
            ++fills;
        }
    }

    /// @dev Repeats settlement until `maxRedeem` is 0: whatever USDC is then left in spUSDC is
    ///      < c_s (worth less than one spUSDC share) while shares remain queued.
    function _settleUntilBudgetIsZero(uint256 liquidity, uint256 chiS) internal {
        for (uint256 r = 0; r < 10 && spUsdc.maxRedeem(address(vault)) != 0; ++r) {
            _processCancelledDeposits(type(uint256).max, type(uint256).max);
        }
        assertEq(spUsdc.maxRedeem(address(vault)), 0);
        uint256 paid = usdc.balanceOf(alice);
        assertLe(paid, liquidity);
        if (_vaultSpUsdc() != 0) {
            assertLt((liquidity - paid) * RAY, chiS, "R10 batch: final stranded >= c_s");
        }
    }

    /// @dev Harness, the C-1 state transposed to the cancelled queue: liquidity 3717 USDC against
    ///      3549 queued spUSDC (2310 + 1239), budget floor(3717 / 1.0476) = 3547 shares. Fills
    ///      2310 -> 2420 and 1237 -> 1295 USDC, total 3715 <= 3717, no revert (the same two sizes
    ///      on the redeem queue revert, `test_BUG_processPendingRedeems_*`). Stranded 2 wei; a second
    ///      call settles 1 more share for 1 USDC, leaving 1 share queued and 1 wei (< c_s) in spUSDC.
    function test_R10_batchSettle_c1StateDoesNotRevert() public {
        _setCapacity(0);
        uint256 id1 = _deposit(alice, 2421);
        uint256 id2 = _deposit(alice, 1299);
        assertEq(_depositShares(id1), 2310);
        assertEq(_depositShares(id2), 1239);

        vm.startPrank(alice);
        vault.requestDepositCancellation(id1, alice);
        uint256 c2 = vault.requestDepositCancellation(id2, alice);
        vm.stopPrank();

        _drainSpUsdcLiquidity(3);
        assertEq(usdc.balanceOf(address(spUsdc)), 3717);
        assertEq(spUsdc.maxRedeem(address(vault)), 3547);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(alice), 2420 + 1295);
        assertEq(usdc.balanceOf(address(spUsdc)), 2);
        (,, uint256 left) = _cancelledDepositRequest(c2);
        assertEq(left, 2);

        assertEq(spUsdc.maxRedeem(address(vault)), 1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), 3716);
        assertEq(usdc.balanceOf(address(spUsdc)), 1);
        (,, left) = _cancelledDepositRequest(c2);
        assertEq(left, 1);
        assertEq(spUsdc.maxRedeem(address(vault)), 0);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);   // no-op, no revert
        (,, left) = _cancelledDepositRequest(c2);
        assertEq(left, 1);
    }

    /**********************************************************************************************/
    /*** R11 drip:649 / nowChi:698  _rpow(vsr, dt) * chi / RAY, _rpow half-up                    ***/
    /**********************************************************************************************/

    /// @dev The harness indexes equal the python mirror of `_rpow` (test/tables/drip_reference.py).
    function test_R11_harnessIndexesMatchReference() public view {
        assertEq(spUsdc.chi(), DripTable.HARNESS_CHI_S);
        assertEq(vault.chi(),  DripTable.HARNESS_CHI_P);
        assertEq(vault.chi(),  1009687768242461209408770821);
        assertEq(spUsdc.chi(), 1047633055711877768967605062);
    }

    /// @dev `nowChi()` and `drip()` equal the reference table exactly for every VSR constant and
    ///      duration in {1s, 60s, 1h, 1d, 30d, 365d, 10y}, from chi0 = RAY (fresh vault) and from
    ///      the harness chi0.
    function test_R11_dripMatchesReferenceTable() public {
        DripTable.Row[] memory rows = DripTable.rows();
        assertEq(rows.length, 112);

        address impl = address(new SparkPrimeVault());

        uint256 snapshot = vm.snapshotState();

        for (uint256 i = 0; i < rows.length; ++i) {
            DripTable.Row memory row = rows[i];

            SparkPrimeVault v;
            if (row.chi0 == RAY) {
                v = _freshVault(impl);
            } else {
                assertEq(row.chi0, vault.chi(), "table chi0 is not the harness chi");
                v = vault;
            }

            vm.prank(setter);
            v.setVSR(row.vsr);

            uint256 rho = v.rho();
            vm.warp(rho + row.seconds_);

            assertEq(v.nowChi(), row.expectedChi, string.concat("nowChi row ", vm.toString(i)));
            assertEq(v.drip(),   row.expectedChi, string.concat("drip row ",   vm.toString(i)));
            assertEq(v.chi(),    row.expectedChi, string.concat("chi row ",    vm.toString(i)));
            assertEq(v.rho(),    rho + row.seconds_);

            vm.revertToState(snapshot);
        }
    }

    /// @dev `_rpow` compounding versus the continuous value chi0 * vsr^t (80-digit Decimal in the
    ///      python script, rounded to RAY). Drift in RAY units, from the script:
    ///        FOUR_PCT 365d: -318_029       FOUR_PCT 10y: -4_526_538
    ///        FIVE_PCT 365d: -4_298_403     FIVE_PCT 10y: -66_682_338
    ///        MAX_VSR  365d: +1_506_719     MAX_VSR  10y: +7_714_388_883
    ///      i.e. < 1e-18 relative over 10 years at 100% APY (chi ~ 1.024e30).
    function test_R11_rpowDriftVsContinuous() public view {
        assertEq(math.rpow(FOUR_PCT_VSR, 365 days),  1039999999999999999955174055);
        assertEq(math.rpow(FOUR_PCT_VSR, TEN_YEARS), 1480244284918343925121987035);
        assertEq(math.rpow(FIVE_PCT_VSR, 365 days),  1049999999999999999961070145);
        assertEq(math.rpow(FIVE_PCT_VSR, TEN_YEARS), 1628894626777441405646070172);
        assertEq(math.rpow(MAX_VSR, 365 days),       1999999999999999999947093656);
        assertEq(math.rpow(MAX_VSR, TEN_YEARS),      1023999999999999999729119504860);

        // continuous references (rounded half-up to RAY units)
        assertEq(math.rpow(FOUR_PCT_VSR, 365 days)  + 318_029,       1039999999999999999955492084);
        assertEq(math.rpow(FOUR_PCT_VSR, TEN_YEARS) + 4_526_538,     1480244284918343925126513573);
        assertEq(math.rpow(FIVE_PCT_VSR, 365 days)  + 4_298_403,     1049999999999999999965368548);
        assertEq(math.rpow(FIVE_PCT_VSR, TEN_YEARS) + 66_682_338,    1628894626777441405712752510);
        assertEq(math.rpow(MAX_VSR, 365 days)       - 1_506_719,     1999999999999999999945586937);
        assertEq(math.rpow(MAX_VSR, TEN_YEARS)      - 7_714_388_883, 1023999999999999999721405115977);

        // Relative drift bound: |drift| * 1e18 < chi over 10y at MAX_VSR.
        assertLt(uint256(7_714_388_883) * 1e18, uint256(1023999999999999999729119504860));
    }

    /// @dev Drip is path dependent: dripping every day for a year lands within a few RAY units of
    ///      a single 365-day drip (the half-up rounding is applied once per call).
    function test_R11_dripPathDependenceIsBounded() public {
        uint256 snapshot = vm.snapshotState();

        _setPrimeVsr(FIVE_PCT_VSR);
        uint256 rho = vault.rho();
        vm.warp(rho + 365 days);
        uint256 single = vault.drip();

        vm.revertToState(snapshot);

        _setPrimeVsr(FIVE_PCT_VSR);
        for (uint256 d = 1; d <= 365; ++d) {
            vm.warp(rho + d * 1 days);
            vault.drip();
        }
        uint256 daily = vault.chi();

        assertEq(vault.rho(), rho + 365 days);
        assertApproxEqAbs(daily, single, 400);
        console2.log("single drip", single, "daily drips", daily);
    }

    /**********************************************************************************************/
    /*** R12 convertToAssets:668 / convertToShares:672  floor / floor                            ***/
    /**********************************************************************************************/

    function testFuzz_R12_convertToAssets_roundsInFavourOfVault(
        uint256 shares, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        shares = bound(shares, 0, 1e30);
        (, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        uint256 assets = vault.convertToAssets(shares);
        assertEq(assets, shares * chiP / RAY);
        _assertFloor(assets, shares * chiP, RAY, "R12 convertToAssets");
        assertGe(assets, shares);  // chi_p >= RAY
    }

    function testFuzz_R12_convertToShares_roundsInFavourOfVault(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 0, 1e30);
        (, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        uint256 shares = vault.convertToShares(assets);
        assertEq(shares, assets * RAY / chiP);
        _assertFloor(shares, assets * RAY, chiP, "R12 convertToShares");
        assertLe(shares, assets);  // chi_p >= RAY
    }

    /// @dev convertToAssets(convertToShares(a)) <= a and the gap is < 1 + c_p.
    function testFuzz_R12_symmetry_assetsSharesAssets(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 0, 1e30);
        (, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        uint256 back = vault.convertToAssets(vault.convertToShares(assets));

        assertLe(back, assets);
        assertLt((assets - back) * RAY, RAY + chiP, "symmetry: gap >= 1 + c_p");
    }

    /// @dev convertToShares(convertToAssets(s)) <= s and the gap is at most 1 share.
    function testFuzz_R12_symmetry_sharesAssetsShares(
        uint256 shares, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        shares = bound(shares, 0, 1e30);
        _randomChis(vsrS, vsrP, secs);

        uint256 back = vault.convertToShares(vault.convertToAssets(shares));

        assertLe(back, shares);
        assertLe(shares - back, 1, "symmetry: gap > 1 share");
    }

    /**********************************************************************************************/
    /*** R13 realizeLoss:382  chi = uint192(((totalAssets() - loss) * RAY) / totalSupply)       ***/
    /***     requires :376  0 < loss < totalAssets()  and  :380  totalSupply != 0               ***/
    /**********************************************************************************************/

    /// @dev Direction. Two floors, both against holders: TA = floor(S chi / RAY), then
    ///      chi' = floor((TA - L) RAY / S). So S chi' <= (TA - L) RAY and S chi' > (TA - L) RAY - S,
    ///      giving TA' = floor(S chi' / RAY) in [TA - L - ceil(S / RAY), TA - L]. For a 6-decimal
    ///      supply (S < RAY) that is TA' in {TA - L - 1, TA - L}: holders lose at least `loss`
    ///      and at most 1 wei more, and exactly 1 wei more unless S | (TA - L) RAY. In chi units
    ///      the over-reduction is < RAY / S + 1. chi' <= chi always (uint192 cast cannot truncate).
    ///      Round 3: the admissible range is `0 < loss < TA` (`invalid-loss` otherwise), the
    ///      characterisation is unchanged on it.
    function testFuzz_R13_realizeLoss_floorsAgainstHolders_overRealisesAtMostOneWei(
        uint256 assets, uint256 loss, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 supply = vault.totalSupply();
        vm.assume(supply != 0);
        assertLt(supply, RAY);

        uint256 ta = vault.totalAssets();
        vm.assume(ta >= 2);                 // `0 < loss < TA` needs TA >= 2
        loss = bound(loss, 1, ta - 1);

        _pause();
        _realizeLoss(loss);

        uint256 chiNew = vault.chi();
        uint256 taNew  = vault.totalAssets();

        assertEq(chiNew, (ta - loss) * RAY / supply);
        _assertFloor(chiNew, (ta - loss) * RAY, supply, "R13 chi");
        assertLe(chiNew, chiP, "R13: chi grew");
        assertEq(vault.nowChi(), chiNew);

        // exact chi' would be chi - L RAY / S: the realised reduction is at least that and
        // less than RAY / S + 1 units more
        assertGe((chiP - chiNew) * supply, loss * RAY, "R13: holders lost less than loss");
        assertLt((chiP - chiNew) * supply - loss * RAY, RAY + supply, "R13: over-reduction bound");

        // in assets: drop in {loss, loss + 1}; exactly loss iff S divides (TA - L) RAY, which for
        // S coprime to 10 means TA - L in {0, S, 2S, ...}: the generic case is loss + 1.
        assertGe(ta - taNew, loss,     "R13: totalAssets dropped by less than loss");
        assertLe(ta - taNew, loss + 1, "R13: totalAssets dropped by more than loss + 1");
        assertEq(ta - taNew, loss + ((ta - loss) * RAY % supply == 0 ? 0 : 1), "R13: exact drop");
        assertEq(vault.assetsOf(alice), taNew);
    }

    /// @dev Both outcomes occur. Harness chis, 1_000_000e6 deposited (S = 990_405_184_109, coprime
    ///      to 10, TA = 999_999_999_998): loss 1 drops totalAssets by 2, loss 999_999_999 by
    ///      1_000_000_000 (generic case). The only loss with an exact drop is TA - S =
    ///      9_594_815_889 (lands chi exactly on RAY); TA itself (chi 0 in round 2) is now rejected.
    function test_R13_realizeLoss_harnessExamples() public {
        _deposit(alice, 1_000_000e6);
        assertEq(vault.totalSupply(),  990_405_184_109);
        assertEq(vault.totalAssets(),  999_999_999_998);
        uint256 chi0 = vault.chi();

        _pause();

        uint256 snapshot = vm.snapshotState();

        _realizeLoss(1);
        assertEq(vault.totalAssets(), 999_999_999_996);              // loss 1, drop 2
        assertEq(vault.chi(), 1009687768240663846587628160);
        assertEq(vault.chi(), 999_999_999_997 * RAY / 990_405_184_109);
        assertLt(vault.chi(), chi0);

        vm.revertToState(snapshot);

        _realizeLoss(999_999_999);
        assertEq(vault.totalAssets(), 999_999_999_998 - 1_000_000_000); // loss + 1

        vm.revertToState(snapshot);

        _realizeLoss(999_999_999_998 - 990_405_184_109);
        assertEq(vault.chi(), RAY);                                     // exact
        assertEq(vault.totalAssets(), 990_405_184_109);
    }

    /// @dev With S = 1 share, TA = floor(chi / RAY) = 1 for chi in [RAY, 2 RAY), so no loss passes
    ///      `0 < loss < totalAssets()`: a single-share vault cannot realise any loss (round 2: a
    ///      1-wei loss zeroed chi; the new bound removes that brick and with it every loss). The
    ///      smallest supply that can realise one is S = 2 (TA = 2): loss 1 gives chi = RAY / 2
    ///      exactly (2 | RAY), totalAssets 1, drop exactly 1.
    function test_R13_realizeLoss_singleShareSupply_noLossIsPossible() public {
        _trimSupplyTo(1);
        assertEq(vault.totalSupply(), 1);
        assertEq(vault.totalAssets(), 1);           // floor(1 * 1.0097) = 1

        _pause();
        for (uint256 loss = 0; loss <= 2; ++loss) {
            vm.prank(riskManager);
            vm.expectRevert("SparkPrimeVault/invalid-loss");
            vault.realizeLoss(loss);
        }
        assertEq(vault.totalAssets(), 1);
    }

    function test_R13_realizeLoss_twoShareSupply_oneWeiLossHalvesChi() public {
        _trimSupplyTo(2);
        assertEq(vault.totalSupply(), 2);
        assertEq(vault.totalAssets(), 2);

        _pause();
        _realizeLoss(1);

        assertEq(vault.chi(), RAY / 2);
        assertEq(vault.totalAssets(), 1);
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(1);                       // TA is 1 again: nothing more can be lost
    }

    /// @dev Boundary: `loss >= totalAssets()` and `loss == 0` revert `invalid-loss` (round 2 let
    ///      `loss == TA` through and left chi == 0, bricking `convertToShares`). The largest
    ///      succeeding loss is `totalAssets() - 1`; it leaves chi == floor(RAY / S), which is >= 1
    ///      for a 6-decimal supply (S < RAY), and totalAssets() in {0, 1}. chi can no longer reach 0.
    function testFuzz_R13_realizeLoss_largestSucceedingLossIsTotalAssetsMinusOne(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 supply = vault.totalSupply();
        vm.assume(supply != 0);
        uint256 ta = vault.totalAssets();

        _pause();

        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(ta + 1);

        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(ta);

        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(0);

        if (ta == 1) {
            assertEq(supply, 1);                           // TA >= S, so TA == 1 forces S == 1
            return;                                        // no loss is possible (see above)
        }

        _realizeLoss(ta - 1);
        assertEq(vault.chi(), RAY / supply);               // floor(1 * RAY / S) >= 1 as S < RAY
        assertGe(vault.chi(), 1);
        assertEq(vault.totalAssets(), supply * (RAY / supply) / RAY);  // 0 or 1
        assertEq(vault.convertToShares(1), RAY / (RAY / supply));      // no division by zero
    }

    /// @dev `totalSupply == 0`: `totalAssets()` is 0, so `loss_ < 0` is false for every loss and
    ///      the call reverts `invalid-loss` before the `no-shares` check. `no-shares` is unreachable
    ///      in `realizeLoss`: S == 0 implies TA == 0 implies `invalid-loss`, and S != 0 passes it.
    ///      (It is reachable in `realizeGain`, R14.)
    function testFuzz_R13_realizeLoss_zeroSupply_revertsInvalidLoss_noSharesUnreachable(uint256 loss)
        public
    {
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        _pause();

        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(loss);
    }

    /// @dev No truncation: chi' <= (TA - L) RAY / S <= TA RAY / S <= chi < 2^192, for any loss
    ///      in the admissible range. Checked over random chis up to 10 years at 100% APY
    ///      (chi ~ 1e30) and the full loss range.
    function testFuzz_R13_realizeLoss_castNeverTruncates(
        uint256 assets, uint256 loss, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 supply = vault.totalSupply();
        vm.assume(supply != 0);
        uint256 ta = vault.totalAssets();
        vm.assume(ta >= 2);                 // `0 < loss < TA` needs TA >= 2
        loss = bound(loss, 1, ta - 1);

        uint256 wide = (ta - loss) * RAY / supply;   // the uint256 value before the cast
        assertLe(wide, chiP);
        assertLt(wide, 2 ** 192);

        _pause();
        _realizeLoss(loss);
        assertEq(uint256(vault.chi()), wide);
    }

    /// @dev Path dependence: k losses summing to L never leave MORE than one loss of L (floor is
    ///      monotone and S chi_i / RAY <= TA_{i-1} - l_{i-1}), and at most k wei less:
    ///      0 <= TA_single - TA_k <= k. In chi units the gap is < k (RAY / S + 1).
    function testFuzz_R13_realizeLoss_sequenceVsSingle_pathDependenceBound(
        uint256 assets, uint256 total, uint256 k, uint256 split, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        k      = bound(k, 2, 6);
        _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 supply = vault.totalSupply();
        vm.assume(supply != 0);
        uint256 ta = vault.totalAssets();
        vm.assume(ta >= 2 * k);
        total = bound(total, k, ta - k);   // each step may over-realise 1 wei: keep k of headroom

        _pause();

        uint256 snapshot = vm.snapshotState();
        _realizeLoss(total);
        uint256 chiSingle = vault.chi();
        uint256 taSingle  = vault.totalAssets();
        vm.revertToState(snapshot);

        _realizeInParts(total, k, split);
        uint256 chiSeq = vault.chi();
        uint256 taSeq  = vault.totalAssets();

        assertLe(chiSeq, chiSingle, "R13 path: sequence left more value than one loss");
        assertLt((chiSingle - chiSeq) * supply, k * (RAY + supply), "R13 path: chi gap bound");
        assertLe(taSingle - taSeq, k, "R13 path: sequence over-realised more than k wei");
    }

    /// @dev Consequence for R8/R12: after a loss chi can be below RAY, so `convertToAssets(s) >= s`
    ///      no longer holds and a small redeem pays floor(s c_p) == 0 while the shares are burned.
    ///      Harness: lose all but 1 wei of a 1_000_000e6 position, chi ~ 1e15; redeeming 1e9 shares
    ///      pays 0 USDC (and burns 0 spUSDC: `withdraw(0)`).
    function test_R13_afterLoss_chiBelowRay_smallRedeemPaysZero() public {
        _deposit(alice, 1_000_000e6);
        uint256 ta = vault.totalAssets();

        _pause();
        _realizeLoss(ta - 1);
        _unpause();

        assertLt(vault.chi(), RAY);
        assertEq(vault.convertToAssets(1e9), 0);

        uint256 spBefore = _vaultSpUsdc();
        _requestRedeem(alice, 1e9);
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.balanceOf(alice), 990_405_184_109 - 1e9);
        assertEq(vault.totalSupply(),    990_405_184_109 - 1e9);
        assertEq(_vaultSpUsdc(), spBefore);
    }


    /**********************************************************************************************/
    /*** R14 realizeGain:306  chi = uint192(((totalAssets() + gain) * RAY) / totalSupply)       ***/
    /***     requires :298  gain > 0  and  :304  totalSupply != 0; drip() first; no pause check   ***/
    /**********************************************************************************************/

    /// @dev Direction. The same two floors as R13, again against holders: TA = floor(S chi / RAY),
    ///      chi' = floor((TA + G) RAY / S). S chi' <= (TA + G) RAY gives TA' <= TA + G and
    ///      S chi' > (TA + G) RAY - S gives TA' >= TA + G - ceil(S / RAY). For S < RAY:
    ///      TA' in {TA + G - 1, TA + G}, exactly TA + G iff S | (TA + G) RAY. In chi units the
    ///      credit is <= the exact G RAY / S and less than RAY / S + 1 units short. chi' >= chi for
    ///      every G >= 1 because (TA + 1) RAY > S chi.
    function testFuzz_R14_realizeGain_floorsAgainstHolders_underCreditsAtMostOneWei(
        uint256 assets, uint256 gain, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 supply = vault.totalSupply();
        vm.assume(supply != 0);
        assertLt(supply, RAY);

        uint256 ta = vault.totalAssets();
        gain = bound(gain, 1, 1e24);

        _realizeGain(gain);

        uint256 chiNew = vault.chi();
        uint256 taNew  = vault.totalAssets();

        assertEq(chiNew, (ta + gain) * RAY / supply);
        _assertFloor(chiNew, (ta + gain) * RAY, supply, "R14 chi");
        assertGe(chiNew, chiP, "R14: chi fell");
        assertEq(vault.nowChi(), chiNew);

        // exact chi' would be chi + G RAY / S: the credit is at most that and less than
        // RAY / S + 1 units short
        assertLe((chiNew - chiP) * supply, gain * RAY, "R14: holders credited more than gain");
        assertLt(gain * RAY - (chiNew - chiP) * supply, RAY + supply, "R14: under-credit bound");

        // in assets: rise in {gain - 1, gain}; exactly gain iff S divides (TA + G) RAY
        assertLe(taNew - ta, gain,          "R14: totalAssets rose by more than gain");
        assertGe(taNew - ta + 1, gain,      "R14: totalAssets rose by less than gain - 1");
        assertEq(taNew - ta, gain - ((ta + gain) * RAY % supply == 0 ? 0 : 1), "R14: exact rise");
        assertEq(vault.assetsOf(alice), taNew);
    }

    /// @dev Harness, 1_000_000e6 deposited (S = 990_405_184_109, TA = 999_999_999_998): gain 1
    ///      raises totalAssets by 0, gain 2 by 1, gain 999_999_999 by 999_999_998 (generic case:
    ///      gain - 1). Exact only when S | TA + G, e.g. G = 2S - TA = 980_810_368_220 lands chi on
    ///      exactly 2 RAY.
    function test_R14_realizeGain_harnessExamples() public {
        _deposit(alice, 1_000_000e6);
        assertEq(vault.totalSupply(), 990_405_184_109);
        assertEq(vault.totalAssets(), 999_999_999_998);
        uint256 chi0 = vault.chi();

        uint256 snapshot = vm.snapshotState();

        _realizeGain(1);
        assertEq(vault.totalAssets(), 999_999_999_998);              // gain 1, rise 0
        assertEq(vault.chi(), 1009687768242683222124115546);
        assertGt(vault.chi(), chi0);
        vm.revertToState(snapshot);

        _realizeGain(2);
        assertEq(vault.totalAssets(), 999_999_999_999);              // gain 2, rise 1
        vm.revertToState(snapshot);

        _realizeGain(999_999_999);
        assertEq(vault.totalAssets(), 999_999_999_998 + 999_999_998); // gain - 1
        vm.revertToState(snapshot);

        _realizeGain(2 * 990_405_184_109 - 999_999_999_998);
        assertEq(vault.chi(), 2 * RAY);                               // exact
        assertEq(vault.totalAssets(), 2 * 990_405_184_109);
    }

    /// @dev No pause check, admin only, `drip()` first: the gain is added on top of the accrued
    ///      index, paused or not. 365 days at 5% un-dripped, then gain 1 while paused: chi is
    ///      floor((TA_accrued + 1) RAY / S) with TA_accrued from `nowChi()` before the call, and
    ///      rho moves to now.
    function test_R14_realizeGain_dripsFirst_worksPausedAndUnpaused() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply = vault.totalSupply();

        _setPrimeVsr(FIVE_PCT_VSR);
        _warp(365 days);
        uint256 taAccrued = vault.totalAssets();                      // via nowChi(), not dripped
        assertGt(taAccrued, 999_999_999_998);

        _pause();
        _realizeGain(1);
        assertEq(vault.chi(), (taAccrued + 1) * RAY / supply);
        assertEq(vault.rho(), block.timestamp);

        _unpause();
        uint256 ta = vault.totalAssets();
        _realizeGain(5);
        assertEq(vault.chi(), (ta + 5) * RAY / supply);

        vm.prank(riskManager);
        vm.expectRevert();
        vault.realizeGain(1);                                          // DEFAULT_ADMIN_ROLE only
    }

    function test_R14_realizeGain_zeroGain_revertsInvalidGain() public {
        _deposit(alice, 1_000e6);
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/invalid-gain");
        vault.realizeGain(0);
    }

    /// @dev Unlike R13, `no-shares` is reachable here: with S == 0 any positive gain passes the
    ///      first check and hits the supply check (the division by zero is never reached).
    function testFuzz_R14_realizeGain_zeroSupply_revertsNoShares(uint256 gain) public {
        gain = bound(gain, 1, type(uint256).max);
        assertEq(vault.totalSupply(), 0);

        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/no-shares");
        vault.realizeGain(gain);
    }

    /// @dev Path dependence: k gains summing to G credit no more than one gain of G
    ///      (TA_{i} <= TA_{i-1} + g_i, so TA_{k-1} + g_k <= TA + G and the floor is monotone) and at
    ///      most k wei less: 0 <= TA_single - TA_k <= k, (chi_single - chi_k) S < k (RAY + S). One
    ///      aggregated gain is better for holders than a stream of small ones.
    function testFuzz_R14_realizeGain_sequenceVsSingle_pathDependenceBound(
        uint256 assets, uint256 total, uint256 k, uint256 split, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        k      = bound(k, 2, 6);
        _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 supply = vault.totalSupply();
        vm.assume(supply != 0);
        total = bound(total, k, 1e24);

        uint256 snapshot = vm.snapshotState();
        _realizeGain(total);
        uint256 chiSingle = vault.chi();
        uint256 taSingle  = vault.totalAssets();
        vm.revertToState(snapshot);

        _realizeGainInParts(total, k, split);
        uint256 chiSeq = vault.chi();
        uint256 taSeq  = vault.totalAssets();

        assertLe(chiSeq, chiSingle, "R14 path: sequence credited more than one gain");
        assertLt((chiSingle - chiSeq) * supply, k * (RAY + supply), "R14 path: chi gap bound");
        assertLe(taSingle - taSeq, k, "R14 path: sequence under-credited more than k wei");
    }

    /// @dev Three thresholds on `gain`, in this order for every supply (because RAY > 2^64):
    ///        G_drip  = ceil((C + 1) S / RAY) - 1 - TA,  C = floor((2^256 - 1) / RAY)
    ///                  largest gain after which `drip()` still works at VSR == RAY
    ///        G_trunc = ceil(2^192 S / RAY) - TA         smallest gain whose quotient wraps in uint192
    ///        G_ovf   = C - TA                            largest gain whose product fits uint256
    ///      Harness (S = 990_405_184_109, TA = 999_999_999_998):
    ///        G_drip  = 114_681_085_459_449_903_921_528_244_645_760_028                 (1.1468e35)
    ///        G_trunc = 6_216_874_099_906_568_962_213_193_772_734_343_774_180_112       (6.2169e42)
    ///        G_ovf   = 115_792_089_237_316_195_423_570_985_008_687_907_852_269_984_665_642 (1.1579e50)
    function _gainThresholds(uint256 supply, uint256 ta)
        internal pure returns (uint256 gDrip, uint256 gTrunc, uint256 gOvf)
    {
        uint256 c = type(uint256).max / RAY;
        gDrip  = _divUp((c + 1) * supply, RAY) - 1 - ta;
        gTrunc = _divUp((2 ** 192) * supply, RAY) - ta;
        gOvf   = c - ta;
    }

    /// @dev uint256: `(TA + G) * RAY` overflows (panic 0x11) iff TA + G > C, i.e. G > G_ovf.
    function testFuzz_R14_realizeGain_uint256OverflowThreshold(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 supply = vault.totalSupply();
        vm.assume(supply != 0);
        uint256 ta = vault.totalAssets();

        (uint256 gDrip, uint256 gTrunc, uint256 gOvf) = _gainThresholds(supply, ta);
        assertLt(gDrip, gTrunc);
        assertLt(gTrunc, gOvf);

        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        vault.realizeGain(gOvf + 1);

        _realizeGain(gOvf);                                            // fits; wraps in uint192
        assertEq(uint256(vault.chi()), ((ta + gOvf) * RAY / supply) % (2 ** 192));
    }

    /// @dev uint192: for G < G_trunc the quotient is < 2^192 and chi stores it exactly; at G_trunc
    ///      the cast wraps silently and chi becomes `quotient mod 2^192`, far below the intended
    ///      value. (Every such G is already > G_drip, so `drip()` is bricked anyway unless the wrap
    ///      lands below C, see the BUG test.)
    function testFuzz_R14_realizeGain_uint192TruncationThreshold(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 supply = vault.totalSupply();
        vm.assume(supply != 0);
        uint256 ta = vault.totalAssets();

        (, uint256 gTrunc,) = _gainThresholds(supply, ta);

        uint256 snapshot = vm.snapshotState();

        uint256 wide = (ta + gTrunc - 1) * RAY / supply;
        assertLt(wide, 2 ** 192);
        _realizeGain(gTrunc - 1);
        assertEq(uint256(vault.chi()), wide);
        vm.revertToState(snapshot);

        wide = (ta + gTrunc) * RAY / supply;
        assertGe(wide, 2 ** 192);
        _realizeGain(gTrunc);
        assertEq(uint256(vault.chi()), wide % (2 ** 192));
        assertLt(uint256(vault.chi()), wide, "R14: cast did not wrap");
    }

    /// @dev BUG · Low (admin only). Past G_trunc the wrap can land chi anywhere in [0, 2^192), and
    ///      in particular back below C where `drip()` works again: the vault stays alive with a
    ///      collapsed index. Harness: G = ceil((2^192 + RAY) S / RAY) - TA =
    ///      6_216_874_099_906_568_962_213_193_772_735_334_179_364_221 gives quotient 2^192 + RAY +
    ///      458_233_707_431_279, stored chi = 1_000_000_000_000_458_233_707_431_279 (~RAY):
    ///      totalAssets() falls from 999_999_999_998 to 990_405_184_109 after a "gain", drip works,
    ///      `GainRealized` reports the collapsed chi. A wrap to exactly 0 is also possible
    ///      (quotient = m 2^192), bricking `convertToShares`.
    function test_BUG_realizeGain_uint192TruncationCollapsesChi() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply = vault.totalSupply();
        uint256 ta     = vault.totalAssets();

        uint256 gain = _divUp((2 ** 192 + RAY) * supply, RAY) - ta;
        assertEq(gain, 6_216_874_099_906_568_962_213_193_772_735_334_179_364_221);

        uint256 quotient = (ta + gain) * RAY / supply;
        assertEq(quotient - 2 ** 192, 1_000_000_000_000_458_233_707_431_279);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.GainRealized(uint192(quotient), gain);
        _realizeGain(gain);

        assertEq(vault.chi(), 1_000_000_000_000_458_233_707_431_279);
        assertEq(vault.totalAssets(), 990_405_184_109);               // was 999_999_999_998
        assertLt(vault.totalAssets(), ta);

        _warpAndDrip(365 days);                                        // drip alive
        assertEq(vault.chi(), 1_000_000_000_000_458_233_707_431_279); // VSR == RAY
    }

    /// @dev BUG · Low (admin only). `drip()` computes `_rpow(vsr, dt) * chi`, which must stay below
    ///      2^256: chi <= floor((2^256 - 1) / rpow). At VSR == RAY that is chi <= C ~ 1.158e50 for
    ///      any dt. G_drip is the largest gain keeping chi <= C; one more wei pushes chi over it
    ///      and every call that drips (deposits, redeems, queue processing, setVSR, realizeLoss,
    ///      realizeGain, nowChi-based views) panics as soon as block.timestamp > rho. Only an
    ///      upgrade can recover. Deposits die earlier through CAP-1: `availableCapacity() * chi`
    ///      overflows once chi > type(uint256).max / availableCapacity() (3.4e38 at the harness cap).
    function testFuzz_BUG_realizeGain_dripOverflowThreshold_exact(
        uint256 assets, uint256 dt, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        dt     = bound(dt, 1, TEN_YEARS);
        _randomChis(vsrS, vsrP, secs);
        _setPrimeVsr(RAY);                                             // rpow(RAY, dt) == RAY

        _deposit(alice, assets);
        uint256 supply = vault.totalSupply();
        vm.assume(supply != 0);
        uint256 ta = vault.totalAssets();

        (uint256 gDrip,,) = _gainThresholds(supply, ta);
        uint256 c = type(uint256).max / RAY;

        uint256 snapshot = vm.snapshotState();

        _realizeGain(gDrip);
        assertLe(uint256(vault.chi()), c);
        _warp(dt);
        assertEq(vault.nowChi(), vault.chi());
        vault.drip();
        // CAP-1 binds long before G_drip at the harness cap (3.4e38 * chi overflows once
        // chi > 3.4e38), so shrink the capacity to keep `availableCapacity() * chi` in range.
        _setCapacity(vault.totalSupply() + 1);
        _deposit(bob, 1e6);                                            // no revert: vault alive
        vm.revertToState(snapshot);

        _realizeGain(gDrip + 1);
        assertGt(uint256(vault.chi()), c);
        _warp(dt);

        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
        vm.expectRevert(stdError.arithmeticError);
        vault.nowChi();
        vm.expectRevert(stdError.arithmeticError);
        vault.totalAssets();

        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(1e6, bob);

        _pause();
        vm.prank(riskManager);
        vm.expectRevert(stdError.arithmeticError);
        vault.realizeLoss(1);
        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        vault.realizeGain(1);
        vm.prank(setter);
        vm.expectRevert(stdError.arithmeticError);
        vault.setVSR(RAY);
    }

    /// @dev Harness numbers for the drip threshold, and the VSR dependence: the same G_drip that is
    ///      safe forever at VSR == RAY bricks the vault 1 second after the VSR is raised, because
    ///      the bound is chi <= (2^256 - 1) / rpow(vsr, dt) and rpow(MAX_VSR, 1) > RAY.
    function test_BUG_realizeGain_dripOverflow_oneWeiBricks_thresholdShrinksWithVsr() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply = vault.totalSupply();
        uint256 ta     = vault.totalAssets();

        (uint256 gDrip, uint256 gTrunc, uint256 gOvf) = _gainThresholds(supply, ta);
        assertEq(gDrip,  114_681_085_459_449_903_921_528_244_645_760_028);
        assertEq(gTrunc, 6_216_874_099_906_568_962_213_193_772_734_343_774_180_112);
        assertEq(gOvf,   115_792_089_237_316_195_423_570_985_008_687_907_852_269_984_665_642);

        uint256 snapshot = vm.snapshotState();

        _realizeGain(gDrip + 1);
        assertEq(vault.chi(), 115792089237316195423570985008687908517705232418866);
        _warp(1);
        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
        vm.revertToState(snapshot);

        _realizeGain(gDrip);
        assertEq(vault.chi(), 115792089237316195423570985008687907508017464175173);
        assertLe(uint256(vault.chi()), type(uint256).max / RAY);
        _warpAndDrip(TEN_YEARS);                                       // fine at VSR == RAY

        _setPrimeVsr(MAX_VSR);                                         // drips at dt == 0: fine
        assertGt(uint256(vault.chi()), type(uint256).max / MAX_VSR);  // over the 1-second bound
        _warp(1);
        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
    }

    /**********************************************************************************************/
    /*** Round trips                                                                            ***/
    /**********************************************************************************************/

    /// @dev deposit X -> instant fill -> requestRedeem all (fee 0) -> process. Four floors in a
    ///      row (R1, R3, R4, R8): X - out < 2 + c_s + c_p. The vault keeps the spUSDC dust.
    function testFuzz_roundTrip_instantDepositRedeem_lossBound(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (uint256 chiS, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 shares = vault.balanceOf(alice);
        if (shares != 0) {
            _requestRedeem(alice, shares);
            _processRedeems(type(uint256).max, 1);
        }

        uint256 out = usdc.balanceOf(alice);

        assertLe(out, assets);
        assertLt((assets - out) * RAY, 2 * RAY + chiS + chiP, "round trip: loss >= 2 + c_s + c_p");

        // Vault keeps whatever spUSDC the ceil burn left, never goes short.
        assertGe(spUsdc.convertToAssets(_vaultSpUsdc()), 0);
        assertEq(vault.totalSupply(), 0);
    }

    /// @dev Harness chis (c_s ~1.0476, c_p ~1.0097): the bound is 4.057, so the loss is at most
    ///      4 wei. Brute force in the python script over X in [1, 4e6]: max 4 wei, first at X=836;
    ///      histogram {1: 1, 2: 3781586, 3: 216766, 4: 1647}.
    function testFuzz_roundTrip_instantDepositRedeem_harnessChis_lossAtMost4(uint256 assets) public {
        assets = bound(assets, 1, 1e15);

        _deposit(alice, assets);
        uint256 shares = vault.balanceOf(alice);
        if (shares != 0) {
            _requestRedeem(alice, shares);
            _processRedeems(type(uint256).max, 1);
        }

        uint256 out = usdc.balanceOf(alice);
        assertLe(out, assets);
        assertLe(assets - out, 4, "round trip: loss > 4 wei at harness chis");
    }

    function test_roundTrip_maxLossExample_836wei() public {
        _deposit(alice, 836);
        assertEq(_vaultSpUsdc(),         797);   // floor(836 / 1.0476)
        assertEq(vault.balanceOf(alice), 825);   // floor(floor(797 * 1.0476) = 834 / 1.0097)

        _requestRedeem(alice, 825);
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice), 832);    // floor(825 * 1.0097)
        assertEq(_vaultSpUsdc(), 797 - 795);     // ceil(832 / 1.0476) = 795 burned, 2 shares kept
    }

    /// @dev Same bound when the deposit sits in the queue first (capacity 0 at request, raised
    ///      before processing). Conversion happens at fill time with the same four floors.
    function testFuzz_roundTrip_queuedDepositRedeem_lossBound(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (uint256 chiS, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        _setCapacity(0);
        uint256 id = _deposit(alice, assets);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(_depositShares(id), assets * RAY / chiS);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);
        assertEq(_depositShares(id), 0);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        uint256 shares = vault.balanceOf(alice);
        if (shares != 0) {
            _requestRedeem(alice, shares);
            _processRedeems(type(uint256).max, 1);
        }

        uint256 out = usdc.balanceOf(alice);
        assertLe(out, assets);
        assertLt((assets - out) * RAY, 2 * RAY + chiS + chiP, "queued round trip: loss bound");
    }

    function testFuzz_roundTrip_queuedDepositRedeem_harnessChis_lossAtMost4(uint256 assets) public {
        assets = bound(assets, 1, 1e15);

        _setCapacity(0);
        _deposit(alice, assets);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);

        uint256 shares = vault.balanceOf(alice);
        if (shares != 0) {
            _requestRedeem(alice, shares);
            _processRedeems(type(uint256).max, 1);
        }

        assertLe(assets - usdc.balanceOf(alice), 4);
    }

    /**********************************************************************************************/
    /*** Capacity chain                                                                         ***/
    /**********************************************************************************************/

    function testFuzz_capacity_totalSupplyNeverExceedsMaxCapacity(
        uint256 capacity, uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        capacity = bound(capacity, 0, 1e15);
        assets   = bound(assets, 1, 4e15);
        _randomChis(vsrS, vsrP, secs);

        _setCapacity(capacity);
        _deposit(alice, assets);
        assertLe(vault.totalSupply(), capacity);

        // a second fill from the queue cannot push it over either
        _processDeposits(type(uint256).max, type(uint256).max);
        assertLe(vault.totalSupply(), capacity);
    }

    /// @dev Repeatedly fill a queued deposit until a call makes no progress. The capacity that
    ///      stays unfillable satisfies residual < 1 + (2 + c_s) / c_p shares, i.e.
    ///      residual * chi_p < chi_p + 2 * RAY + chi_s. At harness chis this is 2 shares.
    function testFuzz_capacity_underUseBound(uint256 capacity, uint256 vsrS, uint256 vsrP, uint256 secs)
        public
    {
        capacity = bound(capacity, 0, 1e12);
        (uint256 chiS, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        _setCapacity(capacity);
        uint256 id = _deposit(alice, 4e15);

        for (uint256 n = 0; n < 8 && _depositShares(id) != 0; ++n) {
            uint256 before = vault.totalSupply();
            _processDeposits(type(uint256).max, 1);
            if (vault.totalSupply() == before) break;   // no progress: stuck (F-4 may have burnt dust)
        }

        assertLe(vault.totalSupply(), capacity);
        uint256 residual = vault.availableCapacity();

        assertLt(residual * chiP, chiP + 2 * RAY + chiS, "capacity: unfillable residual too large");
    }

    function testFuzz_capacity_underUseBound_harnessChis_atMost2(uint256 capacity) public {
        capacity = bound(capacity, 0, 1e12);

        _setCapacity(capacity);
        uint256 id = _deposit(alice, 4e15);

        for (uint256 n = 0; n < 8 && _depositShares(id) != 0; ++n) {
            uint256 before = vault.totalSupply();
            _processDeposits(type(uint256).max, 1);
            if (vault.totalSupply() == before) break;
        }

        assertLe(vault.totalSupply(), capacity);
        assertLe(vault.availableCapacity(), 2, "capacity: residual > 2 at harness chis");
    }

    /// @dev `setCapacity` no longer bounds the value. `_processPendingDeposits` computes
    ///      `convertToAssets(availableCapacity())` = `availableCapacity() * nowChi()`, which
    ///      overflows (panic 0x11) once `maxCapacity - totalSupply > type(uint256).max / nowChi()`.
    ///      Every deposit routes through it, so the exact usable bound is
    ///      `maxCapacity <= totalSupply + type(uint256).max / nowChi()` and it shrinks as chi grows.
    function testFuzz_capacity_overflowThreshold_isMaxUintOverChi(uint256 vsrS, uint256 vsrP, uint256 secs)
        public
    {
        (, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        uint256 limit = type(uint256).max / chiP;

        _setCapacity(limit);
        _deposit(alice, 1e6);                     // fine: availableCapacity * chi fits
        uint256 supply = vault.totalSupply();

        _setCapacity(limit + supply);             // availableCapacity == limit exactly: still fine
        _deposit(alice, 1e6);
        supply = vault.totalSupply();

        _setCapacity(limit + supply + 1);         // one over: every deposit reverts
        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(1e6, bob);

        vm.prank(rebalancer);
        vm.expectRevert(stdError.arithmeticError);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);
    }

    /// @dev The same capacity that works today overflows after the index grows: harness
    ///      chi_p ~1.0097e27 gives a limit of 1.1468e50; after 365 days at 5% (chi ~1.0602e27) the
    ///      limit is 1.0922e50, and a capacity set between the two bricks deposits a year later.
    function test_capacity_overflowThreshold_shrinksAsChiGrows() public {
        uint256 chi0   = vault.nowChi();
        uint256 limit0 = type(uint256).max / chi0;
        assertEq(limit0, 114681085459589801375833087904206311575507395147570);

        _setCapacity(limit0);
        _deposit(alice, 1e6);
        assertGt(vault.totalSupply(), 0);

        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);

        uint256 limit1 = type(uint256).max / vault.nowChi();
        assertEq(limit1, 109220081390085525123890485623544109152849575647725);
        assertLt(limit1, limit0 - vault.totalSupply());

        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(1e6, bob);

        _setCapacity(limit1 + vault.totalSupply());
        vm.prank(bob);
        vault.requestDeposit(1e6, bob);
        assertGt(vault.balanceOf(bob), 0);

        // the harness value type(uint128).max is 3.4e38, far inside the limit at any reachable chi
        assertLt(type(uint128).max, type(uint256).max / (RAY * 1024));  // 10 years at 100% APY
    }

    /// @dev Harness chis, exact: capacity 2 is unfillable and every attempt burns 1 spUSDC share
    ///      from the head request without minting (F-4, known).
    function test_capacity_residualTwo_isUnfillable_andDustBurnsSpUsdc() public {
        _setCapacity(2);
        uint256 id = _deposit(alice, 1_000e6);
        uint256 queued = _depositShares(id);

        assertEq(vault.totalSupply(), 0);   // floor(2 * 1.0097) = 2 USDC -> 1 spUSDC -> 1 USDC -> 0 shares
        assertEq(queued, 1_000e6 * RAY / spUsdc.nowChi() - 1);   // 1 spUSDC share already consumed (F-4)

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.totalSupply(), 0);
        assertEq(_depositShares(id), queued - 1);  // another spUSDC share burnt, nothing minted
        assertEq(vault.availableCapacity(), 2);
    }

    /**********************************************************************************************/
    /*** Zero-mint region (F-4)                                                                 ***/
    /**********************************************************************************************/

    /// @dev Exact characterisation: convertToShares(spUSDC.convertToAssets(s)) == 0  iff
    ///      floor(s * c_s) * RAY < chi_p  iff  s <= sMax, with
    ///        K    = (chi_p - 1) / RAY                       (largest USDC amount worth < 1 share)
    ///        sMax = ceil((K + 1) * RAY / chi_s) - 1         (largest s worth at most K USDC)
    ///      For chi_p in (RAY, 2 RAY): K = 1, sMax = ceil(2 RAY / chi_s) - 1, which is 1 for any
    ///      chi_s > RAY (1 spUSDC share -> 1 USDC wei -> 0 spPRIME shares) and 0 at chi_s == RAY.
    function _zeroMintMax(uint256 chiS, uint256 chiP) internal pure returns (uint256) {
        uint256 k = (chiP - 1) / RAY;
        return _divUp((k + 1) * RAY, chiS) - 1;
    }

    function testFuzz_F4_zeroMintRegion_exactCharacterisation(uint256 vsrS, uint256 vsrP, uint256 secs)
        public
    {
        (uint256 chiS, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        uint256 sMax = _zeroMintMax(chiS, chiP);

        assertEq(vault.convertToShares(spUsdc.convertToAssets(sMax)),     0, "sMax mints");
        assertGe(vault.convertToShares(spUsdc.convertToAssets(sMax + 1)), 1, "sMax + 1 mints 0");

        // composition is monotone in s, so every s <= sMax mints 0 and every s > sMax mints >= 1
        if (sMax != 0) assertEq(vault.convertToShares(spUsdc.convertToAssets(sMax - 1)), 0);
        assertGe(vault.convertToShares(spUsdc.convertToAssets(sMax + 2)), 1);

        // rough form from the task: sMax < ceil(chi_p / chi_s) + 1  (sMax ~ (K+1)/c_s - 1)
        assertLt(sMax * chiS, chiP + RAY + chiS);
    }

    struct ZeroMintRow { uint256 chiS; uint256 chiP; uint256 sMax; }

    /// @dev Table of (chi_s, chi_p, max zero-mint s), checked against a brute-force scan of the
    ///      same two floors.
    function test_F4_zeroMintRegion_table() public pure {
        ZeroMintRow[8] memory rows = [
            ZeroMintRow(RAY,                            RAY,                            0),
            ZeroMintRow(DripTable.HARNESS_CHI_S,        DripTable.HARNESS_CHI_P,        1),
            ZeroMintRow(RAY,                            DripTable.HARNESS_CHI_P,        1),
            ZeroMintRow(DripTable.HARNESS_CHI_S,        RAY,                            0),
            ZeroMintRow(1.5e27,                         1.5e27,                         1),
            ZeroMintRow(RAY,                            2e27,                           1),
            ZeroMintRow(RAY,                            2e27 + 1,                       2),
            ZeroMintRow(2e27,                           10e27,                          4)
        ];

        for (uint256 i = 0; i < rows.length; ++i) {
            uint256 sMax = _zeroMintMax(rows[i].chiS, rows[i].chiP);
            assertEq(sMax, rows[i].sMax, string.concat("row ", vm.toString(i)));

            // brute force the boundary with the contract formulas
            uint256 s = 0;
            while ((s * rows[i].chiS / RAY) * RAY / rows[i].chiP == 0) ++s;
            assertEq(s - 1, rows[i].sMax, string.concat("brute row ", vm.toString(i)));
        }
    }

    /**********************************************************************************************/
    /*** Rate mismatch economics (3x3, 365 days, 1_000_000e6 deposited at harness chis)          ***/
    /**********************************************************************************************/

    /// @dev backing = spUSDC value of the vault's spUSDC, notional = totalAssets(). Surplus is
    ///      what the vault's equity gains (positive) or the deficit a future setChi would have to
    ///      realise (negative). Deposit at harness chis: 1_000_000e6 USDC -> 954_532_691_143 spUSDC
    ///      shares -> 999_999_999_999 USDC credited -> 990_405_184_109 spPRIME shares.
    function test_rateMismatch_3x3_surplusAfter365d() public {
        uint256[3] memory rates = [RAY, FOUR_PCT_VSR, FIVE_PCT_VSR];

        // expected[s][p], from the first run, in USDC wei (6 decimals)
        int256[3][3] memory expected = [
            [int256(1),              int256(-39_999_999_999), int256(-49_999_999_999)],
            [int256(40_000_000_000), int256(0),               int256(-10_000_000_000)],
            [int256(50_000_000_000), int256(10_000_000_000),  int256(0)]
        ];

        uint256 snapshot = vm.snapshotState();

        for (uint256 s = 0; s < 3; ++s) {
            for (uint256 p = 0; p < 3; ++p) {
                _deposit(alice, 1_000_000e6);
                assertEq(_vaultSpUsdc(), 954_532_691_143);
                assertEq(vault.balanceOf(alice), 990_405_184_109);

                _setSpUsdcVsr(rates[s]);
                _setPrimeVsr(rates[p]);
                _warpAndDrip(365 days);

                int256 backing  = int256(spUsdc.convertToAssets(_vaultSpUsdc()));
                int256 notional = int256(vault.totalAssets());
                int256 surplus  = backing - notional;

                console2.log("spUSDC rate idx", s, "prime rate idx", p);
                console2.log("  backing", uint256(backing), "notional", uint256(notional));
                console2.log("  surplus", surplus);

                assertEq(surplus, expected[s][p]);

                vm.revertToState(snapshot);
            }
        }
    }

    /**********************************************************************************************/
    /*** _divUp                                                                                 ***/
    /**********************************************************************************************/

    function test_divUp_zeroNumerator() public view {
        assertEq(math.divUp(0, 1), 0);
        assertEq(math.divUp(0, type(uint256).max), 0);
        assertEq(math.divUp(0, 0), 0);   // the `x_ != 0` guard stops the unchecked `x_ - 1` underflow
    }

    function test_divUp_divideByZero_reverts() public {
        vm.expectRevert(stdError.divisionError);
        math.divUp(1, 0);
    }

    function testFuzz_divUp_exactMultiple(uint256 k, uint256 y) public view {
        y = bound(y, 1, type(uint128).max);
        k = bound(k, 1, type(uint128).max);
        assertEq(math.divUp(k * y, y), k);
    }

    function testFuzz_divUp_multiplePlusOne(uint256 k, uint256 y) public view {
        y = bound(y, 2, type(uint128).max);
        k = bound(k, 0, type(uint128).max);
        assertEq(math.divUp(k * y + 1, y), k + 1);
        assertEq(math.divUp(k * y + y - 1, y), k + 1);
    }

    function testFuzz_divUp_isCeil(uint256 x, uint256 y) public view {
        y = bound(y, 1, type(uint256).max);
        uint256 z = math.divUp(x, y);
        assertEq(z, x / y + (x % y == 0 ? 0 : 1));
    }

}
