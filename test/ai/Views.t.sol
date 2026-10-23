// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl } from "../../lib/oz/contracts/access/IAccessControl.sol";
import { IERC165 }        from "../../lib/oz/contracts/utils/introspection/IERC165.sol";

import { LocalTestBase }    from "./LocalTestBase.t.sol";
import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../src/SparkPrimeVault.sol";

/// @dev Every view on `master` @ c512609: the three single-entry request getters, the head-to-end
///      and `(startId, length)` range getters (fuzzed against the full view), `availableCapacity`,
///      `availableLiquidAssets`, `assetsOf`, `totalAssets`, `totalClaimable`, `convertToAssets` /
///      `convertToShares`, `nowChi` vs `drip`, `DOMAIN_SEPARATOR`, `implementation`, the ERC20
///      metadata, the whole `ISparkPrimeVault` surface (IERC20Metadata, IERC20Permit,
///      IAccessControlEnumerable) called through the interface, plus the overflow bounds of the
///      index maths (still open).
contract ViewsTest is LocalTestBase {

    // keccak256("eip1967.proxy.implementation") - 1
    bytes32 constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // c512609 layout: slot 7 = rho (uint64, offset 0) | chi (uint192, offset 8).
    uint256 constant SLOT_RHO_CHI = 7;

    // Largest `chi` for which `_rpow(RAY, dt) * chi` (== RAY * chi) fits in uint256.
    uint256 constant CHI_RPOW_BOUND = type(uint256).max / 1e27;

    bytes constant PANIC_OVERFLOW = abi.encodeWithSignature("Panic(uint256)", 0x11);

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");

    /// @dev Overwrites `chi` in place (slot 7, offset 8), keeping `rho`.
    function _storeChi(uint256 chi_) internal {
        uint256 word_ = uint256(vm.load(address(vault), bytes32(SLOT_RHO_CHI)));
        word_ = (chi_ << 64) | uint64(word_);
        vm.store(address(vault), bytes32(SLOT_RHO_CHI), bytes32(word_));
    }

    /// @dev Raw array read: element `i` of the array at `slot_` lives at keccak256(slot_) + 3i.
    function _rawRequest(uint256 slot_, uint256 id_)
        internal view returns (address owner_, address recipient_, uint256 shares_)
    {
        uint256 base_ = uint256(keccak256(abi.encode(slot_))) + 3 * id_;
        owner_     = address(uint160(uint256(vm.load(address(vault), bytes32(base_)))));
        recipient_ = address(uint160(uint256(vm.load(address(vault), bytes32(base_ + 1)))));
        shares_    = uint256(vm.load(address(vault), bytes32(base_ + 2)));
    }

    function _cancel(address who_, uint256 id_, address recipient_) internal returns (uint256) {
        ( , , uint256 shares_ ) = vault.getPendingDepositRequest(id_);
        vm.prank(who_);
        return vault.requestDepositCancellation(id_, recipient_, shares_);
    }

    /**********************************************************************************************/
    /*** Head-to-end array getters                                                              ***/
    /**********************************************************************************************/

    function test_getPendingRequests_emptyQueues() public view {
        assertEq(vault.getPendingDepositRequests().length,                 0);
        assertEq(vault.getPendingDepositCancellationRequests().length,     0);
        assertEq(vault.getPendingRedeemRequests().length,                  0);
        assertEq(vault.getPendingDepositRequests(0, 0).length,             0);
        assertEq(vault.getPendingDepositCancellationRequests(0, 0).length, 0);
        assertEq(vault.getPendingRedeemRequests(0, 0).length,              0);
    }

    function test_getPendingDepositRequests_excludesFilledAndStartsAtHead() public {
        _deposit(alice, 100e6);                       // filled instantly, id 0, deleted
        _setCapacity(vault.totalSupply());
        _deposit(bob,   50e6);                        // queued, id 1
        _deposit(carol, 25e6);                        // queued, id 2

        assertEq(vault.firstPendingDepositId(), 1);

        SparkPrimeVault.Request[] memory pending = vault.getPendingDepositRequests();
        assertEq(pending.length,       2);
        assertEq(pending[0].owner,     bob);
        assertEq(pending[0].recipient, bob);
        assertEq(pending[0].shares,    47_726_634);
        assertEq(pending[1].owner,     carol);
        assertEq(pending[1].recipient, carol);
        assertEq(pending[1].shares,    23_863_317);

        // The range getter covers exactly the same window and nothing below the head.
        SparkPrimeVault.Request[] memory window = vault.getPendingDepositRequests(1, 2);
        assertEq(keccak256(abi.encode(window)), keccak256(abi.encode(pending)));
        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingDepositRequests(0, 3);
        assertEq(_depositQueueLength(), 3);

        // The filled entry is zeroed in storage.
        (address o_, address r_, uint256 s_) = _rawRequest(0, 0);
        assertEq(o_, address(0));
        assertEq(r_, address(0));
        assertEq(s_, 0);
    }

    // Cancelling the head entry self-skips it: `requestDepositCancellation` ends with a budget-0
    // walk that advances the head past zero entries, so the deposit view no longer shows it.
    function test_getPendingDepositCancellationRequests_tracksCancelAndSettle() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, 100e6);
        uint256 cid = _cancel(alice, id, bob);
        assertEq(cid, 0);

        SparkPrimeVault.Request[] memory pending = vault.getPendingDepositCancellationRequests();
        assertEq(pending.length,       1);
        assertEq(pending[0].owner,     alice);
        assertEq(pending[0].recipient, bob);
        assertEq(pending[0].shares,    95_453_269);

        assertEq(vault.getPendingDepositRequests().length, 0);   // self-skipped at the head
        assertEq(vault.firstPendingDepositId(),            1);
        assertEq(vault.pendingDepositSavingsShares(),      0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 95_453_269);

        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(vault.getPendingDepositCancellationRequests().length, 0);
        assertEq(vault.firstPendingDepositCancellationId(),            1);
        assertEq(vault.pendingCancelledDepositSavingsShares(),         0);
        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingDepositCancellationRequests(0, 1);
        assertEq(usdc.balanceOf(bob), 99_999_999);
    }

    // A cancelled entry BEHIND a live head is not self-skipped: it stays in the view as a zero
    // struct until a walk with budget passes it (the budget-0 walk breaks at the live head).
    function test_getPendingDepositRequests_cancelledBehindLiveHeadStaysVisible() public {
        _setCapacity(0);
        uint256 aId = _deposit(alice, 100e6);   // id 0, live head
        uint256 bId = _deposit(bob,   50e6);    // id 1
        _cancel(bob, bId, bob);

        SparkPrimeVault.Request[] memory pending = vault.getPendingDepositRequests();
        assertEq(pending.length,       2);
        assertEq(pending[0].owner,     alice);
        assertEq(pending[0].shares,    95_453_269);
        assertEq(pending[1].owner,     address(0));
        assertEq(pending[1].recipient, address(0));
        assertEq(pending[1].shares,    0);
        assertEq(vault.firstPendingDepositId(), 0);

        // Operator walk at capacity 0: breaks at the live head, nothing moves.
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(vault.getPendingDepositRequests().length, 2);

        // Capacity returns: alice fills, bob's zero entry is walked, the view empties.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingDepositId(), 2);
        assertEq(vault.getPendingDepositRequests().length, 0);
        assertEq(vault.balanceOf(alice), 99_040_517);
        assertEq(vault.assetsOf(alice),  99_999_998);
        aId;
    }

    function test_getPendingRedeemRequests_partialFillKeepsHeadEntry() public {
        _deposit(alice, 100e6);
        _deposit(bob,   100e6);
        uint256 aliceShares = vault.balanceOf(alice);
        _requestRedeem(alice, aliceShares);
        _requestRedeem(bob,   vault.balanceOf(bob));

        _processRedeems(aliceShares / 2, 10);     // half of alice

        SparkPrimeVault.Request[] memory pending = vault.getPendingRedeemRequests();
        assertEq(pending.length,    2);
        assertEq(pending[0].owner,  alice);
        assertEq(pending[0].shares, aliceShares - aliceShares / 2);
        assertEq(pending[1].owner,  bob);
        assertEq(vault.firstPendingRedeemId(), 0);

        // The single-entry getter reports the remaining shares, not the original request.
        (address owner_, address recipient_, uint256 shares_) = vault.getPendingRedeemRequest(0);
        assertEq(owner_,     alice);
        assertEq(recipient_, alice);
        assertEq(shares_,    aliceShares - aliceShares / 2);

        _processRedeems(type(uint256).max, 10);
        assertEq(vault.getPendingRedeemRequests().length, 0);
        assertEq(vault.firstPendingRedeemId(),            2);
        assertEq(_redeemQueueLength(),                    2);
    }

    // The head-to-end view, the single-entry getter and the counters agree for any cancel
    // pattern; the head ends exactly past the leading run of cancelled entries (self-skip).
    function testFuzz_getPendingRequests_matchHeadAndCounters(uint8 n, uint16 cancelMask) public {
        n = uint8(bound(n, 1, 12));
        _setCapacity(0);
        for (uint256 i; i < n; ++i) _deposit(makeAddr(string(abi.encodePacked("u", i))), 10e6 * (i + 1));
        uint256 expectedHead_ = n;
        for (uint256 i; i < n; ++i) {
            if (cancelMask & (1 << i) != 0) {
                _cancel(makeAddr(string(abi.encodePacked("u", i))), i, bob);
            } else if (expectedHead_ == n) {
                expectedHead_ = i;   // first live entry
            }
        }
        uint256 head = vault.firstPendingDepositId();
        assertEq(head, expectedHead_);

        SparkPrimeVault.Request[] memory pending = vault.getPendingDepositRequests();
        assertEq(pending.length, n - head);
        uint256 sum;
        for (uint256 i; i < pending.length; ++i) {
            sum += pending[i].shares;
            (address o_, address r_, uint256 s_) = vault.getPendingDepositRequest(head + i);
            assertEq(o_, pending[i].owner);
            assertEq(r_, pending[i].recipient);
            assertEq(s_, pending[i].shares);
            bool cancelled_ = cancelMask & (1 << (head + i)) != 0;
            assertEq(s_ == 0, cancelled_);
        }
        assertEq(sum, vault.pendingDepositSavingsShares());

        SparkPrimeVault.Request[] memory cancelled = vault.getPendingDepositCancellationRequests();
        uint256 csum;
        for (uint256 i; i < cancelled.length; ++i) {
            csum += cancelled[i].shares;
            assertEq(cancelled[i].recipient, bob);
        }
        assertEq(csum, vault.pendingCancelledDepositSavingsShares());
    }

    /**********************************************************************************************/
    /*** Range getters (startId, length)                                                        ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequests_range_failure() public {
        _setCapacity(0);
        _deposit(alice, 100e6);
        _deposit(bob,   50e6);
        _deposit(carol, 25e6);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);   // head 1, length 3

        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingDepositRequests(0, 1);
        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingDepositRequests(0, 0);
        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingDepositRequests(1, 3);
        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingDepositRequests(2, 2);
        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingDepositRequests(3, 1);
        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingDepositRequests(1, type(uint256).max);

        // startId past the end underflows `length - startId` before the LengthTooLarge check.
        vm.expectRevert(PANIC_OVERFLOW);
        vault.getPendingDepositRequests(4, 0);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.getPendingDepositRequests(type(uint256).max, 0);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.getPendingDepositRequests(type(uint256).max, type(uint256).max);

        // Boundaries that pass.
        vault.getPendingDepositRequests(1, 2);
        assertEq(vault.getPendingDepositRequests(3, 0).length, 0);   // startId == length
    }

    function test_getPendingDepositRequests_range_success() public {
        _setCapacity(0);
        _deposit(alice, 100e6);
        _deposit(bob,   50e6);
        _deposit(carol, 25e6);

        SparkPrimeVault.Request[] memory r = vault.getPendingDepositRequests(0, 3);
        assertEq(r.length,       3);
        assertEq(r[0].owner,     alice);
        assertEq(r[0].shares,    95_453_269);
        assertEq(r[1].owner,     bob);
        assertEq(r[1].shares,    47_726_634);
        assertEq(r[2].owner,     carol);
        assertEq(r[2].recipient, carol);
        assertEq(r[2].shares,    23_863_317);

        r = vault.getPendingDepositRequests(1, 1);
        assertEq(r.length,    1);
        assertEq(r[0].owner,  bob);
        assertEq(r[0].shares, 47_726_634);

        r = vault.getPendingDepositRequests(2, 1);
        assertEq(r.length,   1);
        assertEq(r[0].owner, carol);

        assertEq(vault.getPendingDepositRequests(0, 0).length, 0);
        assertEq(vault.getPendingDepositRequests(2, 0).length, 0);
        assertEq(vault.getPendingDepositRequests(3, 0).length, 0);
    }

    function test_getPendingDepositCancellationRequests_range() public {
        _setCapacity(0);
        uint256 aId = _deposit(alice, 100e6);
        uint256 bId = _deposit(bob,   40e6);
        _cancel(alice, aId, carol);
        _cancel(bob,   bId, bob);

        SparkPrimeVault.Request[] memory r = vault.getPendingDepositCancellationRequests(0, 2);
        assertEq(r.length,       2);
        assertEq(r[0].owner,     alice);
        assertEq(r[0].recipient, carol);
        assertEq(r[0].shares,    95_453_269);
        assertEq(r[1].owner,     bob);
        assertEq(r[1].recipient, bob);
        assertEq(r[1].shares,    38_181_307);
        assertEq(vault.getPendingDepositCancellationRequests(1, 1)[0].owner, bob);
        assertEq(vault.getPendingDepositCancellationRequests(2, 0).length, 0);

        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingDepositCancellationRequests(0, 3);
        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingDepositCancellationRequests(1, 2);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.getPendingDepositCancellationRequests(3, 0);

        _processCancelledDeposits(type(uint256).max, 1);   // head 1
        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingDepositCancellationRequests(0, 1);
        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingDepositCancellationRequests(0, 0);
        r = vault.getPendingDepositCancellationRequests(1, 1);
        assertEq(r[0].owner, bob);
        assertEq(usdc.balanceOf(carol), 99_999_999);
    }

    function test_getPendingRedeemRequests_range() public {
        _deposit(alice, 100e6);
        _deposit(bob,   50e6);
        uint256 aShares_ = vault.balanceOf(alice);
        uint256 bShares_ = vault.balanceOf(bob);
        _requestRedeem(alice, aShares_);
        _requestRedeem(bob,   bShares_);

        SparkPrimeVault.Request[] memory r = vault.getPendingRedeemRequests(0, 2);
        assertEq(r.length,       2);
        assertEq(r[0].owner,     alice);
        assertEq(r[0].recipient, alice);
        assertEq(r[0].shares,    aShares_);
        assertEq(r[0].shares,    99_040_517);
        assertEq(r[1].owner,     bob);
        assertEq(r[1].shares,    bShares_);
        assertEq(r[1].shares,    49_520_258);
        assertEq(vault.getPendingRedeemRequests(1, 1)[0].owner, bob);
        assertEq(vault.getPendingRedeemRequests(2, 0).length, 0);

        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingRedeemRequests(0, 3);
        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingRedeemRequests(2, 1);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.getPendingRedeemRequests(3, 0);

        _processRedeems(type(uint256).max, 1);   // head 1
        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingRedeemRequests(0, 2);
        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingRedeemRequests(0, 0);
        r = vault.getPendingRedeemRequests(1, 1);
        assertEq(r[0].owner,  bob);
        assertEq(r[0].shares, bShares_);
        assertEq(usdc.balanceOf(alice), 99_999_998);
    }

    /// @dev Builds a deposit queue of `n` entries (owner u_i, 10e6 * (i + 1)), fills `k` of them
    ///      and returns the head.
    function _depositQueue(uint256 n, uint256 k) internal returns (uint256 head_) {
        _setCapacity(0);
        for (uint256 i; i < n; ++i) _deposit(makeAddr(string(abi.encodePacked("u", i))), 10e6 * (i + 1));
        _setCapacity(type(uint128).max);
        if (k != 0) _processDeposits(type(uint256).max, k);
        head_ = vault.firstPendingDepositId();
        assertEq(head_, k);
    }

    // Any `(startId, length)` inside `[head, length]` equals the matching slice of the full
    // view; anything else reverts with the exact selector (or the underflow panic past the end).
    function testFuzz_getPendingDepositRequests_range(
        uint8 n, uint8 k, uint256 startId, uint256 length
    ) public {
        n = uint8(bound(n, 1, 10));
        k = uint8(bound(k, 0, n));
        uint256 head_ = _depositQueue(n, k);
        startId = bound(startId, 0, uint256(n) + 1);
        length  = bound(length, 0, uint256(n) + 1);

        SparkPrimeVault.Request[] memory full = vault.getPendingDepositRequests();
        assertEq(full.length, n - head_);

        if (startId < head_) {
            vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
            vault.getPendingDepositRequests(startId, length);
            return;
        }
        if (startId > n) {
            vm.expectRevert(PANIC_OVERFLOW);
            vault.getPendingDepositRequests(startId, length);
            return;
        }
        if (length > n - startId) {
            vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
            vault.getPendingDepositRequests(startId, length);
            return;
        }

        SparkPrimeVault.Request[] memory r = vault.getPendingDepositRequests(startId, length);
        assertEq(r.length, length);
        for (uint256 i; i < length; ++i) {
            SparkPrimeVault.Request memory e = full[startId - head_ + i];
            assertEq(r[i].owner,     e.owner);
            assertEq(r[i].recipient, e.recipient);
            assertEq(r[i].shares,    e.shares);
            assertEq(r[i].owner,     makeAddr(string(abi.encodePacked("u", startId + i))));
            (address o_, address r2_, uint256 s_) = vault.getPendingDepositRequest(startId + i);
            assertEq(o_,  e.owner);
            assertEq(r2_, e.recipient);
            assertEq(s_,  e.shares);
        }
    }

    function testFuzz_getPendingRedeemRequests_range(
        uint8 n, uint8 k, uint256 startId, uint256 length
    ) public {
        n = uint8(bound(n, 1, 10));
        k = uint8(bound(k, 0, n));
        for (uint256 i; i < n; ++i) {
            address who_ = makeAddr(string(abi.encodePacked("u", i)));
            _deposit(who_, 10e6 * (i + 1));
            _requestRedeem(who_, vault.balanceOf(who_));
        }
        if (k != 0) _processRedeems(type(uint256).max, k);
        uint256 head_ = vault.firstPendingRedeemId();
        assertEq(head_, k);
        startId = bound(startId, 0, uint256(n) + 1);
        length  = bound(length, 0, uint256(n) + 1);

        SparkPrimeVault.Request[] memory full = vault.getPendingRedeemRequests();
        assertEq(full.length, n - head_);

        if (startId < head_) {
            vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
            vault.getPendingRedeemRequests(startId, length);
            return;
        }
        if (startId > n) {
            vm.expectRevert(PANIC_OVERFLOW);
            vault.getPendingRedeemRequests(startId, length);
            return;
        }
        if (length > n - startId) {
            vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
            vault.getPendingRedeemRequests(startId, length);
            return;
        }

        SparkPrimeVault.Request[] memory r = vault.getPendingRedeemRequests(startId, length);
        assertEq(r.length, length);
        for (uint256 i; i < length; ++i) {
            SparkPrimeVault.Request memory e = full[startId - head_ + i];
            assertEq(r[i].owner,     e.owner);
            assertEq(r[i].recipient, e.recipient);
            assertEq(r[i].shares,    e.shares);
            assertEq(r[i].owner,     makeAddr(string(abi.encodePacked("u", startId + i))));
            assertGt(r[i].shares,    0);
        }
    }

    function testFuzz_getPendingDepositCancellationRequests_range(
        uint8 n, uint8 k, uint256 startId, uint256 length
    ) public {
        n = uint8(bound(n, 1, 10));
        k = uint8(bound(k, 0, n));
        _setCapacity(0);
        for (uint256 i; i < n; ++i) {
            address who_ = makeAddr(string(abi.encodePacked("u", i)));
            _deposit(who_, 10e6 * (i + 1));
            _cancel(who_, i, who_);
        }
        if (k != 0) _processCancelledDeposits(type(uint256).max, k);
        uint256 head_ = vault.firstPendingDepositCancellationId();
        assertEq(head_, k);
        startId = bound(startId, 0, uint256(n) + 1);
        length  = bound(length, 0, uint256(n) + 1);

        SparkPrimeVault.Request[] memory full = vault.getPendingDepositCancellationRequests();
        assertEq(full.length, n - head_);

        if (startId < head_) {
            vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
            vault.getPendingDepositCancellationRequests(startId, length);
            return;
        }
        if (startId > n) {
            vm.expectRevert(PANIC_OVERFLOW);
            vault.getPendingDepositCancellationRequests(startId, length);
            return;
        }
        if (length > n - startId) {
            vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
            vault.getPendingDepositCancellationRequests(startId, length);
            return;
        }

        SparkPrimeVault.Request[] memory r =
            vault.getPendingDepositCancellationRequests(startId, length);
        assertEq(r.length, length);
        for (uint256 i; i < length; ++i) {
            SparkPrimeVault.Request memory e = full[startId - head_ + i];
            assertEq(r[i].owner,     e.owner);
            assertEq(r[i].recipient, e.recipient);
            assertEq(r[i].shares,    e.shares);
            assertEq(r[i].owner,     makeAddr(string(abi.encodePacked("u", startId + i))));
            assertGt(r[i].shares,    0);
        }
    }

    // Deleted head entries are zero in raw storage and unreachable through every getter.
    function test_getPendingRequests_deletedHeadEntriesUnreachable() public {
        _deposit(alice, 100e6);                   // deposit id 0 filled, deleted
        _setCapacity(vault.totalSupply());
        _deposit(bob, 50e6);                      // deposit id 1 queued
        _cancel(bob, 1, bob);                     // cancel id 0, deposit id 1 self-skipped
        _processCancelledDeposits(type(uint256).max, 1);   // cancel id 0 settled, deleted
        _requestRedeem(alice, vault.balanceOf(alice));     // redeem id 0
        _processRedeems(type(uint256).max, 1);             // paid, deleted

        assertEq(vault.firstPendingDepositId(),             2);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        assertEq(vault.firstPendingRedeemId(),              1);

        for (uint256 slot_; slot_ < 3; ++slot_) {
            (address o_, address r_, uint256 s_) = _rawRequest(slot_, 0);
            assertEq(o_, address(0));
            assertEq(r_, address(0));
            assertEq(s_, 0);
        }
        (address o1_, , uint256 s1_) = _rawRequest(0, 1);
        assertEq(o1_, address(0));
        assertEq(s1_, 0);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(0);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(1);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositCancellationRequest(0);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingRedeemRequest(0);
        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingDepositRequests(1, 1);
        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingDepositCancellationRequests(0, 1);
        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingRedeemRequests(0, 1);

        assertEq(vault.getPendingDepositRequests().length,             0);
        assertEq(vault.getPendingDepositCancellationRequests().length, 0);
        assertEq(vault.getPendingRedeemRequests().length,              0);
        assertEq(vault.getPendingDepositRequests(2, 0).length,         0);
        assertEq(vault.getPendingRedeemRequests(1, 0).length,          0);
    }

    /**********************************************************************************************/
    /*** Single-entry getters                                                                   ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequest_bounds() public {
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(0);                       // empty queue: 0 == length

        _deposit(alice, 100e6);                                  // id 0, instant, head -> 1
        assertEq(vault.firstPendingDepositId(), 1);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(0);                       // below head (filled)
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(1);                       // == length

        _setCapacity(vault.totalSupply());
        uint256 bobId   = _deposit(bob,   50e6);                 // id 1, queued
        uint256 carolId = _deposit(carol, 25e6);                 // id 2, queued

        (address o_, address r_, uint256 s_) = vault.getPendingDepositRequest(bobId);
        assertEq(o_, bob);
        assertEq(r_, bob);
        assertEq(s_, 47_726_634);
        (o_, r_, s_) = vault.getPendingDepositRequest(carolId);
        assertEq(o_, carol);
        assertEq(r_, carol);
        assertEq(s_, 23_863_317);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(3);                       // == length
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(type(uint256).max);

        // Cancelled id behind the live head returns all zeros, no revert, head unchanged.
        _cancel(carol, carolId, carol);
        (o_, r_, s_) = vault.getPendingDepositRequest(carolId);
        assertEq(o_, address(0));
        assertEq(r_, address(0));
        assertEq(s_, 0);
        assertEq(vault.firstPendingDepositId(), 1);

        // Partial fill of bob: capacity for roughly half of his request (the capacity -> assets
        // -> spUSDC shares conversion floors twice, so 2 shares less than half). The getter
        // reports the remaining spUSDC shares and the head stays on his id.
        uint256 halfSavings_ = uint256(47_726_634) / 2;
        uint256 halfShares_  = vault.convertToShares(spUsdc.convertToAssets(halfSavings_));
        _setCapacity(vault.totalSupply() + halfShares_);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(), bobId);
        (o_, r_, s_) = vault.getPendingDepositRequest(bobId);
        assertEq(o_, bob);
        assertEq(s_, 47_726_634 - (halfSavings_ - 2));
        assertEq(s_, 23_863_319);
        assertEq(s_, vault.pendingDepositSavingsShares());

        // Partial cancel of the rest: the entry keeps its position with the remainder.
        vm.prank(bob);
        vault.requestDepositCancellation(bobId, bob, 1_000_000);
        (o_, r_, s_) = vault.getPendingDepositRequest(bobId);
        assertEq(o_, bob);
        assertEq(s_, 22_863_319);
        assertEq(vault.firstPendingDepositId(), bobId);

        // Full fill: head == length, every id rejected.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(), 3);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(bobId);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(carolId);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(3);
        assertEq(vault.getPendingDepositRequests().length, 0);
    }

    function test_getPendingDepositCancellationRequest_bounds() public {
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositCancellationRequest(0);

        _setCapacity(0);
        uint256 aId = _deposit(alice, 100e6);
        uint256 bId = _deposit(bob,   40e6);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositCancellationRequest(0);           // nothing cancelled yet

        uint256 ca_ = _cancel(alice, aId, carol);
        uint256 cb_ = _cancel(bob,   bId, bob);
        assertEq(ca_, 0);
        assertEq(cb_, 1);

        (address o_, address r_, uint256 s_) = vault.getPendingDepositCancellationRequest(ca_);
        assertEq(o_, alice);
        assertEq(r_, carol);
        assertEq(s_, 95_453_269);
        (o_, r_, s_) = vault.getPendingDepositCancellationRequest(cb_);
        assertEq(o_, bob);
        assertEq(r_, bob);
        assertEq(s_, 38_181_307);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositCancellationRequest(2);           // == length

        // Partial settlement of the head: spUSDC can only redeem 50e6 worth.
        uint256 spUsdcUsdc_ = usdc.balanceOf(address(spUsdc));
        _drainSpUsdcLiquidity(spUsdcUsdc_ - 50e6);
        uint256 maxRedeem_ = spUsdc.maxRedeem(address(vault));
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositCancellationId(), 0);
        (o_, r_, s_) = vault.getPendingDepositCancellationRequest(0);
        assertEq(o_, alice);
        assertEq(r_, carol);
        assertEq(s_, 95_453_269 - maxRedeem_);
        assertEq(s_, vault.pendingCancelledDepositSavingsShares() - 38_181_307);
        assertEq(usdc.balanceOf(carol), spUsdc.convertToAssets(maxRedeem_));
        assertLe(usdc.balanceOf(carol), 50e6);

        // Full settlement: head == length, both ids rejected.
        _returnSpUsdcLiquidity(spUsdcUsdc_);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositCancellationRequest(0);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositCancellationRequest(1);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositCancellationRequest(2);
        assertApproxEqAbs(usdc.balanceOf(carol), 100e6, 2);
        assertEq(usdc.balanceOf(bob), 39_999_999);
    }

    function test_getPendingRedeemRequest_bounds() public {
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingRedeemRequest(0);

        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 100e6);
        uint256 aliceShares_ = vault.balanceOf(alice);

        uint256 ghost_ = _requestRedeem(alice, 1);               // id 0: 1 share, fee 1 -> 0 queued
        uint256 real_  = _requestRedeem(alice, 50e6);            // id 1: 49.5e6 queued
        assertEq(ghost_, 0);
        assertEq(real_,  1);

        (address o_, address r_, uint256 s_) = vault.getPendingRedeemRequest(ghost_);
        assertEq(o_, alice);                                     // owner / recipient are recorded ...
        assertEq(r_, alice);
        assertEq(s_, 0);                                         // ... but the ghost carries 0 shares
        (o_, r_, s_) = vault.getPendingRedeemRequest(real_);
        assertEq(o_, alice);
        assertEq(s_, 49_500_000);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingRedeemRequest(2);

        // Partial fill of the real entry: the ghost at the head is walked (0 shares), head -> 1.
        _processRedeems(20e6, 10);
        assertEq(vault.firstPendingRedeemId(), real_);
        (o_, r_, s_) = vault.getPendingRedeemRequest(real_);
        assertEq(s_, 29_500_000);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingRedeemRequest(ghost_);                   // below the head now

        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), 2);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingRedeemRequest(real_);
        assertEq(vault.balanceOf(alice), aliceShares_ - 1 - 50e6);
    }

    /**********************************************************************************************/
    /*** availableCapacity / availableLiquidAssets / assetsOf / totalAssets / totalClaimable    ***/
    /**********************************************************************************************/

    function test_availableCapacity() public {
        assertEq(vault.availableCapacity(), type(uint128).max);

        _deposit(alice, 100e6);
        uint256 supply_ = vault.totalSupply();
        assertEq(vault.availableCapacity(), type(uint128).max - supply_);

        _setCapacity(supply_ + 1);
        assertEq(vault.availableCapacity(), 1);
        _setCapacity(supply_);
        assertEq(vault.availableCapacity(), 0);
        _setCapacity(supply_ - 1);
        assertEq(vault.availableCapacity(), 0);                  // clamps, never underflows
        _setCapacity(0);
        assertEq(vault.availableCapacity(), 0);

        // Capacity is in shares: a loss does not change it.
        _setCapacity(supply_ + 1_000e6);
        _adjustTotalAssetsWhilePaused(-50e6);
        assertEq(vault.availableCapacity(), 1_000e6);
        assertEq(vault.totalSupply(),       supply_);

        // Escrowed redeem shares still count toward totalSupply; burning them frees capacity.
        _requestRedeem(alice, 10e6);
        assertEq(vault.availableCapacity(), 1_000e6);
        _processRedeems(type(uint256).max, 1);
        assertEq(vault.availableCapacity(), 1_010e6);
    }

    function test_availableLiquidAssets_isSpUsdcMaxWithdraw() public {
        assertEq(vault.availableLiquidAssets(), 0);

        _deposit(alice, 100e6);
        assertEq(vault.availableLiquidAssets(), spUsdc.maxWithdraw(address(vault)));
        assertEq(vault.availableLiquidAssets(), 99_999_999);     // floor of the spUSDC index

        // Queued deposit backing counts too (F-2: not ring-fenced).
        _setCapacity(vault.totalSupply());
        _deposit(bob, 50e6);
        assertEq(vault.availableLiquidAssets(), 149_999_999);

        // spUSDC liquidity gone: bounded by spUSDC's USDC balance.
        uint256 spUsdcUsdc_ = usdc.balanceOf(address(spUsdc));
        _drainSpUsdcLiquidity(spUsdcUsdc_ - 10e6);
        assertEq(vault.availableLiquidAssets(), 10e6);
        _drainAllSpUsdcLiquidity();
        assertEq(vault.availableLiquidAssets(), 0);
        _returnSpUsdcLiquidity(spUsdcUsdc_);
        assertEq(vault.availableLiquidAssets(), 149_999_999);

        // spUSDC taken out of the vault: bounded by the vault's spUSDC balance.
        _take(_vaultSpUsdc() / 2);
        assertEq(vault.availableLiquidAssets(), spUsdc.convertToAssets(_vaultSpUsdc()));
        _takeAll();
        assertEq(vault.availableLiquidAssets(), 0);

        // USDC parked in the vault for claims is not liquid for redeems.
        usdc.mint(address(vault), 1e6);
        assertEq(vault.availableLiquidAssets(), 0);
    }

    function test_assetsOf() public {
        assertEq(vault.assetsOf(alice), 0);
        _deposit(alice, 100e6);
        assertEq(vault.assetsOf(alice), vault.convertToAssets(vault.balanceOf(alice)));
        assertEq(vault.assetsOf(alice), 99_999_998);             // two floors (spUSDC, spPRIME)
        assertEq(vault.assetsOf(bob),   0);

        // Escrowed redeem shares are the vault's own "assets".
        _requestRedeem(alice, 40e6);
        assertEq(vault.assetsOf(address(vault)), vault.convertToAssets(40e6));
        assertApproxEqAbs(vault.assetsOf(alice) + vault.assetsOf(address(vault)), vault.totalAssets(), 1);

        // Accrual moves it with nowChi, before any drip.
        _setPrimeVsr(TEN_PCT_VSR);
        _warp(365 days);
        assertEq(vault.assetsOf(alice), vault.balanceOf(alice) * vault.nowChi() / RAY);
        assertEq(vault.assetsOf(alice), 65_573_736);             // ~60e6 shares, +10% at the ugly index
    }

    function test_totalAssets_isNotionalOnly() public {
        assertEq(vault.totalAssets(), 0);
        _deposit(alice, 100e6);
        assertEq(vault.totalAssets(), vault.totalSupply() * vault.nowChi() / RAY);
        uint256 ta_ = vault.totalAssets();

        // Taking every spUSDC out does not change totalAssets (notional, index-based).
        _takeAll();
        assertEq(vault.totalAssets(), ta_);

        // USDC parked in the vault for a blacklisted redeemer is not counted either.
        _returnToVault(spUsdc.convertToShares(100e6) + 1);
        _requestRedeem(alice, 10e6);
        _blacklist(alice);
        _processRedeems(type(uint256).max, 10);
        assertGt(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.claimableAssets(alice), usdc.balanceOf(address(vault)));
        assertEq(vault.totalClaimable(),       usdc.balanceOf(address(vault)));
        assertEq(vault.totalAssets(), vault.totalSupply() * vault.nowChi() / RAY);
        assertApproxEqAbs(vault.totalAssets(), ta_ - vault.convertToAssets(10e6), 1);
    }

    // `totalClaimable` is the sum of every `claimableAssets` entry, credited by redeem and
    // cancellation fallbacks and decremented by `claim`; it always equals the USDC the vault
    // holds for claimants.
    function test_totalClaimable_tracksClaimableAssets() public {
        assertEq(vault.totalClaimable(), 0);

        _deposit(alice, 100e6);
        _deposit(bob,   100e6);
        _setCapacity(vault.totalSupply());
        uint256 cId = _deposit(carol, 50e6);                    // queued

        // Redeem fallback for alice (blacklisted at payout).
        _requestRedeem(alice, 40e6);
        _blacklist(alice);
        _processRedeems(type(uint256).max, 1);
        uint256 aliceClaim_ = vault.claimableAssets(alice);
        assertEq(aliceClaim_, 40_387_510);                       // 40e6 shares at the ugly index
        assertEq(vault.totalClaimable(), aliceClaim_);

        // Cancellation fallback for carol -> bob (blacklisted at payout).
        _cancel(carol, cId, bob);
        _blacklist(bob);
        _processCancelledDeposits(type(uint256).max, 1);
        uint256 bobClaim_ = vault.claimableAssets(bob);
        assertEq(bobClaim_, 49_999_999);
        assertEq(vault.totalClaimable(), aliceClaim_ + bobClaim_);
        assertEq(usdc.balanceOf(address(vault)), aliceClaim_ + bobClaim_);

        // A second credit to the same recipient accumulates.
        _requestRedeem(alice, 10e6);
        _processRedeems(type(uint256).max, 1);
        assertEq(vault.claimableAssets(alice), aliceClaim_ + 10_096_877);
        assertEq(vault.totalClaimable(), aliceClaim_ + 10_096_877 + bobClaim_);

        // Claims decrement; a claim with nothing to claim reverts.
        _unblacklist(alice);
        assertEq(vault.claim(alice), aliceClaim_ + 10_096_877);
        assertEq(vault.totalClaimable(), bobClaim_);
        assertEq(vault.claimableAssets(alice), 0);
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(alice);
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(carol);

        // Still-blacklisted bob: the claim's USDC transfer reverts, nothing is decremented.
        vm.expectRevert(BLACKLISTED);
        vault.claim(bob);
        assertEq(vault.totalClaimable(), bobClaim_);

        _unblacklist(bob);
        vault.claim(bob);
        assertEq(vault.totalClaimable(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /**********************************************************************************************/
    /*** ERC20 metadata and the full ISparkPrimeVault surface                                   ***/
    /**********************************************************************************************/

    function test_erc20Metadata() public {
        assertEq(vault.name(),     "Spark Prime USDC");
        assertEq(vault.symbol(),   "spPRIME");
        assertEq(vault.decimals(), 6);
        assertEq(vault.decimals(), usdc.decimals());
        assertEq(vault.version(),  "1");
        assertEq(vault.asset(),    address(usdc));
        assertEq(vault.savings(),  address(spUsdc));
        assertEq(vault.totalSupply(), 0);

        _deposit(alice, 100e6);
        assertEq(vault.totalSupply(),    99_040_517);   // 99_999_999 USDC-worth at the ugly index
        assertEq(vault.balanceOf(alice), 99_040_517);
        assertEq(vault.assetsOf(alice),  99_999_998);

        // Constants through the ABI.
        assertEq(vault.RAY(),            1e27);
        assertEq(vault.WAD(),            1e18);
        assertEq(vault.MAX_VSR(),        MAX_VSR);
        assertEq(vault.MAX_REDEEM_FEE(), 0.01e18);
        assertEq(
            vault.PERMIT_TYPEHASH(),
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
        );
    }

    // Every IERC20 / IERC20Metadata / IERC20Permit function is callable through the interface
    // the vault declares, with the vault's own semantics.
    function test_interface_erc20Surface() public {
        ISparkPrimeVault i = ISparkPrimeVault(address(vault));
        _deposit(alice, 100e6);

        assertEq(i.name(),     "Spark Prime USDC");
        assertEq(i.symbol(),   "spPRIME");
        assertEq(i.decimals(), 6);
        assertEq(i.totalSupply(),      99_040_517);
        assertEq(i.balanceOf(alice),   99_040_517);
        assertEq(i.allowance(alice, bob), 0);
        assertEq(i.nonces(alice),      0);
        assertEq(i.DOMAIN_SEPARATOR(), vault.DOMAIN_SEPARATOR());

        vm.prank(alice);
        assertTrue(i.approve(bob, 30e6));
        assertEq(i.allowance(alice, bob), 30e6);

        vm.prank(alice);
        assertTrue(i.transfer(carol, 10e6));
        assertEq(i.balanceOf(carol), 10e6);
        assertEq(i.balanceOf(alice), 89_040_517);

        vm.prank(bob);
        assertTrue(i.transferFrom(alice, bob, 20e6));
        assertEq(i.balanceOf(bob),        20e6);
        assertEq(i.allowance(alice, bob), 10e6);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-allowance");
        i.transferFrom(alice, bob, 10e6 + 1);

        // Both permit overloads: the IERC20Permit (v, r, s) one and the vault's bytes one.
        (address signer_, uint256 pk_) = makeAddrAndKey("signer");
        _deposit(signer_, 5e6);
        uint256 deadline_ = block.timestamp + 1 hours;
        bytes32 digest_ = keccak256(abi.encodePacked(
            "\x19\x01",
            i.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(vault.PERMIT_TYPEHASH(), signer_, bob, 1e6, 0, deadline_))
        ));
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(pk_, digest_);
        i.permit(signer_, bob, 1e6, deadline_, v_, r_, s_);
        assertEq(i.allowance(signer_, bob), 1e6);
        assertEq(i.nonces(signer_), 1);

        digest_ = keccak256(abi.encodePacked(
            "\x19\x01",
            i.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(vault.PERMIT_TYPEHASH(), signer_, carol, 2e6, 1, deadline_))
        ));
        (v_, r_, s_) = vm.sign(pk_, digest_);
        i.permit(signer_, carol, 2e6, deadline_, abi.encodePacked(r_, s_, v_));
        assertEq(i.allowance(signer_, carol), 2e6);
        assertEq(i.nonces(signer_), 2);

        // Replay of the first permit: nonce moved on.
        digest_ = keccak256(abi.encodePacked(
            "\x19\x01",
            i.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(vault.PERMIT_TYPEHASH(), signer_, bob, 1e6, 0, deadline_))
        ));
        (v_, r_, s_) = vm.sign(pk_, digest_);
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        i.permit(signer_, bob, 1e6, deadline_, v_, r_, s_);
        vm.expectRevert("SparkPrimeVault/permit-expired");
        i.permit(signer_, bob, 1e6, block.timestamp - 1, v_, r_, s_);
        vm.expectRevert("SparkPrimeVault/invalid-owner");
        i.permit(address(0), bob, 1e6, deadline_, v_, r_, s_);
    }

    // Every IAccessControl / IAccessControlEnumerable function through the interface, plus the
    // ERC165 answers of the enumerable extension.
    function test_interface_accessControlSurface() public {
        ISparkPrimeVault i = ISparkPrimeVault(address(vault));

        assertEq(vault.DEFAULT_ADMIN_ROLE(), bytes32(0));   // OZ parent, not in the interface
        assertEq(i.LOSS_MANAGER_ROLE(),      LOSS_MANAGER_ROLE);
        assertEq(i.OPERATOR_ROLE(),          OPERATOR_ROLE);
        assertEq(i.PAUSER_ROLE(),            PAUSER_ROLE);
        assertEq(i.UNPAUSER_ROLE(),          UNPAUSER_ROLE);
        assertEq(i.REDEEM_FEE_SETTER_ROLE(), REDEEM_FEE_SETTER_ROLE);
        assertEq(i.TAKER_ROLE(),             TAKER_ROLE);

        assertTrue(i.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(i.hasRole(LOSS_MANAGER_ROLE,  lossManager));
        assertTrue(i.hasRole(OPERATOR_ROLE,      operator));
        assertTrue(i.hasRole(PAUSER_ROLE,        pauser));
        assertTrue(i.hasRole(UNPAUSER_ROLE,      unpauser));
        assertTrue(i.hasRole(REDEEM_FEE_SETTER_ROLE, redeemFeeSetter));
        assertTrue(i.hasRole(TAKER_ROLE,         taker));
        assertFalse(i.hasRole(OPERATOR_ROLE,     alice));

        assertEq(i.getRoleAdmin(OPERATOR_ROLE),      bytes32(0));
        assertEq(i.getRoleAdmin(DEFAULT_ADMIN_ROLE), bytes32(0));
        assertEq(i.getRoleMemberCount(OPERATOR_ROLE), 1);
        assertEq(i.getRoleMember(OPERATOR_ROLE, 0),   operator);
        assertEq(vault.getRoleMembers(OPERATOR_ROLE).length, 1);

        vm.prank(admin);
        i.grantRole(OPERATOR_ROLE, alice);
        assertTrue(i.hasRole(OPERATOR_ROLE, alice));
        assertEq(i.getRoleMemberCount(OPERATOR_ROLE), 2);
        assertEq(i.getRoleMember(OPERATOR_ROLE, 1),   alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, alice, DEFAULT_ADMIN_ROLE
        ));
        i.grantRole(OPERATOR_ROLE, bob);

        vm.prank(admin);
        i.revokeRole(OPERATOR_ROLE, alice);
        assertFalse(i.hasRole(OPERATOR_ROLE, alice));
        assertEq(i.getRoleMemberCount(OPERATOR_ROLE), 1);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlBadConfirmation.selector));
        i.renounceRole(OPERATOR_ROLE, alice);
        vm.prank(operator);
        i.renounceRole(OPERATOR_ROLE, operator);
        assertEq(i.getRoleMemberCount(OPERATOR_ROLE), 0);
        vm.expectRevert();
        i.getRoleMember(OPERATOR_ROLE, 0);

        // ERC165 from the OZ parent (not part of ISparkPrimeVault, but on the ABI).
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
        assertTrue(vault.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(vault.supportsInterface(0x5a05180f));   // IAccessControlEnumerable
        assertFalse(vault.supportsInterface(0xffffffff));
    }

    /**********************************************************************************************/
    /*** convertToAssets / convertToShares                                                      ***/
    /**********************************************************************************************/

    function testFuzz_convertToAssets_monotonic(uint256 a, uint256 b) public view {
        a = bound(a, 0, type(uint128).max);
        b = bound(b, a, type(uint128).max);
        assertLe(vault.convertToAssets(a), vault.convertToAssets(b));
        assertLe(vault.convertToShares(a), vault.convertToShares(b));
    }

    // With chi > RAY: shares -> assets -> shares loses at most 1 share; assets -> shares ->
    // assets loses at most ceil(chi / RAY) assets and never gains.
    function testFuzz_convert_roundTripBounds(uint256 x, uint256 secs) public {
        x    = bound(x, 0, type(uint128).max);
        secs = bound(secs, 0, 10 * 365 days);
        _setPrimeVsr(FORTY_PCT_VSR);
        _warp(secs);
        uint256 chi_ = vault.nowChi();
        assertGt(chi_, RAY);

        uint256 assets_ = vault.convertToAssets(x);
        uint256 back_   = vault.convertToShares(assets_);
        assertLe(back_, x);
        assertGe(back_ + 1, x);

        uint256 shares_ = vault.convertToShares(x);
        uint256 backA_  = vault.convertToAssets(shares_);
        assertLe(backA_, x);
        assertGe(backA_ + (chi_ + RAY - 1) / RAY, x);
    }

    function test_convert_exactAtKnownChi() public {
        // Freeze time at rho so nowChi == chi, then pin chi = 1.5e27 in slot 7 (offset 8).
        vault.drip();
        _storeChi(1.5e27);
        assertEq(vault.chi(),                1.5e27);
        assertEq(vault.rho(),                block.timestamp);
        assertEq(vault.nowChi(),             1.5e27);
        assertEq(vault.convertToAssets(2),   3);
        assertEq(vault.convertToAssets(1),   1);      // floor(1.5)
        assertEq(vault.convertToShares(3),   2);
        assertEq(vault.convertToShares(1),   0);      // floor(0.66)
        assertEq(vault.convertToShares(2),   1);
        assertEq(vault.convertToAssets(0),   0);
        assertEq(vault.convertToShares(0),   0);
    }

    /**********************************************************************************************/
    /*** nowChi / drip                                                                          ***/
    /**********************************************************************************************/

    function test_nowChi_matchesDrip() public {
        vault.drip();
        uint192 chi0_ = vault.chi();
        assertEq(vault.rho(),    block.timestamp);
        assertEq(vault.nowChi(), chi0_);                         // timestamp == rho: raw chi

        // vsr == RAY: time passes, nowChi stays put, drip is a no-op on chi.
        _warp(30 days);
        assertEq(vault.nowChi(), chi0_);
        assertEq(vault.drip(),   chi0_);
        assertEq(vault.chi(),    chi0_);
        assertEq(vault.rho(),    block.timestamp);

        // vsr > RAY: nowChi previews exactly what drip will store.
        _setPrimeVsr(FIVE_PCT_VSR);
        _warp(365 days);
        uint192 preview_ = vault.nowChi();
        assertGt(preview_, chi0_);
        assertEq(vault.chi(), chi0_);                            // not stored yet
        uint192 dripped_ = vault.drip();
        assertEq(dripped_,       preview_);
        assertEq(vault.chi(),    preview_);
        assertEq(vault.nowChi(), preview_);
        assertApproxEqRel(uint256(preview_), uint256(chi0_) * 105 / 100, 0.0001e18);

        // Pause does not freeze the index: nowChi keeps growing and drip still works.
        _pause();
        _warp(1 days);
        assertGt(vault.nowChi(), preview_);
        assertEq(vault.drip(), vault.nowChi());
        assertGt(vault.chi(),  preview_);
    }

    // The Drip event carries the new chi and the asset diff of the whole supply.
    function test_drip_event() public {
        _deposit(alice, 100e6);
        _setPrimeVsr(FIVE_PCT_VSR);
        _warp(365 days);
        uint192 next_ = vault.nowChi();
        uint192 chi0_ = vault.chi();
        uint256 supply_ = vault.totalSupply();
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Drip(next_, supply_ * next_ / RAY - supply_ * chi0_ / RAY);
        vault.drip();
    }

    // rho is only ever set to block.timestamp, so it is never ahead of it on a chain; if it
    // were, both views short-circuit to the raw chi and drip leaves rho alone.
    function test_nowChi_rhoInFuture() public {
        vault.drip();
        uint192 chi0_ = vault.chi();
        _setPrimeVsr(FIVE_PCT_VSR);
        vm.warp(block.timestamp - 1);
        assertEq(vault.nowChi(), chi0_);
        assertEq(vault.drip(),   chi0_);
        assertEq(vault.rho(),    block.timestamp + 1);
    }

    /**********************************************************************************************/
    /*** DOMAIN_SEPARATOR / implementation                                                      ***/
    /**********************************************************************************************/

    function test_DOMAIN_SEPARATOR() public {
        bytes32 expected_ = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Spark Prime USDC"),
            keccak256("1"),
            block.chainid,
            address(vault)
        ));
        assertEq(vault.DOMAIN_SEPARATOR(), expected_);
        assertEq(vault.version(), "1");

        // Not cached: it follows the live chain id (safe on chain forks).
        vm.chainId(999);
        assertTrue(vault.DOMAIN_SEPARATOR() != expected_);
        assertEq(vault.DOMAIN_SEPARATOR(), keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Spark Prime USDC"),
            keccak256("1"),
            uint256(999),
            address(vault)
        )));

        // `name` has no setter, so the separator can only move with the chain id.
        (bool ok_, ) = address(vault).call(abi.encodeWithSignature("setName(string)", "x"));
        assertFalse(ok_);
    }

    function test_implementation() public {
        address impl_ = address(uint160(uint256(vm.load(address(vault), IMPLEMENTATION_SLOT))));
        assertEq(vault.implementation(), impl_);
        assertGt(impl_.code.length, 0);
        assertEq(SparkPrimeVault(impl_).implementation(), address(0));  // slot empty on the impl

        address fresh_ = address(new SparkPrimeVault());
        vm.prank(admin);
        vault.upgradeToAndCall(fresh_, "");
        assertEq(vault.implementation(), fresh_);
    }

    /**********************************************************************************************/
    /*** Overflow bounds of the index maths (R5-1 / G-1, R5-8 / V2-7: still open at c512609)    ***/
    /**********************************************************************************************/

    // `adjustTotalAssets` only checks `chi <= type(uint192).max` (~6.28e57, `:280`), but `drip`
    // and `nowChi` compute `_rpow(vsr, dt) * chi` in uint256 (`:655`, `:846`). With vsr == RAY
    // the product is exactly `RAY * chi`, so any `chi > type(uint256).max / RAY`
    // (= 115792089237316195423570985008687907853269984665640564039457, ~1.158e50) makes every
    // index read revert with panic 0x11 from the next second on. `adjustTotalAssets` calls
    // `drip()` first, so it cannot undo itself once a block has passed; only an upgrade can.
    function test_BUG_adjustTotalAssets_chiAboveRpowBoundBricksVault() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply_ = vault.totalSupply();

        // Smallest delta that lands chi above the bound: chi = (TA + delta) * RAY / supply.
        _pause();
        vault.drip();
        uint256 ta_      = vault.totalAssets();
        uint256 target_  = CHI_RPOW_BOUND + 1;
        uint256 needTa_  = (target_ * supply_ + RAY - 1) / RAY;      // ceil so chi >= target
        int256  delta_   = int256(needTa_ - ta_);
        emit log_named_uint("supply", supply_);
        emit log_named_int("delta (USDC wei)", delta_);

        _adjustTotalAssets(delta_);
        uint256 chi_ = vault.chi();
        assertGt(chi_, CHI_RPOW_BOUND);
        assertLe(chi_, type(uint192).max);

        // Same block: everything still reads (timestamp == rho short-circuits).
        assertEq(vault.nowChi(), chi_);
        assertEq(vault.totalAssets(), supply_ * chi_ / RAY);

        // One second later: every index read and every state-changing path that drips panics.
        _warp(1);
        vm.expectRevert(PANIC_OVERFLOW); vault.nowChi();
        vm.expectRevert(PANIC_OVERFLOW); vault.drip();
        vm.expectRevert(PANIC_OVERFLOW); vault.totalAssets();
        vm.expectRevert(PANIC_OVERFLOW); vault.convertToAssets(1);
        vm.expectRevert(PANIC_OVERFLOW); vault.convertToShares(1);
        vm.expectRevert(PANIC_OVERFLOW); vault.assetsOf(alice);

        vm.prank(lossManager);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.adjustTotalAssets(-delta_);                        // cannot undo: drip() first
        vm.prank(operator);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.setVSR(RAY);

        _unpause();
        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.requestDeposit(1e6, bob, 0);
        vm.prank(alice);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.requestRedeem(1e6, alice);
        vm.prank(operator);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.processPendingRedeems(type(uint256).max, 1);
        vm.prank(operator);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.processPendingDeposits(type(uint256).max, 1);
        vm.prank(operator);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.processPendingDepositCancellations(type(uint256).max, 1);

        // What still works: plain ERC20 moves, take, pause, role admin, upgrade.
        vm.prank(alice);
        vault.transfer(bob, 1);
        assertEq(vault.balanceOf(bob), 1);
        _takeAll();
        assertEq(_vaultSpUsdc(), 0);

        // Only an upgrade to code that rewrites chi recovers; vm.store stands in for that
        // implementation to show the rest of the state is intact.
        _storeChi(2e27);
        assertEq(vault.nowChi(), 2e27);
        assertEq(vault.balanceOf(alice), supply_ - 1);
    }

    // The only non-upgrade recovery is in the SAME block: `drip()` short-circuits while
    // `block.timestamp == rho`, so a second `adjustTotalAssets` in the same block can pull chi
    // back below the bound. One second later the door is shut.
    function test_BUG_adjustTotalAssets_chiBrickRecoverableOnlyInSameBlock() public {
        _deposit(alice, 1_000_000e6);
        uint256 supply_ = vault.totalSupply();
        _pause();
        vault.drip();
        uint256 ta_     = vault.totalAssets();
        uint256 needTa_ = ((CHI_RPOW_BOUND + 1) * supply_ + RAY - 1) / RAY;
        int256  delta_  = int256(needTa_ - ta_);

        _adjustTotalAssets(delta_);
        assertGt(vault.chi(), CHI_RPOW_BOUND);

        uint256 snap_ = vm.snapshotState();

        // Same block: undo works and lands within 1 wei of chi of the original index.
        _adjustTotalAssets(-delta_);
        assertLe(vault.chi(), CHI_RPOW_BOUND);
        assertEq(vault.totalAssets(), ta_ - 2);   // 2 wei lost to the two floors of the round trip

        // Next block: the same undo panics inside drip().
        vm.revertToState(snap_);
        _warp(1);
        vm.prank(lossManager);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.adjustTotalAssets(-delta_);
    }

    // The `uint192(...)` casts in `drip` (`:655`) and `nowChi` (`:846`) can never truncate:
    // the uint256 product is bounded by type(uint256).max, so the quotient by RAY is at most
    // ~1.158e50 < type(uint192).max (~6.277e57). The real ceiling on chi is the uint256
    // product, not the uint192 storage type.
    function test_nowChi_uint192CastCannotTruncate() public pure {
        assertLt(CHI_RPOW_BOUND, type(uint192).max);
        assertEq(type(uint192).max / CHI_RPOW_BOUND, 54_210_108);   // ~5.4e7x headroom unused
    }

    // The exact threshold: chi == bound reads fine after any delay, chi == bound + 1 panics.
    function test_BUG_nowChi_exactRpowOverflowThreshold() public {
        _deposit(alice, 100e6);
        vault.drip();
        _warp(1);

        _storeChi(CHI_RPOW_BOUND);
        assertEq(vault.nowChi(), CHI_RPOW_BOUND);
        assertEq(vault.drip(),   CHI_RPOW_BOUND);

        _warp(1);
        _storeChi(CHI_RPOW_BOUND + 1);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.nowChi();
        vm.expectRevert(PANIC_OVERFLOW);
        vault.drip();

        // With vsr > RAY the bound is lower: `_rpow(MAX_VSR, 400 days)` ~= 2.14e27, so chi above
        // ~bound / 2 already panics after 400 days at the max rate.
        _storeChi(CHI_RPOW_BOUND / 2 + 1);
        _setPrimeVsr(MAX_VSR);                                   // drips at the current chi: fine
        _warp(400 days);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.nowChi();
    }

    // R5-8 / V2-7: `setCapacity` is unbounded and `_processPendingDeposits` computes
    // `convertToAssets(availableCapacity())` (`:864`), so a capacity more than
    // `type(uint256).max / nowChi` shares above `totalSupply` makes every deposit path panic.
    function test_BUG_availableCapacity_overflowInConvertToAssets() public {
        _deposit(alice, 100e6);
        uint256 supply_ = vault.totalSupply();
        uint256 chi_    = vault.nowChi();
        uint256 bound_  = type(uint256).max / chi_;              // ~1.146e50 shares at this chi

        _setCapacity(supply_ + bound_);
        assertEq(vault.convertToAssets(vault.availableCapacity()), bound_ * chi_ / RAY);
        _deposit(bob, 1e6);                                      // still fine
        assertGt(vault.balanceOf(bob), 0);

        _setCapacity(vault.totalSupply() + bound_ + 1);
        _fund(carol, 1e6);
        vm.prank(carol);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.requestDeposit(1e6, carol, 0);
        vm.prank(operator);
        vm.expectRevert(PANIC_OVERFLOW);
        vault.processPendingDeposits(type(uint256).max, 1);

        // The view itself reverts too, so a front end reading `convertToAssets(availableCapacity())`
        // breaks before the user does.
        uint256 avail_ = vault.availableCapacity();
        vm.expectRevert(PANIC_OVERFLOW);
        vault.convertToAssets(avail_);

        // Recoverable by the operator (setCapacity does not drip or convert).
        _setCapacity(type(uint128).max);
        _deposit(carol, 1e6);
        assertGt(vault.balanceOf(carol), 0);
    }

}
