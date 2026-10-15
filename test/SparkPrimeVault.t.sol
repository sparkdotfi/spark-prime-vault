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

    // Success tests

    function test_requestDeposit_partialFill() external {
        _requestDeposit(user, 1_000_000e6); // Deposit Request 0 (Filled instantly)

        _setCapacity(1_500_000e6);

        assertEq(spUSDC.nowChi(), 1.076547682778879499179621925e27);

        vaultState.rho                   = vm.getBlockTimestamp();
        vaultState.chi                   = 1.049999999999999999961070145e27;
        vaultState.totalSupply           = 952_380.952380e6; // 1_000_000e6 USDC -> spUSDC -> USD -> spPrime
        vaultState.totalAssets           = 1_000_000e6 - 2;
        vaultState.availableCapacity     = 1_500_000e6 - 952_380.952380e6;
        vaultState.availableLiquidAssets = 1_000_000e6 - 1;

        // The head points at cancelled request 1
        vaultState.depositRequests.pendingShares  = 0;
        vaultState.depositRequests.length         = 0;
        vaultState.depositRequests.firstPendingId = 1;

        AccountBalances memory userBalances = AccountBalances({
            account         : user,
            assets          : 0,
            shares          : 952_380.952380e6,
            savingsShares   : 0,
            claimableAssets : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account         : address(spPrime),
            assets          : 0,
            shares          : 0,
            savingsShares   : 928_895.223125e6,  // 1_000_000e6 USDC -> spUSDC
            claimableAssets : 0
        });

        _assertVaultState();

        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        deal(address(usdc), user, 800_000e6);

        vm.prank(user);
        usdc.approve(address(spPrime), 800_000e6);

        uint256 expectedSavingsShares       = spUSDC.convertToShares(800_000e6);
        uint256 expectedSavingsSharesBurned = 534_114.753297e6;  // availableCapacity -> USDC -> spUSDC
        uint256 expectedShares              = vaultState.availableCapacity - 2;  // Rounding error away from remaining capacity.
        uint256 expectedConvertedAssets     = 574_999.999999e6;  // expectedSavingsSharesBurned -> USDC

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Referral(REFERRAL, 1, user, user, 800_000e6);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.DepositRequest(1, user, user, 800_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Deposit(1, user, user, expectedSavingsSharesBurned, expectedConvertedAssets, expectedShares);

        vm.prank(user);
        uint256 requestId = spPrime.requestDeposit(800_000e6, user, REFERRAL);

        assertEq(requestId, 1);

        vaultState.totalSupply           += expectedShares;
        vaultState.totalAssets           += expectedConvertedAssets;
        vaultState.availableCapacity     = 2;
        vaultState.availableLiquidAssets += 800_000e6;

        vaultState.depositRequests.pendingShares  = expectedSavingsShares - expectedSavingsSharesBurned;
        vaultState.depositRequests.length         = 1;
        vaultState.depositRequests.firstPendingId = 1;

        userBalances.shares += expectedShares;

        vaultBalances.savingsShares += expectedSavingsShares;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

    function test_requestDeposit_queued() external {
        _requestDeposit(user, 1_000_000e6); // Deposit Request 0 (Filled instantly)

        _setCapacity(952_380.952380e6);  // 1_000_000e6 USDC -> spUSDC -> USD -> spPrime

        assertEq(spUSDC.nowChi(), 1.076547682778879499179621925e27);

        vaultState.rho                   = vm.getBlockTimestamp();
        vaultState.chi                   = 1.049999999999999999961070145e27;
        vaultState.totalSupply           = 952_380.952380e6;
        vaultState.totalAssets           = 1_000_000e6 - 2;
        vaultState.availableCapacity     = 0;
        vaultState.availableLiquidAssets = 1_000_000e6 - 1;

        // The head points at cancelled request 1
        vaultState.depositRequests.pendingShares  = 0;
        vaultState.depositRequests.length         = 0;
        vaultState.depositRequests.firstPendingId = 1;

        AccountBalances memory userBalances = AccountBalances({
            account         : user,
            assets          : 0,
            shares          : 952_380.952380e6,
            savingsShares   : 0,
            claimableAssets : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account         : address(spPrime),
            assets          : 0,
            shares          : 0,
            savingsShares   : 928_895.223125e6,  // 1_000_000e6 USDC -> spUSDC
            claimableAssets : 0
        });

        _assertVaultState();

        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        deal(address(usdc), user, 800_000e6);

        vm.prank(user);
        usdc.approve(address(spPrime), 800_000e6);

        uint256 expectedSavingsShares = spUSDC.convertToShares(800_000e6);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.Referral(REFERRAL, 1, user, user, 800_000e6);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.DepositRequest(1, user, user, 800_000e6, expectedSavingsShares);

        vm.prank(user);
        uint256 requestId = spPrime.requestDeposit(800_000e6, user, REFERRAL);

        assertEq(requestId, 1);

        vaultState.availableLiquidAssets += 800_000e6;

        vaultState.depositRequests.pendingShares  = expectedSavingsShares;
        vaultState.depositRequests.length         = 1;
        vaultState.depositRequests.firstPendingId = 1;

        vaultBalances.savingsShares += expectedSavingsShares;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

}


contract RequestRedeemTests is SparkPrimeVaultTests {

    // Failure tests

    function test_requestRedeem_paused() external {
        _pause();

        vm.expectRevert("SparkPrimeVault/paused");
        vm.prank(user);
        spPrime.requestRedeem(100e6, user);
    }
    
    function test_requestRedeem_zeroRecipient() external {
        vm.expectRevert("SparkPrimeVault/zero-recipient");
        vm.prank(user);
        spPrime.requestRedeem(100e6, address(0));
    }
    
    function test_requestRedeem_recipientCannotReceive() external {
        _blacklist(user);

        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vm.prank(user);
        spPrime.requestRedeem(100e6, user);
    }

    function test_requestRedeem_belowMinimumBoundary() external {
        _requestDeposit(user, 1_000e6); // Deposit Request 0 (Filled instantly)

        vm.expectRevert("SparkPrimeVault/below-minimum");
        vm.prank(user);
        spPrime.requestRedeem(MINIMUM_REDEEM - 1, user);

        vm.prank(user);
        spPrime.requestRedeem(MINIMUM_REDEEM, user);
    }

    function test_requestRedeem_insufficientBalanceBoundary() external {
        _requestDeposit(user, 1_000e6); // Deposit Request 0 (Filled instantly)

        uint256 spPrimeShares = spPrime.balanceOf(user);

        assertEq(spPrimeShares, 952.380951e6);

        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vm.prank(user);
        spPrime.requestRedeem(spPrimeShares + 1, user);

        vm.prank(user);
        spPrime.requestRedeem(spPrimeShares, user);
    }

    // Success tests

    function test_requestRedeem() external {
        _requestDeposit(user, 1_000_000e6); // Deposit Request 0 (Filled instantly)

        vaultState.rho                   = vm.getBlockTimestamp();
        vaultState.chi                   = 1.049999999999999999961070145e27;
        vaultState.totalSupply           = 952_380.952380e6;  // 1_000_000e6 USDC -> spUSDC -> USD -> spPrime
        vaultState.totalAssets           = 1_000_000e6 - 2;
        vaultState.availableCapacity     = VAULT_CAPACITY - 952_380.952380e6;
        vaultState.availableLiquidAssets = 1_000_000e6 - 1;

        vaultState.depositRequests.firstPendingId = 1;

        AccountBalances memory userBalances = AccountBalances({
            account         : user,
            assets          : 0,
            shares          : 952_380.952380e6,
            savingsShares   : 0,
            claimableAssets : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account         : address(spPrime),
            assets          : 0,
            shares          : 0,
            savingsShares   : 928_895.223125e6,  // 1_000_000e6 USDC -> spUSDC
            claimableAssets : 0
        });

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.RedeemRequest(0, user, user, 500_000e6, 0);

        vm.prank(user);
        uint256 requestId = spPrime.requestRedeem(500_000e6, user);

        assertEq(requestId, 0);

        vaultState.redeemRequests.pendingShares  = 500_000e6;
        vaultState.redeemRequests.length         = 1;
        vaultState.redeemRequests.firstPendingId = 0;

        userBalances.shares  -= 500_000e6;
        vaultBalances.shares += 500_000e6;

        _assertRedeemRequest(0, user, user, 500_000e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

    function test_requestRedeem_withFee() external {
        _setRedeemFeeRate(0.005e18);  // 0.5%

        _requestDeposit(user, 1_000_000e6); // Deposit Request 0 (Filled instantly)

        vaultState.rho                   = vm.getBlockTimestamp();
        vaultState.chi                   = 1.049999999999999999961070145e27;
        vaultState.totalSupply           = 952_380.952380e6;  // 1_000_000e6 USDC -> spUSDC -> USD -> spPrime
        vaultState.totalAssets           = 1_000_000e6 - 2;
        vaultState.availableCapacity     = VAULT_CAPACITY - 952_380.952380e6;
        vaultState.availableLiquidAssets = 1_000_000e6 - 1;

        vaultState.depositRequests.firstPendingId = 1;

        AccountBalances memory userBalances = AccountBalances({
            account         : user,
            assets          : 0,
            shares          : 952_380.952380e6,
            savingsShares   : 0,
            claimableAssets : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account         : address(spPrime),
            assets          : 0,
            shares          : 0,
            savingsShares   : 928_895.223125e6,  // 1_000_000e6 USDC -> spUSDC
            claimableAssets : 0
        });

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // Assets held (spUSDC value) match assets owed to spPrime holders, within rounding
        assertEq(spPrime.availableLiquidAssets() - spPrime.totalAssets(), 1);

        uint256 expectedFee = 2_500e6;  // 500_000e6 * 0.5%

        vm.expectEmit(address(spPrime));
        emit SparkPrimeVault.RedeemRequest(0, user, user, 500_000e6, expectedFee);

        vm.prank(user);
        uint256 requestId = spPrime.requestRedeem(500_000e6, user);

        assertEq(requestId, 0);

        // Fee shares are burned, so supply and assets drop and capacity frees up
        vaultState.totalSupply       -= expectedFee;
        vaultState.totalAssets        = 1_000_000e6 - 2_625e6 - 2;  // 2_500e6 fee shares * 1.05 chi
        vaultState.availableCapacity += expectedFee;

        vaultState.redeemRequests.pendingShares  = 500_000e6 - expectedFee;
        vaultState.redeemRequests.length         = 1;
        vaultState.redeemRequests.firstPendingId = 0;

        userBalances.shares  -= 500_000e6;
        vaultBalances.shares += 500_000e6 - expectedFee;

        _assertRedeemRequest(0, user, user, 500_000e6 - expectedFee);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // Assets held are unchanged but assets owed dropped by the burned fee, the difference is Spark's profit
        assertEq(spPrime.availableLiquidAssets() - spPrime.totalAssets(), 2_625e6 + 1);
    }

}
