// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../../lib/forge-std/src/StdError.sol";

import { IAccessControl } from "../../lib/oz/contracts/access/IAccessControl.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";
import { ISparkPrimeVault } from "src/ISparkPrimeVault.sol";

/// @dev Tests for the surface that was new in rounds 3/4 and survived onto `master` @ 0ebb452:
///      owner-only recipient updaters (V2-1), the removed pauser cancel path (V2-2 / F-1),
///      unbounded `setCapacity`, `requestRedeem(0)` ghosts, the deferred head walk (no
///      head-advance loops any more), `delete` after fill, `pause` on GUARDIAN / `unpause` on
///      admin, getters and event shapes. `adjustTotalAssets` lives in `AdjustTotalAssets.t.sol`,
///      the blacklist surface in `Blacklist.t.sol`.
///
///      Harness indexes (frozen at RAY after setUp):
///        spUSDC  chi_s = 1.047633055711877768967605062e27
///        spPRIME chi_p = 1.009687768242461209408770821e27
abstract contract NewSurfaceBase is LocalTestBase {

    event DepositRequest(
        address indexed owner,
        address indexed recipient,
        uint256 indexed requestId,
        uint256         assetsDeposited,
        uint256         savingsSharesMinted
    );
    event Deposit(
        address indexed owner,
        address indexed recipient,
        uint256         assetsConverted,
        uint256         sharesMinted
    );
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
    event DepositRecipientUpdated(uint256 indexed requestId, address indexed recipient);
    event DepositCancellationRecipientUpdated(uint256 indexed requestId, address indexed recipient);
    event RedeemRecipientUpdated(uint256 indexed requestId, address indexed recipient);
    event Paused();
    event Unpaused();

    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address carol   = makeAddr("carol");
    address dave    = makeAddr("dave");
    address mallory = makeAddr("mallory");

    uint256 constant CHI_S = 1.047633055711877768967605062e27;
    uint256 constant CHI_P = 1.009687768242461209408770821e27;

    uint256 constant ONE_M     = 1_000_000e6;
    uint256 constant HUNDRED_K = 100_000e6;

    uint256 constant S_1M   = 954_532_691_143;
    uint256 constant S_100K = 95_453_269_114;
    uint256 constant A_1M   = 999_999_999_999;
    uint256 constant A_100K = 99_999_999_999;
    uint256 constant SH_1M   = 990_405_184_109;
    uint256 constant SH_100K = 99_040_518_410;

    // convertToAssets(SH_1M) and the spUSDC burned (ceil) to withdraw it.
    uint256 constant R_1M    = 999_999_999_998;
    uint256 constant RS_1M   = 954_532_691_143;
    uint256 constant R_100K  = 99_999_999_998;
    uint256 constant RS_100K = 95_453_269_113;

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _depositLength() internal view returns (uint256) {
        return _depositQueueLength();
    }

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, who, role
        );
    }

    function test_harnessConstants() public view {
        assertEq(spUsdc.nowChi(), CHI_S);
        assertEq(vault.nowChi(),  CHI_P);
        assertEq(spUsdc.convertToShares(ONE_M), S_1M);
        assertEq(spUsdc.convertToAssets(S_1M),  A_1M);
        assertEq(vault.convertToShares(A_1M),   SH_1M);
        assertEq(vault.convertToAssets(SH_1M),  R_1M);
        assertEq(vault.convertToAssets(SH_100K), R_100K);
    }

}

