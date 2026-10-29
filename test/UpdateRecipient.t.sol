// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

contract UpdateRecipientTests is TestBase {

    address internal user = makeAddr("user");

    function setUp() public override virtual {
        super.setUp();

        vm.label(user, "user");
    }

    /**********************************************************************************************/
    /*** updateDepositRecipient                                                                 ***/
    /**********************************************************************************************/

    function test_updateDepositRecipient_zeroRecipient() external {
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vm.prank(user);
        spPrime.updateDepositRecipient(0, address(0));
    }

    function test_updateDepositRecipient_vaultIsRecipient() external {
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vm.prank(user);
        spPrime.updateDepositRecipient(0, address(spPrime));
    }

    function test_updateDepositRecipient_invalidRequestIdBoundary() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vm.prank(user);
        spPrime.updateDepositRecipient(2, user);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vm.prank(user);
        spPrime.updateDepositRecipient(0, user);  // 0 is the null pointer

        vm.prank(user);
        spPrime.updateDepositRecipient(1, user);
    }

    function test_updateDepositRecipient_noRequest() external {
        _requestDeposit(user, 1_000_000e6);  // Request 1 filled instantly

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateDepositRecipient(1, user);
    }

    function test_updateDepositRecipient_notRequestOwner() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);  // Request 1 queued

        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vm.prank(makeAddr("unauthorized"));
        spPrime.updateDepositRecipient(1, user);
    }

    function test_updateDepositRecipient() external {
        address newRecipient = makeAddr("newRecipient");

        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);  // Request 1 queued

        _assertDepositRequest(1, user, user, 1_000_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositRecipientUpdated(1, newRecipient);

        vm.prank(user);
        spPrime.updateDepositRecipient(1, newRecipient);

        _assertDepositRequest(1, user, newRecipient, 1_000_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** updateDepositCancellationRecipient                                                     ***/
    /**********************************************************************************************/

    function test_updateDepositCancellationRecipient_zeroRecipient() external {
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(0, address(0));
    }

    function test_updateDepositCancellationRecipient_vaultIsRecipient() external {
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(0, address(spPrime));
    }

    function test_updateDepositCancellationRecipient_invalidRequestIdBoundary() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);                                         // Deposit request 1 queued
        _requestDepositCancellation(user, 1, spUSDC.convertToShares(1_000_000e6));  // Cancellation request 0 queued

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(1, user);

        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(0, user);
    }

    function test_updateDepositCancellationRecipient_noRequest() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);                                         // Deposit request 1 queued
        _requestDepositCancellation(user, 1, spUSDC.convertToShares(1_000_000e6));  // Cancellation request 0 queued
        _processPendingDepositCancellations(1);                                     // Cancellation request 0 processed

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(0, user);
    }

    function test_updateDepositCancellationRecipient_notRequestOwner() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);                                         // Deposit request 1 queued
        _requestDepositCancellation(user, 1, spUSDC.convertToShares(1_000_000e6));  // Cancellation request 0 queued

        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vm.prank(makeAddr("unauthorized"));
        spPrime.updateDepositCancellationRecipient(0, user);
    }

    function test_updateDepositCancellationRecipient() external {
        address newRecipient = makeAddr("newRecipient");

        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);                                         // Deposit request 1 queued
        _requestDepositCancellation(user, 1, spUSDC.convertToShares(1_000_000e6));  // Cancellation request 0 queued

        _assertDepositCancellationRequest(0, user, user, 1_000_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellationRecipientUpdated(0, newRecipient);

        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(0, newRecipient);

        _assertDepositCancellationRequest(0, user, newRecipient, 1_000_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** updateRedeemRecipient                                                                  ***/
    /**********************************************************************************************/

    function test_updateRedeemRecipient_zeroRecipient() external {
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vm.prank(user);
        spPrime.updateRedeemRecipient(0, address(0));
    }

    function test_updateRedeemRecipient_vaultIsRecipient() external {
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vm.prank(user);
        spPrime.updateRedeemRecipient(0, address(spPrime));
    }

    function test_updateRedeemRecipient_invalidRequestIdBoundary() external {
        _requestDeposit(user, 1_000_000e6);  // Deposit request 1 filled instantly
        _requestRedeem(user,  100e6);        // Request 0 redeem queued

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vm.prank(user);
        spPrime.updateRedeemRecipient(1, user);

        vm.prank(user);
        spPrime.updateRedeemRecipient(0, user);
    }

    function test_updateRedeemRecipient_noRequest() external {
        _requestDeposit(user, 1_000_000e6);  // Deposit request 1 filled instantly
        _requestRedeem(user,  100e6);        // Request 0 redeem queued

        _processPendingRedeems(1);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateRedeemRecipient(0, user);
    }

    function test_updateRedeemRecipient_notRequestOwner() external {
        _requestDeposit(user, 1_000_000e6);  // Deposit request 1 filled instantly
        _requestRedeem(user,  100e6);        // Request 0 redeem queued

        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vm.prank(makeAddr("unauthorized"));
        spPrime.updateRedeemRecipient(0, user);
    }

    function test_updateRedeemRecipient() external {
        address newRecipient = makeAddr("newRecipient");

        _requestDeposit(user, 1_000_000e6);      // Deposit request 1 filled instantly
        _requestRedeem(user,  1_000_000e6 - 1);  // Request 0 redeem queued

        _assertRedeemRequest(0, user, user, 1_000_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.RedeemRecipientUpdated(0, newRecipient);

        vm.prank(user);
        spPrime.updateRedeemRecipient(0, newRecipient);

        _assertRedeemRequest(0, user, newRecipient, 1_000_000e6 - 1);
    }

}
