// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl } from "../lib/oz/contracts/access/IAccessControl.sol";

import {
    IAccessControlEnumerable
} from "../lib/oz/contracts/access/extensions/IAccessControlEnumerable.sol";

import { IERC165 } from "../lib/oz/contracts/utils/introspection/IERC165.sol";

import { TestBase, ISparkVaultLike } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

abstract contract GettersTestBase is TestBase {

    uint16 internal constant REFERRAL = type(uint16).max;

    address internal owner1 = makeAddr("owner1");
    address internal owner2 = makeAddr("owner2");
    address internal owner3 = makeAddr("owner3");

    address internal recipient1 = makeAddr("recipient1");
    address internal recipient2 = makeAddr("recipient2");
    address internal recipient3 = makeAddr("recipient3");

    function setUp() public virtual override {
        super.setUp();

        vm.label(owner1, "owner1");
        vm.label(owner2, "owner2");
        vm.label(owner3, "owner3");

        vm.label(recipient1, "recipient1");
        vm.label(recipient2, "recipient2");
        vm.label(recipient3, "recipient3");
    }

}

contract PendingDepositRequestTests is GettersTestBase {

    /**********************************************************************************************/
    /*** pendingDepositRequestsLength                                                           ***/
    /**********************************************************************************************/

    function test_pendingDepositRequestsLength() external {
        assertEq(spPrime.pendingDepositRequestsLength(), 0);

        _requestDeposit(owner1, recipient1, 1_000e6);

        assertEq(spPrime.pendingDepositRequestsLength(), 1);

        _requestDeposit(owner1, recipient1, 1_000e6);

        assertEq(spPrime.pendingDepositRequestsLength(), 2);

        _processPendingDeposits(1);

        assertEq(spPrime.pendingDepositRequestsLength(), 1);

        _processPendingDeposits(1);

        assertEq(spPrime.pendingDepositRequestsLength(), 0);
    }

    /**********************************************************************************************/
    /*** getPendingDepositRequest                                                               ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequest_noRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _processPendingDeposits(1);

        // Zero ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingDepositRequest(0);

        // Processed ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingDepositRequest(1);

        // Non-existent ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingDepositRequest(3);

        // Suspended ID
        _suspendDeposit(2);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingDepositRequest(2);

        _unsuspendDeposit(2);

        spPrime.getPendingDepositRequest(2);
    }

    function test_getPendingDepositRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _assertDepositRequest(1, owner1, recipient1, 1_000e6 - 1);
        _assertDepositRequest(2, owner2, recipient2, 2_000e6 - 1);
    }

    function test_getPendingDepositRequest_partialFill() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1

        _processPendingDeposits(spUSDC.convertToShares(1_000e6) / 4, 1);

        _assertDepositRequest(1, owner1, recipient1, 750e6 - 1);
    }

    /**********************************************************************************************/
    /*** pendingDepositRequests                                                                 ***/
    /**********************************************************************************************/

    function test_pendingDepositRequests_noRequests() external view {
        assertEq(spPrime.pendingDepositRequests().length, 0);
    }

    function test_pendingDepositRequests() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2
        _requestDeposit(owner3, recipient3, 3_000e6);  // Request 3

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositRequests();

        assertEq(requests.length, 3);

        _assertDepositRequest(requests[0], 1, owner1, recipient1, 1_000e6 - 1);
        _assertDepositRequest(requests[1], 2, owner2, recipient2, 2_000e6 - 1);
        _assertDepositRequest(requests[2], 3, owner3, recipient3, 3_000e6 - 1);
    }

    function test_pendingDepositRequests_someProcessed() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2
        _requestDeposit(owner3, recipient3, 3_000e6);  // Request 3

        _processPendingDeposits(2);

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositRequests();

        assertEq(requests.length, 1);

        _assertDepositRequest(requests[0], 3, owner3, recipient3, 3_000e6 - 1);
    }

    function test_pendingDepositRequests_allProcessed() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _processPendingDeposits();

        assertEq(spPrime.pendingDepositRequests().length, 0);
    }

    function test_pendingDepositRequests_partialFill() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _processPendingDeposits(spUSDC.convertToShares(1_000e6) / 4, type(uint256).max);

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositRequests();

        assertEq(requests.length, 2);

        _assertDepositRequest(requests[0], 1, owner1, recipient1, 750e6 - 1);
        _assertDepositRequest(requests[1], 2, owner2, recipient2, 2_000e6 - 1);
    }

    function test_pendingDepositRequests_cancelledRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2
        _requestDeposit(owner3, recipient3, 3_000e6);  // Request 3

        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositRequests();

        assertEq(requests.length, 2);

        _assertDepositRequest(requests[0], 1, owner1, recipient1, 1_000e6 - 1);
        _assertDepositRequest(requests[1], 3, owner3, recipient3, 3_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** getPendingDepositRequests                                                              ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequests_startIndexTooLargeBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);

        vm.expectRevert(ISparkPrimeVault.StartIndexTooLarge.selector);
        spPrime.getPendingDepositRequests(2, 0);

        spPrime.getPendingDepositRequests(1, 0);
    }

    function test_getPendingDepositRequests_zeroLength() external view {
        assertEq(spPrime.getPendingDepositRequests(0, 0).length, 0);
    }

    function test_getPendingDepositRequests_range() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2
        _requestDeposit(owner3, recipient3, 3_000e6);  // Request 3

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests(0, 3);

        assertEq(requests.length, 3);

        _assertDepositRequest(requests[0], 1, owner1, recipient1, 1_000e6 - 1);
        _assertDepositRequest(requests[1], 2, owner2, recipient2, 2_000e6 - 1);
        _assertDepositRequest(requests[2], 3, owner3, recipient3, 3_000e6 - 1);

        requests = spPrime.getPendingDepositRequests(1, 2);

        assertEq(requests.length, 2);

        _assertDepositRequest(requests[0], 2, owner2, recipient2, 2_000e6 - 1);
        _assertDepositRequest(requests[1], 3, owner3, recipient3, 3_000e6 - 1);

        _processPendingDeposits(1);

        requests = spPrime.getPendingDepositRequests(0, 2);

        assertEq(requests.length, 2);

        _assertDepositRequest(requests[0], 2, owner2, recipient2, 2_000e6 - 1);
        _assertDepositRequest(requests[1], 3, owner3, recipient3, 3_000e6 - 1);
    }

    function test_getPendingDepositRequests_clamping() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        assertEq(spPrime.getPendingDepositRequests(0, 3).length, 2);
    }

}

