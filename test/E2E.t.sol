// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

import { TestBase } from "./TestBase.t.sol";

contract E2ETests is TestBase {

    uint256 internal constant DAILY_1BP_VSR = 1.000000001157349541564501380e27;  // 1.0001 per day
    uint256 internal constant DAILY_2BP_VSR = 1.000000002314583366871550052e27;  // 1.0002 per day

    address internal ali = makeAddr("ali");
    address internal bob = makeAddr("bob");

    uint256 internal depositRequestValue0;
    uint256 internal depositRequestValue1;

    uint256 internal depositDeltaSavingsYield0;
    uint256 internal depositDeltaSavingsYield1;

    uint256 internal depositRequestTimestamp0;
    uint256 internal depositRequestTimestamp1;

    uint256 internal redeemRequestValue0;
    uint256 internal redeemRequestValue1;
    uint256 internal redeemRequestValue2;

    uint256 internal redeemDeltaPrimeYield0;
    uint256 internal redeemDeltaPrimeYield1;
    uint256 internal redeemDeltaPrimeYield2;

    uint256 internal redeemRequestTimestamp0;
    uint256 internal redeemRequestTimestamp1;
    uint256 internal redeemRequestTimestamp2;

    uint256 internal deltaSavingsYield;

    uint256 internal aliDeltaPrimeYield;
    uint256 internal bobDeltaPrimeYield;

    AccountBalances internal aliBalances;
    AccountBalances internal bobBalances;
    AccountBalances internal takerBalances;
    AccountBalances internal vaultBalances;

    function setUp() public override {
        super.setUp();

        vm.label(ali, "ali");
        vm.label(bob, "bob");

        _setVSR(DAILY_2BP_VSR);
        _setSavingsVSR(DAILY_1BP_VSR);

        aliBalances = AccountBalances({
            account           : ali,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        bobBalances = AccountBalances({
            account           : bob,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        takerBalances = AccountBalances({
            account           : taker,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });
    }

    function test_e2e_flow1() external {
        // Vault is at capacity, so the deposit request queues instead of filling instantly

        _setCapacity(0);

        vaultState.availableCapacityValue = 0;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 1. Ali requests deposit 0

        depositRequestValue0 = 1_000_000e6;

        _requestDeposit(ali, depositRequestValue0);  // Deposit Request 0 (Queued)

        depositRequestTimestamp0 = vm.getBlockTimestamp();

        vaultState.availableLiquidAssets += depositRequestValue0 - 1;

        vaultState.depositRequests.pendingShareValue += depositRequestValue0 - 1;
        vaultState.depositRequests.length            += 1;

        vaultBalances.savingsShareValue += depositRequestValue0 - 1;

        _assertDepositRequest(0, ali, ali, depositRequestValue0 - 1, depositRequestTimestamp0);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 2. Warp 1 day, queued spUSDC earns 1bp while waiting, no drip so rho and chi are unchanged

        skip(1 days);

        deltaSavingsYield = depositRequestValue0 * 1 / 10_000;

        assertEq(deltaSavingsYield, 100e6);

        depositRequestValue0 += deltaSavingsYield;

        vaultState.availableLiquidAssets += deltaSavingsYield;

        vaultState.depositRequests.pendingShareValue += deltaSavingsYield;

        vaultBalances.savingsShareValue += deltaSavingsYield;

        _assertDepositRequest(0, ali, ali, depositRequestValue0 - 1, depositRequestTimestamp0);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 3. Ali gets filled once capacity is raised, at the current spUSDC value and chi of 1.0002

        _setCapacity(VAULT_CAPACITY);

        vaultState.availableCapacityValue = spPrime.convertToAssets(VAULT_CAPACITY);

        _processPendingDeposits(type(uint256).max);

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000199999999999999999965892e27;

        vaultState.totalAssets            += depositRequestValue0 - 2;
        vaultState.availableCapacityValue -= depositRequestValue0 - 2;

        vaultState.depositRequests.pendingShareValue  = 0;
        vaultState.depositRequests.length            -= 1;
        vaultState.depositRequests.processedCount    += 1;

        aliBalances.shareValue = depositRequestValue0 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 4. Warp 1 day, spPrime grows 2bp while spUSDC grows 1bp

        skip(1 days);

        deltaSavingsYield  = vaultState.availableLiquidAssets * 1 / 10_000;
        aliDeltaPrimeYield = aliBalances.shareValue * 2 / 10_000;

        assertEq(deltaSavingsYield,  100.01e6 - 1);
        assertEq(aliDeltaPrimeYield, 200.02e6 - 1);

        vaultState.totalAssets            += aliDeltaPrimeYield + 1;
        vaultState.availableCapacityValue += vaultState.availableCapacityValue * 2 / 10_000;
        vaultState.availableLiquidAssets  += deltaSavingsYield + 1;

        aliBalances.shareValue += aliDeltaPrimeYield + 1;

        vaultBalances.savingsShareValue += deltaSavingsYield + 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 5. Take, taker deploys half of the vault's spUSDC

        uint256 takenSavingsShareValue = vaultState.availableLiquidAssets / 2;

        _take(spUSDC.convertToShares(takenSavingsShareValue));

        vaultState.availableLiquidAssets -= takenSavingsShareValue;

        vaultBalances.savingsShareValue -= takenSavingsShareValue;

        takerBalances.savingsShareValue += takenSavingsShareValue - 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 6. Warp 1 day

        skip(1 days);

        deltaSavingsYield  = vaultState.availableLiquidAssets * 1 / 10_000;
        aliDeltaPrimeYield = aliBalances.shareValue * 2 / 10_000;

        assertEq(deltaSavingsYield,  50.01e6);
        assertEq(aliDeltaPrimeYield, 200.060002e6 + 1);

        vaultState.totalAssets            += aliDeltaPrimeYield + 1;
        vaultState.availableCapacityValue += vaultState.availableCapacityValue * 2 / 10_000;
        vaultState.availableLiquidAssets  += deltaSavingsYield + 1;

        aliBalances.shareValue += aliDeltaPrimeYield + 1;

        vaultBalances.savingsShareValue += deltaSavingsYield + 1;

        takerBalances.savingsShareValue += takerBalances.savingsShareValue * 1 / 10_000 + 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 7. Ali requests redeem of 250k USD worth of shares

        redeemRequestValue0 = 250_000e6;

        _requestRedeem(ali, spPrime.convertToShares(redeemRequestValue0));  // Redeem Request 0

        redeemRequestTimestamp0 = vm.getBlockTimestamp();

        vaultState.rho = redeemRequestTimestamp0;
        vaultState.chi = 1.000600120007999999999897636e27;

        vaultState.redeemRequests.pendingShareValue += redeemRequestValue0 - 1;
        vaultState.redeemRequests.length            += 1;

        aliBalances.shareValue -= redeemRequestValue0 - 1;

        vaultBalances.shareValue += redeemRequestValue0 - 1;

        _assertRedeemRequest(0, ali, ali, redeemRequestValue0 - 1, redeemRequestTimestamp0);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 8. Warp 1 day, the queued redeem keeps earning at the vault rate

        skip(1 days);

        deltaSavingsYield  = vaultState.availableLiquidAssets * 1 / 10_000;
        aliDeltaPrimeYield = aliBalances.shareValue * 2 / 10_000;

        redeemDeltaPrimeYield0 = redeemRequestValue0 * 2 / 10_000;

        assertEq(deltaSavingsYield,      50.015e6 + 1);
        assertEq(aliDeltaPrimeYield,     150.100015e6 + 1);
        assertEq(redeemDeltaPrimeYield0, 50e6);

        redeemRequestValue0 += redeemDeltaPrimeYield0;

        vaultState.totalAssets            += aliDeltaPrimeYield + redeemDeltaPrimeYield0;
        vaultState.availableCapacityValue += vaultState.availableCapacityValue * 2 / 10_000;
        vaultState.availableLiquidAssets  += deltaSavingsYield;

        vaultState.redeemRequests.pendingShareValue += redeemDeltaPrimeYield0;

        aliBalances.shareValue += aliDeltaPrimeYield;

        vaultBalances.shareValue        += redeemDeltaPrimeYield0;
        vaultBalances.savingsShareValue += deltaSavingsYield;

        takerBalances.savingsShareValue += takerBalances.savingsShareValue * 1 / 10_000;

        _assertRedeemRequest(0, ali, ali, redeemRequestValue0 - 1, redeemRequestTimestamp0);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 9. Ali redeems, the request is filled from the spUSDC still held by the vault

        _processPendingRedeems();

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000800240032001599999863487e27;

        vaultState.totalAssets            -= redeemRequestValue0 - 1;
        vaultState.availableCapacityValue += redeemRequestValue0;
        vaultState.availableLiquidAssets  -= redeemRequestValue0 - 2;

        vaultState.redeemRequests.pendingShareValue  = 0;
        vaultState.redeemRequests.length            -= 1;
        vaultState.redeemRequests.processedCount    += 1;

        aliBalances.assets += redeemRequestValue0 - 2;

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue -= redeemRequestValue0 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 10. Warp 1 day

        skip(1 days);

        deltaSavingsYield  = vaultState.availableLiquidAssets * 1 / 10_000;
        aliDeltaPrimeYield = aliBalances.shareValue * 2 / 10_000;

        assertEq(deltaSavingsYield,  25.015002e6 + 1);
        assertEq(aliDeltaPrimeYield, 150.130035e6 + 1);

        vaultState.totalAssets            += aliDeltaPrimeYield;
        vaultState.availableCapacityValue += vaultState.availableCapacityValue * 2 / 10_000;
        vaultState.availableLiquidAssets  += deltaSavingsYield;

        aliBalances.shareValue += aliDeltaPrimeYield;

        vaultBalances.savingsShareValue += deltaSavingsYield;

        takerBalances.savingsShareValue += takerBalances.savingsShareValue * 1 / 10_000;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);
    }

    function test_e2e_flow2() external {
        // Vault is at capacity, so deposit requests queue instead of filling instantly

        _setCapacity(0);

        vaultState.availableCapacityValue = 0;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 1. Ali requests deposit 0

        depositRequestValue0 = 1_000_000e6;

        _requestDeposit(ali, depositRequestValue0);  // Deposit Request 0 (Queued)

        depositRequestTimestamp0 = vm.getBlockTimestamp();

        vaultState.availableLiquidAssets += depositRequestValue0 - 1;

        vaultState.depositRequests.pendingShareValue += depositRequestValue0 - 1;
        vaultState.depositRequests.length            += 1;

        vaultBalances.savingsShareValue += depositRequestValue0 - 1;

        _assertDepositRequest(0, ali, ali, depositRequestValue0 - 1, depositRequestTimestamp0);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 2. Warp 1 day, queued spUSDC earns 1bp while waiting, no drip so rho and chi are unchanged

        skip(1 days);

        deltaSavingsYield = depositRequestValue0 * 1 / 10_000;

        assertEq(deltaSavingsYield, 100e6);

        depositRequestValue0 += deltaSavingsYield;

        vaultState.availableLiquidAssets += deltaSavingsYield;

        vaultState.depositRequests.pendingShareValue += deltaSavingsYield;

        vaultBalances.savingsShareValue += deltaSavingsYield;

        _assertDepositRequest(0, ali, ali, depositRequestValue0 - 1, depositRequestTimestamp0);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 3. Taker takes all of the vault's spUSDC, which backs deposit 0

        uint256 takenSavingsShareValue = vaultState.availableLiquidAssets;

        _take(spUSDC.convertToShares(takenSavingsShareValue));

        vaultState.availableLiquidAssets -= takenSavingsShareValue - 1;

        vaultBalances.savingsShareValue -= takenSavingsShareValue - 1;

        takerBalances.savingsShareValue += takenSavingsShareValue - 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 4. Ali requests deposit 1, which drips chi to 1.0002

        depositRequestValue1 = 2_000_000e6;

        _requestDeposit(ali, depositRequestValue1);  // Deposit Request 1 (Queued)

        depositRequestTimestamp1 = vm.getBlockTimestamp();

        vaultState.rho = depositRequestTimestamp1;
        vaultState.chi = 1.000199999999999999999965892e27;

        vaultState.availableLiquidAssets += depositRequestValue1 - 1;

        vaultState.depositRequests.pendingShareValue += depositRequestValue1 - 1;
        vaultState.depositRequests.length            += 1;

        vaultBalances.savingsShareValue += depositRequestValue1 - 1;

        _assertDepositRequest(0, ali, ali, depositRequestValue0 - 1, depositRequestTimestamp0);
        _assertDepositRequest(1, ali, ali, depositRequestValue1 - 1, depositRequestTimestamp1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 5. Warp 1 day, queued deposits keep their spUSDC value growth even though deposit 0 shares were taken

        skip(1 days);

        depositDeltaSavingsYield0 = depositRequestValue0 * 1 / 10_000;
        depositDeltaSavingsYield1 = depositRequestValue1 * 1 / 10_000;

        assertEq(depositDeltaSavingsYield0, 100.01e6);
        assertEq(depositDeltaSavingsYield1, 200e6);

        depositRequestValue0 += depositDeltaSavingsYield0;
        depositRequestValue1 += depositDeltaSavingsYield1;

        vaultState.availableLiquidAssets += depositDeltaSavingsYield1;  // assets from deposit 0 were taken

        vaultState.depositRequests.pendingShareValue += depositDeltaSavingsYield0 + depositDeltaSavingsYield1;

        vaultBalances.savingsShareValue += depositDeltaSavingsYield1;  // assets from deposit 0 were taken

        takerBalances.savingsShareValue += takerBalances.savingsShareValue * 1 / 10_000 + 1;

        _assertDepositRequest(0, ali, ali, depositRequestValue0 - 1, depositRequestTimestamp0);
        _assertDepositRequest(1, ali, ali, depositRequestValue1 - 1, depositRequestTimestamp1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 6. Ali gets filled for deposit 0 once capacity is raised, at chi of 1.0002^2

        _setCapacity(VAULT_CAPACITY);

        vaultState.availableCapacityValue = spPrime.convertToAssets(VAULT_CAPACITY);

        _processPendingDeposits(1);  // Deposit Request 0 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000400039999999999999931770e27;

        vaultState.totalAssets            += depositRequestValue0 - 2;
        vaultState.availableCapacityValue -= depositRequestValue0 - 2;

        vaultState.depositRequests.pendingShareValue -= depositRequestValue0 - 1;
        vaultState.depositRequests.length            -= 1;
        vaultState.depositRequests.processedCount    += 1;

        aliBalances.shareValue = depositRequestValue0 - 2;

        _assertDepositRequest(1, ali, ali, depositRequestValue1 - 1, depositRequestTimestamp1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 7. Warp 1 day, spPrime grows 2bp while spUSDC grows 1bp

        skip(1 days);

        depositDeltaSavingsYield1 = depositRequestValue1 * 1 / 10_000;
        deltaSavingsYield         = vaultState.availableLiquidAssets * 1 / 10_000;
        aliDeltaPrimeYield        = aliBalances.shareValue * 2 / 10_000;

        assertEq(depositDeltaSavingsYield1, 200.02e6);
        assertEq(deltaSavingsYield,         200.02e6);
        assertEq(aliDeltaPrimeYield,        200.04e6 + 1);

        depositRequestValue1 += depositDeltaSavingsYield1;

        vaultState.totalAssets            += aliDeltaPrimeYield + 1;
        vaultState.availableCapacityValue += vaultState.availableCapacityValue * 2 / 10_000;
        vaultState.availableLiquidAssets  += deltaSavingsYield;

        vaultState.depositRequests.pendingShareValue += depositDeltaSavingsYield1;

        aliBalances.shareValue += aliDeltaPrimeYield + 1;

        vaultBalances.savingsShareValue += deltaSavingsYield;

        takerBalances.savingsShareValue += takerBalances.savingsShareValue * 1 / 10_000 + 1;

        _assertDepositRequest(1, ali, ali, depositRequestValue1 - 1, depositRequestTimestamp1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 8. Taker takes all of the vault's spUSDC, which backs deposit 1

        takenSavingsShareValue = vaultState.availableLiquidAssets;

        _take(spUSDC.convertToShares(takenSavingsShareValue));  // Deposit Request 1 savings shares

        vaultState.availableLiquidAssets -= takenSavingsShareValue - 1;

        vaultBalances.savingsShareValue -= takenSavingsShareValue - 1;

        takerBalances.savingsShareValue += takenSavingsShareValue - 1;

        _assertDepositRequest(1, ali, ali, depositRequestValue1 - 1, depositRequestTimestamp1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 9. Warp 1 day

        skip(1 days);

        depositDeltaSavingsYield1 = depositRequestValue1 * 1 / 10_000;
        deltaSavingsYield         = vaultState.availableLiquidAssets * 1 / 10_000;
        aliDeltaPrimeYield        = aliBalances.shareValue * 2 / 10_000;

        assertEq(depositDeltaSavingsYield1, 200.040002e6);
        assertEq(deltaSavingsYield,         0);
        assertEq(aliDeltaPrimeYield,        200.08001e6);

        depositRequestValue1 += depositDeltaSavingsYield1;

        vaultState.totalAssets            += aliDeltaPrimeYield;
        vaultState.availableCapacityValue += vaultState.availableCapacityValue * 2 / 10_000;
        vaultState.availableLiquidAssets  += deltaSavingsYield;

        vaultState.depositRequests.pendingShareValue += depositDeltaSavingsYield1;

        aliBalances.shareValue += aliDeltaPrimeYield;

        vaultBalances.savingsShareValue += deltaSavingsYield;

        takerBalances.savingsShareValue += takerBalances.savingsShareValue * 1 / 10_000 + 1;

        _assertDepositRequest(1, ali, ali, depositRequestValue1 - 1, depositRequestTimestamp1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 10. Ali gets filled for deposit 1 at chi of 1.0002^4

        _processPendingDeposits(1);  // Deposit Request 1 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000800240032001599999863487e27;

        vaultState.totalAssets            += depositRequestValue1 - 1;
        vaultState.availableCapacityValue -= depositRequestValue1 - 1;

        vaultState.depositRequests.pendingShareValue -= depositRequestValue1 - 1;
        vaultState.depositRequests.length            -= 1;
        vaultState.depositRequests.processedCount    += 1;

        aliBalances.shareValue += depositRequestValue1 - 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 11. Warp 1 day

        skip(1 days);

        aliDeltaPrimeYield = aliBalances.shareValue * 2 / 10_000;

        assertEq(aliDeltaPrimeYield, 600.240038e6);

        vaultState.totalAssets            += aliDeltaPrimeYield;
        vaultState.availableCapacityValue += vaultState.availableCapacityValue * 2 / 10_000;

        aliBalances.shareValue += aliDeltaPrimeYield;

        takerBalances.savingsShareValue += takerBalances.savingsShareValue * 1 / 10_000;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 12. Ali requests redeem

        redeemRequestValue0 = 1_000_000e6;

        _requestRedeem(ali, spPrime.convertToShares(redeemRequestValue0));  // Redeem Request 0

        redeemRequestTimestamp0 = vm.getBlockTimestamp();

        vaultState.rho = redeemRequestTimestamp0;
        vaultState.chi = 1.001000400080008000319829324e27;

        vaultState.redeemRequests.pendingShareValue += redeemRequestValue0 - 1;
        vaultState.redeemRequests.length            += 1;

        aliBalances.shareValue -= redeemRequestValue0 - 1;

        vaultBalances.shareValue += redeemRequestValue0 - 1;

        _assertRedeemRequest(0, ali, ali, redeemRequestValue0 - 1, redeemRequestTimestamp0);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 13. Warp 1 day, the queued redeem keeps earning at the vault rate

        skip(1 days);

        aliDeltaPrimeYield     = aliBalances.shareValue * 2 / 10_000;
        redeemDeltaPrimeYield0 = redeemRequestValue0 * 2 / 10_000;

        assertEq(aliDeltaPrimeYield,     400.360086e6);
        assertEq(redeemDeltaPrimeYield0, 200e6);

        redeemRequestValue0 += redeemDeltaPrimeYield0;

        vaultState.totalAssets            += aliDeltaPrimeYield + redeemDeltaPrimeYield0;
        vaultState.availableCapacityValue += vaultState.availableCapacityValue * 2 / 10_000 + 1;

        vaultState.redeemRequests.pendingShareValue += redeemDeltaPrimeYield0;

        aliBalances.shareValue += aliDeltaPrimeYield;

        vaultBalances.shareValue        += redeemDeltaPrimeYield0;
        vaultBalances.savingsShareValue += deltaSavingsYield;

        takerBalances.savingsShareValue += takerBalances.savingsShareValue * 1 / 10_000;

        _assertRedeemRequest(0, ali, ali, redeemRequestValue0 - 1, redeemRequestTimestamp0);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 14. Taker returns enough spUSDC to cover redeem request 0

        _transferSavingsShares(taker, address(spPrime), spUSDC.convertToShares(redeemRequestValue0));

        vaultState.availableLiquidAssets += redeemRequestValue0 - 1;

        vaultBalances.savingsShareValue += redeemRequestValue0 - 1;

        takerBalances.savingsShareValue -= redeemRequestValue0 - 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 15. Ali gets filled for redeem request 0

        _processPendingRedeems();  // Redeem Request 0 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.001200600160024001919859147e27;

        vaultState.totalAssets            -= redeemRequestValue0 - 1;
        vaultState.availableCapacityValue += redeemRequestValue0;
        vaultState.availableLiquidAssets  -= redeemRequestValue0 - 2;

        vaultState.redeemRequests.pendingShareValue  = 0;
        vaultState.redeemRequests.length            -= 1;
        vaultState.redeemRequests.processedCount    += 1;

        aliBalances.assets += redeemRequestValue0 - 2;

        vaultBalances.shareValue         = 0;
        vaultBalances.savingsShareValue -= redeemRequestValue0 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 16. Ali requests redeem of all remaining shares

        redeemRequestValue1 = spPrime.convertToAssets(spPrime.balanceOf(ali));

        _requestRedeem(ali, spPrime.balanceOf(ali));  // Redeem Request 1

        redeemRequestTimestamp1 = vm.getBlockTimestamp();

        vaultState.redeemRequests.pendingShareValue += redeemRequestValue1;
        vaultState.redeemRequests.length            += 1;

        aliBalances.shareValue = 0;

        vaultBalances.shareValue += redeemRequestValue1;

        _assertRedeemRequest(1, ali, ali, redeemRequestValue1, redeemRequestTimestamp1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 17. Warp 1 day, the queued redeem keeps earning at the vault rate

        skip(1 days);

        redeemDeltaPrimeYield1 = redeemRequestValue1 * 2 / 10_000;

        assertEq(redeemDeltaPrimeYield1, 400.440158e6);

        redeemRequestValue1 += redeemDeltaPrimeYield1;

        vaultState.totalAssets            += redeemDeltaPrimeYield1;
        vaultState.availableCapacityValue += vaultState.availableCapacityValue * 2 / 10_000;

        vaultState.redeemRequests.pendingShareValue += redeemDeltaPrimeYield1;

        vaultBalances.shareValue += redeemDeltaPrimeYield1;

        takerBalances.savingsShareValue += takerBalances.savingsShareValue * 1 / 10_000;

        _assertRedeemRequest(1, ali, ali, redeemRequestValue1, redeemRequestTimestamp1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 18. Taker returns enough spUSDC to cover redeem request 1, the taker's spUSDC grew 1bp a day while
        //     the redeem is owed 2bp a day, so the taker tops up the difference before returning it

        deal(address(spUSDC), taker, spUSDC.convertToShares(redeemRequestValue1));

        _transferSavingsShares(taker, address(spPrime), spUSDC.convertToShares(redeemRequestValue1));

        vaultState.availableLiquidAssets += redeemRequestValue1 - 1;

        vaultBalances.savingsShareValue += redeemRequestValue1 - 1;

        takerBalances.savingsShareValue = 0;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 19. User gets filled for redeem request 1, the vault has no supply left

        _processPendingRedeems();  // Redeem Request 1 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.001400840280056006720208969e27;

        vaultState.totalAssets             = 0;
        vaultState.availableCapacityValue += redeemRequestValue1;
        vaultState.availableLiquidAssets  -= redeemRequestValue1 - 1;

        vaultState.redeemRequests.pendingShareValue  = 0;
        vaultState.redeemRequests.length            -= 1;
        vaultState.redeemRequests.processedCount    += 1;

        aliBalances.assets += redeemRequestValue1 - 1;

        vaultBalances.shareValue         = 0;
        vaultBalances.savingsShareValue -= redeemRequestValue1 - 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);
    }

    function test_e2e_lossWithPendingQueues() external {
        // Vault capacity only fits Ali's deposit, so Bob's deposit queues

        _setCapacity(1_000_000e6);

        vaultState.availableCapacityValue = 1_000_000e6;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 1. Ali requests deposit 0, filled instantly

        depositRequestValue0 = 1_000_000e6;

        _requestDeposit(ali, depositRequestValue0);  // Deposit Request 0 (Filled instantly)

        vaultState.totalAssets            += depositRequestValue0 - 1;
        vaultState.availableCapacityValue -= depositRequestValue0 - 1;
        vaultState.availableLiquidAssets  += depositRequestValue0 - 1;

        vaultState.depositRequests.processedCount += 1;

        aliBalances.shareValue += depositRequestValue0 - 1;

        vaultBalances.savingsShareValue += depositRequestValue0 - 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 2. Warp 1 day, spPrime grows 2bp while spUSDC grows 1bp

        skip(1 days);

        deltaSavingsYield  = vaultState.availableLiquidAssets * 1 / 10_000;
        aliDeltaPrimeYield = aliBalances.shareValue * 2 / 10_000;

        assertEq(deltaSavingsYield,  100e6 - 1);
        assertEq(aliDeltaPrimeYield, 200e6 - 1);

        vaultState.totalAssets            += aliDeltaPrimeYield;
        vaultState.availableCapacityValue += vaultState.availableCapacityValue * 2 / 10_000;
        vaultState.availableLiquidAssets  += deltaSavingsYield + 1;

        aliBalances.shareValue += aliDeltaPrimeYield;

        vaultBalances.savingsShareValue += deltaSavingsYield + 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 3. Bob requests deposit 1, queued because the vault is at capacity

        depositRequestValue1 = 2_000_000e6;

        _requestDeposit(bob, depositRequestValue1);  // Deposit Request 1 (Queued)

        depositRequestTimestamp1 = vm.getBlockTimestamp();

        vaultState.rho = depositRequestTimestamp1;
        vaultState.chi = 1.000199999999999999999965892e27;

        vaultState.availableLiquidAssets += depositRequestValue1 - 1;

        vaultState.depositRequests.pendingShareValue += depositRequestValue1 - 1;
        vaultState.depositRequests.length            += 1;

        vaultBalances.savingsShareValue += depositRequestValue1 - 1;

        _assertDepositRequest(1, bob, bob, depositRequestValue1 - 1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 4. Taker takes all of the vault's spUSDC, including the shares backing Bob's queued deposit

        uint256 takenSavingsShareValue = 2_000_100e6;

        _take(spUSDC.convertToShares(takenSavingsShareValue));

        vaultState.availableLiquidAssets -= takenSavingsShareValue - 1;

        vaultBalances.savingsShareValue -= takenSavingsShareValue - 1;

        takerBalances.savingsShareValue += takenSavingsShareValue - 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 5. Warp 1 day, spPrime grows 2bp while Bob's queued deposit grows at the 1bp spUSDC rate

        skip(1 days);

        deltaSavingsYield         = vaultState.availableLiquidAssets * 1 / 10_000;
        aliDeltaPrimeYield        = aliBalances.shareValue * 2 / 10_000;
        depositDeltaSavingsYield1 = depositRequestValue1 * 1 / 10_000;

        assertEq(deltaSavingsYield,         100e6 - 1);
        assertEq(aliDeltaPrimeYield,        200.04e6 - 1);
        assertEq(depositDeltaSavingsYield1, 200e6);

        depositRequestValue1 += depositDeltaSavingsYield1;

        vaultState.totalAssets           += aliDeltaPrimeYield + 1;
        vaultState.availableLiquidAssets += deltaSavingsYield + 1;

        vaultState.depositRequests.pendingShareValue += depositDeltaSavingsYield1;

        aliBalances.shareValue += aliDeltaPrimeYield + 1;

        vaultBalances.savingsShareValue += deltaSavingsYield + 1;

        takerBalances.savingsShareValue += takerBalances.savingsShareValue * 1 / 10_000 + 1;

        _assertDepositRequest(1, bob, bob, depositRequestValue1 - 1, depositRequestTimestamp1);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 6. Ali requests redeem of half of the shares, queued because there is no liquidity

        redeemRequestValue0 = 500_000e6;

        _requestRedeem(ali, spPrime.convertToShares(redeemRequestValue0));  // Redeem Request 0

        redeemRequestTimestamp0 = vm.getBlockTimestamp();

        vaultState.rho = redeemRequestTimestamp0;
        vaultState.chi = 1.000400039999999999999931770e27;

        vaultState.redeemRequests.pendingShareValue += redeemRequestValue0 - 1;
        vaultState.redeemRequests.length            += 1;

        aliBalances.shareValue -= redeemRequestValue0 - 1;

        vaultBalances.shareValue += redeemRequestValue0 - 1;

        _assertRedeemRequest(0, ali, ali, redeemRequestValue0 - 1, redeemRequestTimestamp0);

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

        _impair(vaultState.totalAssets / 10);

        redeemRequestValue0 -= redeemRequestValue0 / 10;

        vaultState.chi = 0.900360035999900360035999900e27;

        vaultState.totalAssets            -= (vaultState.totalAssets / 10) + 1;
        vaultState.availableCapacityValue  = 0;

        vaultState.redeemRequests.pendingShareValue -= vaultState.redeemRequests.pendingShareValue / 10 + 1;

        aliBalances.shareValue -= aliBalances.shareValue / 10 + 1;

        vaultBalances.shareValue -= vaultBalances.shareValue / 10 + 1;

        _assertRedeemRequest(0, ali, ali, redeemRequestValue0 - 1, redeemRequestTimestamp0);

        // Bob's pending deposit is held in spUSDC, so its value is unchanged by the loss
        _assertDepositRequest(1, bob, bob, depositRequestValue1 - 1, depositRequestTimestamp1);

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

        vaultState.availableCapacityValue = spPrime.convertToAssets(VAULT_CAPACITY - spPrime.totalSupply());

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 11. Bob gets filled for deposit 1 at the post-loss chi, so Bob gets more shares than Ali did for
        //     the same 1m deposit because each share is cheaper, Ali's value is unchanged by Bob's mint

        _processPendingDeposits(1);  // Deposit Request 1 (Filled)

        vaultState.totalAssets            += depositRequestValue1 - 1;
        vaultState.availableCapacityValue -= depositRequestValue1 - 1;

        vaultState.depositRequests.pendingShareValue -= depositRequestValue1 - 1;
        vaultState.depositRequests.length            -= 1;
        vaultState.depositRequests.processedCount    += 1;

        bobBalances.shareValue += depositRequestValue1 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 12. Warp 1 day, the queued redeem keeps earning at the vault rate
        skip(1 days);

        deltaSavingsYield      = vaultState.availableLiquidAssets * 1 / 10_000;
        aliDeltaPrimeYield     = aliBalances.shareValue * 2 / 10_000;
        bobDeltaPrimeYield     = bobBalances.shareValue * 2 / 10_000;
        redeemDeltaPrimeYield0 = redeemRequestValue0 * 2 / 10_000;

        assertEq(deltaSavingsYield,      100.01e6 - 1);
        assertEq(aliDeltaPrimeYield,     90.072007e6);
        assertEq(bobDeltaPrimeYield,     400.04e6 - 1);
        assertEq(redeemDeltaPrimeYield0, 90e6);

        redeemRequestValue0 += redeemDeltaPrimeYield0;

        vaultState.totalAssets            += aliDeltaPrimeYield + bobDeltaPrimeYield + redeemDeltaPrimeYield0 + 2;
        vaultState.availableCapacityValue += vaultState.availableCapacityValue * 2 / 10_000;
        vaultState.availableLiquidAssets  += deltaSavingsYield + 1;

        vaultState.redeemRequests.pendingShareValue += redeemDeltaPrimeYield0;

        aliBalances.shareValue += aliDeltaPrimeYield;
        bobBalances.shareValue += bobDeltaPrimeYield + 1;

        vaultBalances.shareValue        += redeemDeltaPrimeYield0;
        vaultBalances.savingsShareValue += deltaSavingsYield + 1;

        takerBalances.savingsShareValue += takerBalances.savingsShareValue * 1 / 10_000 + 1;

        _assertRedeemRequest(0, ali, ali, redeemRequestValue0 - 1, redeemRequestTimestamp0);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 13. Taker returns enough spUSDC to cover redeem request 0

        _transferSavingsShares(taker, address(spPrime), spUSDC.convertToShares(redeemRequestValue0));

        vaultState.availableLiquidAssets += redeemRequestValue0 - 1;

        vaultBalances.savingsShareValue += redeemRequestValue0 - 1;

        takerBalances.savingsShareValue -= redeemRequestValue0 - 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 14. Ali gets filled for redeem request 0 at the post-loss value

        _processPendingRedeems();  // Redeem Request 0 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 0.900540108007100340107976390e27;

        vaultState.totalAssets            -= redeemRequestValue0;
        vaultState.availableCapacityValue += redeemRequestValue0;
        vaultState.availableLiquidAssets  -= redeemRequestValue0 - 2;

        vaultState.redeemRequests.pendingShareValue  = 0;
        vaultState.redeemRequests.length            -= 1;
        vaultState.redeemRequests.processedCount    += 1;

        aliBalances.assets += redeemRequestValue0 - 2;

        vaultBalances.shareValue         = 0;
        vaultBalances.savingsShareValue -= redeemRequestValue0 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 15. Ali and Bob request redeem of all their remaining shares

        redeemRequestValue1 = spPrime.convertToAssets(spPrime.balanceOf(ali));
        redeemRequestValue2 = spPrime.convertToAssets(spPrime.balanceOf(bob));

        _requestRedeem(ali, spPrime.balanceOf(ali));  // Redeem Request 1
        _requestRedeem(bob, spPrime.balanceOf(bob));  // Redeem Request 2

        redeemRequestTimestamp1 = vm.getBlockTimestamp();
        redeemRequestTimestamp2 = vm.getBlockTimestamp();

        vaultState.redeemRequests.pendingShareValue += redeemRequestValue1 + redeemRequestValue2 + 1;
        vaultState.redeemRequests.length            += 2;

        aliBalances.shareValue = 0;

        bobBalances.shareValue = 0;

        vaultBalances.shareValue += redeemRequestValue1 + redeemRequestValue2 + 1;

        _assertRedeemRequest(1, ali, ali, redeemRequestValue1, redeemRequestTimestamp1);
        _assertRedeemRequest(2, bob, bob, redeemRequestValue2, redeemRequestTimestamp2);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 16. Warp 1 day, the queued redeems keep earning at the vault rate

        skip(1 days);

        deltaSavingsYield      = vaultState.availableLiquidAssets * 1 / 10_000;
        redeemDeltaPrimeYield1 = redeemRequestValue1 * 2 / 10_000;
        redeemDeltaPrimeYield2 = redeemRequestValue2 * 2 / 10_000;

        assertEq(deltaSavingsYield,      100.02e6 + 1);
        assertEq(redeemDeltaPrimeYield1, 90.09002e6 + 1);
        assertEq(redeemDeltaPrimeYield2, 400.120007e6);

        redeemRequestValue1 += redeemDeltaPrimeYield1;
        redeemRequestValue2 += redeemDeltaPrimeYield2;

        vaultState.totalAssets            += redeemDeltaPrimeYield1 + redeemDeltaPrimeYield2 + 1;
        vaultState.availableCapacityValue += vaultState.availableCapacityValue * 2 / 10_000 + 1;
        vaultState.availableLiquidAssets  += deltaSavingsYield;

        vaultState.redeemRequests.pendingShareValue += redeemDeltaPrimeYield1 + redeemDeltaPrimeYield2 + 1;

        vaultBalances.shareValue        += redeemDeltaPrimeYield1 + redeemDeltaPrimeYield2 + 1;
        vaultBalances.savingsShareValue += deltaSavingsYield;

        takerBalances.savingsShareValue += takerBalances.savingsShareValue * 1 / 10_000;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 17. Taker returns enough spUSDC to cover redeem requests 1 and 2

        uint256 returnValue = redeemRequestValue1 + redeemRequestValue2 - vaultState.availableLiquidAssets + 10;

        deal(address(spUSDC), taker, spUSDC.convertToShares(returnValue));

        _transferSavingsShares(taker, address(spPrime), spUSDC.convertToShares(returnValue));

        vaultState.availableLiquidAssets += returnValue - 1;

        vaultBalances.savingsShareValue += returnValue - 1;

        takerBalances.savingsShareValue = 0;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 18. Ali and Bob get filled for redeem requests 1 and 2.

        _processPendingRedeems();  // Redeem Requests 1 and 2 (Filled)

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 0.900720216028701760175967269e27;

        vaultState.totalAssets             = 0;
        vaultState.availableCapacityValue += redeemRequestValue1 + redeemRequestValue2 + 3;
        vaultState.availableLiquidAssets   = 9;

        vaultState.redeemRequests.pendingShareValue  = 0;
        vaultState.redeemRequests.length            -= 2;
        vaultState.redeemRequests.processedCount    += 2;

        aliBalances.assets += redeemRequestValue1 - 1;
        bobBalances.assets += redeemRequestValue2;

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 9;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);
    }

}
