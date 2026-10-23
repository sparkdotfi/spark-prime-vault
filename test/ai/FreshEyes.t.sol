// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl }  from "../../lib/oz/contracts/access/IAccessControl.sol";
import { Initializable }   from "../../lib/oz-upgradeable/contracts/proxy/utils/Initializable.sol";
import { ERC1967Proxy }    from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UUPSUpgradeable } from "../../lib/oz/contracts/proxy/utils/UUPSUpgradeable.sol";

import { SparkPrimeVault }       from "../../src/SparkPrimeVault.sol";
import { ISparkPrimeVault }      from "../../src/ISparkPrimeVault.sol";
import { SparkPrimeVaultV2Mock } from "./mocks/SparkPrimeVaultV2Mock.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

/// @dev Minimal ERC1271 wallet: accepts exactly one digest.
contract ERC1271Wallet {
    bytes32 public accepted;
    function set(bytes32 d) external { accepted = d; }
    function isValidSignature(bytes32 digest, bytes memory) external view returns (bytes4) {
        return digest == accepted ? bytes4(0x1626ba7e) : bytes4(0);
    }
}

/// @dev Fresh-eyes attacker pass on `src/SparkPrimeVault.sol` @ c512609 (round 6). Round-5 tests
///      are ported below (section R5), new attacks on the partial-cancel / self-skip / per-entry
///      liquidity bound / try-catch surface are in section R6. Every claim in
///      REPORT-fresh-eyes.md is backed by a test here. `test_BUG_*` tests prove real bugs by
///      asserting the bad behaviour (none fails deliberately); `test_fixed_*` pin round-5 bugs
///      that this master fixed; `test_property_*` pin attacks that were tried and ruled out.
contract FreshEyesTest is LocalTestBase {

    // Harness index values after setUp (pinned so every expectation below is exact wei).
    uint256 constant CHI_S = 1.047633055711877768967605062e27;  // spUSDC chi
    uint256 constant CHI_P = 1.009687768242461209408770821e27;  // spPRIME chi

    uint256 constant ONE_M = 1_000_000e6;

    // Exact derived constants for a 1M USDC deposit on the harness indexes.
    uint256 constant S_1M      = 954_532_691_143;  // spUSDC shares minted for 1M USDC
    uint256 constant SH_1M     = 990_405_184_109;  // spPRIME shares minted for S_1M
    uint256 constant ASSETS_1M = 999_999_999_998;  // assetsOf(SH_1M)

    // Storage slots on c512609 (pinned in test_property_storageLayout_c512609_pinned).
    uint256 constant SLOT_DEPOSITS = 0;
    uint256 constant SLOT_CANCELS  = 1;
    uint256 constant SLOT_REDEEMS  = 2;

    address alice  = makeAddr("alice");
    address bob    = makeAddr("bob");
    address carol  = makeAddr("carol");
    address mal    = makeAddr("mal");
    address victim = makeAddr("victim");

    function setUp() public override {
        super.setUp();
        assertEq(spUsdc.nowChi(), CHI_S, "chi_s pin");
        assertEq(vault.nowChi(),  CHI_P, "chi_p pin");
    }

    /*** helpers ***/

    function _sShares(uint256 assets) internal pure returns (uint256) { return assets * RAY / CHI_S; }
    function _sAssets(uint256 shares) internal pure returns (uint256) { return shares * CHI_S / RAY; }
    function _pShares(uint256 assets) internal pure returns (uint256) { return assets * RAY / CHI_P; }
    function _pAssets(uint256 shares) internal pure returns (uint256) { return shares * CHI_P / RAY; }
    function _divUp(uint256 x, uint256 y) internal pure returns (uint256) { return x == 0 ? 0 : (x - 1) / y + 1; }

    function _sumDeposits() internal view returns (uint256 s) {
        SparkPrimeVault.Request[] memory r = vault.getPendingDepositRequests();
        for (uint256 i; i < r.length; ++i) s += r[i].shares;
    }
    function _sumCancels() internal view returns (uint256 s) {
        SparkPrimeVault.Request[] memory r = vault.getPendingDepositCancellationRequests();
        for (uint256 i; i < r.length; ++i) s += r[i].shares;
    }
    function _sumRedeems() internal view returns (uint256 s) {
        SparkPrimeVault.Request[] memory r = vault.getPendingRedeemRequests();
        for (uint256 i; i < r.length; ++i) s += r[i].shares;
    }

    /// @dev Raw read of `shares` of entry `i` of the array at `slot` (works below the head).
    function _rawShares(uint256 slot, uint256 i) internal view returns (uint256) {
        return uint256(vm.load(
            address(vault), bytes32(uint256(keccak256(abi.encode(slot))) + 3 * i + 2)
        ));
    }

    function _rawLength(uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(address(vault), bytes32(slot)));
    }

    /// @dev Full cancel of a live entry by its owner, refund to the owner.
    function _cancelAll(address who, uint256 id) internal returns (uint256 cancelId) {
        ( , , uint256 sh ) = vault.getPendingDepositRequest(id);
        vm.prank(who);
        cancelId = vault.requestDepositCancellation(id, who, sh);
    }

    function _cancelPart(address who, uint256 id, uint256 sh) internal returns (uint256 cancelId) {
        vm.prank(who);
        cancelId = vault.requestDepositCancellation(id, who, sh);
    }

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, who, role
        );
    }

    /**********************************************************************************************/
    /**********************************************************************************************/
    /*** R6: new surface on c512609                                                             ***/
    /**********************************************************************************************/
    /**********************************************************************************************/

    /**********************************************************************************************/
    /*** R6-1. Partial cancellations: slices, delete vs decrement, interplay with partial fill  ***/
    /**********************************************************************************************/

    // Owner slices a queued entry: two partial cancels (decrement branch) then the remainder
    // (delete branch). Each slice is its own cancellation entry with its own recipient, the
    // pending counters move exactly, and the self-skip walk only advances the head once the entry
    // is deleted.
    function test_property_partialCancel_slicesAreExact_deleteOnlyWhenEmpty() public {
        _deposit(alice, ONE_M);                       // filled, head = 1
        _setCapacity(vault.totalSupply());            // queue mode
        uint256 id = _deposit(bob, ONE_M);            // live at the head (index 1)
        assertEq(id, 1);
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(vault.pendingDepositSavingsShares(), S_1M);

        // Slice 1: 100 spUSDC shares to carol. Decrement branch: entry stays live, head stays.
        vm.prank(bob);
        uint256 c0 = vault.requestDepositCancellation(id, carol, 100);
        assertEq(c0, 0);
        ( address o, address r, uint256 sh ) = _depositRequest(id);
        assertEq(o, bob); assertEq(r, bob); assertEq(sh, S_1M - 100);
        assertEq(vault.pendingDepositSavingsShares(),          S_1M - 100);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 100);
        assertEq(vault.firstPendingDepositId(), 1);               // live head: walk broke at once
        ( o, r, sh ) = _cancelledDepositRequest(c0);
        assertEq(o, bob); assertEq(r, carol); assertEq(sh, 100);

        // Slice 2: 400_000 USDC worth, to bob.
        uint256 s2 = _sShares(400_000e6);
        uint256 c1 = _cancelPart(bob, id, s2);
        assertEq(c1, 1);
        ( , , sh ) = _depositRequest(id);
        assertEq(sh, S_1M - 100 - s2);
        assertEq(vault.firstPendingDepositId(), 1);

        // Remainder: delete branch, the walk advances the head past it.
        uint256 rest = S_1M - 100 - s2;
        uint256 c2 = _cancelPart(bob, id, rest);
        assertEq(c2, 2);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
        assertEq(vault.firstPendingDepositId(), 2);               // walked past the deleted entry
        assertEq(_rawShares(SLOT_DEPOSITS, id), 0);
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);     // a 4th cancel finds nothing
        vault.requestDepositCancellation(id, bob, 1);

        // Settlement pays each slice floor(shares * chi_s / RAY) to its own recipient.
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(carol), _sAssets(100));
        assertEq(usdc.balanceOf(carol), 104);
        assertEq(usdc.balanceOf(bob),   _sAssets(s2) + _sAssets(rest));
        assertEq(usdc.balanceOf(bob),   999_999_999_893);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        // Slicing costs bob 1 wei per slice of floor rounding vs one shot (999_999_999_999).
        assertEq(usdc.balanceOf(bob) + usdc.balanceOf(carol), 999_999_999_997);
    }

    // Operator partially fills the head, owner partially cancels the remainder, then cancels the
    // rest: exact shares minted, exact refunds, and the head only moves on the delete.
    function test_property_partialFill_thenPartialCancel_thenFullCancel_exact() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);          // queued at index 0
        _setCapacity(type(uint128).max);

        uint256 F = _sShares(250_000e6);              // fill budget in spUSDC shares
        _processDeposits(F, type(uint256).max);
        uint256 minted = _pShares(_sAssets(F));
        assertEq(vault.balanceOf(alice), minted);
        assertEq(vault.balanceOf(alice), 247_601_296_025);
        ( , , uint256 sh ) = _depositRequest(id);
        assertEq(sh, S_1M - F);
        assertEq(vault.firstPendingDepositId(), 0);   // partial fill: entry stays at the head

        uint256 C = _sShares(100_000e6);
        _cancelPart(alice, id, C);
        ( , , sh ) = _depositRequest(id);
        assertEq(sh, S_1M - F - C);
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(vault.pendingDepositSavingsShares(), S_1M - F - C);

        _cancelPart(alice, id, S_1M - F - C);
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), _sAssets(C) + _sAssets(S_1M - F - C));
        assertEq(usdc.balanceOf(alice), 749_999_999_999);
        // Total value: filled 250k (floors) + refunded; alice is 4 wei short of 1M in total.
        assertEq(vault.assetsOf(alice) + usdc.balanceOf(alice), 999_999_999_996);
    }

    // `minDepositCancellation` is a floor on EVERY cancel, including the one that would empty the
    // entry. A remainder below it (left by a partial cancel OR by an operator partial fill) can
    // never be cancelled by the owner: only an operator fill releases it. With launch minimums a
    // min-size deposit can be entirely uncancellable when `minDepositCancellation` (spUSDC shares)
    // exceeds `convertToShares_spUSDC(minDeposit)`.
    function test_BUG_cancelRemainderBelowMinDepositCancellation_isUncancellable() public {
        _setMinDeposit(1_000e6);
        _setMinDepositCancellation(100e6);            // 100e6 spUSDC share-wei
        _setCapacity(0);

        uint256 id = _deposit(alice, 1_000e6);        // 954_532_691 spUSDC shares
        ( , , uint256 sh ) = _depositRequest(id);
        assertEq(sh, 954_532_691);

        // Owner leaves 50e6 behind: the remainder is now stuck in the deposit queue.
        _cancelPart(alice, id, sh - 50e6);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, 50e6);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, alice, 100e6);

        // Operator-made remainder: a budgeted fill leaves `sh - 50e6` ... same trap for bob.
        uint256 idB = _deposit(bob, 1_000e6);
        _setCapacity(type(uint128).max);
        _processDeposits(0, type(uint256).max);       // head still alice's live remainder
        assertEq(vault.firstPendingDepositId(), 0);
        _processDeposits(50e6 + (954_532_691 - 50e6), 1);  // clears alice exactly
        assertEq(vault.firstPendingDepositId(), 1);
        _processDeposits(954_532_691 - 50e6, 1);      // bob partially filled: 50e6 left
        ( , , sh ) = _depositRequest(idB);
        assertEq(sh, 50e6);
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(idB, bob, 50e6);

        // Entirely uncancellable min-size deposit: minDepositCancellation above the share value
        // of minDeposit (1_000e6 USDC = 954_532_691 shares < 1_000e6 shares).
        _setMinDepositCancellation(1_000e6);
        _setCapacity(vault.totalSupply());
        uint256 idC = _deposit(carol, 1_000e6);
        vm.prank(carol);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(idC, carol, 954_532_691);
        vm.prank(carol);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(idC, carol, 1_000e6);
    }

    /**********************************************************************************************/
    /*** R6-2. Self-skip walk in requestDepositCancellation                                     ***/
    /**********************************************************************************************/

    // The walk `_processPendingDeposits(0, max)` runs inside `requestDepositCancellation`, which
    // is not pause-gated. While paused it calls `drip()` (which anyone may call at any time, so
    // the pause never gated chi) and mints nothing (budget 0). It advances the head over ghosts
    // only, never over a live entry.
    function test_property_cancelWhilePaused_walkDripsButMintsNothing() public {
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());
        uint256 idB = _deposit(bob, 100e6);           // live head at 1
        uint256 idC = _deposit(carol, 100e6);         // live at 2
        _setPrimeVsr(FIVE_PCT_VSR);
        _pause();
        _warp(30 days);

        uint256 tsBefore = vault.totalSupply();
        uint256 chiView  = vault.nowChi();            // what any drip() would write now
        assertGt(chiView, CHI_P);
        assertEq(vault.chi(), CHI_P);                 // not yet written

        _cancelAll(carol, idC);                       // behind the live head: walk breaks at bob
        assertEq(vault.chi(), chiView);               // drip ran while paused
        assertEq(vault.rho(), block.timestamp);
        assertEq(vault.totalSupply(), tsBefore);      // nothing minted
        assertEq(vault.firstPendingDepositId(), 1);   // live head untouched
        assertEq(_rawShares(SLOT_DEPOSITS, idC), 0);

        _cancelAll(bob, idB);                         // head deleted: walk clears 1 and 2
        assertEq(vault.firstPendingDepositId(), 3);
        assertEq(vault.totalSupply(), tsBefore);
        assertTrue(vault.paused());

        // The loss manager's adjustment is computed on the dripped chi either way, because
        // adjustTotalAssets drips first itself: the walk's drip changes nothing for it.
        uint256 ta = vault.totalAssets();
        _adjustTotalAssets(-int256(ta / 10));
        assertEq(vault.chi(), (ta - ta / 10) * RAY / tsBefore);
        _unpause();
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),   _sAssets(_sShares(100e6)));
        assertEq(usdc.balanceOf(carol), _sAssets(_sShares(100e6)));
        assertEq(usdc.balanceOf(bob), 99_999_999);
    }

    // Ghosts behind a live head (R5-9 follow-up). An attacker queues N entries behind the
    // victim's live head and cancels each one (each cancel's walk breaks at the victim at once,
    // so the attacker's walks are O(1)). The victim's FULL cancel then deletes the head and walks
    // all N ghosts with `maxRequests_ = max`: measured per-ghost cost. A PARTIAL cancel by the
    // victim is O(1) (the entry stays live, the walk breaks immediately), so the victim can still
    // pull everything but `minDepositCancellation` out cheaply. The operator cannot skip a live
    // head with budget 0; it must fill it (capacity permitting) and then chunk the ghosts.
    function test_BUG_ghostsBehindLiveHead_fullCancelWalksThemAll() public {
        _setMinDeposit(1_000e6);
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());            // queue mode

        uint256 idV = _deposit(victim, 10_000e6);     // live head at index 1
        assertEq(vault.firstPendingDepositId(), 1);

        // Attacker: N request + full-cancel cycles, capital recycled via the cancellation queue.
        uint256 N = 2_000;
        _fund(mal, 1_000e6 + N);                      // +1 wei per cycle of floor rounding
        uint256 gCancelSum;
        for (uint256 i; i < N; ++i) {
            vm.prank(mal);
            uint256 id = vault.requestDeposit(1_000e6, mal, 0);
            vm.prank(mal);
            uint256 g0 = gasleft();
            vault.requestDepositCancellation(id, mal, 954_532_691);
            gCancelSum += g0 - gasleft();
            _processCancelledDeposits(type(uint256).max, type(uint256).max);
        }
        assertEq(usdc.balanceOf(mal), 1_000e6);       // N wei lost to rounding
        assertEq(vault.getPendingDepositRequests().length, N + 1);
        assertEq(vault.firstPendingDepositId(), 1);   // head still the victim
        emit log_named_uint("attacker cancel gas (avg, O(1) walk)", gCancelSum / N);

        // Operator cannot move a live head with budget 0.
        _processDeposits(0, type(uint256).max);
        assertEq(vault.firstPendingDepositId(), 1);

        // Victim's partial cancel is O(1): keeps minDepositCancellation (1 wei) behind.
        ( , , uint256 shV ) = _depositRequest(idV);
        vm.cool(address(vault));
        vm.prank(victim);
        uint256 g1 = gasleft();
        vault.requestDepositCancellation(idV, victim, shV - 1);
        uint256 gPartial = g1 - gasleft();
        emit log_named_uint("victim partial cancel gas", gPartial);
        assertLt(gPartial, 250_000);

        // Victim's full cancel (last wei) walks all N ghosts.
        vm.cool(address(vault));
        vm.prank(victim);
        uint256 g2 = gasleft();
        vault.requestDepositCancellation(idV, victim, 1);
        uint256 gFull = g2 - gasleft();
        uint256 perGhost = (gFull - gPartial) / N;
        emit log_named_uint("victim full cancel gas after 2000 ghosts", gFull);
        emit log_named_uint("walk gas per ghost", perGhost);
        assertGt(perGhost, 2_000);
        assertLt(perGhost, 3_000);
        assertEq(vault.firstPendingDepositId(), N + 2);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(victim), _sAssets(shV - 1) + _sAssets(1));
        assertEq(usdc.balanceOf(victim), 9_999_999_999);
    }

    // Operator recovery when the live head is NOT cancelled: fill it (1 request), then chunk the
    // ghosts with budget 0 and bounded maxRequests. Ghosts count against maxRequests_.
    function test_property_operatorChunksGhosts_afterFillingLiveHead() public {
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());
        _deposit(victim, 10_000e6);                   // live head at 1
        for (uint256 i; i < 30; ++i) {
            uint256 id = _deposit(mal, 1e6);
            _cancelAll(mal, id);                      // ghosts 2..31
        }
        uint256 idZ = _deposit(carol, 5e6);           // live at 32
        assertEq(idZ, 32);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);       // fills the victim only
        assertEq(vault.balanceOf(victim), _pShares(_sAssets(_sShares(10_000e6))));
        assertEq(vault.firstPendingDepositId(), 2);
        _processDeposits(0, 10);                      // budget 0 still walks ghosts
        assertEq(vault.firstPendingDepositId(), 12);
        _processDeposits(0, 100);                     // stops at carol (live, budget 0)
        assertEq(vault.firstPendingDepositId(), 32);
        assertEq(vault.balanceOf(carol), 0);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(carol), _pShares(_sAssets(_sShares(5e6))));
        assertEq(vault.firstPendingDepositId(), 33);
    }

    /**********************************************************************************************/
    /*** R6-3. Per-entry redeem liquidity bound (C-1 fix) and what is left of FE-1             ***/
    /**********************************************************************************************/

    // C-1 / FE-6 fixed: the (11, 11, rest) batch that drained all backing now settles in one
    // call. What remains is FE-1's dust: the last entry is bounded by
    // convertToShares(maxWithdraw) (floor) while each withdraw ceil-burns spUSDC, so the final
    // entry keeps 1 share the vault can no longer back.
    function test_fixed_C1_redeemBatch_drainingAllBacking_noRevert_dustMeasured() public {
        _deposit(alice, ONE_M);
        uint256 total = vault.balanceOf(alice);
        for (uint256 k = 1; k < 40; ++k) {
            uint256 snap = vm.snapshotState();
            _requestRedeem(alice, k);
            _requestRedeem(alice, k);
            _requestRedeem(alice, total - 2 * k);
            _processRedeems(type(uint256).max, type(uint256).max);   // never reverts now
            uint256 left = vault.pendingRedeemShares();
            // Each small entry ceil-burns ~0.5 spUSDC wei of value above what it pays, so the
            // last entry can be short by up to 2 shares here (grows with the number of entries).
            assertLe(left, 2, "more than 2 shares of dust");
            if (left != 0) {
                assertEq(vault.firstPendingRedeemId(), 2);           // last entry is the one
                assertLe(_vaultSpUsdc(), 1);                         // <= 1 spUSDC wei = 0 shares
                assertEq(vault.convertToShares(vault.availableLiquidAssets()), 0);
            } else {
                assertEq(vault.firstPendingRedeemId(), 3);
            }
            assertLe(ASSETS_1M - usdc.balanceOf(alice), 3);          // at most 3 wei of floors
            vm.revertToState(snap);
        }
        // The 3401-spUSDC shape: alice redeems everything in one entry, capacity for fills only.
        _requestRedeem(alice, total);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), ASSETS_1M);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.firstPendingRedeemId(), 1);
        assertEq(_vaultSpUsdc(), S_1M - _divUp(ASSETS_1M * RAY, CHI_S));
        assertEq(_vaultSpUsdc(), 0);
    }

    // Fuzz: with random entries, random spUSDC liquidity, random `take`, the batched redeem never
    // reverts and only stops when `convertToShares(availableLiquidAssets()) == 0`. Also pins that
    // `fillable_ > 0` always implies `withdraw` succeeds (the bound is tight enough).
    function testFuzz_property_redeemBatch_neverReverts_stopsOnlyAtZeroLiquidity(uint256 seed) public {
        uint256 n = 1 + seed % 6;
        for (uint256 i; i < n; ++i) {
            address u = i % 2 == 0 ? alice : bob;
            uint256 amt = uint256(keccak256(abi.encode(seed, i, "d"))) % 400_000e6 + 2;
            _deposit(u, amt);
            uint256 bal = vault.balanceOf(u);
            _requestRedeem(u, uint256(keccak256(abi.encode(seed, i, "r"))) % bal + 1);
        }
        uint256 liq = usdc.balanceOf(address(spUsdc));
        if (seed % 3 == 0) _drainSpUsdcLiquidity(uint256(keccak256(abi.encode(seed, "l"))) % liq);
        if (seed % 5 == 0) _take(uint256(keccak256(abi.encode(seed, "t"))) % (_vaultSpUsdc() + 1));

        // A single call can stop one share short after a partial fill (`break` after the fill
        // while the floored leftover converts to 1 share again); a second call picks it up, so
        // the property is stated after calls stop making progress.
        uint256 calls;
        for (;;) {
            uint256 before = vault.pendingRedeemShares();
            _processRedeems(type(uint256).max, type(uint256).max);
            ++calls;
            if (vault.pendingRedeemShares() == before) break;
        }
        assertLe(calls, 3, "needed more than 2 productive calls");

        uint256 left = vault.pendingRedeemShares();
        if (left != 0) {
            assertEq(vault.convertToShares(vault.availableLiquidAssets()), 0, "stopped with liquidity");
            // The head is live.
            ( , , uint256 sh ) = _redeemRequest(vault.firstPendingRedeemId());
            assertGt(sh, 0);
        } else {
            assertEq(vault.firstPendingRedeemId(), _redeemQueueLength());
        }
        assertEq(vault.pendingRedeemShares(), _sumRedeems());
        assertEq(vault.pendingRedeemShares(), vault.balanceOf(address(vault)));
    }

    // Every `withdraw` inside the loop burns at most the vault's spUSDC and asks at most spUSDC's
    // liquidity: a reverting `withdraw` with `fillable_ > 0` is impossible because
    // maxWithdraw = min(liquidity, floor(bal * chi_s / RAY)) and divUp(assets * RAY / chi_s) <= bal
    // whenever assets <= floor(bal * chi_s / RAY). Direct check over every bal in a window.
    function testFuzz_property_ceilBurn_neverExceedsBalance(uint256 bal, uint256 chiS) public pure {
        bal  = bound(bal, 0, 1e30);
        chiS = bound(chiS, RAY, 10 * RAY);
        uint256 assets = bal * chiS / RAY;              // maxWithdraw with infinite liquidity
        uint256 burned = assets == 0 ? 0 : (assets * RAY - 1) / chiS + 1;
        assertLe(burned, bal);
    }

    /**********************************************************************************************/
    /*** R6-4. try/catch fallback                                                               ***/
    /**********************************************************************************************/

    // Low-gas operator call: the inner `withdraw` gets 63/64 of the gas; if it OOGs the catch
    // runs the fallback with the 1/64 left, which can only OOG too (same work, colder slots), so
    // a clean recipient can never be flipped into a claimable credit by gas starvation.
    function testFuzz_property_lowGasOperatorCall_cannotForceClaimable(uint256 gas_) public {
        gas_ = bound(gas_, 30_000, 400_000);
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_1M);
        vm.prank(operator);
        try vault.processPendingRedeems{gas: gas_}(type(uint256).max, type(uint256).max) {
            assertEq(usdc.balanceOf(alice), ASSETS_1M, "paid directly or not at all");
            assertEq(vault.firstPendingRedeemId(), 1);
        } catch {
            assertEq(usdc.balanceOf(alice), 0);
            assertEq(vault.firstPendingRedeemId(), 0);
            assertEq(vault.pendingRedeemShares(), SH_1M);
        }
        assertEq(vault.claimableAssets(alice), 0);
        assertEq(vault.totalClaimable(), 0);
    }

    // Three kinds of recipient through both fallbacks (redeem and cancellation): a blacklisted
    // EOA (claimable), a contract (USDC has no hooks: paid directly), spUSDC itself (paid: a
    // USDC self-transfer inside spUSDC, i.e. a donation to spUSDC's other holders). And a
    // NON-recipient revert (vault blacklisted so the fallback's own payout fails) propagates.
    function test_property_fallback_recipientKinds_andNonRecipientRevertPropagates() public {
        _deposit(alice, 3 * ONE_M);
        uint256 third = vault.balanceOf(alice) / 3;
        ERC1271Wallet someContract = new ERC1271Wallet();
        address bl = BLACKLISTED_EOA();

        vm.startPrank(alice);
        vault.requestRedeem(third, bl);
        vault.requestRedeem(third, address(someContract));
        vault.requestRedeem(third, address(spUsdc));
        vm.stopPrank();

        uint256 spUsdcUsdcBefore   = usdc.balanceOf(address(spUsdc));
        uint256 spUsdcSupplyBefore = spUsdc.totalSupply();
        _processRedeems(type(uint256).max, type(uint256).max);
        uint256 a = _pAssets(third);
        assertEq(a, 999_999_999_998);
        assertEq(vault.claimableAssets(bl), a);
        assertEq(vault.totalClaimable(), a);
        assertEq(usdc.balanceOf(address(vault)), a);
        assertEq(usdc.balanceOf(address(someContract)), a);
        assertEq(vault.claimableAssets(address(someContract)), 0);
        // spUSDC as recipient: liquidity falls by the two real payouts only, shares burned by 3.
        assertEq(usdc.balanceOf(address(spUsdc)), spUsdcUsdcBefore - 2 * a);
        assertEq(spUsdc.totalSupply(), spUsdcSupplyBefore - 3 * _divUp(a * RAY, CHI_S));
        assertEq(vault.claimableAssets(address(spUsdc)), 0);
        assertEq(vault.firstPendingRedeemId(), 3);

        // Cancellation fallback to the blacklisted EOA, then the vault itself is blacklisted:
        // the fallback's `redeem(.., vault, vault)` reverts in USDC and the WHOLE call reverts.
        _setCapacity(vault.totalSupply());
        uint256 id = _deposit(bob, 100e6);
        vm.prank(bob);
        vault.requestDepositCancellation(id, bl, _sShares(100e6));
        _blacklist(address(vault));
        vm.prank(operator);
        vm.expectRevert(BLACKLISTED);
        vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);
        // ... and the escrow already credited cannot be claimed while the vault is blacklisted.
        _unblacklist(bl);
        vm.expectRevert(BLACKLISTED);
        vault.claim(bl);
        _unblacklist(address(vault));
        assertEq(vault.claim(bl), a);
        assertEq(vault.totalClaimable(), 0);
        _blacklist(bl);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(bl), _sAssets(_sShares(100e6)));
        assertEq(vault.totalClaimable(), 99_999_999);
        assertEq(usdc.balanceOf(address(vault)), 99_999_999);
    }

    function BLACKLISTED_EOA() internal returns (address who) {
        who = makeAddr("blacklisted");
        if (!usdc.isBlacklisted(who)) _blacklist(who);
    }

    // totalClaimable == sum(claimableAssets) and == USDC held by the vault under random
    // interleavings of direct payouts, fallback payouts, deposits and claims.
    function testFuzz_property_totalClaimable_tracksEscrowExactly(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        uint256[3] memory credited;
        _blacklist(carol);                             // carol is the fallback recipient
        _deposit(alice, ONE_M);
        _deposit(bob,   ONE_M);
        for (uint256 step; step < 20; ++step) {
            uint256 r  = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 6;
            address u  = users[(r >> 8) % 2];          // alice or bob act
            address to = users[(r >> 16) % 3];         // any recipient incl. carol
            if (op == 0) {
                uint256 bal = vault.balanceOf(u);
                if (bal != 0) {
                    vm.prank(u);
                    vault.requestRedeem((r >> 24) % bal + 1, to);
                }
            } else if (op == 1) {
                _processRedeems((r >> 24) % 500_000e6 + 1, 3);
            } else if (op == 2) {
                _setCapacity(0);
                uint256 id = _deposit(u, (r >> 24) % 100_000e6 + 2);
                ( , , uint256 sh ) = _depositRequest(id);
                vm.prank(u);
                vault.requestDepositCancellation(id, to, sh);
                _setCapacity(type(uint128).max);
            } else if (op == 3) {
                _processCancelledDeposits(type(uint256).max, 2);
            } else if (op == 4) {
                _deposit(u, (r >> 24) % 50_000e6 + 2);
            } else {
                _unblacklist(carol);
                if (vault.claimableAssets(carol) != 0) vault.claim(carol);
                _blacklist(carol);
            }
            uint256 sum;
            for (uint256 i; i < 3; ++i) sum += vault.claimableAssets(users[i]);
            assertEq(vault.totalClaimable(), sum, "totalClaimable != sum");
            assertEq(usdc.balanceOf(address(vault)), sum, "escrow != USDC held");
            // Only the blacklisted recipient ever gets credited.
            assertEq(vault.claimableAssets(alice), 0);
            assertEq(vault.claimableAssets(bob), 0);
            credited[2] = vault.claimableAssets(carol);
        }
    }

    /**********************************************************************************************/
    /*** R6-5. Roles: LOSS_MANAGER as a hot wallet, UNPAUSER vs PAUSER, operator rate+process   ***/
    /**********************************************************************************************/

    // `adjustTotalAssets` has no bound relative to totalAssets. A compromised LOSS_MANAGER during
    // any legitimate pause window (it cannot pause itself) can mark up chi by any factor and, once
    // unpaused, a dust position redeems ALL of the vault's liquid backing (the per-entry bound is
    // the vault's whole spUSDC balance). Exact: alice 1M, mal 1k, +1e12 USDC: mal drains ~1.001M.
    function test_BUG_lossManager_unboundedGain_dustHolderDrainsAllBacking() public {
        _deposit(alice, ONE_M);
        _deposit(mal,   1_000e6);
        uint256 malShares = vault.balanceOf(mal);
        uint256 ts = vault.totalSupply();
        uint256 ta = vault.totalAssets();

        _pause();
        _adjustTotalAssets(1e18);                      // +1_000_000_000_000 USDC "gain"
        _unpause();
        uint256 chiN = (ta + 1e18) * RAY / ts;
        assertEq(vault.chi(), chiN);
        assertGt(vault.assetsOf(mal), 9e14);           // on paper mal holds ~1e9 USDC

        _requestRedeem(mal, malShares);
        uint256 L = vault.availableLiquidAssets();     // everything the vault can withdraw
        assertEq(L, _sAssets(_vaultSpUsdc()));
        _processRedeems(type(uint256).max, type(uint256).max);
        uint256 fillable = L * RAY / chiN;
        uint256 paid     = fillable * chiN / RAY;
        assertEq(usdc.balanceOf(mal), paid);
        // alice's 1M + mal's 1k minus < 1 USDC (fillable floors at the inflated chi).
        assertEq(usdc.balanceOf(mal), 1_000_998_999_890);
        assertLt(vault.availableLiquidAssets(), 2_000_000);   // ~1 USDC (one share at chiN) left
        assertEq(vault.firstPendingRedeemId(), 0);     // mal's entry still "owed" the rest
        // alice: on paper rich, in practice unbacked.
        _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertLt(usdc.balanceOf(alice), 2_000_000);
        emit log_named_uint("alice recovers (USDC wei)", usdc.balanceOf(alice));
    }

    // A gain that pushes chi above 2^256 / RAY (allowed: the check is uint192.max) bricks every
    // path that drips, including adjustTotalAssets itself (it drips first) and the view
    // `nowChi()`: only an upgrade can recover. R5-1 / G-1 still open, proven end to end.
    function test_BUG_adjustTotalAssets_chiAboveDripBound_bricksVaultPermanently() public {
        _deposit(alice, ONE_M);
        uint256 ts = vault.totalSupply();
        uint256 targetChi = type(uint256).max / RAY + 1;      // 1 above the drip multiply bound
        assertLt(targetChi, type(uint192).max);
        uint256 targetTA = _divUp(targetChi * ts, RAY);
        int256 delta = int256(targetTA) - int256(vault.totalAssets());

        _pause();
        _adjustTotalAssets(delta);                     // accepted: chi <= uint192.max
        assertGe(vault.chi(), targetChi);
        assertEq(vault.rho(), block.timestamp);        // packed write kept rho

        _warp(1);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.drip();
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.nowChi();
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.assetsOf(alice);
        vm.prank(lossManager);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.adjustTotalAssets(-delta);               // cannot be undone
        _unpause();
        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.requestDeposit(1e6, bob, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.requestRedeem(1, alice);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.processPendingRedeems(1, 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.setVSR(RAY);
        // The dripless paths still work: transfers, take, pause/unpause, upgrade.
        vm.prank(alice);
        vault.transfer(bob, 1);
        _takeAll();
        address v2 = address(new SparkPrimeVaultV2Mock());
        vm.prank(admin);
        vault.upgradeToAndCall(v2, "");
    }

    function test_property_pauserAndUnpauser_areDisjoint_andUnpauseFrontrunsLoss() public {
        vm.prank(pauser);
        vm.expectRevert(_unauthorized(pauser, UNPAUSER_ROLE));
        vault.unpause();
        vm.prank(unpauser);
        vm.expectRevert(_unauthorized(unpauser, PAUSER_ROLE));
        vault.pause();
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, PAUSER_ROLE));
        vault.pause();
        vm.prank(lossManager);
        vm.expectRevert(_unauthorized(lossManager, PAUSER_ROLE));
        vault.pause();

        _deposit(alice, ONE_M);
        _pause();
        _pause();                                      // idempotent
        _unpause();                                    // unpauser front-runs the loss tx
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(-1);
        _unpause();                                    // idempotent too
        assertFalse(vault.paused());
    }

    // The operator sets the rate AND processes; a VSR change has no same-block effect on a fill,
    // and cannot exceed the admin's bounds. Operator cannot touch the fee, minimums or losses.
    function test_property_operator_rateChangeHasNoSameBlockEffect_andIsBounded() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, 100_000_000);
        _setPrimeVsr(MAX_VSR);
        assertEq(vault.nowChi(), CHI_P);               // same timestamp: unchanged
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), _pAssets(100_000_000));
        assertEq(usdc.balanceOf(alice), 100_968_776);
        vm.prank(admin);
        vault.setVSRBounds(RAY, FIVE_PCT_VSR);         // live vsr (MAX) is not clamped (R5-11)
        assertEq(vault.vsr(), MAX_VSR);
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.VSRTooHigh.selector);
        vault.setVSR(TEN_PCT_VSR);
        vm.prank(operator);
        vm.expectRevert(_unauthorized(operator, REDEEM_FEE_SETTER_ROLE));
        vault.setRedeemFeeRate(1);
        vm.prank(operator);
        vm.expectRevert(_unauthorized(operator, LOSS_MANAGER_ROLE));
        vault.adjustTotalAssets(-1);
        vm.prank(operator);
        vm.expectRevert(_unauthorized(operator, DEFAULT_ADMIN_ROLE));
        vault.setMinDeposit(1);
    }

    /**********************************************************************************************/
    /*** R6-6. transferFrom ordering, initialize minimums, zero admin, rho/chi repack, Referral  ***/
    /**********************************************************************************************/

    function test_property_transferFrom_balanceCheckedBeforeAllowance() public {
        _deposit(alice, ONE_M);
        vm.prank(alice);
        vault.approve(bob, 5);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.transferFrom(alice, carol, SH_1M + 1);   // balance first, even with no allowance
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-allowance");
        vault.transferFrom(alice, carol, 6);
        vm.prank(bob);
        vault.transferFrom(alice, carol, 5);
        assertEq(vault.allowance(alice, bob), 0);
        assertEq(vault.balanceOf(carol), 5);
        // Infinite allowance is not decremented.
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);
        vm.prank(bob);
        vault.transferFrom(alice, carol, 5);
        assertEq(vault.allowance(alice, bob), type(uint256).max);
    }

    function test_property_initialize_rejectsZeroMinimums_acceptsZeroAdmin() public {
        address impl = address(new SparkPrimeVault());
        bytes memory z1 = abi.encodeCall(ISparkPrimeVault.initialize, (address(spUsdc), "x", "x", admin, 0, 1, 1));
        bytes memory z2 = abi.encodeCall(ISparkPrimeVault.initialize, (address(spUsdc), "x", "x", admin, 1, 0, 1));
        bytes memory z3 = abi.encodeCall(ISparkPrimeVault.initialize, (address(spUsdc), "x", "x", admin, 1, 1, 0));
        vm.expectRevert(ISparkPrimeVault.ZeroMinDeposit.selector);
        new ERC1967Proxy(impl, z1);
        vm.expectRevert(ISparkPrimeVault.ZeroMinDepositCancellation.selector);
        new ERC1967Proxy(impl, z2);
        vm.expectRevert(ISparkPrimeVault.ZeroMinRedeem.selector);
        new ERC1967Proxy(impl, z3);
        // Unbounded above, and a zero admin is accepted (R5-6 still open): an admin-less vault.
        SparkPrimeVault v = SparkPrimeVault(address(new ERC1967Proxy(impl, abi.encodeCall(
            ISparkPrimeVault.initialize,
            (address(spUsdc), "x", "x", address(0), type(uint256).max, type(uint256).max, type(uint256).max)
        ))));
        assertTrue(v.hasRole(DEFAULT_ADMIN_ROLE, address(0)));
        assertEq(v.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(v.minDeposit(), type(uint256).max);
        assertEq(usdc.allowance(address(v), address(spUsdc)), type(uint256).max);
        assertEq(v.decimals(), 6);
        // Zero setters rejected too.
        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.ZeroMinRedeem.selector);
        vault.setMinRedeem(0);
    }

    function test_BUG_adjustTotalAssets_zeroSupply_panicsDivByZero() public {
        assertEq(vault.totalSupply(), 0);
        _pause();
        vm.prank(lossManager);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x12));
        vault.adjustTotalAssets(1);
    }

    // rho (uint64, offset 0) and chi (uint192, offset 8) share slot 7; every writer of one keeps
    // the other.
    function test_property_rhoChiRepack_slot7_writesPreserveEachOther() public {
        address V = address(vault);
        uint256 rho0 = vault.rho();
        assertEq(uint256(vm.load(V, bytes32(uint256(7)))), rho0 | (CHI_P << 64));
        _deposit(alice, ONE_M);
        _pause();
        _warp(10);
        _adjustTotalAssets(-1);                        // drips (rho = now) then writes chi only
        assertEq(vault.rho(), block.timestamp);
        assertEq(uint256(vm.load(V, bytes32(uint256(7)))), block.timestamp | (uint256(vault.chi()) << 64));
        assertEq(vault.chi(), (ASSETS_1M - 1) * RAY / SH_1M);
        _unpause();
        _setPrimeVsr(FIVE_PCT_VSR);
        _warp(365 days);
        uint192 nChi = vault.drip();
        assertEq(uint256(vm.load(V, bytes32(uint256(7)))), block.timestamp | (uint256(nChi) << 64));
        assertEq(vault.drip(), nChi);                  // idempotent same block
    }

    event Referral(uint16 indexed referral, uint256 indexed requestId, address owner, address recipient, uint256 assets);

    // Referral is emitted at request time with the request id; cancel loops still inflate it and
    // a request for someone else attaches a code to them. Off-chain accounting must use `Deposit`.
    function test_info_referral_emittedOnRequest_cancelLoopInflates() public {
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());
        _fund(mal, ONE_M + 3);
        for (uint256 i; i < 3; ++i) {
            vm.expectEmit(true, true, true, true);
            emit Referral(777, 1 + i, mal, victim, ONE_M);
            vm.prank(mal);
            uint256 id = vault.requestDeposit(ONE_M, victim, 777);  // attaches 777 to victim
            assertEq(id, 1 + i);
            vm.prank(mal);
            vault.requestDepositCancellation(id, mal, S_1M);         // refund to mal, not victim
            _processCancelledDeposits(type(uint256).max, type(uint256).max);
        }
        assertEq(vault.balanceOf(victim), 0);
        assertEq(usdc.balanceOf(mal), ONE_M);
    }

    /**********************************************************************************************/
    /**********************************************************************************************/
    /*** R5 port                                                                                ***/
    /**********************************************************************************************/
    /**********************************************************************************************/

    /**********************************************************************************************/
    /*** FE-2. setCapacity above the overflow threshold bricks deposit fills AND cancels (:864) ***/
    /**********************************************************************************************/

    // `convertToAssets(availableCapacity())` is `cap * chi / RAY` in checked uint256. Threshold
    // with totalSupply == 0 is exactly `type(uint256).max / chi`. "Unlimited" capacity makes
    // `requestDeposit` (instant-fill path), `processPendingDeposits` AND NOW
    // `requestDepositCancellation` (its self-skip walk runs the same line) revert with Panic 0x11:
    // queued depositors cannot even cancel until the operator lowers the cap.
    function test_BUG_setCapacity_uint256Max_bricksDepositFillsAndCancels() public {
        uint256 threshold = type(uint256).max / CHI_P;

        _setCapacity(threshold);
        _fund(alice, ONE_M);
        vm.prank(alice);
        vault.requestDeposit(ONE_M, alice, 0);
        assertEq(vault.balanceOf(alice), _pShares(_sAssets(_sShares(ONE_M))));
        assertEq(vault.balanceOf(alice), SH_1M);

        _setCapacity(0);
        uint256 idB = _deposit(bob, ONE_M);            // queued
        _setCapacity(type(uint256).max);

        // A newcomer behind bob only queues (no instant-fill walk), so it does not revert ...
        uint256 idC = _deposit(carol, ONE_M);
        assertEq(idC, 2);
        assertEq(vault.balanceOf(carol), 0);

        // ... but every fill path and every cancel path does.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));   // NEW on c512609
        vault.requestDepositCancellation(idB, bob, S_1M);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.requestDepositCancellation(idC, carol, 1);

        // Exact edge: cap = threshold + totalSupply works, +1 panics.
        uint256 ts = vault.totalSupply();
        _setCapacity(threshold + ts + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.requestDepositCancellation(idB, bob, S_1M);
        _setCapacity(threshold + ts);
        vm.prank(bob);
        vault.requestDepositCancellation(idB, bob, S_1M);
        assertEq(vault.firstPendingDepositId(), idC);  // walked past bob, stopped at carol
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.balanceOf(carol), SH_1M);
        // With the queue empty, a fresh depositor hits the instant-fill walk and panics again.
        _setCapacity(type(uint256).max);
        _fund(mal, 1e6);
        vm.prank(mal);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.requestDeposit(1e6, mal, 0);
    }

    /**********************************************************************************************/
    /*** FE-3. Ghost entries at the head are now cleared at cancel time (self-skip)             ***/
    /**********************************************************************************************/

    // Round 5: request-then-cancel left ghosts the next depositor paid to walk. Now a cancel of the
    // head entry walks itself and every ghost behind it, and zero-asset requests are impossible
    // with `minDeposit != 0`. Pinned with launch-like minDeposit.
    function test_fixed_ghostsAtHead_clearedByCancelSelfSkip() public {
        _setMinDeposit(1_000e6);
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());
        _fund(mal, 1_000e6 + 5);
        for (uint256 i; i < 5; ++i) {
            vm.prank(mal);
            uint256 id = vault.requestDeposit(1_000e6, mal, 0);
            assertEq(vault.firstPendingDepositId(), id);
            vm.prank(mal);
            vault.requestDepositCancellation(id, mal, 954_532_691);
            assertEq(vault.firstPendingDepositId(), id + 1);    // walked past itself
            _processCancelledDeposits(type(uint256).max, type(uint256).max);
        }
        assertEq(usdc.balanceOf(mal), 1_000e6);
        assertEq(vault.getPendingDepositRequests().length, 0);
        assertEq(_rawLength(SLOT_DEPOSITS), 6);
        // The next depositor walks nothing: baseline gas.
        _setCapacity(type(uint128).max);
        _fund(bob, 1_000e6);
        vm.cool(address(vault));
        vm.prank(bob);
        uint256 g0 = gasleft();
        vault.requestDeposit(1_000e6, bob, 0);
        uint256 g = g0 - gasleft();
        emit log_named_uint("deposit gas after 5 cleared ghosts", g);
        assertLt(g, 400_000);
        assertEq(vault.firstPendingDepositId(), 7);
        // Zero-asset requests are gone.
        vm.prank(mal);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(0, mal, 0);
    }

    // 1 wei of USDC (the harness minDeposit) mints 0 spUSDC shares: a zero-share entry is pushed,
    // the instant-fill predicate (0 == 0) walks it immediately, the wei is donated to spUSDC and
    // nothing can be cancelled (NoRequest). R5-15 residue: harmless, launch minDeposit prevents it.
    function test_info_oneWeiDeposit_zeroShareEntry_isWalkedAndUncancellable() public {
        _fund(mal, 1);
        vm.prank(mal);
        uint256 id = vault.requestDeposit(1, mal, 0);
        assertEq(id, 0);
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(_rawLength(SLOT_DEPOSITS), 1);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(usdc.balanceOf(address(spUsdc)), 1);
        assertEq(spUsdc.totalSupply(), 0);
        vm.prank(mal);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, mal, 1);
    }

    /**********************************************************************************************/
    /*** Instant-fill predicate cannot fill a newcomer ahead of a live entry                    ***/
    /**********************************************************************************************/

    function test_property_instantFill_neverSkipsLiveEntry_partialHeadThenCancel() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, ONE_M);      // queued
        uint256 idB = _deposit(bob,   500_000e6);  // queued behind alice

        _setCapacity(_pShares(300_000e6));
        _processDeposits(type(uint256).max, type(uint256).max);
        ( , , uint256 remA ) = vault.getPendingDepositRequest(idA);
        assertGt(remA, 0);
        assertEq(vault.firstPendingDepositId(), idA);
        assertEq(vault.balanceOf(bob), 0);

        _cancelAll(alice, idA);                    // head deleted, walk stops at bob (live)
        assertEq(vault.firstPendingDepositId(), idB);
        assertEq(vault.pendingDepositSavingsShares(), _sShares(500_000e6));

        _setCapacity(type(uint128).max);
        uint256 idC = _deposit(carol, 100e6);
        assertEq(vault.balanceOf(carol), 0, "carol must not jump the queue");
        assertEq(idC, 2);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(bob), _pShares(_sAssets(_sShares(500_000e6))));
        assertEq(vault.balanceOf(carol), 0);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(carol), _pShares(_sAssets(_sShares(100e6))));
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(), 3);
    }

    /**********************************************************************************************/
    /*** Queue accounting: counters == array sums under random ops incl. partial cancels (fuzz) ***/
    /**********************************************************************************************/

    function testFuzz_property_queueCountersMatchArrays(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        uint256[] memory open = new uint256[](64);
        uint256 nOpen;

        _setCapacity(0);
        for (uint256 step; step < 24; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address u = users[r % 3];
            uint256 op = (r >> 8) % 7;
            if (op < 3) {
                uint256 amt = ((r >> 16) % 2_000_000e6) + 2;
                uint256 id = _deposit(u, amt);
                if (nOpen < 64) open[nOpen++] = id;
            } else if (op == 3 && nOpen > 0) {
                uint256 k = (r >> 16) % nOpen;
                if (open[k] >= vault.firstPendingDepositId()) {
                    ( address owner, , uint256 sh ) = _depositRequest(open[k]);
                    if (sh != 0) {
                        uint256 part = (r >> 40) % 2 == 0 ? sh : (r >> 48) % sh + 1;  // full or slice
                        vm.prank(owner);
                        vault.requestDepositCancellation(open[k], owner, part);
                        if (part != sh) continue;      // keep the sliced entry open
                    }
                }
                open[k] = open[--nOpen];
            } else if (op == 4) {
                _setCapacity(vault.totalSupply() + ((r >> 16) % 1_000_000e6));
                _processDeposits((r >> 64) % 3_000_000e6 + 1, (r >> 128) % 5 + 1);
            } else if (op == 5) {
                _processCancelledDeposits((r >> 64) % 3_000_000e6 + 1, (r >> 128) % 5 + 1);
            } else {
                uint256 bal = vault.balanceOf(u);
                if (bal != 0) {
                    _requestRedeem(u, (r >> 16) % bal + 1);
                    _processRedeems((r >> 64) % bal + 1, 2);
                }
            }
            assertEq(vault.pendingDepositSavingsShares(),          _sumDeposits(), "dep counter");
            assertEq(vault.pendingCancelledDepositSavingsShares(), _sumCancels(),  "cancel counter");
            assertEq(vault.pendingRedeemShares(),                  _sumRedeems(),  "redeem counter");
            assertEq(vault.pendingRedeemShares(), vault.balanceOf(address(vault)), "escrow");
            assertGe(
                _vaultSpUsdc(),
                vault.pendingDepositSavingsShares() + vault.pendingCancelledDepositSavingsShares(),
                "queue backing"
            );
            assertLe(vault.firstPendingDepositId(), _rawLength(SLOT_DEPOSITS));
            assertLe(vault.firstPendingDepositCancellationId(), _rawLength(SLOT_CANCELS));
            assertLe(vault.firstPendingRedeemId(), _rawLength(SLOT_REDEEMS));
            for (uint256 i; i < vault.firstPendingDepositId(); ++i) {
                assertEq(_rawShares(SLOT_DEPOSITS, i), 0, "live deposit below head");
            }
            for (uint256 i; i < vault.firstPendingDepositCancellationId(); ++i) {
                assertEq(_rawShares(SLOT_CANCELS, i), 0, "live cancel below head");
            }
            // The head of the deposit queue is never a ghost unless the queue is empty.
            uint256 h = vault.firstPendingDepositId();
            if (h < _rawLength(SLOT_DEPOSITS)) {
                // Ghost heads are possible only when a ghost sits behind a live entry that was
                // then filled with maxRequests_ exhausted; the next walk clears it. Just pin it.
                _processDeposits(0, type(uint256).max);
                h = vault.firstPendingDepositId();
                if (h < _rawLength(SLOT_DEPOSITS)) assertGt(_rawShares(SLOT_DEPOSITS, h), 0, "ghost head");
            }
        }
    }

    /**********************************************************************************************/
    /*** Cancellation batches never revert on rounding                                          ***/
    /**********************************************************************************************/

    function testFuzz_property_cancellationBatch_neverRevertsOnRounding(uint256 seed) public {
        _setCapacity(0);
        uint256 n = 2 + seed % 6;
        for (uint256 i; i < n; ++i) {
            uint256 amt = uint256(keccak256(abi.encode(seed, i))) % 500_000e6 + 2;
            uint256 id = _deposit(alice, amt);
            ( , , uint256 sh ) = _depositRequest(id);
            // Random slice then the rest: two cancellation entries per deposit.
            uint256 part = uint256(keccak256(abi.encode(seed, i, "p"))) % sh + 1;
            _cancelPart(alice, id, part);
            if (part != sh) _cancelPart(alice, id, sh - part);
        }
        if (seed % 2 == 0) _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) / 2);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        if (seed % 2 == 1) assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), _sumCancels());
        assertEq(vault.firstPendingDepositId(), _rawLength(SLOT_DEPOSITS));   // all walked
    }

    /**********************************************************************************************/
    /*** FE-4 / R5-2. adjustTotalAssets gain sandwich (deposit before pause), quantified        ***/
    /**********************************************************************************************/

    function test_BUG_adjustTotalAssets_gainSandwich_depositBeforePause() public {
        _deposit(alice, ONE_M);
        _deposit(mal,   ONE_M);
        uint256 malShares = vault.balanceOf(mal);
        assertEq(malShares, SH_1M);

        uint256 ts   = vault.totalSupply();
        uint256 chiN = (vault.totalAssets() + 10_000e6) * RAY / ts;
        _pause();
        _adjustTotalAssets(10_000e6);
        _unpause();
        assertEq(vault.chi(), chiN);

        uint256 malAssets = vault.assetsOf(mal);
        assertEq(malAssets, malShares * chiN / RAY);
        assertEq(malAssets, 1_004_999_999_998);
        assertEq(vault.assetsOf(alice), 1_004_999_999_998);

        uint256 snap = vm.snapshotState();
        _requestRedeem(mal, malShares);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(mal), 1_004_999_999_998);
        vm.revertToState(snap);

        _setRedeemFeeRate(0.01e18);
        _requestRedeem(mal, malShares);
        _processRedeems(type(uint256).max, type(uint256).max);
        uint256 fee = _divUp(malShares * 0.01e18, WAD);
        assertEq(fee, 9_904_051_842);
        assertEq(usdc.balanceOf(mal), (malShares - fee) * chiN / RAY);
        assertLt(usdc.balanceOf(mal), ONE_M);
    }

    /**********************************************************************************************/
    /*** FE-5 / R5-5. Redeem liquidity is not ring-fenced from queued-deposit backing           ***/
    /**********************************************************************************************/

    function test_BUG_redeemsConsumeQueuedDepositBacking_cancellerStuck() public {
        _deposit(alice, ONE_M);
        _takeAll();
        assertEq(_vaultSpUsdc(), 0);

        _setCapacity(vault.totalSupply());
        uint256 idB = _deposit(bob, ONE_M);
        assertEq(_vaultSpUsdc(), S_1M);
        assertEq(vault.availableLiquidAssets(), _sAssets(S_1M));

        _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, type(uint256).max);
        uint256 filled = _pShares(_sAssets(S_1M));
        uint256 paidA  = _pAssets(filled);
        assertEq(usdc.balanceOf(alice), paidA);
        assertEq(paidA, ASSETS_1M);
        assertEq(_vaultSpUsdc(), 0);
        assertEq(filled, SH_1M);

        _cancelAll(bob, idB);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(vault.firstPendingDepositCancellationId(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);

        _returnToVault(S_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), 999_999_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
    }

    /**********************************************************************************************/
    /*** Fee cannot be bypassed; zero-share redeem entries (R5-14) are harmless                 ***/
    /**********************************************************************************************/

    function test_property_redeemFee_notBypassableByTransferOrRecipient() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, ONE_M);
        vm.prank(alice);
        vault.transfer(bob, SH_1M);
        vm.prank(bob);
        vault.requestRedeem(SH_1M, carol);
        uint256 fee = _divUp(SH_1M * 0.01e18, WAD);
        assertEq(fee, 9_904_051_842);
        assertEq(vault.totalSupply(), SH_1M - fee);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(carol), _pAssets(SH_1M - fee));
        assertEq(usdc.balanceOf(carol), 989_999_999_997);
    }

    function test_BUG_oneWeiRedeemWithFee_isAllFee_zeroShareEntryQueued() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, ONE_M);
        uint256 id = _requestRedeem(alice, 1);     // minRedeem == 1: fee divUp(1 * 1e16, 1e18) = 1
        ( , , uint256 sh ) = _redeemRequest(id);
        assertEq(sh, 0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(_rawLength(SLOT_REDEEMS), 1);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(id, bob);
        // The zero entry at the head is "filled" by a loop that touches it: no break, delete,
        // head moves. It still costs the operator one iteration.
        uint256 id2 = _requestRedeem(alice, 1_000);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingRedeemId(), id2 + 1);
        assertEq(usdc.balanceOf(alice), _pAssets(990));
    }

    /**********************************************************************************************/
    /*** Blacklist: owner-side evasion, vault blacklisted, claimable escrow invariants          ***/
    /**********************************************************************************************/

    function test_info_blacklistedOwner_canStillExitViaCleanRecipient() public {
        _deposit(alice, ONE_M);
        uint256 half = vault.balanceOf(alice) / 2;
        uint256 id = _requestRedeem(alice, half);
        _blacklist(alice);

        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);
        vm.prank(alice);
        vault.requestRedeem(half, carol);
        uint256 rest = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(mal, rest);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),   _pAssets(half));
        assertEq(usdc.balanceOf(carol), _pAssets(half));
        assertEq(vault.claimableAssets(alice), 0);
    }

    function test_info_vaultBlacklisted_redeemsAndCancelsStillPay_depositsAndClaimsDont() public {
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());
        uint256 idB = _deposit(bob, 100e6);
        uint256 idR = _requestRedeem(alice, 1_000_000);
        _fund(carol, 1e6);
        _blacklist(address(vault));

        vm.prank(carol);
        vm.expectRevert(BLACKLISTED);
        vault.requestDeposit(1e6, carol, 0);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), _pAssets(1_000_000));
        assertEq(_rawShares(SLOT_REDEEMS, idR), 0);
        _cancelAll(bob, idB);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), 99_999_999);
    }

    function test_property_claimableEscrow_untouchedByDeposits_exactWei() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_1M);
        _blacklist(alice);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(alice), ASSETS_1M);
        assertEq(vault.totalClaimable(), ASSETS_1M);
        assertEq(usdc.balanceOf(address(vault)), ASSETS_1M);

        _deposit(bob, 123_456e6);
        assertEq(usdc.balanceOf(address(vault)), ASSETS_1M);
        _requestRedeem(bob, vault.balanceOf(bob));
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(address(vault)), ASSETS_1M);

        vm.expectRevert(BLACKLISTED);
        vault.claim(alice);
        _unblacklist(alice);
        vm.prank(mal);
        assertEq(vault.claim(alice), ASSETS_1M);
        assertEq(usdc.balanceOf(alice), ASSETS_1M);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalClaimable(), 0);
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(alice);
    }

    /**********************************************************************************************/
    /*** Take-all stalls every settlement without reverting; returns resume it                 ***/
    /**********************************************************************************************/

    function test_property_takeAll_settlementsAreNoOps_notReverts() public {
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());
        uint256 idB = _deposit(bob, 100e6);
        _setCapacity(type(uint128).max);
        _requestRedeem(alice, SH_1M);
        _cancelAll(bob, idB);
        _takeAll();

        _processRedeems(type(uint256).max, type(uint256).max);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(vault.firstPendingDepositCancellationId(), 0);

        _deposit(carol, 10e6);
        assertEq(vault.balanceOf(carol), _pShares(_sAssets(_sShares(10e6))));
        assertEq(_vaultSpUsdc(), _sShares(10e6));

        _returnToVault(S_1M + _sShares(100e6));
        _processRedeems(type(uint256).max, type(uint256).max);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), ASSETS_1M);
        assertEq(usdc.balanceOf(bob), 99_999_999);
    }

    /**********************************************************************************************/
    /*** spUSDC failure modes: deposit cap, drained liquidity, FE-1 dust                        ***/
    /**********************************************************************************************/

    function test_property_spUsdcDepositCap_propagatesAsRevert() public {
        uint256 cap = spUsdc.totalAssets() + 500_000e6;
        vm.prank(spAdmin);
        spUsdc.setDepositCap(cap);
        _fund(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert("SparkVault/deposit-cap-exceeded");
        vault.requestDeposit(ONE_M, alice, 0);
        vm.prank(alice);
        vault.requestDeposit(500_000e6, alice, 0);
        assertEq(vault.balanceOf(alice), _pShares(_sAssets(_sShares(500_000e6))));
    }

    // FE-1 / R5-10 still open with the per-entry bound: each partial fill ceil-burns spUSDC while
    // the liability is floored, so the last slice is bounded 1 share below what is owed and the
    // head keeps 1 share nobody can pay until spUSDC arrives from outside. The loop now RUNS
    // (`fillable_ == 0` -> break) but the outcome is identical; the deficit migrates to bob.
    function test_BUG_partialFills_leaveUnpayableDustAtRedeemHead() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_1M);

        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 250_000e6);
        assertEq(vault.availableLiquidAssets(), 250_000e6);
        _processRedeems(type(uint256).max, type(uint256).max);
        uint256 f1 = _pShares(250_000e6);
        uint256 a1 = _pAssets(f1);
        uint256 b1 = _divUp(a1 * RAY, CHI_S);
        assertEq(a1, 249_999_999_999);
        assertEq(_vaultSpUsdc(), S_1M - b1);
        assertEq(vault.firstPendingRedeemId(), 0);

        _returnSpUsdcLiquidity(ONE_M);
        uint256 owedAssets = _pAssets(SH_1M - f1);
        uint256 backing    = _sAssets(S_1M - b1);
        assertEq(backing, owedAssets);                 // value matches exactly ...
        assertEq(_pShares(backing), SH_1M - f1 - 1);   // ... but re-flooring loses 1 share
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.pendingRedeemShares(), 1);
        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(usdc.balanceOf(alice), 999_999_999_997);
        assertEq(_vaultSpUsdc(), 0);

        _processRedeems(type(uint256).max, type(uint256).max);   // fillable_ == 0 -> break
        assertEq(vault.firstPendingRedeemId(), 0);

        _deposit(bob, 100e6);
        uint256 shB = vault.balanceOf(bob);
        _requestRedeem(bob, shB);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingRedeemId(), 1);     // alice cleared out of bob's backing
        assertEq(usdc.balanceOf(alice), 999_999_999_998);
        assertEq(vault.pendingRedeemShares(), 1);      // bob now holds the dust
        assertEq(usdc.balanceOf(bob), _pAssets(shB) - 1);
        assertEq(usdc.balanceOf(bob), 99_999_997);
        assertEq(_vaultSpUsdc(), 1);                   // 1 spUSDC wei = 1 USDC wei = 0 shares
        assertEq(vault.convertToShares(vault.availableLiquidAssets()), 0);
    }

    function test_property_queuedEntries_accrueTheirOwnIndex() public {
        _setCapacity(0);
        _deposit(alice, ONE_M);
        _setSpUsdcVsr(TEN_PCT_VSR);
        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        uint256 a = vault.assetsOf(alice);
        assertGt(a, 1_099_999e6);
        assertLt(a, 1_100_001e6);
    }

    /**********************************************************************************************/
    /*** adjustTotalAssets is relative: spell lag drifts the target                             ***/
    /**********************************************************************************************/

    function test_info_adjustTotalAssets_relativeDelta_spellLagDrift() public {
        _deposit(alice, 100_000_000e6);
        _setPrimeVsr(FIVE_PCT_VSR);
        uint256 t0 = vault.totalAssets();
        int256 delta = 1_000_000e6;
        _warp(3 days);
        _pause();
        _adjustTotalAssets(delta);
        _unpause();
        uint256 drift = vault.totalAssets() - (t0 + 1_000_000e6);
        assertGt(drift, 40_000e6);
        assertLt(drift, 42_000e6);
    }

    /**********************************************************************************************/
    /*** ERC20 / permit / ERC1271                                                               ***/
    /**********************************************************************************************/

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal view returns (bytes32)
    {
        return keccak256(abi.encodePacked(
            "\x19\x01",
            vault.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(vault.PERMIT_TYPEHASH(), owner, spender, value, nonce, deadline))
        ));
    }

    function test_property_permit_eoa_nonceOnlyAdvancesOnSuccess() public {
        (address owner, uint256 pk) = makeAddrAndKey("owner");
        bytes32 digest = _permitDigest(owner, bob, 123, 0, block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner, bob, 124, block.timestamp, v, r, s);
        assertEq(vault.nonces(owner), 0);

        vault.permit(owner, bob, 123, block.timestamp, v, r, s);
        assertEq(vault.allowance(owner, bob), 123);
        assertEq(vault.nonces(owner), 1);

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner, bob, 123, block.timestamp, v, r, s);
        _warp(1);
        vm.expectRevert("SparkPrimeVault/permit-expired");
        vault.permit(owner, bob, 123, block.timestamp - 1, v, r, s);
    }

    function test_info_permit_acceptsMalleatedHighS_signature() public {
        (address owner, uint256 pk) = makeAddrAndKey("owner");
        bytes32 digest = _permitDigest(owner, bob, 5, 0, block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        uint256 N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 s2 = bytes32(N - uint256(s));
        uint8 v2 = v == 27 ? 28 : 27;
        vault.permit(owner, bob, 5, block.timestamp, v2, r, s2);
        assertEq(vault.allowance(owner, bob), 5);
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner, bob, 5, block.timestamp, v, r, s);
    }

    function test_property_permit_erc1271_contractOwner() public {
        ERC1271Wallet w = new ERC1271Wallet();
        bytes32 digest = _permitDigest(address(w), bob, 9, 0, block.timestamp);
        bytes memory sig = hex"deadbeef";
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(address(w), bob, 9, block.timestamp, sig);
        w.set(digest);
        vault.permit(address(w), bob, 9, block.timestamp, sig);
        assertEq(vault.allowance(address(w), bob), 9);
        bytes32 d2 = _permitDigest(address(w), bob, 10, 1, block.timestamp);
        w.set(d2);
        vault.permit(address(w), bob, 10, block.timestamp, 27, bytes32(uint256(1)), bytes32(uint256(2)));
        assertEq(vault.allowance(address(w), bob), 10);
    }

    function test_property_erc20_selfTransfer_andVaultTargets() public {
        _deposit(alice, ONE_M);
        vm.prank(alice);
        vault.transfer(alice, SH_1M);
        assertEq(vault.balanceOf(alice), SH_1M);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transfer(address(vault), 1);
        vm.prank(alice);
        vault.approve(bob, 10);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transferFrom(alice, address(vault), 1);
        vm.prank(alice);
        vault.transferFrom(alice, carol, SH_1M);
        assertEq(vault.balanceOf(carol), SH_1M);
        assertEq(vault.allowance(alice, bob), 10);
    }

    /**********************************************************************************************/
    /*** Initialization, upgrade authorization, storage layout                                  ***/
    /**********************************************************************************************/

    function test_property_initializer_cannotRerun_onProxyOrImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(address(spUsdc), "x", "x", mal, 1, 1, 1);
        SparkPrimeVault impl = SparkPrimeVault(vault.implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(spUsdc), "x", "x", mal, 1, 1, 1);
        address v2 = address(new SparkPrimeVaultV2Mock());
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        impl.upgradeToAndCall(v2, "");
    }

    function test_property_upgrade_adminOnly_statePreserved_slot29Appended() public {
        _deposit(alice, ONE_M);
        address v2 = address(new SparkPrimeVaultV2Mock());
        vm.prank(mal);
        vm.expectRevert(_unauthorized(mal, DEFAULT_ADMIN_ROLE));
        vault.upgradeToAndCall(v2, "");
        vm.prank(admin);
        vault.upgradeToAndCall(v2, abi.encodeCall(SparkPrimeVaultV2Mock.initializeV2, (42)));
        assertEq(vault.implementation(), v2);
        assertEq(SparkPrimeVaultV2Mock(address(vault)).newVar(), 42);
        // NOTE: the mock's comment still says slot 28; on c512609 `allowance` is 28
        //       (`totalClaimable` was inserted at 18) and the appended var lands in 29.
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(28)))), 0);
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(29)))), 42);
        assertEq(vault.balanceOf(alice), SH_1M);
        assertEq(vault.chi(), CHI_P);
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        SparkPrimeVaultV2Mock(address(vault)).initializeV2(43);
    }

    function test_property_storageLayout_c512609_pinned() public {
        _deposit(alice, ONE_M);
        uint256 id = _requestRedeem(alice, 1_000);
        assertEq(id, 0);
        address V = address(vault);
        assertEq(uint256(vm.load(V, bytes32(uint256(0)))), 1);   // _depositRequests.length
        assertEq(uint256(vm.load(V, bytes32(uint256(1)))), 0);   // _depositCancellationRequests
        assertEq(uint256(vm.load(V, bytes32(uint256(2)))), 1);   // _redeemRequests
        assertEq(address(uint160(uint256(vm.load(V, bytes32(uint256(3)))))), address(spUsdc));
        // 4: asset | paused (offset 20) | decimals (offset 21)
        assertEq(uint256(vm.load(V, bytes32(uint256(4)))), uint256(uint160(address(usdc))) | (6 << 168));
        _pause();
        assertEq(uint256(vm.load(V, bytes32(uint256(4)))), uint256(uint160(address(usdc))) | (1 << 160) | (6 << 168));
        _unpause();
        // 7: rho (uint64) | chi (uint192 at offset 8)
        assertEq(uint256(vm.load(V, bytes32(uint256(7)))), uint256(vault.rho()) | (CHI_P << 64));
        assertEq(uint256(vm.load(V, bytes32(uint256(8)))),  RAY);                 // vsr
        assertEq(uint256(vm.load(V, bytes32(uint256(9)))),  RAY);                 // minVSR
        assertEq(uint256(vm.load(V, bytes32(uint256(10)))), MAX_VSR);             // maxVSR
        assertEq(uint256(vm.load(V, bytes32(uint256(11)))), type(uint128).max);   // maxCapacity
        assertEq(uint256(vm.load(V, bytes32(uint256(12)))), 1);                   // minDeposit
        assertEq(uint256(vm.load(V, bytes32(uint256(13)))), 1);                   // minDepositCancellation
        assertEq(uint256(vm.load(V, bytes32(uint256(14)))), 1);                   // minRedeem
        assertEq(uint256(vm.load(V, bytes32(uint256(15)))), 0);                   // redeemFeeRate
        assertEq(uint256(vm.load(V, bytes32(uint256(16)))), 0.01e18);             // maxRedeemFeeRate
        assertEq(uint256(vm.load(V, bytes32(uint256(17)))), vault.totalSupply());
        assertEq(uint256(vm.load(V, bytes32(uint256(18)))), 0);                   // totalClaimable
        assertEq(uint256(vm.load(V, bytes32(uint256(19)))), 0);                   // pendingDepositSavingsShares
        assertEq(uint256(vm.load(V, bytes32(uint256(20)))), 0);                   // pendingCancelled
        assertEq(uint256(vm.load(V, bytes32(uint256(21)))), 1_000);               // pendingRedeemShares
        assertEq(uint256(vm.load(V, bytes32(uint256(22)))), 1);                   // firstPendingDepositId
        assertEq(uint256(vm.load(V, bytes32(uint256(23)))), 0);                   // firstPendingDepositCancellationId
        assertEq(uint256(vm.load(V, bytes32(uint256(24)))), 0);                   // firstPendingRedeemId
        assertEq(uint256(vm.load(V, keccak256(abi.encode(alice, uint256(25))))), vault.balanceOf(alice));
        assertEq(uint256(vm.load(V, keccak256(abi.encode(V, uint256(25))))), 1_000);
        vm.prank(alice);
        vault.approve(bob, 77);
        assertEq(uint256(vm.load(V, keccak256(abi.encode(bob, keccak256(abi.encode(alice, uint256(28))))))), 77);
        _blacklist(alice);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(uint256(vm.load(V, keccak256(abi.encode(alice, uint256(27))))), _pAssets(1_000));  // claimableAssets
        assertEq(uint256(vm.load(V, bytes32(uint256(18)))), _pAssets(1_000));     // totalClaimable
        bytes32 base = keccak256(abi.encode(uint256(2)));
        assertEq(address(uint160(uint256(vm.load(V, base)))), address(0));        // deleted after fill
        assertEq(uint256(vm.load(V, bytes32(uint256(base) + 2))), 0);
    }

    /**********************************************************************************************/
    /*** Index math: drip at MAX_VSR over long idle periods                                     ***/
    /**********************************************************************************************/

    function test_property_drip_maxVsr_survives60YearsIdle_overflowsAt77() public {
        _deposit(alice, ONE_M);
        _setPrimeVsr(MAX_VSR);
        uint256 snap = vm.snapshotState();
        _warp(60 * 365 days);
        vault.drip();
        assertGt(vault.chi(), CHI_P * (1 << 59));
        vm.revertToState(snap);
        _warp(77 * 365 days);
        vm.expectRevert();
        vault.drip();
    }

    /**********************************************************************************************/
    /*** Loss adjustment: who pays across the three queues (exact wei)                          ***/
    /**********************************************************************************************/

    function test_property_loss_hitsHoldersAndQueuedRedeemers_notQueuedDepositsOrCancels() public {
        _deposit(alice, ONE_M);
        _deposit(bob,   ONE_M);
        _requestRedeem(bob, vault.balanceOf(bob));
        _setCapacity(vault.totalSupply());
        uint256 idC = _deposit(carol, ONE_M);
        uint256 idD = _deposit(mal,   ONE_M);
        _cancelAll(mal, idD);
        uint256 ta = vault.totalAssets();
        assertEq(ta, 1_999_999_999_997);
        uint256 chiN = (ta - ta / 2) * RAY / (2 * SH_1M);

        _adjustTotalAssetsWhilePaused(-int256(ta / 2));
        assertEq(vault.chi(), chiN);

        assertEq(vault.assetsOf(alice), 499_999_999_999);
        assertEq(vault.assetsOf(address(vault)), 499_999_999_999);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), 499_999_999_999);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(mal), 999_999_999_999);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        uint256 carolShares = _sAssets(S_1M) * RAY / chiN;
        assertEq(vault.balanceOf(carol), carolShares);
        assertGe(vault.assetsOf(carol), 999_999_999_996);
        assertEq(_rawShares(SLOT_DEPOSITS, idC), 0);
    }

    /**********************************************************************************************/
    /*** FE-10. Vault as recipient is rejected everywhere (V2-13 fixed); spUSDC still accepted  ***/
    /**********************************************************************************************/

    function test_fixed_vaultAsRecipient_rejectedOnEveryPath() public {
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());
        uint256 idD = _deposit(bob, 100e6);
        uint256 idR = _requestRedeem(alice, 1_000);
        uint256 idC = _cancelPart(bob, idD, 1);
        address V = address(vault);
        _fund(carol, 1e6);

        vm.startPrank(carol);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDeposit(1e6, V, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDepositCancellation(idD, V, 1);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositRecipient(idD, V);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositCancellationRecipient(idC, V);
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestRedeem(1_000, V);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateRedeemRecipient(idR, V);
        vm.stopPrank();
        // Zero recipient likewise, and the vault's USDC escrow is untouched.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.requestRedeem(1_000, address(0));
        assertEq(usdc.balanceOf(V), 0);
    }

    function test_info_depositRecipientSpUsdc_strandsShares() public {
        _fund(alice, ONE_M);
        vm.prank(alice);
        vault.requestDeposit(ONE_M, address(spUsdc), 0);
        assertEq(vault.balanceOf(address(spUsdc)), SH_1M);   // nobody can ever move them
    }

    function test_fixed_requestDepositCancellation_outOfRange_revertsInvalidRequestId() public {
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.requestDepositCancellation(0, alice, 1);
        _deposit(alice, ONE_M);                        // id 0 filled, head 1
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);      // below head: deleted entry
        vault.requestDepositCancellation(0, alice, 1);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.requestDepositCancellation(1, alice, 1);
    }

}
