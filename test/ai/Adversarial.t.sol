// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { LocalTestBase } from "./LocalTestBase.t.sol";

import { SparkPrimeVault } from "../../src/SparkPrimeVault.sol";

/**********************************************************************************************/
/*** Mocks                                                                                  ***/
/**********************************************************************************************/

// Recipient that records any call it receives. Used to prove no callback fires on fills.
contract CallbackRecorder {
    uint256 public calls;
    fallback() external payable { calls++; }
    receive()  external payable { calls++; }
}

// ERC-1271 signer that accepts exactly one (digest, signature) pair.
contract Erc1271Accepter {
    bytes32 public okDigest;
    bytes32 public okSigHash;
    function set(bytes32 digest_, bytes memory sig_) external {
        okDigest  = digest_;
        okSigHash = keccak256(sig_);
    }
    function isValidSignature(bytes32 digest_, bytes memory sig_) external view returns (bytes4) {
        if (digest_ == okDigest && keccak256(sig_) == okSigHash) return 0x1626ba7e;
        return 0xffffffff;
    }
}

// ERC-1271 signer that returns 64 bytes instead of 32 (malformed).
contract Erc1271Malformed {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        assembly {
            mstore(0x00, 0x1626ba7e00000000000000000000000000000000000000000000000000000000)
            mstore(0x20, 0)
            return(0x00, 0x40)
        }
    }
}

// ERC-1271 signer that tries to mutate vault state from inside the signature check.
contract Erc1271Reentrant {
    SparkPrimeVault public vault;
    constructor(SparkPrimeVault vault_) { vault = vault_; }
    function isValidSignature(bytes32, bytes memory) external returns (bytes4) {
        vault.approve(address(0xBEEF), 1);  // state write inside a staticcall: reverts
        return 0x1626ba7e;
    }
}

// ERC-1271 signer that holds spPRIME and tries to use the signature check to reach the queues
// (requestRedeem, updateRedeemRecipient) or to nest a second permit. `mode` selects the attempt.
contract Erc1271QueueReentrant {
    SparkPrimeVault public vault;
    uint256 public mode;
    uint256 public redeemId;
    constructor(SparkPrimeVault vault_) { vault = vault_; }
    function setMode(uint256 mode_) external { mode = mode_; }
    function requestRedeem(uint256 shares_) external { redeemId = vault.requestRedeem(shares_, address(this)); }
    function isValidSignature(bytes32, bytes memory sig_) external returns (bytes4) {
        if (mode == 1)      vault.requestRedeem(vault.balanceOf(address(this)), address(this));
        else if (mode == 2) vault.updateRedeemRecipient(redeemId, address(0xBEEF));
        else if (mode == 3) vault.permit(address(this), address(0xBEEF), 1, block.timestamp + 1, sig_);
        return 0x1626ba7e;
    }
}

// Contract with no receive, no fallback and no ERC-20/ERC-777 hooks: a mint to it must still work.
contract NoHooks {}

