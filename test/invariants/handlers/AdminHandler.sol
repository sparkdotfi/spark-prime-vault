// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISparkPrimeVault } from "../../../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../../src/SparkPrimeVault.sol";

import { HandlerBase } from "./HandlerBase.sol";
import { UserHandler } from "./UserHandler.sol";

contract AdminHandler is HandlerBase {

    // Practical window for chi after `adjustTotalAssets` (the contract allows (0, uint192.max]).
    uint256 internal constant MIN_CHI = 1e21;
    uint256 internal constant MAX_CHI = 1e33;

    UserHandler internal userHandler;

    address public admin;
    address public lossManager;
    address public operator;
    address public pauser;
    address public redeemFeeSetter;
    address public taker;
    address public unpauser;

    // Ghost variables tracking admin-driven flows.
    uint256 public ghostTakenSavingsShares;   // spUSDC pulled by the taker
    uint256 public ghostBurnedRedeemShares;   // vault shares burned by redeem fills
    uint256 public ghostSavingsOutRedeem;     // spUSDC burned by redeem fills
    uint256 public ghostSavingsOutCancel;     // spUSDC burned by cancellation fills
    uint256 public ghostRedeemPaidAssets;     // USDC owed by redeem fills (paid or parked)
    uint256 public ghostCancelPaidAssets;     // USDC owed by cancellation fills (paid or parked)
    uint256 public ghostRedeemFills;          // entries touched by redeem fills
    int256  public ghostAdjustNet;            // sum of adjustTotalAssets deltas [USDC]
    int256  public ghostAdjustNetShares;      // the same, in vault shares at the post-call chi (upper bound ledger)

    bool public capacityLoweredBelowSupply;   // setCapacity(cap < totalSupply) happened
    bool public gapWidenedByRedeemFill;       // a redeem fill spent spUSDC backing the queues
    bool public rateOrderBroken;              // spPrime vsr above spUSDC vsr at some point

    // Spare implementations to exercise UUPS upgrades against identical bytecode.
    SparkPrimeVault[2] internal spareImplementations;

    constructor(address spPrime_, UserHandler userHandler_) HandlerBase(spPrime_) {
        userHandler = userHandler_;

        for (uint256 i = 0; i < userHandler_.numUsers(); i++) {
            users.push(userHandler_.users(i));
        }

        admin           = spPrime.getRoleMember(DEFAULT_ADMIN_ROLE,     0);
        lossManager     = spPrime.getRoleMember(LOSS_MANAGER_ROLE,      0);
        operator        = spPrime.getRoleMember(OPERATOR_ROLE,          0);
        pauser          = spPrime.getRoleMember(PAUSER_ROLE,            0);
        redeemFeeSetter = spPrime.getRoleMember(REDEEM_FEE_SETTER_ROLE, 0);
        taker           = spPrime.getRoleMember(TAKER_ROLE,             0);
        unpauser        = spPrime.getRoleMember(UNPAUSER_ROLE,          0);

        spareImplementations[0] = new SparkPrimeVault();
        spareImplementations[1] = new SparkPrimeVault();
    }

    /**********************************************************************************************/
    /*** Setters                                                                                ***/
    /**********************************************************************************************/

    function setVSRBounds(uint256 minVSR_, uint256 maxVSR_)
        public
        checked(CHECK_ALL)
    {
        minVSR_ = _bound(minVSR_, RAY,     spPrime.MAX_VSR());
        maxVSR_ = _bound(maxVSR_, minVSR_, spPrime.MAX_VSR());

        vm.prank(admin);
        spPrime.setVSRBounds(minVSR_, maxVSR_);

        assertEq(spPrime.minVSR(), minVSR_, "setVSRBounds: minVSR not set");
        assertEq(spPrime.maxVSR(), maxVSR_, "setVSRBounds: maxVSR not set");
    }

    function setVSR(uint256 vsr_, uint256 seed_)
        public
        checked(CHECK_ALL)
    {
        uint256 minVSR_ = spPrime.minVSR();
        uint256 maxVSR_ = spPrime.maxVSR();

        // Keep spPrime's rate at or below spUSDC's most of the time so the solvency bound stays
        // meaningful; one call in eight is free to break the order.
        if (seed_ % 8 != 0) maxVSR_ = _max(minVSR_, _min(maxVSR_, spUSDC.vsr()));

        vsr_ = _bound(vsr_, minVSR_, maxVSR_);

        vm.prank(operator);
        spPrime.setVSR(vsr_);

        assertEq(spPrime.vsr(),          vsr_,            "setVSR: vsr not set");
        assertEq(spPrime.rho(),          block.timestamp, "setVSR: rho not updated");
        assertEq(uint256(spPrime.chi()), spPrime.nowChi(), "setVSR: chi not synced");

        if (vsr_ > spUSDC.vsr()) rateOrderBroken = true;
    }

    function setCapacity(uint256 capacity_)
        public
        checked(CHECK_ALL)
    {
        uint256 supply_ = spPrime.totalSupply();

        // Never near uint256.max: `convertToAssets(availableCapacity())` would overflow.
        capacity_ = _bound(capacity_, 0, _min(supply_ + MAX_AMOUNT, type(uint128).max));

        vm.prank(operator);
        spPrime.setCapacity(capacity_);

        assertEq(spPrime.maxCapacity(), capacity_, "setCapacity: capacity not set");

        if (capacity_ < supply_) capacityLoweredBelowSupply = true;
    }

    function setMaxRedeemFeeRate(uint256 feeRate_)
        public
        checked(CHECK_ALL)
    {
        feeRate_ = _bound(feeRate_, 0, spPrime.MAX_REDEEM_FEE());

        vm.prank(admin);
        spPrime.setMaxRedeemFeeRate(feeRate_);

        assertEq(spPrime.maxRedeemFeeRate(), feeRate_, "setMaxRedeemFeeRate: not set");
    }

    function setRedeemFeeRate(uint256 feeRate_)
        public
        checked(CHECK_ALL)
    {
        feeRate_ = _bound(feeRate_, 0, spPrime.maxRedeemFeeRate());

        vm.prank(redeemFeeSetter);
        spPrime.setRedeemFeeRate(feeRate_);

        assertEq(spPrime.redeemFeeRate(), feeRate_, "setRedeemFeeRate: not set");
    }

    function setMinDeposit(uint256 minDeposit_)
        public
        checked(CHECK_ALL)
    {
        // At least one USDC so a deposit always mints spUSDC shares.
        minDeposit_ = _bound(minDeposit_, 1e6, 1_000e6);

        vm.prank(admin);
        spPrime.setMinDeposit(minDeposit_);

        assertEq(spPrime.minDeposit(), minDeposit_, "setMinDeposit: not set");
    }

    function setMinDepositCancellation(uint256 minDepositCancellation_)
        public
        checked(CHECK_ALL)
    {
        minDepositCancellation_ = _bound(minDepositCancellation_, 1, 1_000e6);

        vm.prank(admin);
        spPrime.setMinDepositCancellation(minDepositCancellation_);

        assertEq(spPrime.minDepositCancellation(), minDepositCancellation_, "setMinDepositCancellation: not set");
    }

    function setMinRedeem(uint256 minRedeem_)
        public
        checked(CHECK_ALL)
    {
        // Never 1: a one-share redeem with any nonzero fee burns the whole share and queues a
        // zero-share entry.
        minRedeem_ = _bound(minRedeem_, 2, 1_000e6);

        vm.prank(admin);
        spPrime.setMinRedeem(minRedeem_);

        assertEq(spPrime.minRedeem(), minRedeem_, "setMinRedeem: not set");
    }

    /**********************************************************************************************/
    /*** Pause and loss management                                                              ***/
    /**********************************************************************************************/

    function pause(uint256 seed_)
        public
        checked(CHECK_ALL)
    {
        if (seed_ % 4 != 0) return;  // keep the vault unpaused most of the time

        vm.prank(pauser);
        spPrime.pause();

        assertTrue(spPrime.paused(), "pause: not paused");
    }

    function unpause()
        public
        checked(CHECK_ALL)
    {
        vm.prank(unpauser);
        spPrime.unpause();

        assertFalse(spPrime.paused(), "unpause: still paused");
    }

    function adjustTotalAssets(uint256 magnitude_, uint256 seed_)
        public
        checked(CHECK_ALL & ~CHECK_CHI_UNCHANGED)
    {
        uint256 supply_ = spPrime.totalSupply();

        if (supply_ == 0) return;  // division by zero in the contract

        if (!spPrime.paused()) {
            vm.prank(pauser);
            spPrime.pause();
        }

        uint256 totalAssets_ = spPrime.totalAssets();

        bool gain_ = seed_ % 2 == 0;

        if (!gain_ && totalAssets_ < 2) return;

        magnitude_ = gain_
            ? _bound(magnitude_, 1, totalAssets_)
            : _bound(magnitude_, 1, totalAssets_ / 2);

        uint256 expectedAssets_ = gain_ ? totalAssets_ + magnitude_ : totalAssets_ - magnitude_;
        uint256 expectedChi_    = expectedAssets_ * RAY / supply_;

        if (expectedChi_ < MIN_CHI || expectedChi_ > MAX_CHI) return;

        uint256 chiBefore_ = spPrime.nowChi();

        int256 delta_ = gain_ ? int256(magnitude_) : -int256(magnitude_);

        vm.prank(lossManager);
        spPrime.adjustTotalAssets(delta_);

        uint256 chiAfter_ = spPrime.nowChi();

        assertEq(uint256(spPrime.chi()), chiAfter_,       "adjustTotalAssets: chi not synced");
        assertEq(chiAfter_,              expectedChi_,    "adjustTotalAssets: chi mismatch");
        assertEq(spPrime.rho(),          block.timestamp, "adjustTotalAssets: rho not updated");

        // A gain of a few wei can leave the floored chi where it was; a loss always lowers it.
        if (gain_) assertGe(chiAfter_, chiBefore_, "adjustTotalAssets: chi fell on a gain");
        else       assertLt(chiAfter_, chiBefore_, "adjustTotalAssets: chi did not fall on a loss");

        assertApproxEqAbs(
            spPrime.totalAssets(),
            expectedAssets_,
            1,
            "adjustTotalAssets: totalAssets moved by more than delta +/- 1"
        );

        ghostAdjustNet += delta_;

        // Share-denominated ledger, an upper bound on (totalAssets - backing) * RAY / chi. The
        // existing entry is first rescaled by the chi jump (a deficit measured in shares grows
        // when chi falls), then the delta is added at the new chi. Rounding keeps it an upper
        // bound: the rescale rounds up, gains round up, losses round down.
        ghostAdjustNetShares = _scaleLedger(ghostAdjustNetShares, chiBefore_, chiAfter_);

        if (gain_) ghostAdjustNetShares += int256(_divUp(magnitude_ * RAY, chiAfter_));
        else       ghostAdjustNetShares -= int256(magnitude_ * RAY / chiAfter_);

        if (!gain_) userHandler.refreshLastAssetsOf();
    }

    // ledger * chiBefore / chiAfter, rounded towards +infinity (truncation already does that for
    // negative values).
    function _scaleLedger(int256 ledger_, uint256 chiBefore_, uint256 chiAfter_)
        internal pure returns (int256 scaled_)
    {
        if (ledger_ == 0) return 0;

        int256 numerator_ = ledger_ * int256(chiBefore_);

        scaled_ = numerator_ / int256(chiAfter_);

        if (ledger_ > 0 && numerator_ % int256(chiAfter_) != 0) scaled_ += 1;
    }

    /**********************************************************************************************/
    /*** Queue processing                                                                       ***/
    /**********************************************************************************************/

    function processPendingDeposits(uint256 maxSavingsShares_, uint256 maxRequests_)
        public
        checked(CHECK_ALL & ~CHECK_SUPPLY_UNCHANGED)
    {
        if (spPrime.paused()) {
            vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
            vm.prank(operator);
            spPrime.processPendingDeposits(maxSavingsShares_, maxRequests_);
            return;
        }

        ( maxSavingsShares_, maxRequests_ ) =
            _boundProcessing(DEPOSIT_SLOT, spPrime.pendingDepositSavingsShares(), maxSavingsShares_, maxRequests_);

        _processPendingDeposits(maxSavingsShares_, maxRequests_);
    }

    function processPendingDepositCancellations(uint256 maxSavingsShares_, uint256 maxRequests_)
        public
        checked(CHECK_ALL)
    {
        // Not pause-gated.
        ( maxSavingsShares_, maxRequests_ ) =
            _boundProcessing(CANCEL_SLOT, spPrime.pendingCancelledDepositSavingsShares(), maxSavingsShares_, maxRequests_);

        _processPendingDepositCancellations(maxSavingsShares_, maxRequests_);
    }

    function processPendingRedeems(uint256 maxShares_, uint256 maxRequests_)
        public
        checked(CHECK_CHI_UNCHANGED | CHECK_HEADS_NON_DECREASING)
    {
        if (spPrime.paused()) {
            vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
            vm.prank(operator);
            spPrime.processPendingRedeems(maxShares_, maxRequests_);
            return;
        }

        ( maxShares_, maxRequests_ ) =
            _boundProcessing(REDEEM_SLOT, spPrime.pendingRedeemShares(), maxShares_, maxRequests_);

        _processPendingRedeems(maxShares_, maxRequests_);
    }

    /**********************************************************************************************/
    /*** Taker and upgrade                                                                      ***/
    /**********************************************************************************************/

    function take(uint256 savingsShares_)
        public
        checked(CHECK_ALL & ~CHECK_GAP_NEVER_WIDENS)
    {
        uint256 vaultBefore_ = spUSDC.balanceOf(address(spPrime));
        uint256 takerBefore_ = spUSDC.balanceOf(taker);

        savingsShares_ = _bound(savingsShares_, 0, vaultBefore_);

        vm.prank(taker);
        spPrime.take(savingsShares_);

        assertEq(spUSDC.balanceOf(address(spPrime)), vaultBefore_ - savingsShares_, "take: vault delta");
        assertEq(spUSDC.balanceOf(taker),            takerBefore_ + savingsShares_, "take: taker delta");

        ghostTakenSavingsShares += savingsShares_;
    }

    struct UpgradeState {
        address savings;
        address asset;
        uint8   decimals;
        uint64  rho;
        uint192 chi;
        uint256 vsr;
        uint256 minVSR;
        uint256 maxVSR;
        uint256 maxCapacity;
        uint256 minDeposit;
        uint256 minDepositCancellation;
        uint256 minRedeem;
        uint256 redeemFeeRate;
        uint256 maxRedeemFeeRate;
        bool    paused;
        bytes32 digest;
    }

    function upgrade(uint256 seed_)
        public
        checked(CHECK_ALL)
    {
        address implementation_ = address(spareImplementations[seed_ % 2]);

        UpgradeState memory s_;

        s_.savings                = spPrime.savings();
        s_.asset                  = spPrime.asset();
        s_.decimals               = spPrime.decimals();
        s_.rho                    = spPrime.rho();
        s_.chi                    = spPrime.chi();
        s_.vsr                    = spPrime.vsr();
        s_.minVSR                 = spPrime.minVSR();
        s_.maxVSR                 = spPrime.maxVSR();
        s_.maxCapacity            = spPrime.maxCapacity();
        s_.minDeposit             = spPrime.minDeposit();
        s_.minDepositCancellation = spPrime.minDepositCancellation();
        s_.minRedeem              = spPrime.minRedeem();
        s_.redeemFeeRate          = spPrime.redeemFeeRate();
        s_.maxRedeemFeeRate       = spPrime.maxRedeemFeeRate();
        s_.paused                 = spPrime.paused();
        s_.digest                 = _stateDigest();

        vm.prank(admin);
        spPrime.upgradeToAndCall(implementation_, "");

        assertEq(spPrime.implementation(), implementation_, "upgrade: implementation not set");

        assertEq(spPrime.savings(),                s_.savings,                "upgrade: savings changed");
        assertEq(spPrime.asset(),                  s_.asset,                  "upgrade: asset changed");
        assertEq(spPrime.decimals(),               s_.decimals,               "upgrade: decimals changed");
        assertEq(spPrime.rho(),                    s_.rho,                    "upgrade: rho changed");
        assertEq(spPrime.chi(),                    s_.chi,                    "upgrade: chi changed");
        assertEq(spPrime.vsr(),                    s_.vsr,                    "upgrade: vsr changed");
        assertEq(spPrime.minVSR(),                 s_.minVSR,                 "upgrade: minVSR changed");
        assertEq(spPrime.maxVSR(),                 s_.maxVSR,                 "upgrade: maxVSR changed");
        assertEq(spPrime.maxCapacity(),            s_.maxCapacity,            "upgrade: maxCapacity changed");
        assertEq(spPrime.minDeposit(),             s_.minDeposit,             "upgrade: minDeposit changed");
        assertEq(spPrime.minDepositCancellation(), s_.minDepositCancellation, "upgrade: minDepositCancellation changed");
        assertEq(spPrime.minRedeem(),              s_.minRedeem,              "upgrade: minRedeem changed");
        assertEq(spPrime.redeemFeeRate(),          s_.redeemFeeRate,          "upgrade: redeemFeeRate changed");
        assertEq(spPrime.maxRedeemFeeRate(),       s_.maxRedeemFeeRate,       "upgrade: maxRedeemFeeRate changed");
        assertEq(spPrime.paused(),                 s_.paused,                 "upgrade: paused changed");
        assertEq(_stateDigest(),                   s_.digest,                 "upgrade: state digest changed");
        assertEq(spPrime.version(),                "1",                       "upgrade: version changed");

        assertTrue(spPrime.hasRole(DEFAULT_ADMIN_ROLE, admin), "upgrade: admin role lost");
    }

    /**********************************************************************************************/
    /*** Recording hooks (test-driven flows, never fuzz targets)                                ***/
    /**********************************************************************************************/

    function noteRateOrderBroken() external {
        rateOrderBroken = true;
    }

    function processPendingDepositsExact(uint256 maxSavingsShares_, uint256 maxRequests_) external {
        _processPendingDeposits(maxSavingsShares_, maxRequests_);
    }

    function processPendingDepositCancellationsExact(uint256 maxSavingsShares_, uint256 maxRequests_)
        external
    {
        _processPendingDepositCancellations(maxSavingsShares_, maxRequests_);
    }

    function processPendingRedeemsExact(uint256 maxShares_, uint256 maxRequests_) external {
        _processPendingRedeems(maxShares_, maxRequests_);
    }

    /**********************************************************************************************/
    /*** Internal processing with full accounting                                               ***/
    /**********************************************************************************************/

    struct Snapshot {
        uint256   head;
        uint256[] sharesBefore;      // pending window, by id - head
        address[] recipients;        // pending window, by id - head
        uint256[] userShares;        // vault shares per user
        uint256[] userUsdc;          // USDC per user
        uint256[] userClaimable;     // claimableAssets per user
        uint256   supplyBefore;
        uint256   savingsBefore;     // spUSDC held by the vault
        uint256   pendingBefore;
        uint256   vaultUsdcBefore;
        uint256   totalClaimableBefore;
        uint256   escrowBefore;
        uint256   gapBefore;
    }

    function _snapshot(uint256 slot_, uint256 pending_) internal view returns (Snapshot memory s_) {
        s_.head = _head(slot_);

        uint256 length_ = _rawLength(slot_);
        uint256 window_ = length_ - s_.head;

        s_.sharesBefore = new uint256[](window_);
        s_.recipients   = new address[](window_);

        for (uint256 i = 0; i < window_; i++) {
            ( , s_.recipients[i], s_.sharesBefore[i] ) = _rawRequest(slot_, s_.head + i);
        }

        s_.userShares    = new uint256[](users.length);
        s_.userUsdc      = new uint256[](users.length);
        s_.userClaimable = new uint256[](users.length);

        for (uint256 i = 0; i < users.length; i++) {
            s_.userShares[i]    = spPrime.balanceOf(users[i]);
            s_.userUsdc[i]      = usdc.balanceOf(users[i]);
            s_.userClaimable[i] = spPrime.claimableAssets(users[i]);
        }

        s_.supplyBefore         = spPrime.totalSupply();
        s_.savingsBefore        = spUSDC.balanceOf(address(spPrime));
        s_.pendingBefore        = pending_;
        s_.vaultUsdcBefore      = usdc.balanceOf(address(spPrime));
        s_.totalClaimableBefore = spPrime.totalClaimable();
        s_.escrowBefore         = spPrime.balanceOf(address(spPrime));
        s_.gapBefore            = _backingGap();
    }

    function _boundProcessing(uint256 slot_, uint256 pending_, uint256 maxAmount_, uint256 maxRequests_)
        internal view returns (uint256, uint256)
    {
        uint256 window_ = _rawLength(slot_) - _head(slot_);

        maxAmount_   = maxAmount_   % 4 == 0 ? type(uint256).max : _bound(maxAmount_,   0, pending_ + 1);
        maxRequests_ = maxRequests_ % 4 == 0 ? type(uint256).max : _bound(maxRequests_, 0, window_ + 1);

        return ( maxAmount_, maxRequests_ );
    }

    function _userIndex(address user_) internal view returns (uint256) {
        uint256 indexPlusOne_ = userHandler.userIndexPlusOne(user_);

        assertGt(indexPlusOne_, 0, "processing: recipient is not a tracked user");

        return indexPlusOne_ - 1;
    }

    function _processPendingDeposits(uint256 maxSavingsShares_, uint256 maxRequests_) internal {
        Snapshot memory s_ = _snapshot(DEPOSIT_SLOT, spPrime.pendingDepositSavingsShares());

        uint256 capacityBefore_ = spPrime.availableCapacity();

        vm.prank(operator);
        spPrime.processPendingDeposits(maxSavingsShares_, maxRequests_);

        uint256 minted_ = spPrime.totalSupply() - s_.supplyBefore;

        assertLe(minted_, capacityBefore_, "processPendingDeposits: minted above availableCapacity");

        uint256[] memory expectedByUser_ = new uint256[](users.length);

        uint256 consumedTotal_;
        uint256 expectedMinted_;

        for (uint256 i = 0; i < s_.sharesBefore.length; i++) {
            uint256 after_ = _rawShares(DEPOSIT_SLOT, s_.head + i);

            assertLe(after_, s_.sharesBefore[i], "processPendingDeposits: entry grew");

            if (after_ == s_.sharesBefore[i]) continue;

            uint256 consumed_ = s_.sharesBefore[i] - after_;
            uint256 shares_   = spPrime.convertToShares(spUSDC.convertToAssets(consumed_));

            consumedTotal_  += consumed_;
            expectedMinted_ += shares_;

            expectedByUser_[_userIndex(s_.recipients[i])] += shares_;
        }

        assertEq(
            s_.pendingBefore - spPrime.pendingDepositSavingsShares(),
            consumedTotal_,
            "processPendingDeposits: pending delta != consumed"
        );
        assertEq(minted_, expectedMinted_, "processPendingDeposits: minted != exact conversion");

        for (uint256 i = 0; i < users.length; i++) {
            uint256 delta_ = spPrime.balanceOf(users[i]) - s_.userShares[i];

            assertEq(delta_, expectedByUser_[i], "processPendingDeposits: recipient balance delta");

            if (delta_ != 0) userHandler.noteMinted(users[i], delta_);
        }

        assertEq(spUSDC.balanceOf(address(spPrime)), s_.savingsBefore, "processPendingDeposits: spUSDC moved");

        if (maxRequests_ != type(uint256).max) {
            assertLe(
                spPrime.firstPendingDepositId() - s_.head,
                maxRequests_,
                "processPendingDeposits: head advanced past maxRequests"
            );
        }
    }

    function _processPendingDepositCancellations(uint256 maxSavingsShares_, uint256 maxRequests_) internal {
        Snapshot memory s_ = _snapshot(CANCEL_SLOT, spPrime.pendingCancelledDepositSavingsShares());

        uint256 maxRedeemBefore_ = spUSDC.maxRedeem(address(spPrime));

        vm.prank(operator);
        spPrime.processPendingDepositCancellations(maxSavingsShares_, maxRequests_);

        uint256[] memory expectedByUser_ = new uint256[](users.length);

        uint256 consumedTotal_;
        uint256 expectedPaid_;

        for (uint256 i = 0; i < s_.sharesBefore.length; i++) {
            uint256 after_ = _rawShares(CANCEL_SLOT, s_.head + i);

            assertLe(after_, s_.sharesBefore[i], "processPendingDepositCancellations: entry grew");

            if (after_ == s_.sharesBefore[i]) continue;

            uint256 consumed_ = s_.sharesBefore[i] - after_;
            uint256 assets_   = spUSDC.convertToAssets(consumed_);

            consumedTotal_ += consumed_;
            expectedPaid_  += assets_;

            expectedByUser_[_userIndex(s_.recipients[i])] += assets_;
        }

        assertLe(consumedTotal_, maxRedeemBefore_, "processPendingDepositCancellations: consumed above maxRedeem");

        assertEq(
            s_.savingsBefore - spUSDC.balanceOf(address(spPrime)),
            consumedTotal_,
            "processPendingDepositCancellations: spUSDC delta != consumed"
        );
        assertEq(
            s_.pendingBefore - spPrime.pendingCancelledDepositSavingsShares(),
            consumedTotal_,
            "processPendingDepositCancellations: pending delta != consumed"
        );

        _settlePayouts(s_, expectedByUser_);

        ghostSavingsOutCancel += consumedTotal_;
        ghostCancelPaidAssets += expectedPaid_;
    }

    function _processPendingRedeems(uint256 maxShares_, uint256 maxRequests_) internal {
        Snapshot memory s_ = _snapshot(REDEEM_SLOT, spPrime.pendingRedeemShares());

        uint256 liquidBefore_ = spPrime.availableLiquidAssets();
        uint256 chiSavings_   = spUSDC.nowChi();

        vm.prank(operator);
        spPrime.processPendingRedeems(maxShares_, maxRequests_);

        uint256 burned_ = s_.supplyBefore - spPrime.totalSupply();

        assertEq(burned_, s_.escrowBefore - spPrime.balanceOf(address(spPrime)), "processPendingRedeems: escrow delta != burned");
        assertEq(burned_, s_.pendingBefore - spPrime.pendingRedeemShares(),      "processPendingRedeems: pending delta != burned");

        uint256[] memory expectedByUser_ = new uint256[](users.length);

        uint256 consumedTotal_;
        uint256 assetsTotal_;
        uint256 savingsBurned_;
        uint256 fills_;

        for (uint256 i = 0; i < s_.sharesBefore.length; i++) {
            uint256 after_ = _rawShares(REDEEM_SLOT, s_.head + i);

            assertLe(after_, s_.sharesBefore[i], "processPendingRedeems: entry grew");

            if (after_ == s_.sharesBefore[i]) continue;

            uint256 consumed_ = s_.sharesBefore[i] - after_;
            uint256 assets_   = spPrime.convertToAssets(consumed_);

            consumedTotal_ += consumed_;
            assetsTotal_   += assets_;
            savingsBurned_ += _divUp(assets_ * RAY, chiSavings_);  // spUSDC withdraw rounds shares up
            fills_++;

            expectedByUser_[_userIndex(s_.recipients[i])] += assets_;
        }

        assertEq(consumedTotal_, burned_,       "processPendingRedeems: consumed != burned");
        assertLe(assetsTotal_,   liquidBefore_, "processPendingRedeems: paid above availableLiquidAssets");

        assertEq(
            s_.savingsBefore - spUSDC.balanceOf(address(spPrime)),
            savingsBurned_,
            "processPendingRedeems: spUSDC delta != ceil burns"
        );

        _settlePayouts(s_, expectedByUser_);

        ghostBurnedRedeemShares += burned_;
        ghostSavingsOutRedeem   += savingsBurned_;
        ghostRedeemPaidAssets   += assetsTotal_;
        ghostRedeemFills        += fills_;

        if (_backingGap() > s_.gapBefore) gapWidenedByRedeemFill = true;
    }

    // Every USDC owed by the fills landed in the recipient's wallet or in its claimable balance.
    function _settlePayouts(Snapshot memory s_, uint256[] memory expectedByUser_)
        internal returns (uint256 credited_)
    {
        for (uint256 i = 0; i < users.length; i++) {
            uint256 usdcDelta_      = usdc.balanceOf(users[i]) - s_.userUsdc[i];
            uint256 claimableDelta_ = spPrime.claimableAssets(users[i]) - s_.userClaimable[i];

            assertEq(
                usdcDelta_ + claimableDelta_,
                expectedByUser_[i],
                "processing: payout != exact conversion"
            );

            if (usdcDelta_      != 0) userHandler.notePaidDirect(users[i], usdcDelta_);
            if (claimableDelta_ != 0) userHandler.noteClaimableCredited(users[i], claimableDelta_);

            credited_ += claimableDelta_;
        }

        assertEq(
            usdc.balanceOf(address(spPrime)) - s_.vaultUsdcBefore,
            credited_,
            "processing: vault USDC delta != credited claimables"
        );
        assertEq(
            spPrime.totalClaimable() - s_.totalClaimableBefore,
            credited_,
            "processing: totalClaimable delta != credited claimables"
        );
    }

}
