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

    function convertToAssets(uint256 shares) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

}

abstract contract TestBase is Test {

    struct PendingRequestsState {
        uint256 pendingShares;  // spUSDC shares (deposit queue) or spPRIME shares (redeem queue)
        uint256 length;         // requests from firstPendingId to the end, cancelled included
        uint256 firstPendingId; // first unfilled request id
    }

    struct VaultState {
        uint256 rho;                   // last chi update timestamp
        uint256 chi;                   // rate accumulator [ray]
        uint256 totalSupply;           // spPRIME shares total supply
        uint256 totalAssets;           // USDC value of supply
        uint256 availableCapacity;     // spPRIME shares left to mint
        uint256 availableLiquidAssets; // USDC the vault can withdraw from spUSDC now (maxWithdraw)
        PendingRequestsState depositRequests;
        PendingRequestsState depositCancellationRequests;
        PendingRequestsState redeemRequests;
    }

    struct AccountBalances {
        address account;         // account being checked
        uint256 asset;           // USDC held
        uint256 shares;          // spPRIME held
        uint256 savingsShares;   // spUSDC held
        uint256 claimableAssets; // USDC claimable
    }

    uint256 internal constant MINIMUM_DEPOSIT = 100e6;
    uint256 internal constant MINIMUM_REDEEM  = 100e6;
    uint256 internal constant VAULT_CAPACITY  = 100_000_000e6;
    uint256 internal constant RAY             = 1e27;
    uint256 internal constant FIVE_PCT_VSR    = 1.000000001547125957863212448e27;
    uint256 internal constant MAX_VSR         = 1.000000021979553151239153027e27;  // 100% APY

    address internal admin           = makeAddr("admin");
    address internal guardian        = makeAddr("guardian");
    address internal rebalancer      = makeAddr("rebalancer");
    address internal redeemFeeSetter = makeAddr("redeemFeeSetter");
    address internal taker           = makeAddr("taker");
    address internal vsrSetter       = makeAddr("vsrSetter");

    bytes32 internal DEFAULT_ADMIN_ROLE     = 0x00;
    bytes32 internal GUARDIAN_ROLE          = keccak256("GUARDIAN_ROLE");
    bytes32 internal REBALANCER_ROLE        = keccak256("REBALANCER_ROLE");
    bytes32 internal REDEEM_FEE_SETTER_ROLE = keccak256("REDEEM_FEE_SETTER_ROLE");
    bytes32 internal TAKER_ROLE             = keccak256("TAKER_ROLE");
    bytes32 internal VSR_SETTER_ROLE        = keccak256("VSR_SETTER_ROLE");

    IERC20Like      internal usdc   = IERC20Like(Ethereum.USDC);
    ISparkVaultLike internal spUSDC = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDC);

    SparkPrimeVault internal spPRIME;

    VaultState internal vaultState;

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl, _getBlock());

        spPRIME = SparkPrimeVault(
            address(new ERC1967Proxy(
                address(new SparkPrimeVault()),
                abi.encodeCall(
                    SparkPrimeVault.initialize,
                    (address(spUSDC), "Spark Prime USDC", "spPRIME", admin)
                )
            ))
        );

        vm.startPrank(admin);

        spPRIME.grantRole(GUARDIAN_ROLE,   guardian);
        spPRIME.grantRole(REBALANCER_ROLE, rebalancer);
        spPRIME.grantRole(VSR_SETTER_ROLE, vsrSetter);

        spPRIME.setCapacity(VAULT_CAPACITY);
        spPRIME.setMinDeposit(MINIMUM_DEPOSIT);
        spPRIME.setMinRedeem(MINIMUM_REDEEM);
        spPRIME.setVSRBounds(RAY, spPRIME.MAX_VSR());

        vm.stopPrank();

        vm.prank(vsrSetter);
        spPRIME.setVSR(FIVE_PCT_VSR);

        PendingRequestsState memory depositRequests = PendingRequestsState({
            pendingShares  : 0,
            length         : 0,
            firstPendingId : 0
        });

        PendingRequestsState memory depositCancellationRequests = PendingRequestsState({
            pendingShares  : 0,
            length         : 0,
            firstPendingId : 0
        });

        PendingRequestsState memory redeemRequests = PendingRequestsState({
            pendingShares  : 0,
            length         : 0,
            firstPendingId : 0
        });

        vaultState = VaultState({
            rho                         : vm.getBlockTimestamp(),
            chi                         : uint192(RAY),
            totalSupply                 : 0,
            totalAssets                 : 0,
            availableCapacity           : VAULT_CAPACITY,
            availableLiquidAssets       : 0,
            depositRequests             : depositRequests,
            depositCancellationRequests : depositCancellationRequests,
            redeemRequests              : redeemRequests
        });
    }

    function _getBlock() internal pure returns (uint256) {
        return 26148600;
    }

    /**********************************************************************************************/
    /*** Action Helpers                                                                         ***/
    /**********************************************************************************************/

    function _pause() internal {
        vm.prank(guardian);
        spPRIME.pause();
    }

    function _setCapacity(uint256 capacity) internal {
        vm.prank(admin);
        spPRIME.setCapacity(capacity);
    }

    function _processPendingDeposits(uint256 maxSavingsShares, uint256 maxRequests) internal {
        vm.prank(rebalancer);
        spPRIME.processPendingDeposits(maxSavingsShares, maxRequests);
    }

    function _processPendingDeposits(uint256 maxRequests) internal {
        _processPendingDeposits(type(uint256).max, maxRequests);
    }

    function _requestDeposit(address account, address recipient, uint256 assets) internal {
        deal(address(usdc), account, assets);

        vm.startPrank(account);
        usdc.approve(address(spPRIME), assets);
        spPRIME.requestDeposit(assets, recipient);
        vm.stopPrank();
    }

    function _requestDeposit(address account, uint256 assets) internal {
        _requestDeposit(account, account, assets);
    }

    function _requestDepositCancellation(address account, uint256 requestId, address recipient) internal {
        vm.prank(account);
        spPRIME.requestDepositCancellation(requestId, recipient);
    }

    function _requestDepositCancellation(address account, uint256 requestId) internal {
        vm.prank(account);
        spPRIME.requestDepositCancellation(requestId, account);
    }

    /**********************************************************************************************/
    /*** Assertion helpers                                                                      ***/
    /**********************************************************************************************/

    function _assertVaultState() internal view {
        assertEq(
            spPRIME.rho(),
            vaultState.rho,
            "vaultState.rho"
        );

        assertEq(
            spPRIME.chi(),
            vaultState.chi,
            "vaultState.chi"
        );

        assertEq(
            spPRIME.totalSupply(),
            vaultState.totalSupply,
            "vaultState.totalSupply"
        );

        assertEq(
            spPRIME.totalAssets(),
            vaultState.totalAssets,
            "vaultState.totalAssets"
        );

        assertEq(
            spPRIME.availableCapacity(),
            vaultState.availableCapacity,
            "vaultState.availableCapacity"
        );

        assertEq(
            spPRIME.availableLiquidAssets(),
            vaultState.availableLiquidAssets,
            "vaultState.availableLiquidAssets"
        );


        assertEq(
            spPRIME.pendingDepositSavingsShares(),
            vaultState.depositRequests.pendingShares,
            "vaultState.depositRequests.pendingShares"
        );

        assertEq(
            spPRIME.getPendingDepositRequests().
            length, vaultState.depositRequests.length,
            "length, vaultState.depositRequests.length"
        );

        assertEq(
            spPRIME.firstPendingDepositId(),
            vaultState.depositRequests.firstPendingId,
            "vaultState.depositRequests.firstPendingId"
        );


        assertEq(
            spPRIME.pendingCancelledDepositSavingsShares(),
            vaultState.depositCancellationRequests.pendingShares,
            "vaultState.depositCancellationRequests.pendingShares"
        );

        assertEq(
            spPRIME.getPendingDepositCancellationRequests().
            length, vaultState.depositCancellationRequests.length,
            "length, vaultState.depositCancellationRequests.length"
        );

        assertEq(
            spPRIME.firstPendingDepositCancellationId(),
            vaultState.depositCancellationRequests.firstPendingId,
            "vaultState.depositCancellationRequests.firstPendingId"
        );


        assertEq(
            spPRIME.pendingRedeemShares(),
            vaultState.redeemRequests.pendingShares,
            "vaultState.redeemRequests.pendingShares"
        );

        assertEq(
            spPRIME.getPendingRedeemRequests().
            length, vaultState.redeemRequests.length,
            "length, vaultState.redeemRequests.length"
        );

        assertEq(
            spPRIME.firstPendingRedeemId(),
            vaultState.redeemRequests.firstPendingId,
            "vaultState.redeemRequests.firstPendingId"
        );

    }

    function _assertAccountBalances(AccountBalances memory state) internal view {
        assertEq(usdc.balanceOf(state.account),          state.asset);
        assertEq(spPRIME.balanceOf(state.account),       state.shares);
        assertEq(spUSDC.balanceOf(state.account),        state.savingsShares);
        assertEq(spPRIME.claimableAssets(state.account), state.claimableAssets);
    }

    function _assertDepositRequest(
        uint256 requestId,
        address owner,
        address recipient,
        uint256 sparkVaultShares
    )
        internal view
    {
        ( address owner_, address recipient_, uint256 shares_ ) = spPRIME.getPendingDepositRequest(requestId);

        assertEq(owner_,     owner);
        assertEq(recipient_, recipient);
        assertEq(shares_,    sparkVaultShares);
    }

}
