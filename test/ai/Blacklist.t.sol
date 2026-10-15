// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { NewSurfaceBase } from "./NewSurface.t.sol";

/// @dev The USDC-blacklist surface new on `master` @ 0ebb452: `_canReceiveAsset` (:1051) gates
///      the recipient of `requestRedeem` (:452), `requestDepositCancellation` (:425),
///      `updateDepositCancellationRecipient` (:493) and `updateRedeemRecipient` (:508) with
///      `recipient-cannot-receive`; at payout `_withdrawSavings` (:947) and `_redeemSavings`
///      (:934) fall back to withdrawing to the vault and crediting `claimableAssets`
///      (`ClaimableAssetsIncreased`); `claim(recipient)` (:524) is permissionless and pays USDC
///      out of the vault's own balance.
///
///      Harness numbers: 1M USDC -> S_1M = 954_532_691_143 spUSDC -> SH_1M = 990_405_184_109
///      spPRIME; a full redeem pays R_1M = 999_999_999_998 and burns the whole S_1M; a full
///      cancellation refunds A_1M = 999_999_999_999.
abstract contract BlacklistBase is NewSurfaceBase {

    event ClaimableAssetsIncreased(address indexed recipient, uint256 increase);
    event Claim(address indexed recipient, uint256 assets);
    event DepositCancellation(
        address indexed owner,
        address indexed recipient,
        uint256         savingsSharesBurned,
        uint256         assetsReceived
    );
    event DepositCancellationRequest(
        uint256 indexed depositRequestId,
        uint256 indexed cancelRequestId,
        address indexed recipient
    );

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

    /// @dev alice's 1M is queued (capacity 0) and cancelled to `recipient`.
    function _queuedCancellation(address recipient) internal returns (uint256 cid) {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        cid = vault.requestDepositCancellation(id, recipient);
    }

}

/**************************************************************************************************/
/*** requestRedeem                                                                              ***/
/**************************************************************************************************/

contract RequestRedeemBlacklistTests is BlacklistBase {

    function test_requestRedeem_blacklistedRecipient_failure() public {
        _deposit(alice, ONE_M);
        _blacklist(bob);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestRedeem(SH_1M, bob);

        // Checked after `zero-recipient` (:451) and before `below-minimum` (:453).
        _setMinRedeem(SH_1M + 1);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/zero-recipient");
        vault.requestRedeem(SH_1M, address(0));
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestRedeem(SH_1M, bob);

        assertEq(vault.balanceOf(alice), SH_1M);
        assertEq(_redeemQueueLength(),   0);
    }

    // The owner is not consulted: a blacklisted holder can still exit to a clean recipient.
    function test_requestRedeem_blacklistedOwner_success() public {
        _deposit(alice, ONE_M);
        _blacklist(alice);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestRedeem(SH_1M, alice);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(SH_1M, bob);
        ( address owner, address recipient, uint256 shares ) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    SH_1M);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),   R_1M);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.claimableAssets(alice), 0);
    }

    function test_requestRedeem_unblacklistedRecipient_success() public {
        _deposit(alice, ONE_M);
        _blacklist(bob);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestRedeem(SH_1M, bob);

        _unblacklist(bob);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(SH_1M, bob);
        assertEq(id, 0);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), R_1M);
        assertEq(_vaultUsdc(), 0);
    }

    // The vault and spUSDC are not blacklisted, so both are accepted as recipients (V2-13).
    function test_requestRedeem_vaultAndSavingsRecipients_accepted() public {
        _deposit(alice, ONE_M);
        vm.prank(alice);
        assertEq(vault.requestRedeem(SH_100K, address(vault)),  0);
        vm.prank(alice);
        assertEq(vault.requestRedeem(SH_100K, address(spUsdc)), 1);
    }

}

/**************************************************************************************************/
/*** requestDepositCancellation                                                                 ***/
/**************************************************************************************************/

contract RequestDepositCancellationBlacklistTests is BlacklistBase {

    function test_requestDepositCancellation_blacklistedRecipient_failure() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _blacklist(bob);

        // Checked before the entry is loaded (:425), so even a bad id reports it.
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestDepositCancellation(id, bob);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestDepositCancellation(99, bob);

        ( ,, uint256 shares ) = _depositRequest(id);
        assertEq(shares, S_1M);
        assertEq(vault.pendingDepositSavingsShares(), S_1M);
    }

    function test_requestDepositCancellation_blacklistedOwner_success() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        _blacklist(alice);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestDepositCancellation(id, alice);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 0, bob);
        uint256 cid = vault.requestDepositCancellation(id, bob);

        ( address owner, address recipient, uint256 shares ) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), A_1M);
    }

}

