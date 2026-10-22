// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { ERC1967Proxy } from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Ethereum } from "../../lib/spark-address-registry/src/Ethereum.sol";

import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../src/SparkPrimeVault.sol";

interface IERC20Like {

    function balanceOf(address user) external view returns (uint256);

}

interface ISparkVaultLike {

    function balanceOf(address user) external view returns (uint256);

}

/// @dev Mainnet-fork base for the review PoCs (`Review.t.sol`). Compiled only in this
///      environment (no RPC). `master` @ c512609: seven roles, three non-zero minimums at
///      initialize, `(startId, length)` range getters.
contract TestBase is Test {

    address internal admin           = makeAddr("admin");
    address internal lossManager     = makeAddr("lossManager");
    address internal operator        = makeAddr("operator");
    address internal pauser          = makeAddr("pauser");
    address internal redeemFeeSetter = makeAddr("redeemFeeSetter");
    address internal taker           = makeAddr("taker");
    address internal unpauser        = makeAddr("unpauser");

    bytes32 internal DEFAULT_ADMIN_ROLE     = 0x00;
    bytes32 internal LOSS_MANAGER_ROLE      = keccak256("LOSS_MANAGER_ROLE");
    bytes32 internal OPERATOR_ROLE          = keccak256("OPERATOR_ROLE");
    bytes32 internal PAUSER_ROLE            = keccak256("PAUSER_ROLE");
    bytes32 internal REDEEM_FEE_SETTER_ROLE = keccak256("REDEEM_FEE_SETTER_ROLE");
    bytes32 internal TAKER_ROLE             = keccak256("TAKER_ROLE");
    bytes32 internal UNPAUSER_ROLE          = keccak256("UNPAUSER_ROLE");

    // Launch-like minimums for the fork PoCs.
    uint256 internal constant MIN_DEPOSIT              = 1e6;
    uint256 internal constant MIN_DEPOSIT_CANCELLATION = 1e6;
    uint256 internal constant MIN_REDEEM               = 1e6;

    IERC20Like      internal usdc   = IERC20Like(Ethereum.USDC);
    ISparkVaultLike internal spUsdc = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDC);

    SparkPrimeVault internal vault;

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl, 26148600);

        vault = SparkPrimeVault(
            address(new ERC1967Proxy(
                address(new SparkPrimeVault()),
                abi.encodeCall(
                    ISparkPrimeVault.initialize,
                    (
                        address(spUsdc),
                        "Spark Prime USDC",
                        "spPRIME",
                        admin,
                        MIN_DEPOSIT,
                        MIN_DEPOSIT_CANCELLATION,
                        MIN_REDEEM
                    )
                )
            ))
        );
    }

    /// @dev Raw reads of any id, including ids below the head, through the range getters: they
    ///      only reject ids below the head, so these helpers are for ids in `[head, length)`.
    function _depositRequest(uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        ISparkPrimeVault.Request[] memory r = vault.getPendingDepositRequests(id, 1);
        return (r[0].owner, r[0].recipient, r[0].shares);
    }

    function _redeemRequest(uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        ISparkPrimeVault.Request[] memory r = vault.getPendingRedeemRequests(id, 1);
        return (r[0].owner, r[0].recipient, r[0].shares);
    }

    function _cancelledDepositRequest(uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        ISparkPrimeVault.Request[] memory r = vault.getPendingDepositCancellationRequests(id, 1);
        return (r[0].owner, r[0].recipient, r[0].shares);
    }

    function _depositQueueLength() internal view returns (uint256) {
        return vault.firstPendingDepositId() + vault.getPendingDepositRequests().length;
    }

    function _redeemQueueLength() internal view returns (uint256) {
        return vault.firstPendingRedeemId() + vault.getPendingRedeemRequests().length;
    }

    function _cancelledDepositQueueLength() internal view returns (uint256) {
        return vault.firstPendingDepositCancellationId()
            + vault.getPendingDepositCancellationRequests().length;
    }

}
