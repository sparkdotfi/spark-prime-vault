// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import "./b_flows_user.sol";

// Admin / role / environment flows: capacity, fee, minimums, both VSRs, pause/unpause, queue
// processing, take/return, spUSDC liquidity drains and returns, time.
contract FlowsAdmin is FlowsUser {

    constructor(address vault_) FlowsUser(vault_) {}

    /**********************************************************************************************/
    /*** Parameters                                                                             ***/
    /**********************************************************************************************/

    function setCapacity(uint256 capacity, uint256 seed) public counted("setCapacity") {
        uint256 supply = vault.totalSupply();
        uint256 kind   = seed % 10;

        if      (kind < 5) capacity = type(uint128).max;                       // wide open
        else if (kind < 8) capacity = _bound(capacity, supply, supply + 1e18); // some headroom
        else               capacity = _bound(capacity, 0, supply);             // at or below supply

        vm.startPrank(admin);
        vault.setCapacity(capacity);
        vm.stopPrank();
    }

    function setRedeemFee(uint256 fee) public counted("setRedeemFee") {
        fee = _bound(fee, 0, vault.maxRedeemFee());

        vm.startPrank(riskManager);
        vault.setRedeemFee(fee);
        vm.stopPrank();
    }

    // Half of the calls clear the minimums so zero-amount and one-wei requests stay reachable.
    function setMinimums(uint256 minDeposit, uint256 minWithdraw, uint256 seed)
        public counted("setMinimums")
    {
        minDeposit  = seed % 2 == 0 ? 0 : _bound(minDeposit,  1, 10e6);
        minWithdraw = seed % 2 == 0 ? 0 : _bound(minWithdraw, 1, 10e6);

        vm.startPrank(admin);
        vault.setMinimums(minDeposit, minWithdraw);
        vm.stopPrank();
    }

    // spPRIME VSR; kept at or below the spUSDC VSR except in ~1 of 8 calls (flagged for H).
    function setPrimeVsr(uint256 vsr_, uint256 seed) public counted("setPrimeVsr") {
        uint256 spVsr = spUsdc.vsr();

        if (seed % 8 == 0) vsr_ = _bound(vsr_, vault.minVSR(), vault.maxVSR());
        else               vsr_ = _bound(vsr_, vault.minVSR(), _min(vault.maxVSR(), spVsr));

        vm.startPrank(setter);
        vault.setVSR(vsr_);
        vm.stopPrank();

        if (vsr_ > spVsr) rateOrderBroken = true;
    }

    // spUSDC VSR; kept at or above the spPRIME VSR except in ~1 of 8 calls (flagged for H).
    function setSpUsdcVsr(uint256 vsr_, uint256 seed) public counted("setSpUsdcVsr") {
        uint256 primeVsr = vault.vsr();

        if (seed % 8 == 0) vsr_ = _bound(vsr_, spUsdc.minVsr(), spUsdc.maxVsr());
        else               vsr_ = _bound(vsr_, _max(spUsdc.minVsr(), primeVsr), spUsdc.maxVsr());

        vm.startPrank(spSetter);
        spUsdc.setVsr(vsr_);
        vm.stopPrank();

        if (vsr_ < primeVsr) rateOrderBroken = true;
    }

    /**********************************************************************************************/
    /*** Pause                                                                                  ***/
    /**********************************************************************************************/

    // Pauses in ~1 of 4 calls so the vault is not paused half of the time.
    function pause(uint256 seed) public counted("pause") {
        if (seed % 4 != 0) return;

        vm.startPrank(guardian);
        vault.pause();
        vm.stopPrank();
    }

    function unpause() public counted("unpause") {
        vm.startPrank(admin);
        vault.unpause();
        vm.stopPrank();
    }

    /**********************************************************************************************/
    /*** Queue processing                                                                       ***/
    /**********************************************************************************************/

    function processDepositQueue(uint256 maxSavingsShares, uint256 maxRequests, uint256 seed)
        public counted("processDepositQueue")
    {
        if (vault.paused()) return;

        uint256 kind = seed % 4;
        if (kind == 0) maxSavingsShares = type(uint256).max;
        else           maxSavingsShares = _bound(maxSavingsShares, 0, vault.pendingDepositSavingsShares() + 1e12);

        maxRequests = kind == 1 ? type(uint256).max : _bound(maxRequests, 0, 8);

        uint256          head         = vault.depositHead();
        uint256[] memory sharesBefore = _snapshotDepositQueue(head);
        uint256[N] memory balsBefore  = _balances();
        uint256          supplyBefore = vault.totalSupply();

        vm.startPrank(rebalancer);
        vault.processDepositQueue(maxSavingsShares, maxRequests);
        vm.stopPrank();

        _countDepositFills(head, sharesBefore, supplyBefore);
        _attributeMints(balsBefore);
        _capacityCheck(supplyBefore);
    }

    function processRedeemQueue(uint256 maxShares, uint256 maxRequests, uint256 seed)
        public counted("processRedeemQueue")
    {
        if (vault.paused()) return;

        uint256 kind = seed % 4;
        if (kind == 0) maxShares = type(uint256).max;
        else           maxShares = _bound(maxShares, 0, vault.pendingRedeemShares() + 1e12);

        maxRequests = kind == 1 ? type(uint256).max : _bound(maxRequests, 0, 8);

        uint256          head         = vault.redeemHead();
        uint256[] memory sharesBefore = _snapshotRedeemQueue(head);

        // The call is wrapped: spUSDC's `withdraw` burns ceil(assets*RAY/chi_s) shares per fill,
        // so a multi-entry fill bounded by the vault's spUSDC *balance* (not spUSDC liquidity) can
        // exceed the balance by up to one share per entry and revert. Observed, not asserted.
        vm.startPrank(rebalancer);
        try vault.processRedeemQueue(maxShares, maxRequests) {
            vm.stopPrank();
            _countRedeemFills(head, sharesBefore);
        } catch Error(string memory reason) {
            vm.stopPrank();
            lastRedeemProcessRevert = reason;
            if (keccak256(bytes(reason)) == keccak256("SparkVault/insufficient-balance")) {
                redeemProcessReverts++;
            } else {
                redeemProcessRevertsOther++;
            }
        }
    }

    /**********************************************************************************************/
    /*** TAKER_ROLE: spUSDC out of and back into the vault                                      ***/
    /**********************************************************************************************/

    function take(uint256 savingsShares, uint256 seed) public counted("take") {
        uint256 balance = spUsdc.balanceOf(address(vault));
        if (balance == 0) return;

        savingsShares = seed % 4 == 0 ? balance : _bound(savingsShares, 0, balance);

        vm.startPrank(taker);
        vault.take(savingsShares);
        vm.stopPrank();

        takerOutstandingSpUsdc += savingsShares;
    }

    // Returns taken spUSDC by plain transfer. The taker mints what it does not hold (USDC minted
    // from thin air, tracked as `takerInjectedUsdc`). ~1 in 4 calls returns everything outstanding.
    function returnToVault(uint256 savingsShares, uint256 seed) public counted("returnToVault") {
        if (takerOutstandingSpUsdc == 0) return;

        savingsShares = seed % 4 == 0
            ? takerOutstandingSpUsdc
            : _bound(savingsShares, 0, takerOutstandingSpUsdc);
        if (savingsShares == 0) return;

        uint256 held = spUsdc.balanceOf(taker);

        vm.startPrank(taker);
        if (held < savingsShares) {
            uint256 assets = spUsdc.previewMint(savingsShares - held);
            usdc.mint(taker, assets);
            totalUsdcMinted   += assets;
            takerInjectedUsdc += assets;
            usdc.approve(address(spUsdc), assets);
            spUsdc.mint(savingsShares - held, taker);
        }
        spUsdc.transfer(address(vault), savingsShares);
        vm.stopPrank();

        takerOutstandingSpUsdc -= savingsShares;
        takerReturnedSpUsdc    += savingsShares;
    }

    /**********************************************************************************************/
    /*** spUSDC liquidity                                                                       ***/
    /**********************************************************************************************/

    function drainSpUsdcLiquidity(uint256 amount, uint256 seed) public counted("drainSpUsdcLiquidity") {
        uint256 liquidity = usdc.balanceOf(address(spUsdc));
        if (liquidity == 0) return;

        amount = seed % 4 == 0 ? liquidity : _bound(amount, 0, liquidity);

        vm.startPrank(spTaker);
        spUsdc.take(amount);
        vm.stopPrank();
    }

    // USDC minted straight into spUSDC: the spUSDC taker's capital (plus yield) coming home.
    function returnSpUsdcLiquidity(uint256 amount, uint256 seed) public counted("returnSpUsdcLiquidity") {
        uint256 owed = spUsdc.assetsOutstanding();

        amount = seed % 4 == 0 ? owed : _bound(amount, 0, owed + 1_000e6);
        if (amount == 0) return;

        usdc.mint(address(spUsdc), amount);
        totalUsdcMinted   += amount;
        spUsdcYieldMinted += amount;
    }

    /**********************************************************************************************/
    /*** Time                                                                                   ***/
    /**********************************************************************************************/

    function warp(uint256 secs) public counted("warp") {
        secs = _bound(secs, 1, 30 days);
        vm.warp(block.timestamp + secs);
        spUsdc.drip();
        vault.drip();
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }
    function _max(uint256 a, uint256 b) internal pure returns (uint256) { return a > b ? a : b; }

}
