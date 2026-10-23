// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { LocalTestBase } from "./LocalTestBase.t.sol";
import { ISparkPrimeVault } from "src/ISparkPrimeVault.sol";

import { SparkPrimeVault } from "../../src/SparkPrimeVault.sol";
import { ERC1967Proxy }    from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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

// Recipient that reverts on every call: proves USDC/spUSDC payouts never call the recipient, so a
// contract recipient cannot trigger the try/catch fallback on purpose.
contract RevertingRecipient {
    fallback() external payable { revert("RevertingRecipient"); }
    receive()  external payable { revert("RevertingRecipient"); }
}

/// @dev Shared helpers for the three round contracts. Line numbers in comments refer to
///      `src/SparkPrimeVault.sol` @ c512609 unless a round header says otherwise.
abstract contract AdversarialBase is LocalTestBase {

    bytes4 internal constant PANIC_SEL = bytes4(keccak256("Panic(uint256)"));

    /// @dev Full cancel of `id` by `who` to `to` (the 3-arg signature needs the entry's shares).
    function _cancelTo(address who, uint256 id, address to) internal returns (uint256 cancelId) {
        ( , , uint256 shares ) = vault.getPendingDepositRequest(id);
        vm.prank(who);
        cancelId = vault.requestDepositCancellation(id, to, shares);
    }

    // Fills capacity exactly: `who` deposits `amt`, then capacity is pinned to totalSupply.
    function _fillCapacityExactly(address who, uint256 amt) internal {
        _deposit(who, amt);
        _setCapacity(vault.totalSupply());
        assertEq(vault.availableCapacity(), 0);
    }

    /// @dev Raw storage read of array element `i` of the queue at `slot` (0 deposits,
    ///      1 cancellations, 2 redeems); the getters refuse ids below the head.
    function _rawRequest(uint256 slot, uint256 i)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        uint256 base = uint256(keccak256(abi.encode(slot))) + 3 * i;
        owner     = address(uint160(uint256(vm.load(address(vault), bytes32(base)))));
        recipient = address(uint160(uint256(vm.load(address(vault), bytes32(base + 1)))));
        shares    = uint256(vm.load(address(vault), bytes32(base + 2)));
    }

    function _rawDeposit(uint256 i)   internal view returns (address, address, uint256) { return _rawRequest(0, i); }
    function _rawCancelled(uint256 i) internal view returns (address, address, uint256) { return _rawRequest(1, i); }
    function _rawRedeem(uint256 i)    internal view returns (address, address, uint256) { return _rawRequest(2, i); }

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", who, role);
    }

}

