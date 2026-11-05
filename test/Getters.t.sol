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

    function setUp() public override {
        super.setUp();

        _setCapacity(0);
    }

    /**********************************************************************************************/
    /*** pendingDepositRequestsLength                                                           ***/
    /**********************************************************************************************/

    function test_pendingDepositRequestsLength() external {
        assertEq(spPrime.pendingDepositRequestsLength(), 0);

        _requestDeposit(owner1, recipient1, 1_000e6);

        assertEq(spPrime.pendingDepositRequestsLength(), 1);

        _requestDeposit(owner1, recipient1, 1_000e6);

        assertEq(spPrime.pendingDepositRequestsLength(), 2);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(type(uint256).max, 1);

        assertEq(spPrime.pendingDepositRequestsLength(), 1);

        _processPendingDeposits(type(uint256).max, 1);

        assertEq(spPrime.pendingDepositRequestsLength(), 0);
    }

    /**********************************************************************************************/
    /*** getPendingDepositRequest                                                               ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequest_idBeforeFirstPendingBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(1);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingDepositRequest(0);

        spPrime.getPendingDepositRequest(1);
    }

    function test_getPendingDepositRequest_idAfterQueueBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingDepositRequest(1);

        spPrime.getPendingDepositRequest(0);
    }

    function test_getPendingDepositRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _assertDepositRequest(0, owner1, recipient1, 1_000e6 - 1);
        _assertDepositRequest(1, owner2, recipient2, 2_000e6 - 1);
    }

    function test_getPendingDepositRequest_partialFill() external {
        _requestDeposit(owner1, recipient1, 1_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(spUSDC.convertToShares(1_000e6) / 4, 1);

        _assertDepositRequest(0, owner1, recipient1, 750e6 - 1);
    }

    /**********************************************************************************************/
    /*** pendingDepositRequests                                                                 ***/
    /**********************************************************************************************/

    function test_pendingDepositRequests_noRequests() external view {
        assertEq(spPrime.pendingDepositRequests().length, 0);
    }

    function test_pendingDepositRequests() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        _requestDeposit(owner3, recipient3, 3_000e6);

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositRequests();

        assertEq(requests.length, 3);

        _assertDepositRequest(requests[0], owner1, recipient1, 1_000e6 - 1);
        _assertDepositRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
        _assertDepositRequest(requests[2], owner3, recipient3, 3_000e6 - 1);
    }

    function test_pendingDepositRequests_someProcessed() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        _requestDeposit(owner3, recipient3, 3_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(type(uint256).max, 2);

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositRequests();

        assertEq(requests.length, 1);

        _assertDepositRequest(requests[0], owner3, recipient3, 3_000e6 - 1);
    }

    function test_pendingDepositRequests_allProcessed() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(type(uint256).max, type(uint256).max);

        assertEq(spPrime.pendingDepositRequests().length, 0);
    }

    function test_pendingDepositRequests_partialFill() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(spUSDC.convertToShares(1_000e6) / 4, type(uint256).max);

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositRequests();

        assertEq(requests.length, 2);

        _assertDepositRequest(requests[0], owner1, recipient1, 750e6 - 1);
        _assertDepositRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
    }

    function test_pendingDepositRequests_cancelledRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        _requestDeposit(owner3, recipient3, 3_000e6);

        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositRequests();

        assertEq(requests.length, 3);

        _assertDepositRequest(requests[0], owner1, recipient1, 1_000e6 - 1);
        _assertEmptyRequest(requests[1]);
        _assertDepositRequest(requests[2], owner3, recipient3, 3_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** getPendingDepositRequests                                                              ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequests_startIdTooSmallBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(type(uint256).max, 1);

        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        spPrime.getPendingDepositRequests(0, 1);

        spPrime.getPendingDepositRequests(1, 1);
    }

    function test_getPendingDepositRequests_startIdTooLargeBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);

        vm.expectRevert(ISparkPrimeVault.StartIdTooLarge.selector);
        spPrime.getPendingDepositRequests(2, 0);

        spPrime.getPendingDepositRequests(1, 0);
    }

    function test_getPendingDepositRequests_zeroLength() external view {
        assertEq(spPrime.getPendingDepositRequests(0, 0).length, 0);
    }

    function test_getPendingDepositRequests_range() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        _requestDeposit(owner3, recipient3, 3_000e6);

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests(0, 3);

        assertEq(requests.length, 3);

        _assertDepositRequest(requests[0], owner1, recipient1, 1_000e6 - 1);
        _assertDepositRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
        _assertDepositRequest(requests[2], owner3, recipient3, 3_000e6 - 1);

        requests = spPrime.getPendingDepositRequests(1, 2);

        assertEq(requests.length, 2);

        _assertDepositRequest(requests[0], owner2, recipient2, 2_000e6 - 1);
        _assertDepositRequest(requests[1], owner3, recipient3, 3_000e6 - 1);
    }

    function test_getPendingDepositRequests_clamping() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        assertEq(spPrime.getPendingDepositRequests(0, 3).length, 2);
    }

}

