// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { SparkPrimeVaultInvariantTestBase } from "./InvariantsBase.t.sol";

import { AdminHandler }    from "./handlers/AdminHandler.sol";
import { ExternalHandler } from "./handlers/ExternalHandler.sol";
import { UserHandler }     from "./handlers/UserHandler.sol";

// Run with:
//   FOUNDRY_OFFLINE=true FOUNDRY_INVARIANT_RUNS=500 FOUNDRY_INVARIANT_DEPTH=500 \
//     forge test --match-path 'test/ai/invariants/Invariants.t.sol' -vv
contract SparkPrimeVaultInvariantTest is SparkPrimeVaultInvariantTestBase {

    uint256 internal constant NUM_USERS = 10;

    function setUp() public override {
        super.setUp();

        userHandler     = new UserHandler(address(vault), NUM_USERS);
        adminHandler    = new AdminHandler(address(vault), NUM_USERS);
        externalHandler = new ExternalHandler(address(vault), NUM_USERS, spSetter, spTaker);

        vm.label(address(userHandler),     "userHandler");
        vm.label(address(adminHandler),    "adminHandler");
        vm.label(address(externalHandler), "externalHandler");

        // Foundry fuzzes every non-view function of these contracts.
        targetContract(address(userHandler));
        targetContract(address(adminHandler));
        targetContract(address(externalHandler));
    }

    /**********************************************************************************************/
    /*** Invariants                                                                             ***/
    /**********************************************************************************************/

    function invariant_vaultInvariants() public {
        this.vaultInvariant_A_sumBalancesPlusEscrowEqTotalSupply();
        this.vaultInvariant_B_escrowEqPendingRedeemShares();
        this.vaultInvariant_C_assetConversions();
        this.vaultInvariant_D_pendingSharesEqSumOfQueues();
        this.vaultInvariant_E_queueHeadsAndLengths();
        this.vaultInvariant_F_claimables();
        this.vaultInvariant_G_configBounds();
        this.vaultInvariant_H_capacity();
        this.vaultInvariant_I_chiRhoDrip();
        this.vaultInvariant_J_backing();
        this.vaultInvariant_K_roles();
        this.vaultInvariant_L_escrowOnlyLeavesThroughRedeemFills();
        this.vaultInvariant_M_redeemPayoutsNeverExceedSharesBurned();
        this.vaultInvariant_N_cancellationPayoutsNeverExceedSavingsSharesRedeemed();
    }

    /**********************************************************************************************/
    /*** Post-Invariant: full settlement                                                        ***/
    /**********************************************************************************************/

    function afterInvariant() public {
        _checkInvariantsOverTime();

        // 1. Normalise: unpause, unblacklist, bring every taken spUSDC share and every drained USDC
        //    back, freeze both indexes, make spUSDC fully liquid (the vault is its only depositor
        //    here, so accrued spUSDC interest has no USDC behind it) and open the capacity.
        if (vault.paused()) _unpause();

        for (uint256 i = 0; i < NUM_USERS; i++) {
            _unblacklist(userHandler.users(i));
        }

        uint256 takenShares_      = spUsdc.balanceOf(taker);
        uint256 drainedLiquidity_ = usdc.balanceOf(spTaker);

        vm.prank(taker);
        spUsdc.transfer(address(vault), takenShares_);

        vm.prank(spTaker);
        usdc.transfer(address(spUsdc), drainedLiquidity_);

        vm.prank(admin);
        vault.setVSRBounds(RAY, RAY);

        _setPrimeVsr(RAY);
        _setSpUsdcVsr(RAY);

        uint256 savingsAssets_    = spUsdc.totalAssets();
        uint256 savingsLiquidity_ = usdc.balanceOf(address(spUsdc));

        if (savingsLiquidity_ < savingsAssets_) usdc.mint(address(spUsdc), savingsAssets_ - savingsLiquidity_);

        _setCapacity(type(uint128).max);

        _checkInvariantsOverTime();

        // 2. Deposits: one walk fills everything with the capacity open. Processing goes through
        //    the handlers so their ghost counters see these fills too; `(0, 0)` is the unbounded
        //    branch of `_boundProcessing`.
        adminHandler.processPendingDeposits(0, 0);

        assertEq(vault.pendingDepositSavingsShares(), 0, "afterInvariant: deposit queue not drained");

        // 3. Cancellations: top the vault up if redeem fills or `take` spent the backing, then drain.
        uint256 owed_ = vault.pendingCancelledDepositSavingsShares();
        uint256 held_ = spUsdc.balanceOf(address(vault));

        if (held_ < owed_) _giveSavingsShares((owed_ - held_) * spUsdc.nowChi() / RAY + 2);

        adminHandler.processPendingDepositCancellations(0, 0);

        assertEq(vault.pendingCancelledDepositSavingsShares(), 0, "afterInvariant: cancellation queue not drained");

        _checkInvariantsOverTime();

        // 4. Every holder redeems everything (no fee, minRedeem 1 so dust balances can exit).
        _setRedeemFeeRate(0);
        _setMinRedeem(1);

        for (uint256 i = 0; i < NUM_USERS; i++) {
            uint256 balance_ = vault.balanceOf(userHandler.users(i));

            // Seeds `i` resolve to user `i`; the exact balance is within the handler's bounds.
            if (balance_ != 0) userHandler.requestRedeem(balance_, i, i);
        }

        assertEq(vault.balanceOf(address(vault)), vault.totalSupply(), "afterInvariant: supply not fully escrowed");

        // 5. Give the vault whatever spUSDC and liquidity it is short of. The shortfall is notional
        //    created by positive `adjustTotalAssets` plus one spUSDC share of rounding per fill.
        uint256 fills_       = vault.getPendingRedeemRequests().length;
        uint256 savingsUnit_ = spUsdc.nowChi() / RAY + 1;  // USDC value of one spUSDC share, rounded up

        uint256 needed_ = vault.convertToAssets(vault.pendingRedeemShares()) + (fills_ + 2) * savingsUnit_;
        uint256 have_   = spUsdc.assetsOf(address(vault));

        if (have_ < needed_) _giveSavingsShares(needed_ - have_);

        usdc.mint(address(spUsdc), needed_);

        adminHandler.processPendingRedeems(0, 0);

        assertEq(vault.pendingRedeemShares(),       0, "afterInvariant: redeem queue not drained");
        assertEq(vault.totalSupply(),               0, "afterInvariant: totalSupply != 0 after full exit");
        assertEq(vault.balanceOf(address(vault)),   0, "afterInvariant: escrow left after full exit");

        // 6. Claims: nobody is blacklisted any more, so every claimable is payable.
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user_ = userHandler.users(i);

            if (vault.claimableAssets(user_) != 0) vault.claim(user_);
        }

        assertEq(vault.totalClaimable(),           0, "afterInvariant: claimables left");
        assertEq(usdc.balanceOf(address(vault)),   0, "afterInvariant: vault still holds USDC");
        assertEq(vault.totalAssets(),              0, "afterInvariant: totalAssets != 0");

        _checkInvariantsOverTime();
    }

    /**********************************************************************************************/
    /*** Internal Helpers                                                                       ***/
    /**********************************************************************************************/

    function _checkInvariantsOverTime() internal {
        this.invariant_vaultInvariants();

        uint256 sumAssetsBefore_   = _sumAssetsOf();
        uint256 totalAssetsBefore_ = vault.totalAssets();

        skip(30 minutes);

        // With no interactions, holdings can only grow over time.
        assertGe(_sumAssetsOf(),      sumAssetsBefore_,   "checkInvariantsOverTime: sum(assetsOf) decreased");
        assertGe(vault.totalAssets(), totalAssetsBefore_, "checkInvariantsOverTime: totalAssets decreased");

        this.invariant_vaultInvariants();
    }

}
