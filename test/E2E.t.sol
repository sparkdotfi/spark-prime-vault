// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase } from "./TestBase.t.sol";

contract E2ETests is TestBase {

    address internal user = makeAddr("user");

    function setUp() public override {
        super.setUp();

        vm.label(user, "user");
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

        _processPendingDeposits(type(uint256).max);

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

        vm.prank(taker);
        spPrime.take(takenSavingsShares);

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

        // 0. Vault is at capacity, so deposit requests queue instead of filling instantly.

        _setCapacity(0);

        vaultState.availableCapacityValue = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

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

        // 2. Warp

        skip(365 days);

        // spUSDC accrues 3.8% on the queued savings shares, spPrime has no supply yet
        vaultState.availableLiquidAssets = 1_038_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 1_038_000e6 - 1;

        vaultBalances.savingsShareValue = 1_038_000e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 3. Taker takes full `availableLiquidAssets()`

        vm.startPrank(taker);
        spPrime.take(spUSDC.convertToShares(1_038_000e6));  // Deposit Request 0 savings shares
        vm.stopPrank();

        vaultState.availableLiquidAssets = 0;

        vaultBalances.savingsShareValue = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 4. User requests deposit 1

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

        // 5. Warp

        skip(365 days);

        // Queued deposits keep their spUSDC value growth even though deposit 0 shares were taken
        vaultState.availableLiquidAssets = 1_038_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 2_115_444e6 - 1;

        vaultBalances.savingsShareValue = 1_038_000e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 6. User gets filled for first deposit

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

        // 7. Warp

        skip(365 days);

        vaultState.totalAssets            = 1_131_316.2e6 - 3;
        vaultState.availableCapacityValue = 114_631_183.8e6 + 2;
        vaultState.availableLiquidAssets  = 1_077_444e6 - 1;

        vaultState.depositRequests.pendingShareValue = 1_077_444e6 - 1;

        userBalances.shareValue = 1_131_316.2e6 - 3;

        vaultBalances.savingsShareValue = 1_077_444e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 8. Taker takes full `availableLiquidAssets()`

        vm.startPrank(taker);
        spPrime.take(spUSDC.convertToShares(1_077_444e6));  // Deposit Request 1 savings shares
        vm.stopPrank();

        vaultState.availableLiquidAssets = 0;

        vaultBalances.savingsShareValue = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 9. Warp

        skip(365 days);

        vaultState.totalAssets            = 1_187_882.01e6 - 3;
        vaultState.availableCapacityValue = 120_362_742.99e6 + 2;

        vaultState.depositRequests.pendingShareValue = 1_118_386.872e6 - 1;

        userBalances.shareValue = 1_187_882.01e6 - 3;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 10. User gets filled for second deposit

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

        // 11. Warp

        skip(365 days);

        vaultState.totalAssets            = 2_421_582.3261e6 - 4;
        vaultState.availableCapacityValue = 125_206_573.9239e6 + 3;

        userBalances.shareValue = 2_421_582.3261e6 - 4;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 12. User requests partial redeem

        _requestRedeem(user, spPrime.balanceOf(user) / 2);  // Redeem Request 0 (Half of the shares)

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

        // 13. Warp

        skip(365 days);

        // Shares queued for redemption keep accruing yield
        vaultState.totalAssets            = 2_542_661.442401e6;
        vaultState.availableCapacityValue = 131_466_902.620098e6;

        vaultState.redeemRequests.pendingShareValue = 1_271_330.7212e6;

        userBalances.shareValue = 1_271_330.7212e6;

        vaultBalances.shareValue = 1_271_330.7212e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 14. Taker returns liquidity

        // Minimum spUSDC that fills Redeem Request 0 in full (2 extra share units cover rounding)
        deal(address(spUSDC), address(spPrime), 980_028.044433e6);

        vaultState.availableLiquidAssets = 1_271_330.7212e6 + 1;

        vaultBalances.savingsShareValue = 1_271_330.7212e6 + 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 15. User partial redeem gets fulfilled

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

        // 16. User requests partial redeem

        _requestRedeem(user, spPrime.balanceOf(user));  // Redeem Request 1 (Remaining shares)

        vaultState.redeemRequests.pendingShareValue = 1_271_330.7212e6;
        vaultState.redeemRequests.length            = 1;

        userBalances.shareValue = 0;

        vaultBalances.shareValue = 1_271_330.7212e6;

        _assertRedeemRequest(1, user, user, 1_271_330.7212e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 17. Warp

        skip(365 days);

        vaultState.totalAssets            = 1_334_897.25726e6;
        vaultState.availableCapacityValue = 139_375_145.008364e6;

        vaultState.redeemRequests.pendingShareValue = 1_334_897.25726e6;

        vaultBalances.shareValue = 1_334_897.25726e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 18. Taker returns liquidity

        // Minimum spUSDC that fills Redeem Request 1 in full (2 extra share units cover rounding)
        deal(address(spUSDC), address(spPrime), 991_357.848415e6);

        vaultState.availableLiquidAssets = 1_334_897.25726e6 + 2;

        vaultBalances.savingsShareValue = 1_334_897.25726e6 + 2;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 19. User fully redeems

        _processPendingRedeems();  // Redeem Request 1 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.407100422656249999634811897e27;

        vaultState.totalAssets            = 0;
        vaultState.availableCapacityValue = 140_710_042.265624e6;
        vaultState.availableLiquidAssets  = 1;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.firstPendingId    = 2;

        userBalances.assets = 2_606_227.97846e6;  // 1_271_330.7212e6 + 1_334_897.25726e6

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 1;  // Rounding

        assertEq(spPrime.totalSupply(),         0);
        assertEq(spPrime.balanceOf(user),       0);
        assertEq(spPrime.pendingRedeemShares(), 0);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

}
