// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase, SparkPrimeVault, ISparkVaultLike } from "./TestBase.t.sol";

contract RequestDepositCancellationTests is TestBase {

    address internal user      = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    uint256 internal requestId;
    uint256 internal requestShares;

    AccountBalances internal userBalances;
    AccountBalances internal recipientBalances;
    AccountBalances internal vaultBalances;

    function setUp() public override {
        super.setUp();

        skip(365 days);

        vm.label(address(user),      "user");
        vm.label(address(recipient), "recipient");

        _setCapacity(0);

        requestId = _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Queued)

        ( , , requestShares ) = spPrime.getPendingDepositRequest(requestId);

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalAssets            = 0;
        vaultState.availableCapacityValue = 0;
        vaultState.availableLiquidAssets  = 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 1_000_000e6 - 1;
        vaultState.depositRequests.length            = 1;
        vaultState.depositRequests.firstPendingId    = 0;

        userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        recipientBalances = AccountBalances({
            account           : recipient,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssets   : 0
        });

        _assertVaultState();
        _assertDepositRequest(requestId, user, user, 1_000_000e6 - 1);

        _assertAccountBalances(userBalances);
        _assertAccountBalances(recipientBalances);
        _assertAccountBalances(vaultBalances);
    }

    // Failure tests

    function test_requestDepositCancellation_paused() external {
        _pause();

        vm.expectRevert(SparkPrimeVault.IsPaused.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(requestId, user, requestShares);
    }

    function test_requestDepositCancellation_zeroRecipient() external {
        vm.expectRevert(SparkPrimeVault.ZeroRecipient.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(requestId, address(0), requestShares);
    }

    function test_requestDepositCancellation_vaultRecipient() external {
        vm.expectRevert(SparkPrimeVault.VaultIsRecipient.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(requestId, address(spPrime), requestShares);
    }

    function test_requestDepositCancellation_recipientCannotReceive() external {
        _blacklist(recipient);

        vm.expectRevert(SparkPrimeVault.RecipientCannotReceive.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(requestId, recipient, requestShares);
    }

    function test_requestDepositCancellation_requestFilled() external {
        _setCapacity(VAULT_CAPACITY);

        _processPendingDeposits(type(uint256).max);

        vm.expectRevert(SparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(requestId, user, requestShares);
    }

    function test_requestDepositCancellation_notAuthorized() external {
        uint256 requestId2 = _requestDeposit(user, recipient, 1_000_000e6);

        ( , , uint256 requestShares2 ) = spPrime.getPendingDepositRequest(requestId2);

        // The deposit recipient cannot cancel, only the owner can.
        vm.expectRevert(SparkPrimeVault.NotRequestOwner.selector);
        vm.prank(recipient);
        spPrime.requestDepositCancellation(requestId2, recipient, requestShares2);

        vm.prank(user);
        spPrime.requestDepositCancellation(requestId2, recipient, requestShares2);
    }

    function test_requestDepositCancellation_belowMinimumBoundary() external {
        vm.expectRevert(SparkPrimeVault.BelowMinDepositCancellation.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(requestId, user, MINIMUM_DEPOSIT_CANCELLATION - 1);

        vm.prank(user);
        spPrime.requestDepositCancellation(requestId, user, MINIMUM_DEPOSIT_CANCELLATION);
    }

    function test_requestDepositCancellation_aboveRequestSharesBoundary() external {
        vm.expectRevert(SparkPrimeVault.SavingsSharesTooHigh.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(requestId, user, requestShares + 1);

        vm.prank(user);
        spPrime.requestDepositCancellation(requestId, user, requestShares);
    }

    // Success tests

    function test_requestDepositCancellation_full() external {
        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.DepositCancellationRequest(requestId, 0, recipient, requestShares);

        vm.prank(user);
        uint256 cancelRequestId = spPrime.requestDepositCancellation(requestId, recipient, requestShares);

        assertEq(cancelRequestId, 0);

        // The cancelled deposit request stays in the queue as an empty entry.

        vaultState.depositRequests.pendingShareValue = 0;

        vaultState.depositCancellationRequests.pendingShareValue = 1_000_000e6 - 1;
        vaultState.depositCancellationRequests.length            = 1;
        vaultState.depositCancellationRequests.firstPendingId    = 0;

        _assertVaultState();
        _assertDepositRequest(requestId, address(0), address(0), 0);
        _assertDepositCancellationRequest(cancelRequestId, user, recipient, 1_000_000e6 - 1);

        // No funds move until the cancellation is processed.

        _assertAccountBalances(userBalances);
        _assertAccountBalances(recipientBalances);
        _assertAccountBalances(vaultBalances);
    }

    function test_requestDepositCancellation_partial() external {
        uint256 cancelShares = spUSDC.convertToShares(400_000e6);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.DepositCancellationRequest(requestId, 0, recipient, cancelShares);

        vm.prank(user);
        uint256 cancelRequestId = spPrime.requestDepositCancellation(requestId, recipient, cancelShares);

        assertEq(cancelRequestId, 0);

        // The remainder of the deposit request stays queued.

        vaultState.depositRequests.pendingShareValue = 600_000e6 - 1;

        vaultState.depositCancellationRequests.pendingShareValue = 400_000e6 - 1;
        vaultState.depositCancellationRequests.length            = 1;
        vaultState.depositCancellationRequests.firstPendingId    = 0;

        _assertVaultState();
        _assertDepositRequest(requestId, user, user, 600_000e6 - 1);
        _assertDepositCancellationRequest(cancelRequestId, user, recipient, 400_000e6 - 1);

        // No funds move until the cancellation is processed.

        _assertAccountBalances(userBalances);
        _assertAccountBalances(recipientBalances);
        _assertAccountBalances(vaultBalances);
    }

}
