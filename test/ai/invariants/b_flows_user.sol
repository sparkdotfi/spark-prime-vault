// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import "./a_init.sol";

// User flows: deposit requests (with and without referral, including zero-amount ghosts), owner
// deposit cancels (into the cancelled-deposit queue), redeem requests (including zero-share and
// one-wei ghosts; redeems cannot be cancelled), owner recipient updates to active / fresh /
// blacklisted holders (plus stranger attempts), transfers, transferFrom, USDC blacklisting of
// holders, and `claim`.
//
// Every guard the blacklist adds (`recipient-cannot-receive` on requestRedeem,
// requestDepositCancellation, updateDepositCancellationRecipient, updateRedeemRecipient) is
// probed, not avoided: the handler calls with the blacklisted recipient and asserts the exact
// revert reason.
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
        address recipient = getRandomHolder(recipientIndex);  // blacklisted recipients are allowed

        // A blacklisted depositor cannot approve or be pulled from in USDC (mock mirrors mainnet).
        if (usdc.isBlacklisted(user)) { skippedBlacklistedDepositors++; return; }

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
            : vault.requestDeposit(assets, recipient, 0);
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

    // Owner-only since 0ebb452 (guardian path removed). Moves the entry into the cancelled-deposit
    // queue; nothing is paid here. A blacklisted recipient is probed for the exact guard revert.
    function requestDepositCancellation(uint256 idSeed, uint256 recipientIndex, uint256 seed)
        public counted("requestDepositCancellation")
    {
        if (vault.paused()) return;

        uint256 head = vault.firstPendingDepositId();
        if (head >= depositQueueLength) return;

        uint256 id = _bound(idSeed, head, depositQueueLength - 1);

        (address owner, , uint256 shares) = _depositRequest(id);
        if (shares == 0) return;

        address recipient = seed % 5 == 0 ? owner : getRandomHolder(recipientIndex);

        if (usdc.isBlacklisted(recipient)) {
            vm.startPrank(owner);
            try vault.requestDepositCancellation(id, recipient) {
                vm.stopPrank();
                lastBlacklistProbeRevert = "<no revert>";
                blacklistRecipientProbes++;
            } catch Error(string memory r) {
                vm.stopPrank();
                _probeBlacklistRevert(r);
            } catch {
                vm.stopPrank();
                _probeBlacklistRevert("<non-string revert>");
            }
            return;
        }

        uint256[4] memory before = [
            vault.pendingDepositSavingsShares(),
            vault.pendingCancelledDepositSavingsShares(),
            spUsdc.balanceOf(address(vault)),
            _usersUsdc()
        ];

        vm.startPrank(owner);
        uint256 cancelId = vault.requestDepositCancellation(id, recipient);
        vm.stopPrank();

        assertEq(cancelId, cancelledQueueLength, "handler: unexpected cancel request id");
        cancelledQueueLength++;

        _checkCancel(id, cancelId, owner, recipient, shares, before);
    }

    function _checkCancel(
        uint256 id,
        uint256 cancelId,
        address owner,
        address recipient,
        uint256 shares,
        uint256[4] memory before
    ) internal view {
        (, , uint256 sharesAfter) = _depositRequest(id);
        assertEq(sharesAfter, 0, "handler: cancel left deposit entry open");

        (address cOwner, address cRecipient, uint256 cShares) = _cancelledDepositRequest(cancelId);
        assertEq(cOwner,     owner,     "handler: cancelled entry owner");
        assertEq(cRecipient, recipient, "handler: cancelled entry recipient");
        assertEq(cShares,    shares,    "handler: cancelled entry shares");

        assertEq(vault.pendingDepositSavingsShares(),          before[0] - shares, "handler: cancel pending deposit");
        assertEq(vault.pendingCancelledDepositSavingsShares(), before[1] + shares, "handler: cancel pending cancelled");
        assertEq(spUsdc.balanceOf(address(vault)),             before[2],          "handler: cancel moved spUSDC");
        assertEq(_usersUsdc(),                                 before[3],          "handler: cancel paid USDC");
    }

    // A request or update naming a blacklisted recipient must revert with exactly
    // `SparkPrimeVault/recipient-cannot-receive`.
    function _probeBlacklistRevert(string memory reason) internal {
        blacklistRecipientProbes++;
        lastBlacklistProbeRevert = reason;
        if (_recordRevert(reason, _eq(reason, "SparkPrimeVault/recipient-cannot-receive"))) {
            blacklistRecipientProbeReverts++;
        }
    }

    /**********************************************************************************************/
    /*** Redeems                                                                                ***/
    /**********************************************************************************************/

    function requestRedeem(uint256 shares, uint256 userIndex, uint256 recipientIndex, uint256 seed)
        public counted("requestRedeem")
    {
        if (vault.paused()) return;

        address user      = getRandomUser(userIndex);
        address recipient = getRandomHolder(recipientIndex);

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

        if (usdc.isBlacklisted(recipient)) {
            bytes32 before = _stateDigest();
            vm.startPrank(user);
            try vault.requestRedeem(shares, recipient) {
                vm.stopPrank();
                lastBlacklistProbeRevert = "<no revert>";
                blacklistRecipientProbes++;
            } catch Error(string memory r) {
                vm.stopPrank();
                _probeBlacklistRevert(r);
            } catch {
                vm.stopPrank();
                _probeBlacklistRevert("<non-string revert>");
            }
            assertEq(_stateDigest(), before, "handler: blacklisted-recipient redeem probe moved state");
            return;
        }

        uint256 fee = _divup(shares * vault.redeemFeeRate(), WAD);
        if (shares - fee == 0) ghostRedeemEntries++;

        vm.startPrank(user);
        uint256 id = vault.requestRedeem(shares, recipient);
        vm.stopPrank();

        assertEq(id, redeemQueueLength, "handler: unexpected redeem request id");
        redeemQueueLength++;

        ghostEscrowed[user] += shares;
    }

    /**********************************************************************************************/
    /*** Recipient updates (owner-only, open entries only)                                      ***/
    /**********************************************************************************************/

    // The entry OWNER repoints a random open entry of one of the three queues to a random holder
    // (active, fresh or blacklisted). The handler asserts that only the recipient field moved
    // (invariant R) and attributes later fills by balance diff (invariant J). In ~1 of 8 calls a
    // user who is not the owner tries the same update; that attempt must revert with exactly
    // `SparkPrimeVault/not-authorized` (invariant S). A blacklisted recipient is accepted by the
    // deposit queue and must be rejected with `recipient-cannot-receive` by the other two.
    function updateRecipient(
        uint256 queueSeed,
        uint256 idSeed,
        uint256 callerIndex,
        uint256 recipientIndex
    )
        public counted("updateRecipient")
    {
        uint256 q = queueSeed % 3;

        (uint256 id, address owner, bool found) = _findOpenEntry(q, idSeed);
        if (!found) return;

        address recipient = getRandomHolder(recipientIndex);

        if (queueSeed / 3 % 8 == 0) {
            _strangerUpdate(q, id, owner, recipient, callerIndex);
            return;
        }

        _ownerUpdate(q, id, owner, recipient);

        if (_bound(recipientIndex, 0, N - 1) >= ACTIVE && !usdc.isBlacklisted(recipient)) {
            recipientUpdatesToFresh++;
        }
    }

    // Scans forward from a random start for an open entry (closed ones revert `no-request`).
    function _findOpenEntry(uint256 q, uint256 idSeed)
        internal view returns (uint256 id, address owner, bool found)
    {
        uint256 length = q == 0 ? depositQueueLength
                       : q == 1 ? cancelledQueueLength
                       :          redeemQueueLength;

        uint256 head = q == 0 ? vault.firstPendingDepositId()
                     : q == 1 ? vault.firstPendingDepositCancellationId()
                     :          vault.firstPendingRedeemId();
        if (head >= length) return (0, address(0), false);

        for (uint256 i = _bound(idSeed, head, length - 1); i < length; i++) {
            (address o, , uint256 shares) = _entry(q, i);
            if (shares != 0) return (i, o, true);
        }
    }

    function _ownerUpdate(uint256 q, uint256 id, address owner, address recipient) internal {
        bytes32 before = _stateDigest();

        bool blacklisted = usdc.isBlacklisted(recipient);

        vm.startPrank(owner);
        (bool ok, string memory reason) = _tryUpdate(q, id, recipient);
        vm.stopPrank();

        if (_stateDigest() != before) recipientUpdateChangedState = true;

        if (q != 0 && blacklisted) {
            // The guard must have fired.
            if (ok) { lastBlacklistProbeRevert = "<no revert>"; blacklistRecipientProbes++; }
            else    _probeBlacklistRevert(reason);
            return;
        }

        if (!ok) { _recordRevert(reason, false); return; }

        (, address recipientAfter, ) = _entry(q, id);
        assertEq(recipientAfter, recipient, "handler: recipient not updated");

        recipientUpdates++;
        if (blacklisted) recipientUpdatesToBlacklisted++;
    }

    function _tryUpdate(uint256 q, uint256 id, address recipient)
        internal returns (bool ok, string memory reason)
    {
        if      (q == 0) { try vault.updateDepositRecipient(id, recipient)             { ok = true; } catch Error(string memory r) { reason = r; } catch { reason = "<non-string revert>"; } }
        else if (q == 1) { try vault.updateDepositCancellationRecipient(id, recipient) { ok = true; } catch Error(string memory r) { reason = r; } catch { reason = "<non-string revert>"; } }
        else             { try vault.updateRedeemRecipient(id, recipient)              { ok = true; } catch Error(string memory r) { reason = r; } catch { reason = "<non-string revert>"; } }
    }

    function _strangerUpdate(uint256 q, uint256 id, address owner, address recipient, uint256 callerIndex)
        internal
    {
        uint256 ci = callerIndex % ACTIVE;
        if (users[ci] == owner) ci = (ci + 1) % ACTIVE;
        address stranger = users[ci];
        assertTrue(stranger != owner, "handler: stranger is the owner");

        recipientUpdateStrangerAttempts++;

        bytes32 before = _stateDigest();

        vm.startPrank(stranger);
        (bool ok, string memory reason) = _tryUpdate(q, id, recipient);
        vm.stopPrank();

        assertEq(_stateDigest(), before, "handler: stranger update moved state");

        lastStrangerUpdateRevert = ok ? "<no revert>" : reason;

        // The blacklist guard runs before the ownership check on the cancel / redeem queues, so a
        // stranger naming a blacklisted recipient legitimately sees `recipient-cannot-receive`.
        bool blacklistFirst = q != 0 && usdc.isBlacklisted(recipient);
        if (!ok && _eq(reason, "SparkPrimeVault/not-authorized")) {
            _recordRevert(reason, true);
            recipientUpdateStrangerReverts++;
        } else if (!ok && blacklistFirst && _eq(reason, "SparkPrimeVault/recipient-cannot-receive")) {
            _recordRevert(reason, true);
            recipientUpdateStrangerReverts++;
        } else if (!ok) {
            _recordRevert(reason, false);
        }
    }

    function _entry(uint256 q, uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        return q == 0 ? _depositRequest(id)
             : q == 1 ? _cancelledDepositRequest(id)
             :          _redeemRequest(id);
    }

    /**********************************************************************************************/
    /*** Blacklist and claim                                                                    ***/
    /**********************************************************************************************/

    // USDC-blacklists (2 of 3 calls) or un-blacklists (1 of 3) a random holder. Role holders, the
    // vault and spUSDC are never blacklisted here (a blacklisted vault is a separate unit topic).
    function setBlacklisted(uint256 index, uint256 seed) public counted("setBlacklisted") {
        address who   = getRandomHolder(index);
        bool    state = seed % 3 != 0;

        // Sets prefer the recipient of an open redeem / cancellation entry (the shape that sends a
        // fill into `claimableAssets`); clears prefer a blacklisted holder that has a claimable,
        // so `claim` gets to pay out.
        if (state && seed / 3 % 4 != 0) {
            uint256 q    = seed / 12 % 2 == 0 ? 2 : 1;
            (uint256 id, , bool found) = _findOpenEntry(q, index);
            if (found) (, who, ) = _entry(q, id);
        }
        if (!state) {
            uint256 start = _bound(index, 0, N - 1);
            for (uint256 i = 0; i < N; i++) {
                address h = users[(start + i) % N];
                if (usdc.isBlacklisted(h) && vault.claimableAssets(h) != 0) { who = h; break; }
            }
        }

        usdc.setBlacklisted(who, state);

        if (state) blacklistSets++;
        else       blacklistClears++;
    }

    // Permissionless `claim(recipient)`, called by a random active user. Three outcomes: nothing
    // to claim (exact revert), recipient still blacklisted (USDC reverts, nothing moves), or paid.
    // 3 of 4 calls look for a holder that actually has something to claim (scanning from a random
    // start); the rest take the random holder as drawn so the `nothing-to-claim` guard is probed.
    function claim(uint256 index, uint256 callerIndex) public counted("claim") {
        address who    = getRandomHolder(index);
        address caller = getRandomUser(callerIndex);

        if (callerIndex % 4 != 0) {
            uint256 start = _bound(index, 0, N - 1);
            for (uint256 i = 0; i < N; i++) {
                address h = users[(start + i) % N];
                if (vault.claimableAssets(h) != 0 && (who == h || !usdc.isBlacklisted(h) || callerIndex / 4 % 3 == 0)) { who = h; break; }
            }
        }

        uint256 amount      = vault.claimableAssets(who);
        uint256 whoBefore   = usdc.balanceOf(who);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        if (amount == 0) {
            claimNothingProbes++;
            vm.startPrank(caller);
            try vault.claim(who) {
                vm.stopPrank();
                _recordRevert("<no revert: claim of nothing>", false);
            } catch Error(string memory r) {
                vm.stopPrank();
                if (_recordRevert(r, _eq(r, "SparkPrimeVault/nothing-to-claim"))) claimNothingProbeReverts++;
            } catch {
                vm.stopPrank();
                _recordRevert("<non-string revert: claim of nothing>", false);
            }
            return;
        }

        if (usdc.isBlacklisted(who)) {
            claimWhileBlacklistedAttempts++;
            vm.startPrank(caller);
            try vault.claim(who) {
                vm.stopPrank();
                claimPaidWhileBlacklisted = true;
                _recordRevert("<no revert: claim while blacklisted>", false);
            } catch Error(string memory r) {
                vm.stopPrank();
                if (_recordRevert(r, _eq(r, BLACKLISTED))) claimWhileBlacklistedReverts++;
            } catch {
                vm.stopPrank();
                _recordRevert("<non-string revert: claim while blacklisted>", false);
            }
            if (
                vault.claimableAssets(who)        != amount    ||
                usdc.balanceOf(who)               != whoBefore ||
                usdc.balanceOf(address(vault))    != vaultBefore
            ) claimChangedStateWhileBlacklisted = true;

            // Half of the time the recipient is cleared right away and the claim retried below.
            if (callerIndex / 4 % 2 != 0) return;
            usdc.setBlacklisted(who, false);
            blacklistClears++;
        }

        vm.startPrank(caller);
        uint256 paid = vault.claim(who);
        vm.stopPrank();

        assertEq(paid,                           amount,              "handler: claim returned wrong amount");
        assertEq(vault.claimableAssets(who),     0,                   "handler: claim left claimable");
        assertEq(usdc.balanceOf(who),            whoBefore + amount,  "handler: claim did not pay recipient");
        assertEq(usdc.balanceOf(address(vault)), vaultBefore - amount,"handler: claim did not debit vault");

        claims++;
        usersClaimedUsdc += amount;
    }

    /**********************************************************************************************/
    /*** ERC20                                                                                  ***/
    /**********************************************************************************************/

    function transfer(uint256 amount, uint256 userIndex, uint256 toIndex)
        public counted("transfer")
    {
        address user = getRandomUser(userIndex);
        address to   = getRandomHolder(toIndex);

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
        address to      = getRandomHolder(toIndex);

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
