// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";

import { SparkPrimeInvariantTestBase } from "./InvariantsBase.t.sol";

import { AdminHandler }    from "./handlers/AdminHandler.sol";
import { ExternalHandler } from "./handlers/ExternalHandler.sol";
import { OperatorHandler } from "./handlers/OperatorHandler.sol";
import { UserHandler }     from "./handlers/UserHandler.sol";

contract SparkPrimeVaultInvariantTest is SparkPrimeInvariantTestBase {

    uint256 internal lastChi;

    function setUp() public override {
        super.setUp();

        userHandler     = new UserHandler(address(vault), 10);
        adminHandler    = new AdminHandler(address(vault));
        operatorHandler = new OperatorHandler(address(vault));
        externalHandler = new ExternalHandler(address(vault), address(userHandler));

        targetContract(address(userHandler));
        targetContract(address(adminHandler));
        targetContract(address(operatorHandler));
        targetContract(address(externalHandler));

        lastChi = vault.chi();
    }

    function invariant_totalSupply() public view {
        uint256 sum = vault.balanceOf(address(vault));

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            sum += vault.balanceOf(userHandler.users(i));
        }

        assertEq(sum, vault.totalSupply());
    }

    // Entries behind a queue head are settled and zeroed, no getter exposes them, so they are
    // read via raw storage, with the slot math cross-checked against the first live entry.
    function invariant_processedEntriesZeroed() public view {
        _assertZeroedBelowHead(0, vault.firstPendingDepositId());
        _assertZeroedBelowHead(1, vault.firstPendingDepositCancellationId());
        _assertZeroedBelowHead(2, vault.firstPendingRedeemId());

        ISparkPrimeVault.Request[] memory live = vault.getPendingDepositRequests();
        if (live.length != 0) {
            assertEq(_sharesAt(0, vault.firstPendingDepositId()), live[0].shares);
        }
    }

    function invariant_pendingAggregates() public view {
        assertEq(
            _sumShares(vault.getPendingDepositRequests()),
            vault.pendingDepositSavingsShares()
        );
        assertEq(
            _sumShares(vault.getPendingDepositCancellationRequests()),
            vault.pendingCancelledDepositSavingsShares()
        );
        assertEq(
            _sumShares(vault.getPendingRedeemRequests()),
            vault.pendingRedeemShares()
        );
    }

    function invariant_claimableBacking() public view {
        assertEq(asset.balanceOf(address(vault)), vault.totalClaimable());
    }

    function invariant_claimableSum() public view {
        uint256 sum;

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            sum += vault.claimableAssets(userHandler.users(i));
        }

        assertEq(sum, vault.totalClaimable());
    }

    // Exact savings share ledger, valid while both rates stay at RAY:
    // savingsBal + taken == pendingDeposit + pendingCancel + totalSupply + burnedFees.
    function invariant_savingsShareLedger() public view {
        if (operatorHandler.ratesMoved() || externalHandler.ratesMoved()) return;

        assertEq(
            savings.balanceOf(address(vault)) + adminHandler.ghostTakenSavingsShares(),
            vault.pendingDepositSavingsShares()
                + vault.pendingCancelledDepositSavingsShares()
                + vault.totalSupply()
                + userHandler.ghostFeeShares()
        );
    }

    function invariant_rateAccumulator() public {
        assertGe(vault.vsr(),    RAY);
        assertLe(vault.vsr(),    vault.MAX_VSR());
        assertGe(vault.minVSR(), RAY);
        assertLe(vault.minVSR(), vault.maxVSR());
        assertLe(vault.maxVSR(), vault.MAX_VSR());

        assertLe(vault.rho(), block.timestamp);

        uint256 expectedChi = vault.nowChi();
        assertGe(vault.chi(), RAY);
        assertGe(expectedChi, vault.chi());
        assertEq(vault.drip(), expectedChi);

        assertGe(vault.chi(), lastChi);
        lastChi = vault.chi();
    }

    // Whatever state the fuzzer reached, the system can always unwind to zero with everyone paid.
    function afterInvariant() public {
        _unwind();
        _assertUnwound();
        invariant_totalSupply();
    }

    function _sumShares(ISparkPrimeVault.Request[] memory requests) internal pure returns (uint256 sum) {
        for (uint256 i = 0; i < requests.length; i++) {
            sum += requests[i].shares;
        }
    }

    function _assertZeroedBelowHead(uint256 arraySlot, uint256 head) internal view {
        for (uint256 i = 0; i < head; i++) {
            assertEq(_sharesAt(arraySlot, i), 0);
        }
    }

    // The three request arrays occupy slots 0 to 2, each Request takes three slots and
    // shares is the third.
    function _sharesAt(uint256 arraySlot, uint256 index) internal view returns (uint256) {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(arraySlot))) + 3 * index + 2);
        return uint256(vm.load(address(vault), slot));
    }

}
