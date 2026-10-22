// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { SparkPrimeVaultInvariantTestBase } from "./InvariantsBase.t.sol";

import { AdminHandler }    from "./handlers/AdminHandler.sol";
import { ExternalHandler } from "./handlers/ExternalHandler.sol";
import { UserHandler }     from "./handlers/UserHandler.sol";

contract SparkPrimeVaultInvariantTest is SparkPrimeVaultInvariantTestBase {

    uint256 internal constant NUM_USERS = 10;

    function setUp() public override {
        super.setUp();

        userHandler     = new UserHandler(address(spPrime), NUM_USERS);
        adminHandler    = new AdminHandler(address(spPrime), NUM_USERS);
        externalHandler = new ExternalHandler(address(spPrime), NUM_USERS, spSetter, spTaker);

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
    }

    /**********************************************************************************************/
    /*** Post-Invariant: full settlement                                                        ***/
    /**********************************************************************************************/

    function afterInvariant() public {
        _checkInvariantsOverTime();

        // 1. Normalise: unpause, unblacklist, bring every taken spUSDC share and every drained USDC
        //    back, freeze both indexes and open the capacity.
        if (spPrime.paused()) _unpause();

        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user_ = userHandler.users(i);

            if (!fiatToken.isBlacklisted(user_)) continue;

            vm.prank(fiatToken.blacklister());
            fiatToken.unBlacklist(user_);
        }

        uint256 takenShares_      = savings.balanceOf(taker);
        uint256 drainedLiquidity_ = usdc.balanceOf(spTaker);

        vm.prank(taker);
        savings.transfer(address(spPrime), takenShares_);

        vm.prank(spTaker);
        fiatToken.transfer(address(savings), drainedLiquidity_);

        vm.prank(admin);
        spPrime.setVSRBounds(RAY, RAY);

        vm.prank(operator);
        spPrime.setVSR(RAY);

        vm.prank(spSetter);
        savings.setVsr(RAY);

        _setCapacity(type(uint128).max);

        _checkInvariantsOverTime();

        // 2. Deposits: one walk fills everything with the capacity open.
        _processPendingDeposits();

        assertEq(spPrime.pendingDepositSavingsShares(), 0, "afterInvariant: deposit queue not drained");

        // 3. Cancellations: top the vault up if redeem fills or `take` spent the backing, then drain.
        uint256 owed_ = spPrime.pendingCancelledDepositSavingsShares();
        uint256 held_ = savings.balanceOf(address(spPrime));

        if (held_ < owed_) _giveSavingsShares((owed_ - held_) * savings.nowChi() / RAY + 2);

        _processPendingDepositCancellations(type(uint256).max, type(uint256).max);

        assertEq(spPrime.pendingCancelledDepositSavingsShares(), 0, "afterInvariant: cancellation queue not drained");

        _checkInvariantsOverTime();

        // 4. Every holder redeems everything (no fee, minRedeem 1 so dust balances can exit).
        _setRedeemFeeRate(0);

        vm.prank(admin);
        spPrime.setMinRedeem(1);

        for (uint256 i = 0; i < NUM_USERS; i++) {
            uint256 balance_ = spPrime.balanceOf(userHandler.users(i));

            // Seeds `i` resolve to user `i`; the exact balance is within the handler's bounds.
            if (balance_ != 0) userHandler.requestRedeem(balance_, i, i);
        }

        assertEq(spPrime.balanceOf(address(spPrime)), spPrime.totalSupply(), "afterInvariant: supply not fully escrowed");

        // 5. Give the vault whatever spUSDC and liquidity it is short of. The shortfall is notional
        //    created by positive `adjustTotalAssets` plus one spUSDC share of rounding per fill.
        uint256 fills_       = spPrime.getPendingRedeemRequests().length;
        uint256 savingsUnit_ = savings.nowChi() / RAY + 1;  // USDC value of one spUSDC share, rounded up

        uint256 needed_ = spPrime.convertToAssets(spPrime.pendingRedeemShares()) + (fills_ + 2) * savingsUnit_;
        uint256 have_   = savings.assetsOf(address(spPrime));

        if (have_ < needed_) _giveSavingsShares(needed_ - have_);

        deal(address(usdc), address(savings), usdc.balanceOf(address(savings)) + needed_);

        _processPendingRedeems();

        assertEq(spPrime.pendingRedeemShares(),       0, "afterInvariant: redeem queue not drained");
        assertEq(spPrime.totalSupply(),               0, "afterInvariant: totalSupply != 0 after full exit");
        assertEq(spPrime.balanceOf(address(spPrime)), 0, "afterInvariant: escrow left after full exit");

        // 6. Claims: nobody is blacklisted any more, so every claimable is payable.
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user_ = userHandler.users(i);

            if (spPrime.claimableAssets(user_) != 0) spPrime.claim(user_);
        }

        assertEq(spPrime.totalClaimable(),             0, "afterInvariant: claimables left");
        assertEq(usdc.balanceOf(address(spPrime)),     0, "afterInvariant: vault still holds USDC");
        assertEq(spPrime.totalAssets(),                0, "afterInvariant: totalAssets != 0");

        _checkInvariantsOverTime();
    }

    /**********************************************************************************************/
    /*** Internal Helpers                                                                       ***/
    /**********************************************************************************************/

    function _checkInvariantsOverTime() internal {
        this.invariant_vaultInvariants();

        uint256 sumAssetsBefore_   = _sumAssetsOf();
        uint256 totalAssetsBefore_ = spPrime.totalAssets();

        skip(30 minutes);

        // With no interactions, holdings can only grow over time.
        assertGe(_sumAssetsOf(),        sumAssetsBefore_,   "checkInvariantsOverTime: sum(assetsOf) decreased");
        assertGe(spPrime.totalAssets(), totalAssetsBefore_, "checkInvariantsOverTime: totalAssets decreased");

        this.invariant_vaultInvariants();
    }

}
