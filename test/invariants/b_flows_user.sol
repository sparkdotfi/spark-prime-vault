// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import "./a_init.sol";

// User flows: deposit requests (with and without referral, including zero-amount ghosts), deposit
// cancels, redeem requests (including 1-wei ghosts), redeem cancels, transfers and transferFrom.
contract FlowsUser is Init {

    constructor(address vault_) Init(vault_) {}

    /**********************************************************************************************/
    /*** Deposits                                                                               ***/
    /**********************************************************************************************/

    function requestDeposit(uint256 assets, uint256 userIndex, uint256 recipientIndex, uint256 seed)
        public counted("requestDeposit")
    {
        _requestDeposit(assets, userIndex, recipientIndex, seed, false);
    }

    function requestDepositWithReferral(
        uint256 assets,
        uint256 userIndex,
        uint256 recipientIndex,
        uint256 seed
    )
        public counted("requestDepositWithReferral")
    {
        _requestDeposit(assets, userIndex, recipientIndex, seed, true);
    }

    function _requestDeposit(
        uint256 assets,
        uint256 userIndex,
        uint256 recipientIndex,
        uint256 seed,
        bool    referral
    )
        internal
    {
        if (vault.paused()) return;

        address user      = getRandomUser(userIndex);
        address recipient = getRandomUser(recipientIndex);

        uint256 minDeposit = vault.minDeposit();

        // ~10% zero-amount ghosts (only possible while minDeposit == 0), ~10% dust, rest normal.
        uint256 kind = seed % 10;
        if (kind == 0 && minDeposit == 0) {
            assets = 0;
        } else if (kind == 1) {
            assets = _bound(assets, minDeposit, minDeposit + 1_000);
        } else {
            assets = _bound(assets, minDeposit, MAX_DEPOSIT);
        }

        usdc.mint(user, assets);
        totalUsdcMinted         += assets;
        usersDepositedUsdc      += assets;
        depositedUsdc[user]     += assets;

        uint256[N] memory balsBefore = _balances();
        uint256 supplyBefore         = vault.totalSupply();
        uint256 spUsdcBefore         = spUsdc.balanceOf(address(vault));
        uint256 pendingBefore        = vault.pendingDepositSavingsShares();

        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        uint256 id = referral
            ? vault.requestDeposit(assets, recipient, uint16(seed))
            : vault.requestDeposit(assets, recipient);
        vm.stopPrank();

        assertEq(id, depositQueueLength, "handler: unexpected deposit request id");
        depositQueueLength++;

        uint256 savingsShares = spUsdc.balanceOf(address(vault)) - spUsdcBefore;
        if (savingsShares == 0) ghostDepositEntries++;

        // Instant fill bookkeeping: whatever was pushed and not left pending was consumed.
        uint256 consumed = savingsShares + pendingBefore - vault.pendingDepositSavingsShares();
        uint256 minted   = vault.totalSupply() - supplyBefore;

        if (consumed != 0) {
            depositFills++;
            if (minted == 0) zeroShareFills++;
        }

        _attributeMints(balsBefore);
        _capacityCheck(supplyBefore);
    }

    function cancelDepositRequest(uint256 idSeed, uint256 recipientIndex, uint256 seed)
        public counted("cancelDepositRequest")
    {
        if (vault.paused()) return;

        uint256 head = vault.depositHead();
        if (head >= depositQueueLength) return;

        uint256 id = _bound(idSeed, head, depositQueueLength - 1);

        (address owner, , uint256 shares) = vault.depositQueue(id);
        if (shares == 0) return;

        // F-2: the spUSDC backing the entry may have been taken or spent on redeems.
        if (spUsdc.balanceOf(address(vault)) < shares) { cancelDepositBlockedF2++; return; }
        if (usdc.balanceOf(address(spUsdc)) < spUsdc.convertToAssets(shares)) {
            cancelDepositBlockedF2++;
            return;
        }

        bool    byGuardian = seed % 3 == 0;
        address caller     = byGuardian ? guardian : owner;
        address recipient  = getRandomUser(recipientIndex);

        vm.startPrank(caller);
        vault.cancelDepositRequest(id, recipient);
        vm.stopPrank();

        (, , uint256 sharesAfter) = vault.depositQueue(id);
        assertEq(sharesAfter, 0, "handler: cancel left deposit entry open");
    }

    /**********************************************************************************************/
    /*** Redeems                                                                                ***/
    /**********************************************************************************************/

    function requestRedeem(uint256 shares, uint256 userIndex, uint256 recipientIndex, uint256 seed)
        public counted("requestRedeem")
    {
        if (vault.paused()) return;

        address user      = getRandomUser(userIndex);
        address recipient = getRandomUser(recipientIndex);

        uint256 balance = vault.balanceOf(user);
        if (balance == 0) return;

        // shares * chi / RAY >= minWithdraw
        uint256 chi_      = vault.nowChi();
        uint256 minShares = _divup(vault.minWithdraw() * RAY, chi_);
        if (minShares == 0) minShares = 1;
        if (balance < minShares) return;

        // ~10% one-wei requests (ghost entries when the fee eats the single wei).
        if (seed % 10 == 0 && minShares == 1) shares = 1;
        else                                  shares = _bound(shares, minShares, balance);

        uint256 fee = _divup(shares * vault.redeemFee(), WAD);
        if (shares - fee == 0) ghostRedeemEntries++;

        vm.startPrank(user);
        uint256 id = vault.requestRedeem(shares, recipient);
        vm.stopPrank();

        assertEq(id, redeemQueueLength, "handler: unexpected redeem request id");
        redeemQueueLength++;

        ghostEscrowed[user] += shares;
    }

    function cancelRedeemRequest(uint256 idSeed, uint256 recipientIndex, uint256 seed)
        public counted("cancelRedeemRequest")
    {
        if (vault.paused()) return;

        uint256 head = vault.redeemHead();
        if (head >= redeemQueueLength) return;

        uint256 id = _bound(idSeed, head, redeemQueueLength - 1);

        (address owner, , uint256 shares) = vault.redeemQueue(id);
        if (shares == 0) return;

        bool    byGuardian = seed % 3 == 0;
        address caller     = byGuardian ? guardian : owner;
        address recipient  = getRandomUser(recipientIndex);

        vm.startPrank(caller);
        vault.cancelRedeemRequest(id, recipient);
        vm.stopPrank();

        // The F-1 patch: a guardian cancel always refunds the owner.
        ghostRefunded[byGuardian ? owner : recipient] += shares;
    }

    /**********************************************************************************************/
    /*** ERC20                                                                                  ***/
    /**********************************************************************************************/

    function transfer(uint256 amount, uint256 userIndex, uint256 toIndex)
        public counted("transfer")
    {
        address user = getRandomUser(userIndex);
        address to   = getRandomUser(toIndex);

        amount = _bound(amount, 0, vault.balanceOf(user));

        vm.startPrank(user);
        vault.transfer(to, amount);
        vm.stopPrank();

        ghostTransferOut[user] += amount;
        ghostTransferIn[to]    += amount;
    }

    function transferFrom(uint256 amount, uint256 userIndex, uint256 spenderIndex, uint256 toIndex)
        public counted("transferFrom")
    {
        address user    = getRandomUser(userIndex);
        address spender = getRandomUser(spenderIndex);
        address to      = getRandomUser(toIndex);

        amount = _bound(amount, 0, vault.balanceOf(user));

        vm.startPrank(user);
        vault.approve(spender, amount);
        vm.stopPrank();

        vm.startPrank(spender);
        vault.transferFrom(user, to, amount);
        vm.stopPrank();

        ghostTransferOut[user] += amount;
        ghostTransferIn[to]    += amount;
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _divup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        unchecked { z = x != 0 ? ((x - 1) / y) + 1 : 0; }
    }

}