/**************************************************************************************************/
/*** updateDepositCancellationRecipient                                                         ***/
/**************************************************************************************************/

contract UpdateDepositCancellationRecipientBlacklistTests is BlacklistBase {

    function test_updateDepositCancellationRecipient_blacklistedRecipient_failure() public {
        uint256 cid = _queuedCancellation(alice);
        _blacklist(bob);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.updateDepositCancellationRecipient(cid, bob);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");  // before the entry load
        vault.updateDepositCancellationRecipient(99, bob);

        ( , address recipient, ) = _cancelledDepositRequest(cid);
        assertEq(recipient, alice);
    }

    function test_updateDepositCancellationRecipient_blacklistedOwner_success() public {
        uint256 cid = _queuedCancellation(bob);
        _blacklist(alice);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.updateDepositCancellationRecipient(cid, alice);

        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cid, carol);
        ( , address recipient, ) = _cancelledDepositRequest(cid);
        assertEq(recipient, carol);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(carol), A_1M);
        assertEq(usdc.balanceOf(bob),   0);
    }

}

/**************************************************************************************************/
/*** updateRedeemRecipient                                                                      ***/
/**************************************************************************************************/

contract UpdateRedeemRecipientBlacklistTests is BlacklistBase {

    function test_updateRedeemRecipient_blacklistedRecipient_failure() public {
        uint256 id = _queuedRedeem(alice);
        _blacklist(bob);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.updateRedeemRecipient(id, bob);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.updateRedeemRecipient(99, bob);

        ( , address recipient, ) = _redeemRequest(id);
        assertEq(recipient, alice);
    }

    function test_updateRedeemRecipient_blacklistedOwner_success() public {
        uint256 id = _queuedRedeem(bob);
        _blacklist(alice);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.updateRedeemRecipient(id, alice);

        vm.prank(alice);
        vault.updateRedeemRecipient(id, carol);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(carol), R_1M);
        assertEq(usdc.balanceOf(bob),   0);
    }

    // Re-pointing to the vault itself is accepted (not blacklisted): see V2-13 below.
    function test_updateRedeemRecipient_vaultRecipient_accepted() public {
        uint256 id = _queuedRedeem(alice);
        vm.prank(alice);
        vault.updateRedeemRecipient(id, address(vault));
        ( , address recipient, ) = _redeemRequest(id);
        assertEq(recipient, address(vault));
    }

}

/**************************************************************************************************/
/*** requestDeposit / updateDepositRecipient: blacklist NOT consulted                           ***/
/**************************************************************************************************/

contract RequestDepositBlacklistTests is BlacklistBase {

    // USDC's own `transferFrom` (:400) rejects a blacklisted depositor; the vault adds nothing.
    function test_requestDeposit_blacklistedSender_failure() public {
        _fund(alice, ONE_M);
        _blacklist(alice);

        vm.prank(alice);
        vm.expectRevert(BLACKLISTED);
        vault.requestDeposit(ONE_M, bob, 0);

        assertEq(usdc.balanceOf(alice), ONE_M);
        assertEq(_depositQueueLength(), 0);
    }

    // `requestDeposit` (:389-396) only rejects zero and the vault: a blacklisted recipient is
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

        // But bob cannot redeem to himself; he can to a clean address.
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestRedeem(SH_100K, bob);
        vm.prank(bob);
        vault.requestRedeem(SH_100K, carol);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(carol), R_100K);
    }

    // The queued path and `updateDepositRecipient` (:479-489) do not consult it either.
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
    }

}

/**************************************************************************************************/
/*** processPendingRedeems: `_withdrawSavings` fallback                                         ***/
/**************************************************************************************************/

