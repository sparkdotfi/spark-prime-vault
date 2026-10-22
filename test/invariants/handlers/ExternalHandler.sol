// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { HandlerBase } from "./HandlerBase.sol";

// Everything outside the vault's own interface: time, spUSDC's rate and liquidity, the taker
// returning what it took, USDC blacklisting and spUSDC donations.
contract ExternalHandler is HandlerBase {

    // Cap cumulative warping so extreme-depth campaigns cannot push chi towards overflow.
    uint256 public constant MAX_TOTAL_WARP = 20 * 365 days;

    address public spSetter;  // spUSDC SETTER_ROLE (rate)
    address public spTaker;   // spUSDC TAKER_ROLE (liquidity)
    address public taker;     // spPrime TAKER_ROLE

    uint256 public totalWarped;

    constructor(address spPrime_, uint256 numUsers_, address spSetter_, address spTaker_)
        HandlerBase(spPrime_, numUsers_)
    {
        spSetter = spSetter_;
        spTaker  = spTaker_;
        taker    = spPrime.getRoleMember(TAKER_ROLE, 0);
    }

    /**********************************************************************************************/
    /*** Time                                                                                   ***/
    /**********************************************************************************************/

    function warp(uint256 secs_) public chiNeverDecreases headsNeverMoveBack {
        secs_ = _bound(secs_, 0, _min(10 days, MAX_TOTAL_WARP - totalWarped));

        totalWarped += secs_;

        vm.warp(block.timestamp + secs_);
    }

    function drip() public chiNeverDecreases headsNeverMoveBack {
        spPrime.drip();
    }

    /**********************************************************************************************/
    /*** spUSDC                                                                                 ***/
    /**********************************************************************************************/

    function setSavingsVsr(uint256 vsr_) public chiNeverDecreases headsNeverMoveBack {
        vsr_ = _bound(vsr_, spUSDC.minVsr(), spUSDC.maxVsr());

        vm.prank(spSetter);
        spUSDC.setVsr(vsr_);
    }

    function drainSavingsLiquidity(uint256 amount_) public chiNeverDecreases headsNeverMoveBack {
        amount_ = _bound(amount_, 0, usdc.balanceOf(address(spUSDC)));

        vm.prank(spTaker);
        spUSDC.take(amount_);
    }

    function returnSavingsLiquidity(uint256 amount_) public chiNeverDecreases headsNeverMoveBack {
        amount_ = _bound(amount_, 0, usdc.balanceOf(spTaker));

        vm.prank(spTaker);
        usdc.transfer(address(spUSDC), amount_);
    }

    function returnTakenSavingsShares(uint256 amount_) public chiNeverDecreases headsNeverMoveBack {
        amount_ = _bound(amount_, 0, spUSDC.balanceOf(taker));

        vm.prank(taker);
        spUSDC.transfer(address(spPrime), amount_);
    }

    function giveSavingsShares(uint256 assets_) public chiNeverDecreases headsNeverMoveBack {
        assets_ = _bound(assets_, 0, _min(MAX_AMOUNT, spUSDC.maxDeposit(address(this))));

        if (assets_ == 0) return;

        deal(address(usdc), address(this), usdc.balanceOf(address(this)) + assets_);

        usdc.approve(address(spUSDC), assets_);

        uint256 shares_ = spUSDC.deposit(assets_, address(this));

        spUSDC.transfer(address(spPrime), shares_);
    }

    /**********************************************************************************************/
    /*** USDC                                                                                   ***/
    /**********************************************************************************************/

    // Fills paid to a blacklisted recipient land in `claimableAssets` instead of reverting.
    function setBlacklisted(uint256 userSeed_, bool flag_) public chiNeverDecreases headsNeverMoveBack {
        address user_ = _randomUser(userSeed_);

        vm.prank(usdc.blacklister());

        if (flag_) usdc.blacklist(user_);
        else       usdc.unBlacklist(user_);
    }

}
