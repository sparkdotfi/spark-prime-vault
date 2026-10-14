// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { LocalTestBase } from "./LocalTestBase.t.sol";
import { SparkPrimeVault } from "../../src/SparkPrimeVault.sol";

/// @dev The queue arrays became internal at 072e8d0; these views are now the only way to read them.
contract ViewsTest is LocalTestBase {

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");

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

        assertEq(vault.getPendingDepositRequests(1, 1).length, 0);   // empty range at the end is fine
        assertEq(vault.getPendingDepositRequests(0, 1).length, 1);
    }

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
        assertEq(vault.getPendingDepositRequests().length, 0);   // head walked past the cancelled entry

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
        assertEq(pending.length, n - head);
        uint256 sum;
        for (uint256 i; i < pending.length; ++i) sum += pending[i].shares;
        assertEq(sum, vault.pendingDepositSavingsShares());

        SparkPrimeVault.Request[] memory cancelled = vault.getPendingDepositCancellationRequests();
        uint256 csum;
        for (uint256 i; i < cancelled.length; ++i) csum += cancelled[i].shares;
        assertEq(csum, vault.pendingCancelledDepositSavingsShares());
    }
}
