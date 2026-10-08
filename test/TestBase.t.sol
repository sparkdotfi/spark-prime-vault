// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../lib/forge-std/src/Test.sol";

import { ERC1967Proxy } from "../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Ethereum } from "../lib/spark-address-registry/src/Ethereum.sol";

import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

interface IERC20Like {

    function balanceOf(address user) external view returns (uint256);

}

interface ISparkVaultLike {

    function balanceOf(address user) external view returns (uint256);

}

contract TestBase is Test {

    address internal admin       = makeAddr("admin");
    address internal guardian    = makeAddr("guardian");
    address internal rebalancer  = makeAddr("rebalancer");
    address internal riskManager = makeAddr("riskManager");
    address internal setter      = makeAddr("setter");
    address internal taker       = makeAddr("taker");
    address internal unpauser    = makeAddr("unpauser");

    bytes32 internal DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal GUARDIAN_ROLE      = keccak256("GUARDIAN_ROLE");
    bytes32 internal REBALANCER_ROLE    = keccak256("REBALANCER_ROLE");
    bytes32 internal RISK_MANAGER_ROLE  = keccak256("RISK_MANAGER_ROLE");
    bytes32 internal SETTER_ROLE        = keccak256("SETTER_ROLE");
    bytes32 internal TAKER_ROLE         = keccak256("TAKER_ROLE");
    bytes32 internal UNPAUSER_ROLE      = keccak256("UNPAUSER_ROLE");

    IERC20Like      internal usdc   = IERC20Like(Ethereum.USDC);
    ISparkVaultLike internal spUsdc = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDC);

    SparkPrimeVault internal vault;

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl, 26148600);

        vault = SparkPrimeVault(
            address(new ERC1967Proxy(
                address(new SparkPrimeVault()),
                abi.encodeCall(
                    SparkPrimeVault.initialize,
                    (address(usdc), address(spUsdc), "Spark Prime USDC", "spPRIME", admin)
                )
            ))
        );
    }

}
