// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

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

contract GetPendingDepositRequestTests is GettersTestBase {

    function setUp() public override {
        super.setUp();

        _setCapacity(0);
    }

    /**********************************************************************************************/
    /*** getPendingDepositRequest                                                               ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequest_noRequests() external {
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingDepositRequest(0);
    }

    function test_getPendingDepositRequest_idOutOfBoundsBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingDepositRequest(1);

        _assertDepositRequest(0, owner1, recipient1, 1_000e6 - 1);
    }

    function test_getPendingDepositRequest_idBeforeFirstPendingBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(type(uint256).max, 1);

        assertEq(spPrime.firstPendingDepositId(), 1);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingDepositRequest(0);

        _assertDepositRequest(1, owner2, recipient2, 2_000e6 - 1);
    }

    function test_getPendingDepositRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _assertDepositRequest(0, owner1, recipient1, 1_000e6 - 1);
        _assertDepositRequest(1, owner2, recipient2, 2_000e6 - 1);
    }

    function test_getPendingDepositRequest_partialFill() external {
        uint256 shares = spUSDC.convertToShares(1_000e6);
        assertEq(shares, 964.193241e6);

        _requestDeposit(owner1, recipient1, 1_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(shares / 4, 1);

        assertEq(spPrime.firstPendingDepositId(), 0);

        _assertDepositRequest(0, owner1, recipient1, 750e6 - 1);
    }

    function test_getPendingDepositRequest_cancelled() external {
        _requestDeposit(owner1, recipient1, 1_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));

        _assertDepositRequest(0, address(0), address(0), 0);
    }

    /**********************************************************************************************/
    /*** getPendingDepositRequests()                                                            ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequests_noRequests() external view {
        assertEq(spPrime.getPendingDepositRequests().length, 0);
    }

    function test_getPendingDepositRequests() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        _requestDeposit(owner3, recipient3, 3_000e6);

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests();

        assertEq(requests.length, 3);

        _assertDepositRequest(requests[0], owner1, recipient1, 1_000e6 - 1);
        _assertDepositRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
        _assertDepositRequest(requests[2], owner3, recipient3, 3_000e6 - 1);
    }

    function test_getPendingDepositRequests_someProcessed() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        _requestDeposit(owner3, recipient3, 3_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(type(uint256).max, 2);

        assertEq(spPrime.firstPendingDepositId(), 2);

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests();

        assertEq(requests.length, 1);

        _assertDepositRequest(requests[0], owner3, recipient3, 3_000e6 - 1);
    }

    function test_getPendingDepositRequests_allProcessed() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(type(uint256).max, type(uint256).max);

        assertEq(spPrime.firstPendingDepositId(),            2);
        assertEq(spPrime.getPendingDepositRequests().length, 0);
    }

    function test_getPendingDepositRequests_partialFill() external {
        uint256 shares1 = spUSDC.convertToShares(1_000e6);

        assertEq(shares1, 964.193241e6);

        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(shares1 / 4, type(uint256).max);

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests();

        assertEq(requests.length, 2);

        _assertDepositRequest(requests[0], owner1, recipient1, 750e6 - 1);
        _assertDepositRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
    }

    function test_getPendingDepositRequests_cancelledRequest() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        _requestDeposit(owner3, recipient3, 3_000e6);

        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests();

        assertEq(requests.length, 3);

        _assertDepositRequest(requests[0], owner1, recipient1, 1_000e6 - 1);
        _assertEmptyRequest(requests[1]);
        _assertDepositRequest(requests[2], owner3, recipient3, 3_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** getPendingDepositRequests(startId, length)                                             ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequests_zeroLength() external {
        vm.expectRevert(ISparkPrimeVault.ZeroLength.selector);
        spPrime.getPendingDepositRequests(0, 0);
    }

    function test_getPendingDepositRequests_startIdTooSmallBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(type(uint256).max, 1);

        assertEq(spPrime.firstPendingDepositId(), 1);

        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        spPrime.getPendingDepositRequests(0, 1);

        spPrime.getPendingDepositRequests(1, 1);
    }

    function test_getPendingDepositRequests_lengthTooLargeBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        spPrime.getPendingDepositRequests(0, 3);

        spPrime.getPendingDepositRequests(0, 2);
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

}

contract GetPendingDepositCancellationRequestTests is GettersTestBase {

    function setUp() public override {
        super.setUp();

        _setCapacity(0);
    }

    /**********************************************************************************************/
    /*** getPendingDepositCancellationRequest                                                   ***/
    /**********************************************************************************************/

    function test_getPendingDepositCancellationRequest_noRequests() external {
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingDepositCancellationRequest(0);
    }

    function test_getPendingDepositCancellationRequest_idOutOfBoundsBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingDepositCancellationRequest(1);

        spPrime.getPendingDepositCancellationRequest(0);
    }

    function test_getPendingDepositCancellationRequest_idBeforeFirstPendingBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        _setCapacity(VAULT_CAPACITY);
        _processPendingDepositCancellations(type(uint256).max, 1);

        assertEq(spPrime.firstPendingDepositCancellationId(), 1);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingDepositCancellationRequest(0);

        spPrime.getPendingDepositCancellationRequest(1);
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

        assertEq(spPrime.firstPendingDepositCancellationId(), 1);

        _assertDepositCancellationRequest(1, owner2, recipient2, 1_500e6);
    }

    /**********************************************************************************************/
    /*** getPendingDepositCancellationRequests()                                                ***/
    /**********************************************************************************************/

    function test_getPendingDepositCancellationRequests_noRequests() external view {
        assertEq(spPrime.getPendingDepositCancellationRequests().length, 0);
    }

    function test_getPendingDepositCancellationRequests() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        _requestDeposit(owner3, recipient3, 3_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));
        _requestDepositCancellation(owner3, 2, recipient3, spUSDC.convertToShares(3_000e6));

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositCancellationRequests();

        assertEq(requests.length, 3);

        _assertDepositCancellationRequest(requests[0], owner1, recipient1, 1_000e6 - 1);
        _assertDepositCancellationRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
        _assertDepositCancellationRequest(requests[2], owner3, recipient3, 3_000e6 - 1);
    }

    function test_getPendingDepositCancellationRequests_someProcessed() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        _requestDeposit(owner3, recipient3, 3_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));
        _requestDepositCancellation(owner3, 2, recipient3, spUSDC.convertToShares(3_000e6));

        _setCapacity(VAULT_CAPACITY);
        _processPendingDepositCancellations(type(uint256).max, 2);

        assertEq(spPrime.firstPendingDepositCancellationId(), 2);

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositCancellationRequests();

        assertEq(requests.length, 1);

        _assertDepositCancellationRequest(requests[0], owner3, recipient3, 3_000e6 - 1);
    }

    function test_getPendingDepositCancellationRequests_allProcessed() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        _setCapacity(VAULT_CAPACITY);
        _processPendingDepositCancellations(type(uint256).max, 2);

        assertEq(spPrime.firstPendingDepositCancellationId(), 2);

        assertEq(spPrime.getPendingDepositCancellationRequests().length, 0);
    }

    function test_getPendingDepositCancellationRequests_partialFill() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        _setCapacity(VAULT_CAPACITY);
        _processPendingDepositCancellations(spUSDC.convertToShares(1_000e6) / 4, 1);

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositCancellationRequests();

        assertEq(requests.length, 2);

        _assertDepositCancellationRequest(requests[0], owner1, recipient1, 750e6 - 1);
        _assertDepositCancellationRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** getPendingDepositCancellationRequests(startId, length)                                 ***/
    /**********************************************************************************************/

    function test_getPendingDepositCancellationRequests_zeroLength() external {
        vm.expectRevert(ISparkPrimeVault.ZeroLength.selector);
        spPrime.getPendingDepositCancellationRequests(0, 0);
    }

    function test_getPendingDepositCancellationRequests_startIdTooSmallBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        assertEq(spPrime.firstPendingDepositCancellationId(), 0);

        _setCapacity(VAULT_CAPACITY);
        _processPendingDepositCancellations(type(uint256).max, 1);

        assertEq(spPrime.firstPendingDepositCancellationId(), 1);

        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        spPrime.getPendingDepositCancellationRequests(0, 1);

        spPrime.getPendingDepositCancellationRequests(1, 1);
    }

    function test_getPendingDepositCancellationRequests_lengthTooLargeBoundary() external {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _requestDepositCancellation(owner1, 0, recipient1, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(owner2, 1, recipient2, spUSDC.convertToShares(2_000e6));

        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        spPrime.getPendingDepositCancellationRequests(0, 3);

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositCancellationRequests(0, 2);

        assertEq(requests.length, 2);

        _assertDepositCancellationRequest(requests[0], owner1, recipient1, 1_000e6 - 1);
        _assertDepositCancellationRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
    }

    function test_getPendingDepositCancellationRequestsRange() external {
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

}

contract GetPendingRedeemRequestTests is GettersTestBase {

    /**********************************************************************************************/
    /*** getPendingRedeemRequest                                                                ***/
    /**********************************************************************************************/

    function test_getPendingRedeemRequest_noRequests() external {
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingRedeemRequest(0);
    }

    function test_getPendingRedeemRequest_idOutOfBoundsBoundary() external {
        _requestDeposit(owner1, 1_000e6);
        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingRedeemRequest(1);

        spPrime.getPendingRedeemRequest(0);
    }

    function test_getPendingRedeemRequest_idBeforeFirstPendingBoundary() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));

        _processPendingRedeems(type(uint256).max, 1);

        assertEq(spPrime.firstPendingRedeemId(), 1);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingRedeemRequest(0);

        spPrime.getPendingRedeemRequest(1);
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
        uint256 owner1SpPrimeShares = spPrime.balanceOf(owner1);
        _requestRedeem(owner1, recipient1, owner1SpPrimeShares);

        _requestDeposit(owner2, 2_000e6);
        uint256 owner2SpPrimeShares = spPrime.balanceOf(owner2);
        _requestRedeem(owner2, recipient2, owner2SpPrimeShares);

        _processPendingRedeems(owner1SpPrimeShares + owner2SpPrimeShares / 4, 2);

        assertEq(spPrime.firstPendingRedeemId(), 1);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingRedeemRequest(0);

        _assertRedeemRequest(1, owner2, recipient2, 1_500e6);
    }

    /**********************************************************************************************/
    /*** getPendingRedeemRequests()                                                             ***/
    /**********************************************************************************************/

    function test_getPendingRedeemRequests_noRequests() external view {
        assertEq(spPrime.getPendingRedeemRequests().length, 0);
    }

    function test_getPendingRedeemRequests() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);
        _requestDeposit(owner3, 3_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));
        _requestRedeem(owner3, recipient3, spPrime.balanceOf(owner3));

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingRedeemRequests();

        assertEq(requests.length, 3);

        _assertRedeemRequest(requests[0], owner1, recipient1, 1_000e6 - 1);
        _assertRedeemRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
        _assertRedeemRequest(requests[2], owner3, recipient3, 3_000e6 - 1);
    }

    function test_getPendingRedeemRequests_someProcessed() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);
        _requestDeposit(owner3, 3_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));
        _requestRedeem(owner3, recipient3, spPrime.balanceOf(owner3));

        _processPendingRedeems(type(uint256).max, 2);

        assertEq(spPrime.firstPendingRedeemId(), 2);

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingRedeemRequests();

        assertEq(requests.length, 1);

        _assertRedeemRequest(requests[0], owner3, recipient3, 3_000e6 - 1);
    }

    function test_getPendingRedeemRequests_allProcessed() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));

        _processPendingRedeems(type(uint256).max, type(uint256).max);

        assertEq(spPrime.firstPendingRedeemId(), 2);

        assertEq(spPrime.getPendingRedeemRequests().length, 0);
    }

    function test_getPendingRedeemRequests_partialFill() external {
        _requestDeposit(owner1, 1_000e6);
        uint256 owner1SpPrimeShares = spPrime.balanceOf(owner1);
        _requestRedeem(owner1, recipient1, owner1SpPrimeShares);

        _requestDeposit(owner2, 2_000e6);
        uint256 owner2SpPrimeShares = spPrime.balanceOf(owner2);
        _requestRedeem(owner2, recipient2, owner2SpPrimeShares);

        _processPendingRedeems(owner1SpPrimeShares / 4, type(uint256).max);

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingRedeemRequests();

        assertEq(requests.length, 2);

        _assertRedeemRequest(requests[0], owner1, recipient1, 750e6);
        _assertRedeemRequest(requests[1], owner2, recipient2, 2_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** getPendingRedeemRequests(startId, length)                                              ***/
    /**********************************************************************************************/

    function test_getPendingRedeemRequests_zeroLength() external {
        vm.expectRevert(ISparkPrimeVault.ZeroLength.selector);
        spPrime.getPendingRedeemRequests(0, 0);
    }

    function test_getPendingRedeemRequests_startIdTooSmallBoundary() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));

        assertEq(spPrime.firstPendingRedeemId(), 0);

        _processPendingRedeems(type(uint256).max, 1);

        assertEq(spPrime.firstPendingRedeemId(), 1);

        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        spPrime.getPendingRedeemRequests(0, 1);

        spPrime.getPendingRedeemRequests(1, 1);
    }

    function test_getPendingRedeemRequests_lengthTooLargeBoundary() external {
        _requestDeposit(owner1, 1_000e6);
        _requestDeposit(owner2, 2_000e6);

        _requestRedeem(owner1, recipient1, spPrime.balanceOf(owner1));
        _requestRedeem(owner2, recipient2, spPrime.balanceOf(owner2));

        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        spPrime.getPendingRedeemRequests(0, 3);

        spPrime.getPendingRedeemRequests(0, 2);
    }

    function test_getPendingRedeemRequestsRange() external {
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

}
