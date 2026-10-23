// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { HalmosTestBase } from "./HalmosTestBase.t.sol";

// Run with --solver cvc5-int (and HALMOS_ALLOW_DOWNLOAD=1 once): bitvector solvers
// time out on the mulDiv chains.
contract SolvencyCheck is HalmosTestBase {

    // Redeem payouts draw from the same savings balance that backs queued deposits. A holder's
    // full exit must consume exactly its own backing, leaving a queued deposit of any size
    // untouched. Rates stay at RAY (exact equality); the holder amount is concrete for the solver.
    function check_queuedDepositBackedAfterHolderExit() external frozenTime {
        _deposit(userA, 1_000_000e6);

        _setCapacity(vault.totalSupply());  // zero free capacity: the next deposit stays queued

        uint256 queuedAssets = svm.createUint(64, "queuedAssets");
        vm.assume(queuedAssets >= 1);

        _deposit(userB, queuedAssets);
        assertEq(vault.balanceOf(userB), 0);

        uint256 holderShares = vault.balanceOf(userA);

        vm.prank(userA);
        vault.requestRedeem(holderShares, userA);

        vm.prank(operator);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);

        assertEq(vault.totalSupply(),         0);
        assertEq(vault.pendingRedeemShares(), 0);

        // At RAY rates 1 asset == 1 savings share == 1 prime share, so the units coincide
        assertEq(
            savings.balanceOf(address(vault)),
            vault.totalSupply()
                + vault.pendingDepositSavingsShares()
                + vault.pendingCancelledDepositSavingsShares()
        );
    }

}
