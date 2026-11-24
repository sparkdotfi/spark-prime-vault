// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "../lib/oz/contracts/token/ERC20/IERC20.sol";

import { TestBase } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

interface IERC4626Like {

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

}

contract ClaimTests is TestBase {

    address internal user      = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    function setUp() public override virtual {
        super.setUp();

        vm.label(user,      "user");
        vm.label(recipient, "recipient");
    }

    function test_claim_zeroRecipient() external {
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vm.prank(user);
        spPrime.claim(address(0));
    }

    function test_claim_vaultIsRecipient() external {
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vm.prank(user);
        spPrime.claim(address(spPrime));
    }

    function test_claim_nothingToClaim() external {
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vm.prank(user);
        spPrime.claim(user);
    }

    function test_claim_onlyOwnerCanClaim() external {
        _requestDeposit(user, recipient, 1_000_000e6);

        vm.prank(operator);
        spPrime.rejectDepositRequest(0);

        // Recipient has no claimable assets; only the request owner can claim.
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vm.prank(recipient);
        spPrime.claim(recipient);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Claim(user, recipient, 1_000_000e6 - 1);

        vm.prank(user);
        uint256 claimed = spPrime.claim(recipient);

        assertEq(claimed, 1_000_000e6 - 1);
        assertEq(usdc.balanceOf(recipient), 1_000_000e6 - 1);
    }

    function test_claim_transferAmountExceedsBalanceBoundary() external {
        _requestDeposit(user, 1_000_000e6);
        _requestDepositCancellation(user, 0, spUSDC.convertToShares(1_000_000e6));

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

        _processPendingDepositCancellations(1);

        // spPrime has 1 less than claimable amount
        deal(address(usdc), address(spPrime), 1_000_000e6 - 2);

        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(user);
        spPrime.claim(user);

        // spPrime has the full claimable amount
        deal(address(usdc), address(spPrime), 1_000_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Claim(user, user, 1_000_000e6 - 1);

        vm.prank(user);
        spPrime.claim(user);
    }

    function test_claim_transferFails() external {
        _requestDeposit(user, 1_000_000e6);
        _requestDepositCancellation(user, 0, spUSDC.convertToShares(1_000_000e6));

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

        _processPendingDepositCancellations(1);

        // Original recipient is still unable to receive the asset (e.g. blacklisted)
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, user, 1_000_000e6 - 1),
            ""
        );

        vm.expectRevert(bytes(""));
        vm.prank(user);
        spPrime.claim(user);

        // Owner can still claim to a different recipient
        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Claim(user, recipient, 1_000_000e6 - 1);

        vm.prank(user);
        spPrime.claim(recipient);

        assertEq(usdc.balanceOf(recipient), 1_000_000e6 - 1);
    }

    function test_claim_fromDepositCancellation() external {
        _requestDeposit(user, 1_000_000e6);
        _requestDepositCancellation(user, 0, recipient, spUSDC.convertToShares(1_000_000e6));

        vaultState.availableLiquidAssets += 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 1;
        vaultState.depositRequests.processedCount    = 0;

        vaultState.depositCancellationRequests.pendingShareValue = 1_000_000e6 - 1;
        vaultState.depositCancellationRequests.length            = 1;
        vaultState.depositCancellationRequests.processedCount    = 0;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        AccountBalances memory recipientBalances = AccountBalances({
            account           : recipient,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssetsOf : 0
        });

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(recipientBalances);
        _assertAccountBalances(vaultBalances);

        // Redeeming directly to the recipient fails, so assets are kept in the vault as claimable
        // by the request owner.
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(
                IERC4626Like.redeem.selector,
                spUSDC.convertToShares(1_000_000e6),
                recipient,
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
        vaultState.depositCancellationRequests.processedCount    = 1;

        userBalances.claimableAssetsOf = 1_000_000e6 - 1;

        vaultBalances.assets            = 1_000_000e6 - 1;
        vaultBalances.savingsShareValue = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(recipientBalances);
        _assertAccountBalances(vaultBalances);

        // Owner claims their assets to recipient
        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Claim(user, recipient, 1_000_000e6 - 1);

        vm.prank(user);
        spPrime.claim(recipient);

        vaultState.totalClaimable = 0;

        userBalances.claimableAssetsOf = 0;

        recipientBalances.assets = 1_000_000e6 - 1;

        vaultBalances.assets = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(recipientBalances);
        _assertAccountBalances(vaultBalances);
    }

    function test_claim_fromRedeem() external {
        _requestDeposit(user, 1_000_000e6);
        _processPendingDeposits(1);
        _requestRedeem(user, recipient, spPrime.convertToShares(500_000e6));

        vaultState.availableCapacityValue -= 1_000_000e6 - 1;
        vaultState.availableLiquidAssets  += 1_000_000e6 - 1;
        vaultState.totalAssets            += 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.processedCount    = 1;

        vaultState.redeemRequests.pendingShareValue = 500_000e6;
        vaultState.redeemRequests.length            = 1;
        vaultState.redeemRequests.processedCount    = 0;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 500_000e6 - 1,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        AccountBalances memory recipientBalances = AccountBalances({
            account           : recipient,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 500_000e6,
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssetsOf : 0
        });

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(recipientBalances);
        _assertAccountBalances(vaultBalances);

        // Redeeming directly to the recipient fails, so assets are kept in the vault as claimable
        // by the request owner.
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(
                IERC4626Like.redeem.selector,
                spUSDC.convertToShares(500_000e6),
                recipient,
                address(spPrime)
            ),
            ""
        );

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(user, 500_000e6 - 1);

        _processPendingRedeems(1);

        vaultState.availableCapacityValue += 500_000e6;
        vaultState.availableLiquidAssets  -= 500_000e6;
        vaultState.totalAssets            -= 500_000e6;
        vaultState.totalClaimable         += 500_000e6 - 1;

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.processedCount    = 1;

        userBalances.claimableAssetsOf = 500_000e6 - 1;

        vaultBalances.assets            = 500_000e6 - 1;
        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 500_000e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(recipientBalances);
        _assertAccountBalances(vaultBalances);

        // Owner claims their assets to recipient
        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Claim(user, recipient, 500_000e6 - 1);

        vm.prank(user);
        spPrime.claim(recipient);

        vaultState.totalClaimable = 0;

        userBalances.claimableAssetsOf = 0;

        recipientBalances.assets = 500_000e6 - 1;

        vaultBalances.assets = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(recipientBalances);
        _assertAccountBalances(vaultBalances);
    }

}
