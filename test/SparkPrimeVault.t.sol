// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase, SparkPrimeVault, ISparkVaultLike } from "./TestBase.t.sol";

abstract contract SparkPrimeVaultTests is TestBase {

    uint16 internal constant REFERRAL = type(uint16).max;

    function setUp() public override virtual {
        super.setUp();

        skip(365 days);
    }

}

/**********************************************************************************************/
/*** Getter Tests                                                                           ***/
/**********************************************************************************************/

abstract contract GettersTestBase is SparkPrimeVaultTests {

    address internal owner1 = makeAddr("owner1");
    address internal owner2 = makeAddr("owner2");
    address internal owner3 = makeAddr("owner3");

    address internal recipient1 = makeAddr("recipient1");
    address internal recipient2 = makeAddr("recipient2");
    address internal recipient3 = makeAddr("recipient3");

    function setUp() public virtual override {
        super.setUp();

        vm.prank(admin);
        spPrime.grantRole(PROCESSOR_ROLE, processor);

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

contract RequestDepositTests is SparkPrimeVaultTests {

    address internal user = makeAddr("user");

    function setUp() public override {
        super.setUp();

        vm.label(address(user), "user");
    }

    // Failure tests

    function test_requestDeposit_paused() external {
        _pause();

        vm.expectRevert("SparkPrimeVault/paused");
        vm.prank(user);
        spPrime.requestDeposit(100e6, user, 0);
    }

    function test_requestDeposit_zeroRecipient() external {
        vm.expectRevert("SparkPrimeVault/zero-recipient");
        vm.prank(user);
        spPrime.requestDeposit(100e6, address(0), 0);
    }

    function test_requestDeposit_vaultRecipient() external {
        vm.expectRevert("SparkPrimeVault/vault-recipient");
        vm.prank(user);
        spPrime.requestDeposit(100e6, address(spPrime), 0);
    }

    function test_requestDeposit_belowMinimumBoundary() external {
        deal(address(usdc), user, MINIMUM_DEPOSIT);

        vm.prank(user);
        usdc.approve(address(spPrime), MINIMUM_DEPOSIT);

        vm.expectRevert("SparkPrimeVault/below-minimum");
        vm.prank(user);
        spPrime.requestDeposit(MINIMUM_DEPOSIT - 1, user, 0);

        vm.prank(user);
        spPrime.requestDeposit(MINIMUM_DEPOSIT, user, 0);
    }

    function test_requestDeposit_insufficientAllowanceBoundary() external {
        deal(address(usdc), user, 1_000_000e6 + 1);

        vm.prank(user);
        usdc.approve(address(spPrime), 1_000_000e6);

        vm.prank(user);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        spPrime.requestDeposit(1_000_000e6 + 1, user, 0);

        vm.prank(user);
        spPrime.requestDeposit(1_000_000e6, user, 0);
    }

    function test_requestDeposit_insufficientBalanceBoundary() external {
        deal(address(usdc), user, 1_000_000e6);

        vm.prank(user);
        usdc.approve(address(spPrime), 1_000_000e6 + 1);

        vm.prank(user);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        spPrime.requestDeposit(1_000_000e6 + 1, user, 0);

        vm.prank(user);
        spPrime.requestDeposit(1_000_000e6, user, 0);
    }

    // Success tests

    function test_requestDeposit_partialFill() external {
        _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Filled instantly)

        _setCapacity(spPrime.convertToShares(1_500_000e6));

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalAssets            = 1_000_000e6 - 2;
        vaultState.availableCapacityValue = 500_000e6;
        vaultState.availableLiquidAssets  = 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 1;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 1_000_000e6 - 2,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssets   : 0
        });

        _assertVaultState();

        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        deal(address(usdc), user, 800_000e6);

        vm.prank(user);
        usdc.approve(address(spPrime), 800_000e6);

        uint256 expectedConvertedAssets       = 500_000e6 - 1;
        uint256 expectedSavingsSharesMinted   = spUSDC.convertToShares(800_000e6);
        uint256 expectedSavingsSharesConsumed = spUSDC.convertToShares(expectedConvertedAssets) + 1;
        uint256 expectedSharesMinted          = spPrime.convertToShares(expectedConvertedAssets);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Referral(REFERRAL, 1, user, user, 800_000e6);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.DepositRequest(1, user, user, 800_000e6, expectedSavingsSharesMinted);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Deposit(1, user, user, expectedSavingsSharesConsumed, expectedConvertedAssets, expectedSharesMinted);

        vm.prank(user);
        uint256 requestId = spPrime.requestDeposit(800_000e6, user, REFERRAL);

        assertEq(requestId, 1);

        _assertDepositRequest(1, user, user, 300_000e6);

        vaultState.totalAssets            += 500_000e6 - 1;
        vaultState.availableCapacityValue  = 2;
        vaultState.availableLiquidAssets  += 800_000e6;

        vaultState.depositRequests.pendingShareValue += 300_000e6;
        vaultState.depositRequests.length             = 1;
        vaultState.depositRequests.firstPendingId     = 1;

        userBalances.shareValue += 500_000e6 - 1;

        vaultBalances.savingsShareValue += 800_000e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

    function test_requestDeposit_queued() external {
        _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Filled instantly)

        _setCapacity(spPrime.convertToShares(1_000_000e6));

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalAssets            = 1_000_000e6 - 2;
        vaultState.availableCapacityValue = 0;
        vaultState.availableLiquidAssets  = 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 1;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 1_000_000e6 - 2,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssets   : 0
        });

        _assertVaultState();

        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        deal(address(usdc), user, 800_000e6);

        vm.prank(user);
        usdc.approve(address(spPrime), 800_000e6);

        uint256 expectedSavingsSharesMinted = spUSDC.convertToShares(800_000e6);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Referral(REFERRAL, 1, user, user, 800_000e6);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.DepositRequest(1, user, user, 800_000e6, expectedSavingsSharesMinted);

        vm.prank(user);
        uint256 requestId = spPrime.requestDeposit(800_000e6, user, REFERRAL);

        assertEq(requestId, 1);

        _assertDepositRequest(1, user, user, 800_000e6 - 1);

        vaultState.availableLiquidAssets += 800_000e6;

        vaultState.depositRequests.pendingShareValue = 800_000e6 - 1;
        vaultState.depositRequests.length            = 1;
        vaultState.depositRequests.firstPendingId    = 1;

        vaultBalances.savingsShareValue += 800_000e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

}

