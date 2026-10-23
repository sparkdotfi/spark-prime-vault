// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { NewSurfaceBase } from "./NewSurface.t.sol";

import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";

interface IERC4626Like {

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    function maxRedeem(address owner) external view returns (uint256);

    function maxWithdraw(address owner) external view returns (uint256);

}

/// @dev A recipient that reverts on any call: USDC's `transfer` never calls the receiver, so this
///      proves "reverting contract recipient" is NOT a fallback trigger.
contract RevertingRecipient {

    fallback() external payable { revert("RevertingRecipient"); }

    receive() external payable { revert("RevertingRecipient"); }

}

/// @dev The blacklist surface on `master` @ c512609: there is no `isBlacklisted` check anywhere.
///      `requestRedeem` (:448), `requestDepositCancellation` (:405) and the updaters accept any
///      non-zero, non-vault recipient; at payout `_withdrawSavings` (:997) / `_redeemSavings`
///      (:978) `try` the payout to the recipient and on ANY revert withdraw/redeem to the vault
///      and credit `claimableAssets` + `totalClaimable` (`_incrementClaimableAssets`, :1100).
///      `claim(recipient)` (:531) is permissionless, decrements `totalClaimable` and pays USDC out
///      of the vault's own balance.
///
///      Harness numbers: 1M USDC -> S_1M = 954_532_691_143 spUSDC -> SH_1M = 990_405_184_109
///      spPRIME; a full redeem pays R_1M = 999_999_999_998 and burns the whole S_1M; a full
///      cancellation refunds A_1M = 999_999_999_999.
abstract contract BlacklistBase is NewSurfaceBase {

    // Partial redeem of SH_1M with 300k of spUSDC liquidity, then the rest.
    uint256 constant PR_SHARES_1  = 297_121_555_233;
    uint256 constant PR_ASSETS_1  = 299_999_999_999;
    uint256 constant PR_SAVINGS_1 = 286_359_807_343;
    uint256 constant PR_SHARES_2  = 693_283_628_876;
    uint256 constant PR_ASSETS_2  = 699_999_999_998;
    uint256 constant PR_SAVINGS_2 = 668_172_883_799;

    // Partial cancellation of S_1M with 300k of spUSDC liquidity, then the rest.
    uint256 constant PC_SAVINGS_1 = 286_359_807_343;
    uint256 constant PC_ASSETS_1  = 299_999_999_999;
    uint256 constant PC_SAVINGS_2 = 668_172_883_800;
    uint256 constant PC_ASSETS_2  = 699_999_999_999;

    function _vaultUsdc() internal view returns (uint256) {
        return usdc.balanceOf(address(vault));
    }

    /// @dev alice holds SH_1M and has queued a full redeem to `recipient`.
    function _queuedRedeem(address recipient) internal returns (uint256 id) {
        _deposit(alice, ONE_M);
        vm.prank(alice);
        id = vault.requestRedeem(SH_1M, recipient);
    }

    /// @dev alice's 1M is queued (capacity 0) and cancelled in full to `recipient`.
    function _queuedCancellation(address recipient) internal returns (uint256 cid) {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        cid = _cancel(alice, id, recipient, S_1M);
    }

    function _assertNoClaimable(address who) internal view {
        assertEq(vault.claimableAssets(who), 0);
        assertEq(vault.totalClaimable(),     0);
        assertEq(_vaultUsdc(),               0);
    }

}

/**************************************************************************************************/
/*** requestRedeem: blacklisted recipients are accepted at request time                         ***/
/**************************************************************************************************/

contract RequestRedeemBlacklistTests is BlacklistBase {

    // Accepted at request (no check between `VaultIsRecipient` :455 and `BelowMinRedeem` :456),
    // parked at fill: the exact payout is credited instead of sent.
    function test_requestRedeem_blacklistedRecipient_acceptedAndParkedAtFill() public {
        _deposit(alice, ONE_M);
        _blacklist(bob);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRequest(0, alice, bob, SH_1M, 0);
        uint256 id = vault.requestRedeem(SH_1M, bob);

        ( address owner, address recipient, uint256 shares ) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    SH_1M);
        assertEq(vault.balanceOf(alice),          0);
        assertEq(vault.balanceOf(address(vault)), SH_1M);
        _assertNoClaimable(bob);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, R_1M);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, bob, SH_1M, RS_1M, R_1M);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(bob), R_1M);
        assertEq(vault.totalClaimable(),     R_1M);
        assertEq(_vaultUsdc(),               R_1M);
        assertEq(usdc.balanceOf(bob),        0);
        assertEq(vault.firstPendingRedeemId(), 1);
    }

    // The owner is not consulted: a blacklisted holder can request to itself (parked) or to a
    // clean recipient (paid).
    function test_requestRedeem_blacklistedOwner_success() public {
        _deposit(alice, ONE_M);
        _blacklist(alice);

        vm.prank(alice);
        uint256 idSelf = vault.requestRedeem(SH_100K, alice);
        vm.prank(alice);
        uint256 idBob = vault.requestRedeem(SH_100K, bob);
        ( address owner, address recipient, uint256 shares ) = _redeemRequest(idBob);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    SH_100K);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),          R_100K);
        assertEq(usdc.balanceOf(alice),        0);
        assertEq(vault.claimableAssets(alice), R_100K);
        assertEq(vault.totalClaimable(),       R_100K);
        assertEq(vault.firstPendingRedeemId(), idSelf + 2);
    }

    // Blacklisted at request time, clean at fill: the plain path pays, nothing is parked.
    function test_requestRedeem_unblacklistedBetweenRequestAndFill_paysDirectly() public {
        _deposit(alice, ONE_M);
        _blacklist(bob);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(SH_1M, bob);
        assertEq(id, 0);

        _unblacklist(bob);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, bob, SH_1M, RS_1M, R_1M);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), R_1M);
        _assertNoClaimable(bob);
    }

    // spUSDC is still accepted as a recipient (the vault is not, see `VaultAsRecipientTests`).
    function test_requestRedeem_savingsRecipient_accepted() public {
        _deposit(alice, ONE_M);
        vm.prank(alice);
        assertEq(vault.requestRedeem(SH_100K, address(spUsdc)), 0);
        ( , address recipient, ) = _redeemRequest(0);
        assertEq(recipient, address(spUsdc));
    }

}