contract PendingDepositCancellationRequestTests is GettersTestBase {

    function setUp() public override {
        super.setUp();

        _setCapacity(0);
    }

    /**********************************************************************************************/
    /*** pendingDepositCancellationRequestsLength                                               ***/
    /**********************************************************************************************/

    function test_pendingDepositCancellationRequestsLength() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        assertEq(spPrime.pendingDepositCancellationRequestsLength(), 0);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));

        assertEq(spPrime.pendingDepositCancellationRequestsLength(), 1);

        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        assertEq(spPrime.pendingDepositCancellationRequestsLength(), 2);

        _processPendingDepositCancellations(type(uint256).max, 1);

        assertEq(spPrime.pendingDepositCancellationRequestsLength(), 1);

        _processPendingDepositCancellations(type(uint256).max, 1);

        assertEq(spPrime.pendingDepositCancellationRequestsLength(), 0);
    }

    /**********************************************************************************************/
    /*** getPendingDepositCancellationRequest                                                   ***/
    /**********************************************************************************************/

    function test_getPendingDepositCancellationRequest_idBeforeFirstPendingBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        _setCapacity(VAULT_CAPACITY);
        _processPendingDepositCancellations(type(uint256).max, 1);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingDepositCancellationRequest(0);

        spPrime.getPendingDepositCancellationRequest(1);
    }

    function test_getPendingDepositCancellationRequest_idAfterQueueBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingDepositCancellationRequest(1);

        spPrime.getPendingDepositCancellationRequest(0);
    }

    function test_getPendingDepositCancellationRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        _assertDepositCancellationRequest(0, owner1, recipient1, 1_000e6 - 1);
        _assertDepositCancellationRequest(1, owner2, recipient2, 2_000e6 - 1);
    }

    function test_getPendingDepositCancellationRequest_partialFill() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        _setCapacity(VAULT_CAPACITY);

        _processPendingDepositCancellations(
            spUSDC.convertToShares(1_000e6) + spUSDC.convertToShares(2_000e6) / 4,
            2
        );

        _assertDepositCancellationRequest(1, owner2, recipient2, 1_500e6);
    }

    /**********************************************************************************************/
    /*** pendingDepositCancellationRequests                                                     ***/
    /**********************************************************************************************/

    function test_pendingDepositCancellationRequests_noRequests() external view {
        assertEq(spPrime.pendingDepositCancellationRequests().length, 0);
    }

    function test_pendingDepositCancellationRequests() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        _requestDeposit(owner3, recipient3, 3_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));
        _requestDepositCancellation(owner3, 2, recipient3, spUSDC.convertToShares(3_000e6));

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositCancellationRequests();

        assertEq(requests.length, 3);

        _assertDepositCancellationRequest(requests[0], owner1, recipient1, 1_000e6 - 1);
        _assertDepositCancellationRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
        _assertDepositCancellationRequest(requests[2], owner3, recipient3, 3_000e6 - 1);
    }

    function test_pendingDepositCancellationRequests_someProcessed() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        _requestDeposit(owner3, recipient3, 3_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));
        _requestDepositCancellation(owner3, 2, recipient3, spUSDC.convertToShares(3_000e6));

        _setCapacity(VAULT_CAPACITY);
        _processPendingDepositCancellations(type(uint256).max, 2);

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositCancellationRequests();

        assertEq(requests.length, 1);

        _assertDepositCancellationRequest(requests[0], owner3, recipient3, 3_000e6 - 1);
    }

    function test_pendingDepositCancellationRequests_allProcessed() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        _setCapacity(VAULT_CAPACITY);
        _processPendingDepositCancellations(type(uint256).max, 2);

        assertEq(spPrime.pendingDepositCancellationRequests().length, 0);
    }

    function test_pendingDepositCancellationRequests_partialFill() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        _setCapacity(VAULT_CAPACITY);
        _processPendingDepositCancellations(spUSDC.convertToShares(1_000e6) / 4, 1);

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingDepositCancellationRequests();

        assertEq(requests.length, 2);

        _assertDepositCancellationRequest(requests[0], owner1, recipient1, 750e6 - 1);
        _assertDepositCancellationRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** getPendingDepositCancellationRequests                                                  ***/
    /**********************************************************************************************/

    function test_getPendingDepositCancellationRequests_startIdTooSmallBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        _setCapacity(VAULT_CAPACITY);
        _processPendingDepositCancellations(type(uint256).max, 1);

        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        spPrime.getPendingDepositCancellationRequests(0, 1);

        spPrime.getPendingDepositCancellationRequests(1, 1);
    }

    function test_getPendingDepositCancellationRequests_startIdTooLargeBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));

        vm.expectRevert(ISparkPrimeVault.StartIdTooLarge.selector);
        spPrime.getPendingDepositCancellationRequests(2, 0);

        spPrime.getPendingDepositCancellationRequests(1, 0);
    }

    function test_getPendingDepositCancellationRequests_zeroLength() external view {
        assertEq(spPrime.getPendingDepositCancellationRequests(0, 0).length, 0);
    }

    function test_getPendingDepositCancellationRequests_range() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        _requestDeposit(owner3, recipient3, 3_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));
        _requestDepositCancellation(owner3, 2, recipient3, spUSDC.convertToShares(3_000e6));

        ISparkPrimeVault.Request[] memory requests
            = spPrime.getPendingDepositCancellationRequests(0, 3);

        assertEq(requests.length, 3);

        _assertDepositCancellationRequest(requests[0], owner1, recipient1, 1_000e6 - 1);
        _assertDepositCancellationRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
        _assertDepositCancellationRequest(requests[2], owner3, recipient3, 3_000e6 - 1);

        requests = spPrime.getPendingDepositCancellationRequests(1, 2);

        assertEq(requests.length, 2);

        _assertDepositCancellationRequest(requests[0], owner2, recipient2, 2_000e6 - 1);
        _assertDepositCancellationRequest(requests[1], owner3, recipient3, 3_000e6 - 1);
    }

    function test_getPendingDepositCancellationRequests_clamping() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        assertEq(spPrime.getPendingDepositCancellationRequests(0, 3).length, 2);
    }

}

