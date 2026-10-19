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

}
