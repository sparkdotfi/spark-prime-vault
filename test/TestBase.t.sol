// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../lib/forge-std/src/Test.sol";

import { ERC1967Proxy } from "../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Ethereum } from "../lib/spark-address-registry/src/Ethereum.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../src/SparkPrimeVault.sol";

interface IERC20Like {

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external;

    function balanceOf(address owner) external view returns (uint256);

}

interface ISparkVaultLike {

    function redeem(uint256 shares, address to, address from) external returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function withdraw(uint256 assets, address to, address from) external returns (uint256);

    function assetsOf(address owner) external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function nowChi() external view returns (uint256);

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
        uint256 totalClaimable;          // USDC value of all claimable assets
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

    uint256 internal constant MINIMUM_DEPOSIT              = 100e6;
    uint256 internal constant MINIMUM_DEPOSIT_CANCELLATION = 100e6;
    uint256 internal constant MINIMUM_REDEEM               = 100e6;
    uint256 internal constant VAULT_CAPACITY               = 100_000_000e6;
    uint256 internal constant RAY                          = 1e27;
    uint256 internal constant MAX_VSR                      = 1.000000021979553151239153027e27;  // 100% APY

    uint256 internal constant ONE_PCT_VSR  = 1.000000000315522921573372069e27;
    uint256 internal constant FOUR_PCT_VSR = 1.000000001243680656318820312e27;
    uint256 internal constant FIVE_PCT_VSR = 1.000000001547125957863212448e27;

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
                    ISparkPrimeVault.initialize,
                    (
                        address(spUSDC),
                        "Spark Prime USDC",
                        "spPrime",
                        admin,
                        MINIMUM_DEPOSIT,
                        MINIMUM_DEPOSIT_CANCELLATION,
                        MINIMUM_REDEEM
                    )
                )
            ))
        );

        vm.startPrank(admin);

        spPrime.grantRole(LOSS_MANAGER_ROLE,      lossManager);
        spPrime.grantRole(OPERATOR_ROLE,          operator);
        spPrime.grantRole(PAUSER_ROLE,            pauser);
        spPrime.grantRole(REDEEM_FEE_SETTER_ROLE, redeemFeeSetter);
        spPrime.grantRole(TAKER_ROLE,             taker);
        spPrime.grantRole(UNPAUSER_ROLE,          unpauser);

        spPrime.setVSRBounds(RAY, spPrime.MAX_VSR());

        vm.stopPrank();

        vm.startPrank(operator);
        spPrime.setCapacity(VAULT_CAPACITY);
        spPrime.setVSR(FIVE_PCT_VSR);
        vm.stopPrank();

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
            totalClaimable              : 0,
            availableCapacityValue      : spPrime.convertToAssets(VAULT_CAPACITY),
            availableLiquidAssets       : 0,
            depositRequests             : depositRequests,
            depositCancellationRequests : depositCancellationRequests,
            redeemRequests              : redeemRequests
        });

        vm.label(address(admin),           "admin");
        vm.label(address(lossManager),     "lossManager");
        vm.label(address(operator),        "operator");
        vm.label(address(redeemFeeSetter), "redeemFeeSetter");
        vm.label(address(spPrime),         "spPrime");
        vm.label(address(spUSDC),          "spUSDC");
        vm.label(address(taker),           "taker");
        vm.label(address(unpauser),        "unpauser");
        vm.label(address(usdc),            "usdc");
    }

    function _getBlock() internal pure returns (uint256) {
        return 26148600;
    }

    /**********************************************************************************************/
    /*** Action Helpers                                                                         ***/
    /**********************************************************************************************/

    function _pause() internal {
        vm.prank(pauser);
        spPrime.pause();
    }

    function _unpause() internal {
        vm.prank(unpauser);
        spPrime.unpause();
    }

    function _setCapacity(uint256 capacity) internal {
        vm.prank(operator);
        spPrime.setCapacity(capacity);
    }

    function _setMaxRedeemFeeRate(uint256 maxRedeemFeeRate) internal {
        vm.prank(admin);
        spPrime.setMaxRedeemFeeRate(maxRedeemFeeRate);
    }

    function _setRedeemFeeRate(uint256 feeRate) internal {
        vm.prank(redeemFeeSetter);
        spPrime.setRedeemFeeRate(feeRate);
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

    function _requestDepositCancellation(address account, uint256 requestId, address recipient, uint256 savingShares)
        internal
        returns (uint256 newRequestId)
    {
        vm.prank(account);
        return spPrime.requestDepositCancellation(requestId, recipient, savingShares);
    }

    function _requestDepositCancellation(address account, uint256 requestId, uint256 savingShares) internal returns (uint256 newRequestId) {
        return _requestDepositCancellation(account, requestId, account, savingShares);
    }

    function _requestRedeem(address account, address recipient, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(account);
        return spPrime.requestRedeem(shares, recipient);
    }

    function _requestRedeem(address account, uint256 shares) internal returns (uint256 requestId) {
        return _requestRedeem(account, account, shares);
    }

    function _processPendingDeposits(uint256 maxSavingsShares, uint256 maxRequests) internal {
        vm.prank(operator);
        spPrime.processPendingDeposits(maxSavingsShares, maxRequests);
    }

    function _processPendingDeposits(uint256 maxRequests) internal {
        _processPendingDeposits(type(uint256).max, maxRequests);
    }

    function _processPendingDeposits() internal {
        _processPendingDeposits(type(uint256).max, type(uint256).max);
    }

    function _processPendingDepositCancellations(uint256 maxSavingsShares, uint256 maxRequests) internal {
        vm.prank(operator);
        spPrime.processPendingDepositCancellations(maxSavingsShares, maxRequests);
    }

    function _processPendingDepositCancellations(uint256 maxRequests) internal {
        _processPendingDepositCancellations(type(uint256).max, maxRequests);
    }

    function _processPendingRedeems(uint256 maxShares, uint256 maxRequests) internal {
        vm.prank(operator);
        spPrime.processPendingRedeems(maxShares, maxRequests);
    }

    function _processPendingRedeems(uint256 maxRequests) internal {
        _processPendingRedeems(type(uint256).max, maxRequests);
    }

    function _processPendingRedeems() internal {
        _processPendingRedeems(type(uint256).max, type(uint256).max);
    }

    function _take(uint256 savingsShares) internal {
        vm.prank(taker);
        spPrime.take(savingsShares);
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
            spPrime.totalClaimable(),
            vaultState.totalClaimable,
            tolerance,
            "vaultState.totalClaimable"
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
            spPrime.pendingDepositRequests().length,
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
            spPrime.pendingDepositCancellationRequests().length,
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
            spPrime.convertToAssets(spPrime.pendingRedeemShares()),
            vaultState.redeemRequests.pendingShareValue,
            tolerance,
            "vaultState.redeemRequests.pendingShareValue"
        );

        assertEq(
            spPrime.pendingRedeemRequests().length,
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
        ( address owner_, address recipient_, uint256 shares_ ) =
            spPrime.getPendingDepositRequest(requestId);

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

    function _assertDepositRequest(
        ISparkPrimeVault.Request memory request,
        address                         owner,
        address                         recipient,
        uint256                         savingsShareValue
    )
        internal view
    {
        assertEq(
            request.owner,
            owner,
            "depositRequest.owner"
        );

        assertEq(
            request.recipient,
            recipient,
            "depositRequest.recipient"
        );

        assertEq(
            spUSDC.convertToAssets(request.shares),
            savingsShareValue,
            "depositRequest.savingsShareValue"
        );
    }

    function _assertDepositCancellationRequest(
        uint256 requestId,
        address owner,
        address recipient,
        uint256 savingsShareValue
    )
        internal view
    {
        ( address owner_, address recipient_, uint256 shares_ ) =
            spPrime.getPendingDepositCancellationRequest(requestId);

        assertEq(
            owner_,
            owner,
            "depositCancellationRequest.owner"
        );

        assertEq(
            recipient_,
            recipient,
            "depositCancellationRequest.recipient"
        );

        assertEq(
            spUSDC.convertToAssets(shares_),
            savingsShareValue,
            "depositCancellationRequest.savingsShareValue"
        );
    }

    function _assertDepositCancellationRequest(
        ISparkPrimeVault.Request memory request,
        address                         owner,
        address                         recipient,
        uint256                         savingsShareValue
    )
        internal view
    {
        assertEq(
            request.owner,
            owner,
            "depositCancellationRequest.owner"
        );

        assertEq(
            request.recipient,
            recipient,
            "depositCancellationRequest.recipient"
        );

        assertEq(
            spUSDC.convertToAssets(request.shares),
            savingsShareValue,
            "depositCancellationRequest.savingsShareValue"
        );
    }

    function _assertRedeemRequest(
        uint256 requestId,
        address owner,
        address recipient,
        uint256 shareValue
    )
        internal view
    {
        ( address owner_, address recipient_, uint256 shares_ ) =
            spPrime.getPendingRedeemRequest(requestId);

        assertEq(
            owner_,
            owner,
            "redeemRequest.owner"
        );

        assertEq(
            recipient_,
            recipient,
            "redeemRequest.recipient"
        );

        assertEq(
            spPrime.convertToAssets(shares_),
            shareValue,
            "redeemRequest.shareValue"
        );
    }

    function _assertRedeemRequest(
        ISparkPrimeVault.Request memory request,
        address                         owner,
        address                         recipient,
        uint256                         shareValue
    )
        internal view
    {
        assertEq(
            request.owner,
            owner,
            "redeemRequest.owner"
        );

        assertEq(
            request.recipient,
            recipient,
            "redeemRequest.recipient"
        );

        assertEq(
            spPrime.convertToAssets(request.shares),
            shareValue,
            "redeemRequest.shareValue"
        );
    }

    function _assertEmptyRequest(ISparkPrimeVault.Request memory request) internal view {
        assertEq(
            request.owner,
            address(0),
            "request.owner not zero"
        );

        assertEq(
            request.recipient,
            address(0),
            "request.recipient not zero"
        );

        assertEq(
            request.shares,
            0,
            "request.shares not zero"
        );
    }

}