contract SuspendedDepositRequestTests is GettersTestBase {

    /**********************************************************************************************/
    /*** suspendedDepositRequestsLength                                                         ***/
    /**********************************************************************************************/

    function test_suspendedDepositRequestsLength() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        assertEq(spPrime.suspendedDepositRequestsLength(), 0);

        _suspendDeposit(1);

        assertEq(spPrime.suspendedDepositRequestsLength(), 1);

        _suspendDeposit(2);

        assertEq(spPrime.suspendedDepositRequestsLength(), 2);

        _unsuspendDeposit(1);

        assertEq(spPrime.suspendedDepositRequestsLength(), 1);

        _unsuspendDeposit(2);

        assertEq(spPrime.suspendedDepositRequestsLength(), 0);
    }

    /**********************************************************************************************/
    /*** getSuspendedDepositRequest                                                             ***/
    /**********************************************************************************************/

    function test_getSuspendedDepositRequest_noRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _suspendDeposit(1);

        // Zero ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getSuspendedDepositRequest(0);

        // Pending (not suspended) ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getSuspendedDepositRequest(2);

        // Non-existent ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getSuspendedDepositRequest(3);

        spPrime.getSuspendedDepositRequest(1);

        // Unsuspended ID
        _unsuspendDeposit(1);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getSuspendedDepositRequest(1);
    }

    function test_getSuspendedDepositRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _suspendDeposit(1);
        _suspendDeposit(2);

        _assertSuspendedDepositRequest(1, owner1, recipient1, 1_000e6 - 1);
        _assertSuspendedDepositRequest(2, owner2, recipient2, 2_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** suspendedDepositRequests                                                               ***/
    /**********************************************************************************************/

    function test_suspendedDepositRequests_noRequests() external view {
        assertEq(spPrime.suspendedDepositRequests().length, 0);
    }

    function test_suspendedDepositRequests() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2
        _requestDeposit(owner3, recipient3, 3_000e6);  // Request 3

        _suspendDeposit(3);
        _suspendDeposit(1);

        ISparkPrimeVault.Request[] memory requests = spPrime.suspendedDepositRequests();

        assertEq(requests.length, 2);

        _assertDepositRequest(requests[0], 3, owner3, recipient3, 3_000e6 - 1);
        _assertDepositRequest(requests[1], 1, owner1, recipient1, 1_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** getSuspendedDepositRequests                                                            ***/
    /**********************************************************************************************/

    function test_getSuspendedDepositRequests_startIndexTooLargeBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _suspendDeposit(1);

        vm.expectRevert(ISparkPrimeVault.StartIndexTooLarge.selector);
        spPrime.getSuspendedDepositRequests(2, 0);

        spPrime.getSuspendedDepositRequests(1, 0);
    }

    function test_getSuspendedDepositRequests_zeroLength() external view {
        assertEq(spPrime.getSuspendedDepositRequests(0, 0).length, 0);
    }

    function test_getSuspendedDepositRequests_range() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2
        _requestDeposit(owner3, recipient3, 3_000e6);  // Request 3

        _suspendDeposit(1);
        _suspendDeposit(2);
        _suspendDeposit(3);

        ISparkPrimeVault.Request[] memory requests = spPrime.getSuspendedDepositRequests(0, 3);

        assertEq(requests.length, 3);

        _assertDepositRequest(requests[0], 1, owner1, recipient1, 1_000e6 - 1);
        _assertDepositRequest(requests[1], 2, owner2, recipient2, 2_000e6 - 1);
        _assertDepositRequest(requests[2], 3, owner3, recipient3, 3_000e6 - 1);

        requests = spPrime.getSuspendedDepositRequests(1, 2);

        assertEq(requests.length, 2);

        _assertDepositRequest(requests[0], 2, owner2, recipient2, 2_000e6 - 1);
        _assertDepositRequest(requests[1], 3, owner3, recipient3, 3_000e6 - 1);
    }

    function test_getSuspendedDepositRequests_clamping() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _suspendDeposit(1);
        _suspendDeposit(2);

        assertEq(spPrime.getSuspendedDepositRequests(0, 3).length, 2);
    }

}

