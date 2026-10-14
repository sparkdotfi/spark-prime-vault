// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../lib/forge-std/src/StdError.sol";

import { IAccessControl } from "../lib/oz/contracts/access/IAccessControl.sol";

import { TestBase, SparkPrimeVault, ISparkVaultLike } from "./TestBase.t.sol";

contract SparkPrimeVaultTests is TestBase {

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(admin);
        spPRIME.grantRole(SETTER_ROLE,   setter);
        spPRIME.grantRole(GUARDIAN_ROLE, guardian);

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

    function test_requestDeposit_instantFill_noInterestAccrual() external {
        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                          : 0,
            totalAssets                          : 0,
            availableCapacity                    : VAULT_CAPACITY,
            availableLiquidAssets                : 0,
            pendingDepositSavingsShares          : 0,
            pendingCancelledDepositSavingsShares : 0,
            pendingRedeemShares                  : 0,
            chi                                  : RAY,
            rho                                  : block.timestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares : 0,
            head          : 0
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

        vaultState.totalSupply                 = 1_000_000e6 - 1; // Rounding
        vaultState.totalAssets                 = 1_000_000e6 - 1; // Rounding
        vaultState.availableCapacity           = VAULT_CAPACITY - 1_000_000e6 + 1; // Rounding
        vaultState.availableLiquidAssets       = 1_000_000e6 - 1; // Rounding
        vaultState.pendingDepositSavingsShares = expectedSavingsShares;

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

    function test_requestDeposit_instantFill() external {
        uint256 deployTimestamp = block.timestamp;

        _accrueInterest(365 days);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                          : 0,
            totalAssets                          : 0,
            availableCapacity                    : VAULT_CAPACITY,
            availableLiquidAssets                : 0,
            pendingDepositSavingsShares          : 0,
            pendingCancelledDepositSavingsShares : 0,
            pendingRedeemShares                  : 0,
            chi                                  : RAY,
            rho                                  : deployTimestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares : 0,
            head          : 0
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

        vaultState.totalSupply                 = expectedShares;
        vaultState.totalAssets                 = expectedShares * expectedChi / RAY;
        vaultState.availableCapacity           = VAULT_CAPACITY - expectedShares;
        vaultState.availableLiquidAssets       = expectedAssets;
        vaultState.pendingDepositSavingsShares = expectedSavingsShares;
        vaultState.chi                         = expectedChi;
        vaultState.rho                         = block.timestamp;

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

    function test_requestDeposit_instantFillMultipleRequests() external {
        uint256 deployTimestamp = block.timestamp;

        _accrueInterest(365 days);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                          : 0,
            totalAssets                          : 0,
            availableCapacity                    : VAULT_CAPACITY,
            availableLiquidAssets                : 0,
            pendingDepositSavingsShares          : 0,
            pendingCancelledDepositSavingsShares : 0,
            pendingRedeemShares                  : 0,
            chi                                  : RAY,
            rho                                  : deployTimestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares : 0,
            head          : 0
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

        vaultState.totalSupply                 = expectedShares;
        vaultState.totalAssets                 = expectedShares * expectedChi / RAY;
        vaultState.availableCapacity           = VAULT_CAPACITY - expectedShares;
        vaultState.availableLiquidAssets       = expectedAssets;
        vaultState.pendingDepositSavingsShares = expectedSavingsShares;
        vaultState.chi                         = expectedChi;
        vaultState.rho                         = block.timestamp;

        depositQueueState.head = 1;

        userBalances.asset  = 500_000e6;
        userBalances.shares = expectedShares;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, 0);

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

        vaultState.totalSupply                 = 2 * expectedShares;
        vaultState.totalAssets                 = 2 * expectedShares * expectedChi / RAY;
        vaultState.availableCapacity           = VAULT_CAPACITY - 2 * expectedShares;
        vaultState.availableLiquidAssets       = 2 * expectedAssets;
        vaultState.pendingDepositSavingsShares = 2 * expectedSavingsShares;

        depositQueueState.head = 2;

        userBalances.asset  = 0;
        userBalances.shares = 2 * expectedShares;

        vaultBalances.savingsShares = 2 * expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, 0);
    }

    function test_requestDeposit_instantAfterQueueFullyCancelled() external {
        _accrueInterest(365 days);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        uint256 expectedChi = spPRIME.nowChi();

        // 5% APY over one year
        assertApproxEqRel(expectedChi, 1.05e27, 0.0001e18);

        uint256 expectedSavingsShares = spUSDC.convertToShares(500_000e6);
        uint256 expectedAssets        = spUSDC.convertToAssets(expectedSavingsShares);
        uint256 expectedShares        = expectedAssets * RAY / expectedChi;

        assertEq(expectedSavingsShares, 464_447.611562e6);
        assertEq(expectedAssets,        500_000e6 - 1); // Rounding
        assertEq(expectedShares,        476_190.476189e6);

        // No capacity, so request 0 is queued in full
        vm.prank(admin);
        spPRIME.setCapacity(0);

        vm.prank(user);
        assertEq(spPRIME.requestDeposit(500_000e6, user), 0);

        _assertDepositRequest(0, user, user, expectedSavingsShares);

        // Cancel request 0, which leaves no shares encumbered by deposits
        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositCancellationRequest(0, 0, user);

        vm.prank(user);
        spPRIME.requestDepositCancellation(0, user);

        vm.prank(admin);
        spPRIME.setCapacity(VAULT_CAPACITY);

        // Request 0 already updated chi in this block
        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                          : 0,
            totalAssets                          : 0,
            availableCapacity                    : VAULT_CAPACITY,
            availableLiquidAssets                : 0,
            pendingDepositSavingsShares          : 0,
            pendingCancelledDepositSavingsShares : 0,
            pendingRedeemShares                  : 0,
            chi                                  : expectedChi,
            rho                                  : block.timestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares : 0,
            head          : 0
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

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 1, 500_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, expectedAssets, expectedShares);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        // The cancelled entry is skipped and this request fills instantly
        assertEq(requestId, 1);

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vaultState.totalSupply                 = expectedShares;
        vaultState.totalAssets                 = expectedShares * expectedChi / RAY;
        vaultState.availableCapacity           = VAULT_CAPACITY - expectedShares;
        vaultState.availableLiquidAssets       = expectedAssets;
        vaultState.pendingDepositSavingsShares = expectedSavingsShares;

        depositQueueState.head = 2;

        userBalances.asset  = 500_000e6 - 1; // Rounding
        userBalances.shares = expectedShares;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(0,         address(0), address(0), 0);
        _assertDepositRequest(requestId, user,       user,       0);
    }

    function test_requestDeposit_partialInstantFill_noInterestAccrual() external {
        vm.prank(admin);
        spPRIME.setCapacity(500_000e6);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                          : 0,
            totalAssets                          : 0,
            availableCapacity                    : 500_000e6,
            availableLiquidAssets                : 0,
            pendingDepositSavingsShares          : 0,
            pendingCancelledDepositSavingsShares : 0,
            pendingRedeemShares                  : 0,
            chi                                  : RAY,
            rho                                  : block.timestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares : 0,
            head          : 0
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

        assertEq(expectedSavingsShares, 964_193.241604e6);

        // Half the request's value is filled, rounded up : dipUp(expectedSavingsShares * 500_000e6 / (1_000_000e6 - 1))
        uint256 filledSavingsShares = (expectedSavingsShares * 500_000e6 - 1) / (1_000_000e6 - 1) + 1;
        uint256 queuedSavingsShares = expectedSavingsShares - filledSavingsShares;

        vm.expectEmit(address(spUSDC));
        emit ISparkVaultLike.Deposit(address(spPRIME), address(spPRIME), 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, 500_000e6, 500_000e6);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(1_000_000e6, user);

        assertEq(requestId, 0);

        vaultState.totalSupply                 = 500_000e6;
        vaultState.totalAssets                 = 500_000e6;
        vaultState.availableCapacity           = 0;
        vaultState.availableLiquidAssets       = spUSDC.convertToAssets(filledSavingsShares);
        vaultState.pendingDepositSavingsShares = filledSavingsShares;

        // Partial fill, the request stays at the head with the rest of its spUSDC
        depositQueueState.pendingShares = queuedSavingsShares;

        userBalances.asset  = 0;
        userBalances.shares = 500_000e6;

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
            totalSupply                          : 0,
            totalAssets                          : 0,
            availableCapacity                    : 500_000e6,
            availableLiquidAssets                : 0,
            pendingDepositSavingsShares          : 0,
            pendingCancelledDepositSavingsShares : 0,
            pendingRedeemShares                  : 0,
            chi                                  : RAY,
            rho                                  : deployTimestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares : 0,
            head          : 0
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
        uint256 expectedValue         = spUSDC.convertToAssets(expectedSavingsShares);
        uint256 expectedAssets        = 500_000e6 * expectedChi / RAY;  // Capacity in USDC, the budget
        uint256 expectedShares        = expectedAssets * RAY / expectedChi;

        assertEq(expectedSavingsShares, 928_895.223125e6);
        assertEq(expectedValue,         1_000_000e6 - 1); // Rounding
        assertEq(expectedAssets,        525_000e6 - 1);   // Rounding
        assertEq(expectedShares,        500_000e6 - 1);   // Rounding

        // The budget's share of the request, rounded up : divUp(expectedSavingsShares * expectedAssets / expectedValue)
        uint256 filledSavingsShares = (expectedSavingsShares * expectedAssets - 1) / expectedValue + 1;
        uint256 queuedSavingsShares = expectedSavingsShares - filledSavingsShares;

        assertEq(filledSavingsShares, 487_669.992141e6);
        assertEq(queuedSavingsShares, 441_225.230984e6);

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

        vaultState.totalSupply                 = expectedShares;
        vaultState.totalAssets                 = expectedShares * expectedChi / RAY;
        vaultState.availableCapacity           = 1;  // Rounding
        vaultState.availableLiquidAssets       = 525_000e6;
        vaultState.pendingDepositSavingsShares = filledSavingsShares;
        vaultState.chi                         = expectedChi;
        vaultState.rho                         = block.timestamp;

        // Partial fill, the request stays at the head with the rest of its spUSDC
        depositQueueState.pendingShares = queuedSavingsShares;

        userBalances.asset  = 0;
        userBalances.shares = expectedShares;

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

        assertEq(expectedSavingsShares, 482_096.620802e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                          : 500_000e6 - 1, // Rounding
            totalAssets                          : 500_000e6 - 1, // Rounding
            availableCapacity                    : 1,             // Rounding
            availableLiquidAssets                : 500_000e6 - 1, // Rounding
            pendingDepositSavingsShares          : expectedSavingsShares,
            pendingCancelledDepositSavingsShares : 0,
            pendingRedeemShares                  : 0,
            chi                                  : RAY,
            rho                                  : block.timestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares : 0,
            head          : 1
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
        emit SparkPrimeVault.DepositRequest(user, user, 1, 500_000e6, expectedSavingsShares);

        // The 1 share of leftover capacity is filled from request 1
        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Deposit(user, user, 1, 1);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 1);

        // 1 wei of value is worth less than one spUSDC share, so 1 share is taken (rounded up)
        vaultState.totalSupply                 = 500_000e6;
        vaultState.totalAssets                 = 500_000e6;
        vaultState.availableCapacity           = 0;
        vaultState.availableLiquidAssets       = spUSDC.convertToAssets(expectedSavingsShares + 1);
        vaultState.pendingDepositSavingsShares = expectedSavingsShares + 1;

        depositQueueState.pendingShares = expectedSavingsShares - 1;

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
        uint256 deployTimestamp = block.timestamp;

        _accrueInterest(365 days);

        vm.prank(admin);
        spPRIME.setCapacity(0);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                          : 0,
            totalAssets                          : 0,
            availableCapacity                    : 0,
            availableLiquidAssets                : 0,
            pendingDepositSavingsShares          : 0,
            pendingCancelledDepositSavingsShares : 0,
            pendingRedeemShares                  : 0,
            chi                                  : RAY,
            rho                                  : deployTimestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares : 0,
            head          : 0
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
        vaultState.chi = expectedChi;
        vaultState.rho = block.timestamp;

        depositQueueState.pendingShares = expectedSavingsShares;

        userBalances.asset = 0;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, expectedSavingsShares);
    }

    function test_requestDeposit_queued_queueNotEmpty() external {
        _accrueInterest(365 days);

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

        uint256 expectedChi = spPRIME.nowChi();

        // 5% APY over one year
        assertApproxEqRel(expectedChi, 1.05e27, 0.0001e18);

        uint256 expectedSavingsShares = spUSDC.convertToShares(500_000e6);

        ( , , uint256 queuedSavingsShares ) = spPRIME.getPendingDepositRequest(0);

        uint256 filledSavingsShares = expectedSavingsShares - queuedSavingsShares;

        assertEq(expectedSavingsShares, 464_447.611562e6);
        assertEq(queuedSavingsShares,   220_612.615492e6);
        assertEq(filledSavingsShares,   243_834.996070e6);

        // Request 0 already updated chi in this block
        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                          : 250_000e6 - 1, // Rounding
            totalAssets                          : (250_000e6 - 1) * expectedChi / RAY,
            availableCapacity                    : VAULT_CAPACITY - 250_000e6 + 1, // Rounding
            availableLiquidAssets                : 262_500e6 - 1, // Rounding
            pendingDepositSavingsShares          : filledSavingsShares,
            pendingCancelledDepositSavingsShares : 0,
            pendingRedeemShares                  : 0,
            chi                                  : expectedChi,
            rho                                  : block.timestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares : queuedSavingsShares,
            head          : 0
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 500_000e6,
            shares        : 250_000e6 - 1, // Rounding
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
        emit SparkPrimeVault.DepositRequest(user, user, 1, 500_000e6, expectedSavingsShares);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 1);

        // Queued behind request 0 (FIFO), nothing is filled
        depositQueueState.pendingShares = queuedSavingsShares + expectedSavingsShares;

        userBalances.asset = 0;

        vaultBalances.savingsShares = 2 * expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(0,         user, user, queuedSavingsShares);
        _assertDepositRequest(requestId, user, user, expectedSavingsShares);
    }

    function test_requestDeposit_queued_capacityTooSmallToMintShare() external {
        uint256 deployTimestamp = block.timestamp;

        _accrueInterest(365 days);

        vm.prank(admin);
        spPRIME.setCapacity(1);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                          : 0,
            totalAssets                          : 0,
            availableCapacity                    : 1,
            availableLiquidAssets                : 0,
            pendingDepositSavingsShares          : 0,
            pendingCancelledDepositSavingsShares : 0,
            pendingRedeemShares                  : 0,
            chi                                  : RAY,
            rho                                  : deployTimestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares : 0,
            head          : 0
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

        assertEq(expectedSavingsShares, 464_447.611562e6);

        // 1 share of capacity gives a budget of 1 wei, which buys 0 shares at chi 1.05
        assertEq(1 * RAY / expectedChi, 0);

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.Drip(uint192(expectedChi), 0);  // No supply yet, so no diff

        vm.expectEmit(address(spPRIME));
        emit SparkPrimeVault.DepositRequest(user, user, 0, 500_000e6, expectedSavingsShares);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 0);

        // Nothing is minted, the whole request waits in the queue
        vaultState.chi = expectedChi;
        vaultState.rho = block.timestamp;

        depositQueueState.pendingShares = expectedSavingsShares;

        userBalances.asset = 500_000e6;

        vaultBalances.savingsShares = expectedSavingsShares;

        _assertVaultState(vaultState);
        _assertDepositQueueState(depositQueueState);
        _assertBalances(userBalances);
        _assertBalances(vaultBalances);
        _assertDepositRequest(requestId, user, user, expectedSavingsShares);
    }

    function test_requestDeposit_queued_moreThan500CancelledAhead() external {
        _accrueInterest(365 days);

        vm.prank(admin);
        spPRIME.setCapacity(0);

        vm.startPrank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        // Queue 500 requests, then cancel all of them
        for (uint256 i; i < 500; ++i) {
            spPRIME.requestDeposit(MINIMUM_DEPOSIT, user);
        }

        for (uint256 i; i < 500; ++i) {
            spPRIME.requestDepositCancellation(i, user);
        }
        vm.stopPrank();

        vm.prank(admin);
        spPRIME.setCapacity(VAULT_CAPACITY);

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares : 0,
            head          : 0
        });

        _assertDepositQueueState(depositQueueState);

        uint256 expectedSavingsShares = spUSDC.convertToShares(500_000e6);

        assertEq(expectedSavingsShares, 464_447.611562e6);

        vm.prank(user);
        uint256 requestId = spPRIME.requestDeposit(500_000e6, user);

        assertEq(requestId, 500);

        // The walk stops at the 500th cancelled entry, before it reaches request 500
        depositQueueState.pendingShares = expectedSavingsShares;
        depositQueueState.head             = 499;

        _assertDepositQueueState(depositQueueState);
        _assertDepositRequest(requestId, user, user, expectedSavingsShares);

        assertEq(spPRIME.totalSupply(),   0);
        assertEq(spPRIME.balanceOf(user), 0);
    }

    function test_requestDeposit_instantFill_withReferral() external {
        uint256 deployTimestamp = block.timestamp;

        _accrueInterest(365 days);

        vm.prank(user);
        usdc.approve(address(spPRIME), 1_000_000e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply                          : 0,
            totalAssets                          : 0,
            availableCapacity                    : VAULT_CAPACITY,
            availableLiquidAssets                : 0,
            pendingDepositSavingsShares          : 0,
            pendingCancelledDepositSavingsShares : 0,
            pendingRedeemShares                  : 0,
            chi                                  : RAY,
            rho                                  : deployTimestamp
        });

        AssertQueueStateParams memory depositQueueState = AssertQueueStateParams({
            pendingShares : 0,
            head          : 0
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

        vaultState.totalSupply                 = expectedShares;
        vaultState.totalAssets                 = expectedShares * expectedChi / RAY;
        vaultState.availableCapacity           = VAULT_CAPACITY - expectedShares;
        vaultState.availableLiquidAssets       = expectedAssets;
        vaultState.pendingDepositSavingsShares = expectedSavingsShares;
        vaultState.chi                         = expectedChi;
        vaultState.rho                         = block.timestamp;

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

}

contract RealizeLossTests is SparkPrimeVaultTests {

    event LossRealized(uint192 chi, uint256 loss);

    uint256 internal constant DEPOSIT  = 1_000_000e6;
    uint256 internal constant FIVE_PCT = 1.000000001547125957863212448e27;  // 5% APY

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);

        spPRIME.grantRole(GUARDIAN_ROLE,     guardian);
        spPRIME.grantRole(RISK_MANAGER_ROLE, riskManager);
        spPRIME.grantRole(SETTER_ROLE,       setter);

        spPRIME.setCapacity(VAULT_CAPACITY);
        spPRIME.setVSRBounds(RAY, spPRIME.MAX_VSR());

        vm.stopPrank();

        vm.prank(setter);
        spPRIME.setVSR(FIVE_PCT);
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _deposit(uint256 assets) internal {
        deal(address(usdc), user, assets);

        vm.startPrank(user);
        usdc.approve(address(spPRIME), assets);
        spPRIME.requestDeposit(assets, user);
        vm.stopPrank();
    }

    function _depositAndPause() internal {
        _deposit(DEPOSIT);

        vm.prank(guardian);
        spPRIME.pause();
    }

    /**********************************************************************************************/
    /*** Failure tests                                                                          ***/
    /**********************************************************************************************/

    function test_realizeLoss_notRiskManager() public {
        _depositAndPause();

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            address(this),
            RISK_MANAGER_ROLE
        ));
        spPRIME.realizeLoss(1e6);
    }

    function test_realizeLoss_notPaused() public {
        _deposit(DEPOSIT);

        vm.expectRevert("SparkPrimeVault/not-paused");
        vm.prank(riskManager);
        spPRIME.realizeLoss(1e6);
    }

    function test_realizeLoss_invalidLoss_zeroLoss() public {
        _depositAndPause();

        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vm.prank(riskManager);
        spPRIME.realizeLoss(0);

        vm.prank(riskManager);
        spPRIME.realizeLoss(1);
    }

    function test_realizeLoss_invalidLoss_tooHighBoundary() public {
        _depositAndPause();

        uint256 totalAssets = spPRIME.totalAssets();

        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vm.prank(riskManager);
        spPRIME.realizeLoss(totalAssets + 1);

        vm.prank(riskManager);
        spPRIME.realizeLoss(totalAssets);
    }

    // TODO: test_realizeLoss_zeroSupply can probably only be done with a harness

    /**********************************************************************************************/
    /*** Success tests                                                                          ***/
    /**********************************************************************************************/

    function test_realizeLoss() public {
        uint256 loss = 100_000e6;

        _depositAndPause();

        skip(365 days);

        uint192 chiBefore    = spPRIME.nowChi();
        uint256 assetsBefore = spPRIME.totalAssets();
        uint256 supply       = spPRIME.totalSupply();

        // Drip is pending, realizeLoss must settle it before writing chi down.
        assertEq(chiBefore,    1.049999999999999999961070145e27);  // ~5% APY
        assertEq(assetsBefore, supply * chiBefore / RAY);
        assertEq(supply,       1_000_000e6 - 1);  // Rounding

        uint192 expectedChiAfterLossEvent = uint192(((assetsBefore - loss) * RAY) / supply);

        assertEq(expectedChiAfterLossEvent, 0.949999999998949999999998949e27);

        assertEq(spPRIME.rho(),          block.timestamp - 365 days);
        assertEq(spPRIME.totalSupply(),  supply);
        assertEq(spPRIME.assetsOf(user), assetsBefore);

        vm.expectEmit(address(spPRIME));
        emit LossRealized(expectedChiAfterLossEvent, loss);

        vm.prank(riskManager);
        spPRIME.realizeLoss(loss);

        assertEq(spPRIME.chi(),          expectedChiAfterLossEvent);
        assertEq(spPRIME.rho(),          block.timestamp);
        assertEq(spPRIME.totalSupply(),  supply);
        assertEq(spPRIME.assetsOf(user), supply * expectedChiAfterLossEvent / RAY);

        uint256 realizedLoss = assetsBefore - spPRIME.totalAssets();

        assertEq(realizedLoss, loss + 1);
    }

    function test_realizeLoss_accrualContinuesFromNewChi() public {
        _depositAndPause();

        vm.prank(riskManager);
        spPRIME.realizeLoss(100_000e6);

        uint192 chiAfterLoss = spPRIME.chi();

        assertEq(chiAfterLoss,          0.899999999999899999999999899e27);
        assertEq(spPRIME.totalAssets(), 900_000e6 - 2);  // Rounding

        skip(365 days);

        spPRIME.drip();

        // 5% APY over one year, compounding on the new chi
        assertEq(spPRIME.chi(), 1.049999999999999999961070145e27 * chiAfterLoss / RAY);

        assertEq(spPRIME.totalAssets(), 945_000e6 - 2);  // Rounding
    }

    function test_realizeLoss_redeemReflectsLoss() public {
        uint256 loss = 100_000e6;

        _depositAndPause();

        uint256 supply = spPRIME.totalSupply();

        uint256 expectedChiAfterLossEvent = uint192(((DEPOSIT - loss) * RAY) / supply);

        vm.prank(riskManager);
        spPRIME.realizeLoss(loss);

        vm.prank(admin);
        spPRIME.unpause();

        uint256 shares   = spPRIME.balanceOf(user);
        uint256 expected = spPRIME.assetsOf(user);

        assertEq(expected, supply * expectedChiAfterLossEvent / RAY - 1);

        vm.prank(user);
        spPRIME.requestRedeem(shares, user);

        assertEq(spPRIME.balanceOf(user),       0);
        assertEq(usdc.balanceOf(user),          0);
        assertEq(spPRIME.pendingRedeemShares(), shares);
    }

}
