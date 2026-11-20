// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl } from "../lib/oz/contracts/access/IAccessControl.sol";

import { TestBase } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

contract FrozenTests is TestBase {

    address internal user  = makeAddr("user");
    address internal user2 = makeAddr("user2");

    function _setFrozen(address account, bool frozen) internal {
        vm.prank(operator);
        spPrime.setFrozen(account, frozen);
    }

    function test_setFrozen_notOperator() external {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            address(this),
            OPERATOR_ROLE
        ));
        spPrime.setFrozen(user, true);
    }

    function test_setFrozen() external {
        assertEq(spPrime.frozen(user), false);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.FrozenSet(operator, user, true);

        _setFrozen(user, true);

        assertEq(spPrime.frozen(user), true);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.FrozenSet(operator, user, false);

        _setFrozen(user, false);

        assertEq(spPrime.frozen(user), false);
    }

    function test_requestDeposit_frozenOwner() external {
        _setFrozen(user, true);

        vm.prank(user);
        vm.expectRevert(ISparkPrimeVault.Frozen.selector);
        spPrime.requestDeposit(1_000_000e6, user2, 0);
    }

    function test_requestDeposit_frozenRecipient() external {
        _setFrozen(user2, true);

        vm.prank(user);
        vm.expectRevert(ISparkPrimeVault.Frozen.selector);
        spPrime.requestDeposit(1_000_000e6, user2, 0);
    }

    function test_requestRedeem_frozenOwner() external {
        _requestDeposit(user, 1_000_000e6);
        _setFrozen(user, true);

        vm.prank(user);
        vm.expectRevert(ISparkPrimeVault.Frozen.selector);
        spPrime.requestRedeem(1_000_000e6 - 1, user2);
    }

    function test_requestRedeem_frozenRecipient() external {
        _requestDeposit(user, 1_000_000e6);
        _setFrozen(user2, true);

        vm.prank(user);
        vm.expectRevert(ISparkPrimeVault.Frozen.selector);
        spPrime.requestRedeem(1_000_000e6 - 1, user2);
    }

    function test_transfer_frozenSender() external {
        _requestDeposit(user, 1_000_000e6);
        _setFrozen(user, true);

        vm.prank(user);
        vm.expectRevert(ISparkPrimeVault.Frozen.selector);
        spPrime.transfer(user2, 1);
    }

    function test_transfer_frozenRecipient() external {
        _requestDeposit(user, 1_000_000e6);
        _setFrozen(user2, true);

        vm.prank(user);
        vm.expectRevert(ISparkPrimeVault.Frozen.selector);
        spPrime.transfer(user2, 1);
    }

    function test_processPendingDeposits_frozenRequestBlocksQueueUntilRejected() external {
        _setCapacity(0);

        uint256 savingsShares = spUSDC.convertToShares(1_000_000e6);

        _requestDeposit(user,  1_000_000e6);
        _requestDeposit(user2, 1_000_000e6);

        _setFrozen(user, true);
        _setCapacity(VAULT_CAPACITY);

        // The frozen request at the head is not filled, and blocks the queue
        _processPendingDeposits();

        assertEq(spPrime.balanceOf(user),              0);
        assertEq(spPrime.balanceOf(user2),             0);
        assertEq(spPrime.processedDepositCount(),      0);
        assertEq(spPrime.pendingDepositSavingsShares(), savingsShares * 2);

        // The operator can't reject the request with another recipient
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        spPrime.requestDepositCancellation(0, operator, savingsShares);

        // The operator can't reject the request of an account that is not frozen
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        spPrime.requestDepositCancellation(1, user2, savingsShares);

        // The operator rejects the request by cancelling it on behalf of its owner
        vm.prank(operator);
        spPrime.requestDepositCancellation(0, user, savingsShares);

        _processPendingDeposits();

        assertEq(spPrime.balanceOf(user),              0);
        assertEq(spPrime.balanceOf(user2),             1_000_000e6 - 1);
        assertEq(spPrime.pendingDepositSavingsShares(), 0);

        // The assets of the rejected request are held as claimable assets
        _processPendingDepositCancellations(1);

        assertEq(usdc.balanceOf(user),            0);
        assertEq(spPrime.claimableAssetsOf(user), 1_000_000e6 - 1);

        vm.expectRevert(ISparkPrimeVault.Frozen.selector);
        spPrime.claim(user);

        _setFrozen(user, false);

        spPrime.claim(user);

        assertEq(usdc.balanceOf(user),            1_000_000e6 - 1);
        assertEq(spPrime.claimableAssetsOf(user), 0);
    }

    function test_processPendingRedeems_frozenOwnerAssetsHeld() external {
        _requestDeposit(user, 1_000_000e6);
        _requestRedeem(user, user2, 1_000_000e6 - 1);

        _setFrozen(user, true);

        _processPendingRedeems(1);

        // The assets are held as claimable assets of the frozen owner, not sent to the recipient
        assertEq(usdc.balanceOf(user2),            0);
        assertEq(spPrime.claimableAssetsOf(user2), 0);
        assertEq(spPrime.claimableAssetsOf(user),  1_000_000e6 - 2);
    }

    function test_processPendingRedeems_frozenRecipientAssetsHeld() external {
        _requestDeposit(user, 1_000_000e6);
        _requestRedeem(user, user2, 1_000_000e6 - 1);

        _setFrozen(user2, true);

        _processPendingRedeems(1);

        assertEq(usdc.balanceOf(user2),            0);
        assertEq(spPrime.claimableAssetsOf(user2), 1_000_000e6 - 2);
    }

}
