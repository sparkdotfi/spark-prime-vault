// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase, SparkPrimeVault } from "./TestBase.t.sol";

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
        vm.expectRevert("SparkPrimeVault/zero-recipient");
        vm.prank(user);
        spPrime.updateDepositRecipient(0, address(0));
    }

    function test_updateDepositRecipient_vaultRecipient() external {
        vm.expectRevert("SparkPrimeVault/vault-recipient");
        vm.prank(user);
        spPrime.updateDepositRecipient(0, address(spPrime));
    }

    function test_updateDepositRecipient_invalidRequestIdBoundary() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vm.prank(user);
        spPrime.updateDepositRecipient(1, user);

        vm.prank(user);
        spPrime.updateDepositRecipient(0, user);
    }

    function test_updateDepositRecipient_noRequest() external {
        _requestDeposit(user, 1_000_000e6); // Request 0 filled instantly

        vm.expectRevert("SparkPrimeVault/no-request");
        vm.prank(user);
        spPrime.updateDepositRecipient(0, user);
    }

    function test_updateDepositRecipient_notAuthorized() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6); // Request 0 queued

        vm.expectRevert("SparkPrimeVault/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        spPrime.updateDepositRecipient(0, user);

        vm.prank(user);
        spPrime.updateDepositRecipient(0, user);
    }

    function test_updateDepositRecipient() external {
        address newRecipient = makeAddr("newRecipient");

        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6); // Request 0 queued

        _assertDepositRequest(0, user, user, 1_000_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.DepositRecipientUpdated(0, newRecipient);

        vm.prank(user);
        spPrime.updateDepositRecipient(0, newRecipient);

        _assertDepositRequest(0, user, newRecipient, 1_000_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** updateDepositCancellationRecipient                                                     ***/
    /**********************************************************************************************/

    function test_updateDepositCancellationRecipient_zeroRecipient() external {
        vm.expectRevert("SparkPrimeVault/zero-recipient");
        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(0, address(0));
    }

    function test_updateDepositCancellationRecipient_vaultRecipient() external {
        vm.expectRevert("SparkPrimeVault/vault-recipient");
        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(0, address(spPrime));
    }

    function test_updateDepositCancellationRecipient_recipientCannotReceive() external {
        _blacklist(user);

        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(0, user);
    }

    function test_updateDepositCancellationRecipient_invalidRequestIdBoundary() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);   // Request 0 queued
        _requestDepositCancellation(user, 0); // Request 0 cancellation queued

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(1, user);

        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(0, user);
    }

    function test_updateDepositCancellationRecipient_noRequest() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);     // Request 0 queued
        _requestDepositCancellation(user, 0);   // Request 0 cancellation queued
        _processPendingDepositCancellations(1); // Request 0 processed

        vm.expectRevert("SparkPrimeVault/no-request");
        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(0, user);
    }

    function test_updateDepositCancellationRecipient_notAuthorized() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);   // Request 0 queued
        _requestDepositCancellation(user, 0); // Request 0 cancellation queued

        vm.expectRevert("SparkPrimeVault/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        spPrime.updateDepositCancellationRecipient(0, user);

        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(0, user);
    }

    function test_updateDepositCancellationRecipient() external {
        address newRecipient = makeAddr("newRecipient");

        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);   // Request 0 queued
        _requestDepositCancellation(user, 0); // Request 0 cancellation queued

        _assertDepositCancellationRequest(0, user, user, 1_000_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.DepositCancellationRecipientUpdated(0, newRecipient);

        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(0, newRecipient);

        _assertDepositCancellationRequest(0, user, newRecipient, 1_000_000e6 - 1);
    }

    /**********************************************************************************************/
    /*** updateRedeemRecipient                                                                  ***/
    /**********************************************************************************************/

    function test_updateRedeemRecipient_zeroRecipient() external {
        vm.expectRevert("SparkPrimeVault/zero-recipient");
        vm.prank(user);
        spPrime.updateRedeemRecipient(0, address(0));
    }

    function test_updateRedeemRecipient_vaultRecipient() external {
        vm.expectRevert("SparkPrimeVault/vault-recipient");
        vm.prank(user);
        spPrime.updateRedeemRecipient(0, address(spPrime));
    }

    function test_updateRedeemRecipient_recipientCannotReceive() external {
        _blacklist(user);

        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vm.prank(user);
        spPrime.updateRedeemRecipient(0, user);
    }

    function test_updateRedeemRecipient_invalidRequestIdBoundary() external {
        _requestDeposit(user, 1_000_000e6); // Request 0 filled instantly
        _requestRedeem(user,  100e6);       // Request 0 redeem queued

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vm.prank(user);
        spPrime.updateRedeemRecipient(1, user);

        vm.prank(user);
        spPrime.updateRedeemRecipient(0, user);
    }

    function test_updateRedeemRecipient_noRequest() external {
        _requestDeposit(user, 1_000_000e6); // Request 0 filled instantly
        _requestRedeem(user,  100e6);       // Request 0 redeem queued

        _processPendingRedeems(1);

        vm.expectRevert("SparkPrimeVault/no-request");
        vm.prank(user);
        spPrime.updateRedeemRecipient(0, user);
    }

    function test_updateRedeemRecipient_notAuthorized() external {
        _requestDeposit(user, 1_000_000e6); // Request 0 filled instantly
        _requestRedeem(user,  100e6);       // Request 0 redeem queued

        vm.expectRevert("SparkPrimeVault/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        spPrime.updateRedeemRecipient(0, user);

        vm.prank(user);
        spPrime.updateRedeemRecipient(0, user);
    }

    function test_updateRedeemRecipient() external {
        address newRecipient = makeAddr("newRecipient");

        _requestDeposit(user, 1_000_000e6);     // Request 0 filled instantly
        _requestRedeem(user,  1_000_000e6 - 1); // Request 0 redeem queued
        
        _assertRedeemRequest(0, user, user, 1_000_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.RedeemRecipientUpdated(0, newRecipient);

        vm.prank(user);
        spPrime.updateRedeemRecipient(0, newRecipient);

        _assertRedeemRequest(0, user, newRecipient, 1_000_000e6 - 1);
    }

}