/**************************************************************************************************/
/*** requestDepositCancellation: blacklisted recipients are accepted at request time            ***/
/**************************************************************************************************/

contract RequestDepositCancellationBlacklistTests is BlacklistBase {

    function test_requestDepositCancellation_blacklistedRecipient_acceptedAndParkedAtFill() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _blacklist(bob);

        // A bad id with a blacklisted recipient is `InvalidRequestId`: no recipient check exists.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.requestDepositCancellation(99, bob, S_1M);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRequest(id, 0, bob, S_1M);
        uint256 cid = vault.requestDepositCancellation(id, bob, S_1M);

        ( address owner, address recipient, uint256 shares ) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_1M);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, A_1M);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(cid, alice, bob, S_1M, A_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(bob), A_1M);
        assertEq(vault.totalClaimable(),     A_1M);
        assertEq(_vaultUsdc(),               A_1M);
        assertEq(usdc.balanceOf(bob),        0);
        assertEq(_vaultSpUsdc(),             0);
    }

    function test_requestDepositCancellation_blacklistedOwner_success() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _blacklist(alice);

        uint256 cidSelf = _cancel(alice, id, alice, S_100K);  // parked at fill
        uint256 cidBob  = _cancel(alice, id, bob, S_1M - S_100K);  // paid
        assertEq(cidSelf, 0);
        assertEq(cidBob,  1);
        assertEq(vault.firstPendingDepositId(), 1);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),          899_999_999_999);
        assertEq(usdc.balanceOf(alice),        0);
        assertEq(vault.claimableAssets(alice), A_100K);
        assertEq(vault.totalClaimable(),       A_100K);
        assertEq(_vaultUsdc(),                 A_100K);
    }

    // A partial cancel to a blacklisted recipient parks only that part.
    function test_requestDepositCancellation_partialToBlacklisted_parksOnlyThatPart() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _blacklist(bob);
        _cancel(alice, id, bob, S_100K);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(bob), A_100K);
        assertEq(vault.totalClaimable(),     A_100K);
        ( ,, uint256 left ) = _depositRequest(id);
        assertEq(left, S_1M - S_100K);
        assertEq(_vaultSpUsdc(), S_1M - S_100K);
    }

}

/**************************************************************************************************/
/*** updaters: blacklisted recipients are accepted                                              ***/
/**************************************************************************************************/

contract UpdateRecipientBlacklistTests is BlacklistBase {

    function test_updateDepositCancellationRecipient_toBlacklisted_parksAtFill() public {
        uint256 cid = _queuedCancellation(alice);
        _blacklist(bob);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRecipientUpdated(cid, bob);
        vault.updateDepositCancellationRecipient(cid, bob);
        ( , address recipient, ) = _cancelledDepositRequest(cid);
        assertEq(recipient, bob);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(bob),   A_1M);
        assertEq(vault.claimableAssets(alice), 0);
        assertEq(usdc.balanceOf(alice),        0);
        assertEq(vault.totalClaimable(),       A_1M);
    }

    // Re-pointing away from a blacklisted recipient before the fill pays the new one directly.
    function test_updateDepositCancellationRecipient_awayFromBlacklisted_paysDirectly() public {
        uint256 cid = _queuedCancellation(bob);
        _blacklist(bob);
        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cid, carol);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(carol), A_1M);
        assertEq(usdc.balanceOf(bob),   0);
        _assertNoClaimable(bob);
    }

    function test_updateDepositCancellationRecipient_blacklistedOwner_success() public {
        uint256 cid = _queuedCancellation(bob);
        _blacklist(alice);

        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cid, alice);  // accepted, will park
        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cid, carol);
        ( , address recipient, ) = _cancelledDepositRequest(cid);
        assertEq(recipient, carol);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(carol), A_1M);
        assertEq(usdc.balanceOf(bob),   0);
    }

    function test_updateRedeemRecipient_toBlacklisted_parksAtFill() public {
        uint256 id = _queuedRedeem(alice);
        _blacklist(bob);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRecipientUpdated(id, bob);
        vault.updateRedeemRecipient(id, bob);
        ( , address recipient, ) = _redeemRequest(id);
        assertEq(recipient, bob);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(bob),   R_1M);
        assertEq(vault.claimableAssets(alice), 0);
        assertEq(vault.totalClaimable(),       R_1M);
    }

    function test_updateRedeemRecipient_awayFromBlacklisted_paysDirectly() public {
        uint256 id = _queuedRedeem(bob);
        _blacklist(bob);
        vm.prank(alice);
        vault.updateRedeemRecipient(id, carol);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(carol), R_1M);
        _assertNoClaimable(bob);
    }

    function test_updateRedeemRecipient_blacklistedOwner_success() public {
        uint256 id = _queuedRedeem(bob);
        _blacklist(alice);

        vm.prank(alice);
        vault.updateRedeemRecipient(id, alice);
        vm.prank(alice);
        vault.updateRedeemRecipient(id, carol);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(carol), R_1M);
        assertEq(usdc.balanceOf(bob),   0);
    }

    // A parked entry is already settled: the owner cannot re-point it (`NoRequest`) and the
    // claimable stays with the blacklisted recipient until `claim` succeeds.
    function test_updateRedeemRecipient_parkedEntryCannotBeRepointed() public {
        uint256 id = _queuedRedeem(bob);
        _blacklist(bob);
        _processRedeems(type(uint256).max, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(id, carol);
        assertEq(vault.claimableAssets(bob), R_1M);
    }

}

/**************************************************************************************************/
/*** requestDeposit / updateDepositRecipient: USDC's own checks only                            ***/
/**************************************************************************************************/

