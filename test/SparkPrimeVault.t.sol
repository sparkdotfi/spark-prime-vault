// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase, SparkPrimeVault, ISparkVaultLike } from "./TestBase.t.sol";

contract SparkPrimeVaultTests is TestBase {

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        spPRIME.grantRole(SETTER_ROLE, setter);

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

    function test_requestDeposit_instantFill_exactCapacity() external {
        vm.prank(admin);
        spPRIME.setCapacity(1_000_000e6);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                  : 0,
            totalAssets                  : 0,
            availableCapacity            : 1_000_000e6,
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

        // spUSDC rounding credits 1 wei less than deposited, so 1 share of capacity is left over
        vaultState.totalSupply                  = 1_000_000e6 - 1; // Rounding
        vaultState.totalAssets                  = 1_000_000e6 - 1; // Rounding
        vaultState.availableCapacity            = 1;               // Rounding
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

    function test_requestDeposit_instantFill_afterInterestAccrual() external {
        uint256 deployTimestamp = block.timestamp;

        vm.prank(admin);
        spPRIME.setVSRBounds(RAY, MAX_VSR);

        vm.prank(setter);
        spPRIME.setVSR(FIVE_PCT_VSR);

        skip(365 days);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                  : 0,
            totalAssets                  : 0,
            availableCapacity            : VAULT_CAPACITY,
            availableLiquidAssets        : 0,
            unencumberedSparkVaultShares : 0,
            chi                          : RAY,
            rho                          : deployTimestamp
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

        uint256 expectedChi = spPRIME.nowChi();

        // 5% APY over one year
        assertApproxEqRel(expectedChi, 1.05e27, 0.0001e18);

        uint256 expectedSavingsShares = spUSDC.convertToShares(1_000_000e6);
        uint256 expectedAssets        = spUSDC.convertToAssets(expectedSavingsShares);
        uint256 expectedShares        = expectedAssets * RAY / expectedChi;

        // Shares are minted at the accrued chi, so fewer shares than assets
        assertLt(expectedShares, expectedAssets);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Drip(uint192(expectedChi), 0);  // No supply yet, so no diff

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 1_000_000e6);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, expectedAssets, expectedShares);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(1_000_000e6, user);

        assertEq(requestId, 0);

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vaultState.totalSupply                  = expectedShares;
        vaultState.totalAssets                  = expectedShares * expectedChi / RAY;
        vaultState.availableCapacity            = VAULT_CAPACITY - expectedShares;
        vaultState.availableLiquidAssets        = expectedAssets;
        vaultState.unencumberedSparkVaultShares = expectedSavingsShares;
        vaultState.chi                          = expectedChi;
        vaultState.rho                          = block.timestamp;

        depositQueueState.head = 1;

        userBalances.asset  = 0;
        userBalances.shares = expectedShares;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, 0);
    }

    function test_requestDeposit_instantAfterQueueFullyCancelled() external {
        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        // No capacity, so request 0 is queued in full
        vm.prank(admin);
        spPRIME.setCapacity(0);

        uint256 queuedSavingsShares = spUSDC.convertToShares(500_000e6);

        vm.prank(user);
        assertEq(spPRIME.requestDeposit(500_000e6, user), 0);

        _assertDepositRequest(0, user, user, queuedSavingsShares);

        // Cancel request 0, which leaves no shares encumbered by deposits
        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.CancelDepositRequest(0, 500_000e6 - 1); // Rounding

        vm.prank(user);
        spPRIME.cancelDepositRequest(0, user);

        vm.prank(admin);
        spPRIME.setCapacity(VAULT_CAPACITY);

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
            asset         : 1_000_000e6 - 1, // Rounding
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
        _assertDepositRequest(0, address(0), address(0), 0);

        assertEq(usdc.allowance(user, address(spPRIME)), 500_000e6);

        uint256 expectedSavingsShares = spUSDC.convertToShares(500_000e6);

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 1, 500_000e6);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, 500_000e6 - 1, 500_000e6 - 1); // Rounding

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        // The cancelled entry is skipped and this request fills instantly
        assertEq(requestId, 1);

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vaultState.totalSupply                  = 500_000e6 - 1; // Rounding
        vaultState.totalAssets                  = 500_000e6 - 1; // Rounding
        vaultState.availableCapacity            = VAULT_CAPACITY - 500_000e6 + 1; // Rounding
        vaultState.availableLiquidAssets        = 500_000e6 - 1; // Rounding
        vaultState.unencumberedSparkVaultShares = expectedSavingsShares;

        depositQueueState.head = 2;

        userBalances.asset  = 500_000e6 - 1; // Rounding
        userBalances.shares = 500_000e6 - 1; // Rounding

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(0,         address(0), address(0), 0);
        _assertDepositRequest(requestId, user,       user,       0);
    }

    function test_requestDeposit_partialInstantFill() external {
        vm.prank(admin);
        spPRIME.setCapacity(500_000e6);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                  : 0,
            totalAssets                  : 0,
            availableCapacity            : 500_000e6,
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

        uint256 expectedSavingsShares = spUSDC.convertToShares(1_000_000e6);

        // Half the request's value is filled, rounded up : dipUp(expectedSavingsShares * 500_000e6 / (1_000_000e6 - 1))
        uint256 filledSavingsShares = (expectedSavingsShares * 500_000e6 - 1) / (1_000_000e6 - 1) + 1;
        uint256 queuedSavingsShares = expectedSavingsShares - filledSavingsShares;

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 1_000_000e6);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, 500_000e6, 500_000e6);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(1_000_000e6, user);

        assertEq(requestId, 0);

        vaultState.totalSupply                  = 500_000e6;
        vaultState.totalAssets                  = 500_000e6;
        vaultState.availableCapacity            = 0;
        vaultState.availableLiquidAssets        = spUSDC.convertToAssets(filledSavingsShares);
        vaultState.unencumberedSparkVaultShares = filledSavingsShares;

        // Partial fill, the request stays at the head with the rest of its spUSDC
        depositQueueState.encumberedShares = queuedSavingsShares;

        userBalances.asset  = 0;
        userBalances.shares = 500_000e6;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, queuedSavingsShares);
    }

    function test_requestDeposit_partialInstantFill_oneShareCapacityLeft() external {
        vm.prank(admin);
        spPRIME.setCapacity(500_000e6);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        // Request 0 fills 500k - 1 (rounding), leaving 1 share of capacity
        vm.prank(user);
        spPRIME.requestDeposit(500_000e6, user);

        uint256 expectedSavingsShares = spUSDC.convertToShares(500_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                  : 500_000e6 - 1, // Rounding
            totalAssets                  : 500_000e6 - 1, // Rounding
            availableCapacity            : 1,             // Rounding
            availableLiquidAssets        : 500_000e6 - 1, // Rounding
            unencumberedSparkVaultShares : expectedSavingsShares,
            chi                          : RAY,
            rho                          : block.timestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            encumberedShares : 0,
            head             : 1
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 500_000e6,
            shares        : 500_000e6 - 1, // Rounding
            savingsShares : 0
        });

        AssertBalancesParams memory vaultBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 0,
            shares        : 0,
            savingsShares : expectedSavingsShares
        });

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 1, 500_000e6);

        // The 1 share of leftover capacity is filled from request 1
        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, 1, 1);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 1);

        // 1 wei of value is worth less than one spUSDC share, so 1 share is taken (rounded up)
        vaultState.totalSupply                  = 500_000e6;
        vaultState.totalAssets                  = 500_000e6;
        vaultState.availableCapacity            = 0;
        vaultState.availableLiquidAssets        = spUSDC.convertToAssets(expectedSavingsShares + 1);
        vaultState.unencumberedSparkVaultShares = expectedSavingsShares + 1;

        depositQueueState.encumberedShares = expectedSavingsShares - 1;

        userBalances.asset  = 0;
        userBalances.shares = 500_000e6;

        vaultBalances.savingsShares = 2 * expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, expectedSavingsShares - 1);
    }

    function test_requestDeposit_queued_noCapacity() external {
        vm.prank(admin);
        spPRIME.setCapacity(0);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                  : 0,
            totalAssets                  : 0,
            availableCapacity            : 0,
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

        uint256 expectedSavingsShares = spUSDC.convertToShares(1_000_000e6);

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 1_000_000e6);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(1_000_000e6, user);

        assertEq(requestId, 0);

        // Nothing is minted, the whole request waits in the queue as spUSDC
        depositQueueState.encumberedShares = expectedSavingsShares;

        userBalances.asset = 0;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, expectedSavingsShares);
    }

    function test_requestDeposit_queued_queueNotEmpty() external {
        vm.prank(admin);
        spPRIME.setCapacity(250_000e6);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        // Request 0 is partially filled and stays at the head
        vm.prank(user);
        spPRIME.requestDeposit(500_000e6, user);

        // Capacity is free again, but request 0 is still queued ahead
        vm.prank(admin);
        spPRIME.setCapacity(VAULT_CAPACITY);

        uint256 expectedSavingsShares = spUSDC.convertToShares(500_000e6);

        ( , , uint256 queuedSavingsShares ) = spPRIME.depositQueue(0);

        assertGt(queuedSavingsShares, 0);

        uint256 filledSavingsShares = expectedSavingsShares - queuedSavingsShares;

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                  : 250_000e6,
            totalAssets                  : 250_000e6,
            availableCapacity            : VAULT_CAPACITY - 250_000e6,
            availableLiquidAssets        : spUSDC.convertToAssets(filledSavingsShares),
            unencumberedSparkVaultShares : filledSavingsShares,
            chi                          : RAY,
            rho                          : block.timestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            encumberedShares : queuedSavingsShares,
            head             : 0
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 500_000e6,
            shares        : 250_000e6,
            savingsShares : 0
        });

        AssertBalancesParams memory vaultBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 0,
            shares        : 0,
            savingsShares : expectedSavingsShares
        });

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 1, 500_000e6);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 1);

        // Queued behind request 0 (FIFO), nothing is filled
        depositQueueState.encumberedShares = queuedSavingsShares + expectedSavingsShares;

        userBalances.asset = 0;

        vaultBalances.savingsShares = 2 * expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(0,         user, user, queuedSavingsShares);
        _assertDepositRequest(requestId, user, user, expectedSavingsShares);
    }

    function test_requestDeposit_queued_subShareCapacityLeft() external {
        uint256 deployTimestamp = block.timestamp;

        vm.startPrank(admin);
        spPRIME.setVSRBounds(RAY, MAX_VSR);
        spPRIME.setCapacity(1);
        vm.stopPrank();

        vm.prank(setter);
        spPRIME.setVSR(FIVE_PCT_VSR);

        skip(365 days);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                  : 0,
            totalAssets                  : 0,
            availableCapacity            : 1,
            availableLiquidAssets        : 0,
            unencumberedSparkVaultShares : 0,
            chi                          : RAY,
            rho                          : deployTimestamp
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

        uint256 expectedChi           = spPRIME.nowChi();
        uint256 expectedSavingsShares = spUSDC.convertToShares(500_000e6);

        // 1 share of capacity gives a budget of 1 wei, which buys 0 shares at chi 1.05
        assertEq(1 * RAY / expectedChi, 0);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Drip(uint192(expectedChi), 0);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 500_000e6);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 0);

        // Nothing is minted, the whole request waits in the queue
        vaultState.chi = expectedChi;
        vaultState.rho = block.timestamp;

        depositQueueState.encumberedShares = expectedSavingsShares;

        userBalances.asset = 500_000e6;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, expectedSavingsShares);
    }

    function test_requestDeposit_queued_moreThan500CancelledAhead() external {
        vm.prank(admin);
        spPRIME.setCapacity(0);

        vm.startPrank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        // Queue 500 requests, then cancel all of them
        for (uint256 i; i < 500; ++i) {
            spPRIME.requestDeposit(MINIMUM_DEPOSIT, user);
        }

        for (uint256 i; i < 500; ++i) {
            spPRIME.cancelDepositRequest(i, user);
        }
        vm.stopPrank();

        vm.prank(admin);
        spPRIME.setCapacity(VAULT_CAPACITY);

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            encumberedShares : 0,
            head             : 0
        });

        _assertDepositQueueState(depositQueueState);

        uint256 expectedSavingsShares = spUSDC.convertToShares(500_000e6);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 500);

        // The walk stops at the 500th cancelled entry, before it reaches request 500
        depositQueueState.encumberedShares = expectedSavingsShares;
        depositQueueState.head             = 499;

        _assertDepositQueueState(depositQueueState);
        _assertDepositRequest(requestId, user, user, expectedSavingsShares);

        assertEq(spPRIME.totalSupply(),   0);
        assertEq(spPRIME.balanceOf(user), 0);
    }

    function test_requestDeposit_instantFill_withReferral() external {
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

        uint256 expectedSavingsShares = spUSDC.convertToShares(1_000_000e6);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Referral(1, user, 1_000_000e6);

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 1_000_000e6);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, 1_000_000e6 - 1, 1_000_000e6 - 1); // Rounding

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(1_000_000e6, user, 1);

        assertEq(requestId, 0);

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

}