contract ProcessPendingRedeemsBlacklistTests is BlacklistBase {

    // Recipient blacklisted between request and payout: spUSDC is withdrawn to the vault, the
    // exact assets are credited, `Redeem` carries the same amounts as the clean path.
    function test_processPendingRedeems_blacklistedRecipient_fallsBackToClaimable() public {
        uint256 id = _queuedRedeem(alice);
        _blacklist(alice);

        assertEq(vault.balanceOf(address(vault)), SH_1M);
        assertEq(_vaultSpUsdc(), S_1M);
        assertEq(_vaultUsdc(),   0);

        vm.expectEmit(address(vault));
        emit ClaimableAssetsIncreased(alice, R_1M);
        vm.expectEmit(address(vault));
        emit Redeem(alice, alice, SH_1M, RS_1M, R_1M);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(alice), R_1M);
        assertEq(_vaultUsdc(),                 R_1M);
        assertEq(usdc.balanceOf(alice),        0);
        assertEq(_vaultSpUsdc(),               0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(),          0);
        assertEq(vault.pendingRedeemShares(),  0);
        assertEq(vault.firstPendingRedeemId(), 1);
        ( ,, uint256 left ) = _redeemRequest(id);
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
        assertEq(usdc.balanceOf(alice),        0);
        assertEq(usdc.balanceOf(bob),          R_1M);
        assertEq(_vaultUsdc(),                 R_1M);
        assertEq(_vaultSpUsdc(),               0);
        ( ,, uint256 leftA ) = _redeemRequest(idA);
        ( ,, uint256 leftB ) = _redeemRequest(idB);
        assertEq(leftA, 0);
        assertEq(leftB, 0);

        _unblacklist(alice);
        vault.claim(alice);
        assertEq(usdc.balanceOf(alice), R_1M);
        assertEq(_vaultUsdc(), 0);
    }

    // Blacklisted entries behind a liquidity-limited head do not change the bound: the walk is
    // still `convertToShares(maxWithdraw)` once at the top (:903).
    function test_processPendingRedeems_partialFillsAccrueClaimableTwice() public {
        _queuedRedeem(alice);
        _blacklist(alice);
        _drainSpUsdcLiquidity(700_000e6);  // 300k USDC left in spUSDC

        vm.expectEmit(address(vault));
        emit ClaimableAssetsIncreased(alice, PR_ASSETS_1);
        vm.expectEmit(address(vault));
        emit Redeem(alice, alice, PR_SHARES_1, PR_SAVINGS_1, PR_ASSETS_1);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(alice), PR_ASSETS_1);
        assertEq(_vaultUsdc(),                 PR_ASSETS_1);
        assertEq(vault.firstPendingRedeemId(), 0);  // partial fill stays at the head
        ( ,, uint256 left ) = _redeemRequest(0);
        assertEq(left, PR_SHARES_2);

        _returnSpUsdcLiquidity(700_000e6);
        vm.expectEmit(address(vault));
        emit ClaimableAssetsIncreased(alice, PR_ASSETS_2);
        vm.expectEmit(address(vault));
        emit Redeem(alice, alice, PR_SHARES_2, PR_SAVINGS_2, PR_ASSETS_2);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(alice), PR_ASSETS_1 + PR_ASSETS_2);
        assertEq(vault.claimableAssets(alice), 999_999_999_997);  // 1 wei less than one fill
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
        assertEq(_vaultUsdc(),                 PR_ASSETS_2);

        _unblacklist(alice);
        vault.claim(alice);
        assertEq(usdc.balanceOf(alice), PR_ASSETS_1 + PR_ASSETS_2);
    }

    // Two entries to the same blacklisted recipient sum into one claimable balance.
    function test_processPendingRedeems_multipleEntriesSum() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_100K);
        vm.prank(alice);
        vault.requestRedeem(SH_100K, bob);
        _requestRedeem(alice, SH_100K);
        _blacklist(alice);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(alice), 2 * R_100K);
        assertEq(vault.claimableAssets(alice), 199_999_999_996);
        assertEq(usdc.balanceOf(bob),          R_100K);
        assertEq(_vaultUsdc(),                 199_999_999_996);
        assertEq(vault.firstPendingRedeemId(), 3);
    }

    // Recipient blacklisted at request time but clean at payout: plain path, nothing claimable.
    function test_processPendingRedeems_unblacklistedBeforePayout_paysDirectly() public {
        uint256 id = _queuedRedeem(alice);
        _blacklist(alice);
        _unblacklist(alice);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),        R_1M);
        assertEq(vault.claimableAssets(alice), 0);
        assertEq(_vaultUsdc(),                 0);
        ( ,, uint256 left ) = _redeemRequest(id);
        assertEq(left, 0);
    }

}