contract RequestDepositBlacklistTests is BlacklistBase {

    // USDC's own `transferFrom` (:386) rejects a blacklisted depositor; the vault adds nothing.
    function test_requestDeposit_blacklistedSender_failure() public {
        _fund(alice, ONE_M);
        _blacklist(alice);

        vm.prank(alice);
        vm.expectRevert(BLACKLISTED);
        vault.requestDeposit(ONE_M, bob, 0);

        assertEq(usdc.balanceOf(alice), ONE_M);
        assertEq(_depositQueueLength(), 0);
    }

    // `requestDeposit` (:380-382) only rejects zero and the vault: a blacklisted recipient is
    // minted spPRIME, holds it and transfers it freely (shares are not USDC).
    function test_requestDeposit_blacklistedRecipient_success() public {
        _fund(alice, ONE_M);
        _blacklist(bob);

        vm.prank(alice);
        vault.requestDeposit(ONE_M, bob, 0);

        assertEq(vault.balanceOf(bob),   SH_1M);
        assertEq(vault.assetsOf(bob),    R_1M);
        assertEq(vault.balanceOf(alice), 0);

        vm.prank(bob);
        assertTrue(vault.transfer(carol, SH_100K));
        assertEq(vault.balanceOf(carol), SH_100K);
        assertEq(vault.balanceOf(bob),   SH_1M - SH_100K);

        // Bob redeems to himself (parked) and to a clean address (paid).
        vm.prank(bob);
        vault.requestRedeem(SH_100K, bob);
        vm.prank(bob);
        vault.requestRedeem(SH_100K, carol);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(carol),      R_100K);
        assertEq(vault.claimableAssets(bob), R_100K);
    }

    function test_updateDepositRecipient_blacklistedRecipient_success() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _blacklist(bob);

        vm.prank(alice);
        vault.updateDepositRecipient(id, bob);
        ( , address recipient, ) = _depositRequest(id);
        assertEq(recipient, bob);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.balanceOf(bob), SH_1M);
        _assertNoClaimable(bob);
    }

}

/**************************************************************************************************/
/*** processPendingRedeems: `_withdrawSavings` try / catch                                      ***/
/**************************************************************************************************/

contract ProcessPendingRedeemsBlacklistTests is BlacklistBase {

    // The `try` branch: spUSDC pays the recipient, the catch body never runs, nothing is parked.
    function test_processPendingRedeems_cleanRecipient_directBranch() public {
        uint256 id = _queuedRedeem(bob);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, bob, SH_1M, RS_1M, R_1M);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(bob), R_1M);
        _assertNoClaimable(bob);
        assertEq(_vaultSpUsdc(), 0);
        assertEq(vault.firstPendingRedeemId(), 1);
    }

    // The `catch` branch: spUSDC is withdrawn to the vault, the exact assets are credited,
    // `Redeem` carries the same amounts as the clean path.
    function test_processPendingRedeems_blacklistedRecipient_catchBranch() public {
        uint256 id = _queuedRedeem(alice);
        _blacklist(alice);

        assertEq(vault.balanceOf(address(vault)), SH_1M);
        assertEq(_vaultSpUsdc(), S_1M);
        assertEq(_vaultUsdc(),   0);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(alice, R_1M);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, alice, SH_1M, RS_1M, R_1M);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(alice), R_1M);
        assertEq(vault.totalClaimable(),       R_1M);
        assertEq(_vaultUsdc(),                 R_1M);
        assertEq(usdc.balanceOf(alice),        0);
        assertEq(_vaultSpUsdc(),               0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(),          0);
        assertEq(vault.pendingRedeemShares(),  0);
        assertEq(vault.firstPendingRedeemId(), 1);
        ( ,, uint256 left ) = _rawRedeem(id);
        assertEq(left, 0);
    }

    // R4-A fixed: the blacklisted entry no longer reverts the walk; the queue continues.
    function test_fixed_R4A_processPendingRedeems_queueContinuesPastBlacklistedRecipient() public {
        _deposit(alice, ONE_M);
        _deposit(bob,   ONE_M);
        uint256 idA = _requestRedeem(alice, SH_1M);
        uint256 idB = _requestRedeem(bob,   SH_1M);
        _blacklist(alice);

        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(vault.firstPendingRedeemId(), 2);
        assertEq(vault.claimableAssets(alice), R_1M);
        assertEq(vault.totalClaimable(),       R_1M);
        assertEq(usdc.balanceOf(alice),        0);
        assertEq(usdc.balanceOf(bob),          R_1M);
        assertEq(_vaultUsdc(),                 R_1M);
        assertEq(_vaultSpUsdc(),               0);
        ( ,, uint256 leftA ) = _rawRedeem(idA);
        ( ,, uint256 leftB ) = _rawRedeem(idB);
        assertEq(leftA, 0);
        assertEq(leftB, 0);

        _unblacklist(alice);
        vault.claim(alice);
        assertEq(usdc.balanceOf(alice), R_1M);
        assertEq(_vaultUsdc(), 0);
        assertEq(vault.totalClaimable(), 0);
    }

    // Partial fills (per-entry liquidity bound, :953) accrue into the same claimable.
    function test_processPendingRedeems_partialFillsAccrueClaimableTwice() public {
        _queuedRedeem(alice);
        _blacklist(alice);
        _drainSpUsdcLiquidity(700_000e6);  // 300k USDC left in spUSDC

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(alice, PR_ASSETS_1);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(0, alice, alice, PR_SHARES_1, PR_SAVINGS_1, PR_ASSETS_1);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(alice), PR_ASSETS_1);
        assertEq(vault.totalClaimable(),       PR_ASSETS_1);
        assertEq(_vaultUsdc(),                 PR_ASSETS_1);
        assertEq(vault.firstPendingRedeemId(), 0);  // partial fill stays at the head
        ( ,, uint256 left ) = _redeemRequest(0);
        assertEq(left, PR_SHARES_2);

        _returnSpUsdcLiquidity(700_000e6);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(alice, PR_ASSETS_2);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(0, alice, alice, PR_SHARES_2, PR_SAVINGS_2, PR_ASSETS_2);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(alice), PR_ASSETS_1 + PR_ASSETS_2);
        assertEq(vault.claimableAssets(alice), 999_999_999_997);  // 1 wei less than one fill
        assertEq(vault.totalClaimable(),       999_999_999_997);
        assertEq(_vaultUsdc(),                 999_999_999_997);
        assertEq(_vaultSpUsdc(),               S_1M - PR_SAVINGS_1 - PR_SAVINGS_2);
        assertEq(_vaultSpUsdc(),               1);
        assertEq(vault.firstPendingRedeemId(), 1);
    }

    // Blacklist flipped between two partial fills: the first pays alice, the second accrues.
    function test_processPendingRedeems_blacklistFlipsBetweenPartialFills() public {
        _queuedRedeem(alice);
        _drainSpUsdcLiquidity(700_000e6);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),        PR_ASSETS_1);
        assertEq(vault.claimableAssets(alice), 0);

        _blacklist(alice);
        _returnSpUsdcLiquidity(700_000e6);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),        PR_ASSETS_1);
        assertEq(vault.claimableAssets(alice), PR_ASSETS_2);
        assertEq(vault.totalClaimable(),       PR_ASSETS_2);
        assertEq(_vaultUsdc(),                 PR_ASSETS_2);

        _unblacklist(alice);
        vault.claim(alice);
        assertEq(usdc.balanceOf(alice), PR_ASSETS_1 + PR_ASSETS_2);
    }

    // Two entries to the same blacklisted recipient sum into one claimable balance.
    function test_processPendingRedeems_multipleEntriesSameRecipientSum() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_100K);
        vm.prank(alice);
        vault.requestRedeem(SH_100K, bob);
        _requestRedeem(alice, SH_100K);
        _blacklist(alice);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(alice), 2 * R_100K);
        assertEq(vault.claimableAssets(alice), 199_999_999_996);
        assertEq(vault.totalClaimable(),       199_999_999_996);
        assertEq(usdc.balanceOf(bob),          R_100K);
        assertEq(_vaultUsdc(),                 199_999_999_996);
        assertEq(vault.firstPendingRedeemId(), 3);
    }

    // Several blacklisted recipients in one walk: per-recipient balances, one total.
    function test_processPendingRedeems_multipleRecipientsSumIntoTotalClaimable() public {
        _deposit(alice, ONE_M);
        vm.startPrank(alice);
        vault.requestRedeem(SH_100K, bob);
        vault.requestRedeem(SH_100K, carol);
        vault.requestRedeem(SH_100K, dave);
        vault.requestRedeem(SH_100K, bob);
        vm.stopPrank();
        _blacklist(bob);
        _blacklist(carol);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(bob),   2 * R_100K);
        assertEq(vault.claimableAssets(carol), R_100K);
        assertEq(vault.claimableAssets(dave),  0);
        assertEq(usdc.balanceOf(dave),         R_100K);
        assertEq(vault.totalClaimable(),       3 * R_100K);
        assertEq(_vaultUsdc(),                 3 * R_100K);
        assertEq(vault.firstPendingRedeemId(), 4);
    }

    // Recipient blacklisted after the request but clean again at payout: plain path.
    function test_processPendingRedeems_unblacklistedBeforePayout_paysDirectly() public {
        uint256 id = _queuedRedeem(alice);
        _blacklist(alice);
        _unblacklist(alice);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), R_1M);
        _assertNoClaimable(alice);
        ( ,, uint256 left ) = _rawRedeem(id);
        assertEq(left, 0);
    }

    // A contract that reverts on every call is a fine recipient: ERC20 `transfer` does not call
    // it, so the direct branch pays it like an EOA.
    function test_processPendingRedeems_revertingContractRecipient_paidDirectly() public {
        address sink = address(new RevertingRecipient());
        uint256 id = _queuedRedeem(sink);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(sink), R_1M);
        _assertNoClaimable(sink);
        ( ,, uint256 left ) = _rawRedeem(id);
        assertEq(left, 0);
    }

}

