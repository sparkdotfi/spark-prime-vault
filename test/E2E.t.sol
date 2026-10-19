// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

interface ISavingsDepositLike {

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

}

contract E2ETests is TestBase {

    address internal user = makeAddr("user");

    function setUp() public override {
        super.setUp();

        vm.label(user, "user");
    }

    function test_e2e_basic() external {
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

        // 1. First deposit request is queued.

        _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Queued)

        vaultState.availableLiquidAssets = 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 1_000_000e6 - 1;
        vaultState.depositRequests.length            = 1;

        vaultBalances.savingsShareValue = 1_000_000e6 - 1;

        _assertDepositRequest(0, user, user, 1_000_000e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 2. Second deposit request is queued behind the first.

        _requestDeposit(user, 1_000_000e6);  // Deposit Request 1 (Queued)

        vaultState.availableLiquidAssets = 2_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 2_000_000e6 - 1;
        vaultState.depositRequests.length            = 2;

        vaultBalances.savingsShareValue = 2_000_000e6 - 1;

        _assertDepositRequest(0, user, user, 1_000_000e6 - 1);
        _assertDepositRequest(1, user, user, 1_000_000e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 3. User cancels the second deposit request in full.

        ( , , uint256 request1Shares ) = spPrime.getPendingDepositRequest(1);

        vm.prank(user);
        spPrime.requestDepositCancellation(1, user, request1Shares);  // Deposit Cancellation Request 0

        vaultState.depositRequests.pendingShareValue = 1_000_000e6 - 1;  // Cancelled entry still counts towards length

        vaultState.depositCancellationRequests.pendingShareValue = 1_000_000e6 - 1;
        vaultState.depositCancellationRequests.length            = 1;

        _assertDepositRequest(0, user, user, 1_000_000e6 - 1);

        _assertDepositCancellationRequest(0, user, user, 1_000_000e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 4. Cancellation is processed and the user gets the USDC back.

        _processPendingDepositCancellations(type(uint256).max);

        vaultState.availableLiquidAssets = 1_000_000e6 - 1;

        vaultState.depositCancellationRequests.pendingShareValue = 0;
        vaultState.depositCancellationRequests.length            = 0;
        vaultState.depositCancellationRequests.firstPendingId    = 1;

        userBalances.assets = 1_000_000e6 - 1;

        vaultBalances.savingsShareValue = 1_000_000e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 5. Admin raises capacity and the first deposit request is filled.

        _setCapacity(VAULT_CAPACITY);

        _processPendingDeposits(type(uint256).max);

        vaultState.totalAssets            = 1_000_000e6 - 1;
        vaultState.availableCapacityValue = 99_000_000e6 + 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 2;

        userBalances.shareValue = 1_000_000e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 6. Taker deploys all savings shares held by the vault.

        uint256 takenSavingsShares = spUSDC.balanceOf(address(spPrime));

        vm.prank(taker);
        spPrime.take(takenSavingsShares);

        vaultState.availableLiquidAssets = 0;

        vaultBalances.savingsShareValue = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 7. One year of yield at 5% VSR, no drip yet so rho and chi are unchanged.

        skip(365 days);

        vaultState.totalAssets            = 1_050_000e6 - 2;
        vaultState.availableCapacityValue = 103_950_000e6 + 1;

        userBalances.shareValue = 1_050_000e6 - 2;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 8. Redeem request stays queued while there is no liquidity

        _requestRedeem(user, spPrime.balanceOf(user));  // Redeem Request 0

        _processPendingRedeems();  // No liquidity, nothing is filled

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.049999999999999999961070145e27;

        vaultState.redeemRequests.pendingShareValue = 1_050_000e6 - 2;
        vaultState.redeemRequests.length            = 1;

        userBalances.shareValue = 0;

        vaultBalances.shareValue = 1_050_000e6 - 2;

        _assertRedeemRequest(0, user, user, 1_050_000e6 - 2);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 9. Taker returns the deployed savings shares plus enough to cover the yield owed
        //    (spUSDC earned less than 5% over the year, so the returned shares alone fall short)

        vm.prank(taker);
        spUSDC.transfer(address(spPrime), takenSavingsShares);

        uint256 shortfall = spPrime.totalAssets() - spPrime.availableLiquidAssets() + 1;

        assertEq(shortfall, 12_000e6);

        deal(address(usdc), taker, shortfall);

        vm.startPrank(taker);
        usdc.approve(address(spUSDC), shortfall);
        ISavingsDepositLike(address(spUSDC)).deposit(shortfall, address(spPrime));
        vm.stopPrank();

        vaultState.availableLiquidAssets = 1_050_000e6 - 1;

        vaultBalances.savingsShareValue = 1_050_000e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // 10. Redeem is filled and the user receives principal plus yield on top of the refund

        _processPendingRedeems();

        vaultState.totalAssets            = 0;
        vaultState.availableCapacityValue = 105_000_000e6 - 1;
        vaultState.availableLiquidAssets  = 1;  // Rounding

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.firstPendingId    = 1;

        userBalances.assets = 2_050_000e6 - 3;  // 1m - 1 refund + 1.05m - 2 redeem

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

}
