// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "../lib/oz/contracts/token/ERC20/IERC20.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

import { TestBase, ISparkVaultLike } from "./TestBase.t.sol";

abstract contract SparkPrimeVaultTests is TestBase {

    uint16 internal constant REFERRAL = type(uint16).max;

    address internal user = makeAddr("user");

    function setUp() public override virtual {
        super.setUp();

        vm.label(user, "user");

        skip(365 days);

        vaultState.availableCapacityValue = spPrime.convertToAssets(VAULT_CAPACITY);
    }

}

contract RequestDepositTests is SparkPrimeVaultTests {

    // Failure tests

    function test_requestDeposit_isPaused() external {
        _pause();

        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(user);
        spPrime.requestDeposit(100e6, user, 0);
    }

    function test_requestDeposit_zeroRecipient() external {
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vm.prank(user);
        spPrime.requestDeposit(100e6, address(0), 0);
    }

    function test_requestDeposit_vaultIsRecipient() external {
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vm.prank(user);
        spPrime.requestDeposit(100e6, address(spPrime), 0);
    }

    function test_requestDeposit_belowMinDepositBoundary() external {
        deal(address(usdc), user, MINIMUM_DEPOSIT);

        vm.prank(user);
        usdc.approve(address(spPrime), MINIMUM_DEPOSIT);

        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vm.prank(user);
        spPrime.requestDeposit(MINIMUM_DEPOSIT - 1, user, 0);

        vm.prank(user);
        spPrime.requestDeposit(MINIMUM_DEPOSIT, user, 0);
    }

    function test_requestDeposit_insufficientAllowanceBoundary() external {
        deal(address(usdc), user, 1_000_000e6 + 1);

        vm.prank(user);
        usdc.approve(address(spPrime), 1_000_000e6);

        vm.prank(user);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        spPrime.requestDeposit(1_000_000e6 + 1, user, 0);

        vm.prank(user);
        spPrime.requestDeposit(1_000_000e6, user, 0);
    }

    function test_requestDeposit_insufficientBalanceBoundary() external {
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
        emit ISparkPrimeVault.Referral(REFERRAL, 1, user, user, 800_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositRequest(1, user, user, 800_000e6, expectedSavingsSharesMinted);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(1, user, user, expectedSavingsSharesConsumed, expectedConvertedAssets, expectedSharesMinted);

        vm.prank(user);
        uint256 requestId = spPrime.requestDeposit(800_000e6, user, REFERRAL);

        assertEq(requestId, 1);

        _assertDepositRequest(1, user, user, 300_000e6);

        vaultState.totalAssets            += 500_000e6 - 1;
        vaultState.availableCapacityValue  = 2;
        vaultState.availableLiquidAssets  += 800_000e6;

        vaultState.depositRequests.pendingShareValue += 300_000e6;
        vaultState.depositRequests.length             = 1;
        vaultState.depositRequests.firstPendingId     = 1;

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
        emit ISparkPrimeVault.Referral(REFERRAL, 1, user, user, 800_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositRequest(1, user, user, 800_000e6, expectedSavingsSharesMinted);

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

contract BoundedAutoProcessingTests is SparkPrimeVaultTests {

    // A run of fully cancelled deposit requests (tombstones) behind a live head. Anyone can grow
    // it by repeatedly depositing and fully cancelling while the head is unfilled, since the
    // cleanup in `requestDepositCancellation` stops at the first live entry. Once the head is
    // filled the run sits at the front of the queue, and every automatic walk over it is bounded
    // by `maxAutoProcessRequests` (50 in tests).

    uint256 internal constant RUN_LENGTH = 120;

    address internal attacker = makeAddr("attacker");
    address internal head     = makeAddr("head");

    uint256 internal headShares;
    uint256 internal runShares;  // Savings shares of all cancelled entries of the run

    function setUp() public override {
        super.setUp();

        vm.label(attacker, "attacker");
        vm.label(head,     "head");

        _setCapacity(0);

        _requestDeposit(head, 1_000_000e6);  // Deposit Request 0 (Queued, live head)

        ( , , headShares ) = spPrime.getPendingDepositRequest(0);

        for (uint256 i = 1; i <= RUN_LENGTH; ++i) {
            uint256 requestId = _requestDeposit(attacker, 200e6);  // Deposit Request i (Queued)

            assertEq(requestId, i);

            ( , , uint256 shares ) = spPrime.getPendingDepositRequest(requestId);

            _requestDepositCancellation(attacker, requestId, shares);  // Fully cancelled (tombstone)

            runShares += shares;
        }

        assertEq(spPrime.firstPendingDepositId(),                 0);
        assertEq(spPrime.getPendingDepositRequests().length,      RUN_LENGTH + 1);
        assertEq(spPrime.pendingDepositSavingsShares(),           headShares);
        assertEq(spPrime.pendingCancelledDepositSavingsShares(),  runShares);
        assertEq(spPrime.getPendingDepositCancellationRequests().length, RUN_LENGTH);
    }

    function _fillHead() internal {
        _setCapacity(VAULT_CAPACITY);

        _processPendingDeposits(type(uint256).max, 1);  // Fills the head only

        assertEq(spPrime.firstPendingDepositId(), 1);
        assertEq(spPrime.assetsOf(head),          1_000_000e6 - 2);
    }

    function test_requestDepositCancellation_boundedCleanup() external {
        uint256 victimRequestId = _requestDeposit(user, 1_000_000e6);  // Deposit Request 121 (Queued)

        assertEq(victimRequestId, RUN_LENGTH + 1);

        ( , , uint256 victimShares ) = spPrime.getPendingDepositRequest(victimRequestId);

        _fillHead();

        assertEq(spPrime.firstPendingDepositId(),            1);
        assertEq(spPrime.getPendingDepositRequests().length, RUN_LENGTH + 1);
        assertEq(spPrime.pendingDepositSavingsShares(),      victimShares);

        uint256 cancelShares = spUSDC.convertToShares(100_000e6);

        // The cancellation succeeds and its cleanup visits exactly `maxAutoProcessRequests`
        // entries of the run.

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellationRequest(victimRequestId, RUN_LENGTH, user, cancelShares);

        uint256 cancelRequestId = _requestDepositCancellation(user, victimRequestId, cancelShares);

        assertEq(cancelRequestId, RUN_LENGTH);

        assertEq(spPrime.firstPendingDepositId(),                        1 + MAX_AUTO_PROCESS_REQUESTS);
        assertEq(spPrime.getPendingDepositRequests().length,             RUN_LENGTH + 1 - MAX_AUTO_PROCESS_REQUESTS);
        assertEq(spPrime.pendingDepositSavingsShares(),                  victimShares - cancelShares);
        assertEq(spPrime.pendingCancelledDepositSavingsShares(),         runShares + cancelShares);
        assertEq(spPrime.getPendingDepositCancellationRequests().length, RUN_LENGTH + 1);

        _assertDepositRequest(victimRequestId, user, user, 900_000e6);

        // A second cancellation advances the head by the bound again.

        cancelRequestId = _requestDepositCancellation(user, victimRequestId, cancelShares);

        assertEq(cancelRequestId, RUN_LENGTH + 1);

        assertEq(spPrime.firstPendingDepositId(),                        1 + 2 * MAX_AUTO_PROCESS_REQUESTS);
        assertEq(spPrime.getPendingDepositRequests().length,             RUN_LENGTH + 1 - 2 * MAX_AUTO_PROCESS_REQUESTS);
        assertEq(spPrime.pendingDepositSavingsShares(),                  victimShares - 2 * cancelShares);
        assertEq(spPrime.pendingCancelledDepositSavingsShares(),         runShares + 2 * cancelShares);
        assertEq(spPrime.getPendingDepositCancellationRequests().length, RUN_LENGTH + 2);

        _assertDepositRequest(victimRequestId, user, user, 800_000e6);

        // A third one clears the remainder of the run and stops at the live victim entry.

        cancelRequestId = _requestDepositCancellation(user, victimRequestId, cancelShares);

        assertEq(cancelRequestId, RUN_LENGTH + 2);

        assertEq(spPrime.firstPendingDepositId(),                        RUN_LENGTH + 1);
        assertEq(spPrime.getPendingDepositRequests().length,             1);
        assertEq(spPrime.pendingDepositSavingsShares(),                  victimShares - 3 * cancelShares);
        assertEq(spPrime.pendingCancelledDepositSavingsShares(),         runShares + 3 * cancelShares);
        assertEq(spPrime.getPendingDepositCancellationRequests().length, RUN_LENGTH + 3);

        _assertDepositRequest(victimRequestId, user, user, 700_000e6 + 1);

        // No shares were minted by the cleanups.

        assertEq(spPrime.balanceOf(user), 0);
    }

    function test_requestDeposit_boundedInstantFill() external {
        _fillHead();

        assertEq(spPrime.getPendingDepositRequests().length, RUN_LENGTH);
        assertEq(spPrime.pendingDepositSavingsShares(),      0);

        // The run (120 entries) is longer than the bound (50): the deposit is queued, not filled,
        // and the walk advances the head by the bound.

        deal(address(usdc), user, 1_000_000e6);

        vm.prank(user);
        usdc.approve(address(spPrime), 1_000_000e6);

        uint256 expectedSavingsShares = spUSDC.convertToShares(1_000_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Referral(REFERRAL, RUN_LENGTH + 1, user, user, 1_000_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositRequest(RUN_LENGTH + 1, user, user, 1_000_000e6, expectedSavingsShares);

        vm.prank(user);
        uint256 requestId = spPrime.requestDeposit(1_000_000e6, user, REFERRAL);

        assertEq(requestId, RUN_LENGTH + 1);

        assertEq(spPrime.firstPendingDepositId(),            1 + MAX_AUTO_PROCESS_REQUESTS);
        assertEq(spPrime.getPendingDepositRequests().length, RUN_LENGTH + 1 - MAX_AUTO_PROCESS_REQUESTS);
        assertEq(spPrime.pendingDepositSavingsShares(),      expectedSavingsShares);
        assertEq(spPrime.balanceOf(user),                    0);
        assertEq(spPrime.totalSupply(),                      spPrime.balanceOf(head));

        _assertDepositRequest(requestId, user, user, 1_000_000e6 - 1);

        // Fully cancelling it leaves 21 tombstones in a row (70 of the run, minus the 50 cleared
        // by the cancellation, plus the cancelled request itself).

        _requestDepositCancellation(user, requestId, expectedSavingsShares);

        assertEq(spPrime.firstPendingDepositId(),            1 + 2 * MAX_AUTO_PROCESS_REQUESTS);
        assertEq(spPrime.getPendingDepositRequests().length, RUN_LENGTH + 1 - 2 * MAX_AUTO_PROCESS_REQUESTS);
        assertEq(spPrime.pendingDepositSavingsShares(),      0);

        // The run (21 entries) is now shorter than the bound: the next deposit is filled instantly.

        deal(address(usdc), user, 1_000_000e6);

        vm.prank(user);
        usdc.approve(address(spPrime), 1_000_000e6);

        uint256 expectedConvertedAssets = 1_000_000e6 - 1;
        uint256 expectedSharesMinted    = spPrime.convertToShares(expectedConvertedAssets);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Referral(REFERRAL, RUN_LENGTH + 2, user, user, 1_000_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositRequest(RUN_LENGTH + 2, user, user, 1_000_000e6, expectedSavingsShares);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(RUN_LENGTH + 2, user, user, expectedSavingsShares, expectedConvertedAssets, expectedSharesMinted);

        vm.prank(user);
        requestId = spPrime.requestDeposit(1_000_000e6, user, REFERRAL);

        assertEq(requestId, RUN_LENGTH + 2);

        assertEq(spPrime.firstPendingDepositId(),            RUN_LENGTH + 3);
        assertEq(spPrime.getPendingDepositRequests().length, 0);
        assertEq(spPrime.pendingDepositSavingsShares(),      0);
        assertEq(spPrime.balanceOf(user),                    expectedSharesMinted);
        assertEq(spPrime.assetsOf(user),                     1_000_000e6 - 2);
    }

    function test_processPendingDeposits_clearsRun() external {
        _fillHead();

        assertEq(spPrime.getPendingDepositRequests().length, RUN_LENGTH);
        assertEq(spPrime.pendingDepositSavingsShares(),      0);

        _processPendingDeposits(0, RUN_LENGTH);

        assertEq(spPrime.firstPendingDepositId(),                 RUN_LENGTH + 1);
        assertEq(spPrime.getPendingDepositRequests().length,      0);
        assertEq(spPrime.pendingDepositSavingsShares(),           0);
        assertEq(spPrime.pendingCancelledDepositSavingsShares(),  runShares);
        assertEq(spPrime.totalSupply(),                           spPrime.balanceOf(head));
    }

}

contract RequestRedeemTests is SparkPrimeVaultTests {

    // Failure tests

    function test_requestRedeem_isPaused() external {
        _pause();

        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(user);
        spPrime.requestRedeem(100e6, user);
    }

    function test_requestRedeem_zeroRecipient() external {
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vm.prank(user);
        spPrime.requestRedeem(100e6, address(0));
    }

    function test_requestRedeem_vaultIsRecipient() external {
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vm.prank(user);
        spPrime.requestRedeem(100e6, address(spPrime));
    }

    function test_requestRedeem_belowMinRedeemBoundary() external {
        _requestDeposit(user, 1_000e6);

        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vm.prank(user);
        spPrime.requestRedeem(MINIMUM_REDEEM - 1, user);

        vm.prank(user);
        spPrime.requestRedeem(MINIMUM_REDEEM, user);
    }

    function test_requestRedeem_insufficientBalanceBoundary() external {
        _requestDeposit(user, 1_000e6);

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
        _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Filled instantly)

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalAssets            = 1_000_000e6 - 2;
        vaultState.availableCapacityValue = 104_000_000e6;  // Vault capacity value was 105m because of 5% change in chi prior to the first deposit
        vaultState.availableLiquidAssets  = 1_000_000e6 - 1;

        vaultState.depositRequests.firstPendingId = 1;

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

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.RedeemRequest(0, user, user, 500_000e6, 0);

        vm.prank(user);
        uint256 requestId = spPrime.requestRedeem(500_000e6, user);

        assertEq(requestId, 0);

        vaultState.redeemRequests.pendingShareValue = 525_000e6 - 1;  // 500k spPrime == 525k USD because of current exchange rate
        vaultState.redeemRequests.length            = 1;
        vaultState.redeemRequests.firstPendingId    = 0;

        userBalances.shareValue -= 525_000e6;

        vaultBalances.shareValue += 525_000e6 - 1;

        _assertRedeemRequest(0, user, user, 525_000e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

    function test_requestRedeem_withFee() external {
        _setMaxRedeemFeeRate(0.01e18);  // 1%
        _setRedeemFeeRate(0.005e18);    // 0.5%

        _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Filled instantly)

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalAssets            = 1_000_000e6 - 2;
        vaultState.availableCapacityValue = 104_000_000e6;  // Vault capacity value was 105m because of 5% change in chi prior to the first deposit
        vaultState.availableLiquidAssets  = 1_000_000e6 - 1;

        vaultState.depositRequests.firstPendingId = 1;

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

        // Assets held (spUSDC value) match assets owed to spPrime holders, within rounding
        assertEq(spPrime.availableLiquidAssets() - spPrime.totalAssets(), 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.RedeemRequest(0, user, user, 500_000e6, 2_500e6);

        vm.prank(user);
        uint256 requestId = spPrime.requestRedeem(500_000e6, user);

        assertEq(requestId, 0);

        // Fee shares are burned, so supply and assets drop and capacity frees up
        vaultState.totalAssets            -= 2_625e6;  // 2_500e6 fee shares * 1.05 chi
        vaultState.availableCapacityValue += 2_625e6;

        vaultState.redeemRequests.pendingShareValue = 525_000e6 - 2_625e6 - 1;
        vaultState.redeemRequests.length            = 1;
        vaultState.redeemRequests.firstPendingId    = 0;

        userBalances.shareValue -= 525_000e6;

        vaultBalances.shareValue += 525_000e6 - 2_625e6 - 1;

        _assertRedeemRequest(0, user, user, 525_000e6 - 2_625e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // Assets held are unchanged but assets owed dropped by the burned fee, the difference is Spark's profit
        assertEq(spPrime.availableLiquidAssets() - spPrime.totalAssets(), 2_625e6 + 1);
    }

}

contract ProcessPendingDepositsTests is SparkPrimeVaultTests {

    address internal ali = makeAddr("ali");
    address internal bob = makeAddr("bob");
    address internal cam = makeAddr("cam");

    AccountBalances internal aliBalances;
    AccountBalances internal bobBalances;
    AccountBalances internal camBalances;
    AccountBalances internal vaultBalances;

    function setUp() public override {
        super.setUp();

        vm.label(ali, "ali");
        vm.label(bob, "bob");
        vm.label(cam, "cam");

        _setCapacity(0);

        _requestDeposit(ali, 100_000e6);    // Will be cancelled
        _requestDeposit(bob, 200_000e6);    // Will be cancelled
        _requestDeposit(cam, 300_000e6);    // Will be cancelled
        _requestDeposit(ali, 400_000e6);    // Will be filled
        _requestDeposit(bob, 500_000e6);    // Will be filled
        _requestDeposit(cam, 600_000e6);    // Will be cancelled
        _requestDeposit(ali, 700_000e6);    // Will be filled
        _requestDeposit(bob, 800_000e6);    // Will be filled
        _requestDeposit(cam, 900_000e6);    // Will be cancelled
        _requestDeposit(ali, 1_000_000e6);  // Will be partially filled

        _requestDepositCancellation(ali, 0, spUSDC.convertToShares(100_000e6));
        _requestDepositCancellation(bob, 1, spUSDC.convertToShares(200_000e6));
        _requestDepositCancellation(cam, 2, spUSDC.convertToShares(300_000e6));
        _requestDepositCancellation(cam, 5, spUSDC.convertToShares(600_000e6));
        _requestDepositCancellation(cam, 8, spUSDC.convertToShares(900_000e6));

        uint256 depositedAssets = 5_500_000e6;

        uint256 pendingDepositAssets = 400_000e6 + 500_000e6 + 700_000e6 + 800_000e6 + 1_000_000e6;

        uint256 pendingDepositCancellationAssets = 100_000e6 + 200_000e6 + 300_000e6 + 600_000e6 + 900_000e6;

        uint256 targetAssets = 400_000e6 + 500_000e6 + 700_000e6 + 800_000e6 + 200_000e6;  // Only 200k of the last 1MM deposit

        _setCapacity(spPrime.convertToShares(targetAssets));

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalAssets            = 0;
        vaultState.totalClaimable         = 0;
        vaultState.availableCapacityValue = targetAssets - 1;
        vaultState.availableLiquidAssets  = depositedAssets - 5;

        vaultState.depositRequests.pendingShareValue = pendingDepositAssets - 3;
        vaultState.depositRequests.length            = 7;
        vaultState.depositRequests.firstPendingId    = 3;

        vaultState.depositCancellationRequests.pendingShareValue = pendingDepositCancellationAssets - 3;
        vaultState.depositCancellationRequests.length            = 5;
        vaultState.depositCancellationRequests.firstPendingId    = 0;

        aliBalances = AccountBalances({
            account           : ali,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        bobBalances = AccountBalances({
            account           : bob,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        camBalances = AccountBalances({
            account           : cam,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : depositedAssets - 5,
            claimableAssets   : 0
        });

        _assertVaultState();

        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 3; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertDepositRequest(3, ali,        ali,        400_000e6 - 1);
        _assertDepositRequest(4, bob,        bob,        500_000e6 - 1);
        _assertDepositRequest(5, address(0), address(0), 0);
        _assertDepositRequest(6, ali,        ali,        700_000e6 - 1);
        _assertDepositRequest(7, bob,        bob,        800_000e6 - 1);
        _assertDepositRequest(8, address(0), address(0), 0);
        _assertDepositRequest(9, ali,        ali,        1_000_000e6 - 1);
    }

    // Failure tests

    function test_processPendingDeposits_isPaused() external {
        _pause();

        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(operator);
        spPrime.processPendingDeposits(type(uint256).max, type(uint256).max);
    }

    // Success tests

    function test_processPendingDeposits_infiniteMaxSavingsShares_infiniteMaxRequests() external {
        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(3, ali, ali, spUSDC.convertToShares(400_000e6), 400_000e6 - 1, spPrime.convertToShares(400_000e6) - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), bob, spPrime.convertToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1, spPrime.convertToShares(500_000e6) - 1);

        // Deposit Request 6

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertToShares(700_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(6, ali, ali, spUSDC.convertToShares(700_000e6), 700_000e6 - 1, spPrime.convertToShares(700_000e6) - 1);

        // Deposit Request 7

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), bob, spPrime.convertToShares(800_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(7, bob, bob, spUSDC.convertToShares(800_000e6), 800_000e6 - 1, spPrime.convertToShares(800_000e6) - 1);

        // Deposit Request 9 (Partial)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertToShares(200_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(9, ali, ali, spUSDC.convertToShares(200_000e6) + 1, 200_000e6, spPrime.convertToShares(200_000e6));

        vm.prank(operator);
        spPrime.processPendingDeposits(type(uint256).max, type(uint256).max);

        uint256 assetsDeposited = 400_000e6 + 500_000e6 + 700_000e6 + 800_000e6 + 200_000e6;  // Only ~200k of the last 1MM deposit

        vaultState.totalAssets            += assetsDeposited - 7;
        vaultState.availableCapacityValue -= assetsDeposited - 7;

        vaultState.depositRequests.pendingShareValue -= assetsDeposited - 1;
        vaultState.depositRequests.length             = 1;
        vaultState.depositRequests.firstPendingId     = 9;

        aliBalances.shareValue += 400_000e6 + 700_000e6 + 200_000e6 - 4;
        bobBalances.shareValue += 500_000e6 + 800_000e6 - 4;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 9; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertDepositRequest(9, ali, ali, 800_000e6 - 2);
    }

    function test_processPendingDeposits_infiniteMaxSavingsShares_limitedMaxRequests() external {
        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(3, ali, ali, spUSDC.convertToShares(400_000e6), 400_000e6 - 1, spPrime.convertToShares(400_000e6) - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), bob, spPrime.convertToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1, spPrime.convertToShares(500_000e6) - 1);

        // First 3 cancelled deposits were already skipped, so this fills 2 deposits, then skips 1 cancelled deposit.
        vm.prank(operator);
        spPrime.processPendingDeposits(type(uint256).max, 3);

        uint256 assetsDeposited = 400_000e6 + 500_000e6;  // Only first 2 uncancelled deposits

        vaultState.totalAssets            += assetsDeposited - 4;
        vaultState.availableCapacityValue -= assetsDeposited - 3;

        vaultState.depositRequests.pendingShareValue -= assetsDeposited - 1;
        vaultState.depositRequests.length             = 4;
        vaultState.depositRequests.firstPendingId     = 6;

        aliBalances.shareValue += 400_000e6 - 2;
        bobBalances.shareValue += 500_000e6 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 6; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertDepositRequest(6, ali,        ali,        700_000e6 - 1);
        _assertDepositRequest(7, bob,        bob,        800_000e6 - 1);
        _assertDepositRequest(8, address(0), address(0), 0);
        _assertDepositRequest(9, ali,        ali,        1_000_000e6 - 1);
    }

    function test_processPendingDeposits_limitedMaxSavingsShares_infiniteMaxRequests() external {
        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(3, ali, ali, spUSDC.convertToShares(400_000e6), 400_000e6 - 1, spPrime.convertToShares(400_000e6) - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), bob, spPrime.convertToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1, spPrime.convertToShares(500_000e6) - 1);

        // Deposit Request 6 (Partial)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertToShares(300_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(6, ali, ali, spUSDC.convertToShares(300_000e6) + 1, 300_000e6, spPrime.convertToShares(300_000e6));

        vm.startPrank(operator);
        spPrime.processPendingDeposits(spUSDC.convertToShares(1_200_000e6), type(uint256).max);
        vm.stopPrank();

        uint256 assetsDeposited = 400_000e6 + 500_000e6 + 300_000e6;  // Only ~300k of the third uncancelled 700k deposit

        vaultState.totalAssets            += assetsDeposited - 4;
        vaultState.availableCapacityValue -= assetsDeposited - 3;

        vaultState.depositRequests.pendingShareValue -= assetsDeposited - 1;
        vaultState.depositRequests.length             = 4;
        vaultState.depositRequests.firstPendingId     = 6;

        aliBalances.shareValue += 400_000e6 + 300_000e6 - 2;
        bobBalances.shareValue += 500_000e6 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 6; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertDepositRequest(6, ali,        ali,        400_000e6 - 2);  // Partial fill
        _assertDepositRequest(7, bob,        bob,        800_000e6 - 1);
        _assertDepositRequest(8, address(0), address(0), 0);
        _assertDepositRequest(9, ali,        ali,        1_000_000e6 - 1);
    }

    function _getMaxDepositableAmount(uint256 requestAmount, uint256 maxSavingsShareValue, uint256 assetsDeposited) internal pure returns (uint256) {
        return assetsDeposited + requestAmount > maxSavingsShareValue
            ? maxSavingsShareValue - assetsDeposited
            : requestAmount;
    }

    function testFuzz_processPendingDeposits(uint256 maxSavingsShareValue, uint256 maxRequests) external {
        maxSavingsShareValue = _bound(maxSavingsShareValue, 0, 2 * vaultState.depositRequests.pendingShareValue);
        maxRequests          = _bound(maxRequests,          0, 2 * vaultState.depositRequests.length);

        vm.startPrank(operator);
        spPrime.processPendingDeposits(spUSDC.convertToShares(maxSavingsShareValue), maxRequests);
        vm.stopPrank();

        uint256 assetsDeposited;

        for (uint256 i = 0; i < maxRequests; ++i) {
            if (i == 0) {
                uint256 depositAmount = _getMaxDepositableAmount(400_000e6, maxSavingsShareValue, 0);

                aliBalances.shareValue += depositAmount;
                assetsDeposited        += depositAmount;

                if (depositAmount < 400_000e6) break;
            }

            if (i == 1) {
                uint256 depositAmount = _getMaxDepositableAmount(500_000e6, maxSavingsShareValue, assetsDeposited);

                bobBalances.shareValue += depositAmount;
                assetsDeposited        += depositAmount;

                if (depositAmount < 500_000e6) break;
            }

            if (i == 3) {
                uint256 depositAmount = _getMaxDepositableAmount(700_000e6, maxSavingsShareValue, assetsDeposited);

                aliBalances.shareValue += depositAmount;
                assetsDeposited        += depositAmount;

                if (depositAmount < 700_000e6) break;
            }

            if (i == 4) {
                uint256 depositAmount = _getMaxDepositableAmount(800_000e6, maxSavingsShareValue, assetsDeposited);

                bobBalances.shareValue += depositAmount;
                assetsDeposited        += depositAmount;

                if (depositAmount < 800_000e6) break;
            }

            if (i == 6) {
                uint256 depositAmount = _getMaxDepositableAmount(200_000e6, maxSavingsShareValue, assetsDeposited);

                aliBalances.shareValue += depositAmount;
                assetsDeposited        += depositAmount;

                break; // Last deposit request can never be entirely fulfilled.
            }

            --vaultState.depositRequests.length;
            ++vaultState.depositRequests.firstPendingId;

            if (vaultState.depositRequests.length == 0) break;
        }

        vaultState.totalAssets += assetsDeposited;

        if (vaultState.availableCapacityValue < assetsDeposited) {
            vaultState.availableCapacityValue = 0;
        } else {
            vaultState.availableCapacityValue -= assetsDeposited;
        }

        if (vaultState.depositRequests.pendingShareValue < assetsDeposited) {
            vaultState.depositRequests.pendingShareValue = 0;
        } else {
            vaultState.depositRequests.pendingShareValue -= assetsDeposited;
        }

        _assertVaultState(10);
        _assertAccountBalances(aliBalances,   10);
        _assertAccountBalances(bobBalances,   10);
        _assertAccountBalances(camBalances,   10);
        _assertAccountBalances(vaultBalances, 10);
    }

    function test_processPendingDeposits_multipleCalls() external {
        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(3, ali, ali, spUSDC.convertToShares(400_000e6), 400_000e6 - 1, spPrime.convertToShares(400_000e6) - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), bob, spPrime.convertToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1, spPrime.convertToShares(500_000e6) - 1);

        // Deposit Request 6 (Partial)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertToShares(300_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(6, ali, ali, spUSDC.convertToShares(300_000e6) + 1, 300_000e6, spPrime.convertToShares(300_000e6));

        vm.startPrank(operator);
        spPrime.processPendingDeposits(spUSDC.convertToShares(1_200_000e6), type(uint256).max);
        vm.stopPrank();

        uint256 assetsDeposited = 400_000e6 + 500_000e6 + 300_000e6;  // Only ~300k of the Request 6 700k deposit

        vaultState.totalAssets            += assetsDeposited - 4;
        vaultState.availableCapacityValue -= assetsDeposited - 3;

        vaultState.depositRequests.pendingShareValue -= assetsDeposited - 1;
        vaultState.depositRequests.length             = 4;
        vaultState.depositRequests.firstPendingId     = 6;

        aliBalances.shareValue += 400_000e6 + 300_000e6 - 2;
        bobBalances.shareValue += 500_000e6 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 6; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertDepositRequest(6, ali,        ali,        400_000e6 - 2);  // Partial fill
        _assertDepositRequest(7, bob,        bob,        800_000e6 - 1);
        _assertDepositRequest(8, address(0), address(0), 0);
        _assertDepositRequest(9, ali,        ali,        1_000_000e6 - 1);

        // Deposit Request 6 (Remainder)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertToShares(400_000e6) - 2);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(6, ali, ali, spUSDC.convertToShares(400_000e6) - 1, 400_000e6 - 2, spPrime.convertToShares(400_000e6) - 2);

        // Deposit Request 7

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), bob, spPrime.convertToShares(800_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(7, bob, bob, spUSDC.convertToShares(800_000e6), 800_000e6 - 1, spPrime.convertToShares(800_000e6) - 1);

        // Deposit Request 9 (Partial)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertToShares(200_000e6) + 3);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(9, ali, ali, spUSDC.convertToShares(200_000e6) + 3, 200_000e6 + 3, spPrime.convertToShares(200_000e6) + 3);

        vm.prank(operator);
        spPrime.processPendingDeposits(type(uint256).max, type(uint256).max);

        assetsDeposited = 400_000e6 + 800_000e6 + 200_000e6;  // Remaining ~400k of request 6, then only ~200k of the last 1MM deposit

        vaultState.totalAssets            += assetsDeposited - 1;
        vaultState.availableCapacityValue -= assetsDeposited - 2;

        vaultState.depositRequests.pendingShareValue -= assetsDeposited + 2;
        vaultState.depositRequests.length             = 1;
        vaultState.depositRequests.firstPendingId     = 9;

        aliBalances.shareValue += 400_000e6 + 200_000e6;
        bobBalances.shareValue += 800_000e6 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 9; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertDepositRequest(9, ali, ali, 800_000e6 - 4);
    }

}

contract ProcessPendingDepositsCancellationsTests is SparkPrimeVaultTests {

    address internal ali = makeAddr("ali");
    address internal bob = makeAddr("bob");
    address internal cam = makeAddr("cam");
    address internal dan = makeAddr("dan");

    AccountBalances internal aliBalances;
    AccountBalances internal bobBalances;
    AccountBalances internal camBalances;
    AccountBalances internal danBalances;
    AccountBalances internal vaultBalances;

    function setUp() public override {
        super.setUp();

        vm.label(ali, "ali");
        vm.label(bob, "bob");
        vm.label(cam, "cam");
        vm.label(dan, "dan");

        _setCapacity(0);

        _requestDeposit(ali, 100_000e6);
        _requestDeposit(bob, 200_000e6);
        _requestDeposit(cam, 300_000e6);
        _requestDeposit(ali, 400_000e6);
        _requestDeposit(bob, 500_000e6);
        _requestDeposit(cam, 600_000e6);
        _requestDeposit(ali, 700_000e6);
        _requestDeposit(bob, 800_000e6);
        _requestDeposit(cam, 900_000e6);
        _requestDeposit(ali, 1_000_000e6);

        _requestDepositCancellation(ali, 0, ali, spUSDC.convertToShares(100_000e6));  // Will fail
        _requestDepositCancellation(bob, 1, bob, spUSDC.convertToShares(200_000e6));
        _requestDepositCancellation(cam, 2, cam, spUSDC.convertToShares(300_000e6));
        _requestDepositCancellation(ali, 3, dan, spUSDC.convertToShares(400_000e6));  // Will fail
        _requestDepositCancellation(bob, 4, bob, spUSDC.convertToShares(500_000e6));  // Will fail
        _requestDepositCancellation(cam, 5, cam, spUSDC.convertToShares(600_000e6));
        _requestDepositCancellation(ali, 6, ali, spUSDC.convertToShares(700_000e6));  // Will fail
        _requestDepositCancellation(bob, 7, dan, spUSDC.convertToShares(800_000e6));  // Will fail
        _requestDepositCancellation(cam, 8, cam, spUSDC.convertToShares(900_000e6));
        _requestDepositCancellation(ali, 9, ali, spUSDC.convertToShares(1_000_000e6));

        uint256 depositedAssets = 5_500_000e6;

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalAssets            = 0;
        vaultState.totalClaimable         = 0;
        vaultState.availableCapacityValue = 0;
        vaultState.availableLiquidAssets  = depositedAssets - 5;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 10;

        vaultState.depositCancellationRequests.pendingShareValue = depositedAssets - 5;
        vaultState.depositCancellationRequests.length            = 10;
        vaultState.depositCancellationRequests.firstPendingId    = 0;

        aliBalances = AccountBalances({
            account           : ali,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        bobBalances = AccountBalances({
            account           : bob,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        camBalances = AccountBalances({
            account           : cam,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        danBalances = AccountBalances({
            account           : dan,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : depositedAssets - 5,
            claimableAssets   : 0
        });

        _assertVaultState();

        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 10; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertDepositCancellationRequest(0, ali, ali, 100_000e6 - 1);
        _assertDepositCancellationRequest(1, bob, bob, 200_000e6 - 1);
        _assertDepositCancellationRequest(2, cam, cam, 300_000e6 - 1);
        _assertDepositCancellationRequest(3, ali, dan, 400_000e6 - 1);
        _assertDepositCancellationRequest(4, bob, bob, 500_000e6 - 1);
        _assertDepositCancellationRequest(5, cam, cam, 600_000e6 - 1);
        _assertDepositCancellationRequest(6, ali, ali, 700_000e6 - 1);
        _assertDepositCancellationRequest(7, bob, dan, 800_000e6 - 1);
        _assertDepositCancellationRequest(8, cam, cam, 900_000e6 - 1);
        _assertDepositCancellationRequest(9, ali, ali, 1_000_000e6 - 1);
    }

    function test_processPendingDepositCancellations_fallbackRedeemReverts() external {
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.redeem.selector, spUSDC.convertToShares(100_000e6), ali, address(spPrime)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.redeem.selector, spUSDC.convertToShares(100_000e6), address(spPrime), address(spPrime)),
            "redeem-to-vault-reverts"
        );

        vm.expectRevert(bytes("redeem-to-vault-reverts"));
        vm.prank(operator);
        spPrime.processPendingDepositCancellations(type(uint256).max, type(uint256).max);
    }

    function test_processPendingDepositCancellations_whilePaused() external {
        _pause();

        vm.prank(operator);
        spPrime.processPendingDepositCancellations(type(uint256).max, type(uint256).max);
    }

    function _setupMockCallReverts() internal {
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.redeem.selector, spUSDC.convertToShares(100_000e6), ali, address(spPrime)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.redeem.selector, spUSDC.convertToShares(400_000e6), dan, address(spPrime)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.redeem.selector, spUSDC.convertToShares(500_000e6), bob, address(spPrime)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.redeem.selector, spUSDC.convertToShares(700_000e6), ali, address(spPrime)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.redeem.selector, spUSDC.convertToShares(800_000e6), dan, address(spPrime)),
            ""
        );
    }

    function test_processPendingDepositCancellations_infiniteMaxSavingsShares_infiniteMaxRequests() external {
        _setupMockCallReverts();

        // Deposit Request 0

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, 100_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(0, ali, ali, spUSDC.convertToShares(100_000e6), 100_000e6 - 1);

        // Deposit Request 1

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(1, bob, bob, spUSDC.convertToShares(200_000e6), 200_000e6 - 1);

        // Deposit Request 2

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(2, cam, cam, spUSDC.convertToShares(300_000e6), 300_000e6 - 1);

        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, 400_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(3, ali, dan, spUSDC.convertToShares(400_000e6), 400_000e6 - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, 500_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1);

        // Deposit Request 5

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(5, cam, cam, spUSDC.convertToShares(600_000e6), 600_000e6 - 1);

        // Deposit Request 6

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, 700_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(6, ali, ali, spUSDC.convertToShares(700_000e6), 700_000e6 - 1);

        // Deposit Request 7

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, 800_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(7, bob, dan, spUSDC.convertToShares(800_000e6), 800_000e6 - 1);

        // Deposit Request 8

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(8, cam, cam, spUSDC.convertToShares(900_000e6), 900_000e6 - 1);

        // Deposit Request 9

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(9, ali, ali, spUSDC.convertToShares(1_000_000e6), 1_000_000e6 - 1);

        vm.prank(operator);
        spPrime.processPendingDepositCancellations(type(uint256).max, type(uint256).max);

        uint256 totalClaimable = 100_000e6 + 400_000e6 + 500_000e6 + 700_000e6 + 800_000e6;

        vaultState.totalClaimable        += totalClaimable - 5;
        vaultState.availableLiquidAssets  = 0;

        vaultState.depositCancellationRequests.pendingShareValue = 0;
        vaultState.depositCancellationRequests.length            = 0;
        vaultState.depositCancellationRequests.firstPendingId    = 10;

        aliBalances.assets          += 1_000_000e6 - 1;
        aliBalances.claimableAssets += 100_000e6 + 700_000e6 - 2;

        bobBalances.assets          += 200_000e6 - 1;
        bobBalances.claimableAssets += 500_000e6 - 1;

        camBalances.assets += 300_000e6 + 600_000e6 + 900_000e6 - 3;

        danBalances.claimableAssets += 400_000e6 + 800_000e6 - 2;

        vaultBalances.assets            += totalClaimable - 5;
        vaultBalances.savingsShareValue  = 0;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 10; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositCancellationRequest(i);
        }
    }

    function test_processPendingDepositCancellations_infiniteMaxSavingsShares_limitedMaxRequests() external {
        _setupMockCallReverts();

        // Deposit Request 0

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, 100_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(0, ali, ali, spUSDC.convertToShares(100_000e6), 100_000e6 - 1);

        // Deposit Request 1

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(1, bob, bob, spUSDC.convertToShares(200_000e6), 200_000e6 - 1);

        // Deposit Request 2

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(2, cam, cam, spUSDC.convertToShares(300_000e6), 300_000e6 - 1);

        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, 400_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(3, ali, dan, spUSDC.convertToShares(400_000e6), 400_000e6 - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, 500_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1);

        // Deposit Request 5

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(5, cam, cam, spUSDC.convertToShares(600_000e6), 600_000e6 - 1);

        vm.prank(operator);
        spPrime.processPendingDepositCancellations(type(uint256).max, 6);

        uint256 assetsWithdrawn = 100_000e6 + 200_000e6 + 300_000e6 + 400_000e6 + 500_000e6 + 600_000e6;
        uint256 totalClaimable  = 100_000e6 + 400_000e6 + 500_000e6;

        vaultState.totalClaimable        += totalClaimable - 3;
        vaultState.availableLiquidAssets -= assetsWithdrawn - 2;

        vaultState.depositCancellationRequests.pendingShareValue -= assetsWithdrawn - 2;
        vaultState.depositCancellationRequests.length            = 4;
        vaultState.depositCancellationRequests.firstPendingId    = 6;

        aliBalances.claimableAssets += 100_000e6 - 1;

        bobBalances.assets          += 200_000e6 - 1;
        bobBalances.claimableAssets += 500_000e6 - 1;

        camBalances.assets += 300_000e6 + 600_000e6 - 2;

        danBalances.claimableAssets += 400_000e6 - 1;

        vaultBalances.assets            += totalClaimable - 3;
        vaultBalances.savingsShareValue -= assetsWithdrawn - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 6; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositCancellationRequest(i);
        }

        _assertDepositCancellationRequest(6, ali, ali, 700_000e6 - 1);
        _assertDepositCancellationRequest(7, bob, dan, 800_000e6 - 1);
        _assertDepositCancellationRequest(8, cam, cam, 900_000e6 - 1);
        _assertDepositCancellationRequest(9, ali, ali, 1_000_000e6 - 1);
    }

    function test_processPendingDepositCancellations_limitedMaxSavingsShares_infiniteMaxRequests() external {
        _setupMockCallReverts();

        // Deposit Request 0

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, 100_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(0, ali, ali, spUSDC.convertToShares(100_000e6), 100_000e6 - 1);

        // Deposit Request 1

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(1, bob, bob, spUSDC.convertToShares(200_000e6), 200_000e6 - 1);

        // Deposit Request 2

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(2, cam, cam, spUSDC.convertToShares(300_000e6), 300_000e6 - 1);

        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, 400_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(3, ali, dan, spUSDC.convertToShares(400_000e6), 400_000e6 - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, 500_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1);

        // Deposit Request 5

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(5, cam, cam, spUSDC.convertToShares(500_000e6) + 2, 500_000e6 + 1);  // Only 500k of the 600k is processed

        vm.startPrank(operator);
        spPrime.processPendingDepositCancellations(spUSDC.convertToShares(2_000_000e6), type(uint256).max);
        vm.stopPrank();

        uint256 assetsWithdrawn = 100_000e6 + 200_000e6 + 300_000e6 + 400_000e6 + 500_000e6 + 500_000e6;  // Only 500k of the last request is processed
        uint256 totalClaimable  = 100_000e6 + 400_000e6 + 500_000e6;

        vaultState.totalClaimable        += totalClaimable - 3;
        vaultState.availableLiquidAssets -= assetsWithdrawn;

        vaultState.depositCancellationRequests.pendingShareValue -= assetsWithdrawn;
        vaultState.depositCancellationRequests.length            = 5;
        vaultState.depositCancellationRequests.firstPendingId    = 5;

        aliBalances.claimableAssets += 100_000e6 - 1;

        bobBalances.assets          += 200_000e6 - 1;
        bobBalances.claimableAssets += 500_000e6 - 1;

        camBalances.assets += 300_000e6 + 500_000e6;

        danBalances.claimableAssets += 400_000e6 - 1;

        vaultBalances.assets            += totalClaimable - 3;
        vaultBalances.savingsShareValue -= assetsWithdrawn;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 5; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositCancellationRequest(i);
        }

        _assertDepositCancellationRequest(5, cam, cam, 100_000e6 - 2);
        _assertDepositCancellationRequest(6, ali, ali, 700_000e6 - 1);
        _assertDepositCancellationRequest(7, bob, dan, 800_000e6 - 1);
        _assertDepositCancellationRequest(8, cam, cam, 900_000e6 - 1);
        _assertDepositCancellationRequest(9, ali, ali, 1_000_000e6 - 1);
    }

    function test_processPendingDepositCancellations_multipleCalls() external {
        _setupMockCallReverts();

        // Deposit Request 0

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, 100_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(0, ali, ali, spUSDC.convertToShares(100_000e6), 100_000e6 - 1);

        // Deposit Request 1

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(1, bob, bob, spUSDC.convertToShares(200_000e6), 200_000e6 - 1);

        // Deposit Request 2

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(2, cam, cam, spUSDC.convertToShares(300_000e6), 300_000e6 - 1);

        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, 400_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(3, ali, dan, spUSDC.convertToShares(400_000e6), 400_000e6 - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, 500_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1);

        // Deposit Request 5 (Partial)

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(5, cam, cam, spUSDC.convertToShares(500_000e6) + 2, 500_000e6 + 1);  // Only 500k of the 600k is processed

        vm.startPrank(operator);
        spPrime.processPendingDepositCancellations(spUSDC.convertToShares(2_000_000e6), type(uint256).max);
        vm.stopPrank();

        uint256 assetsWithdrawn = 100_000e6 + 200_000e6 + 300_000e6 + 400_000e6 + 500_000e6 + 500_000e6;  // Only 500k of the last request is processed
        uint256 totalClaimable  = 100_000e6 + 400_000e6 + 500_000e6;

        vaultState.totalClaimable        += totalClaimable - 3;
        vaultState.availableLiquidAssets -= assetsWithdrawn;

        vaultState.depositCancellationRequests.pendingShareValue -= assetsWithdrawn;
        vaultState.depositCancellationRequests.length             = 5;
        vaultState.depositCancellationRequests.firstPendingId     = 5;

        aliBalances.claimableAssets += 100_000e6 - 1;

        bobBalances.assets          += 200_000e6 - 1;
        bobBalances.claimableAssets += 500_000e6 - 1;

        camBalances.assets += 300_000e6 + 500_000e6;

        danBalances.claimableAssets += 400_000e6 - 1;

        vaultBalances.assets            += totalClaimable - 3;
        vaultBalances.savingsShareValue -= assetsWithdrawn;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 5; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositCancellationRequest(i);
        }

        _assertDepositCancellationRequest(5, cam, cam, 100_000e6 - 2);  // Partial fill
        _assertDepositCancellationRequest(6, ali, ali, 700_000e6 - 1);
        _assertDepositCancellationRequest(7, bob, dan, 800_000e6 - 1);
        _assertDepositCancellationRequest(8, cam, cam, 900_000e6 - 1);
        _assertDepositCancellationRequest(9, ali, ali, 1_000_000e6 - 1);

        // Deposit Request 5 (Remainder)

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(5, cam, cam, spUSDC.convertToShares(100_000e6) - 1, 100_000e6 - 2);

        // Deposit Request 6

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, 700_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(6, ali, ali, spUSDC.convertToShares(700_000e6), 700_000e6 - 1);

        // Deposit Request 7

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, 800_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(7, bob, dan, spUSDC.convertToShares(800_000e6), 800_000e6 - 1);

        // Deposit Request 8

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(8, cam, cam, spUSDC.convertToShares(900_000e6), 900_000e6 - 1);

        // Deposit Request 9

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(9, ali, ali, spUSDC.convertToShares(1_000_000e6), 1_000_000e6 - 1);

        vm.prank(operator);
        spPrime.processPendingDepositCancellations(type(uint256).max, type(uint256).max);

        totalClaimable = 700_000e6 + 800_000e6;

        vaultState.totalClaimable        += totalClaimable - 2;
        vaultState.availableLiquidAssets  = 0;

        vaultState.depositCancellationRequests.pendingShareValue = 0;
        vaultState.depositCancellationRequests.length            = 0;
        vaultState.depositCancellationRequests.firstPendingId    = 10;

        aliBalances.assets          += 1_000_000e6 - 1;
        aliBalances.claimableAssets += 700_000e6 - 1;

        camBalances.assets += 100_000e6 + 900_000e6 - 3;

        danBalances.claimableAssets += 800_000e6 - 1;

        vaultBalances.assets            += totalClaimable - 2;
        vaultBalances.savingsShareValue  = 0;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 10; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositCancellationRequest(i);
        }
    }

}

contract ProcessPendingRedeemsTests is SparkPrimeVaultTests {

    address internal ali = makeAddr("ali");
    address internal bob = makeAddr("bob");
    address internal cam = makeAddr("cam");
    address internal dan = makeAddr("dan");

    AccountBalances internal aliBalances;
    AccountBalances internal bobBalances;
    AccountBalances internal camBalances;
    AccountBalances internal danBalances;
    AccountBalances internal vaultBalances;

    function setUp() public override {
        super.setUp();

        vm.label(ali, "ali");
        vm.label(bob, "bob");
        vm.label(cam, "cam");
        vm.label(dan, "dan");

        // All deposits will be filled instantly

        _requestDeposit(ali, 100_000e6 + 400_000e6 + 700_000e6 + 1_000_000e6);
        _requestDeposit(bob, 200_000e6 + 500_000e6 + 800_000e6);
        _requestDeposit(cam, 300_000e6 + 600_000e6 + 900_000e6);

        _requestRedeem(ali, ali, spPrime.convertToShares(100_000e6));  // Will fail
        _requestRedeem(bob, bob, spPrime.convertToShares(200_000e6));
        _requestRedeem(cam, cam, spPrime.convertToShares(300_000e6));
        _requestRedeem(ali, dan, spPrime.convertToShares(400_000e6));  // Will fail
        _requestRedeem(bob, bob, spPrime.convertToShares(500_000e6));  // Will fail
        _requestRedeem(cam, cam, spPrime.convertToShares(600_000e6));
        _requestRedeem(ali, ali, spPrime.convertToShares(700_000e6));  // Will fail
        _requestRedeem(bob, dan, spPrime.convertToShares(800_000e6));  // Will fail
        _requestRedeem(cam, cam, spPrime.convertToShares(900_000e6));
        _requestRedeem(ali, ali, spPrime.convertToShares(1_000_000e6));

        uint256 depositedAssets = 5_500_000e6;

        uint256 targetAssets = 200_000e6 + 300_000e6 + 600_000e6 + 900_000e6 + 200_000e6;  // Only 200k of the last 1MM deposit

        _take(spUSDC.convertToShares(800_000e6));  // 800k so the last redeem cannot be fully fulfilled

        vaultState.rho                     = vm.getBlockTimestamp();
        vaultState.chi                     = 1.049999999999999999961070145e27;
        vaultState.totalAssets             = depositedAssets - 5;
        vaultState.availableCapacityValue -= depositedAssets - 5;
        vaultState.availableLiquidAssets   = depositedAssets - 800_000e6 - 2;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.firstPendingId    = 3;

        vaultState.redeemRequests.pendingShareValue = depositedAssets - 6;
        vaultState.redeemRequests.length            = 10;
        vaultState.redeemRequests.firstPendingId    = 0;

        aliBalances = AccountBalances({
            account           : ali,
            assets            : 0,
            shareValue        : 1,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        bobBalances = AccountBalances({
            account           : bob,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        camBalances = AccountBalances({
            account           : cam,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        danBalances = AccountBalances({
            account           : dan,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssets   : 0
        });

        vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : depositedAssets - 6,
            savingsShareValue : depositedAssets - 800_000e6 - 2,
            claimableAssets   : 0
        });

        _assertVaultState();

        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 3; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertRedeemRequest(0, ali, ali, 100_000e6 - 1);
        _assertRedeemRequest(1, bob, bob, 200_000e6 - 1);
        _assertRedeemRequest(2, cam, cam, 300_000e6 - 1);
        _assertRedeemRequest(3, ali, dan, 400_000e6 - 1);
        _assertRedeemRequest(4, bob, bob, 500_000e6 - 1);
        _assertRedeemRequest(5, cam, cam, 600_000e6 - 1);
        _assertRedeemRequest(6, ali, ali, 700_000e6 - 1);
        _assertRedeemRequest(7, bob, dan, 800_000e6 - 1);
        _assertRedeemRequest(8, cam, cam, 900_000e6 - 1);
        _assertRedeemRequest(9, ali, ali, 1_000_000e6 - 2);
    }

    function test_processPendingRedeems_fallbackWithdrawReverts() external {
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.withdraw.selector, 100_000e6 - 1, ali, address(spPrime)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.withdraw.selector, 100_000e6 - 1, address(spPrime), address(spPrime)),
            "withdraw-to-vault-reverts"
        );

        vm.expectRevert(bytes("withdraw-to-vault-reverts"));
        vm.prank(operator);
        spPrime.processPendingRedeems(type(uint256).max, type(uint256).max);
    }

    function _setupMockCallReverts() internal {
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.withdraw.selector, 100_000e6 - 1, ali, address(spPrime)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.withdraw.selector, 400_000e6 - 1, dan, address(spPrime)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.withdraw.selector, 500_000e6 - 1, bob, address(spPrime)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.withdraw.selector, 700_000e6 - 1, ali, address(spPrime)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(ISparkVaultLike.withdraw.selector, 800_000e6 - 1, dan, address(spPrime)),
            ""
        );
    }

    function test_processPendingRedeems_infiniteMaxShares_infiniteMaxRequests() external {
        _setupMockCallReverts();

        // Redeem Request 0

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(100_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, 100_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(0, ali, ali, spPrime.convertToShares(100_000e6), spUSDC.convertToShares(100_000e6), 100_000e6 - 1);

        // Redeem Request 1

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(200_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(1, bob, bob, spPrime.convertToShares(200_000e6), spUSDC.convertToShares(200_000e6), 200_000e6 - 1);

        // Redeem Request 2

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(300_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(2, cam, cam, spPrime.convertToShares(300_000e6), spUSDC.convertToShares(300_000e6), 300_000e6 - 1);

        // Redeem Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(400_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, 400_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(3, ali, dan, spPrime.convertToShares(400_000e6), spUSDC.convertToShares(400_000e6), 400_000e6 - 1);

        // Redeem Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(500_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, 500_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(4, bob, bob, spPrime.convertToShares(500_000e6), spUSDC.convertToShares(500_000e6), 500_000e6 - 1);

        // Redeem Request 5

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(600_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(5, cam, cam, spPrime.convertToShares(600_000e6), spUSDC.convertToShares(600_000e6), 600_000e6 - 1);

        // Redeem Request 6

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(700_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, 700_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(6, ali, ali, spPrime.convertToShares(700_000e6), spUSDC.convertToShares(700_000e6), 700_000e6 - 1);

        // Redeem Request 7

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(800_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, 800_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(7, bob, dan, spPrime.convertToShares(800_000e6), spUSDC.convertToShares(800_000e6), 800_000e6 - 1);

        // Redeem Request 8

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(900_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(8, cam, cam, spPrime.convertToShares(900_000e6), spUSDC.convertToShares(900_000e6), 900_000e6 - 1);

        // Redeem Request 9

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(200_000e6) + 3);  // Only ~200k of the last 1MM deposit

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(9, ali, ali, spPrime.convertToShares(200_000e6) + 3, spUSDC.convertToShares(200_000e6) + 2, 200_000e6 + 2);

        vm.prank(operator);
        spPrime.processPendingRedeems(type(uint256).max, type(uint256).max);

        uint256 assetsRedeemed = 5_500_000e6 - 800_000e6;
        uint256 totalClaimable = 100_000e6 + 400_000e6 + 500_000e6 + 700_000e6 + 800_000e6;

        vaultState.totalAssets             = 800_000e6 - 3;
        vaultState.totalClaimable         += totalClaimable - 5;
        vaultState.availableCapacityValue += assetsRedeemed - 2;
        vaultState.availableLiquidAssets   = 1;

        vaultState.redeemRequests.pendingShareValue -= assetsRedeemed - 2;
        vaultState.redeemRequests.length             = 1;
        vaultState.redeemRequests.firstPendingId     = 9;

        aliBalances.assets          += 200_000e6 + 2;
        aliBalances.claimableAssets += 100_000e6 + 700_000e6 - 2;

        bobBalances.assets          += 200_000e6 - 1;
        bobBalances.claimableAssets += 500_000e6 - 1;

        camBalances.assets += 300_000e6 + 600_000e6 + 900_000e6 - 3;

        danBalances.claimableAssets += 400_000e6 + 800_000e6 - 2;

        vaultBalances.assets            += totalClaimable - 5;
        vaultBalances.shareValue        -= assetsRedeemed - 2;
        vaultBalances.savingsShareValue  = 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 9; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingRedeemRequest(i);
        }

        _assertRedeemRequest(9, ali, ali, 800_000e6 - 4);  // Partial fill
    }

    function test_processPendingRedeems_infiniteMaxShares_limitedMaxRequests() external {
        _setupMockCallReverts();

        // Redeem Request 0

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(100_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, 100_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(0, ali, ali, spPrime.convertToShares(100_000e6), spUSDC.convertToShares(100_000e6), 100_000e6 - 1);

        // Redeem Request 1

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(200_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(1, bob, bob, spPrime.convertToShares(200_000e6), spUSDC.convertToShares(200_000e6), 200_000e6 - 1);

        // Redeem Request 2

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(300_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(2, cam, cam, spPrime.convertToShares(300_000e6), spUSDC.convertToShares(300_000e6), 300_000e6 - 1);

        // Redeem Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(400_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, 400_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(3, ali, dan, spPrime.convertToShares(400_000e6), spUSDC.convertToShares(400_000e6), 400_000e6 - 1);

        // Redeem Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(500_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, 500_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(4, bob, bob, spPrime.convertToShares(500_000e6), spUSDC.convertToShares(500_000e6), 500_000e6 - 1);

        // Redeem Request 5

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(600_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(5, cam, cam, spPrime.convertToShares(600_000e6), spUSDC.convertToShares(600_000e6), 600_000e6 - 1);

        vm.prank(operator);
        spPrime.processPendingRedeems(type(uint256).max, 6);

        uint256 assetsRedeemed = 100_000e6 + 200_000e6 + 300_000e6 + 400_000e6 + 500_000e6 + 600_000e6;
        uint256 totalClaimable = 100_000e6 + 400_000e6 + 500_000e6;

        vaultState.totalAssets            -= assetsRedeemed - 2;
        vaultState.totalClaimable         += totalClaimable - 3;
        vaultState.availableCapacityValue += assetsRedeemed - 2;
        vaultState.availableLiquidAssets  -= assetsRedeemed - 3;

        vaultState.redeemRequests.pendingShareValue -= assetsRedeemed - 2;
        vaultState.redeemRequests.length             = 4;
        vaultState.redeemRequests.firstPendingId     = 6;

        aliBalances.claimableAssets += 100_000e6 - 1;

        bobBalances.assets          += 200_000e6 - 1;
        bobBalances.claimableAssets += 500_000e6 - 1;

        camBalances.assets += 300_000e6 + 600_000e6 - 2;

        danBalances.claimableAssets += 400_000e6 - 1;

        vaultBalances.assets            += totalClaimable - 3;
        vaultBalances.shareValue        -= assetsRedeemed - 2;
        vaultBalances.savingsShareValue -= assetsRedeemed - 3;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 6; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingRedeemRequest(i);
        }

        _assertRedeemRequest(6, ali, ali, 700_000e6 - 1);
        _assertRedeemRequest(7, bob, dan, 800_000e6 - 1);
        _assertRedeemRequest(8, cam, cam, 900_000e6 - 1);
        _assertRedeemRequest(9, ali, ali, 1_000_000e6 - 2);
    }

    function test_processPendingRedeems_limitedMaxShares_infiniteMaxRequests() external {
        _setupMockCallReverts();

        // Redeem Request 0

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(100_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, 100_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(0, ali, ali, spPrime.convertToShares(100_000e6), spUSDC.convertToShares(100_000e6), 100_000e6 - 1);

        // Redeem Request 1

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(200_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(1, bob, bob, spPrime.convertToShares(200_000e6), spUSDC.convertToShares(200_000e6), 200_000e6 - 1);

        // Redeem Request 2

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(300_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(2, cam, cam, spPrime.convertToShares(300_000e6), spUSDC.convertToShares(300_000e6), 300_000e6 - 1);

        // Redeem Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(400_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, 400_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(3, ali, dan, spPrime.convertToShares(400_000e6), spUSDC.convertToShares(400_000e6), 400_000e6 - 1);

        // Redeem Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(500_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, 500_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(4, bob, bob, spPrime.convertToShares(500_000e6), spUSDC.convertToShares(500_000e6), 500_000e6 - 1);

        // Redeem Request 5

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(500_000e6) + 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(5, cam, cam, spPrime.convertToShares(500_000e6) + 1, spUSDC.convertToShares(500_000e6) + 1, 500_000e6);

        vm.startPrank(operator);
        spPrime.processPendingRedeems(spPrime.convertToShares(2_000_000e6), type(uint256).max);
        vm.stopPrank();

        uint256 assetsRedeemed = 2_000_000e6;
        uint256 totalClaimable = 100_000e6 + 400_000e6 + 500_000e6;

        vaultState.totalAssets            -= assetsRedeemed - 1;
        vaultState.totalClaimable         += totalClaimable - 3;
        vaultState.availableCapacityValue += assetsRedeemed - 1;
        vaultState.availableLiquidAssets  -= assetsRedeemed - 2;

        vaultState.redeemRequests.pendingShareValue -= assetsRedeemed - 1;
        vaultState.redeemRequests.length             = 5;
        vaultState.redeemRequests.firstPendingId     = 5;

        aliBalances.claimableAssets += 100_000e6 - 1;

        bobBalances.assets          += 200_000e6 - 1;
        bobBalances.claimableAssets += 500_000e6 - 1;

        camBalances.assets += 300_000e6 + 500_000e6 - 1;

        danBalances.claimableAssets += 400_000e6 - 1;

        vaultBalances.assets            += totalClaimable - 3;
        vaultBalances.shareValue        -= assetsRedeemed - 1;
        vaultBalances.savingsShareValue -= assetsRedeemed - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 5; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingRedeemRequest(i);
        }

        _assertRedeemRequest(5, cam, cam, 100_000e6 - 2);  // 500k out of 600k redeemed
        _assertRedeemRequest(6, ali, ali, 700_000e6 - 1);
        _assertRedeemRequest(7, bob, dan, 800_000e6 - 1);
        _assertRedeemRequest(8, cam, cam, 900_000e6 - 1);
        _assertRedeemRequest(9, ali, ali, 1_000_000e6 - 2);
    }

    function test_processPendingRedeems_multipleCalls() external {
        _setupMockCallReverts();

        // Redeem Request 0

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(100_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, 100_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(0, ali, ali, spPrime.convertToShares(100_000e6), spUSDC.convertToShares(100_000e6), 100_000e6 - 1);

        // Redeem Request 1

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(200_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(1, bob, bob, spPrime.convertToShares(200_000e6), spUSDC.convertToShares(200_000e6), 200_000e6 - 1);

        // Redeem Request 2

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(300_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(2, cam, cam, spPrime.convertToShares(300_000e6), spUSDC.convertToShares(300_000e6), 300_000e6 - 1);

        // Redeem Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(400_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, 400_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(3, ali, dan, spPrime.convertToShares(400_000e6), spUSDC.convertToShares(400_000e6), 400_000e6 - 1);

        // Redeem Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(500_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, 500_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(4, bob, bob, spPrime.convertToShares(500_000e6), spUSDC.convertToShares(500_000e6), 500_000e6 - 1);

        // Redeem Request 5 (Partial)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(500_000e6) + 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(5, cam, cam, spPrime.convertToShares(500_000e6) + 1, spUSDC.convertToShares(500_000e6) + 1, 500_000e6);  // Only 500k of the 600k is processed

        vm.startPrank(operator);
        spPrime.processPendingRedeems(spPrime.convertToShares(2_000_000e6), type(uint256).max);
        vm.stopPrank();

        uint256 assetsRedeemed = 100_000e6 + 200_000e6 + 300_000e6 + 400_000e6 + 500_000e6 + 500_000e6;  // Only 500k of the last request is processed
        uint256 totalClaimable = 100_000e6 + 400_000e6 + 500_000e6;

        vaultState.totalAssets            -= assetsRedeemed - 1;
        vaultState.totalClaimable         += totalClaimable - 3;
        vaultState.availableCapacityValue += assetsRedeemed - 1;
        vaultState.availableLiquidAssets  -= assetsRedeemed - 2;

        vaultState.redeemRequests.pendingShareValue -= assetsRedeemed - 1;
        vaultState.redeemRequests.length             = 5;
        vaultState.redeemRequests.firstPendingId     = 5;

        aliBalances.claimableAssets += 100_000e6 - 1;

        bobBalances.assets          += 200_000e6 - 1;
        bobBalances.claimableAssets += 500_000e6 - 1;

        camBalances.assets += 300_000e6 + 500_000e6 - 1;

        danBalances.claimableAssets += 400_000e6 - 1;

        vaultBalances.assets            += totalClaimable - 3;
        vaultBalances.shareValue        -= assetsRedeemed - 1;
        vaultBalances.savingsShareValue -= assetsRedeemed - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 5; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingRedeemRequest(i);
        }

        _assertRedeemRequest(5, cam, cam, 100_000e6 - 2);  // Partial fill
        _assertRedeemRequest(6, ali, ali, 700_000e6 - 1);
        _assertRedeemRequest(7, bob, dan, 800_000e6 - 1);
        _assertRedeemRequest(8, cam, cam, 900_000e6 - 1);
        _assertRedeemRequest(9, ali, ali, 1_000_000e6 - 2);

        // Redeem Request 5 (Remainder)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(100_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(5, cam, cam, spPrime.convertToShares(100_000e6) - 1, spUSDC.convertToShares(100_000e6) - 1, 100_000e6 - 2);

        // Redeem Request 6

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(700_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, 700_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(6, ali, ali, spPrime.convertToShares(700_000e6), spUSDC.convertToShares(700_000e6), 700_000e6 - 1);

        // Redeem Request 7

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(800_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, 800_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(7, bob, dan, spPrime.convertToShares(800_000e6), spUSDC.convertToShares(800_000e6), 800_000e6 - 1);

        // Redeem Request 8

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(900_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(8, cam, cam, spPrime.convertToShares(900_000e6), spUSDC.convertToShares(900_000e6), 900_000e6 - 1);

        // Redeem Request 9 (Partial)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertToShares(200_000e6) + 4);  // Only ~200k of the last 1MM deposit

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(9, ali, ali, spPrime.convertToShares(200_000e6) + 4, spUSDC.convertToShares(200_000e6) + 3, 200_000e6 + 3);

        vm.prank(operator);
        spPrime.processPendingRedeems(type(uint256).max, type(uint256).max);

        assetsRedeemed = 100_000e6 + 700_000e6 + 800_000e6 + 900_000e6 + 200_000e6;  // Remaining ~100k of request 5, then only ~200k of the last 1MM deposit
        totalClaimable = 700_000e6 + 800_000e6;

        vaultState.totalAssets             = 800_000e6 - 4;
        vaultState.totalClaimable         += totalClaimable - 2;
        vaultState.availableCapacityValue += assetsRedeemed;
        vaultState.availableLiquidAssets   = 1;

        vaultState.redeemRequests.pendingShareValue -= assetsRedeemed + 1;
        vaultState.redeemRequests.length             = 1;
        vaultState.redeemRequests.firstPendingId     = 9;

        aliBalances.assets          += 200_000e6 + 3;
        aliBalances.claimableAssets += 700_000e6 - 1;

        camBalances.assets += 100_000e6 + 900_000e6 - 3;

        danBalances.claimableAssets += 800_000e6 - 1;

        vaultBalances.assets            += totalClaimable - 2;
        vaultBalances.shareValue        -= assetsRedeemed + 1;
        vaultBalances.savingsShareValue  = 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 9; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingRedeemRequest(i);
        }

        _assertRedeemRequest(9, ali, ali, 800_000e6 - 6);  // Partial fill
    }

}
