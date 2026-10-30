// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase } from "./TestBase.t.sol";

contract E2ETests is TestBase {

    address internal user = makeAddr("user");

    function setUp() public override {
        super.setUp();

        vm.label(user, "user");

        _setVSR(DAILY_2BP_VSR);
        _setSavingsVSR(DAILY_1BP_VSR);
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

        _processPendingDeposits(type(uint256).max);

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

        vm.prank(taker);
        spPrime.take(takenSavingsShares);

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

}