/**************************************************************************************************/
/*** processPendingDepositCancellations: `_redeemSavings` try / catch                           ***/
/**************************************************************************************************/

contract ProcessPendingDepositCancellationsBlacklistTests is BlacklistBase {

    function test_processPendingDepositCancellations_cleanRecipient_directBranch() public {
        uint256 cid = _queuedCancellation(bob);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(cid, alice, bob, S_1M, A_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), A_1M);
        _assertNoClaimable(bob);
        assertEq(_vaultSpUsdc(), 0);
    }

    function test_processPendingDepositCancellations_blacklistedRecipient_catchBranch() public {
        uint256 cid = _queuedCancellation(alice);
        _blacklist(alice);
        assertEq(_vaultSpUsdc(), S_1M);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(alice, A_1M);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(cid, alice, alice, S_1M, A_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(alice), A_1M);
        assertEq(vault.totalClaimable(),       A_1M);
        assertEq(_vaultUsdc(),                 A_1M);
        assertEq(usdc.balanceOf(alice),        0);
        assertEq(_vaultSpUsdc(),               0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),    1);
        ( ,, uint256 left ) = _rawCancellation(cid);
        assertEq(left, 0);
    }

    // R4-B fixed: the cancellation queue continues past a blacklisted recipient.
    function test_fixed_R4B_processPendingDepositCancellations_queueContinues() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, ONE_M);
        uint256 idB = _deposit(bob,   HUNDRED_K);
        _cancel(alice, idA, alice, S_1M);
        _cancel(bob,   idB, bob,   S_100K);
        _blacklist(alice);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(vault.claimableAssets(alice), A_1M);
        assertEq(vault.totalClaimable(),       A_1M);
        assertEq(usdc.balanceOf(alice),        0);
        assertEq(usdc.balanceOf(bob),          A_100K);
        assertEq(_vaultUsdc(),                 A_1M);
        assertEq(_vaultSpUsdc(),               0);

        _unblacklist(alice);
        vault.claim(alice);
        assertEq(usdc.balanceOf(alice), A_1M);
        assertEq(_vaultUsdc(), 0);
        assertEq(vault.totalClaimable(), 0);
    }

    function test_processPendingDepositCancellations_partialFillsAccrueTwice() public {
        _queuedCancellation(alice);
        _blacklist(alice);
        _drainSpUsdcLiquidity(700_000e6);  // maxRedeem bounds the walk (:908)

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(alice, PC_ASSETS_1);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(0, alice, alice, PC_SAVINGS_1, PC_ASSETS_1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(alice), PC_ASSETS_1);
        assertEq(vault.firstPendingDepositCancellationId(), 0);

        _returnSpUsdcLiquidity(700_000e6);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(alice, PC_ASSETS_2);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(0, alice, alice, PC_SAVINGS_2, PC_ASSETS_2);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(alice), PC_ASSETS_1 + PC_ASSETS_2);
        assertEq(vault.claimableAssets(alice), 999_999_999_998);  // 1 wei below A_1M
        assertEq(vault.totalClaimable(),       999_999_999_998);
        assertEq(_vaultUsdc(),                 999_999_999_998);
        assertEq(_vaultSpUsdc(),               0);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
    }

    function test_processPendingDepositCancellations_blacklistFlipsBetweenPartialFills() public {
        _queuedCancellation(alice);
        _drainSpUsdcLiquidity(700_000e6);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), PC_ASSETS_1);

        _blacklist(alice);
        _returnSpUsdcLiquidity(700_000e6);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),        PC_ASSETS_1);
        assertEq(vault.claimableAssets(alice), PC_ASSETS_2);
        assertEq(vault.totalClaimable(),       PC_ASSETS_2);
    }

    function test_processPendingDepositCancellations_multipleRecipientsSum() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _cancel(alice, id, bob,   S_100K);
        _cancel(alice, id, carol, S_100K);
        _cancel(alice, id, bob,   S_100K);
        _cancel(alice, id, dave,  S_100K);
        _blacklist(bob);
        _blacklist(carol);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(bob),   2 * A_100K);
        assertEq(vault.claimableAssets(carol), A_100K);
        assertEq(usdc.balanceOf(dave),         A_100K);
        assertEq(vault.totalClaimable(),       3 * A_100K);
        assertEq(_vaultUsdc(),                 3 * A_100K);
        assertEq(vault.firstPendingDepositCancellationId(), 4);
    }

    function test_processPendingDepositCancellations_revertingContractRecipient_paidDirectly() public {
        address sink = address(new RevertingRecipient());
        _queuedCancellation(sink);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(sink), A_1M);
        _assertNoClaimable(sink);
    }

}

