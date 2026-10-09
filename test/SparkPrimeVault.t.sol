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

        // vm.prank(admin);
        // spPRIME.setVSRBounds(RAY, MAX_VSR);

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
        // TODO
    }

    function test_requestDeposit_partialInstantFill_oneShareCapacityLeft() external {
        // TODO
    }

    function test_requestDeposit_queued_noCapacity() external {
        // TODO
    }

    function test_requestDeposit_queued_queueNotEmpty() external {
        // TODO
    }

    function test_requestDeposit_queued_subShareCapacityLeft() external {
        // TODO
    }

    function test_requestDeposit_queued_moreThan500CancelledAhead() external {
        // TODO
    }

    function test_requestDeposit_instantFill_withReferral() external {
        // TODO
    }
    
}