contract NewSurfaceTest is NewSurfaceBase {

    /**********************************************************************************************/
    /*** 11. Recipient updaters are owner-only (V2-1 fixed)                                     ***/
    /**********************************************************************************************/

    // `updateDepositRecipient` (:479-489): the owner redirects the fill and the exact spPRIME
    // amount that anyone used to be able to steal goes to the owner's choice.
    function test_fixed_V2_1_updateDepositRecipient_ownerRedirectsQueuedDeposit() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);

        ( address owner, address recipient, uint256 shares ) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    S_1M);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit DepositRecipientUpdated(id, bob);
        vault.updateDepositRecipient(id, bob);

        ( owner, recipient, shares ) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);

        vm.roll(block.number + 1);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.balanceOf(bob),   SH_1M);   // 990_405_184_109 spPRIME, ~999_999.99 USDC
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.firstPendingDepositId(), 1);
    }

    function test_updateDepositRecipient_strangerGuardianAdminAndRecipientRevert() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);

        address[4] memory who = [mallory, pauser, admin, operator];
        for (uint256 i; i < 4; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.updateDepositRecipient(id, who[i]);
        }

        // Being the current recipient grants nothing either: only `owner` may re-point.
        vm.prank(alice);
        vault.updateDepositRecipient(id, bob);
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositRecipient(id, mallory);

        ( address owner, address recipient, uint256 shares ) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.balanceOf(bob),     SH_1M);
        assertEq(vault.balanceOf(mallory), 0);
    }

    // A partially filled head entry still has `shares != 0`, so the owner can redirect the rest.
    function test_updateDepositRecipient_ownerRedirectsRemainderOfPartialFill() public {
        _setCapacity(SH_100K);  // room for ~100k of alice's 1M
        uint256 fillable = spUsdc.convertToShares(vault.convertToAssets(SH_100K));
        assertEq(fillable, S_100K - 2);
        uint256 id = _deposit(alice, ONE_M);
        uint256 aliceShares = vault.balanceOf(alice);
        assertEq(aliceShares, SH_100K - 2);
        ( ,, uint256 left ) = _depositRequest(id);
        assertEq(left, S_1M - fillable);

        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositRecipient(id, mallory);

        vm.prank(alice);
        vault.updateDepositRecipient(id, bob);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.balanceOf(alice), aliceShares);
        assertEq(vault.balanceOf(bob),   vault.totalSupply() - aliceShares);
        assertEq(vault.balanceOf(bob),   891_364_665_700);
        assertEq(vault.firstPendingDepositId(), 1);
    }

    // A filled entry is deleted (owner 0, shares 0): `no-request` fires before the owner check,
    // and nothing is written into the dead slot.
    function test_updateDepositRecipient_filledEntryRevertsNoRequest() public {
        uint256 id = _deposit(alice, ONE_M);  // instant fill, deleted
        assertEq(vault.balanceOf(alice), SH_1M);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositRecipient(id, bob);

        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositRecipient(id, mallory);

        ( address o, address r, uint256 s ) = _depositRequest(id);
        assertEq(o, address(0));
        assertEq(r, address(0));
        assertEq(s, 0);

        // The pending-only single getter rejects the id once the head moved past it.
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(id);
    }

    function test_updateDepositRecipient_cancelledEntryRevertsNoRequest() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        vault.requestDepositCancellation(id, alice);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositRecipient(id, bob);
    }

    // `updateDepositRecipient` (:481) still rejects the vault itself; the queued deposit path is
    // the only one that does.
    function test_updateDepositRecipient_vaultRecipientReverts() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositRecipient(id, address(vault));
    }

    // `updateRedeemRecipient` (:506-516): same shape, for the USDC paid on a queued redeem.
    function test_fixed_V2_1_updateRedeemRecipient_ownerRedirectsQueuedRedeem() public {
        _deposit(alice, ONE_M);
        assertEq(vault.balanceOf(alice), SH_1M);
        uint256 id = _requestRedeem(alice, SH_1M);

        uint256 expectedAssets = vault.convertToAssets(SH_1M);
        assertEq(expectedAssets, R_1M);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit RedeemRecipientUpdated(id, bob);
        vault.updateRedeemRecipient(id, bob);

        ( address owner, address recipient, uint256 shares ) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    SH_1M);

        vm.roll(block.number + 1);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(bob),    expectedAssets);
        assertEq(usdc.balanceOf(alice),  0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.firstPendingRedeemId(), 1);
    }

    function test_updateRedeemRecipient_strangerGuardianAndRecipientRevert() public {
        _deposit(alice, ONE_M);
        uint256 id = _requestRedeem(alice, SH_1M);

        address[4] memory who = [mallory, pauser, admin, operator];
        for (uint256 i; i < 4; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.updateRedeemRecipient(id, who[i]);
        }

        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(id, mallory);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),     R_1M);
        assertEq(usdc.balanceOf(mallory), 0);
    }

    // `cancelRedeemRequest` is gone: a redeem entry is open until the planner fills it, and the
    // filled (deleted) slot rejects the updater.
    function test_updateRedeemRecipient_filledEntryRevertsNoRequest() public {
        _deposit(alice, ONE_M);
        uint256 filled = _requestRedeem(alice, SH_100K);
        _processRedeems(type(uint256).max, type(uint256).max);
        ( ,, uint256 s ) = _redeemRequest(filled);
        assertEq(s, 0);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(filled, bob);

        // The selector is gone from the contract: a call to the old function is a plain revert
        // (no fallback), and the owner's shares stay escrowed until the planner pays.
        uint256 open = _requestRedeem(alice, SH_100K);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("cancelRedeemRequest(uint256,address)", open, alice)
        );
        assertFalse(ok);
        ( ,, s ) = _redeemRequest(open);
        assertEq(s, SH_100K);
        assertEq(vault.balanceOf(address(vault)), SH_100K);
    }

    // `updateDepositCancellationRecipient` (:491-504): same shape, for the USDC refund.
    function test_fixed_V2_1_updateDepositCancellationRecipient_ownerRedirectsRefund() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        uint256 cid = vault.requestDepositCancellation(id, alice);

        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(cid, mallory);

        vm.prank(pauser);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(cid, pauser);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit DepositCancellationRecipientUpdated(cid, bob);
        vault.updateDepositCancellationRecipient(cid, bob);

        ( address owner, address recipient, uint256 shares ) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);

        vm.roll(block.number + 1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(bob),   A_1M);
        assertEq(usdc.balanceOf(alice), 0);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);  // settled entry
        vault.updateDepositCancellationRecipient(cid, alice);
    }

    // V2-2 / F-1 fixed: the pauser cancel path is gone. `requestDepositCancellation` (:419-444)
    // is owner-only for every recipient, including the owner.
    function test_fixed_V2_2_guardianCannotCancelDeposits() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);

        address[4] memory who = [pauser, admin, operator, mallory];
        for (uint256 i; i < 4; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.requestDepositCancellation(id, alice);
            vm.prank(who[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.requestDepositCancellation(id, who[i]);
        }

        ( address owner, address recipient, uint256 shares ) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    S_1M);
        assertEq(_cancelledDepositQueueLength(), 0);

        vm.prank(alice);
        uint256 cid = vault.requestDepositCancellation(id, bob);
        ( owner, recipient, shares ) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),      A_1M);
        assertEq(usdc.balanceOf(alice),    0);
        assertEq(usdc.balanceOf(pauser), 0);
    }

    // `zero-recipient` is checked before the entry is loaded, so it fires even on ids that do
    // not exist.
    function test_updateRecipient_zeroRecipientReverts() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.updateDepositRecipient(id, address(0));
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.updateDepositRecipient(99, address(0));
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.updateDepositCancellationRecipient(0, address(0));
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.updateRedeemRecipient(0, address(0));
    }

    // The updaters are not pause-gated: an owner can still re-point while paused, while the
    // request functions are blocked.
    function test_updateRecipient_worksWhilePaused() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _pause();

        vm.prank(alice);
        vault.updateDepositRecipient(id, bob);
        ( , address recipient, ) = _depositRequest(id);
        assertEq(recipient, bob);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDepositCancellation(id, alice);
    }

}