/**************************************************************************************************/
/*** Non-recipient reverts propagate out of the catch path                                      ***/
/**************************************************************************************************/

contract NonRecipientRevertTests is BlacklistBase {

    // With spUSDC's liquidity really drained the walks never call spUSDC: the redeem walk breaks
    // at `fillable_ == 0` (:955) and the cancellation walk has `remaining_ == 0` (:908).
    function test_drainedLiquidity_walksDoNotCallSpUsdc() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_100K);
        _setCapacity(0);
        uint256 id = _deposit(bob, HUNDRED_K);
        _cancel(bob, id, bob, S_100K);
        _drainAllSpUsdcLiquidity();
        assertEq(vault.availableLiquidAssets(), 0);
        assertEq(spUsdc.maxRedeem(address(vault)), 0);

        _processRedeems(type(uint256).max, type(uint256).max);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(vault.firstPendingDepositCancellationId(), 0);
        assertEq(vault.pendingRedeemShares(), SH_100K);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_100K);
        _assertNoClaimable(alice);
    }

    // If the bound were stale (liquidity gone between the view and the call), the `try` reverts
    // with `SparkVault/insufficient-liquidity`, the fallback withdraw to the vault reverts the
    // same way, and the revert propagates: no claimable, no state change. Simulated by mocking
    // the bound views while the real liquidity is drained.
    function test_drainedLiquidity_staleBound_bothCallsRevertAndPropagate() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_100K);
        _setCapacity(0);
        uint256 id = _deposit(bob, HUNDRED_K);
        _cancel(bob, id, bob, S_100K);
        _drainAllSpUsdcLiquidity();

        vm.mockCall(
            address(spUsdc),
            abi.encodeWithSelector(IERC4626Like.maxWithdraw.selector, address(vault)),
            abi.encode(uint256(ONE_M))
        );
        vm.mockCall(
            address(spUsdc),
            abi.encodeWithSelector(IERC4626Like.maxRedeem.selector, address(vault)),
            abi.encode(uint256(S_1M))
        );

        vm.prank(operator);
        vm.expectRevert("SparkVault/insufficient-liquidity");
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);
        vm.prank(operator);
        vm.expectRevert("SparkVault/insufficient-liquidity");
        vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);

        assertEq(vault.pendingRedeemShares(), SH_100K);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_100K);
        _assertNoClaimable(alice);
        _assertNoClaimable(bob);

        // Same with a blacklisted recipient: the recipient revert is caught, the liquidity revert
        // of the fallback is not.
        _blacklist(alice);
        _blacklist(bob);
        vm.prank(operator);
        vm.expectRevert("SparkVault/insufficient-liquidity");
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);
        vm.prank(operator);
        vm.expectRevert("SparkVault/insufficient-liquidity");
        vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);
        _assertNoClaimable(alice);
    }

    // Any revert that is not recipient-specific (here: spUSDC reverting for every receiver)
    // reverts the whole walk; the catch is not a blanket swallow.
    function test_spUsdcRevertsForEveryReceiver_walkReverts() public {
        _queuedRedeem(alice);
        vm.mockCallRevert(address(spUsdc), abi.encodeWithSelector(IERC4626Like.withdraw.selector), bytes("boom"));
        vm.prank(operator);
        vm.expectRevert(bytes("boom"));
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);
        vm.clearMockedCalls();

        _queuedCancellation(bob);
        vm.mockCallRevert(address(spUsdc), abi.encodeWithSelector(IERC4626Like.redeem.selector), bytes("boom"));
        vm.prank(operator);
        vm.expectRevert(bytes("boom"));
        vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);
        assertEq(vault.totalClaimable(), 0);
    }

}

/**************************************************************************************************/
/*** claim                                                                                      ***/
/**************************************************************************************************/

