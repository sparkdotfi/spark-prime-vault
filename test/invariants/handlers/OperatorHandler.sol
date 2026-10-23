// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { HandlerBase } from "./HandlerBase.sol";

contract OperatorHandler is HandlerBase {

    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // Below the overflow bound of availableCapacity() * chi.
    uint256 internal constant MAX_CAPACITY = 1e30;

    address public operator;

    bool public ratesMoved;

    constructor(address vault_) HandlerBase(vault_) {
        operator = vault.getRoleMember(OPERATOR_ROLE, 0);
    }

    function processPendingDeposits(uint256 maxSavingsShares, uint256 maxRequests) public accountingCheck {
        if (vault.paused()) return;

        vm.prank(operator);
        vault.processPendingDeposits(_bound(maxSavingsShares, 0, MAX_AMOUNT), _bound(maxRequests, 0, 20));
    }

    // Intentionally not pause gated: callable while paused.
    function processPendingDepositCancellations(uint256 maxSavingsShares, uint256 maxRequests) public accountingCheck {
        vm.prank(operator);
        vault.processPendingDepositCancellations(_bound(maxSavingsShares, 0, MAX_AMOUNT), _bound(maxRequests, 0, 20));
    }

    function processPendingRedeems(uint256 maxShares, uint256 maxRequests) public accountingCheck {
        if (vault.paused()) return;

        vm.prank(operator);
        vault.processPendingRedeems(_bound(maxShares, 0, MAX_AMOUNT), _bound(maxRequests, 0, 20));
    }

    function setVSR(uint256 vsr) public accountingCheck {
        vsr = _bound(vsr, vault.minVSR(), vault.maxVSR());

        if (vsr > RAY) ratesMoved = true;

        vm.prank(operator);
        vault.setVSR(vsr);
    }

    function setCapacity(uint256 capacity) public accountingCheck {
        vm.prank(operator);
        vault.setCapacity(_bound(capacity, 0, MAX_CAPACITY));
    }

}
