// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { SparkPrimeVault } from "../../../src/SparkPrimeVault.sol";

/// @dev Upgrade target for the upgrade tests: identical layout (inherits the V1 contract on
///      `master` @ c512609, linear slots 0..28 ending in `allowance` at 28), one appended
///      storage variable (slot 29) and a `reinitializer(2)` entry point.
///
///      It also exposes raw reads of the three internal `Request[]` arrays so a test can prove
///      the new code sees exactly what the old code wrote (owner / recipient / shares of any id,
///      including filled and cancelled ids below the head, and the raw array lengths).
contract SparkPrimeVaultV2Mock is SparkPrimeVault {

    uint256 public newVar;  // Appended after `allowance` (slot 28) -> slot 29

    function initializeV2(uint256 newVar_) external reinitializer(2) {
        newVar = newVar_;
    }

    function version2() external pure returns (string memory) {
        return "2";
    }

    /**********************************************************************************************/
    /*** Raw reads of inherited storage (what a real V2 would see)                              ***/
    /**********************************************************************************************/

    function depositRequestsLength() external view returns (uint256) {
        return _depositRequests.length;
    }

    function depositCancellationRequestsLength() external view returns (uint256) {
        return _depositCancellationRequests.length;
    }

    function redeemRequestsLength() external view returns (uint256) {
        return _redeemRequests.length;
    }

    function rawDepositRequest(uint256 id_) external view returns (Request memory) {
        return _depositRequests[id_];
    }

    function rawDepositCancellationRequest(uint256 id_) external view returns (Request memory) {
        return _depositCancellationRequests[id_];
    }

    function rawRedeemRequest(uint256 id_) external view returns (Request memory) {
        return _redeemRequests[id_];
    }

}