contract AdversarialTest is AdversarialBase {

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
        for (uint256 i = vault.firstPendingDepositId(); i < n; ++i) { ( , , uint256 s) = _depositRequest(i); sum += s; }
    }

    function _sumOpenRedeems() internal view returns (uint256 sum) {
        uint256 n = _redeemQueueLength();
        for (uint256 i = vault.firstPendingRedeemId(); i < n; ++i) { ( , , uint256 s) = _redeemRequest(i); sum += s; }
    }

    function _sumOpenCancelled() internal view returns (uint256 sum) {
        uint256 n = _cancelledDepositQueueLength();
        for (uint256 i = vault.firstPendingDepositCancellationId(); i < n; ++i) { ( , , uint256 s) = _cancelledDepositRequest(i); sum += s; }
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
        amt   = bound(amt,   1,   1e12 * 1e6);   // 0 is `BelowMinDeposit` now
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
        amt    = bound(amt,    1,   1e12 * 1e6);
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
            if (have == 0) break;                 // a previous cycle lost the last wei
            totalIn += have;

            vm.prank(alice);
            uint256 id = vault.requestDeposit(have, alice, 0);

            assertEq(vault.balanceOf(alice), 0);  // nothing minted: capacity full

            (, , uint256 queued) = _rawDeposit(id);     // a 0-share entry is skipped at request time
            if (queued == 0) { totalOut += 0; break; }  // 0-share entry: cannot cancel (C-11), USDC lost

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

        (, , uint256 jamLeft) = _rawDeposit(1);     // below the head now: raw read
        assertEq(jamLeft, 0);                       // jam entry closed, 0 shares minted
        assertEq(vault.balanceOf(attacker), 0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(), 3);
        assertEq(
            vault.totalSupply() - supplyBefore,
            vault.convertToShares(spUsdc.convertToAssets(victimQueued))
        );
    }

    // C-11 residual at the harness minimum (1 wei): 1 wei USDC converts to 0 spUSDC shares, the
    // entry is a ghost, no jam, 1 wei donated to spUSDC. `minDeposit != 0` (:382) does not close
    // this: only `minDeposit >= ceil(chi_s / RAY)` (2 wei at the harness chi) does.
    function test_BUG_C11_oneWeiDepositGivesZeroSavingsSharesGhost_minDepositOneWei() public {
        _fillCapacityExactly(alice, 1_000_000e6);

        _fund(attacker, 1);
        vm.prank(attacker);
        uint256 id = vault.requestDeposit(1, attacker, 0);

        (, , uint256 queued) = _rawDeposit(id);
        assertEq(queued, 0);
        assertEq(vault.firstPendingDepositId(), id + 1);     // skipped by the instant path at once
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(usdc.balanceOf(address(spUsdc)), 1_000_000e6 + 1);  // donated to spUSDC

        vm.prank(attacker);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, attacker, 1);

        // Next depositor is still instant once capacity exists.
        _setCapacity(type(uint128).max);
        _deposit(victim, 10e6);
        assertGt(vault.balanceOf(victim), 0);

        // The guard: minDeposit = 2 (>= ceil(chi_s / RAY)) makes a zero-share entry impossible.
        _setMinDeposit(2);
        _fund(attacker, 3);
        vm.prank(attacker);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(1, attacker, 0);
        _setCapacity(vault.totalSupply());
        vm.prank(attacker);
        uint256 id2 = vault.requestDeposit(2, attacker, 0);
        (, , uint256 q2) = _depositRequest(id2);
        assertEq(q2, 1);
    }

    // Regression for R5-9 (zero-asset ghosts): `requestDeposit(0)` is `BelowMinDeposit` (:382)
    // for every minimum (the setter and `initialize` reject 0), `requestRedeem(0)` is
    // `BelowMinRedeem` (:456), so the free ghosts of rounds 2-5 are gone. Exact selectors and
    // the state left untouched.
    function test_fixed_R5_9_zeroAssetAndZeroShareRequestsRejected() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 len = _depositQueueLength();

        vm.startPrank(attacker);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(0, attacker, 0);
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(0, attacker);
        vm.stopPrank();
        assertEq(_depositQueueLength(), len);
        assertEq(_redeemQueueLength(), 0);

        vm.startPrank(admin);
        vm.expectRevert(ISparkPrimeVault.ZeroMinDeposit.selector);
        vault.setMinDeposit(0);
        vm.expectRevert(ISparkPrimeVault.ZeroMinRedeem.selector);
        vault.setMinRedeem(0);
        vm.expectRevert(ISparkPrimeVault.ZeroMinDepositCancellation.selector);
        vault.setMinDepositCancellation(0);
        vm.stopPrank();

        // A fresh proxy cannot be initialised with a zero minimum either.
        address impl = address(new SparkPrimeVault());
        bytes memory initZero = abi.encodeCall(
            ISparkPrimeVault.initialize, (address(spUsdc), "x", "x", admin, 0, 1, 1)
        );
        vm.expectRevert(ISparkPrimeVault.ZeroMinDeposit.selector);
        new ERC1967Proxy(impl, initZero);
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
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDeposit(100_000e6, address(vault), 0);

        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(usdc.balanceOf(attacker), 100_000e6);        // nothing pulled

        // Queued entry repointed to the vault: rejected too.
        _fillCapacityExactly(alice, 1_000e6);
        vm.prank(attacker);
        uint256 id = vault.requestDeposit(100_000e6, attacker, 0);
        vm.prank(attacker);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositRecipient(id, address(vault));
        (, address r, ) = _depositRequest(id);
        assertEq(r, attacker);
    }

    // Regression for V2-13 / R5-7 (vault as recipient): `requestRedeem` :455, `requestDeposit`
    // :381, `requestDepositCancellation` :415 and the three updaters (:484, :500, :515) reject
    // `address(this)` with `VaultIsRecipient`, before the owner check, so no USDC can be stranded
    // in the vault through a queue any more. State untouched after every attempt.
    function test_fixed_V2_13_vaultAsRecipientRejectedEverywhere() public {
        _deposit(attacker, 100_000e6);
        uint256 shares = vault.balanceOf(attacker);
        _fillCapacityExactly(alice, 1_000e6);
        uint256 dId = _deposit(attacker, 10e6);
        uint256 cId = _cancelTo(attacker, dId, attacker);
        uint256 dId2 = _deposit(attacker, 10e6);
        uint256 rId = _requestRedeem(attacker, shares / 2);

        vm.startPrank(attacker);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestRedeem(shares / 2, address(vault));
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDeposit(1, address(vault), 0);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDepositCancellation(dId2, address(vault), 1);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateRedeemRecipient(rId, address(vault));
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositRecipient(dId2, address(vault));
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositCancellationRecipient(cId, address(vault));
        vm.stopPrank();

        // A stranger gets the same reason: the recipient check precedes the owner check.
        vm.startPrank(rando);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateRedeemRecipient(rId, address(vault));
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDepositCancellation(dId2, address(vault), 1);
        vm.stopPrank();

        (, address r, uint256 s) = _redeemRequest(rId);
        assertEq(r, attacker);
        assertEq(s, shares / 2);
        _processRedeems(type(uint256).max, 10);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.claimableAssets(address(vault)), 0);
        assertEq(usdc.balanceOf(attacker), vault.convertToAssets(shares / 2) + 9_999_999);
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
        vm.prank(operator);
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

    // The only ghost left on c512609: a `minDeposit`-sized request that is fully cancelled (the
    // entry is deleted :435, the cancel's self-skip :445 only clears entries AT the head). Costs
    // the attacker 2 wei (refunded as 1 wei through the cancel queue) and two calls.
    function _ghost(address who) internal returns (uint256 gas) {
        _fund(who, 2);
        vm.startPrank(who);
        uint256 g0 = gasleft();
        uint256 id = vault.requestDeposit(2, who, 0);
        vault.requestDepositCancellation(id, who, 1);
        gas = g0 - gasleft();
        vm.stopPrank();
    }

    // Ghosts can only be placed behind a live head entry. Measures the planner's gas per skipped
    // ghost and shows the head advances across multiple calls.
    function test_griefing_ghostDepositEntriesGasPerSkip() public {
        _fillCapacityExactly(alice, 1_000_000e6);
        _deposit(bob, 1e6);  // opens the queue: pending != 0, live head

        uint256 ghostCost = _ghost(attacker);
        for (uint256 i; i < 1999; ++i) _ghost(attacker);
        assertEq(vault.firstPendingDepositId(), 1);            // bob is live: nothing walked

        uint256 victimId = _deposit(victim, 5e6);
        assertEq(victimId, 2002);

        _setCapacity(type(uint128).max);

        // Call 1: bob (1 request) + 1000 ghosts.
        vm.prank(operator);
        uint256 g1 = gasleft();
        vault.processPendingDeposits(type(uint256).max, 1001);
        uint256 gas1 = g1 - gasleft();
        assertEq(vault.firstPendingDepositId(), 1002);

        // Call 2: 1000 ghosts only.
        vm.prank(operator);
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
        emit log_named_uint("gas per deposit(2)+cancel ghost (attacker)", ghostCost);
        emit log_named_uint("planner gas, 1 fill + 1000 ghost skips", gas1);
        emit log_named_uint("planner gas, 1000 ghost skips", gas2);
        emit log_named_uint("planner gas per ghost skip", perGhost);
        emit log_named_uint("ghosts per 30M block", 30_000_000 / perGhost);

        assertLt(perGhost, 3_000);
        assertGt(30_000_000 / perGhost, 10_000);
    }

    // R6-2 (new, low): `_processPendingRedeems` has no `shares == 0` skip (:950-973), so a
    // 0-share ghost (R5-14: `requestRedeem(1)` at a non-zero fee) runs the whole fill body:
    // `maxWithdraw` + `convertToShares` (:953) and `_withdrawSavings(0, ..)` (:966), i.e. a real
    // `spUSDC.withdraw(0)` with a 0-wei USDC transfer, ~37k gas per ghost instead of the ~500 a
    // skip costs in the deposit queue (:875). The attacker pays 1 share and ~95k per ghost;
    // bounded by `maxRequests`, `minRedeem >= 100` removes it.
    function test_BUG_R6_2_zeroShareRedeemGhostCostsFullWithdrawRoundTrip() public {
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

        vm.prank(operator);
        uint256 g1 = gasleft();
        vault.processPendingRedeems(type(uint256).max, 1000);
        uint256 gas1 = g1 - gasleft();
        assertEq(vault.firstPendingRedeemId(), 1000);
        assertEq(usdc.balanceOf(alice), 0);

        vm.prank(operator);
        vault.processPendingRedeems(type(uint256).max, 1001);
        assertEq(vault.firstPendingRedeemId(), 2001);
        assertGt(usdc.balanceOf(alice), 0);

        uint256 perGhost = gas1 / 1000;
        emit log_named_uint("gas per requestRedeem(1) ghost (attacker)", ghostCost);
        emit log_named_uint("planner gas per 0-share redeem entry (withdraw(0) round trip)", perGhost);
        emit log_named_uint("ghosts per 30M block", 30_000_000 / perGhost);
        assertGt(perGhost, 20_000);                           // not a skip: a full withdraw(0)
        assertLt(perGhost, 60_000);
        assertLt(ghostCost, 200_000);
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

        vm.prank(operator);
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
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(0, attacker, 0);

        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(1e6 - 1, attacker, 0);

        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(0, attacker);

        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(1e6 - 1, attacker);

        // Smallest allowed redeem: queued shares are non-zero (fee cannot eat the whole thing).
        uint256 id = vault.requestRedeem(1e6, attacker);
        vm.stopPrank();
        (, , uint256 q) = _redeemRequest(id);
        assertEq(q, 1e6 - 1e4);
    }

    // Regression for V2-9: `requestRedeem(0)` is `BelowMinRedeem` (:456) at every minimum, and
    // an attacker with no shares cannot queue anything at all (`_transfer` :1037 needs balance).
    // The 1-share-at-nonzero-fee ghost (R5-14) is the only redeem ghost left and is pinned in
    // `test_requestRedeem_oneShareAtNonZeroFeeIsAllFeeGhost`.
    function test_fixed_V2_9_zeroRedeemGhostRejected() public {
        _deposit(alice, 100e6);

        vm.startPrank(attacker);                     // attacker holds no shares at all
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(0, attacker);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.requestRedeem(1, attacker);
        vm.stopPrank();

        assertEq(_redeemQueueLength(), 0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.balanceOf(attacker), 0);
    }

    // Without capacity (deposits) or liquidity (redeems) the head cannot move past a LIVE entry,
    // but then nothing could be processed anyway; the ghosts behind it wait.
    function test_griefing_headDoesNotAdvanceWithoutCapacityOrLiquidity() public {
        _fillCapacityExactly(alice, 1_000e6);
        _deposit(bob, 1e6);
        for (uint256 i; i < 10; ++i) _ghost(attacker);

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
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", operator, TAKER_ROLE
        ));
        vault.take(1);
    }

    function test_take_moreThanBalance() public {
        _deposit(alice, 1e6);
        uint256 bal = _vaultSpUsdc();
        vm.prank(taker);
        vm.expectRevert(ISparkPrimeVault.InsufficientShares.selector);
        vault.take(bal + 1);
        vm.prank(taker);
        vault.take(bal);
        assertEq(_vaultSpUsdc(), 0);
    }

    function test_adjustTotalAssets_notPaused() public {
        _deposit(alice, 1e6);
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(-1);
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(1);
        // The admin lost the role on c512609: LOSS_MANAGER_ROLE only (:265), checked first.
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, LOSS_MANAGER_ROLE));
        vault.adjustTotalAssets(-1);
    }

    // pause() is PAUSER_ROLE (:356); no other role, admin included, can pause.
    function test_pause_otherRolesCannot() public {
        address[6] memory who = [admin, operator, redeemFeeSetter, lossManager, taker, unpauser];
        for (uint256 i; i < 6; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(_unauthorized(who[i], PAUSER_ROLE));
            vault.pause();
        }
        _pause();
        assertTrue(vault.paused());
    }

    // unpause() is UNPAUSER_ROLE (:365): the pauser cannot undo his own pause, and neither can
    // the admin without granting himself the role first.
    function test_unpause_otherRolesCannot() public {
        _pause();
        address[6] memory who = [admin, pauser, operator, redeemFeeSetter, lossManager, taker];
        for (uint256 i; i < 6; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(_unauthorized(who[i], UNPAUSER_ROLE));
            vault.unpause();
        }
        _unpause();
        assertFalse(vault.paused());
    }

    function test_upgradeToAndCall_notAdmin() public {
        address impl = address(new SparkPrimeVault());
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", pauser, DEFAULT_ADMIN_ROLE
        ));
        vault.upgradeToAndCall(impl, "");

        vm.prank(admin);
        vault.upgradeToAndCall(impl, "");
        assertEq(vault.implementation(), impl);
    }

    // No hot-wallet role reaches an admin lever (grantRole, bounds, max fee, minimums, upgrade)
    // or another hot wallet's lever. `setCapacity`/`setVSR` moved to OPERATOR (:304/:308).
    function test_hotWalletRoles_cannotEscalate() public {
        bytes32[6] memory roles = [OPERATOR_ROLE, REDEEM_FEE_SETTER_ROLE, PAUSER_ROLE, UNPAUSER_ROLE, LOSS_MANAGER_ROLE, TAKER_ROLE];
        address[6] memory who   = [operator, redeemFeeSetter, pauser, unpauser, lossManager, taker];
        address impl = address(new SparkPrimeVault());
        for (uint256 i; i < 6; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(_unauthorized(who[i], DEFAULT_ADMIN_ROLE));
            vault.grantRole(roles[i], attacker);
            vm.expectRevert(_unauthorized(who[i], DEFAULT_ADMIN_ROLE));
            vault.setVSRBounds(RAY, RAY);
            vm.expectRevert(_unauthorized(who[i], DEFAULT_ADMIN_ROLE));
            vault.setMaxRedeemFeeRate(0);
            vm.expectRevert(_unauthorized(who[i], DEFAULT_ADMIN_ROLE));
            vault.setMinDeposit(1);
            vm.expectRevert(_unauthorized(who[i], DEFAULT_ADMIN_ROLE));
            vault.setMinRedeem(1);
            vm.expectRevert(_unauthorized(who[i], DEFAULT_ADMIN_ROLE));
            vault.setMinDepositCancellation(1);
            vm.expectRevert(_unauthorized(who[i], DEFAULT_ADMIN_ROLE));
            vault.upgradeToAndCall(impl, "");
            if (who[i] != operator) {
                vm.expectRevert(_unauthorized(who[i], OPERATOR_ROLE));
                vault.setCapacity(1);
                vm.expectRevert(_unauthorized(who[i], OPERATOR_ROLE));
                vault.setVSR(RAY);
                vm.expectRevert(_unauthorized(who[i], OPERATOR_ROLE));
                vault.processPendingDeposits(1, 1);
            }
            if (who[i] != taker) {
                vm.expectRevert(_unauthorized(who[i], TAKER_ROLE));
                vault.take(0);
            }
            if (who[i] != lossManager) {
                vm.expectRevert(_unauthorized(who[i], LOSS_MANAGER_ROLE));
                vault.adjustTotalAssets(1);
            }
            if (who[i] != redeemFeeSetter) {
                vm.expectRevert(_unauthorized(who[i], REDEEM_FEE_SETTER_ROLE));
                vault.setRedeemFeeRate(0);
            }
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
        vm.stopPrank();
        _cancelTo(alice, id, address(rec));                            // moved to the cancel queue
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

        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.VSRTooHigh.selector);
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
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.VSRTooHigh.selector);
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
        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
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
        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
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

        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.ZeroDeltaTotalAssets.selector);
        vault.adjustTotalAssets(0);

        int256 ta = int256(vault.totalAssets());
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(-ta);
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
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
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
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
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(-1);                          // totalSupply == 0, totalAssets 0
        vm.prank(lossManager);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Panic(uint256)")), 0x12));
        vault.adjustTotalAssets(1);                           // division by zero
        _unpause();

        _deposit(alice, 1_000_000e6);
        _pause();
        int256 ta = int256(vault.totalAssets());
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(-ta - 1);
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(-ta);
        _adjustTotalAssets(-(ta - 1));
        assertEq(vault.totalAssets(), 0);
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);    // totalAssets is 0 now: nothing left
        vault.adjustTotalAssets(-1);
    }

    // REBALANCER: can only move the queues FIFO. Every payout equals convertToAssets(shares),
    // every mint equals convertToShares(assets); the operator's own balances never change.
    function test_compromised_rebalancer_cannotExtractValue() public {
        _fillCapacityExactly(alice, 500_000e6);
        uint256 bobId = _deposit(bob, 100_000e6);
        (, , uint256 bobQueued) = _depositRequest(bobId);

        uint256 aliceShares = vault.balanceOf(alice);
        _requestRedeem(alice, aliceShares);

        uint256 rbUsdc = usdc.balanceOf(operator);
        uint256 rbSp   = spUsdc.balanceOf(operator);
        uint256 rbSh   = vault.balanceOf(operator);

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

        assertEq(usdc.balanceOf(operator),   rbUsdc);
        assertEq(spUsdc.balanceOf(operator), rbSp);
        assertEq(vault.balanceOf(operator),  rbSh);

        // Starvation ceiling: a user can always cancel a starved request (not paused), but the
        // refund now also waits for the operator. Partial settlement pays exactly
        // spUSDC.redeem(shares) per fill: the user loses at most one floor per partial.
        _setCapacity(vault.totalSupply());
        uint256 dId = _deposit(rando, 10e6);
        (, , uint256 dq) = _depositRequest(dId);
        assertGt(dq, 0);
                uint256 cId = _cancelTo(rando, dId, rando);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), dq);

        _processCancelledDeposits(1, 1);
        assertEq(usdc.balanceOf(rando), spUsdc.convertToAssets(1));
        _processCancelledDeposits(dq / 3, 1);
        _processCancelledDeposits(type(uint256).max, 1);
        (, , uint256 cLeft) = _rawCancelled(cId);
        assertEq(cLeft, 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertLe(usdc.balanceOf(rando), spUsdc.convertToAssets(dq));
        assertGe(usdc.balanceOf(rando), spUsdc.convertToAssets(dq) - 3);

        assertEq(usdc.balanceOf(operator),   rbUsdc);
        assertEq(spUsdc.balanceOf(operator), rbSp);
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
                // Partial or full cancel of an open entry of `u`, slice chosen at random.
                uint256 h = vault.firstPendingDepositId();
                uint256 n = _depositQueueLength() - h;
                if (n > 0) {
                    uint256 id = h + (r >> 48) % n;
                    (address o, , uint256 s) = _depositRequest(id);
                    if (s != 0 && o == u) {
                        uint256 slice = 1 + (r >> 72) % s;
                        vm.prank(u);
                        vault.requestDepositCancellation(id, u, slice);
                    }
                }
            } else if (op == 4) {
                // V2-2: cancel is owner-only (:421). The pauser gets `NotRequestOwner`; the
                // owner cancels in full to himself.
                uint256 h = vault.firstPendingDepositId();
                uint256 n = _depositQueueLength() - h;
                if (n > 0) {
                    uint256 id = h + (r >> 48) % n;
                    (address o, , uint256 s) = _depositRequest(id);
                    if (s != 0) {
                        vm.prank(pauser);
                        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
                        vault.requestDepositCancellation(id, o, s);
                        _cancelTo(o, id, o);
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
                uint256 h = which == 0 ? vault.firstPendingDepositId()
                          : which == 1 ? vault.firstPendingRedeemId() : vault.firstPendingDepositCancellationId();
                uint256 n = (which == 0 ? _depositQueueLength()
                          : which == 1 ? _redeemQueueLength() : _cancelledQueueLength()) - h;
                if (n > 0) {
                    uint256 id = h + (r >> 56) % n;
                    (address o, , uint256 s) = which == 0 ? _depositRequest(id)
                                             : which == 1 ? _redeemRequest(id)
                                             : _cancelledDepositRequest(id);
                    bool asOwner = (r >> 64) % 2 == 0 && s != 0;
                    address caller = asOwner ? o : attacker;
                    if (!asOwner) {
                        vm.expectRevert(s == 0 ? bytes(abi.encodeWithSelector(ISparkPrimeVault.NoRequest.selector))
                                               : bytes(abi.encodeWithSelector(ISparkPrimeVault.NotRequestOwner.selector)));
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
            (, , uint256 s) = _rawDeposit(i);
            assertEq(s, 0, "open deposit entry before head");
        }
        uint256 rh = vault.firstPendingRedeemId();
        for (uint256 i; i < rh; ++i) {
            (, , uint256 s) = _rawRedeem(i);
            assertEq(s, 0, "open redeem entry before head");
        }
        uint256 ch = vault.firstPendingDepositCancellationId();
        for (uint256 i; i < ch; ++i) {
            (, , uint256 s) = _rawCancelled(i);
            assertEq(s, 0, "open cancelled entry before head");
        }
        assertEq(vault.totalClaimable(), usdc.balanceOf(address(vault)), "claimable != vault USDC");
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

    // Regression for R4-A (blacklisted redeem recipient blocked the FIFO queue): there is no
    // request-time check any more (an already-blacklisted recipient is accepted at :454-456),
    // and the payout `try`s the recipient (:1001) and falls back to the vault + `claimableAssets`
    // (:1011-1013) so the queue keeps moving. Minimal version at fee 0 with two 1-share jams;
    // the full accounting is in AdversarialRound4Test.
    function test_fixed_R4A_blacklistedRedeemRecipientDoesNotBlockQueue() public {
        address blacklisted = makeAddr("blacklisted");
        _blacklist(blacklisted);

        _deposit(attacker, 1e6);
        _deposit(alice, 1_000_000e6);

        vm.prank(attacker);
        uint256 jam0 = vault.requestRedeem(1, blacklisted);  // accepted
        assertEq(jam0, 0);

        // Mid-flight: clean at request time, blacklisted before the planner runs.
        address mid = makeAddr("mid");
        vm.prank(attacker);
        uint256 jamId = vault.requestRedeem(1, mid);
        _requestRedeem(alice, vault.balanceOf(alice));
        _blacklist(mid);

        _processRedeems(type(uint256).max, 10);              // no revert, FIFO moves on
        assertEq(vault.firstPendingRedeemId(), 3);
        assertEq(vault.claimableAssets(blacklisted), 1);     // convertToAssets(1 share) = 1 wei
        assertEq(vault.claimableAssets(mid), 1);
        assertEq(vault.totalClaimable(), 2);
        assertEq(usdc.balanceOf(address(vault)), 2);
        assertEq(usdc.balanceOf(mid), 0);
        assertGt(usdc.balanceOf(alice), 999_990e6);

        vm.expectRevert(BLACKLISTED);
        vault.claim(mid);
        _unblacklist(mid);
        vault.claim(mid);
        assertEq(usdc.balanceOf(mid), 1);
        assertEq(usdc.balanceOf(address(vault)), 1);
        assertEq(vault.totalClaimable(), 1);
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

                _cancelTo(attacker, whaleId, attacker);        // cancel id 0 (head)
                _cancelTo(victim, victimId, victim);         // cancel id 1

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
        vault.requestDepositCancellation(d, attacker, 1);
        uint256 perDust = g0 - gasleft();
        for (uint256 i; i < 499; ++i) {
            d = vault.requestDeposit(2, attacker, 0);
            vault.requestDepositCancellation(d, attacker, 1);
        }
        vm.stopPrank();
        assertEq(_cancelledQueueLength(), 500);

        uint256 vId = _deposit(victim, 100e6);
                uint256 vc = _cancelTo(victim, vId, victim);
        assertEq(vc, 500);

        vm.prank(operator);
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
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(id, attacker);

        // Roles do not help either: pauser, operator and admin are strangers to the entry.
        address[3] memory roles = [pauser, operator, admin];
        for (uint256 i; i < 3; ++i) {
            vm.prank(roles[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
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
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
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

                uint256 cId = _cancelTo(victim, id, victim);

        vm.prank(attacker);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
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
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositRecipient(id, attacker);

                uint256 cId = _cancelTo(victim, id, safe);
        (address o, address r, ) = _cancelledDepositRequest(cId);
        assertEq(o, victim);                                   // owner carries over
        assertEq(r, safe);

        vm.prank(attacker);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(cId, attacker);

        // The deposit entry is closed: even the owner cannot repoint it anymore.
        vm.prank(victim);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositRecipient(id, victim);

        _processCancelledDeposits(type(uint256).max, 1);
        assertApproxEqAbs(usdc.balanceOf(safe), 500_000e6, 2);
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(usdc.balanceOf(victim), 0);
    }

    // R2-2 / R4-A on c512609: the owner MAY repoint a live redeem to a blacklisted address (no
    // check at :514-525), a stranger gets `NotRequestOwner`. The round-1 A-1 self-harm (owner
    // blocks the queue by naming a blacklisted recipient) stays gone: the fill falls back to
    // `claimableAssets` (:1011-1013) and never blocks anyone. Exact amounts, fee 1%.
    function test_updateRedeemRecipient_blacklistedAccepted_paidToClaimable() public {
        address blacklisted = makeAddr("blacklisted");
        _blacklist(blacklisted);
        _setRedeemFeeRate(0.01e18);

        _deposit(alice, 1_000_000e6);
        _deposit(bob, 10_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 aId = _requestRedeem(alice, aliceShares);
        _requestRedeem(bob, vault.balanceOf(bob));

        vm.prank(attacker);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(aId, blacklisted);
        vm.prank(attacker);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(aId, attacker);
        vm.prank(alice);
        vault.updateRedeemRecipient(aId, blacklisted);         // owner's choice, accepted

        (, address r, ) = _redeemRequest(aId);
        assertEq(r, blacklisted);

        // Both filled in one call; alice's payout is parked, bob is paid directly.
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.claimableAssets(blacklisted), 989_999_999_997);
        assertEq(usdc.balanceOf(address(vault)), 989_999_999_997);
        assertEq(usdc.balanceOf(alice), 0);
        assertGt(usdc.balanceOf(bob), 9_800e6);
        assertEq(vault.firstPendingRedeemId(), 2);
        assertEq(vault.totalClaimable(), 989_999_999_997);
    }

    // Regression for round-2 R2-2 / round-1 A-6 (strand in vault): `updateRedeemRecipient` :515
    // rejects the vault for the owner too, so the self-harm is gone. spUSDC as the recipient is
    // still accepted (donation, pinned as open in AdversarialRound5Test).
    function test_fixed_V2_13_updateRedeemRecipientVaultRejected() public {
        _deposit(alice, 100_000e6);
        uint256 shares = vault.balanceOf(alice);
        uint256 id = _requestRedeem(alice, shares);

        vm.prank(attacker);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);  // :515 before the owner check
        vault.updateRedeemRecipient(id, address(vault));
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateRedeemRecipient(id, address(vault));

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(alice), vault.convertToAssets(shares));
        assertEq(usdc.balanceOf(alice), 99_999_999_998);
    }

    // Regression for round-2 R2-2 (dead capacity): `updateDepositRecipient` rejects the vault
    // (:481) for the owner too, so queued deposits can no longer be minted as phantom shares.
    function test_fixed_updateDepositRecipientVaultRejected() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 id = _deposit(victim, 100_000e6);
        (, , uint256 queued) = _depositRequest(id);

        vm.prank(attacker);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);  // :481 runs before the owner check :486
        vault.updateDepositRecipient(id, address(vault));

        vm.prank(victim);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
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
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.updateRedeemRecipient(id, attacker);
            vm.prank(alice);
            vault.updateRedeemRecipient(id, i % 2 == 0 ? alice : bob);
        }
        (, address r, ) = _redeemRequest(id);
        assertEq(r, alice);

        _processRedeems(shares / 2, 1);
        assertEq(usdc.balanceOf(alice), vault.convertToAssets(shares / 2));

        vm.prank(attacker);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
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
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositRecipient(dId, attacker);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(rId, attacker);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);   // :485 bounds check
        vault.updateDepositRecipient(dId + 1, attacker);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.updateDepositCancellationRecipient(0, attacker);    // empty queue
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.updateRedeemRecipient(rId, address(0));
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.requestDepositCancellation(dId + 1, attacker, 1);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(dId, attacker, 1);
        vm.stopPrank();

        vm.startPrank(alice);                                  // owner, closed entries
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositRecipient(dId, alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(rId, alice);
        vm.stopPrank();

        // The getters refuse ids below the head; the raw slot is zeroed.
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(dId);
        (address o0, address r0, uint256 s0) = _rawDeposit(dId);
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

    // R5-9 residual: ghosts (cancelled entries) behind an open head entry are not walked until
    // that entry closes (the cancel's self-skip :445 breaks at the live head). If the planner
    // closes the head exactly (maxRequests ends there) the head lands on the first ghost and the
    // next depositor's instant path (:400-401, unbounded walk) pays the whole walk once.
    // Measures gas per ghost and the N for 30M.
    function test_griefing_headWalkChargedToNextDepositorAfterPlannerClosesHead() public {
        _fillCapacityExactly(alice, 1_000e6);

        _fund(attacker, 2);
        vm.prank(attacker);
        vault.requestDeposit(2, attacker, 0);                     // id 1: 1 share, open, at head
        for (uint256 i; i < 1000; ++i) _ghost(attacker);          // ids 2..1001, O(1) each
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
        uint256 perGhostCold = perGhost > 2_100 ? perGhost : perGhost + 2_000;   // cold SLOAD per ghost
        emit log_named_uint("requestDeposit gas with 1000-ghost walk", walked);
        emit log_named_uint("requestDeposit gas baseline", baseline);
        emit log_named_uint("walk gas per ghost (as metered)", perGhost);
        emit log_named_uint("ghosts to exceed 30M gas (cold)", 30_000_000 / perGhostCold);
        emit log_named_uint("attacker gas to place them (~250k each)", 30_000_000 / perGhostCold * 250_000);
        assertLt(perGhost, 2_600);
        assertGt(30_000_000 / perGhostCold, 10_000);

        // The operator can pre-empt the walk at any time: a budget-0 call advances the head over
        // closed entries (:875-878), bounded by maxRequests.
    }

    // Regression for R5-9 (head freeze): the walk in `_processPendingDeposits` now `continue`s
    // over cancelled entries BEFORE testing the budget (:875-878), so with `availableCapacity()
    // == 0` the planner still advances the head past closed entries, bounded by `maxRequests`.
    // The cancel's own self-skip (:445) also clears closed entries at the head, so an attacker
    // cancelling his own head entries in FIFO order cleans up after himself.
    function test_fixed_R5_9_budgetZeroWalkAdvancesHeadPastCancelledEntries() public {
        _fillCapacityExactly(alice, 1_000e6);                  // capacity 0: no instant fills
        assertEq(vault.firstPendingDepositId(), 1);

        // 300 live dust entries at the head, then a victim.
        _fund(attacker, 600);
        vm.startPrank(attacker);
        for (uint256 i; i < 300; ++i) vault.requestDeposit(2, attacker, 0);   // ids 1..300
        vm.stopPrank();
        uint256 vId = _deposit(victim, 100e6);                 // id 301
        assertEq(vault.pendingDepositSavingsShares(), 300 + spUsdc.convertToShares(100e6));

        // Cancelled in REVERSE order: ids 300..2 are behind the live head (O(1) each), the last
        // cancel of id 1 walks all 299 closed entries and stops at the victim (live).
        vm.startPrank(attacker);
        for (uint256 i = 300; i > 1; --i) vault.requestDepositCancellation(i, attacker, 1);
        assertEq(vault.firstPendingDepositId(), 1);            // id 1 still live
        uint256 g0 = gasleft();
        vault.requestDepositCancellation(1, attacker, 1);
        uint256 walk = g0 - gasleft();
        vm.stopPrank();
        assertEq(vault.firstPendingDepositId(), 301);          // walked to the victim
        emit log_named_uint("attacker's own cancel walking 299 closed entries (warm)", walk);

        // Closed entries landed at the head by a planner call that closes the live head exactly:
        // the budget-0 walk (capacity still 0) advances over them.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);                // fills the victim, head 302 = length
        assertGt(vault.balanceOf(victim), 0);
        _setCapacity(vault.totalSupply());                     // capacity 0 again
        _fund(attacker, 200);
        vm.startPrank(attacker);
        for (uint256 i; i < 100; ++i) vault.requestDeposit(2, attacker, 0);   // ids 302..401
        vm.stopPrank();
        uint256 bId = _deposit(bob, 50e6);                     // id 402, live
        vm.startPrank(attacker);
        for (uint256 i = 401; i >= 303; --i) vault.requestDepositCancellation(i, attacker, 1);
        vm.stopPrank();
        // Head id 302 is live; closing it with a 1-share budget... capacity is 0, so the planner
        // cannot fill it. Attacker cancels it last: self-skip walks 303..401 and stops at bob.
        vm.prank(attacker);
        vault.requestDepositCancellation(302, attacker, 1);
        assertEq(vault.firstPendingDepositId(), 402);
        assertEq(vault.pendingDepositSavingsShares(), spUsdc.convertToShares(50e6));

        // Now the planner at capacity 0 with bob live at the head: breaks at bob, head stays.
        _processDeposits(type(uint256).max, 1000);
        assertEq(vault.firstPendingDepositId(), 402);

        // And closed entries AT the head (bob cancels in full, then 50 ghosts behind) are walked
        // by a budget-0 planner call, `maxRequests` at a time.
        _cancelTo(bob, bId, bob);
        assertEq(vault.firstPendingDepositId(), 403);          // bob's cancel walked to the end
        _fund(attacker, 100);
        vm.startPrank(attacker);
        for (uint256 i; i < 50; ++i) vault.requestDeposit(2, attacker, 0);   // ids 403..452
        for (uint256 i = 452; i > 403; --i) vault.requestDepositCancellation(i, attacker, 1);
        vm.stopPrank();
        assertEq(vault.firstPendingDepositId(), 403);          // id 403 live at the head
        // Planner closes nothing (capacity 0) but once id 403 is cancelled the self-skip clears.
        vm.prank(attacker);
        vault.requestDepositCancellation(403, attacker, 1);
        assertEq(vault.firstPendingDepositId(), 453);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        // Finally the planner's budget-0 walk itself, with ghosts parked at the head by an exact
        // planner close: victim2 live at head, 40 ghosts behind, planner fills victim2 only.
        _setCapacity(type(uint128).max);
        _deposit(rando, 1e6);                                  // instant: head 454
        _setCapacity(vault.totalSupply());
        uint256 v2 = _deposit(victim, 10e6);                   // id 454, live
        for (uint256 i; i < 40; ++i) _ghost(attacker);         // ids 455..494
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);                // closes 454 exactly
        assertEq(vault.firstPendingDepositId(), 455);          // head on the first ghost
        _setCapacity(vault.totalSupply());                     // capacity 0
        _processDeposits(0, 10);                               // budget 0: still advances 10
        assertEq(vault.firstPendingDepositId(), 465);
        _processDeposits(0, 1000);
        assertEq(vault.firstPendingDepositId(), 495);
        v2; vId;
    }

    // R6-1 (new): the cancel's self-skip walk (:445, `maxRequests = max`) is unbounded and is
    // paid by the HEAD OWNER's cancel. An attacker parks N closed entries behind a live head
    // (each O(1): the walk breaks at the live head) and the victim's full cancel then walks all
    // N. Measured per entry; the escape is a PARTIAL cancel (the entry stays live, the walk
    // breaks immediately) or waiting for the planner.
    function test_BUG_R6_1_selfSkipWalkChargedToHeadOwnerCancel_partialCancelEscapes() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 vId = _deposit(victim, 100e6);                 // id 1, live head
        (, , uint256 vQ) = _depositRequest(vId);
        for (uint256 i; i < 1000; ++i) _ghost(attacker);       // ids 2..1001
        assertEq(vault.firstPendingDepositId(), 1);

        uint256 snap = vm.snapshotState();

        // Full cancel: walks 1000 closed entries.
        vm.prank(victim);
        uint256 g0 = gasleft();
        vault.requestDepositCancellation(vId, victim, vQ);
        uint256 full = g0 - gasleft();
        assertEq(vault.firstPendingDepositId(), 1002);

        // Partial cancel (vQ - 1 slices out, 1 share stays): O(1), entry still live at the head.
        vm.revertToState(snap);
        vm.prank(victim);
        uint256 g1 = gasleft();
        vault.requestDepositCancellation(vId, victim, vQ - 1);
        uint256 partialGas = g1 - gasleft();
        assertEq(vault.firstPendingDepositId(), 1);
        (, , uint256 left) = _depositRequest(vId);
        assertEq(left, 1);

        uint256 perEntry = (full - partialGas) / 1000;
        emit log_named_uint("victim full cancel gas with 1000 ghosts behind (warm)", full);
        emit log_named_uint("victim partial cancel gas, same queue", partialGas);
        uint256 perEntryCold = perEntry > 2_100 ? perEntry : perEntry + 2_100;
        emit log_named_uint("walk gas per closed entry (as metered)", perEntry);
        emit log_named_uint("entries to push a cancel past 30M (cold)", 30_000_000 / perEntryCold);
        emit log_named_uint("attacker gas to place them (~250k each)", 30_000_000 / perEntryCold * 250_000);
        assertGt(full, partialGas + 300_000);                  // the walk is real
        assertLt(perEntry, 2_600);

        // The remainder (1 share) is refunded via a second slice; the planner settles both
        // (behind the attacker's 1000 dust cancel entries, R2-5).
        _processCancelledDeposits(type(uint256).max, 2000);
        assertEq(usdc.balanceOf(victim), spUsdc.convertToAssets(vQ - 1));
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);                // fills the 1-share remainder
        assertEq(vault.firstPendingDepositId(), 2);
        _processDeposits(0, 2000);                             // operator clears the ghosts
        assertEq(vault.firstPendingDepositId(), 1002);
    }

    /**********************************************************************************************/
    /*** 15. adjustTotalAssets gain sandwich (round 3, re-pinned on 0ebb452)                    ***/
    /**********************************************************************************************/

    event TotalAssetsAdjusted(uint192 chi, int256 deltaTotalAssets);

    // Runs the gain sandwich under the real governance flow: alice holds `tvl`, the spell payload
    // `adjustTotalAssets(+gain)` is public, the attacker deposits `capital` on the instant path,
    // the pauser pauses, the spell adjusts (the gain's backing arrives as spUSDC), the admin
    // unpauses, the attacker exits through the redeem queue at `fee`. With `pauseFirst` the
    // pauser pauses BEFORE the attacker's deposit, which then reverts.
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
        if (pauseFirst) vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDeposit(capital, attacker, 0);               // front-run, instant path

        _returnToVault(spUsdc.convertToShares(gain));          // the gain is real backing
        if (!pauseFirst) _pause();                             // pauser pauses before the spell
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
    // (:279) and `requestDeposit` is `whenNotPaused` (:391), so once the pauser has paused no
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
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
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
        (, , uint256 left) = _rawDeposit(id);
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
                uint256 cId = _cancelTo(bob, bId, bob);

        _returnToVault(spUsdc.convertToShares(50_000e6));
        _adjustTotalAssetsWhilePaused(50_000e6);               // totalSupply == escrow only

        _processRedeems(type(uint256).max, 1);
        uint256 paid = usdc.balanceOf(alice);
        emit log_named_uint("escrowed redeemer paid", paid);
        assertApproxEqAbs(paid, owedBefore + 50_000e6, 1);     // whole gain: she was the supply
        assertEq(paid, 1_049_999_999_997);

        _processCancelledDeposits(type(uint256).max, 1);
        (, , uint256 cLeft) = _rawCancelled(cId);
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
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.ChiTooHigh.selector);
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
        vm.prank(lossManager);
        vm.expectRevert(overflow);
        vault.adjustTotalAssets(-1);                           // drips first: cannot repair
        vm.prank(lossManager);
        vm.expectRevert(overflow);
        vault.adjustTotalAssets(-int256(ta2));
        vm.prank(operator);
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
        vm.prank(operator);
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

    // Access and bounds: LOSS_MANAGER only (role check before the pause check), paused only,
    // delta != 0, totalSupply == 0 panics on a gain, drips first, emits the new chi and delta.
    function test_adjustTotalAssets_accessAndBounds() public {
        address[6] memory who = [redeemFeeSetter, pauser, operator, admin, taker, unpauser];
        for (uint256 i; i < 6; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(_unauthorized(who[i], LOSS_MANAGER_ROLE));
            vault.adjustTotalAssets(1);
        }

        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(1);

        _pause();
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.ZeroDeltaTotalAssets.selector);
        vault.adjustTotalAssets(0);

        vm.prank(lossManager);
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
        vm.prank(lossManager);
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
///      comments refer to `src/SparkPrimeVault.sol` at c512609.
contract AdversarialRound4Test is AdversarialBase {

    event Referral(
        uint16  indexed referral,
        uint256 indexed requestId,
        address         owner,
        address         recipient,
        uint256         assets
    );
    event RedeemRequest(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         sharesToBurn,
        uint256         feeSharesBurned
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
        // the mainnet message; the vault no longer consults `isBlacklisted`, it `try`s the payout.
        _blacklist(blacklisted);
    }

    function _processRedeemsReverts(bytes memory reason) internal {
        vm.prank(operator);
        vm.expectRevert(reason);
        vault.processPendingRedeems(type(uint256).max, 10);
    }

    function _processCancelsReverts(bytes memory reason) internal {
        vm.prank(operator);
        vm.expectRevert(reason);
        vault.processPendingDepositCancellations(type(uint256).max, 10);
    }

    /**********************************************************************************************/
    /*** 1. Blacklisted / vault / spUSDC recipients with no cancel                               ***/
    /**********************************************************************************************/

    // (a) Regression for R4-A at launch-like parameters (minRedeem = 100 shares, fee 1%). There
    // is no request-time check on c512609: a blacklisted recipient is accepted (:454-456, fee
    // burned, entry queued), the owner may repoint a live entry to one (:514-525), and the payout
    // `try`s the recipient (:1001) then falls back to the vault and `claimableAssets`
    // (:1011-1013): the queue moves, alice is paid, the USDC waits in the vault, `claim` reverts
    // inside USDC while blacklisted and pays after. Same exact amounts as round 5.
    function test_fixed_R4A_blacklistedRedeemRecipient_acceptedAtRequest_claimableAtPayout() public {
        _setMinRedeem(100e6);
        _setRedeemFeeRate(0.01e18);

        _deposit(attacker, 200e6);
        _deposit(alice, 1_000_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 supply0     = vault.totalSupply();

        vm.prank(attacker);
        uint256 jamId = vault.requestRedeem(100e6, blacklisted);     // accepted, 1e6 fee burned
        assertEq(jamId, 0);
        assertEq(vault.pendingRedeemShares(), 99e6);
        assertEq(vault.totalSupply(), supply0 - 1e6);

        uint256 aId = _requestRedeem(alice, aliceShares);
        assertEq(vault.pendingRedeemShares(), 99e6 + aliceShares - ((aliceShares * 0.01e18 - 1) / WAD + 1));

        // Repointing to another blacklisted address is the owner's business.
        address mid = makeAddr("mid");
        _blacklist(mid);
        vm.prank(attacker);
        vault.updateRedeemRecipient(jamId, mid);
        vm.prank(victim);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(jamId, victim);

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
        assertEq(vault.totalClaimable(), owed);
        assertEq(usdc.balanceOf(address(vault)), owed);              // escrowed as USDC
        assertEq(usdc.balanceOf(mid), 0);
        assertEq(usdc.balanceOf(alice), aliceOwed);
        // spUSDC burned: one ceil per successful withdraw (:1001 or :1011), nothing extra for
        // the failed try.
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
        assertEq(vault.totalClaimable(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
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

    // (c) V2-13, half fixed: recipient == vault is rejected (:455), recipient == spUSDC is still
    // accepted and the fill donates the USDC to spUSDC's liquidity (its totalAssets is
    // index-based, so the USDC is credited to nobody and spUSDC's taker can pull it). Owner's
    // own choice; nobody else can set it. Open, low.
    function test_BUG_V2_13_redeemRecipientSpUsdcDonates_vaultRejected() public {
        _deposit(attacker, 200_000e6);
        uint256 half = vault.balanceOf(attacker) / 2;

        vm.startPrank(attacker);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestRedeem(half, address(vault));
        vault.requestRedeem(half, address(spUsdc));
        vm.stopPrank();

        uint256 spTotalAssetsBefore = spUsdc.totalAssets();
        uint256 spUsdcBefore        = usdc.balanceOf(address(spUsdc));
        uint256 owed                = vault.convertToAssets(half);

        _processRedeems(type(uint256).max, 10);

        assertEq(owed, 99_999_999_998);
        assertEq(usdc.balanceOf(address(vault)), 0);                 // nothing stranded
        assertEq(usdc.balanceOf(address(spUsdc)), spUsdcBefore);     // leg nets to 0 in spUSDC
        assertApproxEqAbs(spUsdc.totalAssets(), spTotalAssetsBefore - owed, 2);  // but burned
        assertEq(vault.claimableAssets(address(spUsdc)), 0);         // no credit: the try succeeded
        assertEq(usdc.balanceOf(attacker), 0);

        // The donation is spUSDC's to take.
        uint256 excess = usdc.balanceOf(address(spUsdc)) - spUsdc.totalAssets();
        emit log_named_uint("USDC donated to spUSDC (excess over its totalAssets)", excess);
        assertGe(excess + 2, owed);
        vm.prank(spTaker);
        spUsdc.take(excess);
        assertEq(usdc.balanceOf(spTaker), excess);

        // Strangers cannot cause it: the updater is owner-only.
        _deposit(victim, 1_000e6);
        uint256 vId = _requestRedeem(victim, vault.balanceOf(victim));
        vm.prank(attacker);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(vId, address(spUsdc));
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
        (, , uint256 vLeft) = _rawDeposit(vId);
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
                uint256 cId = _cancelTo(bob, bId, bob);

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

        address[5] memory roles = [pauser, admin, redeemFeeSetter, lossManager, taker];
        for (uint256 i; i < 5; ++i) {
            vm.startPrank(roles[i]);
            vm.expectRevert(_unauthorized(roles[i], OPERATOR_ROLE));
            vault.processPendingRedeems(type(uint256).max, 10);
            vm.expectRevert(_unauthorized(roles[i], OPERATOR_ROLE));
            vault.processPendingDepositCancellations(type(uint256).max, 10);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.updateRedeemRecipient(aId, roles[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
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
        vault.grantRole(OPERATOR_ROLE, clean);
        vm.startPrank(clean);
        vault.processPendingRedeems(type(uint256).max, 10);
        vault.processPendingDepositCancellations(type(uint256).max, 10);
        vm.stopPrank();
        assertEq(usdc.balanceOf(clean), lockedRedeem);
        assertEq(usdc.balanceOf(bob),   lockedCancel);
    }

    // Regression for V2-2 / F-1 and round-4 R5-B: the pauser cancel path is gone.
    // `requestDepositCancellation` :421 is owner-only (`NotRequestOwner` for the pauser whatever
    // recipient he names, `VaultIsRecipient` first for the vault), the updaters are owner-only,
    // the pauser's only tool is `pause` (:356). Cancel and its settlement are NOT pause-gated
    // (:405-446, :326-332): a paused vault still refunds exactly spUSDC.redeem.
    function test_fixed_V2_2_pauserHasNoCancelPath_cancelNotPauseGated() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 dId = _deposit(victim, 100e6);
        (, , uint256 vQ) = _depositRequest(dId);
        _requestRedeem(alice, vault.balanceOf(alice));

        vm.startPrank(pauser);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(dId, pauser, vQ);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(dId, victim, vQ);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDepositCancellation(dId, address(vault), vQ);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(0, victim);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositRecipient(dId, victim);
        vault.pause();
        vm.stopPrank();

        // Cancel and settle while paused.
        vm.prank(victim);
        uint256 cId = vault.requestDepositCancellation(dId, victim, vQ);
        (address o, address r, uint256 s) = _cancelledDepositRequest(cId);
        assertEq(o, victim);
        assertEq(r, victim);
        assertEq(s, vQ);
        vm.prank(pauser);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(cId, pauser);
        assertTrue(vault.paused());
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(victim), 99_999_999);
        assertEq(usdc.balanceOf(pauser), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        _unpause();
    }

    /**********************************************************************************************/
    /*** 4. Fresh eyes                                                                          ***/
    /**********************************************************************************************/

    // (a) Regression for R4-B: a cancel naming a blacklisted refund address is accepted
    // (:414-423 has no blacklist check), the owner may repoint a live cancel entry to one
    // (:495-512), and the settlement `try`s `spUSDC.redeem` to the recipient (:982) then falls
    // back to the vault + `claimableAssets` (:992-994): the cancellation queue keeps moving and
    // the victim behind is refunded. Exact amounts (same as round 5).
    function test_fixed_R4B_blacklistedCancelRecipient_acceptedAtRequest_claimableAtSettlement()
        public
    {
        _setMinDeposit(1e6);
        _fillCapacityExactly(alice, 1_000e6);

        uint256 aId = _deposit(attacker, 1e6);                       // queued: capacity full
        uint256 vId = _deposit(victim, 1_000_000e6);                 // queued behind him
        (, , uint256 aQueued) = _depositRequest(aId);

        vm.prank(attacker);
        uint256 jam = vault.requestDepositCancellation(aId, blacklisted, aQueued);   // accepted
        uint256 vc  = _cancelTo(victim, vId, victim);
        assertEq(jam, 0);
        assertEq(vc,  1);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);        // entry deleted, below head
        vault.getPendingDepositRequest(aId);

        address mid = makeAddr("mid");
        _blacklist(mid);
        vm.prank(attacker);
        vault.updateDepositCancellationRecipient(jam, mid);          // owner's choice
        vm.prank(victim);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(jam, victim);

        uint256 spBefore = _vaultSpUsdc();
        _processCancelledDeposits(type(uint256).max, 10);           // no revert

        uint256 refund = spUsdc.convertToAssets(aQueued);            // redeem floors
        assertEq(refund, 999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.claimableAssets(mid), refund);
        assertEq(vault.claimableAssets(blacklisted), 0);
        assertEq(vault.totalClaimable(), refund);
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
        assertEq(vault.totalClaimable(), 0);
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
        emit Referral(777, 0, attacker, victim, 1e6);
        vault.requestDeposit(1e6, victim, 777);
        assertGt(vault.balanceOf(victim), 0);                        // unsolicited shares
        assertEq(vault.balanceOf(attacker), 0);

        // Queued variant: the attacker owns the entry, the recipient cannot touch it, and the
        // attacker can take it back (cancel to himself) before fill.
        _setCapacity(vault.totalSupply());
        vm.prank(attacker);
        uint256 id = vault.requestDeposit(1e6, victim, 777);
        (, , uint256 q) = _depositRequest(id);
        vm.startPrank(victim);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositRecipient(id, victim);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id, victim, q);
        vm.stopPrank();
        _cancelTo(attacker, id, attacker);
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
        emit RedeemRequest(0, alice, alice, 1, 1);
        uint256 id = vault.requestRedeem(1, alice);
        (, , uint256 s) = _redeemRequest(id);
        assertEq(s, 0);
        assertEq(vault.totalSupply(), supply - 1);                   // burned, nothing queued
        assertEq(vault.pendingRedeemShares(), 0);

        // 99 shares: fee rounds 0.99 up to 1 share (1.01%); 100 shares: exactly 1.
        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit RedeemRequest(1, alice, alice, 99, 1);
        vault.requestRedeem(99, alice);
        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit RedeemRequest(2, alice, alice, 100, 1);
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

/// @dev Third contract (jump-tag limit). Line numbers refer to `src/SparkPrimeVault.sol` @ c512609.
contract AdversarialRound5Test is AdversarialBase {

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

    function _ceilBurn(uint256 assets) internal view returns (uint256) {
        return (assets * RAY - 1) / spUsdc.nowChi() + 1;
    }

    /**********************************************************************************************/
    /*** (a) Blacklist fallback                                                                 ***/
    /**********************************************************************************************/

    // Redeem queue, every combination of (blacklisted at request / at payout / at claim), with a
    // partial fill while blacklisted and the remainder paid directly after un-blacklisting.
    function test_blacklist_redeemQueue_fullMatrix() public {
        _deposit(carol, 100e6);
        _deposit(alice, 1_000e6);
        _deposit(bob,   1_000e6);
        uint256 carolShares = vault.balanceOf(carol);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares   = vault.balanceOf(bob);

        // 1. blacklisted at request: accepted (no check at :454-456), fee burned, escrowed.
        _setRedeemFeeRate(0.01e18);
        uint256 carolQ = carolShares - ((carolShares * 0.01e18 - 1) / WAD + 1);
        {
            uint256 supply = vault.totalSupply();
            vm.prank(carol);
            assertEq(vault.requestRedeem(carolShares, sanctioned), 0);
            assertEq(vault.totalSupply(), supply - (carolShares - carolQ));
            assertEq(vault.balanceOf(carol), 0);
            assertEq(vault.pendingRedeemShares(), carolQ);
        }
        _setRedeemFeeRate(0);

        // 2. clean at request, blacklisted at payout: partial fill goes to claimable.
        uint256 aId = _requestRedeem(alice, aliceShares);
        _requestRedeem(bob, bobShares);
        _blacklist(alice);

        uint256 half   = aliceShares / 2;
        uint256 owed1  = vault.convertToAssets(half);
        uint256 owedC  = vault.convertToAssets(carolQ);
        uint256 sp0    = _vaultSpUsdc();
        _processRedeems(carolQ + half, 10);                      // carol in full, budget stops inside alice
        assertEq(owed1, 499_999_998);
        assertEq(owedC, 98_999_997);
        assertEq(vault.firstPendingRedeemId(), 1);               // partial: alice still at the head
        assertEq(vault.claimableAssets(sanctioned), owedC);
        assertEq(vault.claimableAssets(alice), owed1);
        assertEq(vault.totalClaimable(), owedC + owed1);
        assertEq(usdc.balanceOf(address(vault)), owedC + owed1);
        assertEq(sp0 - _vaultSpUsdc(), _ceilBurn(owedC) + _ceilBurn(owed1));   // :1011 ceil burn, nothing extra
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
        assertEq(vault.firstPendingRedeemId(), 3);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.balanceOf(address(vault)), 0);

        // 5. claim pays exactly the credited part; a second claim is `NothingToClaim`.
        assertEq(vault.claim(alice), owed1);
        assertEq(usdc.balanceOf(alice), owed1 + owed2);
        assertEq(usdc.balanceOf(alice), 999_999_997);           // bob - 1: one extra floor for the split, none for the fallback
        assertEq(usdc.balanceOf(address(vault)), owedC);
        assertEq(vault.totalClaimable(), owedC);
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(alice);
    }

    // Cancellation queue, same matrix: `spUSDC.redeem` to the vault (:942) floors, so the
    // claimable amount equals exactly what a clean recipient would have received.
    function test_blacklist_cancelQueue_fullMatrix() public {
        _fillCapacityExactly(carol, 1_000e6);
        uint256 aId = _deposit(alice, 1_000e6);
        uint256 bId = _deposit(bob,   1_000e6);
        (, , uint256 aQ) = _depositRequest(aId);
        (, , uint256 bQ) = _depositRequest(bId);

        // 1. blacklisted refund address at cancel: accepted (no check at :414-423). A 1-share
        //    slice to `sanctioned` is cancel id 0; the entry stays live with aQ - 1.
        vm.prank(alice);
        uint256 c0 = vault.requestDepositCancellation(aId, sanctioned, 1);
        assertEq(c0, 0);
        (, , uint256 stillQ) = _depositRequest(aId);
        assertEq(stillQ, aQ - 1);

        // 2. clean at cancel, blacklisted at settlement, partial.
        uint256 ca = _cancelTo(alice, aId, alice);               // id 1, aQ - 1 shares
        _cancelTo(bob, bId, bob);                                // id 2
        assertEq(ca, 1);
        _blacklist(alice);

        uint256 half  = (aQ - 1) / 2;
        uint256 owed1 = spUsdc.convertToAssets(half);
        uint256 sp0   = _vaultSpUsdc();
        _processCancelledDeposits(1 + half, 10);                 // slice 0 in full, then half of alice
        assertEq(owed1, 499_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        assertEq(vault.claimableAssets(sanctioned), 1);          // convertToAssets(1 share) = 1 wei
        assertEq(vault.claimableAssets(alice), owed1);
        assertEq(vault.totalClaimable(), owed1 + 1);
        assertEq(usdc.balanceOf(address(vault)), owed1 + 1);
        assertEq(sp0 - _vaultSpUsdc(), 1 + half);                // redeem burns exactly the shares
        (, , uint256 left) = _cancelledDepositRequest(ca);
        assertEq(left, aQ - 1 - half);

        // 3. claim while blacklisted reverts; 4. remainder after un-blacklisting is direct.
        vm.expectRevert(BLACKLISTED);
        vault.claim(alice);
        _unblacklist(alice);
        uint256 owed2 = spUsdc.convertToAssets(aQ - 1 - half);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), owed2);
        assertEq(usdc.balanceOf(bob), spUsdc.convertToAssets(bQ));
        assertEq(usdc.balanceOf(bob), 999_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);

        // 5. claim exact: alice ends 1 share + at most one floor behind bob.
        assertEq(vault.claim(alice), owed1);
        assertEq(usdc.balanceOf(alice), owed1 + owed2);
        assertEq(usdc.balanceOf(alice), 999_999_998);            // bob - 1: the 1-share slice went to `sanctioned`
        assertEq(usdc.balanceOf(address(vault)), 1);
        assertEq(vault.totalClaimable(), 1);
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

    // V2-13 for the cancellation queue, half fixed: the vault as refund recipient is rejected
    // (:415, for the updater :500 too), spUSDC is still accepted and `redeem(.., spUSDC, vault)`
    // donates the USDC to spUSDC's liquidity with no claimable credit (the try succeeds).
    // Owner's own choice only; nobody else can set it. Open, low.
    function test_BUG_V2_13_cancelRecipientSpUsdcDonates_vaultRejected() public {
        _fillCapacityExactly(carol, 1_000e6);
        uint256 a = _deposit(attacker, 100e6);
        uint256 b = _deposit(attacker, 100e6);
        (, , uint256 aQ) = _depositRequest(a);

        vm.startPrank(attacker);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDepositCancellation(a, address(vault), aQ);
        uint256 c = vault.requestDepositCancellation(b, address(spUsdc), aQ);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositCancellationRecipient(c, address(vault));
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(c, bob);

        uint256 spUsdcLiquidity = usdc.balanceOf(address(spUsdc));
        uint256 spTotal         = spUsdc.totalAssets();
        _processCancelledDeposits(type(uint256).max, 10);

        uint256 refund = spUsdc.convertToAssets(aQ);
        assertEq(refund, 99_999_999);
        assertEq(usdc.balanceOf(address(vault)), 0);             // nothing stranded
        assertEq(vault.claimableAssets(address(spUsdc)), 0);
        assertEq(vault.totalClaimable(), 0);
        assertEq(usdc.balanceOf(address(spUsdc)), spUsdcLiquidity);            // leg nets 0
        assertApproxEqAbs(spUsdc.totalAssets(), spTotal - refund, 2);          // but burned
        assertEq(usdc.balanceOf(attacker), 0);
        uint256 excess = usdc.balanceOf(address(spUsdc)) - spUsdc.totalAssets();
        assertGe(excess + 2, refund);
        vm.prank(spTaker);
        spUsdc.take(excess);                                     // spUSDC's taker can pull it
        assertEq(usdc.balanceOf(spTaker), excess);
    }

    // Info: if Circle sanctions the VAULT itself, deposits revert in USDC, payouts to clean
    // recipients still work (spUSDC -> recipient), but a mid-flight-blacklisted recipient makes
    // the `try` (:1001) fail AND the fallback withdraw-to-vault (:1011) revert, which propagates
    // and blocks that queue; `claim` is dead. Only the owner's repoint to a clean address
    // unblocks. Out of the trust model (USDC risk), pinned.
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
        vm.prank(operator);
        vm.expectRevert(BLACKLISTED);                            // :1011 withdraw to the vault
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

                uint256 c = _cancelTo(alice, d1, clean);  // clean recipient: ok
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
    //   (iv)  deposit -> pause -> adjust -> unpause, operator never pays: dilution is already
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
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
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

        // (iv) operator never pays: alice is already diluted on paper.
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
                _cancelTo(carol, d2, carol);
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
    // that leaves only the cancelled depositor's backing, the operator can pay a redeemer from
    // it (`availableLiquidAssets` :789 counts all spUSDC), and the refund is then unpayable.
    // The operator chooses who gets paid under shortage.
    function test_BUG_F2_redeemsCanConsumeCancellationBacking_afterTake() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 aShares = vault.balanceOf(alice);
        uint256 bId = _deposit(bob, 1_000e6);
        (, , uint256 bQ) = _depositRequest(bId);
                _cancelTo(bob, bId, bob);

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

    // When the vault is fully backed, the operator's ordering and chunking change no payout:
    // every path is priced by the indexes alone. Same end state in three orders.
    function test_rebalancer_orderingDoesNotChangePayouts_whenBacked() public {
        _fillCapacityExactly(alice, 1_000e6);
        uint256 aShares = vault.balanceOf(alice);
        uint256 d1 = _deposit(bob, 300e6);
        uint256 d2 = _deposit(carol, 200e6);
                _cancelTo(carol, d2, carol);
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

    // Regression for C-1 / R5-4: `_processPendingRedeems` recomputes the liquidity bound PER
    // ENTRY (`fillable_ = min(remaining_, convertToShares(availableLiquidAssets()))` :953) and
    // breaks at 0 (:955), so every withdraw is covered by the live balance and a batched call
    // cannot revert on spUSDC ceil-rounding. Round-5 minimal reproduction (rounding worker):
    // vault holds 3401 spUSDC, entries 108 + 3420 spPRIME shares, `processPendingRedeems(max, 2)`
    // reverted `SparkVault/insufficient-balance`. Now it pays 109 + 3451 USDC in one call and
    // leaves exactly 1 spUSDC share and 2 spPRIME shares (the clamp of 1 USDC is 0 shares).
    function test_fixed_C1_batch3401_paysInOneCall_dustExact() public {
        _deposit(alice, 1_000e6);
        _requestRedeem(alice, 108);
        _requestRedeem(alice, 3420);
        _take(_vaultSpUsdc() - 3401);
        assertEq(_vaultSpUsdc(), 3401);
        assertEq(vault.availableLiquidAssets(), 3563);
        assertEq(vault.convertToShares(3563), 3528);

        _processRedeems(type(uint256).max, 2);                   // no revert

        assertEq(usdc.balanceOf(alice), 109 + 3451);
        assertEq(_vaultSpUsdc(), 1);                             // 1 spUSDC share of dust
        assertEq(vault.pendingRedeemShares(), 2);                // 2 spPRIME shares unpayable
        assertEq(vault.firstPendingRedeemId(), 1);               // entry 1 partially filled
        assertEq(vault.availableLiquidAssets(), 1);
        assertEq(vault.convertToShares(1), 0);                   // clamp 0: stays until backing returns
        _processRedeems(type(uint256).max, 2);                   // still no revert, no progress
        assertEq(vault.pendingRedeemShares(), 2);
        _returnToVault(10);
        _processRedeems(type(uint256).max, 2);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(usdc.balanceOf(alice), 109 + 3451 + 2);
    }

    // Regression for C-1 (fresh-eyes FE-6): three entries (11, 11, rest) of alice's full
    // 990_405_184_109 shares, full backing, `processPendingRedeems(max, max)` reverted
    // `SparkVault/insufficient-balance`. Now it pays 11 + 11 + 999_999_999_974 in one call. The
    // R5-10 residual is exact: the per-entry bound floors twice (`maxWithdraw` :354 of spUSDC,
    // `convertToShares` :832), so the last entry of a fully drained vault is clamped 2 shares
    // short; those 2 spPRIME shares (2 wei) stay queued, with 1 spUSDC share of dust in the
    // vault, until backing is topped up. No revert, no lock-up beyond the dust.
    function test_fixed_C1_elevenElevenRest_paysInOneCall_R5_10_dustExact() public {
        _deposit(alice, 1_000_000e6);
        uint256 shares = vault.balanceOf(alice);
        assertEq(shares, 990_405_184_109);
        _requestRedeem(alice, 11);
        _requestRedeem(alice, 11);
        _requestRedeem(alice, shares - 22);
        uint256 sp0 = _vaultSpUsdc();

        _processRedeems(type(uint256).max, type(uint256).max);   // no revert

        assertEq(usdc.balanceOf(alice), 11 + 11 + 999_999_999_974);
        assertEq(vault.firstPendingRedeemId(), 2);               // last entry partial
        assertEq(vault.pendingRedeemShares(), 2);                // 2 shares = 2 wei unpayable
        assertEq(sp0 - _vaultSpUsdc(), _ceilBurn(11) + _ceilBurn(11) + _ceilBurn(999_999_999_974));
        assertEq(_vaultSpUsdc(), 1);                             // 1 spUSDC share of dust
        assertEq(vault.availableLiquidAssets(), 1);
        assertEq(vault.convertToShares(1), 0);                   // clamp 0: nothing more fillable
        _processRedeems(type(uint256).max, type(uint256).max);   // no revert, no progress
        assertEq(vault.pendingRedeemShares(), 2);

        _returnToVault(10);                                      // any top-up clears it
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.firstPendingRedeemId(), 3);
        assertEq(usdc.balanceOf(alice), 999_999_999_998);        // = a single full redeem's payout
    }

    // The law behind the fix, fuzzed: for n entries and ANY backing (full to a few shares short)
    // the batched call never reverts, pays exactly what one-per-call pays, and the vault's spUSDC
    // never goes below 0. Entries that cannot be covered stay queued (break at :955).
    function testFuzz_fixed_C1_batchNeverReverts_equalsChunked(
        uint256 seed, uint256 n, uint256 cut, uint256 vsrS, uint256 secs
    ) public {
        n    = bound(n, 2, 5);
        vsrS = bound(vsrS, RAY, MAX_VSR);
        secs = bound(secs, 0, 365 days);
        _setSpUsdcVsr(vsrS);
        _warpAndDrip(secs);
        _setSpUsdcVsr(RAY);

        address[5] memory users;
        for (uint256 i; i < n; ++i) {
            users[i] = makeAddr(string(abi.encodePacked("u", i)));
            uint256 amt = 1 + uint256(keccak256(abi.encode(seed, i))) % 1_000_000e6;
            _deposit(users[i], amt);
        }
        for (uint256 i; i < n; ++i) _requestRedeem(users[i], vault.balanceOf(users[i]));
        cut = bound(cut, 0, _vaultSpUsdc());
        if (cut != 0) _take(cut);
        uint256 snap = vm.snapshotState();

        vm.prank(operator);
        (bool ok, ) = address(vault).call(
            abi.encodeCall(vault.processPendingRedeems, (type(uint256).max, type(uint256).max))
        );
        assertTrue(ok, "batched call reverted");
        uint256[5] memory paid;
        for (uint256 i; i < n; ++i) paid[i] = usdc.balanceOf(users[i]);
        uint256 pendingBatched = vault.pendingRedeemShares();

        vm.revertToState(snap);
        for (uint256 i; i < n; ++i) {
            uint256 head = vault.firstPendingRedeemId();
            _processRedeems(type(uint256).max, 1);
            if (vault.firstPendingRedeemId() == head) break;   // partial: the batch stopped here too
        }
        for (uint256 i; i < n; ++i) assertEq(usdc.balanceOf(users[i]), paid[i], "chunked != batched");
        assertEq(vault.pendingRedeemShares(), pendingBatched);
    }

    // Round-5 search kept as a property: 8 odd-sized entries, backing from exact to 400 shares
    // short, batched never reverts and chunked pays the same.
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
            vm.prank(operator);
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
                _cancelTo(attacker, id, attacker);
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

    // What still works while paused: drip, take, claim, transfer/approve/permit, setVSR,
    // setCapacity, the three updaters, adjustTotalAssets, and (new on c512609) deposit
    // cancellation + its settlement (:405, :326); what does not: requestDeposit, requestRedeem,
    // processPendingDeposits, processPendingRedeems. `take` during an incident is the one worth
    // a note: the taker can empty the backing while nobody can exit.
    function test_pause_matrix() public {
        _fillCapacityExactly(carol, 1_000e6);
        uint256 dId = _deposit(alice, 100e6);
        uint256 dId2 = _deposit(alice, 100e6);
        _setCapacity(type(uint128).max);
        uint256 cShares = vault.balanceOf(carol);
                uint256 cId = _cancelTo(alice, dId2, alice);
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
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDeposit(1e6, bob, 0);
        vm.prank(carol);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestRedeem(1, carol);
        vm.startPrank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingDeposits(1, 1);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingRedeems(1, 1);
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
        _setCapacity(type(uint128).max);
        _adjustTotalAssets(1);
        _take(1);
        assertEq(spUsdc.balanceOf(taker), 1);
        // Cancellation request (partial and full) and settlement run while paused.
        (, , uint256 dQ) = _depositRequest(dId);
        vm.prank(alice);
        vault.requestDepositCancellation(dId, alice, 1);
        uint256 cId2 = _cancelTo(alice, dId, alice);
        (, , uint256 c2) = _cancelledDepositRequest(cId2);
        assertEq(c2, dQ - 1);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(usdc.balanceOf(clean), spUsdc.convertToAssets(dQ));   // cId was repointed to clean
        assertEq(usdc.balanceOf(alice), spUsdc.convertToAssets(1) + spUsdc.convertToAssets(dQ - 1));
        assertTrue(vault.paused());
    }

}

/**********************************************************************************************/
/*** Round 6 (c512609): try/catch fallback, partial cancels, LOSS_MANAGER and OPERATOR as    ***/
/*** adversaries, ERC20 ordering, ordering fuzzes                                            ***/
/**********************************************************************************************/

/// @dev Fourth contract (jump-tag limit). Line numbers refer to `src/SparkPrimeVault.sol` @ c512609.
contract AdversarialRound6Test is AdversarialBase {

    event DepositCancellationRequest(
        uint256 indexed depositRequestId,
        uint256 indexed cancelRequestId,
        address indexed recipient,
        uint256         sharesCancelled
    );
    event ClaimableAssetsIncreased(address indexed recipient, uint256 increase);

    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal carol    = makeAddr("carol");
    address internal attacker = makeAddr("attacker");
    address internal victim   = makeAddr("victim");
    address internal clean    = makeAddr("clean");

    function _ceilBurn(uint256 assets) internal view returns (uint256) {
        return (assets * RAY - 1) / spUsdc.nowChi() + 1;
    }

    /**********************************************************************************************/
    /*** (a) The try/catch fallback: what can and cannot trigger it                             ***/
    /**********************************************************************************************/

    // A recipient that is a contract reverting on every call cannot make `withdraw`/`redeem`
    // revert for its own reasons: neither USDC (no hooks) nor spUSDC (`_pushAsset` is a plain
    // transfer) ever calls the recipient. Both queues pay it directly, the fallback never runs,
    // `claimableAssets` stays 0. Also `_mint` to it (deposit path) works.
    function test_fallback_contractRecipientCannotTriggerFallback() public {
        RevertingRecipient sink = new RevertingRecipient();
        _deposit(alice, 1_000e6);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.requestRedeem(shares / 2, address(sink));
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(address(sink)), vault.convertToAssets(shares / 2));
        assertEq(usdc.balanceOf(address(sink)), 499_999_998);
        assertEq(vault.claimableAssets(address(sink)), 0);
        assertEq(vault.totalClaimable(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);

        _setCapacity(vault.totalSupply());
        _fund(alice, 100e6);
        vm.prank(alice);
        uint256 dId = vault.requestDeposit(100e6, address(sink), 0);     // queued, mints to sink later
        (, , uint256 q) = _depositRequest(dId);
        vm.prank(alice);
        vault.requestDepositCancellation(dId, address(sink), q / 2);    // half refunded to sink
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(address(sink)), 499_999_998 + spUsdc.convertToAssets(q / 2));
        assertEq(vault.claimableAssets(address(sink)), 0);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(address(sink)), vault.convertToShares(spUsdc.convertToAssets(q - q / 2)));
        assertGt(vault.balanceOf(address(sink)), 0);
    }

    // The only revert the fallback is meant for is a recipient-specific one (the blacklist). A
    // USDC-wide failure (Circle pause, simulated by reverting every `transfer`) is not: the try
    // fails, the fallback withdraw-to-vault fails too, the revert propagates with USDC's reason
    // and the whole batch is undone, both queues. Nothing is parked, nothing is credited.
    function test_fallback_usdcWideRevert_isNotRecipientSpecific_batchReverts() public {
        _fillCapacityExactly(carol, 1_000e6);
        _deposit(alice, 1_000e6);                                    // queued
        uint256 dId = _depositQueueLength() - 1;
        _cancelTo(alice, dId, alice);
        uint256 cShares = vault.balanceOf(carol);
        _requestRedeem(carol, cShares / 2);
        _requestRedeem(carol, cShares / 4);

        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(usdc.transfer.selector), "FiatToken: paused");

        vm.prank(operator);
        vm.expectRevert("FiatToken: paused");
        vault.processPendingRedeems(type(uint256).max, 10);
        vm.prank(operator);
        vm.expectRevert("FiatToken: paused");
        vault.processPendingDepositCancellations(type(uint256).max, 10);
        vm.prank(operator);
        vm.expectRevert("FiatToken: paused");
        vault.processPendingRedeems(1, 1);                           // even a 1-share fill

        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(vault.firstPendingDepositCancellationId(), 0);
        assertEq(vault.pendingRedeemShares(), cShares / 2 + cShares / 4);
        assertEq(vault.claimableAssets(carol), 0);
        assertEq(vault.claimableAssets(alice), 0);
        assertEq(vault.totalClaimable(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);

        vm.clearMockedCalls();
        _processRedeems(type(uint256).max, 10);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(carol), vault.convertToAssets(cShares / 2) + vault.convertToAssets(cShares / 4));
        assertEq(usdc.balanceOf(alice), 999_999_999);
    }

    // A liquidity shortfall of exactly the fill amount is impossible by construction: the fill is
    // bounded per entry by `convertToShares(maxWithdraw(vault))` (:953) and `convertToAssets`
    // floors (:958), so `assets_ <= maxWithdraw <= liquidity`. Exact boundary: with spUSDC
    // liquidity equal to the owed amount the double floor clamps the fill ONE SHARE SHORT
    // (R5-10 dust: `convertToShares(convertToAssets(s)) == s - 1` here), a partial fill, paid
    // directly, nothing credited; the full fill needs 1 wei of liquidity more than owed.
    function test_fallback_exactLiquidityBoundary_neverCredits_R5_10_oneShareShort() public {
        _deposit(alice, 1_000e6);
        uint256 shares = vault.balanceOf(alice);
        _requestRedeem(alice, shares);
        uint256 owed = vault.convertToAssets(shares);
        assertEq(owed, 999_999_998);
        assertEq(vault.convertToShares(owed), shares - 1);              // the double floor

        uint256 snap = vm.snapshotState();
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - owed);
        assertEq(vault.availableLiquidAssets(), owed);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), vault.convertToAssets(shares - 1));
        assertEq(usdc.balanceOf(alice), 999_999_997);
        assertEq(vault.pendingRedeemShares(), 1);                       // 1 share (1 wei) waits
        assertEq(vault.claimableAssets(alice), 0);
        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(usdc.balanceOf(address(spUsdc)), 1);                   // 1 wei of liquidity unused

        vm.revertToState(snap);
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - (owed + 1));
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), owed);                          // full fill, direct
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.claimableAssets(alice), 0);
        assertEq(usdc.balanceOf(address(spUsdc)), 1);
    }

    // Fuzzed: for any spUSDC liquidity, any vault backing (after `take`) and any entry sizes, a
    // clean recipient is never credited to `claimableAssets` and the batch never reverts. The
    // fallback only ever fires for the blacklisted recipient in the mix.
    function testFuzz_fallback_onlyBlacklistedRecipientIsCredited(
        uint256 a1, uint256 a2, uint256 a3, uint256 drain, uint256 cut
    ) public {
        a1 = bound(a1, 1e6, 1_000_000e6);
        a2 = bound(a2, 1e6, 1_000_000e6);
        a3 = bound(a3, 1e6, 1_000_000e6);
        _deposit(alice, a1);
        _deposit(bob, a2);
        _deposit(carol, a3);
        _requestRedeem(alice, vault.balanceOf(alice));
        uint256 bShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bShares, victim);                        // victim gets blacklisted
        _requestRedeem(carol, vault.balanceOf(carol));
        _blacklist(victim);

        drain = bound(drain, 0, usdc.balanceOf(address(spUsdc)));
        cut   = bound(cut, 0, _vaultSpUsdc());
        if (drain != 0) _drainSpUsdcLiquidity(drain);
        if (cut != 0)   _take(cut);

        vm.prank(operator);
        (bool ok, ) = address(vault).call(
            abi.encodeCall(vault.processPendingRedeems, (type(uint256).max, 10))
        );
        assertTrue(ok, "batch reverted");
        assertEq(vault.claimableAssets(alice), 0);
        assertEq(vault.claimableAssets(carol), 0);
        assertEq(vault.claimableAssets(bob), 0);
        assertEq(vault.totalClaimable(), vault.claimableAssets(victim));
        assertEq(usdc.balanceOf(address(vault)), vault.claimableAssets(victim));
    }

    // Gas: the `try` (:1001) gets 63/64 of the remaining gas. Can an operator-sized gas limit
    // make the try run out of gas while the catch path (:1011-1013, a second withdraw plus two
    // SSTOREs) still succeeds, parking a clean recipient's USDC in the vault? Scanned every gas
    // limit from 30k to 600k in 1k steps on `processPendingRedeems{gas: g}(max, 1)`: each call
    // either reverts (OOG) or pays the recipient directly; `claimableAssets` is never credited
    // for a clean recipient. Reason: if 63/64 R < G_try then R / 64 < G_try / 63 < G_catch.
    function test_fallback_gasScan_noParkingForCleanRecipient() public {
        _deposit(alice, 1_000e6);
        uint256 shares = vault.balanceOf(alice);
        _requestRedeem(alice, shares);
        uint256 owed = vault.convertToAssets(shares);
        bytes memory data = abi.encodeCall(vault.processPendingRedeems, (type(uint256).max, 1));

        uint256 snap = vm.snapshotState();
        uint256 successes;
        uint256 firstSuccess;
        for (uint256 g = 30_000; g <= 600_000; g += 1_000) {
            vm.revertToState(snap);
            vm.prank(operator);
            (bool ok, ) = address(vault).call{gas: g}(data);
            if (ok) {
                if (successes == 0) firstSuccess = g;
                ++successes;
                assertEq(usdc.balanceOf(alice), owed, "not paid directly");
                assertEq(vault.claimableAssets(alice), 0, "clean recipient parked");
                assertEq(usdc.balanceOf(address(vault)), 0);
            } else {
                assertEq(usdc.balanceOf(alice), 0);
                assertEq(vault.claimableAssets(alice), 0);
                assertEq(vault.pendingRedeemShares(), shares);
            }
        }
        emit log_named_uint("smallest gas limit that fills (1k granularity)", firstSuccess);
        assertGt(successes, 0);
        assertLt(firstSuccess, 300_000);
    }

    // Same scan with the recipient blacklisted: every successful call credits exactly `owed`,
    // never more, never pays USDC out, and the OOG calls leave nothing behind.
    function test_fallback_gasScan_blacklistedRecipientCreditedExactlyOrReverted() public {
        _deposit(alice, 1_000e6);
        uint256 shares = vault.balanceOf(alice);
        _requestRedeem(alice, shares);
        uint256 owed = vault.convertToAssets(shares);
        _blacklist(alice);
        bytes memory data = abi.encodeCall(vault.processPendingRedeems, (type(uint256).max, 1));

        uint256 snap = vm.snapshotState();
        uint256 successes;
        for (uint256 g = 30_000; g <= 600_000; g += 1_000) {
            vm.revertToState(snap);
            vm.prank(operator);
            (bool ok, ) = address(vault).call{gas: g}(data);
            if (ok) {
                ++successes;
                assertEq(vault.claimableAssets(alice), owed);
                assertEq(usdc.balanceOf(address(vault)), owed);
                assertEq(vault.totalClaimable(), owed);
            } else {
                assertEq(vault.claimableAssets(alice), 0);
                assertEq(usdc.balanceOf(address(vault)), 0);
            }
        }
        assertGt(successes, 0);
    }

    /**********************************************************************************************/
    /*** (b) Partial cancels                                                                    ***/
    /**********************************************************************************************/

    // Bounds and bookkeeping of `requestDepositCancellation(id, recipient, savingsShares)`
    // (:405-446): below `minDepositCancellation` -> `BelowMinDepositCancellation`, above the
    // entry -> `SavingsSharesTooHigh`, exact -> entry deleted, less -> entry decremented; each
    // slice is its own cancel entry carrying the owner; pending counters move exactly; event
    // shape `(depositRequestId, cancelRequestId, recipient, sharesCancelled)`.
    function test_cancel_partial_boundsAndAccounting() public {
        _setMinDepositCancellation(10);
        _fillCapacityExactly(carol, 1_000e6);
        uint256 id = _deposit(alice, 100e6);
        (, , uint256 q) = _depositRequest(id);
        assertEq(q, 95_453_269);

        vm.startPrank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, 9);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, alice, q + 1);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.requestDepositCancellation(id, address(0), 10);

        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 0, bob, 10);
        uint256 c0 = vault.requestDepositCancellation(id, bob, 10);      // slice 1 to bob
        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 1, alice, 1_000);
        uint256 c1 = vault.requestDepositCancellation(id, alice, 1_000); // slice 2 to alice
        vm.stopPrank();

        assertEq(c0, 0);
        assertEq(c1, 1);
        (address o, , uint256 left) = _depositRequest(id);
        assertEq(o, alice);
        assertEq(left, q - 1_010);
        assertEq(vault.pendingDepositSavingsShares(), q - 1_010);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 1_010);
        (address o0, address r0, uint256 s0) = _cancelledDepositRequest(c0);
        assertEq(o0, alice);                                              // owner carries over
        assertEq(r0, bob);
        assertEq(s0, 10);
        assertEq(vault.firstPendingDepositId(), id);                      // still live: no walk

        // The exact remainder deletes the entry and the self-skip advances the head.
        vm.prank(alice);
        vault.requestDepositCancellation(id, alice, q - 1_010);
        (address o2, address r2, uint256 s2) = _rawDeposit(id);
        assertEq(o2, address(0));
        assertEq(r2, address(0));
        assertEq(s2, 0);
        assertEq(vault.firstPendingDepositId(), id + 1);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), q);

        // A closed entry cannot be cancelled again, by anyone.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, alice, 10);

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob), spUsdc.convertToAssets(10));
        assertEq(usdc.balanceOf(bob), 10);
        assertEq(usdc.balanceOf(alice), spUsdc.convertToAssets(1_000) + spUsdc.convertToAssets(q - 1_010));
        assertEq(usdc.balanceOf(alice), 99_999_988);                      // 100e6 - 10 - two floors
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // Cancel-then-refill ordering: a partially cancelled entry keeps its place and its remainder
    // is filled at the live indexes; cancelling the remainder AFTER a partial fill works and the
    // head moves on. Refund = `spUSDC.redeem` of the slices, mint = `convertToShares` of the
    // rest: nothing is double counted, `pendingDepositSavingsShares` ends at 0.
    function test_cancel_sliceThenRefill_thenCancelRemainderAfterPartialFill() public {
        _fillCapacityExactly(carol, 1_000e6);
        uint256 id  = _deposit(alice, 100e6);
        uint256 id2 = _deposit(bob, 50e6);
        (, , uint256 q)  = _depositRequest(id);
        (, , uint256 q2) = _depositRequest(id2);

        // Slice a third out, then the planner fills what is left of alice and all of bob.
        vm.prank(alice);
        vault.requestDepositCancellation(id, alice, q / 3);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(alice), vault.convertToShares(spUsdc.convertToAssets(q - q / 3)));
        assertEq(vault.balanceOf(bob),   vault.convertToShares(spUsdc.convertToAssets(q2)));
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(), id2 + 1);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), spUsdc.convertToAssets(q / 3));

        // Partial fill first, then cancel the remainder: head advances, refund exact.
        _setCapacity(vault.totalSupply());
        uint256 id3 = _deposit(victim, 100e6);
        (, , uint256 q3) = _depositRequest(id3);
        _setCapacity(type(uint128).max);
        _processDeposits(q3 / 2, 10);                                     // budget stops mid-entry
        (, , uint256 left3) = _depositRequest(id3);
        assertEq(left3, q3 - q3 / 2);
        assertEq(vault.firstPendingDepositId(), id3);
        assertEq(vault.balanceOf(victim), vault.convertToShares(spUsdc.convertToAssets(q3 / 2)));
        vm.prank(victim);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id3, victim, q3);                // the filled part is gone
        vm.prank(victim);
        vault.requestDepositCancellation(id3, victim, q3 - q3 / 2);
        assertEq(vault.firstPendingDepositId(), id3 + 1);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(victim), spUsdc.convertToAssets(q3 - q3 / 2));
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // Griefing the cancellation queue with minimum-sized slices: one deposit of N shares split
    // into N cancels of `minDepositCancellation` each. Every slice is a full `spUSDC.redeem` for
    // the planner (~37k warm). Measured per slice; `minDepositCancellation` in spUSDC shares is
    // the only dial (at 1e6 shares a 1M-USDC deposit yields at most ~955 slices).
    function test_cancel_minSlices_griefCancelQueue_gasPerSlice() public {
        _fillCapacityExactly(carol, 1_000e6);
        _fund(attacker, 1_000e6);
        vm.prank(attacker);
        uint256 id = vault.requestDeposit(1_000e6, attacker, 0);

        vm.startPrank(attacker);
        uint256 g0 = gasleft();
        vault.requestDepositCancellation(id, attacker, 1);
        uint256 perSlice = g0 - gasleft();
        for (uint256 i; i < 499; ++i) vault.requestDepositCancellation(id, attacker, 1);
        vm.stopPrank();
        assertEq(_cancelledDepositQueueLength(), 500);
        assertEq(vault.firstPendingDepositId(), 1);                       // entry still live

        uint256 vId = _deposit(victim, 100e6);
        uint256 vc  = _cancelTo(victim, vId, victim);
        assertEq(vc, 500);

        vm.prank(operator);
        uint256 g1 = gasleft();
        vault.processPendingDepositCancellations(type(uint256).max, 500);
        uint256 plannerGas = g1 - gasleft();
        assertEq(vault.firstPendingDepositCancellationId(), 500);
        assertEq(usdc.balanceOf(attacker), 500);                          // 1 wei per 1-share slice
        assertEq(usdc.balanceOf(victim), 0);
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(victim), 99_999_999);

        uint256 perEntry = plannerGas / 500;
        emit log_named_uint("attacker gas per 1-share cancel slice", perSlice);
        emit log_named_uint("planner gas per 1-share cancelled entry", perEntry);
        emit log_named_uint("slices settleable per 30M block", 30_000_000 / perEntry);
        assertLt(perEntry, 60_000);
        assertGt(30_000_000 / perEntry, 500);

        // With a realistic minimum the same deposit cannot be split below it.
        _setMinDepositCancellation(1e6);
        vm.prank(attacker);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, attacker, 1e6 - 1);
    }

    // Partial-cancel accounting, fuzzed: random slices (>= min) out of one entry, the planner
    // settles some and fills the rest; refunds + mint never exceed the original deposit and the
    // three counters end consistent.
    function testFuzz_cancel_slicesAccounting(uint256 seed, uint256 amt, uint256 k) public {
        amt = bound(amt, 1e6, 1_000_000e6);
        k   = bound(k, 1, 6);
        _fillCapacityExactly(carol, 1_000e6);
        uint256 id = _deposit(alice, amt);
        (, , uint256 q) = _depositRequest(id);
        uint256 cancelled;
        for (uint256 i; i < k; ++i) {
            (, , uint256 left) = _depositRequest(id);
            if (left == 0) break;
            uint256 slice = 1 + uint256(keccak256(abi.encode(seed, i))) % left;
            vm.prank(alice);
            vault.requestDepositCancellation(id, alice, slice);
            cancelled += slice;
            if (slice == left) break;
        }
        assertEq(vault.pendingCancelledDepositSavingsShares(), cancelled);
        assertEq(vault.pendingDepositSavingsShares(), q - cancelled);
        _processCancelledDeposits(type(uint256).max, 10);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        uint256 refund = usdc.balanceOf(alice);
        uint256 minted = vault.assetsOf(alice);
        assertLe(refund + minted, amt, "value created");
        assertGe(refund + minted + k + 3, amt, "value lost beyond rounding");
    }

    /**********************************************************************************************/
    /*** (c) LOSS_MANAGER as a hot wallet (C-3 re-rated)                                       ***/
    /**********************************************************************************************/

    // C-3 on c512609: `adjustTotalAssets` (:262-283) is now a hot-wallet role. A compromised
    // LOSS_MANAGER key plus a pause (own PAUSER key, or any legitimate pause) writes every
    // holder to 0 in one call (`chi = RAY / totalSupply`, :277), and can also over-credit
    // without bound below `uint192.max` (:280). No admin, no timelock, no floor; the UNPAUSER
    // is not needed for the damage. Exact numbers for 1M + 100k.
    function test_BUG_C3_lossManagerHotWallet_pauserCollusionWipesAllHolders() public {
        _deposit(alice, 1_000_000e6);
        _deposit(bob, 100_000e6);
        uint256 backing = spUsdc.convertToAssets(_vaultSpUsdc());
        assertEq(vault.assetsOf(alice), 999_999_999_998);
        assertEq(vault.assetsOf(bob),    99_999_999_998);

        // Without a pause the key is powerless.
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(-1);

        // PAUSER + LOSS_MANAGER (two hot keys, or one compromised ops box holding both).
        _pause();
        int256 ta = int256(vault.totalAssets());
        _adjustTotalAssets(-(ta - 1));
        assertEq(vault.assetsOf(alice), 0);
        assertEq(vault.assetsOf(bob), 0);
        assertEq(vault.totalAssets(), 0);
        assertApproxEqAbs(spUsdc.convertToAssets(_vaultSpUsdc()), backing, 1);   // backing untouched: all equity

        // The same key can hand the equity to anyone who deposits next: after the unpause a 1
        // USDC deposit is minted at the dust chi and owns ~all the backing.
        _unpause();
        _deposit(attacker, 1e6);
        assertGt(vault.balanceOf(attacker), vault.balanceOf(alice) * 1_000_000);
        _requestRedeem(attacker, vault.balanceOf(attacker));
        _processRedeems(type(uint256).max, 1);
        assertLe(usdc.balanceOf(attacker), 1e6 + 2);               // chi is dust: the attacker gets ~1 USDC back
        // ...but a +gain by the same key before the unpause re-prices the whole supply:
    }

    // Variant: loss then gain inside one pause: the key rewrites who owns the backing. Alice
    // (1M) and bob (100k) are wiped, the attacker's queued 1 USDC... cannot be minted while
    // paused (`processPendingDeposits` is `whenNotPaused`), so the cleanest extraction is the
    // over-credit: +1M "gain" with nothing behind it, then the attacker's own redeem is paid
    // first from the backing. Exact: the attacker's 100k becomes 190_909 USDC of payout.
    function test_BUG_C3_lossManagerHotWallet_overCreditThenFrontOfQueue() public {
        _deposit(alice, 1_000_000e6);
        _deposit(attacker, 100_000e6);
        uint256 backing = spUsdc.convertToAssets(_vaultSpUsdc());

        _requestRedeem(attacker, vault.balanceOf(attacker));          // first in the queue
        _pause();
        _adjustTotalAssets(1_000_000e6);                               // unbacked gain
        _unpause();
        _processRedeems(type(uint256).max, 1);

        uint256 paid = usdc.balanceOf(attacker);
        emit log_named_uint("attacker paid after a 1M unbacked gain on 1.1M TVL", paid);
        assertEq(paid, 190_909_090_907);                               // 100k * 2.1M / 1.1M
        assertLt(backing - paid, 1_000_000e6);                         // alice is short by the difference
        _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 909_090_909_089);              // backing - paid, two floors
        assertApproxEqAbs(usdc.balanceOf(alice), backing - paid, 2);
        assertGt(vault.pendingRedeemShares(), 0);                      // unpayable remainder
        assertEq(vault.convertToAssets(vault.pendingRedeemShares()), 1_000_000_000_000);   // the whole fake gain
    }

    /**********************************************************************************************/
    /*** (d) OPERATOR as adversary                                                              ***/
    /**********************************************************************************************/

    // Ordering between the three queues and capacity games cannot move value to the operator:
    // every payout is `convertToAssets` at the fill, every mint `convertToShares`, FIFO is
    // enforced by the head. The operator's own deposit cannot jump a queue by raising capacity
    // (it queues behind the open entries) and starving the queues earns him nothing. Exact.
    function test_operator_orderingAndCapacity_cannotExtractValue() public {
        _fillCapacityExactly(alice, 1_000_000e6);
        uint256 vId = _deposit(victim, 100_000e6);                     // queued
        (, , uint256 vQ) = _depositRequest(vId);

        // Operator raises capacity and deposits: his entry queues behind the victim.
        _setCapacity(type(uint128).max);
        _fund(operator, 100_000e6);
        vm.prank(operator);
        uint256 oId = vault.requestDeposit(100_000e6, operator, 0);
        assertEq(vault.balanceOf(operator), 0);
        assertEq(oId, vId + 1);

        // He can only fill FIFO: processing 1 request fills the victim, not him.
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(victim), vault.convertToShares(spUsdc.convertToAssets(vQ)));
        assertEq(vault.balanceOf(operator), 0);
        _processDeposits(type(uint256).max, 1);
        uint256 oShares = vault.balanceOf(operator);
        assertApproxEqAbs(vault.assetsOf(operator), 100_000e6, 2);
        assertLe(vault.assetsOf(operator), 100_000e6);

        // Capacity sandwich on his own exit: pin capacity, redeem himself first, re-enter.
        // Payout is his own `convertToAssets` and nothing more.
        _requestRedeem(victim, vault.balanceOf(victim));               // victim ahead in the queue
        uint256 oRed = _requestRedeem(operator, oShares);
        _processRedeems(type(uint256).max, 1);                         // pays the victim first
        assertEq(usdc.balanceOf(operator), 0);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(operator), vault.convertToAssets(oShares));
        assertLe(usdc.balanceOf(operator), 100_000e6);
        oRed;
    }

    // The one lever the operator has is `setVSR` within the admin bounds (:308-315): with his
    // own deposit in the vault he over-credits himself along with everyone else and exits
    // first. Profit on 1M own capital at MAX_VSR for 1 day: 1_900.84 USDC, paid out of the
    // other holders' backing; at a 10% admin cap 261.16 USDC. C-9 / R5-13 re-rated for the
    // operator key.
    function test_BUG_C9_operatorSetsMaxVsr_frontOfQueueProfit() public {
        _deposit(alice, 1_000_000e6);
        _fund(operator, 1_000_000e6);
        vm.prank(operator);
        vault.requestDeposit(1_000_000e6, operator, 0);
        uint256 oShares = vault.balanceOf(operator);
        uint256 backing = spUsdc.convertToAssets(_vaultSpUsdc());

        _setPrimeVsr(MAX_VSR);
        _warpAndDrip(1 days);
        _setPrimeVsr(RAY);

        vm.prank(operator);
        vault.requestRedeem(oShares, operator);
        _processRedeems(type(uint256).max, 1);
        uint256 paid = usdc.balanceOf(operator);
        emit log_named_uint("operator paid after 1 day at MAX_VSR on 1M", paid);
        assertEq(paid, 1_001_900_837_676);                             // 1M + 1_900.84 less rounding
        assertEq(paid - 1_000_000e6, 1_900_837_676);

        // Alice is short by exactly that amount when she exits.
        _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 998_099_162_320);              // backing - paid - 2 floors
        assertApproxEqAbs(usdc.balanceOf(alice), backing - paid, 2);
        // Unpayable: alice's own over-credit (1_900.84) plus what the operator took (1_900.84).
        assertEq(vault.convertToAssets(vault.pendingRedeemShares()), 3_801_675_355);
        assertLe(_vaultSpUsdc(), 1);

        // Bounded by the admin: at a 10% cap the same move yields 261.16 USDC/day.
        vm.prank(admin);
        vault.setVSRBounds(RAY, TEN_PCT_VSR);
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.VSRTooHigh.selector);
        vault.setVSR(MAX_VSR);
    }

    // `setCapacity` is unbounded (R5-8 / V2-7, open), now on the operator key: a capacity of
    // `type(uint256).max` makes `convertToAssets(availableCapacity())` (:864) overflow, so every
    // instant deposit and every planner call panics 0x11 until the capacity is lowered. Exact
    // threshold `totalSupply + type(uint256).max / nowChi()`.
    function test_BUG_R5_8_operatorSetCapacityUnbounded_overflowBricksDeposits() public {
        _deposit(alice, 1_000e6);
        uint256 chi   = vault.nowChi();
        uint256 limit = vault.totalSupply() + type(uint256).max / chi;

        _setCapacity(limit);                                           // largest working capacity
        _deposit(bob, 1e6);
        assertGt(vault.balanceOf(bob), 0);

        limit = vault.totalSupply() + type(uint256).max / chi;         // supply grew with bob
        _setCapacity(limit + 1);
        _fund(carol, 1e6);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(PANIC_SEL, 0x11));
        vault.requestDeposit(1e6, carol, 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PANIC_SEL, 0x11));
        vault.processPendingDeposits(1, 1);
        // Cancels run the same walk (:445): they are bricked too.
        _setCapacity(vault.totalSupply());
        uint256 dId = _deposit(carol, 1e6);
        _setCapacity(type(uint256).max);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(PANIC_SEL, 0x11));
        vault.requestDepositCancellation(dId, carol, 1);
        // Redeems and claims are unaffected; the operator (or a new one) repairs it.
        _requestRedeem(bob, vault.balanceOf(bob));
        _processRedeems(type(uint256).max, 1);
        _setCapacity(vault.totalSupply() + type(uint256).max / chi);   // threshold moves with supply
        vm.prank(carol);
        vault.requestDepositCancellation(dId, carol, 1);
    }

    // R5-6 / V2-8 (open): the last DEFAULT_ADMIN can renounce, leaving no admin at all: no
    // upgrade, no bounds, no role grants; the hot wallets keep their powers forever.
    function test_BUG_R5_6_lastAdminRenounce_leavesNoAdmin() public {
        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        vm.prank(admin);
        vault.renounceRole(DEFAULT_ADMIN_ROLE, admin);
        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 0);
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, DEFAULT_ADMIN_ROLE));
        vault.grantRole(DEFAULT_ADMIN_ROLE, admin);
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, DEFAULT_ADMIN_ROLE));
        vault.setVSRBounds(RAY, RAY);
        // Operator and loss manager still work.
        _setCapacity(1);
        assertEq(vault.maxCapacity(), 1);
        _setCapacity(type(uint128).max);
        _deposit(alice, 1e6);
        _pause();
        _adjustTotalAssets(-1);
        _unpause();
    }

    /**********************************************************************************************/
    /*** (e) ERC20: transferFrom ordering                                                       ***/
    /**********************************************************************************************/

    // `transferFrom` (:565-587) now calls `_transfer` before the allowance check, so the balance
    // requirement is tested first. The only observable difference is the revert reason when
    // BOTH are insufficient (`insufficient-balance`, previously `insufficient-allowance`); no
    // state is written on any failing path, and the allowance is decremented after the move.
    function test_transferFrom_balanceCheckedBeforeAllowance() public {
        _deposit(alice, 100e6);
        uint256 bal = vault.balanceOf(alice);

        vm.prank(alice);
        vault.approve(bob, 1);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");        // both insufficient
        vault.transferFrom(alice, bob, bal + 1);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-allowance");      // balance ok, allowance not
        vault.transferFrom(alice, bob, 2);
        assertEq(vault.balanceOf(alice), bal);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.allowance(alice, bob), 1);

        // Self-spend with no allowance and more than the balance: balance error, not allowance.
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.transferFrom(alice, bob, bal + 1);

        vm.prank(bob);
        vault.transferFrom(alice, bob, 1);
        assertEq(vault.allowance(alice, bob), 0);
        assertEq(vault.balanceOf(bob), 1);
    }

    /**********************************************************************************************/
    /*** (f) Ordering games, fuzzed                                                             ***/
    /**********************************************************************************************/

    // When the vault is fully backed, any interleaving and chunking of the three planner calls
    // by the operator leaves every user within one floor per partial (two for a deposit fill:
    // spUSDC assets then spPRIME shares) of the index-determined amount, and the operator's own
    // balances unchanged. Run with FOUNDRY_FUZZ_RUNS=20000.
    function testFuzz_operatorOrdering_payoutsIndexDetermined(bytes32 seed, uint256 steps) public {
        steps = bound(steps, 3, 12);
        _fillCapacityExactly(alice, 1_000e6);
        uint256 aShares = vault.balanceOf(alice);
        uint256 d1 = _deposit(bob, 300e6);
        uint256 d2 = _deposit(carol, 200e6);
        (, , uint256 bQ) = _depositRequest(d1);
        _cancelTo(carol, d2, carol);
        _requestRedeem(alice, aShares / 2);
        _setCapacity(type(uint128).max);

        uint256 expAlice = vault.convertToAssets(aShares / 2);
        uint256 expBob   = vault.convertToShares(spUsdc.convertToAssets(bQ));
        uint256 expCarol = 199_999_999;
        uint256 opUsdc = usdc.balanceOf(operator);
        uint256 opSp   = spUsdc.balanceOf(operator);

        uint256 partials;
        for (uint256 i; i < steps; ++i) {
            uint256 r  = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 3;
            bool chunk = (r >> 8) % 2 == 0;
            uint256 budget = chunk ? 1 + (r >> 16) % 1_000_000_000 : type(uint256).max;
            if (chunk) ++partials;
            if (op == 0)      _processDeposits(budget, 1 + (r >> 48) % 3);
            else if (op == 1) _processRedeems(budget, 1 + (r >> 48) % 3);
            else              _processCancelledDeposits(budget, 1 + (r >> 48) % 3);
        }
        _processDeposits(type(uint256).max, 10);
        _processRedeems(type(uint256).max, 10);
        _processCancelledDeposits(type(uint256).max, 10);

        assertLe(usdc.balanceOf(alice), expAlice);
        assertGe(usdc.balanceOf(alice) + partials + 1, expAlice);
        assertLe(vault.balanceOf(bob), expBob);
        assertGe(vault.balanceOf(bob) + 2 * partials + 2, expBob);   // a deposit partial floors twice
        assertLe(usdc.balanceOf(carol), expCarol);
        assertGe(usdc.balanceOf(carol) + partials + 1, expCarol);
        assertEq(usdc.balanceOf(operator), opUsdc);
        assertEq(spUsdc.balanceOf(operator), opSp);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // Under shortage (after `take`), the operator's ordering decides WHO is paid first (F-2) but
    // never HOW MUCH in total: USDC paid out + claimable credited never exceeds the backing the
    // vault holds plus what was refunded, for any order and chunking. Run with FOUNDRY_FUZZ_RUNS=20000.
    function testFuzz_operatorOrdering_underShortage_totalPayoutBoundedByBacking(
        bytes32 seed, uint256 cut, uint256 steps
    ) public {
        steps = bound(steps, 2, 10);
        _fillCapacityExactly(alice, 1_000e6);
        uint256 aShares = vault.balanceOf(alice);
        uint256 d2 = _deposit(carol, 500e6);
        _cancelTo(carol, d2, carol);
        _requestRedeem(alice, aShares);
        cut = bound(cut, 0, _vaultSpUsdc());
        if (cut != 0) _take(cut);
        uint256 backingAssets = spUsdc.convertToAssets(_vaultSpUsdc());

        for (uint256 i; i < steps; ++i) {
            uint256 r  = uint256(keccak256(abi.encode(seed, i)));
            uint256 budget = (r >> 8) % 2 == 0 ? 1 + (r >> 16) % 1_000_000_000 : type(uint256).max;
            if (r % 2 == 0) _processRedeems(budget, 1);
            else            _processCancelledDeposits(budget, 1);
        }
        uint256 out = usdc.balanceOf(alice) + usdc.balanceOf(carol) + vault.totalClaimable();
        assertLe(out, backingAssets + 1, "paid more than the backing");
        assertLe(out + spUsdc.convertToAssets(_vaultSpUsdc()), backingAssets + 1, "value created");
        assertGe(out + spUsdc.convertToAssets(_vaultSpUsdc()) + steps + 2, backingAssets, "lost beyond rounding");
        assertLe(usdc.balanceOf(alice), vault.convertToAssets(aShares));
        assertLe(usdc.balanceOf(carol), 499_999_999);
    }

}