contract AdversarialTest is LocalTestBase {

    event Approval(address indexed owner, address indexed spender, uint256 value);

    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal attacker = makeAddr("attacker");
    address internal victim   = makeAddr("victim");
    address internal rando    = makeAddr("rando");

    uint256 internal signerPk = 0xA11CE;
    address internal signer;

    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;

    function setUp() public override {
        super.setUp();
        signer = vm.addr(signerPk);
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    // Makes both indexes arbitrary: accrue each at `vsr` for `secs`, then freeze at RAY.
    function _setUglyChis(uint256 vsrS, uint256 secsS, uint256 vsrP, uint256 secsP) internal {
        _setSpUsdcVsr(vsrS);
        _warp(secsS);
        _setSpUsdcVsr(RAY);
        _setPrimeVsr(vsrP);
        _warp(secsP);
        _setPrimeVsr(RAY);
        spUsdc.drip();
        vault.drip();
    }

    // Fills capacity exactly: `who` deposits `amt`, then capacity is pinned to totalSupply.
    function _fillCapacityExactly(address who, uint256 amt) internal {
        _deposit(who, amt);
        _setCapacity(vault.totalSupply());
        assertEq(vault.availableCapacity(), 0);
    }

    function _permitDigest(
        address owner_,
        address spender_,
        uint256 value_,
        uint256 nonce_,
        uint256 deadline_
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            "\x19\x01",
            vault.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(vault.PERMIT_TYPEHASH(), owner_, spender_, value_, nonce_, deadline_))
        ));
    }

    function _sumOpenDeposits() internal view returns (uint256 sum) {
        uint256 n = _depositQueueLength();
        for (uint256 i = 0; i < n; ++i) { ( , , uint256 s) = _depositRequest(i); sum += s; }
    }

    function _sumOpenRedeems() internal view returns (uint256 sum) {
        uint256 n = _redeemQueueLength();
        for (uint256 i = 0; i < n; ++i) { ( , , uint256 s) = _redeemRequest(i); sum += s; }
    }

    function _sumOpenCancelled() internal view returns (uint256 sum) {
        uint256 n = _cancelledDepositQueueLength();
        for (uint256 i = 0; i < n; ++i) { ( , , uint256 s) = _cancelledDepositRequest(i); sum += s; }
    }

    function _cancelledQueueLength() internal view returns (uint256) {
        return _cancelledDepositQueueLength();
    }



    /**********************************************************************************************/
    /*** 1. Rounding extraction round trips                                                     ***/
    /**********************************************************************************************/

    // Deposit X (instant), redeem everything, process. The user never gets back more than X and
    // the loss is bounded by the four floor operations along the path.
    function testFuzz_roundTrip_userNeverProfits(
        uint256 amt,
        uint256 vsrS,
        uint256 secsS,
        uint256 vsrP,
        uint256 secsP
    ) public {
        amt   = bound(amt,   0,   1e12 * 1e6);
        vsrS  = bound(vsrS,  RAY, MAX_VSR);
        vsrP  = bound(vsrP,  RAY, MAX_VSR);
        secsS = bound(secsS, 0,   365 days);
        secsP = bound(secsP, 0,   365 days);

        _setUglyChis(vsrS, secsS, vsrP, secsP);

        uint256 chiS = spUsdc.nowChi();
        uint256 chiP = vault.nowChi();

        _deposit(alice, amt);
        assertEq(usdc.balanceOf(alice), 0);

        uint256 shares = vault.balanceOf(alice);
        if (shares == 0) return;

        _requestRedeem(alice, shares);
        _processRedeems(type(uint256).max, 1);

        uint256 out = usdc.balanceOf(alice);

        assertLe(out, amt, "user profited on round trip");
        assertLe(amt - out, chiS / RAY + chiP / RAY + 4, "loss above rounding bound");
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    // Deposit X while capacity is full (queued), then cancel. Refund never exceeds X and the
    // loss is at most one spUSDC share of value.
    function testFuzz_depositCancelCycle_userNeverProfits(
        uint256 amt,
        uint256 vsrS,
        uint256 secsS,
        uint256 cycles
    ) public {
        amt    = bound(amt,    0,   1e12 * 1e6);
        vsrS   = bound(vsrS,   RAY, MAX_VSR);
        secsS  = bound(secsS,  0,   365 days);
        cycles = bound(cycles, 1,   5);

        _setUglyChis(vsrS, secsS, RAY, 0);
        _fillCapacityExactly(bob, 1_000e6);

        uint256 chiS = spUsdc.nowChi();

        _fund(alice, amt);
        uint256 totalIn;
        uint256 totalOut;

        for (uint256 c; c < cycles; ++c) {
            uint256 have = usdc.balanceOf(alice);
            totalIn += have;

            vm.prank(alice);
            uint256 id = vault.requestDeposit(have, alice, 0);

            assertEq(vault.balanceOf(alice), 0);  // nothing minted: capacity full

            (, , uint256 queued) = _depositRequest(id);
            if (queued == 0) { totalOut += 0; break; }  // 0-share entry: cannot cancel (F-5), USDC lost

            _cancelDepositAndSettle(alice, id);   // cancel is async now: planner settles

            uint256 back = usdc.balanceOf(alice);
            totalOut += back;

            assertLe(back, have, "cancel refunded more than deposited");
            assertLe(have - back, chiS / RAY + 1, "cancel loss above one spUSDC share");
        }

        assertLe(totalOut, totalIn);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // Three full round trips in a row: cumulative USDC out <= cumulative USDC in.
    function testFuzz_roundTrip_repeatedCyclesNeverProfit(uint256 amt, uint256 vsrP, uint256 secsP)
        public
    {
        amt   = bound(amt,   1e6, 1e9 * 1e6);
        vsrP  = bound(vsrP,  RAY, MAX_VSR);
        secsP = bound(secsP, 0,   365 days);

        _setUglyChis(RAY, 0, vsrP, secsP);

        _fund(alice, amt);

        for (uint256 c; c < 3; ++c) {
            uint256 have = usdc.balanceOf(alice);
            vm.prank(alice);
            vault.requestDeposit(have, alice, 0);
            uint256 shares = vault.balanceOf(alice);
            if (shares == 0) break;
            _requestRedeem(alice, shares);
            _processRedeems(type(uint256).max, 1);
            assertLe(usdc.balanceOf(alice), have);
        }

        assertLe(usdc.balanceOf(alice), amt);
    }

    /**********************************************************************************************/
    /*** 2. Instant-path jamming                                                                ***/
    /**********************************************************************************************/

    // With capacity exactly full, a 2-wei deposit leaves one spUSDC share queued. From then on
    // every deposit is queued, even after a redeem frees capacity.
    function test_jam_fullCapacityTwoWeiDepositBlocksInstantPath() public {
        _fillCapacityExactly(alice, 1_000_000e6);
        uint256 aliceShares = vault.balanceOf(alice);

        // Attacker: 2 wei USDC -> 1 spUSDC share (1 wei would round to 0 shares, see below).
        _fund(attacker, 2);
        vm.prank(attacker);
        uint256 jamId = vault.requestDeposit(2, attacker, 0);

        assertEq(jamId, 1);
        assertEq(vault.pendingDepositSavingsShares(), 1);
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(usdc.balanceOf(attacker), 0);

        // Alice redeems 10% and the planner pays her: capacity frees.
        _requestRedeem(alice, aliceShares / 10);
        _processRedeems(type(uint256).max, 1);
        assertGt(vault.availableCapacity(), 0);

        // Victim deposits 50_000 USDC: plenty of capacity, but queued behind the jam.
        uint256 victimId = _deposit(victim, 50_000e6);
        assertEq(victimId, 2);
        assertEq(vault.balanceOf(victim), 0);
        (, , uint256 victimQueued) = _depositRequest(victimId);
        assertEq(victimQueued, spUsdc.convertToShares(50_000e6));

        // Cost to the attacker: 2 wei USDC + gas. The attacker can also cancel and get 1 wei back
        // (once the planner settles the cancelled queue).
        _cancelDepositAndSettle(attacker, jamId);
        assertEq(usdc.balanceOf(attacker), 1);  // 1 spUSDC share -> floor(1.0476) = 1 wei

        // After the cancel pending == victim's shares != 0: the victim still needs the planner.
        assertEq(vault.pendingDepositSavingsShares(), victimQueued);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.balanceOf(victim), vault.convertToShares(spUsdc.convertToAssets(victimQueued)));
    }

    // The 1-share jam entry is closed by the first planner call that has capacity: the entry's
    // single spUSDC share converts to 1 USDC and then to 0 spPRIME shares (F-4), so it is
    // deducted and the queue moves on to the victim in the same call.
    function test_jam_clearedByOnePlannerCall() public {
        _fillCapacityExactly(alice, 1_000_000e6);

        _fund(attacker, 2);
        vm.prank(attacker);
        vault.requestDeposit(2, attacker, 0);

        _setCapacity(type(uint128).max);
        uint256 victimId = _deposit(victim, 50_000e6);
        (, , uint256 victimQueued) = _depositRequest(victimId);

        assertEq(spUsdc.convertToAssets(1), 1);
        assertEq(vault.convertToShares(1), 0);

        uint256 supplyBefore = vault.totalSupply();

        _processDeposits(type(uint256).max, 2);

        (, , uint256 jamLeft) = _depositRequest(1);
        assertEq(jamLeft, 0);                       // jam entry closed, 0 shares minted
        assertEq(vault.balanceOf(attacker), 0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(), 3);
        assertEq(
            vault.totalSupply() - supplyBefore,
            vault.convertToShares(spUsdc.convertToAssets(victimQueued))
        );
    }

    // 1 wei USDC converts to 0 spUSDC shares: the entry is a ghost, no jam, 1 wei lost.
    function test_jam_oneWeiDepositGivesZeroSavingsSharesNoJam() public {
        _fillCapacityExactly(alice, 1_000_000e6);

        _fund(attacker, 1);
        vm.prank(attacker);
        uint256 id = vault.requestDeposit(1, attacker, 0);

        (, , uint256 queued) = _depositRequest(id);
        assertEq(queued, 0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(usdc.balanceOf(address(spUsdc)), 1_000_000e6 + 1);  // donated to spUSDC

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.requestDepositCancellation(id, attacker);

        // Next depositor is still instant once capacity exists.
        _setCapacity(type(uint128).max);
        _deposit(victim, 10e6);
        assertGt(vault.balanceOf(victim), 0);
    }

    // Re-jamming once the queue is empty costs real capital: the attacker must fill the free
    // capacity (which then counts as their own locked shares) and only the overflow queues.
    function test_jam_rejamRequiresFillingFreeCapacity() public {
        _fillCapacityExactly(alice, 1_000_000e6);
        _setCapacity(vault.totalSupply() + 100_000e6 * RAY / vault.nowChi());  // ~100k free

        uint256 freeAssets = vault.convertToAssets(vault.availableCapacity());

        // Attacker wants a jam with capacity > 0. Anything <= freeAssets fills instantly.
        _deposit(attacker, freeAssets);
        assertLe(vault.availableCapacity(), 2);                         // rounding dust at most
        assertEq(vault.pendingDepositSavingsShares(), 0);               // no jam yet

        // A few more wei queue (dust capacity may absorb 1-2 shares): the jam is live, but the
        // attacker now has `freeAssets` locked as shares.
        _fund(attacker, 10);
        vm.prank(attacker);
        vault.requestDeposit(10, attacker, 0);
        assertGe(vault.pendingDepositSavingsShares(), 1);
        assertLe(vault.pendingDepositSavingsShares(), 9);
        assertApproxEqAbs(vault.assetsOf(attacker), freeAssets, 3);
    }

    // When availableCapacity() is 1 spPRIME share it converts to 0 spUSDC shares, so neither
    // the instant path nor the planner can process anything. Not a jam: capacity is full.
    function test_jam_capacityOneShareRemainderIsNotProcessable() public {
        _deposit(alice, 1_000_000e6);
        _setCapacity(vault.totalSupply() + 1);

        assertEq(vault.availableCapacity(), 1);
        assertEq(spUsdc.convertToShares(vault.convertToAssets(1)), 0);

        _fund(attacker, 2);
        vm.prank(attacker);
        vault.requestDeposit(2, attacker, 0);
        assertEq(vault.pendingDepositSavingsShares(), 1);

        _processDeposits(type(uint256).max, 10);
        assertEq(vault.pendingDepositSavingsShares(), 1);
        assertEq(vault.firstPendingDepositId(), 1);

        _setCapacity(vault.totalSupply() + 3);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(), 2);
    }

    /**********************************************************************************************/
    /*** 3. Escrow confusion                                                                    ***/
    /**********************************************************************************************/

    // Regression (round-1 A-5 / round-2 R2-2 "dead capacity"): `requestDeposit` :395 and
    // `updateDepositRecipient` :481 reject the vault as recipient, so phantom spPRIME in the
    // vault's own balance can no longer be created through the deposit path.
    function test_fixed_depositRecipientVaultRejected() public {
        _setCapacity(1_000_000e6);
        _fund(attacker, 100_000e6);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/vault-recipient");
        vault.requestDeposit(100_000e6, address(vault), 0);

        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(usdc.balanceOf(attacker), 100_000e6);        // nothing pulled

        // Queued entry repointed to the vault: rejected too.
        _fillCapacityExactly(alice, 1_000e6);
        vm.prank(attacker);
        uint256 id = vault.requestDeposit(100_000e6, attacker, 0);
        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/vault-recipient");
        vault.updateDepositRecipient(id, address(vault));
        (, address r, ) = _depositRequest(id);
        assertEq(r, attacker);
    }

    // V2-13 (open): requestRedeem(x, recipient = vault) passes the blacklist check (:452) and the
    // fill sends USDC to the vault (:952), where nothing can use it: `availableLiquidAssets` only
    // counts spUSDC, `take` moves spUSDC only, and `claimableAssets[vault]` is never credited
    // because the vault itself is not blacklisted (:951).
    function test_BUG_V2_13_redeemRecipientVaultStrandsUsdcInVault() public {
        _deposit(attacker, 100_000e6);
        uint256 shares = vault.balanceOf(attacker);

        vm.prank(attacker);
        vault.requestRedeem(shares, address(vault));

        uint256 liquidBefore = vault.availableLiquidAssets();
        _processRedeems(type(uint256).max, 1);

        uint256 expected = vault.convertToAssets(shares);
        assertEq(expected, 99_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), expected);
        assertEq(vault.claimableAssets(address(vault)), 0);  // no claim path either
        assertEq(usdc.balanceOf(attacker), 0);
        assertApproxEqAbs(vault.availableLiquidAssets(), liquidBefore - expected, 2);  // USDC not counted

        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(address(vault));

        // Not takeable either (take moves spUSDC only).
        uint256 sp = _vaultSpUsdc();
        vm.prank(taker);
        vault.take(sp);
        assertEq(usdc.balanceOf(address(vault)), expected);
    }

    // Every path that could park spPRIME in the vault outside the redeem escrow is closed
    // (:395, :481, :549, :557): `balanceOf(vault) == pendingRedeemShares` cannot be broken by a
    // user, and the redeem queue burns exactly its own entries.
    function test_fixed_noPhantomSharesOutsideEscrow() public {
        _deposit(attacker, 10_000e6);
        uint256 atk = vault.balanceOf(attacker);

        vm.startPrank(attacker);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transfer(address(vault), atk);
        vault.approve(attacker, atk);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transferFrom(attacker, address(vault), atk);
        vm.stopPrank();

        _deposit(alice, 50_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        _requestRedeem(alice, aliceShares);

        assertEq(vault.balanceOf(address(vault)), aliceShares);
        assertEq(vault.pendingRedeemShares(), aliceShares);

        _processRedeems(type(uint256).max, 10);

        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.totalSupply(), atk);
    }

    /**********************************************************************************************/
    /*** 4. spUSDC donations                                                                    ***/
    /**********************************************************************************************/

    function test_donation_spUsdcRaisesLiquidityAndIsTakeable() public {
        _deposit(alice, 100_000e6);
        uint256 vaultSp = _vaultSpUsdc();

        // Rando deposits into spUSDC directly and donates the shares to the vault.
        usdc.mint(rando, 50_000e6);
        vm.startPrank(rando);
        usdc.approve(address(spUsdc), 50_000e6);
        uint256 donated = spUsdc.deposit(50_000e6, rando);
        spUsdc.transfer(address(vault), donated);
        vm.stopPrank();

        assertEq(_vaultSpUsdc(), vaultSp + donated);
        assertEq(vault.availableLiquidAssets(), spUsdc.convertToAssets(vaultSp + donated));
        assertEq(vault.totalSupply(), vault.balanceOf(alice));       // no shares minted
        assertEq(vault.pendingDepositSavingsShares(), 0);

        // The planner can pay redeems from it and the taker can take it.
        _take(donated);
        assertEq(_vaultSpUsdc(), vaultSp);
        assertEq(spUsdc.balanceOf(taker), donated);
    }

    // Donation does not touch deposit-queue accounting; the "over-backing" is simply
    // balanceOf(vault) - pendingDepositSavingsShares.
    function test_donation_doesNotAffectDepositQueueAccounting() public {
        _fillCapacityExactly(alice, 100_000e6);
        uint256 id = _deposit(bob, 10_000e6);
        (, , uint256 queued) = _depositRequest(id);

        uint256 vaultSp = _vaultSpUsdc();
        assertEq(vault.pendingDepositSavingsShares(), queued);

        usdc.mint(rando, 5_000e6);
        vm.startPrank(rando);
        usdc.approve(address(spUsdc), 5_000e6);
        uint256 donated = spUsdc.deposit(5_000e6, rando);
        spUsdc.transfer(address(vault), donated);
        vm.stopPrank();

        assertEq(vault.pendingDepositSavingsShares(), queued);
        assertEq(_vaultSpUsdc() - vault.pendingDepositSavingsShares(), vaultSp - queued + donated);

        // Bob's fill is unaffected by the donation (minted from his own queued shares only).
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(bob), vault.convertToShares(spUsdc.convertToAssets(queued)));
        assertEq(_vaultSpUsdc(), vaultSp + donated);
    }

    /**********************************************************************************************/
    /*** 5. Capacity races                                                                      ***/
    /**********************************************************************************************/

    function test_race_firstComeWins_loserQueuedEvenAfterRedeemFreesCapacity() public {
        _setCapacity(1_000_000e6);

        // Alice and bob race for the last capacity: alice's tx lands first.
        _deposit(alice, 999_000e6);
        uint256 bobId = _deposit(bob, 100_000e6);

        uint256 aliceShares = vault.balanceOf(alice);
        assertEq(aliceShares, vault.convertToShares(spUsdc.convertToAssets(spUsdc.convertToShares(999_000e6))));
        (, , uint256 bobQueued) = _depositRequest(bobId);
        assertGt(bobQueued, 0);
        assertGt(vault.balanceOf(bob), 0);       // partial instant fill of the ~10.8k USDC left
        assertLe(vault.availableCapacity(), 2);

        // Alice redeems half in the same block, planner pays: capacity frees.
        _requestRedeem(alice, aliceShares / 2);
        _processRedeems(type(uint256).max, 1);
        assertGt(vault.convertToAssets(vault.availableCapacity()), 400_000e6);

        // Bob is still queued: the instant path only runs on new requests with an empty queue.
        (, , uint256 bobStill) = _depositRequest(bobId);
        assertEq(bobStill, bobQueued);

        // And a brand-new depositor (carol) is queued behind bob too.
        uint256 caroId = _deposit(rando, 1e6);
        (, , uint256 caroQueued) = _depositRequest(caroId);
        assertEq(caroQueued, spUsdc.convertToShares(1e6));

        _processDeposits(type(uint256).max, 10);
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    function test_race_capacityLoweredBelowSupplyWhileQueueOpen() public {
        _fillCapacityExactly(alice, 1_000_000e6);
        uint256 bobId = _deposit(bob, 10_000e6);

        _setCapacity(100e6);  // far below totalSupply
        assertEq(vault.availableCapacity(), 0);

        // Nothing breaks: processing is a no-op, cancel works, redeems work.
        _processDeposits(type(uint256).max, 10);
        (, , uint256 bobQueued) = _depositRequest(bobId);
        assertEq(bobQueued, spUsdc.convertToShares(10_000e6));

        _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems(type(uint256).max, 1);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.availableCapacity(), 100e6);

        _cancelDepositAndSettle(bob, bobId);
        assertApproxEqAbs(usdc.balanceOf(bob), 10_000e6, 2);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // Attacker sees victim's deposit in the mempool and front-runs it by filling capacity:
    // victim loses instant access. Cost: capital equal to the free capacity, no fee at 0%.
    function test_race_frontRunJamQueuesVictim() public {
        _deposit(alice, 900_000e6);
        _setCapacity(vault.totalSupply() + vault.convertToShares(100_000e6));

        uint256 free = vault.convertToAssets(vault.availableCapacity());

        _deposit(attacker, free + 2);
        assertGe(vault.pendingDepositSavingsShares(), 1);   // >= 1 spUSDC share left queued
        assertLe(vault.pendingDepositSavingsShares(), 3);

        uint256 victimId = _deposit(victim, 50_000e6);
        assertEq(vault.balanceOf(victim), 0);
        (, , uint256 q) = _depositRequest(victimId);
        assertEq(q, spUsdc.convertToShares(50_000e6));

        // Attacker exits via the queue at fee 0: no cost beyond gas and time.
        _requestRedeem(attacker, vault.balanceOf(attacker));
        _processRedeems(type(uint256).max, 1);
        assertApproxEqAbs(usdc.balanceOf(attacker), free, 4);
    }

    /**********************************************************************************************/
    /*** 6. Permit and allowance                                                                ***/
    /**********************************************************************************************/

    function test_permit_validSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(signer, bob, 123e18, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        assertEq(vault.allowance(signer, bob), 0);
        assertEq(vault.nonces(signer), 0);

        vm.expectEmit(address(vault));
        emit Approval(signer, bob, 123e18);
        vm.prank(rando);
        vault.permit(signer, bob, 123e18, deadline, v, r, s);

        assertEq(vault.allowance(signer, bob), 123e18);
        assertEq(vault.nonces(signer), 1);
    }

    function test_permit_replayRejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(signer, bob, 1, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        vault.permit(signer, bob, 1, deadline, v, r, s);

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(signer, bob, 1, deadline, v, r, s);

        assertEq(vault.nonces(signer), 1);  // failed attempt did not consume a nonce
    }

    function test_permit_expiredRejected() public {
        uint256 deadline = block.timestamp - 1;
        bytes32 digest = _permitDigest(signer, bob, 1, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        vm.expectRevert("SparkPrimeVault/permit-expired");
        vault.permit(signer, bob, 1, deadline, v, r, s);

        // Boundary: deadline == now is accepted.
        deadline = block.timestamp;
        digest = _permitDigest(signer, bob, 1, 0, deadline);
        (v, r, s) = vm.sign(signerPk, digest);
        vault.permit(signer, bob, 1, deadline, v, r, s);
        assertEq(vault.allowance(signer, bob), 1);
    }

    function test_permit_wrongSignerRejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(signer, bob, 1, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, digest);

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(signer, bob, 1, deadline, v, r, s);

        // Signed for a different spender / value / nonce: all rejected.
        (v, r, s) = vm.sign(signerPk, _permitDigest(signer, alice, 1, 0, deadline));
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(signer, bob, 1, deadline, v, r, s);

        (v, r, s) = vm.sign(signerPk, _permitDigest(signer, bob, 2, 0, deadline));
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(signer, bob, 1, deadline, v, r, s);

        (v, r, s) = vm.sign(signerPk, _permitDigest(signer, bob, 1, 1, deadline));
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(signer, bob, 1, deadline, v, r, s);

        vm.expectRevert("SparkPrimeVault/invalid-owner");
        vault.permit(address(0), bob, 1, deadline, v, r, s);
    }

    function test_permit_erc1271Accepted() public {
        Erc1271Accepter wallet = new Erc1271Accepter();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(address(wallet), bob, 5e18, 0, deadline);
        bytes memory sig = hex"deadbeef";  // not 65 bytes: skips ecrecover, goes to ERC-1271
        wallet.set(digest, sig);

        vault.permit(address(wallet), bob, 5e18, deadline, sig);
        assertEq(vault.allowance(address(wallet), bob), 5e18);
        assertEq(vault.nonces(address(wallet)), 1);

        // Same signature again: nonce moved, digest differs, wallet rejects.
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(address(wallet), bob, 5e18, deadline, sig);
    }

    function test_permit_erc1271Rejected() public {
        Erc1271Accepter wallet = new Erc1271Accepter();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(address(wallet), bob, 5e18, 0, deadline);
        wallet.set(digest, hex"01");

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(address(wallet), bob, 5e18, deadline, hex"02");

        // 65-byte garbage for a contract owner: ecrecover mismatch, then ERC-1271 rejects.
        bytes memory sig65 = new bytes(65);
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(address(wallet), bob, 5e18, deadline, sig65);

        // Malformed 64-byte return is rejected.
        Erc1271Malformed bad = new Erc1271Malformed();
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(address(bad), bob, 5e18, deadline, hex"01");

        // EOA with non-65-byte signature: no code, rejected.
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(signer, bob, 5e18, deadline, hex"01");
    }

    function test_transferFrom_maxAllowanceNotDecremented() public {
        _deposit(alice, 100e6);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        vm.prank(bob);
        vault.transferFrom(alice, rando, shares);

        assertEq(vault.allowance(alice, bob), type(uint256).max);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(rando), shares);
    }

    function test_transferFrom_finiteAllowanceDecrements() public {
        _deposit(alice, 100e6);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.approve(bob, shares + 7);

        vm.prank(bob);
        vault.transferFrom(alice, rando, shares);

        assertEq(vault.allowance(alice, bob), 7);
        assertEq(vault.balanceOf(rando), shares);
    }

    function test_transferFrom_insufficientAllowanceReverts() public {
        _deposit(alice, 100e6);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.approve(bob, shares - 1);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-allowance");
        vault.transferFrom(alice, rando, shares);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.transferFrom(alice, rando, shares + 1);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transferFrom(alice, address(0), 1);

        // Self transferFrom needs no allowance.
        vm.prank(alice);
        vault.transferFrom(alice, rando, shares);
        assertEq(vault.balanceOf(rando), shares);
    }

    // Standard ERC20 approve race (info only): a spender can front-run an allowance change.
    function test_approve_raceStandard() public {
        _deposit(alice, 100e6);
        vm.prank(alice);
        vault.approve(bob, 60);
        vm.prank(bob);
        vault.transferFrom(alice, bob, 60);      // front-runs alice's change
        vm.prank(alice);
        vault.approve(bob, 40);
        vm.prank(bob);
        vault.transferFrom(alice, bob, 40);
        assertEq(vault.balanceOf(bob), 100);     // bob spent 60 + 40 although alice meant 40
    }

    /**********************************************************************************************/
    /*** 7. Extremes                                                                            ***/
    /**********************************************************************************************/

    function test_extremes_maxCapacityDepositAndRedeem() public {
        uint256 amt = type(uint128).max;
        _deposit(alice, amt);

        uint256 shares = vault.balanceOf(alice);
        assertEq(shares, vault.convertToShares(spUsdc.convertToAssets(spUsdc.convertToShares(amt))));
        assertLe(shares, type(uint128).max);
        assertEq(vault.totalAssets(), vault.convertToAssets(shares));

        _setRedeemFeeRate(0.01e18);
        uint256 fee = (shares * 0.01e18 - 1) / WAD + 1;
        _requestRedeem(alice, shares);
        assertEq(vault.pendingRedeemShares(), shares - fee);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), vault.convertToAssets(shares - fee));
        assertLe(usdc.balanceOf(alice), amt);
    }

    // 10 years at MAX_VSR: chi grows 2^10, nothing overflows, uint192 holds it.
    function test_extremes_chiAfterTenYearsAtMaxVsr() public {
        _deposit(alice, type(uint128).max);
        uint256 chi0 = vault.nowChi();

        _setPrimeVsr(MAX_VSR);
        _warp(10 * 365 days);
        uint256 chi = vault.drip();

        assertApproxEqRel(chi, chi0 * 1024, 1e9);  // 1e-9 relative (rpow rounding)
        assertEq(vault.totalAssets(), vault.totalSupply() * chi / RAY);

        _requestRedeem(alice, vault.balanceOf(alice));   // shares * chi fits
    }

    // drip() reverts (checked mul of totalSupply * nChi) once totalSupply * chi >= 2^256.
    // With totalSupply ~ uint128.max that is chi ~ 3.4e38 = 2^38.3 growth = 38 years at 100% APY.
    // Any user-level multiplication (shares * chi) is bounded by the same product, so drip is
    // always the first thing to overflow. Realistic supplies (< 1e15 shares) can never reach it.
    function test_extremes_dripOverflowBoundAtMaxSupply() public {
        _deposit(alice, type(uint128).max);
        uint256 supply = vault.totalSupply();

        _setPrimeVsr(MAX_VSR);
        _warp(38 * 365 days);
        uint256 chi = vault.drip();
        assertLt(supply * chi, type(uint256).max);   // fits
        assertEq(vault.totalAssets(), supply * chi / RAY);

        _warp(365 days);
        uint256 nChi = vault.nowChi();                // view: only rpow * chi, no supply product
        assertGt(nChi, type(uint256).max / supply);   // supply * nChi overflows

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Panic(uint256)")), 0x11));
        vault.drip();

        // Every entry point drips first, so the vault is bricked (setVSR included).
        vm.prank(vsrSetter);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Panic(uint256)")), 0x11));
        vault.setVSR(RAY);
    }

    // chi is capped by the checked product _rpow(vsr, dt) * chi < 2^256, i.e. chi < 1.16e50,
    // which is 2^76.6 growth: 76 years at 100% APY in total, however the drips are split.
    function test_extremes_chiLimit_76YearsAtMaxVsrOk() public {
        _deposit(alice, 1e6);
        _setPrimeVsr(MAX_VSR);
        _warp(40 * 365 days);
        vault.drip();
        _warp(36 * 365 days);
        uint256 chi = vault.drip();
        assertGt(chi, 7e49);
        assertLt(chi, type(uint256).max / RAY);
        assertGt(vault.assetsOf(alice), 0);
    }

    function test_extremes_chiLimit_77YearsAtMaxVsrReverts() public {
        _deposit(alice, 1e6);
        _setPrimeVsr(MAX_VSR);
        _warp(40 * 365 days);
        vault.drip();
        _warp(37 * 365 days);
        vm.expectRevert();
        vault.nowChi();
        vm.expectRevert();
        vault.drip();
    }

    // uint192 truncation of chi is unreachable: nChi < 2^256 / RAY ~ 1.16e50 < uint192.max.
    function test_extremes_chiCannotExceedUint192() public pure {
        assertLt(type(uint256).max / 1e27, type(uint192).max);
    }

    function test_extremes_feeMultiplicationCannotOverflow() public pure {
        // shares <= uint128.max (capacity), fee <= MAX_REDEEM_FEE.
        uint256 product = uint256(type(uint128).max) * 0.01e18;
        assertLt(product, type(uint256).max);
        assertEq((product - 1) / 1e18 + 1, 3402823669209384634633746074317682115);  // 1% of uint128.max
    }

    /**********************************************************************************************/
    /*** 8. Planner griefing with ghost entries                                                 ***/
    /**********************************************************************************************/

    // Ghost deposit entries created while pending == 0 are skipped immediately by the instant
    // path, so they never sit in front of anyone.
    function test_griefing_ghostDepositsWhileQueueEmptyAreSkippedInstantly() public {
        vm.startPrank(attacker);
        for (uint256 i; i < 50; ++i) vault.requestDeposit(0, attacker, 0);
        vm.stopPrank();

        assertEq(vault.firstPendingDepositId(), 50);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        _deposit(victim, 1e6);
        assertGt(vault.balanceOf(victim), 0);  // instant
        assertEq(vault.firstPendingDepositId(), 51);
    }

    // Ghosts can only be placed in front of a request while the queue is open. Measures the
    // planner's gas per skipped ghost and shows the head advances across multiple calls.
    function test_griefing_ghostDepositEntriesGasPerSkip() public {
        _fillCapacityExactly(alice, 1_000_000e6);
        _deposit(bob, 1e6);  // opens the queue: pending != 0

        vm.startPrank(attacker);
        uint256 g0 = gasleft();
        vault.requestDeposit(0, attacker, 0);
        uint256 ghostCost = g0 - gasleft();
        for (uint256 i; i < 1999; ++i) vault.requestDeposit(0, attacker, 0);
        vm.stopPrank();

        uint256 victimId = _deposit(victim, 5e6);
        assertEq(victimId, 2002);

        _setCapacity(type(uint128).max);

        // Call 1: bob (1 request) + 1000 ghosts.
        vm.prank(rebalancer);
        uint256 g1 = gasleft();
        vault.processPendingDeposits(type(uint256).max, 1001);
        uint256 gas1 = g1 - gasleft();
        assertEq(vault.firstPendingDepositId(), 1002);

        // Call 2: 1000 ghosts only.
        vm.prank(rebalancer);
        uint256 g2 = gasleft();
        vault.processPendingDeposits(type(uint256).max, 1000);
        uint256 gas2 = g2 - gasleft();
        assertEq(vault.firstPendingDepositId(), 2002);
        assertEq(vault.balanceOf(victim), 0);

        // Call 3: victim.
        _processDeposits(type(uint256).max, 1);
        assertGt(vault.balanceOf(victim), 0);
        assertEq(vault.firstPendingDepositId(), 2003);

        // NOTE: slots are warm inside one test tx; on mainnet each skip is a cold SLOAD, add ~2_000.
        uint256 perGhost = gas2 / 1000;
        emit log_named_uint("gas per requestDeposit(0) ghost (attacker)", ghostCost);
        emit log_named_uint("planner gas, 1 fill + 1000 ghost skips", gas1);
        emit log_named_uint("planner gas, 1000 ghost skips", gas2);
        emit log_named_uint("planner gas per ghost skip", perGhost);
        emit log_named_uint("ghosts per 30M block", 30_000_000 / perGhost);

        assertLt(perGhost, 3_000);
        assertGt(30_000_000 / perGhost, 10_000);
    }

    function test_griefing_ghostRedeemEntriesGasPerSkip() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(attacker, 1e6);
        _deposit(alice, 100e6);

        vm.startPrank(attacker);
        uint256 g0 = gasleft();
        vault.requestRedeem(1, attacker);           // fee = divup(1 * 1%, 1) = 1 -> 0 queued
        uint256 ghostCost = g0 - gasleft();
        for (uint256 i; i < 1999; ++i) vault.requestRedeem(1, attacker);
        vm.stopPrank();

        (, , uint256 q) = _redeemRequest(0);
        assertEq(q, 0);
        assertEq(vault.pendingRedeemShares(), 0);

        uint256 aliceShares = vault.balanceOf(alice);
        _requestRedeem(alice, aliceShares);
        assertEq(_redeemQueueLength(), 2001);

        vm.prank(rebalancer);
        uint256 g1 = gasleft();
        vault.processPendingRedeems(type(uint256).max, 1000);
        uint256 gas1 = g1 - gasleft();
        assertEq(vault.firstPendingRedeemId(), 1000);
        assertEq(usdc.balanceOf(alice), 0);

        vm.prank(rebalancer);
        vault.processPendingRedeems(type(uint256).max, 1001);
        assertEq(vault.firstPendingRedeemId(), 2001);
        assertGt(usdc.balanceOf(alice), 0);

        uint256 perGhost = gas1 / 1000;
        emit log_named_uint("gas per requestRedeem(1) ghost (attacker)", ghostCost);
        emit log_named_uint("planner gas per ghost skip", perGhost);
        emit log_named_uint("ghosts per 30M block", 30_000_000 / perGhost);
        assertLt(perGhost, 3_000);
    }

    // With fee 0, 1-wei redeem entries are real: each costs the planner a full fill.
    function test_griefing_oneWeiRedeemFillsGas() public {
        _deposit(attacker, 1e6);
        _deposit(alice, 100e6);

        vm.startPrank(attacker);
        for (uint256 i; i < 200; ++i) vault.requestRedeem(1, attacker);
        vm.stopPrank();
        assertEq(vault.pendingRedeemShares(), 200);

        uint256 vaultSp = _vaultSpUsdc();

        vm.prank(rebalancer);
        uint256 g = gasleft();
        vault.processPendingRedeems(type(uint256).max, 200);
        uint256 gas = g - gasleft();

        assertEq(vault.firstPendingRedeemId(), 200);
        assertEq(usdc.balanceOf(attacker), 200);           // 1 wei USDC per 1-share entry
        assertEq(vaultSp - _vaultSpUsdc(), 200);           // 1 spUSDC share burned per fill (R9)

        uint256 perFill = gas / 200;
        emit log_named_uint("planner gas per 1-wei fill", perFill);
        emit log_named_uint("1-wei fills per 30M block", 30_000_000 / perFill);
        assertLt(perFill, 80_000);
    }

    // minDeposit (assets) and minRedeem (shares, since the refactor) block both ghost types,
    // including the new free requestRedeem(0) ghost.
    function test_griefing_ghostsBlockedByMinimums() public {
        _setMinDeposit(1e6);
        _setMinRedeem(1e6);
        _setRedeemFeeRate(0.01e18);
        _deposit(attacker, 10e6);

        vm.startPrank(attacker);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(0, attacker, 0);

        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(1e6 - 1, attacker, 0);

        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(0, attacker);

        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(1e6 - 1, attacker);

        // Smallest allowed redeem: queued shares are non-zero (fee cannot eat the whole thing).
        uint256 id = vault.requestRedeem(1e6, attacker);
        vm.stopPrank();
        (, , uint256 q) = _redeemRequest(id);
        assertEq(q, 1e6 - 1e4);
    }

    // requestRedeem(0) is accepted since the refactor: a ghost that needs no shares and pays no
    // fee. Measures its cost and the planner's cost to skip it.
    function test_griefing_zeroRedeemGhostsAreFree() public {
        _deposit(alice, 100e6);

        vm.startPrank(attacker);                     // attacker holds no shares at all
        uint256 g0 = gasleft();
        vault.requestRedeem(0, attacker);
        uint256 ghostCost = g0 - gasleft();
        for (uint256 i; i < 999; ++i) vault.requestRedeem(0, attacker);
        vm.stopPrank();

        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.balanceOf(attacker), 0);

        _requestRedeem(alice, vault.balanceOf(alice));

        vm.prank(rebalancer);
        uint256 g1 = gasleft();
        vault.processPendingRedeems(type(uint256).max, 1000);
        uint256 gas1 = g1 - gasleft();
        assertEq(vault.firstPendingRedeemId(), 1000);
        assertEq(usdc.balanceOf(alice), 0);

        _processRedeems(type(uint256).max, 1);
        assertGt(usdc.balanceOf(alice), 0);

        emit log_named_uint("gas per requestRedeem(0) ghost (attacker, no shares)", ghostCost);
        emit log_named_uint("planner gas per ghost skip", gas1 / 1000);
        assertLt(ghostCost, 100_000);
        assertLt(gas1 / 1000, 3_000);

        // A ghost is permanent: there is no cancel at all now, and the only owner action on a
        // redeem entry (`updateRedeemRecipient`) rejects the 0-share slot.
        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateRedeemRecipient(0, attacker);
    }

    // Without capacity (deposits) or liquidity (redeems) the head cannot move past ghosts,
    // but then nothing could be processed anyway.
    function test_griefing_headDoesNotAdvanceWithoutCapacityOrLiquidity() public {
        _fillCapacityExactly(alice, 1_000e6);
        _deposit(bob, 1e6);
        vm.startPrank(attacker);
        for (uint256 i; i < 10; ++i) vault.requestDeposit(0, attacker, 0);
        vm.stopPrank();

        _processDeposits(type(uint256).max, 100);
        assertEq(vault.firstPendingDepositId(), 1);

        _setRedeemFeeRate(0.01e18);
        _requestRedeem(alice, vault.balanceOf(alice) / 2);
        vm.startPrank(alice);
        for (uint256 i; i < 10; ++i) vault.requestRedeem(1, alice);
        vm.stopPrank();

        _drainAllSpUsdcLiquidity();
        _processRedeems(type(uint256).max, 100);
        assertEq(vault.firstPendingRedeemId(), 0);

        _returnSpUsdcLiquidity(1_000e6);
        _processRedeems(type(uint256).max, 100);
        assertEq(vault.firstPendingRedeemId(), 11);
    }

    /**********************************************************************************************/
    /*** 9. Role mistakes                                                                       ***/
    /**********************************************************************************************/

    function test_take_notTaker() public {
        _deposit(alice, 1e6);
        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", rebalancer, TAKER_ROLE
        ));
        vault.take(1);
    }

    function test_take_moreThanBalance() public {
        _deposit(alice, 1e6);
        uint256 bal = _vaultSpUsdc();
        vm.prank(taker);
        vm.expectRevert("SparkPrimeVault/insufficient-shares");
        vault.take(bal + 1);
        vm.prank(taker);
        vault.take(bal);
        assertEq(_vaultSpUsdc(), 0);
    }

    function test_adjustTotalAssets_notPaused() public {
        _deposit(alice, 1e6);
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/not-paused");
        vault.adjustTotalAssets(-1);
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/not-paused");
        vault.adjustTotalAssets(1);
    }

    // pause() is GUARDIAN_ROLE (restored upstream); a hot-wallet role cannot pause or unpause.
    function test_pause_hotWalletRolesCannot() public {
        address[3] memory who = [rebalancer, redeemFeeSetter, vsrSetter];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", who[i], GUARDIAN_ROLE
            ));
            vault.pause();
        }
        _pause();
        assertTrue(vault.paused());
    }

    function test_unpause_guardianCannot() public {
        _pause();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", guardian, DEFAULT_ADMIN_ROLE
        ));
        vault.unpause();

        // UNPAUSER_ROLE is gone at 0ebb452: no hot-wallet role can unpause.
        address[3] memory who = [rebalancer, redeemFeeSetter, vsrSetter];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", who[i], DEFAULT_ADMIN_ROLE
            ));
            vault.unpause();
        }

        _unpause();
        assertFalse(vault.paused());
    }

    function test_upgradeToAndCall_notAdmin() public {
        address impl = address(new SparkPrimeVault());
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", guardian, DEFAULT_ADMIN_ROLE
        ));
        vault.upgradeToAndCall(impl, "");

        vm.prank(admin);
        vault.upgradeToAndCall(impl, "");
        assertEq(vault.implementation(), impl);
    }

    function test_hotWalletRoles_cannotEscalate() public {
        bytes32[3] memory roles = [REBALANCER_ROLE, REDEEM_FEE_SETTER_ROLE, VSR_SETTER_ROLE];
        address[3] memory who   = [rebalancer, redeemFeeSetter, vsrSetter];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", who[i], DEFAULT_ADMIN_ROLE
            ));
            vault.grantRole(roles[i], attacker);
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", who[i], DEFAULT_ADMIN_ROLE
            ));
            vault.setCapacity(1);
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", who[i], DEFAULT_ADMIN_ROLE
            ));
            vault.setVSRBounds(RAY, RAY);
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", who[i], DEFAULT_ADMIN_ROLE
            ));
            vault.setMaxRedeemFeeRate(0);
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", who[i], TAKER_ROLE
            ));
            vault.take(0);
            vm.stopPrank();
        }
    }

    /**********************************************************************************************/
    /*** 10. Reentrancy                                                                         ***/
    /**********************************************************************************************/

    // No fill, cancel or request ever calls the recipient: USDC and spUSDC have no hooks.
    function test_reentrancy_noCallbackToRecipient() public {
        CallbackRecorder rec = new CallbackRecorder();

        _fund(alice, 300e6);
        vm.startPrank(alice);
        vault.requestDeposit(100e6, address(rec), 0);          // instant mint to contract
        vault.requestDeposit(100e6, alice, 0);
        vault.requestRedeem(vault.balanceOf(alice), address(rec));
        vm.stopPrank();
        assertEq(rec.calls(), 0);

        _processRedeems(type(uint256).max, 10);
        assertEq(rec.calls(), 0);
        assertGt(usdc.balanceOf(address(rec)), 0);

        _fillCapacityExactly(bob, 1e6);
        vm.startPrank(alice);
        uint256 id = vault.requestDeposit(100e6, address(rec), 0);   // queued
        vault.requestDepositCancellation(id, address(rec));             // moved to the cancel queue
        vm.stopPrank();
        assertEq(rec.calls(), 0);

        uint256 before = usdc.balanceOf(address(rec));
        _processCancelledDeposits(type(uint256).max, 10);        // spUSDC.redeem to rec
        assertEq(rec.calls(), 0);
        assertGt(usdc.balanceOf(address(rec)), before);
    }

    // An ERC-1271 signer is reached by staticcall: any state write makes the check fail.
    function test_reentrancy_erc1271SignerCannotMutateState() public {
        Erc1271Reentrant wallet = new Erc1271Reentrant(vault);
        uint256 deadline = block.timestamp + 1 hours;

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(address(wallet), bob, 1, deadline, hex"01");

        assertEq(vault.allowance(address(wallet), address(0xBEEF)), 0);
        assertEq(vault.nonces(address(wallet)), 0);
    }

    /**********************************************************************************************/
    /*** 11. Compromised hot-wallet roles                                                       ***/
    /**********************************************************************************************/

    // SETTER at the admin bound MAX_VSR (100% APY): over-crediting per day on 1M USDC, versus a
    // 10% bound.
    function test_compromised_setter_maxVsrOverCreditsPerDay() public {
        _deposit(alice, 1_000_000e6);
        uint256 a0 = vault.assetsOf(alice);

        vm.prank(vsrSetter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVSR(MAX_VSR + 1);

        _setPrimeVsr(MAX_VSR);
        _warpAndDrip(1 days);
        uint256 perDayAt100 = vault.assetsOf(alice) - a0;

        _warpAndDrip(29 days);
        uint256 perMonthAt100 = vault.assetsOf(alice) - a0;

        emit log_named_uint("over-credit per day at MAX_VSR on 1M", perDayAt100);
        emit log_named_uint("over-credit per 30 days at MAX_VSR on 1M", perMonthAt100);

        // 2^(1/365) - 1 = 0.19008% per day; 2^(30/365) - 1 = 5.8625% per 30 days.
        assertEq(perDayAt100,   1_900_837_678);   // 1_900.84 USDC per day
        assertEq(perMonthAt100, 58_625_111_031);  // 58_625.11 USDC per 30 days

        // Realistic admin bound 10% APY on a fresh 1M (bob): 0.02612% per day.
        vm.prank(admin);
        vault.setVSRBounds(RAY, TEN_PCT_VSR);
        vm.prank(vsrSetter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVSR(FORTY_PCT_VSR);
        _setPrimeVsr(TEN_PCT_VSR);
        _deposit(bob, 1_000_000e6);
        uint256 b0 = vault.assetsOf(bob);
        _warpAndDrip(1 days);
        uint256 perDayAt10 = vault.assetsOf(bob) - b0;
        emit log_named_uint("over-credit per day at 10% on 1M", perDayAt10);
        assertEq(perDayAt10, 261_157_876);        // 261.16 USDC per day
        assertEq(perDayAt100 / perDayAt10, 7);    // 7.28x
    }

    // The over-credit becomes real when the honest planner pays a redeem: payout is clamped to
    // the spUSDC the vault holds, the vault is drained and the rest of the request is unpayable.
    function test_compromised_setter_overCreditRealisedOnRedeem() public {
        _deposit(alice, 1_000_000e6);
        uint256 backing = spUsdc.convertToAssets(_vaultSpUsdc());

        _setPrimeVsr(MAX_VSR);
        _warpAndDrip(7 days);

        uint256 owed = vault.assetsOf(alice);
        emit log_named_uint("owed after 7 days at MAX_VSR", owed);
        assertGt(owed, 1_013_000e6);                        // ~1.337% in a week

        _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems(type(uint256).max, 1);

        uint256 paid = usdc.balanceOf(alice);
        assertLe(paid, backing);
        assertGe(paid, backing - 2);
        assertLe(_vaultSpUsdc(), 1);                        // vault drained to dust

        uint256 shortfall = vault.convertToAssets(vault.pendingRedeemShares());
        emit log_named_uint("unpayable remainder", shortfall);
        assertGt(shortfall, 13_000e6);
        assertApproxEqAbs(shortfall, owed - paid, 2);
    }

    // REDEEM_FEE_SETTER: fee bounded by maxRedeemFeeRate (admin). Worst case every exit loses 1%.
    function test_compromised_redeemFeeSetter_maxFeeOnEveryExit() public {
        vm.prank(redeemFeeSetter);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFeeRate(0.01e18 + 1);

        _setRedeemFeeRate(0.01e18);

        _deposit(alice, 1_000_000e6);
        uint256 shares = vault.balanceOf(alice);
        _requestRedeem(alice, shares);
        uint256 fee = (shares * 0.01e18 - 1) / WAD + 1;
        assertEq(vault.totalSupply(), shares - fee);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), vault.convertToAssets(shares - fee));
        assertLt(usdc.balanceOf(alice), 990_001e6);
        assertGt(usdc.balanceOf(alice), 989_999e6);

        // Admin can cap it harder: setMaxRedeemFeeRate(0) then the setter cannot charge anything.
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0);
        vm.prank(redeemFeeSetter);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFeeRate(1);
        // C-7: the live fee is NOT clamped by lowering the max.
        assertEq(vault.redeemFeeRate(), 0.01e18);
    }

    // C-3 (open): `adjustTotalAssets` :278-295 has no loss floor below `totalAssets_ > 0` (:286).
    // `delta = -(totalAssets - 1)` wipes every holder in one call; only the exact full loss (and
    // worse) is rejected with `loss-too-high`, and `delta == 0` with `delta-total-assets-zero`.
    function test_BUG_C3_adjustTotalAssets_nearFullLossWipesHolders() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply = vault.totalSupply();
        assertGt(vault.assetsOf(alice), 999_999e6);

        _pause();

        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/delta-total-assets-zero");
        vault.adjustTotalAssets(0);

        int256 ta = int256(vault.totalAssets());
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/loss-too-high");
        vault.adjustTotalAssets(-ta);
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/loss-too-high");
        vault.adjustTotalAssets(-ta - 1);

        _adjustTotalAssets(-(ta - 1));

        // chi = (totalAssets + delta) * RAY / totalSupply = 1 * RAY / totalSupply (:289).
        assertEq(vault.chi(), RAY / supply);
        assertEq(vault.assetsOf(alice), 0);
        assertEq(vault.totalAssets(), 0);

        // VSR cannot restore it: accrual from dust takes forever. Only a positive adjustment can.
        _unpause();
        _setPrimeVsr(MAX_VSR);
        _warpAndDrip(10 * 365 days);
        assertLt(vault.assetsOf(alice), 2_000);                // ~1_023 wei after a decade at 100%

        // Backing is untouched: all spUSDC is now vault equity, takeable.
        assertApproxEqAbs(spUsdc.convertToAssets(_vaultSpUsdc()), 1_000_000e6, 1);
    }

    // After the near-wipe the vault keeps working (no panics anywhere): redeems process (paying
    // 0), deposits fill at the dust chi, a further loss works again once totalAssets > 0, and the
    // backing stays takeable.
    function test_adjustTotalAssets_nearWipeStillOperates() public {
        _deposit(alice, 1_000_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        _pause();

        int256 ta = int256(vault.totalAssets());
        _adjustTotalAssets(-(ta - 1));                         // the worst reachable state
        assertGt(vault.chi(), 0);
        assertEq(vault.totalAssets(), 0);
        _unpause();

        // Conversions do not panic; the redeem queue still processes and pays alice 0.
        assertEq(vault.convertToShares(1), 1 * RAY / vault.chi());
        _requestRedeem(alice, aliceShares);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.totalSupply(), 0);

        // The backing is all vault equity now; the next depositor is minted at the dust chi,
        // i.e. an enormous number of shares, still fillable because capacity is uint128.max.
        _setCapacity(type(uint128).max);
        _deposit(bob, 1e6);
        assertGt(vault.balanceOf(bob), 0);
        assertApproxEqAbs(vault.assetsOf(bob), 1e6, 2);

        // With totalSupply > 0 and totalAssets > 0 again, a further loss works; full loss still not.
        _pause();
        int256 ta2 = int256(vault.totalAssets());
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/loss-too-high");
        vault.adjustTotalAssets(-ta2);
        _adjustTotalAssets(-1);
        _unpause();

        _takeAll();                                           // the backing is still takeable
        assertEq(_vaultSpUsdc(), 0);
    }

    // Bounds are checks except one: `totalAssets_ > 0` is `loss-too-high` (:286) in every loss
    // case including totalSupply == 0 (totalAssets 0, so -1 fails first), but a GAIN at
    // totalSupply == 0 reaches `/ totalSupply` (:289) and panics with division by zero.
    function test_adjustTotalAssets_boundsAreChecks_gainAtZeroSupplyPanics() public {
        _pause();
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/loss-too-high");
        vault.adjustTotalAssets(-1);                          // totalSupply == 0, totalAssets 0
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Panic(uint256)")), 0x12));
        vault.adjustTotalAssets(1);                           // division by zero
        _unpause();

        _deposit(alice, 1_000_000e6);
        _pause();
        int256 ta = int256(vault.totalAssets());
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/loss-too-high");
        vault.adjustTotalAssets(-ta - 1);
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/loss-too-high");
        vault.adjustTotalAssets(-ta);
        _adjustTotalAssets(-(ta - 1));
        assertEq(vault.totalAssets(), 0);
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/loss-too-high");    // totalAssets is 0 now: nothing left
        vault.adjustTotalAssets(-1);
    }

    // REBALANCER: can only move the queues FIFO. Every payout equals convertToAssets(shares),
    // every mint equals convertToShares(assets); the rebalancer's own balances never change.
    function test_compromised_rebalancer_cannotExtractValue() public {
        _fillCapacityExactly(alice, 500_000e6);
        uint256 bobId = _deposit(bob, 100_000e6);
        (, , uint256 bobQueued) = _depositRequest(bobId);

        uint256 aliceShares = vault.balanceOf(alice);
        _requestRedeem(alice, aliceShares);

        uint256 rbUsdc = usdc.balanceOf(rebalancer);
        uint256 rbSp   = spUsdc.balanceOf(rebalancer);
        uint256 rbSh   = vault.balanceOf(rebalancer);

        // Starve: 1 share at a time, both queues, arbitrary order.
        _processRedeems(1, 1);
        assertEq(usdc.balanceOf(alice), vault.convertToAssets(1));
        _processRedeems(aliceShares / 3, 1);
        _processDeposits(bobQueued / 2, 1);
        assertEq(vault.balanceOf(bob), vault.convertToShares(spUsdc.convertToAssets(bobQueued / 2)));
        _processRedeems(type(uint256).max, 1);
        _processDeposits(type(uint256).max, 1);

        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertLe(usdc.balanceOf(alice), vault.convertToAssets(aliceShares));
        assertGe(usdc.balanceOf(alice), vault.convertToAssets(aliceShares) - 3);  // 3 partial fills
        assertLe(vault.balanceOf(bob), vault.convertToShares(spUsdc.convertToAssets(bobQueued)));
        assertGe(vault.balanceOf(bob), vault.convertToShares(spUsdc.convertToAssets(bobQueued)) - 2);

        assertEq(usdc.balanceOf(rebalancer),   rbUsdc);
        assertEq(spUsdc.balanceOf(rebalancer), rbSp);
        assertEq(vault.balanceOf(rebalancer),  rbSh);

        // Starvation ceiling: a user can always cancel a starved request (not paused), but the
        // refund now also waits for the rebalancer. Partial settlement pays exactly
        // spUSDC.redeem(shares) per fill: the user loses at most one floor per partial.
        _setCapacity(vault.totalSupply());
        uint256 dId = _deposit(rando, 10e6);
        (, , uint256 dq) = _depositRequest(dId);
        assertGt(dq, 0);
        vm.prank(rando);
        uint256 cId = vault.requestDepositCancellation(dId, rando);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), dq);

        _processCancelledDeposits(1, 1);
        assertEq(usdc.balanceOf(rando), spUsdc.convertToAssets(1));
        _processCancelledDeposits(dq / 3, 1);
        _processCancelledDeposits(type(uint256).max, 1);
        (, , uint256 cLeft) = _cancelledDepositRequest(cId);
        assertEq(cLeft, 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertLe(usdc.balanceOf(rando), spUsdc.convertToAssets(dq));
        assertGe(usdc.balanceOf(rando), spUsdc.convertToAssets(dq) - 3);

        assertEq(usdc.balanceOf(rebalancer),   rbUsdc);
        assertEq(spUsdc.balanceOf(rebalancer), rbSp);
    }

    // REBALANCER processing 1 share at a time costs the vault <= 1 spUSDC share per fill (R9).
    // Bounded by gas: ~600 fills per block, i.e. dust.
    function test_compromised_rebalancer_partialFillsLeakAtMostOneSpUsdcShareEach() public {
        _deposit(alice, 1_000e6);
        uint256 shares = vault.balanceOf(alice);
        _requestRedeem(alice, shares);

        uint256 sp0 = _vaultSpUsdc();
        for (uint256 i; i < 100; ++i) _processRedeems(1, 1);

        assertEq(usdc.balanceOf(alice), 100);
        assertEq(sp0 - _vaultSpUsdc(), 100);     // 1 spUSDC share (1.0476 wei) per 1-wei payout
        // One full fill of the same 100 shares would have burned ceil(100 * RAY / chi_s) ~ 96.
        uint256 oneFill = (100 * RAY - 1) / spUsdc.nowChi() + 1;
        assertLt(oneFill, 100);
    }

    /**********************************************************************************************/
    /*** 12. Queue state consistency                                                            ***/
    /**********************************************************************************************/

    // pending == sum of open entries, entries before the head are closed, and head reset on the
    // instant path never skips an open entry. Random op sequence.
    function testFuzz_queueInvariants_randomOps(bytes32 seed) public {
        address[3] memory users = [alice, bob, rando];
        _setCapacity(500_000e6);
        _setRedeemFeeRate(0.001e18);

        for (uint256 step; step < 24; ++step) {
            uint256 r   = uint256(keccak256(abi.encode(seed, step)));
            address u   = users[r % 3];
            uint256 op  = (r >> 8) % 11;
            uint256 amt = ((r >> 16) % 200_000) * 1e6 + (r >> 40) % 1000;

            if (op == 0 || op == 1) {
                _deposit(u, amt);
            } else if (op == 2) {
                uint256 bal = vault.balanceOf(u);
                if (bal > 1_000) _requestRedeem(u, bal / 2);
            } else if (op == 3) {
                uint256 n = _depositQueueLength();
                if (n > 0) {
                    uint256 id = (r >> 48) % n;
                    (address o, , uint256 s) = _depositRequest(id);
                    if (s != 0 && o == u) { vm.prank(u); vault.requestDepositCancellation(id, u); }
                }
            } else if (op == 4) {
                // V2-2: the guardian cancel path is gone (0ebb452): cancel is owner-only
                // (:430). The guardian gets `not-authorized`; the owner cancels to himself.
                uint256 n = _depositQueueLength();
                if (n > 0) {
                    uint256 id = (r >> 48) % n;
                    (address o, , uint256 s) = _depositRequest(id);
                    if (s != 0) {
                        vm.prank(guardian);
                        vm.expectRevert("SparkPrimeVault/not-authorized");
                        vault.requestDepositCancellation(id, o);
                        vm.prank(o);
                        vault.requestDepositCancellation(id, o);
                    }
                }
            } else if (op == 5) {
                _processDeposits((r >> 48) % 2 == 0 ? type(uint256).max : amt, 1 + (r >> 56) % 4);
            } else if (op == 6) {
                _processRedeems((r >> 48) % 2 == 0 ? type(uint256).max : amt, 1 + (r >> 56) % 4);
            } else if (op == 7) {
                _setCapacity(((r >> 48) % 1_000_000) * 1e6);
            } else if (op == 8) {
                _warp((r >> 48) % 7 days);
            } else if (op == 9) {
                _processCancelledDeposits((r >> 48) % 2 == 0 ? type(uint256).max : amt, 1 + (r >> 56) % 4);
            } else {
                // Repoints: the owner may repoint their own open entry to anyone (here: a fresh
                // address of theirs); a stranger or a closed entry reverts. Accounting unaffected.
                uint256 which = (r >> 48) % 3;
                uint256 n = which == 0 ? _depositQueueLength()
                          : which == 1 ? _redeemQueueLength() : _cancelledQueueLength();
                if (n > 0) {
                    uint256 id = (r >> 56) % n;
                    (address o, , uint256 s) = which == 0 ? _depositRequest(id)
                                             : which == 1 ? _redeemRequest(id)
                                             : _cancelledDepositRequest(id);
                    bool asOwner = (r >> 64) % 2 == 0 && s != 0;
                    address caller = asOwner ? o : attacker;
                    if (!asOwner) {
                        vm.expectRevert(s == 0 ? bytes("SparkPrimeVault/no-request")
                                               : bytes("SparkPrimeVault/not-authorized"));
                    }
                    vm.prank(caller);
                    if (which == 0)      vault.updateDepositRecipient(id, caller);
                    else if (which == 1) vault.updateRedeemRecipient(id, caller);
                    else                 vault.updateDepositCancellationRecipient(id, caller);
                }
            }

            _checkQueueInvariants();
        }
    }

    function _checkQueueInvariants() internal view {
        assertEq(vault.pendingDepositSavingsShares(),          _sumOpenDeposits(),  "pendingDeposit != sum");
        assertEq(vault.pendingCancelledDepositSavingsShares(), _sumOpenCancelled(), "pendingCancelled != sum");
        assertEq(vault.pendingRedeemShares(),                  _sumOpenRedeems(),   "pendingRedeem != sum");
        assertEq(vault.balanceOf(address(vault)),     vault.pendingRedeemShares(), "escrow != pending");
        assertGe(
            _vaultSpUsdc(),
            vault.pendingDepositSavingsShares() + vault.pendingCancelledDepositSavingsShares(),
            "spUSDC backing below queued claims"
        );

        uint256 dh = vault.firstPendingDepositId();
        for (uint256 i; i < dh; ++i) {
            (, , uint256 s) = _depositRequest(i);
            assertEq(s, 0, "open deposit entry before head");
        }
        uint256 rh = vault.firstPendingRedeemId();
        for (uint256 i; i < rh; ++i) {
            (, , uint256 s) = _redeemRequest(i);
            assertEq(s, 0, "open redeem entry before head");
        }
        uint256 ch = vault.firstPendingDepositCancellationId();
        for (uint256 i; i < ch; ++i) {
            (, , uint256 s) = _cancelledDepositRequest(i);
            assertEq(s, 0, "open cancelled entry before head");
        }
        assertLe(dh, _depositQueueLength());
        assertLe(rh, _redeemQueueLength());
        assertLe(ch, _cancelledQueueLength());
    }

    // The instant path resets depositHead to the new request only when pending == 0, which
    // implies every earlier entry has shares == 0 (sum of open entries == pending).
    function test_requestDeposit_headResetSkipsOnlyClosedEntries() public {
        _fillCapacityExactly(alice, 100e6);
        uint256 id0 = _deposit(bob, 10e6);
        uint256 id1 = _deposit(rando, 10e6);
        assertEq(vault.firstPendingDepositId(), 1);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);   // fills bob only
        assertEq(vault.firstPendingDepositId(), 2);
        (, , uint256 s1) = _depositRequest(id1);
        assertGt(s1, 0);
        assertEq(vault.pendingDepositSavingsShares(), s1);

        // New deposit while rando is open: NOT instant, head untouched.
        uint256 id3 = _deposit(victim, 1e6);
        assertEq(vault.firstPendingDepositId(), 2);
        assertEq(vault.balanceOf(victim), 0);

        _processDeposits(type(uint256).max, 10);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(), 4);

        // Now pending == 0: next deposit resets head to its own index (5) and fills.
        uint256 id4 = _deposit(victim, 1e6);
        assertEq(id4, 4);
        assertEq(vault.firstPendingDepositId(), 5);
        assertGt(vault.balanceOf(victim), 0);
        id0; id3;
    }

    /**********************************************************************************************/
    /*** Extra: things found along the way                                                      ***/
    /**********************************************************************************************/

    // Regression for R4-A (blacklisted redeem recipient blocked the FIFO queue): the request is
    // rejected up front (:452 `recipient-cannot-receive`), and a recipient blacklisted after
    // queueing is paid into `claimableAssets` (:955-957) so the queue keeps moving. Minimal
    // version at fee 0 with a 1-share jam; the full accounting is in AdversarialRound4Test.
    function test_fixed_R4A_blacklistedRedeemRecipientDoesNotBlockQueue() public {
        address blacklisted = makeAddr("blacklisted");
        _blacklist(blacklisted);

        _deposit(attacker, 1e6);
        _deposit(alice, 1_000_000e6);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestRedeem(1, blacklisted);

        // Mid-flight: clean at request time, blacklisted before the planner runs.
        address mid = makeAddr("mid");
        vm.prank(attacker);
        uint256 jamId = vault.requestRedeem(1, mid);
        _requestRedeem(alice, vault.balanceOf(alice));
        _blacklist(mid);

        _processRedeems(type(uint256).max, 10);              // no revert, FIFO moves on
        assertEq(vault.firstPendingRedeemId(), 2);
        assertEq(vault.claimableAssets(mid), 1);             // convertToAssets(1 share) = 1 wei
        assertEq(usdc.balanceOf(address(vault)), 1);
        assertEq(usdc.balanceOf(mid), 0);
        assertGt(usdc.balanceOf(alice), 999_990e6);

        vm.expectRevert(BLACKLISTED);
        vault.claim(mid);
        _unblacklist(mid);
        vault.claim(mid);
        assertEq(usdc.balanceOf(mid), 1);
        assertEq(usdc.balanceOf(address(vault)), 0);
        jamId;
    }

    // spUSDC's own deposit cap is a hard dependency: once it is hit, requestDeposit reverts
    // outright (nothing is queued).
    function test_requestDeposit_revertsWhenSpUsdcCapHit() public {
        _deposit(alice, 1_000e6);
        uint256 cap = spUsdc.totalAssets() + 100e6;
        vm.prank(spAdmin);
        spUsdc.setDepositCap(cap);

        _fund(bob, 101e6);
        vm.prank(bob);
        vm.expectRevert("SparkVault/deposit-cap-exceeded");
        vault.requestDeposit(101e6, bob, 0);

        vm.prank(bob);
        vault.requestDeposit(100e6, bob, 0);
        assertGt(vault.balanceOf(bob), 0);
    }

    // Regression for round-2 R2-4: the settlement budget is `spUSDC.maxRedeem(vault)` (clamped to
    // spUSDC liquidity), so a whale cancel at the head no longer reverts the planner. The whale
    // is drip-fed automatically with whatever liquidity exists; the small entry behind still
    // waits (FIFO) until liquidity covers the remainder of the whale.
    function test_cancelQueue_whaleCancelStarvesQueueWhenSpUsdcShort() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 whaleId  = _deposit(attacker, 10_000_000e6);
        uint256 victimId = _deposit(victim, 100e6);
        (, , uint256 whaleShares) = _depositRequest(whaleId);

        vm.prank(attacker);
        vault.requestDepositCancellation(whaleId, attacker);        // cancel id 0 (head)
        vm.prank(victim);
        vault.requestDepositCancellation(victimId, victim);         // cancel id 1

        // spUSDC has only 1_000 USDC of liquidity left.
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 1_000e6);
        uint256 budget = spUsdc.maxRedeem(address(vault));
        assertEq(budget, 1_000e6 * RAY / spUsdc.nowChi());   // liquidity in shares, floored

        // No revert: the whale is partially paid up to the liquidity, the victim gets nothing.
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(attacker), spUsdc.convertToAssets(budget));
        assertLe(1_000e6 - usdc.balanceOf(attacker), 2);     // ~1_000 USDC, floor rounding
        assertEq(usdc.balanceOf(victim), 0);
        assertEq(vault.firstPendingDepositCancellationId(), 0);           // whale still at the head
        (, , uint256 whaleLeft) = _cancelledDepositRequest(0);
        assertEq(whaleLeft, whaleShares - budget);
        assertLe(usdc.balanceOf(address(spUsdc)), 1);        // spUSDC drained to dust

        // Liquidity trickles back 1_000 USDC at a time: each planner call pays the whale only.
        for (uint256 i; i < 3; ++i) {
            _returnSpUsdcLiquidity(1_000e6);
            _processCancelledDeposits(type(uint256).max, 10);
            assertEq(usdc.balanceOf(victim), 0);
            assertEq(vault.firstPendingDepositCancellationId(), 0);
        }
        assertApproxEqAbs(usdc.balanceOf(attacker), 4_000e6, 8);

        // Only once liquidity covers the remainder of the whale does the victim get paid.
        _returnSpUsdcLiquidity(10_000_000e6);
        _processCancelledDeposits(type(uint256).max, 10);
        assertApproxEqAbs(usdc.balanceOf(attacker), 10_000_000e6, 10);
        assertApproxEqAbs(usdc.balanceOf(victim), 100e6, 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
    }

    // Cancel-queue bloat: dust deposits (2 wei -> 1 spUSDC share) cancelled in bulk are real
    // entries (shares != 0) that each cost the planner a full spUSDC.redeem. Measures the cost to
    // delay a victim's refund by N entries.
    function test_cancelQueue_dustCancelsGasPerEntry() public {
        _fillCapacityExactly(alice, 1_000e6);

        _fund(attacker, 2 * 500);
        vm.startPrank(attacker);
        uint256 g0 = gasleft();
        uint256 d = vault.requestDeposit(2, attacker, 0);
        vault.requestDepositCancellation(d, attacker);
        uint256 perDust = g0 - gasleft();
        for (uint256 i; i < 499; ++i) {
            d = vault.requestDeposit(2, attacker, 0);
            vault.requestDepositCancellation(d, attacker);
        }
        vm.stopPrank();
        assertEq(_cancelledQueueLength(), 500);

        uint256 vId = _deposit(victim, 100e6);
        vm.prank(victim);
        uint256 vc = vault.requestDepositCancellation(vId, victim);
        assertEq(vc, 500);

        vm.prank(rebalancer);
        uint256 g1 = gasleft();
        vault.processPendingDepositCancellations(type(uint256).max, 500);
        uint256 plannerGas = g1 - gasleft();
        assertEq(vault.firstPendingDepositCancellationId(), 500);
        assertEq(usdc.balanceOf(victim), 0);
        assertEq(usdc.balanceOf(attacker), 500);          // 1 wei back per 2 wei in

        _processCancelledDeposits(type(uint256).max, 1);
        assertApproxEqAbs(usdc.balanceOf(victim), 100e6, 2);

        uint256 perEntry = plannerGas / 500;
        emit log_named_uint("attacker gas per dust deposit+cancel", perDust);
        emit log_named_uint("planner gas per dust cancelled entry (warm)", perEntry);
        emit log_named_uint("dust cancels settleable per 30M block", 30_000_000 / perEntry);
        assertLt(perEntry, 40_000);
        assertGt(30_000_000 / perEntry, 500);
    }

    // Capacity hog: deposit to fill capacity, request redeem at once. Escrowed shares stay in
    // totalSupply so capacity is full until the planner pays; at fee 0 the attacker is refunded
    // in full and can repeat forever at zero cost.
    function test_capacityHog_depositThenRedeemHoldsCapacityForFree() public {
        _setCapacity(1_000_000e6);

        uint256 free = vault.convertToAssets(vault.availableCapacity());
        _deposit(attacker, free);
        assertLe(vault.availableCapacity(), 2);

        _requestRedeem(attacker, vault.balanceOf(attacker));
        assertLe(vault.availableCapacity(), 2);              // escrow still counts

        uint256 vId = _deposit(victim, 1_000e6);
        assertEq(vault.balanceOf(victim), 0);                // queued

        _processRedeems(type(uint256).max, 1);
        assertApproxEqAbs(usdc.balanceOf(attacker), free, 4); // full refund, fee 0
        assertGt(vault.availableCapacity(), 0);

        // Victim is still queued; before the planner runs deposits, attacker re-hogs.
        uint256 have = usdc.balanceOf(attacker);
        vm.prank(attacker);
        vault.requestDeposit(have, attacker, 0);                 // queued behind victim (pending != 0)

        _processDeposits(type(uint256).max, 10);              // FIFO: victim first, then attacker
        assertGt(vault.balanceOf(victim), 0);
        vId;
    }


    /**********************************************************************************************/
    /*** 13. Recipient updates are owner-only (round 2 attacks, re-pinned as regressions)        ***/
    /**********************************************************************************************/

    // Regression for round-2 R2-1 (redeem): mallory sees the planner's processPendingRedeems in the
    // mempool and tries to repoint alice's head entry to herself. The call reverts and the
    // planner pays alice in full.
    function test_updateRecipient_strangerCannotRepointRedeem_victimPaid() public {
        _deposit(alice, 1_000_000e6);
        uint256 shares = vault.balanceOf(alice);
        uint256 id = _requestRedeem(alice, shares);
        uint256 owed = vault.convertToAssets(shares);

        vm.prank(attacker);                                    // no shares, no deposit, no role
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateRedeemRecipient(id, attacker);

        // Roles do not help either: guardian, rebalancer and admin are strangers to the entry.
        address[3] memory roles = [guardian, rebalancer, admin];
        for (uint256 i; i < 3; ++i) {
            vm.prank(roles[i]);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.updateRedeemRecipient(id, attacker);
        }

        (, address r, ) = _redeemRequest(id);
        assertEq(r, alice);

        _processRedeems(type(uint256).max, 1);                 // honest planner, same block

        assertEq(usdc.balanceOf(alice), owed);
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    // Regression for round-2 R2-1 (deposit): the queued spUSDC is minted to the victim.
    function test_updateRecipient_strangerCannotRepointDeposit_victimMinted() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 id = _deposit(victim, 1_000_000e6);
        (, , uint256 queued) = _depositRequest(id);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositRecipient(id, attacker);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);

        uint256 expected = vault.convertToShares(spUsdc.convertToAssets(queued));
        assertEq(vault.balanceOf(victim), expected);
        assertEq(vault.balanceOf(attacker), 0);
    }

    // Regression for round-2 R2-1 (cancelled deposit): the refund goes to the victim's chosen
    // recipient.
    function test_updateRecipient_strangerCannotRepointCancelled_victimRefunded() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 id = _deposit(victim, 1_000_000e6);

        vm.prank(victim);
        uint256 cId = vault.requestDepositCancellation(id, victim);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositCancellationRecipient(cId, attacker);

        _processCancelledDeposits(type(uint256).max, 1);

        assertApproxEqAbs(usdc.balanceOf(victim), 1_000_000e6, 2);
        assertEq(usdc.balanceOf(attacker), 0);
    }

    // Regression for round-2 R2-1 (no safe exit): the owner can repoint and cancel to a fresh
    // address and a stranger can touch neither queue entry. Whichever queue the money sits in,
    // only the owner's writes count.
    function test_updateRecipient_ownerRepointsAndCancelsSafely() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 id = _deposit(victim, 500_000e6);

        address safe = makeAddr("victim-safe");
        vm.prank(victim);
        vault.updateDepositRecipient(id, safe);
        (, address r0, ) = _depositRequest(id);
        assertEq(r0, safe);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositRecipient(id, attacker);

        vm.prank(victim);
        uint256 cId = vault.requestDepositCancellation(id, safe);
        (address o, address r, ) = _cancelledDepositRequest(cId);
        assertEq(o, victim);                                   // owner carries over
        assertEq(r, safe);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositCancellationRecipient(cId, attacker);

        // The deposit entry is closed: even the owner cannot repoint it anymore.
        vm.prank(victim);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateDepositRecipient(id, victim);

        _processCancelledDeposits(type(uint256).max, 1);
        assertApproxEqAbs(usdc.balanceOf(safe), 500_000e6, 2);
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(usdc.balanceOf(victim), 0);
    }

    // Regression for round-2 R2-2 and R4-A: nobody, owner included, can repoint a live redeem to
    // a blacklisted address (:508 `recipient-cannot-receive` runs BEFORE the owner check :513, so
    // a stranger gets that reason too). The round-1 A-1 self-harm (owner blocks the queue by
    // naming a blacklisted recipient) is gone: the only remaining case is a recipient blacklisted
    // after the request, which pays into `claimableAssets` and never blocks anyone.
    function test_fixed_R4A_nobodyCanRepointToBlacklisted_checkOrder() public {
        address blacklisted = makeAddr("blacklisted");
        _blacklist(blacklisted);
        _setRedeemFeeRate(0.01e18);

        _deposit(alice, 1_000_000e6);
        _deposit(bob, 10_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 aId = _requestRedeem(alice, aliceShares);
        _requestRedeem(bob, vault.balanceOf(bob));

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");   // before not-authorized
        vault.updateRedeemRecipient(aId, blacklisted);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.updateRedeemRecipient(aId, blacklisted);
        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateRedeemRecipient(aId, attacker);

        (, address r, ) = _redeemRequest(aId);
        assertEq(r, alice);

        // Both paid; nothing anyone did mattered.
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 989_999_999_997);
        assertGt(usdc.balanceOf(bob), 9_800e6);
        assertEq(vault.firstPendingRedeemId(), 2);
    }

    // Regression for round-2 R2-2 (strand in vault): only the owner can repoint to the vault,
    // and `address(this)` is still accepted, so the round-1 A-6 self-harm persists.
    function test_updateRecipient_onlyOwnerCanStrandOwnRedeemInVault() public {
        _deposit(alice, 100_000e6);
        uint256 shares = vault.balanceOf(alice);
        uint256 id = _requestRedeem(alice, shares);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateRedeemRecipient(id, address(vault));

        vm.prank(alice);
        vault.updateRedeemRecipient(id, address(vault));       // self-harm, still allowed

        _processRedeems(type(uint256).max, 1);

        uint256 expected = vault.convertToAssets(shares);
        assertEq(usdc.balanceOf(address(vault)), expected);
        assertEq(usdc.balanceOf(alice), 0);
        _takeAll();                                            // take moves spUSDC only
        assertEq(usdc.balanceOf(address(vault)), expected);
    }

    // Regression for round-2 R2-2 (dead capacity): `updateDepositRecipient` rejects the vault
    // (:481) for the owner too, so queued deposits can no longer be minted as phantom shares.
    function test_fixed_updateDepositRecipientVaultRejected() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 id = _deposit(victim, 100_000e6);
        (, , uint256 queued) = _depositRequest(id);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/vault-recipient");  // :481 runs before the owner check :486
        vault.updateDepositRecipient(id, address(vault));

        vm.prank(victim);
        vm.expectRevert("SparkPrimeVault/vault-recipient");
        vault.updateDepositRecipient(id, address(vault));

        _setCapacity(1_000_000e6);
        _processDeposits(type(uint256).max, 1);

        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.balanceOf(victim), vault.convertToShares(spUsdc.convertToAssets(queued)));
    }

    // Only the owner's writes land; the stranger's attempts revert every time, including between
    // partial fills. The owner may legitimately repoint the remainder after a partial fill.
    function test_updateRecipient_onlyOwnerWritesCountAtFill() public {
        _deposit(alice, 10_000e6);
        uint256 shares = vault.balanceOf(alice);
        uint256 id = _requestRedeem(alice, shares);

        for (uint256 i; i < 5; ++i) {
            vm.prank(attacker);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.updateRedeemRecipient(id, attacker);
            vm.prank(alice);
            vault.updateRedeemRecipient(id, i % 2 == 0 ? alice : bob);
        }
        (, address r, ) = _redeemRequest(id);
        assertEq(r, alice);

        _processRedeems(shares / 2, 1);
        assertEq(usdc.balanceOf(alice), vault.convertToAssets(shares / 2));

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateRedeemRecipient(id, attacker);
        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);                  // owner redirects the remainder
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob), vault.convertToAssets(shares - shares / 2));
        assertEq(usdc.balanceOf(attacker), 0);
    }

    // Closed (filled or cancelled) entries can no longer be written at all: `no-request` for
    // everyone, owner included. Check order: zero recipient, then index bounds, then open entry,
    // then owner. Out-of-range ids revert with the array panic.
    function test_updateRecipient_filledEntryIsHarmless() public {
        uint256 dId = _deposit(alice, 1_000e6);                // instant: entry 0 deleted
        uint256 rId = _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems(type(uint256).max, 1);                 // entry 0 deleted

        vm.startPrank(attacker);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateDepositRecipient(dId, attacker);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateRedeemRecipient(rId, attacker);
        vm.expectRevert();                                     // index out of bounds
        vault.updateDepositRecipient(dId + 1, attacker);
        vm.expectRevert();
        vault.updateDepositCancellationRecipient(0, attacker);    // empty queue
        vm.expectRevert("SparkPrimeVault/zero-recipient");
        vault.updateRedeemRecipient(rId, address(0));
        vm.stopPrank();

        vm.startPrank(alice);                                  // owner, closed entries
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateDepositRecipient(dId, alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateRedeemRecipient(rId, alice);
        vm.stopPrank();

        (address o0, address r0, uint256 s0) = _depositRequest(dId);
        assertEq(o0, address(0));
        assertEq(r0, address(0));
        assertEq(s0, 0);

        // Nothing changes for the next users.
        _deposit(bob, 10e6);
        assertGt(vault.balanceOf(bob), 0);
        _requestRedeem(bob, vault.balanceOf(bob));
        _processRedeems(type(uint256).max, 10);
        assertApproxEqAbs(usdc.balanceOf(bob), 10e6, 2);
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(vault.balanceOf(attacker), 0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    /**********************************************************************************************/
    /*** 14. Deposit head walk griefing (round 2)                                               ***/
    /**********************************************************************************************/

    // Ghosts behind an open head entry are not walked until that entry closes. If the planner
    // closes it exactly (budget or maxRequests ends there) the head lands on the first ghost and
    // the next depositor pays the whole walk once. Measures gas per ghost and the N for 30M.
    function test_griefing_headWalkChargedToNextDepositorAfterPlannerClosesHead() public {
        _fillCapacityExactly(alice, 1_000e6);

        _fund(attacker, 2);
        vm.startPrank(attacker);
        vault.requestDeposit(2, attacker, 0);                     // id 1: 1 share, open, at head
        for (uint256 i; i < 1000; ++i) vault.requestDeposit(0, attacker, 0);   // ids 2..1001
        vm.stopPrank();
        assertEq(vault.firstPendingDepositId(), 1);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);                // closes id 1 only
        assertEq(vault.firstPendingDepositId(), 2);                      // head on the first ghost

        // Baseline: an instant deposit with nothing to walk (fresh vault state is similar).
        _fund(victim, 20e6);
        vm.prank(victim);
        uint256 g0 = gasleft();
        vault.requestDeposit(10e6, victim, 0);
        uint256 walked = g0 - gasleft();
        assertEq(vault.firstPendingDepositId(), 1003);                   // walked 1000 ghosts, filled self
        assertGt(vault.balanceOf(victim), 0);

        vm.prank(victim);
        uint256 g1 = gasleft();
        vault.requestDeposit(10e6, victim, 0);
        uint256 baseline = g1 - gasleft();

        uint256 perGhost = (walked - baseline) / 1000;
        uint256 perGhostCold = perGhost + 2_000;               // one cold SLOAD per ghost on mainnet
        emit log_named_uint("requestDeposit gas with 1000-ghost walk", walked);
        emit log_named_uint("requestDeposit gas baseline", baseline);
        emit log_named_uint("walk gas per ghost (warm)", perGhost);
        emit log_named_uint("ghosts to exceed 30M gas (cold estimate)", 30_000_000 / perGhostCold);
        emit log_named_uint("attacker gas to place them (75k each)", 30_000_000 / perGhostCold * 75_000);
        assertLt(perGhost, 1_000);
        assertGt(30_000_000 / perGhostCold, 10_000);
    }

    // 0ebb452 head freeze: with `availableCapacity() == 0` the walk in `_processPendingDeposits`
    // never runs (`remaining_ == 0` :837), so ghosts placed while capacity is full are NOT walked
    // by each other any more; they pile up at the frozen head. The first real depositor once
    // capacity returns pays the whole walk in his instant fill. Gas per ghost measured.
    function test_griefing_capacityZeroFreezesHead_nextDepositorPaysWalk() public {
        _fillCapacityExactly(alice, 1_000e6);                  // capacity 0: no instant fills
        assertEq(vault.firstPendingDepositId(), 1);

        vm.startPrank(attacker);
        uint256 g0 = gasleft();
        vault.requestDeposit(0, attacker, 0);
        uint256 ghostCost = g0 - gasleft();
        for (uint256 i; i < 299; ++i) vault.requestDeposit(0, attacker, 0);   // ids 1..300
        vm.stopPrank();
        assertEq(vault.firstPendingDepositId(), 1);                      // frozen: nothing walked
        assertEq(vault.pendingDepositSavingsShares(), 0);

        // The planner cannot clear them either while capacity is 0.
        _processDeposits(type(uint256).max, 1000);
        assertEq(vault.firstPendingDepositId(), 1);

        _setCapacity(type(uint128).max);
        _fund(victim, 1e6);
        vm.prank(victim);
        uint256 g1 = gasleft();
        vault.requestDeposit(1e6, victim, 0);                     // id 301: walks ids 1..300, fills self
        uint256 walked = g1 - gasleft();
        assertEq(vault.firstPendingDepositId(), 302);
        assertGt(vault.balanceOf(victim), 0);

        vm.prank(victim);
        _fund(victim, 1e6);
        vm.prank(victim);
        uint256 g2 = gasleft();
        vault.requestDeposit(1e6, victim, 0);                     // baseline: nothing to walk
        uint256 baseline = g2 - gasleft();

        uint256 perGhost = (walked - baseline) / 300;
        emit log_named_uint("attacker gas per ghost at capacity 0", ghostCost);
        emit log_named_uint("victim requestDeposit gas behind 300 frozen ghosts", walked);
        emit log_named_uint("victim requestDeposit gas baseline", baseline);
        emit log_named_uint("walk gas per ghost (warm)", perGhost);
        emit log_named_uint("ghosts to exceed 30M gas (cold +2_000 each)", 30_000_000 / (perGhost + 2_000));
        assertLt(perGhost, 1_000);
        assertLt(walked, 1_000_000);

        // The planner can also clear frozen ghosts once capacity exists, 1 share budget suffices.
        _setCapacity(vault.totalSupply());
        vm.startPrank(attacker);
        for (uint256 i; i < 100; ++i) vault.requestDeposit(0, attacker, 0);   // ids 303..402
        vm.stopPrank();
        assertEq(vault.firstPendingDepositId(), 303);
        _setCapacity(vault.totalSupply() + 1e12);
        _processDeposits(1, 1000);
        assertEq(vault.firstPendingDepositId(), 403);
    }

    // 0ebb452: `requestDepositCancellation` no longer walks the head (:419-444 has no loop), so an
    // owner cancelling at the head pays O(1) regardless of the ghosts behind him; the head stays
    // on his closed entry, `pending` drops to 0, and the NEXT depositor's instant fill walks the
    // ghosts (predicate :414 true). The redeem queue has no owner walk at all: free
    // `requestRedeem(0)` ghosts are only ever walked by the planner.
    function test_griefing_ownerCancelAtHeadIsO1_nextDepositorWalksGhosts() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 vId = _deposit(victim, 100e6);                 // id 1, head
        vm.startPrank(attacker);
        for (uint256 i; i < 1000; ++i) vault.requestDeposit(0, attacker, 0);   // ids 2..1001
        vm.stopPrank();

        vm.prank(victim);
        uint256 g0 = gasleft();
        vault.requestDepositCancellation(vId, victim);
        uint256 gas = g0 - gasleft();
        assertEq(vault.firstPendingDepositId(), 1);                      // head untouched
        assertEq(vault.pendingDepositSavingsShares(), 0);
        emit log_named_uint("victim cancel gas at head with 1000 ghosts behind (warm)", gas);
        assertLt(gas, 150_000);

        // Next depositor: predicate true (pending == own shares), walks 1001 closed entries.
        _setCapacity(type(uint128).max);
        _fund(bob, 100e6);
        vm.prank(bob);
        uint256 g1 = gasleft();
        vault.requestDeposit(100e6, bob, 0);                      // id 1002
        uint256 gasWalk = g1 - gasleft();
        assertEq(vault.firstPendingDepositId(), 1003);
        assertGt(vault.balanceOf(bob), 0);
        emit log_named_uint("next depositor gas walking 1001 closed entries (warm)", gasWalk);
        assertLt(gasWalk, 1_500_000);

        // Redeem queue: only the planner walks ghosts, paying the skip per ghost on top of the fill.
        _requestRedeem(bob, vault.balanceOf(bob));
        vm.startPrank(attacker);
        for (uint256 i; i < 1000; ++i) vault.requestRedeem(0, attacker);
        vm.stopPrank();
        vm.prank(rebalancer);
        uint256 g2 = gasleft();
        vault.processPendingRedeems(type(uint256).max, 1001);
        uint256 gasR = g2 - gasleft();
        assertEq(vault.firstPendingRedeemId(), 1001);
        emit log_named_uint("planner gas paying bob and skipping 1000 ghosts (warm)", gasR);
        assertLt(gasR, 1_500_000);
    }

    /**********************************************************************************************/
    /*** 15. adjustTotalAssets gain sandwich (round 3, re-pinned on 0ebb452)                    ***/
    /**********************************************************************************************/

    event TotalAssetsAdjusted(uint192 chi, int256 deltaTotalAssets);

    // Runs the gain sandwich under the real governance flow: alice holds `tvl`, the spell payload
    // `adjustTotalAssets(+gain)` is public, the attacker deposits `capital` on the instant path,
    // the guardian pauses, the spell adjusts (the gain's backing arrives as spUSDC), the admin
    // unpauses, the attacker exits through the redeem queue at `fee`. With `pauseFirst` the
    // guardian pauses BEFORE the attacker's deposit, which then reverts.
    function _runGainSandwich(
        uint256 tvl,
        uint256 capital,
        uint256 gain,
        uint256 fee,
        bool    pauseFirst
    )
        internal
        returns (uint256 attackerOut, uint256 aliceAssets, uint256 aliceFair)
    {
        _setRedeemFeeRate(fee);
        _deposit(alice, tvl);
        aliceFair = vault.assetsOf(alice) + gain;              // alice alone would get the gain

        if (pauseFirst) _pause();

        _fund(attacker, capital);
        vm.prank(attacker);
        if (pauseFirst) vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(capital, attacker, 0);               // front-run, instant path

        _returnToVault(spUsdc.convertToShares(gain));          // the gain is real backing
        if (!pauseFirst) _pause();                             // guardian pauses before the spell
        _adjustTotalAssets(int256(gain));                      // adjustTotalAssets requires paused
        _unpause();

        uint256 sh = vault.balanceOf(attacker);
        if (sh != 0) {
            _requestRedeem(attacker, sh);
            _processRedeems(type(uint256).max, 1);             // honest planner pays FIFO
        }
        attackerOut = usdc.balanceOf(attacker);
        aliceAssets = vault.assetsOf(alice);
    }

    // (a) R3-1, changed: `adjustTotalAssets` requires `paused` (:279), but the pause is a separate
    // GUARDIAN transaction and the spell payload is public before it. A deposit landing between
    // "payload public" and "pause" is priced at the old chi and captures the gain pro rata; the
    // exit is the redeem queue after the unpause. Exact numbers for 1M TVL, 1M capital, 50k gain.
    function test_BUG_R3_1_adjustTotalAssets_depositBeforePauseCapturesGain_0pctFee() public {
        (uint256 out, uint256 aliceAssets, uint256 aliceFair) =
            _runGainSandwich(1_000_000e6, 1_000_000e6, 50_000e6, 0, false);

        uint256 profit    = out - 1_000_000e6;
        uint256 aliceLoss = aliceFair - aliceAssets;

        emit log_named_uint("attacker USDC out (fee 0)", out);
        emit log_named_uint("attacker profit (fee 0)", profit);
        emit log_named_uint("alice assets after the sandwich", aliceAssets);
        emit log_named_uint("alice loss vs no sandwich", aliceLoss);

        assertEq(out,         1_024_999_999_998);              // 1_025_000 USDC less rounding
        assertEq(profit,      24_999_999_998);                 // 25_000 USDC of the 50_000 gain
        assertEq(aliceAssets, 1_024_999_999_998);              // same shares, same payout
        assertEq(aliceLoss,   25_000_000_000);                 // 25_000 USDC

        // The attacker's payout came out of the vault's spUSDC; what is left exactly backs alice.
        assertApproxEqAbs(spUsdc.convertToAssets(_vaultSpUsdc()), aliceAssets, 2);
        assertEq(vault.balanceOf(attacker), 0);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    // (a) A 1% redeem fee only reduces the take: the fee is 1% of the attacker's exit (1_025_000),
    // 10_250 USDC, profit still 14_750.
    function test_BUG_R3_1_adjustTotalAssets_depositBeforePauseCapturesGain_1pctFee() public {
        (uint256 out, uint256 aliceAssets, uint256 aliceFair) =
            _runGainSandwich(1_000_000e6, 1_000_000e6, 50_000e6, 0.01e18, false);

        emit log_named_uint("attacker USDC out (fee 1%)", out);
        emit log_named_uint("attacker profit (fee 1%)", out - 1_000_000e6);
        emit log_named_uint("alice loss (fee 1%)", aliceFair - aliceAssets);

        assertEq(out, 1_014_749_999_997);                      // 1_025_000 * 0.99, less rounding
        assertEq(out - 1_000_000e6, 14_749_999_997);           // 14_750 USDC profit
        assertEq(aliceFair - aliceAssets, 25_000_000_000);     // alice still loses 25_000

        // The burned fee shares are the only mitigation: they stay as vault equity.
        assertGt(spUsdc.convertToAssets(_vaultSpUsdc()), aliceAssets + 10_249e6);
    }

    // (a) Capital requirement scales with TVL: the attacker's take is gain * c / (tvl + c).
    // 1M against 10M TVL takes 1/11 of the gain; 10M against 10M takes half.
    function test_BUG_R3_1_adjustTotalAssets_takeScalesWithCapital_1MvsTVL10M() public {
        (uint256 out, , ) = _runGainSandwich(10_000_000e6, 1_000_000e6, 50_000e6, 0, false);
        uint256 profit = out - 1_000_000e6;
        emit log_named_uint("profit, 1M capital vs 10M TVL", profit);
        assertEq(profit, 4_545_454_544);                       // 50_000 / 11, less rounding
        assertApproxEqAbs(profit, uint256(50_000e6) / 11, 2);  // take = gain * c / (tvl + c)
    }

    function test_BUG_R3_1_adjustTotalAssets_takeScalesWithCapital_10MvsTVL10M() public {
        (uint256 out, , ) = _runGainSandwich(10_000_000e6, 10_000_000e6, 50_000e6, 0, false);
        uint256 profit = out - 10_000_000e6;
        emit log_named_uint("profit, 10M capital vs 10M TVL", profit);
        assertEq(profit, 24_999_999_998);
        assertApproxEqAbs(profit, uint256(50_000e6) / 2, 2);
    }

    // (a) Regression for R3-1 as fixed upstream: `adjustTotalAssets` is only callable while paused
    // (:279) and `requestDeposit` is `whenNotPaused` (:391), so once the guardian has paused no
    // deposit can be priced at the pre-gain chi. The order that kills the sandwich is
    // pause -> adjust -> unpause with the pause landing BEFORE the attacker's deposit.
    function test_fixed_R3_1_pauseBeforeDepositKillsSandwich() public {
        (uint256 out, uint256 aliceAssets, uint256 aliceFair) =
            _runGainSandwich(1_000_000e6, 1_000_000e6, 50_000e6, 0, true);

        assertEq(out, 1_000_000e6);                            // never got in: USDC untouched
        assertEq(vault.balanceOf(attacker), 0);
        assertApproxEqAbs(aliceAssets, aliceFair, 1);          // alice receives the full gain
        assertEq(aliceAssets, 1_049_999_999_997);

        // A deposit after the unpause is priced at the new chi and earns nothing from the gain.
        _deposit(attacker, 1_000_000e6);
        assertApproxEqAbs(vault.assetsOf(attacker), 1_000_000e6, 2);
        assertLe(vault.assetsOf(attacker), 1_000_000e6);

        // And the adjustment itself cannot run unpaused.
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/not-paused");
        vault.adjustTotalAssets(1);
    }

    // (a) Queued variant: if the attacker's deposit cannot fill instantly (capacity full), it is
    // priced at the post-gain chi when the planner fills it, so there is no profit to take.
    // Pinning capacity to totalSupply before the payload is public is the second kill switch.
    function test_adjustTotalAssets_queuedDepositFilledAfterGainGetsNoProfit() public {
        _fillCapacityExactly(alice, 1_000_000e6);
        uint256 aliceFair = vault.assetsOf(alice) + 50_000e6;

        uint256 id = _deposit(attacker, 1_000_000e6);         // queued, 0 shares
        assertEq(vault.balanceOf(attacker), 0);

        _returnToVault(spUsdc.convertToShares(50_000e6));
        _adjustTotalAssetsWhilePaused(50_000e6);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);
        (, , uint256 left) = _depositRequest(id);
        assertEq(left, 0);

        assertApproxEqAbs(vault.assetsOf(alice), aliceFair, 1);
        assertEq(vault.assetsOf(alice), 1_049_999_999_997);
        assertApproxEqAbs(vault.assetsOf(attacker), 1_000_000e6, 2);
        assertLe(vault.assetsOf(attacker), 1_000_000e6);       // no profit, rounding loss only

        _requestRedeem(attacker, vault.balanceOf(attacker));
        _processRedeems(type(uint256).max, 1);
        assertLe(usdc.balanceOf(attacker), 1_000_000e6);
    }

    // (b) Escrowed redeemers (shares parked in the vault, still in totalSupply) receive the gain
    // because the fill prices their shares at the chi of the fill, not of the request. The
    // cancelled-deposit queue does not: refunds are spUSDC.redeem, untouched by chi.
    function test_adjustTotalAssets_escrowedRedeemersReceiveGain_cancelledDepositsDoNot() public {
        _deposit(alice, 1_000_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 owedBefore  = vault.convertToAssets(aliceShares);
        _requestRedeem(alice, aliceShares);                    // escrowed, planner has not run

        // Bob's deposit is queued (capacity pinned) and then cancelled; refund pending.
        _setCapacity(vault.totalSupply());
        uint256 bId = _deposit(bob, 100_000e6);
        vm.prank(bob);
        uint256 cId = vault.requestDepositCancellation(bId, bob);

        _returnToVault(spUsdc.convertToShares(50_000e6));
        _adjustTotalAssetsWhilePaused(50_000e6);               // totalSupply == escrow only

        _processRedeems(type(uint256).max, 1);
        uint256 paid = usdc.balanceOf(alice);
        emit log_named_uint("escrowed redeemer paid", paid);
        assertApproxEqAbs(paid, owedBefore + 50_000e6, 1);     // whole gain: she was the supply
        assertEq(paid, 1_049_999_999_997);

        _processCancelledDeposits(type(uint256).max, 1);
        (, , uint256 cLeft) = _cancelledDepositRequest(cId);
        assertEq(cLeft, 0);
        assertApproxEqAbs(usdc.balanceOf(bob), 100_000e6, 2);  // no share of the gain
        assertLe(usdc.balanceOf(bob), 100_000e6);
    }

    // (c) Compromised or fat-fingered admin (out of the trust model, blast radius only).
    //  - gain above the real backing: holders are over-credited; the first redeemer is paid in
    //    full from backing, the last is short (same shape as the VSR_SETTER over-credit).
    //  - gain pushing chi above 2^256 / RAY: `_rpow(vsr, dt) * chi` in drip() overflows one
    //    second later, every entry point drips, so the vault is bricked (pause/unpause/take do
    //    not drip; adjustTotalAssets does, so it cannot undo it; only an upgrade repairs it).
    function test_compromised_admin_adjustTotalAssetsOverCreditIsInsolvency() public {
        _deposit(alice, 1_000_000e6);
        _deposit(bob, 1_000_000e6);
        uint256 backing = spUsdc.convertToAssets(_vaultSpUsdc());

        // Over-credit: 1_000_000 USDC "gain" with no backing behind it.
        _adjustTotalAssetsWhilePaused(1_000_000e6);
        assertApproxEqAbs(vault.totalAssets(), backing + 1_000_000e6, 2);

        _requestRedeem(alice, vault.balanceOf(alice));
        _requestRedeem(bob, vault.balanceOf(bob));
        _processRedeems(type(uint256).max, 10);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_500_000e6, 2);   // alice: full, 50% bonus
        assertApproxEqAbs(usdc.balanceOf(bob),     500_000e6, 2);   // bob: whatever was left
        assertLe(_vaultSpUsdc(), 1);
        uint256 shortfall = vault.convertToAssets(vault.pendingRedeemShares());
        emit log_named_uint("unpayable remainder after over-credit", shortfall);
        assertApproxEqAbs(shortfall, 1_000_000e6, 4);
    }

    // G-1 / G-2 (open): the only bound on the new chi is `<= type(uint192).max` (:292, ~6.3e57),
    // but `drip` computes `_rpow(vsr, dt) * chi` in checked uint256 (:637), so any chi above
    // floor(2^256 / RAY) = 1.157e50 makes every drip revert one second later. Exact thresholds:
    // the largest surviving chi is `type(uint256).max / RAY`; one chi-step above it bricks;
    // `adjustTotalAssets` itself drips first (:282) so it cannot undo it; only an upgrade can.
    function test_BUG_G1_adjustTotalAssets_chiAboveDripBoundBricks_exactThreshold() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply = vault.totalSupply();
        _pause();

        // uint192 bound is enforced, but it is ~5.4e7 times above the real overflow bound.
        uint256 ta       = vault.totalAssets();
        uint256 over192  = (uint256(type(uint192).max) / RAY + 1) * supply;   // chi > uint192.max
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/chi-too-high");
        vault.adjustTotalAssets(int256(over192 - ta));

        // Largest safe chi: chiMax = floor(uint256.max / RAY). Choose totalAssets so that the
        // resulting chi is <= chiMax, then one second later drip still works.
        uint256 chiMax = type(uint256).max / RAY;
        uint256 taSafe = chiMax * supply / RAY;                // floor: chi lands <= chiMax
        _adjustTotalAssets(int256(taSafe - ta));
        uint256 chiSafe = vault.chi();
        assertLe(chiSafe, chiMax);
        assertGt(chiSafe, chiMax - RAY / supply - 1);          // within one chi-step of the bound
        emit log_named_uint("largest surviving chi", chiSafe);
        emit log_named_uint("totalAssets at that chi (USDC wei)", vault.totalAssets());
        _warp(1);
        vault.drip();                                          // still fine
        assertEq(vault.chi(), chiSafe);                        // vsr == RAY: unchanged

        // One more chi-step (+supply assets => +RAY chi) and the vault is bricked.
        uint256 ta2 = vault.totalAssets();
        _adjustTotalAssets(int256(supply));                    // same second: no drip change
        assertGt(uint256(vault.chi()), chiMax);
        assertLe(uint256(vault.chi()), type(uint192).max);
        emit log_named_uint("bricking gain over 1M TVL (USDC wei)", vault.totalAssets() - ta2 + (ta2 - ta));

        bytes memory overflow = abi.encodeWithSelector(bytes4(keccak256("Panic(uint256)")), 0x11);
        _warp(1);
        vm.expectRevert(overflow);
        vault.drip();
        vm.expectRevert(overflow);
        vault.nowChi();
        vm.expectRevert(overflow);
        vault.totalAssets();
        vm.prank(admin);
        vm.expectRevert(overflow);
        vault.adjustTotalAssets(-1);                           // drips first: cannot repair
        vm.prank(admin);
        vm.expectRevert(overflow);
        vault.adjustTotalAssets(-int256(ta2));
        vm.prank(vsrSetter);
        vm.expectRevert(overflow);
        vault.setVSR(RAY);
        _unpause();
        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(overflow);
        vault.requestDeposit(1e6, bob, 0);
        vm.prank(alice);
        vm.expectRevert(overflow);
        vault.requestRedeem(1, alice);
        vm.prank(rebalancer);
        vm.expectRevert(overflow);
        vault.processPendingRedeems(1, 1);
        // What still works: transfer, approve, pause, take (backing exits), claim.
        vm.prank(alice);
        vault.transfer(bob, 1);
        _takeAll();
        assertEq(_vaultSpUsdc(), 0);
    }

    // (d) Same-pause gain/loss pairs (and the reverse order) never ratchet chi upward: every step
    // floors (:289), so after n netting pairs chi <= chi0 and totalAssets is within 2n units of
    // the start. Users have no hook between the two admin calls (paused), and a round trip after
    // them never returns more than deposited.
    function testFuzz_adjustTotalAssets_gainLossPairs_noRatchet(
        uint256 g, uint256 n, bool lossFirst, uint256 amt
    ) public {
        amt = bound(amt, 1e6, 1e9 * 1e6);
        n   = bound(n, 1, 8);

        _deposit(alice, amt);
        uint256 ta0  = vault.totalAssets();
        uint256 chi0 = vault.chi();
        g = bound(g, 1, ta0 - 1);

        _pause();
        for (uint256 i; i < n; ++i) {
            if (lossFirst) {
                if (g >= vault.totalAssets()) break;           // drift ate the room
                _adjustTotalAssets(-int256(g));
                _adjustTotalAssets(int256(g));
            } else {
                _adjustTotalAssets(int256(g));
                uint256 ta = vault.totalAssets();
                if (g >= ta) break;                            // floor ate the room: nothing to lose
                _adjustTotalAssets(-int256(g));
            }
            assertLe(vault.chi(), chi0, "chi ratcheted up");
        }
        _unpause();

        uint256 ta1 = vault.totalAssets();
        assertLe(ta1, ta0);
        assertLe(ta0 - ta1, 2 * n, "drift above 2 units per pair");

        _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems(type(uint256).max, 1);
        assertLe(usdc.balanceOf(alice), amt);
    }

    // Access and bounds: DEFAULT_ADMIN only (role check before the pause check), paused only,
    // delta != 0, totalSupply == 0 panics on a gain, drips first, emits the new chi and delta.
    function test_adjustTotalAssets_accessAndBounds() public {
        address[5] memory who = [redeemFeeSetter, guardian, vsrSetter, rebalancer, taker];
        for (uint256 i; i < 5; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", who[i], DEFAULT_ADMIN_ROLE
            ));
            vault.adjustTotalAssets(1);
        }

        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/not-paused");
        vault.adjustTotalAssets(1);

        _pause();
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/delta-total-assets-zero");
        vault.adjustTotalAssets(0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Panic(uint256)")), 0x12));
        vault.adjustTotalAssets(1);                            // totalSupply == 0
        _unpause();

        _deposit(alice, 1_000_000e6);
        _setPrimeVsr(FIVE_PCT_VSR);
        _warp(30 days);                                        // undripped accrual pending

        uint256 supply   = vault.totalSupply();
        uint256 dripped  = vault.nowChi();
        uint256 taAfter  = supply * dripped / RAY;
        uint192 expected = uint192((taAfter + 1_000e6) * RAY / supply);

        _pause();
        vm.expectEmit(address(vault));
        emit TotalAssetsAdjusted(expected, 1_000e6);
        vm.prank(admin);
        vault.adjustTotalAssets(1_000e6);
        assertEq(vault.chi(), expected);
        assertEq(vault.rho(), block.timestamp);                // dripped first
        assertApproxEqAbs(vault.totalAssets(), taAfter + 1_000e6, 1);
        assertLe(vault.totalAssets(), taAfter + 1_000e6);      // floor
    }

}