contract ClaimTests is BlacklistBase {

    function test_claim_nothingToClaim_failure() public {
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(alice);
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(address(0));
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(address(vault));

        // A clean payout never leaves anything to claim.
        _queuedRedeem(alice);
        _processRedeems(type(uint256).max, type(uint256).max);
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(alice);
    }

    // USDC reverts while the recipient is still blacklisted; the vault's writes happened inside
    // the same call, so nothing changes.
    function test_claim_stillBlacklisted_failure() public {
        _queuedRedeem(alice);
        _blacklist(alice);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(alice), R_1M);

        vm.expectRevert(BLACKLISTED);
        vault.claim(alice);
        vm.prank(alice);
        vm.expectRevert(BLACKLISTED);
        vault.claim(alice);

        assertEq(vault.claimableAssets(alice), R_1M);
        assertEq(vault.totalClaimable(),       R_1M);
        assertEq(_vaultUsdc(),                 R_1M);
        assertEq(usdc.balanceOf(alice),        0);
    }

    function test_claim_success() public {
        _queuedRedeem(alice);
        _blacklist(alice);
        _processRedeems(type(uint256).max, type(uint256).max);
        _unblacklist(alice);

        // Permissionless: a stranger triggers it, the USDC still goes to alice.
        vm.prank(mallory);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Claim(alice, R_1M);
        uint256 paid = vault.claim(alice);

        assertEq(paid,                         R_1M);
        assertEq(vault.claimableAssets(alice), 0);
        assertEq(vault.totalClaimable(),       0);
        assertEq(usdc.balanceOf(alice),        R_1M);
        assertEq(usdc.balanceOf(mallory),      0);
        assertEq(_vaultUsdc(),                 0);

        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(alice);
    }

    function test_claim_worksWhilePaused() public {
        _queuedRedeem(alice);
        _blacklist(alice);
        _processRedeems(type(uint256).max, type(uint256).max);
        _unblacklist(alice);
        _pause();
        assertEq(vault.claim(alice), R_1M);
        assertEq(usdc.balanceOf(alice), R_1M);
        assertEq(vault.totalClaimable(), 0);
    }

    // Accruals from both queues add into the same balance and pay out in one claim.
    function test_claim_sumsRedeemAndCancellationAccruals() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_100K);
        _setCapacity(vault.totalSupply());
        uint256 id = _deposit(alice, HUNDRED_K);  // queued
        _cancel(alice, id, alice, S_100K);
        _blacklist(alice);

        _processRedeems(type(uint256).max, type(uint256).max);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(alice), R_100K + A_100K);
        assertEq(vault.claimableAssets(alice), 199_999_999_997);
        assertEq(vault.totalClaimable(),       199_999_999_997);
        assertEq(_vaultUsdc(),                 199_999_999_997);

        _unblacklist(alice);
        assertEq(vault.claim(alice), 199_999_999_997);
        assertEq(usdc.balanceOf(alice), 199_999_999_997);
        assertEq(_vaultUsdc(), 0);
        assertEq(vault.totalClaimable(), 0);
    }

    // `totalClaimable` is decremented per claim; other recipients' balances are untouched.
    function test_claim_decrementsTotalClaimablePerRecipient() public {
        _deposit(alice, ONE_M);
        vm.startPrank(alice);
        vault.requestRedeem(SH_100K, bob);
        vault.requestRedeem(SH_100K, carol);
        vm.stopPrank();
        _blacklist(bob);
        _blacklist(carol);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.totalClaimable(), 2 * R_100K);

        _unblacklist(bob);
        assertEq(vault.claim(bob), R_100K);
        assertEq(vault.totalClaimable(),       R_100K);
        assertEq(vault.claimableAssets(carol), R_100K);
        assertEq(_vaultUsdc(),                 R_100K);
        vm.expectRevert(BLACKLISTED);
        vault.claim(carol);
        _unblacklist(carol);
        assertEq(vault.claim(carol), R_100K);
        assertEq(vault.totalClaimable(), 0);
        assertEq(_vaultUsdc(), 0);
    }

}

/**************************************************************************************************/
/*** Claimable USDC is isolated from every other flow                                           ***/
/**************************************************************************************************/

