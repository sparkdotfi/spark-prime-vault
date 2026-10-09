// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../lib/forge-std/src/Test.sol";

import { ERC1967Proxy } from "../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Ethereum } from "../lib/spark-address-registry/src/Ethereum.sol";

import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

interface IERC20Like {

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external;

    function balanceOf(address user) external view returns (uint256);

}

interface ISparkVaultLike {

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    function balanceOf(address user) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

}

abstract contract TestBase is Test {

    struct AssertVaultStateParams {
        uint256 totalSupply;                  // spPRIME shares total supply
        uint256 totalAssets;                  // USDC value of supply
        uint256 availableCapacity;            // spPRIME shares left to mint
        uint256 availableLiquidAssets;        // idle USDC + redeemable unencumbered spUSDC
        uint256 unencumberedSparkVaultShares; // spUSDC not backing queued deposits
        uint256 chi;                          // rate accumulator [ray]
        uint256 rho;                          // last chi update timestamp
    }

    struct AssertQueueStateParams {
        uint256 encumberedShares; // spUSDC shares (deposit queue) or spPRIME shares (redeem queue)
        // uint256 length;           // entries ever pushed, filled and cancelled included
        uint256 head;             // first unfilled index
    }

    struct AssertBalancesParams {
        address account;       // account being checked
        uint256 asset;         // USDC held
        uint256 shares;        // spPRIME held
        uint256 savingsShares; // spUSDC held
    }

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant GUARDIAN_ROLE      = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant REBALANCER_ROLE    = keccak256("REBALANCER_ROLE");
    bytes32 internal constant RISK_MANAGER_ROLE  = keccak256("RISK_MANAGER_ROLE");
    bytes32 internal constant SETTER_ROLE        = keccak256("SETTER_ROLE");
    bytes32 internal constant TAKER_ROLE         = keccak256("TAKER_ROLE");
    bytes32 internal constant UNPAUSER_ROLE      = keccak256("UNPAUSER_ROLE");

    uint256 internal constant MINIMUM_DEPOSIT  = 100e6;
    uint256 internal constant MINIMUM_WITHDRAW = 100e6;
    uint256 internal constant VAULT_CAPACITY   = 100_000_000e6;
    uint256 internal constant RAY              = 1e27;

    address internal admin       = makeAddr("admin");
    address internal guardian    = makeAddr("guardian");
    address internal rebalancer  = makeAddr("rebalancer");
    address internal riskManager = makeAddr("riskManager");
    address internal setter      = makeAddr("setter");
    address internal taker       = makeAddr("taker");
    address internal unpauser    = makeAddr("unpauser");

    address internal user = makeAddr("user");

    IERC20Like      internal usdc   = IERC20Like(Ethereum.USDC);
    ISparkVaultLike internal spUSDC = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDC);

    SparkPrimeVault internal spPRIME;

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl, _getBlock());

        spPRIME = SparkPrimeVault(
            address(new ERC1967Proxy(
                address(new SparkPrimeVault()),
                abi.encodeCall(
                    SparkPrimeVault.initialize,
                    (address(usdc), address(spUSDC), "Spark Prime USDC", "spPRIME", admin)
                )
            ))
        );
    }

    function _getBlock() internal pure returns (uint256) {
        return 26148600;
    }

    /**********************************************************************************************/
    /*** Assertion helpers                                                                      ***/
    /**********************************************************************************************/

    function _assertVaultState(AssertVaultStateParams memory state) internal view {
        assertEq(spPRIME.totalSupply(),                  state.totalSupply);
        assertEq(spPRIME.totalAssets(),                  state.totalAssets);
        assertEq(spPRIME.availableCapacity(),            state.availableCapacity);
        assertEq(spPRIME.availableLiquidAssets(),        state.availableLiquidAssets);
        assertEq(spPRIME.unencumberedSparkVaultShares(), state.unencumberedSparkVaultShares);
        assertEq(spPRIME.chi(),                          state.chi);
        assertEq(spPRIME.rho(),                          state.rho);
    }

    function _assertDepositQueueState(AssertQueueStateParams memory state) internal view {
        assertEq(spPRIME.sparkVaultSharesEncumberedByDeposits(), state.encumberedShares);
        // assertEq(spPRIME.depositQueueLength(),                   state.length); // TODO: implement
        assertEq(spPRIME.depositHead(),                          state.head);
    }

    function _assertBalances(AssertBalancesParams memory params) internal view {
        assertEq(usdc.balanceOf(params.account),    params.asset);
        assertEq(spPRIME.balanceOf(params.account), params.shares);
        assertEq(spUSDC.balanceOf(params.account),  params.savingsShares);
    }

    function _assertDepositRequest(
        uint256 requestId,
        address owner,
        address recipient,
        uint256 sparkVaultShares
    )
        internal view
    {
        ( address owner_, address recipient_, uint256 shares_ ) = spPRIME.depositQueue(requestId);

        assertEq(owner_,     owner);
        assertEq(recipient_, recipient);
        assertEq(shares_,    sparkVaultShares);
    }

}
