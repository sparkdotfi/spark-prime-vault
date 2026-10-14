// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError, Vm } from "../lib/forge-std/src/Test.sol";
import { console2 }     from "../lib/forge-std/src/console2.sol";

import { ERC1967Proxy } from "../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";
import { DripTable }     from "./tables/DripTable.sol";

// Exposes the pure math helpers (same pattern as spark-vaults-v2 test/Math.t.sol).
contract SparkPrimeVaultMathHarness is SparkPrimeVault {

    function divup(uint256 x, uint256 y) external pure returns (uint256) {
        return _divup(x, y);
    }

    function rpow(uint256 x, uint256 n) external pure returns (uint256) {
        return _rpow(x, n);
    }

}

/// @dev Rounding campaign for `SparkPrimeVault`. Every rounding site of REVIEW-2026-10-13.md
///      (R1..R12) gets a direction proof against the exact rational value, computed in the test
///      with cross-multiplication so nothing is rounded on the reference side. Indexes are
///      randomised (VSR in bounds, random warp, drip) unless a test says "harness chis", which
///      means the ugly setUp values chi_s ~1.0476e27 and chi_p ~1.0097e27.
///
///      Notation: c_s = chi_s / RAY, c_p = chi_p / RAY (real numbers >= 1).
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

    function _divup(uint256 x, uint256 y) internal pure returns (uint256) {
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
    /*** R1  requestDeposit:366  spUSDC.deposit  floor(assets * RAY / chi_s)                     ***/
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
        vault.cancelDepositRequest(id, alice);
    }

    /**********************************************************************************************/
    /*** R2  _processDepositQueue:633-636  spUSDC.convertToShares(convertToAssets(capacity))     ***/
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
    /*** R3  _processDepositQueue:653  spUSDC.convertToAssets  floor(s * chi_s / RAY)            ***/
    /*** R4  _processDepositQueue:654  convertToShares         floor(assets * RAY / chi_p)       ***/
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
    /*** R5  requestRedeem:426  shares * chi / RAY >= minWithdraw  (floor, stricter than exact)  ***/
    /**********************************************************************************************/

    function testFuzz_R5_minWithdraw_floorIsStricterThanExact(
        uint256 shares, uint256 minWithdraw, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        (, uint256 chiP) = _randomChis(vsrS, vsrP, secs);

        _deposit(alice, 1e15);
        uint256 balance = vault.balanceOf(alice);
        vm.assume(balance != 0);

        shares      = bound(shares, 1, balance);
        minWithdraw = bound(minWithdraw, 0, 2e15);

        _setMinimums(0, minWithdraw);

        bool passesExact = shares * chiP >= minWithdraw * RAY;   // exact rational check
        bool passesFloor = shares * chiP / RAY >= minWithdraw;   // what the contract does

        // floor never admits what the exact check rejects
        if (passesFloor) assertTrue(passesExact, "R5: floor admitted below exact");

        if (!passesFloor) vm.expectRevert("SparkPrimeVault/below-minimum");
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
    }

    /// @dev Boundary (info): a request whose exact value is within half a wei below `minWithdraw`
    ///      is rejected because the check floors. Found at the harness chi by scanning minimums.
    function test_R5_minWithdraw_floorRejectsRequestWithinHalfWeiOfMinimum() public {
        uint256 chiP = vault.nowChi();

        _deposit(alice, 1e15);

        uint256 minWithdraw;
        uint256 shares;
        for (uint256 m = 1_000e6; m < 1_000e6 + 10_000; ++m) {
            uint256 s = (m * RAY - 1) / chiP;             // largest s with s * chi < m * RAY
            if (2 * s * chiP >= (2 * m - 1) * RAY) {       // exact value >= m - 0.5
                minWithdraw = m;
                shares      = s;
                break;
            }
        }
        assertGt(minWithdraw, 0, "no boundary found");

        _setMinimums(0, minWithdraw);

        // exact value in [minWithdraw - 0.5, minWithdraw), floored to minWithdraw - 1
        assertEq(shares * chiP / RAY, minWithdraw - 1);
        assertGe(2 * shares * chiP, (2 * minWithdraw - 1) * RAY);

        console2.log("minWithdraw", minWithdraw, "rejected shares", shares);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(shares, alice);

        // one more share passes
        assertGe((shares + 1) * chiP / RAY, minWithdraw);
        vm.prank(alice);
        vault.requestRedeem(shares + 1, alice);
    }

    /**********************************************************************************************/
    /*** R6  requestRedeem:435  _divup(shares * redeemFee, WAD)                                  ***/
    /**********************************************************************************************/

    function testFuzz_R6_redeemFee_roundsInFavourOfVault(
        uint256 shares, uint256 fee, uint256 vsrS, uint256 vsrP, uint256 secs
    ) public {
        _randomChis(vsrS, vsrP, secs);
        fee = bound(fee, 0, vault.MAX_REDEEM_FEE());
        _setRedeemFee(fee);

        _deposit(alice, 1e15);
        uint256 balance = vault.balanceOf(alice);
        vm.assume(balance != 0);
        shares = bound(shares, 1, balance);

        uint256 supplyBefore = vault.totalSupply();

        uint256 id = _requestRedeem(alice, shares);

        uint256 burned = supplyBefore - vault.totalSupply();

        assertEq(burned, _divup(shares * fee, WAD));
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

        uint256 ceilFee = math.divup(shares * fee, WAD);

        assertGe(ceilFee * WAD, shares * fee);
        assertLt(ceilFee * WAD - shares * fee, WAD);
        assertLe(ceilFee, shares * fee / WAD + 1);
    }

    /**********************************************************************************************/
    /*** R7  _processRedeemQueue:675  convertToShares(availableLiquidAssets())  floor            ***/
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
    /*** R8  _processRedeemQueue:688  convertToAssets(shares)  floor                             ***/
    /*** R9  _processRedeemQueue:698  spUSDC.withdraw(assets)  burns ceil(assets * RAY / chi_s)  ***/
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
        assertEq(burned, _divup(paid * RAY, chiS));
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
    function test_BUG_processRedeemQueue_batchCeilBurnsExceedSpUsdcBalance() public {
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
    function test_processRedeemQueue_batchCeilBurn_oneRequestPerCallSucceeds() public {
        _deposit(alice, 1_000_000e6);
        _take(_vaultSpUsdc() - 3548);

        uint256 id1 = _requestRedeem(alice, 2396);
        uint256 id2 = _requestRedeem(alice, 1285);

        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(rebalancer);
        vm.expectRevert("SparkVault/insufficient-balance");
        vault.processRedeemQueue(type(uint256).max, 2);

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
    /*** R10 cancelDepositRequest:411  spUSDC.redeem(shares)  floor(shares * chi_s / RAY)        ***/
    /**********************************************************************************************/

    function testFuzz_R10_cancelDeposit_roundsAgainstCancellingUser(
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
        vault.cancelDepositRequest(id, alice);

        uint256 refund = usdc.balanceOf(alice);

        assertEq(refund, savingsShares * chiS / RAY);
        _assertFloor(refund, savingsShares * chiS, RAY, "R10");

        // Round trip through spUSDC: user gets back <= assets, loses < 1 + c_s wei.
        assertLe(refund, assets);
        assertLt((assets - refund) * RAY, RAY + chiS, "R10: cancel loss exceeds 1 + c_s");
        assertEq(_vaultSpUsdc(), 0);
    }

    /**********************************************************************************************/
    /*** R11 drip:575 / nowChi:621  _rpow(vsr, dt) * chi / RAY, _rpow half-up                    ***/
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
    /*** R12 convertToAssets:590 / convertToShares:594  floor / floor                            ***/
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
        return _divup((k + 1) * RAY, chiS) - 1;
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
    /*** _divup                                                                                 ***/
    /**********************************************************************************************/

    function test_divup_zeroNumerator() public view {
        assertEq(math.divup(0, 1), 0);
        assertEq(math.divup(0, type(uint256).max), 0);
        assertEq(math.divup(0, 0), 0);   // the `x_ != 0` guard stops the unchecked `x_ - 1` underflow
    }

    function test_divup_divideByZero_reverts() public {
        vm.expectRevert(stdError.divisionError);
        math.divup(1, 0);
    }

    function testFuzz_divup_exactMultiple(uint256 k, uint256 y) public view {
        y = bound(y, 1, type(uint128).max);
        k = bound(k, 1, type(uint128).max);
        assertEq(math.divup(k * y, y), k);
    }

    function testFuzz_divup_multiplePlusOne(uint256 k, uint256 y) public view {
        y = bound(y, 2, type(uint128).max);
        k = bound(k, 0, type(uint128).max);
        assertEq(math.divup(k * y + 1, y), k + 1);
        assertEq(math.divup(k * y + y - 1, y), k + 1);
    }

    function testFuzz_divup_isCeil(uint256 x, uint256 y) public view {
        y = bound(y, 1, type(uint256).max);
        uint256 z = math.divup(x, y);
        assertEq(z, x / y + (x % y == 0 ? 0 : 1));
    }

}