contract NewSurfaceMiscTest is NewSurfaceBase {

    /**********************************************************************************************/
    /*** 13. setCapacity has no bound (V2-7 open)                                               ***/
    /**********************************************************************************************/

    // `convertToAssets(availableCapacity())` (:829) multiplies the free capacity by chi, so any
    // capacity above maxUint256 / chi + totalSupply makes every requestDeposit and
    // processPendingDeposits panic. The safe bound shrinks as chi grows.
    function test_BUG_setCapacity_maxUint256BricksDeposits() public {
        _setCapacity(type(uint256).max);
        _fund(alice, ONE_M);

        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(ONE_M, alice, 0);

        vm.prank(operator);
        vm.expectRevert(stdError.arithmeticError);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);

        // Exact edge at supply 0: floor(maxUint256 / chi) is safe, one more is not.
        uint256 safe = type(uint256).max / vault.nowChi();
        assertEq(safe, 114_681_085_459_589_801_375_833_087_904_206_311_575_507_395_147_570);  // ~1.1e50 shares

        _setCapacity(safe + 1);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(ONE_M, alice, 0);

        _setCapacity(safe);
        vm.prank(alice);
        vault.requestDeposit(ONE_M, alice, 0);
        assertEq(vault.balanceOf(alice), SH_1M);

        // A capacity that was safe today bricks deposits once chi has grown.
        _setPrimeVsr(MAX_VSR);
        _warp(1 days);
        _fund(bob, ONE_M);
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(ONE_M, bob, 0);

        vm.prank(operator);
        vm.expectRevert(stdError.arithmeticError);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);

        // Admin recovers by lowering the capacity.
        _setCapacity(type(uint128).max);
        vm.prank(bob);
        vault.requestDeposit(ONE_M, bob, 0);
        assertGt(vault.balanceOf(bob), 0);
    }

    /**********************************************************************************************/
    /*** 14. requestRedeem(0) (V2-9 open)                                                       ***/
    /**********************************************************************************************/

    function test_BUG_V2_9_requestRedeem_zeroSharesCreatesGhostEntry() public {
        _setRedeemFeeRate(vault.MAX_REDEEM_FEE());
        assertEq(vault.minRedeem(),        0);
        assertEq(vault.balanceOf(mallory), 0);

        vm.prank(mallory);
        vm.expectEmit(address(vault));
        emit RedeemRequest(mallory, mallory, 0, 0, 0);
        uint256 id = vault.requestRedeem(0, mallory);

        assertEq(id, 0);
        ( address owner, address recipient, uint256 shares ) = _redeemRequest(id);
        assertEq(owner,     mallory);
        assertEq(recipient, mallory);
        assertEq(shares,    0);
        assertEq(vault.pendingRedeemShares(), 0);

        // Permanent: no cancel exists and the updater rejects the 0-share slot.
        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(id, mallory);
    }

    // Ghost entries ahead of a real one consume `maxRequests` (C-12 persists).
    function test_BUG_V2_9_requestRedeem_ghostsConsumeMaxRequests() public {
        _deposit(alice, ONE_M);
        for (uint256 i; i < 3; ++i) {
            vm.prank(mallory);
            vault.requestRedeem(0, mallory);
        }
        uint256 id = _requestRedeem(alice, SH_1M);
        assertEq(id, 3);

        _processRedeems(type(uint256).max, 3);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.firstPendingRedeemId(), 3);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), R_1M);
        assertEq(vault.firstPendingRedeemId(), 4);
    }

    function test_requestRedeem_zeroSharesRevertsWithMinRedeem() public {
        _setMinRedeem(1);
        vm.prank(mallory);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(0, mallory);
    }

    /**********************************************************************************************/
    /*** 15. Deferred head walk (no head-advance loops on 0ebb452)                              ***/
    /**********************************************************************************************/

    // A zero-asset request always satisfies `pendingDepositSavingsShares == savingsShares_`
    // (:414) and runs the walk, but with `availableCapacity() == 0` the loop body never executes
    // (`remaining_ == 0`, :837) so the head does not move. The ghosts are skipped by the first
    // real instant fill after capacity returns.
    function test_requestDeposit_ghostsDoNotAdvanceHeadUntilCapacityReturns() public {
        _setCapacity(0);
        _fund(mallory, 0);
        for (uint256 i; i < 3; ++i) {
            vm.prank(mallory);
            assertEq(vault.requestDeposit(0, mallory, 0), i);
        }
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(_depositLength(),              3);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        _setCapacity(type(uint128).max);
        uint256 id = _deposit(bob, ONE_M);
        assertEq(id,                            3);
        assertEq(vault.balanceOf(bob),          SH_1M);
        assertEq(vault.firstPendingDepositId(), 4);
        assertEq(_depositLength(),              4);
    }

    // `requestDepositCancellation` (:419-444) no longer walks the head: cancelled entries at the
    // head stay there (as zero slots) until the next walk, and they still count against
    // `maxRequests_` (:835).
    function test_requestDepositCancellation_doesNotAdvanceHead() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, ONE_M);
        _fund(mallory, 0);
        vm.prank(mallory);
        vault.requestDeposit(0, mallory, 0);        // ghost at 1
        uint256 idB = _deposit(bob,   HUNDRED_K);  // 2
        uint256 idC = _deposit(carol, HUNDRED_K);  // 3
        assertEq(vault.firstPendingDepositId(), 0);

        vm.prank(bob);
        vault.requestDepositCancellation(idB, bob);   // non-head cancel
        assertEq(vault.firstPendingDepositId(), 0);

        vm.prank(alice);
        vault.requestDepositCancellation(idA, alice); // head cancel: head stays
        assertEq(vault.firstPendingDepositId(), 0);

        vm.prank(carol);
        vault.requestDepositCancellation(idC, carol);
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(_depositLength(),              4);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M + 2 * S_100K);

        // The next instant fill walks past the four dead slots.
        _setCapacity(type(uint128).max);
        uint256 idD = _deposit(dave, HUNDRED_K);  // pending == own shares, walks 0..4
        assertEq(idD, 4);
        assertEq(vault.balanceOf(dave), SH_100K);
        assertEq(vault.firstPendingDepositId(), 5);

        // A bounded operator walk over a dead slot only moves the head.
        _setCapacity(0);
        _deposit(alice, ONE_M);                      // 5, queued
        vm.prank(alice);
        vault.requestDepositCancellation(5, alice);  // dead slot 5
        _deposit(bob, HUNDRED_K);                    // 6, queued (predicate true but cap 0)
        assertEq(vault.firstPendingDepositId(), 5);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);      // budget spent on slot 5
        assertEq(vault.firstPendingDepositId(), 6);
        assertEq(vault.balanceOf(bob), 0);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.firstPendingDepositId(), 7);
        assertEq(vault.balanceOf(bob), SH_100K);
    }

    function test_requestDeposit_gasOfWalkingGhostsPaidOnce() public {
        _setCapacity(0);
        _deposit(alice, ONE_M);  // head stuck at 0
        _fund(mallory, 0);
        for (uint256 i; i < 500; ++i) {
            vm.prank(mallory);
            vault.requestDeposit(0, mallory, 0);  // predicate false: alice is queued ahead
        }
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(_depositLength(),              501);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);  // fills alice, head = 1, 500 ghosts ahead
        assertEq(vault.firstPendingDepositId(), 1);

        _fund(bob, ONE_M);
        vm.prank(bob);
        uint256 g0 = gasleft();
        vault.requestDeposit(ONE_M, bob, 0);
        uint256 gasBob = g0 - gasleft();
        assertEq(vault.firstPendingDepositId(), 502);
        assertEq(vault.balanceOf(bob), SH_1M);

        _fund(carol, ONE_M);
        vm.prank(carol);
        g0 = gasleft();
        vault.requestDeposit(ONE_M, carol, 0);
        uint256 gasCarol = g0 - gasleft();
        assertEq(vault.firstPendingDepositId(), 503);

        emit log_named_uint("gas: requestDeposit walking 500 ghosts", gasBob);
        emit log_named_uint("gas: requestDeposit with no walk       ", gasCarol);
        // Slots are warm inside one test tx; on mainnet every ghost is a cold SLOAD (2_100) so
        // 500 ghosts cost the next depositor ~1.1M gas, once.
        assertGt(gasBob - gasCarol, 500 * 400);
        assertLt(gasBob - gasCarol, 500 * 2_500);
    }

    /**********************************************************************************************/
    /*** 16. delete after full fill                                                             ***/
    /**********************************************************************************************/

    function test_processQueues_entriesDeletedAfterFill() public {
        uint256 id = _deposit(alice, ONE_M);  // instant
        assertEq(id, 0);
        ( address o, address r, uint256 s ) = _depositRequest(0);
        assertEq(o, address(0)); assertEq(r, address(0)); assertEq(s, 0);

        uint256 rid = _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, type(uint256).max);
        ( o, r, s ) = _redeemRequest(rid);
        assertEq(o, address(0)); assertEq(r, address(0)); assertEq(s, 0);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingRedeemRequest(rid);
    }

    function test_updateRecipient_outOfRangePanics() public {
        vm.expectRevert(stdError.indexOOBError);
        vault.updateDepositRecipient(0, mallory);
        vm.expectRevert(stdError.indexOOBError);
        vault.updateDepositCancellationRecipient(0, mallory);
        vm.expectRevert(stdError.indexOOBError);
        vault.updateRedeemRecipient(0, mallory);
        vm.expectRevert("SparkPrimeVault/invalid-range");  // range getter guards the index
        vault.getPendingDepositRequests(0, 1);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(0);
    }

    /**********************************************************************************************/
    /*** 17. pause on GUARDIAN, unpause on admin                                                ***/
    /**********************************************************************************************/

    function test_pause_guardianCanAdminCannot() public {
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, PAUSER_ROLE));
        vault.pause();

        vm.prank(pauser);
        vm.expectEmit(address(vault));
        emit Paused();
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(operator);
        vm.expectRevert(_unauthorized(operator, DEFAULT_ADMIN_ROLE));
        vault.unpause();

        vm.prank(pauser);
        vm.expectRevert(_unauthorized(pauser, DEFAULT_ADMIN_ROLE));
        vault.unpause();

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit Unpaused();
        vault.unpause();
        assertFalse(vault.paused());
    }

    /**********************************************************************************************/
    /*** 18. Getters and strings                                                                ***/
    /**********************************************************************************************/

    function test_asset_isUsdc() public view {
        assertEq(vault.asset(),   address(usdc));
        assertEq(vault.savings(), address(spUsdc));
        assertEq(vault.decimals(), 6);
    }

    function test_DOMAIN_SEPARATOR_matchesEip712() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Spark Prime USDC")),
                keccak256(bytes("1")),
                block.chainid,
                address(vault)
            )
        );
        assertEq(vault.DOMAIN_SEPARATOR(), expected);
    }

    function test_take_insufficientSharesString() public {
        _deposit(alice, ONE_M);
        assertEq(_vaultSpUsdc(), S_1M);
        vm.prank(taker);
        vm.expectRevert(ISparkPrimeVault.InsufficientShares.selector);
        vault.take(S_1M + 1);
        _take(S_1M);
        assertEq(_vaultSpUsdc(), 0);
    }

    /**********************************************************************************************/
    /*** 19. Event shapes                                                                       ***/
    /**********************************************************************************************/

    function test_events_depositRequestCarriesSavingsShares() public {
        _setCapacity(0);
        _fund(alice, ONE_M);
        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit DepositRequest(alice, alice, 0, ONE_M, S_1M);
        vault.requestDeposit(ONE_M, alice, 0);
    }

    // `Deposit(owner, recipient, assetsConverted, sharesMinted)`: the 4th argument is spPRIME.
    function test_events_depositFourthArgIsPrimeShares() public {
        _fund(alice, ONE_M);
        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit Deposit(alice, alice, A_1M, SH_1M);
        vault.requestDeposit(ONE_M, alice, 0);
    }

    // `Redeem(owner, recipient, sharesBurned, savingsSharesBurned, assetsReceived)`: the spUSDC
    // burned is the ceil of assets * RAY / chi_s; for the full 1M it is the whole S_1M.
    function test_events_redeemOrderIsOwnerRecipientSharesSavingsAssets() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_1M);
        vm.expectEmit(address(vault));
        emit Redeem(alice, alice, SH_1M, RS_1M, R_1M);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(_vaultSpUsdc(), 0);
        assertEq(usdc.balanceOf(alice), R_1M);
    }

    function test_events_partialRedeemBurnsCeilSavingsShares() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_100K);
        vm.expectEmit(address(vault));
        emit Redeem(alice, alice, SH_100K, RS_100K, R_100K);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(_vaultSpUsdc(), S_1M - RS_100K);
    }

}