contract PendingDepositCancellationRequestTests is GettersTestBase {

    /**********************************************************************************************/
    /*** pendingDepositCancellationRequestsLength                                               ***/
    /**********************************************************************************************/

    function test_pendingDepositCancellationRequestsLength() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        assertEq(spPrime.pendingDepositCancellationRequestsLength(), 0);

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));

        assertEq(spPrime.pendingDepositCancellationRequestsLength(), 1);

        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));

        assertEq(spPrime.pendingDepositCancellationRequestsLength(), 2);

        _processPendingDepositCancellations(1);

        assertEq(spPrime.pendingDepositCancellationRequestsLength(), 1);

        _processPendingDepositCancellations(1);

        assertEq(spPrime.pendingDepositCancellationRequestsLength(), 0);
    }

    /**********************************************************************************************/
    /*** getPendingDepositCancellationRequest                                                   ***/
    /**********************************************************************************************/

    function test_getPendingDepositCancellationRequest_noRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 3
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 4

        _processPendingDepositCancellations(1);

        // Zero ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingDepositCancellationRequest(0);

        // Wrong queue / removed deposit ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingDepositCancellationRequest(1);

        // Processed cancellation ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingDepositCancellationRequest(3);

        // Non-existent ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingDepositCancellationRequest(5);

        // Suspended ID
        _suspendDepositCancellation(4);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingDepositCancellationRequest(4);

        _unsuspendDepositCancellation(4);

        spPrime.getPendingDepositCancellationRequest(4);
    }

    function test_getPendingDepositCancellationRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 3
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 4

        _assertDepositCancellationRequest(3, owner1, recipient1, 1_000e6 - 1);
        _assertDepositCancellationRequest(4, owner2, recipient2, 2_000e6 - 1);
    }

    function test_getPendingDepositCancellationRequest_partialFill() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 3
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 4

        _processPendingDepositCancellations(
            spUSDC.convertToShares(1_000e6) + spUSDC.convertToShares(2_000e6) / 4,
            2
        );

        _assertDepositCancellationRequest(4, owner2, recipient2, 1_500e6);
    }

    /**********************************************************************************************/
    /*** pendingDepositCancellationRequests                                                     ***/
    /**********************************************************************************************/

    function test_pendingDepositCancellationRequests_noRequests() external view {
        assertEq(spPrime.pendingDepositCancellationRequests().length, 0);
    }

    function test_pendingDepositCancellationRequests() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2
        _requestDeposit(owner3, recipient3, 3_000e6);  // Request 3

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 4
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 5
        _requestDepositCancellation(owner3, 3, recipient3, spUSDC.convertToShares(3_000e6));  // Request 6

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositCancellationRequests();

        assertEq(requests.length, 3);

        _assertDepositCancellationRequest(requests[0], 4, owner1, recipient1, 1_000e6 - 1);
        _assertDepositCancellationRequest(requests[1], 5, owner2, recipient2, 2_000e6 - 1);
        _assertDepositCancellationRequest(requests[2], 6, owner3, recipient3, 3_000e6 - 1);
    }

    function test_pendingDepositCancellationRequests_someProcessed() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2
        _requestDeposit(owner3, recipient3, 3_000e6);  // Request 3

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 4
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 5
        _requestDepositCancellation(owner3, 3, recipient3, spUSDC.convertToShares(3_000e6));  // Request 6

        _processPendingDepositCancellations(2);

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositCancellationRequests();

        assertEq(requests.length, 1);

        _assertDepositCancellationRequest(requests[0], 6, owner3, recipient3, 3_000e6 - 1);
    }

    function test_pendingDepositCancellationRequests_allProcessed() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 3
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 4

        _processPendingDepositCancellations(2);

        assertEq(spPrime.pendingDepositCancellationRequests().length, 0);
    }

    function test_pendingDepositCancellationRequests_partialFill() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 3
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 4

        _processPendingDepositCancellations(spUSDC.convertToShares(1_000e6) / 4, 1);

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositCancellationRequests();

        assertEq(requests.length, 2);

        _assertDepositCancellationRequest(requests[0], 3, owner1, recipient1, 750e6 - 1);
        _assertDepositCancellationRequest(requests[1], 4, owner2, recipient2, 2_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** getPendingDepositCancellationRequests                                                  ***/
    /**********************************************************************************************/

    function test_getPendingDepositCancellationRequests_startIndexTooLargeBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 2

        vm.expectRevert(ISparkPrimeVault.StartIndexTooLarge.selector);
        spPrime.getPendingDepositCancellationRequests(2, 0);

        spPrime.getPendingDepositCancellationRequests(1, 0);
    }

    function test_getPendingDepositCancellationRequests_zeroLength() external view {
        assertEq(spPrime.getPendingDepositCancellationRequests(0, 0).length, 0);
    }

    function test_getPendingDepositCancellationRequests_range() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2
        _requestDeposit(owner3, recipient3, 3_000e6);  // Request 3

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 4
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 5
        _requestDepositCancellation(owner3, 3, recipient3, spUSDC.convertToShares(3_000e6));  // Request 6

        ISparkPrimeVault.Request[] memory requests
            = spPrime.getPendingDepositCancellationRequests(0, 3);

        assertEq(requests.length, 3);

        _assertDepositCancellationRequest(requests[0], 4, owner1, recipient1, 1_000e6 - 1);
        _assertDepositCancellationRequest(requests[1], 5, owner2, recipient2, 2_000e6 - 1);
        _assertDepositCancellationRequest(requests[2], 6, owner3, recipient3, 3_000e6 - 1);

        requests = spPrime.getPendingDepositCancellationRequests(1, 2);

        assertEq(requests.length, 2);

        _assertDepositCancellationRequest(requests[0], 5, owner2, recipient2, 2_000e6 - 1);
        _assertDepositCancellationRequest(requests[1], 6, owner3, recipient3, 3_000e6 - 1);
    }

    function test_getPendingDepositCancellationRequests_clamping() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 3
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 4

        assertEq(spPrime.getPendingDepositCancellationRequests(0, 3).length, 2);
    }

}

