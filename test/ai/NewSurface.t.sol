// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../../lib/forge-std/src/StdError.sol";
import { Vm }       from "../../lib/forge-std/src/Vm.sol";

import { IAccessControl } from "../../lib/oz/contracts/access/IAccessControl.sol";
import { ERC1967Proxy }   from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { LocalTestBase }    from "./LocalTestBase.t.sol";
import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../src/SparkPrimeVault.sol";

/// @dev Tests for the surface that is new or changed on `master` @ c512609: owner-only recipient
///      updaters (V2-1), the removed pauser cancel path (V2-2 / F-1), unbounded `setCapacity`
///      (V2-7), minimum-sized redeem ghosts (R5-14), the cancel self-skip and the budget-0 head
///      walk (R5-9), partial cancellations and `minDepositCancellation`, cancellations and their
///      settlement while paused, `pause` on PAUSER / `unpause` on UNPAUSER, the single and
///      `(startId, length)` getters, the storage layout and the `requestId`-first event shapes.
///      `adjustTotalAssets` lives in `AdjustTotalAssets.t.sol`, the blacklist fallback and
///      `claim` / `totalClaimable` in `Blacklist.t.sol`.
///
///      Harness indexes (frozen at RAY after setUp):
///        spUSDC  chi_s = 1.047633055711877768967605062e27
///        spPRIME chi_p = 1.009687768242461209408770821e27
abstract contract NewSurfaceBase is LocalTestBase {

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

    // Storage slots pinned by `forge inspect` (see CAMPAIGN.md).
    uint256 constant SLOT_DEPOSITS        = 0;
    uint256 constant SLOT_CANCELLATIONS   = 1;
    uint256 constant SLOT_REDEEMS         = 2;
    uint256 constant SLOT_TOTAL_CLAIMABLE = 18;

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, who, role
        );
    }

    /// @dev Owner cancels `shares` of deposit `id` to `recipient`.
    function _cancel(address who, uint256 id, address recipient, uint256 shares)
        internal returns (uint256 cid)
    {
        vm.prank(who);
        cid = vault.requestDepositCancellation(id, recipient, shares);
    }

    /// @dev Raw read of a queue entry, including ids below the head that the getters reject.
    function _rawRequest(uint256 slot, uint256 i)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        uint256 base = uint256(keccak256(abi.encode(slot))) + 3 * i;
        owner     = address(uint160(uint256(vm.load(address(vault), bytes32(base)))));
        recipient = address(uint160(uint256(vm.load(address(vault), bytes32(base + 1)))));
        shares    = uint256(vm.load(address(vault), bytes32(base + 2)));
    }

    function _rawDeposit(uint256 i)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        return _rawRequest(SLOT_DEPOSITS, i);
    }

    function _rawRedeem(uint256 i)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        return _rawRequest(SLOT_REDEEMS, i);
    }

    function _rawCancellation(uint256 i)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        return _rawRequest(SLOT_CANCELLATIONS, i);
    }

    function _rawLength(uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(address(vault), bytes32(slot)));
    }

    function test_harnessConstants() public view {
        assertEq(spUsdc.nowChi(), CHI_S);
        assertEq(vault.nowChi(),  CHI_P);
        assertEq(spUsdc.convertToShares(ONE_M), S_1M);
        assertEq(spUsdc.convertToAssets(S_1M),  A_1M);
        assertEq(vault.convertToShares(A_1M),   SH_1M);
        assertEq(vault.convertToAssets(SH_1M),  R_1M);
        assertEq(vault.convertToAssets(SH_100K), R_100K);
        assertEq(vault.minDeposit(),             MIN_DEPOSIT);
        assertEq(vault.minDepositCancellation(), MIN_DEPOSIT_CANCELLATION);
        assertEq(vault.minRedeem(),              MIN_REDEEM);
    }

}

/**************************************************************************************************/
/*** 11. Recipient updaters are owner-only (V2-1 fixed)                                         ***/
/**************************************************************************************************/

