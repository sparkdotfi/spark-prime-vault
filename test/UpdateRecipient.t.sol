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

    function test_updateDepositRecipient_noRequest_invalidId() external {
        _requestDeposit(user, 1_000_000e6);  // Request 1 queued

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateDepositRecipient(0, user);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateDepositRecipient(2, user);

        vm.prank(user);
        spPrime.updateDepositRecipient(1, user);
    }

    function test_updateDepositRecipient_noRequest() external {
        _requestDeposit(user, 1_000_000e6);  // Request 1 queued
        _processPendingDeposits(1);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateDepositRecipient(1, user);
    }

    function test_updateDepositRecipient_notRequestOwner() external {
        _requestDeposit(user, 1_000_000e6);  // Request 1 queued

        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vm.prank(makeAddr("unauthorized"));
        spPrime.updateDepositRecipient(1, user);
    }

    function test_updateDepositRecipient() external {
        address newRecipient = makeAddr("newRecipient");

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

    function test_updateDepositCancellationRecipient_noRequest_invalidId() external {
        _requestDeposit(user, 1_000_000e6);                                         // Request 1 queued
        _requestDepositCancellation(user, 1, spUSDC.convertToShares(1_000_000e6));  // Request 2 cancellation queued

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(0, user);

        // Request 1 is not a pending deposit cancellation
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(1, user);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(3, user);

        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(2, user);
    }

    function test_updateDepositCancellationRecipient_noRequest() external {
        _requestDeposit(user, 1_000_000e6);                                         // Request 1 queued
        _requestDepositCancellation(user, 1, spUSDC.convertToShares(1_000_000e6));  // Request 2 cancellation queued
        _processPendingDepositCancellations(1);                                     // Request 2 processed

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(2, user);
    }

    function test_updateDepositCancellationRecipient_notRequestOwner() external {
        _requestDeposit(user, 1_000_000e6);                                         // Request 1 queued
        _requestDepositCancellation(user, 1, spUSDC.convertToShares(1_000_000e6));  // Request 2 cancellation queued

        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vm.prank(makeAddr("unauthorized"));
        spPrime.updateDepositCancellationRecipient(2, user);
    }

    function test_updateDepositCancellationRecipient() external {
        address newRecipient = makeAddr("newRecipient");

        _requestDeposit(user, 1_000_000e6);                                         // Request 1 queued
        _requestDepositCancellation(user, 1, spUSDC.convertToShares(1_000_000e6));  // Request 2 cancellation queued

        _assertDepositCancellationRequest(2, user, user, 1_000_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellationRecipientUpdated(2, newRecipient);

        vm.prank(user);
        spPrime.updateDepositCancellationRecipient(2, newRecipient);

        _assertDepositCancellationRequest(2, user, newRecipient, 1_000_000e6 - 1);
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

    function test_updateRedeemRecipient_noRequest_invalidId() external {
        _requestDeposit(user, 1_000_000e6);  // Request 1 queued
        _processPendingDeposits(1);
        _requestRedeem(user,  100e6);        // Request 2 redeem queued

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateRedeemRecipient(0, user);

        // Request 1 is not a pending redeem
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateRedeemRecipient(1, user);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateRedeemRecipient(3, user);

        vm.prank(user);
        spPrime.updateRedeemRecipient(2, user);
    }

    function test_updateRedeemRecipient_noRequest() external {
        _requestDeposit(user, 1_000_000e6);  // Request 1 queued
        _processPendingDeposits(1);
        _requestRedeem(user,  100e6);        // Request 2 redeem queued

        _processPendingRedeems(1);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.updateRedeemRecipient(2, user);
    }

    function test_updateRedeemRecipient_notRequestOwner() external {
        _requestDeposit(user, 1_000_000e6);  // Request 1 queued
        _processPendingDeposits(1);
        _requestRedeem(user,  100e6);        // Request 2 redeem queued

        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vm.prank(makeAddr("unauthorized"));
        spPrime.updateRedeemRecipient(2, user);
    }

    function test_updateRedeemRecipient() external {
        address newRecipient = makeAddr("newRecipient");

        _requestDeposit(user, 1_000_000e6);  // Request 1 queued
        _processPendingDeposits(1);
        _requestRedeem(user,  1_000_000e6 - 1);  // Request 2 redeem queued

        _assertRedeemRequest(2, user, user, 1_000_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.RedeemRecipientUpdated(2, newRecipient);

        vm.prank(user);
        spPrime.updateRedeemRecipient(2, newRecipient);

        _assertRedeemRequest(2, user, newRecipient, 1_000_000e6 - 1);
    }

}