contract SuspendedDepositCancellationRequestTests is GettersTestBase {

    /**********************************************************************************************/
    /*** suspendedDepositCancellationRequestsLength                                             ***/
    /**********************************************************************************************/

    function test_suspendedDepositCancellationRequestsLength() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 3
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 4

        assertEq(spPrime.suspendedDepositCancellationRequestsLength(), 0);

        _suspendDepositCancellation(3);

        assertEq(spPrime.suspendedDepositCancellationRequestsLength(), 1);

        _suspendDepositCancellation(4);

        assertEq(spPrime.suspendedDepositCancellationRequestsLength(), 2);

        _unsuspendDepositCancellation(3);

        assertEq(spPrime.suspendedDepositCancellationRequestsLength(), 1);

        _unsuspendDepositCancellation(4);

        assertEq(spPrime.suspendedDepositCancellationRequestsLength(), 0);
    }

    /**********************************************************************************************/
    /*** getSuspendedDepositCancellationRequest                                                 ***/
    /**********************************************************************************************/

    function test_getSuspendedDepositCancellationRequest_noRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 3
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 4

        _suspendDepositCancellation(3);

        // Zero ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getSuspendedDepositCancellationRequest(0);

        // Pending (not suspended) ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getSuspendedDepositCancellationRequest(4);

        // Non-existent ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getSuspendedDepositCancellationRequest(5);

        spPrime.getSuspendedDepositCancellationRequest(3);

        // Unsuspended ID
        _unsuspendDepositCancellation(3);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getSuspendedDepositCancellationRequest(3);
    }

    function test_getSuspendedDepositCancellationRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 3
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 4

        _suspendDepositCancellation(3);
        _suspendDepositCancellation(4);

        _assertSuspendedDepositCancellationRequest(3, owner1, recipient1, 1_000e6 - 1);
        _assertSuspendedDepositCancellationRequest(4, owner2, recipient2, 2_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** suspendedDepositCancellationRequests                                                   ***/
    /**********************************************************************************************/

    function test_suspendedDepositCancellationRequests_noRequests() external view {
        assertEq(spPrime.suspendedDepositCancellationRequests().length, 0);
    }

    function test_suspendedDepositCancellationRequests() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2
        _requestDeposit(owner3, recipient3, 3_000e6);  // Request 3

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 4
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 5
        _requestDepositCancellation(owner3, 3, recipient3, spUSDC.convertToShares(3_000e6));  // Request 6

        _suspendDepositCancellation(6);
        _suspendDepositCancellation(4);

        ISparkPrimeVault.Request[] memory requests = spPrime.suspendedDepositCancellationRequests();

        assertEq(requests.length, 2);

        _assertDepositCancellationRequest(requests[0], 6, owner3, recipient3, 3_000e6 - 1);
        _assertDepositCancellationRequest(requests[1], 4, owner1, recipient1, 1_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** getSuspendedDepositCancellationRequests                                                ***/
    /**********************************************************************************************/

    function test_getSuspendedDepositCancellationRequests_startIndexTooLargeBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 2

        _suspendDepositCancellation(2);

        vm.expectRevert(ISparkPrimeVault.StartIndexTooLarge.selector);
        spPrime.getSuspendedDepositCancellationRequests(2, 0);

        spPrime.getSuspendedDepositCancellationRequests(1, 0);
    }

    function test_getSuspendedDepositCancellationRequests_zeroLength() external view {
        assertEq(spPrime.getSuspendedDepositCancellationRequests(0, 0).length, 0);
    }

    function test_getSuspendedDepositCancellationRequests_range() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2
        _requestDeposit(owner3, recipient3, 3_000e6);  // Request 3

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 4
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 5
        _requestDepositCancellation(owner3, 3, recipient3, spUSDC.convertToShares(3_000e6));  // Request 6

        _suspendDepositCancellation(4);
        _suspendDepositCancellation(5);
        _suspendDepositCancellation(6);

        ISparkPrimeVault.Request[] memory requests
            = spPrime.getSuspendedDepositCancellationRequests(0, 3);

        assertEq(requests.length, 3);

        _assertDepositCancellationRequest(requests[0], 4, owner1, recipient1, 1_000e6 - 1);
        _assertDepositCancellationRequest(requests[1], 5, owner2, recipient2, 2_000e6 - 1);
        _assertDepositCancellationRequest(requests[2], 6, owner3, recipient3, 3_000e6 - 1);

        requests = spPrime.getSuspendedDepositCancellationRequests(1, 2);

        assertEq(requests.length, 2);

        _assertDepositCancellationRequest(requests[0], 5, owner2, recipient2, 2_000e6 - 1);
        _assertDepositCancellationRequest(requests[1], 6, owner3, recipient3, 3_000e6 - 1);
    }

    function test_getSuspendedDepositCancellationRequests_clamping() external {
        _requestDeposit(owner1, recipient1, 1_000e6);  // Request 1
        _requestDeposit(owner2, recipient2, 2_000e6);  // Request 2

        _requestDepositCancellation(owner1, 1, recipient1, spUSDC.convertToShares(1_000e6));  // Request 3
        _requestDepositCancellation(owner2, 2, recipient2, spUSDC.convertToShares(2_000e6));  // Request 4

        _suspendDepositCancellation(3);
        _suspendDepositCancellation(4);

        assertEq(spPrime.getSuspendedDepositCancellationRequests(0, 3).length, 2);
    }

}

