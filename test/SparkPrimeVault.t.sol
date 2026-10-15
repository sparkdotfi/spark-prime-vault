// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase, SparkPrimeVault, ISparkVaultLike } from "./TestBase.t.sol";

contract SparkPrimeVaultTests is TestBase {

    uint16 internal constant REFERRAL = type(uint16).max;

    address internal user = makeAddr("user");

    function setUp() public override {
        super.setUp();

        vm.label(address(user), "user");

        skip(365 days);
    }

}

contract RequestDepositTests is SparkPrimeVaultTests {

    // Failure tests

    function test_requestDeposit_paused() external {
        _pause();

        vm.expectRevert("SparkPrimeVault/paused");
        vm.prank(user);
        spPrime.requestDeposit(100e6, user, 0);
    }

    function test_requestDeposit_zeroRecipient() external {
        vm.expectRevert("SparkPrimeVault/zero-recipient");
        vm.prank(user);
        spPrime.requestDeposit(100e6, address(0), 0);
    }

    function test_requestDeposit_vaultRecipient() external {
        vm.expectRevert("SparkPrimeVault/vault-recipient");
        vm.prank(user);
        spPrime.requestDeposit(100e6, address(spPrime), 0);
    }

    function test_requestDeposit_belowMinimumBoundary() external {
        deal(address(usdc), user, MINIMUM_DEPOSIT);

        vm.prank(user);
        usdc.approve(address(spPrime), MINIMUM_DEPOSIT);

        vm.expectRevert("SparkPrimeVault/below-minimum");
        vm.prank(user);
        spPrime.requestDeposit(MINIMUM_DEPOSIT - 1, user, 0);

        vm.prank(user);
        spPrime.requestDeposit(MINIMUM_DEPOSIT, user, 0);
    }

    function test_requestDeposit_notEnoughAllowanceBoundary() external {
        deal(address(usdc), user, 1_000_000e6 + 1);

        vm.prank(user);
        usdc.approve(address(spPrime), 1_000_000e6);

        vm.prank(user);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        spPrime.requestDeposit(1_000_000e6 + 1, user, 0);

        vm.prank(user);
        spPrime.requestDeposit(1_000_000e6, user, 0);
    }

    function test_requestDeposit_notEnoughBalanceBoundary() external {
        deal(address(usdc), user, 1_000_000e6);

        vm.prank(user);
        usdc.approve(address(spPrime), 1_000_000e6 + 1);

        vm.prank(user);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        spPrime.requestDeposit(1_000_000e6 + 1, user, 0);

        vm.prank(user);
        spPrime.requestDeposit(1_000_000e6, user, 0);
    }

    // Success tests

    function test_requestDeposit_partialFill() external {
        _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Filled instantly)

        _setCapacity(spPrime.convertToShares(1_500_000e6));

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalAssets            = 1_000_000e6 - 2;
        vaultState.availableCapacityValue = 500_000e6;
        vaultState.availableLiquidAssets  = 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 1;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 1_000_000e6 - 2,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssets   : 0
        });

        _assertVaultState();

        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        deal(address(usdc), user, 800_000e6);

        vm.prank(user);
        usdc.approve(address(spPrime), 800_000e6);

        uint256 expectedConvertedAssets       = 500_000e6 - 1;
        uint256 expectedSavingsSharesMinted   = spUSDC.convertToShares(800_000e6);
        uint256 expectedSavingsSharesConsumed = spUSDC.convertToShares(expectedConvertedAssets) + 1;
        uint256 expectedSharesMinted          = spPrime.convertToShares(expectedConvertedAssets);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Referral(REFERRAL, 1, user, user, 800_000e6);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.DepositRequest(1, user, user, 800_000e6, expectedSavingsSharesMinted);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Deposit(1, user, user, expectedSavingsSharesConsumed, expectedConvertedAssets, expectedSharesMinted);

        vm.prank(user);
        uint256 requestId = spPrime.requestDeposit(800_000e6, user, REFERRAL);

        assertEq(requestId, 1);

        _assertDepositRequest(1, user, user, 800_000e6 - 500_000e6);

        vaultState.totalAssets            += expectedConvertedAssets;
        vaultState.availableCapacityValue = 2;
        vaultState.availableLiquidAssets  += 800_000e6;

        vaultState.depositRequests.pendingShareValue += 800_000e6 - 500_000e6;
        vaultState.depositRequests.length            = 1;
        vaultState.depositRequests.firstPendingId    = 1;

        userBalances.shareValue += 500_000e6 - 1;

        vaultBalances.savingsShareValue += 800_000e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

    function test_requestDeposit_queued() external {
        _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Filled instantly)

        _setCapacity(spPrime.convertToShares(1_000_000e6));

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalAssets            = 1_000_000e6 - 2;
        vaultState.availableCapacityValue = 0;
        vaultState.availableLiquidAssets  = 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 1;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 1_000_000e6 - 2,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssets   : 0
        });

        _assertVaultState();

        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        deal(address(usdc), user, 800_000e6);

        vm.prank(user);
        usdc.approve(address(spPrime), 800_000e6);

        uint256 expectedSavingsSharesMinted = spUSDC.convertToShares(800_000e6);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Referral(REFERRAL, 1, user, user, 800_000e6);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.DepositRequest(1, user, user, 800_000e6, expectedSavingsSharesMinted);

        vm.prank(user);
        uint256 requestId = spPrime.requestDeposit(800_000e6, user, REFERRAL);

        assertEq(requestId, 1);

        _assertDepositRequest(1, user, user, 800_000e6 - 1);

        vaultState.availableLiquidAssets += 800_000e6;

        vaultState.depositRequests.pendingShareValue = 800_000e6 - 1;
        vaultState.depositRequests.length            = 1;
        vaultState.depositRequests.firstPendingId    = 1;

        vaultBalances.savingsShareValue += 800_000e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

}
