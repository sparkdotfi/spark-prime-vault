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

    function nowChi() external view returns (uint256);

}

abstract contract TestBase is Test {

    struct PendingRequestsState {
        uint256 pendingShares;  // spUSDC shares (deposit queue) or spPrime shares (redeem queue)
        uint256 length;         // requests from firstPendingId to the end, cancelled included
        uint256 firstPendingId; // first unfilled request id
    }

    struct VaultState {
        uint256 rho;                   // last chi update timestamp
        uint256 chi;                   // rate accumulator [ray]
        uint256 totalSupply;           // spPrime shares total supply
        uint256 totalAssets;           // USDC value of supply
        uint256 availableCapacity;     // spPrime shares left to mint
        uint256 availableLiquidAssets; // USDC the vault can withdraw from spUSDC now (maxWithdraw)
        PendingRequestsState depositRequests;
        PendingRequestsState depositCancellationRequests;
        PendingRequestsState redeemRequests;
    }

    struct AccountBalances {
        address account;         // account being checked
        uint256 assets;          // USDC held
        uint256 shares;          // spPrime held
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

    SparkPrimeVault internal spPrime;

    VaultState internal vaultState;

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl, _getBlock());

        spPrime = SparkPrimeVault(
            address(new ERC1967Proxy(
                address(new SparkPrimeVault()),
                abi.encodeCall(
                    SparkPrimeVault.initialize,
                    (address(spUSDC), "Spark Prime USDC", "spPrime", admin)
                )
            ))
        );

        vm.startPrank(admin);

        spPrime.grantRole(GUARDIAN_ROLE,   guardian);
        spPrime.grantRole(REBALANCER_ROLE, rebalancer);
        spPrime.grantRole(VSR_SETTER_ROLE, vsrSetter);

        spPrime.setCapacity(VAULT_CAPACITY);
        spPrime.setMinDeposit(MINIMUM_DEPOSIT);
        spPrime.setMinRedeem(MINIMUM_REDEEM);
        spPrime.setVSRBounds(RAY, spPrime.MAX_VSR());

        vm.stopPrank();

        vm.prank(vsrSetter);
        spPrime.setVSR(FIVE_PCT_VSR);

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

        vm.label(address(spPrime), "spPrime");
        vm.label(address(spUSDC), "spUSDC");
        vm.label(address(usdc), "usdc");
        vm.label(address(admin), "admin");
        vm.label(address(guardian), "guardian");
        vm.label(address(rebalancer), "rebalancer");
        vm.label(address(redeemFeeSetter), "redeemFeeSetter");
        vm.label(address(taker), "taker");
        vm.label(address(vsrSetter), "vsrSetter");
    }

    function _getBlock() internal pure returns (uint256) {
        return 26148600;
    }

    /**********************************************************************************************/
    /*** Action Helpers                                                                         ***/
    /**********************************************************************************************/

    function _pause() internal {
        vm.prank(guardian);
        spPrime.pause();
    }

    function _setCapacity(uint256 capacity) internal {
        vm.prank(admin);
        spPrime.setCapacity(capacity);
    }

    function _processPendingDeposits(uint256 maxSavingsShares, uint256 maxRequests) internal {
        vm.prank(rebalancer);
        spPrime.processPendingDeposits(maxSavingsShares, maxRequests);
    }

    function _processPendingDeposits(uint256 maxRequests) internal {
        _processPendingDeposits(type(uint256).max, maxRequests);
    }

    function _requestDeposit(address account, address recipient, uint256 assets) internal returns (uint256 requestId) {
        deal(address(usdc), account, assets);

        vm.startPrank(account);
        usdc.approve(address(spPrime), assets);
        requestId = spPrime.requestDeposit(assets, recipient, 0);
        vm.stopPrank();
    }

    function _requestDeposit(address account, uint256 assets) internal returns (uint256 requestId) {
        return _requestDeposit(account, account, assets);
    }

    function _requestDepositCancellation(address account, uint256 requestId, address recipient) internal returns (uint256 newRequestId) {
        vm.prank(account);
        return spPrime.requestDepositCancellation(requestId, recipient);
    }

    function _requestDepositCancellation(address account, uint256 requestId) internal returns (uint256 newRequestId) {
        return _requestDepositCancellation(account, requestId, account);
    }

    /**********************************************************************************************/
    /*** Assertion helpers                                                                      ***/
    /**********************************************************************************************/

    function _assertVaultState() internal view {
        // General state variables

        assertEq(
            spPrime.rho(),
            vaultState.rho,
            "vaultState.rho"
        );

        assertEq(
            spPrime.chi(),
            vaultState.chi,
            "vaultState.chi"
        );

        assertEq(
            spPrime.totalSupply(),
            vaultState.totalSupply,
            "vaultState.totalSupply"
        );

        assertEq(
            spPrime.totalAssets(),
            vaultState.totalAssets,
            "vaultState.totalAssets"
        );

        assertEq(
            spPrime.availableCapacity(),
            vaultState.availableCapacity,
            "vaultState.availableCapacity"
        );

        assertEq(
            spPrime.availableLiquidAssets(),
            vaultState.availableLiquidAssets,
            "vaultState.availableLiquidAssets"
        );

        // Deposit Requests

        assertEq(
            spPrime.pendingDepositSavingsShares(),
            vaultState.depositRequests.pendingShares,
            "vaultState.depositRequests.pendingShares"
        );

        assertEq(
            spPrime.getPendingDepositRequests().
            length, vaultState.depositRequests.length,
            "length, vaultState.depositRequests.length"
        );

        assertEq(
            spPrime.firstPendingDepositId(),
            vaultState.depositRequests.firstPendingId,
            "vaultState.depositRequests.firstPendingId"
        );

        // Deposit Cancellation Requests

        assertEq(
            spPrime.pendingCancelledDepositSavingsShares(),
            vaultState.depositCancellationRequests.pendingShares,
            "vaultState.depositCancellationRequests.pendingShares"
        );

        assertEq(
            spPrime.getPendingDepositCancellationRequests().
            length, vaultState.depositCancellationRequests.length,
            "length, vaultState.depositCancellationRequests.length"
        );

        assertEq(
            spPrime.firstPendingDepositCancellationId(),
            vaultState.depositCancellationRequests.firstPendingId,
            "vaultState.depositCancellationRequests.firstPendingId"
        );

        // Redeem Requests

        assertEq(
            spPrime.pendingRedeemShares(),
            vaultState.redeemRequests.pendingShares,
            "vaultState.redeemRequests.pendingShares"
        );

        assertEq(
            spPrime.getPendingRedeemRequests().
            length, vaultState.redeemRequests.length,
            "length, vaultState.redeemRequests.length"
        );

        assertEq(
            spPrime.firstPendingRedeemId(),
            vaultState.redeemRequests.firstPendingId,
            "vaultState.redeemRequests.firstPendingId"
        );

    }

    function _assertAccountBalances(AccountBalances memory accountState) internal view {
        assertEq(
            usdc.balanceOf(accountState.account),
            accountState.assets,
            "accountState.assets"
        );

        assertEq(
            spPrime.balanceOf(accountState.account),
            accountState.shares,
            "accountState.shares"
        );

        assertEq(
            spUSDC.balanceOf(accountState.account),
            accountState.savingsShares,
            "accountState.savingsShares"
        );

        assertEq(
            spPrime.claimableAssets(accountState.account),
            accountState.claimableAssets,
            "accountState.claimableAssets"
        );

    }

    function _assertDepositRequest(
        uint256 requestId,
        address owner,
        address recipient,
        uint256 sparkVaultShares
    )
        internal view
    {
        ( address owner_, address recipient_, uint256 shares_ ) = spPrime.getPendingDepositRequest(requestId);

        assertEq(
            owner_,
            owner,
            "depositRequest.owner"
        );

        assertEq(
            recipient_,
            recipient,
            "depositRequest.recipient"
        );

        assertEq(
            shares_,
            sparkVaultShares,
            "depositRequest.sparkVaultShares"
        );

    }

}