contract PendingRedeemRequestTests is GettersTestBase {

    /**********************************************************************************************/
    /*** pendingRedeemRequestsLength                                                            ***/
    /**********************************************************************************************/

    function test_pendingRedeemRequestsLength() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);

        _processPendingDeposits();

        assertEq(spPrime.pendingRedeemRequestsLength(), 0);

        _requestRedeem(owner1, spPrime.balanceOf(owner1));

        assertEq(spPrime.pendingRedeemRequestsLength(), 1);

        _requestRedeem(owner2, spPrime.balanceOf(owner2));

        assertEq(spPrime.pendingRedeemRequestsLength(), 2);

        _processPendingRedeems(1);

        assertEq(spPrime.pendingRedeemRequestsLength(), 1);

        _processPendingRedeems(1);

        assertEq(spPrime.pendingRedeemRequestsLength(), 0);
    }

    /**********************************************************************************************/
    /*** getPendingRedeemRequest                                                                ***/
    /**********************************************************************************************/

    function test_getPendingRedeemRequest_noRequest() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _requestDeposit(owner2, 2_000e6);  // Request 2

        _processPendingDeposits();

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));  // Request 3
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));  // Request 4

        _processPendingRedeems(1);

        // Zero ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingRedeemRequest(0);

        // Processed redeem ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingRedeemRequest(3);

        // Non-existent ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingRedeemRequest(5);

        // Suspended ID
        _suspendRedeem(4);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getPendingRedeemRequest(4);

        _unsuspendRedeem(4);

        spPrime.getPendingRedeemRequest(4);
    }

    function test_getPendingRedeemRequest() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _requestDeposit(owner2, 2_000e6);  // Request 2

        _processPendingDeposits();

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));  // Request 3
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));  // Request 4

        _assertRedeemRequest(3, owner1, recipient1, 1_000e6 - 1);
        _assertRedeemRequest(4, owner2, recipient2, 2_000e6 - 1);
    }

    function test_getPendingRedeemRequest_partialFill() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _requestDeposit(owner2, 2_000e6);  // Request 2

        _processPendingDeposits();

        uint256 sharesOfOwner1 = spPrime.balanceOf(owner1);
        _requestRedeem(owner1, recipient1, sharesOfOwner1);  // Request 3

        uint256 sharesOfOwner2 = spPrime.balanceOf(owner2);
        _requestRedeem(owner2, recipient2, sharesOfOwner2);  // Request 4

        _processPendingRedeems(sharesOfOwner1 / 4, 1);

        _assertRedeemRequest(3, owner1, recipient1, 750e6);
        _assertRedeemRequest(4, owner2, recipient2, 2_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** pendingRedeemRequests                                                                  ***/
    /**********************************************************************************************/

    function test_pendingRedeemRequests_noRequests() external view {
        assertEq(spPrime.pendingRedeemRequests().length, 0);
    }

    function test_pendingRedeemRequests() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _requestDeposit(owner2, 2_000e6);  // Request 2
        _requestDeposit(owner3, 3_000e6);  // Request 3

        _processPendingDeposits();

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));  // Request 4
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));  // Request 5
        _requestRedeem(owner3, recipient3, spPrime.balanceOf(owner3));  // Request 6

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingRedeemRequests();

        assertEq(requests.length, 3);

        _assertRedeemRequest(requests[0], 4, owner1, recipient1, 1_000e6 - 1);
        _assertRedeemRequest(requests[1], 5, owner2, recipient2, 2_000e6 - 1);
        _assertRedeemRequest(requests[2], 6, owner3, recipient3, 3_000e6 - 1);
    }

    function test_pendingRedeemRequests_someProcessed() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _requestDeposit(owner2, 2_000e6);  // Request 2
        _requestDeposit(owner3, 3_000e6);  // Request 3

        _processPendingDeposits();

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));  // Request 4
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));  // Request 5
        _requestRedeem(owner3, recipient3, spPrime.balanceOf(owner3));  // Request 6

        _processPendingRedeems(2);

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingRedeemRequests();

        assertEq(requests.length, 1);

        _assertRedeemRequest(requests[0], 6, owner3, recipient3, 3_000e6 - 1);
    }

    function test_pendingRedeemRequests_allProcessed() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);

        _processPendingDeposits();

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));

        _processPendingRedeems();

        assertEq(spPrime.pendingRedeemRequests().length, 0);
    }

    function test_pendingRedeemRequests_partialFill() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _requestDeposit(owner2, 2_000e6);  // Request 2

        _processPendingDeposits();

        uint256 primeSharesOfOwner1 = spPrime.balanceOf(owner1);
        _requestRedeem(owner1, recipient1, primeSharesOfOwner1);  // Request 3

        uint256 primeSharesOfOwner2 = spPrime.balanceOf(owner2);
        _requestRedeem(owner2, recipient2, primeSharesOfOwner2);  // Request 4

        _processPendingRedeems(primeSharesOfOwner1 / 4, type(uint256).max);

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingRedeemRequests();

        assertEq(requests.length, 2);

        _assertRedeemRequest(requests[0], 3, owner1, recipient1, 750e6);
        _assertRedeemRequest(requests[1], 4, owner2, recipient2, 2_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** getPendingRedeemRequests                                                               ***/
    /**********************************************************************************************/

    function test_getPendingRedeemRequests_startIndexTooLargeBoundary() external {
        _requestDeposit(owner1, 1_000e6);
        _processPendingDeposits();
        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));

        vm.expectRevert(ISparkPrimeVault.StartIndexTooLarge.selector);
        spPrime.getPendingRedeemRequests(2, 0);

        spPrime.getPendingRedeemRequests(1, 0);
    }

    function test_getPendingRedeemRequests_zeroLength() external view {
        assertEq(spPrime.getPendingRedeemRequests(0, 0).length, 0);
    }

    function test_getPendingRedeemRequests_range() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _requestDeposit(owner2, 2_000e6);  // Request 2
        _requestDeposit(owner3, 3_000e6);  // Request 3

        _processPendingDeposits();

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));  // Request 4
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));  // Request 5
        _requestRedeem(owner3, recipient3, spPrime.balanceOf(owner3));  // Request 6

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingRedeemRequests(0, 3);

        assertEq(requests.length, 3);

        _assertRedeemRequest(requests[0], 4, owner1, recipient1, 1_000e6 - 1);
        _assertRedeemRequest(requests[1], 5, owner2, recipient2, 2_000e6 - 1);
        _assertRedeemRequest(requests[2], 6, owner3, recipient3, 3_000e6 - 1);

        requests = spPrime.getPendingRedeemRequests(1, 2);

        assertEq(requests.length, 2);

        _assertRedeemRequest(requests[0], 5, owner2, recipient2, 2_000e6 - 1);
        _assertRedeemRequest(requests[1], 6, owner3, recipient3, 3_000e6 - 1);
    }

    function test_getPendingRedeemRequests_clamping() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);

        _processPendingDeposits();

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));

        assertEq(spPrime.getPendingRedeemRequests(0, 3).length, 2);
    }

}

