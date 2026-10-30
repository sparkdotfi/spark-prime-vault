// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../../lib/forge-std/src/Test.sol";

import { MockERC20, MockSavings } from "../../mocks/Mocks.sol";

import { SparkPrimeVault } from "../../../src/SparkPrimeVault.sol";

contract HandlerBase is Test {

    uint256 internal constant RAY = 1e27;

    uint256 public MAX_AMOUNT;

    MockERC20       internal asset;
    MockSavings     internal savings;
    SparkPrimeVault internal vault;

    // chi can only grow: no handler performs loss realization.
    modifier accountingCheck() {
        uint256 shareValue = vault.convertToAssets(1e18);
        _;
        assertGe(vault.convertToAssets(1e18), shareValue);
    }

    constructor(address vault_) {
        vault   = SparkPrimeVault(vault_);
        asset   = MockERC20(vault.asset());
        savings = MockSavings(vault.savings());

        MAX_AMOUNT = 10_000_000_000 * 10 ** asset.decimals();
    }

}
