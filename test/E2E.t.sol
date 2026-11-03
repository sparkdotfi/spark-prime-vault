// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase } from "./TestBase.t.sol";

contract E2ETests is TestBase {

    uint256 internal constant DAILY_1BP_VSR = 1.000000001157349541564501380e27;  // 1.0001 per day
    uint256 internal constant DAILY_2BP_VSR = 1.000000002314583366871550052e27;  // 1.0002 per day

    address internal ali = makeAddr("ali");

    function setUp() public override {
        super.setUp();

        vm.label(ali, "ali");

        _setVSR(DAILY_2BP_VSR);
        _setSavingsVSR(DAILY_1BP_VSR);
    }

    function test_e2e_flow1() external {
        AccountBalances memory aliBalances = AccountBalances({
            account           : ali,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        AccountBalances memory takerBalances = AccountBalances({
            account           : taker,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        // Vault is at capacity, so the deposit request queues instead of filling instantly

        _setCapacity(0);

        vaultState.availableCapacityValue = 0;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 1. User requests deposit

        _requestDeposit(ali, 1_000_000e6);  // Deposit Request 0 (Queued)

        uint256 aliEarmarkedAssets = 1_000_000e6;
        uint256 depositTimestamp   = vm.getBlockTimestamp();

        vaultState.availableLiquidAssets += aliEarmarkedAssets - 1;

        vaultState.depositRequests.pendingShareValue += aliEarmarkedAssets - 1;
        vaultState.depositRequests.length            += 1;

        vaultBalances.savingsShareValue += aliEarmarkedAssets - 1;

        _assertDepositRequest(0, ali, ali, aliEarmarkedAssets - 1, depositTimestamp);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 2. Warp 1 day, queued spUSDC earns 1bp while waiting, no drip so rho and chi are unchanged

        skip(1 days);

        uint256 deltaSavingsYield = vaultState.availableLiquidAssets * 1 / 10_000;

        assertEq(deltaSavingsYield, 100e6 - 1);

        aliEarmarkedAssets += deltaSavingsYield;

        vaultState.availableLiquidAssets += deltaSavingsYield + 1;

        vaultState.depositRequests.pendingShareValue += deltaSavingsYield + 1;

        vaultBalances.savingsShareValue += deltaSavingsYield + 1;

        _assertDepositRequest(0, ali, ali, aliEarmarkedAssets, depositTimestamp);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 3. User gets filled once capacity is raised, at the current spUSDC value and chi of 1.0002

        _setCapacity(VAULT_CAPACITY);

        vaultState.availableCapacityValue = spPrime.convertToAssets(VAULT_CAPACITY);

        _processPendingDeposits(type(uint256).max);

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000199999999999999999965892e27;

        vaultState.totalAssets            += aliEarmarkedAssets - 1;
        vaultState.availableCapacityValue -= aliEarmarkedAssets - 1;

        vaultState.depositRequests.pendingShareValue  = 0;
        vaultState.depositRequests.length            -= 1;
        vaultState.depositRequests.processedCount    += 1;

        aliBalances.shareValue = aliEarmarkedAssets - 1;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 4. Warp 1 day, spPrime grows 2bp while spUSDC grows 1bp

        skip(1 days);

        deltaSavingsYield = vaultState.availableLiquidAssets * 1 / 10_000;

        uint256 aliDeltaPrimeYield = aliEarmarkedAssets * 2 / 10_000;

        assertEq(deltaSavingsYield,  100.01e6 - 1);
        assertEq(aliDeltaPrimeYield, 200.02e6 - 1);

        aliEarmarkedAssets += aliDeltaPrimeYield;

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

        vm.startPrank(taker);
        spPrime.take(spUSDC.convertToShares(takenSavingsShareValue));
        vm.stopPrank();

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
        aliDeltaPrimeYield = aliEarmarkedAssets * 2 / 10_000;

        assertEq(deltaSavingsYield,  50.01e6);
        assertEq(aliDeltaPrimeYield, 200.060002e6 + 1);

        aliEarmarkedAssets += aliDeltaPrimeYield;

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

        // 7. User requests redeem of 250k USD worth of shares

        uint256 redeemValue           = 250_000e6;
        uint256 requestedRedeemShares = spPrime.convertToShares(redeemValue);

        _requestRedeem(ali, requestedRedeemShares);  // Redeem Request 0

        uint256 redeemTimestamp = vm.getBlockTimestamp();

        vaultState.rho = redeemTimestamp;
        vaultState.chi = 1.000600120007999999999897636e27;

        vaultState.redeemRequests.pendingShareValue += redeemValue - 1;
        vaultState.redeemRequests.length            += 1;

        aliBalances.shareValue -= redeemValue - 1;

        vaultBalances.shareValue += redeemValue - 1;

        _assertRedeemRequest(0, ali, ali, redeemValue - 1, redeemTimestamp);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 8. Warp 1 day, the queued redeem keeps earning at the vault rate

        skip(1 days);

        deltaSavingsYield  = vaultState.availableLiquidAssets * 1 / 10_000;
        aliDeltaPrimeYield = (aliEarmarkedAssets - redeemValue) * 2 / 10_000;

        uint256 redeemRequestPrimeYield = redeemValue * 2 / 10_000;

        assertEq(deltaSavingsYield,       50.015e6 + 1);
        assertEq(aliDeltaPrimeYield,      150.100015e6 + 1);
        assertEq(redeemRequestPrimeYield, 50e6);

        aliEarmarkedAssets += aliDeltaPrimeYield + redeemRequestPrimeYield;

        redeemValue += redeemRequestPrimeYield;

        vaultState.totalAssets            += aliDeltaPrimeYield + redeemRequestPrimeYield;
        vaultState.availableCapacityValue += vaultState.availableCapacityValue * 2 / 10_000;
        vaultState.availableLiquidAssets  += deltaSavingsYield;

        vaultState.redeemRequests.pendingShareValue += redeemRequestPrimeYield;

        aliBalances.shareValue += aliDeltaPrimeYield;

        vaultBalances.shareValue        += redeemRequestPrimeYield;
        vaultBalances.savingsShareValue += deltaSavingsYield;

        takerBalances.savingsShareValue += takerBalances.savingsShareValue * 1 / 10_000;

        _assertRedeemRequest(0, ali, ali, redeemValue - 1, redeemTimestamp);

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 9. User redeems, the request is filled from the spUSDC still held by the vault

        _processPendingRedeems();

        aliEarmarkedAssets -= redeemValue;

        vaultState.rho = vm.getBlockTimestamp();
        vaultState.chi = 1.000800240032001599999863487e27;

        vaultState.totalAssets            -= redeemValue - 1;
        vaultState.availableCapacityValue += redeemValue;
        vaultState.availableLiquidAssets  -= redeemValue - 2;

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.processedCount    = 1;

        aliBalances.assets += redeemValue - 2;

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue -= redeemValue - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(vaultBalances);
        _assertAccountBalances(takerBalances);

        // 10. Warp 1 day

        skip(1 days);

        deltaSavingsYield  = vaultState.availableLiquidAssets * 1 / 10_000;
        aliDeltaPrimeYield = aliEarmarkedAssets * 2 / 10_000;

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

}
