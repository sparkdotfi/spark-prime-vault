// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl } from "../lib/oz/contracts/access/IAccessControl.sol";

import { TestBase } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

contract SuspendedRequestsTests is TestBase {

    address internal user1        = makeAddr("user1");
    address internal user2        = makeAddr("user2");
    address internal recipient1   = makeAddr("recipient1");
    address internal recipient2   = makeAddr("recipient2");
    address internal unauthorized = makeAddr("unauthorized");

    function setUp() public override {
        super.setUp();

        vm.label(user1,        "user1");
        vm.label(user2,        "user2");
        vm.label(recipient1,   "recipient1");
        vm.label(recipient2,   "recipient2");
        vm.label(unauthorized, "unauthorized");
    }

    function _notAuthorized(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            account,
            role
        );
    }

    /**********************************************************************************************/
    /*** Authorization tests                                                                    ***/
    /**********************************************************************************************/

    function test_suspendAndUnsuspend_notOperator() external {
        vm.expectRevert(_notAuthorized(unauthorized, OPERATOR_ROLE));
        vm.prank(unauthorized);
        spPrime.suspendDepositRequest(1);

        vm.expectRevert(_notAuthorized(unauthorized, OPERATOR_ROLE));
        vm.prank(unauthorized);
        spPrime.suspendDepositCancellationRequest(1);

        vm.expectRevert(_notAuthorized(unauthorized, OPERATOR_ROLE));
        vm.prank(unauthorized);
        spPrime.suspendRedeemRequest(1);

        vm.expectRevert(_notAuthorized(unauthorized, OPERATOR_ROLE));
        vm.prank(unauthorized);
        spPrime.unsuspendDepositRequest(1);

        vm.expectRevert(_notAuthorized(unauthorized, OPERATOR_ROLE));
        vm.prank(unauthorized);
        spPrime.unsuspendDepositCancellationRequest(1);

        vm.expectRevert(_notAuthorized(unauthorized, OPERATOR_ROLE));
        vm.prank(unauthorized);
        spPrime.unsuspendRedeemRequest(1);
    }

    /**********************************************************************************************/
    /*** Deposit suspension tests                                                               ***/
    /**********************************************************************************************/

    function test_suspendDepositRequest_validation() external {
        uint48 dep1 = _requestDeposit(user1, 1_000e6);  // Request 1
        uint48 dep2 = _requestDeposit(user2, 2_000e6);  // Request 2

        // Zero ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(operator);
        spPrime.suspendDepositRequest(0);

        // Non-existent ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(operator);
        spPrime.suspendDepositRequest(3);

        // Cancelled deposit is removed from pending list
        uint256 shares1 = spPrime.getPendingDepositRequest(dep1).shares;
        uint48  cancel3 = _requestDepositCancellation(user1, dep1, shares1);  // Request 3

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(operator);
        spPrime.suspendDepositRequest(dep1);

        // Wrong queue ID (cancellation request ID is not a pending deposit)
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(operator);
        spPrime.suspendDepositRequest(cancel3);

        // Filled deposit is removed from pending list
        _processPendingDeposits();

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(operator);
        spPrime.suspendDepositRequest(dep2);
    }

    function test_suspendDepositRequest_alreadySuspended() external {
        uint48 dep1 = _requestDeposit(user1, 1_000e6);  // Request 1
        _requestDeposit(user2, 2_000e6);                // Request 2

        vm.prank(operator);
        spPrime.suspendDepositRequest(dep1);

        // Already suspended
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(operator);
        spPrime.suspendDepositRequest(dep1);

        // Process remaining pending deposit
        _processPendingDeposits();

        assertEq(spPrime.pendingDepositRequestsLength(),   0);
        assertEq(spPrime.suspendedDepositRequestsLength(), 1);

        // Still reverts with NoRequest
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(operator);
        spPrime.suspendDepositRequest(dep1);
    }

    function test_unsuspendDepositRequest_notSuspended() external {
        uint48 dep1 = _requestDeposit(user1, 1_000e6);  // Request 1

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(operator);
        spPrime.unsuspendDepositRequest(0);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(operator);
        spPrime.unsuspendDepositRequest(dep1);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(operator);
        spPrime.unsuspendDepositRequest(dep1 + 1);
    }

    function test_suspendAndUnsuspendDepositRequest() external {
        uint256 ts1     = vm.getBlockTimestamp();
        uint48  id1     = _requestDeposit(user1, recipient1, 1_000e6);  // Request 1
        uint256 shares1 = spPrime.getPendingDepositRequest(id1).shares;

        skip(100);

        uint48  id2     = _requestDeposit(user2, recipient2, 2_000e6);  // Request 2
        uint256 shares2 = spPrime.getPendingDepositRequest(id2).shares;

        assertEq(spPrime.pendingDepositSavingsShares(),   shares1 + shares2);
        assertEq(spPrime.suspendedDepositSavingsShares(), 0);

        // Suspend request 1
        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositRequestSuspended(operator, id1);

        vm.prank(operator);
        spPrime.suspendDepositRequest(id1);

        assertEq(spPrime.pendingDepositSavingsShares(),    shares2);
        assertEq(spPrime.pendingDepositRequestsLength(),   1);
        assertEq(spPrime.suspendedDepositSavingsShares(),  shares1);
        assertEq(spPrime.suspendedDepositRequestsLength(), 1);

        // No longer in pending list; now in suspended list
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingDepositRequest(id1);

        ISparkPrimeVault.Request memory req1 = spPrime.getSuspendedDepositRequest(id1);

        assertEq(req1.id,        id1);
        assertEq(req1.owner,     user1);
        assertEq(req1.recipient, recipient1);
        assertEq(req1.timestamp, uint64(ts1));
        assertEq(req1.shares,    shares1);

        // Blocked while suspended
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user1);
        spPrime.requestDepositCancellation(id1, recipient1, shares1);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user1);
        spPrime.updateDepositRecipient(id1, user1);

        // Processing fills request 2, leaving request 1 suspended
        _processPendingDeposits();

        assertEq(spPrime.pendingDepositRequestsLength(),   0);
        assertEq(spPrime.pendingDepositSavingsShares(),    0);
        assertEq(spPrime.suspendedDepositRequestsLength(), 1);
        assertEq(spPrime.balanceOf(recipient1),            0);
        assertGt(spPrime.balanceOf(recipient2),            0);

        // Enumerable via suspended getters
        ISparkPrimeVault.Request[] memory sReqs = spPrime.suspendedDepositRequests();

        assertEq(sReqs.length,        1);
        assertEq(sReqs[0].id,         id1);
        assertEq(sReqs[0].owner,      user1);
        assertEq(sReqs[0].recipient,  recipient1);
        assertEq(sReqs[0].timestamp,  uint64(ts1));
        assertEq(sReqs[0].shares,     shares1);

        // Unsuspend while paused also works and re-queues with the same ID and preserved metadata
        _pause();

        skip(200);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositRequestUnsuspended(operator, id1);

        vm.prank(operator);
        spPrime.unsuspendDepositRequest(id1);

        assertEq(spPrime.suspendedDepositRequestsLength(), 0);
        assertEq(spPrime.suspendedDepositSavingsShares(),  0);
        assertEq(spPrime.pendingDepositRequestsLength(),   1);
        assertEq(spPrime.pendingDepositSavingsShares(),    shares1);

        // No longer suspended
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(operator);
        spPrime.unsuspendDepositRequest(id1);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getSuspendedDepositRequest(id1);

        // Back in pending list with original ID, timestamp, owner, recipient, and shares
        ISparkPrimeVault.Request memory pendingReq = spPrime.getPendingDepositRequest(id1);

        assertEq(pendingReq.id,        id1);
        assertEq(pendingReq.owner,     user1);
        assertEq(pendingReq.recipient, recipient1);
        assertEq(pendingReq.timestamp, uint64(ts1));
        assertEq(pendingReq.shares,    shares1);

        // Can update recipient and process once unpaused
        _unpause();

        vm.prank(user1);
        spPrime.updateDepositRecipient(id1, user1);

        assertEq(spPrime.getPendingDepositRequest(id1).recipient, user1);

        _processPendingDeposits();

        assertEq(spPrime.pendingDepositRequestsLength(), 0);
        assertEq(spPrime.pendingDepositSavingsShares(),  0);
        assertGt(spPrime.balanceOf(user1),               0);
    }

    function test_suspendDepositRequest_partialFillThenSuspend() external {
        uint48  id1     = _requestDeposit(user1, 1_000e6);  // Request 1
        uint256 shares1 = spPrime.getPendingDepositRequest(id1).shares;

        uint256 fillShares = shares1 / 4;
        _processPendingDeposits(fillShares, 1);

        uint256 remainingShares = shares1 - fillShares;
        assertEq(spPrime.getPendingDepositRequest(id1).shares, remainingShares);

        vm.prank(operator);
        spPrime.suspendDepositRequest(id1);

        assertEq(spPrime.pendingDepositRequestsLength(),   0);
        assertEq(spPrime.pendingDepositSavingsShares(),    0);
        assertEq(spPrime.suspendedDepositRequestsLength(), 1);
        assertEq(spPrime.suspendedDepositSavingsShares(),  remainingShares);

        uint256 balBefore = spPrime.balanceOf(user1);

        _processPendingDeposits();

        assertEq(spPrime.balanceOf(user1),                 balBefore);
        assertEq(spPrime.suspendedDepositRequestsLength(), 1);
    }

    /**********************************************************************************************/
    /*** Deposit cancellation suspension tests                                                  ***/
    /**********************************************************************************************/

    function test_suspendAndUnsuspendDepositCancellationRequest() external {
        uint48 dep1 = _requestDeposit(user1, 1_000e6);  // Request 1
        uint48 dep2 = _requestDeposit(user2, 2_000e6);  // Request 2

        uint256 shares1 = spPrime.getPendingDepositRequest(dep1).shares;
        uint256 shares2 = spPrime.getPendingDepositRequest(dep2).shares;

        uint256 ts3     = vm.getBlockTimestamp();
        uint48  cancel3 = _requestDepositCancellation(user1, dep1, recipient1, shares1);  // Request 3

        skip(50);

        uint48 cancel4 = _requestDepositCancellation(user2, dep2, recipient2, shares2);   // Request 4

        // Suspend cancel3
        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellationRequestSuspended(operator, cancel3);

        vm.prank(operator);
        spPrime.suspendDepositCancellationRequest(cancel3);

        assertEq(spPrime.pendingDepositCancellationSavingsShares(),    shares2);
        assertEq(spPrime.pendingDepositCancellationRequestsLength(),   1);
        assertEq(spPrime.suspendedDepositCancellationSavingsShares(),  shares1);
        assertEq(spPrime.suspendedDepositCancellationRequestsLength(), 1);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingDepositCancellationRequest(cancel3);

        assertEq(spPrime.getSuspendedDepositCancellationRequest(cancel3).id, cancel3);

        // Update recipient blocked while suspended
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user1);
        spPrime.updateDepositCancellationRecipient(cancel3, user1);

        // Unsuspend cancel3 BEFORE processing: appends to tail after cancel4 with the same ID
        skip(50);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellationRequestUnsuspended(operator, cancel3);

        vm.prank(operator);
        spPrime.unsuspendDepositCancellationRequest(cancel3);

        ISparkPrimeVault.Request[] memory pending = spPrime.pendingDepositCancellationRequests();

        assertEq(pending.length,        2);
        assertEq(pending[0].id,         cancel4);
        assertEq(pending[1].id,         cancel3);
        assertEq(pending[1].owner,      user1);
        assertEq(pending[1].recipient,  recipient1);
        assertEq(pending[1].timestamp,  uint64(ts3));
        assertEq(pending[1].shares,     shares1);

        // Processing 1 request processes cancel4 (head), leaving cancel3 pending
        _processPendingDepositCancellations(1);

        assertEq(spPrime.pendingDepositCancellationRequestsLength(), 1);
        assertEq(usdc.balanceOf(recipient1),                         0);
        assertGt(usdc.balanceOf(recipient2),                         0);

        // Processing next request processes cancel3
        _processPendingDepositCancellations(1);

        assertEq(spPrime.pendingDepositCancellationRequestsLength(), 0);
        assertEq(spPrime.pendingDepositCancellationSavingsShares(),  0);
        assertGt(usdc.balanceOf(recipient1),                         0);
    }

    function test_suspendDepositCancellationRequest_pausedAndSkipped() external {
        uint48  dep1    = _requestDeposit(user1, 1_000e6);                                 // Request 1
        uint256 shares1 = spPrime.getPendingDepositRequest(dep1).shares;
        uint48  cancel2 = _requestDepositCancellation(user1, dep1, recipient1, shares1);   // Request 2

        _pause();

        vm.prank(operator);
        spPrime.suspendDepositCancellationRequest(cancel2);

        assertEq(spPrime.pendingDepositCancellationRequestsLength(),   0);
        assertEq(spPrime.suspendedDepositCancellationRequestsLength(), 1);

        _processPendingDepositCancellations(1);

        assertEq(usdc.balanceOf(recipient1), 0);

        vm.prank(operator);
        spPrime.unsuspendDepositCancellationRequest(cancel2);

        assertEq(spPrime.pendingDepositCancellationRequestsLength(),   1);
        assertEq(spPrime.suspendedDepositCancellationRequestsLength(), 0);

        _processPendingDepositCancellations(1);

        assertGt(usdc.balanceOf(recipient1), 0);
    }

    /**********************************************************************************************/
    /*** Redeem suspension tests                                                                ***/
    /**********************************************************************************************/

    function test_suspendAndUnsuspendRedeemRequest() external {
        _requestDeposit(user1, 1_000e6);  // Request 1
        _requestDeposit(user2, 2_000e6);  // Request 2
        _processPendingDeposits();

        uint256 bal1 = spPrime.balanceOf(user1);
        uint256 bal2 = spPrime.balanceOf(user2);

        uint256 ts3     = vm.getBlockTimestamp();
        uint48  redeem3 = _requestRedeem(user1, recipient1, bal1);  // Request 3

        _requestRedeem(user2, recipient2, bal2);                    // Request 4

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.RedeemRequestSuspended(operator, redeem3);

        vm.prank(operator);
        spPrime.suspendRedeemRequest(redeem3);

        assertEq(spPrime.pendingRedeemShares(),           bal2);
        assertEq(spPrime.pendingRedeemRequestsLength(),   1);
        assertEq(spPrime.suspendedRedeemShares(),         bal1);
        assertEq(spPrime.suspendedRedeemRequestsLength(), 1);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingRedeemRequest(redeem3);

        assertEq(spPrime.getSuspendedRedeemRequest(redeem3).id, redeem3);

        // Update recipient blocked while suspended
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user1);
        spPrime.updateRedeemRecipient(redeem3, user1);

        // Processing fills redeem4, leaving redeem3 suspended
        _processPendingRedeems();

        assertEq(spPrime.pendingRedeemRequestsLength(),   0);
        assertEq(spPrime.pendingRedeemShares(),           0);
        assertEq(spPrime.suspendedRedeemRequestsLength(), 1);
        assertEq(spPrime.suspendedRedeemShares(),         bal1);
        assertEq(usdc.balanceOf(recipient1),              0);
        assertGt(usdc.balanceOf(recipient2),              0);

        // Unsuspend while paused and update recipient after unpausing
        _pause();

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.RedeemRequestUnsuspended(operator, redeem3);

        vm.prank(operator);
        spPrime.unsuspendRedeemRequest(redeem3);

        assertEq(spPrime.suspendedRedeemRequestsLength(), 0);
        assertEq(spPrime.suspendedRedeemShares(),         0);
        assertEq(spPrime.pendingRedeemRequestsLength(),   1);
        assertEq(spPrime.pendingRedeemShares(),           bal1);

        ISparkPrimeVault.Request memory req = spPrime.getPendingRedeemRequest(redeem3);

        assertEq(req.id,        redeem3);
        assertEq(req.owner,     user1);
        assertEq(req.recipient, recipient1);
        assertEq(req.timestamp, uint64(ts3));
        assertEq(req.shares,    bal1);

        _unpause();

        vm.prank(user1);
        spPrime.updateRedeemRecipient(redeem3, user1);

        _processPendingRedeems();

        assertEq(spPrime.pendingRedeemRequestsLength(), 0);
        assertEq(spPrime.pendingRedeemShares(),         0);
        assertGt(usdc.balanceOf(user1),                 0);
    }

    function test_unsuspendRedeemRequest_beforeProcessedAppendsToTail() external {
        _requestDeposit(user1, 1_000e6);  // Request 1
        _requestDeposit(user2, 2_000e6);  // Request 2
        _processPendingDeposits();

        uint256 bal1    = spPrime.balanceOf(user1);
        uint256 bal2    = spPrime.balanceOf(user2);
        uint48  redeem3 = _requestRedeem(user1, recipient1, bal1);  // Request 3
        uint48  redeem4 = _requestRedeem(user2, recipient2, bal2);  // Request 4

        vm.prank(operator);
        spPrime.suspendRedeemRequest(redeem3);

        vm.prank(operator);
        spPrime.unsuspendRedeemRequest(redeem3);

        ISparkPrimeVault.Request[] memory pending = spPrime.pendingRedeemRequests();

        assertEq(pending.length, 2);
        assertEq(pending[0].id,  redeem4);
        assertEq(pending[1].id,  redeem3);

        // First call processes redeem4 (now at head), leaving redeem3 pending
        _processPendingRedeems(1);

        assertEq(spPrime.pendingRedeemRequestsLength(), 1);
        assertEq(usdc.balanceOf(recipient1),            0);
        assertGt(usdc.balanceOf(recipient2),            0);

        _processPendingRedeems(1);

        assertEq(spPrime.pendingRedeemRequestsLength(), 0);
        assertGt(usdc.balanceOf(recipient1),            0);
    }

    /**********************************************************************************************/
    /*** Doubly-linked list boundary & re-suspension tests                                      ***/
    /**********************************************************************************************/

    function test_linkedList_headMiddleTailSingleAndReSuspend() external {
        // Create 4 deposit requests: [1, 2, 3, 4]
        uint48 id1 = _requestDeposit(user1, 1_000e6);
        uint48 id2 = _requestDeposit(user1, 2_000e6);
        uint48 id3 = _requestDeposit(user1, 3_000e6);
        uint48 id4 = _requestDeposit(user1, 4_000e6);

        // Suspend head (1), middle (3), tail (4), and finally the only remaining element (2)
        vm.startPrank(operator);
        spPrime.suspendDepositRequest(id1);
        spPrime.suspendDepositRequest(id3);
        spPrime.suspendDepositRequest(id4);
        vm.stopPrank();

        ISparkPrimeVault.Request[] memory pending   = spPrime.pendingDepositRequests();
        ISparkPrimeVault.Request[] memory suspended = spPrime.suspendedDepositRequests();

        assertEq(pending.length,   1);
        assertEq(pending[0].id,    id2);
        assertEq(suspended.length, 3);
        assertEq(suspended[0].id,  id1);
        assertEq(suspended[1].id,  id3);
        assertEq(suspended[2].id,  id4);

        // Suspend the sole remaining pending element
        vm.prank(operator);
        spPrime.suspendDepositRequest(id2);

        assertEq(spPrime.pendingDepositRequestsLength(),   0);
        assertEq(spPrime.suspendedDepositRequestsLength(), 4);

        // Unsuspend middle (3), tail (2), head (1), and sole remaining (4)
        vm.startPrank(operator);
        spPrime.unsuspendDepositRequest(id3);
        spPrime.unsuspendDepositRequest(id2);
        spPrime.unsuspendDepositRequest(id1);
        spPrime.unsuspendDepositRequest(id4);
        vm.stopPrank();

        assertEq(spPrime.suspendedDepositRequestsLength(), 0);

        pending = spPrime.pendingDepositRequests();

        assertEq(pending.length, 4);
        assertEq(pending[0].id,  id3);
        assertEq(pending[1].id,  id2);
        assertEq(pending[2].id,  id1);
        assertEq(pending[3].id,  id4);

        // Re-suspend middle element (2) and verify order of both lists
        vm.prank(operator);
        spPrime.suspendDepositRequest(id2);

        pending   = spPrime.pendingDepositRequests();
        suspended = spPrime.suspendedDepositRequests();

        assertEq(pending.length,   3);
        assertEq(pending[0].id,    id3);
        assertEq(pending[1].id,    id1);
        assertEq(pending[2].id,    id4);
        assertEq(suspended.length, 1);
        assertEq(suspended[0].id,  id2);

        // Processing fills 3, 1, 4 while 2 remains suspended
        _processPendingDeposits();

        assertEq(spPrime.pendingDepositRequestsLength(),   0);
        assertEq(spPrime.suspendedDepositRequestsLength(), 1);
        assertEq(spPrime.getSuspendedDepositRequest(id2).id, id2);
    }

}
