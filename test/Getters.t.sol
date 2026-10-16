// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase, SparkPrimeVault, ISparkVaultLike } from "./TestBase.t.sol";

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

        _setCapacity(0);
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _requestDepositWithShares(address owner, address recipient, uint256 assets)
        internal
        returns (uint256 requestId, uint256 savingsShares)
    {
        deal(address(usdc), owner, assets);

        uint256 savingsSharesBefore = spUSDC.balanceOf(address(spPrime));

        vm.startPrank(owner);
        usdc.approve(address(spPrime), assets);
        requestId = spPrime.requestDeposit(assets, recipient, REFERRAL);
        vm.stopPrank();

        savingsShares = spUSDC.balanceOf(address(spPrime)) - savingsSharesBefore;
    }

    function _assertRequest(
        SparkPrimeVault.Request memory request,
        address                        owner,
        address                        recipient,
        uint256                        shares
    )
        internal pure
    {
        assertEq(request.owner,     owner);
        assertEq(request.recipient, recipient);
        assertEq(request.shares,    shares);
    }

    function _assertEmptyRequest(SparkPrimeVault.Request memory request) internal pure {
        _assertRequest(request, address(0), address(0), 0);
    }

}

contract GetPendingDepositRequestTests is GettersTestBase {

    function _processDeposits(uint256 maxSavingsShares, uint256 maxRequests) internal {
        vm.prank(admin);
        spPrime.setCapacity(VAULT_CAPACITY);

        vm.prank(processor);
        spPrime.processPendingDeposits(maxSavingsShares, maxRequests);
    }

    function _assertPendingDepositRequest(
        uint256 requestId,
        address owner,
        address recipient,
        uint256 shares
    )
        internal view
    {
        (
            address requestOwner,
            address requestRecipient,
            uint256 requestShares
        ) = spPrime.getPendingDepositRequest(requestId);

        assertEq(requestOwner,     owner);
        assertEq(requestRecipient, recipient);
        assertEq(requestShares,    shares);
    }

    /**********************************************************************************************/
    /*** getPendingDepositRequest                                                               ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequest_noRequests() public {
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        spPrime.getPendingDepositRequest(0);
    }

    function test_getPendingDepositRequest_idOutOfBoundsBoundary() public {
        ( , uint256 shares ) = _requestDepositWithShares(owner1, recipient1, 1_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        spPrime.getPendingDepositRequest(1);

        _assertPendingDepositRequest(0, owner1, recipient1, shares);
    }

    function test_getPendingDepositRequest_idBeforeFirstPendingBoundary() public {
        _requestDepositWithShares(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositWithShares(owner2, recipient2, 2_000e6);

        _processDeposits(type(uint256).max, 1);

        assertEq(spPrime.firstPendingDepositId(), 1);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        spPrime.getPendingDepositRequest(0);

        _assertPendingDepositRequest(1, owner2, recipient2, shares2);
    }

    function test_getPendingDepositRequest() public {
        ( uint256 requestId1, uint256 shares1 ) = _requestDepositWithShares(owner1, recipient1, 1_000e6);
        ( uint256 requestId2, uint256 shares2 ) = _requestDepositWithShares(owner2, recipient2, 2_000e6);

        assertEq(requestId1, 0);
        assertEq(requestId2, 1);

        _assertPendingDepositRequest(0, owner1, recipient1, shares1);
        _assertPendingDepositRequest(1, owner2, recipient2, shares2);
    }

    function test_getPendingDepositRequest_partialFill() public {
        ( , uint256 shares ) = _requestDepositWithShares(owner1, recipient1, 1_000e6);

        _processDeposits(shares / 4, 1);

        assertEq(spPrime.firstPendingDepositId(), 0);

        _assertPendingDepositRequest(0, owner1, recipient1, shares - shares / 4);
    }

    function test_getPendingDepositRequest_cancelled() public {
        _requestDepositWithShares(owner1, recipient1, 1_000e6);

        vm.prank(owner1);
        spPrime.requestDepositCancellation(0, recipient1);

        _assertPendingDepositRequest(0, address(0), address(0), 0);
    }

    /**********************************************************************************************/
    /*** getPendingDepositRequests()                                                            ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequests_noRequests() public view {
        assertEq(spPrime.getPendingDepositRequests().length, 0);
    }

    function test_getPendingDepositRequests() public {
        ( , uint256 shares1 ) = _requestDepositWithShares(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositWithShares(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestDepositWithShares(owner3, recipient3, 3_000e6);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests();

        assertEq(requests.length, 3);

        _assertRequest(requests[0], owner1, recipient1, shares1);
        _assertRequest(requests[1], owner2, recipient2, shares2);
        _assertRequest(requests[2], owner3, recipient3, shares3);
    }

    function test_getPendingDepositRequests_someProcessed() public {
        _requestDepositWithShares(owner1, recipient1, 1_000e6);
        _requestDepositWithShares(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestDepositWithShares(owner3, recipient3, 3_000e6);

        _processDeposits(type(uint256).max, 2);

        assertEq(spPrime.firstPendingDepositId(), 2);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests();

        assertEq(requests.length, 1);

        _assertRequest(requests[0], owner3, recipient3, shares3);
    }

    function test_getPendingDepositRequests_allProcessed() public {
        _requestDepositWithShares(owner1, recipient1, 1_000e6);
        _requestDepositWithShares(owner2, recipient2, 2_000e6);

        _processDeposits(type(uint256).max, type(uint256).max);

        assertEq(spPrime.firstPendingDepositId(), 2);

        assertEq(spPrime.getPendingDepositRequests().length, 0);
    }

    function test_getPendingDepositRequests_partialFill() public {
        ( , uint256 shares1 ) = _requestDepositWithShares(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositWithShares(owner2, recipient2, 2_000e6);

        _processDeposits(shares1 / 4, type(uint256).max);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests();

        assertEq(requests.length, 2);

        _assertRequest(requests[0], owner1, recipient1, shares1 - shares1 / 4);
        _assertRequest(requests[1], owner2, recipient2, shares2);
    }

    function test_getPendingDepositRequests_cancelledRequest() public {
        ( , uint256 shares1 ) = _requestDepositWithShares(owner1, recipient1, 1_000e6);
        _requestDepositWithShares(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestDepositWithShares(owner3, recipient3, 3_000e6);

        vm.prank(owner2);
        spPrime.requestDepositCancellation(1, recipient2);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests();

        assertEq(requests.length, 3);

        _assertRequest(requests[0], owner1, recipient1, shares1);
        _assertEmptyRequest(requests[1]);
        _assertRequest(requests[2], owner3, recipient3, shares3);
    }

    /**********************************************************************************************/
    /*** getPendingDepositRequests(startId, endId)                                              ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequests_startAfterEnd() public {
        _requestDepositWithShares(owner1, recipient1, 1_000e6);
        _requestDepositWithShares(owner2, recipient2, 2_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-range");
        spPrime.getPendingDepositRequests(2, 1);
    }

    function test_getPendingDepositRequests_endOutOfBoundsBoundary() public {
        _requestDepositWithShares(owner1, recipient1, 1_000e6);
        _requestDepositWithShares(owner2, recipient2, 2_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-range");
        spPrime.getPendingDepositRequests(0, 3);

        assertEq(spPrime.getPendingDepositRequests(0, 2).length, 2);
    }

    function test_getPendingDepositRequests_emptyRange() public {
        assertEq(spPrime.getPendingDepositRequests(0, 0).length, 0);

        _requestDepositWithShares(owner1, recipient1, 1_000e6);

        assertEq(spPrime.getPendingDepositRequests(0, 0).length, 0);
        assertEq(spPrime.getPendingDepositRequests(1, 1).length, 0);
    }

    function test_getPendingDepositRequestsRange() public {
        ( , uint256 shares1 ) = _requestDepositWithShares(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositWithShares(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestDepositWithShares(owner3, recipient3, 3_000e6);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests(0, 3);

        assertEq(requests.length, 3);

        _assertRequest(requests[0], owner1, recipient1, shares1);
        _assertRequest(requests[1], owner2, recipient2, shares2);
        _assertRequest(requests[2], owner3, recipient3, shares3);

        requests = spPrime.getPendingDepositRequests(1, 2);

        assertEq(requests.length, 1);

        _assertRequest(requests[0], owner2, recipient2, shares2);

        requests = spPrime.getPendingDepositRequests(1, 3);

        assertEq(requests.length, 2);

        _assertRequest(requests[0], owner2, recipient2, shares2);
        _assertRequest(requests[1], owner3, recipient3, shares3);
    }

    function test_getPendingDepositRequestsRange_includesProcessed() public {
        _requestDepositWithShares(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositWithShares(owner2, recipient2, 2_000e6);

        _processDeposits(type(uint256).max, 1);

        assertEq(spPrime.firstPendingDepositId(), 1);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests(0, 2);

        assertEq(requests.length, 2);

        _assertEmptyRequest(requests[0]);
        _assertRequest(requests[1], owner2, recipient2, shares2);
    }

}

contract GetPendingDepositCancellationRequestTests is GettersTestBase {

    function _requestDepositCancellation(address owner, address recipient, uint256 assets)
        internal
        returns (uint256 requestId, uint256 savingsShares)
    {
        uint256 depositRequestId;

        ( depositRequestId, savingsShares ) = _requestDepositWithShares(owner, owner, assets);

        vm.prank(owner);
        requestId = spPrime.requestDepositCancellation(depositRequestId, recipient);
    }

    function _processDepositCancellations(uint256 maxSavingsShares, uint256 maxRequests) internal {
        vm.prank(processor);
        spPrime.processPendingDepositCancellations(maxSavingsShares, maxRequests);
    }

    function _assertPendingDepositCancellationRequest(
        uint256 requestId,
        address owner,
        address recipient,
        uint256 shares
    )
        internal view
    {
        (
            address requestOwner,
            address requestRecipient,
            uint256 requestShares
        ) = spPrime.getPendingDepositCancellationRequest(requestId);

        assertEq(requestOwner,     owner);
        assertEq(requestRecipient, recipient);
        assertEq(requestShares,    shares);
    }

    /**********************************************************************************************/
    /*** getPendingDepositCancellationRequest                                                   ***/
    /**********************************************************************************************/

    function test_getPendingDepositCancellationRequest_noRequests() public {
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        spPrime.getPendingDepositCancellationRequest(0);
    }

    function test_getPendingDepositCancellationRequest_idOutOfBoundsBoundary() public {
        ( , uint256 shares ) = _requestDepositCancellation(owner1, recipient1, 1_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        spPrime.getPendingDepositCancellationRequest(1);

        _assertPendingDepositCancellationRequest(0, owner1, recipient1, shares);
    }

    function test_getPendingDepositCancellationRequest_idBeforeFirstPendingBoundary() public {
        _requestDepositCancellation(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositCancellation(owner2, recipient2, 2_000e6);

        _processDepositCancellations(type(uint256).max, 1);

        assertEq(spPrime.firstPendingDepositCancellationId(), 1);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        spPrime.getPendingDepositCancellationRequest(0);

        _assertPendingDepositCancellationRequest(1, owner2, recipient2, shares2);
    }

    function test_getPendingDepositCancellationRequest() public {
        ( uint256 requestId1, uint256 shares1 )
            = _requestDepositCancellation(owner1, recipient1, 1_000e6);
        ( uint256 requestId2, uint256 shares2 )
            = _requestDepositCancellation(owner2, recipient2, 2_000e6);

        assertEq(requestId1, 0);
        assertEq(requestId2, 1);

        _assertPendingDepositCancellationRequest(0, owner1, recipient1, shares1);
        _assertPendingDepositCancellationRequest(1, owner2, recipient2, shares2);
    }

    function test_getPendingDepositCancellationRequest_partialFill() public {
        ( , uint256 shares1 ) = _requestDepositCancellation(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositCancellation(owner2, recipient2, 2_000e6);

        _processDepositCancellations(shares1 + shares2 / 4, 2);

        assertEq(spPrime.firstPendingDepositCancellationId(), 1);

        _assertPendingDepositCancellationRequest(1, owner2, recipient2, shares2 - shares2 / 4);
    }

    /**********************************************************************************************/
    /*** getPendingDepositCancellationRequests()                                                ***/
    /**********************************************************************************************/

    function test_getPendingDepositCancellationRequests_noRequests() public view {
        assertEq(spPrime.getPendingDepositCancellationRequests().length, 0);
    }

    function test_getPendingDepositCancellationRequests() public {
        ( , uint256 shares1 ) = _requestDepositCancellation(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositCancellation(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestDepositCancellation(owner3, recipient3, 3_000e6);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositCancellationRequests();

        assertEq(requests.length, 3);

        _assertRequest(requests[0], owner1, recipient1, shares1);
        _assertRequest(requests[1], owner2, recipient2, shares2);
        _assertRequest(requests[2], owner3, recipient3, shares3);
    }

    function test_getPendingDepositCancellationRequests_someProcessed() public {
        _requestDepositCancellation(owner1, recipient1, 1_000e6);
        _requestDepositCancellation(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestDepositCancellation(owner3, recipient3, 3_000e6);

        _processDepositCancellations(type(uint256).max, 2);

        assertEq(spPrime.firstPendingDepositCancellationId(), 2);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositCancellationRequests();

        assertEq(requests.length, 1);

        _assertRequest(requests[0], owner3, recipient3, shares3);
    }

    function test_getPendingDepositCancellationRequests_allProcessed() public {
        _requestDepositCancellation(owner1, recipient1, 1_000e6);
        _requestDepositCancellation(owner2, recipient2, 2_000e6);

        _processDepositCancellations(type(uint256).max, 2);

        assertEq(spPrime.firstPendingDepositCancellationId(), 2);

        assertEq(spPrime.getPendingDepositCancellationRequests().length, 0);
    }

    function test_getPendingDepositCancellationRequests_partialFill() public {
        ( , uint256 shares1 ) = _requestDepositCancellation(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositCancellation(owner2, recipient2, 2_000e6);

        _processDepositCancellations(shares1 / 4, 1);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositCancellationRequests();

        assertEq(requests.length, 2);

        _assertRequest(requests[0], owner1, recipient1, shares1 - shares1 / 4);
        _assertRequest(requests[1], owner2, recipient2, shares2);
    }

    /**********************************************************************************************/
    /*** getPendingDepositCancellationRequests(startId, endId)                                  ***/
    /**********************************************************************************************/

    function test_getPendingDepositCancellationRequests_startAfterEnd() public {
        _requestDepositCancellation(owner1, recipient1, 1_000e6);
        _requestDepositCancellation(owner2, recipient2, 2_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-range");
        spPrime.getPendingDepositCancellationRequests(2, 1);
    }

    function test_getPendingDepositCancellationRequests_endOutOfBoundsBoundary() public {
        _requestDepositCancellation(owner1, recipient1, 1_000e6);
        _requestDepositCancellation(owner2, recipient2, 2_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-range");
        spPrime.getPendingDepositCancellationRequests(0, 3);

        assertEq(spPrime.getPendingDepositCancellationRequests(0, 2).length, 2);
    }

    function test_getPendingDepositCancellationRequests_emptyRange() public {
        assertEq(spPrime.getPendingDepositCancellationRequests(0, 0).length, 0);

        _requestDepositCancellation(owner1, recipient1, 1_000e6);

        assertEq(spPrime.getPendingDepositCancellationRequests(0, 0).length, 0);
        assertEq(spPrime.getPendingDepositCancellationRequests(1, 1).length, 0);
    }

    function test_getPendingDepositCancellationRequestsRange() public {
        ( , uint256 shares1 ) = _requestDepositCancellation(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositCancellation(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestDepositCancellation(owner3, recipient3, 3_000e6);

        SparkPrimeVault.Request[] memory requests
            = spPrime.getPendingDepositCancellationRequests(0, 3);

        assertEq(requests.length, 3);

        _assertRequest(requests[0], owner1, recipient1, shares1);
        _assertRequest(requests[1], owner2, recipient2, shares2);
        _assertRequest(requests[2], owner3, recipient3, shares3);

        requests = spPrime.getPendingDepositCancellationRequests(1, 2);

        assertEq(requests.length, 1);

        _assertRequest(requests[0], owner2, recipient2, shares2);

        requests = spPrime.getPendingDepositCancellationRequests(1, 3);

        assertEq(requests.length, 2);

        _assertRequest(requests[0], owner2, recipient2, shares2);
        _assertRequest(requests[1], owner3, recipient3, shares3);
    }

    function test_getPendingDepositCancellationRequests_includesProcessed() public {
        _requestDepositCancellation(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositCancellation(owner2, recipient2, 2_000e6);

        _processDepositCancellations(type(uint256).max, 1);

        assertEq(spPrime.firstPendingDepositCancellationId(), 1);

        SparkPrimeVault.Request[] memory requests
            = spPrime.getPendingDepositCancellationRequests(0, 2);

        assertEq(requests.length, 2);

        _assertEmptyRequest(requests[0]);
        _assertRequest(requests[1], owner2, recipient2, shares2);
    }

}

contract GetPendingRedeemRequestTests is GettersTestBase {

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        spPrime.setCapacity(VAULT_CAPACITY);
    }

    function _requestRedeemWithShares(address owner, address recipient, uint256 assets)
        internal
        returns (uint256 requestId, uint256 shares)
    {
        _requestDepositWithShares(owner, owner, assets);

        shares = spPrime.balanceOf(owner);

        vm.prank(owner);
        requestId = spPrime.requestRedeem(shares, recipient);
    }

    function _processRedeems(uint256 maxShares, uint256 maxRequests) internal {
        vm.prank(processor);
        spPrime.processPendingRedeems(maxShares, maxRequests);
    }

    function _assertPendingRedeemRequest(
        uint256 requestId,
        address owner,
        address recipient,
        uint256 shares
    )
        internal view
    {
        (
            address requestOwner,
            address requestRecipient,
            uint256 requestShares
        ) = spPrime.getPendingRedeemRequest(requestId);

        assertEq(requestOwner,     owner);
        assertEq(requestRecipient, recipient);
        assertEq(requestShares,    shares);
    }

    /**********************************************************************************************/
    /*** getPendingRedeemRequest                                                                ***/
    /**********************************************************************************************/

    function test_getPendingRedeemRequest_noRequests() public {
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        spPrime.getPendingRedeemRequest(0);
    }

    function test_getPendingRedeemRequest_idOutOfBoundsBoundary() public {
        ( , uint256 shares ) = _requestRedeemWithShares(owner1, recipient1, 1_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        spPrime.getPendingRedeemRequest(1);

        _assertPendingRedeemRequest(0, owner1, recipient1, shares);
    }

    function test_getPendingRedeemRequest_idBeforeFirstPendingBoundary() public {
        _requestRedeemWithShares(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestRedeemWithShares(owner2, recipient2, 2_000e6);

        _processRedeems(type(uint256).max, 1);

        assertEq(spPrime.firstPendingRedeemId(), 1);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        spPrime.getPendingRedeemRequest(0);

        _assertPendingRedeemRequest(1, owner2, recipient2, shares2);
    }

    function test_getPendingRedeemRequest() public {
        ( uint256 requestId1, uint256 shares1 ) = _requestRedeemWithShares(owner1, recipient1, 1_000e6);
        ( uint256 requestId2, uint256 shares2 ) = _requestRedeemWithShares(owner2, recipient2, 2_000e6);

        assertEq(requestId1, 0);
        assertEq(requestId2, 1);

        _assertPendingRedeemRequest(0, owner1, recipient1, shares1);
        _assertPendingRedeemRequest(1, owner2, recipient2, shares2);
    }

    function test_getPendingRedeemRequest_partialFill() public {
        ( , uint256 shares1 ) = _requestRedeemWithShares(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestRedeemWithShares(owner2, recipient2, 2_000e6);

        _processRedeems(shares1 + shares2 / 4, 2);

        assertEq(spPrime.firstPendingRedeemId(), 1);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        spPrime.getPendingRedeemRequest(0);

        _assertPendingRedeemRequest(1, owner2, recipient2, shares2 - shares2 / 4);
    }

    /**********************************************************************************************/
    /*** getPendingRedeemRequests()                                                             ***/
    /**********************************************************************************************/

    function test_getPendingRedeemRequests_noRequests() public view {
        assertEq(spPrime.getPendingRedeemRequests().length, 0);
    }

    function test_getPendingRedeemRequests() public {
        ( , uint256 shares1 ) = _requestRedeemWithShares(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestRedeemWithShares(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestRedeemWithShares(owner3, recipient3, 3_000e6);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingRedeemRequests();

        assertEq(requests.length, 3);

        _assertRequest(requests[0], owner1, recipient1, shares1);
        _assertRequest(requests[1], owner2, recipient2, shares2);
        _assertRequest(requests[2], owner3, recipient3, shares3);
    }

    function test_getPendingRedeemRequests_someProcessed() public {
        _requestRedeemWithShares(owner1, recipient1, 1_000e6);
        _requestRedeemWithShares(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestRedeemWithShares(owner3, recipient3, 3_000e6);

        _processRedeems(type(uint256).max, 2);

        assertEq(spPrime.firstPendingRedeemId(), 2);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingRedeemRequests();

        assertEq(requests.length, 1);

        _assertRequest(requests[0], owner3, recipient3, shares3);
    }

    function test_getPendingRedeemRequests_allProcessed() public {
        _requestRedeemWithShares(owner1, recipient1, 1_000e6);
        _requestRedeemWithShares(owner2, recipient2, 2_000e6);

        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(spPrime.firstPendingRedeemId(), 2);

        assertEq(spPrime.getPendingRedeemRequests().length, 0);
    }

    function test_getPendingRedeemRequests_partialFill() public {
        ( , uint256 shares1 ) = _requestRedeemWithShares(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestRedeemWithShares(owner2, recipient2, 2_000e6);

        _processRedeems(shares1 / 4, type(uint256).max);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingRedeemRequests();

        assertEq(requests.length, 2);

        _assertRequest(requests[0], owner1, recipient1, shares1 - shares1 / 4);
        _assertRequest(requests[1], owner2, recipient2, shares2);
    }

    /**********************************************************************************************/
    /*** getPendingRedeemRequests(startId, endId)                                               ***/
    /**********************************************************************************************/

    function test_getPendingRedeemRequests_startAfterEnd() public {
        _requestRedeemWithShares(owner1, recipient1, 1_000e6);
        _requestRedeemWithShares(owner2, recipient2, 2_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-range");
        spPrime.getPendingRedeemRequests(2, 1);
    }

    function test_getPendingRedeemRequests_endOutOfBoundsBoundary() public {
        _requestRedeemWithShares(owner1, recipient1, 1_000e6);
        _requestRedeemWithShares(owner2, recipient2, 2_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-range");
        spPrime.getPendingRedeemRequests(0, 3);

        assertEq(spPrime.getPendingRedeemRequests(0, 2).length, 2);
    }

    function test_getPendingRedeemRequests_emptyRange() public {
        assertEq(spPrime.getPendingRedeemRequests(0, 0).length, 0);

        _requestRedeemWithShares(owner1, recipient1, 1_000e6);

        assertEq(spPrime.getPendingRedeemRequests(0, 0).length, 0);
        assertEq(spPrime.getPendingRedeemRequests(1, 1).length, 0);
    }

    function test_getPendingRedeemRequestsRange() public {
        ( , uint256 shares1 ) = _requestRedeemWithShares(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestRedeemWithShares(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestRedeemWithShares(owner3, recipient3, 3_000e6);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingRedeemRequests(0, 3);

        assertEq(requests.length, 3);

        _assertRequest(requests[0], owner1, recipient1, shares1);
        _assertRequest(requests[1], owner2, recipient2, shares2);
        _assertRequest(requests[2], owner3, recipient3, shares3);

        requests = spPrime.getPendingRedeemRequests(1, 2);

        assertEq(requests.length, 1);

        _assertRequest(requests[0], owner2, recipient2, shares2);

        requests = spPrime.getPendingRedeemRequests(1, 3);

        assertEq(requests.length, 2);

        _assertRequest(requests[0], owner2, recipient2, shares2);
        _assertRequest(requests[1], owner3, recipient3, shares3);
    }

    function test_getPendingRedeemRequestsRange_includesProcessed() public {
        _requestRedeemWithShares(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestRedeemWithShares(owner2, recipient2, 2_000e6);

        _processRedeems(type(uint256).max, 1);

        assertEq(spPrime.firstPendingRedeemId(), 1);

        SparkPrimeVault.Request[] memory requests = spPrime.getPendingRedeemRequests(0, 2);

        assertEq(requests.length, 2);

        _assertEmptyRequest(requests[0]);
        _assertRequest(requests[1], owner2, recipient2, shares2);
    }

}
