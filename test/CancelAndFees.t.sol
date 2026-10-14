// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../lib/forge-std/src/StdError.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

// Cancel permissions, cancel ordering, the cancelled-deposit queue, fee math and fee economics
// for spPRIME on `refactor/more-simplifying`.
//
// Harness indexes at setUp (see LocalTestBase): chi_s = 1.047633055711877768967605062e27,
// chi_p = 1.009687768242461209408770821e27. All hard-coded numbers below derive from them.
//
//   100e6 USDC deposit        -> 95_453_269 spUSDC shares (worth 99_999_999 USDC)
//                             -> 99_040_517 spPRIME shares when filled
//   1_000_000e6 USDC deposit  -> 954_532_691_143 spUSDC shares (worth 999_999_999_999 USDC)
//                             -> 990_405_184_109 spPRIME shares when filled
contract CancelAndFeesTest is LocalTestBase {

    event DepositCancellationRequest(uint256 indexed depositRequestId, uint256 cancelRequestId);
    event DepositCancellation(
        address indexed owner, address indexed recipient, uint256 savingsShares, uint256 assets
    );
    event CancelRedeemRequest(uint256 indexed requestId, uint256 shares);
    event DepositCancellationRecipientUpdated(uint256 indexed requestId, address indexed recipient);
    event GainRealized(uint192 chi, uint256 gain);

    uint256 constant CHI_S = 1.047633055711877768967605062e27;
    uint256 constant CHI_P = 1.009687768242461209408770821e27;

    uint256 constant SS_100   = 95_453_269;        // spUSDC shares for 100e6
    uint256 constant SH_100   = 99_040_517;        // spPRIME shares for 100e6
    uint256 constant SS_1M    = 954_532_691_143;   // spUSDC shares for 1_000_000e6
    uint256 constant SH_1M    = 990_405_184_109;   // spPRIME shares for 1_000_000e6

    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address carol    = makeAddr("carol");
    address stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        assertEq(spUsdc.nowChi(), CHI_S);
        assertEq(vault.nowChi(),  CHI_P);
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    // Queues a deposit with zero capacity so nothing fills instantly.
    function _queueDeposit(address who, uint256 amt) internal returns (uint256 id) {
        _setCapacity(0);
        id = _deposit(who, amt);
        _setCapacity(type(uint128).max);
    }

    // Cancel only: the entry moves to the cancelled queue, nothing is paid yet.
    function _cancelDeposit(address who, uint256 id, address to) internal returns (uint256 cid) {
        vm.prank(who);
        cid = vault.requestDepositCancellation(id, to);
    }

    function _settleCancelled() internal {
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
    }

    function _cancelRedeem(address who, uint256 id, address to) internal {
        vm.prank(who);
        vault.cancelRedeemRequest(id, to);
    }

    function _ceil(uint256 x, uint256 y) internal pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / y + 1;
    }

    // Foundry runs a test as one transaction, so every slot touched by setup is warm. Cool the
    // contracts so gas measurements reflect a fresh transaction.
    function _cool() internal {
        vm.cool(address(vault));
        vm.cool(address(spUsdc));
        vm.cool(address(usdc));
    }

    /**********************************************************************************************/
    /*** 1. Cancel permissions: deposits                                                        ***/
    /**********************************************************************************************/

    function test_requestDepositCancellation_ownerCanChooseRecipient() public {
        uint256 id = _queueDeposit(alice, 100e6);

        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    SS_100);

        assertEq(usdc.balanceOf(alice),               0);
        assertEq(usdc.balanceOf(bob),                 0);
        assertEq(_vaultSpUsdc(),                      SS_100);
        assertEq(vault.pendingDepositSavingsShares(), SS_100);

        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 0);
        uint256 cid = _cancelDeposit(alice, id, bob);
        assertEq(cid, 0);

        // Deposit entry cleared, cancelled entry created with the caller-chosen recipient.
        (owner, recipient, shares) = _depositRequest(id);
        assertEq(owner,     address(0));
        assertEq(recipient, address(0));
        assertEq(shares,    0);

        (owner, recipient, shares) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    SS_100);

        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100);
        assertEq(vault.firstPendingDepositCancellationId(),                 0);
        assertEq(_vaultSpUsdc(),                               SS_100);  // nothing paid yet
        assertEq(usdc.balanceOf(bob),                          0);

        // Settlement by the rebalancer pays the chosen recipient.
        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, bob, SS_100, 99_999_999);
        _settleCancelled();

        (owner, recipient, shares) = _cancelledDepositRequest(cid);
        assertEq(owner,     address(0));
        assertEq(recipient, address(0));
        assertEq(shares,    0);

        assertEq(usdc.balanceOf(alice),                        0);
        assertEq(usdc.balanceOf(bob),                          99_999_999);  // 1 wei to spUSDC rounding
        assertEq(_vaultSpUsdc(),                               0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),                 1);
    }

    function test_requestDepositCancellation_revertsNotAuthorized() public {
        uint256 id = _queueDeposit(alice, 100e6);

        vm.prank(stranger);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(id, stranger);

        // The recipient of the fill is not the owner either.
        _setCapacity(0);
        _fund(alice, 100e6);
        vm.prank(alice);
        uint256 id2 = vault.requestDeposit(100e6, bob);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(id2, bob);
    }

    // F-1 is NOT patched upstream: a guardian cancel records `recipient_` as the refund recipient
    // of the cancelled entry, so the settlement pays the guardian, not the depositor.
    function test_BUG_requestDepositCancellation_guardianCanRedirectRefund() public {
        uint256 id = _queueDeposit(alice, 1_000_000e6);

        uint256 cid = _cancelDeposit(guardian, id, guardian);

        (address owner, address recipient, uint256 shares) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, guardian);
        assertEq(shares,    SS_1M);

        _settleCancelled();

        assertEq(usdc.balanceOf(guardian), 999_999_999_999);  // theft of the whole deposit
        assertEq(usdc.balanceOf(alice),    0);
        assertEq(_vaultSpUsdc(),           0);
    }

    // `updateDepositCancellationRecipient` is owner-only at ff828d2: the owner can repair a guardian
    // redirect in the window before the planner settles, and nobody else can flip it back. The
    // repair only exists for the deposit side; see the redeem-side BUG test.
    function test_requestDepositCancellation_guardianRedirectRepairedByOwnerBeforeSettlement() public {
        uint256 id  = _queueDeposit(alice, 100e6);
        uint256 cid = _cancelDeposit(guardian, id, guardian);

        (address owner, address recipient, uint256 shares) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, guardian);
        assertEq(shares,    SS_100);

        // Only the entry owner may repair it.
        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositCancellationRecipient(cid, guardian);

        vm.prank(stranger);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositCancellationRecipient(cid, stranger);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateDepositCancellationRecipient(cid, address(0));

        vm.expectEmit(address(vault));
        emit DepositCancellationRecipientUpdated(cid, alice);
        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cid, alice);

        (, recipient, ) = _cancelledDepositRequest(cid);
        assertEq(recipient, alice);

        // The guardian cannot redirect it again: cancel is spent (`no-request`) and the updater
        // is owner-only.
        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(id, guardian);

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositCancellationRecipient(cid, guardian);

        _settleCancelled();
        assertEq(usdc.balanceOf(alice),    99_999_999);
        assertEq(usdc.balanceOf(guardian), 0);

        // Settled entries are deleted: no further update possible.
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateDepositCancellationRecipient(cid, alice);
    }

    // The window closes at settlement: if the planner settles before the owner notices, the
    // guardian-chosen recipient is paid and there is nothing left to repair.
    function test_requestDepositCancellation_guardianRedirectNotRepairableAfterSettlement() public {
        uint256 id  = _queueDeposit(alice, 100e6);
        uint256 cid = _cancelDeposit(guardian, id, guardian);
        _settleCancelled();

        assertEq(usdc.balanceOf(guardian), 99_999_999);
        assertEq(usdc.balanceOf(alice),    0);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateDepositCancellationRecipient(cid, alice);
    }

    function test_requestDepositCancellation_revertsNoRequest_alreadyCancelled() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, alice);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(id, alice);

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(id, alice);
    }

    function test_requestDepositCancellation_revertsNoRequest_alreadyFilled() public {
        uint256 id = _deposit(alice, 100e6);  // instant fill
        assertEq(vault.balanceOf(alice), SH_100);

        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     address(0));  // filled entries are deleted
        assertEq(recipient, address(0));
        assertEq(shares,    0);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(id, alice);
    }

    function test_requestDepositCancellation_revertsOutOfRange() public {
        uint256 id = _queueDeposit(alice, 100e6);

        vm.prank(alice);
        vm.expectRevert(stdError.indexOOBError);
        vault.requestDepositCancellation(id + 1, alice);
    }

    function test_requestDepositCancellation_revertsZeroRecipient() public {
        uint256 id = _queueDeposit(alice, 100e6);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.requestDepositCancellation(id, address(0));

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.requestDepositCancellation(id, address(0));
    }

    // recipient_ == vault is not rejected: the refund lands as USDC inside the prime vault, where
    // nothing counts or moves it (F-6 / C-6).
    function test_requestDepositCancellation_recipientVaultStrandsUsdc() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, address(vault));
        _settleCancelled();

        assertEq(usdc.balanceOf(address(vault)), 99_999_999);
        assertEq(usdc.balanceOf(alice),          0);
        assertEq(_vaultSpUsdc(),                 0);
    }

    /**********************************************************************************************/
    /*** 1. Cancel permissions: redeems                                                         ***/
    /**********************************************************************************************/

    function test_cancelRedeemRequest_ownerCanChooseRecipient() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);

        (address owner, address recipient, uint256 shares) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    SH_100);

        assertEq(vault.balanceOf(alice),          0);
        assertEq(vault.balanceOf(bob),            0);
        assertEq(vault.balanceOf(address(vault)), SH_100);
        assertEq(vault.pendingRedeemShares(),     SH_100);

        vm.expectEmit(address(vault));
        emit CancelRedeemRequest(id, SH_100);
        _cancelRedeem(alice, id, bob);

        (owner, recipient, shares) = _redeemRequest(id);
        assertEq(owner,     address(0));
        assertEq(recipient, address(0));
        assertEq(shares,    0);

        assertEq(vault.balanceOf(alice),          0);
        assertEq(vault.balanceOf(bob),            SH_100);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.totalSupply(),             SH_100);
        assertEq(vault.firstPendingRedeemId(),              1);  // head entry: advanced past it
    }

    function test_cancelRedeemRequest_revertsNotAuthorized() public {
        _deposit(alice, 100e6);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(SH_100, bob);  // bob is the fill recipient, not the owner

        vm.prank(stranger);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelRedeemRequest(id, stranger);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelRedeemRequest(id, bob);
    }

    // F-1 is NOT patched upstream: a guardian cancel transfers the escrowed shares to `recipient_`
    // immediately. There is no repair path for the owner.
    function test_BUG_cancelRedeemRequest_guardianCanRedirectShares() public {
        _deposit(alice, 1_000_000e6);
        uint256 id = _requestRedeem(alice, SH_1M);

        _cancelRedeem(guardian, id, guardian);

        assertEq(vault.balanceOf(guardian),       SH_1M);  // theft of the whole position
        assertEq(vault.assetsOf(guardian),        999_999_999_998);
        assertEq(vault.balanceOf(alice),          0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRedeemShares(),     0);
    }

    function test_cancelRedeemRequest_revertsNoRequest_alreadyCancelled() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);
        _cancelRedeem(alice, id, alice);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(id, alice);

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(id, alice);
    }

    function test_cancelRedeemRequest_revertsNoRequest_alreadyFilled() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice), 99_999_998);  // 99_040_517 * chi_p / RAY
        (, , uint256 shares) = _redeemRequest(id);
        assertEq(shares, 0);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(id, alice);
    }

    function test_cancelRedeemRequest_revertsOutOfRange() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);

        vm.prank(alice);
        vm.expectRevert(stdError.indexOOBError);
        vault.cancelRedeemRequest(id + 1, alice);
    }

    // N-2 (round 1) is fixed for address(0): both cancels now reject it.
    function test_cancelRedeemRequest_revertsZeroRecipient() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.cancelRedeemRequest(id, address(0));

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.cancelRedeemRequest(id, address(0));
    }

    // Owner-chosen recipient == vault still strands the shares (see section 8).
    function test_cancelRedeemRequest_recipientVaultStrandsShares() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);

        _cancelRedeem(alice, id, address(vault));

        assertEq(vault.balanceOf(address(vault)), SH_100);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.balanceOf(alice),          0);
    }

    /**********************************************************************************************/
    /*** 2. Cancel ordering and partial fills                                                   ***/
    /**********************************************************************************************/

    function test_requestDepositCancellation_partialFillRefundsRemainder() public {
        uint256 id = _queueDeposit(alice, 100e6);
        assertEq(vault.pendingDepositSavingsShares(), SS_100);

        // Capacity worth 40e6: 40e6 * RAY / chi_p = 39_616_207 shares.
        _setCapacity(39_616_207);
        _processDeposits(type(uint256).max, 1);

        // Capacity -> 39_999_999 USDC -> 38_181_306 spUSDC shares -> 39_999_998 USDC -> 39_616_205 shares.
        assertEq(vault.balanceOf(alice), 39_616_205);
        assertEq(vault.totalSupply(),    39_616_205);
        assertEq(vault.firstPendingDepositId(),    id);  // partial: head stays

        (, , uint256 shares) = _depositRequest(id);
        assertEq(shares, SS_100 - 38_181_306);
        assertEq(shares, 57_271_963);
        assertEq(vault.pendingDepositSavingsShares(), 57_271_963);
        assertEq(_vaultSpUsdc(),                      SS_100);  // fills do not move spUSDC

        uint256 cid = _cancelDeposit(alice, id, alice);
        (, , uint256 cshares) = _cancelledDepositRequest(cid);
        assertEq(cshares, 57_271_963);  // only the unfilled remainder is refundable
        assertEq(vault.firstPendingDepositId(), 1);

        _settleCancelled();

        assertEq(usdc.balanceOf(alice),               60_000_001);  // 57_271_963 * chi_s / RAY
        assertEq(vault.balanceOf(alice),              39_616_205);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(),                      38_181_306);

        // Minted value (39_999_997) + refund == 99_999_998: 1 wei lost at deposit, 1 at the fill.
        assertEq(vault.assetsOf(alice), 39_999_997);
        assertEq(vault.assetsOf(alice) + usdc.balanceOf(alice), 99_999_998);
    }

    function test_cancelRedeemRequest_partialFillRefundsRemainder() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);

        // Leave exactly 40e6 USDC of liquidity inside spUSDC.
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 40e6);
        assertEq(vault.availableLiquidAssets(), 40e6);

        _processRedeems(type(uint256).max, 1);

        // convertToShares(40e6) = 39_616_207 shares -> 39_999_999 USDC paid.
        assertEq(usdc.balanceOf(alice),       39_999_999);
        assertEq(vault.totalSupply(),         SH_100 - 39_616_207);
        assertEq(vault.pendingRedeemShares(), 59_424_310);
        assertEq(vault.firstPendingRedeemId(),          id);

        (, , uint256 shares) = _redeemRequest(id);
        assertEq(shares, 59_424_310);

        _cancelRedeem(alice, id, alice);

        assertEq(vault.balanceOf(alice),          59_424_310);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.totalSupply(),             59_424_310);
        assertEq(vault.firstPendingRedeemId(),              1);
    }

    // Cancelling the head entry now advances the head past every dead entry that follows it.
    function test_requestDepositCancellation_headEntryAdvancesHead() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        uint256 idC = _deposit(carol, 100e6);
        assertEq(idA, 0);
        assertEq(idB, 1);
        assertEq(idC, 2);
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(vault.pendingDepositSavingsShares(), 3 * SS_100);

        // Cancelling a non-head entry leaves the head alone.
        _cancelDeposit(bob, idB, bob);
        assertEq(vault.firstPendingDepositId(), 0);

        // Cancelling the head walks over bob's dead slot to carol.
        _cancelDeposit(alice, idA, alice);
        assertEq(vault.firstPendingDepositId(), 2);
        assertEq(vault.pendingDepositSavingsShares(),          SS_100);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 2 * SS_100);

        // Cancelling the last live entry parks the head at the queue length.
        _cancelDeposit(carol, idC, carol);
        assertEq(vault.firstPendingDepositId(), 3);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(),    3);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob),   0);
        assertEq(vault.balanceOf(carol), 0);

        // The cancelled queue pays in cancel order: bob, alice, carol.
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),   99_999_999);
        assertEq(usdc.balanceOf(alice), 0);
        _processCancelledDeposits(type(uint256).max, 2);
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(usdc.balanceOf(carol), 99_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
        assertEq(_vaultSpUsdc(), 0);
    }

    function test_cancelRedeemRequest_headEntryAdvancesHead() public {
        _deposit(alice, 100e6);
        _deposit(bob,   100e6);
        _deposit(carol, 100e6);
        uint256 idA = _requestRedeem(alice, SH_100);
        uint256 idB = _requestRedeem(bob,   SH_100);
        uint256 idC = _requestRedeem(carol, SH_100);
        assertEq(idA, 0);
        assertEq(idB, 1);
        assertEq(idC, 2);

        _cancelRedeem(bob, idB, bob);
        assertEq(vault.firstPendingRedeemId(), 0);

        _cancelRedeem(alice, idA, alice);
        assertEq(vault.firstPendingRedeemId(), 2);
        assertEq(vault.pendingRedeemShares(), SH_100);

        _processRedeems(type(uint256).max, 1);

        assertEq(vault.firstPendingRedeemId(),      3);
        assertEq(usdc.balanceOf(alice),   0);
        assertEq(usdc.balanceOf(bob),     0);
        assertEq(usdc.balanceOf(carol),   99_999_998);
        assertEq(vault.balanceOf(alice),  SH_100);
        assertEq(vault.balanceOf(bob),    SH_100);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    function test_requestDepositCancellation_thenReRequestFillsInstantlyWhenQueueEmpty() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, alice);
        assertEq(vault.firstPendingDepositId(), 1);  // walked past its own dead slot
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        // Queue empty again: the re-request fills instantly.
        vm.prank(alice);
        uint256 id2 = vault.requestDeposit(99_999_999, alice);
        assertEq(id2, 1);
        assertEq(vault.firstPendingDepositId(), 2);
        assertEq(vault.balanceOf(alice), 99_040_516);  // 99_999_999 -> 95_453_268 spUSDC -> 99_999_998 -> shares
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    // An unsettled cancel does not block the instant path: the re-request fills even while the
    // refund is still waiting in the cancelled queue (the vault still holds that spUSDC).
    function test_requestDepositCancellation_reRequestFillsInstantlyBeforeSettlement() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, alice);
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100);

        uint256 id2 = _deposit(alice, 100e6);
        assertEq(id2, 1);
        assertEq(vault.balanceOf(alice), SH_100);
        assertEq(_vaultSpUsdc(), 2 * SS_100);

        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(_vaultSpUsdc(), SS_100);
    }

    function test_requestDepositCancellation_thenReRequestQueuesBehindOthers() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        _cancelDeposit(alice, idA, alice);
        assertEq(vault.firstPendingDepositId(), 1);  // walked to bob
        _settleCancelled();

        vm.prank(alice);
        uint256 id2 = vault.requestDeposit(99_999_999, alice);
        assertEq(id2, 2);
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(vault.pendingDepositSavingsShares(), SS_100 + 95_453_268);

        _setCapacity(type(uint128).max);

        // The dead head slot was skipped at cancel time, so a 1-request batch fills bob directly.
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(bob),   SH_100);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.firstPendingDepositId(),    2);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(alice), 99_040_516);
        assertEq(vault.firstPendingDepositId(),    3);
    }

    /**********************************************************************************************/
    /*** 3. Cancelled-deposit queue mechanics                                                   ***/
    /**********************************************************************************************/

    function test_processCancelledDepositQueue_maxRequestsHonoured() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        uint256 idC = _deposit(carol, 100e6);
        _cancelDeposit(alice, idA, alice);
        _cancelDeposit(bob,   idB, bob);
        _cancelDeposit(carol, idC, carol);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 3 * SS_100);

        _processCancelledDeposits(type(uint256).max, 0);
        assertEq(vault.firstPendingDepositCancellationId(), 0);
        assertEq(usdc.balanceOf(alice), 0);

        _processCancelledDeposits(type(uint256).max, 2);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(usdc.balanceOf(bob),   99_999_999);
        assertEq(usdc.balanceOf(carol), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100);

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
        assertEq(usdc.balanceOf(carol), 99_999_999);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);

        // Idle call on an empty queue is a no-op.
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
    }

    function test_processCancelledDepositQueue_maxSavingsSharesPartialFill() public {
        uint256 id  = _queueDeposit(alice, 100e6);
        uint256 cid = _cancelDeposit(alice, id, alice);

        // 40e6 worth = 38_181_306 spUSDC shares.
        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, 38_181_306, 39_999_998);
        _processCancelledDeposits(38_181_306, 10);

        assertEq(usdc.balanceOf(alice), 39_999_998);
        assertEq(vault.firstPendingDepositCancellationId(), 0);  // partial: head stays
        (address owner, address recipient, uint256 shares) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    57_271_963);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 57_271_963);
        assertEq(_vaultSpUsdc(), 57_271_963);

        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 39_999_998 + 60_000_001);
        assertEq(usdc.balanceOf(alice), 99_999_999);  // chunking costs nothing extra here
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        assertEq(_vaultSpUsdc(), 0);
    }

    function test_processCancelledDepositQueue_revertsNotRebalancer() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, alice);

        vm.prank(alice);
        vm.expectRevert();  // AccessControlUnauthorizedAccount
        vault.processCancelledDepositQueue(type(uint256).max, 1);

        vm.prank(guardian);
        vm.expectRevert();
        vault.processCancelledDepositQueue(type(uint256).max, 1);
    }

    // The cancelled queue is settled from the vault's whole spUSDC balance, which includes the
    // backing of deposits still queued: a settlement can spend other depositors' spUSDC.
    function test_processCancelledDepositQueue_spendsOtherQueuedDepositorsBacking() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        _take(SS_100);  // Arkis took 100e6 worth; 2 * 100e6 is still owed to the two queued depositors

        _cancelDeposit(alice, idA, alice);
        _settleCancelled();

        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(_vaultSpUsdc(),        0);
        assertEq(vault.pendingDepositSavingsShares(), SS_100);  // bob: owed, unbacked until return
    }

    /**********************************************************************************************/
    /*** 4. F-2: cancel after take() spent the queue backing                                   ***/
    /**********************************************************************************************/

    function test_requestDepositCancellation_afterTakeSettlesWhatIsThere_restWaits() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        assertEq(_vaultSpUsdc(), 2 * SS_100);

        // Taker pulls 100e6 worth: exactly one depositor's backing by amount, but spUSDC is fungible.
        _take(SS_100);
        assertEq(_vaultSpUsdc(),                      SS_100);
        assertEq(vault.pendingDepositSavingsShares(), 2 * SS_100);  // not reduced by take

        // Both cancel; neither cancel reverts now.
        _cancelDeposit(alice, idA, alice);
        _cancelDeposit(bob,   idB, bob);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 2 * SS_100);
        assertEq(vault.firstPendingDepositId(), 2);

        // Settlement pays alice in full and stops; bob's entry is untouched and no revert.
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(_vaultSpUsdc(),        0);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100);

        // With nothing in the vault the call is a no-op (budget 0), not a revert.
        _settleCancelled();
        assertEq(vault.firstPendingDepositCancellationId(), 1);

        // Returning exactly the shortfall completes bob.
        _returnToVault(SS_100);
        _settleCancelled();
        assertEq(usdc.balanceOf(bob), 99_999_999);
        assertEq(_vaultSpUsdc(),      0);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    function test_requestDepositCancellation_takeExceedsOneRequest_partialThenWait() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);

        // 150e6 worth = 143_179_903 spUSDC shares; 47_726_635 remain (< one request).
        _take(143_179_903);
        assertEq(_vaultSpUsdc(), 47_726_635);

        uint256 cidA = _cancelDeposit(alice, idA, alice);
        uint256 cidB = _cancelDeposit(bob,   idB, bob);

        // Alice is paid the 47_726_635 that is there (50_000_000 USDC) and stays at the head.
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 50_000_000);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(_vaultSpUsdc(),        0);
        assertEq(vault.firstPendingDepositCancellationId(), cidA);
        (, , uint256 leftA) = _cancelledDepositRequest(cidA);
        assertEq(leftA, 47_726_634);
        (, , uint256 leftB) = _cancelledDepositRequest(cidB);
        assertEq(leftB, SS_100);

        // Return alice's remainder: alice completes (49_999_999), bob still waits.
        _returnToVault(47_726_634);
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(vault.firstPendingDepositCancellationId(), cidB);

        _returnToVault(SS_100);
        _settleCancelled();
        assertEq(usdc.balanceOf(bob), 99_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // B-3 (round 2) is fixed: the budget is `spUSDC.maxRedeem(vault)`, so when spUSDC itself is
    // short of USDC the settlement pays what is liquid, FIFO, leaves the head on the partially
    // paid entry, is a no-op while nothing is liquid, and completes once liquidity returns.
    function test_processCancelledDepositQueue_clampsToSpUsdcLiquidity() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        uint256 cidA = _cancelDeposit(alice, idA, alice);
        uint256 cidB = _cancelDeposit(bob,   idB, bob);

        // Leave 40e6 USDC inside spUSDC; the vault still holds 2 * SS_100 spUSDC shares.
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 40e6);
        assertEq(spUsdc.maxRedeem(address(vault)),   38_181_307);  // 40e6 * RAY / chi_s, floor
        assertEq(spUsdc.maxWithdraw(address(vault)), 40e6);

        vm.expectEmit(address(vault));
        emit DepositCancellation(alice, alice, 38_181_307, 39_999_999);
        _processCancelledDeposits(type(uint256).max, 10);

        // Alice is paid the liquid 39_999_999, stays at the head with the remainder; bob untouched.
        assertEq(usdc.balanceOf(alice), 39_999_999);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(vault.firstPendingDepositCancellationId(), cidA);
        (, , uint256 leftA) = _cancelledDepositRequest(cidA);
        assertEq(leftA, SS_100 - 38_181_307);
        assertEq(leftA, 57_271_962);
        (, , uint256 leftB) = _cancelledDepositRequest(cidB);
        assertEq(leftB, SS_100);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 57_271_962 + SS_100);
        assertEq(usdc.balanceOf(address(spUsdc)),              1);  // 1 wei of dust left in spUSDC
        assertEq(spUsdc.maxRedeem(address(vault)),             0);

        // Nothing liquid: the call is a no-op, no revert.
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 39_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), cidA);

        // Liquidity returns: one call completes alice and bob in order.
        _returnSpUsdcLiquidity(200e6);
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);  // 39_999_999 + 60_000_000: chunking cost nothing
        assertEq(usdc.balanceOf(bob),   99_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(), 0);
    }

    // `maxRequests_` still binds under the liquidity clamp: with 1 request bob is never reached
    // even when liquidity would cover both.
    function test_processCancelledDepositQueue_liquidityClampRespectsMaxRequests() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        _cancelDeposit(alice, idA, alice);
        _cancelDeposit(bob,   idB, bob);
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 150e6);

        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(vault.firstPendingDepositCancellationId(), 1);

        // 50e6 + 1 wei left in spUSDC: bob gets a partial fill.
        assertEq(usdc.balanceOf(address(spUsdc)), 50_000_001);
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob), 50_000_000);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
    }

    function test_processDepositQueue_stillMintsAfterTakeSpentBacking() public {
        _setCapacity(0);
        _deposit(alice, 100e6);
        _deposit(bob,   100e6);

        _take(143_179_903);
        assertEq(_vaultSpUsdc(), 47_726_635);  // worth 50_000_000 USDC

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 2);

        // Both filled in full; fills never touch the spUSDC balance.
        assertEq(vault.balanceOf(alice), SH_100);
        assertEq(vault.balanceOf(bob),   SH_100);
        assertEq(vault.totalAssets(),    199_999_997);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 50_000_000);
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    /**********************************************************************************************/
    /*** 5. Fee math                                                                            ***/
    /**********************************************************************************************/

    function testFuzz_requestRedeem_feeIsCeil(uint256 shares, uint256 feeRate) public {
        shares  = bound(shares,  1, 1e30);
        feeRate = bound(feeRate, 0, 0.01e18);

        _setRedeemFeeRate(feeRate);

        // Mint at least `shares` to alice (rounding loses a few wei on the way in).
        _deposit(alice, vault.convertToAssets(shares) + 10);
        uint256 balance = vault.balanceOf(alice);
        assertGe(balance, shares);

        uint256 supplyBefore = vault.totalSupply();
        uint256 expectedFee  = _ceil(shares * feeRate, WAD);

        uint256 id = _requestRedeem(alice, shares);

        (address owner, address recipient, uint256 queued) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(queued,    shares - expectedFee);

        assertLe(expectedFee, shares);
        assertEq(expectedFee == 0, feeRate == 0);

        assertEq(vault.totalSupply(),             supplyBefore - expectedFee);
        assertEq(vault.balanceOf(alice),          balance - shares);
        assertEq(vault.balanceOf(address(vault)), queued);
        assertEq(vault.pendingRedeemShares(),     queued);
    }

    function test_requestRedeem_revertsBelowMinRedeem() public {
        _setMinRedeem(SH_100);
        _deposit(alice, 200e6);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(SH_100 - 1, alice);

        uint256 id = _requestRedeem(alice, SH_100);
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, SH_100);
    }

    function test_requestRedeem_feeRoundsUpToOneWei() public {
        _setRedeemFeeRate(1);  // 1e-18
        _deposit(alice, 100e6);

        uint256 id = _requestRedeem(alice, SH_100);
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, SH_100 - 1);
        assertEq(vault.totalSupply(), SH_100 - 1);
    }

    /**********************************************************************************************/
    /*** 6. Fee economics                                                                       ***/
    /**********************************************************************************************/

    function test_requestRedeem_feeLeavesChiUnchangedAndRaisesBackingPerShare() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);

        assertEq(vault.balanceOf(alice), SH_1M);
        assertEq(_vaultSpUsdc(),         SS_1M);
        assertEq(vault.totalAssets(),    999_999_999_998);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 999_999_999_999);

        uint256 chiBefore   = vault.nowChi();
        uint256 oneShareVal = vault.convertToAssets(1e6);

        uint256 id = _requestRedeem(alice, SH_1M);

        uint256 fee = 9_904_051_842;  // ceil(990_405_184_109 * 0.01)
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued,                      SH_1M - fee);
        assertEq(queued,                      980_501_132_267);
        assertEq(vault.totalSupply(),         980_501_132_267);
        assertEq(vault.nowChi(),              chiBefore);        // chi is index-based
        assertEq(vault.convertToAssets(1e6),  oneShareVal);      // per-share claim unchanged
        assertEq(_vaultSpUsdc(),              SS_1M);            // backing unchanged

        // Notional liability dropped by the fee's value; real backing did not.
        assertEq(vault.totalAssets(), 989_999_999_997);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()) - vault.totalAssets(), 10_000_000_002);

        // Fill: alice gets the net, the surplus spUSDC stays in the vault and is take-able.
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice),  989_999_999_997);
        assertEq(vault.totalSupply(),    0);
        assertEq(vault.totalAssets(),    0);
        assertEq(_vaultSpUsdc(),         9_545_326_913);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 10_000_000_001);

        _take(9_545_326_913);
        assertEq(_vaultSpUsdc(), 0);
        assertEq(spUsdc.balanceOf(taker), 9_545_326_913);
    }

    function test_requestRedeem_feeNotCreditedToRemainingHolders() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(bob,   100e6);
        _deposit(alice, 1_000_000e6);

        assertEq(vault.assetsOf(bob),  99_999_998);
        assertEq(vault.totalAssets(),  1_000_099_999_997);

        _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems(type(uint256).max, 1);

        // Bob's claim is unchanged; the fee's backing sits in vault equity, uncounted by chi.
        assertEq(vault.assetsOf(bob),  99_999_998);
        assertEq(vault.totalSupply(),  SH_100);
        assertEq(vault.totalAssets(),  99_999_998);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 10_100_000_001);  // bob's 100e6 + the 10_000e6 fee
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()) - vault.totalAssets(), 10_000_000_003);
    }

    // The fee surplus is also what settles cancelled deposits: with alice's fee still in the
    // vault, a cancelled deposit can be refunded even after Arkis took every queued share.
    function test_processCancelledDepositQueue_feeSurplusCoversRefund() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);
        _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, 1);
        assertEq(_vaultSpUsdc(), 9_545_326_913);  // 10_000_000_001 USDC of fee surplus
        assertEq(vault.totalSupply(), 0);

        uint256 id = _queueDeposit(bob, 100e6);
        _take(SS_100);  // takes bob's worth; the fee surplus remains
        _cancelDeposit(bob, id, bob);
        _settleCancelled();

        assertEq(usdc.balanceOf(bob), 99_999_999);
        assertEq(_vaultSpUsdc(), 9_545_326_913 - SS_100);
    }

    /**********************************************************************************************/
    /*** 7. Minimums: gross vs net                                                              ***/
    /**********************************************************************************************/

    // minRedeem is in shares and checked before the fee, so the net payout can land below the
    // value the minimum represents.
    function test_requestRedeem_minRedeemIsGrossOfFee() public {
        _setRedeemFeeRate(0.01e18);
        uint256 minShares = vault.convertToShares(100e6);
        assertEq(minShares, 99_040_518);
        _setMinRedeem(minShares);
        _deposit(alice, 1_000_000e6);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(minShares - 1, alice);

        uint256 id = _requestRedeem(alice, minShares);

        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, minShares - 990_406);
        assertEq(queued, 98_050_112);

        _processRedeems(type(uint256).max, 1);

        // Minimum is worth 99_999_999 USDC; the net payout is 98_999_998: 1_000_001 wei below.
        assertEq(vault.convertToAssets(minShares), 99_999_999);
        assertEq(usdc.balanceOf(alice),            98_999_998);
        assertEq(vault.convertToAssets(minShares) - usdc.balanceOf(alice), 1_000_001);
    }

    // minRedeem is a share count, so the USDC value it enforces drifts up with chi.
    function test_requestRedeem_minRedeemValueDriftsWithChi() public {
        _setMinRedeem(SH_100);
        assertEq(vault.convertToAssets(SH_100), 99_999_998);

        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);

        assertEq(vault.convertToAssets(SH_100), 104_999_998);

        _deposit(alice, 200e6);
        uint256 shares = vault.convertToShares(100e6);  // 100 USDC worth is now below the minimum
        assertLt(shares, SH_100);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(shares, alice);
    }

    function test_requestDeposit_minDepositBoundary() public {
        _setMinDeposit(100e6);
        _fund(alice, 200e6);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(100e6 - 1, alice);

        vm.prank(alice);
        vault.requestDeposit(100e6, alice);
        assertEq(vault.balanceOf(alice), SH_100);
    }

    /**********************************************************************************************/
    /*** 8. Ghost entries and gas                                                               ***/
    /**********************************************************************************************/

    function test_processDepositQueue_gasWith500GhostEntries() public {
        // Baseline: carol queued, alice behind her, no ghosts.
        _setCapacity(0);
        _deposit(carol, 10e6);
        _deposit(alice, 100e6);
        _setCapacity(type(uint128).max);

        _cool();
        vm.prank(rebalancer);
        uint256 gas = gasleft();
        vault.processDepositQueue(type(uint256).max, 502);
        uint256 baseline = gas - gasleft();

        assertEq(vault.balanceOf(carol), 9_904_050);
        assertEq(vault.balanceOf(alice), SH_100);
        assertEq(vault.firstPendingDepositId(),    2);

        // Ghosts: carol queued first (so the head cannot walk past them), then 500 zero-asset requests.
        _setCapacity(0);
        uint256 idC = _deposit(carol, 10e6);
        assertEq(idC, 2);

        for (uint256 i; i < 500; ++i) {
            vm.prank(stranger);
            uint256 id = vault.requestDeposit(0, stranger);
            assertEq(id, 3 + i);
        }
        assertEq(vault.pendingDepositSavingsShares(), 9_545_326);

        uint256 idA = _deposit(alice, 100e6);
        assertEq(idA, 503);
        _setCapacity(type(uint128).max);

        _cool();
        vm.prank(rebalancer);
        gas = gasleft();
        vault.processDepositQueue(type(uint256).max, 502);
        uint256 withGhosts = gas - gasleft();

        assertEq(vault.balanceOf(carol), 2 * 9_904_050);
        assertEq(vault.balanceOf(alice), 2 * SH_100);
        assertEq(vault.firstPendingDepositId(),    504);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        emit log_named_uint("processDepositQueue gas, 2 real requests",             baseline);
        emit log_named_uint("processDepositQueue gas, 2 real + 500 ghost requests", withGhosts);
        emit log_named_uint("gas per ghost entry",                                  (withGhosts - baseline) / 500);

        assertGt(withGhosts, baseline + 500 * 2_000);  // at least one cold SLOAD per ghost

        // A ghost cannot be cancelled.
        vm.prank(stranger);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(3, stranger);
    }

    // Ghosts at the head are walked by the next request, so they only cost when a live entry
    // sits in front of them.
    function test_requestDeposit_walksGhostsAtHead() public {
        _setCapacity(0);
        for (uint256 i; i < 10; ++i) {
            vm.prank(stranger);
            vault.requestDeposit(0, stranger);
        }
        assertEq(vault.firstPendingDepositId(), 9);  // each ghost request walked the head up to itself
        _setCapacity(type(uint128).max);

        uint256 id = _deposit(alice, 100e6);
        assertEq(id, 10);
        assertEq(vault.balanceOf(alice), SH_100);  // instant: head walked 9 -> 10 before the fill
        assertEq(vault.firstPendingDepositId(), 11);
    }

    function test_processRedeemQueue_gasWith500GhostEntries() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 100e6);
        _deposit(bob,   100e6);

        // Baseline: one real request.
        _requestRedeem(bob, SH_100);
        _cool();
        vm.prank(rebalancer);
        uint256 gas = gasleft();
        vault.processRedeemQueue(type(uint256).max, 501);
        uint256 baseline = gas - gasleft();
        assertEq(usdc.balanceOf(bob), 98_999_997);  // 98_050_111 net shares
        assertEq(vault.firstPendingRedeemId(),  1);

        // 500 one-wei redeems: fee = ceil(1 * 0.01) = 1, queued 0.
        for (uint256 i; i < 500; ++i) {
            uint256 id = _requestRedeem(alice, 1);
            (, , uint256 q) = _redeemRequest(id);
            assertEq(q, 0);
        }
        assertEq(vault.balanceOf(alice),      SH_100 - 500);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.totalSupply(),         SH_100 - 500);

        _deposit(bob, 100e6);
        _requestRedeem(bob, SH_100);

        _cool();
        vm.prank(rebalancer);
        gas = gasleft();
        vault.processRedeemQueue(type(uint256).max, 501);
        uint256 withGhosts = gas - gasleft();

        assertEq(usdc.balanceOf(bob), 2 * 98_999_997);
        assertEq(vault.firstPendingRedeemId(),  502);

        emit log_named_uint("processRedeemQueue gas, 1 real request",              baseline);
        emit log_named_uint("processRedeemQueue gas, 1 real + 500 ghost requests", withGhosts);
        emit log_named_uint("gas per ghost entry",                                 (withGhosts - baseline) / 500);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(1, alice);
    }

    /**********************************************************************************************/
    /*** 9. Donated shares                                                                      ***/
    /**********************************************************************************************/

    function test_transfer_toVaultStrandsSharesWithoutBreakingQueues() public {
        _deposit(alice, 100e6);
        _deposit(bob,   100e6);

        vm.prank(alice);
        vault.transfer(address(vault), 1_000_000);

        assertEq(vault.balanceOf(address(vault)), 1_000_000);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.totalSupply(),             2 * SH_100);

        // Bob's redeem request and fill behave exactly as without the donation.
        uint256 id = _requestRedeem(bob, SH_100);
        assertEq(vault.balanceOf(address(vault)), 1_000_000 + SH_100);
        assertEq(vault.pendingRedeemShares(),     SH_100);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),             99_999_998);
        assertEq(vault.balanceOf(address(vault)), 1_000_000);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.totalSupply(),             SH_100);  // alice's remainder + donation

        // Cancel paths only move request.shares, never the donation.
        uint256 id2 = _requestRedeem(alice, SH_100 - 1_000_000);
        _cancelRedeem(alice, id2, alice);
        assertEq(vault.balanceOf(alice),          SH_100 - 1_000_000);
        assertEq(vault.balanceOf(address(vault)), 1_000_000);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(id, alice);

        // Donation keeps consuming capacity: with capacity == totalSupply nothing can be deposited.
        _setCapacity(vault.totalSupply());
        assertEq(vault.availableCapacity(), 0);
        uint256 id3 = _deposit(carol, 100e6);
        (, , uint256 queued) = _depositRequest(id3);
        assertEq(queued, SS_100);  // stuck in queue behind 1_000_000 dead shares
    }

    function test_transferFrom_toVaultStrandsShares() public {
        _deposit(alice, 100e6);

        vm.prank(alice);
        vault.approve(bob, 1_000_000);

        vm.prank(bob);
        vault.transferFrom(alice, address(vault), 1_000_000);

        assertEq(vault.balanceOf(address(vault)), 1_000_000);
        assertEq(vault.balanceOf(alice),          SH_100 - 1_000_000);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.allowance(alice, bob),     0);
    }

    /**********************************************************************************************/
    /*** 10. Fee kept on guardian cancel (F-8)                                                  ***/
    /**********************************************************************************************/

    function test_cancelRedeemRequest_guardianCancelKeepsFee() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);

        uint256 id = _requestRedeem(alice, SH_1M);
        assertEq(vault.totalSupply(), SH_1M - 9_904_051_842);

        _cancelRedeem(guardian, id, alice);  // guardian must name the owner, see F-1 tests

        assertEq(vault.balanceOf(alice), SH_1M - 9_904_051_842);
        assertEq(vault.balanceOf(alice), 980_501_132_267);
        assertEq(vault.assetsOf(alice),  989_999_999_997);

        // Alice lost 9_904_051_842 shares = 10_000_000_001 USDC of claim for a cancelled request.
        assertEq(999_999_999_998 - vault.assetsOf(alice), 10_000_000_001);
    }

    /**********************************************************************************************/
    /*** 11. Fee locked at request                                                              ***/
    /**********************************************************************************************/

    function test_processRedeemQueue_feeChangeAfterRequestHasNoEffect() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);
        _deposit(bob,   1_000_000e6);

        uint256 idA = _requestRedeem(alice, SH_1M);
        (, , uint256 queuedA) = _redeemRequest(idA);
        assertEq(queuedA, 980_501_132_267);

        _setRedeemFeeRate(0);

        // Bob requests at 0% after the change.
        uint256 idB = _requestRedeem(bob, SH_1M);
        (, , uint256 queuedB) = _redeemRequest(idB);
        assertEq(queuedB, SH_1M);

        _processRedeems(type(uint256).max, 2);

        assertEq(usdc.balanceOf(alice), 989_999_999_997);  // 1% already burned
        assertEq(usdc.balanceOf(bob),   999_999_999_998);
    }

    /**********************************************************************************************/
    /*** 12. Fee setters                                                                        ***/
    /**********************************************************************************************/

    function test_setRedeemFee_revertsAboveMax() public {
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFeeRate(0.01e18 + 1);

        vm.prank(riskManager);
        vault.setRedeemFeeRate(0.01e18);
        assertEq(vault.redeemFeeRate(), 0.01e18);
    }

    function test_setMaxRedeemFee_revertsAboveOnePercent() public {
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setMaxRedeemFeeRate(0.01e18 + 1);

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.01e18);
        assertEq(vault.maxRedeemFeeRate(), 0.01e18);
    }

    function test_setMaxRedeemFee_belowCurrentFeeLeavesFeeInForce() public {
        _setRedeemFeeRate(0.01e18);

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.001e18);
        assertEq(vault.maxRedeemFeeRate(), 0.001e18);
        assertEq(vault.redeemFeeRate(),    0.01e18);  // unchanged, above the new max

        // New requests keep paying 1%.
        _deposit(alice, 1_000_000e6);
        uint256 id = _requestRedeem(alice, SH_1M);
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, SH_1M - 9_904_051_842);

        // Risk manager can no longer set anything above 0.1%, including the value in force.
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFeeRate(0.01e18);

        vm.prank(riskManager);
        vault.setRedeemFeeRate(0.001e18);
        assertEq(vault.redeemFeeRate(), 0.001e18);
    }

    /**********************************************************************************************/
    /*** 13. Pause                                                                              ***/
    /**********************************************************************************************/

    function test_requestDepositCancellation_revertsWhilePaused() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _pause();

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDepositCancellation(id, alice);

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDepositCancellation(id, alice);

        // take() is not gated by pause (F-7): backing can still leave during the freeze.
        _take(SS_100);
        assertEq(_vaultSpUsdc(), 0);
        _returnToVault(SS_100);

        _unpause();
        _cancelDeposit(alice, id, alice);
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);
    }

    // A refund already in the cancelled queue is also frozen by pause; take() is not.
    function test_processCancelledDepositQueue_revertsWhilePaused() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, alice);
        _pause();

        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processCancelledDepositQueue(type(uint256).max, 1);

        _take(SS_100);
        assertEq(_vaultSpUsdc(), 0);

        _unpause();
        _settleCancelled();  // no-op: budget 0
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.firstPendingDepositCancellationId(), 0);

        _returnToVault(SS_100);
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);
    }

    function test_cancelRedeemRequest_revertsWhilePaused() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);
        _pause();

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelRedeemRequest(id, alice);

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelRedeemRequest(id, alice);

        _unpause();
        _cancelRedeem(alice, id, alice);
        assertEq(vault.balanceOf(alice), SH_100);
    }

    // realizeLoss (paused only, 0 < loss < totalAssets) hits escrowed redeem shares; cancelled
    // deposits waiting for settlement are spUSDC and take no loss.
    function test_realizeLoss_escrowedRedeemTakesLoss_cancelledDepositDoesNot() public {
        _deposit(alice, 100e6);
        uint256 rid = _requestRedeem(alice, SH_100);

        uint256 did = _queueDeposit(bob, 100e6);
        _cancelDeposit(bob, did, bob);

        _pause();
        assertEq(vault.totalAssets(), 99_999_998);

        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(0);

        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(99_999_998);  // loss == totalAssets: rejected; 99_999_997 is the max

        _realizeLoss(50e6);  // chi halves: 50e6 of 99_999_998 notional
        _unpause();

        _cancelRedeem(alice, rid, alice);
        assertEq(vault.balanceOf(alice), SH_100);
        assertApproxEqAbs(vault.assetsOf(alice), 49_999_998, 1);  // 1 wei depends on the chi formula

        _settleCancelled();
        assertEq(usdc.balanceOf(bob), 99_999_999);
    }

    /**********************************************************************************************/
    /*** 14. realizeGain: distributing the fee surplus (new at ff828d2)                        ***/
    /**********************************************************************************************/

    // The burned redeem fee leaves spUSDC in the vault that chi does not count (I-2). With
    // `realizeGain(surplus)` the admin can credit that surplus to the remaining holders: chi is
    // re-anchored to `(totalAssets + gain) / totalSupply`, and `totalAssets` lands within 1 wei of
    // the real backing. The gain is a pure chi move, it does not touch spUSDC.
    function test_realizeGain_distributesFeeSurplusToRemainingHolders() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(bob,   100e6);
        _deposit(alice, 1_000_000e6);

        _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, 1);

        // Bob is the only holder; the 1% fee on alice's redeem sits in the vault uncounted.
        assertEq(vault.totalSupply(),  SH_100);
        assertEq(vault.assetsOf(bob),  99_999_998);
        assertEq(vault.totalAssets(),  99_999_998);
        uint256 backing = spUsdc.convertToAssets(_vaultSpUsdc());
        assertEq(backing, 10_100_000_001);
        uint256 surplus = backing - vault.totalAssets();
        assertEq(surplus, 10_000_000_003);

        uint256 spUsdcBefore = _vaultSpUsdc();
        uint192 expectedChi  = uint192((99_999_998 + surplus) * RAY / SH_100);
        assertEq(expectedChi, 101.978466055462937456192802386e27);

        vm.expectEmit(address(vault));
        emit GainRealized(expectedChi, surplus);
        vm.prank(admin);
        vault.realizeGain(surplus);

        assertEq(vault.nowChi(),      expectedChi);
        assertEq(vault.totalSupply(), SH_100);               // shares unchanged
        assertEq(vault.assetsOf(bob), 10_100_000_000);       // bob credited ~10_000 USDC
        assertEq(vault.totalAssets(), 10_100_000_000);
        assertEq(_vaultSpUsdc(),      spUsdcBefore);         // backing untouched
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()) - vault.totalAssets(), 1);  // 1 wei

        // Bob can actually redeem the credited amount: the backing is real.
        _setRedeemFeeRate(0);
        uint256 id = _requestRedeem(bob, SH_100);
        _processRedeems(type(uint256).max, 1);
        (, , uint256 left) = _redeemRequest(id);
        assertEq(left,                 0);
        assertEq(usdc.balanceOf(bob),  10_100_000_000);
        assertEq(vault.totalSupply(),  0);
        assertEq(_vaultSpUsdc(),       1);  // 1 spUSDC wei of dust
    }

    // `realizeGain(10_000_000_001)` (the surplus as measured in the alice-only scenario) under-
    // credits by 3 wei; the admin should measure `backing - totalAssets()` at call time.
    function test_realizeGain_roundNumberLeavesDust() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(bob,   100e6);
        _deposit(alice, 1_000_000e6);
        _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, 1);

        vm.prank(admin);
        vault.realizeGain(10_000_000_001);

        assertEq(vault.nowChi(),      101.978466035269181803645067805e27);
        assertEq(vault.assetsOf(bob), 10_099_999_998);
        assertEq(vault.totalAssets(), 10_099_999_998);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()) - vault.totalAssets(), 3);
    }

    // With nobody left holding shares the surplus cannot be distributed: `realizeGain` reverts
    // `no-shares` and the only way out for the 10_000_000_001 USDC of fee is `take()`.
    function test_realizeGain_revertsWithNoHolders() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);
        _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, 1);

        assertEq(vault.totalSupply(), 0);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 10_000_000_001);

        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/no-shares");
        vault.realizeGain(10_000_000_001);

        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/invalid-gain");
        vault.realizeGain(0);

        vm.prank(riskManager);
        vm.expectRevert();  // AccessControlUnauthorizedAccount: DEFAULT_ADMIN only
        vault.realizeGain(1);
    }

    // The mirror: `realizeGain` is not checked against backing. A gain with nothing behind it is
    // purely notional; the redeem queue then clamps to real liquidity and the excess claim waits
    // forever. Not pause-gated, unlike `realizeLoss`.
    function test_realizeGain_withoutBackingIsNotional() public {
        _deposit(alice, 100e6);
        assertEq(vault.totalAssets(), 99_999_998);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 99_999_999);

        vm.prank(admin);
        vault.realizeGain(100e6);  // unpaused: accepted

        assertEq(vault.nowChi(),       2.019375545061017805470462154e27);
        assertEq(vault.totalAssets(),  199_999_997);
        assertEq(vault.assetsOf(alice), 199_999_997);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 99_999_999);  // unchanged
        assertEq(vault.availableLiquidAssets(),          99_999_999);

        // Alice redeems everything: half her shares are paid from the real 99_999_999, the other
        // half (worth exactly 100_000_000 on paper) sits at the head with 2 spUSDC wei behind it.
        uint256 id = _requestRedeem(alice, SH_100);
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice), 99_999_997);
        (, , uint256 left) = _redeemRequest(id);
        assertEq(left,                       49_520_259);
        assertEq(vault.convertToAssets(left), 100_000_000);
        assertEq(_vaultSpUsdc(),              2);
        assertEq(vault.firstPendingRedeemId(),          id);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 99_999_997);  // no progress without new backing

        // Also accepted while paused.
        _pause();
        vm.prank(admin);
        vault.realizeGain(1);
        assertGt(vault.nowChi(), 2.019375545061017805470462154e27);
    }

    /**********************************************************************************************/
    /*** 15. Yield while queued, cancel / re-request cycles                                     ***/
    /**********************************************************************************************/

    // A queued depositor earns spUSDC yield on the full amount with no fee, exactly as if they held
    // spUSDC directly, while spPRIME holders earn the (lower) VSR. The same holds while the refund
    // sits unsettled in the cancelled queue.
    function test_requestDepositCancellation_queuedDepositEarnsSpUsdcYield() public {
        _deposit(carol, 1_000_000e6);  // holder, VSR stays at RAY

        // Bob holds spUSDC directly for comparison.
        usdc.mint(bob, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(spUsdc), 1_000_000e6);
        spUsdc.deposit(1_000_000e6, bob);
        vm.stopPrank();
        assertEq(spUsdc.balanceOf(bob), SS_1M);

        uint256 id = _queueDeposit(alice, 1_000_000e6);
        (, , uint256 ss) = _depositRequest(id);
        assertEq(ss, SS_1M);

        _setSpUsdcVsr(FIVE_PCT_VSR);
        _warpAndDrip(182 days);

        // Cancel half-way, settle at the end of the year: the cancelled queue earns the same rate.
        _cancelDeposit(alice, id, alice);
        _warpAndDrip(183 days);

        uint256 chiS = spUsdc.nowChi();
        uint256 expected = SS_1M * chiS / RAY;

        _settleCancelled();
        vm.prank(bob);
        spUsdc.redeem(SS_1M, bob, bob);

        assertEq(usdc.balanceOf(alice), expected);
        assertEq(usdc.balanceOf(bob),   expected);
        assertEq(usdc.balanceOf(alice), 1_049_999_999_998);  // 5% on 1_000_000e6, 2 wei of rounding
        assertEq(vault.assetsOf(carol), 999_999_999_998);    // holder earned nothing (VSR = RAY)

        emit log_named_uint("queued+cancelled depositor USDC after 1y at 5% spUSDC VSR", usdc.balanceOf(alice));
        emit log_named_uint("direct spUSDC holder USDC after 1y",                       usdc.balanceOf(bob));
        emit log_named_uint("spPRIME holder claim after 1y (VSR 0)",                    vault.assetsOf(carol));
    }

    // The same yield is credited at fill: a late fill mints more shares than an early one.
    function test_processDepositQueue_fillCreditsSpUsdcYieldAccruedWhileQueued() public {
        _deposit(carol, 1_000_000e6);
        assertEq(vault.balanceOf(carol), SH_1M);

        uint256 id = _queueDeposit(alice, 1_000_000e6);

        _setSpUsdcVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);

        _processDeposits(type(uint256).max, 1);
        (, , uint256 left) = _depositRequest(id);
        assertEq(left, 0);

        uint256 expectedAssets = spUsdc.convertToAssets(SS_1M);
        uint256 expectedShares = vault.convertToShares(expectedAssets);
        assertEq(vault.balanceOf(alice), expectedShares);
        assertEq(vault.balanceOf(alice), 1_039_925_443_313);
        assertEq(vault.assetsOf(alice),  1_049_999_999_997);
        assertEq(vault.assetsOf(carol),  999_999_999_998);

        // Alice ends with ~5% more shares than carol for the same USDC in.
        assertEq(vault.balanceOf(alice) - vault.balanceOf(carol), 49_520_259_204);
    }

    // Escrowed redeem shares keep accruing VSR; cancel returns them intact minus the fee.
    function test_cancelRedeemRequest_afterChiGrowthReturnsSharesIntact() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);

        uint256 id = _requestRedeem(alice, SH_1M);
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, 980_501_132_267);

        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);

        _cancelRedeem(alice, id, alice);

        assertEq(vault.balanceOf(alice), 980_501_132_267);
        assertEq(vault.assetsOf(alice),  1_039_499_999_997);  // 989_999_999_997 * 1.05
        assertEq(vault.totalSupply(),    980_501_132_267);
    }

    // Deposit / cancel / settle cycles only lose spUSDC rounding dust: 1 wei per cycle.
    function test_requestDepositCancellation_cycleLosesOneWeiPerRound() public {
        _setCapacity(0);
        _fund(alice, 100e6);

        uint256 amount = 100e6;
        for (uint256 i; i < 10; ++i) {
            vm.prank(alice);
            uint256 id = vault.requestDeposit(amount, alice);
            assertEq(id, i);
            assertEq(vault.firstPendingDepositId(), i);

            (, , uint256 ss) = _depositRequest(id);
            assertEq(ss, amount * RAY / CHI_S);

            uint256 cid = _cancelDeposit(alice, id, alice);
            assertEq(cid, i);
            assertEq(vault.firstPendingDepositId(), i + 1);
            _settleCancelled();
            assertEq(vault.firstPendingDepositCancellationId(), i + 1);

            uint256 refunded = usdc.balanceOf(alice);
            assertEq(refunded, ss * CHI_S / RAY);
            assertEq(refunded, amount - 1);
            amount = refunded;
        }
        assertEq(usdc.balanceOf(alice), 100e6 - 10);
        assertEq(_vaultSpUsdc(),        0);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // N-1 re-measured. Request / cancel cycles behind a live head entry still leave dead deposit
    // entries that consume maxRequests_ budget and gas. Each cycle now also appends an entry to
    // the cancelled queue that the rebalancer must settle (one spUSDC redeem each), and the
    // griefer can only recycle the same 100e6 if the rebalancer settles between cycles.
    function test_requestDepositCancellation_cancelledEntriesConsumeRequestBudget() public {
        _setMinDeposit(100e6);
        _setCapacity(0);
        uint256 idB = _deposit(bob, 100e6);  // live head entry keeps the head from walking
        assertEq(idB, 0);

        _fund(stranger, 100e6);
        for (uint256 i; i < 50; ++i) {
            vm.prank(stranger);
            uint256 id = vault.requestDeposit(100e6, stranger);
            assertEq(id, 1 + i);
            uint256 cid = _cancelDeposit(stranger, id, stranger);
            assertEq(cid, i);
            assertEq(vault.firstPendingDepositId(), 0);
            _settleCancelled();  // rebalancer co-operates; otherwise 50 x 100e6 of capital is needed
            // Top up the single wei lost per cycle so the request stays above minDeposit.
            usdc.mint(stranger, 100e6 - usdc.balanceOf(stranger));
        }
        _deposit(alice, 100e6);  // id 51
        _setCapacity(type(uint128).max);

        // 50 dead entries sit between bob and alice; a 50-request batch fills bob only.
        _processDeposits(type(uint256).max, 50);
        assertEq(vault.balanceOf(bob),   SH_100);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.firstPendingDepositId(),    50);

        _processDeposits(type(uint256).max, 1);  // skips dead entry 50
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.firstPendingDepositId(),    51);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(alice), SH_100);
        assertEq(vault.firstPendingDepositId(),    52);

        // Griefer paid 50 wei of USDC plus gas for 50 dead entries and 50 settlements.
        assertEq(usdc.balanceOf(stranger), 100e6);
        assertEq(vault.firstPendingDepositCancellationId(), 50);
    }

    // Gas the rebalancer pays per cancelled entry it settles, cold.
    function test_processCancelledDepositQueue_gasPerEntry() public {
        _setCapacity(0);
        uint256 id0 = _deposit(stranger, 100e6);
        _cancelDeposit(stranger, id0, stranger);

        _cool();
        vm.prank(rebalancer);
        uint256 gas = gasleft();
        vault.processCancelledDepositQueue(type(uint256).max, 1);
        uint256 one = gas - gasleft();

        for (uint256 i; i < 50; ++i) {
            uint256 id = _deposit(stranger, 100e6);
            _cancelDeposit(stranger, id, stranger);
        }
        assertEq(vault.pendingCancelledDepositSavingsShares(), 50 * SS_100);

        _cool();
        vm.prank(rebalancer);
        gas = gasleft();
        vault.processCancelledDepositQueue(type(uint256).max, 50);
        uint256 fifty = gas - gasleft();

        assertEq(vault.firstPendingDepositCancellationId(), 51);
        assertEq(usdc.balanceOf(stranger), 51 * 99_999_999);

        emit log_named_uint("processCancelledDepositQueue gas, 1 entry",   one);
        emit log_named_uint("processCancelledDepositQueue gas, 50 entries", fifty);
        emit log_named_uint("marginal gas per settled entry",              (fifty - one) / 49);

        assertGt((fifty - one) / 49, 10_000);  // each settlement is a full spUSDC redeem
    }

    // Redeem / cancel cycles cost the fee each time; nothing else moves.
    function test_cancelRedeemRequest_cycleLosesFeeEachRound() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);

        uint256 shares = SH_1M;
        for (uint256 i; i < 3; ++i) {
            uint256 id  = _requestRedeem(alice, shares);
            uint256 fee = _ceil(shares * 0.01e18, WAD);
            _cancelRedeem(alice, id, alice);
            shares -= fee;
            assertEq(vault.balanceOf(alice), shares);
            assertEq(vault.totalSupply(),    shares);
        }
        assertEq(shares, 960_989_159_734);  // 3 fees: 9_904_051_842 + 9_805_011_323 + 9_706_961_210
        assertEq(_vaultSpUsdc(), SS_1M);  // backing untouched, surplus now 3 fees
    }

}