contract UpdateRecipientTests is NewSurfaceBase {

    // `updateDepositRecipient` (:482-493): the owner redirects the fill and the exact spPRIME
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
        emit ISparkPrimeVault.DepositRecipientUpdated(id, bob);
        vault.updateDepositRecipient(id, bob);

        ( owner, recipient, shares ) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);

        vm.roll(block.number + 1);
        _setCapacity(type(uint128).max);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(id, alice, bob, S_1M, A_1M, SH_1M);
        _processDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.balanceOf(bob),   SH_1M);   // 990_405_184_109 spPRIME, ~999_999.99 USDC
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.firstPendingDepositId(), 1);
    }

    function test_updateDepositRecipient_strangerAndRolesAndRecipientRevert() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);

        address[7] memory who = [mallory, pauser, unpauser, admin, operator, lossManager, taker];
        for (uint256 i; i < 7; ++i) {
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

    // A filled entry is deleted (owner 0, shares 0): `NoRequest` fires before the owner check,
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

        ( address o, address r, uint256 s ) = _rawDeposit(id);
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
        _cancel(alice, id, alice, S_1M);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositRecipient(id, bob);
    }

    // A partially cancelled entry keeps `shares != 0`: the owner can still re-point the rest.
    function test_updateDepositRecipient_partiallyCancelledEntryStillUpdatable() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _cancel(alice, id, alice, S_100K);

        vm.prank(alice);
        vault.updateDepositRecipient(id, bob);
        ( , address recipient, uint256 shares ) = _depositRequest(id);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M - S_100K);
    }

    // `updateRedeemRecipient` (:514-525): same shape, for the USDC paid on a queued redeem.
    function test_fixed_V2_1_updateRedeemRecipient_ownerRedirectsQueuedRedeem() public {
        _deposit(alice, ONE_M);
        assertEq(vault.balanceOf(alice), SH_1M);
        uint256 id = _requestRedeem(alice, SH_1M);

        uint256 expectedAssets = vault.convertToAssets(SH_1M);
        assertEq(expectedAssets, R_1M);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRecipientUpdated(id, bob);
        vault.updateRedeemRecipient(id, bob);

        ( address owner, address recipient, uint256 shares ) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    SH_1M);

        vm.roll(block.number + 1);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, bob, SH_1M, RS_1M, R_1M);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(bob),    expectedAssets);
        assertEq(usdc.balanceOf(alice),  0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.firstPendingRedeemId(), 1);
    }

    function test_updateRedeemRecipient_strangerAndRolesAndRecipientRevert() public {
        _deposit(alice, ONE_M);
        uint256 id = _requestRedeem(alice, SH_1M);

        address[7] memory who = [mallory, pauser, unpauser, admin, operator, lossManager, taker];
        for (uint256 i; i < 7; ++i) {
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

    // `cancelRedeemRequest` is gone: a redeem entry is open until the operator fills it, and the
    // filled (deleted) slot rejects the updater.
    function test_updateRedeemRecipient_filledEntryRevertsNoRequest() public {
        _deposit(alice, ONE_M);
        uint256 filled = _requestRedeem(alice, SH_100K);
        _processRedeems(type(uint256).max, type(uint256).max);
        ( ,, uint256 s ) = _rawRedeem(filled);
        assertEq(s, 0);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(filled, bob);

        // The selector is gone from the contract: a call to the old function is a plain revert
        // (no fallback), and the owner's shares stay escrowed until the operator pays.
        uint256 open = _requestRedeem(alice, SH_100K);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("cancelRedeemRequest(uint256,address)", open, alice)
        );
        assertFalse(ok);
        ( ,, s ) = _redeemRequest(open);
        assertEq(s, SH_100K);
        assertEq(vault.balanceOf(address(vault)), SH_100K);
    }

    // `updateDepositCancellationRecipient` (:495-512): same shape, for the USDC refund.
    function test_fixed_V2_1_updateDepositCancellationRecipient_ownerRedirectsRefund() public {
        _setCapacity(0);
        uint256 id  = _deposit(alice, ONE_M);
        uint256 cid = _cancel(alice, id, alice, S_1M);

        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(cid, mallory);

        vm.prank(pauser);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(cid, pauser);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRecipientUpdated(cid, bob);
        vault.updateDepositCancellationRecipient(cid, bob);

        ( address owner, address recipient, uint256 shares ) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);

        vm.roll(block.number + 1);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(cid, alice, bob, S_1M, A_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(bob),   A_1M);
        assertEq(usdc.balanceOf(alice), 0);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);  // settled entry
        vault.updateDepositCancellationRecipient(cid, alice);
    }

    // V2-2 / F-1 fixed: the pauser cancel path is gone. `requestDepositCancellation` (:405-446)
    // is owner-only for every recipient, including the owner.
    function test_fixed_V2_2_rolesCannotCancelDeposits() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);

        address[6] memory who = [pauser, unpauser, admin, operator, lossManager, mallory];
        for (uint256 i; i < 6; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.requestDepositCancellation(id, alice, S_1M);
            vm.prank(who[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.requestDepositCancellation(id, who[i], S_1M);
        }

        ( address owner, address recipient, uint256 shares ) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    S_1M);
        assertEq(_cancelledDepositQueueLength(), 0);

        uint256 cid = _cancel(alice, id, bob, S_1M);
        ( owner, recipient, shares ) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),    A_1M);
        assertEq(usdc.balanceOf(alice),  0);
        assertEq(usdc.balanceOf(pauser), 0);
    }

    // `ZeroRecipient` is checked before the entry is loaded, so it fires even on ids that do
    // not exist; `InvalidRequestId` follows for ids at or past the length.
    function test_updateRecipient_zeroRecipientThenInvalidId() public {
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

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.updateDepositRecipient(1, mallory);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.updateDepositCancellationRecipient(0, mallory);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.updateRedeemRecipient(0, mallory);
    }

}

/**************************************************************************************************/
/*** 12. Pause: PAUSER pauses, UNPAUSER unpauses, cancellations are not gated                  ***/
/**************************************************************************************************/

contract PauseTests is NewSurfaceBase {

    function test_pause_pauserOnly() public {
        address[6] memory who = [admin, unpauser, operator, lossManager, taker, mallory];
        for (uint256 i; i < 6; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(_unauthorized(who[i], PAUSER_ROLE));
            vault.pause();
        }
        assertFalse(vault.paused());

        vm.prank(pauser);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Paused();
        vault.pause();
        assertTrue(vault.paused());

        // Idempotent: pausing twice is a no-op that still emits.
        vm.prank(pauser);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Paused();
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_unpause_unpauserOnly() public {
        _pause();

        address[6] memory who = [admin, pauser, operator, lossManager, taker, mallory];
        for (uint256 i; i < 6; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(_unauthorized(who[i], UNPAUSER_ROLE));
            vault.unpause();
        }
        assertTrue(vault.paused());

        vm.prank(unpauser);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Unpaused();
        vault.unpause();
        assertFalse(vault.paused());
    }

    // What `whenNotPaused` gates (:377, :451, :321, :338) and what it does not.
    function test_pause_gatesRequestsAndFillsOnly() public {
        _deposit(bob, ONE_M);
        uint256 rid = _requestRedeem(bob, SH_100K);
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _pause();

        _fund(carol, ONE_M);
        vm.prank(carol);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDeposit(ONE_M, carol, 0);
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestRedeem(1, bob);
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);

        // Not gated: updaters, drip, transfer, take, setVSR, setCapacity, cancellations.
        vm.prank(alice);
        vault.updateDepositRecipient(id, carol);
        vm.prank(bob);
        vault.updateRedeemRecipient(rid, carol);
        vault.drip();
        vm.prank(bob);
        assertTrue(vault.transfer(carol, 1));
        _take(1);
        _setPrimeVsr(ONE_PCT_VSR);
        _setCapacity(0);
        assertTrue(vault.paused());
    }

    // R5-B (round 4) wanted this: a depositor is not trapped by a pause. Full and partial
    // cancellations are accepted (:405 has no `whenNotPaused`) and the refund settles
    // (`processPendingDepositCancellations`, :326, is not gated either).
    function test_fixed_R5B_requestDepositCancellation_worksWhilePaused() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _pause();

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRequest(id, 0, alice, S_100K);
        uint256 cid1 = vault.requestDepositCancellation(id, alice, S_100K);
        ( ,, uint256 left ) = _depositRequest(id);
        assertEq(left, S_1M - S_100K);

        uint256 cid2 = _cancel(alice, id, bob, S_1M - S_100K);
        assertEq(cid2, 1);
        assertEq(vault.firstPendingDepositId(), 1);  // self-skip ran while paused
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(cid1, alice, alice, S_100K, A_100K);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(cid2, alice, bob, S_1M - S_100K, 899_999_999_999);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertTrue(vault.paused());
        assertEq(usdc.balanceOf(alice), A_100K);
        assertEq(usdc.balanceOf(bob),   899_999_999_999);
        assertEq(_vaultSpUsdc(),        0);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
    }

    // The settlement while paused also runs the blacklist fallback (no pause check in
    // `_redeemSavings`), so a paused vault still accrues claimables.
    function test_processPendingDepositCancellations_fallbackWhilePaused() public {
        _setCapacity(0);
        uint256 id  = _deposit(alice, ONE_M);
        uint256 cid = _cancel(alice, id, alice, S_1M);
        _blacklist(alice);
        _pause();

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(alice, A_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(alice), A_1M);
        assertEq(vault.totalClaimable(),       A_1M);
        assertEq(usdc.balanceOf(address(vault)), A_1M);
        ( ,, uint256 left ) = _rawCancellation(cid);
        assertEq(left, 0);
    }

}

