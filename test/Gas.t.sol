// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { console2 } from "../lib/forge-std/src/console2.sol";

import { TestBase } from "./TestBase.t.sol";

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
 * @dev Gas measurements for the deposit queue, used to compare the array queue on master with the
 *      linked-list queue. Every measurement is a single external call made from cold storage, and
 *      storage refunds are netted out with the EIP-3529 cap applied, so the numbers are
 *      comparable across branches and close to what a transaction pays on top of its intrinsic
 *      cost. Refunds matter here: the linked list resets its head, tail and counter to zero
 *      whenever the queue empties. Run with `forge test --mc GasTests -vv`.
 */
contract GasTests is TestBase {

    uint256 internal constant TOMBSTONES = 200;

    address internal user  = makeAddr("user");
    address internal other = makeAddr("other");

    function setUp() public override {
        super.setUp();

        skip(365 days);

        // Steady state: both accounts already hold shares, so no measurement pays for a
        // zero-to-nonzero balance or total supply.
        _requestDeposit(user,  1_000e6);
        _requestDeposit(other, 1_000e6);

        deal(address(usdc), user,  1_000_000_000e6);
        deal(address(usdc), other, 1_000_000_000e6);

        vm.prank(user);
        usdc.approve(address(spPrime), type(uint256).max);

        vm.prank(other);
        usdc.approve(address(spPrime), type(uint256).max);
    }

    // Gas spent by the last call net of its storage refund, capped at a fifth of the gas spent.
    function _netGas() internal view returns (uint256 gas) {
        IVmGasLike.Gas memory lastCall = IVmGasLike(address(vm)).lastCallGas();

        uint256 spent    = lastCall.gasTotalUsed;
        uint256 refunded = lastCall.gasRefunded > 0 ? uint256(uint64(lastCall.gasRefunded)) : 0;

        return spent - _min(refunded, spent / 5);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // Every measured call starts from cold storage, as a real transaction would.
    function _cool() internal {
        vm.cool(address(spPrime));
        vm.cool(address(spUSDC));
        vm.cool(address(usdc));
    }

    function _requestDepositGas(address account, uint256 assets)
        internal
        returns (uint256 requestId, uint256 gas)
    {
        _cool();
        vm.prank(account);
        requestId = spPrime.requestDeposit(assets, account, 0);
        gas       = _netGas();
    }

    function _cancelGas(address account, uint256 requestId, uint256 savingsShares)
        internal
        returns (uint256 gas)
    {
        _cool();
        vm.prank(account);
        spPrime.requestDepositCancellation(requestId, account, savingsShares);
        gas = _netGas();
    }

    function _processGas(uint256 maxRequests) internal returns (uint256 gas) {
        _cool();
        vm.prank(operator);
        spPrime.processPendingDeposits(type(uint256).max, maxRequests);
        gas = _netGas();
    }

    function _shares(uint256 requestId) internal view returns (uint256 shares) {
        ( , , shares ) = spPrime.getPendingDepositRequest(requestId);
    }

    function test_gas_requestDeposit_instantFill() external {
        ( , uint256 gas ) = _requestDepositGas(user, 1_000e6);

        console2.log("requestDeposit instant fill:", gas);
    }

    function test_gas_requestDeposit_queued() external {
        _setCapacity(0);

        _requestDeposit(other, 1_000e6);  // Live head, so the new request is queued behind it.

        ( , uint256 gas ) = _requestDepositGas(user, 1_000e6);

        console2.log("requestDeposit queued:", gas);
    }

    function test_gas_requestDepositCancellation_full() external {
        _setCapacity(0);

        _requestDeposit(other, 1_000e6);
        uint256 requestId = _requestDeposit(user, 1_000e6);  // Middle of three
        _requestDeposit(other, 1_000e6);

        uint256 gas = _cancelGas(user, requestId, _shares(requestId));

        console2.log("requestDepositCancellation full (middle node):", gas);
    }

    function test_gas_requestDepositCancellation_fullHead() external {
        _setCapacity(0);

        uint256 requestId = _requestDeposit(user, 1_000e6);  // Head of two
        _requestDeposit(other, 1_000e6);

        uint256 gas = _cancelGas(user, requestId, _shares(requestId));

        console2.log("requestDepositCancellation full (head node):", gas);
    }

    function test_gas_requestDepositCancellation_partial() external {
        _setCapacity(0);

        _requestDeposit(other, 1_000e6);
        uint256 requestId = _requestDeposit(user, 1_000e6);
        _requestDeposit(other, 1_000e6);

        uint256 gas = _cancelGas(user, requestId, _shares(requestId) / 2);

        console2.log("requestDepositCancellation partial (middle node):", gas);
    }

    function test_gas_processPendingDeposits_perRequest() external {
        _setCapacity(0);

        for (uint256 i; i < 6; ++i) _requestDeposit(user, 1_000e6);

        _setCapacity(VAULT_CAPACITY);

        uint256 gasOne  = _processGas(1);
        uint256 gasFour = _processGas(4);

        console2.log("processPendingDeposits 1 request:", gasOne);
        console2.log("processPendingDeposits 4 requests:", gasFour);
        console2.log("processPendingDeposits marginal per request:", (gasFour - gasOne) / 3);
    }

    function test_gas_processPendingDeposits_behindTombstones() external {
        _setCapacity(0);

        _requestDeposit(other, 1_000e6);  // Live head blocks instant fills.

        // Reference: fill one request queued behind the head with nothing between them.
        uint256 cleanRequestId = _requestDeposit(user, 1_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processGas(1);  // Fill the head so `cleanRequestId` is the new head.

        // Unbounded request budget, as in the automatic fills in the request functions.
        uint256 gasClean = _processGas(type(uint256).max);
        assertEq(spPrime.pendingDepositSavingsShares(), 0, "clean fill");

        // Griefed: the same shape, but with TOMBSTONES fully cancelled requests between the head
        // and the request being filled.
        _setCapacity(0);

        _requestDeposit(other, 1_000e6);  // Live head blocks instant fills.

        for (uint256 i; i < TOMBSTONES; ++i) {
            uint256 id = _requestDeposit(user, 1_000e6);
            _requestDepositCancellation(user, id, _shares(id));
        }

        uint256 griefedRequestId = _requestDeposit(user, 1_000e6);

        _setCapacity(VAULT_CAPACITY);
        _processGas(1);  // Fill the head.

        // On master this walks over the TOMBSTONES entries before reaching the live request.
        uint256 gasGriefed = _processGas(type(uint256).max);
        assertEq(spPrime.pendingDepositSavingsShares(), 0, "griefed fill");

        console2.log("fill after 0 tombstones:  ", gasClean);
        console2.log("fill after 200 tombstones:", gasGriefed);

        cleanRequestId; griefedRequestId;
    }

}
