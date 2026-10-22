// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

interface IERC4626Like {

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

}

contract ClaimTests is TestBase {

    address internal user = makeAddr("user");

    function setUp() public override virtual {
        super.setUp();

        vm.label(user, "user");
    }

    function test_claim_nothingToClaim() external {
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        spPrime.claim(user);
    }

    function test_claim_fromDepositCancellation() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);
        _requestDepositCancellation(user, 0, spUSDC.convertToShares(1_000_000e6));

        vaultState.availableCapacityValue  = 0;
        vaultState.availableLiquidAssets  += 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 1;

        vaultState.depositCancellationRequests.pendingShareValue = 1_000_000e6 - 1;
        vaultState.depositCancellationRequests.length            = 1;
        vaultState.depositCancellationRequests.firstPendingId    = 0;

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
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssets   : 0
        });

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // Redeeming directly to the recipient fails, so assets are kept in the vault as claimable
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(
                IERC4626Like.redeem.selector,
                spUSDC.convertToShares(1_000_000e6),
                user,
                address(spPrime)
            ),
            ""
        );

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(user, 1_000_000e6 - 1);

        _processPendingDepositCancellations(1);

        vaultState.totalClaimable        += 1_000_000e6 - 1;
        vaultState.availableLiquidAssets -= 1_000_000e6 - 1;

        vaultState.depositCancellationRequests.pendingShareValue = 0;
        vaultState.depositCancellationRequests.length            = 0;
        vaultState.depositCancellationRequests.firstPendingId    = 1;

        userBalances.claimableAssets = 1_000_000e6 - 1;

        vaultBalances.assets            = 1_000_000e6 - 1;
        vaultBalances.savingsShareValue = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // User claims their assets

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Claim(user, 1_000_000e6 - 1);

        spPrime.claim(user);

        vaultState.totalClaimable = 0;

        userBalances.assets          = 1_000_000e6 - 1;
        userBalances.claimableAssets = 0;

        vaultBalances.assets = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

    function test_claim_fromRedeem() external {
        _requestDeposit(user, 1_000_000e6);
        _requestRedeem(user,  spPrime.convertToShares(500_000e6));

        vaultState.availableCapacityValue -= 1_000_000e6 - 1;
        vaultState.availableLiquidAssets  += 1_000_000e6 - 1;
        vaultState.totalAssets            += 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 1;

        vaultState.redeemRequests.pendingShareValue = 500_000e6;
        vaultState.redeemRequests.length            = 1;
        vaultState.redeemRequests.firstPendingId    = 0;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 500_000e6 - 1,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 500_000e6,
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssets   : 0
        });

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // Withdrawing directly to the recipient fails, so assets are kept in the vault as claimable
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(
                IERC4626Like.withdraw.selector,
                500_000e6,
                user,
                address(spPrime)
            ),
            ""
        );

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(user, 500_000e6);

        _processPendingRedeems(1);

        vaultState.availableCapacityValue += 500_000e6;
        vaultState.availableLiquidAssets  -= 500_000e6 + 1;
        vaultState.totalAssets            -= 500_000e6;
        vaultState.totalClaimable         += 500_000e6;

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.firstPendingId    = 1;

        userBalances.claimableAssets = 500_000e6;

        vaultBalances.assets            = 500_000e6;
        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 500_000e6 - 2;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        // User claims their assets

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Claim(user, 500_000e6);

        spPrime.claim(user);

        vaultState.totalClaimable = 0;

        userBalances.assets          = 500_000e6;
        userBalances.claimableAssets = 0;

        vaultBalances.assets = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

}