/**************************************************************************************************/
/*** processPendingDepositCancellations: `_redeemSavings` fallback                              ***/
/**************************************************************************************************/

contract ProcessPendingDepositCancellationsBlacklistTests is BlacklistBase {

    function test_processPendingDepositCancellations_blacklistedRecipient_fallsBackToClaimable() public {
        uint256 cid = _queuedCancellation(alice);
        _blacklist(alice);
        assertEq(_vaultSpUsdc(), S_1M);

        vm.expectEmit(address(vault));
        emit ClaimableAssetsIncreased(alice, A_1M);
        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, S_1M, A_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(alice), A_1M);
        assertEq(_vaultUsdc(),                 A_1M);
        assertEq(usdc.balanceOf(alice),        0);
        assertEq(_vaultSpUsdc(),               0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),    1);
        ( ,, uint256 left ) = _cancelledDepositRequest(cid);
        assertEq(left, 0);
    }

    // R4-B fixed: the cancellation queue continues past a blacklisted recipient.
    function test_fixed_R4B_processPendingDepositCancellations_queueContinues() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, ONE_M);
        uint256 idB = _deposit(bob,   HUNDRED_K);
        vm.prank(alice);
        vault.requestDepositCancellation(idA, alice);
        vm.prank(bob);
        vault.requestDepositCancellation(idB, bob);
        _blacklist(alice);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(vault.claimableAssets(alice), A_1M);
        assertEq(usdc.balanceOf(alice),        0);
        assertEq(usdc.balanceOf(bob),          A_100K);
        assertEq(_vaultUsdc(),                 A_1M);
        assertEq(_vaultSpUsdc(),               0);

        _unblacklist(alice);
        vault.claim(alice);
        assertEq(usdc.balanceOf(alice), A_1M);
        assertEq(_vaultUsdc(), 0);
    }

    function test_processPendingDepositCancellations_partialFillsAccrueTwice() public {
        _queuedCancellation(alice);
        _blacklist(alice);
        _drainSpUsdcLiquidity(700_000e6);  // maxRedeem bounds the walk (:870)

        vm.expectEmit(address(vault));
        emit ClaimableAssetsIncreased(alice, PC_ASSETS_1);
        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, PC_SAVINGS_1, PC_ASSETS_1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(alice), PC_ASSETS_1);
        assertEq(vault.firstPendingDepositCancellationId(), 0);

        _returnSpUsdcLiquidity(700_000e6);
        vm.expectEmit(address(vault));
        emit ClaimableAssetsIncreased(alice, PC_ASSETS_2);
        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, PC_SAVINGS_2, PC_ASSETS_2);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssets(alice), PC_ASSETS_1 + PC_ASSETS_2);
        assertEq(vault.claimableAssets(alice), 999_999_999_998);  // 1 wei below A_1M
        assertEq(_vaultUsdc(),                 999_999_999_998);
        assertEq(_vaultSpUsdc(),               0);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
    }

}

/**************************************************************************************************/
/*** claim                                                                                      ***/
/**************************************************************************************************/

