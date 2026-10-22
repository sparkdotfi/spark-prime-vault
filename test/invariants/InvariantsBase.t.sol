// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";

import { TestBase } from "../TestBase.t.sol";

import { AdminHandler }                   from "./handlers/AdminHandler.sol";
import { ExternalHandler }                from "./handlers/ExternalHandler.sol";
import { HandlerBase, ISavingsVaultLike, IUSDCLike } from "./handlers/HandlerBase.sol";
import { UserHandler }                    from "./handlers/UserHandler.sol";

contract SparkPrimeVaultInvariantTestBase is TestBase {

    bytes32 internal constant SETTER_ROLE = keccak256("SETTER_ROLE");  // spUSDC

    address internal spSetter = makeAddr("spSetter");
    address internal spTaker  = makeAddr("spTaker");

    ISavingsVaultLike internal savings;    // spUSDC with the surface the handlers use
    IUSDCLike         internal fiatToken;  // USDC with the blacklist surface

    AdminHandler    internal adminHandler;
    ExternalHandler internal externalHandler;
    UserHandler     internal userHandler;

    function setUp() public virtual override {
        super.setUp();

        savings   = ISavingsVaultLike(address(spUSDC));
        fiatToken = IUSDCLike(address(usdc));

        // spUSDC: own role holders, no deposit cap, full rate range.
        address spAdmin_ = savings.getRoleMember(DEFAULT_ADMIN_ROLE, 0);

        vm.startPrank(spAdmin_);
        savings.grantRole(SETTER_ROLE, spSetter);
        savings.grantRole(TAKER_ROLE,  spTaker);
        savings.setDepositCap(type(uint256).max);
        savings.setVsrBounds(RAY, MAX_VSR);
        vm.stopPrank();

        vm.prank(spSetter);
        savings.setVsr(FIVE_PCT_VSR);

        _setMaxRedeemFeeRate(spPrime.MAX_REDEEM_FEE());

        vm.label(spSetter, "spSetter");
        vm.label(spTaker,  "spTaker");
    }

    /**********************************************************************************************/
    /*** Vault Invariant Helpers                                                                ***/
    /**********************************************************************************************/

    function vaultInvariant_A_sumBalancesPlusEscrowEqTotalSupply() public view {
        uint256 sum_ = spPrime.balanceOf(address(spPrime));

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            sum_ += spPrime.balanceOf(userHandler.users(i));
        }

        assertEq(sum_, spPrime.totalSupply(), "invariant A: sum(balances) + escrow != totalSupply");
    }

    function vaultInvariant_B_escrowEqPendingRedeemShares() public view {
        assertEq(
            spPrime.balanceOf(address(spPrime)),
            spPrime.pendingRedeemShares(),
            "invariant B: escrow != pendingRedeemShares"
        );
    }

    function vaultInvariant_C_assetConversions() public view {
        uint256 chi_ = spPrime.nowChi();

        assertEq(spPrime.totalAssets(), spPrime.totalSupply() * chi_ / RAY, "invariant C: totalAssets formula");

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            address user_ = userHandler.users(i);

            assertEq(spPrime.assetsOf(user_), spPrime.balanceOf(user_) * chi_ / RAY, "invariant C: assetsOf formula");
            assertLe(spPrime.assetsOf(user_), spPrime.totalAssets(),                 "invariant C: assetsOf > totalAssets");
        }
    }

    function vaultInvariant_D_pendingSharesEqSumOfQueues() public view {
        assertEq(
            _sumShares(spPrime.getPendingDepositRequests()),
            spPrime.pendingDepositSavingsShares(),
            "invariant D: pendingDepositSavingsShares != sum(deposit queue)"
        );
        assertEq(
            _sumShares(spPrime.getPendingDepositCancellationRequests()),
            spPrime.pendingCancelledDepositSavingsShares(),
            "invariant D: pendingCancelledDepositSavingsShares != sum(cancellation queue)"
        );
        assertEq(
            _sumShares(spPrime.getPendingRedeemRequests()),
            spPrime.pendingRedeemShares(),
            "invariant D: pendingRedeemShares != sum(redeem queue)"
        );
    }

    function vaultInvariant_E_queueHeadsAndLengths() public view {
        assertEq(
            spPrime.firstPendingDepositId() + spPrime.getPendingDepositRequests().length,
            userHandler.depositQueueLength(),
            "invariant E: deposit head + window != requests made"
        );
        assertEq(
            spPrime.firstPendingDepositCancellationId() + spPrime.getPendingDepositCancellationRequests().length,
            userHandler.depositCancellationQueueLength(),
            "invariant E: cancellation head + window != requests made"
        );
        assertEq(
            spPrime.firstPendingRedeemId() + spPrime.getPendingRedeemRequests().length,
            userHandler.redeemQueueLength(),
            "invariant E: redeem head + window != requests made"
        );
    }

    function vaultInvariant_F_claimables() public view {
        uint256 sum_;

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            sum_ += spPrime.claimableAssets(userHandler.users(i));
        }

        assertEq(sum_,                             spPrime.totalClaimable(), "invariant F: sum(claimableAssets) != totalClaimable");
        assertEq(usdc.balanceOf(address(spPrime)), spPrime.totalClaimable(), "invariant F: vault USDC != totalClaimable");
    }

    function vaultInvariant_G_configBounds() public view {
        assertGe(spPrime.vsr(),    RAY,               "invariant G: vsr < RAY");
        assertLe(spPrime.vsr(),    spPrime.MAX_VSR(), "invariant G: vsr > MAX_VSR");
        assertGe(spPrime.minVSR(), RAY,               "invariant G: minVSR < RAY");
        assertLe(spPrime.maxVSR(), spPrime.MAX_VSR(), "invariant G: maxVSR > MAX_VSR");
        assertLe(spPrime.minVSR(), spPrime.maxVSR(),  "invariant G: minVSR > maxVSR");

        // Lowering `maxRedeemFeeRate` does not clamp the live fee, so only the constant cap holds.
        assertLe(spPrime.redeemFeeRate(),    spPrime.MAX_REDEEM_FEE(), "invariant G: redeemFeeRate > MAX_REDEEM_FEE");
        assertLe(spPrime.maxRedeemFeeRate(), spPrime.MAX_REDEEM_FEE(), "invariant G: maxRedeemFeeRate > MAX_REDEEM_FEE");

        assertGt(spPrime.minDeposit(),             0, "invariant G: minDeposit zero");
        assertGt(spPrime.minDepositCancellation(), 0, "invariant G: minDepositCancellation zero");
        assertGt(spPrime.minRedeem(),              0, "invariant G: minRedeem zero");
    }

    function vaultInvariant_H_capacity() public view {
        uint256 cap_    = spPrime.maxCapacity();
        uint256 supply_ = spPrime.totalSupply();

        assertEq(
            spPrime.availableCapacity(),
            cap_ > supply_ ? cap_ - supply_ : 0,
            "invariant H: availableCapacity formula"
        );

        if (!adminHandler.capacityLoweredBelowSupply()) {
            assertLe(supply_, cap_, "invariant H: totalSupply above maxCapacity");
        }
    }

    function vaultInvariant_I_chiRhoDrip() public {
        uint256 nowChi_ = spPrime.nowChi();

        assertGt(uint256(spPrime.chi()), 0,                      "invariant I: chi is zero");
        assertLe(spPrime.rho(),          block.timestamp,        "invariant I: rho in the future");
        assertGe(nowChi_,                uint256(spPrime.chi()), "invariant I: nowChi < chi");

        assertEq(uint256(spPrime.drip()), nowChi_,         "invariant I: drip != nowChi");
        assertEq(uint256(spPrime.chi()),  nowChi_,         "invariant I: chi not synced after drip");
        assertEq(spPrime.rho(),           block.timestamp, "invariant I: rho not updated by drip");
    }

    // The vault's spUSDC covers the queued deposits and cancellations until `take` or a redeem
    // fill (which is paid from the whole balance) spends some of it.
    function vaultInvariant_J_backing() public view {
        if (adminHandler.backingGapOpened()) return;

        assertGe(
            savings.balanceOf(address(spPrime)),
            spPrime.pendingDepositSavingsShares() + spPrime.pendingCancelledDepositSavingsShares(),
            "invariant J: vault spUSDC below queued spUSDC"
        );
    }

    function vaultInvariant_K_roles() public view {
        assertTrue(spPrime.hasRole(DEFAULT_ADMIN_ROLE,     admin),           "invariant K: admin role lost");
        assertTrue(spPrime.hasRole(LOSS_MANAGER_ROLE,      lossManager),     "invariant K: loss manager role lost");
        assertTrue(spPrime.hasRole(OPERATOR_ROLE,          operator),        "invariant K: operator role lost");
        assertTrue(spPrime.hasRole(PAUSER_ROLE,            pauser),          "invariant K: pauser role lost");
        assertTrue(spPrime.hasRole(REDEEM_FEE_SETTER_ROLE, redeemFeeSetter), "invariant K: fee setter role lost");
        assertTrue(spPrime.hasRole(TAKER_ROLE,             taker),           "invariant K: taker role lost");
        assertTrue(spPrime.hasRole(UNPAUSER_ROLE,          unpauser),        "invariant K: unpauser role lost");

        assertEq(spPrime.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "invariant K: unexpected admin count");
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
            sum_ += spPrime.assetsOf(userHandler.users(i));
        }
    }

    // Gives the vault spUSDC worth at least `assets_` USDC.
    function _giveSavingsShares(uint256 assets_) internal {
        deal(address(usdc), address(this), usdc.balanceOf(address(this)) + assets_);

        usdc.approve(address(savings), assets_);

        uint256 shares_ = savings.deposit(assets_, address(this));

        savings.transfer(address(spPrime), shares_);
    }

}
