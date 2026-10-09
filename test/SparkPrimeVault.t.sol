// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase, SparkPrimeVault, ISparkVaultLike } from "./TestBase.t.sol";

contract SparkPrimeVaultTests is TestBase {

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        spPRIME.setCapacity(VAULT_CAPACITY);
        spPRIME.setMinimums(MINIMUM_DEPOSIT, MINIMUM_WITHDRAW);
        vm.stopPrank();

        // Deal USDC to user
        deal(address(usdc), user, 1_000_000e6);
    }

}

contract RequestDepositTests is SparkPrimeVaultTests {

    // Failure tests

    function test_requestDeposit_invalidRecipient() external {
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        spPRIME.requestDeposit(100e6, address(0));
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
        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                  : 0,
            totalAssets                  : 0,
            availableCapacity            : VAULT_CAPACITY,
            availableLiquidAssets        : 0,
            unencumberedSparkVaultShares : 0,
            chi                          : RAY,
            rho                          : block.timestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            encumberedShares : 0,
            head             : 0
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 1_000_000e6,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory vaultBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);

        assertEq(usdc.allowance(user, address(spPRIME)), 1_000_000e6);

        uint256 expectedSavingsShares = spUSDC.convertToShares(1_000_000e6);

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 1_000_000e6);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, 1_000_000e6 - 1, 1_000_000e6 - 1); // Rounding

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(1_000_000e6, user);

        assertEq(requestId, 0);

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vaultState.totalSupply                  = 1_000_000e6 - 1; // Rounding
        vaultState.totalAssets                  = 1_000_000e6 - 1; // Rounding
        vaultState.availableCapacity            = VAULT_CAPACITY - 1_000_000e6 + 1; // Rounding
        vaultState.availableLiquidAssets        = 1_000_000e6 - 1; // Rounding
        vaultState.unencumberedSparkVaultShares = expectedSavingsShares;

        depositQueueState.head = 1;

        userBalances.asset  = 0;
        userBalances.shares = 1_000_000e6 - 1; // Rounding

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, 0);
    }

    function test_requestDeposit_instantFillMultipleRequests() external {
        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                  : 0,
            totalAssets                  : 0,
            availableCapacity            : VAULT_CAPACITY,
            availableLiquidAssets        : 0,
            unencumberedSparkVaultShares : 0,
            chi                          : RAY,
            rho                          : block.timestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            encumberedShares : 0,
            head             : 0
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 1_000_000e6,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory vaultBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);

        // Request 1 with 500k USDC

        assertEq(usdc.allowance(user, address(spPRIME)), 1_000_000e6);

        uint256 expectedSavingsShares = spUSDC.convertToShares(500_000e6);

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 500_000e6);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, 500_000e6 - 1, 500_000e6 - 1); // Rounding

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 0);

        assertEq(usdc.allowance(user, address(spPRIME)), 500_000e6);

        vaultState.totalSupply                  = 500_000e6 - 1; // Rounding
        vaultState.totalAssets                  = 500_000e6 - 1; // Rounding
        vaultState.availableCapacity            = VAULT_CAPACITY - 500_000e6 + 1; // Rounding
        vaultState.availableLiquidAssets        = 500_000e6 - 1; // Rounding
        vaultState.unencumberedSparkVaultShares = expectedSavingsShares;

        depositQueueState.head = 1;

        userBalances.asset  = 500_000e6;
        userBalances.shares = 500_000e6 - 1; // Rounding

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, 0);

        // Request 2 with 500k USDC

        expectedSavingsShares = spUSDC.convertToShares(500_000e6);

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 1, 500_000e6);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, 500_000e6 - 1, 500_000e6 - 1); // Rounding

        vm.prank(user);
        requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 1);

        vaultState.totalSupply                  = 1_000_000e6 - 2; // Rounding
        vaultState.totalAssets                  = 1_000_000e6 - 2; // Rounding
        vaultState.availableCapacity            = VAULT_CAPACITY - 1_000_000e6 + 2; // Rounding
        vaultState.availableLiquidAssets        = 1_000_000e6 - 1; // Rounding
        vaultState.unencumberedSparkVaultShares += expectedSavingsShares;

        depositQueueState.head = 2;

        userBalances.asset  = 0;
        userBalances.shares = 1_000_000e6 - 2; // Rounding

        vaultBalances.savingsShares += expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, 0);
    }
    

}
