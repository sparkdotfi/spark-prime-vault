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

        _setVSR(DAILY_2BP_VSR);
        _setSavingsVSR(DAILY_1BP_VSR);

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

        // 2. Warp 1 day, queued spUSDC earns 1bp while waiting, no drip so rho and chi are unchanged

        skip(1 days);

        vaultState.availableLiquidAssets = 1_000_100e6 - 1;

        vaultState.depositRequests.pendingShareValue = 1_000_100e6 - 1;

        vaultBalances.savingsShareValue = 1_000_100e6 - 1;

        _assertDepositRequest(0, user, user, 1_000_100e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 3. User gets filled once capacity is raised, at the current spUSDC value and chi of 1.0002

        _setCapacity(VAULT_CAPACITY);

        _processPendingDeposits();

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000199999999999999999965892e27;

        vaultState.totalAssets            = 1_000_100e6 - 2;
        vaultState.availableCapacityValue = 99_019_900e6 + 1;  // (100m - 999_900.019995) * 1.0002

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 1;

        userBalances.shareValue = 1_000_100e6 - 2;

        assertEq(spPrime.balanceOf(user), 999_900.019995e6);  // (1_000_100e6 - 1) / 1.0002

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 4. Warp 1 day, spPrime grows 2bp while spUSDC grows 1bp

        skip(1 days);

        vaultState.totalAssets            = 1_000_300.02e6 - 2;
        vaultState.availableCapacityValue = 99_039_703.98e6 + 1;
        vaultState.availableLiquidAssets  = 1_000_200.01e6 - 1;

        userBalances.shareValue = 1_000_300.02e6 - 2;

        vaultBalances.savingsShareValue = 1_000_200.01e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 5. Take, taker deploys half of the vault's spUSDC

        uint256 takenSavingsShares = spUSDC.balanceOf(address(spPrime)) / 2;

        _take(takenSavingsShares);

        vaultState.availableLiquidAssets = 500_100.005e6 - 1;

        vaultBalances.savingsShareValue = 500_100.005e6 - 1;

        takerBalances.savingsShareValue = 500_100.005e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 6. Warp 1 day

        skip(1 days);

        vaultState.totalAssets            = 1_000_500.08e6 + 2;
        vaultState.availableCapacityValue = 99_059_511.9208e6 - 3;
        vaultState.availableLiquidAssets  = 500_150.015e6;

        userBalances.shareValue = 1_000_500.08e6 + 2;

        vaultBalances.savingsShareValue = 500_150.015e6;

        takerBalances.savingsShareValue = 500_150.015e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 7. User requests redeem of 250k shares, worth 250,150.03 USD at chi of 1.0002^3

        _requestRedeem(user, 250_000e6);  // Redeem Request 0

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000600120007999999999897636e27;

        vaultState.redeemRequests.pendingShareValue = 250_150.03e6 + 1;
        vaultState.redeemRequests.length            = 1;

        userBalances.shareValue = 750_350.05e6;

        vaultBalances.shareValue = 250_150.03e6 + 1;

        _assertRedeemRequest(0, user, user, 250_150.03e6 + 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 8. Warp 1 day, the queued redeem keeps earning at the vault rate

        skip(1 days);

        vaultState.totalAssets            = 1_000_700.180018e6;
        vaultState.availableCapacityValue = 99_079_323.823181e6;
        vaultState.availableLiquidAssets  = 500_200.03e6 + 1;

        vaultState.redeemRequests.pendingShareValue = 250_200.060008e6;

        userBalances.shareValue = 750_500.12001e6;

        vaultBalances.shareValue        = 250_200.060008e6;
        vaultBalances.savingsShareValue = 500_200.03e6 + 1;

        takerBalances.savingsShareValue = 500_200.03e6 + 1;

        _assertRedeemRequest(0, user, user, 250_200.060008e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 9. User redeems, the request is filled from the spUSDC still held by the vault

        _processPendingRedeems();

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000800240032001599999863487e27;

        vaultState.totalAssets            = 750_500.12001e6;
        vaultState.availableCapacityValue = 99_329_523.883189e6;
        vaultState.availableLiquidAssets  = 249_999.969993e6;

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.firstPendingId    = 1;

        userBalances.assets = 250_200.060008e6;

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 249_999.969993e6;

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

        // 2. Warp 1 day, queued spUSDC earns 1bp while waiting, spPrime has no supply yet

        skip(1 days);

        vaultState.availableLiquidAssets = 1_000_100e6 - 1;

        vaultState.depositRequests.pendingShareValue = 1_000_100e6 - 1;

        vaultBalances.savingsShareValue = 1_000_100e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 3. Taker takes all of the vault's spUSDC, which backs deposit 0

        _take(spUSDC.balanceOf(address(spPrime)));  // Deposit Request 0 savings shares

        vaultState.availableLiquidAssets = 0;

        vaultBalances.savingsShareValue = 0;

        takerBalances.savingsShareValue = 1_000_100e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 4. User requests deposit 1, which drips chi to 1.0002

        _requestDeposit(user, 1_000_000e6);  // Deposit Request 1 (Queued)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000199999999999999999965892e27;

        vaultState.availableLiquidAssets = 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 2_000_100e6 - 2;
        vaultState.depositRequests.length            = 2;

        vaultBalances.savingsShareValue = 1_000_000e6 - 1;

        _assertDepositRequest(0, user, user, 1_000_100e6 - 1);
        _assertDepositRequest(1, user, user, 1_000_000e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 5. Warp 1 day, queued deposits keep their spUSDC value growth even though deposit 0 shares were taken

        skip(1 days);

        vaultState.availableLiquidAssets = 1_000_100e6 - 1;

        vaultState.depositRequests.pendingShareValue = 2_000_300.01e6 - 2;

        vaultBalances.savingsShareValue = 1_000_100e6 - 1;

        takerBalances.savingsShareValue = 1_000_200.01e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 6. User gets filled for deposit 0 once capacity is raised, at chi of 1.0002^2

        _setCapacity(VAULT_CAPACITY);

        _processPendingDeposits(1);  // Deposit Request 0 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000400039999999999999931770e27;

        vaultState.totalAssets            = 1_000_200.01e6 - 2;
        vaultState.availableCapacityValue = 99_039_803.99e6 + 1;

        vaultState.depositRequests.pendingShareValue = 1_000_100e6 - 1;
        vaultState.depositRequests.length            = 1;
        vaultState.depositRequests.firstPendingId    = 1;

        userBalances.shareValue = 1_000_200.01e6 - 2;

        _assertDepositRequest(1, user, user, 1_000_100e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 7. Warp 1 day, spPrime grows 2bp while spUSDC grows 1bp

        skip(1 days);

        vaultState.totalAssets            = 1_000_400.05e6;
        vaultState.availableCapacityValue = 99_059_611.9508e6 - 1;
        vaultState.availableLiquidAssets  = 1_000_200.01e6 - 1;

        vaultState.depositRequests.pendingShareValue = 1_000_200.01e6 - 1;

        userBalances.shareValue = 1_000_400.05e6;

        vaultBalances.savingsShareValue = 1_000_200.01e6 - 1;

        takerBalances.savingsShareValue = 1_000_300.03e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 8. Taker takes all of the vault's spUSDC, which backs deposit 1

        _take(spUSDC.balanceOf(address(spPrime)));  // Deposit Request 1 savings shares

        vaultState.availableLiquidAssets = 0;

        vaultBalances.savingsShareValue = 0;

        takerBalances.savingsShareValue = 2_000_500.04e6 - 1;  // 1_000_300.03e6 + 1_000_200.01e6 - 1

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 9. Warp 1 day

        skip(1 days);

        vaultState.totalAssets            = 1_000_600.13001e6;
        vaultState.availableCapacityValue = 99_079_423.873189e6;

        vaultState.depositRequests.pendingShareValue = 1_000_300.03e6;

        userBalances.shareValue = 1_000_600.13001e6;

        takerBalances.savingsShareValue = 2_000_700.09e6 + 3;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 10. User gets filled for deposit 1 at chi of 1.0002^4

        _processPendingDeposits(1);  // Deposit Request 1 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000800240032001599999863487e27;

        vaultState.totalAssets            = 2_000_900.16001e6;
        vaultState.availableCapacityValue = 98_079_123.843189e6;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 2;

        userBalances.shareValue = 2_000_900.16001e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 11. Warp 1 day

        skip(1 days);

        vaultState.totalAssets            = 2_001_300.340042e6;
        vaultState.availableCapacityValue = 98_098_739.667957e6;

        userBalances.shareValue = 2_001_300.340042e6;

        takerBalances.savingsShareValue = 2_000_900.160012e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 12. User requests redeem of half of the shares, worth 1,000,650.17 USD at chi of 1.0002^5

        _requestRedeem(user, spPrime.balanceOf(user) / 2);  // Redeem Request 0

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.001000400080008000319829324e27;

        vaultState.redeemRequests.pendingShareValue = 1_000_650.17002e6;
        vaultState.redeemRequests.length            = 1;

        userBalances.shareValue = 1_000_650.170021e6;

        vaultBalances.shareValue = 1_000_650.17002e6;

        _assertRedeemRequest(0, user, user, 1_000_650.17002e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 13. Warp 1 day, the queued redeem keeps earning at the vault rate

        skip(1 days);

        vaultState.totalAssets            = 2_001_700.60011e6;
        vaultState.availableCapacityValue = 98_118_359.415891e6;

        vaultState.redeemRequests.pendingShareValue = 1_000_850.300054e6;

        userBalances.shareValue = 1_000_850.300055e6;

        vaultBalances.shareValue = 1_000_850.300054e6;

        takerBalances.savingsShareValue = 2_001_100.250028e6;

        _assertRedeemRequest(0, user, user, 1_000_850.300054e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 14. Taker returns enough spUSDC to cover redeem request 0

        // Redeem Request 0 is owed 1_000_850.300054e6 + 2 Rounding
        uint256 returnedSavingsShares = spUSDC.convertToShares(1_000_850.300054e6 + 2);

        vm.prank(taker);
        spUSDC.transfer(address(spPrime), returnedSavingsShares);

        vaultState.availableLiquidAssets = 1_000_850.300055e6;

        vaultBalances.savingsShareValue = 1_000_850.300055e6;

        takerBalances.savingsShareValue = 1_000_249.949972e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 15. User gets filled for redeem request 0

        _processPendingRedeems();  // Redeem Request 0 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.001200600160024001919859147e27;

        vaultState.totalAssets            = 1_000_850.300055e6;
        vaultState.availableCapacityValue = 99_119_209.715946e6;
        vaultState.availableLiquidAssets  = 1;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.firstPendingId    = 1;

        userBalances.assets = 1_000_850.300054e6;

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 1;  // Rounding

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 16. User requests redeem of all remaining shares

        _requestRedeem(user, spPrime.balanceOf(user));  // Redeem Request 1

        vaultState.redeemRequests.pendingShareValue = 1_000_850.300055e6;
        vaultState.redeemRequests.length            = 1;

        userBalances.shareValue = 0;

        vaultBalances.shareValue = 1_000_850.300055e6;

        _assertRedeemRequest(1, user, user, 1_000_850.300055e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 17. Warp 1 day, the queued redeem keeps earning at the vault rate

        skip(1 days);

        vaultState.totalAssets            = 1_001_050.470116e6;
        vaultState.availableCapacityValue = 99_139_033.557889e6;
        vaultState.availableLiquidAssets  = 1;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 1_001_050.470116e6;

        vaultBalances.shareValue        = 1_001_050.470116e6;
        vaultBalances.savingsShareValue = 1;  // Rounding

        takerBalances.savingsShareValue = 1_000_349.974967e6;

        _assertRedeemRequest(1, user, user, 1_001_050.470116e6);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 18. Taker returns enough spUSDC to cover redeem request 1, the taker's spUSDC grew 1bp a day while
        //     the redeem is owed 2bp a day, so the taker tops up the difference before returning it

        // Redeem Request 1 is owed 1_001_050.470116e6 + 3 Rounding
        deal(address(spUSDC), taker, spUSDC.convertToShares(1_001_050.470116e6 + 3));

        returnedSavingsShares = spUSDC.balanceOf(taker);

        vm.prank(taker);
        spUSDC.transfer(address(spPrime), returnedSavingsShares);

        vaultState.availableLiquidAssets = 1_001_050.470119e6;  // Includes 1 rounding left from redeem request 0

        vaultBalances.savingsShareValue = 1_001_050.470119e6;

        takerBalances.savingsShareValue = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 19. User gets filled for redeem request 1, the vault has no supply left

        _processPendingRedeems();  // Redeem Request 1 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.001400840280056006720208969e27;

        vaultState.totalAssets            = 0;
        vaultState.availableCapacityValue = 100_140_084.028005e6;
        vaultState.availableLiquidAssets  = 3;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.firstPendingId    = 2;

        userBalances.assets = 2_001_900.77017e6;  // 1_000_850.300054e6 + 1_001_050.470116e6

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 3;  // Rounding

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

        assertEq(spPrime.balanceOf(ali), 1_000_000e6 - 1);  // (1_000_000e6 - 1) / 1.0

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 2. Warp 1 day, spPrime grows 2bp while spUSDC grows 1bp

        skip(1 days);

        vaultState.totalAssets           = 1_000_200e6 - 2;
        vaultState.availableLiquidAssets = 1_000_100e6 - 1;

        aliBalances.shareValue = 1_000_200e6 - 2;

        vaultBalances.savingsShareValue = 1_000_100e6 - 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 3. Bob requests deposit 1, queued because the vault is at capacity

        _requestDeposit(bob, 1_000_000e6);  // Deposit Request 1 (Queued)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000199999999999999999965892e27;

        vaultState.availableLiquidAssets = 2_000_100e6 - 2;

        vaultState.depositRequests.pendingShareValue = 1_000_000e6 - 1;
        vaultState.depositRequests.length            = 1;

        vaultBalances.savingsShareValue = 2_000_100e6 - 2;

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

        takerBalances.savingsShareValue = 2_000_100e6 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 5. Warp 1 day, spPrime grows 2bp while Bob's queued deposit grows at the 1bp spUSDC rate

        skip(1 days);

        vaultState.totalAssets = 1_000_400.04e6 - 2;

        vaultState.depositRequests.pendingShareValue = 1_000_100e6 - 1;

        aliBalances.shareValue = 1_000_400.04e6 - 2;

        takerBalances.savingsShareValue = 2_000_300.01e6 - 2;

        _assertDepositRequest(1, bob, bob, 1_000_100e6 - 1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 6. Ali requests redeem of half of the shares, queued because there is no liquidity

        _requestRedeem(ali, spPrime.balanceOf(ali) / 2);  // Redeem Request 0

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000400039999999999999931770e27;

        vaultState.redeemRequests.pendingShareValue = 500_200.02e6 - 2;
        vaultState.redeemRequests.length            = 1;

        aliBalances.shareValue = 500_200.02e6 - 1;

        vaultBalances.shareValue = 500_200.02e6 - 2;

        _assertRedeemRequest(0, ali, ali, 500_200.02e6 - 2);

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
        spPrime.adjustTotalAssets(-(100_040.004e6 - 1));  // 10% of 1_000_400.04e6 - 2 totalAssets

        vaultState.chi = 0.900360035999900360035999900e27;

        vaultState.totalAssets            = 900_360.036e6 - 2;
        vaultState.availableCapacityValue = 0;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 450_180.018e6 - 1;

        aliBalances.shareValue = 450_180.018e6 - 1;

        vaultBalances.shareValue = 450_180.018e6 - 1;

        _assertRedeemRequest(0, ali, ali, 450_180.018e6 - 1);

        // Bob's pending deposit is held in spUSDC, so its value is unchanged by the loss
        _assertDepositRequest(1, bob, bob, 1_000_100e6 - 1);

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

        vaultState.availableCapacityValue = 89_135_643.563991e6;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 11. Bob gets filled for deposit 1 at the post-loss chi, so Bob gets more shares than Ali did for
        //     the same 1m deposit because each share is cheaper, Ali's value is unchanged by Bob's mint

        _processPendingDeposits(1);  // Deposit Request 1 (Filled)

        vaultState.totalAssets            = 1_900_460.036e6 - 3;
        vaultState.availableCapacityValue = 88_135_543.563992e6;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 2;

        bobBalances.shareValue = 1_000_100e6 - 2;

        assertEq(spPrime.balanceOf(bob), 1_110_777.866643e6);  // (1_000_100e6 - 1) / 0.90036

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 12. Warp 1 day, the queued redeem keeps earning at the vault rate

        skip(1 days);

        vaultState.totalAssets            = 1_900_840.128004e6;
        vaultState.availableCapacityValue = 88_153_170.672705e6;

        vaultState.redeemRequests.pendingShareValue = 450_270.054e6 + 2;

        aliBalances.shareValue = 450_270.054e6 + 3;
        bobBalances.shareValue = 1_000_300.02e6 - 2;

        vaultBalances.shareValue = 450_270.054e6 + 2;

        takerBalances.savingsShareValue = 2_000_500.04e6 - 1;

        _assertRedeemRequest(0, ali, ali, 450_270.054e6 + 2);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 13. Taker returns enough spUSDC to cover redeem request 0

        // Redeem Request 0 is owed 450_270.054e6 + 2 + 3 Rounding
        uint256 returnedSavingsShares = spUSDC.convertToShares(450_270.054e6 + 5);

        vm.prank(taker);
        spUSDC.transfer(address(spPrime), returnedSavingsShares);

        vaultState.availableLiquidAssets = 450_270.054e6 + 3;

        vaultBalances.savingsShareValue = 450_270.054e6 + 3;

        takerBalances.savingsShareValue = 1_550_229.985995e6;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 14. Ali gets filled for redeem request 0 at the post-loss value

        _processPendingRedeems();  // Redeem Request 0 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 0.900540108007100340107976390e27;

        vaultState.totalAssets            = 1_450_570.074e6 + 2;
        vaultState.availableCapacityValue = 88_603_440.726707e6;
        vaultState.availableLiquidAssets  = 1;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.firstPendingId    = 1;

        aliBalances.assets = 450_270.054e6 + 2;

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

        vaultState.redeemRequests.pendingShareValue = 1_450_570.074e6 + 2;
        vaultState.redeemRequests.length            = 2;

        aliBalances.shareValue = 0;
        bobBalances.shareValue = 0;

        vaultBalances.shareValue = 1_450_570.074e6 + 2;

        _assertRedeemRequest(1, ali, ali, 450_270.054e6 + 3);
        _assertRedeemRequest(2, bob, bob, 1_000_300.02e6 - 2);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 16. Warp 1 day, the queued redeems keep earning at the vault rate

        skip(1 days);

        vaultState.totalAssets            = 1_450_860.188016e6;
        vaultState.availableCapacityValue = 88_621_161.414853e6;
        vaultState.availableLiquidAssets  = 1;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 1_450_860.188016e6;

        vaultBalances.shareValue        = 1_450_860.188016e6;
        vaultBalances.savingsShareValue = 1;  // Rounding

        takerBalances.savingsShareValue = 1_550_385.008994e6;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 17. Taker returns enough spUSDC to cover redeem requests 1 and 2

        // Redeem Requests 1 and 2 are owed 1_450_860.188016e6 + 2 Rounding
        returnedSavingsShares = spUSDC.convertToShares(1_450_860.188016e6 + 2);

        vm.prank(taker);
        spUSDC.transfer(address(spPrime), returnedSavingsShares);

        vaultState.availableLiquidAssets = 1_450_860.188018e6;

        vaultBalances.savingsShareValue = 1_450_860.188018e6;

        takerBalances.savingsShareValue = 99_524.820976e6;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 18. Ali and Bob get filled for redeem requests 1 and 2, the vault has no supply left.
        //     Ali deposited a day before Bob but gets back less, because Ali held shares through
        //     the loss while Bob's queued deposit was still in spUSDC

        _processPendingRedeems();  // Redeem Requests 1 and 2 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 0.900720216028701760175967269e27;

        vaultState.totalAssets            = 0;
        vaultState.availableCapacityValue = 90_072_021.60287e6;
        vaultState.availableLiquidAssets  = 2;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.firstPendingId    = 3;

        aliBalances.assets = 900_630.162016e6;  // 450_270.054e6 + 2 + 450_360.108014e6
        bobBalances.assets = 1_000_500.08e6 + 2;

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 2;  // Rounding

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
