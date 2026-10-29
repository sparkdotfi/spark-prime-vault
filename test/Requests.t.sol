// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase, ISparkVaultLike } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

contract RequestDepositCancellationTests is TestBase {

    address internal user      = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    uint256 internal depositRequestId;
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

        depositRequestId = _requestDeposit(user, 1_000_000e6);  // Deposit Request 1 (Queued)

        ( , , requestShares ) = spPrime.getPendingDepositRequest(depositRequestId);

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalAssets            = 0;
        vaultState.availableCapacityValue = 0;
        vaultState.availableLiquidAssets  = 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 1_000_000e6 - 1;
        vaultState.depositRequests.length            = 1;
        vaultState.depositRequests.firstPendingId    = 1;

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
        _assertDepositRequest(depositRequestId, user, user, 1_000_000e6 - 1);

        _assertAccountBalances(userBalances);
        _assertAccountBalances(recipientBalances);
        _assertAccountBalances(vaultBalances);
    }

    // Failure tests

    function test_requestDepositCancellation_zeroRecipient() external {
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(depositRequestId, address(0), requestShares);
    }

    function test_requestDepositCancellation_vaultIsRecipient() external {
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(depositRequestId, address(spPrime), requestShares);
    }

    function test_requestDepositCancellation_invalidRequestIdBoundary() external {
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(2, recipient, requestShares);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(0, recipient, requestShares);  // 0 is the null pointer

        vm.prank(user);
        spPrime.requestDepositCancellation(1, recipient, requestShares);
    }

    function test_requestDepositCancellation_noRequest() external {
        _setCapacity(VAULT_CAPACITY);

        _processPendingDeposits(type(uint256).max);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(depositRequestId, user, requestShares);
    }

    function test_requestDepositCancellation_notRequestOwner() external {
        uint256 requestId2 = _requestDeposit(user, recipient, 1_000_000e6);

        ( , , uint256 requestShares2 ) = spPrime.getPendingDepositRequest(requestId2);

        // The deposit recipient cannot cancel, only the owner can.
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vm.prank(recipient);
        spPrime.requestDepositCancellation(requestId2, recipient, requestShares2);

        vm.prank(user);
        spPrime.requestDepositCancellation(requestId2, recipient, requestShares2);
    }

    function test_requestDepositCancellation_belowMinDepositCancellationBoundary() external {
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(depositRequestId, user, MINIMUM_DEPOSIT_CANCELLATION - 1);

        vm.prank(user);
        spPrime.requestDepositCancellation(depositRequestId, user, MINIMUM_DEPOSIT_CANCELLATION);
    }

    function test_requestDepositCancellation_savingsSharesTooHighBoundary() external {
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vm.prank(user);
        spPrime.requestDepositCancellation(depositRequestId, user, requestShares + 1);

        vm.prank(user);
        spPrime.requestDepositCancellation(depositRequestId, user, requestShares);
    }

    // Success tests

    function test_requestDepositCancellation_whilePaused() external {
        _pause();

        vm.prank(user);
        spPrime.requestDepositCancellation(depositRequestId, recipient, requestShares);
    }

    function test_requestDepositCancellation_full() external {
        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellationRequest(depositRequestId, 0, recipient, requestShares);

        vm.prank(user);
        uint256 cancelRequestId = spPrime.requestDepositCancellation(depositRequestId, recipient, requestShares);

        assertEq(cancelRequestId, 0);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        spPrime.getPendingDepositRequest(depositRequestId);

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 0;

        vaultState.depositCancellationRequests.pendingShareValue = 1_000_000e6 - 1;
        vaultState.depositCancellationRequests.length            = 1;
        vaultState.depositCancellationRequests.firstPendingId    = 0;

        _assertVaultState();
        _assertDepositCancellationRequest(cancelRequestId, user, recipient, 1_000_000e6 - 1);

        // No funds move until the cancellation is processed.

        _assertAccountBalances(userBalances);
        _assertAccountBalances(recipientBalances);
        _assertAccountBalances(vaultBalances);
    }

    function test_requestDepositCancellation_partial() external {
        uint256 cancelShares = spUSDC.convertToShares(400_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellationRequest(depositRequestId, 0, recipient, cancelShares);

        vm.prank(user);
        uint256 cancelRequestId = spPrime.requestDepositCancellation(depositRequestId, recipient, cancelShares);

        assertEq(cancelRequestId, 0);

        // The remainder of the deposit request stays queued.

        vaultState.depositRequests.pendingShareValue = 600_000e6 - 1;

        vaultState.depositCancellationRequests.pendingShareValue = 400_000e6 - 1;
        vaultState.depositCancellationRequests.length            = 1;
        vaultState.depositCancellationRequests.firstPendingId    = 0;

        _assertVaultState();
        _assertDepositRequest(depositRequestId, user, user, 600_000e6 - 1);
        _assertDepositCancellationRequest(cancelRequestId, user, recipient, 400_000e6 - 1);

        // No funds move until the cancellation is processed.

        _assertAccountBalances(userBalances);
        _assertAccountBalances(recipientBalances);
        _assertAccountBalances(vaultBalances);
    }

}