/**************************************************************************************************/
/*** 13. setCapacity has no bound (V2-7 / R5-8 open)                                           ***/
/**************************************************************************************************/

contract CapacityTests is NewSurfaceBase {

    // `convertToAssets(availableCapacity())` (:864) multiplies the free capacity by chi, so any
    // capacity above maxUint256 / chi + totalSupply makes every requestDeposit and
    // processPendingDeposits panic. The safe bound shrinks as chi grows.
    function test_BUG_V2_7_setCapacity_maxUint256BricksDeposits() public {
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

        // Cancellations still work (no capacity conversion in the cancel queue walk)...
        _setCapacity(0);
        vm.prank(bob);
        uint256 id = vault.requestDeposit(ONE_M, bob, 0);
        _setCapacity(type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);  // ...but the cancel self-skip walk does not
        vault.requestDepositCancellation(id, bob, S_1M);

        // The operator recovers by lowering the capacity.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        assertGt(vault.balanceOf(bob), 0);
    }

    function test_setCapacity_operatorOnly() public {
        address[6] memory who = [admin, pauser, unpauser, lossManager, taker, mallory];
        for (uint256 i; i < 6; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(_unauthorized(who[i], OPERATOR_ROLE));
            vault.setCapacity(1);
        }
        vm.prank(operator);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.CapacitySet(1);
        vault.setCapacity(1);
        assertEq(vault.maxCapacity(), 1);
    }

}

/**************************************************************************************************/
/*** 14. Minimum-sized redeems (V2-9 fixed by `minRedeem`, R5-14 open)                         ***/
/**************************************************************************************************/

contract RedeemMinimumTests is NewSurfaceBase {

    // `minRedeem` can no longer be zero (:186, :241), so `requestRedeem(0)` always reverts.
    function test_fixed_V2_9_requestRedeem_zeroSharesRevertsBelowMinRedeem() public {
        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(0, mallory);

        _setMinRedeem(SH_100K);
        _deposit(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(SH_100K - 1, alice);
        assertEq(_requestRedeem(alice, SH_100K), 0);
        assertEq(_redeemQueueLength(), 1);
    }

    // R5-14 open: the minimum is checked on `shares_` before the fee (:456), so with
    // `minRedeem == 1` and any nonzero fee `requestRedeem(1)` burns the whole share as fee
    // (`_divUp(1 * fee, WAD) == 1`, :463) and queues a zero-share entry. The entry is a ghost: it
    // consumes `maxRequests` in the walk and the updater rejects it (`NoRequest`).
    function test_BUG_R5_14_requestRedeem_minRedeemAtNonzeroFeeQueuesZeroShareEntry() public {
        _setRedeemFeeRate(0.0001e18);  // 0.01%: still rounds 1 share up to a 1-share fee
        _deposit(alice, ONE_M);
        _deposit(mallory, ONE_M);
        assertEq(vault.minRedeem(), 1);

        vm.prank(mallory);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRequest(0, mallory, mallory, 1, 1);
        uint256 id = vault.requestRedeem(1, mallory);

        ( address owner, address recipient, uint256 shares ) = _redeemRequest(id);
        assertEq(owner,     mallory);
        assertEq(recipient, mallory);
        assertEq(shares,    0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.balanceOf(mallory),    SH_1M - 1);
        assertEq(vault.totalSupply(),         2 * SH_1M - 1);  // the share is burned, not escrowed

        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(id, mallory);

        // Three ghosts ahead of alice consume three units of `maxRequests`; the walk does clear
        // them (zero-share fills are a no-op withdraw of 0) so they are not permanent.
        vm.startPrank(mallory);
        vault.requestRedeem(1, mallory);
        vault.requestRedeem(1, mallory);
        vm.stopPrank();
        uint256 aliceId = _requestRedeem(alice, SH_1M);
        assertEq(aliceId, 3);

        _processRedeems(type(uint256).max, 3);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.firstPendingRedeemId(), 3);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 999_899_999_998);  // R_1M less the 0.01% fee
        assertEq(vault.firstPendingRedeemId(), 4);
    }

    // With `minRedeem >= 2` the fee can never consume the whole request at the 1% cap.
    function test_requestRedeem_minRedeemTwoCannotGhost() public {
        _setRedeemFeeRate(vault.MAX_REDEEM_FEE());
        _setMinRedeem(2);
        _deposit(mallory, ONE_M);
        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(1, mallory);
        vm.prank(mallory);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRequest(0, mallory, mallory, 2, 1);
        uint256 id = vault.requestRedeem(2, mallory);
        ( ,, uint256 shares ) = _redeemRequest(id);
        assertEq(shares, 1);
    }

}

/**************************************************************************************************/
/*** 15. Head walk: cancel self-skip and the budget-0 walk (R5-9)                              ***/
/**************************************************************************************************/

