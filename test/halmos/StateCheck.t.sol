// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";

import { SeededHalmosTestBase } from "./HalmosTestBase.t.sol";

contract StateCheck is SeededHalmosTestBase {

    function _generalize() internal {
        _setCapacity(svm.createUint256("capacity"));
        _symbolicRates();
    }

    function check_redeemEscrow() external frozenTime {
        _generalize();
        vm.assume(vault.balanceOf(address(vault)) == vault.pendingRedeemShares());

        _anyCall();

        assertEq(vault.balanceOf(address(vault)), vault.pendingRedeemShares());
    }

    function check_supplyTransitions() external frozenTime {
        _generalize();
        uint256 supplyBefore = vault.totalSupply();

        bytes4 selector = _anyCall();

        if (vault.totalSupply() > supplyBefore) {
            assertTrue(
                selector == vault.requestDeposit.selector ||
                selector == vault.processPendingDeposits.selector
            );
        }
        if (vault.totalSupply() < supplyBefore) {
            assertTrue(
                selector == vault.requestRedeem.selector ||
                selector == vault.processPendingRedeems.selector
            );
        }
    }

    function check_queueGrowth() external frozenTime {
        _generalize();
        ( uint256 deposits, uint256 cancellations, uint256 redeems ) = _queueLengths();

        uint256 depositHead = vault.firstPendingDepositId();
        uint256 cancelHead  = vault.firstPendingDepositCancellationId();
        uint256 redeemHead  = vault.firstPendingRedeemId();

        _anyCall();

        ( uint256 deposits_, uint256 cancellations_, uint256 redeems_ ) = _queueLengths();

        assertGe(deposits_,      deposits);
        assertGe(cancellations_, cancellations);
        assertGe(redeems_,       redeems);

        assertGe(vault.firstPendingDepositId(),             depositHead);
        assertGe(vault.firstPendingDepositCancellationId(), cancelHead);
        assertGe(vault.firstPendingRedeemId(),              redeemHead);
    }

    // Justifies processing the cancellation queue without a shares == 0 skip guard.
    function check_cancelQueueNoZeroEntries() external frozenTime {
        _generalize();
        _assumeNoZeroEntries(vault.getPendingDepositCancellationRequests());

        _anyCall();

        _assertNoZeroEntries(vault.getPendingDepositCancellationRequests());
    }

    // Expected counterexample: with any nonzero fee rate, requestRedeem(1) burns the whole
    // amount as fee and queues a zero-share entry.
    function check_redeemQueueNoZeroEntries() external frozenTime {
        _generalize();
        _setRedeemFeeRate(_gridFeeRate(svm.createUint(8, "feeIdx")));
        _assumeNoZeroEntries(vault.getPendingRedeemRequests());

        _anyCall();

        _assertNoZeroEntries(vault.getPendingRedeemRequests());
    }

    function check_claimableBacking() external frozenTime {
        _generalize();
        vm.assume(asset.balanceOf(address(vault)) >= vault.totalClaimable());

        _anyCall();

        assertGe(asset.balanceOf(address(vault)), vault.totalClaimable());
    }

    function check_pauseFreezesQueues() external frozenTime {
        _pause();

        bytes32 queuesBefore = _queueStateHash();
        uint256 supplyBefore = vault.totalSupply();

        // Cancellations are intentionally not pause gated.
        bytes4 selector = _anyCall();
        vm.assume(selector != vault.requestDepositCancellation.selector);
        vm.assume(selector != vault.processPendingDepositCancellations.selector);

        assertEq(_queueStateHash(),   queuesBefore);
        assertEq(vault.totalSupply(), supplyBefore);
    }

    function _assumeNoZeroEntries(ISparkPrimeVault.Request[] memory requests) internal pure {
        for (uint256 i = 0; i < requests.length; i++) {
            vm.assume(requests[i].shares != 0);
        }
    }

    function _assertNoZeroEntries(ISparkPrimeVault.Request[] memory requests) internal pure {
        for (uint256 i = 0; i < requests.length; i++) {
            assertGt(requests[i].shares, 0);
        }
    }

    function _queueStateHash() internal view returns (bytes32) {
        return keccak256(abi.encode(
            vault.pendingDepositSavingsShares(),
            vault.pendingCancelledDepositSavingsShares(),
            vault.pendingRedeemShares(),
            vault.firstPendingDepositId(),
            vault.firstPendingDepositCancellationId(),
            vault.firstPendingRedeemId()
        ));
    }

}
