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
            uint256 id = vault.requestDeposit(have, alice);

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
            vault.requestDeposit(have, alice);
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
        uint256 jamId = vault.requestDeposit(2, attacker);

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
        vault.requestDeposit(2, attacker);

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
        uint256 id = vault.requestDeposit(1, attacker);

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
        vault.requestDeposit(10, attacker);
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
        vault.requestDeposit(2, attacker);
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

    // requestDeposit(x, recipient = vault) mints spPRIME to the vault. Nobody can ever burn or
    // move them, they count in totalSupply forever and permanently consume capacity.
    function test_escrow_depositRecipientVaultPermanentlyConsumesCapacity() public {
        _setCapacity(1_000_000e6);

        _fund(attacker, 100_000e6);
        vm.prank(attacker);
        vault.requestDeposit(100_000e6, address(vault));

        uint256 phantom = vault.balanceOf(address(vault));
        assertEq(phantom, vault.convertToShares(spUsdc.convertToAssets(spUsdc.convertToShares(100_000e6))));
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.totalSupply(), phantom);
        assertEq(vault.availableCapacity(), 1_000_000e6 - phantom);

        // No path burns them: redeem queue is empty, so _processPendingRedeems does nothing.
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.balanceOf(address(vault)), phantom);

        vm.expectRevert();  // empty queue: index out of bounds
        vault.cancelRedeemRequest(0, attacker);

        // 100 years later they are still there and still inside totalSupply.
        _warpAndDrip(100 * 365 days);
        assertEq(vault.balanceOf(address(vault)), phantom);
        assertEq(vault.totalSupply(), phantom);

        // Attacker lost everything; backing spUSDC stays in the vault as equity (takeable).
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(vault.balanceOf(attacker), 0);
        assertEq(_vaultSpUsdc(), spUsdc.convertToShares(100_000e6));
    }

    // requestRedeem(x, recipient = vault): the fill sends USDC to the vault, where nothing can
    // use it (availableLiquidAssets only counts spUSDC).
    function test_escrow_redeemRecipientVaultStrandsUsdcInVault() public {
        _deposit(attacker, 100_000e6);
        uint256 shares = vault.balanceOf(attacker);

        vm.prank(attacker);
        vault.requestRedeem(shares, address(vault));

        uint256 liquidBefore = vault.availableLiquidAssets();
        _processRedeems(type(uint256).max, 1);

        uint256 expected = vault.convertToAssets(shares);
        assertEq(usdc.balanceOf(address(vault)), expected);
        assertEq(usdc.balanceOf(attacker), 0);
        assertApproxEqAbs(vault.availableLiquidAssets(), liquidBefore - expected, 2);  // USDC not counted

        // Not takeable either (take moves spUSDC only).
        uint256 sp = _vaultSpUsdc();
        vm.prank(taker);
        vault.take(sp);
        assertEq(usdc.balanceOf(address(vault)), expected);
    }

    // Phantom shares in the vault's balance can never be burned through the redeem queue: the
    // loop burns at most `request.shares`, which is bounded by pendingRedeemShares.
    function test_escrow_phantomSharesCannotBeBurnedByRedeemQueue() public {
        _fund(attacker, 10_000e6);
        vm.prank(attacker);
        vault.requestDeposit(10_000e6, address(vault));
        uint256 phantom = vault.balanceOf(address(vault));

        _deposit(alice, 50_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        _requestRedeem(alice, aliceShares);

        assertEq(vault.balanceOf(address(vault)), phantom + aliceShares);
        assertEq(vault.pendingRedeemShares(), aliceShares);

        _processRedeems(type(uint256).max, 10);

        assertEq(vault.balanceOf(address(vault)), phantom);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.totalSupply(), phantom);
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
        vm.prank(setter);
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
        for (uint256 i; i < 50; ++i) vault.requestDeposit(0, attacker);
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
        vault.requestDeposit(0, attacker);
        uint256 ghostCost = g0 - gasleft();
        for (uint256 i; i < 1999; ++i) vault.requestDeposit(0, attacker);
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
        vault.requestDeposit(0, attacker);

        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(1e6 - 1, attacker);

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

        // A ghost cannot be cancelled (no-request), so it stays a ghost forever.
        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(0, attacker);
    }

    // Without capacity (deposits) or liquidity (redeems) the head cannot move past ghosts,
    // but then nothing could be processed anyway.
    function test_griefing_headDoesNotAdvanceWithoutCapacityOrLiquidity() public {
        _fillCapacityExactly(alice, 1_000e6);
        _deposit(bob, 1e6);
        vm.startPrank(attacker);
        for (uint256 i; i < 10; ++i) vault.requestDeposit(0, attacker);
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

    function test_realizeLoss_notPaused() public {
        _deposit(alice, 1e6);
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/not-paused");
        vault.realizeLoss(1);
    }

    // pause() is GUARDIAN_ROLE (restored upstream); a hot-wallet role cannot pause or unpause.
    function test_pause_hotWalletRolesCannot() public {
        address[3] memory who = [rebalancer, riskManager, setter];
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

        vm.prank(unpauser);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", unpauser, DEFAULT_ADMIN_ROLE
        ));
        vault.unpause();

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
        bytes32[3] memory roles = [REBALANCER_ROLE, RISK_MANAGER_ROLE, SETTER_ROLE];
        address[3] memory who   = [rebalancer, riskManager, setter];
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
        vault.requestDeposit(100e6, address(rec));          // instant mint to contract
        vault.requestDeposit(100e6, alice);
        vault.requestRedeem(vault.balanceOf(alice), address(rec));
        vm.stopPrank();
        assertEq(rec.calls(), 0);

        _processRedeems(type(uint256).max, 10);
        assertEq(rec.calls(), 0);
        assertGt(usdc.balanceOf(address(rec)), 0);

        _fillCapacityExactly(bob, 1e6);
        vm.startPrank(alice);
        uint256 id = vault.requestDeposit(100e6, address(rec));   // queued
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

        vm.prank(setter);
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
        vm.prank(setter);
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

    // RISK_MANAGER: fee bounded by maxRedeemFee (admin). Worst case every exit loses 1%.
    function test_compromised_riskManager_maxFeeOnEveryExit() public {
        vm.prank(riskManager);
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

        // Admin can cap it harder: setMaxRedeemFeeRate(0) then the RM cannot charge anything.
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0);
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFeeRate(1);
        // Existing fee is NOT reset by lowering the max.
        assertEq(vault.redeemFeeRate(), 0.01e18);
    }

    // RISK_MANAGER while paused (guardian paused for an unrelated reason): realizeLoss still has
    // no floor below `loss < totalAssets`. `loss = totalAssets - 1` wipes every holder in one
    // call (C-3 persists); only the exact full loss is now rejected.
    function test_compromised_riskManager_realizeLossWipesHolders() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply = vault.totalSupply();
        assertGt(vault.assetsOf(alice), 999_999e6);

        _pause();

        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(0);

        uint256 ta = vault.totalAssets();
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(ta);                                // chi == 0 is unreachable now

        _realizeLoss(ta - 1);

        // chi = (totalAssets - loss) * RAY / totalSupply = 1 * RAY / totalSupply.
        assertEq(vault.chi(), RAY / supply);
        assertEq(vault.assetsOf(alice), 0);
        assertEq(vault.totalAssets(), 0);

        // Admin cannot restore via VSR: accrual from dust takes forever. (realizeGain can, see
        // section 15: that is the only repair path.)
        _unpause();
        _setPrimeVsr(MAX_VSR);
        _warpAndDrip(10 * 365 days);
        assertLt(vault.assetsOf(alice), 2_000);                // 1_023 wei after a decade at 100%

        // Backing is untouched: all spUSDC is now vault equity, takeable.
        assertApproxEqAbs(spUsdc.convertToAssets(_vaultSpUsdc()), 1_000_000e6, 1);
    }

    // Regression for round-2 R2-3: the full loss is rejected with a clean revert, chi never
    // reaches 0, and after the near-wipe the vault keeps working (no panics anywhere): deposits
    // fill, redeems process (paying ~0), realizeLoss(1) reverts cleanly because totalAssets is 0.
    function test_compromised_riskManager_fullLossRejected_nearWipeStillOperates() public {
        _deposit(alice, 1_000_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        _pause();

        uint256 ta = vault.totalAssets();
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(ta);
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(ta + 1);

        _realizeLoss(ta - 1);                                 // the worst reachable state
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

        // After the near-wipe, with totalSupply > 0 and totalAssets > 0 again, realizeLoss works.
        _pause();
        uint256 ta2 = vault.totalAssets();
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(ta2);
        _realizeLoss(1);
        _unpause();

        _takeAll();                                           // the backing is still takeable
        assertEq(_vaultSpUsdc(), 0);
    }

    // realizeLoss bounds are designed checks now: `0 < loss < totalAssets` is `invalid-loss`.
    // With totalSupply == 0, totalAssets is 0 so `invalid-loss` fires before `no-shares`: the
    // `no-shares` branch is unreachable through realizeLoss (it is reachable in realizeGain).
    function test_compromised_riskManager_realizeLossBoundsAreChecks() public {
        _pause();
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(1);                                 // totalSupply == 0, totalAssets 0
        _unpause();

        _deposit(alice, 1_000_000e6);
        _pause();
        uint256 ta = vault.totalAssets();
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(ta + 1);
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(ta);
        _realizeLoss(ta - 1);
        assertEq(vault.totalAssets(), 0);
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");      // totalAssets is 0 now: nothing left
        vault.realizeLoss(1);
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
                uint256 n = _redeemQueueLength();
                if (n > 0) {
                    uint256 id = (r >> 48) % n;
                    (address o, , uint256 s) = _redeemRequest(id);
                    if (s != 0 && o == u) { vm.prank(u); vault.cancelRedeemRequest(id, u); }
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

    // A redeem whose recipient cannot receive USDC (Circle blacklist on mainnet USDC) makes
    // processPendingRedeems revert whenever the loop reaches that entry: the FIFO queue is blocked
    // for everyone behind it until a guardian cancels the entry. The owner gets the shares back
    // on cancel, so the attacker's only cost is gas, and they can resubmit immediately.
    function test_BUG_blacklistedRecipientBlocksRedeemQueue() public {
        address blacklisted = makeAddr("blacklisted");
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(usdc.transfer.selector, blacklisted),
            "Blacklistable: account is blacklisted"
        );

        _deposit(attacker, 1e6);
        _deposit(alice, 1_000_000e6);

        // Attacker queues 1 share to the blacklisted recipient, alice queues behind.
        vm.prank(attacker);
        uint256 jamId = vault.requestRedeem(1, blacklisted);
        _requestRedeem(alice, vault.balanceOf(alice));

        vm.prank(rebalancer);
        vm.expectRevert("Blacklistable: account is blacklisted");
        vault.processPendingRedeems(type(uint256).max, 10);

        // No way to skip: maxShares/maxRequests cannot jump over the head entry.
        vm.prank(rebalancer);
        vm.expectRevert("Blacklistable: account is blacklisted");
        vault.processPendingRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.firstPendingRedeemId(), 0);

        // Guardian cancel (refunding the owner) unblocks; attacker gets the share back and can
        // re-jam for gas only.
        vm.prank(guardian);
        vault.cancelRedeemRequest(jamId, attacker);
        assertEq(vault.balanceOf(attacker), vault.convertToShares(spUsdc.convertToAssets(spUsdc.convertToShares(1e6))));

        vm.prank(attacker);
        vault.requestRedeem(1, blacklisted);   // id 2, behind alice now: alice can be paid

        assertEq(vault.firstPendingRedeemId(), 1);       // cancel walked the head past id 0
        _processRedeems(type(uint256).max, 1); // pays alice (id 1)
        assertGt(usdc.balanceOf(alice), 999_990e6);

        // ...but the next honest redeemer (bob) is stuck behind the new jam again.
        _deposit(bob, 10e6);
        _requestRedeem(bob, vault.balanceOf(bob));
        vm.prank(rebalancer);
        vm.expectRevert("Blacklistable: account is blacklisted");
        vault.processPendingRedeems(type(uint256).max, 10);
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
        vault.requestDeposit(101e6, bob);

        vm.prank(bob);
        vault.requestDeposit(100e6, bob);
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
        uint256 d = vault.requestDeposit(2, attacker);
        vault.requestDepositCancellation(d, attacker);
        uint256 perDust = g0 - gasleft();
        for (uint256 i; i < 499; ++i) {
            d = vault.requestDeposit(2, attacker);
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
        vault.requestDeposit(have, attacker);                 // queued behind victim (pending != 0)

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

    // Regression for round-2 R2-2 (zero-cost queue block): a stranger cannot repoint alice's
    // redeem to a blacklisted address, so the queue stays unblockable by third parties. The
    // owner-side version (alice blacklists herself) is the round-1 A-1 self-harm and persists:
    // bob is stuck until the guardian cancels alice, who loses her fee.
    function test_updateRecipient_strangerCannotBlacklistBlockQueue_ownerStillCan() public {
        address blacklisted = makeAddr("blacklisted");
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(usdc.transfer.selector, blacklisted),
            "Blacklistable: account is blacklisted"
        );
        _setRedeemFeeRate(0.01e18);

        _deposit(alice, 1_000_000e6);
        _deposit(bob, 10_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 aId = _requestRedeem(alice, aliceShares);
        _requestRedeem(bob, vault.balanceOf(bob));

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateRedeemRecipient(aId, blacklisted);

        // Both paid; nothing a stranger did mattered.
        _processRedeems(type(uint256).max, 10);
        assertGt(usdc.balanceOf(alice), 989_000e6);
        assertGt(usdc.balanceOf(bob), 9_800e6);

        // Owner-side self-harm (round-1 A-1): alice repoints her own new redeem to the
        // blacklisted address; bob, behind her, is stuck until the guardian cancels alice.
        _deposit(alice, 100_000e6);
        _deposit(bob, 10_000e6);
        uint256 a2 = vault.balanceOf(alice);
        uint256 aId2 = _requestRedeem(alice, a2);
        _requestRedeem(bob, vault.balanceOf(bob));
        vm.prank(alice);
        vault.updateRedeemRecipient(aId2, blacklisted);

        vm.prank(rebalancer);
        vm.expectRevert("Blacklistable: account is blacklisted");
        vault.processPendingRedeems(type(uint256).max, 10);

        vm.prank(guardian);
        vault.cancelRedeemRequest(aId2, alice);
        uint256 fee = (a2 * 0.01e18 - 1) / WAD + 1;
        assertEq(vault.balanceOf(alice), a2 - fee);            // alice paid the fee for nothing
        uint256 bobBefore = usdc.balanceOf(bob);
        _processRedeems(type(uint256).max, 10);
        assertGt(usdc.balanceOf(bob) - bobBefore, 9_800e6);
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

    // Regression for round-2 R2-2 (dead capacity): only the owner can mint their own queued
    // deposit to the vault as phantom shares (round-1 self-harm persists).
    function test_updateRecipient_onlyOwnerCanBurnOwnDepositIntoDeadCapacity() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 id = _deposit(victim, 100_000e6);
        (, , uint256 queued) = _depositRequest(id);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositRecipient(id, address(vault));

        vm.prank(victim);
        vault.updateDepositRecipient(id, address(vault));

        _setCapacity(1_000_000e6);
        _processDeposits(type(uint256).max, 1);

        uint256 phantom = vault.convertToShares(spUsdc.convertToAssets(queued));
        assertEq(vault.balanceOf(address(vault)), phantom);
        assertEq(vault.balanceOf(victim), 0);
        assertEq(vault.pendingRedeemShares(), 0);
        _processRedeems(type(uint256).max, 10);
        _warpAndDrip(100 * 365 days);
        assertEq(vault.balanceOf(address(vault)), phantom);
        assertEq(vault.availableCapacity(), 1_000_000e6 - vault.totalSupply());
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
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
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
        vault.requestDeposit(2, attacker);                     // id 1: 1 share, open, at head
        for (uint256 i; i < 1000; ++i) vault.requestDeposit(0, attacker);   // ids 2..1001
        vm.stopPrank();
        assertEq(vault.firstPendingDepositId(), 1);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);                // closes id 1 only
        assertEq(vault.firstPendingDepositId(), 2);                      // head on the first ghost

        // Baseline: an instant deposit with nothing to walk (fresh vault state is similar).
        _fund(victim, 20e6);
        vm.prank(victim);
        uint256 g0 = gasleft();
        vault.requestDeposit(10e6, victim);
        uint256 walked = g0 - gasleft();
        assertEq(vault.firstPendingDepositId(), 1003);                   // walked 1000 ghosts, filled self
        assertGt(vault.balanceOf(victim), 0);

        vm.prank(victim);
        uint256 g1 = gasleft();
        vault.requestDeposit(10e6, victim);
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

    // When the head already sits on zero entries, every new ghost walks the ones before it, so
    // the attacker pays the walk incrementally and a later victim pays one step. Same-block
    // front-running with ghosts cannot inflate the victim's walk.
    function test_griefing_ghostsWalkThemselvesWhenHeadIsOnZeroEntries() public {
        _fillCapacityExactly(alice, 1_000e6);                  // capacity 0: no instant fills
        assertEq(vault.firstPendingDepositId(), 1);

        vm.startPrank(attacker);
        for (uint256 i; i < 300; ++i) vault.requestDeposit(0, attacker);   // ids 1..300
        vm.stopPrank();
        assertEq(vault.firstPendingDepositId(), 300);                    // each ghost walked the previous

        _fund(victim, 1e6);
        vm.prank(victim);
        uint256 g0 = gasleft();
        vault.requestDeposit(1e6, victim);                     // id 301: walks only id 300
        uint256 gas = g0 - gasleft();
        assertEq(vault.firstPendingDepositId(), 301);
        emit log_named_uint("victim requestDeposit gas behind 300 self-walked ghosts", gas);
        assertLt(gas, 300_000);
    }

    // An owner whose entry sits at the head pays the walk over every ghost behind it when
    // cancelling (cancel walks to the next open entry or the end of the queue).
    function test_griefing_ownerCancelAtHeadPaysWalkOverGhosts() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 vId = _deposit(victim, 100e6);                 // id 1, head
        vm.startPrank(attacker);
        for (uint256 i; i < 1000; ++i) vault.requestDeposit(0, attacker);
        vm.stopPrank();

        vm.prank(victim);
        uint256 g0 = gasleft();
        vault.requestDepositCancellation(vId, victim);
        uint256 gas = g0 - gasleft();
        assertEq(vault.firstPendingDepositId(), 1002);
        emit log_named_uint("victim cancel gas with 1000 ghosts behind (warm)", gas);
        assertLt(gas, 1_500_000);

        // The same holds for the redeem queue with free requestRedeem(0) ghosts.
        _setCapacity(type(uint128).max);
        _deposit(bob, 100e6);
        uint256 rId = _requestRedeem(bob, vault.balanceOf(bob));
        vm.startPrank(attacker);
        for (uint256 i; i < 1000; ++i) vault.requestRedeem(0, attacker);
        vm.stopPrank();
        vm.prank(bob);
        uint256 g1 = gasleft();
        vault.cancelRedeemRequest(rId, bob);
        uint256 gasR = g1 - gasleft();
        assertEq(vault.firstPendingRedeemId(), 1001);
        emit log_named_uint("bob cancelRedeem gas with 1000 ghosts behind (warm)", gasR);
        assertLt(gasR, 1_500_000);
    }

    /**********************************************************************************************/
    /*** 15. realizeGain (round 3)                                                               ***/
    /**********************************************************************************************/

    event GainRealized(uint192 chi, uint256 gain);

    // Runs the gain sandwich: alice holds `tvl`, the admin broadcasts realizeGain(gain) (and the
    // gain's backing arrives as spUSDC), the attacker front-runs with an instant deposit of
    // `capital` and exits through the redeem queue at `fee`. With `pauseFirst` the guardian pauses
    // before the admin's call (deposits revert) and the admin unpauses after it.
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
        vault.requestDeposit(capital, attacker);               // front-run, instant path

        _returnToVault(spUsdc.convertToShares(gain));          // the gain is real backing
        vm.prank(admin);
        vault.realizeGain(gain);

        if (pauseFirst) _unpause();

        uint256 sh = vault.balanceOf(attacker);
        if (sh != 0) {
            _requestRedeem(attacker, sh);
            _processRedeems(type(uint256).max, 1);             // honest planner pays FIFO
        }
        attackerOut = usdc.balanceOf(attacker);
        aliceAssets = vault.assetsOf(alice);
    }

    // (a) The sandwich. realizeGain spreads `gain` over whoever holds shares at that block, and
    // the instant deposit path has no entry delay or fee, so an attacker who front-runs the
    // admin's transaction with capital equal to the TVL takes half the gain from the honest
    // holders and leaves through the redeem queue. Exact numbers for 1M TVL, 50k gain.
    function test_BUG_realizeGain_sandwichExtractsFromHolders() public {
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
    function test_BUG_realizeGain_sandwichSurvivesOnePercentFee() public {
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
    function test_BUG_realizeGain_sandwichTakeScalesWithCapital_1MvsTVL10M() public {
        (uint256 out, , ) = _runGainSandwich(10_000_000e6, 1_000_000e6, 50_000e6, 0, false);
        uint256 profit = out - 1_000_000e6;
        emit log_named_uint("profit, 1M capital vs 10M TVL", profit);
        assertEq(profit, 4_545_454_544);                       // 50_000 / 11, less rounding
        assertApproxEqAbs(profit, uint256(50_000e6) / 11, 2);  // take = gain * c / (tvl + c)
    }

    function test_BUG_realizeGain_sandwichTakeScalesWithCapital_10MvsTVL10M() public {
        (uint256 out, , ) = _runGainSandwich(10_000_000e6, 10_000_000e6, 50_000e6, 0, false);
        uint256 profit = out - 10_000_000e6;
        emit log_named_uint("profit, 10M capital vs 10M TVL", profit);
        assertEq(profit, 24_999_999_998);
        assertApproxEqAbs(profit, uint256(50_000e6) / 2, 2);
    }

    // (a) Mitigation: pausing before realizeGain closes the instant deposit path, so the
    // attacker's front-run reverts and the whole gain goes to the existing holders.
    function test_realizeGain_pauseBeforeGainKillsSandwich() public {
        (uint256 out, uint256 aliceAssets, uint256 aliceFair) =
            _runGainSandwich(1_000_000e6, 1_000_000e6, 50_000e6, 0, true);

        assertEq(out, 1_000_000e6);                            // never got in: USDC untouched
        assertEq(vault.balanceOf(attacker), 0);
        assertApproxEqAbs(aliceAssets, aliceFair, 1);          // alice receives the full gain
        assertEq(aliceAssets, 1_049_999_999_997);

        // Ordering matters: realizeGain while paused, then unpause. A deposit after the unpause
        // is priced at the new chi and earns nothing from the gain.
        _deposit(attacker, 1_000_000e6);
        assertApproxEqAbs(vault.assetsOf(attacker), 1_000_000e6, 2);
    }

    // (a) Queued variant: if the attacker's deposit cannot fill instantly (capacity full), it is
    // priced at the post-gain chi when the planner fills it, so there is no profit to take.
    function test_realizeGain_queuedDepositFilledAfterGainGetsNoProfit() public {
        _fillCapacityExactly(alice, 1_000_000e6);
        uint256 aliceFair = vault.assetsOf(alice) + 50_000e6;

        uint256 id = _deposit(attacker, 1_000_000e6);         // queued, 0 shares
        assertEq(vault.balanceOf(attacker), 0);

        _returnToVault(spUsdc.convertToShares(50_000e6));
        vm.prank(admin);
        vault.realizeGain(50_000e6);

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
    function test_realizeGain_escrowedRedeemersReceiveGain_cancelledDepositsDoNot() public {
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
        vm.prank(admin);
        vault.realizeGain(50_000e6);                           // totalSupply == escrow only

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
    //    full from backing, the last is short (same shape as the SETTER over-credit).
    //  - gain pushing chi above 2^256 / RAY: `_rpow(vsr, dt) * chi` in drip() overflows one
    //    second later, every entry point drips, so the vault is bricked (pause/unpause do not
    //    drip but realizeLoss does; only an upgrade repairs it). NEWSURFACE owns the thresholds.
    function test_compromised_admin_realizeGainOverCreditIsInsolvency() public {
        _deposit(alice, 1_000_000e6);
        _deposit(bob, 1_000_000e6);
        uint256 backing = spUsdc.convertToAssets(_vaultSpUsdc());

        // Over-credit: 1_000_000 USDC "gain" with no backing behind it.
        vm.prank(admin);
        vault.realizeGain(1_000_000e6);
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

    // Brick: a gain of ~1.2e35 units puts chi above 2^256 / RAY; one second later every drip
    // overflows.
    function test_compromised_admin_realizeGainCanBrickViaDripOverflow() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply = vault.totalSupply();
        uint256 gain   = (type(uint256).max / RAY) * supply / RAY;  // chi lands just above
        vm.prank(admin);
        vault.realizeGain(gain);
        assertGt(uint256(vault.chi()), type(uint256).max / RAY);
        emit log_named_uint("bricking gain (USDC units)", gain);

        bytes memory overflow = abi.encodeWithSelector(bytes4(keccak256("Panic(uint256)")), 0x11);
        _warp(1);
        vm.expectRevert(overflow);
        vault.drip();
        vm.expectRevert(overflow);
        vault.nowChi();
        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(overflow);
        vault.requestDeposit(1e6, bob);
        vm.prank(admin);
        vm.expectRevert(overflow);
        vault.realizeGain(1);
        _pause();
        vm.prank(riskManager);
        vm.expectRevert(overflow);
        vault.realizeLoss(1);
        _unpause();
        vm.prank(setter);
        vm.expectRevert(overflow);
        vault.setVSR(RAY);
        _takeAll();                                            // take does not drip: backing exits
        assertEq(_vaultSpUsdc(), 0);
    }

    // (d) Same-block gain/loss pairs (and the reverse order) never ratchet chi upward: every step
    // floors, so after n netting pairs chi <= chi0 and totalAssets is within 2n units of the
    // start. A user has no hook between the two admin calls, and a round trip after them never
    // returns more than deposited.
    function testFuzz_realizeGainLoss_noRatchet(uint256 g, uint256 n, bool lossFirst, uint256 amt)
        public
    {
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
                _realizeLoss(g);
                vm.prank(admin);
                vault.realizeGain(g);
            } else {
                vm.prank(admin);
                vault.realizeGain(g);
                uint256 ta = vault.totalAssets();
                if (g >= ta) break;                            // floor ate the room: nothing to lose
                _realizeLoss(g);
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

    // Access and bounds: admin only, gain > 0, totalSupply != 0, not pause-gated, drips first,
    // emits the new chi.
    function test_realizeGain_accessAndBounds() public {
        address[4] memory who = [riskManager, guardian, setter, rebalancer];
        for (uint256 i; i < 4; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", who[i], DEFAULT_ADMIN_ROLE
            ));
            vault.realizeGain(1);
        }

        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/invalid-gain");
        vault.realizeGain(0);

        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/no-shares");
        vault.realizeGain(1);                                  // totalSupply == 0

        _deposit(alice, 1_000_000e6);
        _setPrimeVsr(FIVE_PCT_VSR);
        _warp(30 days);                                        // undripped accrual pending

        uint256 supply   = vault.totalSupply();
        uint256 dripped  = vault.nowChi();
        uint256 taAfter  = supply * dripped / RAY;
        uint192 expected = uint192((taAfter + 1_000e6) * RAY / supply);

        _pause();                                              // works while paused
        vm.expectEmit(address(vault));
        emit GainRealized(expected, 1_000e6);
        vm.prank(admin);
        vault.realizeGain(1_000e6);
        assertEq(vault.chi(), expected);
        assertEq(vault.rho(), block.timestamp);                // dripped first
        assertApproxEqAbs(vault.totalAssets(), taAfter + 1_000e6, 1);
    }

}