contract HeadWalkTests is NewSurfaceBase {

    // R5-9 part 1 fixed: `minDeposit` cannot be zero, so zero-asset deposit requests are gone.
    function test_fixed_R5_9_requestDeposit_zeroAssetsRevertsBelowMinDeposit() public {
        _fund(mallory, 0);
        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(0, mallory, 0);
        assertEq(_depositQueueLength(), 0);

        _setMinDeposit(HUNDRED_K);
        _fund(mallory, HUNDRED_K);
        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(HUNDRED_K - 1, mallory, 0);
        vm.prank(mallory);
        vault.requestDeposit(HUNDRED_K, mallory, 0);
        assertEq(vault.balanceOf(mallory), SH_100K);
    }

    // R5-15 open: with the harness `minDeposit == 1`, a 1-wei deposit mints 0 spUSDC shares
    // (`1 * RAY / chi_s == 0`) and pushes a zero-share entry that nobody can cancel (`NoRequest`)
    // and that is walked as a cancelled slot. The wei is donated to spUSDC. This is the cheapest
    // dead slot a griefer can make; a launch `minDeposit` of one USDC or more removes it.
    function test_BUG_R5_15_requestDeposit_dustMintsZeroSharesAndLeavesDeadSlot() public {
        _setCapacity(0);
        _deposit(alice, ONE_M);  // live head at 0
        _fund(mallory, 1);

        vm.prank(mallory);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositRequest(1, mallory, mallory, 1, 0);
        uint256 id = vault.requestDeposit(1, mallory, 0);

        ( address owner, , uint256 shares ) = _depositRequest(id);
        assertEq(owner,  mallory);
        assertEq(shares, 0);
        assertEq(vault.pendingDepositSavingsShares(), S_1M);
        assertEq(usdc.balanceOf(address(spUsdc)), ONE_M + 1);
        assertEq(spUsdc.totalSupply(), S_1M);  // the wei bought nothing

        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, mallory, 1);
        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositRecipient(id, mallory);

        // Once alice fills, the dead slot behind her costs one unit of `maxRequests`.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.firstPendingDepositId(), 1);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.firstPendingDepositId(), 2);
    }

    // R5-9 part 2 fixed: a full cancellation AT the head clears the head in the same call
    // (`_processPendingDeposits(0, max)`, :445, skips zero entries before the budget check, :875-878).
    function test_fixed_R5_9_requestDepositCancellation_headCancelClearsHeadImmediately() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, ONE_M);
        uint256 idB = _deposit(bob,   HUNDRED_K);
        assertEq(vault.firstPendingDepositId(), 0);

        _cancel(alice, idA, alice, S_1M);
        assertEq(vault.firstPendingDepositId(), 1);  // walked past the dead slot 0, stopped at bob
        ( ,, uint256 sharesB ) = _depositRequest(idB);
        assertEq(sharesB, S_100K);
        assertEq(vault.pendingDepositSavingsShares(), S_100K);
        assertEq(vault.balanceOf(bob), 0);          // budget 0: bob was not filled

        _cancel(bob, idB, bob, S_100K);
        assertEq(vault.firstPendingDepositId(), 2);  // queue empty, head at length
        assertEq(vault.getPendingDepositRequests().length, 0);
    }

    // A cancelled entry BEHIND a live head stays in the queue until the head is filled: the
    // self-skip only clears entries at the head.
    function test_requestDepositCancellation_cancelledEntryBehindLiveHeadWaits() public {
        _setCapacity(0);
        _deposit(alice, ONE_M);
        uint256 idB = _deposit(bob,   HUNDRED_K);
        uint256 idC = _deposit(carol, HUNDRED_K);

        _cancel(bob, idB, bob, S_100K);
        assertEq(vault.firstPendingDepositId(), 0);
        ( ,, uint256 sharesB ) = _depositRequest(idB);
        assertEq(sharesB, 0);
        assertEq(vault.getPendingDepositRequests().length, 3);

        // A budget-0 operator walk cannot pass alice either.
        _processDeposits(0, type(uint256).max);
        assertEq(vault.firstPendingDepositId(), 0);

        // Filling alice with `maxRequests == 1` leaves the dead slot at the head...
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(vault.balanceOf(alice), SH_1M);

        // ...and alice's own full cancel would have cleared it; here the next walk does.
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.firstPendingDepositId(), 2);  // one unit of budget, head only
        assertEq(vault.balanceOf(carol), 0);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.firstPendingDepositId(), 3);
        assertEq(vault.balanceOf(carol), SH_100K);
        ( ,, uint256 sharesC ) = _rawDeposit(idC);
        assertEq(sharesC, 0);
    }

    // `processPendingDeposits(0, max)` and a walk with `availableCapacity() == 0` both have
    // `remaining_ == 0` and still advance the head past cancelled entries (:875-878).
    function test_processPendingDeposits_zeroBudgetAdvancesHeadPastCancelledEntries() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, ONE_M);
        uint256 idB = _deposit(bob,   HUNDRED_K);
        uint256 idC = _deposit(carol, HUNDRED_K);

        // Cancel the two behind the head first, then the head with a partial so it stays live.
        _cancel(carol, idC, carol, S_100K);
        _cancel(bob,   idB, bob,   S_100K);
        _cancel(alice, idA, alice, S_100K);
        assertEq(vault.firstPendingDepositId(), 0);
        ( ,, uint256 sharesA ) = _depositRequest(idA);
        assertEq(sharesA, S_1M - S_100K);

        // Now cancel the rest of alice: the self-skip runs over all three dead slots.
        _cancel(alice, idA, alice, S_1M - S_100K);
        assertEq(vault.firstPendingDepositId(), 3);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M + 2 * S_100K);

        // Operator budget-0 walk with capacity 0 over fresh dead slots.
        uint256 idD = _deposit(dave, HUNDRED_K);
        _cancel(dave, idD, dave, S_100K);  // at head: cleared by the self-skip already
        assertEq(vault.firstPendingDepositId(), 4);
        uint256 idE = _deposit(dave, HUNDRED_K);
        uint256 idF = _deposit(dave, HUNDRED_K);
        _cancel(dave, idF, dave, S_100K);  // behind idE
        _processDeposits(0, type(uint256).max);
        assertEq(vault.firstPendingDepositId(), 4);  // idE live, budget 0: break
        _cancel(dave, idE, dave, S_100K);
        assertEq(vault.firstPendingDepositId(), 6);
        assertEq(_depositQueueLength(), 6);
    }

    // `maxRequests_` counts cancelled entries (:870), so a walk over dead slots only moves the head.
    function test_processPendingDeposits_maxRequestsCountsCancelledEntries() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, ONE_M);
        for (uint256 i; i < 5; ++i) {
            uint256 id = _deposit(mallory, HUNDRED_K);
            _cancel(mallory, id, mallory, S_100K);
        }
        uint256 idB = _deposit(bob, HUNDRED_K);
        assertEq(idB, 6);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);  // alice
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(vault.balanceOf(alice), SH_1M);
        ( ,, uint256 sA ) = _rawDeposit(idA);
        assertEq(sA, 0);

        _processDeposits(type(uint256).max, 3);  // three dead slots
        assertEq(vault.firstPendingDepositId(), 4);
        assertEq(vault.balanceOf(bob), 0);

        _processDeposits(type(uint256).max, 3);  // two dead slots + bob
        assertEq(vault.firstPendingDepositId(), 7);
        assertEq(vault.balanceOf(bob), SH_100K);
    }

    // What a griefer can still do (R5-9 residue): request-then-cancel loops of `minDeposit`
    // behind a live head leave dead slots that the first walk past the head must visit. Each
    // loop costs the griefer gas plus the spUSDC floor (1 wei on 100 USDC), refunded through the
    // cancellation queue. 500 dead slots cost the walk ~1.1M gas on mainnet (cold SLOADs), once.
    function test_requestDepositCancellation_deadSlotsBehindLiveHeadCostTheFirstWalkOnce() public {
        _setMinDeposit(100e6);
        _setCapacity(0);
        _deposit(alice, ONE_M);  // live head at 0
        _fund(mallory, 500 * 100e6);
        for (uint256 i; i < 500; ++i) {
            vm.prank(mallory);
            uint256 id = vault.requestDeposit(100e6, mallory, 0);
            ( ,, uint256 shares ) = _depositRequest(id);
            assertEq(shares, 95_453_269);
            _cancel(mallory, id, mallory, shares);
        }
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(_depositQueueLength(),         501);
        assertEq(_cancelledDepositQueueLength(), 500);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 500 * 95_453_269);

        // The refunds: 99_999_999 each, 1 wei of spUSDC floor lost per loop.
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(mallory), 500 * 99_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 500);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);  // fills alice, head = 1, 500 dead slots ahead
        assertEq(vault.firstPendingDepositId(), 1);

        _fund(bob, ONE_M);
        vm.prank(bob);
        uint256 g0 = gasleft();
        vault.requestDeposit(ONE_M, bob, 0);  // pending == own shares: walks 1..501
        uint256 gasBob = g0 - gasleft();
        assertEq(vault.firstPendingDepositId(), 502);
        assertEq(vault.balanceOf(bob), SH_1M);

        _fund(carol, ONE_M);
        vm.prank(carol);
        g0 = gasleft();
        vault.requestDeposit(ONE_M, carol, 0);
        uint256 gasCarol = g0 - gasleft();
        assertEq(vault.firstPendingDepositId(), 503);

        emit log_named_uint("gas: requestDeposit walking 500 dead slots", gasBob);
        emit log_named_uint("gas: requestDeposit with no walk          ", gasCarol);
        assertGt(gasBob - gasCarol, 500 * 400);
        assertLt(gasBob - gasCarol, 500 * 2_500);
    }

    // A bounded operator walk can always drain a dead-slot run in chunks, so the instant-fill
    // depositor never has to pay for it if the operator walks first.
    function test_processPendingDeposits_operatorDrainsDeadSlotsInChunks() public {
        _setCapacity(0);
        _deposit(alice, ONE_M);
        for (uint256 i; i < 20; ++i) {
            uint256 id = _deposit(mallory, HUNDRED_K);
            _cancel(mallory, id, mallory, S_100K);
        }
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.firstPendingDepositId(), 1);
        _processDeposits(0, 10);
        assertEq(vault.firstPendingDepositId(), 11);
        _processDeposits(0, 10);
        assertEq(vault.firstPendingDepositId(), 21);
        _processDeposits(0, 10);  // nothing left: end == head
        assertEq(vault.firstPendingDepositId(), 21);
    }

}