contract ClaimTests is BlacklistBase {

    function test_claim_nothingToClaim_failure() public {
        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(alice);
        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(address(0));

        // A clean payout never leaves anything to claim.
        _queuedRedeem(alice);
        _processRedeems(type(uint256).max, type(uint256).max);
        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(alice);
    }

    // USDC reverts while the recipient is still blacklisted; the vault's write happened inside
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
        emit Claim(alice, R_1M);
        uint256 paid = vault.claim(alice);

        assertEq(paid,                         R_1M);
        assertEq(vault.claimableAssets(alice), 0);
        assertEq(usdc.balanceOf(alice),        R_1M);
        assertEq(usdc.balanceOf(mallory),      0);
        assertEq(_vaultUsdc(),                 0);

        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
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
    }

    // Accruals from both queues add into the same balance and pay out in one claim.
    function test_claim_sumsRedeemAndCancellationAccruals() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_100K);
        _setCapacity(vault.totalSupply());
        uint256 id = _deposit(alice, HUNDRED_K);  // queued
        vm.prank(alice);
        vault.requestDepositCancellation(id, alice);
        _blacklist(alice);

        _processRedeems(type(uint256).max, type(uint256).max);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(alice), R_100K + A_100K);
        assertEq(vault.claimableAssets(alice), 199_999_999_997);
        assertEq(_vaultUsdc(),                 199_999_999_997);

        _unblacklist(alice);
        assertEq(vault.claim(alice), 199_999_999_997);
        assertEq(usdc.balanceOf(alice), 199_999_999_997);
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
        assertEq(_vaultUsdc(),                 R_1M);
    }

    // Not counted anywhere: `totalAssets` is notional (:815) and `availableLiquidAssets` is
    // spUSDC's `maxWithdraw` (:789).
    function test_claimable_notCountedByViews() public {
        _setUpClaimable();
        assertEq(vault.totalAssets(),           0);
        assertEq(vault.totalSupply(),           0);
        assertEq(vault.availableLiquidAssets(), 0);
        assertEq(_vaultSpUsdc(),                0);

        _deposit(bob, ONE_M);
        assertEq(vault.totalAssets(),           R_1M);
        assertEq(vault.availableLiquidAssets(), A_1M);  // spUSDC side only
        assertEq(_vaultUsdc(),                  R_1M);  // unchanged
    }

    // `requestDeposit` (:400-402) pulls exactly `assets_` and deposits exactly `assets_`; `take`
    // (:346) moves spUSDC only; the three walks only touch spUSDC; `adjustTotalAssets` only
    // touches chi. The vault's USDC balance equals the outstanding claimable through all of it.
    function test_claimable_untouchedByEveryOtherFunction() public {
        _setUpClaimable();

        _deposit(bob, ONE_M);                                  // instant fill
        assertEq(_vaultUsdc(), R_1M);
        _setCapacity(vault.totalSupply());
        uint256 id = _deposit(carol, HUNDRED_K);               // queued
        assertEq(_vaultUsdc(), R_1M);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(_vaultUsdc(), R_1M);

        _setCapacity(0);
        id = _deposit(carol, HUNDRED_K);
        vm.prank(carol);
        vault.requestDepositCancellation(id, carol);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(_vaultUsdc(), R_1M);
        assertEq(usdc.balanceOf(carol), A_100K);

        _requestRedeem(bob, SH_100K);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(_vaultUsdc(), R_1M);

        _takeAll();                                            // every spUSDC share leaves
        assertEq(_vaultSpUsdc(), 0);
        assertEq(_vaultUsdc(),   R_1M);

        _pause();
        _adjust(-int256(HUNDRED_K));
        _adjust(int256(HUNDRED_K));
        _unpause();
        assertEq(_vaultUsdc(), R_1M);
        assertEq(vault.claimableAssets(alice), R_1M);

        vm.prank(vsrSetter);
        vault.setVSR(ONE_PCT_VSR);
        _warpAndDrip(30 days);
        assertEq(_vaultUsdc(), R_1M);

        _unblacklist(alice);
        assertEq(vault.claim(alice), R_1M);
        assertEq(_vaultUsdc(), 0);
    }

    function _adjust(int256 delta) internal {
        vm.prank(admin);
        vault.adjustTotalAssets(delta);
    }

    // The vault's USDC never falls below the sum of claimables: nothing but `claim` sends USDC.
    function testFuzz_claimable_vaultUsdcCoversClaimables(uint256 take, uint256 deposit) public {
        _setUpClaimable();
        deposit = bound(deposit, 0, 10_000_000e6);
        _deposit(bob, deposit);
        take = bound(take, 0, _vaultSpUsdc());
        _take(take);
        assertGe(_vaultUsdc(), vault.claimableAssets(alice));
        assertEq(_vaultUsdc(), R_1M);
    }

}

/**************************************************************************************************/
/*** V2-13: the vault and spUSDC as recipients                                                  ***/
/**************************************************************************************************/

