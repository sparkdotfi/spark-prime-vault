// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

// `forge` 1.5.1 returns five fields from `lastCallGas`, one fewer than the vendored forge-std
// declares, so the cheatcode is called through this matching interface.
interface IVmGasLike {

    struct Gas {
        uint64 gasLimit;
        uint64 gasTotalUsed;
        uint64 gasMemoryUsed;
        int64  gasRefunded;
        uint64 gasRemaining;
    }

    function lastCallGas() external view returns (Gas memory gas);

}

/**
 * @dev Tests of the linked-list structure of the deposit queue: links, head and tail after
 *      cancellations, and the gas cost of walking a queue that was griefed with cancellations.
 */
contract DepositQueueTests is TestBase {

    address internal ali = makeAddr("ali");
    address internal bob = makeAddr("bob");
    address internal cam = makeAddr("cam");

    function setUp() public override {
        super.setUp();

        vm.label(ali, "ali");
        vm.label(bob, "bob");
        vm.label(cam, "cam");

        _setCapacity(0);  // Everything queues
    }

    function _cancelAll(address account, uint256 requestId) internal {
        ( , , uint256 shares ) = spPrime.getPendingDepositRequest(requestId);
        _requestDepositCancellation(account, requestId, shares);
    }

    function _threeRequests() internal {
        _requestDeposit(ali, 1_000e6);  // 1
        _requestDeposit(bob, 2_000e6);  // 2
        _requestDeposit(cam, 3_000e6);  // 3

        _assertDepositNode(1, ali, ali, 1_000e6 - 1, 0, 2);
        _assertDepositNode(2, bob, bob, 2_000e6 - 1, 1, 3);
        _assertDepositNode(3, cam, cam, 3_000e6 - 1, 2, 0);

        _assertDepositQueue(1, 3, 3);
    }

    /**********************************************************************************************/
    /*** Request IDs                                                                            ***/
    /**********************************************************************************************/

    function test_depositQueue_idsStartAtOne() external {
        assertEq(spPrime.nextDepositRequestId(), 1);

        _assertDepositQueue(0, 0, 0);

        assertEq(_requestDeposit(ali, 1_000e6), 1);
        assertEq(_requestDeposit(bob, 1_000e6), 2);

        assertEq(spPrime.nextDepositRequestId(), 3);
    }

    function test_depositQueue_idsAreNeverReused() external {
        _requestDeposit(ali, 1_000e6);  // 1
        _cancelAll(ali, 1);

        _assertDepositQueue(0, 0, 0);

        assertEq(_requestDeposit(bob, 1_000e6), 2);

        _assertDepositNode(1, address(0), address(0), 0, 0, 0);
        _assertDepositNode(2, bob,        bob,        1_000e6 - 1, 0, 0);
    }

    /**********************************************************************************************/
    /*** Cancellation unlinking                                                                 ***/
    /**********************************************************************************************/

    function test_requestDepositCancellation_head() external {
        _threeRequests();

        _cancelAll(ali, 1);

        _assertDepositNode(1, address(0), address(0), 0, 0, 0);
        _assertDepositNode(2, bob, bob, 2_000e6 - 1, 0, 3);
        _assertDepositNode(3, cam, cam, 3_000e6 - 1, 2, 0);

        _assertDepositQueue(2, 3, 2);

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests();

        assertEq(requests.length, 2);

        _assertDepositRequest(requests[0], bob, bob, 2_000e6 - 1);
        _assertDepositRequest(requests[1], cam, cam, 3_000e6 - 1);
    }

    function test_requestDepositCancellation_middle() external {
        _threeRequests();

        _cancelAll(bob, 2);

        _assertDepositNode(1, ali, ali, 1_000e6 - 1, 0, 3);
        _assertDepositNode(2, address(0), address(0), 0, 0, 0);
        _assertDepositNode(3, cam, cam, 3_000e6 - 1, 1, 0);

        _assertDepositQueue(1, 3, 2);

        ISparkPrimeVault.Request[] memory requests = spPrime.getPendingDepositRequests();

        assertEq(requests.length, 2);

        _assertDepositRequest(requests[0], ali, ali, 1_000e6 - 1);
        _assertDepositRequest(requests[1], cam, cam, 3_000e6 - 1);
    }

    function test_requestDepositCancellation_tail() external {
        _threeRequests();

        _cancelAll(cam, 3);

        _assertDepositNode(1, ali, ali, 1_000e6 - 1, 0, 2);
        _assertDepositNode(2, bob, bob, 2_000e6 - 1, 1, 0);
        _assertDepositNode(3, address(0), address(0), 0, 0, 0);

        _assertDepositQueue(1, 2, 2);

        // The next request is appended after the new tail.
        assertEq(_requestDeposit(cam, 4_000e6), 4);

        _assertDepositNode(2, bob, bob, 2_000e6 - 1, 1, 4);
        _assertDepositNode(4, cam, cam, 4_000e6 - 1, 2, 0);

        _assertDepositQueue(1, 4, 3);
    }

    function test_requestDepositCancellation_onlyNode() external {
        _requestDeposit(ali, 1_000e6);  // 1

        _assertDepositNode(1, ali, ali, 1_000e6 - 1, 0, 0);
        _assertDepositQueue(1, 1, 1);

        _cancelAll(ali, 1);

        _assertDepositNode(1, address(0), address(0), 0, 0, 0);
        _assertDepositQueue(0, 0, 0);

        assertEq(spPrime.getPendingDepositRequests().length, 0);
        assertEq(spPrime.pendingDepositSavingsShares(),      0);
    }

    function test_requestDepositCancellation_partialThenFull() external {
        _threeRequests();

        uint256 half = spUSDC.convertToShares(1_000e6);

        // Partial: the node keeps its position and links.
        _requestDepositCancellation(bob, 2, half);

        _assertDepositNode(2, bob, bob, 1_000e6, 1, 3);
        _assertDepositQueue(1, 3, 3);

        // Full: the remainder is cancelled and the node is unlinked.
        _cancelAll(bob, 2);

        _assertDepositNode(1, ali, ali, 1_000e6 - 1, 0, 3);
        _assertDepositNode(2, address(0), address(0), 0, 0, 0);
        _assertDepositNode(3, cam, cam, 3_000e6 - 1, 1, 0);

        _assertDepositQueue(1, 3, 2);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(bob);
        spPrime.requestDepositCancellation(2, bob, half);
    }

    function test_requestDepositCancellation_allThenRequestAgain() external {
        _threeRequests();

        _cancelAll(bob, 2);
        _cancelAll(cam, 3);
        _cancelAll(ali, 1);

        _assertDepositQueue(0, 0, 0);

        assertEq(_requestDeposit(ali, 5_000e6), 4);

        _assertDepositNode(4, ali, ali, 5_000e6 - 1, 0, 0);
        _assertDepositQueue(4, 4, 1);
    }

    /**********************************************************************************************/
    /*** Processing                                                                             ***/
    /**********************************************************************************************/

    function test_processPendingDeposits_advancesHead() external {
        _threeRequests();

        _setCapacity(VAULT_CAPACITY);

        _processPendingDeposits(1);

        _assertDepositNode(1, address(0), address(0), 0, 0, 0);
        _assertDepositNode(2, bob, bob, 2_000e6 - 1, 0, 3);
        _assertDepositQueue(2, 3, 2);

        _processPendingDeposits(type(uint256).max);

        _assertDepositNode(2, address(0), address(0), 0, 0, 0);
        _assertDepositNode(3, address(0), address(0), 0, 0, 0);
        _assertDepositQueue(0, 0, 0);
    }

    function test_processPendingDeposits_partialFillStaysAtHead() external {
        _threeRequests();

        _setCapacity(VAULT_CAPACITY);

        _processPendingDeposits(spUSDC.convertToShares(500e6), type(uint256).max);

        _assertDepositNode(1, ali, ali, 500e6, 0, 2);
        _assertDepositQueue(1, 3, 3);
    }

    function test_requestDeposit_instantFillAfterWholeQueueCancelled() external {
        _threeRequests();

        _cancelAll(ali, 1);
        _cancelAll(bob, 2);
        _cancelAll(cam, 3);

        _assertDepositQueue(0, 0, 0);

        _setCapacity(VAULT_CAPACITY);

        deal(address(usdc), ali, 1_000e6);

        vm.prank(ali);
        usdc.approve(address(spPrime), 1_000e6);

        // The queue is empty, so the new request is the head and is filled in the same call.
        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(4, ali, ali, spUSDC.convertToShares(1_000e6), 1_000e6 - 1, spPrime.convertToShares(1_000e6) - 1);

        vm.prank(ali);
        assertEq(spPrime.requestDeposit(1_000e6, ali, 0), 4);

        _assertDepositQueue(0, 0, 0);

        assertEq(spPrime.assetsOf(ali), 1_000e6 - 1);
    }

    function test_requestDeposit_noInstantFillBehindLiveHead() external {
        _requestDeposit(ali, 1_000e6);  // 1, queued because capacity is zero

        _setCapacity(VAULT_CAPACITY);

        // A live head blocks the instant fill of later requests, as before.
        assertEq(_requestDeposit(bob, 1_000e6), 2);

        _assertDepositQueue(1, 2, 2);

        assertEq(spPrime.assetsOf(bob), 0);
    }

    /**********************************************************************************************/
    /*** Griefing: cancellations behind a live head                                             ***/
    /**********************************************************************************************/

    // Gas spent by a cold, unbounded `processPendingDeposits` call, before refunds.
    function _coldProcessGas() internal returns (uint256 gas) {
        vm.cool(address(spPrime));
        vm.cool(address(spUSDC));

        vm.prank(operator);
        spPrime.processPendingDeposits(type(uint256).max, type(uint256).max);

        return IVmGasLike(address(vm)).lastCallGas().gasTotalUsed;
    }

    function test_processPendingDeposits_cancellationsBehindHeadCostNothing() external {
        uint256 cancellations = 200;

        // Steady state: ali and bob already hold shares, so neither walk pays for a
        // zero-to-nonzero balance or total supply.
        _setCapacity(VAULT_CAPACITY);
        _requestDeposit(ali, 1_000e6);  // 1, filled instantly
        _requestDeposit(bob, 1_000e6);  // 2, filled instantly
        _setCapacity(0);

        // Reference: a live head and one request behind it.
        uint256 aliRequestId = _requestDeposit(ali, 1_000e6);  // 3, live head
        uint256 bobRequestId = _requestDeposit(bob, 1_000e6);  // 4

        _assertDepositQueue(aliRequestId, bobRequestId, 2);

        _setCapacity(VAULT_CAPACITY);

        uint256 gasClean = _coldProcessGas();

        _assertDepositQueue(0, 0, 0);

        // Griefed: the same, with `cancellations` requests made and fully cancelled in between.
        _setCapacity(0);

        aliRequestId = _requestDeposit(ali, 1_000e6);  // 5, live head

        for (uint256 i; i < cancellations; ++i) {
            uint256 requestId = _requestDeposit(cam, 1_000e6);
            _cancelAll(cam, requestId);
        }

        bobRequestId = _requestDeposit(bob, 1_000e6);

        assertEq(bobRequestId, aliRequestId + cancellations + 1);

        _assertDepositNode(aliRequestId, ali, ali, 1_000e6 - 1, 0,            bobRequestId);
        _assertDepositNode(bobRequestId, bob, bob, 1_000e6 - 1, aliRequestId, 0);
        _assertDepositQueue(aliRequestId, bobRequestId, 2);

        _setCapacity(VAULT_CAPACITY);

        uint256 gasGriefed = _coldProcessGas();

        _assertDepositQueue(0, 0, 0);

        // The walk only visits the two live nodes, so the cancelled requests cost nothing.
        assertEq(gasGriefed, gasClean, "griefed walk costs more");
    }

}
