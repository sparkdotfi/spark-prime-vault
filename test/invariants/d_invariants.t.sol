// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import "./c_flows_admin.sol";

import { LocalTestBase } from "../LocalTestBase.t.sol";

// Invariant campaign for `SparkPrimeVault` over the local harness (real spUSDC code, 6-decimal
// mock USDC). Run with:
//   FOUNDRY_INVARIANT_RUNS=100 FOUNDRY_INVARIANT_DEPTH=500 \
//     forge test --match-path 'test/invariants/*.t.sol' -vv
contract SparkPrimeVaultInvariantTest is LocalTestBase {

    FlowsAdmin handler;

    function setUp() public override {
        super.setUp();

        handler = new FlowsAdmin(address(vault));

        targetContract(address(handler));
    }

    /**********************************************************************************************/
    /*** Shares                                                                                 ***/
    /**********************************************************************************************/

    // A. Share balances of every holder (users + vault escrow) sum to totalSupply.
    function invariant_A_sumOfBalancesEqualsTotalSupply() public view {
        uint256 sum = vault.balanceOf(address(vault));
        for (uint256 i = 0; i < handler.N(); i++) sum += vault.balanceOf(handler.users(i));
        assertEq(sum, vault.totalSupply(), "A: sum of balances != totalSupply");
    }

    // B. The vault's own balance is exactly the escrowed redeem shares (no donations in the campaign).
    function invariant_B_vaultBalanceEqualsPendingRedeemShares() public view {
        if (handler.vaultDonations()) return;
        assertEq(vault.balanceOf(address(vault)), vault.pendingRedeemShares(), "B: escrow mismatch");
    }

    // J. Each user's balance equals minted + transfers in - transfers out - escrowed + refunds.
    function invariant_J_balanceProvenance() public view {
        for (uint256 i = 0; i < handler.N(); i++) {
            address user = handler.users(i);
            uint256 expected =
                handler.ghostMinted(user)
                + handler.ghostTransferIn(user)
                + handler.ghostRefunded(user)
                - handler.ghostTransferOut(user)
                - handler.ghostEscrowed(user);
            assertEq(vault.balanceOf(user), expected, "J: balance provenance mismatch");
        }
    }

    /**********************************************************************************************/
    /*** Queues                                                                                 ***/
    /**********************************************************************************************/

    // C. pendingDepositSavingsShares is the sum of every open deposit entry.
    function invariant_C_pendingDepositEqualsSumOfOpenDepositEntries() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.depositQueueLength(); i++) {
            (, , uint256 shares) = vault.depositQueue(i);
            sum += shares;
        }
        assertEq(sum, vault.pendingDepositSavingsShares(), "C: pending deposit mismatch");
    }

    // D. pendingRedeemShares is the sum of every open redeem entry.
    function invariant_D_pendingRedeemEqualsSumOfOpenRedeemEntries() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.redeemQueueLength(); i++) {
            (, , uint256 shares) = vault.redeemQueue(i);
            sum += shares;
        }
        assertEq(sum, vault.pendingRedeemShares(), "D: pending redeem mismatch");
    }

    // E. Every entry strictly before a head is closed (filled or cancelled); heads never pass the
    //    queue length.
    function invariant_E_headBookkeeping() public view {
        uint256 depositHead = vault.depositHead();
        uint256 redeemHead  = vault.redeemHead();

        assertLe(depositHead, handler.depositQueueLength(), "E: depositHead past length");
        assertLe(redeemHead,  handler.redeemQueueLength(),  "E: redeemHead past length");

        for (uint256 i = 0; i < depositHead; i++) {
            (, , uint256 shares) = vault.depositQueue(i);
            assertEq(shares, 0, "E: open deposit entry before depositHead");
        }
        for (uint256 i = 0; i < redeemHead; i++) {
            (, , uint256 shares) = vault.redeemQueue(i);
            assertEq(shares, 0, "E: open redeem entry before redeemHead");
        }
    }

    /**********************************************************************************************/
    /*** Capacity and index                                                                     ***/
    /**********************************************************************************************/

    // F. No mint ever pushed totalSupply above maxCapacity as it stood at the time of the mint.
    function invariant_F_totalSupplyNeverExceedsCapacityViaMint() public view {
        assertFalse(handler.mintedAboveCapacity(), "F: mint exceeded capacity");
    }

    // G. chi never decreases and drip() lands exactly on nowChi().
    function invariant_G_chiMonotonicAndDripConsistent() public {
        uint256 nowChi_ = vault.nowChi();
        assertGe(nowChi_, handler.lastChi(), "G: chi decreased");
        assertGe(nowChi_, vault.chi(),       "G: nowChi below stored chi");

        uint256 dripped = vault.drip();
        assertEq(dripped,     nowChi_, "G: drip != nowChi");
        assertEq(vault.chi(), nowChi_, "G: stored chi != nowChi after drip");
        assertEq(vault.rho(), block.timestamp, "G: rho not updated");
    }

    // L. availableCapacity() == max(0, maxCapacity - totalSupply).
    function invariant_L_availableCapacityFormula() public view {
        uint256 cap    = vault.maxCapacity();
        uint256 supply = vault.totalSupply();
        uint256 expected = cap > supply ? cap - supply : 0;
        assertEq(vault.availableCapacity(), expected, "L: availableCapacity formula");
    }

    /**********************************************************************************************/
    /*** Value                                                                                  ***/
    /**********************************************************************************************/

    // H. Solvency: while spUSDC's VSR has never been below spPRIME's and the taker holds nothing,
    //    the spUSDC value held by the vault net of what is owed to queued depositors covers the
    //    notional totalAssets() up to a rounding epsilon.
    //
    //    Epsilon: deposit fills round in the vault's favour (double floor) and totalAssets() is a
    //    single floor, so the deposit side contributes at most 1 wei in total. Each redeem fill
    //    withdraws `assets` from spUSDC by burning ceil(assets*RAY/chi_s) spUSDC shares, up to one
    //    share more than the exact amount; that share is worth ceil(chi_s/RAY) USDC wei today.
    //    Index drift between the two `_rpow` chains is below 1e-20 relative and is absorbed by +2.
    function invariant_H_solvencyWhenSpUsdcRateGePrimeRate() public view {
        if (handler.rateOrderBroken())              return;
        if (handler.takerOutstandingSpUsdc() != 0)  return;

        uint256 held    = spUsdc.balanceOf(address(vault));
        uint256 pending = vault.pendingDepositSavingsShares();

        int256 backing =
            int256(spUsdc.convertToAssets(held)) - int256(spUsdc.convertToAssets(pending));

        uint256 chiS    = spUsdc.nowChi();
        uint256 epsilon = handler.redeemFills() * ((chiS + RAY - 1) / RAY) + 2;

        int256 notional = int256(vault.totalAssets());

        assertGe(backing + int256(epsilon), notional, "H: notional exceeds real backing");
    }

    // I. Users never extract more USDC than they deposited plus the USDC that entered spUSDC as
    //    yield or as taker top-ups (no value is created inside the vault).
    function invariant_I_usersNeverExtractMoreThanDepositsPlusYield() public view {
        uint256 received;
        for (uint256 i = 0; i < handler.N(); i++) received += usdc.balanceOf(handler.users(i));

        uint256 sources =
            handler.usersDepositedUsdc() + handler.spUsdcYieldMinted() + handler.takerInjectedUsdc();

        assertLe(received, sources, "I: users extracted more than every USDC source");
    }

    // K. USDC conservation: every USDC wei ever minted sits in spUSDC, with the spUSDC taker, with
    //    users, with the vault, or with the spPRIME taker.
    function invariant_K_backingExistsSomewhere() public view {
        uint256 sum =
            usdc.balanceOf(address(spUsdc))
            + usdc.balanceOf(handler.spTaker())
            + usdc.balanceOf(address(vault))
            + usdc.balanceOf(handler.taker());
        for (uint256 i = 0; i < handler.N(); i++) sum += usdc.balanceOf(handler.users(i));

        assertEq(sum, handler.totalUsdcMinted(), "K: USDC not conserved");
        assertEq(usdc.balanceOf(address(vault)), 0, "K: USDC parked in the vault");
    }

    // N. spUSDC share conservation: the vault plus the spPRIME taker hold every spUSDC share.
    function invariant_N_spUsdcSharesHeldByVaultAndTaker() public view {
        uint256 sum = spUsdc.balanceOf(address(vault)) + spUsdc.balanceOf(handler.taker());
        assertEq(sum, spUsdc.totalSupply(), "N: spUSDC shares leaked");
        assertEq(spUsdc.balanceOf(handler.taker()), handler.takerOutstandingSpUsdc(), "N: taker ledger");
    }

    // M. Zero-share fills (F-4) are counted, not asserted; see afterInvariant().
    function invariant_M_noMintOfZeroSharesExceptDust() public view {
        // A zero-share fill can only consume less than one spPRIME share worth of spUSDC.
        // Nothing to assert on the live state; the handler tallies occurrences.
        handler.zeroShareFills();
    }

    // O. processRedeemQueue only ever reverted with spUSDC's insufficient-balance (ceil burn).
    function invariant_O_processRedeemQueueRevertsOnlyOnCeilBurn() public view {
        assertEq(handler.redeemProcessRevertsOther(), 0, "O: unexpected processRedeemQueue revert");
    }

    /**********************************************************************************************/
    /*** Bug reproductions                                                                      ***/
    /**********************************************************************************************/

    // `_processRedeemQueue` bounds `remaining_` by `convertToShares(maxWithdraw(vault))` but pays
    // each entry with spUSDC `withdraw(assets_)`, which burns ceil(assets_*RAY/chi_s) shares. When
    // the vault's spUSDC *balance* (not spUSDC liquidity) is the binding limit, the per-entry
    // ceilings add up past the balance and the call reverts inside spUSDC.
    //
    // Concrete numbers (harness: chi_s = 1.0476e27, chi_p = 1.0097e27): vault holds 100 spUSDC,
    // maxWithdraw = 104 USDC-wei, remaining_ = 103 spPRIME shares; 110 one-share entries each pay
    // 1 USDC-wei and burn 1 spUSDC share, so the 101st fill reverts. The same call with
    // `maxRequests_ = 1` succeeds 99 times and then does nothing (1 share is left stranded).
    //
    // This test PASSES by asserting the revert; it is a proof, not a regression.
    function test_BUG_processRedeemQueueRevertsOnCeilBurnWhenBalanceBinds() public {
        address alice = makeAddr("alice");

        _deposit(alice, 100e6);
        for (uint256 i; i < 110; i++) _requestRedeem(alice, 1);

        _take(_vaultSpUsdc() - 100);

        assertEq(_vaultSpUsdc(), 100);
        assertEq(spUsdc.maxWithdraw(address(vault)), 104);
        assertEq(vault.convertToShares(spUsdc.maxWithdraw(address(vault))), 103);

        vm.prank(rebalancer);
        vm.expectRevert("SparkVault/insufficient-balance");
        vault.processRedeemQueue(type(uint256).max, 110);

        // Workaround: one entry per call never reverts, but strands the last share.
        for (uint256 i; i < 110; i++) _processRedeems(type(uint256).max, 1);

        assertEq(vault.redeemHead(),      99);
        assertEq(usdc.balanceOf(alice),   99);
        assertEq(_vaultSpUsdc(),          1);
        assertEq(vault.pendingRedeemShares(), 11);
    }

    /**********************************************************************************************/
    /*** Coverage                                                                               ***/
    /**********************************************************************************************/

    function afterInvariant() public view {
        console.log("--- handler call counts ---");
        for (uint256 i = 0; i < handler.callNamesLength(); i++) {
            string memory name_ = handler.callNames(i);
            console.log(name_, handler.calls(name_));
        }
        console.log("--- ghost counters ---");
        console.log("depositQueueLength       ", handler.depositQueueLength());
        console.log("redeemQueueLength        ", handler.redeemQueueLength());
        console.log("depositFills             ", handler.depositFills());
        console.log("redeemFills              ", handler.redeemFills());
        console.log("zeroShareFills (F-4)     ", handler.zeroShareFills());
        console.log("ghostDepositEntries (F-5)", handler.ghostDepositEntries());
        console.log("ghostRedeemEntries (F-5) ", handler.ghostRedeemEntries());
        console.log("cancelDepositBlockedF2   ", handler.cancelDepositBlockedF2());
        console.log("redeemProcessReverts     ", handler.redeemProcessReverts());
        console.log("rateOrderBroken          ", handler.rateOrderBroken());
        console.log("takerOutstandingSpUsdc   ", handler.takerOutstandingSpUsdc());
        console.log("totalSupply              ", vault.totalSupply());
        console.log("chi                      ", vault.chi());
    }

}
