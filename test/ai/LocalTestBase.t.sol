// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { ERC1967Proxy }       from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 }              from "../../lib/oz/contracts/token/ERC20/ERC20.sol";

import { SparkVault }      from "./lib/spusdc/SparkVault.sol";
import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../src/SparkPrimeVault.sol";

// 6-decimal mock USDC with public mint/burn and a Circle-style blacklist: `transfer`,
// `transferFrom` and `approve` revert with the mainnet FiatToken message when the sender, the
// receiver or the spender is blacklisted, and `isBlacklisted` is what the vault consults.
contract MockUSDC is ERC20 {

    string internal constant BLACKLISTED = "Blacklistable: account is blacklisted";

    mapping(address => bool) public isBlacklisted;

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) { return 6; }

    function mint(address to, uint256 amt) external { _mint(to, amt); }

    function burn(address from, uint256 amt) external { _burn(from, amt); }

    function setBlacklisted(address who, bool state) external { isBlacklisted[who] = state; }

    function transfer(address to, uint256 amt) public override returns (bool) {
        require(!isBlacklisted[msg.sender] && !isBlacklisted[to], BLACKLISTED);
        return super.transfer(to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) public override returns (bool) {
        require(
            !isBlacklisted[msg.sender] && !isBlacklisted[from] && !isBlacklisted[to],
            BLACKLISTED
        );
        return super.transferFrom(from, to, amt);
    }

    function approve(address spender, uint256 amt) public override returns (bool) {
        require(!isBlacklisted[msg.sender] && !isBlacklisted[spender], BLACKLISTED);
        return super.approve(spender, amt);
    }

}