contract ClaimableIsolationTests is BlacklistBase {

    function _setUpClaimable() internal {
        _queuedRedeem(alice);
        _blacklist(alice);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(alice), R_1M);
        assertEq(vault.totalClaimable(),       R_1M);
        assertEq(_vaultUsdc(),                 R_1M);
    }

    // Not counted anywhere: `totalAssets` is notional (:850) and `availableLiquidAssets` is
    // spUSDC's `maxWithdraw` (:823).
    function test_claimable_notCountedByViews() public {
        _setUpClaimable();
        assertEq(vault.totalAssets(),           0);
        assertEq(vault.totalSupply(),           0);
        assertEq(vault.availableLiquidAssets(), 0);
        assertEq(vault.availableCapacity(),     type(uint128).max);
        assertEq(_vaultSpUsdc(),                0);

        _deposit(bob, ONE_M);
        assertEq(vault.totalAssets(),           R_1M);
        assertEq(vault.availableLiquidAssets(), A_1M);  // spUSDC side only
        assertEq(_vaultUsdc(),                  R_1M);  // unchanged
    }

    // `requestDeposit` (:386-388) pulls exactly `assets_` and deposits exactly `assets_`; `take`
    // (:295) moves spUSDC only; the three walks only touch spUSDC; `adjustTotalAssets` only
    // touches chi. The vault's USDC balance equals `totalClaimable` through all of it.
    function test_claimable_untouchedByEveryOtherFunction() public {
        _setUpClaimable();

        _deposit(bob, ONE_M);                                  // instant fill
        assertEq(_vaultUsdc(), R_1M);
        _setCapacity(vault.totalSupply());
        uint256 id = _deposit(carol, HUNDRED_K);               // queued
        assertEq(_vaultUsdc(), R_1M);
        vm.prank(carol);
        vault.updateDepositRecipient(id, carol);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(_vaultUsdc(), R_1M);

        _setCapacity(0);
        id = _deposit(carol, HUNDRED_K);
        _cancel(carol, id, carol, S_100K / 2);
        _cancel(carol, id, carol, S_100K - S_100K / 2);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(_vaultUsdc(), R_1M);
        assertEq(usdc.balanceOf(carol), A_100K - 1);           // two floors

        uint256 rid = _requestRedeem(bob, SH_100K);
        vm.prank(bob);
        vault.updateRedeemRecipient(rid, bob);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(_vaultUsdc(), R_1M);

        _takeAll();                                            // every spUSDC share leaves
        assertEq(_vaultSpUsdc(), 0);
        assertEq(_vaultUsdc(),   R_1M);
        _returnToVault(S_100K);

        _adjustTotalAssetsWhilePaused(-int256(HUNDRED_K));
        _adjustTotalAssetsWhilePaused(int256(HUNDRED_K));
        assertEq(_vaultUsdc(), R_1M);
        assertEq(vault.claimableAssets(alice), R_1M);

        _setPrimeVsr(ONE_PCT_VSR);
        _setSpUsdcVsr(ONE_PCT_VSR);
        _warpAndDrip(30 days);
        _setRedeemFeeRate(0.01e18);
        _setMinDeposit(2);
        _setMinRedeem(2);
        _setMinDepositCancellation(2);
        vm.prank(admin);
        vault.setVSRBounds(RAY, MAX_VSR);
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.01e18);
        assertEq(_vaultUsdc(), R_1M);
        assertEq(vault.totalClaimable(), R_1M);

        _unblacklist(alice);
        assertEq(vault.claim(alice), R_1M);
        assertEq(_vaultUsdc(), 0);
        assertEq(vault.totalClaimable(), 0);
    }

    // Fallback accounting: vault USDC == totalClaimable == sum of claimables, for any mix of
    // blacklisted recipients, amounts, partial liquidity and claims, through both queues.
    /// forge-config: default.fuzz.runs = 20000
    function testFuzz_fallbackAccounting_vaultUsdcEqualsTotalClaimableEqualsSum(
        uint256 redeemA,
        uint256 redeemB,
        uint256 cancelC,
        uint256 cancelD,
        uint256 liquidityPct,
        uint8   mask
    ) public {
        address[4] memory who = [bob, carol, dave, mallory];

        _deposit(alice, ONE_M);
        redeemA = bound(redeemA, 1, SH_1M / 2);
        redeemB = bound(redeemB, 1, SH_1M / 2);
        vm.startPrank(alice);
        vault.requestRedeem(redeemA, bob);
        vault.requestRedeem(redeemB, carol);
        vm.stopPrank();

        _setCapacity(vault.totalSupply());
        uint256 id = _deposit(alice, ONE_M);  // queued
        cancelC = bound(cancelC, 1, S_1M / 2);
        cancelD = bound(cancelD, 1, S_1M / 2);
        _cancel(alice, id, dave,    cancelC);
        _cancel(alice, id, mallory, cancelD);

        for (uint256 i; i < 4; ++i) if (mask & (1 << i) != 0) _blacklist(who[i]);

        // Partial liquidity, two rounds, both queues.
        liquidityPct = bound(liquidityPct, 0, 100);
        uint256 spUsdcBal = usdc.balanceOf(address(spUsdc));
        _drainSpUsdcLiquidity(spUsdcBal - spUsdcBal * liquidityPct / 100);
        _processRedeems(type(uint256).max, type(uint256).max);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        _assertAccounting(who);

        _returnSpUsdcLiquidity(spUsdcBal);
        _processRedeems(type(uint256).max, type(uint256).max);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        _assertAccounting(who);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);

        // Blacklisted recipients were parked for exactly the payout, clean ones were paid.
        uint256[4] memory expected =
            [vault.convertToAssets(redeemA), vault.convertToAssets(redeemB),
             spUsdc.convertToAssets(cancelC), spUsdc.convertToAssets(cancelD)];
        for (uint256 i; i < 4; ++i) {
            if (mask & (1 << i) != 0) {
                assertEq(usdc.balanceOf(who[i]), 0);
                assertApproxEqAbs(vault.claimableAssets(who[i]), expected[i], 2);
            } else {
                assertEq(vault.claimableAssets(who[i]), 0);
                assertApproxEqAbs(usdc.balanceOf(who[i]), expected[i], 2);
            }
        }

        // Claims drain it to zero, in any order.
        for (uint256 i; i < 4; ++i) {
            if (mask & (1 << i) == 0) continue;
            _unblacklist(who[i]);
            uint256 c = vault.claimableAssets(who[i]);
            assertEq(vault.claim(who[i]), c);
            assertEq(usdc.balanceOf(who[i]), c);
            _assertAccounting(who);
        }
        assertEq(_vaultUsdc(), 0);
        assertEq(vault.totalClaimable(), 0);
    }

    function _assertAccounting(address[4] memory who) internal view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) sum += vault.claimableAssets(who[i]);
        assertEq(vault.totalClaimable(), sum);
        assertEq(_vaultUsdc(),           sum);
    }

}

/**************************************************************************************************/
/*** V2-13: the vault is rejected as recipient everywhere; spUSDC is not                       ***/
/**************************************************************************************************/

