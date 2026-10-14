// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import "./b_flows_user.sol";

// Admin / role / environment flows: capacity, fee, minimums, both VSRs, pause/unpause, loss and
// gain realisation, the three queue processors, take/return, spUSDC liquidity drains and returns,
// time.
contract FlowsAdmin is FlowsUser {

    constructor(address vault_) FlowsUser(vault_) {}

    /**********************************************************************************************/
    /*** Parameters                                                                             ***/
    /**********************************************************************************************/

    // `setCapacity` no longer bounds the value; the handler keeps it <= uint128.max because a
    // larger capacity overflows `convertToAssets(availableCapacity())` and bricks deposits.
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

    function setRedeemFeeRate(uint256 fee) public counted("setRedeemFee") {
        fee = _bound(fee, 0, vault.maxRedeemFeeRate());

        vm.startPrank(riskManager);
        vault.setRedeemFeeRate(fee);
        vm.stopPrank();
    }

    // Half of the calls clear the minimum so zero-amount requests stay reachable.
    function setMinDeposit(uint256 minDeposit, uint256 seed) public counted("setMinDeposit") {
        minDeposit = seed % 2 == 0 ? 0 : _bound(minDeposit, 1, 10e6);

        vm.startPrank(admin);
        vault.setMinDeposit(minDeposit);
        vm.stopPrank();
    }

    // `minRedeem` is denominated in shares.
    function setMinRedeem(uint256 minRedeem, uint256 seed) public counted("setMinRedeem") {
        minRedeem = seed % 2 == 0 ? 0 : _bound(minRedeem, 1, 10e6);

        vm.startPrank(admin);
        vault.setMinRedeem(minRedeem);
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
    /*** Pause and losses                                                                       ***/
    /**********************************************************************************************/

    // Pauses in ~1 of 4 calls so the vault is not paused half of the time (GUARDIAN_ROLE).
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

    // Small losses (`1 <= loss <= totalAssets / 10`, so `0 < loss < totalAssets` always holds),
    // only while paused with a live supply, and only when the resulting chi stays positive. The
    // handler asserts the contract's floor (`totalAssets after + loss <= totalAssets before`),
    // records the per-call accounting error (invariant T) and lowers the deficit ledger by the
    // loss (invariant H).
    function realizeLoss(uint256 loss) public counted("realizeLoss") {
        if (!vault.paused()) return;

        uint256 supply = vault.totalSupply();
        if (supply == 0) return;

        uint256 assetsBefore = vault.totalAssets();
        if (assetsBefore < 10) return;

        loss = _bound(loss, 1, assetsBefore / 10);

        if (((assetsBefore - loss) * RAY) / supply == 0) return;

        uint256 chiBefore = vault.nowChi();

        vm.startPrank(riskManager);
        vault.realizeLoss(loss);
        vm.stopPrank();

        uint256 assetsAfter = vault.totalAssets();

        assertLt(vault.nowChi(), chiBefore, "handler: realizeLoss did not lower chi");
        assertGt(vault.nowChi(), 0,         "handler: realizeLoss zeroed chi");
        assertLe(assetsAfter + loss, assetsBefore, "handler: loss under-applied");

        _recordGainLossError(assetsBefore, assetsAfter, loss, false);

        lossRealizations++;
        realizedLossUsdc += loss;
        ghostDeficitUsdc -= int256(loss);

        lastChi = vault.nowChi();  // sanctioned chi decrease (invariant G)
    }

    // Small gains (`1 <= gain <= totalAssets / 10`), admin only, in any pause state, only with a
    // live supply, and skipped when the resulting chi would pass 1e30 (keeps every conversion far
    // from overflow). No backing arrives in the harness, so the gain raises the deficit ledger
    // (invariant H) and the per-call accounting error is recorded (invariant T).
    function realizeGain(uint256 gain) public counted("realizeGain") {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;

        uint256 assetsBefore = vault.totalAssets();
        if (assetsBefore < 10) return;

        gain = _bound(gain, 1, assetsBefore / 10);

        if (((assetsBefore + gain) * RAY) / supply > 1e30) return;

        uint256 chiBefore = vault.nowChi();

        vm.startPrank(admin);
        vault.realizeGain(gain);
        vm.stopPrank();

        uint256 assetsAfter = vault.totalAssets();

        assertGe(vault.nowChi(), chiBefore,     "handler: realizeGain lowered chi");
        assertLe(assetsAfter, assetsBefore + gain, "handler: gain over-applied");

        _recordGainLossError(assetsBefore, assetsAfter, gain, true);

        gainRealizations++;
        realizedGainUsdc += gain;
        ghostDeficitUsdc += int256(gain);

        lastChi = vault.nowChi();  // sanctioned chi increase outside warp (invariant G)
    }

    /**********************************************************************************************/
    /*** Queue processing                                                                       ***/
    /**********************************************************************************************/

    function processPendingDeposits(uint256 maxSavingsShares, uint256 maxRequests, uint256 seed)
        public counted("processPendingDeposits")
    {
        if (vault.paused()) return;

        uint256 kind = seed % 4;
        if (kind == 0) maxSavingsShares = type(uint256).max;
        else           maxSavingsShares = _bound(maxSavingsShares, 0, vault.pendingDepositSavingsShares() + 1e12);

        maxRequests = kind == 1 ? type(uint256).max : _bound(maxRequests, 0, 8);

        uint256          head         = vault.firstPendingDepositId();
        uint256[] memory sharesBefore = _snapshotDepositQueue(head);
        uint256[N] memory balsBefore  = _balances();
        uint256          supplyBefore = vault.totalSupply();

        vm.startPrank(rebalancer);
        vault.processPendingDeposits(maxSavingsShares, maxRequests);
        vm.stopPrank();

        _countDepositFills(head, sharesBefore, supplyBefore);
        _attributeMints(balsBefore);
        _capacityCheck(supplyBefore);
    }

    // Pays cancelled deposits by spUSDC `redeem` with a budget of min(max, spUSDC.maxRedeem(vault)),
    // which caps at both the vault's spUSDC balance and spUSDC's USDC liquidity, so since ff828d2
    // the call must never revert. Any revert is counted and its reason kept (invariant P).
    function processPendingDepositCancellations(uint256 maxSavingsShares, uint256 maxRequests, uint256 seed)
        public counted("processPendingDepositCancellations")
    {
        if (vault.paused()) return;

        uint256 kind = seed % 4;
        if (kind == 0) maxSavingsShares = type(uint256).max;
        else           maxSavingsShares = _bound(maxSavingsShares, 0, vault.pendingCancelledDepositSavingsShares() + 1e12);

        maxRequests = kind == 1 ? type(uint256).max : _bound(maxRequests, 0, 8);

        uint256          head            = vault.firstPendingDepositCancellationId();
        uint256[] memory sharesBefore    = _snapshotCancelledQueue(head);
        uint256          usersUsdcBefore = _usersUsdc();
        uint256          supplyBefore    = vault.totalSupply();

        vm.startPrank(rebalancer);
        try vault.processPendingDepositCancellations(maxSavingsShares, maxRequests) {
            vm.stopPrank();
            _countCancelledFills(head, sharesBefore);
            usersRefundedUsdc += _usersUsdc() - usersUsdcBefore;
            assertEq(vault.totalSupply(), supplyBefore, "handler: refund changed totalSupply");
        } catch Error(string memory reason) {
            vm.stopPrank();
            cancelProcessReverts++;
            lastCancelProcessRevert = reason;
        } catch {
            vm.stopPrank();
            cancelProcessReverts++;
            lastCancelProcessRevert = "<non-string revert>";
        }
    }

    function processPendingRedeems(uint256 maxShares, uint256 maxRequests, uint256 seed)
        public counted("processPendingRedeems")
    {
        if (vault.paused()) return;

        uint256 kind = seed % 4;
        if (kind == 0) maxShares = type(uint256).max;
        else           maxShares = _bound(maxShares, 0, vault.pendingRedeemShares() + 1e12);

        maxRequests = kind == 1 ? type(uint256).max : _bound(maxRequests, 0, 8);

        uint256          head            = vault.firstPendingRedeemId();
        uint256[] memory sharesBefore    = _snapshotRedeemQueue(head);
        uint256          usersUsdcBefore = _usersUsdc();

        // The call is wrapped: spUSDC's `withdraw` burns ceil(assets*RAY/chi_s) shares per fill,
        // so a multi-entry fill bounded by the vault's spUSDC *balance* (not spUSDC liquidity) can
        // exceed the balance by up to one share per entry and revert. Observed, not asserted.
        vm.startPrank(rebalancer);
        try vault.processPendingRedeems(maxShares, maxRequests) {
            vm.stopPrank();
            _countRedeemFills(head, sharesBefore);
            usersRedeemedUsdc += _usersUsdc() - usersUsdcBefore;
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

    // The only handler that moves time. Scales the deficit ledger (invariant H) by the index the
    // bound follows: spUSDC's while the ledger is positive, spPRIME's while it is negative.
    function warp(uint256 secs) public counted("warp") {
        secs = _bound(secs, 1, 30 days);

        uint256 chiSBefore = spUsdc.nowChi();
        uint256 chiPBefore = vault.nowChi();

        vm.warp(block.timestamp + secs);
        spUsdc.drip();
        vault.drip();

        uint256 chiSAfter = spUsdc.nowChi();
        uint256 chiPAfter = vault.nowChi();

        assertGe(chiPAfter, chiPBefore, "handler: warp lowered chi");

        if (ghostDeficitUsdc > 0) _scaleDeficit(chiSBefore, chiSAfter);
        else                      _scaleDeficit(chiPBefore, chiPAfter);

        lastChi = chiPAfter;  // sanctioned chi increase (invariant G)
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }
    function _max(uint256 a, uint256 b) internal pure returns (uint256) { return a > b ? a : b; }

}
