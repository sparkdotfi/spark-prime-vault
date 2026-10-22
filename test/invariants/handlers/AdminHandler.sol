// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISparkPrimeVault } from "../../../src/ISparkPrimeVault.sol";

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

    constructor(address spPrime_, uint256 numUsers_) HandlerBase(spPrime_, numUsers_) {
        admin           = spPrime.getRoleMember(DEFAULT_ADMIN_ROLE,     0);
        lossManager     = spPrime.getRoleMember(LOSS_MANAGER_ROLE,      0);
        operator        = spPrime.getRoleMember(OPERATOR_ROLE,          0);
        pauser          = spPrime.getRoleMember(PAUSER_ROLE,            0);
        redeemFeeSetter = spPrime.getRoleMember(REDEEM_FEE_SETTER_ROLE, 0);
        taker           = spPrime.getRoleMember(TAKER_ROLE,             0);
        unpauser        = spPrime.getRoleMember(UNPAUSER_ROLE,          0);
    }

    /**********************************************************************************************/
    /*** Setters                                                                                ***/
    /**********************************************************************************************/

    function setVSRBounds(uint256 minVSR_, uint256 maxVSR_) public chiNeverDecreases headsNeverMoveBack {
        minVSR_ = _bound(minVSR_, RAY,     spPrime.MAX_VSR());
        maxVSR_ = _bound(maxVSR_, minVSR_, spPrime.MAX_VSR());

        vm.prank(admin);
        spPrime.setVSRBounds(minVSR_, maxVSR_);
    }

    function setVSR(uint256 vsr_) public chiNeverDecreases headsNeverMoveBack {
        vsr_ = _bound(vsr_, spPrime.minVSR(), spPrime.maxVSR());

        vm.prank(operator);
        spPrime.setVSR(vsr_);
    }

    function setCapacity(uint256 capacity_) public chiNeverDecreases headsNeverMoveBack {
        uint256 supply_ = spPrime.totalSupply();

        // Never near uint256.max: `convertToAssets(availableCapacity())` would overflow.
        capacity_ = _bound(capacity_, 0, _min(supply_ + MAX_AMOUNT, type(uint128).max));

        vm.prank(operator);
        spPrime.setCapacity(capacity_);

        if (capacity_ < supply_) capacityLoweredBelowSupply = true;
    }

    function setMaxRedeemFeeRate(uint256 feeRate_) public chiNeverDecreases headsNeverMoveBack {
        feeRate_ = _bound(feeRate_, 0, spPrime.MAX_REDEEM_FEE());

        vm.prank(admin);
        spPrime.setMaxRedeemFeeRate(feeRate_);
    }

    function setRedeemFeeRate(uint256 feeRate_) public chiNeverDecreases headsNeverMoveBack {
        feeRate_ = _bound(feeRate_, 0, spPrime.maxRedeemFeeRate());

        vm.prank(redeemFeeSetter);
        spPrime.setRedeemFeeRate(feeRate_);
    }

    function setMinDeposit(uint256 minDeposit_) public chiNeverDecreases headsNeverMoveBack {
        // At least one USDC so a deposit always mints spUSDC shares.
        minDeposit_ = _bound(minDeposit_, 1e6, 1_000e6);

        vm.prank(admin);
        spPrime.setMinDeposit(minDeposit_);
    }

    function setMinDepositCancellation(uint256 minDepositCancellation_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        minDepositCancellation_ = _bound(minDepositCancellation_, 1, 1_000e6);

        vm.prank(admin);
        spPrime.setMinDepositCancellation(minDepositCancellation_);
    }

    function setMinRedeem(uint256 minRedeem_) public chiNeverDecreases headsNeverMoveBack {
        // Never 1: a one-share redeem with any nonzero fee burns the whole share and queues a
        // zero-share request.
        minRedeem_ = _bound(minRedeem_, 2, 1_000e6);

        vm.prank(admin);
        spPrime.setMinRedeem(minRedeem_);
    }

    /**********************************************************************************************/
    /*** Pause and Loss Management                                                              ***/
    /**********************************************************************************************/

    function pause(uint256 seed_) public chiNeverDecreases headsNeverMoveBack {
        if (seed_ % 4 != 0) return;  // keep the vault unpaused most of the time

        vm.prank(pauser);
        spPrime.pause();
    }

    function unpause() public chiNeverDecreases headsNeverMoveBack {
        vm.prank(unpauser);
        spPrime.unpause();
    }

    // The one action allowed to lower chi.
    function adjustTotalAssets(uint256 magnitude_, bool gain_) public headsNeverMoveBack {
        uint256 supply_ = spPrime.totalSupply();

        if (supply_ == 0) return;  // division by zero in the contract

        uint256 totalAssets_ = spPrime.totalAssets();

        if (!gain_ && totalAssets_ < 2) return;

        magnitude_ = gain_
            ? _bound(magnitude_, 1, totalAssets_)
            : _bound(magnitude_, 1, totalAssets_ / 2);

        uint256 expectedAssets_ = gain_ ? totalAssets_ + magnitude_ : totalAssets_ - magnitude_;
        uint256 expectedChi_    = expectedAssets_ * RAY / supply_;

        if (expectedChi_ < MIN_CHI || expectedChi_ > MAX_CHI) return;

        if (!spPrime.paused()) {
            vm.prank(pauser);
            spPrime.pause();
        }

        vm.prank(lossManager);
        spPrime.adjustTotalAssets(gain_ ? int256(magnitude_) : -int256(magnitude_));
    }

    /**********************************************************************************************/
    /*** Queue Processing                                                                       ***/
    /**********************************************************************************************/

    function processPendingDeposits(uint256 maxSavingsShares_, uint256 maxRequests_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        if (spPrime.paused()) return;

        ( maxSavingsShares_, maxRequests_ ) =
            _boundProcessing(Queue.DEPOSIT, spPrime.pendingDepositSavingsShares(), maxSavingsShares_, maxRequests_);

        vm.prank(operator);
        spPrime.processPendingDeposits(maxSavingsShares_, maxRequests_);
    }

    function processPendingDepositCancellations(uint256 maxSavingsShares_, uint256 maxRequests_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        // Not pause-gated.
        ( maxSavingsShares_, maxRequests_ ) = _boundProcessing(
            Queue.DEPOSIT_CANCELLATION,
            spPrime.pendingCancelledDepositSavingsShares(),
            maxSavingsShares_,
            maxRequests_
        );

        vm.prank(operator);
        spPrime.processPendingDepositCancellations(maxSavingsShares_, maxRequests_);
    }

    function processPendingRedeems(uint256 maxShares_, uint256 maxRequests_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        if (spPrime.paused()) return;

        ( maxShares_, maxRequests_ ) =
            _boundProcessing(Queue.REDEEM, spPrime.pendingRedeemShares(), maxShares_, maxRequests_);

        uint256 gapBefore_ = _backingGap();

        vm.prank(operator);
        spPrime.processPendingRedeems(maxShares_, maxRequests_);

        // Redeem fills are paid from the vault's whole spUSDC balance, queued backing included.
        if (_backingGap() > gapBefore_) backingGapOpened = true;
    }

    /**********************************************************************************************/
    /*** Taker                                                                                 ***/
    /**********************************************************************************************/

    function take(uint256 savingsShares_) public chiNeverDecreases headsNeverMoveBack {
        savingsShares_ = _bound(savingsShares_, 0, spUSDC.balanceOf(address(spPrime)));

        uint256 gapBefore_ = _backingGap();

        vm.prank(taker);
        spPrime.take(savingsShares_);

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