contract VaultAsRecipientTests is BlacklistBase {

    function test_fixed_V2_13_requestDeposit_vaultRecipientReverts() public {
        _fund(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDeposit(ONE_M, address(vault), 0);
        assertEq(_depositQueueLength(), 0);
    }

    function test_fixed_V2_13_requestRedeem_vaultRecipientReverts() public {
        _deposit(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestRedeem(SH_1M, address(vault));
        // After ZeroRecipient, before BelowMinRedeem.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.requestRedeem(0, address(0));
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestRedeem(0, address(vault));
        assertEq(vault.balanceOf(alice), SH_1M);
        assertEq(_redeemQueueLength(),   0);
    }

    function test_fixed_V2_13_requestDepositCancellation_vaultRecipientReverts() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDepositCancellation(id, address(vault), S_1M);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);  // before the id check
        vault.requestDepositCancellation(99, address(vault), S_1M);
        ( ,, uint256 shares ) = _depositRequest(id);
        assertEq(shares, S_1M);
    }

    function test_fixed_V2_13_updaters_vaultRecipientReverts() public {
        _setCapacity(0);
        uint256 id  = _deposit(alice, ONE_M);
        uint256 cid = _cancel(alice, id, alice, S_100K);
        _setCapacity(type(uint128).max);
        _deposit(bob, ONE_M);  // queued behind alice
        _processDeposits(type(uint256).max, type(uint256).max);
        uint256 rid = _requestRedeem(bob, SH_1M);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositCancellationRecipient(cid, address(vault));
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateRedeemRecipient(rid, address(vault));
        _setCapacity(0);
        uint256 id2 = _deposit(carol, HUNDRED_K);
        vm.prank(carol);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositRecipient(id2, address(vault));

        // Before the id check and the owner check: strangers and bad ids get it too.
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositRecipient(99, address(vault));
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositCancellationRecipient(99, address(vault));
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateRedeemRecipient(99, address(vault));

        ( , address r, ) = _cancelledDepositRequest(cid);
        assertEq(r, alice);
        ( , r, ) = _redeemRequest(rid);
        assertEq(r, bob);
    }

    // spUSDC as recipient (open, low): spUSDC burns the vault's shares and transfers the USDC to
    // itself, so the value is donated to the remaining spUSDC holders (its index does not move).
    function test_BUG_V2_13_savingsAsRedeemRecipient_donatesToSpUsdc() public {
        _deposit(bob, ONE_M);
        _queuedRedeem(address(spUsdc));
        uint256 spUsdcUsdcBefore = usdc.balanceOf(address(spUsdc));
        uint256 spUsdcSupply     = spUsdc.totalSupply();
        assertEq(spUsdcUsdcBefore, 2 * ONE_M);
        assertEq(spUsdcSupply,     2 * S_1M);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(0, alice, address(spUsdc), SH_1M, RS_1M, R_1M);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(address(spUsdc)), spUsdcUsdcBefore);     // nothing left spUSDC
        assertEq(spUsdc.totalSupply(),            spUsdcSupply - S_1M);  // but S_1M was burned
        assertEq(spUsdc.nowChi(),                 CHI_S);                // index unchanged
        assertEq(_vaultSpUsdc(),                  S_1M);                 // bob's backing only
        assertEq(vault.claimableAssets(address(spUsdc)), 0);
        assertEq(vault.totalClaimable(),          0);
        assertEq(usdc.balanceOf(alice),           0);
        assertEq(_vaultUsdc(),                    0);
        // spUSDC now holds 2M USDC against ~1M of liabilities: 1M of unaccounted surplus.
        assertEq(usdc.balanceOf(address(spUsdc)) - spUsdc.totalAssets(), 1_000_000_000_001);
    }

    function test_BUG_V2_13_savingsAsCancellationRecipient_donatesToSpUsdc() public {
        _deposit(bob, ONE_M);
        _queuedCancellation(address(spUsdc));
        uint256 spUsdcSupply = spUsdc.totalSupply();
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(address(spUsdc)), 2 * ONE_M);
        assertEq(spUsdc.totalSupply(),            spUsdcSupply - S_1M);
        assertEq(vault.totalClaimable(),          0);
        assertEq(usdc.balanceOf(address(spUsdc)) - spUsdc.totalAssets(), 1_000_000_000_001);
    }

}

/**************************************************************************************************/
/*** A blacklisted vault                                                                        ***/
/**************************************************************************************************/

contract BlacklistedVaultTests is BlacklistBase {

    // If USDC blacklists the vault itself: deposits die at the USDC pull (and even at the
    // approval), clean redeems and cancellations still pay (spUSDC pushes USDC straight to the
    // recipient), `claim` is dead, and the fallback path reverts inside USDC because the
    // withdraw-to-vault is itself a transfer to a blacklisted address: the parked entry sticks at
    // the head and blocks the walk (R4-A shape, needs both blacklists). The owner can still
    // re-point it to a clean recipient, which unsticks the queue.
    function test_blacklistedVault_cleanPayoutsWork_fallbackRevertsAndEntrySticks() public {
        _deposit(alice, ONE_M);
        _deposit(bob,   ONE_M);
        _deposit(dave,  ONE_M);
        _setCapacity(0);
        uint256 depId = _deposit(carol, HUNDRED_K);
        uint256 idA = _requestRedeem(alice, SH_1M);
        uint256 idB = _requestRedeem(bob,   SH_1M);
        uint256 idD = _requestRedeem(dave,  SH_1M);
        _blacklist(bob);
        _blacklist(address(vault));

        // Deposits: the approval and the pull both die in USDC.
        usdc.mint(mallory, ONE_M);
        vm.prank(mallory);
        vm.expectRevert(BLACKLISTED);
        usdc.approve(address(vault), ONE_M);
        vm.prank(alice);  // alice approved in `_deposit` before the blacklist
        vm.expectRevert(BLACKLISTED);
        vault.requestDeposit(1, alice, 0);

        // Clean redeem at the head pays.
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), R_1M);
        assertEq(vault.firstPendingRedeemId(), 1);
        ( ,, uint256 leftA ) = _rawRedeem(idA);
        assertEq(leftA, 0);

        // Bob's entry: the try reverts (bob), the fallback reverts (vault): the walk reverts.
        vm.prank(operator);
        vm.expectRevert(BLACKLISTED);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);
        vm.prank(operator);
        vm.expectRevert(BLACKLISTED);
        vault.processPendingRedeems(type(uint256).max, 1);
        assertEq(vault.firstPendingRedeemId(), 1);
        assertEq(vault.totalClaimable(), 0);
        ( ,, uint256 leftB ) = _redeemRequest(idB);
        assertEq(leftB, SH_1M);
        assertEq(usdc.balanceOf(dave), 0);  // dave is stuck behind bob

        // A clean cancellation still pays while the vault is blacklisted.
        _cancel(carol, depId, carol, S_100K);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(carol), A_100K);

        // Bob re-points to a clean address: the queue moves again.
        vm.prank(bob);
        vault.updateRedeemRecipient(idB, carol);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(carol), A_100K + R_1M);
        assertEq(usdc.balanceOf(dave),  R_1M);
        assertEq(vault.firstPendingRedeemId(), 3);
        ( ,, uint256 leftD ) = _rawRedeem(idD);
        assertEq(leftD, 0);
    }

    // `claim` is dead while the vault is blacklisted even for a clean recipient; it resumes
    // once the vault is clean again.
    function test_blacklistedVault_claimDeadUntilUnblacklisted() public {
        _queuedRedeem(bob);
        _blacklist(bob);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(bob), R_1M);

        _unblacklist(bob);
        _blacklist(address(vault));
        vm.expectRevert(BLACKLISTED);
        vault.claim(bob);
        assertEq(vault.claimableAssets(bob), R_1M);
        assertEq(vault.totalClaimable(),     R_1M);

        _unblacklist(address(vault));
        assertEq(vault.claim(bob), R_1M);
        assertEq(vault.totalClaimable(), 0);
    }

}
