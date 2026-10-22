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
    address public taker;     // spPRIME TAKER_ROLE

    uint256 public totalWarped;

    constructor(address vault_, uint256 numUsers_, address spSetter_, address spTaker_)
        HandlerBase(vault_, numUsers_)
    {
        spSetter = spSetter_;
        spTaker  = spTaker_;
        taker    = vault.getRoleMember(TAKER_ROLE, 0);
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
        vault.drip();
    }

    /**********************************************************************************************/
    /*** spUSDC                                                                                 ***/
    /**********************************************************************************************/

    function setSavingsVsr(uint256 vsr_) public chiNeverDecreases headsNeverMoveBack {
        vsr_ = _bound(vsr_, spUsdc.minVsr(), spUsdc.maxVsr());

        vm.prank(spSetter);
        spUsdc.setVsr(vsr_);
    }

    function drainSavingsLiquidity(uint256 amount_) public chiNeverDecreases headsNeverMoveBack {
        amount_ = _bound(amount_, 0, usdc.balanceOf(address(spUsdc)));

        vm.prank(spTaker);
        spUsdc.take(amount_);
    }

    function returnSavingsLiquidity(uint256 amount_) public chiNeverDecreases headsNeverMoveBack {
        amount_ = _bound(amount_, 0, usdc.balanceOf(spTaker));

        vm.prank(spTaker);
        usdc.transfer(address(spUsdc), amount_);
    }

    function returnTakenSavingsShares(uint256 amount_) public chiNeverDecreases headsNeverMoveBack {
        amount_ = _bound(amount_, 0, spUsdc.balanceOf(taker));

        vm.prank(taker);
        spUsdc.transfer(address(vault), amount_);
    }

    function giveSavingsShares(uint256 assets_) public chiNeverDecreases headsNeverMoveBack {
        assets_ = _bound(assets_, 0, _min(MAX_AMOUNT, spUsdc.maxDeposit(address(this))));

        if (assets_ == 0) return;

        usdc.mint(address(this), assets_);

        usdc.approve(address(spUsdc), assets_);

        uint256 shares_ = spUsdc.deposit(assets_, address(this));

        spUsdc.transfer(address(vault), shares_);
    }

    /**********************************************************************************************/
    /*** USDC                                                                                   ***/
    /**********************************************************************************************/

    // Fills paid to a blacklisted recipient land in `claimableAssets` instead of reverting.
    function setBlacklisted(uint256 userSeed_, bool flag_) public chiNeverDecreases headsNeverMoveBack {
        usdc.setBlacklisted(_randomUser(userSeed_), flag_);
    }

}