/// @dev Local (non-fork) harness: real spUSDC `SparkVault` code deployed behind a proxy over a
///      6-decimal mock USDC, and the `SparkPrimeVault` under test on top of it. No RPC needed.
///      Both indexes start "ugly" (spUSDC chi ~1.0476e27, spPRIME chi ~1.0098e27) with VSR frozen
///      at RAY; tests that want accrual set a rate explicitly. Minimums are 1 wei. `src/` is upstream
///      `master` @ c512609, unpatched.
///
///      Actors
///        spUSDC side : spAdmin (DEFAULT_ADMIN + sets cap/bounds), spSetter (VSR), spTaker (USDC out)
///        spPRIME side: admin, lossManager, operator, pauser, unpauser, redeemFeeSetter, taker
///
///      Helpers at the bottom cover the operations every test file needs: funding, deposits,
///      redeems, draining spUSDC's USDC liquidity, taking spUSDC out of the prime vault and
///      returning it, warping time with drips.
contract LocalTestBase is Test {

    uint256 constant RAY = 1e27;
    uint256 constant WAD = 1e18;

    uint256 constant ONE_PCT_VSR   = 1.000000000315522921573372069e27;
    uint256 constant FOUR_PCT_VSR  = 1.000000001243680656318820312e27;
    uint256 constant FIVE_PCT_VSR  = 1.000000001547125957863212448e27;
    uint256 constant TEN_PCT_VSR   = 1.000000003022265980097387650e27;
    uint256 constant FORTY_PCT_VSR = 1.000000010669464688489416886e27;
    uint256 constant MAX_VSR       = 1.000000021979553151239153027e27;  // 100% APY

    // "Ugly" rates used by setUp to make both indexes non-trivial.
    uint256 constant UGLY_SP_VSR    = 1.000000001356138789912371417e27;  // ~4.37% APY
    uint256 constant UGLY_PRIME_VSR = 1.000000000906634632573938893e27;  // ~2.90% APY

    // spUSDC actors
    address internal spAdmin  = makeAddr("spAdmin");
    address internal spSetter = makeAddr("spSetter");
    address internal spTaker  = makeAddr("spTaker");

    // spPRIME actors
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

    // Harness minimums: the contract rejects zero, 1 wei keeps every amount reachable.
    uint256 internal constant MIN_DEPOSIT              = 1;
    uint256 internal constant MIN_DEPOSIT_CANCELLATION = 1;
    uint256 internal constant MIN_REDEEM               = 1;

    // spUSDC's own role names (SparkVault).
    bytes32 internal SETTER_ROLE = keccak256("SETTER_ROLE");

    MockUSDC        internal usdc;
    SparkVault      internal spUsdc;
    SparkPrimeVault internal vault;

    function setUp() public virtual {
        usdc = new MockUSDC();

        spUsdc = SparkVault(
            address(new ERC1967Proxy(
                address(new SparkVault()),
                abi.encodeCall(
                    SparkVault.initialize,
                    (address(usdc), "Spark Savings USDC V2", "spUSDC", spAdmin)
                )
            ))
        );

        vm.startPrank(spAdmin);
        spUsdc.grantRole(SETTER_ROLE, spSetter);
        spUsdc.grantRole(TAKER_ROLE,  spTaker);
        spUsdc.setDepositCap(type(uint256).max);
        spUsdc.setVsrBounds(RAY, MAX_VSR);
        vm.stopPrank();

        // Make spUSDC's exchange rate "ugly": ~4.37% APY for 397 days, then freeze it at RAY so
        // tests that want accrual set a rate explicitly. chi_s ends at ~1.0476...e27 (not clean).
        vm.warp(1_700_000_000);
        vm.prank(spSetter);
        spUsdc.setVsr(UGLY_SP_VSR);
        vm.warp(block.timestamp + 397 days + 12345);
        vm.prank(spSetter);
        spUsdc.setVsr(RAY);  // drips internally

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

        vm.startPrank(admin);
        vault.grantRole(LOSS_MANAGER_ROLE,      lossManager);
        vault.grantRole(OPERATOR_ROLE,          operator);
        vault.grantRole(PAUSER_ROLE,            pauser);
        vault.grantRole(REDEEM_FEE_SETTER_ROLE, redeemFeeSetter);
        vault.grantRole(TAKER_ROLE,             taker);
        vault.grantRole(UNPAUSER_ROLE,          unpauser);
        vault.setMaxRedeemFeeRate(vault.MAX_REDEEM_FEE());
        vault.setVSRBounds(RAY, MAX_VSR);
        vm.stopPrank();

        vm.prank(operator);
        vault.setCapacity(type(uint128).max);

        // Make spPRIME's index ugly too (~2.9% APY for 123 days), then freeze at RAY.
        vm.prank(operator);
        vault.setVSR(UGLY_PRIME_VSR);
        vm.warp(block.timestamp + 123 days + 6789);
        vm.prank(operator);
        vault.setVSR(RAY);  // drips internally

        assertGt(spUsdc.nowChi(), RAY, "harness: spUSDC chi not ugly");
        assertGt(vault.nowChi(),  RAY, "harness: spPRIME chi not ugly");
    }

    /**********************************************************************************************/
    /*** Funding and user actions                                                               ***/
    /**********************************************************************************************/

    function _fund(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Mints `amt` USDC to `who` and calls requestDeposit(amt, who, 0).
    function _deposit(address who, uint256 amt) internal returns (uint256 id) {
        _fund(who, amt);
        vm.prank(who);
        id = vault.requestDeposit(amt, who, 0);
    }

    function _requestRedeem(address who, uint256 shares) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.requestRedeem(shares, who);
    }

    /**********************************************************************************************/
    /*** Admin / role actions                                                                   ***/
    /**********************************************************************************************/

    function _setCapacity(uint256 cap) internal {
        vm.prank(operator);
        vault.setCapacity(cap);
    }

    function _setRedeemFeeRate(uint256 fee) internal {
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(fee);
    }

    function _setMinDeposit(uint256 minDep) internal {
        vm.prank(admin);
        vault.setMinDeposit(minDep);
    }

    function _setMinRedeem(uint256 minRedeemShares) internal {
        vm.prank(admin);
        vault.setMinRedeem(minRedeemShares);
    }

    function _setMinDepositCancellation(uint256 minSavingsShares) internal {
        vm.prank(admin);
        vault.setMinDepositCancellation(minSavingsShares);
    }

    /// @dev LOSS_MANAGER only, requires the vault to be paused. Negative delta realises a loss,
    ///      positive a gain.
    function _adjustTotalAssets(int256 delta) internal {
        vm.prank(lossManager);
        vault.adjustTotalAssets(delta);
    }

    /// @dev Pause, adjust, unpause: the shape every loss/gain test needs.
    function _adjustTotalAssetsWhilePaused(int256 delta) internal {
        bool wasPaused = vault.paused();
        if (!wasPaused) _pause();
        _adjustTotalAssets(delta);
        if (!wasPaused) _unpause();
    }

    function _setPrimeVsr(uint256 vsr_) internal {
        vm.prank(operator);
        vault.setVSR(vsr_);
    }

    function _setSpUsdcVsr(uint256 vsr_) internal {
        vm.prank(spSetter);
        spUsdc.setVsr(vsr_);
    }

    function _processDeposits(uint256 maxSavingsShares, uint256 maxRequests) internal {
        vm.prank(operator);
        vault.processPendingDeposits(maxSavingsShares, maxRequests);
    }

    function _processRedeems(uint256 maxShares, uint256 maxRequests) internal {
        vm.prank(operator);
        vault.processPendingRedeems(maxShares, maxRequests);
    }

    function _processCancelledDeposits(uint256 maxSavingsShares, uint256 maxRequests) internal {
        vm.prank(operator);
        vault.processPendingDepositCancellations(maxSavingsShares, maxRequests);
    }

    /// @dev Owner cancels the whole remaining deposit request to themselves.
    function _cancelDeposit(address who, uint256 id) internal returns (uint256 cancelId) {
        ( , , uint256 shares ) = vault.getPendingDepositRequest(id);
        vm.prank(who);
        cancelId = vault.requestDepositCancellation(id, who, shares);
    }

    /// @dev Owner cancels a queued deposit in full and the operator settles the refund immediately.
    function _cancelDepositAndSettle(address who, uint256 id) internal returns (uint256 cancelId) {
        cancelId = _cancelDeposit(who, id);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
    }

    function _pause() internal {
        vm.prank(pauser);
        vault.pause();
    }

    function _unpause() internal {
        vm.prank(unpauser);
        vault.unpause();
    }

    /**********************************************************************************************/
    /*** Blacklist                                                                              ***/
    /**********************************************************************************************/

    bytes internal constant BLACKLISTED = "Blacklistable: account is blacklisted";

    function _blacklist(address who) internal {
        usdc.setBlacklisted(who, true);
    }

    function _unblacklist(address who) internal {
        usdc.setBlacklisted(who, false);
    }

    /**********************************************************************************************/
    /*** Liquidity manipulation                                                                 ***/
    /**********************************************************************************************/

    /// @dev spUSDC's taker pulls `amt` USDC out of spUSDC (simulates spUSDC capital deployed
    ///      elsewhere, so spUSDC withdrawals become liquidity-limited).
    function _drainSpUsdcLiquidity(uint256 amt) internal {
        vm.prank(spTaker);
        spUsdc.take(amt);
    }

    function _drainAllSpUsdcLiquidity() internal {
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)));
    }

    /// @dev Returns USDC to spUSDC (simulates spUSDC capital coming back).
    function _returnSpUsdcLiquidity(uint256 amt) internal {
        usdc.mint(address(spUsdc), amt);
    }

    /// @dev Prime vault's taker pulls `savingsShares` spUSDC out (simulates Arkis allocation).
    function _take(uint256 savingsShares) internal {
        vm.prank(taker);
        vault.take(savingsShares);
    }

    function _takeAll() internal {
        _take(spUsdc.balanceOf(address(vault)));
    }

    /// @dev Arkis returns `savingsShares` spUSDC to the prime vault via plain transfer, minting
    ///      the backing into spUSDC from thin air if the taker does not hold enough.
    function _returnToVault(uint256 savingsShares) internal {
        uint256 held = spUsdc.balanceOf(taker);
        if (held < savingsShares) {
            uint256 assets = spUsdc.previewMint(savingsShares - held);
            usdc.mint(taker, assets);
            vm.startPrank(taker);
            usdc.approve(address(spUsdc), assets);
            spUsdc.mint(savingsShares - held, taker);
            vm.stopPrank();
        }
        vm.prank(taker);
        spUsdc.transfer(address(vault), savingsShares);
    }

    /**********************************************************************************************/
    /*** Time                                                                                   ***/
    /**********************************************************************************************/

    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
    }

    function _warpAndDrip(uint256 secs) internal {
        _warp(secs);
        spUsdc.drip();
        vault.drip();
    }

    /**********************************************************************************************/
    /*** Views                                                                                  ***/
    /**********************************************************************************************/


    /// @dev Pending-window read; ids below the head revert `InvalidRequestId` in the vault.
    function _depositRequest(uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        return vault.getPendingDepositRequest(id);
    }

    function _redeemRequest(uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        return vault.getPendingRedeemRequest(id);
    }

    function _cancelledDepositRequest(uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        return vault.getPendingDepositCancellationRequest(id);
    }

    function _depositQueueLength() internal view returns (uint256) {
        return vault.firstPendingDepositId() + vault.getPendingDepositRequests().length;
    }

    function _redeemQueueLength() internal view returns (uint256) {
        return vault.firstPendingRedeemId() + vault.getPendingRedeemRequests().length;
    }

    function _cancelledDepositQueueLength() internal view returns (uint256) {
        return vault.firstPendingDepositCancellationId() + vault.getPendingDepositCancellationRequests().length;
    }

    function _vaultSpUsdc() internal view returns (uint256) {
        return spUsdc.balanceOf(address(vault));
    }

}
