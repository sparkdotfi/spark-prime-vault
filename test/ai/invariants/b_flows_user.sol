// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import "./a_init.sol";

// User flows: deposit requests (with and without referral, including zero-amount ghosts), deposit
// cancels (into the cancelled-deposit queue, by the owner or by the guardian refunding the owner),
// redeem requests (including zero-share and one-wei ghosts; redeems cannot be cancelled since
// bf93b0d), owner recipient updates (plus stranger attempts), transfers and transferFrom.
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
    function requestDepositCancellation(uint256 idSeed, uint256 recipientIndex, uint256 seed)
        public counted("requestDepositCancellation")
    {
        if (vault.paused()) return;

        uint256 head = vault.firstPendingDepositId();
        if (head >= depositQueueLength) return;

        uint256 id = _bound(idSeed, head, depositQueueLength - 1);

        (address owner, , uint256 shares) = _depositRequest(id);
        if (shares == 0) return;

        // The guardian may cancel on the owner's behalf but must refund the owner (bf93b0d).
        bool    byGuardian = seed % 3 == 0;
        address recipient  = byGuardian ? owner : getRandomUser(recipientIndex);

        if (byGuardian) _probeGuardianCancel(id, owner, recipientIndex);

        uint256[4] memory before = [
            vault.pendingDepositSavingsShares(),
            vault.pendingCancelledDepositSavingsShares(),
            spUsdc.balanceOf(address(vault)),
            _usersUsdc()
        ];

        vm.startPrank(byGuardian ? guardian : owner);
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

    // A guardian cancel that would pay anyone but the owner must revert `invalid-recipient`
    // (bf93b0d). Asserted inline; counts reported in afterInvariant().
    function _probeGuardianCancel(uint256 id, address owner, uint256 recipientIndex) internal {
        address other = getRandomUser(recipientIndex);
        if (other == owner) other = users[(_bound(recipientIndex, 0, N - 1) + 1) % N];

        guardianCancelProbes++;

        vm.startPrank(guardian);
        try vault.requestDepositCancellation(id, other) {
            lastGuardianCancelProbe = "<no revert>";
        } catch Error(string memory r) {
            lastGuardianCancelProbe = r;
            if (keccak256(bytes(r)) == keccak256("SparkPrimeVault/invalid-recipient")) {
                guardianCancelProbeReverts++;
            }
        } catch {
            lastGuardianCancelProbe = "<non-string revert>";
        }
        vm.stopPrank();

        assertEq(
            guardianCancelProbeReverts, guardianCancelProbes,
            string.concat("handler: guardian cancel to a non-owner did not revert invalid-recipient: ", lastGuardianCancelProbe)
        );
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
    /*** Recipient updates (owner-only since ff828d2, open entries only)                         ***/
    /**********************************************************************************************/

    // The entry OWNER repoints a random open entry of one of the three queues to a random user.
    // The handler asserts that only the recipient field moved (invariant R) and attributes later
    // fills by balance diff (invariant J). In ~1 of 8 calls a user who is not the owner tries the
    // same update; that attempt must revert with exactly `SparkPrimeVault/not-authorized`
    // (invariant S).
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

        uint256 head = q == 0 ? vault.firstPendingDepositId()
                     : q == 1 ? vault.firstPendingDepositCancellationId()
                     :          vault.firstPendingRedeemId();
        if (head >= length) return;

        // Scan forward from a random start for an open entry (closed ones revert `no-request`).
        uint256 id = _bound(idSeed, head, length - 1);
        address owner;
        uint256 shares;
        for (uint256 i = id; i < length; i++) {
            (owner, , shares) = _entry(q, i);
            if (shares != 0) { id = i; break; }
        }
        if (shares == 0) return;

        address recipient = getRandomUser(recipientIndex);

        if (queueSeed / 3 % 8 == 0) {
            uint256 ci = callerIndex % N;
            if (users[ci] == owner) ci = (ci + 1) % N;
            address stranger = users[ci];
            assertTrue(stranger != owner, "handler: stranger is the owner");

            recipientUpdateStrangerAttempts++;

            vm.startPrank(stranger);
            bool ok;
            string memory reason;
            if      (q == 0) { try vault.updateDepositRecipient(id, recipient)          { ok = true; } catch Error(string memory r) { reason = r; } catch {} }
            else if (q == 1) { try vault.updateDepositCancellationRecipient(id, recipient) { ok = true; } catch Error(string memory r) { reason = r; } catch {} }
            else             { try vault.updateRedeemRecipient(id, recipient)           { ok = true; } catch Error(string memory r) { reason = r; } catch {} }
            vm.stopPrank();

            lastStrangerUpdateRevert = ok ? "<no revert>" : reason;
            if (!ok && keccak256(bytes(reason)) == keccak256("SparkPrimeVault/not-authorized")) {
                recipientUpdateStrangerReverts++;
            }
            return;
        }

        bytes32 before = _stateDigest();

        vm.startPrank(owner);
        _updateRecipient(q, id, recipient);
        vm.stopPrank();

        if (_stateDigest() != before) recipientUpdateChangedState = true;

        (, address recipientAfter, ) = _entry(q, id);
        assertEq(recipientAfter, recipient, "handler: recipient not updated");

        recipientUpdates++;
    }

    function _updateRecipient(uint256 q, uint256 id, address recipient) internal {
        if      (q == 0) vault.updateDepositRecipient(id, recipient);
        else if (q == 1) vault.updateDepositCancellationRecipient(id, recipient);
        else             vault.updateRedeemRecipient(id, recipient);
    }

    function _entry(uint256 q, uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        return q == 0 ? _depositRequest(id)
             : q == 1 ? _cancelledDepositRequest(id)
             :          _redeemRequest(id);
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