contract ProcessPendingDepositsTests is SparkPrimeVaultTests {

    address internal ali = makeAddr("ali");
    address internal bob = makeAddr("bob");
    address internal cam = makeAddr("cam");

    AccountBalances internal aliBalances;
    AccountBalances internal bobBalances;
    AccountBalances internal camBalances;
    AccountBalances internal vaultBalances;

    function setUp() public override {
        super.setUp();

        vm.label(ali, "ali");
        vm.label(bob, "bob");
        vm.label(cam, "cam");

        _setCapacity(0);

        _requestDeposit(ali, 100_000e6);    // Will be cancelled
        _requestDeposit(bob, 200_000e6);    // Will be cancelled
        _requestDeposit(cam, 300_000e6);    // Will be cancelled
        _requestDeposit(ali, 400_000e6);    // Will be filled
        _requestDeposit(bob, 500_000e6);    // Will be filled
        _requestDeposit(cam, 600_000e6);    // Will be cancelled
        _requestDeposit(ali, 700_000e6);    // Will be filled
        _requestDeposit(bob, 800_000e6);    // Will be filled
        _requestDeposit(cam, 900_000e6);    // Will be cancelled
        _requestDeposit(ali, 1_000_000e6);  // Will be partially filled

        _requestDepositCancellation(ali, 0);
        _requestDepositCancellation(bob, 1);
        _requestDepositCancellation(cam, 2);
        _requestDepositCancellation(cam, 5);
        _requestDepositCancellation(cam, 8);

        uint256 depositedAssets  = 5_500_000e6 - 5;  // All transfers in (net of rounding)

        uint256 pendingDepositAssets = 400_000e6 + 500_000e6 + 700_000e6 + 800_000e6 + 1_000_000e6;

        uint256 pendingDepositCancellationAssets = 100_000e6 + 200_000e6 + 300_000e6 + 600_000e6 + 900_000e6;

        uint256 targetAssets = 400_000e6 + 500_000e6 + 700_000e6 + 800_000e6 + 200_000e6;  // Only 200k of the last 1MM deposit

        _setCapacity(spPrime.convertToShares(targetAssets));

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalAssets            = 0;
        vaultState.availableCapacityValue = targetAssets - 1;
        vaultState.availableLiquidAssets  = depositedAssets;

        vaultState.depositRequests.pendingShareValue = pendingDepositAssets - 3;
        vaultState.depositRequests.length            = 10;
        vaultState.depositRequests.firstPendingId    = 0;

        vaultState.depositCancellationRequests.pendingShareValue = pendingDepositCancellationAssets - 3;
        vaultState.depositCancellationRequests.length            = 5;
        vaultState.depositCancellationRequests.firstPendingId    = 0;

        aliBalances = AccountBalances({
            account           : ali,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        bobBalances = AccountBalances({
            account           : bob,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        camBalances = AccountBalances({
            account           : cam,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 5_500_000e6 - 5,
            claimableAssets   : 0
        });

        _assertVaultState();

        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        _assertDepositRequest(0, address(0), address(0), 0);
        _assertDepositRequest(1, address(0), address(0), 0);
        _assertDepositRequest(2, address(0), address(0), 0);
        _assertDepositRequest(3, ali,        ali,        400_000e6 - 1);
        _assertDepositRequest(4, bob,        bob,        500_000e6 - 1);
        _assertDepositRequest(5, address(0), address(0), 0);
        _assertDepositRequest(6, ali,        ali,        700_000e6 - 1);
        _assertDepositRequest(7, bob,        bob,        800_000e6 - 1);
        _assertDepositRequest(8, address(0), address(0), 0);
        _assertDepositRequest(9, ali,        ali,        1_000_000e6 - 1);
    }

    function test_processPendingDeposits_infiniteMaxSavingsShares_infiniteMaxRequests() external {
        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Transfer(address(0), ali, spPrime.convertToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Deposit(3, ali, ali, spUSDC.convertToShares(400_000e6), 400_000e6 - 1, spPrime.convertToShares(400_000e6) - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Transfer(address(0), bob, spPrime.convertToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Deposit(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1, spPrime.convertToShares(500_000e6) - 1);

        // Deposit Request 6

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Transfer(address(0), ali, spPrime.convertToShares(700_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Deposit(6, ali, ali, spUSDC.convertToShares(700_000e6), 700_000e6 - 1, spPrime.convertToShares(700_000e6) - 1);

        // Deposit Request 7

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Transfer(address(0), bob, spPrime.convertToShares(800_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Deposit(7, bob, bob, spUSDC.convertToShares(800_000e6), 800_000e6 - 1, spPrime.convertToShares(800_000e6) - 1);

        // Deposit Request 9 (Partial)

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Transfer(address(0), ali, spPrime.convertToShares(200_000e6));

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Deposit(9, ali, ali, spUSDC.convertToShares(200_000e6) + 1, 200_000e6, spPrime.convertToShares(200_000e6));

        vm.prank(processor);
        spPrime.processPendingDeposits(type(uint256).max, type(uint256).max);

        uint256 assetsDeposited = 400_000e6 + 500_000e6 + 700_000e6 + 800_000e6 + 200_000e6;  // Only ~200k of the last 1MM deposit

        vaultState.totalAssets            += assetsDeposited - 7;
        vaultState.availableCapacityValue -= assetsDeposited - 7;

        vaultState.depositRequests.pendingShareValue -= assetsDeposited - 1;
        vaultState.depositRequests.length             = 1;
        vaultState.depositRequests.firstPendingId     = 9;

        aliBalances.shareValue += 400_000e6 + 700_000e6 + 200_000e6 - 4;
        bobBalances.shareValue += 500_000e6 + 800_000e6 - 4;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 9; i++) {
            vm.expectRevert("SparkPrimeVault/invalid-request-id");
            _assertDepositRequest(i, address(0), address(0), 0);
        }

        _assertDepositRequest(9, ali, ali, 800_000e6 - 2);
    }

    function test_processPendingDeposits_infiniteMaxSavingsShares_limitedMaxRequests() external {
        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Transfer(address(0), ali, spPrime.convertToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Deposit(3, ali, ali, spUSDC.convertToShares(400_000e6), 400_000e6 - 1, spPrime.convertToShares(400_000e6) - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Transfer(address(0), bob, spPrime.convertToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Deposit(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1, spPrime.convertToShares(500_000e6) - 1);

        // Skips 3 cancelled deposits, then fills 2 deposits, then skips 1 cancelled deposit
        vm.prank(processor);
        spPrime.processPendingDeposits(type(uint256).max, 6);

        uint256 assetsDeposited = 400_000e6 + 500_000e6;  // Only first 2 uncancelled deposits

        vaultState.totalAssets            += assetsDeposited - 4;
        vaultState.availableCapacityValue -= assetsDeposited - 3;

        vaultState.depositRequests.pendingShareValue -= assetsDeposited - 1;
        vaultState.depositRequests.length             = 4;
        vaultState.depositRequests.firstPendingId     = 6;

        aliBalances.shareValue += 400_000e6 - 2;
        bobBalances.shareValue += 500_000e6 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 6; i++) {
            vm.expectRevert("SparkPrimeVault/invalid-request-id");
            _assertDepositRequest(i, address(0), address(0), 0);
        }

        _assertDepositRequest(6, ali,        ali,        700_000e6 - 1);
        _assertDepositRequest(7, bob,        bob,        800_000e6 - 1);
        _assertDepositRequest(8, address(0), address(0), 0);
        _assertDepositRequest(9, ali,        ali,        1_000_000e6 - 1);
    }

    function test_processPendingDeposits_limitedMaxSavingsShares_infiniteMaxRequests() external {
        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Transfer(address(0), ali, spPrime.convertToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Deposit(3, ali, ali, spUSDC.convertToShares(400_000e6), 400_000e6 - 1, spPrime.convertToShares(400_000e6) - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Transfer(address(0), bob, spPrime.convertToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Deposit(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1, spPrime.convertToShares(500_000e6) - 1);

        // Deposit Request 6 (Partial)

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Transfer(address(0), ali, spPrime.convertToShares(300_000e6));

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Deposit(6, ali, ali, spUSDC.convertToShares(300_000e6) + 1, 300_000e6, spPrime.convertToShares(300_000e6));

        vm.startPrank(processor);
        spPrime.processPendingDeposits(spUSDC.convertToShares(1_200_000e6), type(uint256).max);
        vm.stopPrank();

        uint256 assetsDeposited = 400_000e6 + 500_000e6 + 300_000e6;  // Only ~300k of the third uncancelled 700k deposit

        vaultState.totalAssets            += assetsDeposited - 4;
        vaultState.availableCapacityValue -= assetsDeposited - 3;

        vaultState.depositRequests.pendingShareValue -= assetsDeposited - 1;
        vaultState.depositRequests.length             = 4;
        vaultState.depositRequests.firstPendingId     = 6;

        aliBalances.shareValue += 400_000e6 + 300_000e6 - 2;
        bobBalances.shareValue += 500_000e6 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 6; i++) {
            vm.expectRevert("SparkPrimeVault/invalid-request-id");
            _assertDepositRequest(i, address(0), address(0), 0);
        }

        _assertDepositRequest(6, ali,        ali,        400_000e6 - 2);  // Partial fill
        _assertDepositRequest(7, bob,        bob,        800_000e6 - 1);
        _assertDepositRequest(8, address(0), address(0), 0);
        _assertDepositRequest(9, ali,        ali,        1_000_000e6 - 1);
    }

}
