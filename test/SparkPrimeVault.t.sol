// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase, SparkPrimeVault } from "./TestBase.t.sol";

abstract contract SparkPrimeVaultTests is TestBase {

    uint16 internal constant REFERRAL = type(uint16).max;

    address internal user = makeAddr("user");

    function setUp() public virtual override {
        super.setUp();

        vm.label(address(user), "user");
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

    uint256 internal constant VAULT_CAPACITY = 100_000_000e6;

    function setUp() public virtual override {
        super.setUp();

        vm.prank(admin);
        vault.grantRole(REBALANCER_ROLE, rebalancer);
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _requestDeposit(address owner, address recipient, uint256 assets)
        internal
        returns (uint256 requestId, uint256 savingsShares)
    {
        deal(address(usdc), owner, assets);

        uint256 savingsSharesBefore = spUsdc.balanceOf(address(vault));

        vm.startPrank(owner);
        usdc.approve(address(vault), assets);
        requestId = vault.requestDeposit(assets, recipient, REFERRAL);
        vm.stopPrank();

        savingsShares = spUsdc.balanceOf(address(vault)) - savingsSharesBefore;
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
        vault.setCapacity(VAULT_CAPACITY);

        vm.prank(rebalancer);
        vault.processPendingDeposits(maxSavingsShares, maxRequests);
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
        ) = vault.getPendingDepositRequest(requestId);

        assertEq(requestOwner,     owner);
        assertEq(requestRecipient, recipient);
        assertEq(requestShares,    shares);
    }

    /**********************************************************************************************/
    /*** getPendingDepositRequest                                                               ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequest_noRequests() public {
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositRequest(0);
    }

    function test_getPendingDepositRequest_idOutOfBoundsBoundary() public {
        ( , uint256 shares ) = _requestDeposit(owner1, recipient1, 1_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositRequest(1);

        _assertPendingDepositRequest(0, owner1, recipient1, shares);
    }

    function test_getPendingDepositRequest_idBeforeFirstPendingBoundary() public {
        _requestDeposit(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDeposit(owner2, recipient2, 2_000e6);

        _processDeposits(type(uint256).max, 1);

        assertEq(vault.firstPendingDepositId(), 1);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositRequest(0);

        _assertPendingDepositRequest(1, owner2, recipient2, shares2);
    }

    function test_getPendingDepositRequest() public {
        ( uint256 requestId1, uint256 shares1 ) = _requestDeposit(owner1, recipient1, 1_000e6);
        ( uint256 requestId2, uint256 shares2 ) = _requestDeposit(owner2, recipient2, 2_000e6);

        assertEq(requestId1, 0);
        assertEq(requestId2, 1);

        _assertPendingDepositRequest(0, owner1, recipient1, shares1);
        _assertPendingDepositRequest(1, owner2, recipient2, shares2);
    }

    function test_getPendingDepositRequest_partialFill() public {
        ( , uint256 shares ) = _requestDeposit(owner1, recipient1, 1_000e6);

        _processDeposits(shares / 4, 1);

        assertEq(vault.firstPendingDepositId(), 0);

        _assertPendingDepositRequest(0, owner1, recipient1, shares - shares / 4);
    }

    function test_getPendingDepositRequest_cancelled() public {
        _requestDeposit(owner1, recipient1, 1_000e6);

        vm.prank(owner1);
        vault.requestDepositCancellation(0, recipient1);

        _assertPendingDepositRequest(0, address(0), address(0), 0);
    }

    /**********************************************************************************************/
    /*** getPendingDepositRequests()                                                            ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequests_noRequests() public view {
        assertEq(vault.getPendingDepositRequests().length, 0);
    }

    function test_getPendingDepositRequests() public {
        ( , uint256 shares1 ) = _requestDeposit(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDeposit(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestDeposit(owner3, recipient3, 3_000e6);

        SparkPrimeVault.Request[] memory requests = vault.getPendingDepositRequests();

        assertEq(requests.length, 3);

        _assertRequest(requests[0], owner1, recipient1, shares1);
        _assertRequest(requests[1], owner2, recipient2, shares2);
        _assertRequest(requests[2], owner3, recipient3, shares3);
    }

    function test_getPendingDepositRequests_someProcessed() public {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestDeposit(owner3, recipient3, 3_000e6);

        _processDeposits(type(uint256).max, 2);

        assertEq(vault.firstPendingDepositId(), 2);

        SparkPrimeVault.Request[] memory requests = vault.getPendingDepositRequests();

        assertEq(requests.length, 1);

        _assertRequest(requests[0], owner3, recipient3, shares3);
    }

    function test_getPendingDepositRequests_allProcessed() public {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        _processDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.firstPendingDepositId(), 2);

        assertEq(vault.getPendingDepositRequests().length, 0);
    }

    function test_getPendingDepositRequests_partialFill() public {
        ( , uint256 shares1 ) = _requestDeposit(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDeposit(owner2, recipient2, 2_000e6);

        _processDeposits(shares1 / 4, type(uint256).max);

        SparkPrimeVault.Request[] memory requests = vault.getPendingDepositRequests();

        assertEq(requests.length, 2);

        _assertRequest(requests[0], owner1, recipient1, shares1 - shares1 / 4);
        _assertRequest(requests[1], owner2, recipient2, shares2);
    }

    function test_getPendingDepositRequests_cancelledRequest() public {
        ( , uint256 shares1 ) = _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestDeposit(owner3, recipient3, 3_000e6);

        vm.prank(owner2);
        vault.requestDepositCancellation(1, recipient2);

        SparkPrimeVault.Request[] memory requests = vault.getPendingDepositRequests();

        assertEq(requests.length, 3);

        _assertRequest(requests[0], owner1, recipient1, shares1);
        _assertEmptyRequest(requests[1]);
        _assertRequest(requests[2], owner3, recipient3, shares3);
    }

    /**********************************************************************************************/
    /*** getPendingDepositRequests(startId, endId)                                              ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequests_startAfterEnd() public {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-range");
        vault.getPendingDepositRequests(2, 1);
    }

    function test_getPendingDepositRequests_endOutOfBoundsBoundary() public {
        _requestDeposit(owner1, recipient1, 1_000e6);
        _requestDeposit(owner2, recipient2, 2_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-range");
        vault.getPendingDepositRequests(0, 3);

        assertEq(vault.getPendingDepositRequests(0, 2).length, 2);
    }

    function test_getPendingDepositRequests_emptyRange() public {
        assertEq(vault.getPendingDepositRequests(0, 0).length, 0);

        _requestDeposit(owner1, recipient1, 1_000e6);

        assertEq(vault.getPendingDepositRequests(0, 0).length, 0);
        assertEq(vault.getPendingDepositRequests(1, 1).length, 0);
    }

    function test_getPendingDepositRequestsRange() public {
        ( , uint256 shares1 ) = _requestDeposit(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDeposit(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestDeposit(owner3, recipient3, 3_000e6);

        SparkPrimeVault.Request[] memory requests = vault.getPendingDepositRequests(0, 3);

        assertEq(requests.length, 3);

        _assertRequest(requests[0], owner1, recipient1, shares1);
        _assertRequest(requests[1], owner2, recipient2, shares2);
        _assertRequest(requests[2], owner3, recipient3, shares3);

        requests = vault.getPendingDepositRequests(1, 2);

        assertEq(requests.length, 1);

        _assertRequest(requests[0], owner2, recipient2, shares2);

        requests = vault.getPendingDepositRequests(1, 3);

        assertEq(requests.length, 2);

        _assertRequest(requests[0], owner2, recipient2, shares2);
        _assertRequest(requests[1], owner3, recipient3, shares3);
    }

    function test_getPendingDepositRequestsRange_includesProcessed() public {
        _requestDeposit(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDeposit(owner2, recipient2, 2_000e6);

        _processDeposits(type(uint256).max, 1);

        assertEq(vault.firstPendingDepositId(), 1);

        SparkPrimeVault.Request[] memory requests = vault.getPendingDepositRequests(0, 2);

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

        ( depositRequestId, savingsShares ) = _requestDeposit(owner, owner, assets);

        vm.prank(owner);
        requestId = vault.requestDepositCancellation(depositRequestId, recipient);
    }

    function _processDepositCancellations(uint256 maxSavingsShares, uint256 maxRequests) internal {
        vm.prank(rebalancer);
        vault.processPendingDepositCancellations(maxSavingsShares, maxRequests);
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
        ) = vault.getPendingDepositCancellationRequest(requestId);

        assertEq(requestOwner,     owner);
        assertEq(requestRecipient, recipient);
        assertEq(requestShares,    shares);
    }

    /**********************************************************************************************/
    /*** getPendingDepositCancellationRequest                                                   ***/
    /**********************************************************************************************/

    function test_getPendingDepositCancellationRequest_noRequests() public {
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositCancellationRequest(0);
    }

    function test_getPendingDepositCancellationRequest_idOutOfBoundsBoundary() public {
        ( , uint256 shares ) = _requestDepositCancellation(owner1, recipient1, 1_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositCancellationRequest(1);

        _assertPendingDepositCancellationRequest(0, owner1, recipient1, shares);
    }

    function test_getPendingDepositCancellationRequest_idBeforeFirstPendingBoundary() public {
        _requestDepositCancellation(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositCancellation(owner2, recipient2, 2_000e6);

        _processDepositCancellations(type(uint256).max, 1);

        assertEq(vault.firstPendingDepositCancellationId(), 1);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositCancellationRequest(0);

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

        assertEq(vault.firstPendingDepositCancellationId(), 1);

        _assertPendingDepositCancellationRequest(1, owner2, recipient2, shares2 - shares2 / 4);
    }

    /**********************************************************************************************/
    /*** getPendingDepositCancellationRequests()                                                ***/
    /**********************************************************************************************/

    function test_getPendingDepositCancellationRequests_noRequests() public view {
        assertEq(vault.getPendingDepositCancellationRequests().length, 0);
    }

    function test_getPendingDepositCancellationRequests() public {
        ( , uint256 shares1 ) = _requestDepositCancellation(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositCancellation(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestDepositCancellation(owner3, recipient3, 3_000e6);

        SparkPrimeVault.Request[] memory requests = vault.getPendingDepositCancellationRequests();

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

        assertEq(vault.firstPendingDepositCancellationId(), 2);

        SparkPrimeVault.Request[] memory requests = vault.getPendingDepositCancellationRequests();

        assertEq(requests.length, 1);

        _assertRequest(requests[0], owner3, recipient3, shares3);
    }

    function test_getPendingDepositCancellationRequests_allProcessed() public {
        _requestDepositCancellation(owner1, recipient1, 1_000e6);
        _requestDepositCancellation(owner2, recipient2, 2_000e6);

        _processDepositCancellations(type(uint256).max, 2);

        assertEq(vault.firstPendingDepositCancellationId(), 2);

        assertEq(vault.getPendingDepositCancellationRequests().length, 0);
    }

    function test_getPendingDepositCancellationRequests_partialFill() public {
        ( , uint256 shares1 ) = _requestDepositCancellation(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositCancellation(owner2, recipient2, 2_000e6);

        _processDepositCancellations(shares1 / 4, 1);

        SparkPrimeVault.Request[] memory requests = vault.getPendingDepositCancellationRequests();

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
        vault.getPendingDepositCancellationRequests(2, 1);
    }

    function test_getPendingDepositCancellationRequests_endOutOfBoundsBoundary() public {
        _requestDepositCancellation(owner1, recipient1, 1_000e6);
        _requestDepositCancellation(owner2, recipient2, 2_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-range");
        vault.getPendingDepositCancellationRequests(0, 3);

        assertEq(vault.getPendingDepositCancellationRequests(0, 2).length, 2);
    }

    function test_getPendingDepositCancellationRequests_emptyRange() public {
        assertEq(vault.getPendingDepositCancellationRequests(0, 0).length, 0);

        _requestDepositCancellation(owner1, recipient1, 1_000e6);

        assertEq(vault.getPendingDepositCancellationRequests(0, 0).length, 0);
        assertEq(vault.getPendingDepositCancellationRequests(1, 1).length, 0);
    }

    function test_getPendingDepositCancellationRequestsRange() public {
        ( , uint256 shares1 ) = _requestDepositCancellation(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositCancellation(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestDepositCancellation(owner3, recipient3, 3_000e6);

        SparkPrimeVault.Request[] memory requests
            = vault.getPendingDepositCancellationRequests(0, 3);

        assertEq(requests.length, 3);

        _assertRequest(requests[0], owner1, recipient1, shares1);
        _assertRequest(requests[1], owner2, recipient2, shares2);
        _assertRequest(requests[2], owner3, recipient3, shares3);

        requests = vault.getPendingDepositCancellationRequests(1, 2);

        assertEq(requests.length, 1);

        _assertRequest(requests[0], owner2, recipient2, shares2);

        requests = vault.getPendingDepositCancellationRequests(1, 3);

        assertEq(requests.length, 2);

        _assertRequest(requests[0], owner2, recipient2, shares2);
        _assertRequest(requests[1], owner3, recipient3, shares3);
    }

    function test_getPendingDepositCancellationRequests_includesProcessed() public {
        _requestDepositCancellation(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestDepositCancellation(owner2, recipient2, 2_000e6);

        _processDepositCancellations(type(uint256).max, 1);

        assertEq(vault.firstPendingDepositCancellationId(), 1);

        SparkPrimeVault.Request[] memory requests
            = vault.getPendingDepositCancellationRequests(0, 2);

        assertEq(requests.length, 2);

        _assertEmptyRequest(requests[0]);
        _assertRequest(requests[1], owner2, recipient2, shares2);
    }

}

contract GetPendingRedeemRequestTests is GettersTestBase {

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setCapacity(VAULT_CAPACITY);
    }

    // NOTE: The redeem fee rate is zero, so the queued shares equal the shares redeemed.
    function _requestRedeem(address owner, address recipient, uint256 assets)
        internal
        returns (uint256 requestId, uint256 shares)
    {
        _requestDeposit(owner, owner, assets);

        shares = vault.balanceOf(owner);

        vm.prank(owner);
        requestId = vault.requestRedeem(shares, recipient);
    }

    function _processRedeems(uint256 maxShares, uint256 maxRequests) internal {
        vm.prank(rebalancer);
        vault.processPendingRedeems(maxShares, maxRequests);
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
        ) = vault.getPendingRedeemRequest(requestId);

        assertEq(requestOwner,     owner);
        assertEq(requestRecipient, recipient);
        assertEq(requestShares,    shares);
    }

    /**********************************************************************************************/
    /*** getPendingRedeemRequest                                                                ***/
    /**********************************************************************************************/

    function test_getPendingRedeemRequest_noRequests() public {
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingRedeemRequest(0);
    }

    function test_getPendingRedeemRequest_idOutOfBoundsBoundary() public {
        ( , uint256 shares ) = _requestRedeem(owner1, recipient1, 1_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingRedeemRequest(1);

        _assertPendingRedeemRequest(0, owner1, recipient1, shares);
    }

    function test_getPendingRedeemRequest_idBeforeFirstPendingBoundary() public {
        _requestRedeem(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestRedeem(owner2, recipient2, 2_000e6);

        _processRedeems(type(uint256).max, 1);

        assertEq(vault.firstPendingRedeemId(), 1);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingRedeemRequest(0);

        _assertPendingRedeemRequest(1, owner2, recipient2, shares2);
    }

    function test_getPendingRedeemRequest() public {
        ( uint256 requestId1, uint256 shares1 ) = _requestRedeem(owner1, recipient1, 1_000e6);
        ( uint256 requestId2, uint256 shares2 ) = _requestRedeem(owner2, recipient2, 2_000e6);

        assertEq(requestId1, 0);
        assertEq(requestId2, 1);

        _assertPendingRedeemRequest(0, owner1, recipient1, shares1);
        _assertPendingRedeemRequest(1, owner2, recipient2, shares2);
    }

    function test_getPendingRedeemRequest_partialFill() public {
        ( , uint256 shares1 ) = _requestRedeem(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestRedeem(owner2, recipient2, 2_000e6);

        _processRedeems(shares1 + shares2 / 4, 2);

        assertEq(vault.firstPendingRedeemId(), 1);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingRedeemRequest(0);

        _assertPendingRedeemRequest(1, owner2, recipient2, shares2 - shares2 / 4);
    }

    /**********************************************************************************************/
    /*** getPendingRedeemRequests()                                                             ***/
    /**********************************************************************************************/

    function test_getPendingRedeemRequests_noRequests() public view {
        assertEq(vault.getPendingRedeemRequests().length, 0);
    }

    function test_getPendingRedeemRequests() public {
        ( , uint256 shares1 ) = _requestRedeem(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestRedeem(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestRedeem(owner3, recipient3, 3_000e6);

        SparkPrimeVault.Request[] memory requests = vault.getPendingRedeemRequests();

        assertEq(requests.length, 3);

        _assertRequest(requests[0], owner1, recipient1, shares1);
        _assertRequest(requests[1], owner2, recipient2, shares2);
        _assertRequest(requests[2], owner3, recipient3, shares3);
    }

    function test_getPendingRedeemRequests_someProcessed() public {
        _requestRedeem(owner1, recipient1, 1_000e6);
        _requestRedeem(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestRedeem(owner3, recipient3, 3_000e6);

        _processRedeems(type(uint256).max, 2);

        assertEq(vault.firstPendingRedeemId(), 2);

        SparkPrimeVault.Request[] memory requests = vault.getPendingRedeemRequests();

        assertEq(requests.length, 1);

        _assertRequest(requests[0], owner3, recipient3, shares3);
    }

    function test_getPendingRedeemRequests_allProcessed() public {
        _requestRedeem(owner1, recipient1, 1_000e6);
        _requestRedeem(owner2, recipient2, 2_000e6);

        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(vault.firstPendingRedeemId(), 2);

        assertEq(vault.getPendingRedeemRequests().length, 0);
    }

    function test_getPendingRedeemRequests_partialFill() public {
        ( , uint256 shares1 ) = _requestRedeem(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestRedeem(owner2, recipient2, 2_000e6);

        _processRedeems(shares1 / 4, type(uint256).max);

        SparkPrimeVault.Request[] memory requests = vault.getPendingRedeemRequests();

        assertEq(requests.length, 2);

        _assertRequest(requests[0], owner1, recipient1, shares1 - shares1 / 4);
        _assertRequest(requests[1], owner2, recipient2, shares2);
    }

    /**********************************************************************************************/
    /*** getPendingRedeemRequests(startId, endId)                                               ***/
    /**********************************************************************************************/

    function test_getPendingRedeemRequests_startAfterEnd() public {
        _requestRedeem(owner1, recipient1, 1_000e6);
        _requestRedeem(owner2, recipient2, 2_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-range");
        vault.getPendingRedeemRequests(2, 1);
    }

    function test_getPendingRedeemRequests_endOutOfBoundsBoundary() public {
        _requestRedeem(owner1, recipient1, 1_000e6);
        _requestRedeem(owner2, recipient2, 2_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-range");
        vault.getPendingRedeemRequests(0, 3);

        assertEq(vault.getPendingRedeemRequests(0, 2).length, 2);
    }

    function test_getPendingRedeemRequests_emptyRange() public {
        assertEq(vault.getPendingRedeemRequests(0, 0).length, 0);

        _requestRedeem(owner1, recipient1, 1_000e6);

        assertEq(vault.getPendingRedeemRequests(0, 0).length, 0);
        assertEq(vault.getPendingRedeemRequests(1, 1).length, 0);
    }

    function test_getPendingRedeemRequestsRange() public {
        ( , uint256 shares1 ) = _requestRedeem(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestRedeem(owner2, recipient2, 2_000e6);
        ( , uint256 shares3 ) = _requestRedeem(owner3, recipient3, 3_000e6);

        SparkPrimeVault.Request[] memory requests = vault.getPendingRedeemRequests(0, 3);

        assertEq(requests.length, 3);

        _assertRequest(requests[0], owner1, recipient1, shares1);
        _assertRequest(requests[1], owner2, recipient2, shares2);
        _assertRequest(requests[2], owner3, recipient3, shares3);

        requests = vault.getPendingRedeemRequests(1, 2);

        assertEq(requests.length, 1);

        _assertRequest(requests[0], owner2, recipient2, shares2);

        requests = vault.getPendingRedeemRequests(1, 3);

        assertEq(requests.length, 2);

        _assertRequest(requests[0], owner2, recipient2, shares2);
        _assertRequest(requests[1], owner3, recipient3, shares3);
    }

    function test_getPendingRedeemRequestsRange_includesProcessed() public {
        _requestRedeem(owner1, recipient1, 1_000e6);
        ( , uint256 shares2 ) = _requestRedeem(owner2, recipient2, 2_000e6);

        _processRedeems(type(uint256).max, 1);

        assertEq(vault.firstPendingRedeemId(), 1);

        SparkPrimeVault.Request[] memory requests = vault.getPendingRedeemRequests(0, 2);

        assertEq(requests.length, 2);

        _assertEmptyRequest(requests[0]);
        _assertRequest(requests[1], owner2, recipient2, shares2);
    }

}
