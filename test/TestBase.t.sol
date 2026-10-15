// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../lib/forge-std/src/Test.sol";

import { ERC1967Proxy } from "../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Ethereum } from "../lib/spark-address-registry/src/Ethereum.sol";

import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

interface IERC20Like {

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external;

    function balanceOf(address owner) external view returns (uint256);

}

interface ISparkVaultLike {

    function transfer(address to, uint256 amount) external returns (bool);

    function assetsOf(address owner) external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function nowChi() external view returns (uint256);

}

interface IUSDCLike {

    function blacklist(address account) external;

    function unblacklist(address account) external;

    function blacklister() external view returns (address);

}

abstract contract TestBase is Test {

    struct PendingRequestsState {
        uint256 pendingShareValue;  // USDC value of spUSDC shares (deposit queue) or spPrime shares (redeem queue)
        uint256 length;             // Requests from firstPendingId to the end, cancelled included
        uint256 firstPendingId;     // First unfilled request id
    }

    struct VaultState {
        uint256 rho;                     // Last chi update timestamp
        uint256 chi;                     // Rate accumulator [ray]
        uint256 totalAssets;             // USDC value of supply
        uint256 availableCapacityValue;  // USDC value of spPrime shares left to mint
        uint256 availableLiquidAssets;   // USDC the vault can withdraw from spUSDC now (maxWithdraw)
        PendingRequestsState depositRequests;
        PendingRequestsState depositCancellationRequests;
        PendingRequestsState redeemRequests;
    }

    struct AccountBalances {
        address account;            // Account being checked
        uint256 assets;             // USDC held
        uint256 shareValue;         // USDC value of spPrime held
        uint256 savingsShareValue;  // USDC value of spUSDC held
        uint256 claimableAssets;    // USDC claimable
    }

    uint256 internal constant MINIMUM_DEPOSIT = 100e6;
    uint256 internal constant MINIMUM_REDEEM  = 100e6;
    uint256 internal constant VAULT_CAPACITY  = 100_000_000e6;
    uint256 internal constant RAY             = 1e27;
    uint256 internal constant MAX_VSR         = 1.000000021979553151239153027e27;  // 100% APY

    uint256 internal constant ONE_PCT_VSR  = 1.000000000315522921573372069e27;
    uint256 internal constant FOUR_PCT_VSR = 1.000000001243680656318820312e27;
    uint256 internal constant FIVE_PCT_VSR = 1.000000001547125957863212448e27;

    address internal admin           = makeAddr("admin");
    address internal guardian        = makeAddr("guardian");
    address internal processor       = makeAddr("processor");
    address internal redeemFeeSetter = makeAddr("redeemFeeSetter");
    address internal taker           = makeAddr("taker");
    address internal vsrSetter       = makeAddr("vsrSetter");

    bytes32 internal DEFAULT_ADMIN_ROLE     = 0x00;
    bytes32 internal GUARDIAN_ROLE          = keccak256("GUARDIAN_ROLE");
    bytes32 internal PROCESSOR_ROLE         = keccak256("PROCESSOR_ROLE");
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

        spPrime.grantRole(GUARDIAN_ROLE,          guardian);
        spPrime.grantRole(PROCESSOR_ROLE,         processor);
        spPrime.grantRole(REDEEM_FEE_SETTER_ROLE, redeemFeeSetter);
        spPrime.grantRole(TAKER_ROLE,             taker);
        spPrime.grantRole(VSR_SETTER_ROLE,        vsrSetter);

        spPrime.setCapacity(VAULT_CAPACITY);
        spPrime.setMinDeposit(MINIMUM_DEPOSIT);
        spPrime.setMinRedeem(MINIMUM_REDEEM);
        spPrime.setVSRBounds(RAY, spPrime.MAX_VSR());

        vm.stopPrank();

        vm.prank(vsrSetter);
        spPrime.setVSR(FIVE_PCT_VSR);

        PendingRequestsState memory depositRequests = PendingRequestsState({
            pendingShareValue : 0,
            length            : 0,
            firstPendingId    : 0
        });

        PendingRequestsState memory depositCancellationRequests = PendingRequestsState({
            pendingShareValue : 0,
            length            : 0,
            firstPendingId    : 0
        });

        PendingRequestsState memory redeemRequests = PendingRequestsState({
            pendingShareValue : 0,
            length            : 0,
            firstPendingId    : 0
        });

        vaultState = VaultState({
            rho                         : vm.getBlockTimestamp(),
            chi                         : uint192(RAY),
            totalAssets                 : 0,
            availableCapacityValue      : spPrime.convertToAssets(VAULT_CAPACITY),
            availableLiquidAssets       : 0,
            depositRequests             : depositRequests,
            depositCancellationRequests : depositCancellationRequests,
            redeemRequests              : redeemRequests
        });

        vm.label(address(admin),           "admin");
        vm.label(address(guardian),        "guardian");
        vm.label(address(processor),       "processor");
        vm.label(address(redeemFeeSetter), "redeemFeeSetter");
        vm.label(address(spPrime),         "spPrime");
        vm.label(address(spUSDC),          "spUSDC");
        vm.label(address(taker),           "taker");
        vm.label(address(usdc),            "usdc");
        vm.label(address(vsrSetter),       "vsrSetter");
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

    function _unpause() internal {
        vm.prank(admin);
        spPrime.unpause();
    }

    function _setCapacity(uint256 capacity) internal {
        vm.prank(admin);
        spPrime.setCapacity(capacity);
    }

    function _processPendingDeposits(uint256 maxSavingsShares, uint256 maxRequests) internal {
        vm.prank(processor);
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

    function _requestRedeem(address account, address recipient, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(account);
        return spPrime.requestRedeem(shares, recipient);
    }

    function _requestRedeem(address account, uint256 shares) internal returns (uint256 requestId) {
        return _requestRedeem(account, account, shares);
    }

    function _processPendingRedeems(uint256 maxAssets, uint256 maxRequests) internal {
        vm.prank(processor);
        spPrime.processPendingRedeems(maxAssets, maxRequests);
    }

    function _processPendingRedeems() internal {
        vm.prank(processor);
        spPrime.processPendingRedeems(type(uint256).max, type(uint256).max);
    }

    function _blacklist(address account) internal {
        vm.prank(IUSDCLike(Ethereum.USDC).blacklister());
        IUSDCLike(Ethereum.USDC).blacklist(account);
    }

    function _unblacklist(address account) internal {
        vm.prank(IUSDCLike(Ethereum.USDC).blacklister());
        IUSDCLike(Ethereum.USDC).unblacklist(account);
    }

    /**********************************************************************************************/
    /*** Assertion helpers                                                                      ***/
    /**********************************************************************************************/

    function _assertVaultState(uint256 tolerance) internal view {
        // General state variables

        assertEq(
            spPrime.rho(),
            vaultState.rho,
            "vaultState.rho"
        );

        assertApproxEqAbs(
            spPrime.chi(),
            vaultState.chi,
            tolerance,
            "vaultState.chi"
        );

        assertApproxEqAbs(
            spPrime.totalAssets(),
            vaultState.totalAssets,
            tolerance,
            "vaultState.totalAssets"
        );

        assertApproxEqAbs(
            spPrime.convertToAssets(spPrime.availableCapacity()),
            vaultState.availableCapacityValue,
            tolerance,
            "vaultState.availableCapacityValue"
        );

        assertApproxEqAbs(
            spPrime.availableLiquidAssets(),
            vaultState.availableLiquidAssets,
            tolerance,
            "vaultState.availableLiquidAssets"
        );

        // Deposit Requests

        assertApproxEqAbs(
            spUSDC.convertToAssets(spPrime.pendingDepositSavingsShares()),
            vaultState.depositRequests.pendingShareValue,
            tolerance,
            "vaultState.depositRequests.pendingShareValue"
        );

        assertEq(
            spPrime.getPendingDepositRequests().length,
            vaultState.depositRequests.length,
            "vaultState.depositRequests.length"
        );

        assertEq(
            spPrime.firstPendingDepositId(),
            vaultState.depositRequests.firstPendingId,
            "vaultState.depositRequests.firstPendingId"
        );

        // Deposit Cancellation Requests

        assertApproxEqAbs(
            spUSDC.convertToAssets(spPrime.pendingCancelledDepositSavingsShares()),
            vaultState.depositCancellationRequests.pendingShareValue,
            tolerance,
            "vaultState.depositCancellationRequests.pendingShareValue"
        );

        assertEq(
            spPrime.getPendingDepositCancellationRequests().length,
            vaultState.depositCancellationRequests.length,
            "vaultState.depositCancellationRequests.length"
        );

        assertEq(
            spPrime.firstPendingDepositCancellationId(),
            vaultState.depositCancellationRequests.firstPendingId,
            "vaultState.depositCancellationRequests.firstPendingId"
        );

        // Redeem Requests

        assertApproxEqAbs(
            spUSDC.convertToAssets(spPrime.pendingRedeemShares()),
            vaultState.redeemRequests.pendingShareValue,
            tolerance,
            "vaultState.redeemRequests.pendingShareValue"
        );

        assertEq(
            spPrime.getPendingRedeemRequests().length,
            vaultState.redeemRequests.length,
            "vaultState.redeemRequests.length"
        );

        assertEq(
            spPrime.firstPendingRedeemId(),
            vaultState.redeemRequests.firstPendingId,
            "vaultState.redeemRequests.firstPendingId"
        );

    }

    function _assertVaultState() internal view {
        _assertVaultState(0);
    }

    function _assertAccountBalances(AccountBalances memory accountState, uint256 tolerance) internal view {
        assertApproxEqAbs(
            usdc.balanceOf(accountState.account),
            accountState.assets,
            tolerance,
            "accountState.assets"
        );

        assertApproxEqAbs(
            spPrime.assetsOf(accountState.account),
            accountState.shareValue,
            tolerance,
            "accountState.shareValue"
        );

        assertApproxEqAbs(
            spUSDC.assetsOf(accountState.account),
            accountState.savingsShareValue,
            tolerance,
            "accountState.savingsShareValue"
        );

        assertApproxEqAbs(
            spPrime.claimableAssets(accountState.account),
            accountState.claimableAssets,
            tolerance,
            "accountState.claimableAssets"
        );
    }

    function _assertAccountBalances(AccountBalances memory accountState) internal view {
        _assertAccountBalances(accountState, 0);
    }

    function _assertDepositRequest(
        uint256 requestId,
        address owner,
        address recipient,
        uint256 savingsShareValue
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
            spUSDC.convertToAssets(shares_),
            savingsShareValue,
            "depositRequest.savingsShareValue"
        );

    }

}