contract PendingRedeemRequestTests is GettersTestBase {

    /**********************************************************************************************/
    /*** pendingRedeemRequestsLength                                                            ***/
    /**********************************************************************************************/

    function test_pendingRedeemRequestsLength() external {
        _setCapacity(VAULT_CAPACITY);

        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);

        assertEq(spPrime.pendingRedeemRequestsLength(), 0);

        _requestRedeem(owner1, spPrime.balanceOf(owner1));

        assertEq(spPrime.pendingRedeemRequestsLength(), 1);

        _requestRedeem(owner2, spPrime.balanceOf(owner2));

        assertEq(spPrime.pendingRedeemRequestsLength(), 2);

        _processPendingRedeems(type(uint256).max, 1);

        assertEq(spPrime.pendingRedeemRequestsLength(), 1);

        _processPendingRedeems(type(uint256).max, 1);

        assertEq(spPrime.pendingRedeemRequestsLength(), 0);
    }

    /**********************************************************************************************/
    /*** getPendingRedeemRequest                                                                ***/
    /**********************************************************************************************/

    function test_getPendingRedeemRequest_idBeforeFirstPendingBoundary() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));

        _processPendingRedeems(type(uint256).max, 1);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingRedeemRequest(0);

        spPrime.getPendingRedeemRequest(1);
    }

    function test_getPendingRedeemRequest_idAfterQueueBoundary() external {
        _requestDeposit(owner1, 1_000e6);
        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingRedeemRequest(1);

        spPrime.getPendingRedeemRequest(0);
    }

    function test_getPendingRedeemRequest() external {
        _requestDeposit(owner1, 1_000e6);
        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));

        _requestDeposit(owner2, 2_000e6);
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));

        _assertRedeemRequest(0, owner1, recipient1, 1_000e6 - 1);
        _assertRedeemRequest(1, owner2, recipient2, 2_000e6 - 1);
    }

    function test_getPendingRedeemRequest_partialFill() external {
        _requestDeposit(owner1, 1_000e6);
        uint256 sharesOfOwner1 = spPrime.balanceOf(owner1);
        _requestRedeem(owner1, recipient1, sharesOfOwner1);

        _requestDeposit(owner2, 2_000e6);
        uint256 sharesOfOwner2 = spPrime.balanceOf(owner2);
        _requestRedeem(owner2, recipient2, sharesOfOwner2);

        _processPendingRedeems(sharesOfOwner1 / 4, 1);

        _assertRedeemRequest(0, owner1, recipient1, 750e6);
        _assertRedeemRequest(1, owner2, recipient2, 2_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** pendingRedeemRequests                                                                  ***/
    /**********************************************************************************************/

    function test_pendingRedeemRequests_noRequests() external view {
        assertEq(spPrime.pendingRedeemRequests().length, 0);
    }

    function test_pendingRedeemRequests() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);
        _requestDeposit(owner3, 3_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));
        _requestRedeem(owner3, recipient3, spPrime.balanceOf(owner3));

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingRedeemRequests();

        assertEq(requests.length, 3);

        _assertRedeemRequest(requests[0], owner1, recipient1, 1_000e6 - 1);
        _assertRedeemRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
        _assertRedeemRequest(requests[2], owner3, recipient3, 3_000e6 - 1);
    }

    function test_pendingRedeemRequests_someProcessed() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);
        _requestDeposit(owner3, 3_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));
        _requestRedeem(owner3, recipient3, spPrime.balanceOf(owner3));

        _processPendingRedeems(type(uint256).max, 2);

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingRedeemRequests();

        assertEq(requests.length, 1);

        _assertRedeemRequest(requests[0], owner3, recipient3, 3_000e6 - 1);
    }

    function test_pendingRedeemRequests_allProcessed() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));

        _processPendingRedeems(type(uint256).max, type(uint256).max);

        assertEq(spPrime.pendingRedeemRequests().length, 0);
    }

    function test_pendingRedeemRequests_partialFill() external {
        _requestDeposit(owner1, 1_000e6);
        uint256 owner1SpPrimeShares = spPrime.balanceOf(owner1);
        _requestRedeem(owner1, recipient1, owner1SpPrimeShares);

        _requestDeposit(owner2, 2_000e6);
        uint256 owner2SpPrimeShares = spPrime.balanceOf(owner2);
        _requestRedeem(owner2, recipient2, owner2SpPrimeShares);

        _processPendingRedeems(owner1SpPrimeShares / 4, type(uint256).max);

        ISparkPrimeVault.Request[] memory requests = spPrime.pendingRedeemRequests();

        assertEq(requests.length, 2);

        _assertRedeemRequest(requests[0], owner1, recipient1, 750e6);
        _assertRedeemRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** getPendingRedeemRequests                                                               ***/
    /**********************************************************************************************/

    function test_getPendingRedeemRequests_startIdTooSmallBoundary() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));

        _processPendingRedeems(type(uint256).max, 1);

        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        spPrime.getPendingRedeemRequests(0, 1);

        spPrime.getPendingRedeemRequests(1, 1);
    }

    function test_getPendingRedeemRequests_startIdTooLargeBoundary() external {
        _requestDeposit(owner1, 1_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));

        vm.expectRevert(ISparkPrimeVault.StartIdTooLarge.selector);
        spPrime.getPendingRedeemRequests(2, 0);

        spPrime.getPendingRedeemRequests(1, 0);
    }

    function test_getPendingRedeemRequests_zeroLength() external view {
        assertEq(spPrime.getPendingRedeemRequests(0, 0).length, 0);
    }

    function test_getPendingRedeemRequests_range() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);
        _requestDeposit(owner3, 3_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));
        _requestRedeem(owner3, recipient3, spPrime.balanceOf(owner3));

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingRedeemRequests(0, 3);

        assertEq(requests.length, 3);

        _assertRedeemRequest(requests[0], owner1, recipient1, 1_000e6 - 1);
        _assertRedeemRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
        _assertRedeemRequest(requests[2], owner3, recipient3, 3_000e6 - 1);

        requests = spPrime.getPendingRedeemRequests(1, 2);

        assertEq(requests.length, 2);

        _assertRedeemRequest(requests[0], owner2, recipient2, 2_000e6 - 1);
        _assertRedeemRequest(requests[1], owner3, recipient3, 3_000e6 - 1);
    }

    function test_getPendingRedeemRequests_clamping() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));

        assertEq(spPrime.getPendingRedeemRequests(0, 3).length, 2);
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
