// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError, Vm } from "../../lib/forge-std/src/Test.sol";
import { console2 }     from "../../lib/forge-std/src/console2.sol";

import { ERC1967Proxy } from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkPrimeVault } from "../../src/SparkPrimeVault.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";
import { ISparkPrimeVault } from "src/ISparkPrimeVault.sol";
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

/// @dev Rounding campaign for `SparkPrimeVault`, round 5 (src = `master` @ 0ebb452; rounds 2-4
///      were ff828d2 / bf93b0d). Every rounding site R1..R14 gets a direction proof against the
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

    /// @dev `adjustTotalAssets(-loss)` as admin; the vault must already be paused.
    function _realizeLoss(uint256 loss) internal {
        vm.prank(admin);
        vault.adjustTotalAssets(-int256(loss));
    }

    /// @dev `adjustTotalAssets(+gain)` as admin; the vault must already be paused.
    function _realizeGain(uint256 gain) internal {
        vm.prank(admin);
        vault.adjustTotalAssets(int256(gain));
    }

    function _realizeInParts(uint256 total, uint256 k, uint256 split) internal {
        uint256[] memory parts = _parts(total, k, split);
        for (uint256 i = 0; i < k; ++i) _realizeLoss(parts[i]);
    }

    function _realizeGainInParts(uint256 total, uint256 k, uint256 split) internal {
        uint256[] memory parts = _parts(total, k, split);
        for (uint256 i = 0; i < k; ++i) _realizeGain(parts[i]);
    }

    /// @dev Sets `chi` directly through storage so a property can be fuzzed at any pair of indexes,
    ///      including ones no sequence of drips and adjustments would land on exactly. Prime vault:
    ///      slot 8, alone (`decimals` and `rho` share slot 7). spUSDC: slot 3, packed after `rho`
    ///      (uint64) at offset 8 bytes. `rho` is kept in both cases.
    function _storeChi(address who, uint256 slot, uint256 offsetBits, uint256 newChi) internal {
        require(newChi < 2 ** 192, "chi does not fit");
        uint256 raw  = uint256(vm.load(who, bytes32(slot)));
        uint256 mask = ((2 ** 192) - 1) << offsetBits;
        vm.store(who, bytes32(slot), bytes32((raw & ~mask) | (newChi << offsetBits)));
    }

    function _setPrimeChi(uint256 newChi) internal {
        _storeChi(address(vault), 8, 0, newChi);
        assertEq(vault.chi(), newChi, "storeChi: prime chi");
        assertEq(vault.nowChi(), newChi, "storeChi: prime nowChi");
    }

    function _setSpUsdcChi(uint256 newChi) internal {
        _storeChi(address(spUsdc), 3, 64, newChi);
        assertEq(spUsdc.chi(), newChi, "storeChi: spUSDC chi");
        assertEq(spUsdc.nowChi(), newChi, "storeChi: spUSDC nowChi");
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
        fresh.grantRole(OPERATOR_ROLE, operator);
        fresh.setVSRBounds(RAY, MAX_VSR);
        vm.stopPrank();
    }

    /**********************************************************************************************/
    /*** R1  requestDeposit:402  spUSDC.deposit  floor(assets * RAY / chi_s)                     ***/
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
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, alice);
    }

    /**********************************************************************************************/
    /*** R2  _processPendingDeposits:829  spUSDC.convertToShares(convertToAssets(capacity))         ***/
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
    /*** R3  _processPendingDeposits:845  spUSDC.convertToAssets  floor(s * chi_s / RAY)            ***/
    /*** R4  _processPendingDeposits:846  convertToShares         floor(assets * RAY / chi_p)       ***/
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
    /*** R5  requestRedeem:453  shares_ >= minRedeem  (minRedeem in SHARES: no rounding)        ***/
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

        // Redeem requests are final (no cancel at 0ebb452); the dead entry is skipped by the
        // planner (`:911` continue) and cannot be repointed (`:513` no-request).
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(id, bob);
        // No spUSDC in the vault: `remaining_ == 0` skips the loop (`:908`) and the dead head is
        // not walked. Dead redeem entries only advance the head once there is liquidity.
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingRedeemId(), 0);
        _deposit(alice, 1_000e6);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingRedeemId(), 1);
    }

    /**********************************************************************************************/
    /*** R6  requestRedeem:460  _divUp(shares * redeemFee, WAD)                                  ***/
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
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(id, alice);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingRedeemId(), 1);  // dead entry skipped, nothing paid
        assertEq(usdc.balanceOf(alice), 0);

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
    /*** R7  _processPendingRedeems:903  convertToShares(availableLiquidAssets())  floor            ***/
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
    /*** R8  _processPendingRedeems:914  convertToAssets(shares)  floor                             ***/
    /*** R9  _processPendingRedeems:922 / _withdrawSavings:952  spUSDC.withdraw(assets)  burns ceil(assets * RAY / chi_s)  ***/
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

        vm.prank(operator);
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
    /*** R10 _processPendingDepositCancellations:888 / _redeemSavings:939  spUSDC.redeem(shares)  floor(s * chi_s / RAY)   ***/
    /***     budget :869-870  min(maxSavingsShares, spUSDC.maxRedeem(vault))                        ***/
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
    /*** R11 drip:637 / nowChi:811  _rpow(vsr, dt) * chi / RAY, _rpow half-up                    ***/
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

            vm.prank(operator);
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
    /*** R12 convertToAssets:793 / convertToShares:797  floor / floor                            ***/
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
    /*** R13 adjustTotalAssets:289  chi = uint192((TA + delta) * RAY / S), delta < 0 (loss)      ***/
    /***     requires :279 paused, :280 delta != 0, :286 TA + delta > 0, :291 chi != 0,         ***/
    /***     :292 chi <= uint192.max; drip() first (:282); S == 0 panics (:289, div by zero)    ***/
    /**********************************************************************************************/

    /// @dev Direction. Two floors, both against holders: TA = floor(S chi / RAY), then
    ///      chi' = floor((TA - L) RAY / S). So S chi' <= (TA - L) RAY and S chi' > (TA - L) RAY - S,
    ///      giving TA' = floor(S chi' / RAY) in [TA - L - ceil(S / RAY), TA - L]. For a 6-decimal
    ///      supply (S < RAY) that is TA' in {TA - L - 1, TA - L}: holders lose at least `loss`
    ///      and at most 1 wei more, and exactly 1 wei more unless S | (TA - L) RAY. In chi units
    ///      the over-reduction is < RAY / S + 1. chi' <= chi always (uint192 cast cannot truncate).
    ///      Round 5: `adjustTotalAssets(-L)` on 0ebb452, admissible range `0 < L < TA`
    ///      (`loss-too-high` at `:286` otherwise), characterisation unchanged.
    function testFuzz_R13_adjustTotalAssets_loss_floorsAgainstHolders_overRealisesAtMostOneWei(
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
    ///      9_594_815_889 (lands chi exactly on RAY); TA itself is rejected (`loss-too-high`).
    function test_R13_adjustTotalAssets_loss_harnessExamples() public {
        _deposit(alice, 1_000_000e6);
        assertEq(vault.totalSupply(),  990_405_184_109);
        assertEq(vault.totalAssets(),  999_999_999_998);
        uint256 chi0 = vault.chi();

        _pause();

        uint256 snapshot = vm.snapshotState();

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.TotalAssetsAdjusted(1009687768240663846587628160, -1);
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
    ///      `TA + delta > 0`: a single-share vault cannot realise any loss. The smallest supply
    ///      that can realise one is S = 2 (TA = 2): loss 1 gives chi = RAY / 2 exactly (2 | RAY),
    ///      totalAssets 1, drop exactly 1.
    function test_R13_adjustTotalAssets_singleShareSupply_noLossIsPossible() public {
        _trimSupplyTo(1);
        assertEq(vault.totalSupply(), 1);
        assertEq(vault.totalAssets(), 1);           // floor(1 * 1.0097) = 1

        _pause();
        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.ZeroDeltaTotalAssets.selector);
        vault.adjustTotalAssets(0);
        for (int256 loss = 1; loss <= 2; ++loss) {
            vm.prank(admin);
            vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
            vault.adjustTotalAssets(-loss);
        }
        assertEq(vault.totalAssets(), 1);
    }

    function test_R13_adjustTotalAssets_twoShareSupply_oneWeiLossHalvesChi() public {
        _trimSupplyTo(2);
        assertEq(vault.totalSupply(), 2);
        assertEq(vault.totalAssets(), 2);

        _pause();
        _realizeLoss(1);

        assertEq(vault.chi(), RAY / 2);
        assertEq(vault.totalAssets(), 1);
        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(-1);                // TA is 1 again: nothing more can be lost
    }

    /// @dev Boundary: `loss >= totalAssets()` reverts `loss-too-high` (`:286`), `loss == 0` reverts
    ///      `delta-total-assets-zero` (`:280`). The largest succeeding loss is `totalAssets() - 1`;
    ///      it leaves chi == floor(RAY / S), which is >= 1 for a 6-decimal supply (S < RAY), and
    ///      totalAssets() in {0, 1}. `chi-too-low` (`:291`) is unreachable while S < RAY (C-3: no
    ///      loss floor, one call wipes the holders down to 1 wei of notional).
    function testFuzz_BUG_C3_adjustTotalAssets_largestLossIsTotalAssetsMinusOne_noFloor(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 supply = vault.totalSupply();
        vm.assume(supply != 0);
        uint256 ta = vault.totalAssets();

        _pause();

        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(-int256(ta + 1));

        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(-int256(ta));

        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.ZeroDeltaTotalAssets.selector);
        vault.adjustTotalAssets(0);

        if (ta == 1) {
            assertEq(supply, 1);                           // TA >= S, so TA == 1 forces S == 1
            return;                                        // no loss is possible (see above)
        }

        _realizeLoss(ta - 1);
        assertEq(vault.chi(), RAY / supply);               // floor(1 * RAY / S) >= 1 as S < RAY
        assertGe(vault.chi(), 1);
        assertEq(vault.totalAssets(), supply * (RAY / supply) / RAY);  // 0 or 1
        assertEq(vault.convertToShares(1), RAY / (RAY / supply));      // no division by zero
        assertEq(vault.assetsOf(alice), vault.totalAssets());          // alice: <= 1 wei left
    }

    /// @dev `chi-too-low` (`:291`) needs `(TA + delta) * RAY < S`, i.e. S > RAY = 1e27 shares
    ///      (1e21 USDC at 6 decimals). Reachable only with such a supply: lose everything but
    ///      1 wei and the quotient floors to 0. With S == RAY exactly, chi lands on 1.
    function test_R13_adjustTotalAssets_chiTooLow_onlyAboveRaySupply() public {
        _setCapacity(type(uint256).max / (2 * vault.nowChi()));
        _deposit(alice, 1.1e27);                    // 1.1e21 USDC
        uint256 supply = vault.totalSupply();
        assertGt(supply, RAY);
        uint256 ta = vault.totalAssets();

        _pause();
        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.ChiTooLow.selector);
        vault.adjustTotalAssets(-int256(ta - 1));

        // TA - delta = ceil(S / RAY) is the smallest surviving notional: chi = 1
        uint256 minTa = _divUp(supply, RAY);
        _realizeLoss(ta - minTa);
        assertEq(vault.chi(), 1);
        assertEq(vault.totalAssets(), supply / RAY);
    }

    /// @dev `totalSupply == 0`: `totalAssets()` is 0, so every loss reverts `loss-too-high` and
    ///      every gain reaches `:289` and panics with a division by zero (the NOTE at `:288`
    ///      assumes it never happens); a gain above C = floor(2^256 / RAY) overflows the product
    ///      first (0x11). A `delta` of 0 is rejected before either.
    function testFuzz_R13_adjustTotalAssets_zeroSupply_lossRevertsGainPanics(int256 delta) public {
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        _pause();

        vm.prank(admin);
        if (delta == 0) {
            vm.expectRevert(ISparkPrimeVault.ZeroDeltaTotalAssets.selector);
        } else if (delta < 0) {
            vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        } else if (uint256(delta) > type(uint256).max / RAY) {
            vm.expectRevert(stdError.arithmeticError);
        } else {
            vm.expectRevert(stdError.divisionError);
        }
        vault.adjustTotalAssets(delta);
    }

    /// @dev `int256` edges: `type(int256).min` is a loss larger than any notional and reverts
    ///      `loss-too-high` (no signed overflow: TA >= 0); `type(int256).max` overflows the signed
    ///      add at `:284` for any TA > 0 (panic 0x11) and is `chi-too-high` at TA == 0 only
    ///      through the division by zero. The largest admissible gain is bounded by the uint256
    ///      product at `:289` long before (see R14).
    function test_R13_adjustTotalAssets_int256Edges() public {
        _deposit(alice, 1_000e6);
        _pause();

        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(type(int256).min);

        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        vault.adjustTotalAssets(type(int256).max);
    }

    /// @dev No truncation on a loss: chi' <= (TA - L) RAY / S <= TA RAY / S <= chi < 2^192, for
    ///      any loss in the admissible range, so the `chi-too-high` check at `:292` never fires
    ///      for `delta < 0`. Checked over random chis up to 10 years at 100% APY (chi ~ 1e30).
    function testFuzz_R13_adjustTotalAssets_loss_castNeverTruncates(
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

    /// @dev Path dependence (V2-12, still open): k losses summing to L never leave MORE than one
    ///      loss of L (floor is monotone and S chi_i / RAY <= TA_{i-1} - l_{i-1}), and at most k
    ///      wei less: 0 <= TA_single - TA_k <= k. In chi units the gap is < k (RAY / S + 1).
    function testFuzz_BUG_V2_12_adjustTotalAssets_loss_sequenceVsSingle_driftsAtMostKWei(
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

    /// @dev V2-12, exact at the harness: each `adjustTotalAssets` call floors once more. 1e6 USDC
    ///      of loss in one call drops totalAssets by 1_000_001 (1 wei of drift); the same loss in
    ///      six calls of 1e6 / 6 (166_666 x 5 + 166_670) drops it by 1_000_006: one wei per call.
    ///      The drift is pure floor, it never favours the holders.
    function test_BUG_V2_12_adjustTotalAssets_oneWeiDriftPerCall_harness() public {
        _deposit(alice, 1_000_000e6);
        uint256 ta = vault.totalAssets();
        assertEq(ta, 999_999_999_998);
        _pause();

        uint256 snapshot = vm.snapshotState();
        _realizeLoss(1_000_000);
        assertEq(ta - vault.totalAssets(), 1_000_001);
        vm.revertToState(snapshot);

        for (uint256 i = 0; i < 5; ++i) _realizeLoss(166_666);
        _realizeLoss(166_670);
        assertEq(ta - vault.totalAssets(), 1_000_006);
    }

    /// @dev Loss then gain of the same amount is not the identity: TA1 in {TA - L - 1, TA - L},
    ///      then TA2 in {TA1 + L - 1, TA1 + L}, so the round trip ends in [TA - 2, TA] and chi''
    ///      <= chi. Fuzzed over random chis and losses; exact harness numbers in the next test.
    function testFuzz_R13_R14_adjustTotalAssets_lossGainRoundTrip_losesAtMostTwoWei(
        uint256 assets, uint256 loss, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 supply = vault.totalSupply();
        vm.assume(supply != 0);
        uint256 ta = vault.totalAssets();
        vm.assume(ta >= 2);
        loss = bound(loss, 1, ta - 1);

        _pause();
        _realizeLoss(loss);
        uint256 ta1 = vault.totalAssets();
        _realizeGain(loss);

        uint256 ta2 = vault.totalAssets();
        assertLe(ta2, ta, "round trip: holders gained");
        assertLe(ta - ta2, 2, "round trip: lost more than 2 wei");
        assertLe(vault.chi(), chiP, "round trip: chi grew");
        assertEq(ta - ta2, (ta - ta1 - loss) + (ta1 + loss - ta2), "round trip: drift is the two floors");
    }

    /// @dev Harness, 1_000_000e6 deposited (TA = 999_999_999_998, S = 990_405_184_109): loss 1
    ///      drops TA to 999_999_999_996 (chi 1009687768242461209408770821 ->
    ///      1009687768240663846587628160); gain 1 then recomputes floor((999_999_999_997) RAY / S),
    ///      the very same chi: the gain is absorbed entirely by the floor, 2 wei lost in total.
    ///      Loss 999_999_999 then gain 999_999_999 ends at 999_999_999_996 as well. The exact-drop
    ///      loss TA - S round-trips to 999_999_999_997: 1 wei lost (only the gain floors).
    function test_R13_R14_adjustTotalAssets_lossGainRoundTrip_harnessExact() public {
        _deposit(alice, 1_000_000e6);
        uint256 chi0 = vault.chi();
        assertEq(chi0, 1009687768242461209408770821);
        _pause();

        uint256 snapshot = vm.snapshotState();

        _realizeLoss(1);
        assertEq(vault.chi(), 1009687768240663846587628160);
        _realizeGain(1);
        assertEq(vault.chi(), 1009687768240663846587628160);          // unchanged by the gain
        assertEq(vault.totalAssets(), 999_999_999_996);
        assertLt(vault.chi(), chi0);
        vm.revertToState(snapshot);

        _realizeLoss(999_999_999);
        _realizeGain(999_999_999);
        assertEq(vault.totalAssets(), 999_999_999_996);
        vm.revertToState(snapshot);

        _realizeLoss(999_999_999_998 - 990_405_184_109);
        assertEq(vault.chi(), RAY);
        _realizeGain(999_999_999_998 - 990_405_184_109);
        assertEq(vault.totalAssets(), 999_999_999_997);
    }

    /// @dev Consequence for R8/R12: after a loss chi can be below RAY, so `convertToAssets(s) >= s`
    ///      no longer holds and a small redeem pays floor(s c_p) == 0 while the shares are burned.
    ///      Harness: lose all but 1 wei of a 1_000_000e6 position, chi ~ 1e15; redeeming 1e9 shares
    ///      pays 0 USDC (and burns 0 spUSDC: `withdraw(0)`). The region is exact: any
    ///      `s < ceil(RAY / chi)` pays 0; `s = ceil(RAY / chi)` = 990_405_184_110 pays 1 wei.
    function test_R13_afterLoss_chiBelowRay_smallRedeemPaysZero() public {
        _deposit(alice, 1_000_000e6);
        uint256 ta = vault.totalAssets();

        _pause();
        _realizeLoss(ta - 1);
        _unpause();

        uint256 chi = vault.chi();
        assertLt(chi, RAY);
        assertEq(chi, 1_009_687_768_243_692);                         // floor(RAY / S)
        assertEq(vault.convertToAssets(1e9), 0);
        uint256 sMin = _divUp(RAY, chi);
        assertEq(sMin, 990_405_184_110);                              // S + 1
        assertEq(vault.convertToAssets(sMin - 1), 0);
        assertEq(vault.convertToAssets(sMin),     1);
        assertGt(sMin, vault.totalSupply());        // nobody holds enough shares to be paid 1 wei

        uint256 spBefore = _vaultSpUsdc();
        _requestRedeem(alice, 1e9);
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.balanceOf(alice), 990_405_184_109 - 1e9);
        assertEq(vault.totalSupply(),    990_405_184_109 - 1e9);
        assertEq(_vaultSpUsdc(), spBefore);
    }

    /// @dev Fuzzed form of the zero-payout region after a loss: for any chi < RAY a redeem of
    ///      `s < ceil(RAY / chi)` shares burns the shares and pays 0, and one of exactly
    ///      `ceil(RAY / chi)` pays 1 wei. Both the shares and the fee are gone for nothing.
    function testFuzz_R13_afterLoss_zeroPayoutRegion_isExact(uint256 loss, uint256 s, uint256 vsrS, uint256 secs)
        public
    {
        _randomChis(vsrS, RAY, secs);
        _deposit(alice, 1_000_000e6);
        uint256 ta = vault.totalAssets();
        uint256 supply = vault.totalSupply();
        loss = bound(loss, ta - supply + 1, ta - 1);   // chi lands strictly below RAY
        _pause();
        _realizeLoss(loss);
        _unpause();
        uint256 chi = vault.chi();
        assertLt(chi, RAY);

        uint256 sMin = _divUp(RAY, chi);
        assertGe(sMin, 2);
        assertEq(vault.convertToAssets(sMin - 1), 0);
        assertEq(vault.convertToAssets(sMin),     1);

        s = bound(s, 1, sMin - 1);
        if (s > supply) return;

        uint256 spBefore = _vaultSpUsdc();
        _requestRedeem(alice, s);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 0, "paid for a redeem below the zero region");
        assertEq(vault.totalSupply(), supply - s);
        assertEq(_vaultSpUsdc(), spBefore);
    }

    /**********************************************************************************************/
    /*** R14 adjustTotalAssets:289  chi = uint192((TA + delta) * RAY / S), delta > 0 (gain)      ***/
    /***     same requires; :292 `chi-too-high` now rejects a uint192 wrap (fixed, was a BUG)    ***/
    /**********************************************************************************************/

    /// @dev Direction. The same two floors as R13, again against holders: TA = floor(S chi / RAY),
    ///      chi' = floor((TA + G) RAY / S). S chi' <= (TA + G) RAY gives TA' <= TA + G and
    ///      S chi' > (TA + G) RAY - S gives TA' >= TA + G - ceil(S / RAY). For S < RAY:
    ///      TA' in {TA + G - 1, TA + G}, exactly TA + G iff S | (TA + G) RAY. In chi units the
    ///      credit is <= the exact G RAY / S and less than RAY / S + 1 units short. chi' >= chi for
    ///      every G >= 1 because (TA + 1) RAY > S chi.
    function testFuzz_R14_adjustTotalAssets_gain_floorsAgainstHolders_underCreditsAtMostOneWei(
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

        _pause();
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
    function test_R14_adjustTotalAssets_gain_harnessExamples() public {
        _deposit(alice, 1_000_000e6);
        assertEq(vault.totalSupply(), 990_405_184_109);
        assertEq(vault.totalAssets(), 999_999_999_998);
        uint256 chi0 = vault.chi();
        _pause();

        uint256 snapshot = vm.snapshotState();

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.TotalAssetsAdjusted(1009687768242683222124115546, 1);
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

    /// @dev R3-1 fixed: `adjustTotalAssets` requires `paused` (`:279`), and while paused
    ///      `requestDeposit` / `requestRedeem` / the three planners revert `paused`, so no request
    ///      can be placed between the adjustment and the next block. `drip()` runs first (`:282`):
    ///      365 days at 5% un-dripped, then gain 1 while paused: chi is
    ///      floor((TA_accrued + 1) RAY / S) with TA_accrued from `nowChi()` before the call, and
    ///      rho moves to now. Not admin: AccessControl revert.
    function test_fixed_R3_1_adjustTotalAssets_requiresPause_dripsFirst() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply = vault.totalSupply();

        _setPrimeVsr(FIVE_PCT_VSR);
        _warp(365 days);
        uint256 taAccrued = vault.totalAssets();                      // via nowChi(), not dripped
        assertGt(taAccrued, 999_999_999_998);

        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(1);

        _pause();
        _realizeGain(1);
        assertEq(vault.chi(), (taAccrued + 1) * RAY / supply);
        assertEq(vault.rho(), block.timestamp);

        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDeposit(1e6, bob, 0);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestRedeem(1, alice);
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);

        vm.prank(redeemFeeSetter);
        vm.expectRevert();
        vault.adjustTotalAssets(1);                                   // DEFAULT_ADMIN_ROLE only
    }

    /// @dev R3-1 residual, quantified: the pause is a separate GUARDIAN tx, so a deposit landing
    ///      between "gain public" and "pause" still captures its pro-rata share of the gain. Harness:
    ///      alice 1_000_000e6, bob 1_000_000e6 one block before the pause, gain 50_000e6 (5%):
    ///      the vault realises 49_999_999_999 (R14 floor) and bob's notional rises by exactly
    ///      25_000_000_000, half the nominal gain (each `assetsOf` floors on its own, so the two
    ///      halves sum to 1 wei more than `totalAssets()` moved). A bob who deposits after the
    ///      unpause gets 0 of it: the window is the gap between the public payload and `pause()`.
    function test_R3_1_depositBeforePause_capturesProRataGain_quantified() public {
        _deposit(alice, 1_000_000e6);
        _deposit(bob,   1_000_000e6);
        uint256 bobBefore = vault.assetsOf(bob);
        uint256 taBefore  = vault.totalAssets();

        _pause();
        _realizeGain(50_000e6);
        _unpause();

        uint256 realised = vault.totalAssets() - taBefore;
        assertEq(realised, 49_999_999_999);                            // gain - 1 (R14 floor)
        assertEq(vault.assetsOf(bob) - bobBefore, 25_000_000_000);
        assertEq(vault.assetsOf(alice) - bobBefore, 25_000_000_000);
        assertEq(vault.balanceOf(alice), vault.balanceOf(bob));

        uint256 taAfter = vault.totalAssets();
        _deposit(makeAddr("late"), 1_000_000e6);
        assertEq(vault.assetsOf(makeAddr("late")), 999_999_999_998);  // no share of the gain (one more floor at the higher chi)
        assertEq(vault.totalAssets() - taAfter, 999_999_999_999);
    }

    function test_R14_adjustTotalAssets_zeroDelta_reverts() public {
        _deposit(alice, 1_000e6);
        _pause();
        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.ZeroDeltaTotalAssets.selector);
        vault.adjustTotalAssets(0);
    }

    /// @dev Path dependence: k gains summing to G credit no more than one gain of G
    ///      (TA_{i} <= TA_{i-1} + g_i, so TA_{k-1} + g_k <= TA + G and the floor is monotone) and at
    ///      most k wei less: 0 <= TA_single - TA_k <= k, (chi_single - chi_k) S < k (RAY + S). One
    ///      aggregated gain is better for holders than a stream of small ones.
    function testFuzz_BUG_V2_12_adjustTotalAssets_gain_sequenceVsSingle_driftsAtMostKWei(
        uint256 assets, uint256 total, uint256 k, uint256 split, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        k      = bound(k, 2, 6);
        _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 supply = vault.totalSupply();
        vm.assume(supply != 0);
        total = bound(total, k, 1e24);
        _pause();

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
    ///        G_trunc = ceil(2^192 S / RAY) - TA         smallest gain rejected `chi-too-high`
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

    /// @dev uint256: `(TA + G) * RAY` overflows (panic 0x11) iff TA + G > C, i.e. G > G_ovf. At
    ///      G_ovf the product fits but the quotient is >= 2^192: `chi-too-high`.
    function testFuzz_R14_adjustTotalAssets_uint256OverflowThreshold(
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
        _pause();

        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        vault.adjustTotalAssets(int256(gOvf + 1));

        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.ChiTooHigh.selector);
        vault.adjustTotalAssets(int256(gOvf));
    }

    /// @dev FIXED (was `test_BUG_realizeGain_uint192TruncationCollapsesChi`): for G < G_trunc the
    ///      quotient is < 2^192 and chi stores it exactly; at G_trunc and above the call reverts
    ///      `chi-too-high` (`:292`) instead of wrapping. The harness gain that used to collapse chi
    ///      to ~RAY (quotient 2^192 + RAY + 458_233_707_431_279) is rejected.
    function testFuzz_fixed_adjustTotalAssets_uint192WrapRevertsChiTooHigh(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 supply = vault.totalSupply();
        vm.assume(supply != 0);
        uint256 ta = vault.totalAssets();

        (, uint256 gTrunc,) = _gainThresholds(supply, ta);
        _pause();

        uint256 snapshot = vm.snapshotState();

        uint256 wide = (ta + gTrunc - 1) * RAY / supply;
        assertLt(wide, 2 ** 192);
        _realizeGain(gTrunc - 1);
        assertEq(uint256(vault.chi()), wide);
        vm.revertToState(snapshot);

        wide = (ta + gTrunc) * RAY / supply;
        assertGe(wide, 2 ** 192);
        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.ChiTooHigh.selector);
        vault.adjustTotalAssets(int256(gTrunc));
        assertEq(uint256(vault.chi()), vault.nowChi());
    }

    function test_fixed_adjustTotalAssets_uint192WrapRevertsChiTooHigh_harness() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply = vault.totalSupply();
        uint256 ta     = vault.totalAssets();

        uint256 gain = _divUp((2 ** 192 + RAY) * supply, RAY) - ta;
        assertEq(gain, 6_216_874_099_906_568_962_213_193_772_735_334_179_364_221);
        assertEq((ta + gain) * RAY / supply - 2 ** 192, 1_000_000_000_000_458_233_707_431_279);

        _pause();
        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.ChiTooHigh.selector);
        vault.adjustTotalAssets(int256(gain));
        assertEq(vault.totalAssets(), ta);
    }

    /// @dev BUG G-1/G-2 (open) · Low (admin only). `drip()` computes `_rpow(vsr, dt) * chi`, which
    ///      must stay below 2^256: chi <= floor((2^256 - 1) / rpow). At VSR == RAY that is
    ///      chi <= C ~ 1.158e50 for any dt. G_drip is the largest gain keeping chi <= C; one more
    ///      wei pushes chi over it and every call that drips (deposits, redeems, queue processing,
    ///      setVSR, adjustTotalAssets, nowChi-based views) panics as soon as block.timestamp > rho.
    ///      `adjustTotalAssets` drips first (`:282`), so it cannot undo it: only an upgrade
    ///      recovers. The `uint192` bound at `:292` (6.3e57) is 5.4e7 times too loose to prevent
    ///      it. Deposits die earlier through CAP-1: `availableCapacity() * chi` overflows once
    ///      chi > type(uint256).max / availableCapacity() (3.4e38 at the harness cap).
    function testFuzz_BUG_G1_adjustTotalAssets_dripOverflowThreshold_exact(
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
        _pause();

        uint256 snapshot = vm.snapshotState();

        _realizeGain(gDrip);
        assertLe(uint256(vault.chi()), c);
        _unpause();
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
        assertLe(uint256(vault.chi()), type(uint192).max);             // the :292 bound admits it
        _warp(dt);

        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
        vm.expectRevert(stdError.arithmeticError);
        vault.nowChi();
        vm.expectRevert(stdError.arithmeticError);
        vault.totalAssets();

        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        vault.adjustTotalAssets(-1);                                   // drip() first: cannot undo
        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        vault.adjustTotalAssets(1);
        vm.prank(operator);
        vm.expectRevert(stdError.arithmeticError);
        vault.setVSR(RAY);

        _unpause();
        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(1e6, bob, 0);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestRedeem(1, alice);
        vm.prank(operator);
        vm.expectRevert(stdError.arithmeticError);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);
    }

    /// @dev Harness numbers for the drip threshold, and the VSR dependence: the same G_drip that is
    ///      safe forever at VSR == RAY bricks the vault 1 second after the VSR is raised, because
    ///      the bound is chi <= (2^256 - 1) / rpow(vsr, dt) and rpow(MAX_VSR, 1) > RAY.
    function test_BUG_G1_adjustTotalAssets_dripOverflow_oneWeiBricks_thresholdShrinksWithVsr() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply = vault.totalSupply();
        uint256 ta     = vault.totalAssets();

        (uint256 gDrip, uint256 gTrunc, uint256 gOvf) = _gainThresholds(supply, ta);
        assertEq(gDrip,  114_681_085_459_449_903_921_528_244_645_760_028);
        assertEq(gTrunc, 6_216_874_099_906_568_962_213_193_772_734_343_774_180_112);
        assertEq(gOvf,   115_792_089_237_316_195_423_570_985_008_687_907_852_269_984_665_642);
        _pause();

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

    /// @dev The exact smallest `chi` that reverts `drip()` at VSR == RAY is C + 1 =
    ///      115792089237316195423570985008687907853269984665641 (chi * RAY is the first product
    ///      past 2^256 - 1); C itself drips for any dt. Set through storage so the value is exact
    ///      (an `adjustTotalAssets` lands on a multiple-free quotient, e.g. gDrip + 1 above gives
    ///      C + 664_435_247_753_226). At MAX_VSR the smallest reverting chi after 1 second is
    ///      floor((2^256 - 1) / MAX_VSR) + 1 = 115792086692257871478197290620423733568884919991398 + 1.
    function test_BUG_G1_drip_smallestRevertingChi_exact() public {
        uint256 c = type(uint256).max / RAY;
        assertEq(c, 115792089237316195423570985008687907853269984665640);
        assertLt(c, type(uint192).max);

        _setPrimeChi(c);
        _warp(TEN_YEARS);
        assertEq(vault.drip(), c);

        _setPrimeChi(c + 1);
        _warp(1);
        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
        vm.expectRevert(stdError.arithmeticError);
        vault.nowChi();

        uint256 cMax = type(uint256).max / MAX_VSR;
        assertEq(cMax, 115792086692257871478197290620423733568884919991398);
        _setPrimeChi(cMax);
        _setPrimeVsr(MAX_VSR);                                         // drips at dt == 0
        _warp(1);
        assertEq(vault.drip(), cMax * MAX_VSR / RAY);
        _setPrimeChi(cMax + 1);
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
        vault.requestDeposit(1e6, bob, 0);

        vm.prank(operator);
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
        vault.requestDeposit(1e6, bob, 0);

        _setCapacity(limit1 + vault.totalSupply());
        vm.prank(bob);
        vault.requestDeposit(1e6, bob, 0);
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

    /// @dev Round 4 (new idea): after a loss `chi_p < RAY`, so `convertToShares` mints more
    ///      shares than USDC wei. The capacity chain `:829` still cannot over-mint: with
    ///      `A = floor(cap chi_p / RAY)`, `s = floor(A RAY / chi_s)`, a fill of `s` pays
    ///      `a = floor(s chi_s / RAY) <= A` and mints `floor(a RAY / chi_p) <= floor(A RAY / chi_p)
    ///      <= cap`. Fuzzed over losses down to `chi = floor(RAY / S)`: the instant fill and a
    ///      follow-up planner call keep `totalSupply <= maxCapacity`, and the minted amount is
    ///      exactly the two-floor composition of `min(request, remaining)`.
    function testFuzz_capacity_afterLoss_chiBelowRay_neverOverMints(
        uint256 loss, uint256 cap, uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        _randomChis(vsrS, vsrP, secs);
        _deposit(alice, 1_000_000e6);

        uint256 ta = vault.totalAssets();
        loss = bound(loss, 1, ta - 1);
        _pause();
        _realizeLoss(loss);
        _unpause();
        uint256 chiP = vault.chi();
        assertEq(vault.nowChi(), chiP);

        cap    = bound(cap, 0, 1e12);
        assets = bound(assets, 1, 4e15);
        uint256 supply = vault.totalSupply();
        _setCapacity(supply + cap);

        uint256 remaining = spUsdc.convertToShares(vault.convertToAssets(cap));
        uint256 queued    = spUsdc.convertToShares(assets);
        uint256 s         = queued < remaining ? queued : remaining;
        uint256 a         = s * spUsdc.chi() / RAY;
        uint256 expected  = a * RAY / chiP;

        uint256 id = _deposit(bob, assets);

        assertEq(vault.balanceOf(bob), expected, "fill is the two-floor composition");
        assertLe(vault.totalSupply(), supply + cap, "instant fill over capacity");
        if (chiP < RAY && a != 0) assertGe(expected, a, "chi < RAY: shares >= assets");

        _processDeposits(type(uint256).max, 1);
        assertLe(vault.totalSupply(), supply + cap, "planner fill over capacity");
        assertLe(_depositShares(id), queued - s, "planner undid the instant fill");
    }

    /// @dev Round 4: a severe loss shrinks what one share of capacity is worth. At the largest
    ///      admissible loss (`TA - 1`, chi = floor(RAY / S) ~ 1.0097e15) a headroom below
    ///      `RAY / chi` ~ 9.9e11 shares (about the whole supply) converts to 0 USDC (`:829`), so
    ///      no deposit can be filled until the admin raises capacity by more than that; the
    ///      deposit is queued and the planner loop is skipped.
    ///      At a 50% loss 1 share of headroom is worth 0 USDC and 2 shares worth 1 wei, which
    ///      spUSDC turns into 0 shares: the smallest fillable headroom is 3 shares (1 spUSDC share
    ///      -> 1 USDC wei -> 2 spPRIME shares). No over-mint in either case.
    function test_capacity_afterLoss_headroomBelowOneUsdcWeiIsUnfillable() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply = vault.totalSupply();
        uint256 ta     = vault.totalAssets();

        // Loss leaving 45% of the supply in assets: chi ~ 0.45e27 (one floor below)
        _pause();
        _realizeLoss(ta - supply * 45 / 100);
        _unpause();
        uint256 chiHalf = vault.chi();
        assertLt(chiHalf, 0.45e27 + 1);
        assertGt(chiHalf, 0.45e27 - RAY / supply - 1);

        assertEq(vault.convertToAssets(1), 0);
        assertEq(vault.convertToAssets(2), 0);
        assertEq(vault.convertToAssets(3), 1);
        assertEq(spUsdc.convertToShares(1), 0);

        _setCapacity(supply + 2);
        uint256 id = _deposit(bob, 1_000e6);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.totalSupply(),  supply);
        assertEq(vault.firstPendingDepositId(), 1);  // head on bob's entry, nothing fillable

        // 3 shares of headroom: A = 1, s = 0 still (1 USDC wei < c_s). Need A >= ceil(c_s) = 2:
        // cap with floor(cap * chi / RAY) = 2 -> cap = 5 (5 * 0.45 = 2.25).
        _setCapacity(supply + 3);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(bob), 0);
        _setCapacity(supply + 5);
        assertEq(vault.convertToAssets(5), 2);
        assertEq(spUsdc.convertToShares(2), 1);
        _processDeposits(type(uint256).max, 1);
        assertEq(_depositShares(id), spUsdc.convertToShares(1_000e6) - 1);
        // 1 spUSDC share -> 1 USDC wei -> floor(RAY / chi) = 2 spPRIME shares
        assertEq(vault.balanceOf(bob), RAY / chiHalf);
        assertEq(vault.balanceOf(bob), 2);
        assertLe(vault.totalSupply(), supply + 5);

        // Largest loss: chi = floor(RAY / S) ~ 1.0097e15. 9e11 shares of headroom (about the
        // whole supply) are worth 0 USDC wei; RAY / chi + 1 shares are worth 1 wei.
        _pause();
        _realizeLoss(vault.totalAssets() - 1);
        _unpause();
        uint256 chiMin = vault.chi();
        assertEq(chiMin, RAY / vault.totalSupply());
        assertEq(chiMin, 1_009_687_768_241_653);  // S = SH_1M + 2 = 990_405_184_111
        assertEq(vault.convertToAssets(9e11), 0);
        _setCapacity(vault.totalSupply() + 9e11);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(bob), 2);  // nothing moved
        assertEq(vault.convertToAssets(RAY / chiMin), 0);
        assertEq(vault.convertToAssets(RAY / chiMin + 1), 1);
        assertGe(RAY / chiMin, vault.totalSupply());  // one share of capacity per share of supply
    }

    /// @dev Round 4: F-4's zero-mint region is empty once `chi_p <= RAY`: `K = (chi_p - 1) / RAY
    ///      = 0`, `sMax = ceil(RAY / chi_s) - 1 = 0` for `chi_s > RAY`. A 1-share fill then mints
    ///      `floor(RAY / chi_p) >= 1`, so the DQ-1 dust head (1 spUSDC share) becomes fillable
    ///      and no spUSDC is burnt for nothing after a loss.
    function testFuzz_F4_afterLoss_zeroMintRegionIsEmpty(uint256 loss, uint256 vsrS, uint256 secs)
        public
    {
        _randomChis(vsrS, RAY, secs);
        _deposit(alice, 1_000_000e6);
        uint256 ta = vault.totalAssets();
        loss = bound(loss, ta - vault.totalSupply(), ta - 1);  // chi lands at or below RAY
        _pause();
        _realizeLoss(loss);
        _unpause();
        uint256 chiP = vault.chi();
        assertLe(chiP, RAY);

        assertEq(_zeroMintMax(spUsdc.chi(), chiP), 0);
        assertGe(spUsdc.convertToAssets(1), 1);
        assertGe(vault.convertToShares(spUsdc.convertToAssets(1)), 1, "1 spUSDC share mints 0");
        assertEq(vault.convertToShares(1), RAY / chiP);
        assertGe(vault.convertToShares(1), 1);
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
    /*** Round 5 attacks (a): C-1 on 0ebb452, minimal reproduction and exact shortfall           ***/
    /***     clamp :903  convertToShares(maxWithdraw)  once per call, in spPRIME shares           ***/
    /***     burn  :922/:952  withdraw(assets)  ceil(assets RAY / chi_s) spUSDC per fill          ***/
    /**********************************************************************************************/

    /// @dev Predicted spUSDC burn of a fill of `s` spPRIME shares: ceil(floor(s chi_p / RAY) RAY / chi_s).
    function _ceilBurn(uint256 s, uint256 chiS, uint256 chiP) internal pure returns (uint256) {
        return _divUp((s * chiP / RAY) * RAY, chiS);
    }

    /// @dev Smallest spUSDC balance at the harness chis for which a two-entry batch reverts:
    ///      3401 spUSDC (maxWithdraw 3563 USDC, clamp 3528 shares). Requests 108 + 3420 = 3528
    ///      pay 109 + 3453 USDC and burn 105 + 3297 = 3402 spUSDC: 1 share short. Found by brute
    ///      force over every balance below 3401 and every split (no smaller balance reverts,
    ///      because the two floors in the clamp leave >= 2 USDC of slack until then).
    ///      Asserts the intended behaviour (both paid) and FAILS with
    ///      `SparkVault/insufficient-balance` (`:416` of the spUSDC code).
    function test_BUG_C1_batchRedeem_minimalReproduction_3401_shortfall1() public {
        _deposit(alice, 1_000_000e6);
        _take(_vaultSpUsdc() - 3401);
        assertEq(_vaultSpUsdc(), 3401);
        assertEq(spUsdc.maxWithdraw(address(vault)), 3563);
        assertEq(vault.convertToShares(3563), 3528);

        uint256 chiS = spUsdc.chi();
        uint256 chiP = vault.chi();
        assertEq(_ceilBurn(108, chiS, chiP),  105);
        assertEq(_ceilBurn(3420, chiS, chiP), 3297);
        assertEq(uint256(105 + 3297), 3402);                           // > 3401 by exactly 1

        uint256 id1 = _requestRedeem(alice, 108);
        uint256 id2 = _requestRedeem(alice, 3420);

        _processRedeems(type(uint256).max, 2);  // reverts: SparkVault/insufficient-balance

        assertEq(_redeemShares(id1), 0);
        assertEq(_redeemShares(id2), 0);
        assertEq(usdc.balanceOf(alice), 109 + 3453);
    }

    /// @dev Same state, `expectRevert` form (passes): the batch reverts, one request per call
    ///      works because the clamp is recomputed from the reduced balance: 108 pays 109 and burns
    ///      105; then maxWithdraw = floor(3296 c_s) = 3452 -> clamp 3418 of the 3420 requested,
    ///      pays 3451, burns 3295: the vault ends with 1 spUSDC share and 2 shares queued until
    ///      the taker returns spUSDC (the next call's clamp is floor(floor(1.0476) / c_p) = 1).
    function test_BUG_C1_batchRedeem_minimalReproduction_expectRevert_thenOneByOne() public {
        _deposit(alice, 1_000_000e6);
        _take(_vaultSpUsdc() - 3401);

        uint256 id1 = _requestRedeem(alice, 108);
        uint256 id2 = _requestRedeem(alice, 3420);

        vm.prank(operator);
        vm.expectRevert("SparkVault/insufficient-balance");
        vault.processPendingRedeems(type(uint256).max, 2);

        _processRedeems(type(uint256).max, 1);
        assertEq(_redeemShares(id1), 0);
        assertEq(_vaultSpUsdc(), 3401 - 105);
        assertEq(usdc.balanceOf(alice), 109);

        assertEq(spUsdc.maxWithdraw(address(vault)), 3452);
        assertEq(vault.convertToShares(3452), 3418);
        _processRedeems(type(uint256).max, 1);
        assertEq(_redeemShares(id2), 2);
        assertEq(_vaultSpUsdc(), 1);
        assertEq(usdc.balanceOf(alice), 109 + 3451);
        assertEq(vault.pendingRedeemShares(), 2);

        // the last share: maxWithdraw floor(1.0476) = 1 -> clamp 0: nothing more can be paid
        assertEq(spUsdc.maxWithdraw(address(vault)), 1);
        assertEq(vault.convertToShares(1), 0);
        _processRedeems(type(uint256).max, 1);
        assertEq(_redeemShares(id2), 2);
    }

    /// @dev Three entries can be 2 short: 13625 spUSDC (maxWithdraw 14274, clamp 14137), requests
    ///      7036 + 6840 + 261 burn 6782 + 6593 + 252 = 13627.
    function test_BUG_C1_batchRedeem_threeEntries_shortfall2() public {
        _deposit(alice, 1_000_000e6);
        _take(_vaultSpUsdc() - 13625);
        assertEq(spUsdc.maxWithdraw(address(vault)), 14274);
        assertEq(vault.convertToShares(14274), 14137);

        _requestRedeem(alice, 7036);
        _requestRedeem(alice, 6840);
        _requestRedeem(alice, 261);

        uint256 chiS = spUsdc.chi();
        uint256 chiP = vault.chi();
        assertEq(_ceilBurn(7036, chiS, chiP) + _ceilBurn(6840, chiS, chiP) + _ceilBurn(261, chiS, chiP), 13627);

        vm.prank(operator);
        vm.expectRevert("SparkVault/insufficient-balance");
        vault.processPendingRedeems(type(uint256).max, 3);

        // the first two alone burn 13375 <= 13625: the third entry is what tips it
        _processRedeems(type(uint256).max, 2);
        assertEq(_vaultSpUsdc(), 13625 - 6782 - 6593);
    }

    /// @dev General form, arbitrary indexes (chi_s in [RAY, 10 RAY], chi_p in [RAY/1000, 10 RAY]
    ///      through storage), n in [2, 4] entries splitting exactly the clamp: the batch reverts
    ///      iff the sum of the per-fill ceil burns exceeds the vault's spUSDC balance, and the
    ///      shortfall is at most n - 1 shares (each ceil adds < 1). With one entry it never
    ///      reverts: ceil(paid / c_s) <= ceil(maxWithdraw / c_s) <= bal.
    function testFuzz_BUG_C1_batchRedeem_revertIffCeilBurnsExceedBalance_shortfallAtMostNMinusOne(
        uint256 chiS, uint256 chiP, uint256 bal, uint256 n, uint256 split
    ) public {
        chiS = bound(chiS, RAY, 10 * RAY);
        chiP = bound(chiP, RAY / 1000, 10 * RAY);
        n    = bound(n, 2, 4);
        bal  = bound(bal, 1, 1e9);

        _setPrimeChi(chiP);
        _setSpUsdcChi(chiS);
        _deposit(alice, 1e15);                                          // enough shares and spUSDC
        _returnSpUsdcLiquidity(spUsdc.totalAssets());                   // liquidity never binds
        _take(_vaultSpUsdc() - bal);
        assertEq(_vaultSpUsdc(), bal);

        uint256 maxWithdraw = spUsdc.maxWithdraw(address(vault));
        assertEq(maxWithdraw, bal * chiS / RAY);
        uint256 clamp = vault.convertToShares(maxWithdraw);
        vm.assume(clamp >= n && clamp <= vault.balanceOf(alice));

        uint256[] memory parts = _parts(clamp, n, split);
        uint256 burns;
        for (uint256 i = 0; i < n; ++i) {
            _requestRedeem(alice, parts[i]);
            burns += _ceilBurn(parts[i], chiS, chiP);
        }

        if (burns > bal) {
            assertLe(burns - bal, n - 1, "C-1: shortfall exceeds n - 1");
            vm.prank(operator);
            vm.expectRevert("SparkVault/insufficient-balance");
            vault.processPendingRedeems(type(uint256).max, n);
        } else {
            _processRedeems(type(uint256).max, n);
            assertEq(_vaultSpUsdc(), bal - burns);
            assertEq(vault.pendingRedeemShares(), 0);
        }
    }

    /// @dev C-1 needs `chi_s > RAY`: at chi_s == RAY `withdraw` burns exactly `paid` spUSDC and
    ///      sum paid_i <= floor(clamp c_p) <= maxWithdraw = bal, so no batch size reverts.
    function testFuzz_C1_chiSEqualsRay_batchNeverReverts(uint256 chiP, uint256 bal, uint256 n, uint256 split)
        public
    {
        chiP = bound(chiP, RAY / 1000, 10 * RAY);
        n    = bound(n, 2, 6);
        bal  = bound(bal, 1, 1e9);

        _setPrimeChi(chiP);
        _setSpUsdcChi(RAY);
        _deposit(alice, 1e15);
        _returnSpUsdcLiquidity(spUsdc.totalAssets());
        _take(_vaultSpUsdc() - bal);

        uint256 clamp = vault.convertToShares(spUsdc.maxWithdraw(address(vault)));
        vm.assume(clamp >= n && clamp <= vault.balanceOf(alice));

        uint256[] memory parts = _parts(clamp, n, split);
        uint256 paid;
        for (uint256 i = 0; i < n; ++i) {
            _requestRedeem(alice, parts[i]);
            paid += parts[i] * chiP / RAY;
        }
        _processRedeems(type(uint256).max, n);                          // never reverts
        assertEq(_vaultSpUsdc(), bal - paid);
        assertLe(paid, bal);
    }

    /**********************************************************************************************/
    /*** Round 5 attacks (b): capacity over-mint at arbitrary index pairs                        ***/
    /**********************************************************************************************/

    /// @dev Instant fill at any (chi_s, chi_p) pair, chi_p above or below RAY, capacity in
    ///      [1, 1e12] shares: `totalSupply <= maxCapacity` and the mint equals the two-floor
    ///      composition of min(requested, admitted) exactly. No pair over-mints by even 1 share.
    function testFuzz_capacity_arbitraryIndexes_instantFill_neverOverMints(
        uint256 chiS, uint256 chiP, uint256 cap, uint256 assets
    ) public {
        chiS   = bound(chiS, RAY, 10 * RAY);
        chiP   = bound(chiP, RAY / 1000, 10 * RAY);
        cap    = bound(cap, 1, 1e12);
        assets = bound(assets, 1, 1e16);

        _setPrimeChi(chiP);
        _setSpUsdcChi(chiS);
        _setCapacity(cap);

        uint256 admitted  = spUsdc.convertToShares(vault.convertToAssets(cap));
        uint256 requested = assets * RAY / chiS;
        uint256 s         = requested < admitted ? requested : admitted;
        uint256 expected  = (s * chiS / RAY) * RAY / chiP;

        uint256 id = _deposit(alice, assets);

        assertEq(vault.balanceOf(alice), expected, "mint is the two-floor composition");
        assertLe(vault.totalSupply(), cap, "instant fill over capacity");
        assertEq(vault.totalSupply(), expected);
        assertEq(_depositShares(id), requested - s);
        assertEq(vault.pendingDepositSavingsShares(), requested - s);
    }

    /// @dev FIFO fills of two queued entries against the spUSDC-share budget of `cap`, each mint
    ///      the two-floor composition of its slice.
    function _expectedBatchMints(uint256 s1, uint256 s2, uint256 chiS, uint256 chiP, uint256 cap)
        internal view returns (uint256 m1, uint256 m2)
    {
        uint256 admitted = spUsdc.convertToShares(vault.convertToAssets(cap));
        uint256 f1 = s1 < admitted ? s1 : admitted;
        uint256 f2 = s2 < admitted - f1 ? s2 : admitted - f1;
        m1 = (f1 * chiS / RAY) * RAY / chiP;
        m2 = (f2 * chiS / RAY) * RAY / chiP;
    }

    /// @dev Batch fill: two queued entries, capacity raised, one planner call with maxRequests 2.
    ///      The budget `remaining_` is fixed once at `:827-830` in spUSDC shares and each fill
    ///      converts its own slice, so the sum of the two mints is floor(a1 / c_p) + floor(a2 / c_p)
    ///      <= floor((a1 + a2) / c_p) <= cap. Never over-mints at any pair.
    function testFuzz_capacity_arbitraryIndexes_batchFill_neverOverMints(
        uint256 chiS, uint256 chiP, uint256 cap, uint256 a1, uint256 a2
    ) public {
        chiS = bound(chiS, RAY, 10 * RAY);
        chiP = bound(chiP, RAY / 1000, 10 * RAY);
        cap  = bound(cap, 1, 1e12);
        a1   = bound(a1, 1, 1e16);
        a2   = bound(a2, 1, 1e16);

        _setCapacity(0);
        uint256 s1 = _depositShares(_deposit(alice, a1));
        uint256 s2 = _depositShares(_deposit(bob,   a2));

        _setPrimeChi(chiP);
        _setSpUsdcChi(chiS);
        _setCapacity(cap);

        (uint256 m1, uint256 m2) = _expectedBatchMints(s1, s2, chiS, chiP, cap);

        _processDeposits(type(uint256).max, 2);

        assertEq(vault.balanceOf(alice), m1);
        assertEq(vault.balanceOf(bob),   m2);
        assertLe(vault.totalSupply(), cap, "batch fill over capacity");

        // a second call cannot push it over either (the head may still hold a partial entry)
        _processDeposits(type(uint256).max, 2);
        assertLe(vault.totalSupply(), cap, "second batch over capacity");
    }

    /**********************************************************************************************/
    /*** Round 5 attacks (c): C-11 dust donations and F-4 zero mints, exact regions             ***/
    /**********************************************************************************************/

    /// @dev C-11 (open). `requestDeposit(X)` with X RAY < chi_s, i.e. X <= floor((chi_s - 1) / RAY),
    ///      buys 0 spUSDC (`:402`): the X USDC is donated to spUSDC, a 0-share entry is pushed
    ///      (`:406`), the instant-fill predicate (`:414`) is true for it, nothing mints, and the
    ///      entry can neither be cancelled nor repointed (`no-request`, `:429` / `:485`). One more
    ///      wei buys exactly 1 spUSDC share. Harness: X == 1 only (c_s = 1.0476). At chi_s = 10 RAY
    ///      every deposit below 10 wei is lost. `minDeposit >= ceil(c_s)` is the only guard.
    function testFuzz_BUG_C11_dustDeposit_exactRegion(uint256 chiS, uint256 x) public {
        chiS = bound(chiS, RAY + 1, 10 * RAY);
        _setSpUsdcChi(chiS);

        uint256 xMax = (chiS - 1) / RAY;                // largest X with X RAY < chi_s
        assertEq(xMax, _divUp(chiS, RAY) - 1);
        x = bound(x, 1, xMax);
        assertLt(x * RAY, chiS);

        uint256 spUsdcUsdcBefore = usdc.balanceOf(address(spUsdc));
        uint256 id = _deposit(alice, x);

        assertEq(_vaultSpUsdc(), 0);
        assertEq(_depositShares(id), 0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(usdc.balanceOf(address(spUsdc)) - spUsdcUsdcBefore, x);   // donated
        assertEq(vault.firstPendingDepositId(), 1);                        // ghost walked past

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, alice);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositRecipient(id, alice);

        // the boundary: xMax + 1 buys exactly 1 spUSDC share and fills instantly
        assertEq((xMax + 1) * RAY / chiS, 1);
        uint256 id2 = _deposit(bob, xMax + 1);
        assertEq(_depositShares(id2), 0);
        assertEq(_vaultSpUsdc() + vault.pendingDepositSavingsShares(), vault.totalSupply() == 0 ? 1 : 1);
    }

    /// @dev F-4 (open) at arbitrary pairs: the zero-mint region of a fill is exactly
    ///      s <= sMax = ceil((K + 1) RAY / chi_s) - 1 with K = floor((chi_p - 1) / RAY), empty once
    ///      chi_p <= RAY. Every spUSDC share in the region is consumed from the head entry
    ///      (`:849`) and mints nothing (`:852`), i.e. donated to the vault's other holders.
    function testFuzz_BUG_F4_zeroMintRegion_arbitraryIndexes(uint256 chiS, uint256 chiP) public {
        chiS = bound(chiS, RAY, 10 * RAY);
        chiP = bound(chiP, RAY / 1000, 10 * RAY);
        _setPrimeChi(chiP);
        _setSpUsdcChi(chiS);

        uint256 sMax = _zeroMintMax(chiS, chiP);
        if (chiP <= RAY) assertEq(sMax, 0, "region not empty below RAY");

        assertEq(vault.convertToShares(spUsdc.convertToAssets(sMax)),     0);
        assertGe(vault.convertToShares(spUsdc.convertToAssets(sMax + 1)), 1);
        if (sMax == 0) return;

        // drive it: capacity exactly sMax + ... such that admitted == sMax spUSDC shares
        // admitted = floor(floor(cap c_p) / c_s); pick cap so that floor(cap c_p) = K, i.e.
        // cap = ceil(K RAY / chi_p) if that floors to K.
        uint256 k   = (chiP - 1) / RAY;
        uint256 cap = _divUp(k * RAY, chiP);
        vm.assume(cap * chiP / RAY == k);
        uint256 admitted = spUsdc.convertToShares(k);
        assertLe(admitted, sMax);
        vm.assume(admitted != 0);

        _setCapacity(cap);
        uint256 id = _deposit(alice, 1e15);

        assertEq(vault.totalSupply(), 0, "F-4: something minted");
        assertEq(_depositShares(id), 1e15 * RAY / chiS - admitted, "F-4: admitted shares consumed for nothing");
        assertEq(vault.availableCapacity(), cap);                       // headroom untouched, repeatable
    }

    /**********************************************************************************************/
    /*** Round 5 attacks (e): overflow regions                                                  ***/
    /**********************************************************************************************/

    /// @dev `convertToAssets(shares)` (`:793`) panics iff shares > floor((2^256 - 1) / nowChi()).
    ///      Harness: 114681085459589801375833087904206311575507395147570 (1.1468e50) shares; the
    ///      supply can never get there (capacity math CAP-1 dies at 3.4e38 first), so only a
    ///      direct view call can hit it. `assetsOf` is safe for any balance.
    function testFuzz_convertToAssets_overflowThreshold_isMaxUintOverChi(uint256 vsrS, uint256 vsrP, uint256 secs)
        public
    {
        (, uint256 chiP) = _randomChis(vsrS, vsrP, secs);
        uint256 limit = type(uint256).max / chiP;

        assertEq(vault.convertToAssets(limit), limit * chiP / RAY);
        vm.expectRevert(stdError.arithmeticError);
        vault.convertToAssets(limit + 1);
    }

    function test_convertToAssets_overflowThreshold_harness() public {
        uint256 limit = type(uint256).max / vault.nowChi();
        assertEq(limit, 114681085459589801375833087904206311575507395147570);
        assertEq(vault.convertToAssets(limit), 115792089237316195423570985008687907853269984665639);
        vm.expectRevert(stdError.arithmeticError);
        vault.convertToAssets(limit + 1);
        // convertToShares: assets * RAY overflows at C + 1
        uint256 c = type(uint256).max / RAY;
        assertEq(vault.convertToShares(c), c * RAY / vault.nowChi());
        vm.expectRevert(stdError.arithmeticError);
        vault.convertToShares(c + 1);
    }

    /// @dev `_rpow(MAX_VSR, dt)` (`:1070`) reverts (empty revert data, `:1084`/`:1086`) from
    ///      dt = 2_416_158_483 s (76.62 years) on: the last good value is 2^76.6 ~ 1.1579e50 =
    ///      floor(2^256 / RAY) to within 1e-9. Below that, `nowChi()` multiplies by chi: at the
    ///      harness chi (1.0097 RAY) the product overflows (panic 0x11) from dt = 2_415_719_841 s
    ///      (76.60 years) on, 438_642 s earlier than `_rpow` itself. Exact values from the python
    ///      mirror (binary search over `rpow`), checked bit for bit here. Not reachable: the VSR
    ///      setter drips on every change and a 76-year gap between drips is not an operating
    ///      state, but the bound is the real one, not `uint192`.
    function test_rpow_maxVsr_revertBound_exact() public {
        assertEq(math.rpow(MAX_VSR, 2_416_158_482), 115792088269848880294669100449313013875845939851551);
        vm.expectRevert(bytes(""));
        math.rpow(MAX_VSR, 2_416_158_483);

        // fresh vault, chi == RAY: same bound as _rpow (chi * rpow / RAY == rpow)
        SparkPrimeVault fresh = _freshVault(address(new SparkPrimeVault()));
        vm.prank(operator);
        fresh.setVSR(MAX_VSR);
        uint256 rho = fresh.rho();
        vm.warp(rho + 2_416_158_482);
        assertEq(fresh.nowChi(), 115792088269848880294669100449313013875845939851551);
        vm.warp(rho + 2_416_158_483);
        vm.expectRevert(bytes(""));
        fresh.nowChi();

        // harness chi: the product overflows first
        _setPrimeVsr(MAX_VSR);
        rho = vault.rho();
        vm.warp(rho + 2_415_719_840);
        assertEq(vault.nowChi(), uint256(114681083086014444046921979579998224692037029469836) * DripTable.HARNESS_CHI_P / RAY);
        vm.warp(rho + 2_415_719_841);
        vm.expectRevert(stdError.arithmeticError);
        vault.nowChi();
        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
    }

    /// @dev The `uint192` cast in `drip` / `nowChi` (`:637`, `:811`) never truncates: the value is
    ///      `_rpow * chi / RAY < 2^256 / RAY = C < 2^192` whenever the product fits, so every
    ///      reachable chi is below 1.158e50 and the `:292` bound (6.3e57) is the only loose one.
    function test_drip_uint192CastNeverTruncates() public pure {
        uint256 c = type(uint256).max / RAY;
        assertLt(c, 2 ** 192);
        assertEq(type(uint192).max / c, 54_210_108);                    // the bound is 5.4e7x too loose
    }

    /**********************************************************************************************/
    /*** Round 5 attacks (f): availableLiquidAssets vs withdraw at the boundary                 ***/
    /**********************************************************************************************/

    /// @dev `maxWithdraw(vault)` = min(L, floor(bal_s c_s)) (spUSDC `:354-358`). A single
    ///      `withdraw(maxWithdraw)` never reverts: it burns ceil(maxWithdraw / c_s) <= bal_s spUSDC
    ///      (because maxWithdraw <= bal_s c_s) and pushes maxWithdraw <= L USDC. The vault's
    ///      redeem clamp (`:903`) is floor(maxWithdraw / c_p) shares, paying <= maxWithdraw, so
    ///      a single fill is always safe; only the batch is not (C-1).
    function testFuzz_availableLiquidAssets_withdrawOfMaxWithdraw_neverReverts(
        uint256 bal, uint256 liquidity, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        (uint256 chiS,) = _randomChis(vsrS, vsrP, secs);
        _deposit(alice, 1e15);
        bal = bound(bal, 1, _vaultSpUsdc());
        _take(_vaultSpUsdc() - bal);
        liquidity = bound(liquidity, 0, usdc.balanceOf(address(spUsdc)));
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - liquidity);

        uint256 maxWithdraw = spUsdc.maxWithdraw(address(vault));
        uint256 assetsOf    = bal * chiS / RAY;
        assertEq(maxWithdraw, liquidity < assetsOf ? liquidity : assetsOf);
        assertEq(vault.availableLiquidAssets(), maxWithdraw);

        vm.prank(address(vault));
        uint256 burned = spUsdc.withdraw(maxWithdraw, address(vault), address(vault));
        assertEq(burned, _divUp(maxWithdraw * RAY, chiS));
        assertLe(burned, bal, "withdraw(maxWithdraw) burned more than held");
        assertEq(usdc.balanceOf(address(vault)), maxWithdraw);
    }

    /// @dev Liquidity binds on the redeem queue: repeated planner calls drain spUSDC's USDC down to
    ///      a strand below c_p (worth less than one spPRIME share: `convertToShares(L) == 0` so
    ///      `remaining_ == 0` and the loop is skipped) while shares stay queued. The strand is
    ///      stuck only until more USDC reaches spUSDC. Per call the strand is < c_p + 1 wei
    ///      (clamp floor plus one payout floor).
    function testFuzz_redeemQueue_liquidityBinds_strandBelowOneShare(
        uint256 assets, uint256 liquidity, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 shares = vault.balanceOf(alice);
        vm.assume(shares != 0);
        _requestRedeem(alice, shares);

        liquidity = bound(liquidity, 0, assets - 1);                    // strictly short
        _drainSpUsdcLiquidity(assets - liquidity);
        vm.assume(spUsdc.maxWithdraw(address(vault)) == liquidity);     // liquidity is the binding term

        _processRedeems(type(uint256).max, type(uint256).max);
        uint256 paid = usdc.balanceOf(alice);
        assertLe(paid, liquidity);
        assertLt((liquidity - paid) * RAY, chiP + RAY, "strand >= c_p + 1 after one call");

        for (uint256 r = 0; r < 12 && vault.convertToShares(spUsdc.maxWithdraw(address(vault))) != 0; ++r) {
            uint256 before = usdc.balanceOf(alice);
            _processRedeems(type(uint256).max, type(uint256).max);
            if (usdc.balanceOf(alice) == before) break;
        }
        uint256 strand = usdc.balanceOf(address(spUsdc));
        // the other binding term: the vault's own spUSDC (random vsrP > vsrS leaves it under-backed)
        if (vault.pendingRedeemShares() != 0 && spUsdc.maxWithdraw(address(vault)) == strand) {
            assertLt(strand * RAY, chiP, "final strand >= c_p while shares are queued");
            assertEq(vault.convertToShares(strand), 0);
        }
    }

    /// @dev R9 strand on the vault side: after a full round trip (deposit X, redeem every share)
    ///      the vault keeps `leftover = s - ceil(out / c_s)` spUSDC shares with
    ///      leftover c_s < c_p + 2 (three floors, one ceil). Harness: at most 2 shares
    ///      ((1.0097 + 2) / 1.0476 = 2.87), e.g. X = 836 keeps 2. Fuzzed over random chis.
    function testFuzz_fullRedeem_leftoverSpUsdc_belowChiPPlusTwo(
        uint256 assets, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        assets = bound(assets, 1, 1e15);
        (uint256 chiS, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        _deposit(alice, assets);
        uint256 shares = vault.balanceOf(alice);
        vm.assume(shares != 0);
        _requestRedeem(alice, shares);
        _processRedeems(type(uint256).max, 1);

        assertEq(vault.totalSupply(), 0);
        uint256 leftover = _vaultSpUsdc();
        assertLt(leftover * chiS, chiP + 2 * RAY, "leftover spUSDC >= (c_p + 2) / c_s");
    }

    function testFuzz_fullRedeem_leftoverSpUsdc_harness_atMost2(uint256 assets) public {
        assets = bound(assets, 1, 1e15);
        _deposit(alice, assets);
        uint256 shares = vault.balanceOf(alice);
        if (shares != 0) {
            _requestRedeem(alice, shares);
            _processRedeems(type(uint256).max, 1);
        }
        assertLe(_vaultSpUsdc(), 2);
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
