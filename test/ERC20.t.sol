// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ERC1967Proxy } from "../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Ethereum } from "../lib/spark-address-registry/src/Ethereum.sol";

import { TokenFuzzChecks } from "../lib/token-tests/src/TokenFuzzChecks.sol";

import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

contract ERC20Tests is TokenFuzzChecks {

    bytes32 internal VSR_SETTER_ROLE = keccak256("VSR_SETTER_ROLE");

    address internal admin     = makeAddr("admin");
    address internal vsrSetter = makeAddr("vsrSetter");

    SparkPrimeVault internal spPRIME;

    function setUp() public {
        vm.createSelectFork(getChain("mainnet").rpcUrl, _getBlock());

        spPRIME = SparkPrimeVault(
            address(new ERC1967Proxy(
                address(new SparkPrimeVault()),
                abi.encodeCall(
                    SparkPrimeVault.initialize,
                    (Ethereum.SPARK_VAULT_V2_SPUSDC, "Spark Prime USDC", "spPRIME", admin)
                )
            ))
        );

        vm.startPrank(admin);
        spPRIME.grantRole(VSR_SETTER_ROLE, vsrSetter);

        spPRIME.setVSRBounds(1e27, spPRIME.MAX_VSR());
        vm.stopPrank();
    }

    function _getBlock() internal pure returns (uint256) {
        return 26148600;
    }

    function testERC20() public {
        checkBulkERC20(address(spPRIME), "SparkPrimeVault", "Spark Prime USDC", "spPRIME", "1", 6);
    }

    function testERC20Fuzz(uint256 amount1, uint256 amount2, uint256 vsr, uint256 warpTime) public {
        amount1  = bound(amount1,  0,    1e36);
        amount2  = bound(amount2,  0,    1e36);
        vsr      = bound(vsr,      1e27, 1.000000012857214317438491659e27);  // 0 to 50% APY
        warpTime = bound(warpTime, 0,    10 days);

        vm.prank(vsrSetter);
        spPRIME.setVSR(vsr);

        skip(warpTime);

        checkBulkERC20Fuzz({
            _token        : address(spPRIME),
            _contractName : "SparkPrimeVault",
            from          : makeAddr("from"),
            to            : makeAddr("to"),
            amount1       : amount1,
            amount2       : amount2
        });
    }

    function testPermit() public {
        checkBulkPermit(address(spPRIME), "SparkPrimeVault");
    }

    function testPermitFuzz(
        uint256 amount,
        uint256 deadline,
        uint256 nonce,
        uint128 privateKey
    )
        public
    {
        amount     = bound(amount,   0,               1e36);
        deadline   = bound(deadline, block.timestamp, block.timestamp + 100 days);
        nonce      = bound(nonce,    0,               type(uint256).max);

        checkBulkPermitFuzz({
            _token        : address(spPRIME),
            _contractName : "SparkPrimeVault",
            privKey       : privateKey,
            to            : makeAddr("to"),
            amount        : amount,
            deadline      : deadline,
            nonce         : nonce
        });
    }

}