/**********************************************************************************************/
/*** Round 4 (bf93b0d), ported to 0ebb452: blacklist fallback, owner-only cancel, fresh attacks ***/
/**********************************************************************************************/

/// @dev Second contract so the file stays under the compiler's jump-tag limit. Line numbers in
///      comments refer to `src/SparkPrimeVault.sol` at 0ebb452.
contract AdversarialRound4Test is LocalTestBase {

    event Referral(uint16 indexed referral, address indexed recipient, uint256 assets);
    event RedeemRequest(
        address indexed owner,
        address indexed recipient,
        uint256 indexed requestId,
        uint256         shares,
        uint256         fee
    );

    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal attacker = makeAddr("attacker");
    address internal victim   = makeAddr("victim");
    address internal clean    = makeAddr("clean");

    address internal blacklisted = makeAddr("blacklisted");

    bytes internal constant BLACKLIST = "Blacklistable: account is blacklisted";

    function setUp() public override {
        super.setUp();
        // Real Circle-style blacklist in MockUSDC: transfers to/from/by the address revert with
        // the mainnet message and `isBlacklisted` is what the vault consults (:1052).
        _blacklist(blacklisted);
    }

    function _fillCapacityExactly(address who, uint256 amt) internal {
        _deposit(who, amt);
        _setCapacity(vault.totalSupply());
        assertEq(vault.availableCapacity(), 0);
    }

    function _processRedeemsReverts(bytes memory reason) internal {
        vm.prank(rebalancer);
        vm.expectRevert(reason);
        vault.processPendingRedeems(type(uint256).max, 10);
    }

    function _processCancelsReverts(bytes memory reason) internal {
        vm.prank(rebalancer);
        vm.expectRevert(reason);
        vault.processPendingDepositCancellations(type(uint256).max, 10);
    }

    /**********************************************************************************************/
    /*** 1. Blacklisted / vault / spUSDC recipients with no cancel                               ***/
    /**********************************************************************************************/

    // (a) Regression for R4-A at launch-like parameters (minRedeem = 100 shares, fee 1%). The
    // request to a blacklisted recipient is rejected before any state change (:452), the owner
    // cannot repoint a live entry to one either (:508), and a recipient blacklisted after the
    // request is paid into `claimableAssets` (:955-957): the queue moves, alice is paid, the USDC
    // waits in the vault, `claim` reverts inside USDC while blacklisted and pays after.
    function test_fixed_R4A_blacklistedRedeemRecipient_rejectedAtRequest_claimableAtPayout() public {
        _setMinRedeem(100e6);
        _setRedeemFeeRate(0.01e18);

        _deposit(attacker, 200e6);
        _deposit(alice, 1_000_000e6);
        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestRedeem(100e6, blacklisted);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.totalSupply(), vault.balanceOf(attacker) + aliceShares);   // no fee burned

        // Clean at request, blacklisted before the planner runs.
        address mid = makeAddr("mid");
        vm.prank(attacker);
        uint256 jamId = vault.requestRedeem(100e6, mid);
        uint256 aId = _requestRedeem(alice, aliceShares);
        assertEq(vault.pendingRedeemShares(), 99e6 + aliceShares - ((aliceShares * 0.01e18 - 1) / WAD + 1));
        _blacklist(mid);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.updateRedeemRecipient(jamId, blacklisted);

        uint256 owed      = vault.convertToAssets(99e6);
        uint256 aliceOwed = vault.convertToAssets(aliceShares - ((aliceShares * 0.01e18 - 1) / WAD + 1));
        uint256 chiS      = spUsdc.nowChi();
        uint256 spBefore  = _vaultSpUsdc();
        assertEq(owed,      99_959_089);
        assertEq(aliceOwed, 989_999_999_997);

        _processRedeems(type(uint256).max, 10);

        assertEq(vault.firstPendingRedeemId(), 2);                   // queue moved past the jam
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.claimableAssets(mid), owed);
        assertEq(usdc.balanceOf(address(vault)), owed);              // escrowed as USDC
        assertEq(usdc.balanceOf(mid), 0);
        assertEq(usdc.balanceOf(alice), aliceOwed);
        // spUSDC burned: one ceil per withdraw (:955 and :952), nothing extra for the fallback.
        assertEq(
            spBefore - _vaultSpUsdc(),
            (owed * RAY - 1) / chiS + 1 + (aliceOwed * RAY - 1) / chiS + 1
        );

        // claim: anyone may call, reverts inside USDC while blacklisted, state untouched.
        vm.prank(attacker);
        vm.expectRevert(BLACKLISTED);
        vault.claim(mid);
        assertEq(vault.claimableAssets(mid), owed);
        assertEq(usdc.balanceOf(address(vault)), owed);

        _unblacklist(mid);
        vm.prank(victim);                                            // a stranger pays it out
        uint256 paid = vault.claim(mid);
        assertEq(paid, owed);
        assertEq(usdc.balanceOf(mid), owed);
        assertEq(usdc.balanceOf(victim), 0);
        assertEq(vault.claimableAssets(mid), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(mid);
        aId;
    }

    // (b) A victim blacklisted while queued (recipient == self) has two exits: repoint to a clean
    // address before the planner runs (`updateRedeemRecipient` moves no USDC, so it works while
    // the owner is blacklisted), or let the planner credit `claimableAssets` and claim once
    // un-blacklisted. Both exact; bob behind her is paid either way.
    function test_blacklistedOwner_repointOrClaim_bothExact() public {
        _deposit(alice, 1_000_000e6);
        _deposit(bob, 10_000e6);
        _deposit(victim, 1_000e6);
        uint256 aliceShares  = vault.balanceOf(alice);
        uint256 victimShares = vault.balanceOf(victim);
        uint256 aId = _requestRedeem(alice, aliceShares);
        _requestRedeem(bob, vault.balanceOf(bob));
        _requestRedeem(victim, victimShares);

        _blacklist(alice);                                           // sanctioned after queueing
        _blacklist(victim);

        vm.prank(alice);
        vault.updateRedeemRecipient(aId, clean);                     // no transfer: succeeds

        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(clean), vault.convertToAssets(aliceShares));
        assertEq(usdc.balanceOf(clean), 999_999_999_998);
        assertGt(usdc.balanceOf(bob), 9_990e6);
        assertEq(vault.firstPendingRedeemId(), 3);

        uint256 victimOwed = vault.convertToAssets(victimShares);
        assertEq(victimOwed, 999_999_998);
        assertEq(vault.claimableAssets(victim), victimOwed);
        assertEq(usdc.balanceOf(victim), 0);
        vm.expectRevert(BLACKLISTED);
        vault.claim(victim);

        _unblacklist(victim);
        vault.claim(victim);
        assertEq(usdc.balanceOf(victim), victimOwed);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // (c) Self-harm only: recipient == vault strands the USDC (no path moves USDC out of the
    // vault, `take` moves spUSDC), recipient == spUSDC donates it to spUSDC's liquidity (its
    // totalAssets is index-based, so the USDC is not credited to anyone and spUSDC's taker can
    // pull it). Both are the owner's own choice; nobody else can set them.
    function test_escrow_redeemRecipientVaultStrandsAndSpUsdcDonates() public {
        _deposit(attacker, 200_000e6);
        uint256 half = vault.balanceOf(attacker) / 2;

        vm.startPrank(attacker);
        vault.requestRedeem(half, address(vault));
        vault.requestRedeem(half, address(spUsdc));
        vm.stopPrank();

        uint256 spTotalAssetsBefore = spUsdc.totalAssets();
        uint256 spUsdcBefore        = usdc.balanceOf(address(spUsdc));
        uint256 owed                = vault.convertToAssets(half);

        _processRedeems(type(uint256).max, 10);

        assertEq(owed, 99_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), owed);              // stranded
        assertEq(usdc.balanceOf(address(spUsdc)), spUsdcBefore - owed);          // 2nd leg nets to 0
        assertApproxEqAbs(spUsdc.totalAssets(), spTotalAssetsBefore - 2 * owed, 2); // both legs burned
        assertEq(usdc.balanceOf(attacker), 0);
        assertLe(vault.balanceOf(attacker), 1);                      // odd share count

        // The donation is spUSDC's to take; the stranded USDC is nobody's to take.
        _takeAll();
        assertEq(usdc.balanceOf(address(vault)), owed);
        uint256 excess = usdc.balanceOf(address(spUsdc)) - spUsdc.totalAssets();
        emit log_named_uint("USDC stranded in the vault", owed);
        emit log_named_uint("USDC donated to spUSDC (excess over its totalAssets)", excess);
        assertGe(excess + 2, owed);
        vm.prank(spTaker);
        spUsdc.take(excess);
        assertEq(usdc.balanceOf(spTaker), excess);

        // Strangers cannot cause either: the updater is owner-only.
        _deposit(victim, 1_000e6);
        uint256 vId = _requestRedeem(victim, vault.balanceOf(victim));
        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateRedeemRecipient(vId, address(vault));
    }

    /**********************************************************************************************/
    /*** 2. Capacity hog is a commitment now                                                   ***/
    /**********************************************************************************************/

    // C-10 downgraded: with no cancel the hog's shares sit in escrow until the planner pays. He
    // cannot transfer them (balance 0), cannot cancel, and repointing changes nothing. The first
    // planner call releases him FIFO, frees the capacity, and his re-hog queues behind the
    // victim. One hog = one planner call of delay, and the attacker's capital is illiquid for it.
    function test_capacityHog_isACommitmentUntilPlannerPays() public {
        _setCapacity(1_000_000e6);
        uint256 free = vault.convertToAssets(vault.availableCapacity());
        _deposit(attacker, free);
        uint256 hogShares = vault.balanceOf(attacker);
        uint256 hogId = _requestRedeem(attacker, hogShares);
        assertLe(vault.availableCapacity(), 2);

        uint256 vId = _deposit(victim, 1_000e6);
        assertEq(vault.balanceOf(victim), 0);                        // queued

        // No exit without the planner.
        assertEq(vault.balanceOf(attacker), 0);
        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.transfer(clean, 1);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("cancelRedeemRequest(uint256,address)", hogId, attacker)
        );
        assertFalse(ok);
        vm.prank(attacker);
        vault.updateRedeemRecipient(hogId, clean);
        assertEq(vault.pendingRedeemShares(), hogShares);
        assertEq(vault.balanceOf(address(vault)), hogShares);
        _warpAndDrip(30 days);
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(usdc.balanceOf(clean),    0);

        // One planner pass: hog paid (to `clean`), capacity free, victim filled first.
        _processRedeems(type(uint256).max, 1);
        assertApproxEqAbs(usdc.balanceOf(clean), free, 4);
        assertGt(vault.availableCapacity(), 0);

        _fund(attacker, free);
        vm.prank(attacker);
        vault.requestDeposit(free, attacker, 0);                        // queued behind the victim
        _processDeposits(type(uint256).max, 10);
        assertGt(vault.balanceOf(victim), 0);
        (, , uint256 vLeft) = _depositRequest(vId);
        assertEq(vLeft, 0);
    }

    /**********************************************************************************************/
    /*** 3. Compromised / absent roles                                                          ***/
    /**********************************************************************************************/

    // REBALANCER lock-in: every exit in all three queues needs the planner. A starved redeemer
    // cannot cancel (gone), transfer (escrowed) or be released by any role; a starved depositor
    // can cancel but the refund is a planner call too. Quantified for 1M + 100k.
    function test_compromised_rebalancer_starvedUsersAreLockedInAllThreeQueues() public {
        _deposit(alice, 1_000_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 aId = _requestRedeem(alice, aliceShares);

        _setCapacity(vault.totalSupply());
        uint256 bId = _deposit(bob, 100_000e6);
        vm.prank(bob);
        uint256 cId = vault.requestDepositCancellation(bId, bob);

        uint256 lockedRedeem = vault.convertToAssets(vault.pendingRedeemShares());
        uint256 lockedCancel = spUsdc.convertToAssets(vault.pendingCancelledDepositSavingsShares());
        emit log_named_uint("locked behind the planner: redeem queue (USDC wei)", lockedRedeem);
        emit log_named_uint("locked behind the planner: cancel queue (USDC wei)", lockedCancel);
        assertEq(lockedRedeem, 999_999_999_998);
        assertEq(lockedCancel, 99_999_999_999);

        // alice: nothing she or any role can do.
        assertEq(vault.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.transfer(clean, 1);
        vm.prank(alice);
        vault.updateRedeemRecipient(aId, clean);                     // allowed, releases nothing
        assertEq(vault.pendingRedeemShares(), aliceShares);

        address[4] memory roles = [guardian, admin, redeemFeeSetter, vsrSetter];
        for (uint256 i; i < 4; ++i) {
            vm.startPrank(roles[i]);
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", roles[i], REBALANCER_ROLE
            ));
            vault.processPendingRedeems(type(uint256).max, 10);
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", roles[i], REBALANCER_ROLE
            ));
            vault.processPendingDepositCancellations(type(uint256).max, 10);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.updateRedeemRecipient(aId, roles[i]);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.updateDepositCancellationRecipient(cId, roles[i]);
            vm.stopPrank();
        }
        _pause(); _unpause();                                        // changes nothing
        _warpAndDrip(365 days);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(usdc.balanceOf(clean), 0);

        // The admin's only lever is the one that does not need the role: a new REBALANCER.
        vm.prank(admin);
        vault.grantRole(REBALANCER_ROLE, clean);
        vm.startPrank(clean);
        vault.processPendingRedeems(type(uint256).max, 10);
        vault.processPendingDepositCancellations(type(uint256).max, 10);
        vm.stopPrank();
        assertEq(usdc.balanceOf(clean), lockedRedeem);
        assertEq(usdc.balanceOf(bob),   lockedCancel);
    }

    // Regression for V2-2 / F-1: the guardian cancel path is gone. `requestDepositCancellation`
    // :430 is owner-only (`not-authorized` for the guardian whatever recipient he names), the
    // updaters are owner-only, the guardian's only tool is `pause` (:380), and cancel is blocked
    // while paused (:420). The owner's own cancel refunds exactly spUSDC.redeem.
    function test_fixed_V2_2_guardianHasNoCancelPath() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 dId = _deposit(victim, 100e6);
        _requestRedeem(alice, vault.balanceOf(alice));

        vm.startPrank(guardian);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(dId, guardian);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(dId, victim);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(dId, address(vault));
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateRedeemRecipient(0, victim);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositRecipient(dId, victim);
        vault.pause();
        vm.stopPrank();

        vm.prank(victim);
        vm.expectRevert("SparkPrimeVault/paused");                   // cannot cancel while paused
        vault.requestDepositCancellation(dId, victim);
        _unpause();

        vm.prank(victim);
        uint256 cId = vault.requestDepositCancellation(dId, victim);
        (address o, address r, ) = _cancelledDepositRequest(cId);
        assertEq(o, victim);
        assertEq(r, victim);
        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositCancellationRecipient(cId, guardian);
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(victim), 99_999_999);
        assertEq(usdc.balanceOf(guardian), 0);
    }

    /**********************************************************************************************/
    /*** 4. Fresh eyes                                                                          ***/
    /**********************************************************************************************/

    // (a) Regression for R4-B: a cancel naming a blacklisted refund address is rejected (:425),
    // the owner cannot repoint a live cancel entry to one (:493), and a refund address blacklisted
    // after the cancel is paid into `claimableAssets` via `spUSDC.redeem` to the vault (:942-944):
    // the cancellation queue keeps moving and the victim behind is refunded. Exact amounts.
    function test_fixed_R4B_blacklistedCancelRecipient_rejectedAtRequest_claimableAtSettlement()
        public
    {
        _setMinDeposit(1e6);
        _fillCapacityExactly(alice, 1_000e6);

        uint256 aId = _deposit(attacker, 1e6);                       // queued: capacity full
        uint256 vId = _deposit(victim, 1_000_000e6);                 // queued behind him
        (, , uint256 aQueued) = _depositRequest(aId);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestDepositCancellation(aId, blacklisted);
        (, , uint256 stillQueued) = _depositRequest(aId);
        assertEq(stillQueued, aQueued);                              // entry untouched

        address mid = makeAddr("mid");
        vm.prank(attacker);
        uint256 jam = vault.requestDepositCancellation(aId, mid);
        vm.prank(victim);
        uint256 vc = vault.requestDepositCancellation(vId, victim);
        assertEq(jam, 0);
        assertEq(vc,  1);
        _blacklist(mid);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.updateDepositCancellationRecipient(jam, blacklisted);

        uint256 spBefore = _vaultSpUsdc();
        _processCancelledDeposits(type(uint256).max, 10);           // no revert

        uint256 refund = spUsdc.convertToAssets(aQueued);            // redeem floors (:942)
        assertEq(refund, 999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.claimableAssets(mid), refund);
        assertEq(usdc.balanceOf(address(vault)), refund);
        assertEq(usdc.balanceOf(mid), 0);
        assertEq(usdc.balanceOf(victim), 999_999_999_999);
        assertEq(spBefore - _vaultSpUsdc(), aQueued + spUsdc.convertToShares(1_000_000e6));

        vm.expectRevert(BLACKLISTED);
        vault.claim(mid);
        _unblacklist(mid);
        assertEq(vault.claim(mid), refund);
        assertEq(usdc.balanceOf(mid), refund);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.claimableAssets(mid), 0);
    }

    // (b) `transferFrom` self-transfer edges (:539-558, :937-950): from == to leaves the balance
    // unchanged (unchecked block is exact), a spender's self-transfer only burns allowance, and a
    // max allowance is never decremented.
    function test_transferFrom_selfTransferEdges() public {
        _deposit(alice, 1_000e6);
        uint256 bal = vault.balanceOf(alice);

        vm.prank(alice);
        vault.transfer(alice, bal);
        assertEq(vault.balanceOf(alice), bal);
        vm.prank(alice);
        vault.transferFrom(alice, alice, bal);                       // msg.sender == from: no allowance
        assertEq(vault.balanceOf(alice), bal);

        vm.prank(alice);
        vault.approve(bob, bal);
        vm.prank(bob);
        vault.transferFrom(alice, alice, bal / 2);                   // to == from
        assertEq(vault.balanceOf(alice), bal);
        assertEq(vault.allowance(alice, bob), bal - bal / 2);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-allowance");
        vault.transferFrom(alice, alice, bal);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.transferFrom(alice, bob, bal + 1);
        assertEq(vault.totalSupply(), bal);
    }

    // (c) Regression: `transfer(address(vault))` and `transferFrom(.., address(vault))` are
    // rejected (:549, :557), so no spPRIME can sit in the vault outside the redeem escrow and
    // `balanceOf(vault) == pendingRedeemShares` holds through a full redeem cycle.
    function test_fixed_transferToVaultRejected_escrowInvariantHolds() public {
        _deposit(attacker, 100e6);
        _deposit(alice, 1_000e6);
        uint256 atk = vault.balanceOf(attacker);
        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transfer(address(vault), atk);
        vm.prank(attacker);
        vault.approve(bob, atk);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transferFrom(attacker, address(vault), atk);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.balanceOf(attacker), atk);

        _requestRedeem(alice, aliceShares);
        assertEq(vault.balanceOf(address(vault)), vault.pendingRedeemShares());
        _processRedeems(aliceShares / 3, 1);
        assertEq(vault.balanceOf(address(vault)), vault.pendingRedeemShares());
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), atk);
        assertEq(usdc.balanceOf(alice), vault.convertToAssets(aliceShares / 3) + vault.convertToAssets(aliceShares - aliceShares / 3));
    }

    // (d) Info: `Referral` (:405) is emitted for any `recipient_` chosen by the caller before the
    // deposit, so off-chain attribution by event is spoofable for the price of `minDeposit`,
    // which is gifted to the recipient as shares. The recipient gets no control over the entry
    // and cannot be harmed by it.
    function test_referral_eventSpoofableForAnyRecipient() public {
        _setMinDeposit(1e6);
        _fund(attacker, 2e6);

        vm.prank(attacker);
        vm.expectEmit(address(vault));
        emit Referral(777, victim, 1e6);
        vault.requestDeposit(1e6, victim, 777);
        assertGt(vault.balanceOf(victim), 0);                        // unsolicited shares
        assertEq(vault.balanceOf(attacker), 0);

        // Queued variant: the attacker owns the entry, the recipient cannot touch it, and the
        // attacker can take it back (cancel to himself) before fill.
        _setCapacity(vault.totalSupply());
        vm.prank(attacker);
        uint256 id = vault.requestDeposit(1e6, victim, 777);
        vm.startPrank(victim);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositRecipient(id, victim);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(id, victim);
        vm.stopPrank();
        vm.prank(attacker);
        vault.requestDepositCancellation(id, attacker);
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(attacker), 999_999);
    }

    // (e) Mint has no hook (:930-935): a recipient contract with neither receive nor fallback is
    // minted on the instant path, on a queued fill, and after `updateDepositRecipient` to it.
    function test_requestDeposit_recipientContractWithoutHooksIsMinted() public {
        NoHooks sink = new NoHooks();

        _fund(alice, 300e6);
        vm.prank(alice);
        vault.requestDeposit(100e6, address(sink), 0);                  // instant
        uint256 minted = vault.balanceOf(address(sink));
        assertGt(minted, 0);

        _setCapacity(vault.totalSupply());
        vm.prank(alice);
        uint256 id = vault.requestDeposit(100e6, alice, 0);             // queued
        vm.prank(alice);
        vault.updateDepositRecipient(id, address(sink));             // repoint right before fill
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(address(sink)), 2 * minted);
        assertEq(vault.balanceOf(alice), 0);
    }

    // (f) ERC-1271 signer reached from `permit` (:989 staticcall) cannot touch the queues or
    // nest a permit: each attempt makes the check fail with `invalid-permit`, nonce and queues
    // untouched. The signer's own honest redeem is unaffected.
    function test_reentrancy_erc1271SignerCannotTouchQueuesOrPermit() public {
        Erc1271QueueReentrant wallet = new Erc1271QueueReentrant(vault);
        _fund(address(wallet), 1_000e6);
        vm.prank(address(wallet));
        vault.requestDeposit(500e6, address(wallet), 0);
        uint256 shares = vault.balanceOf(address(wallet));
        wallet.requestRedeem(shares / 2);                            // honest open entry, id 0
        uint256 pendingBefore = vault.pendingRedeemShares();
        uint256 lenBefore     = _redeemQueueLength();
        uint256 deadline      = block.timestamp + 1 hours;

        for (uint256 mode = 1; mode <= 3; ++mode) {
            wallet.setMode(mode);
            vm.expectRevert("SparkPrimeVault/invalid-permit");
            vault.permit(address(wallet), bob, 1, deadline, hex"01");
        }
        assertEq(vault.nonces(address(wallet)), 0);
        assertEq(vault.allowance(address(wallet), bob), 0);
        assertEq(vault.allowance(address(wallet), address(0xBEEF)), 0);
        assertEq(vault.pendingRedeemShares(), pendingBefore);
        assertEq(_redeemQueueLength(), lenBefore);
        (, address r, ) = _redeemRequest(0);
        assertEq(r, address(wallet));

        wallet.setMode(0);                                           // honest accepter
        vault.permit(address(wallet), bob, 1, deadline, hex"01");
        assertEq(vault.allowance(address(wallet), bob), 1);
        assertEq(vault.nonces(address(wallet)), 1);
    }

    // (g) Info: at any non-zero fee `requestRedeem(1)` is a 100% fee (:464 rounds up) and queues
    // a 0-share ghost that the planner skips; below 1 / rate shares the fee is at least one
    // share. `minRedeem >= 100` at a 1% cap removes it.
    function test_requestRedeem_oneShareAtNonZeroFeeIsAllFeeGhost() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1e6);
        uint256 supply = vault.totalSupply();

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit RedeemRequest(alice, alice, 0, 1, 1);
        uint256 id = vault.requestRedeem(1, alice);
        (, , uint256 s) = _redeemRequest(id);
        assertEq(s, 0);
        assertEq(vault.totalSupply(), supply - 1);                   // burned, nothing queued
        assertEq(vault.pendingRedeemShares(), 0);

        // 99 shares: fee rounds 0.99 up to 1 share (1.01%); 100 shares: exactly 1.
        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit RedeemRequest(alice, alice, 1, 99, 1);
        vault.requestRedeem(99, alice);
        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit RedeemRequest(alice, alice, 2, 100, 1);
        vault.requestRedeem(100, alice);

        _processRedeems(type(uint256).max, 10);                      // ghost skipped, rest paid
        assertEq(vault.firstPendingRedeemId(), 3);
        assertEq(usdc.balanceOf(alice), vault.convertToAssets(98) + vault.convertToAssets(99));
    }

    // (h) Property: fills never push `totalSupply` above `maxCapacity` (budget :803-806 floors
    // twice, mint :824 floors again), on the planner path and on the instant path, for random
    // capacities, indexes and request sizes.
    function testFuzz_processDeposits_supplyNeverExceedsCapacity(
        uint256 cap, uint256 a1, uint256 a2, uint256 vsrS, uint256 secs
    ) public {
        cap  = bound(cap, 1, 10_000_000e6);
        a1   = bound(a1, 1, 5_000_000e6);
        a2   = bound(a2, 1, 5_000_000e6);
        vsrS = bound(vsrS, RAY, MAX_VSR);
        secs = bound(secs, 0, 365 days);

        _setCapacity(cap);
        _deposit(alice, a1);                                         // instant, maybe partial
        assertLe(vault.totalSupply(), cap, "instant path over cap");

        _setSpUsdcVsr(vsrS);
        _warpAndDrip(secs);
        _deposit(bob, a2);
        assertLe(vault.totalSupply(), cap, "second instant path over cap");

        _processDeposits(type(uint256).max, 10);
        assertLe(vault.totalSupply(), cap, "planner over cap");

        uint256 newCap = cap + bound(uint256(keccak256(abi.encode(cap, a1))), 0, 1_000_000e6);
        _setCapacity(newCap);
        _processDeposits(type(uint256).max, 10);
        assertLe(vault.totalSupply(), newCap, "planner over raised cap");
    }


}

