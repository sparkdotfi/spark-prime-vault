// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";

import { TestBase } from "../TestBase.t.sol";

import { AdminHandler }                    from "./handlers/AdminHandler.sol";
import { ExternalHandler }                 from "./handlers/ExternalHandler.sol";
import { HandlerBase, ISavingsVaultLike }  from "./handlers/HandlerBase.sol";
import { UserHandler }                     from "./handlers/UserHandler.sol";

contract SparkPrimeVaultInvariantTestBase is TestBase {

    uint256 internal constant DEPOSIT_SLOT = 0;
    uint256 internal constant CANCEL_SLOT  = 1;
    uint256 internal constant REDEEM_SLOT  = 2;

    bytes32 internal constant SETTER_ROLE = keccak256("SETTER_ROLE");  // spUSDC

    address internal spSetter = makeAddr("spSetter");
    address internal spTaker  = makeAddr("spTaker");

    ISavingsVaultLike internal savings;  // spUSDC with the full surface the handlers use

    AdminHandler    internal adminHandler;
    ExternalHandler internal externalHandler;
    UserHandler     internal userHandler;

    function setUp() public virtual override {
        super.setUp();

        savings = ISavingsVaultLike(address(spUSDC));

        // spUSDC: own role holders so the handlers never depend on mainnet role membership,
        // no deposit cap, full rate range, and the same starting rate as spPrime.
        address spAdmin_ = savings.getRoleMember(DEFAULT_ADMIN_ROLE, 0);

        vm.startPrank(spAdmin_);
        savings.grantRole(SETTER_ROLE, spSetter);
        savings.grantRole(TAKER_ROLE,  spTaker);
        savings.setDepositCap(type(uint256).max);
        savings.setVsrBounds(RAY, MAX_VSR);
        vm.stopPrank();

        vm.prank(spSetter);
        savings.setVsr(FIVE_PCT_VSR);

        // spPrime: give the fee setter range.
        uint256 maxFee_ = spPrime.MAX_REDEEM_FEE();

        vm.prank(admin);
        spPrime.setMaxRedeemFeeRate(maxFee_);

        vm.label(spSetter, "spSetter");
        vm.label(spTaker,  "spTaker");
    }

    /**********************************************************************************************/
    /*** Vault invariant helpers                                                                ***/
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

    function vaultInvariant_C_supplyProvenance() public view {
        assertEq(
            spPrime.totalSupply(),
            userHandler.ghostMintedTotal()
                - userHandler.ghostFeesBurned()
                - adminHandler.ghostBurnedRedeemShares(),
            "invariant C: totalSupply != minted - fees - redeemed"
        );
    }

    function vaultInvariant_D_conversions() public view {
        uint256 chi_    = spPrime.nowChi();
        uint256 supply_ = spPrime.totalSupply();
        uint256 assets_ = spPrime.totalAssets();

        assertEq(assets_, supply_ * chi_ / RAY, "invariant D: totalAssets formula");

        _assertRoundTrips(assets_, supply_, chi_, "invariant D");
    }

    function vaultInvariant_E_chiRhoDrip() public {
        uint256 nowChi_ = spPrime.nowChi();

        assertGt(uint256(spPrime.chi()), 0,                   "invariant E: chi is zero");
        assertLe(spPrime.rho(),          block.timestamp,     "invariant E: rho in the future");
        assertGe(nowChi_,                uint256(spPrime.chi()), "invariant E: nowChi < chi");

        assertEq(uint256(spPrime.drip()), nowChi_,         "invariant E: drip != nowChi");
        assertEq(uint256(spPrime.chi()),  nowChi_,         "invariant E: chi not synced after drip");
        assertEq(spPrime.rho(),           block.timestamp, "invariant E: rho not updated by drip");
    }

    function vaultInvariant_F_configBounds() public view {
        assertGe(spPrime.vsr(),    RAY,              "invariant F: vsr < RAY");
        assertLe(spPrime.vsr(),    spPrime.MAX_VSR(), "invariant F: vsr > MAX_VSR");
        assertGe(spPrime.minVSR(), RAY,              "invariant F: minVSR < RAY");
        assertLe(spPrime.maxVSR(), spPrime.MAX_VSR(), "invariant F: maxVSR > MAX_VSR");
        assertLe(spPrime.minVSR(), spPrime.maxVSR(), "invariant F: minVSR > maxVSR");

        assertLe(spPrime.redeemFeeRate(),    spPrime.MAX_REDEEM_FEE(), "invariant F: redeemFeeRate > MAX_REDEEM_FEE");
        assertLe(spPrime.maxRedeemFeeRate(), spPrime.MAX_REDEEM_FEE(), "invariant F: maxRedeemFeeRate > MAX_REDEEM_FEE");

        assertGt(spPrime.minDeposit(),             0, "invariant F: minDeposit zero");
        assertGt(spPrime.minDepositCancellation(), 0, "invariant F: minDepositCancellation zero");
        assertGt(spPrime.minRedeem(),              1, "invariant F: minRedeem below 2");
    }

    function vaultInvariant_G_capacity() public view {
        uint256 cap_    = spPrime.maxCapacity();
        uint256 supply_ = spPrime.totalSupply();

        assertEq(
            spPrime.availableCapacity(),
            cap_ > supply_ ? cap_ - supply_ : 0,
            "invariant G: availableCapacity formula"
        );

        if (!adminHandler.capacityLoweredBelowSupply()) {
            assertLe(supply_, cap_, "invariant G: totalSupply above maxCapacity");
        }
    }

    function vaultInvariant_H_savingsFlowIdentity() public view {
        uint256 expected_ =
            userHandler.ghostSavingsSharesIn()
            + externalHandler.ghostSavingsReturned()
            + externalHandler.ghostSavingsDonated()
            - adminHandler.ghostSavingsOutCancel()
            - adminHandler.ghostSavingsOutRedeem()
            - adminHandler.ghostTakenSavingsShares();

        assertEq(
            savings.balanceOf(address(spPrime)),
            expected_,
            "invariant H: vault spUSDC != net recorded flows"
        );
    }

    function vaultInvariant_I_claimables() public view {
        uint256 sum_;

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            sum_ += spPrime.claimableAssets(userHandler.users(i));
        }

        assertEq(sum_, spPrime.totalClaimable(), "invariant I: sum(claimableAssets) != totalClaimable");

        assertEq(
            usdc.balanceOf(address(spPrime)),
            spPrime.totalClaimable() + externalHandler.ghostUsdcDonatedToVault(),
            "invariant I: vault USDC != totalClaimable + donations"
        );

        assertEq(
            userHandler.ghostClaimableCreditedTotal() - userHandler.ghostClaimedTotal(),
            spPrime.totalClaimable(),
            "invariant I: credited - claimed != totalClaimable"
        );
    }

    function vaultInvariant_J_usdcPaidOut() public view {
        uint256 sum_;

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            sum_ += usdc.balanceOf(userHandler.users(i));
        }

        assertEq(
            sum_,
            adminHandler.ghostRedeemPaidAssets()
                + adminHandler.ghostCancelPaidAssets()
                - userHandler.ghostClaimableCreditedTotal()
                + userHandler.ghostClaimedTotal(),
            "invariant J: user USDC != fills paid directly + claims"
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

        assertTrue(savings.hasRole(SETTER_ROLE, spSetter), "invariant K: spUSDC setter role lost");
        assertTrue(savings.hasRole(TAKER_ROLE,  spTaker),  "invariant K: spUSDC taker role lost");

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            assertEq(savings.balanceOf(userHandler.users(i)), 0, "invariant K: user holds spUSDC");
        }
    }

    function vaultInvariant_L_backing() public view {
        if (savings.balanceOf(taker) != 0)          return;  // take() opened a gap by design
        if (adminHandler.gapWidenedByRedeemFill())  return;  // redeem fills spend queue backing by design

        assertGe(
            savings.balanceOf(address(spPrime)),
            spPrime.pendingDepositSavingsShares() + spPrime.pendingCancelledDepositSavingsShares(),
            "invariant L: vault spUSDC below queued spUSDC"
        );
    }

    /**********************************************************************************************/
    /*** Queue invariant helpers                                                                ***/
    /**********************************************************************************************/

    function queueInvariant_A_pendingSums() public view {
        assertEq(
            _sumShares(spPrime.getPendingDepositRequests()),
            spPrime.pendingDepositSavingsShares(),
            "invariant QA: pendingDepositSavingsShares != sum of window"
        );
        assertEq(
            _sumShares(spPrime.getPendingDepositCancellationRequests()),
            spPrime.pendingCancelledDepositSavingsShares(),
            "invariant QA: pendingCancelledDepositSavingsShares != sum of window"
        );
        assertEq(
            _sumShares(spPrime.getPendingRedeemRequests()),
            spPrime.pendingRedeemShares(),
            "invariant QA: pendingRedeemShares != sum of window"
        );
    }

    function queueInvariant_B_headsAndLengths() public view {
        uint256 depositLength_ = _rawLength(DEPOSIT_SLOT);
        uint256 cancelLength_  = _rawLength(CANCEL_SLOT);
        uint256 redeemLength_  = _rawLength(REDEEM_SLOT);

        assertEq(depositLength_, userHandler.depositQueueLength(), "invariant QB: deposit length mirror");
        assertEq(cancelLength_,  userHandler.cancelQueueLength(),  "invariant QB: cancellation length mirror");
        assertEq(redeemLength_,  userHandler.redeemQueueLength(),  "invariant QB: redeem length mirror");

        uint256 depositHead_ = spPrime.firstPendingDepositId();
        uint256 cancelHead_  = spPrime.firstPendingDepositCancellationId();
        uint256 redeemHead_  = spPrime.firstPendingRedeemId();

        assertLe(depositHead_, depositLength_, "invariant QB: deposit head past length");
        assertLe(cancelHead_,  cancelLength_,  "invariant QB: cancellation head past length");
        assertLe(redeemHead_,  redeemLength_,  "invariant QB: redeem head past length");

        assertEq(spPrime.getPendingDepositRequests().length,             depositLength_ - depositHead_, "invariant QB: deposit window length");
        assertEq(spPrime.getPendingDepositCancellationRequests().length, cancelLength_  - cancelHead_,  "invariant QB: cancellation window length");
        assertEq(spPrime.getPendingRedeemRequests().length,              redeemLength_  - redeemHead_,  "invariant QB: redeem window length");
    }

    function queueInvariant_C_entriesWellFormed() public view {
        _assertClosedBelowHead(DEPOSIT_SLOT, spPrime.firstPendingDepositId(),             false);
        _assertClosedBelowHead(CANCEL_SLOT,  spPrime.firstPendingDepositCancellationId(), true);
        _assertClosedBelowHead(REDEEM_SLOT,  spPrime.firstPendingRedeemId(),              true);

        _assertWindowWellFormed(DEPOSIT_SLOT, spPrime.firstPendingDepositId(),             false);
        _assertWindowWellFormed(CANCEL_SLOT,  spPrime.firstPendingDepositCancellationId(), true);
        _assertWindowWellFormed(REDEEM_SLOT,  spPrime.firstPendingRedeemId(),              true);
    }

    function queueInvariant_F_emptyQueueCorollaries() public view {
        assertEq(
            spPrime.pendingCancelledDepositSavingsShares() == 0,
            spPrime.firstPendingDepositCancellationId() == _rawLength(CANCEL_SLOT),
            "invariant QF: cancellation queue empty iff head at end"
        );
        assertEq(
            spPrime.pendingRedeemShares() == 0,
            spPrime.firstPendingRedeemId() == _rawLength(REDEEM_SLOT),
            "invariant QF: redeem queue empty iff head at end"
        );

        if (spPrime.pendingDepositSavingsShares() == 0) {
            ISparkPrimeVault.Request[] memory window_ = spPrime.getPendingDepositRequests();

            for (uint256 i = 0; i < window_.length; i++) {
                assertEq(window_[i].shares, 0, "invariant QF: open deposit entry with zero pending");
            }
        }
    }

    function queueInvariant_G_getterConsistency() public {
        _assertGetters(DEPOSIT_SLOT, spPrime.firstPendingDepositId());
        _assertGetters(CANCEL_SLOT,  spPrime.firstPendingDepositCancellationId());
        _assertGetters(REDEEM_SLOT,  spPrime.firstPendingRedeemId());
    }

    /**********************************************************************************************/
    /*** User invariant helpers                                                                 ***/
    /**********************************************************************************************/

    function userInvariant_A_balanceProvenance(address user_) public view {
        assertEq(
            spPrime.balanceOf(user_),
            userHandler.ghostMinted(user_)
                + userHandler.ghostTransferIn(user_)
                - userHandler.ghostTransferOut(user_)
                - userHandler.ghostEscrowed(user_),
            string(abi.encodePacked("invariant UA: balance provenance for ", vm.toString(user_)))
        );
    }

    function userInvariant_B_assetsOf(address user_) public view {
        uint256 assets_ = spPrime.assetsOf(user_);

        assertEq(assets_, spPrime.convertToAssets(spPrime.balanceOf(user_)), "invariant UB: assetsOf formula");
        assertLe(assets_, spPrime.totalAssets(),                             "invariant UB: assetsOf > totalAssets");
    }

    function userInvariant_C_assetsOfCannotDecrease(address user_) public view {
        assertGe(
            spPrime.assetsOf(user_),
            userHandler.lastAssetsOf(user_),
            string(abi.encodePacked("invariant UC: assetsOf decreased for ", vm.toString(user_)))
        );
    }

    function userInvariant_D_claimableProvenance(address user_) public view {
        uint256 claimable_ = spPrime.claimableAssets(user_);

        assertEq(
            claimable_,
            userHandler.ghostClaimableCredited(user_) - userHandler.ghostClaimed(user_),
            "invariant UD: claimable provenance"
        );
        assertLe(claimable_, spPrime.totalClaimable(), "invariant UD: claimable > totalClaimable");
    }

    function userInvariant_E_conversionRoundTrips(address user_) public view {
        _assertRoundTrips(spPrime.assetsOf(user_), spPrime.balanceOf(user_), spPrime.nowChi(), "invariant UE");
    }

    function userInvariant_F_usdcProvenance(address user_) public view {
        assertEq(
            usdc.balanceOf(user_),
            userHandler.ghostPaidDirect(user_) + userHandler.ghostClaimed(user_),
            string(abi.encodePacked("invariant UF: USDC provenance for ", vm.toString(user_)))
        );
    }

    /**********************************************************************************************/
    /*** Internal helpers                                                                       ***/
    /**********************************************************************************************/

    function _assertRoundTrips(uint256 assets_, uint256 shares_, uint256 chi_, string memory tag_)
        internal view
    {
        // chi is unbounded upward and can sit below RAY after a loss, so the round-trip slack is
        // one unit of the other denomination plus one.
        uint256 assetsBack_ = spPrime.convertToAssets(spPrime.convertToShares(assets_));
        uint256 sharesBack_ = spPrime.convertToShares(spPrime.convertToAssets(shares_));

        assertLe(assetsBack_, assets_, string(abi.encodePacked(tag_, ": assets round trip above")));
        assertLe(sharesBack_, shares_, string(abi.encodePacked(tag_, ": shares round trip above")));

        assertGe(assetsBack_ + chi_ / RAY + 1, assets_, string(abi.encodePacked(tag_, ": assets round trip below")));
        assertGe(sharesBack_ + RAY / chi_ + 1, shares_, string(abi.encodePacked(tag_, ": shares round trip below")));
    }

    function _sumShares(ISparkPrimeVault.Request[] memory requests_) internal pure returns (uint256 sum_) {
        for (uint256 i = 0; i < requests_.length; i++) {
            sum_ += requests_[i].shares;
        }
    }

    // Every entry strictly below a head is closed. The deposit queue only guarantees zero shares
    // (zero-share deposits are skipped, never deleted); the other two queues delete the entry.
    function _assertClosedBelowHead(uint256 slot_, uint256 head_, bool fullyDeleted_) internal view {
        for (uint256 i = 0; i < head_; i++) {
            ( address owner_, address recipient_, uint256 shares_ ) = _rawRequest(slot_, i);

            assertEq(shares_, 0, "invariant QC: open entry below head");

            if (fullyDeleted_) {
                assertEq(owner_,     address(0), "invariant QC: owner left below head");
                assertEq(recipient_, address(0), "invariant QC: recipient left below head");
            }
        }
    }

    // Every nonzero entry in a window has a valid owner and recipient; the cancellation and
    // redeem windows contain no zero entries at all.
    function _assertWindowWellFormed(uint256 slot_, uint256 head_, bool nonZero_) internal view {
        uint256 length_ = _rawLength(slot_);

        for (uint256 i = head_; i < length_; i++) {
            ( address owner_, address recipient_, uint256 shares_ ) = _rawRequest(slot_, i);

            if (nonZero_) assertGt(shares_, 0, "invariant QC: zero entry in window");

            if (shares_ == 0) continue;

            assertTrue(owner_     != address(0),      "invariant QC: open entry without owner");
            assertTrue(recipient_ != address(0),      "invariant QC: open entry without recipient");
            assertTrue(recipient_ != address(spPrime), "invariant QC: vault is recipient");
            assertGt(userHandler.userIndexPlusOne(owner_),     0, "invariant QC: owner not a tracked user");
            assertGt(userHandler.userIndexPlusOne(recipient_), 0, "invariant QC: recipient not a tracked user");
        }
    }

    // Single getter, ranged getter and raw storage agree on every id in the window, and the
    // getters refuse ids below the head and ranges past the end.
    function _assertGetters(uint256 slot_, uint256 head_) internal {
        uint256 length_ = _rawLength(slot_);

        ISparkPrimeVault.Request[] memory window_ = _window(slot_);

        for (uint256 i = head_; i < length_; i++) {
            ( address owner_, address recipient_, uint256 shares_ ) = _single(slot_, i);
            ( address rawOwner_, address rawRecipient_, uint256 rawShares_ ) = _rawRequest(slot_, i);

            assertEq(owner_,     rawOwner_,     "invariant QG: getter owner != raw");
            assertEq(recipient_, rawRecipient_, "invariant QG: getter recipient != raw");
            assertEq(shares_,    rawShares_,    "invariant QG: getter shares != raw");

            assertEq(window_[i - head_].owner,     owner_,     "invariant QG: window owner != single");
            assertEq(window_[i - head_].recipient, recipient_, "invariant QG: window recipient != single");
            assertEq(window_[i - head_].shares,    shares_,    "invariant QG: window shares != single");
        }

        if (head_ > 0) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            _single(slot_, head_ - 1);

            vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
            _ranged(slot_, head_ - 1, 1);
        }

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        _single(slot_, length_);

        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        _ranged(slot_, head_, length_ - head_ + 1);
    }

    function _window(uint256 slot_) internal view returns (ISparkPrimeVault.Request[] memory) {
        if (slot_ == DEPOSIT_SLOT) return spPrime.getPendingDepositRequests();
        if (slot_ == CANCEL_SLOT)  return spPrime.getPendingDepositCancellationRequests();
        return spPrime.getPendingRedeemRequests();
    }

    function _single(uint256 slot_, uint256 id_)
        internal view returns (address, address, uint256)
    {
        if (slot_ == DEPOSIT_SLOT) return spPrime.getPendingDepositRequest(id_);
        if (slot_ == CANCEL_SLOT)  return spPrime.getPendingDepositCancellationRequest(id_);
        return spPrime.getPendingRedeemRequest(id_);
    }

    function _ranged(uint256 slot_, uint256 start_, uint256 length_)
        internal view returns (ISparkPrimeVault.Request[] memory)
    {
        if (slot_ == DEPOSIT_SLOT) return spPrime.getPendingDepositRequests(start_, length_);
        if (slot_ == CANCEL_SLOT)  return spPrime.getPendingDepositCancellationRequests(start_, length_);
        return spPrime.getPendingRedeemRequests(start_, length_);
    }

    function _rawLength(uint256 slot_) internal view returns (uint256) {
        return uint256(vm.load(address(spPrime), bytes32(slot_)));
    }

    function _rawRequest(uint256 slot_, uint256 id_)
        internal view returns (address owner_, address recipient_, uint256 shares_)
    {
        uint256 base_ = uint256(keccak256(abi.encode(slot_))) + 3 * id_;

        owner_     = address(uint160(uint256(vm.load(address(spPrime), bytes32(base_)))));
        recipient_ = address(uint160(uint256(vm.load(address(spPrime), bytes32(base_ + 1)))));
        shares_    = uint256(vm.load(address(spPrime), bytes32(base_ + 2)));
    }

    function _sumAssetsOf() internal view returns (uint256 sum_) {
        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            sum_ += spPrime.assetsOf(userHandler.users(i));
        }
    }

}
