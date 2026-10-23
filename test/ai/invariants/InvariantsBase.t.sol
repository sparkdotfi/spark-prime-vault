// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISparkPrimeVault } from "../../../src/ISparkPrimeVault.sol";

import { LocalTestBase } from "../LocalTestBase.t.sol";

import { AdminHandler }    from "./handlers/AdminHandler.sol";
import { ExternalHandler } from "./handlers/ExternalHandler.sol";
import { UserHandler }     from "./handlers/UserHandler.sol";

// Local-harness complement of `test/invariants/InvariantsBase.t.sol` (no RPC): the same
// invariants A-K over `LocalTestBase`, plus L-N from the round-5 campaign.
contract SparkPrimeVaultInvariantTestBase is LocalTestBase {

    AdminHandler    internal adminHandler;
    ExternalHandler internal externalHandler;
    UserHandler     internal userHandler;

    function setUp() public virtual override {
        super.setUp();

        // Both indexes accrue from the start; the handlers move the rates from here.
        _setSpUsdcVsr(FIVE_PCT_VSR);
        _setPrimeVsr(FOUR_PCT_VSR);
    }

    /**********************************************************************************************/
    /*** Vault Invariant Helpers                                                                ***/
    /**********************************************************************************************/

    function vaultInvariant_A_sumBalancesPlusEscrowEqTotalSupply() public view {
        uint256 sum_ = vault.balanceOf(address(vault));

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            sum_ += vault.balanceOf(userHandler.users(i));
        }

        assertEq(sum_, vault.totalSupply(), "invariant A: sum(balances) + escrow != totalSupply");
    }

    function vaultInvariant_B_escrowEqPendingRedeemShares() public view {
        assertEq(
            vault.balanceOf(address(vault)),
            vault.pendingRedeemShares(),
            "invariant B: escrow != pendingRedeemShares"
        );
    }

    function vaultInvariant_C_assetConversions() public view {
        uint256 chi_ = vault.nowChi();

        assertEq(vault.totalAssets(), vault.totalSupply() * chi_ / RAY, "invariant C: totalAssets formula");

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            address user_ = userHandler.users(i);

            assertEq(vault.assetsOf(user_), vault.balanceOf(user_) * chi_ / RAY, "invariant C: assetsOf formula");
            assertLe(vault.assetsOf(user_), vault.totalAssets(),                 "invariant C: assetsOf > totalAssets");
        }
    }

    function vaultInvariant_D_pendingSharesEqSumOfQueues() public view {
        assertEq(
            _sumShares(vault.getPendingDepositRequests()),
            vault.pendingDepositSavingsShares(),
            "invariant D: pendingDepositSavingsShares != sum(deposit queue)"
        );
        assertEq(
            _sumShares(vault.getPendingDepositCancellationRequests()),
            vault.pendingCancelledDepositSavingsShares(),
            "invariant D: pendingCancelledDepositSavingsShares != sum(cancellation queue)"
        );
        assertEq(
            _sumShares(vault.getPendingRedeemRequests()),
            vault.pendingRedeemShares(),
            "invariant D: pendingRedeemShares != sum(redeem queue)"
        );
    }

    function vaultInvariant_E_queueHeadsAndLengths() public view {
        assertEq(
            vault.firstPendingDepositId() + vault.getPendingDepositRequests().length,
            userHandler.depositQueueLength(),
            "invariant E: deposit head + window != requests made"
        );
        assertEq(
            vault.firstPendingDepositCancellationId() + vault.getPendingDepositCancellationRequests().length,
            userHandler.depositCancellationQueueLength(),
            "invariant E: cancellation head + window != requests made"
        );
        assertEq(
            vault.firstPendingRedeemId() + vault.getPendingRedeemRequests().length,
            userHandler.redeemQueueLength(),
            "invariant E: redeem head + window != requests made"
        );
    }

    function vaultInvariant_F_claimables() public view {
        uint256 sum_;

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            sum_ += vault.claimableAssets(userHandler.users(i));
        }

        assertEq(sum_,                           vault.totalClaimable(), "invariant F: sum(claimableAssets) != totalClaimable");
        assertEq(usdc.balanceOf(address(vault)), vault.totalClaimable(), "invariant F: vault USDC != totalClaimable");
    }

    function vaultInvariant_G_configBounds() public view {
        assertGe(vault.vsr(),    RAY,             "invariant G: vsr < RAY");
        assertLe(vault.vsr(),    vault.MAX_VSR(), "invariant G: vsr > MAX_VSR");
        assertGe(vault.minVSR(), RAY,             "invariant G: minVSR < RAY");
        assertLe(vault.maxVSR(), vault.MAX_VSR(), "invariant G: maxVSR > MAX_VSR");
        assertLe(vault.minVSR(), vault.maxVSR(),  "invariant G: minVSR > maxVSR");

        // Lowering `maxRedeemFeeRate` does not clamp the live fee, so only the constant cap holds.
        assertLe(vault.redeemFeeRate(),    vault.MAX_REDEEM_FEE(), "invariant G: redeemFeeRate > MAX_REDEEM_FEE");
        assertLe(vault.maxRedeemFeeRate(), vault.MAX_REDEEM_FEE(), "invariant G: maxRedeemFeeRate > MAX_REDEEM_FEE");

        assertGt(vault.minDeposit(),             0, "invariant G: minDeposit zero");
        assertGt(vault.minDepositCancellation(), 0, "invariant G: minDepositCancellation zero");
        assertGt(vault.minRedeem(),              0, "invariant G: minRedeem zero");
    }

    function vaultInvariant_H_capacity() public view {
        uint256 cap_    = vault.maxCapacity();
        uint256 supply_ = vault.totalSupply();

        assertEq(
            vault.availableCapacity(),
            cap_ > supply_ ? cap_ - supply_ : 0,
            "invariant H: availableCapacity formula"
        );

        if (!adminHandler.capacityLoweredBelowSupply()) {
            assertLe(supply_, cap_, "invariant H: totalSupply above maxCapacity");
        }
    }

    function vaultInvariant_I_chiRhoDrip() public {
        uint256 nowChi_ = vault.nowChi();

        assertGt(uint256(vault.chi()), 0,                    "invariant I: chi is zero");
        assertLe(vault.rho(),          block.timestamp,      "invariant I: rho in the future");
        assertGe(nowChi_,              uint256(vault.chi()), "invariant I: nowChi < chi");

        assertEq(uint256(vault.drip()), nowChi_,         "invariant I: drip != nowChi");
        assertEq(uint256(vault.chi()),  nowChi_,         "invariant I: chi not synced after drip");
        assertEq(vault.rho(),           block.timestamp, "invariant I: rho not updated by drip");
    }

    // The vault's spUSDC covers the queued deposits and cancellations until `take` or a redeem
    // fill (which is paid from the whole balance) spends some of it.
    function vaultInvariant_J_backing() public view {
        if (adminHandler.backingGapOpened()) return;

        assertGe(
            spUsdc.balanceOf(address(vault)),
            vault.pendingDepositSavingsShares() + vault.pendingCancelledDepositSavingsShares(),
            "invariant J: vault spUSDC below queued spUSDC"
        );
    }

    function vaultInvariant_K_roles() public view {
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE,     admin),           "invariant K: admin role lost");
        assertTrue(vault.hasRole(LOSS_MANAGER_ROLE,      lossManager),     "invariant K: loss manager role lost");
        assertTrue(vault.hasRole(OPERATOR_ROLE,          operator),        "invariant K: operator role lost");
        assertTrue(vault.hasRole(PAUSER_ROLE,            pauser),          "invariant K: pauser role lost");
        assertTrue(vault.hasRole(REDEEM_FEE_SETTER_ROLE, redeemFeeSetter), "invariant K: fee setter role lost");
        assertTrue(vault.hasRole(TAKER_ROLE,             taker),           "invariant K: taker role lost");
        assertTrue(vault.hasRole(UNPAUSER_ROLE,          unpauser),        "invariant K: unpauser role lost");

        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "invariant K: unexpected admin count");
    }

    // Escrow only enters through `requestRedeem` and only leaves through redeem fills.
    function vaultInvariant_L_escrowOnlyLeavesThroughRedeemFills() public view {
        assertEq(
            vault.balanceOf(address(vault)),
            userHandler.sharesEscrowed() - adminHandler.sharesFilled(),
            "invariant L: escrow != escrowed - filled"
        );
    }

    // Every fill pays floor(shares * chi / RAY), so the USDC paid out (or parked as claimable)
    // never exceeds the value of the shares burned; the shortfall is at most one wei per fill.
    function vaultInvariant_M_redeemPayoutsNeverExceedSharesBurned() public view {
        assertLe(
            adminHandler.redeemAssetsPaid(),
            adminHandler.redeemAssetsOwed(),
            "invariant M: redeem fills paid more than convertToAssets(shares burned)"
        );
    }

    function vaultInvariant_N_cancellationPayoutsNeverExceedSavingsSharesRedeemed() public view {
        assertLe(
            adminHandler.cancelAssetsPaid(),
            adminHandler.cancelAssetsOwed(),
            "invariant N: cancellation fills paid more than spUSDC.convertToAssets(shares redeemed)"
        );
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _sumShares(ISparkPrimeVault.Request[] memory requests_) internal pure returns (uint256 sum_) {
        for (uint256 i = 0; i < requests_.length; i++) {
            sum_ += requests_[i].shares;
        }
    }

    function _sumAssetsOf() internal view returns (uint256 sum_) {
        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            sum_ += vault.assetsOf(userHandler.users(i));
        }
    }

    // Gives the vault spUSDC worth at least `assets_` USDC.
    function _giveSavingsShares(uint256 assets_) internal {
        usdc.mint(address(this), assets_);

        usdc.approve(address(spUsdc), assets_);

        uint256 shares_ = spUsdc.deposit(assets_, address(this));

        spUsdc.transfer(address(vault), shares_);
    }

}