/**********************************************************************************************/
/*** Round 5 (0ebb452): blacklist fallback, governance-flow sandwich, roles as adversaries,   ***/
/*** extremes, ERC20 escrow, call ordering                                                    ***/
/**********************************************************************************************/

/// @dev Third contract (jump-tag limit). Line numbers refer to `src/SparkPrimeVault.sol` @ 0ebb452.
contract AdversarialRound5Test is LocalTestBase {

    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal carol    = makeAddr("carol");
    address internal attacker = makeAddr("attacker");
    address internal victim   = makeAddr("victim");
    address internal clean    = makeAddr("clean");
    address internal sanctioned = makeAddr("sanctioned");

    bytes4 internal constant PANIC = bytes4(keccak256("Panic(uint256)"));

    function setUp() public override {
        super.setUp();
        _blacklist(sanctioned);
    }

    function _fillCapacityExactly(address who, uint256 amt) internal {
        _deposit(who, amt);
        _setCapacity(vault.totalSupply());
        assertEq(vault.availableCapacity(), 0);
    }

    function _ceilBurn(uint256 assets) internal view returns (uint256) {
        return (assets * RAY - 1) / spUsdc.nowChi() + 1;
    }

    /**********************************************************************************************/
    /*** (a) Blacklist fallback                                                                 ***/
    /**********************************************************************************************/

    // Redeem queue, every combination of (blacklisted at request / at payout / at claim), with a
    // partial fill while blacklisted and the remainder paid directly after un-blacklisting.
    function test_blacklist_redeemQueue_fullMatrix() public {
        _deposit(alice, 1_000e6);
        _deposit(bob,   1_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares   = vault.balanceOf(bob);

        // 1. blacklisted at request: rejected, nothing escrowed, no fee burned.
        _setRedeemFeeRate(0.01e18);
        uint256 supply = vault.totalSupply();
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestRedeem(aliceShares, sanctioned);
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.balanceOf(alice), aliceShares);
        _setRedeemFeeRate(0);

        // 2. clean at request, blacklisted at payout: partial fill goes to claimable.
        uint256 aId = _requestRedeem(alice, aliceShares);
        uint256 bId = _requestRedeem(bob, bobShares);
        _blacklist(alice);

        uint256 half   = aliceShares / 2;
        uint256 owed1  = vault.convertToAssets(half);
        uint256 sp0    = _vaultSpUsdc();
        _processRedeems(half, 10);                               // budget stops inside alice
        assertEq(owed1, 499_999_998);
        assertEq(vault.firstPendingRedeemId(), 0);               // partial: still at the head
        assertEq(vault.claimableAssets(alice), owed1);
        assertEq(usdc.balanceOf(address(vault)), owed1);
        assertEq(sp0 - _vaultSpUsdc(), _ceilBurn(owed1));        // :955 ceil burn, nothing extra
        (, , uint256 left) = _redeemRequest(aId);
        assertEq(left, aliceShares - half);

        // 3. still blacklisted at claim: USDC reverts, nothing changes.
        vm.prank(attacker);
        vm.expectRevert(BLACKLISTED);
        vault.claim(alice);
        assertEq(vault.claimableAssets(alice), owed1);

        // 4. un-blacklisted before the remainder: the rest is paid directly, claimable untouched.
        _unblacklist(alice);
        uint256 owed2 = vault.convertToAssets(aliceShares - half);
        _processRedeems(type(uint256).max, 10);
        assertEq(owed2, 499_999_999);
        assertEq(usdc.balanceOf(alice), owed2);
        assertEq(vault.claimableAssets(alice), owed1);
        assertEq(usdc.balanceOf(bob), 999_999_998);
        assertEq(vault.firstPendingRedeemId(), 2);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.balanceOf(address(vault)), 0);

        // 5. claim pays exactly the credited part; a second claim is `nothing-to-claim`.
        assertEq(vault.claim(alice), owed1);
        assertEq(usdc.balanceOf(alice), owed1 + owed2);
        assertEq(usdc.balanceOf(alice), 999_999_997);           // bob - 1: one extra floor for the split, none for the fallback
        assertEq(usdc.balanceOf(address(vault)), 0);
        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(alice);
        bId;
    }

    // Cancellation queue, same matrix: `spUSDC.redeem` to the vault (:942) floors, so the
    // claimable amount equals exactly what a clean recipient would have received.
    function test_blacklist_cancelQueue_fullMatrix() public {
        _fillCapacityExactly(carol, 1_000e6);
        uint256 aId = _deposit(alice, 1_000e6);
        uint256 bId = _deposit(bob,   1_000e6);
        (, , uint256 aQ) = _depositRequest(aId);
        (, , uint256 bQ) = _depositRequest(bId);

        // 1. blacklisted refund address at cancel: rejected, entry untouched.
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestDepositCancellation(aId, sanctioned);
        (, , uint256 stillQ) = _depositRequest(aId);
        assertEq(stillQ, aQ);

        // 2. clean at cancel, blacklisted at settlement, partial.
        vm.prank(alice);
        uint256 ca = vault.requestDepositCancellation(aId, alice);
        vm.prank(bob);
        vault.requestDepositCancellation(bId, bob);
        _blacklist(alice);

        uint256 half  = aQ / 2;
        uint256 owed1 = spUsdc.convertToAssets(half);
        uint256 sp0   = _vaultSpUsdc();
        _processCancelledDeposits(half, 10);
        assertEq(owed1, 499_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 0);
        assertEq(vault.claimableAssets(alice), owed1);
        assertEq(usdc.balanceOf(address(vault)), owed1);
        assertEq(sp0 - _vaultSpUsdc(), half);                    // redeem burns exactly the shares
        (, , uint256 left) = _cancelledDepositRequest(ca);
        assertEq(left, aQ - half);

        // 3. claim while blacklisted reverts; 4. remainder after un-blacklisting is direct.
        vm.expectRevert(BLACKLISTED);
        vault.claim(alice);
        _unblacklist(alice);
        uint256 owed2 = spUsdc.convertToAssets(aQ - half);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), owed2);
        assertEq(usdc.balanceOf(bob), spUsdc.convertToAssets(bQ));
        assertEq(usdc.balanceOf(bob), 999_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);

        // 5. claim exact: alice ends with the same amount as bob (one more floor at most).
        assertEq(vault.claim(alice), owed1);
        assertEq(usdc.balanceOf(alice), owed1 + owed2);
        assertGe(usdc.balanceOf(alice) + 1, usdc.balanceOf(bob));
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // USDC credited to `claimableAssets` sits in the vault. No other path moves or counts it:
    // requestDeposit pulls and forwards exactly `assets_` (:400-402), `take` moves spUSDC (:346),
    // `adjustTotalAssets` reads totalSupply * chi only (:284), redeem payouts to clean recipients
    // go spUSDC -> recipient (:952), `claim` pays only the credited balance. Two separate credits
    // to the same recipient accumulate and one claim pays the sum. Claim also works while paused.
    function test_blacklist_claimableUsdcIsIsolatedAndAccumulates() public {
        _deposit(alice, 1_000e6);
        _deposit(victim, 500e6);
        uint256 vShares = vault.balanceOf(victim);

        _requestRedeem(victim, vShares / 2);
        _blacklist(victim);
        _processRedeems(type(uint256).max, 10);
        uint256 c1 = vault.claimableAssets(victim);
        assertEq(c1, 249_999_998);

        // Second credit from a second entry (owner may still request while blacklisted: no USDC).
        _unblacklist(victim);
        _requestRedeem(victim, vShares - vShares / 2);
        _blacklist(victim);
        _processRedeems(type(uint256).max, 10);
        uint256 c2 = vault.claimableAssets(victim) - c1;
        assertEq(c2, 249_999_999);
        assertEq(usdc.balanceOf(address(vault)), c1 + c2);

        // Nothing else touches it.
        uint256 vaultUsdc = usdc.balanceOf(address(vault));
        _deposit(bob, 777e6);                                    // pulls 777e6, forwards 777e6
        assertEq(usdc.balanceOf(address(vault)), vaultUsdc);
        _requestRedeem(alice, vault.balanceOf(alice) / 2);
        _processRedeems(type(uint256).max, 10);                  // clean payout: spUSDC -> alice
        assertEq(usdc.balanceOf(address(vault)), vaultUsdc);
        uint256 ta = vault.totalAssets();
        _adjustTotalAssetsWhilePaused(-int256(ta / 2));          // chi halves, USDC untouched
        assertEq(usdc.balanceOf(address(vault)), vaultUsdc);
        assertEq(vault.claimableAssets(victim), c1 + c2);
        _takeAll();                                              // spUSDC gone, USDC stays
        assertEq(usdc.balanceOf(address(vault)), vaultUsdc);
        assertEq(_vaultSpUsdc(), 0);

        // Claim while paused, by a stranger, pays the sum to the recipient only.
        _unblacklist(victim);
        _pause();
        vm.prank(attacker);
        assertEq(vault.claim(victim), c1 + c2);
        assertEq(usdc.balanceOf(victim), c1 + c2);
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // V2-13 for the cancellation queue: vault or spUSDC named as refund recipient pass the
    // blacklist check (:425), `spUSDC.redeem(.., vault, vault)` strands USDC in the vault with
    // no claimable credit (:938-939), `redeem(.., spUSDC, vault)` donates it to spUSDC. Owner's
    // own choice only; nobody else can set these recipients.
    function test_BUG_V2_13_cancelRecipientVaultOrSpUsdc_strandedNotClaimable() public {
        _fillCapacityExactly(carol, 1_000e6);
        uint256 a = _deposit(attacker, 100e6);
        uint256 b = _deposit(attacker, 100e6);
        (, , uint256 aQ) = _depositRequest(a);

        vm.startPrank(attacker);
        vault.requestDepositCancellation(a, address(vault));
        vault.requestDepositCancellation(b, address(spUsdc));
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositCancellationRecipient(0, bob);

        uint256 spUsdcLiquidity = usdc.balanceOf(address(spUsdc));
        uint256 spTotal         = spUsdc.totalAssets();
        _processCancelledDeposits(type(uint256).max, 10);

        uint256 refund = spUsdc.convertToAssets(aQ);
        assertEq(refund, 99_999_999);
        assertEq(usdc.balanceOf(address(vault)), refund);        // stranded
        assertEq(vault.claimableAssets(address(vault)), 0);
        assertEq(vault.claimableAssets(address(spUsdc)), 0);
        assertEq(usdc.balanceOf(address(spUsdc)), spUsdcLiquidity - refund);   // second leg nets 0
        assertApproxEqAbs(spUsdc.totalAssets(), spTotal - 2 * refund, 2);      // but both burned
        assertEq(usdc.balanceOf(attacker), 0);
        vm.expectRevert("SparkPrimeVault/nothing-to-claim");
        vault.claim(address(vault));
    }

    // Info: if Circle sanctions the VAULT itself, deposits revert in USDC, payouts to clean
    // recipients still work (spUSDC -> recipient), but a mid-flight-blacklisted recipient makes
    // the fallback withdraw-to-vault revert and blocks that queue, and `claim` is dead. Only the
    // owner's repoint to a clean address unblocks. Out of the trust model (USDC risk), pinned.
    function test_blacklist_vaultItselfSanctioned_fallbackBlocksQueue() public {
        _deposit(alice, 1_000e6);
        _deposit(victim, 100e6);
        _deposit(bob, 100e6);
        uint256 vId = _requestRedeem(victim, vault.balanceOf(victim));
        _requestRedeem(bob, vault.balanceOf(bob));

        _fund(carol, 1e6);
        _blacklist(address(vault));

        vm.prank(carol);
        vm.expectRevert(BLACKLISTED);
        vault.requestDeposit(1e6, carol, 0);

        _blacklist(victim);
        vm.prank(rebalancer);
        vm.expectRevert(BLACKLISTED);                            // :955 withdraw to the vault
        vault.processPendingRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob), 0);                        // bob stuck behind victim

        vm.prank(victim);
        vault.updateRedeemRecipient(vId, clean);                 // owner can still repoint
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(clean), 99_999_998);
        assertGt(usdc.balanceOf(bob), 99e6);
    }

    // An owner blacklisted mid-flight keeps every owner action that moves no USDC: cancel to a
    // clean recipient, repoint, request a redeem (shares only), and his queued deposit still
    // fills (mint only). Only `requestDeposit` dies (USDC transferFrom from him).
    function test_blacklist_ownerBlacklistedMidFlight_ownerActionsStillWork() public {
        _fillCapacityExactly(carol, 1_000e6);
        uint256 d1 = _deposit(alice, 100e6);
        uint256 d2 = _deposit(alice, 100e6);
        _deposit(bob, 50e6);
        (, , uint256 q1) = _depositRequest(d1);
        (, , uint256 q2) = _depositRequest(d2);

        _fund(alice, 1e6);
        _blacklist(alice);

        vm.prank(alice);
        vm.expectRevert(BLACKLISTED);
        vault.requestDeposit(1e6, alice, 0);

        vm.prank(alice);
        uint256 c = vault.requestDepositCancellation(d1, clean);  // clean recipient: ok
        vm.prank(alice);
        vault.updateDepositRecipient(d2, clean);                  // fill will mint to clean
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(clean), spUsdc.convertToAssets(q1));

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        uint256 minted = vault.convertToShares(spUsdc.convertToAssets(q2));
        assertEq(vault.balanceOf(clean), minted);

        // clean sends the shares back to alice; alice (blacklisted) can request a redeem to clean.
        vm.prank(clean);
        vault.transfer(alice, minted);
        vm.prank(alice);
        uint256 r = vault.requestRedeem(minted, clean);
        vm.prank(alice);
        vault.updateRedeemRecipient(r, clean);
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(clean), spUsdc.convertToAssets(q1) + vault.convertToAssets(minted));
        assertEq(usdc.balanceOf(alice), 1e6);                     // only her un-deposited funds
        c;
    }

    /**********************************************************************************************/
    /*** (b) adjustTotalAssets under the governance flow                                        ***/
    /**********************************************************************************************/

    // The four orders of the real flow, 1M TVL / 1M attacker / 50k gain, fee 0 and 1%:
    //   (i)   payload public -> deposit -> pause -> adjust -> unpause -> redeem: captures half.
    //   (ii)  pause -> deposit (reverts) -> adjust -> unpause: nothing.
    //   (iii) capacity pinned -> deposit queued -> pause/adjust/unpause -> fill: nothing.
    //   (iv)  deposit -> pause -> adjust -> unpause, rebalancer never pays: dilution is already
    //         booked for alice; the attacker merely waits.
    // Uses state snapshots so each order starts from the same vault.
    function test_BUG_R3_1_governanceFlow_fourOrders_exactProfit() public {
        _deposit(alice, 1_000_000e6);
        uint256 aliceFair = vault.assetsOf(alice) + 50_000e6;
        _fund(attacker, 1_000_000e6);
        uint256 snap = vm.snapshotState();

        // (i) fee 0
        vm.prank(attacker);
        vault.requestDeposit(1_000_000e6, attacker, 0);
        _returnToVault(spUsdc.convertToShares(50_000e6));
        _pause();
        _adjustTotalAssets(50_000e6);
        _unpause();
        _requestRedeem(attacker, vault.balanceOf(attacker));
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(attacker), 1_024_999_999_998);
        assertEq(aliceFair - vault.assetsOf(alice), 25_000_000_000);

        // (i) fee 1%
        vm.revertToState(snap);
        _setRedeemFeeRate(0.01e18);
        vm.prank(attacker);
        vault.requestDeposit(1_000_000e6, attacker, 0);
        _returnToVault(spUsdc.convertToShares(50_000e6));
        _pause();
        _adjustTotalAssets(50_000e6);
        _unpause();
        _requestRedeem(attacker, vault.balanceOf(attacker));
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(attacker), 1_014_749_999_997);   // 14_750 profit after fee
        assertEq(aliceFair - vault.assetsOf(alice), 25_000_000_000);

        // (ii) pause before the deposit
        vm.revertToState(snap);
        _pause();
        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(1_000_000e6, attacker, 0);
        _returnToVault(spUsdc.convertToShares(50_000e6));
        _adjustTotalAssets(50_000e6);
        _unpause();
        assertEq(vault.assetsOf(alice), 1_049_999_999_997);
        assertEq(usdc.balanceOf(attacker), 1_000_000e6);

        // (iii) capacity pinned before the payload is public
        vm.revertToState(snap);
        _setCapacity(vault.totalSupply());
        vm.prank(attacker);
        vault.requestDeposit(1_000_000e6, attacker, 0);           // queued
        assertEq(vault.balanceOf(attacker), 0);
        _returnToVault(spUsdc.convertToShares(50_000e6));
        _pause();
        _adjustTotalAssets(50_000e6);
        _unpause();
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.assetsOf(alice), 1_049_999_999_997);
        assertLe(vault.assetsOf(attacker), 1_000_000e6);
        assertGe(vault.assetsOf(attacker), 1_000_000e6 - 2);

        // (iv) rebalancer never pays: alice is already diluted on paper.
        vm.revertToState(snap);
        vm.prank(attacker);
        vault.requestDeposit(1_000_000e6, attacker, 0);
        _returnToVault(spUsdc.convertToShares(50_000e6));
        _pause();
        _adjustTotalAssets(50_000e6);
        _unpause();
        assertEq(aliceFair - vault.assetsOf(alice), 25_000_000_000);
        assertEq(vault.assetsOf(attacker), 1_024_999_999_998);
    }

    // A loss cannot be dodged through the redeem queue: shares are priced at the fill (:914), so
    // a redeem requested before the pause and paid after it eats the loss like every holder.
    // Queued deposits (spUSDC) do not, and get MORE shares when filled after the loss.
    function test_adjustTotalAssets_lossHitsEscrowAndHolders_notQueuedDeposits() public {
        _deposit(alice, 1_000_000e6);
        _deposit(attacker, 100_000e6);
        uint256 atkShares = vault.balanceOf(attacker);
        _requestRedeem(attacker, atkShares);                     // escrowed before the loss

        _setCapacity(vault.totalSupply());
        uint256 bId = _deposit(bob, 100_000e6);                   // queued spUSDC
        (, , uint256 bQ) = _depositRequest(bId);

        uint256 ta = vault.totalAssets();
        _pause();
        _adjustTotalAssets(-int256(ta / 10));                    // 10% loss
        _unpause();

        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(attacker), 89_999_999_999);      // 100k * 0.9, floors
        assertEq(vault.assetsOf(alice), 899_999_999_998);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(bob), vault.convertToShares(spUsdc.convertToAssets(bQ)));
        assertApproxEqAbs(vault.assetsOf(bob), 100_000e6, 2);   // no loss, priced post-loss
        assertGt(vault.balanceOf(bob), atkShares);               // more shares than the same USDC bought pre-loss
    }

    // Capacity is in shares (:785): a loss leaves the share headroom unchanged but shrinks it in
    // USD, so after a 50% loss a deposit that fitted before is half filled and half queued.
    function test_adjustTotalAssets_lossShrinksUsdCapacity() public {
        _deposit(alice, 1_000_000e6);
        _setCapacity(vault.totalSupply() + vault.convertToShares(500_000e6));
        uint256 headroomBefore = vault.convertToAssets(vault.availableCapacity());
        assertApproxEqAbs(headroomBefore, 500_000e6, 2);

        uint256 ta = vault.totalAssets();
        _adjustTotalAssetsWhilePaused(-int256(ta / 2));
        uint256 headroomAfter = vault.convertToAssets(vault.availableCapacity());
        assertApproxEqAbs(headroomAfter, 250_000e6, 2);

        uint256 id = _deposit(bob, 400_000e6);
        (, , uint256 queued) = _depositRequest(id);
        assertApproxEqAbs(spUsdc.convertToAssets(queued), 150_000e6, 3);
        assertApproxEqAbs(vault.assetsOf(bob), 250_000e6, 3);
        assertLe(vault.convertToAssets(vault.availableCapacity()), 2);
    }

    /**********************************************************************************************/
    /*** (c) Rebalancer and taker as adversaries                                               ***/
    /**********************************************************************************************/

    // TAKER takes everything (allowed while paused too), then the three queues: deposits still
    // fill (mint only, :852, now unbacked), redeems and cancellations are no-ops (budgets :903
    // and :870 read the vault's spUSDC), nothing reverts, nothing is lost from the queues.
    function test_taker_takeAll_thenThreeQueues() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 aShares = vault.balanceOf(alice);
        uint256 d1 = _deposit(bob, 100e6);
        uint256 d2 = _deposit(carol, 100e6);
        vm.prank(carol);
        vault.requestDepositCancellation(d2, carol);
        _requestRedeem(alice, aShares);
        (, , uint256 bQ) = _depositRequest(d1);

        _pause();
        _takeAll();                                              // works while paused
        _unpause();
        assertEq(_vaultSpUsdc(), 0);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(bob), vault.convertToShares(spUsdc.convertToAssets(bQ)));  // unbacked mint
        assertEq(vault.pendingDepositSavingsShares(), 0);

        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(vault.pendingRedeemShares(), aShares);
        assertEq(usdc.balanceOf(alice), 0);

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositCancellationId(), 0);
        assertEq(usdc.balanceOf(carol), 0);

        // Backing returns: both queues pay in full.
        _returnToVault(spUsdc.balanceOf(taker));
        _processRedeems(type(uint256).max, 10);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 999_999_998);
        assertEq(usdc.balanceOf(carol), 99_999_999);
    }

    // F-2 (open): deposit-queue / cancellation-queue spUSDC is not ring-fenced. After a take
    // that leaves only the cancelled depositor's backing, the rebalancer can pay a redeemer from
    // it (`availableLiquidAssets` :789 counts all spUSDC), and the refund is then unpayable.
    // The rebalancer chooses who gets paid under shortage.
    function test_BUG_F2_redeemsCanConsumeCancellationBacking_afterTake() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 aShares = vault.balanceOf(alice);
        uint256 bId = _deposit(bob, 1_000e6);
        (, , uint256 bQ) = _depositRequest(bId);
        vm.prank(bob);
        vault.requestDepositCancellation(bId, bob);

        _take(_vaultSpUsdc() - bQ);                              // only bob's refund backing is left
        assertEq(_vaultSpUsdc(), bQ);
        assertEq(vault.pendingCancelledDepositSavingsShares(), bQ);

        _requestRedeem(alice, aShares);
        uint256 snap = vm.snapshotState();

        // Order A: redeems first. Alice is paid from bob's backing; bob gets nothing.
        _processRedeems(type(uint256).max, 10);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 999_999_998);
        assertLe(usdc.balanceOf(bob), 1);                        // one dust share was left for him
        assertLe(_vaultSpUsdc(), 1);
        assertGe(vault.pendingCancelledDepositSavingsShares() + 1, bQ);   // unpayable now
        assertLe(vault.pendingRedeemShares(), 1);                         // budget floor

        // Order B: cancellations first. Bob is refunded; alice waits for the taker to return.
        vm.revertToState(snap);
        _processCancelledDeposits(type(uint256).max, 10);
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob), 999_999_999);
        assertLe(usdc.balanceOf(alice), 1);                      // dust left after the refund
        assertGe(vault.pendingRedeemShares() + 1, aShares);
    }

    // When the vault is fully backed, the rebalancer's ordering and chunking change no payout:
    // every path is priced by the indexes alone. Same end state in three orders.
    function test_rebalancer_orderingDoesNotChangePayouts_whenBacked() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 aShares = vault.balanceOf(alice);
        uint256 d1 = _deposit(bob, 300e6);
        uint256 d2 = _deposit(carol, 200e6);
        vm.prank(carol);
        vault.requestDepositCancellation(d2, carol);
        _requestRedeem(alice, aShares / 2);
        _setCapacity(type(uint128).max);
        (, , uint256 bQ) = _depositRequest(d1);

        uint256 expAlice = vault.convertToAssets(aShares / 2);
        uint256 expBob   = vault.convertToShares(spUsdc.convertToAssets(bQ));
        uint256 expCarol = 199_999_999;
        uint256 snap = vm.snapshotState();

        for (uint256 order; order < 3; ++order) {
            if (order != 0) vm.revertToState(snap);
            if (order == 0) {
                _processDeposits(type(uint256).max, 10);
                _processRedeems(type(uint256).max, 10);
                _processCancelledDeposits(type(uint256).max, 10);
            } else if (order == 1) {
                _processCancelledDeposits(type(uint256).max, 10);
                _processRedeems(type(uint256).max, 10);
                _processDeposits(type(uint256).max, 10);
            } else {
                _processRedeems(aShares / 4, 1);
                _processCancelledDeposits(1, 1);
                _processDeposits(bQ / 3, 1);
                _processRedeems(type(uint256).max, 10);
                _processCancelledDeposits(type(uint256).max, 10);
                _processDeposits(type(uint256).max, 10);
            }
            assertGe(usdc.balanceOf(alice) + 3, expAlice);       // chunking: at most 1 floor per partial
            assertLe(usdc.balanceOf(alice), expAlice);
            assertGe(vault.balanceOf(bob) + 3, expBob);
            assertLe(vault.balanceOf(bob), expBob);
            assertGe(usdc.balanceOf(carol) + 3, expCarol);
            assertLe(usdc.balanceOf(carol), expCarol);
        }
    }

    // C-1 re-examined: `_processPendingRedeems` budgets once by `convertToShares(maxWithdraw)`
    // (:903) and burns ceil per entry (:955/:952), so a batched call could in principle need more
    // spUSDC than held. It does not: a full fill burns at most the entry's own deposited shares
    // (deposit floors twice, :402/:845-846), and the partial tail is bounded by the live balance.
    // Searched: 8 odd-sized entries, vault backing from exact down to 400 shares short, the
    // batched call never reverts and chunked calls pay the same.
    function test_C1_batchedRedeemNeverRevertsAtOrBelowFullBacking() public {
        address[8] memory users;
        uint256[8] memory amts = [uint256(1_234_567), 987_654_321, 55_555_555, 3, 7_777_777, 1_000_001, 999_999_999, 42];
        for (uint256 i; i < 8; ++i) {
            users[i] = makeAddr(string(abi.encodePacked("u", i)));
            _deposit(users[i], amts[i]);
        }
        for (uint256 i; i < 8; ++i) _requestRedeem(users[i], vault.balanceOf(users[i]));

        // Search the spUSDC balances (full backing minus `cut` shares) for which the batched
        // call reverts.
        uint256 snap = vm.snapshotState();
        bool found;
        uint256 foundBal;
        for (uint256 cut = 0; cut <= 400 && !found; ++cut) {
            vm.revertToState(snap);
            if (cut != 0) _take(cut);                            // leave sp - cut
            uint256 bal = _vaultSpUsdc();
            vm.prank(rebalancer);
            (bool ok, ) = address(vault).call(
                abi.encodeCall(vault.processPendingRedeems, (type(uint256).max, 10))
            );
            if (!ok) { found = true; foundBal = bal; }
        }
        assertFalse(found, "batched call reverted");
        foundBal;

        // Exact backing: batched pays everyone; chunked pays the same.
        vm.revertToState(snap);
        _processRedeems(type(uint256).max, 10);
        uint256[8] memory paid;
        for (uint256 i; i < 8; ++i) paid[i] = usdc.balanceOf(users[i]);
        assertEq(vault.firstPendingRedeemId(), 8);
        uint256 surplus = _vaultSpUsdc();
        emit log_named_uint("spUSDC surplus left after paying all 8 (shares)", surplus);
        assertLe(surplus, 16);                                   // <= 2 floors per deposit

        vm.revertToState(snap);
        for (uint256 i; i < 8; ++i) _processRedeems(type(uint256).max, 1);
        for (uint256 i; i < 8; ++i) assertEq(usdc.balanceOf(users[i]), paid[i]);
        emit log_named_uint("entries fully paid, chunked", vault.firstPendingRedeemId());
        emit log_named_uint("shares left unpaid", vault.pendingRedeemShares());
    }

    /**********************************************************************************************/
    /*** (e) Two-index conversion at extreme rates                                              ***/
    /**********************************************************************************************/

    // spUSDC chi ~1.07e30 (10 years at 100% APY) and spPRIME chi ~1e15 (near-wipe): a 1 USDC
    // deposit mints ~1e18 shares; the round trip loses at most chiS/RAY + chiP/RAY + 4 wei
    // (here: 1_074 wei), never profits, and the vault's spUSDC never goes below its backing.
    function test_extremes_spUsdcChiHuge_primeChiTiny_roundTripBounded() public {
        _deposit(alice, 1_000_000e6);
        _setSpUsdcVsr(MAX_VSR);
        _warp(10 * 365 days);
        _setSpUsdcVsr(RAY);
        uint256 chiS = spUsdc.nowChi();
        assertGt(chiS, 1e30);

        uint256 ta = vault.totalAssets();
        _adjustTotalAssetsWhilePaused(-(int256(ta) - 1));
        uint256 chiP = vault.nowChi();
        assertLt(chiP, 1e16);

        uint256 sp0 = _vaultSpUsdc();
        _deposit(bob, 1e6);
        uint256 shares = vault.balanceOf(bob);
        assertGt(shares, 1e17);
        uint256 ss = spUsdc.convertToShares(1e6);
        assertEq(_vaultSpUsdc() - sp0, ss);
        emit log_named_uint("spUSDC chi", chiS);
        emit log_named_uint("spPRIME chi", chiP);
        emit log_named_uint("shares minted for 1 USDC", shares);

        _requestRedeem(bob, shares);
        _processRedeems(type(uint256).max, 1);
        uint256 out = usdc.balanceOf(bob);
        assertLe(out, 1e6);
        assertGe(out + chiS / RAY + chiP / RAY + 4, 1e6);
        emit log_named_uint("round-trip loss (wei)", 1e6 - out);
        assertGe(_vaultSpUsdc(), sp0);                           // bob never took alice's backing
    }

    // F-4 (open): after a large gain chi is huge and `convertToShares` (:797) floors to 0 for
    // deposits below chi / RAY wei. The entry is filled, deleted, 0 shares minted, and the USDC
    // becomes vault equity. Exact threshold at chi = 2e33 (2M x): 1 USDC mints 0, 3 USDC mints 1.
    function test_BUG_F4_zeroShareMint_exactThreshold() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply = vault.totalSupply();
        uint256 ta = vault.totalAssets();
        uint256 target = 2e33 * supply / RAY;                    // totalAssets giving chi = 2e33
        _adjustTotalAssetsWhilePaused(int256(target - ta));
        uint256 chiP = vault.nowChi();
        assertApproxEqRel(chiP, 2e33, 1e9);

        uint256 sp0 = _vaultSpUsdc();
        uint256 supply0 = vault.totalSupply();
        _deposit(bob, 1e6);                                      // below chi / RAY = 2e6 wei
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.totalSupply(), supply0);
        assertEq(vault.pendingDepositSavingsShares(), 0);        // entry filled and deleted
        assertEq(vault.firstPendingDepositId(), 2);
        assertEq(_vaultSpUsdc() - sp0, spUsdc.convertToShares(1e6));   // USDC is now equity
        assertEq(usdc.balanceOf(bob), 0);

        _deposit(carol, 3e6);
        assertEq(vault.balanceOf(carol), 1);
        assertEq(vault.assetsOf(carol), chiP / RAY);
        emit log_named_uint("1 share is worth (USDC wei)", chiP / RAY);
        emit log_named_uint("carol lost to flooring (USDC wei)", 3e6 - chiP / RAY);
    }

    // No fee-free exit from spPRIME exists: moving shares to a fresh address changes nothing (fee
    // is taken at `requestRedeem` :460 for any owner). The cancellation queue is fee-free but
    // never minted shares: the refund is `spUSDC.redeem` at the live spUSDC index (:939), so a
    // queued-then-cancelled deposit earns the spUSDC rate (not spPRIME's) with no fee and no
    // capacity. Exact: 1_000 in, 1_099.999998 out after a year at 10% spUSDC VSR.
    function test_extremes_noFeeFreeExit_cancelQueueEarnsSpUsdcRate() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(attacker, 1_000e6);
        uint256 shares = vault.balanceOf(attacker);
        _setPrimeVsr(TEN_PCT_VSR);
        _setSpUsdcVsr(TEN_PCT_VSR);                              // backing accrues too
        _warpAndDrip(365 days);
        _returnSpUsdcLiquidity(200e6);                           // and spUSDC has the USDC
        uint256 value = vault.assetsOf(attacker);
        assertGt(value, 1_099e6);

        vm.prank(attacker);
        vault.transfer(clean, shares);
        vm.prank(clean);
        vault.requestRedeem(shares, clean);
        _processRedeems(type(uint256).max, 1);
        uint256 fee = (shares * 0.01e18 - 1) / WAD + 1;
        assertEq(usdc.balanceOf(clean), vault.convertToAssets(shares - fee));
        assertLt(usdc.balanceOf(clean), value - 10e6);           // paid 1% on the yield too

        _fillCapacityExactly(alice, 1e6);
        uint256 id = _deposit(attacker, 1_000e6);
        vm.prank(attacker);
        vault.requestDepositCancellation(id, attacker);
        _warpAndDrip(365 days);
        _returnSpUsdcLiquidity(200e6);
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(attacker), 1_099_999_998);       // spUSDC yield passed through, no fee
        assertEq(vault.balanceOf(attacker), 0);                  // never held spPRIME
    }

    /**********************************************************************************************/
    /*** (f) ERC20: the escrow cannot be spent                                                  ***/
    /**********************************************************************************************/

    // `allowance[vault][x]` is only written by `approve` (msg.sender) and `permit` (owner). The
    // vault never calls `approve` on itself; `permit(vault, ..)` needs a signature from an address
    // with no key (ecrecover) or an ERC-1271 answer from the vault, whose staticcall fails (no
    // `isValidSignature`, no fallback :1030-1037). So `transferFrom(vault, ..)` always reverts.
    function test_erc20_escrowCannotBeSpentViaTransferFromOrPermit() public {
        _deposit(alice, 1_000e6);
        uint256 shares = vault.balanceOf(alice);
        _requestRedeem(alice, shares);
        assertEq(vault.balanceOf(address(vault)), shares);

        assertEq(vault.allowance(address(vault), attacker), 0);
        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/insufficient-allowance");
        vault.transferFrom(address(vault), attacker, 1);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig65 = new bytes(65);
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(address(vault), attacker, shares, deadline, sig65);
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(address(vault), attacker, shares, deadline, hex"01");
        assertEq(vault.nonces(address(vault)), 0);
        assertEq(vault.allowance(address(vault), attacker), 0);

        // The staticcall itself: the vault has no isValidSignature and no fallback.
        (bool ok, bytes memory ret) = address(vault).staticcall(
            abi.encodeWithSignature("isValidSignature(bytes32,bytes)", bytes32(0), hex"01")
        );
        assertFalse(ok);
        assertEq(ret.length, 0);

        // Even the vault "itself" as msg.sender would need an allowance: from == msg.sender
        // skips the allowance check, but no code path makes the vault call transferFrom.
        vm.prank(address(vault));
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transferFrom(address(vault), address(vault), 1);
    }

    /**********************************************************************************************/
    /*** (g) External-call ordering (CEI)                                                       ***/
    /**********************************************************************************************/

    // Where external calls precede state writes, a revert in the callee leaves no partial state:
    //  - requestDeposit: transferFrom and spUSDC.deposit (:400-402) run before the push (:406);
    //    a spUSDC cap hit leaves no entry and no USDC in the vault.
    //  - payout fallback: spUSDC.withdraw/redeem (:955/:942) runs before the claimable credit
    //    (:957/:944); a liquidity shortfall credits nothing.
    //  - claim: credit is zeroed before the transfer (:529-533); a USDC revert restores it.
    function test_cei_externalCallBeforeStateWrite_revertsLeaveNoPartialState() public {
        _deposit(alice, 1_000e6);
        uint256 len0 = _depositQueueLength();
        uint256 spCap = spUsdc.totalAssets() + 1e6;
        vm.prank(spAdmin);
        spUsdc.setDepositCap(spCap);
        _fund(bob, 2e6);
        vm.prank(bob);
        vm.expectRevert("SparkVault/deposit-cap-exceeded");
        vault.requestDeposit(2e6, bob, 0);
        assertEq(_depositQueueLength(), len0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(bob), 2e6);
        vm.prank(spAdmin);
        spUsdc.setDepositCap(type(uint256).max);

        // Fallback payout with spUSDC illiquid: withdraw reverts, nothing credited.
        _deposit(victim, 100e6);
        uint256 vShares = vault.balanceOf(victim);
        _requestRedeem(victim, vShares);
        _blacklist(victim);
        uint256 liq = usdc.balanceOf(address(spUsdc));
        _drainSpUsdcLiquidity(liq - 1);                          // 1 wei left: budget is 0 shares
        _processRedeems(type(uint256).max, 10);                  // budget 0: loop does not run
        assertEq(vault.claimableAssets(victim), 0);
        assertEq(vault.firstPendingRedeemId(), 0);
        _returnSpUsdcLiquidity(liq);
        _processRedeems(type(uint256).max, 10);
        uint256 owed = vault.convertToAssets(vShares);
        assertEq(vault.claimableAssets(victim), owed);
        assertEq(owed, 99_999_998);

        // claim: revert in USDC restores the credit.
        vm.expectRevert(BLACKLISTED);
        vault.claim(victim);
        assertEq(vault.claimableAssets(victim), owed);
        _unblacklist(victim);
        assertEq(vault.claim(victim), owed);
    }

    /**********************************************************************************************/
    /*** (h) Pause matrix                                                                       ***/
    /**********************************************************************************************/

    // What still works while paused: drip, take, claim, transfer/approve/permit, setVSR, the
    // three updaters, adjustTotalAssets; what does not: the three requests and the three
    // process* calls. `take` during an incident is the only one worth a note.
    function test_pause_matrix() public {
        _fillCapacityExactly(carol, 1_000e6);
        uint256 dId = _deposit(alice, 100e6);
        uint256 dId2 = _deposit(alice, 100e6);
        _setCapacity(type(uint128).max);
        uint256 cShares = vault.balanceOf(carol);
        vm.prank(alice);
        uint256 cId = vault.requestDepositCancellation(dId2, alice);
        vm.prank(carol);
        vault.requestRedeem(cShares / 4, victim);                 // a claimable credit for victim
        _blacklist(victim);
        _processRedeems(type(uint256).max, 10);
        assertGt(vault.claimableAssets(victim), 0);
        _unblacklist(victim);
        uint256 rId = _requestRedeem(carol, cShares / 2);

        _pause();

        // Blocked.
        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(1e6, bob, 0);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDepositCancellation(dId, alice);
        vm.prank(carol);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestRedeem(1, carol);
        vm.startPrank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processPendingDeposits(1, 1);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processPendingRedeems(1, 1);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processPendingDepositCancellations(1, 1);
        vm.stopPrank();

        // Allowed.
        _warp(1);
        vault.drip();
        vault.claim(victim);
        vm.prank(carol);
        vault.transfer(bob, 1);
        vm.prank(carol);
        vault.approve(bob, 1);
        vm.startPrank(alice);
        vault.updateDepositRecipient(dId, clean);
        vault.updateDepositCancellationRecipient(cId, clean);
        vm.stopPrank();
        vm.prank(carol);
        vault.updateRedeemRecipient(rId, clean);
        _setPrimeVsr(ONE_PCT_VSR);
        _adjustTotalAssets(1);
        _take(1);
        assertEq(spUsdc.balanceOf(taker), 1);
        assertTrue(vault.paused());
    }

}
