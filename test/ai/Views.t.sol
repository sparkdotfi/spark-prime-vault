// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { LocalTestBase } from "./LocalTestBase.t.sol";
import { SparkPrimeVault } from "../../src/SparkPrimeVault.sol";

/// @dev Every view on `master` @ 0ebb452: the three single-entry request getters (new), the
///      head-to-end and range array getters, `availableCapacity`, `availableLiquidAssets`,
///      `assetsOf`, `convertToAssets` / `convertToShares`, `nowChi` vs `drip`, `totalAssets`,
///      `DOMAIN_SEPARATOR`, `implementation`, plus the overflow bounds of the index maths.
contract ViewsTest is LocalTestBase {

    // keccak256("eip1967.proxy.implementation") - 1
    bytes32 constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Largest `chi` for which `_rpow(RAY, dt) * chi` (== RAY * chi) fits in uint256.
    uint256 constant CHI_RPOW_BOUND = type(uint256).max / 1e27;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");

    /**********************************************************************************************/
    /*** Array getters                                                                          ***/
    /**********************************************************************************************/

    function test_getPendingRequests_emptyQueues() public view {
        assertEq(vault.getPendingDepositRequests().length,             0);
        assertEq(vault.getPendingDepositCancellationRequests().length, 0);
        assertEq(vault.getPendingRedeemRequests().length,              0);
        assertEq(vault.getPendingDepositRequests(0, 0).length,         0);
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
        assertEq(pending[1].shares,    23_863_317);

        // Range getter covers any id, including the deleted one.
        SparkPrimeVault.Request[] memory all = vault.getPendingDepositRequests(0, 3);
        assertEq(all.length,     3);
        assertEq(all[0].owner,   address(0));
        assertEq(all[0].shares,  0);
        assertEq(all[2].owner,   carol);
        assertEq(_depositQueueLength(), 3);
    }

    function test_getPendingDepositRequests_rangeValidation() public {
        _setCapacity(0);
        _deposit(alice, 100e6);

        vm.expectRevert("SparkPrimeVault/invalid-range");
        vault.getPendingDepositRequests(1, 0);
        vm.expectRevert("SparkPrimeVault/invalid-range");
        vault.getPendingDepositRequests(0, 2);
        vm.expectRevert("SparkPrimeVault/invalid-range");
        vault.getPendingDepositCancellationRequests(0, 1);
        vm.expectRevert("SparkPrimeVault/invalid-range");
        vault.getPendingRedeemRequests(0, 1);
        vm.expectRevert("SparkPrimeVault/invalid-range");
        vault.getPendingDepositRequests(type(uint256).max, type(uint256).max);

        assertEq(vault.getPendingDepositRequests(1, 1).length, 0);   // empty range at the end is fine
        assertEq(vault.getPendingDepositRequests(0, 1).length, 1);
    }

    // 0ebb452: cancelling no longer advances the deposit head (the head-advance loop was removed
    // from `requestDepositCancellation`), so the cancelled entry stays visible as a zeroed
    // element of `getPendingDepositRequests()` until a processing walk passes it.
    function test_getPendingDepositCancellationRequests_tracksCancelAndSettle() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, 100e6);
        vm.prank(alice);
        uint256 cid = vault.requestDepositCancellation(id, bob);
        assertEq(cid, 0);

        SparkPrimeVault.Request[] memory pending = vault.getPendingDepositCancellationRequests();
        assertEq(pending.length,       1);
        assertEq(pending[0].owner,     alice);
        assertEq(pending[0].recipient, bob);
        assertEq(pending[0].shares,    95_453_269);

        SparkPrimeVault.Request[] memory deposits = vault.getPendingDepositRequests();
        assertEq(deposits.length,    1);          // cancelled entry still inside the window
        assertEq(deposits[0].owner,  address(0));
        assertEq(deposits[0].shares, 0);
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(vault.getPendingDepositCancellationRequests().length, 0);
        assertEq(vault.firstPendingDepositCancellationId(),            1);
        assertEq(vault.getPendingDepositCancellationRequests(0, 1)[0].shares, 0);
        assertEq(usdc.balanceOf(bob), 99_999_999);
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

    function testFuzz_getPendingRequests_matchHeadAndCounters(uint8 n, uint8 cancelMask) public {
        n = uint8(bound(n, 1, 12));
        _setCapacity(0);
        for (uint256 i; i < n; ++i) _deposit(makeAddr(string(abi.encodePacked("u", i))), 10e6 * (i + 1));
        for (uint256 i; i < n; ++i) {
            if (cancelMask & (1 << (i % 8)) != 0) {
                address who = makeAddr(string(abi.encodePacked("u", i)));
                vm.prank(who);
                vault.requestDepositCancellation(i, who);
            }
        }
        SparkPrimeVault.Request[] memory pending = vault.getPendingDepositRequests();
        uint256 head = vault.firstPendingDepositId();
        assertEq(head,           0);   // no walk with remaining == 0 ever moves the head
        assertEq(pending.length, n - head);
        uint256 sum;
        for (uint256 i; i < pending.length; ++i) {
            sum += pending[i].shares;
            (address o_, address r_, uint256 s_) = vault.getPendingDepositRequest(head + i);
            assertEq(o_, pending[i].owner);
            assertEq(r_, pending[i].recipient);
            assertEq(s_, pending[i].shares);
        }
        assertEq(sum, vault.pendingDepositSavingsShares());

        SparkPrimeVault.Request[] memory cancelled = vault.getPendingDepositCancellationRequests();
        uint256 csum;
        for (uint256 i; i < cancelled.length; ++i) csum += cancelled[i].shares;
        assertEq(csum, vault.pendingCancelledDepositSavingsShares());
    }

    // Round 4: a range read of a deleted head entry in each of the three queues returns the
    // zeroed struct, the head-to-end view excludes it, and the range `(head - 1, head)` is a
    // legal, one-element, all-zero read. Reading the deleted slot never reverts and never
    // confuses it with an open entry.
    function test_getPendingRequests_rangeReadOfDeletedHeadEntry() public {
        // Deposit queue: id 0 filled instantly and deleted; id 1 queued.
        _deposit(alice, 100e6);
        _setCapacity(vault.totalSupply());
        _deposit(bob, 50e6);
        assertEq(vault.firstPendingDepositId(), 1);

        SparkPrimeVault.Request[] memory d = vault.getPendingDepositRequests(0, 1);
        assertEq(d.length,       1);
        assertEq(d[0].owner,     address(0));
        assertEq(d[0].recipient, address(0));
        assertEq(d[0].shares,    0);
        assertEq(vault.getPendingDepositRequests().length, 1);
        assertEq(vault.getPendingDepositRequests()[0].owner, bob);

        // Cancellation queue: bob cancels, planner settles, slot 0 is deleted and the head is 1.
        vm.prank(bob);
        vault.requestDepositCancellation(1, bob);
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        SparkPrimeVault.Request[] memory c = vault.getPendingDepositCancellationRequests(0, 1);
        assertEq(c[0].owner,     address(0));
        assertEq(c[0].recipient, address(0));
        assertEq(c[0].shares,    0);
        assertEq(vault.getPendingDepositCancellationRequests().length, 0);
        assertEq(vault.getPendingDepositCancellationRequests(1, 1).length, 0);

        // Redeem queue: alice's redeem is paid in full and deleted; carol's stays open behind it.
        _setCapacity(type(uint128).max);
        _deposit(carol, 10e6);   // walks past bob's cancelled id 1, fills id 2, head -> 3
        assertEq(vault.firstPendingDepositId(), 3);
        _requestRedeem(alice, vault.balanceOf(alice));
        _requestRedeem(carol, vault.balanceOf(carol));
        _processRedeems(type(uint256).max, 1);
        assertEq(vault.firstPendingRedeemId(), 1);

        SparkPrimeVault.Request[] memory r = vault.getPendingRedeemRequests(0, 2);
        assertEq(r.length,       2);
        assertEq(r[0].owner,     address(0));
        assertEq(r[0].recipient, address(0));
        assertEq(r[0].shares,    0);
        assertEq(r[1].owner,     carol);
        assertEq(r[1].shares,    vault.pendingRedeemShares());
        assertEq(vault.getPendingRedeemRequests().length, 1);
        assertEq(vault.getPendingRedeemRequests()[0].owner, carol);

        // Past the end is still rejected, exactly at the end is an empty read.
        vm.expectRevert("SparkPrimeVault/invalid-range");
        vault.getPendingRedeemRequests(0, 3);
        assertEq(vault.getPendingRedeemRequests(2, 2).length, 0);
    }

    /**********************************************************************************************/
    /*** Single-entry getters (new at 0ebb452)                                                  ***/
    /**********************************************************************************************/

    function test_getPendingDepositRequest_bounds() public {
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositRequest(0);                       // empty queue: 0 == length

        _deposit(alice, 100e6);                                  // id 0, instant, head -> 1
        assertEq(vault.firstPendingDepositId(), 1);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositRequest(0);                       // below head (filled)
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
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
        assertEq(s_, 23_863_317);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositRequest(3);                       // == length
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositRequest(type(uint256).max);

        // Cancelled id inside the window returns all zeros, no revert.
        vm.prank(bob);
        vault.requestDepositCancellation(bobId, bob);
        (o_, r_, s_) = vault.getPendingDepositRequest(bobId);
        assertEq(o_, address(0));
        assertEq(r_, address(0));
        assertEq(s_, 0);
        assertEq(vault.firstPendingDepositId(), 1);              // head unchanged by the cancel

        // Partial fill of carol: capacity for roughly half of her request. The getter reports
        // the remaining spUSDC shares and the head stays on her id.
        uint256 halfSavings_ = uint256(23_863_317) / 2;
        uint256 halfShares_  = vault.convertToShares(spUsdc.convertToAssets(halfSavings_));
        _setCapacity(vault.totalSupply() + halfShares_);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(), carolId);
        (o_, r_, s_) = vault.getPendingDepositRequest(carolId);
        assertEq(o_, carol);
        assertGt(s_, 0);
        assertLt(s_, 23_863_317);
        assertEq(s_, vault.pendingDepositSavingsShares());
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositRequest(bobId);                   // now below the head

        // Full fill: head == length, every id rejected.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(), 3);
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositRequest(carolId);
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositRequest(3);
        assertEq(vault.getPendingDepositRequests().length, 0);
    }

    function test_getPendingDepositCancellationRequest_bounds() public {
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositCancellationRequest(0);

        _setCapacity(0);
        uint256 aId = _deposit(alice, 100e6);
        uint256 bId = _deposit(bob,   40e6);

        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositCancellationRequest(0);           // nothing cancelled yet

        vm.prank(alice);
        uint256 ca_ = vault.requestDepositCancellation(aId, carol);
        vm.prank(bob);
        uint256 cb_ = vault.requestDepositCancellation(bId, bob);
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
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
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
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositCancellationRequest(0);
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositCancellationRequest(1);
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingDepositCancellationRequest(2);
        assertApproxEqAbs(usdc.balanceOf(carol), 100e6, 2);
        assertEq(usdc.balanceOf(bob), 39_999_999);
    }

    function test_getPendingRedeemRequest_bounds() public {
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
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
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingRedeemRequest(2);

        // Partial fill of the real entry: the ghost at the head is skipped, head moves to 1.
        _processRedeems(20e6, 10);
        assertEq(vault.firstPendingRedeemId(), real_);
        (o_, r_, s_) = vault.getPendingRedeemRequest(real_);
        assertEq(s_, 29_500_000);
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingRedeemRequest(ghost_);                   // below the head now

        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), 2);
        vm.expectRevert("SparkPrimeVault/invalid-request-id");
        vault.getPendingRedeemRequest(real_);
        assertEq(vault.balanceOf(alice), aliceShares_ - 1 - 50e6);
    }

    /**********************************************************************************************/
    /*** Views that mislead                                                                     ***/
    /**********************************************************************************************/

    // With `availableCapacity() == 0` the deposit walk never runs (`remaining_ == 0`), so
    // cancelled entries stay inside `getPendingDepositRequests()` as zero structs indefinitely,
    // and `processPendingDeposits(max, max)` by the rebalancer cannot clear them either. The
    // view's `length` therefore overstates the number of open requests; integrators must filter
    // `shares == 0`. Once capacity returns, the next depositor pays the walk over every ghost.
    function test_getPendingDepositRequests_includesCancelledWhileCapacityIsZero() public {
        _setCapacity(0);
        uint256 n_ = 50;
        for (uint256 i; i < n_; ++i) {
            address who_ = makeAddr(string(abi.encodePacked("g", i)));
            uint256 id_  = _deposit(who_, 1e6);
            vm.prank(who_);
            vault.requestDepositCancellation(id_, who_);
        }
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.getPendingDepositRequests().length, n_);   // all ghosts
        assertEq(vault.firstPendingDepositId(), 0);

        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingDepositId(), 0);              // cannot advance at capacity 0
        assertEq(vault.getPendingDepositRequests().length, n_);

        // Capacity returns: the next deposit walks all 50 ghosts, fills itself, view is empty.
        _setCapacity(type(uint128).max);
        _fund(alice, 100e6);
        vm.prank(alice);
        uint256 gasBefore_ = gasleft();
        vault.requestDeposit(100e6, alice, 0);
        uint256 gasWithGhosts_ = gasBefore_ - gasleft();
        assertEq(vault.firstPendingDepositId(), n_ + 1);
        assertEq(vault.getPendingDepositRequests().length, 0);

        _fund(bob, 100e6);
        vm.prank(bob);
        gasBefore_ = gasleft();
        vault.requestDeposit(100e6, bob, 0);
        uint256 gasClean_ = gasBefore_ - gasleft();

        emit log_named_uint("gas with 50 ghosts", gasWithGhosts_);
        emit log_named_uint("gas clean",          gasClean_);
        // Measured: 231_756 vs 168_206, i.e. ~1.27k gas per ghost entry.
        assertGt(gasWithGhosts_, gasClean_ + n_ * 1_000);
        assertLt(gasWithGhosts_, gasClean_ + n_ * 2_000);
    }

    /**********************************************************************************************/
    /*** availableCapacity / availableLiquidAssets / assetsOf / totalAssets                     ***/
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
        assertEq(vault.totalAssets(), vault.totalSupply() * vault.nowChi() / RAY);
        assertApproxEqAbs(vault.totalAssets(), ta_ - vault.convertToAssets(10e6), 1);
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
        // Freeze time at rho so nowChi == chi, then pin chi = 1.5e27 with vm.store (slot 8).
        vault.drip();
        vm.store(address(vault), bytes32(uint256(8)), bytes32(uint256(1.5e27)));
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
    /*** Overflow bounds of the index maths (G-1 / G-2 / V2-7, still open at 0ebb452)           ***/
    /**********************************************************************************************/

    // `adjustTotalAssets` only checks `chi <= type(uint192).max` (~6.28e57), but `drip` and
    // `nowChi` compute `_rpow(vsr, dt) * chi` in uint256 (`:637`, `:811`). With vsr == RAY the
    // product is exactly `RAY * chi`, so any `chi > type(uint256).max / RAY`
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

        vm.prank(admin);
        vault.adjustTotalAssets(delta_);
        uint256 chi_ = vault.chi();
        assertGt(chi_, CHI_RPOW_BOUND);
        assertLe(chi_, type(uint192).max);

        // Same block: everything still reads (timestamp == rho short-circuits), and the admin
        // could still lower it back.
        assertEq(vault.nowChi(), chi_);
        assertEq(vault.totalAssets(), supply_ * chi_ / RAY);

        // One second later: every index read and every state-changing path that drips panics.
        _warp(1);
        bytes memory panic_ = abi.encodeWithSignature("Panic(uint256)", 0x11);
        vm.expectRevert(panic_); vault.nowChi();
        vm.expectRevert(panic_); vault.drip();
        vm.expectRevert(panic_); vault.totalAssets();
        vm.expectRevert(panic_); vault.convertToAssets(1);
        vm.expectRevert(panic_); vault.convertToShares(1);
        vm.expectRevert(panic_); vault.assetsOf(alice);

        vm.prank(admin);
        vm.expectRevert(panic_);
        vault.adjustTotalAssets(-delta_);                        // cannot undo: drip() first
        vm.prank(vsrSetter);
        vm.expectRevert(panic_);
        vault.setVSR(RAY);

        _unpause();
        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(panic_);
        vault.requestDeposit(1e6, bob, 0);
        vm.prank(alice);
        vm.expectRevert(panic_);
        vault.requestRedeem(1e6, alice);
        vm.prank(rebalancer);
        vm.expectRevert(panic_);
        vault.processPendingRedeems(type(uint256).max, 1);
        vm.prank(rebalancer);
        vm.expectRevert(panic_);
        vault.processPendingDeposits(type(uint256).max, 1);
        vm.prank(rebalancer);
        vm.expectRevert(panic_);
        vault.processPendingDepositCancellations(type(uint256).max, 1);

        // What still works: plain ERC20 moves, take, pause, role admin, upgrade.
        vm.prank(alice);
        vault.transfer(bob, 1);
        assertEq(vault.balanceOf(bob), 1);
        _takeAll();
        assertEq(_vaultSpUsdc(), 0);

        // Only an upgrade to code that rewrites chi recovers; vm.store stands in for that
        // implementation to show the rest of the state is intact.
        vm.store(address(vault), bytes32(uint256(8)), bytes32(uint256(2e27)));
        assertEq(vault.nowChi(), 2e27);
        assertEq(vault.balanceOf(alice), supply_ - 1);
    }

    // The exact threshold: chi == bound reads fine after any delay, chi == bound + 1 panics.
    function test_BUG_nowChi_exactRpowOverflowThreshold() public {
        _deposit(alice, 100e6);
        vault.drip();
        _warp(1);

        vm.store(address(vault), bytes32(uint256(8)), bytes32(CHI_RPOW_BOUND));
        assertEq(vault.nowChi(), CHI_RPOW_BOUND);
        assertEq(vault.drip(),   CHI_RPOW_BOUND);

        _warp(1);
        vm.store(address(vault), bytes32(uint256(8)), bytes32(CHI_RPOW_BOUND + 1));
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        vault.nowChi();
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        vault.drip();

        // With vsr > RAY the bound is lower: `_rpow(MAX_VSR, 400 days)` ~= 2.14e27, so chi above
        // ~bound / 2 already panics after 400 days at the max rate.
        vm.store(address(vault), bytes32(uint256(8)), bytes32(CHI_RPOW_BOUND / 2 + 1));
        _setPrimeVsr(MAX_VSR);                                   // drips at the current chi: fine
        _warp(400 days);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        vault.nowChi();
    }

    // V2-7: `setCapacity` is unbounded and `_processPendingDeposits` computes
    // `convertToAssets(availableCapacity())` (`:829`), so a capacity more than
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
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        vault.requestDeposit(1e6, carol, 0);
        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        vault.processPendingDeposits(type(uint256).max, 1);

        // The view itself reverts too, so a front end reading `convertToAssets(availableCapacity())`
        // breaks before the user does.
        uint256 avail_ = vault.availableCapacity();
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        vault.convertToAssets(avail_);

        // Recoverable by the admin (setCapacity does not drip or convert).
        _setCapacity(type(uint128).max);
        _deposit(carol, 1e6);
        assertGt(vault.balanceOf(carol), 0);
    }

}
