// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase, SparkPrimeVault, ISparkVaultLike } from "./TestBase.t.sol";

contract SparkPrimeVaultTests is TestBase {

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        spPRIME.grantRole(SETTER_ROLE,     setter);
        spPRIME.grantRole(GUARDIAN_ROLE,   guardian);
        spPRIME.grantRole(REBALANCER_ROLE, rebalancer);

        spPRIME.setCapacity(VAULT_CAPACITY);
        spPRIME.setMinDeposit(MINIMUM_DEPOSIT);
        spPRIME.setMinRedeem(MINIMUM_REDEEM);
        vm.stopPrank();

        // Deal USDC to user
        deal(address(usdc), user, 1_000_000e6);
    }

}

contract RequestDepositTests is SparkPrimeVaultTests {

    // Failure tests

    function test_requestDeposit_paused() external {
        vm.prank(guardian);
        spPRIME.pause();

        vm.expectRevert("SparkPrimeVault/paused");
        vm.prank(user);
        spPRIME.requestDeposit(100e6, user);
    }

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

    function test_requestDeposit_instantFill_advancesPastCancelledRequests() external {
        vm.prank(admin);
        spPRIME.setCapacity(0);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        // No capacity, so requests 0 and 1 are queued in full
        vm.prank(user);
        spPRIME.requestDeposit(250_000e6, user);

        vm.prank(user);
        spPRIME.requestDeposit(250_000e6, user);

        // Request 1 is not the head, so cancelling it leaves a cancelled request behind request 0
        vm.prank(user);
        spPRIME.requestDepositCancellation(1, user);

        vm.prank(admin);
        spPRIME.setCapacity(VAULT_CAPACITY);

        // Process one request, request 0 is filled and the head stops at cancelled request 1
        vm.prank(rebalancer);
        spPRIME.processPendingDeposits(type(uint256).max, 1);

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

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : setupShares,
            totalAssets           : setupShares,
            availableCapacity     : VAULT_CAPACITY - setupShares,
            availableLiquidAssets : 500_000e6 - 1, // Rounding
            chi                   : RAY,
            rho                   : block.timestamp
        });

        // The head points at cancelled request 1
        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares  : 0,
            length         : 1,
            firstPendingId : 1
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 500_000e6,
            shares        : setupShares,
            savingsShares : 0
        });

        // Holds the filled request 0 and the cancelled request 1, which waits to be refunded
        AssertBalancesParams memory vaultBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 0,
            shares        : 0,
            savingsShares : 2 * setupSavingsShares
        });

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(1, address(0), address(0), 0);

        assertEq(spPRIME.pendingCancelledDepositSavingsShares(), setupSavingsShares);

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

        depositQueueState.length         = 0;
        depositQueueState.firstPendingId = 3;

        userBalances.asset  = 0;
        userBalances.shares = setupShares + expectedShares;

        vaultBalances.savingsShares = 2 * setupSavingsShares + expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
    }

    function test_requestDeposit_noFill_requestsExist() external {
        _accrueInterest(365 days);

        vm.prank(admin);
        spPRIME.setCapacity(0);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        // No capacity, so request 0 is queued in full
        vm.prank(user);
        spPRIME.requestDeposit(500_000e6, user);

        // Capacity is free again, but request 0 is still queued ahead
        vm.prank(admin);
        spPRIME.setCapacity(VAULT_CAPACITY);

        uint256 expectedChi = spPRIME.nowChi();

        // 5% APY over one year
        assertApproxEqRel(expectedChi, 1.05e27, 0.0001e18);

        uint256 expectedSavingsShares = spUSDC.convertToShares(500_000e6);

        assertEq(expectedSavingsShares, 464_447.611562e6);

        // Request 0 already updated chi in this block
        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 0,
            totalAssets           : 0,
            availableCapacity     : VAULT_CAPACITY,
            availableLiquidAssets : 500_000e6 - 1, // Rounding
            chi                   : expectedChi,
            rho                   : block.timestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares  : expectedSavingsShares,
            length         : 1,
            firstPendingId : 0
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 500_000e6,
            shares        : 0,
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
        _assertDepositRequest(0, user, user, expectedSavingsShares);

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 1, 500_000e6, expectedSavingsShares);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 1);

        // Queued behind request 0 (FIFO), nothing is filled
        vaultState.availableLiquidAssets = 1_000_000e6 - 2; // Rounding

        depositQueueState.pendingShares = 2 * expectedSavingsShares;
        depositQueueState.length        = 2;

        userBalances.asset = 0;

        vaultBalances.savingsShares = 2 * expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(0,         user, user, expectedSavingsShares);
        _assertDepositRequest(requestId, user, user, expectedSavingsShares);
    }

    function test_requestDeposit_noFill_zeroAvailableCapacity() external {
        uint256 deployTimestamp = block.timestamp;

        _accrueInterest(365 days);

        vm.prank(admin);
        spPRIME.setCapacity(0);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 0,
            totalAssets           : 0,
            availableCapacity     : 0,
            availableLiquidAssets : 0,
            chi                   : RAY,
            rho                   : deployTimestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares  : 0,
            length         : 0,
            firstPendingId : 0
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

        assertEq(expectedSavingsShares, 928_895.223125e6);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Drip(uint192(expectedChi), 0);  // No supply yet, so no diff

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 1_000_000e6, expectedSavingsShares);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(1_000_000e6, user);

        assertEq(requestId, 0);

        // Nothing is minted, the whole request waits in the queue as spUSDC
        vaultState.availableLiquidAssets = 1_000_000e6 - 1; // Rounding
        vaultState.chi                   = expectedChi;
        vaultState.rho                   = block.timestamp;

        depositQueueState.pendingShares = expectedSavingsShares;
        depositQueueState.length        = 1;

        userBalances.asset = 0;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, expectedSavingsShares);
    }

    function test_requestDeposit_instantFill_noInterestAccrual() external {
        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 0,
            totalAssets           : 0,
            availableCapacity     : VAULT_CAPACITY,
            availableLiquidAssets : 0,
            chi                   : RAY,
            rho                   : block.timestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares  : 0,
            length         : 0,
            firstPendingId : 0
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

        assertEq(expectedSavingsShares, 964_193.241604e6);

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, 1_000_000e6 - 1, 1_000_000e6 - 1); // Rounding

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(1_000_000e6, user);

        assertEq(requestId, 0);

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vaultState.totalSupply           = 1_000_000e6 - 1; // Rounding
        vaultState.totalAssets           = 1_000_000e6 - 1; // Rounding
        vaultState.availableCapacity     = VAULT_CAPACITY - 1_000_000e6 + 1; // Rounding
        vaultState.availableLiquidAssets = 1_000_000e6 - 1; // Rounding

        depositQueueState.firstPendingId = 1;

        userBalances.asset  = 0;
        userBalances.shares = 1_000_000e6 - 1; // Rounding

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
    }

    function test_requestDeposit_instantFill() external {
        uint256 deployTimestamp = block.timestamp;

        _accrueInterest(365 days);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 0,
            totalAssets           : 0,
            availableCapacity     : VAULT_CAPACITY,
            availableLiquidAssets : 0,
            chi                   : RAY,
            rho                   : deployTimestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares  : 0,
            length         : 0,
            firstPendingId : 0
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

        uint256 expectedChi = spPRIME.nowChi();

        // 5% APY over one year
        assertApproxEqRel(expectedChi, 1.05e27, 0.0001e18);

        uint256 expectedSavingsShares = spUSDC.convertToShares(1_000_000e6);
        uint256 expectedAssets        = spUSDC.convertToAssets(expectedSavingsShares);
        uint256 expectedShares        = expectedAssets * RAY / expectedChi;

        assertEq(expectedSavingsShares, 928_895.223125e6);
        assertEq(expectedAssets,        1_000_000e6 - 1); // Rounding
        assertEq(expectedShares,        952_380.952380e6);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Drip(uint192(expectedChi), 0);  // No supply yet, so no diff

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, expectedAssets, expectedShares);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(1_000_000e6, user);

        assertEq(requestId, 0);

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vaultState.totalSupply           = expectedShares;
        vaultState.totalAssets           = expectedShares * expectedChi / RAY;
        vaultState.availableCapacity     = VAULT_CAPACITY - expectedShares;
        vaultState.availableLiquidAssets = expectedAssets;
        vaultState.chi                   = expectedChi;
        vaultState.rho                   = block.timestamp;

        depositQueueState.firstPendingId = 1;

        userBalances.asset  = 0;
        userBalances.shares = expectedShares;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
    }

    function test_requestDeposit_instantFillMultipleRequests() external {
        uint256 deployTimestamp = block.timestamp;

        _accrueInterest(365 days);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 0,
            totalAssets           : 0,
            availableCapacity     : VAULT_CAPACITY,
            availableLiquidAssets : 0,
            chi                   : RAY,
            rho                   : deployTimestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares  : 0,
            length         : 0,
            firstPendingId : 0
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

        uint256 expectedSavingsShares = spUSDC.convertToShares(500_000e6);
        uint256 expectedAssets        = spUSDC.convertToAssets(expectedSavingsShares);
        uint256 expectedShares        = expectedAssets * RAY / expectedChi;

        assertEq(expectedSavingsShares, 464_447.611562e6);
        assertEq(expectedAssets,        500_000e6 - 1); // Rounding
        assertEq(expectedShares,        476_190.476189e6);

        // Request 1 with 500k USDC

        assertEq(usdc.allowance(user, address(spPRIME)), 1_000_000e6);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Drip(uint192(expectedChi), 0);  // No supply yet, so no diff

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, expectedAssets, expectedShares);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 0);

        assertEq(usdc.allowance(user, address(spPRIME)), 500_000e6);

        vaultState.totalSupply           = expectedShares;
        vaultState.totalAssets           = expectedShares * expectedChi / RAY;
        vaultState.availableCapacity     = VAULT_CAPACITY - expectedShares;
        vaultState.availableLiquidAssets = expectedAssets;
        vaultState.chi                   = expectedChi;
        vaultState.rho                   = block.timestamp;

        depositQueueState.firstPendingId = 1;

        userBalances.asset  = 500_000e6;
        userBalances.shares = expectedShares;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);

        // Request 2 with 500k USDC, chi is already updated in this block so there is no Drip

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 1, 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, expectedAssets, expectedShares);

        vm.prank(user);
        requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 1);

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vaultState.totalSupply           = 2 * expectedShares;
        vaultState.totalAssets           = 2 * expectedShares * expectedChi / RAY;
        vaultState.availableCapacity     = VAULT_CAPACITY - 2 * expectedShares;
        vaultState.availableLiquidAssets = 2 * expectedAssets;

        depositQueueState.firstPendingId = 2;

        userBalances.asset  = 0;
        userBalances.shares = 2 * expectedShares;

        vaultBalances.savingsShares = 2 * expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
    }

    function test_requestDeposit_partialInstantFill_noInterestAccrual() external {
        vm.prank(admin);
        spPRIME.setCapacity(500_000e6);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 0,
            totalAssets           : 0,
            availableCapacity     : 500_000e6,
            availableLiquidAssets : 0,
            chi                   : RAY,
            rho                   : block.timestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares  : 0,
            length         : 0,
            firstPendingId : 0
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

        // Capacity converted to spUSDC shares, which caps the fill
        uint256 filledSavingsShares = spUSDC.convertToShares(spPRIME.convertToAssets(500_000e6));
        uint256 queuedSavingsShares = expectedSavingsShares - filledSavingsShares;

        uint256 expectedAssets = spUSDC.convertToAssets(filledSavingsShares);
        uint256 expectedShares = spPRIME.convertToShares(expectedAssets);

        assertEq(expectedSavingsShares, 964_193.241604e6);
        assertEq(filledSavingsShares,   482_096.620802e6);
        assertEq(queuedSavingsShares,   482_096.620802e6);
        assertEq(expectedAssets,        500_000e6 - 1); // Rounding
        assertEq(expectedShares,        500_000e6 - 1); // Rounding

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, expectedAssets, expectedShares);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(1_000_000e6, user);

        assertEq(requestId, 0);

        vaultState.totalSupply           = expectedShares;
        vaultState.totalAssets           = expectedShares;
        vaultState.availableCapacity     = 1;               // Rounding
        vaultState.availableLiquidAssets = 1_000_000e6 - 1; // Rounding

        // Partial fill, the request stays at the head with the rest of its spUSDC
        depositQueueState.pendingShares = queuedSavingsShares;
        depositQueueState.length        = 1;

        userBalances.asset  = 0;
        userBalances.shares = expectedShares;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, queuedSavingsShares);
    }

    function test_requestDeposit_partialInstantFill() external {
        uint256 deployTimestamp = block.timestamp;

        _accrueInterest(365 days);

        vm.prank(admin);
        spPRIME.setCapacity(500_000e6);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 0,
            totalAssets           : 0,
            availableCapacity     : 500_000e6,
            availableLiquidAssets : 0,
            chi                   : RAY,
            rho                   : deployTimestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares  : 0,
            length         : 0,
            firstPendingId : 0
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

        // Capacity converted to spUSDC shares, which caps the fill
        uint256 filledSavingsShares = spUSDC.convertToShares(spPRIME.convertToAssets(500_000e6));
        uint256 queuedSavingsShares = expectedSavingsShares - filledSavingsShares;

        uint256 expectedAssets = spUSDC.convertToAssets(filledSavingsShares);
        uint256 expectedShares = expectedAssets * RAY / expectedChi;

        assertEq(expectedSavingsShares, 928_895.223125e6);
        assertEq(filledSavingsShares,   487_669.992139e6);
        assertEq(queuedSavingsShares,   441_225.230986e6);
        assertEq(expectedAssets,        525_000e6 - 2); // Rounding
        assertEq(expectedShares,        500_000e6 - 2); // Rounding

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Drip(uint192(expectedChi), 0);  // No supply yet, so no diff

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, expectedAssets, expectedShares);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(1_000_000e6, user);

        assertEq(requestId, 0);

        vaultState.totalSupply           = expectedShares;
        vaultState.totalAssets           = expectedShares * expectedChi / RAY;
        vaultState.availableCapacity     = 2;               // Rounding
        vaultState.availableLiquidAssets = 1_000_000e6 - 1; // Rounding
        vaultState.chi                   = expectedChi;
        vaultState.rho                   = block.timestamp;

        // Partial fill, the request stays at the head with the rest of its spUSDC
        depositQueueState.pendingShares = queuedSavingsShares;
        depositQueueState.length        = 1;

        userBalances.asset  = 0;
        userBalances.shares = expectedShares;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, queuedSavingsShares);
    }

    // TODO: Check if minting 0 shares for 1 spUSDC share is intended or requires a fix. The fill
    //       has no guard against a partial fill that mints nothing, so the request loses 1 spUSDC
    //       share for 0 spPRIME, and every later fill with the same capacity left repeats it.
    function test_requestDeposit_partialInstantFill_mintsZeroShares() external {
        uint256 deployTimestamp = block.timestamp;

        _accrueInterest(365 days);

        vm.prank(admin);
        spPRIME.setCapacity(2);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 0,
            totalAssets           : 0,
            availableCapacity     : 2,
            availableLiquidAssets : 0,
            chi                   : RAY,
            rho                   : deployTimestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares  : 0,
            length         : 0,
            firstPendingId : 0
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

        uint256 expectedSavingsShares = spUSDC.convertToShares(500_000e6);

        // 2 wei of capacity is worth 2 wei of USDC, which buys 1 wei of spUSDC share
        uint256 filledSavingsShares = spUSDC.convertToShares(spPRIME.convertToAssets(2));

        // 1 wei of spUSDC share is worth 1 wei of USDC, which buys 0 spPRIME at chi 1.05
        uint256 expectedAssets = spUSDC.convertToAssets(filledSavingsShares);
        uint256 expectedShares = expectedAssets * RAY / expectedChi;

        assertEq(expectedSavingsShares, 464_447.611562e6);
        assertEq(filledSavingsShares,   1);
        assertEq(expectedAssets,        1);
        assertEq(expectedShares,        0);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Drip(uint192(expectedChi), 0);  // No supply yet, so no diff

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, 1, 0);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 0);

        // 1 spUSDC share left the request, nothing was minted and the capacity is unchanged
        vaultState.availableLiquidAssets = 500_000e6 - 1; // Rounding
        vaultState.chi                   = expectedChi;
        vaultState.rho                   = block.timestamp;

        depositQueueState.pendingShares = expectedSavingsShares - 1;
        depositQueueState.length        = 1;

        userBalances.asset = 500_000e6;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, expectedSavingsShares - 1);
    }

    function test_requestDeposit_instantFill_withReferral() external {
        uint256 deployTimestamp = block.timestamp;

        _accrueInterest(365 days);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 0,
            totalAssets           : 0,
            availableCapacity     : VAULT_CAPACITY,
            availableLiquidAssets : 0,
            chi                   : RAY,
            rho                   : deployTimestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares  : 0,
            length         : 0,
            firstPendingId : 0
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

        assertEq(expectedSavingsShares, 928_895.223125e6);
        assertEq(expectedAssets,        1_000_000e6 - 1); // Rounding
        assertEq(expectedShares,        952_380.952380e6);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Referral(1, user, 1_000_000e6);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Drip(uint192(expectedChi), 0);  // No supply yet, so no diff

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, expectedAssets, expectedShares);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(1_000_000e6, user, 1);

        assertEq(requestId, 0);

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vaultState.totalSupply           = expectedShares;
        vaultState.totalAssets           = expectedShares * expectedChi / RAY;
        vaultState.availableCapacity     = VAULT_CAPACITY - expectedShares;
        vaultState.availableLiquidAssets = expectedAssets;
        vaultState.chi                   = expectedChi;
        vaultState.rho                   = block.timestamp;

        depositQueueState.firstPendingId = 1;

        userBalances.asset  = 0;
        userBalances.shares = expectedShares;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
    }

}
