// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISparkPrimeVault } from "../../../src/ISparkPrimeVault.sol";

import { HandlerBase } from "./HandlerBase.sol";

contract UserHandler is HandlerBase {

    // Only the handlers push requests, so these mirror the length of each queue.
    uint256 public depositQueueLength;
    uint256 public depositCancellationQueueLength;
    uint256 public redeemQueueLength;

    constructor(address spPrime_, uint256 numUsers_) HandlerBase(spPrime_, numUsers_) {}

    /**********************************************************************************************/
    /*** Fuzzed Actions                                                                         ***/
    /**********************************************************************************************/

    function requestDeposit(uint256 assets_, uint256 userSeed_, uint256 recipientSeed_, uint16 referral_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        if (spPrime.paused()) return;

        address user_      = _randomUser(userSeed_);
        address recipient_ = _randomUser(recipientSeed_);

        if (usdc.isBlacklisted(user_)) return;  // USDC approve / transferFrom would revert

        uint256 minDeposit_ = spPrime.minDeposit();
        uint256 maxDeposit_ = _min(MAX_AMOUNT, spUSDC.maxDeposit(address(spPrime)));

        if (maxDeposit_ < minDeposit_) return;

        assets_ = _bound(assets_, minDeposit_, maxDeposit_);

        // Additive: users accumulate payouts, and `deal` overwrites the balance slot.
        deal(address(usdc), user_, usdc.balanceOf(user_) + assets_);

        vm.startPrank(user_);
        usdc.approve(address(spPrime), assets_);
        spPrime.requestDeposit(assets_, recipient_, referral_);
        vm.stopPrank();

        depositQueueLength++;
    }

    function requestDepositCancellation(uint256 idSeed_, uint256 recipientSeed_, uint256 savingsShares_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        ( bool found_, uint256 requestId_, ISparkPrimeVault.Request memory request_ ) =
            _randomOpenRequest(Queue.DEPOSIT, idSeed_);

        if (!found_) return;

        uint256 minCancellation_ = spPrime.minDepositCancellation();

        if (request_.shares < minCancellation_) return;

        savingsShares_ = _bound(savingsShares_, minCancellation_, request_.shares);

        vm.prank(request_.owner);
        spPrime.requestDepositCancellation(requestId_, _randomUser(recipientSeed_), savingsShares_);

        depositCancellationQueueLength++;
    }

    function requestRedeem(uint256 shares_, uint256 userSeed_, uint256 recipientSeed_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        if (spPrime.paused()) return;

        address user_     = _randomUser(userSeed_);
        uint256 balance_  = spPrime.balanceOf(user_);
        uint256 minRedeem_ = spPrime.minRedeem();

        if (balance_ < minRedeem_) return;

        shares_ = _bound(shares_, minRedeem_, balance_);

        vm.prank(user_);
        spPrime.requestRedeem(shares_, _randomUser(recipientSeed_));

        redeemQueueLength++;
    }

    function updateDepositRecipient(uint256 idSeed_, uint256 recipientSeed_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        ( bool found_, uint256 requestId_, ISparkPrimeVault.Request memory request_ ) =
            _randomOpenRequest(Queue.DEPOSIT, idSeed_);

        if (!found_) return;

        vm.prank(request_.owner);
        spPrime.updateDepositRecipient(requestId_, _randomUser(recipientSeed_));
    }

    function updateDepositCancellationRecipient(uint256 idSeed_, uint256 recipientSeed_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        ( bool found_, uint256 requestId_, ISparkPrimeVault.Request memory request_ ) =
            _randomOpenRequest(Queue.DEPOSIT_CANCELLATION, idSeed_);

        if (!found_) return;

        vm.prank(request_.owner);
        spPrime.updateDepositCancellationRecipient(requestId_, _randomUser(recipientSeed_));
    }

    function updateRedeemRecipient(uint256 idSeed_, uint256 recipientSeed_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        ( bool found_, uint256 requestId_, ISparkPrimeVault.Request memory request_ ) =
            _randomOpenRequest(Queue.REDEEM, idSeed_);

        if (!found_) return;

        vm.prank(request_.owner);
        spPrime.updateRedeemRecipient(requestId_, _randomUser(recipientSeed_));
    }

    function claim(uint256 recipientSeed_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        // Claims only exist for recipients that were blacklisted at fill time, so scan for one.
        uint256 start_ = _bound(recipientSeed_, 0, users.length - 1);

        for (uint256 i = 0; i < users.length; i++) {
            address recipient_ = users[(start_ + i) % users.length];

            if (spPrime.claimableAssets(recipient_) == 0) continue;
            if (usdc.isBlacklisted(recipient_))          continue;  // USDC transfer would revert

            spPrime.claim(recipient_);
            return;
        }
    }

    function transfer(uint256 amount_, uint256 fromSeed_, uint256 toSeed_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        address from_ = _randomUser(fromSeed_);

        amount_ = _bound(amount_, 0, spPrime.balanceOf(from_));

        vm.prank(from_);
        spPrime.transfer(_randomUser(toSeed_), amount_);
    }

    function transferFrom(uint256 amount_, uint256 ownerSeed_, uint256 spenderSeed_, uint256 toSeed_)
        public
        chiNeverDecreases
        headsNeverMoveBack
    {
        address owner_   = _randomUser(ownerSeed_);
        address spender_ = _randomUser(spenderSeed_);

        amount_ = _bound(amount_, 0, spPrime.balanceOf(owner_));

        vm.prank(owner_);
        spPrime.approve(spender_, amount_);

        vm.prank(spender_);
        spPrime.transferFrom(owner_, _randomUser(toSeed_), amount_);
    }

}
