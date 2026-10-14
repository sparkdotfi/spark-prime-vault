// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { SparkPrimeVault } from "../../src/SparkPrimeVault.sol";

/// @dev Upgrade target for the upgrade tests: identical layout (inherits the V1 contract),
///      one appended storage variable (slot 23) and a `reinitializer(2)` entry point.
contract SparkPrimeVaultV2Mock is SparkPrimeVault {

    uint256 public newVar;  // Appended after `allowance` (slot 22) -> slot 23

    function initializeV2(uint256 newVar_) external reinitializer(2) {
        newVar = newVar_;
    }

    function version2() external pure returns (string memory) {
        return "2";
    }

}