/**************************************************************************************************/
/*** 16. Partial cancellations and `minDepositCancellation`                                    ***/
/**************************************************************************************************/

contract DepositCancellationTests is NewSurfaceBase {

    function test_setMinDepositCancellation_adminOnly() public {
        address[6] memory who = [operator, pauser, unpauser, lossManager, taker, mallory];
        for (uint256 i; i < 6; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(_unauthorized(who[i], DEFAULT_ADMIN_ROLE));
            vault.setMinDepositCancellation(2);
        }
        assertEq(vault.minDepositCancellation(), 1);
    }

    function test_setMinDepositCancellation_zeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.ZeroMinDepositCancellation.selector);
        vault.setMinDepositCancellation(0);
        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.ZeroMinDeposit.selector);
        vault.setMinDeposit(0);
        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.ZeroMinRedeem.selector);
        vault.setMinRedeem(0);
    }

    function test_setMinDepositCancellation_success() public {
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.MinDepositCancellationSet(S_100K);
        vault.setMinDepositCancellation(S_100K);
        assertEq(vault.minDepositCancellation(), S_100K);
    }

    // C-8 pinned: zero is rejected everywhere, including `initialize` (:184-186), but there is
    // no upper bound: `type(uint256).max` makes every cancellation `BelowMinDepositCancellation`.
    function test_fixed_C8_minimums_zeroRejectedAtInit_unboundedAbove() public {
        address impl = address(new SparkPrimeVault());
        bytes[3] memory inits = [
            abi.encodeCall(ISparkPrimeVault.initialize, (address(spUsdc), "n", "s", admin, 0, 1, 1)),
            abi.encodeCall(ISparkPrimeVault.initialize, (address(spUsdc), "n", "s", admin, 1, 0, 1)),
            abi.encodeCall(ISparkPrimeVault.initialize, (address(spUsdc), "n", "s", admin, 1, 1, 0))
        ];
        bytes4[3] memory errs = [
            ISparkPrimeVault.ZeroMinDeposit.selector,
            ISparkPrimeVault.ZeroMinDepositCancellation.selector,
            ISparkPrimeVault.ZeroMinRedeem.selector
        ];
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(errs[i]);
            new ERC1967Proxy(impl, inits[i]);
        }

        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _setMinDepositCancellation(type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, S_1M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, type(uint256).max - 1);
        // `type(uint256).max` passes the minimum and fails the maximum instead.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, alice, type(uint256).max);

        _setMinDeposit(type(uint256).max);
        _fund(bob, ONE_M);
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(ONE_M, bob, 0);
        _setMinRedeem(type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(1, alice);
    }

    // Revert order of `requestDepositCancellation` (:414-423).
    function test_requestDepositCancellation_revertOrder() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _setMinDepositCancellation(S_100K);

        // 1. ZeroRecipient, before anything else (bad id, stranger).
        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.requestDepositCancellation(99, address(0), 0);
        // 2. VaultIsRecipient.
        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDepositCancellation(99, address(vault), 0);
        // 3. InvalidRequestId (id >= length).
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.requestDepositCancellation(1, alice, 0);
        // 4. NotRequestOwner before the amount checks.
        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id, mallory, 0);
        // 5. BelowMinDepositCancellation.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, S_100K - 1);
        // 6. SavingsSharesTooHigh.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, alice, S_1M + 1);

        // NoRequest comes right after the id check, before the owner check: a stranger gets it
        // on a cancelled entry.
        _cancel(alice, id, alice, S_1M);
        vm.prank(mallory);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, mallory, S_1M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, alice, S_1M);
    }

    // A partial cancel keeps the rest of the entry in place (owner, recipient, position) and
    // moves exactly `savingsShares_` between the two pending counters.
    function test_requestDepositCancellation_partial_success() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        vault.updateDepositRecipient(id, carol);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRequest(id, 0, bob, S_100K);
        uint256 cid = vault.requestDepositCancellation(id, bob, S_100K);
        assertEq(cid, 0);

        ( address owner, address recipient, uint256 shares ) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, carol);
        assertEq(shares,    S_1M - S_100K);
        ( owner, recipient, shares ) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_100K);
        assertEq(vault.pendingDepositSavingsShares(),          S_1M - S_100K);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_100K);
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(_vaultSpUsdc(), S_1M);  // nothing moved yet

        // A second partial to a different recipient, then the rest: three cancel entries.
        uint256 cid2 = _cancel(alice, id, dave, S_100K);
        uint256 cid3 = _cancel(alice, id, alice, S_1M - 2 * S_100K);
        assertEq(cid2, 1);
        assertEq(cid3, 2);
        assertEq(vault.firstPendingDepositId(), 1);  // fully cancelled: self-skipped
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
        ( owner, recipient, shares ) = _rawDeposit(id);
        assertEq(owner,     address(0));
        assertEq(recipient, address(0));
        assertEq(shares,    0);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),   A_100K);
        assertEq(usdc.balanceOf(dave),  A_100K);
        assertEq(usdc.balanceOf(alice), 799_999_999_999);
        assertEq(usdc.balanceOf(carol), 0);
        assertEq(_vaultSpUsdc(), 0);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
    }

    // The remainder of a partially cancelled entry fills normally, with the original recipient.
    function test_requestDepositCancellation_partial_remainderFills() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _cancel(alice, id, alice, S_100K);

        _setCapacity(type(uint128).max);
        uint256 restAssets = spUsdc.convertToAssets(S_1M - S_100K);
        uint256 restShares = vault.convertToShares(restAssets);
        assertEq(restAssets, 899_999_999_999);
        assertEq(restShares, 891_364_665_698);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(id, alice, alice, S_1M - S_100K, restAssets, restShares);
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.balanceOf(alice), restShares);
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(_vaultSpUsdc(), S_1M);  // the cancelled S_100K is still here until settled
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(_vaultSpUsdc(), S_1M - S_100K);  // alice's backing only
        assertEq(usdc.balanceOf(alice), A_100K);
    }

    // A partially FILLED head entry can be cancelled for its remainder.
    function test_requestDepositCancellation_afterPartialFill() public {
        _setCapacity(SH_100K);
        uint256 id = _deposit(alice, ONE_M);
        ( ,, uint256 left ) = _depositRequest(id);
        assertEq(left, S_1M - (S_100K - 2));
        assertEq(vault.balanceOf(alice), SH_100K - 2);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, alice, left + 1);

        _cancel(alice, id, alice, left);
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), 900_000_000_001);
        assertEq(_vaultSpUsdc(), S_100K - 2);  // backs alice's SH_100K - 2
    }

    // `minDepositCancellation` is in spUSDC share units (:422): a USDC-sized minimum is wrong.
    function test_requestDepositCancellation_minimumIsInSavingsShares() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _setMinDepositCancellation(S_100K);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, S_100K - 1);
        _cancel(alice, id, alice, S_100K);

        // Minimum sized in USDC (100k) is above S_100K spUSDC, so a 100k-share cancel fails.
        _setMinDepositCancellation(HUNDRED_K);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, S_100K);
        _cancel(alice, id, alice, HUNDRED_K);
        ( ,, uint256 left ) = _depositRequest(id);
        assertEq(left, S_1M - S_100K - HUNDRED_K);
    }

    // R5-14 residue: at the harness minimum, 1-share cancellations bloat the cancellation queue
    // and each settles for 1 wei of USDC (floor of 1.0476).
    function test_BUG_R5_14_oneShareCancellationsBloatTheCancellationQueue() public {
        _setCapacity(0);
        uint256 id = _deposit(mallory, HUNDRED_K);
        for (uint256 i; i < 50; ++i) _cancel(mallory, id, mallory, 1);
        assertEq(_cancelledDepositQueueLength(), 50);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 50);
        ( ,, uint256 left ) = _depositRequest(id);
        assertEq(left, S_100K - 50);

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositCancellationId(), 10);
        assertEq(usdc.balanceOf(mallory), 10);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(mallory), 50);
    }

    // The three cancel-side counters and the refund stay consistent for any split.
    function testFuzz_requestDepositCancellation_partialSplitsSumToWhole(uint256 first) public {
        first = bound(first, 1, S_1M - 1);
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);

        _cancel(alice, id, bob,   first);
        _cancel(alice, id, carol, S_1M - first);

        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),   spUsdc.convertToAssets(first));
        assertEq(usdc.balanceOf(carol), spUsdc.convertToAssets(S_1M - first));
        assertLe(A_1M - usdc.balanceOf(bob) - usdc.balanceOf(carol), 1);  // at most 1 wei of floor
        assertEq(_vaultSpUsdc(), 0);
    }

}