contract SuspendedRedeemRequestTests is GettersTestBase {

    /**********************************************************************************************/
    /*** suspendedRedeemRequestsLength                                                          ***/
    /**********************************************************************************************/

    function test_suspendedRedeemRequestsLength() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _requestDeposit(owner2, 2_000e6);  // Request 2

        _processPendingDeposits();

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));  // Request 3
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));  // Request 4

        assertEq(spPrime.suspendedRedeemRequestsLength(), 0);

        _suspendRedeem(3);

        assertEq(spPrime.suspendedRedeemRequestsLength(), 1);

        _suspendRedeem(4);

        assertEq(spPrime.suspendedRedeemRequestsLength(), 2);

        _unsuspendRedeem(3);

        assertEq(spPrime.suspendedRedeemRequestsLength(), 1);

        _unsuspendRedeem(4);

        assertEq(spPrime.suspendedRedeemRequestsLength(), 0);
    }

    /**********************************************************************************************/
    /*** getSuspendedRedeemRequest                                                              ***/
    /**********************************************************************************************/

    function test_getSuspendedRedeemRequest_noRequest() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _requestDeposit(owner2, 2_000e6);  // Request 2

        _processPendingDeposits();

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));  // Request 3
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));  // Request 4

        _suspendRedeem(3);

        // Zero ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getSuspendedRedeemRequest(0);

        // Pending (not suspended) ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getSuspendedRedeemRequest(4);

        // Non-existent ID
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getSuspendedRedeemRequest(5);

        spPrime.getSuspendedRedeemRequest(3);

        // Unsuspended ID
        _unsuspendRedeem(3);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        spPrime.getSuspendedRedeemRequest(3);
    }

    function test_getSuspendedRedeemRequest() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _requestDeposit(owner2, 2_000e6);  // Request 2

        _processPendingDeposits();

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));  // Request 3
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));  // Request 4

        _suspendRedeem(3);
        _suspendRedeem(4);

        _assertSuspendedRedeemRequest(3, owner1, recipient1, 1_000e6 - 1);
        _assertSuspendedRedeemRequest(4, owner2, recipient2, 2_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** suspendedRedeemRequests                                                                ***/
    /**********************************************************************************************/

    function test_suspendedRedeemRequests_noRequests() external view {
        assertEq(spPrime.suspendedRedeemRequests().length, 0);
    }

    function test_suspendedRedeemRequests() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _requestDeposit(owner2, 2_000e6);  // Request 2
        _requestDeposit(owner3, 3_000e6);  // Request 3

        _processPendingDeposits();

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));  // Request 4
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));  // Request 5
        _requestRedeem(owner3, recipient3, spPrime.balanceOf(owner3));  // Request 6

        _suspendRedeem(6);
        _suspendRedeem(4);

        ISparkPrimeVault.Request[] memory requests = spPrime.suspendedRedeemRequests();

        assertEq(requests.length, 2);

        _assertRedeemRequest(requests[0], 6, owner3, recipient3, 3_000e6 - 1);
        _assertRedeemRequest(requests[1], 4, owner1, recipient1, 1_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** getSuspendedRedeemRequests                                                             ***/
    /**********************************************************************************************/

    function test_getSuspendedRedeemRequests_startIndexTooLargeBoundary() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _processPendingDeposits();
        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));  // Request 2

        _suspendRedeem(2);

        vm.expectRevert(ISparkPrimeVault.StartIndexTooLarge.selector);
        spPrime.getSuspendedRedeemRequests(2, 0);

        spPrime.getSuspendedRedeemRequests(1, 0);
    }

    function test_getSuspendedRedeemRequests_zeroLength() external view {
        assertEq(spPrime.getSuspendedRedeemRequests(0, 0).length, 0);
    }

    function test_getSuspendedRedeemRequests_range() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _requestDeposit(owner2, 2_000e6);  // Request 2
        _requestDeposit(owner3, 3_000e6);  // Request 3

        _processPendingDeposits();

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));  // Request 4
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));  // Request 5
        _requestRedeem(owner3, recipient3, spPrime.balanceOf(owner3));  // Request 6

        _suspendRedeem(4);
        _suspendRedeem(5);
        _suspendRedeem(6);

        ISparkPrimeVault.Request[] memory requests = spPrime.getSuspendedRedeemRequests(0, 3);

        assertEq(requests.length, 3);

        _assertRedeemRequest(requests[0], 4, owner1, recipient1, 1_000e6 - 1);
        _assertRedeemRequest(requests[1], 5, owner2, recipient2, 2_000e6 - 1);
        _assertRedeemRequest(requests[2], 6, owner3, recipient3, 3_000e6 - 1);

        requests = spPrime.getSuspendedRedeemRequests(1, 2);

        assertEq(requests.length, 2);

        _assertRedeemRequest(requests[0], 5, owner2, recipient2, 2_000e6 - 1);
        _assertRedeemRequest(requests[1], 6, owner3, recipient3, 3_000e6 - 1);
    }

    function test_getSuspendedRedeemRequests_clamping() external {
        _requestDeposit(owner1, 1_000e6);  // Request 1
        _requestDeposit(owner2, 2_000e6);  // Request 2

        _processPendingDeposits();

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));  // Request 3
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));  // Request 4

        _suspendRedeem(3);
        _suspendRedeem(4);

        assertEq(spPrime.getSuspendedRedeemRequests(0, 3).length, 2);
    }

}

contract SupportsInterfaceTests is GettersTestBase {

    function test_supportsInterface_unsupportedInterface() external view {
        assertEq(spPrime.supportsInterface(0x00000000), false);
        assertEq(spPrime.supportsInterface(0xffffffff), false);
    }

    function test_supportsInterface() external view {
        assertEq(spPrime.supportsInterface(type(IAccessControl).interfaceId),           true);
        assertEq(spPrime.supportsInterface(type(IAccessControlEnumerable).interfaceId), true);
        assertEq(spPrime.supportsInterface(type(IERC165).interfaceId),                  true);
        assertEq(spPrime.supportsInterface(type(ISparkPrimeVault).interfaceId),         true);
    }

}