contract VaultAsRecipientTests is BlacklistBase {

    // `_canReceiveAsset(vault)` is true, so the withdraw goes to the vault with NO claimable
    // entry: the USDC is stranded (no function moves it; `claim(vault)` has nothing to claim).
    function test_BUG_V2_13_vaultAsRedeemRecipient_strandsUsdc() public {
        uint256 id = _queuedRedeem(address(vault));

        vm.expectEmit(address(vault));
        emit Redeem(alice, address(vault), SH_1M, RS_1M, R_1M);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(_vaultUsdc(),                          R_1M);
        assertEq(vault.claimableAssets(address(vault)), 0);
        assertEq(vault.claimableAssets(alice),          0);
        assertEq(usdc.balanceOf(alice),                 0);
        assertEq(vault.totalSupply(),                   0);
        assertEq(vault.totalAssets(),                   0);
        ( ,, uint256 left ) = _redeemRequest(id);
        assertEq(left, 0);

        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(address(vault));
        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(alice);

        // A later deposit and take cannot pull it out either.
        _deposit(bob, ONE_M);
        _takeAll();
        assertEq(_vaultUsdc(), R_1M);
    }

    function test_BUG_V2_13_vaultAsCancellationRecipient_strandsUsdc() public {
        _queuedCancellation(address(vault));

        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, address(vault), S_1M, A_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(_vaultUsdc(),                          A_1M);
        assertEq(vault.claimableAssets(address(vault)), 0);
        assertEq(vault.claimableAssets(alice),          0);
        assertEq(_vaultSpUsdc(),                        0);
        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(address(vault));
    }

    // spUSDC as recipient: spUSDC burns the vault's shares and transfers the USDC to itself, so
    // the value is donated to the remaining spUSDC holders (its index does not move).
    function test_BUG_V2_13_savingsAsRedeemRecipient_donatesToSpUsdc() public {
        _deposit(bob, ONE_M);  // another spUSDC holder through the vault's position is not enough:
        _queuedRedeem(address(spUsdc));
        uint256 spUsdcUsdcBefore = usdc.balanceOf(address(spUsdc));
        uint256 spUsdcSupply     = spUsdc.totalSupply();
        assertEq(spUsdcUsdcBefore, 2 * ONE_M);
        assertEq(spUsdcSupply,     2 * S_1M);

        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(address(spUsdc)), spUsdcUsdcBefore);     // nothing left spUSDC
        assertEq(spUsdc.totalSupply(),            spUsdcSupply - S_1M);  // but S_1M was burned
        assertEq(spUsdc.nowChi(),                 CHI_S);                // index unchanged
        assertEq(_vaultSpUsdc(),                  S_1M);                 // bob's backing only
        assertEq(vault.claimableAssets(address(spUsdc)), 0);
        assertEq(usdc.balanceOf(alice),           0);
        assertEq(_vaultUsdc(),                    0);
        // spUSDC now holds 2M USDC against ~1M of liabilities: 1M of unaccounted surplus.
        assertEq(usdc.balanceOf(address(spUsdc)) - spUsdc.totalAssets(), 1_000_000_000_001);
    }

}

/**************************************************************************************************/
/*** A blacklisted vault / spUSDC                                                               ***/
/**************************************************************************************************/

contract BlacklistedVaultTests is BlacklistBase {

    // If USDC blacklists the vault itself, clean redeems still pay (spUSDC pushes USDC straight
    // to the recipient) but the fallback path (withdraw to the vault) reverts inside USDC, so a
    // blacklisted recipient at the head blocks the walk again (R4-A shape, double-blacklist only).
    function test_blacklistedVault_cleanRedeemsPay_fallbackEntryBlocksWalk() public {
        _deposit(alice, ONE_M);
        _deposit(bob,   ONE_M);
        _requestRedeem(alice, SH_1M);
        _requestRedeem(bob,   SH_1M);
        _blacklist(bob);
        _fund(carol, ONE_M);  // approve before the vault is blacklisted (USDC rejects it after)
        _blacklist(address(vault));

        // Deposits die at the USDC pull (:400).
        vm.prank(carol);
        vm.expectRevert(BLACKLISTED);
        vault.requestDeposit(ONE_M, carol, 0);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), R_1M);
        assertEq(vault.firstPendingRedeemId(), 1);

        vm.prank(rebalancer);
        vm.expectRevert(BLACKLISTED);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingRedeemId(), 1);

        // Cancellations to a clean recipient also still pay; `claim` is dead while it lasts.
        _unblacklist(address(vault));
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(bob), R_1M);
        _blacklist(address(vault));
        _unblacklist(bob);
        vm.expectRevert(BLACKLISTED);
        vault.claim(bob);
        _unblacklist(address(vault));
        assertEq(vault.claim(bob), R_1M);
    }

}