/**************************************************************************************************/
/*** 17. Getters                                                                               ***/
/**************************************************************************************************/

contract GetterTests is NewSurfaceBase {

    function _threeDeposits() internal returns (uint256 idA, uint256 idB, uint256 idC) {
        _setCapacity(0);
        idA = _deposit(alice, ONE_M);
        idB = _deposit(bob,   HUNDRED_K);
        idC = _deposit(carol, HUNDRED_K);
    }

    // Single getters: `InvalidRequestId` below the head and at or past the length (:675-678).
    function test_getPendingRequest_singleGetterWindow() public {
        ( uint256 idA, , uint256 idC ) = _threeDeposits();
        _cancel(carol, idC, carol, S_100K);  // cancelled behind the head: readable, 0 shares
        _cancel(alice, idA, alice, S_1M);    // head moves to 1 (bob is live)

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(0);
        ( address o, address r, uint256 s ) = vault.getPendingDepositRequest(1);
        assertEq(o, bob);
        assertEq(r, bob);
        assertEq(s, S_100K);
        ( o, r, s ) = vault.getPendingDepositRequest(2);
        assertEq(o, address(0));
        assertEq(r, address(0));
        assertEq(s, 0);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(3);

        // Cancellation and redeem queues: same window.
        ( o, r, s ) = vault.getPendingDepositCancellationRequest(0);
        assertEq(o, carol);
        assertEq(s, S_100K);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositCancellationRequest(2);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingRedeemRequest(0);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositCancellationRequest(0);
    }

    // Range getters `(startId, length)` (:700-714): `StartIdTooSmall` below the head,
    // `LengthTooLarge` past the end, exact contents including cancelled zero entries.
    function test_getPendingDepositRequests_range() public {
        ( uint256 idA, , uint256 idC ) = _threeDeposits();
        _cancel(carol, idC, carol, S_100K);
        _cancel(alice, idA, alice, S_1M);  // head = 1 (bob live), length = 3

        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingDepositRequests(0, 1);
        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingDepositRequests(1, 3);
        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingDepositRequests(2, 2);

        ISparkPrimeVault.Request[] memory all = vault.getPendingDepositRequests(1, 2);
        assertEq(all.length, 2);
        assertEq(all[0].owner,     bob);
        assertEq(all[0].recipient, bob);
        assertEq(all[0].shares,    S_100K);
        assertEq(all[1].owner,     address(0));
        assertEq(all[1].shares,    0);

        ISparkPrimeVault.Request[] memory one = vault.getPendingDepositRequests(2, 1);
        assertEq(one.length, 1);
        assertEq(one[0].owner, address(0));

        // The no-arg getter is the same window from the head.
        ISparkPrimeVault.Request[] memory noArg = vault.getPendingDepositRequests();
        assertEq(noArg.length, 2);
        assertEq(noArg[0].owner, bob);

        // Once bob cancels too, the self-skip clears both and the window is empty.
        _cancel(bob, 1, bob, S_100K);
        assertEq(vault.firstPendingDepositId(), 3);
        assertEq(vault.getPendingDepositRequests().length, 0);
        assertEq(vault.getPendingDepositRequests(3, 0).length, 0);
    }

    // Doc vs code (info): the natspec says a zero `length_` reverts (ISparkPrimeVault :855); it
    // returns an empty array. A `startId_` past the end panics in `length - startId_` (:707)
    // instead of reverting `LengthTooLarge`; `startId_ == length` with `length_ == 0` is fine.
    function test_getPendingRequests_range_zeroLengthAndStartPastEnd() public {
        _threeDeposits();
        assertEq(vault.getPendingDepositRequests(0, 0).length, 0);
        assertEq(vault.getPendingDepositRequests(3, 0).length, 0);
        vm.expectRevert(stdError.arithmeticError);
        vault.getPendingDepositRequests(4, 0);
        vm.expectRevert(stdError.arithmeticError);
        vault.getPendingDepositRequests(4, 1);

        // Empty queues: `(0, 0)` works, `(0, 1)` is `LengthTooLarge`, `(1, 0)` panics.
        assertEq(vault.getPendingDepositCancellationRequests(0, 0).length, 0);
        assertEq(vault.getPendingRedeemRequests(0, 0).length, 0);
        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingRedeemRequests(0, 1);
        vm.expectRevert(stdError.arithmeticError);
        vault.getPendingRedeemRequests(1, 0);
    }

    function test_getPendingDepositCancellationRequests_range() public {
        ( uint256 idA, uint256 idB, uint256 idC ) = _threeDeposits();
        uint256 c0 = _cancel(alice, idA, dave,  S_1M);
        uint256 c1 = _cancel(bob,   idB, bob,   S_100K);
        uint256 c2 = _cancel(carol, idC, carol, 1);
        assertEq(c0, 0); assertEq(c1, 1); assertEq(c2, 2);
        _processCancelledDeposits(type(uint256).max, 1);  // head = 1

        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingDepositCancellationRequests(0, 1);
        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingDepositCancellationRequests(1, 3);

        ISparkPrimeVault.Request[] memory r = vault.getPendingDepositCancellationRequests(1, 2);
        assertEq(r.length, 2);
        assertEq(r[0].owner,     bob);
        assertEq(r[0].recipient, bob);
        assertEq(r[0].shares,    S_100K);
        assertEq(r[1].owner,     carol);
        assertEq(r[1].shares,    1);
        assertEq(vault.getPendingDepositCancellationRequests().length, 2);
    }

    function test_getPendingRedeemRequests_range() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_100K);
        vm.prank(alice);
        vault.requestRedeem(SH_100K, bob);
        _requestRedeem(alice, SH_100K);
        _processRedeems(type(uint256).max, 1);  // head = 1

        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingRedeemRequests(0, 1);
        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingRedeemRequests(1, 3);
        ISparkPrimeVault.Request[] memory r = vault.getPendingRedeemRequests(1, 2);
        assertEq(r.length, 2);
        assertEq(r[0].owner,     alice);
        assertEq(r[0].recipient, bob);
        assertEq(r[0].shares,    SH_100K);
        assertEq(r[1].recipient, alice);
        assertEq(vault.getPendingRedeemRequests(2, 1).length, 1);
        assertEq(vault.getPendingRedeemRequests().length, 2);
    }

    // Storage layout pins for the slots this suite reads raw (CAMPAIGN.md): the three arrays
    // at 0-2 and `totalClaimable` at 18.
    function test_storageLayout_arraysAndTotalClaimable() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        assertEq(_rawLength(SLOT_DEPOSITS), 1);
        ( address o, address r, uint256 s ) = _rawDeposit(id);
        assertEq(o, alice);
        assertEq(r, alice);
        assertEq(s, S_1M);

        uint256 cid = _cancel(alice, id, bob, S_100K);
        assertEq(_rawLength(SLOT_CANCELLATIONS), 1);
        ( o, r, s ) = _rawCancellation(cid);
        assertEq(o, alice);
        assertEq(r, bob);
        assertEq(s, S_100K);

        _blacklist(bob);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(uint256(vm.load(address(vault), bytes32(SLOT_TOTAL_CLAIMABLE))), A_100K);
        assertEq(vault.totalClaimable(), A_100K);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        uint256 rid = _requestRedeem(alice, 1);
        assertEq(_rawLength(SLOT_REDEEMS), 1);
        ( o, r, s ) = _rawRedeem(rid);
        assertEq(o, alice);
        assertEq(s, 1);
    }

    function test_asset_isUsdc() public view {
        assertEq(vault.asset(),   address(usdc));
        assertEq(vault.savings(), address(spUsdc));
        assertEq(vault.decimals(), 6);
        assertEq(vault.version(), "1");
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

    function test_take_insufficientShares() public {
        _deposit(alice, ONE_M);
        assertEq(_vaultSpUsdc(), S_1M);
        vm.prank(taker);
        vm.expectRevert(ISparkPrimeVault.InsufficientShares.selector);
        vault.take(S_1M + 1);
        vm.prank(taker);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Take(S_1M);
        vault.take(S_1M);
        assertEq(_vaultSpUsdc(), 0);
        assertEq(spUsdc.balanceOf(taker), S_1M);
    }

    // Filled entries are deleted in all three queues (:896, :936, :972).
    function test_processQueues_entriesDeletedAfterFill() public {
        uint256 id = _deposit(alice, ONE_M);  // instant
        assertEq(id, 0);
        ( address o, address r, uint256 s ) = _rawDeposit(0);
        assertEq(o, address(0)); assertEq(r, address(0)); assertEq(s, 0);

        uint256 rid = _requestRedeem(alice, SH_100K);
        _processRedeems(type(uint256).max, type(uint256).max);
        ( o, r, s ) = _rawRedeem(rid);
        assertEq(o, address(0)); assertEq(r, address(0)); assertEq(s, 0);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingRedeemRequest(rid);

        _setCapacity(0);
        uint256 id2 = _deposit(bob, HUNDRED_K);
        uint256 cid = _cancelDepositAndSettle(bob, id2);
        ( o, r, s ) = _rawCancellation(cid);
        assertEq(o, address(0)); assertEq(r, address(0)); assertEq(s, 0);
        assertEq(usdc.balanceOf(bob), A_100K);
    }

}

