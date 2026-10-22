// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Initializable } from "../lib/oz/contracts/proxy/utils/Initializable.sol";

import { ERC1967Proxy, TestBase, SparkPrimeVault } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

contract InitializeTests is TestBase {

    SparkPrimeVault internal implementation;

    function setUp() public override virtual {
        super.setUp();

        implementation = new SparkPrimeVault();
    }

    function _deploy(uint256 minDeposit, uint256 minDepositCancellation, uint256 minRedeem)
        internal
        returns (ISparkPrimeVault)
    {
        return SparkPrimeVault(
            address(new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(
                    ISparkPrimeVault.initialize,
                    (
                        address(spUSDC),
                        "Spark Prime USDC",
                        "spPrime",
                        admin,
                        minDeposit,
                        minDepositCancellation,
                        minRedeem
                    )
                )
            ))
        );
    }

    /**********************************************************************************************/
    /*** initialize                                                                             ***/
    /**********************************************************************************************/

    function test_initialize_zeroMinDeposit() external {
        vm.expectRevert(ISparkPrimeVault.ZeroMinDeposit.selector);
        _deploy(0, 0, 0);
    }

    function test_initialize_zeroMinDepositCancellation() external {
        vm.expectRevert(ISparkPrimeVault.ZeroMinDepositCancellation.selector);
        _deploy(1, 0, 0);
    }

    function test_initialize_zeroMinRedeem() external {
        vm.expectRevert(ISparkPrimeVault.ZeroMinRedeem.selector);
        _deploy(1, 1, 0);
    }

    function test_initialize_alreadyInitialized() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        spPrime.initialize(address(spUSDC), "Spark Prime USDC", "spPrime", admin, 1, 1, 1);
    }

    function test_initialize_implementationDisabled() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(spUSDC), "Spark Prime USDC", "spPrime", admin, 1, 1, 1);
    }

    function test_initialize() external {
        ISparkPrimeVault vault = _deploy(MINIMUM_DEPOSIT, MINIMUM_DEPOSIT_CANCELLATION, MINIMUM_REDEEM);

        assertEq(vault.savings(),  address(spUSDC));
        assertEq(vault.asset(),    address(usdc));
        assertEq(vault.name(),     "Spark Prime USDC");
        assertEq(vault.symbol(),   "spPrime");
        assertEq(vault.decimals(), 6);

        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));

        assertEq(vault.chi(),    RAY);
        assertEq(vault.rho(),    block.timestamp);
        assertEq(vault.vsr(),    RAY);
        assertEq(vault.minVSR(), RAY);
        assertEq(vault.maxVSR(), RAY);

        assertEq(vault.minDeposit(),             MINIMUM_DEPOSIT);
        assertEq(vault.minDepositCancellation(), MINIMUM_DEPOSIT_CANCELLATION);
        assertEq(vault.minRedeem(),              MINIMUM_REDEEM);

        assertEq(usdc.allowance(address(vault), address(spUSDC)), type(uint256).max);
    }

}
