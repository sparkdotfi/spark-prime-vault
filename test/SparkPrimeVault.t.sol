// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase, SparkPrimeVault, ISparkVaultLike } from "./TestBase.t.sol";

contract SparkPrimeVaultTests is TestBase {

    address internal user = makeAddr("user");

    function setUp() public override {
        super.setUp();

        // Deal USDC to user
        deal(address(usdc), user, 1_000_000e6);

        skip(365 days);
    }

}

contract RequestDepositTests is SparkPrimeVaultTests {

    // Failure tests

    function test_requestDeposit_paused() external {
        _pause();

        vm.expectRevert("SparkPrimeVault/paused");
        vm.prank(user);
        spPRIME.requestDeposit(100e6, user);
    }

    function test_requestDeposit_zeroRecipient() external {
        vm.expectRevert("SparkPrimeVault/zero-recipient");
        vm.prank(user);
        spPRIME.requestDeposit(100e6, address(0));
    }

    function test_requestDeposit_vaultRecipient() external {
        vm.expectRevert("SparkPrimeVault/vault-recipient");
        vm.prank(user);
        spPRIME.requestDeposit(100e6, address(spPRIME));
    }

    function test_requestDeposit_belowMinimumBoundary() external {
        vm.prank(user);
        usdc.approve(address(spPRIME), MINIMUM_DEPOSIT);

        vm.expectRevert("SparkPrimeVault/below-minimum");
        vm.prank(user);
        spPRIME.requestDeposit(MINIMUM_DEPOSIT - 1, user);

        vm.prank(user);
        spPRIME.requestDeposit(MINIMUM_DEPOSIT, user);
    }

    function test_requestDeposit_notEnoughAllowanceBoundary() external {
        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        vm.prank(user);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        spPRIME.requestDeposit(1_000_000e6 + 1, user);

        vm.prank(user);
        spPRIME.requestDeposit(1_000_000e6, user);
    }

    // Success tests

    function test_requestDeposit_instantFill() external {
        _setCapacity(0);

        // No capacity, so requests 0 and 1 are queued in full
        _requestDeposit(user, 250_000e6);
        _requestDeposit(user, 250_000e6);

        // Request 1 is not the head, so cancelling it leaves a cancelled request behind request 0
        _requestDepositCancellation(user, 1);

        _setCapacity(VAULT_CAPACITY);

        // Process one request, request 0 is filled and the head stops at cancelled request 1
        _processPendingDeposits(1);

        uint256 setupSavingsShares = spUSDC.convertToShares(250_000e6);
        uint256 setupShares        = spPRIME.convertToShares(spUSDC.convertToAssets(setupSavingsShares));

        uint256 expectedSavingsShares = spUSDC.convertToShares(500_000e6);
        uint256 expectedAssets        = spUSDC.convertToAssets(expectedSavingsShares);
        uint256 expectedShares        = spPRIME.convertToShares(expectedAssets);

        assertEq(setupSavingsShares,    241_048.310401e6);
        assertEq(setupShares,           250_000e6 - 1); // Rounding
        assertEq(expectedSavingsShares, 482_096.620802e6);
        assertEq(expectedAssets,        500_000e6 - 1); // Rounding
        assertEq(expectedShares,        500_000e6 - 1); // Rounding

        vaultState.totalSupply           = setupShares;
        vaultState.totalAssets           = setupShares;
        vaultState.availableCapacity     = VAULT_CAPACITY - setupShares;
        vaultState.availableLiquidAssets = 500_000e6 - 1; // Rounding
        vaultState.rho                   = vm.getBlockTimestamp();
        vaultState.chi                   = RAY;

        // The head points at cancelled request 1
        vaultState.depositRequests.pendingShares  = 0;
        vaultState.depositRequests.length         = 1;
        vaultState.depositRequests.firstPendingId = 1;

        vaultState.depositCancellationRequests.pendingShares  = setupSavingsShares;
        vaultState.depositCancellationRequests.length         = 1;
        vaultState.depositCancellationRequests.firstPendingId = 1;

        AccountBalances memory userBalances = AccountBalances({
            account         : user,
            asset           : 500_000e6,
            shares          : setupShares,
            savingsShares   : 0,
            claimableAssets : 0
        });

        // Holds the filled request 0 and the cancelled request 1, which waits to be refunded
        AccountBalances memory vaultBalances = AccountBalances({
            account         : address(spPRIME),
            asset           : 0,
            shares          : 0,
            savingsShares   : 2 * setupSavingsShares,
            claimableAssets : 0
        });

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertDepositRequest(1, address(0), address(0), 0);

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 2, 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, expectedAssets, expectedShares);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 2);

        // The head moves past cancelled request 1 to request 2, which fills instantly
        vaultState.totalSupply           = setupShares + expectedShares;
        vaultState.totalAssets           = setupShares + expectedShares;
        vaultState.availableCapacity     = VAULT_CAPACITY - setupShares - expectedShares;
        vaultState.availableLiquidAssets = 1_000_000e6 - 1; // Rounding

        vaultState.depositRequests.pendingShares  = 0;
        vaultState.depositRequests.length         = 0;
        vaultState.depositRequests.firstPendingId = 3;

        userBalances.asset  = 0;
        userBalances.shares = setupShares + expectedShares;

        vaultBalances.savingsShares = 2 * setupSavingsShares + expectedSavingsShares;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

}
