// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { AdminHandler } from "./AdminHandler.sol";
import { HandlerBase }  from "./HandlerBase.sol";
import { UserHandler }  from "./UserHandler.sol";

contract ExternalHandler is HandlerBase {

    // Cap cumulative warping so extreme-depth campaigns cannot push chi towards overflow.
    uint256 public constant MAX_TOTAL_WARP = 20 * 365 days;

    UserHandler  internal userHandler;
    AdminHandler internal adminHandler;

    address public spSetter;  // spUSDC SETTER_ROLE (rate)
    address public spTaker;   // spUSDC TAKER_ROLE (liquidity)
    address public taker;     // spPrime TAKER_ROLE

    // Ghost variables tracking external flows.
    uint256 public ghostTotalWarped;
    uint256 public ghostSavingsReturned;      // spUSDC sent back by the spPrime taker
    uint256 public ghostSavingsDonated;       // spUSDC given to the vault by the handler
    uint256 public ghostUsdcDonatedToVault;   // USDC given to the vault directly
    uint256 public ghostLiquidityDrained;     // USDC pulled out of spUSDC by its taker
    uint256 public ghostLiquidityReturned;    // USDC sent back into spUSDC

    constructor(
        address      spPrime_,
        UserHandler  userHandler_,
        AdminHandler adminHandler_,
        address      spSetter_,
        address      spTaker_
    )
        HandlerBase(spPrime_)
    {
        userHandler  = userHandler_;
        adminHandler = adminHandler_;
        spSetter     = spSetter_;
        spTaker      = spTaker_;
        taker        = adminHandler_.taker();

        for (uint256 i = 0; i < userHandler_.numUsers(); i++) {
            users.push(userHandler_.users(i));
        }
    }

    /**********************************************************************************************/
    /*** Time                                                                                   ***/
    /**********************************************************************************************/

    function warp(uint256 secs_)
        public
        checked((CHECK_ALL & ~CHECK_CHI_UNCHANGED) | CHECK_CHI_NON_DECREASING)
    {
        secs_ = _bound(secs_, 0, _min(10 days, MAX_TOTAL_WARP - ghostTotalWarped));

        ghostTotalWarped += secs_;

        uint256 timestampBefore_  = block.timestamp;
        uint256 savingsChiBefore_ = spUSDC.nowChi();

        vm.warp(block.timestamp + secs_);

        assertEq(block.timestamp, timestampBefore_ + secs_,  "warp: timestamp mismatch");
        assertGe(spUSDC.nowChi(), savingsChiBefore_,         "warp: spUSDC chi decreased");
    }

    function drip()
        public
        checked(CHECK_ALL)
    {
        uint256 nowChi_ = spPrime.nowChi();

        assertEq(uint256(spPrime.drip()), nowChi_,         "drip: return != nowChi");
        assertEq(spPrime.rho(),           block.timestamp, "drip: rho not updated");
        assertEq(uint256(spPrime.chi()),  nowChi_,         "drip: chi not synced");

        // Drip is idempotent within the same block.
        assertEq(uint256(spPrime.drip()), nowChi_, "drip: second drip changed chi");
        assertEq(uint256(spPrime.chi()),  nowChi_, "drip: second drip changed stored chi");
    }

    /**********************************************************************************************/
    /*** spUSDC side                                                                            ***/
    /**********************************************************************************************/

    function setSavingsVsr(uint256 vsr_, uint256 seed_)
        public
        checked(CHECK_ALL)
    {
        uint256 minVsr_ = spUSDC.minVsr();
        uint256 maxVsr_ = spUSDC.maxVsr();

        // Keep spUSDC's rate at or above spPrime's most of the time (see AdminHandler.setVSR).
        if (seed_ % 8 != 0) minVsr_ = _min(maxVsr_, _max(minVsr_, spPrime.vsr()));

        vsr_ = _bound(vsr_, minVsr_, maxVsr_);

        vm.prank(spSetter);
        spUSDC.setVsr(vsr_);

        assertEq(spUSDC.vsr(), vsr_, "setSavingsVsr: vsr not set");

        if (vsr_ < spPrime.vsr()) adminHandler.noteRateOrderBroken();
    }

    function drainSavingsLiquidity(uint256 amount_)
        public
        checked(CHECK_ALL)
    {
        amount_ = _bound(amount_, 0, usdc.balanceOf(address(spUSDC)));

        uint256 liquidBefore_ = spPrime.availableLiquidAssets();
        uint256 takerBefore_  = usdc.balanceOf(spTaker);

        vm.prank(spTaker);
        spUSDC.take(amount_);

        assertLe(spPrime.availableLiquidAssets(), liquidBefore_,          "drainSavingsLiquidity: liquidity grew");
        assertEq(usdc.balanceOf(spTaker),         takerBefore_ + amount_, "drainSavingsLiquidity: taker delta");

        ghostLiquidityDrained += amount_;
    }

    function returnSavingsLiquidity(uint256 amount_)
        public
        checked(CHECK_ALL)
    {
        uint256 outstanding_ = ghostLiquidityDrained - ghostLiquidityReturned;

        if (outstanding_ == 0) return;

        amount_ = _bound(amount_, 0, outstanding_);

        _returnSavingsLiquidity(amount_);
    }

    function returnTakenSavingsShares(uint256 amount_)
        public
        checked(CHECK_ALL)
    {
        amount_ = _bound(amount_, 0, spUSDC.balanceOf(taker));

        _returnTakenSavingsShares(amount_);
    }

    function setBlacklisted(uint256 userSeed_, bool flag_)
        public
        checked(CHECK_ALL)
    {
        address user_ = _randomUser(userSeed_);

        _setBlacklisted(user_, flag_);
    }

    /**********************************************************************************************/
    /*** Donations                                                                              ***/
    /**********************************************************************************************/

    function giveAsset(uint256 amount_)
        public
        checked(CHECK_ALL)
    {
        amount_ = _bound(amount_, 0, MAX_AMOUNT);

        deal(address(usdc), address(this), usdc.balanceOf(address(this)) + amount_);

        uint256 vaultBefore_ = usdc.balanceOf(address(spPrime));

        assertTrue(usdc.transfer(address(spPrime), amount_), "giveAsset: transfer failed");

        assertEq(usdc.balanceOf(address(spPrime)), vaultBefore_ + amount_, "giveAsset: vault delta");

        ghostUsdcDonatedToVault += amount_;
    }

    function giveSavingsShares(uint256 assets_)
        public
        checked(CHECK_ALL)
    {
        assets_ = _bound(assets_, 0, _min(MAX_AMOUNT, spUSDC.maxDeposit(address(this))));

        if (assets_ == 0) return;

        _giveSavingsAssets(assets_);
    }

    /**********************************************************************************************/
    /*** Recording hooks (test-driven flows, never fuzz targets)                                ***/
    /**********************************************************************************************/

    // Gives the vault at least `shares_` spUSDC (deposit rounds down, so overpay by one unit).
    function giveSavingsSharesExact(uint256 shares_) external returns (uint256 given_) {
        uint256 assets_ = _divUp(shares_ * spUSDC.nowChi(), RAY) + 1;

        given_ = _giveSavingsAssets(assets_);

        assertGe(given_, shares_, "giveSavingsSharesExact: short");
    }

    function giveSavingsLiquidityExact(uint256 amount_) external {
        deal(address(usdc), spTaker, usdc.balanceOf(spTaker) + amount_);

        vm.prank(spTaker);
        assertTrue(usdc.transfer(address(spUSDC), amount_), "giveSavingsLiquidityExact: transfer failed");
    }

    function returnAllSavingsLiquidity() external {
        _returnSavingsLiquidity(ghostLiquidityDrained - ghostLiquidityReturned);
    }

    function returnAllTakenSavingsShares() external {
        _returnTakenSavingsShares(spUSDC.balanceOf(taker));
    }

    function setSavingsVsrExact(uint256 vsr_) external {
        vm.prank(spSetter);
        spUSDC.setVsr(vsr_);
    }

    function unblacklistAll() external {
        for (uint256 i = 0; i < users.length; i++) {
            if (userHandler.isBlacklisted(users[i])) _setBlacklisted(users[i], false);
        }
    }

    /**********************************************************************************************/
    /*** Internal helpers                                                                       ***/
    /**********************************************************************************************/

    function _returnSavingsLiquidity(uint256 amount_) internal {
        uint256 savingsBefore_ = usdc.balanceOf(address(spUSDC));

        vm.prank(spTaker);
        assertTrue(usdc.transfer(address(spUSDC), amount_), "returnSavingsLiquidity: transfer failed");

        assertEq(usdc.balanceOf(address(spUSDC)), savingsBefore_ + amount_, "returnSavingsLiquidity: spUSDC delta");

        ghostLiquidityReturned += amount_;
    }

    function _returnTakenSavingsShares(uint256 amount_) internal {
        uint256 vaultBefore_ = spUSDC.balanceOf(address(spPrime));

        vm.prank(taker);
        assertTrue(spUSDC.transfer(address(spPrime), amount_), "returnTakenSavingsShares: transfer failed");

        assertEq(spUSDC.balanceOf(address(spPrime)), vaultBefore_ + amount_, "returnTakenSavingsShares: vault delta");

        ghostSavingsReturned += amount_;
    }

    function _setBlacklisted(address user_, bool flag_) internal {
        vm.prank(usdc.blacklister());

        if (flag_) usdc.blacklist(user_);
        else       usdc.unBlacklist(user_);

        assertEq(usdc.isBlacklisted(user_), flag_, "setBlacklisted: flag not set");

        userHandler.noteBlacklisted(user_, flag_);
    }

    function _giveSavingsAssets(uint256 assets_) internal returns (uint256 shares_) {
        deal(address(usdc), address(this), usdc.balanceOf(address(this)) + assets_);

        usdc.approve(address(spUSDC), assets_);

        shares_ = spUSDC.deposit(assets_, address(this));

        uint256 vaultBefore_ = spUSDC.balanceOf(address(spPrime));

        assertTrue(spUSDC.transfer(address(spPrime), shares_), "giveSavingsShares: transfer failed");

        assertEq(spUSDC.balanceOf(address(spPrime)), vaultBefore_ + shares_, "giveSavingsShares: vault delta");

        ghostSavingsDonated += shares_;
    }

}
