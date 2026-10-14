// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import "./a_init.sol";

// User flows: deposit requests (with and without referral, including zero-amount ghosts), deposit
// cancels (into the cancelled-deposit queue), redeem requests (including zero-share and one-wei
// ghosts), redeem cancels, recipient updates by arbitrary callers, transfers and transferFrom.
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

    // Cancels move the entry into the cancelled-deposit queue; nothing is paid here, so the
    // backing being taken or spent no longer blocks the cancel (the round-1 F-2 skip is gone).
    function cancelDepositRequest(uint256 idSeed, uint256 recipientIndex, uint256 seed)
        public counted("cancelDepositRequest")
    {
        if (vault.paused()) return;

        uint256 head = vault.depositHead();
        if (head >= depositQueueLength) return;

        uint256 id = _bound(idSeed, head, depositQueueLength - 1);

        (address owner, , uint256 shares) = vault.depositQueue(id);
        if (shares == 0) return;

        bool    byGuardian = seed % 3 == 0;
        address caller     = byGuardian ? guardian : owner;
        address recipient  = getRandomUser(recipientIndex);

        uint256 pendingBefore          = vault.pendingDepositSavingsShares();
        uint256 pendingCancelledBefore = vault.pendingCancelledDepositSavingsShares();
        uint256 spUsdcBefore           = spUsdc.balanceOf(address(vault));
        uint256 usersUsdcBefore        = _usersUsdc();

        vm.startPrank(caller);
        uint256 cancelId = vault.cancelDepositRequest(id, recipient);
        vm.stopPrank();

        assertEq(cancelId, cancelledQueueLength, "handler: unexpected cancel request id");
        cancelledQueueLength++;

        (, , uint256 sharesAfter) = vault.depositQueue(id);
        assertEq(sharesAfter, 0, "handler: cancel left deposit entry open");

        (address cOwner, address cRecipient, uint256 cShares) = vault.cancelledDepositQueue(cancelId);
        assertEq(cOwner,     owner,     "handler: cancelled entry owner");
        assertEq(cRecipient, recipient, "handler: cancelled entry recipient");
        assertEq(cShares,    shares,    "handler: cancelled entry shares");

        assertEq(vault.pendingDepositSavingsShares(),          pendingBefore - shares,          "handler: cancel pending deposit");
        assertEq(vault.pendingCancelledDepositSavingsShares(), pendingCancelledBefore + shares, "handler: cancel pending cancelled");
        assertEq(spUsdc.balanceOf(address(vault)),             spUsdcBefore,                    "handler: cancel moved spUSDC");
        assertEq(_usersUsdc(),                                 usersUsdcBefore,                 "handler: cancel paid USDC");
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

        uint256 balance   = vault.balanceOf(user);
        uint256 minShares = vault.minRedeem();  // [shares]

        uint256 kind = seed % 10;
        if (kind == 0 && minShares == 0) {
            shares = 0;  // zero-share ghost entry, allowed by the contract
        } else {
            if (minShares == 0) minShares = 1;
            if (balance < minShares) return;
            // ~10% minimum-size requests (ghost entries when the fee eats everything).
            shares = kind == 1 ? minShares : _bound(shares, minShares, balance);
        }

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

        // Upstream pays the `recipient_` argument whoever the caller is.
        ghostRefunded[recipient] += shares;
    }

    /**********************************************************************************************/
    /*** Recipient updates (unauthenticated upstream: any caller, any entry)                    ***/
    /**********************************************************************************************/

    // A random user repoints a random entry (open when there is one, closed otherwise) of one of
    // the three queues to a random user. The handler asserts that only the recipient field moved
    // (invariant R) and attributes later fills by balance diff (invariant J).
    function updateRecipient(
        uint256 queueSeed,
        uint256 idSeed,
        uint256 callerIndex,
        uint256 recipientIndex
    )
        public counted("updateRecipient")
    {
        uint256 q = queueSeed % 3;

        uint256 length = q == 0 ? depositQueueLength
                       : q == 1 ? cancelledQueueLength
                       :          redeemQueueLength;
        if (length == 0) return;

        uint256 head = q == 0 ? vault.depositHead()
                     : q == 1 ? vault.cancelledDepositHead()
                     :          vault.redeemHead();

        uint256 id = head < length ? _bound(idSeed, head, length - 1) : _bound(idSeed, 0, length - 1);

        address caller    = getRandomUser(callerIndex);
        address recipient = getRandomUser(recipientIndex);

        (address owner, , ) = q == 0 ? vault.depositQueue(id)
                            : q == 1 ? vault.cancelledDepositQueue(id)
                            :          vault.redeemQueue(id);

        bytes32 before = _stateDigest();

        vm.startPrank(caller);
        if      (q == 0) vault.updateDepositRecipient(id, recipient);
        else if (q == 1) vault.updateCancelledDepositRecipient(id, recipient);
        else             vault.updateRedeemRecipient(id, recipient);
        vm.stopPrank();

        if (_stateDigest() != before) recipientUpdateChangedState = true;

        (, address recipientAfter, ) = q == 0 ? vault.depositQueue(id)
                                     : q == 1 ? vault.cancelledDepositQueue(id)
                                     :          vault.redeemQueue(id);
        assertEq(recipientAfter, recipient, "handler: recipient not updated");

        recipientUpdates++;
        if (caller != owner) recipientUpdatesByStranger++;
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