/**************************************************************************************************/
/*** 18. Event shapes: `requestId` first everywhere                                            ***/
/**************************************************************************************************/

contract EventShapeTests is NewSurfaceBase {

    function test_events_requestDeposit_referralThenDepositRequestThenDeposit() public {
        _fund(alice, ONE_M);
        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Referral(7, 0, alice, bob, ONE_M);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositRequest(0, alice, bob, ONE_M, S_1M);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Deposit(0, alice, bob, S_1M, A_1M, SH_1M);
        vault.requestDeposit(ONE_M, bob, 7);
        assertEq(vault.balanceOf(bob), SH_1M);
    }

    function test_events_queuedDepositHasNoDepositEvent() public {
        _setCapacity(0);
        _fund(alice, ONE_M);
        vm.recordLogs();
        vm.prank(alice);
        vault.requestDeposit(ONE_M, alice, 0);
        // USDC Transfer + Approval? no: Transfer(alice->vault), spUSDC Deposit + Transfer (mint),
        // USDC Transfer(vault->spUSDC), Referral, DepositRequest: no `Deposit` from the vault.
        bytes32 depositSig = keccak256("Deposit(uint256,address,address,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault)) assertTrue(logs[i].topics[0] != depositSig);
        }
    }

    function test_events_redeemRequestAndRedeem() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, ONE_M);
        uint256 fee = (SH_1M * 0.01e18 - 1) / WAD + 1;
        assertEq(fee, 9_904_051_842);
        uint256 queued = SH_1M - fee;

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRequest(0, alice, bob, SH_1M, fee);
        vault.requestRedeem(SH_1M, bob);

        uint256 assets  = vault.convertToAssets(queued);
        uint256 savings = spUsdc.previewWithdraw(assets);
        assertEq(assets,  989_999_999_997);
        assertEq(savings, 944_987_364_230);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(0, alice, bob, queued, savings, assets);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), assets);
        assertEq(_vaultSpUsdc(), S_1M - savings);
    }

    function test_events_partialRedeemBurnsCeilSavingsShares() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_100K);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(0, alice, alice, SH_100K, RS_100K, R_100K);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(_vaultSpUsdc(), S_1M - RS_100K);
    }

    function test_events_depositCancellationRequestAndCancellation() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRequest(id, 0, bob, S_100K);
        uint256 cid = vault.requestDepositCancellation(id, bob, S_100K);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(cid, alice, bob, S_100K, A_100K);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
    }

    // The `Drip` event on every walk (each `_processPending*` drips first).
    function test_events_walksDripFirst() public {
        _deposit(alice, ONE_M);
        _setPrimeVsr(ONE_PCT_VSR);
        _warp(1 days);
        uint192 chiNow = vault.nowChi();
        assertGt(chiNow, CHI_P);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Drip(chiNow, vault.convertToAssets(SH_1M) - R_1M);
        _processRedeems(type(uint256).max, type(uint256).max);
    }

}
