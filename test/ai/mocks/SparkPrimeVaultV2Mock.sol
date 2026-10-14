// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { SparkPrimeVault } from "../../../src/SparkPrimeVault.sol";

/// @dev Upgrade target for the upgrade tests: identical layout (inherits the V1 contract on
///      `refactor/more-simplifying`, slots 0..26 ending in `allowance` at 26), one appended
///      storage variable (slot 27) and a `reinitializer(2)` entry point.
contract SparkPrimeVaultV2Mock is SparkPrimeVault {

    uint256 public newVar;  // Appended after `allowance` (slot 26) -> slot 27

    function initializeV2(uint256 newVar_) external reinitializer(2) {
        newVar = newVar_;
    }

    function version2() external pure returns (string memory) {
        return "2";
    }

}
