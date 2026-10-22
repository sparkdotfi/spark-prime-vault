// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISparkPrimeVault } from "../../../../src/ISparkPrimeVault.sol";

import { HandlerBase } from "./HandlerBase.sol";

contract AdminHandler is HandlerBase {

    // Practical window for chi after `adjustTotalAssets` (the contract allows (0, uint192.max]).
    uint256 internal constant MIN_CHI = 1e21;
    uint256 internal constant MAX_CHI = 1e33;

    address public admin;
    address public lossManager;
    address public operator;
    address public pauser;
    address public redeemFeeSetter;
    address public taker;
    address public unpauser;

    // Ghost flags read by the invariants.
    bool public capacityLoweredBelowSupply;  // setCapacity(cap < totalSupply) happened
    bool public backingGapOpened;            // take or a redeem fill spent spUSDC owed to the queues

    // Ghost counters read by the invariants.
    uint256 public sharesFilled;       // escrowed shares burned by redeem fills
    uint256 public redeemAssetsPaid;   // USDC paid (or parked as claimable) by redeem fills
    uint256 public redeemAssetsOwed;   // convertToAssets of the shares those fills burned
    uint256 public cancelAssetsPaid;   // USDC paid (or parked as claimable) by cancellation fills
    uint256 public cancelAssetsOwed;   // spUSDC value of the savings shares those fills redeemed

    constructor(address vault_, uint256 numUsers_) HandlerBase(vault_, numUsers_) {
        admin           = vault.getRoleMember(DEFAULT_ADMIN_ROLE,     0);
        lossManager     = vault.getRoleMember(LOSS_MANAGER_ROLE,      0);
        operator        = vault.getRoleMember(OPERATOR_ROLE,          0);
        pauser          = vault.getRoleMember(PAUSER_ROLE,            0);
        redeemFeeSetter = vault.getRoleMember(REDEEM_FEE_SETTER_ROLE, 0);
        taker           = vault.getRoleMember(TAKER_ROLE,             0);
        unpauser        = vault.getRoleMember(UNPAUSER_ROLE,          0);
    }

    /**********************************************************************************************/
    /*** Setters                                                                                ***/
    /**********************************************************************************************/

    function setVSRBounds(uint256 minVSR_, uint256 maxVSR_) public chiNeverDecreases headsNeverMoveBack {
        minVSR_ = _bound(minVSR_, RAY,     vault.MAX_VSR());
        maxVSR_ = _bound(maxVSR_, minVSR_, vault.MAX_VSR());

        vm.prank(admin);
        vault.setVSRBounds(minVSR_, maxVSR_);
    }

    function setVSR(uint256 vsr_) public chiNeverDecreases headsNeverMoveBack {
        vsr_ = _bound(vsr_, vault.minVSR(), vault.maxVSR());

        vm.prank(operator);
        vault.setVSR(vsr_);
    }

    function setCapacity(uint256 capacity_) public chiNeverDecreases headsNeverMoveBack {
        uint256 supply_ = vault.totalSupply();

        // Never near uint256.max: `convertToAssets(availableCapacity())` would overflow.
        capacity_ = _bound(capacity_, 0, _min(supply_ + MAX_AMOUNT, type(uint128).max));

        vm.prank(operator);
        vault.setCapacity(capacity_);

        if (capacity_ < supply_) capacityLoweredBelowSupply = true;
    }

    function setMaxRedeemFeeRate(uint256 feeRate_) public chiNeverDecreases headsNeverMoveBack {
        feeRate_ = _bound(feeRate_, 0, vault.MAX_REDEEM_FEE());

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(feeRate_);
    }

    function setRedeemFeeRate(uint256 feeRate_) public chiNeverDecreases headsNeverMoveBack {
        feeRate_ = _bound(feeRate_, 0, vault.maxRedeemFeeRate());

        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(feeRate_);
    }

    // The harness starts every minimum at 1 wei; the setters keep dust reachable (1) and go up to
    // launch-sized values.
    function setMinDeposit(uint256 minDeposit_) public chiNeverDecreases headsNeverMoveBack {
        minDeposit_ = _bound(minDeposit_, 1, 1_000e6);

        vm.prank(admin);
        vault.setMinDeposit(minDeposit_);
    }

    function setMinDepositCancellation(uint256 minDepositCancellation_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        minDepositCancellation_ = _bound(minDepositCancellation_, 1, 1_000e6);

        vm.prank(admin);
        vault.setMinDepositCancellation(minDepositCancellation_);
    }

    function setMinRedeem(uint256 minRedeem_) public chiNeverDecreases headsNeverMoveBack {
        minRedeem_ = _bound(minRedeem_, 1, 1_000e6);

        vm.prank(admin);
        vault.setMinRedeem(minRedeem_);
    }

    /**********************************************************************************************/
    /*** Pause and Loss Management                                                              ***/
    /**********************************************************************************************/

    function pause(uint256 seed_) public chiNeverDecreases headsNeverMoveBack {
        if (seed_ % 4 != 0) return;  // keep the vault unpaused most of the time

        vm.prank(pauser);
        vault.pause();
    }

    function unpause() public chiNeverDecreases headsNeverMoveBack {
        vm.prank(unpauser);
        vault.unpause();
    }

    // The one action allowed to lower chi.
    function adjustTotalAssets(uint256 magnitude_, bool gain_) public headsNeverMoveBack {
        uint256 supply_ = vault.totalSupply();

        if (supply_ == 0) return;  // division by zero in the contract

        uint256 totalAssets_ = vault.totalAssets();

        if (!gain_ && totalAssets_ < 2) return;

        magnitude_ = gain_
            ? _bound(magnitude_, 1, totalAssets_)
            : _bound(magnitude_, 1, totalAssets_ / 2);

        uint256 expectedAssets_ = gain_ ? totalAssets_ + magnitude_ : totalAssets_ - magnitude_;
        uint256 expectedChi_    = expectedAssets_ * RAY / supply_;

        if (expectedChi_ < MIN_CHI || expectedChi_ > MAX_CHI) return;

        if (!vault.paused()) {
            vm.prank(pauser);
            vault.pause();
        }

        vm.prank(lossManager);
        vault.adjustTotalAssets(gain_ ? int256(magnitude_) : -int256(magnitude_));
    }

    /**********************************************************************************************/
    /*** Queue Processing                                                                       ***/
    /**********************************************************************************************/

    function processPendingDeposits(uint256 maxSavingsShares_, uint256 maxRequests_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        if (vault.paused()) return;

        ( maxSavingsShares_, maxRequests_ ) =
            _boundProcessing(Queue.DEPOSIT, vault.pendingDepositSavingsShares(), maxSavingsShares_, maxRequests_);

        vm.prank(operator);
        vault.processPendingDeposits(maxSavingsShares_, maxRequests_);
    }

    function processPendingDepositCancellations(uint256 maxSavingsShares_, uint256 maxRequests_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        // Not pause-gated.
        ( maxSavingsShares_, maxRequests_ ) = _boundProcessing(
            Queue.DEPOSIT_CANCELLATION,
            vault.pendingCancelledDepositSavingsShares(),
            maxSavingsShares_,
            maxRequests_
        );

        uint256 pendingBefore_ = vault.pendingCancelledDepositSavingsShares();
        uint256 paidBefore_    = _usersUsdcPlusClaimable();

        vm.prank(operator);
        vault.processPendingDepositCancellations(maxSavingsShares_, maxRequests_);

        cancelAssetsPaid += _usersUsdcPlusClaimable() - paidBefore_;
        cancelAssetsOwed += spUsdc.convertToAssets(pendingBefore_ - vault.pendingCancelledDepositSavingsShares());
    }

    function processPendingRedeems(uint256 maxShares_, uint256 maxRequests_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        if (vault.paused()) return;

        ( maxShares_, maxRequests_ ) =
            _boundProcessing(Queue.REDEEM, vault.pendingRedeemShares(), maxShares_, maxRequests_);

        uint256 gapBefore_     = _backingGap();
        uint256 pendingBefore_ = vault.pendingRedeemShares();
        uint256 paidBefore_    = _usersUsdcPlusClaimable();

        vm.prank(operator);
        vault.processPendingRedeems(maxShares_, maxRequests_);

        // Redeem fills are paid from the vault's whole spUSDC balance, queued backing included.
        if (_backingGap() > gapBefore_) backingGapOpened = true;

        uint256 filled_ = pendingBefore_ - vault.pendingRedeemShares();

        sharesFilled     += filled_;
        redeemAssetsPaid += _usersUsdcPlusClaimable() - paidBefore_;
        redeemAssetsOwed += vault.convertToAssets(filled_);
    }

    /**********************************************************************************************/
    /*** Taker                                                                                 ***/
    /**********************************************************************************************/

    function take(uint256 savingsShares_) public chiNeverDecreases headsNeverMoveBack {
        savingsShares_ = _bound(savingsShares_, 0, spUsdc.balanceOf(address(vault)));

        uint256 gapBefore_ = _backingGap();

        vm.prank(taker);
        vault.take(savingsShares_);

        if (_backingGap() > gapBefore_) backingGapOpened = true;
    }

    /**********************************************************************************************/
    /*** Internal Helpers                                                                       ***/
    /**********************************************************************************************/

    // One call in four is unbounded on each axis, the rest stay around the queue size.
    function _boundProcessing(Queue queue_, uint256 pending_, uint256 maxAmount_, uint256 maxRequests_)
        internal view returns (uint256, uint256)
    {
        ( , ISparkPrimeVault.Request[] memory requests_ ) = _pendingRequests(queue_);

        maxAmount_   = maxAmount_   % 4 == 0 ? type(uint256).max : _bound(maxAmount_,   0, pending_ + 1);
        maxRequests_ = maxRequests_ % 4 == 0 ? type(uint256).max : _bound(maxRequests_, 0, requests_.length + 1);

        return ( maxAmount_, maxRequests_ );
    }

}
