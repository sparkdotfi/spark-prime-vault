// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { console2 } from "../lib/forge-std/src/console2.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

import { TestBase } from "./TestBase.t.sol";

/**
 * Measures the deposit-queue griefing vectors documented in `docs/DEPOSIT_QUEUE_GRIEFING.md`.
 *
 * The attacker queues a live head, then repeats deposit + full cancellation behind it so that
 * the cancellation cleanup (which stops at the first live entry) never removes the resulting
 * zero-share tombstones. Once the head is filled, the run of tombstones sits at the front of the
 * deposit queue and every unbounded walk over it (any `requestDepositCancellation`, any instant
 * fill in `requestDeposit`) pays ~2.4k gas per tombstone.
 *
 * The gas figures logged by these tests feed the economic model in the document. They are
 * measured on the fork in `TestBase` at the pinned block, so they move slightly with the spUSDC
 * exchange rate and with any change to the contract, and the document should be refreshed when
 * the contract changes.
 */
contract DepositQueueGriefingTests is TestBase {

    uint256 internal constant TX_GAS_CAP = 16_777_216;  // EIP-7825 per-transaction gas cap (Osaka)

    address internal attacker = makeAddr("attacker");
    address internal victim   = makeAddr("victim");
    address internal newUser  = makeAddr("newUser");

    // Smallest deposit whose spUSDC shares reach minDepositCancellation, so it can be cancelled in full.
    uint256 internal minCancellableDeposit;

    function setUp() public override {
        super.setUp();

        minCancellableDeposit = spUSDC.convertToAssets(MINIMUM_DEPOSIT_CANCELLATION) + 1;

        assertGe(minCancellableDeposit, MINIMUM_DEPOSIT);
        assertGe(spUSDC.convertToShares(minCancellableDeposit), MINIMUM_DEPOSIT_CANCELLATION);
    }

    /**********************************************************************************************/
    /*** Scenario helpers                                                                       ***/
    /**********************************************************************************************/

    // A test runs as a single transaction, so storage touched while building a scenario stays warm.
    // Real users pay cold access, so every measured call is preceded by a reset of the access lists.
    function _coolAll() internal {
        vm.cool(address(spPrime));
        vm.cool(address(spUSDC));
        vm.cool(address(usdc));
    }

    // Zero capacity so the attacker's first deposit is queued as a live head, then `n` deposit +
    // full cancellation pairs behind it. Returns the attacker's gas on the request calls only
    // (funding, approvals and the getter used to read the share amount are excluded).
    function _buildTombstoneRun(uint256 n) internal returns (uint256 headId, uint256 attackerGas) {
        _setCapacity(0);

        headId = _requestDeposit(attacker, minCancellableDeposit);

        deal(address(usdc), attacker, n * minCancellableDeposit);

        vm.startPrank(attacker);
        usdc.approve(address(spPrime), type(uint256).max);

        for (uint256 i; i < n; ++i) {
            _coolAll();

            uint256 g0 = gasleft();
            uint256 id = spPrime.requestDeposit(minCancellableDeposit, attacker, 0);
            uint256 g1 = gasleft();

            ( , , uint256 shares ) = spPrime.getPendingDepositRequest(id);

            _coolAll();

            uint256 g2 = gasleft();
            spPrime.requestDepositCancellation(id, attacker, shares);
            uint256 g3 = gasleft();

            attackerGas += (g0 - g1) + (g2 - g3);
        }

        vm.stopPrank();

        assertEq(spPrime.firstPendingDepositId(), headId);
    }

    // Restore capacity and fill only the head so the cursor now points at the tombstone run.
    function _fillHead(uint256 headId) internal {
        _setCapacity(VAULT_CAPACITY);
        _processPendingDeposits(type(uint256).max, 1);

        assertEq(spPrime.firstPendingDepositId(), headId + 1);
    }

    // Victim queued behind the run (while capacity is still zero), head filled, victim partially
    // cancels. The cleanup walks the whole run and stops at the victim's own live entry.
    function _measureVictimCancellation(uint256 n) internal returns (uint256 gasUsed) {
        ( uint256 headId, ) = _buildTombstoneRun(n);

        uint256 victimId = _requestDeposit(victim, 2 * minCancellableDeposit);

        _fillHead(headId);

        _coolAll();

        vm.prank(victim);
        uint256 g0 = gasleft();
        spPrime.requestDepositCancellation(victimId, victim, MINIMUM_DEPOSIT_CANCELLATION);
        gasUsed = g0 - gasleft();

        // Cursor moved over the run to the victim's entry.
        assertEq(spPrime.firstPendingDepositId(), victimId);
    }

    // No live entry behind the run, head filled, a new depositor is instantly filled. The instant
    // fill walks the whole run before reaching the new request.
    function _measureInstantFill(uint256 n) internal returns (uint256 gasUsed) {
        ( uint256 headId, ) = _buildTombstoneRun(n);

        _fillHead(headId);

        deal(address(usdc), newUser, 1_000_000e6);

        vm.startPrank(newUser);
        usdc.approve(address(spPrime), 1_000_000e6);

        _coolAll();

        uint256 g0 = gasleft();
        uint256 id = spPrime.requestDeposit(1_000_000e6, newUser, 0);
        gasUsed = g0 - gasleft();

        vm.stopPrank();

        assertGt(spPrime.balanceOf(newUser), 0);               // Instantly filled
        assertEq(spPrime.firstPendingDepositId(), id + 1);    // Run cleared as a side effect
    }

    /**********************************************************************************************/
    /*** Measurements                                                                           ***/
    /**********************************************************************************************/

    function test_griefing_attackerCostPerTombstone() external {
        uint256 n = 100;

        ( , uint256 attackerGas ) = _buildTombstoneRun(n);

        console2.log("min cancellable deposit [USDC 6dp]:", minCancellableDeposit);
        console2.log("attacker gas per tombstone (deposit + full cancel):", attackerGas / n);

        // Two external calls into spUSDC (deposit) plus two queue writes; sanity bound only.
        assertGt(attackerGas / n, 150_000);
        assertLt(attackerGas / n, 400_000);
    }

    function test_griefing_victimCancellationCostPerTombstone() external {
        uint256 n = 200;

        uint256 snapshot = vm.snapshotState();
        uint256 gasBase  = _measureVictimCancellation(0);
        vm.revertToState(snapshot);
        uint256 gasRun   = _measureVictimCancellation(n);

        uint256 perSkip = (gasRun - gasBase) / n;

        console2.log("victim cancellation gas, no run:", gasBase);
        console2.log("victim cancellation gas, run of", n, ":", gasRun);
        console2.log("gas per skipped tombstone:", perSkip);
        console2.log("tombstones to exceed EIP-7825 tx cap:", (TX_GAS_CAP - gasBase) / perSkip);

        // Cold SLOAD of `shares` plus loop overhead.
        assertGt(perSkip, 2_100);
        assertLt(perSkip, 2_700);
    }

    function test_griefing_instantFillCostPerTombstone() external {
        uint256 n = 200;

        uint256 snapshot = vm.snapshotState();
        uint256 gasBase  = _measureInstantFill(0);
        vm.revertToState(snapshot);
        uint256 gasRun   = _measureInstantFill(n);

        uint256 perSkip = (gasRun - gasBase) / n;

        console2.log("instant fill gas, no run:", gasBase);
        console2.log("instant fill gas, run of", n, ":", gasRun);
        console2.log("gas per skipped tombstone:", perSkip);

        assertGt(perSkip, 2_100);
        assertLt(perSkip, 2_700);
    }

    function test_griefing_operatorClearingCostPerTombstone() external {
        uint256 n = 200;

        ( uint256 headId, ) = _buildTombstoneRun(n);

        _fillHead(headId);

        _coolAll();

        vm.prank(operator);
        uint256 g0 = gasleft();
        spPrime.processPendingDeposits(0, n);
        uint256 gasUsed = g0 - gasleft();

        assertEq(spPrime.firstPendingDepositId(), headId + 1 + n);

        console2.log("operator clearing gas, run of", n, ":", gasUsed);
        console2.log("gas per cleared tombstone:", gasUsed / n);

        // Same walk as the victim pays, plus the fixed overhead of a drip and two spUSDC views.
        assertGt(gasUsed / n, 2_100);
        assertLt(gasUsed / n, 3_500);
    }

    // Self-calibrating: measures the per-tombstone cost, builds a run just past the EIP-7825 cap,
    // shows the victim's cancellation reverts at that cap, that nothing can clear it while paused,
    // and that the operator clears it in bounded batches once unpaused.
    function test_griefing_unboundedWalkExceedsTxGasCap() external {
        uint256 snapshot = vm.snapshotState();
        uint256 gasBase  = _measureVictimCancellation(0);
        vm.revertToState(snapshot);
        uint256 gasRun   = _measureVictimCancellation(200);
        vm.revertToState(snapshot);

        uint256 perSkip = (gasRun - gasBase) / 200;
        uint256 n       = (TX_GAS_CAP - gasBase) / perSkip + 200;  // Small margin past the cap

        console2.log("building tombstone run of:", n);
        console2.log("capital cycled through the cancellation queue [USDC 6dp]:", n * minCancellableDeposit);

        ( uint256 headId, uint256 attackerGas ) = _buildTombstoneRun(n);

        console2.log("attacker gas total:", attackerGas);

        uint256 victimId = _requestDeposit(victim, 2 * minCancellableDeposit);

        _fillHead(headId);

        // 1. The victim cannot cancel within the per-transaction gas cap.
        vm.prank(victim);
        vm.expectRevert();
        spPrime.requestDepositCancellation{ gas: TX_GAS_CAP }(victimId, victim, MINIMUM_DEPOSIT_CANCELLATION);

        // 2. A new deposit cannot be instantly filled either (it is queued, not reverted, because
        //    the victim's live entry disables the instant fill; with no live entry it would revert).
        deal(address(usdc), newUser, 1_000_000e6);
        vm.startPrank(newUser);
        usdc.approve(address(spPrime), 1_000_000e6);
        spPrime.requestDeposit{ gas: TX_GAS_CAP }(1_000_000e6, newUser, 0);
        vm.stopPrank();
        assertEq(spPrime.balanceOf(newUser), 0);

        // 3. While paused nothing can clear the run: processing is paused and cancellation runs out of gas.
        _pause();

        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        spPrime.processPendingDeposits(0, 1_000);

        vm.prank(victim);
        vm.expectRevert();
        spPrime.requestDepositCancellation{ gas: TX_GAS_CAP }(victimId, victim, MINIMUM_DEPOSIT_CANCELLATION);

        _unpause();

        // 4. The operator clears the run in bounded batches.
        uint256 batch      = 1_000;
        uint256 clearGas   = 0;
        uint256 txCount    = 0;

        while (spPrime.firstPendingDepositId() < victimId) {
            _coolAll();

            vm.prank(operator);
            uint256 g0 = gasleft();
            spPrime.processPendingDeposits(0, batch);
            clearGas += g0 - gasleft();
            ++txCount;
        }

        console2.log("operator clearing txs of", batch, ":", txCount);
        console2.log("operator clearing gas total:", clearGas);

        // 5. The victim can now cancel.
        vm.prank(victim);
        spPrime.requestDepositCancellation(victimId, victim, MINIMUM_DEPOSIT_CANCELLATION);
    }

    // Related vector (Pashov I-17): one large deposit split into many minimum-size cancellation
    // entries, each costing the operator a spUSDC redeem when processed.
    function test_griefing_cancellationQueueFragmentationCost() external {
        uint256 n = 100;

        _setCapacity(0);

        uint256 id = _requestDeposit(attacker, n * minCancellableDeposit);

        vm.startPrank(attacker);
        uint256 attackerGas;
        for (uint256 i; i < n; ++i) {
            _coolAll();

            uint256 g0 = gasleft();
            spPrime.requestDepositCancellation(id, attacker, MINIMUM_DEPOSIT_CANCELLATION);
            attackerGas += g0 - gasleft();
        }
        vm.stopPrank();

        assertEq(spPrime.pendingCancelledDepositSavingsShares(), n * MINIMUM_DEPOSIT_CANCELLATION);

        _coolAll();

        vm.prank(operator);
        uint256 g1 = gasleft();
        spPrime.processPendingDepositCancellations(type(uint256).max, n);
        uint256 operatorGas = g1 - gasleft();

        assertEq(spPrime.firstPendingDepositCancellationId(), n);

        console2.log("attacker gas per cancellation entry:", attackerGas / n);
        console2.log("operator gas per processed cancellation entry:", operatorGas / n);
    }

}
