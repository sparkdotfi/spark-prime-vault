// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { SparkPrimeVaultInvariantTestBase } from "./InvariantsBase.t.sol";

import { AdminHandler }    from "./handlers/AdminHandler.sol";
import { ExternalHandler } from "./handlers/ExternalHandler.sol";
import { UserHandler }     from "./handlers/UserHandler.sol";

contract SparkPrimeVaultInvariantTest is SparkPrimeVaultInvariantTestBase {

    function setUp() public override {
        super.setUp();

        userHandler     = new UserHandler(address(spPrime), 10);
        adminHandler    = new AdminHandler(address(spPrime), userHandler);
        externalHandler = new ExternalHandler(address(spPrime), userHandler, adminHandler, spSetter, spTaker);

        vm.label(address(userHandler),     "userHandler");
        vm.label(address(adminHandler),    "adminHandler");
        vm.label(address(externalHandler), "externalHandler");

        // Explicit selectors for every handler so recording hooks are never fuzzed.
        targetContract(address(userHandler));
        targetContract(address(adminHandler));
        targetContract(address(externalHandler));

        bytes4[] memory userSelectors_ = new bytes4[](9);
        userSelectors_[0] = UserHandler.requestDeposit.selector;
        userSelectors_[1] = UserHandler.requestDepositCancellation.selector;
        userSelectors_[2] = UserHandler.requestRedeem.selector;
        userSelectors_[3] = UserHandler.updateDepositRecipient.selector;
        userSelectors_[4] = UserHandler.updateDepositCancellationRecipient.selector;
        userSelectors_[5] = UserHandler.updateRedeemRecipient.selector;
        userSelectors_[6] = UserHandler.claim.selector;
        userSelectors_[7] = UserHandler.transfer.selector;
        userSelectors_[8] = UserHandler.transferFrom.selector;

        targetSelector(FuzzSelector({ addr: address(userHandler), selectors: userSelectors_ }));

        bytes4[] memory adminSelectors_ = new bytes4[](16);
        adminSelectors_[0]  = AdminHandler.setVSRBounds.selector;
        adminSelectors_[1]  = AdminHandler.setVSR.selector;
        adminSelectors_[2]  = AdminHandler.setCapacity.selector;
        adminSelectors_[3]  = AdminHandler.setMaxRedeemFeeRate.selector;
        adminSelectors_[4]  = AdminHandler.setRedeemFeeRate.selector;
        adminSelectors_[5]  = AdminHandler.setMinDeposit.selector;
        adminSelectors_[6]  = AdminHandler.setMinDepositCancellation.selector;
        adminSelectors_[7]  = AdminHandler.setMinRedeem.selector;
        adminSelectors_[8]  = AdminHandler.pause.selector;
        adminSelectors_[9]  = AdminHandler.unpause.selector;
        adminSelectors_[10] = AdminHandler.adjustTotalAssets.selector;
        adminSelectors_[11] = AdminHandler.processPendingDeposits.selector;
        adminSelectors_[12] = AdminHandler.processPendingDepositCancellations.selector;
        adminSelectors_[13] = AdminHandler.processPendingRedeems.selector;
        adminSelectors_[14] = AdminHandler.take.selector;
        adminSelectors_[15] = AdminHandler.upgrade.selector;

        targetSelector(FuzzSelector({ addr: address(adminHandler), selectors: adminSelectors_ }));

        bytes4[] memory externalSelectors_ = new bytes4[](9);
        externalSelectors_[0] = ExternalHandler.warp.selector;
        externalSelectors_[1] = ExternalHandler.drip.selector;
        externalSelectors_[2] = ExternalHandler.setSavingsVsr.selector;
        externalSelectors_[3] = ExternalHandler.drainSavingsLiquidity.selector;
        externalSelectors_[4] = ExternalHandler.returnSavingsLiquidity.selector;
        externalSelectors_[5] = ExternalHandler.returnTakenSavingsShares.selector;
        externalSelectors_[6] = ExternalHandler.setBlacklisted.selector;
        externalSelectors_[7] = ExternalHandler.giveAsset.selector;
        externalSelectors_[8] = ExternalHandler.giveSavingsShares.selector;

        targetSelector(FuzzSelector({ addr: address(externalHandler), selectors: externalSelectors_ }));
    }

    /**********************************************************************************************/
    /*** Invariants                                                                             ***/
    /**********************************************************************************************/

    function invariant_vaultInvariants() public {
        this.vaultInvariant_A_sumBalancesPlusEscrowEqTotalSupply();
        this.vaultInvariant_B_escrowEqPendingRedeemShares();
        this.vaultInvariant_C_supplyProvenance();
        this.vaultInvariant_D_conversions();
        this.vaultInvariant_E_chiRhoDrip();
        this.vaultInvariant_F_configBounds();
        this.vaultInvariant_G_capacity();
        this.vaultInvariant_H_savingsFlowIdentity();
        this.vaultInvariant_I_claimables();
        this.vaultInvariant_J_usdcPaidOut();
        this.vaultInvariant_K_roles();
        this.vaultInvariant_L_backing();
    }

    function invariant_queueInvariants() public {
        this.queueInvariant_A_pendingSums();
        this.queueInvariant_B_headsAndLengths();
        this.queueInvariant_C_entriesWellFormed();
        this.queueInvariant_F_emptyQueueCorollaries();
        this.queueInvariant_G_getterConsistency();
    }

    function invariant_userInvariants() public view {
        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            address user_ = userHandler.users(i);

            this.userInvariant_A_balanceProvenance(user_);
            this.userInvariant_B_assetsOf(user_);
            this.userInvariant_C_assetsOfCannotDecrease(user_);
            this.userInvariant_D_claimableProvenance(user_);
            this.userInvariant_E_conversionRoundTrips(user_);
            this.userInvariant_F_usdcProvenance(user_);
        }
    }

    /**********************************************************************************************/
    /*** Post-invariant: full settlement                                                        ***/
    /**********************************************************************************************/

    function afterInvariant() public {
        _checkInvariantsOverTime();

        // 1. Normalise: unpause, unblacklist, bring every spUSDC share and every USDC back, freeze
        //    both indexes and open the capacity.
        if (spPrime.paused()) _unpause();

        externalHandler.unblacklistAll();
        externalHandler.returnAllTakenSavingsShares();
        externalHandler.returnAllSavingsLiquidity();
        externalHandler.giveSavingsLiquidityExact(savings.assetsOutstanding() + 1_000_000e6);

        vm.prank(admin);
        spPrime.setVSRBounds(RAY, RAY);

        vm.prank(operator);
        spPrime.setVSR(RAY);

        externalHandler.setSavingsVsrExact(RAY);

        _setCapacity(type(uint128).max);

        _checkInvariantsOverTime();

        // 2. Deposits: one walk fills everything with the capacity open.
        adminHandler.processPendingDepositsExact(type(uint256).max, type(uint256).max);

        assertEq(spPrime.pendingDepositSavingsShares(), 0,                         "afterInvariant: deposit queue not drained");
        assertEq(spPrime.firstPendingDepositId(),       _rawLength(DEPOSIT_SLOT),  "afterInvariant: deposit head not at end");

        _checkInvariantsOverTime();

        // 3. Cancellations: top the vault up if redeem fills spent the backing, then drain.
        uint256 owed_ = spPrime.pendingCancelledDepositSavingsShares();
        uint256 held_ = savings.balanceOf(address(spPrime));

        if (held_ < owed_) externalHandler.giveSavingsSharesExact(owed_ - held_);

        adminHandler.processPendingDepositCancellationsExact(type(uint256).max, type(uint256).max);

        assertEq(spPrime.pendingCancelledDepositSavingsShares(), 0,                      "afterInvariant: cancellation queue not drained");
        assertEq(spPrime.firstPendingDepositCancellationId(),    _rawLength(CANCEL_SLOT), "afterInvariant: cancellation head not at end");

        _checkInvariantsOverTime();

        // 4. Every holder redeems everything (no fee, minRedeem 1 so dust balances can exit).
        _setRedeemFeeRate(0);

        vm.prank(admin);
        spPrime.setMinRedeem(1);

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            address user_    = userHandler.users(i);
            uint256 balance_ = spPrime.balanceOf(user_);

            if (balance_ != 0) userHandler.requestRedeemExact(user_, balance_);
        }

        assertEq(spPrime.balanceOf(address(spPrime)), spPrime.totalSupply(), "afterInvariant: supply not fully escrowed");

        // 5. Make the vault able to pay. The shortfall is notional created without backing
        //    (positive adjustTotalAssets) plus one spUSDC share of ceil rounding per redeem fill.
        uint256 needed_      = spPrime.convertToAssets(spPrime.pendingRedeemShares());
        uint256 have_        = savings.assetsOf(address(spPrime));
        uint256 shortfall_   = have_ < needed_ ? needed_ - have_ : 0;
        uint256 savingsUnit_ = (savings.nowChi() + RAY - 1) / RAY;  // USDC value of one spUSDC share, rounded up

        if (shortfall_ != 0 && !adminHandler.rateOrderBroken()) {
            int256 ledger_ = adminHandler.ghostAdjustNetShares();

            uint256 bound_ =
                (ledger_ > 0 ? uint256(ledger_) * spPrime.nowChi() / RAY : 0)
                + adminHandler.ghostRedeemFills() * savingsUnit_
                + 2;

            assertLe(shortfall_, bound_, "afterInvariant: shortfall above gains + rounding");
        }

        // The settlement fills (one per holder) each burn up to one extra spUSDC share too.
        uint256 topUp_ = shortfall_ + (userHandler.numUsers() + 2) * savingsUnit_ + 2;

        externalHandler.giveSavingsSharesExact(savings.convertToShares(topUp_) + 1);

        uint256 liquidity_ = usdc.balanceOf(address(spUSDC));

        if (liquidity_ < needed_ + topUp_) {
            externalHandler.giveSavingsLiquidityExact(needed_ + topUp_ - liquidity_);
        }

        adminHandler.processPendingRedeemsExact(type(uint256).max, type(uint256).max);

        assertEq(spPrime.pendingRedeemShares(),       0,                        "afterInvariant: redeem queue not drained");
        assertEq(spPrime.totalSupply(),               0,                        "afterInvariant: totalSupply != 0 after full exit");
        assertEq(spPrime.balanceOf(address(spPrime)), 0,                        "afterInvariant: escrow left after full exit");
        assertEq(spPrime.firstPendingRedeemId(),      _rawLength(REDEEM_SLOT),  "afterInvariant: redeem head not at end");

        // The queue is empty, so the minimum the handlers rely on can be restored.
        vm.prank(admin);
        spPrime.setMinRedeem(2);

        // 6. Claims: nobody is blacklisted any more, so every claimable is payable.
        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            address user_ = userHandler.users(i);

            if (spPrime.claimableAssets(user_) != 0) userHandler.claimExact(user_);
        }

        assertEq(spPrime.totalClaimable(), 0, "afterInvariant: claimables left");

        assertEq(
            usdc.balanceOf(address(spPrime)),
            externalHandler.ghostUsdcDonatedToVault(),
            "afterInvariant: vault holds USDC beyond donations"
        );

        // 7. Terminal state.
        assertEq(spPrime.totalAssets(), 0, "afterInvariant: totalAssets != 0");

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            assertEq(spPrime.balanceOf(userHandler.users(i)),       0, "afterInvariant: user still holds shares");
            assertEq(spPrime.claimableAssets(userHandler.users(i)), 0, "afterInvariant: user still has claimable");
        }

        _checkInvariantsOverTime();
    }

    /**********************************************************************************************/
    /*** Internal helpers                                                                       ***/
    /**********************************************************************************************/

    function _checkInvariantsOverTime() internal {
        this.invariant_vaultInvariants();
        this.invariant_queueInvariants();
        this.invariant_userInvariants();

        uint256 sumAssetsBefore_  = _sumAssetsOf();
        uint256 totalAssetsBefore_ = spPrime.totalAssets();

        skip(30 minutes);

        // With no interactions, holdings can only grow over time.
        assertGe(_sumAssetsOf(),        sumAssetsBefore_,   "checkInvariantsOverTime: sum(assetsOf) decreased");
        assertGe(spPrime.totalAssets(), totalAssetsBefore_, "checkInvariantsOverTime: totalAssets decreased");

        this.invariant_vaultInvariants();
        this.invariant_queueInvariants();
        this.invariant_userInvariants();
    }

}
