// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

contract E2ETests is TestBase {

    address internal user = makeAddr("user");
    address internal ali  = makeAddr("ali");
    address internal bob  = makeAddr("bob");

    function setUp() public override {
        super.setUp();

        vm.label(user, "user");
        vm.label(ali,  "ali");
        vm.label(bob,  "bob");
    }

    function test_e2e_flow1() external {
        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        AccountBalances memory takerBalances = AccountBalances({
            account           : taker,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        // Vault is at capacity, so the deposit request queues instead of filling instantly

        _setCapacity(0);

        vaultState.availableCapacityValue = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 1. User requests deposit

        _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Queued)

        vaultState.availableLiquidAssets = 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 1_000_000e6 - 1;
        vaultState.depositRequests.length            = 1;

        vaultBalances.savingsShareValue = 1_000_000e6 - 1;

        _assertDepositRequest(0, user, user, 1_000_000e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 2. Warp 1% of a year, queued spUSDC earns yield while waiting, no drip so rho and chi are unchanged

        skip(365 days / 100);

        vaultState.availableLiquidAssets = 1_000_373.027404e6;

        vaultState.depositRequests.pendingShareValue = 1_000_373.027404e6;

        vaultBalances.savingsShareValue = 1_000_373.027404e6;

        _assertDepositRequest(0, user, user, 1_000_373.027404e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 3. User gets filled once capacity is raised, at the current spUSDC value and chi of 1.05^(1/100)

        _setCapacity(VAULT_CAPACITY);

        _processPendingDeposits();

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000488020685060001359567214e27;

        vaultState.totalAssets            = 1_000_373.027403e6;
        vaultState.availableCapacityValue = 99_048_429.041102e6;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 1;

        userBalances.shareValue = 1_000_373.027403e6;

        assertEq(spPrime.balanceOf(user), 999_885_062_810);  // 1_000_373.027403e6 / 1.000488

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 4. Warp 1% of a year, spPrime grows at 5% APY while spUSDC grows at 3.8% APY

        skip(365 days / 100);

        vaultState.totalAssets            = 1_000_861.230133e6;
        vaultState.availableCapacityValue = 99_096_766.723297e6;
        vaultState.availableLiquidAssets  = 1_000_746.193959e6;

        userBalances.shareValue = 1_000_861.230133e6;

        vaultBalances.savingsShareValue = 1_000_746.193959e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 5. Take, taker deploys half of the vault's spUSDC

        uint256 takenSavingsShares = spUSDC.balanceOf(address(spPrime)) / 2;

        _take(takenSavingsShares);

        vaultState.availableLiquidAssets = 500_373.096979e6;

        vaultBalances.savingsShareValue = 500_373.096979e6;

        takerBalances.savingsShareValue = 500_373.096979e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 6. Warp 1% of a year

        skip(365 days / 100);

        vaultState.totalAssets            = 1_001_349.671116e6;
        vaultState.availableCapacityValue = 99_145_127.99528e6;
        vaultState.availableLiquidAssets  = 500_559.749857e6;

        userBalances.shareValue = 1_001_349.671116e6;

        vaultBalances.savingsShareValue = 500_559.749857e6;

        takerBalances.savingsShareValue = 500_559.749857e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 7. User requests redeem of 250k shares, worth 250.4k USD at chi of 1.05^(3/100)

        _requestRedeem(user, 250_000e6);  // Redeem Request 0

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.001464776663976194073004157e27;

        vaultState.redeemRequests.pendingShareValue = 250_366.194165e6;
        vaultState.redeemRequests.length            = 1;

        userBalances.shareValue = 750_983.47695e6;

        vaultBalances.shareValue = 250_366.194165e6;

        _assertRedeemRequest(0, user, user, 250_366.194165e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 8. Warp 1% of a year, the queued redeem keeps earning at the vault rate

        skip(365 days / 100);

        vaultState.totalAssets            = 1_001_838.350469e6;
        vaultState.availableCapacityValue = 99_193_512.868565e6;
        vaultState.availableLiquidAssets  = 500_746.472361e6;

        vaultState.redeemRequests.pendingShareValue = 250_488.378047e6;

        userBalances.shareValue = 751_349.972421e6;

        vaultBalances.shareValue        = 250_488.378047e6;
        vaultBalances.savingsShareValue = 500_746.472361e6;

        takerBalances.savingsShareValue = 500_746.472361e6;

        _assertRedeemRequest(0, user, user, 250_488.378047e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 9. User redeems, the request is filled from the spUSDC still held by the vault

        _processPendingRedeems();

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.001953512190347208998217872e27;

        vaultState.totalAssets            = 751_349.972421e6;
        vaultState.availableCapacityValue = 99_444_001.246613e6;
        vaultState.availableLiquidAssets  = 250_258.094314e6;

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.firstPendingId    = 1;

        userBalances.assets = 250_488.378047e6;

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 250_258.094314e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);
    }

    function test_e2e_flow2() external {
        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        AccountBalances memory takerBalances = AccountBalances({
            account           : taker,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        // Vault is at capacity, so deposit requests queue instead of filling instantly

        _setCapacity(0);

        vaultState.availableCapacityValue = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 1. User requests deposit 0

        _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Queued)

        vaultState.availableLiquidAssets = 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 1_000_000e6 - 1;
        vaultState.depositRequests.length            = 1;

        vaultBalances.savingsShareValue = 1_000_000e6 - 1;

        _assertDepositRequest(0, user, user, 1_000_000e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 2. Warp 1 year, queued spUSDC earns 3.8% while waiting, spPrime has no supply yet

        skip(365 days);

        vaultState.availableLiquidAssets = 1_038_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 1_038_000e6 - 1;

        vaultBalances.savingsShareValue = 1_038_000e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 3. Taker takes all of the vault's spUSDC, which backs deposit 0

        _take(spUSDC.balanceOf(address(spPrime)));  // Deposit Request 0 savings shares

        vaultState.availableLiquidAssets = 0;

        vaultBalances.savingsShareValue = 0;

        takerBalances.savingsShareValue = 1_038_000e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 4. User requests deposit 1, which drips chi to 1.05

        _requestDeposit(user, 1_000_000e6);  // Deposit Request 1 (Queued)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.049999999999999999961070145e27;

        vaultState.availableLiquidAssets = 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 2_038_000e6 - 1;
        vaultState.depositRequests.length            = 2;

        vaultBalances.savingsShareValue = 1_000_000e6 - 1;

        _assertDepositRequest(0, user, user, 1_038_000e6 - 1);
        _assertDepositRequest(1, user, user, 1_000_000e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 5. Warp 1 year, queued deposits keep their spUSDC value growth even though deposit 0 shares were taken

        skip(365 days);

        vaultState.availableLiquidAssets = 1_038_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 2_115_444e6 - 1;

        vaultBalances.savingsShareValue = 1_038_000e6 - 1;

        takerBalances.savingsShareValue = 1_077_444e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 6. User gets filled for deposit 0 once capacity is raised, at chi of 1.05^2

        _setCapacity(VAULT_CAPACITY);

        _processPendingDeposits(1);  // Deposit Request 0 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.102499999999999999918247304e27;

        vaultState.totalAssets            = 1_077_444e6 - 2;
        vaultState.availableCapacityValue = 109_172_556e6 + 1;

        vaultState.depositRequests.pendingShareValue = 1_038_000e6 - 1;
        vaultState.depositRequests.length            = 1;
        vaultState.depositRequests.firstPendingId    = 1;

        userBalances.shareValue = 1_077_444e6 - 2;

        _assertDepositRequest(1, user, user, 1_038_000e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 7. Warp 1 year, spPrime grows at 5% APY while spUSDC grows at 3.8% APY

        skip(365 days);

        vaultState.totalAssets            = 1_131_316.2e6 - 3;
        vaultState.availableCapacityValue = 114_631_183.8e6 + 2;
        vaultState.availableLiquidAssets  = 1_077_444e6 - 1;

        vaultState.depositRequests.pendingShareValue = 1_077_444e6 - 1;

        userBalances.shareValue = 1_131_316.2e6 - 3;

        vaultBalances.savingsShareValue = 1_077_444e6 - 1;

        takerBalances.savingsShareValue = 1_118_386.872e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 8. Taker takes all of the vault's spUSDC, which backs deposit 1

        _take(spUSDC.balanceOf(address(spPrime)));  // Deposit Request 1 savings shares

        vaultState.availableLiquidAssets = 0;

        vaultBalances.savingsShareValue = 0;

        takerBalances.savingsShareValue = 2_195_830.872e6 - 1;  // 1_118_386.872e6 + 1_077_444e6

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 9. Warp 1 year

        skip(365 days);

        vaultState.totalAssets            = 1_187_882.01e6 - 3;
        vaultState.availableCapacityValue = 120_362_742.99e6 + 2;

        vaultState.depositRequests.pendingShareValue = 1_118_386.872e6 - 1;

        userBalances.shareValue = 1_187_882.01e6 - 3;

        takerBalances.savingsShareValue = 2_279_272.445135e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 10. User gets filled for deposit 1 at chi of 1.05^4

        _processPendingDeposits(1);  // Deposit Request 1 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.215506249999999999819735307e27;

        vaultState.totalAssets            = 2_306_268.882e6 - 4;
        vaultState.availableCapacityValue = 119_244_356.118e6 + 3;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 2;

        userBalances.shareValue = 2_306_268.882e6 - 4;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 11. Warp 1 year

        skip(365 days);

        vaultState.totalAssets            = 2_421_582.3261e6 - 4;
        vaultState.availableCapacityValue = 125_206_573.9239e6 + 3;

        userBalances.shareValue = 2_421_582.3261e6 - 4;

        takerBalances.savingsShareValue = 2_365_884.79805e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 12. User requests redeem of half of the shares, worth 1.21m USD at chi of 1.05^5

        _requestRedeem(user, spPrime.balanceOf(user) / 2);  // Redeem Request 0

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.276281562499999999763402590e27;

        vaultState.redeemRequests.pendingShareValue = 1_210_791.163048e6;
        vaultState.redeemRequests.length            = 1;

        userBalances.shareValue = 1_210_791.163048e6;

        vaultBalances.shareValue = 1_210_791.163048e6;

        _assertRedeemRequest(0, user, user, 1_210_791.163048e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 13. Warp 1 year, the queued redeem keeps earning at the vault rate

        skip(365 days);

        vaultState.totalAssets            = 2_542_661.442401e6;
        vaultState.availableCapacityValue = 131_466_902.620098e6;

        vaultState.redeemRequests.pendingShareValue = 1_271_330.7212e6;

        userBalances.shareValue = 1_271_330.7212e6;

        vaultBalances.shareValue = 1_271_330.7212e6;

        takerBalances.savingsShareValue = 2_455_788.420376e6;

        _assertRedeemRequest(0, user, user, 1_271_330.7212e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 14. Taker returns enough spUSDC to cover redeem request 0

        // Redeem Request 0 is owed 1_271_330.7212e6 + 2 Rounding
        uint256 returnedSavingsShares = spUSDC.convertToShares(1_271_330.7212e6 + 2);

        vm.prank(taker);
        spUSDC.transfer(address(spPrime), returnedSavingsShares);

        vaultState.availableLiquidAssets = 1_271_330.7212e6 + 1;

        vaultBalances.savingsShareValue = 1_271_330.7212e6 + 1;

        takerBalances.savingsShareValue = 1_184_457.699174e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 15. User gets filled for redeem request 0

        _processPendingRedeems();  // Redeem Request 0 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.340095640624999999701887263e27;

        vaultState.totalAssets            = 1_271_330.7212e6;
        vaultState.availableCapacityValue = 132_738_233.341299e6;
        vaultState.availableLiquidAssets  = 1;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.firstPendingId    = 1;

        userBalances.assets = 1_271_330.7212e6;

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 1;  // Rounding

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 16. User requests redeem of all remaining shares

        _requestRedeem(user, spPrime.balanceOf(user));  // Redeem Request 1

        vaultState.redeemRequests.pendingShareValue = 1_271_330.7212e6;
        vaultState.redeemRequests.length            = 1;

        userBalances.shareValue = 0;

        vaultBalances.shareValue = 1_271_330.7212e6;

        _assertRedeemRequest(1, user, user, 1_271_330.7212e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 17. Warp 1 year, the queued redeem keeps earning at the vault rate

        skip(365 days);

        vaultState.totalAssets            = 1_334_897.25726e6;
        vaultState.availableCapacityValue = 139_375_145.008364e6;
        vaultState.availableLiquidAssets  = 1;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 1_334_897.25726e6;

        vaultBalances.shareValue        = 1_334_897.25726e6;
        vaultBalances.savingsShareValue = 1;  // Rounding

        takerBalances.savingsShareValue = 1_229_467.091743e6;

        _assertRedeemRequest(1, user, user, 1_334_897.25726e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 18. Taker returns enough spUSDC to cover redeem request 1, the taker's spUSDC grew at 3.8% while
        //     the redeem is owed 5%, so the taker tops up the difference before returning it

        // Redeem Request 1 is owed 1_334_897.25726e6 + 3 Rounding
        deal(address(spUSDC), taker, spUSDC.convertToShares(1_334_897.25726e6 + 3));

        returnedSavingsShares = spUSDC.balanceOf(taker);

        vm.prank(taker);
        spUSDC.transfer(address(spPrime), returnedSavingsShares);

        vaultState.availableLiquidAssets = 1_334_897.25726e6 + 3;  // Includes 1 rounding left from redeem request 0

        vaultBalances.savingsShareValue = 1_334_897.25726e6 + 3;

        takerBalances.savingsShareValue = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 19. User gets filled for redeem request 1, the vault has no supply left

        _processPendingRedeems();  // Redeem Request 1 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.407100422656249999634811897e27;

        vaultState.totalAssets            = 0;
        vaultState.availableCapacityValue = 140_710_042.265624e6;
        vaultState.availableLiquidAssets  = 2;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.firstPendingId    = 2;

        userBalances.assets = 2_606_227.97846e6;  // 1_271_330.7212e6 + 1_334_897.25726e6

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 2;  // Rounding

        assertEq(spPrime.totalSupply(),         0);
        assertEq(spPrime.balanceOf(user),       0);
        assertEq(spPrime.pendingRedeemShares(), 0);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);
    }

    function test_e2e_lossWithPendingQueues() external {
        AccountBalances memory aliBalances = AccountBalances({
            account           : ali,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        AccountBalances memory bobBalances = AccountBalances({
            account           : bob,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        AccountBalances memory takerBalances = AccountBalances({
            account           : taker,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        // Vault capacity only fits Ali's deposit, so Bob's deposit queues

        _setCapacity(1_000_000e6);

        vaultState.availableCapacityValue = 1_000_000e6;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 1. Ali requests deposit 0, filled instantly

        _requestDeposit(ali, 1_000_000e6);  // Deposit Request 0 (Filled instantly)

        vaultState.totalAssets            = 1_000_000e6 - 1;
        vaultState.availableCapacityValue = 1;  // Rounding
        vaultState.availableLiquidAssets  = 1_000_000e6 - 1;

        vaultState.depositRequests.firstPendingId = 1;

        aliBalances.shareValue = 1_000_000e6 - 1;

        vaultBalances.savingsShareValue = 1_000_000e6 - 1;

        assertEq(spPrime.balanceOf(ali), 1_000_000e6 - 1);  // 1_000_000e6 - 1 / 1.0

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 2. Warp 1 year, spPrime grows at 5% APY while spUSDC grows at 3.8% APY

        skip(365 days);

        vaultState.totalAssets           = 1_050_000e6 - 2;
        vaultState.availableLiquidAssets = 1_038_000e6 - 1;

        aliBalances.shareValue = 1_050_000e6 - 2;

        vaultBalances.savingsShareValue = 1_038_000e6 - 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 3. Bob requests deposit 1, queued because the vault is at capacity

        _requestDeposit(bob, 1_000_000e6);  // Deposit Request 1 (Queued)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.049999999999999999961070145e27;

        vaultState.availableLiquidAssets = 2_038_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 1_000_000e6 - 1;
        vaultState.depositRequests.length            = 1;

        vaultBalances.savingsShareValue = 2_038_000e6 - 1;

        _assertDepositRequest(1, bob, bob, 1_000_000e6 - 1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 4. Taker takes all of the vault's spUSDC, including the shares backing Bob's queued deposit

        _take(spUSDC.balanceOf(address(spPrime)));

        vaultState.availableLiquidAssets = 0;

        vaultBalances.savingsShareValue = 0;

        takerBalances.savingsShareValue = 2_038_000e6 - 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 5. Warp 1 year, spPrime grows at 5% APY while Bob's queued deposit grows at the 3.8% spUSDC rate

        skip(365 days);

        vaultState.totalAssets = 1_102_500e6 - 2;

        vaultState.depositRequests.pendingShareValue = 1_038_000e6 - 1;

        aliBalances.shareValue = 1_102_500e6 - 2;

        takerBalances.savingsShareValue = 2_115_444e6 - 1;

        _assertDepositRequest(1, bob, bob, 1_038_000e6 - 1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 6. Ali requests redeem of half of the shares, queued because there is no liquidity

        _requestRedeem(ali, spPrime.balanceOf(ali) / 2);  // Redeem Request 0

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.102499999999999999918247304e27;

        vaultState.redeemRequests.pendingShareValue = 551_250e6 - 2;
        vaultState.redeemRequests.length            = 1;

        aliBalances.shareValue = 551_250e6 - 1;

        vaultBalances.shareValue = 551_250e6 - 2;

        _assertRedeemRequest(0, ali, ali, 551_250e6 - 2);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 7. Pauser pauses the vault, so queues can't be processed

        _pause();

        assertEq(spPrime.paused(), true);

        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        _processPendingDeposits();

        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        _processPendingRedeems();

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 8. Loss Manager records a 10% loss on deployed funds, chi drops by 10% so Ali's held shares and
        //    pending redeem lose 10% of their value

        vm.prank(lossManager);
        spPrime.adjustTotalAssets(-(110_250e6 - 1));  // 10% of 1_102_500e6 - 2 totalAssets

        vaultState.chi = 0.992249999999992249999999992e27;

        vaultState.totalAssets            = 992_250e6 - 2;
        vaultState.availableCapacityValue = 0;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 496_125e6 - 1;

        aliBalances.shareValue = 496_125e6 - 1;

        vaultBalances.shareValue = 496_125e6 - 1;

        _assertRedeemRequest(0, ali, ali, 496_125e6 - 1);

        // Bob's pending deposit is held in spUSDC, so its value is unchanged by the loss
        _assertDepositRequest(1, bob, bob, 1_038_000e6 - 1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 9. Unpauser unpauses the vault

        _unpause();

        assertEq(spPrime.paused(), false);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 10. Operator raises capacity

        _setCapacity(VAULT_CAPACITY);

        vaultState.availableCapacityValue = 98_232_750e6;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 11. Bob gets filled for deposit 1 at the post-loss chi, so Bob gets more shares than Ali did for
        //     the same 1m deposit because each share is cheaper, Ali's value is unchanged by Bob's mint

        _processPendingDeposits(1);  // Deposit Request 1 (Filled)

        vaultState.totalAssets            = 2_030_250e6 - 3;
        vaultState.availableCapacityValue = 97_194_750e6 + 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 2;

        bobBalances.shareValue = 1_038_000e6 - 2;

        assertEq(spPrime.balanceOf(bob), 1_046_107.331820e6);  // 1_038_000e6 - 1 / 0.99225

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 12. Warp 1 year, the queued redeem keeps earning at the vault rate

        skip(365 days);

        vaultState.totalAssets            = 2_131_762.5e6 - 3;
        vaultState.availableCapacityValue = 102_054_487.5e6 + 1;

        vaultState.redeemRequests.pendingShareValue = 520_931.25e6 - 2;

        aliBalances.shareValue = 520_931.25e6 - 1;
        bobBalances.shareValue = 1_089_900e6 - 2;

        vaultBalances.shareValue = 520_931.25e6 - 2;

        takerBalances.savingsShareValue = 2_195_830.872e6 - 1;

        _assertRedeemRequest(0, ali, ali, 520_931.25e6 - 2);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 13. Taker returns enough spUSDC to cover redeem request 0

        // Redeem Request 0 is owed 520_931.25e6 - 2 + 3 Rounding
        uint256 returnedSavingsShares = spUSDC.convertToShares(520_931.25e6 + 1);

        vm.prank(taker);
        spUSDC.transfer(address(spPrime), returnedSavingsShares);

        vaultState.availableLiquidAssets = 520_931.25e6;

        vaultBalances.savingsShareValue = 520_931.25e6;

        takerBalances.savingsShareValue = 1_674_899.622e6 - 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 14. Ali gets filled for redeem request 0 at the post-loss value

        _processPendingRedeems();  // Redeem Request 0 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.041862499999991862461371842e27;

        vaultState.totalAssets            = 1_610_831.25e6 - 2;
        vaultState.availableCapacityValue = 102_575_418.75e6;
        vaultState.availableLiquidAssets  = 1;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.firstPendingId    = 1;

        aliBalances.assets = 520_931.25e6 - 2;

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 1;  // Rounding

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 15. Ali and Bob request redeem of all their remaining shares

        _requestRedeem(ali, spPrime.balanceOf(ali));  // Redeem Request 1
        _requestRedeem(bob, spPrime.balanceOf(bob));  // Redeem Request 2

        vaultState.redeemRequests.pendingShareValue = 1_610_831.25e6 - 2;
        vaultState.redeemRequests.length            = 2;

        aliBalances.shareValue = 0;
        bobBalances.shareValue = 0;

        vaultBalances.shareValue = 1_610_831.25e6 - 2;

        _assertRedeemRequest(1, ali, ali, 520_931.25e6 - 1);
        _assertRedeemRequest(2, bob, bob, 1_089_900e6 - 2);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 16. Warp 1 year, the queued redeems keep earning at the vault rate

        skip(365 days);

        vaultState.totalAssets            = 1_691_372.8125e6 - 2;
        vaultState.availableCapacityValue = 107_704_189.6875e6;
        vaultState.availableLiquidAssets  = 1;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 1_691_372.8125e6 - 2;

        vaultBalances.shareValue        = 1_691_372.8125e6 - 2;
        vaultBalances.savingsShareValue = 1;  // Rounding

        takerBalances.savingsShareValue = 1_738_545.807635e6;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 17. Taker returns enough spUSDC to cover redeem requests 1 and 2

        // Redeem Requests 1 and 2 are owed 1_691_372.8125e6 - 2 + 2 Rounding
        returnedSavingsShares = spUSDC.convertToShares(1_691_372.8125e6);

        vm.prank(taker);
        spUSDC.transfer(address(spPrime), returnedSavingsShares);

        vaultState.availableLiquidAssets = 1_691_372.8125e6;

        vaultBalances.savingsShareValue = 1_691_372.8125e6;

        takerBalances.savingsShareValue = 47_172.995135e6;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 18. Ali and Bob get filled for redeem requests 1 and 2, the vault has no supply left.
        ///    Ali deposited a year before Bob but gets back less, because Ali held shares through
        ///    the loss while Bob's queued deposit was still in spUSDC

        _processPendingRedeems();  // Redeem Requests 1 and 2 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.093955624999991455543880878e27;

        vaultState.totalAssets            = 0;
        vaultState.availableCapacityValue = 109_395_562.5e6 - 1;
        vaultState.availableLiquidAssets  = 3;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.firstPendingId    = 3;

        aliBalances.assets = 1_067_909.0625e6 - 3;  // 520_931.25e6 - 2 + 546_977.8125e6 - 1
        bobBalances.assets = 1_144_395e6 - 2;

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 3;  // Rounding

        assertLt(usdc.balanceOf(ali), usdc.balanceOf(bob));

        assertEq(spPrime.totalSupply(),         0);
        assertEq(spPrime.pendingRedeemShares(), 0);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);
    }

}
