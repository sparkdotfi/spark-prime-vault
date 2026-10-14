// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ERC1967Proxy } from "../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

// OZ 5.x refuses an empty-data proxy construction; opt out so `initialize` can be observed.
contract UninitializedERC1967Proxy is ERC1967Proxy {

    constructor(address implementation_) ERC1967Proxy(implementation_, "") {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) { return true; }

}

/// @dev Setter bounds (what each role can and cannot do once its key is compromised), setter
///      validation gaps, setter events, `take`, `initialize`, and ERC20/permit basics.
contract AdminTest is LocalTestBase {

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event CapacitySet(uint256 newCapacity);
    event ChiSet(uint192 chi);
    event Drip(uint192 chi, uint256 diff);
    event MaxRedeemFeeSet(uint256 fee);
    event MinimumsSet(uint256 minDeposit, uint256 minWithdraw);
    event Take(address indexed to, uint256 shares);
    event VSRBoundsSet(uint256 minVSR, uint256 maxVSR);
    event VSRSet(uint256 vsr);
    event RedeemFeeSet(uint256 fee);

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    /**********************************************************************************************/
    /*** setCapacity                                                                            ***/
    /**********************************************************************************************/

    function test_setCapacity_tooHighBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/capacity-too-high");
        vault.setCapacity(uint256(type(uint128).max) + 1);

        vault.setCapacity(type(uint128).max);
        assertEq(vault.maxCapacity(), type(uint128).max);
    }

    function test_setCapacity() public {
        vm.startPrank(admin);
        vm.expectEmit(address(vault));
        emit CapacitySet(1_000_000e6);
        vault.setCapacity(1_000_000e6);
        assertEq(vault.maxCapacity(),       1_000_000e6);
        assertEq(vault.availableCapacity(), 1_000_000e6);

        vm.expectEmit(address(vault));
        emit CapacitySet(0);
        vault.setCapacity(0);
        assertEq(vault.maxCapacity(),       0);
        assertEq(vault.availableCapacity(), 0);
    }

    // Capacity 0 is allowed: deposits are accepted into the queue but nothing is minted.
    function test_setCapacity_zeroFreezesMinting() public {
        _setCapacity(0);
        uint256 id_ = _deposit(alice, 100e6);
        (, , uint256 queued_) = _depositRequest(id_);
        assertGt(queued_,                             0);
        assertEq(vault.balanceOf(alice),              0);
        assertEq(vault.totalSupply(),                 0);
        assertEq(vault.pendingDepositSavingsShares(), queued_);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(alice),              0);
    }

    // Capacity may be set below totalSupply; availableCapacity floors at 0.
    function test_setCapacity_belowTotalSupply() public {
        _deposit(alice, 100e6);
        uint256 supply_ = vault.totalSupply();
        _setCapacity(supply_ - 1);
        assertEq(vault.availableCapacity(), 0);
        assertEq(vault.totalSupply(),       supply_);
    }

    /**********************************************************************************************/
    /*** setMaxRedeemFee                                                                        ***/
    /**********************************************************************************************/

    function test_setMaxRedeemFee_tooHighBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setMaxRedeemFee(0.01e18 + 1);

        vault.setMaxRedeemFee(0.01e18);
        assertEq(vault.maxRedeemFee(), 0.01e18);
    }

    function test_setMaxRedeemFee() public {
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit MaxRedeemFeeSet(0.005e18);
        vault.setMaxRedeemFee(0.005e18);
        assertEq(vault.maxRedeemFee(), 0.005e18);
    }

    // GAP: lowering the max below the current fee leaves the fee above the max; new redeem
    // requests keep paying the old fee until the risk manager sets a new one.
    function test_setMaxRedeemFee_belowCurrentFeeLeavesFeeAboveMax() public {
        _setRedeemFee(0.01e18);
        vm.prank(admin);
        vault.setMaxRedeemFee(0.001e18);
        assertEq(vault.redeemFee(),    0.01e18);
        assertEq(vault.maxRedeemFee(), 0.001e18);

        _deposit(alice, 1_000e6);
        uint256 shares_ = vault.balanceOf(alice);
        uint256 id_     = _requestRedeem(alice, shares_);
        (, , uint256 queued_) = _redeemRequest(id_);
        assertEq(shares_ - queued_, (shares_ * 0.01e18 + WAD - 1) / WAD);  // 1% charged

        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFee(0.01e18);

        _setRedeemFee(0.001e18);
        assertEq(vault.redeemFee(), 0.001e18);
    }

    /**********************************************************************************************/
    /*** setMinimums                                                                            ***/
    /**********************************************************************************************/

    function test_setMinimums() public {
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit MinimumsSet(10e6, 20e6);
        vault.setMinimums(10e6, 20e6);
        assertEq(vault.minDeposit(),  10e6);
        assertEq(vault.minWithdraw(), 20e6);
    }

    // GAP: no validation at all. minWithdraw = max blocks every redeem request forever
    // (cancels still work, the rebalancer can still process what is already queued).
    function test_setMinimums_noValidation_minWithdrawBlocksAllRedeems() public {
        _deposit(alice, 1_000e6);
        uint256 shares_ = vault.balanceOf(alice);

        vm.prank(admin);
        vault.setMinimums(0, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(shares_, alice);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(1, alice);

        // Only a reset by DEFAULT_ADMIN restores exits.
        _setMinimums(0, 0);
        _requestRedeem(alice, shares_);
        assertEq(vault.pendingRedeemShares(), shares_);
    }

    // GAP: minDeposit = max blocks every deposit request.
    function test_setMinimums_noValidation_minDepositBlocksAllDeposits() public {
        vm.prank(admin);
        vault.setMinimums(type(uint256).max, 0);

        _fund(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(1_000e6, alice);
    }

    // GAP: minDeposit may exceed the whole capacity; every deposit then partially fills and the
    // remainder queues behind an unreachable capacity.
    function test_setMinimums_minDepositAboveCapacity() public {
        _setCapacity(100e6);
        _setMinimums(1_000e6, 0);

        _fund(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(999e6, alice);

        uint256 id_ = _deposit(alice, 1_000e6);
        (, , uint256 queued_) = _depositRequest(id_);
        assertApproxEqAbs(vault.totalSupply(),    100e6, 2);  // R2 double rounding
        assertApproxEqAbs(vault.balanceOf(alice), 100e6, 2);
        assertLe(vault.availableCapacity(),       2);
        assertGt(queued_,                         0);
    }

    // minDeposit is checked on assets, minWithdraw on gross shares valued at nowChi (I-4).
    function test_setMinimums_boundaries() public {
        _setMinimums(100e6, 50e6);

        _fund(alice, 1_000e6);
        vm.startPrank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(100e6 - 1, alice);
        vault.requestDeposit(100e6, alice);
        vm.stopPrank();

        uint256 chi_       = vault.nowChi();
        uint256 minShares_ = (50e6 * RAY + chi_ - 1) / chi_;  // smallest shares with value >= 50e6
        assertGe(minShares_ * chi_ / RAY, 50e6);
        assertLt((minShares_ - 1) * chi_ / RAY, 50e6);

        vm.startPrank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(minShares_ - 1, alice);
        vault.requestRedeem(minShares_, alice);
        vm.stopPrank();
    }

    /**********************************************************************************************/
    /*** setVSRBounds                                                                           ***/
    /**********************************************************************************************/

    function test_setVSRBounds_belowRayBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vault.setVSRBounds(RAY - 1, FOUR_PCT_VSR);

        vault.setVSRBounds(RAY, FOUR_PCT_VSR);
    }

    function test_setVSRBounds_aboveMaxVsrBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVSRBounds(RAY, MAX_VSR + 1);

        vault.setVSRBounds(RAY, MAX_VSR);
    }

    function test_setVSRBounds_minVsrGtMaxVsrBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/min-vsr-gt-max-vsr");
        vault.setVSRBounds(FOUR_PCT_VSR + 1, FOUR_PCT_VSR);

        vault.setVSRBounds(FOUR_PCT_VSR, FOUR_PCT_VSR);
    }

    function test_setVSRBounds() public {
        assertEq(vault.minVSR(), RAY);
        assertEq(vault.maxVSR(), MAX_VSR);

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit VSRBoundsSet(ONE_PCT_VSR, FOUR_PCT_VSR);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        assertEq(vault.minVSR(), ONE_PCT_VSR);
        assertEq(vault.maxVSR(), FOUR_PCT_VSR);
    }

    // GAP: bounds may be set so the current vsr is outside them; drip keeps accruing at the old
    // vsr until the setter moves it. Only the setter can bring it back into range.
    function test_setVSRBounds_currentVsrOutsideNewBounds() public {
        _deposit(alice, 1_000e6);
        _setPrimeVsr(TEN_PCT_VSR);

        vm.prank(admin);
        vault.setVSRBounds(RAY, ONE_PCT_VSR);
        assertEq(vault.vsr(), TEN_PCT_VSR);

        uint256 assetsBefore_ = vault.assetsOf(alice);
        _warpAndDrip(365 days);
        uint256 assetsAfter_  = vault.assetsOf(alice);
        // ~10% accrued, far above the 1% ceiling.
        assertGt(assetsAfter_, assetsBefore_ * 109 / 100);
        assertLt(assetsAfter_, assetsBefore_ * 111 / 100);

        vm.prank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVSR(TEN_PCT_VSR);

        _setPrimeVsr(ONE_PCT_VSR);
        assertEq(vault.vsr(), ONE_PCT_VSR);
    }

    /**********************************************************************************************/
    /*** setVSR (SETTER_ROLE, hot wallet)                                                       ***/
    /**********************************************************************************************/

    function test_setVSR_belowMinVsrBoundary() public {
        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.startPrank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vault.setVSR(ONE_PCT_VSR - 1);

        vault.setVSR(ONE_PCT_VSR);
        assertEq(vault.vsr(), ONE_PCT_VSR);
    }

    function test_setVSR_aboveMaxVsrBoundary() public {
        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.startPrank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVSR(FOUR_PCT_VSR + 1);

        vault.setVSR(FOUR_PCT_VSR);
        assertEq(vault.vsr(), FOUR_PCT_VSR);
    }

    // With bounds [RAY, RAY] (deploy default) a compromised setter cannot move the rate at all.
    function test_setVSR_lockedWhenBoundsEqual() public {
        vm.prank(admin);
        vault.setVSRBounds(RAY, RAY);

        vm.startPrank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVSR(RAY + 1);
        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vault.setVSR(RAY - 1);
        vault.setVSR(RAY);
    }

    function test_setVSR() public {
        uint256 rhoBefore_ = vault.rho();
        skip(10 days);

        uint192 nChi_ = vault.nowChi();
        assertEq(nChi_, vault.chi());  // vsr is RAY: no accrual
        assertEq(vault.rho(), rhoBefore_);

        vm.prank(setter);
        vm.expectEmit(address(vault));
        emit Drip(nChi_, 0);
        vm.expectEmit(address(vault));
        emit VSRSet(FOUR_PCT_VSR);
        vault.setVSR(FOUR_PCT_VSR);

        assertEq(vault.chi(), nChi_);
        assertEq(vault.rho(), block.timestamp);
        assertEq(vault.vsr(), FOUR_PCT_VSR);

        skip(10 days);
        assertGt(vault.nowChi(), nChi_);
    }

    // setVSR drips first, so accrual under the previous rate is locked in before the switch.
    function test_setVSR_dripsAtOldRate() public {
        _deposit(alice, 1_000e6);
        _setPrimeVsr(TEN_PCT_VSR);
        skip(365 days);
        uint256 expected_ = vault.assetsOf(alice);
        uint192 nChi_     = vault.nowChi();
        uint256 supply_   = vault.totalSupply();
        uint256 diff_     = supply_ * nChi_ / RAY - supply_ * vault.chi() / RAY;

        vm.prank(setter);
        vm.expectEmit(address(vault));
        emit Drip(nChi_, diff_);
        vault.setVSR(RAY);

        assertEq(vault.assetsOf(alice), expected_);
        assertEq(vault.chi(),           nChi_);
    }

    /**********************************************************************************************/
    /*** setRedeemFee (RISK_MANAGER_ROLE, hot wallet)                                           ***/
    /**********************************************************************************************/

    function test_setRedeemFee_tooHighBoundary() public {
        vm.prank(admin);
        vault.setMaxRedeemFee(0.005e18);

        vm.startPrank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFee(0.005e18 + 1);

        vault.setRedeemFee(0.005e18);
        assertEq(vault.redeemFee(), 0.005e18);
    }

    function test_setRedeemFee_zeroMaxLocksFee() public {
        vm.prank(admin);
        vault.setMaxRedeemFee(0);

        vm.startPrank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFee(1);
        vault.setRedeemFee(0);
    }

    function test_setRedeemFee() public {
        vm.prank(riskManager);
        vm.expectEmit(address(vault));
        emit RedeemFeeSet(0.001e18);
        vault.setRedeemFee(0.001e18);
        assertEq(vault.redeemFee(), 0.001e18);
    }

    /**********************************************************************************************/
    /*** setChi (RISK_MANAGER_ROLE, hot wallet)                                                 ***/
    /**********************************************************************************************/

    function test_setChi_notPaused() public {
        uint192 chi_ = vault.chi();
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/not-paused");
        vault.setChi(chi_ - 1);
    }

    function test_setChi_zero() public {
        _pause();
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-chi");
        vault.setChi(0);
    }

    // chi_ must be strictly below the dripped chi: the risk manager can never raise the index.
    function test_setChi_cannotRaiseBoundary() public {
        _pause();
        uint192 chi_ = vault.chi();

        vm.startPrank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-chi");
        vault.setChi(chi_ + 1);

        vm.expectRevert("SparkPrimeVault/invalid-chi");
        vault.setChi(chi_);

        vault.setChi(chi_ - 1);
        assertEq(vault.chi(), chi_ - 1);
    }

    // After time passes, setChi compares against the dripped value, not the stored one.
    function test_setChi_comparesAgainstDrippedChi() public {
        _setPrimeVsr(TEN_PCT_VSR);
        _pause();
        uint192 stored_ = vault.chi();
        skip(30 days);
        uint192 dripped_ = vault.nowChi();
        assertGt(dripped_, stored_);

        vm.startPrank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-chi");
        vault.setChi(dripped_);

        // A value above the stored chi but below the dripped one is accepted.
        vault.setChi(dripped_ - 1);
        assertEq(vault.chi(), dripped_ - 1);
        assertEq(vault.rho(), block.timestamp);
    }

    function test_setChi() public {
        _deposit(alice, 1_000e6);
        _pause();
        uint192 chi_   = vault.chi();
        uint192 half_  = chi_ / 2;
        uint256 before_ = vault.assetsOf(alice);

        vm.prank(riskManager);
        vm.expectEmit(address(vault));
        emit ChiSet(half_);
        vault.setChi(half_);

        assertEq(vault.chi(),           half_);
        assertEq(vault.assetsOf(alice), vault.balanceOf(alice) * half_ / RAY);
        assertLe(vault.assetsOf(alice), before_ / 2);
    }

    // No floor: a compromised risk manager (while the guardian has paused) can write off the
    // whole vault with one call. Recommend a floor, e.g. chi_ >= drip() * X% or a per-call max
    // drawdown.
    function test_setChi_oneWeiRealisesTotalLoss() public {
        _deposit(alice, 1_000_000e6);
        _pause();
        assertApproxEqAbs(vault.assetsOf(alice), 1_000_000e6, 2);

        vm.prank(riskManager);
        vault.setChi(1);

        assertEq(vault.chi(),           1);
        assertEq(vault.assetsOf(alice), vault.balanceOf(alice) / RAY);  // 0 for < 1e27 shares
        assertEq(vault.assetsOf(alice), 0);
        assertEq(vault.totalAssets(),   0);

        // The spUSDC backing is untouched: the vault now holds ~1M USDC of spUSDC against a
        // notional of 0, and `take` can still remove all of it.
        assertApproxEqAbs(spUsdc.convertToAssets(_vaultSpUsdc()), 1_000_000e6, 2);
    }

    /**********************************************************************************************/
    /*** take (TAKER_ROLE)                                                                      ***/
    /**********************************************************************************************/

    function test_take_insufficientBalanceBoundary() public {
        _deposit(alice, 1_000e6);
        uint256 bal_ = _vaultSpUsdc();

        vm.startPrank(taker);
        vm.expectRevert("SparkPrimeVault/insufficient-unencumbered-shares");
        vault.take(bal_ + 1);

        vault.take(bal_);
        assertEq(_vaultSpUsdc(),          0);
        assertEq(spUsdc.balanceOf(taker), bal_);
    }

    function test_take_zero() public {
        vm.prank(taker);
        vm.expectEmit(address(vault));
        emit Take(taker, 0);
        vault.take(0);
        assertEq(spUsdc.balanceOf(taker), 0);
    }

    function test_take() public {
        _deposit(alice, 1_000e6);
        uint256 bal_ = _vaultSpUsdc();
        assertGt(bal_, 0);
        assertEq(spUsdc.balanceOf(taker), 0);

        vm.prank(taker);
        vm.expectEmit(address(vault));
        emit Take(taker, bal_ / 3);
        vault.take(bal_ / 3);

        assertEq(_vaultSpUsdc(),          bal_ - bal_ / 3);
        assertEq(spUsdc.balanceOf(taker), bal_ / 3);

        // Notional is unchanged by take.
        assertApproxEqAbs(vault.totalAssets(), 1_000e6, 2);
    }

    function test_take_whilePaused() public {
        _deposit(alice, 1_000e6);
        uint256 bal_ = _vaultSpUsdc();
        _pause();
        vm.prank(taker);
        vault.take(bal_);
        assertEq(_vaultSpUsdc(), 0);
    }

    // F-2 (known): take ignores pendingDepositSavingsShares.
    function test_take_ignoresPendingDepositSavingsShares() public {
        _setCapacity(0);
        uint256 id_ = _deposit(alice, 1_000e6);
        (, , uint256 queued_) = _depositRequest(id_);
        assertEq(vault.pendingDepositSavingsShares(), queued_);
        assertEq(_vaultSpUsdc(),                      queued_);

        vm.prank(taker);
        vault.take(queued_);

        assertEq(_vaultSpUsdc(),                      0);
        assertEq(vault.pendingDepositSavingsShares(), queued_);

        vm.prank(alice);
        vm.expectRevert();  // spUSDC redeem of shares the vault no longer holds
        vault.cancelDepositRequest(id_, alice);
    }

    /**********************************************************************************************/
    /*** initialize                                                                             ***/
    /**********************************************************************************************/

    function _freshProxy() internal returns (SparkPrimeVault fresh_) {
        fresh_ = SparkPrimeVault(address(new UninitializedERC1967Proxy(address(new SparkPrimeVault()))));
    }

    function test_initialize() public {
        SparkPrimeVault fresh_ = _freshProxy();

        assertEq(vm.load(address(fresh_), INITIALIZABLE_STORAGE), bytes32(0));
        assertEq(fresh_.savings(),  address(0));
        assertEq(fresh_.name(),     "");
        assertEq(fresh_.symbol(),   "");
        assertEq(fresh_.decimals(), 0);
        assertEq(fresh_.chi(),      0);
        assertEq(fresh_.rho(),      0);
        assertEq(fresh_.vsr(),      0);
        assertEq(fresh_.minVSR(),   0);
        assertEq(fresh_.maxVSR(),   0);
        assertEq(usdc.allowance(address(fresh_), address(spUsdc)), 0);
        assertFalse(fresh_.hasRole(DEFAULT_ADMIN_ROLE, admin));

        skip(1234);
        fresh_.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);

        assertEq(vm.load(address(fresh_), INITIALIZABLE_STORAGE), bytes32(uint256(1)));
        assertEq(fresh_.savings(),      address(spUsdc));
        assertEq(fresh_.name(),         "Spark Prime USDC");
        assertEq(fresh_.symbol(),       "spPRIME");
        assertEq(fresh_.decimals(),     6);
        assertEq(fresh_.decimals(),     usdc.decimals());
        assertEq(fresh_.chi(),          RAY);
        assertEq(fresh_.rho(),          block.timestamp);
        assertEq(fresh_.vsr(),          RAY);
        assertEq(fresh_.minVSR(),       RAY);
        assertEq(fresh_.maxVSR(),       RAY);
        assertEq(fresh_.maxCapacity(),  0);
        assertEq(fresh_.minDeposit(),   0);
        assertEq(fresh_.minWithdraw(),  0);
        assertEq(fresh_.redeemFee(),    0);
        assertEq(fresh_.maxRedeemFee(), 0);
        assertEq(fresh_.totalSupply(),  0);
        assertEq(fresh_.paused(),       false);
        assertEq(fresh_.version(),      "1");
        assertEq(usdc.allowance(address(fresh_), address(spUsdc)), type(uint256).max);

        assertTrue(fresh_.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertEq(fresh_.getRoleMembers(DEFAULT_ADMIN_ROLE).length, 1);
        assertEq(fresh_.getRoleMembers(DEFAULT_ADMIN_ROLE)[0],     admin);
        assertEq(fresh_.getRoleMembers(GUARDIAN_ROLE).length,      0);
        assertEq(fresh_.getRoleMembers(SETTER_ROLE).length,        0);
        assertEq(fresh_.getRoleMembers(TAKER_ROLE).length,         0);
    }

    // Fresh deployment defaults: capacity 0 and maxRedeemFee 0 mean deposits queue and the fee
    // is locked at 0 until the admin configures them; VSR is locked at RAY.
    function test_initialize_defaultsAreSafe() public {
        SparkPrimeVault fresh_ = _freshProxy();
        fresh_.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);
        vm.startPrank(admin);
        fresh_.grantRole(SETTER_ROLE,       setter);
        fresh_.grantRole(RISK_MANAGER_ROLE, riskManager);
        vm.stopPrank();

        vm.prank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        fresh_.setVSR(RAY + 1);

        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        fresh_.setRedeemFee(1);

        assertEq(fresh_.availableCapacity(), 0);
    }

    // GAP: `initialize` does not guard against admin == address(0). OZ `_grantRole` succeeds for
    // the zero address, leaving a vault whose only admin is address(0): no setters, no upgrade.
    function test_initialize_zeroAdminNotGuarded() public {
        SparkPrimeVault fresh_ = _freshProxy();
        fresh_.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", address(0));

        assertTrue(fresh_.hasRole(DEFAULT_ADMIN_ROLE, address(0)));
        assertEq(fresh_.getRoleMembers(DEFAULT_ADMIN_ROLE).length, 1);
        assertEq(fresh_.getRoleMembers(DEFAULT_ADMIN_ROLE)[0],     address(0));
        assertFalse(fresh_.hasRole(DEFAULT_ADMIN_ROLE, admin));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", admin, DEFAULT_ADMIN_ROLE
        ));
        fresh_.setCapacity(1);
    }

    /**********************************************************************************************/
    /*** ERC20 basics                                                                           ***/
    /**********************************************************************************************/

    function test_erc20_metadata() public view {
        assertEq(vault.name(),     "Spark Prime USDC");
        assertEq(vault.symbol(),   "spPRIME");
        assertEq(vault.decimals(), 6);
        assertEq(vault.version(),  "1");
        assertEq(
            vault.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Spark Prime USDC"),
                keccak256("1"),
                block.chainid,
                address(vault)
            ))
        );
        assertEq(
            vault.PERMIT_TYPEHASH(),
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
        );
    }

    function test_approve() public {
        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit Approval(alice, bob, 100);
        assertTrue(vault.approve(bob, 100));
        assertEq(vault.allowance(alice, bob), 100);

        // Overwrites, does not add.
        vm.prank(alice);
        vault.approve(bob, 7);
        assertEq(vault.allowance(alice, bob), 7);
    }

    function test_transfer() public {
        _deposit(alice, 1_000e6);
        uint256 bal_ = vault.balanceOf(alice);
        assertGt(bal_, 0);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit Transfer(alice, bob, 400e6);
        assertTrue(vault.transfer(bob, 400e6));

        assertEq(vault.balanceOf(alice), bal_ - 400e6);
        assertEq(vault.balanceOf(bob),   400e6);
        assertEq(vault.totalSupply(),    bal_);
    }

    function test_transfer_toZeroAddress() public {
        _deposit(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transfer(address(0), 1);
    }

    function test_transfer_insufficientBalanceBoundary() public {
        _deposit(alice, 1_000e6);
        uint256 bal_ = vault.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.transfer(bob, bal_ + 1);

        vault.transfer(bob, bal_);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob),   bal_);
    }

    function test_transfer_toSelf() public {
        _deposit(alice, 1_000e6);
        uint256 bal_ = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(alice, bal_);
        assertEq(vault.balanceOf(alice), bal_);
    }

    function test_transferFrom() public {
        _deposit(alice, 1_000e6);
        uint256 bal_ = vault.balanceOf(alice);

        vm.prank(alice);
        vault.approve(bob, 500e6);

        vm.prank(bob);
        vm.expectEmit(address(vault));
        emit Transfer(alice, bob, 300e6);
        assertTrue(vault.transferFrom(alice, bob, 300e6));

        assertEq(vault.balanceOf(alice),      bal_ - 300e6);
        assertEq(vault.balanceOf(bob),        300e6);
        assertEq(vault.allowance(alice, bob), 200e6);
    }

    function test_transferFrom_insufficientAllowanceBoundary() public {
        _deposit(alice, 1_000e6);
        vm.prank(alice);
        vault.approve(bob, 100e6);

        vm.startPrank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-allowance");
        vault.transferFrom(alice, bob, 100e6 + 1);

        vault.transferFrom(alice, bob, 100e6);
        assertEq(vault.allowance(alice, bob), 0);
    }

    function test_transferFrom_insufficientBalanceBoundary() public {
        _deposit(alice, 1_000e6);
        uint256 bal_ = vault.balanceOf(alice);
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        vm.startPrank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.transferFrom(alice, bob, bal_ + 1);

        vault.transferFrom(alice, bob, bal_);
        assertEq(vault.balanceOf(bob), bal_);
    }

    function test_transferFrom_maxAllowanceNotDecremented() public {
        _deposit(alice, 1_000e6);
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        vm.prank(bob);
        vault.transferFrom(alice, bob, 1e6);
        assertEq(vault.allowance(alice, bob), type(uint256).max);
    }

    function test_transferFrom_selfNeedsNoAllowance() public {
        _deposit(alice, 1_000e6);
        assertEq(vault.allowance(alice, alice), 0);
        vm.prank(alice);
        vault.transferFrom(alice, bob, 1e6);
        assertEq(vault.balanceOf(bob), 1e6);
    }

    function test_transferFrom_toZeroAddress() public {
        _deposit(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transferFrom(alice, address(0), 1);
    }

    /**********************************************************************************************/
    /*** permit                                                                                 ***/
    /**********************************************************************************************/

    function _permitDigest(address owner_, address spender_, uint256 value_, uint256 nonce_, uint256 deadline_)
        internal view returns (bytes32)
    {
        return keccak256(abi.encodePacked(
            "\x19\x01",
            vault.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(vault.PERMIT_TYPEHASH(), owner_, spender_, value_, nonce_, deadline_))
        ));
    }

    function test_permit() public {
        (address owner_, uint256 key_) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, _permitDigest(owner_, bob, 100e6, 0, deadline_));

        assertEq(vault.nonces(owner_), 0);

        vm.expectEmit(address(vault));
        emit Approval(owner_, bob, 100e6);
        vault.permit(owner_, bob, 100e6, deadline_, v_, r_, s_);

        assertEq(vault.allowance(owner_, bob), 100e6);
        assertEq(vault.nonces(owner_),         1);
    }

    function test_permit_bytesSignature() public {
        (address owner_, uint256 key_) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp;  // deadline == now is still valid
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, _permitDigest(owner_, bob, 5, 0, deadline_));

        vault.permit(owner_, bob, 5, deadline_, abi.encodePacked(r_, s_, v_));
        assertEq(vault.allowance(owner_, bob), 5);
        assertEq(vault.nonces(owner_),         1);
    }

    function test_permit_expiredBoundary() public {
        (address owner_, uint256 key_) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, _permitDigest(owner_, bob, 5, 0, deadline_));

        vm.warp(deadline_ + 1);
        vm.expectRevert("SparkPrimeVault/permit-expired");
        vault.permit(owner_, bob, 5, deadline_, v_, r_, s_);

        vm.warp(deadline_);
        vault.permit(owner_, bob, 5, deadline_, v_, r_, s_);
        assertEq(vault.allowance(owner_, bob), 5);
    }

    function test_permit_invalidOwner() public {
        vm.expectRevert("SparkPrimeVault/invalid-owner");
        vault.permit(address(0), bob, 5, block.timestamp, 27, bytes32(0), bytes32(0));
    }

    function test_permit_wrongSigner() public {
        (address owner_, )          = makeAddrAndKey("permitOwner");
        (,               uint256 k2_) = makeAddrAndKey("someoneElse");
        uint256 deadline_ = block.timestamp + 1 hours;
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(k2_, _permitDigest(owner_, bob, 5, 0, deadline_));

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner_, bob, 5, deadline_, v_, r_, s_);
        assertEq(vault.nonces(owner_), 0);
    }

    function test_permit_wrongValue() public {
        (address owner_, uint256 key_) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, _permitDigest(owner_, bob, 5, 0, deadline_));

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner_, bob, 6, deadline_, v_, r_, s_);
    }

    function test_permit_replay() public {
        (address owner_, uint256 key_) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, _permitDigest(owner_, bob, 5, 0, deadline_));

        vault.permit(owner_, bob, 5, deadline_, v_, r_, s_);
        assertEq(vault.nonces(owner_), 1);

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner_, bob, 5, deadline_, v_, r_, s_);
        assertEq(vault.nonces(owner_), 1);
    }

    function test_permit_wrongNonce() public {
        (address owner_, uint256 key_) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, _permitDigest(owner_, bob, 5, 1, deadline_));

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner_, bob, 5, deadline_, v_, r_, s_);
    }

    function test_permit_badSignatureLengthForEOA() public {
        (address owner_, uint256 key_) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        (, bytes32 r_, bytes32 s_) = vm.sign(key_, _permitDigest(owner_, bob, 5, 0, deadline_));

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner_, bob, 5, deadline_, abi.encodePacked(r_, s_));  // 64 bytes
    }

    function test_permit_wrongDomain() public {
        (address owner_, uint256 key_) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        bytes32 digest_ = keccak256(abi.encodePacked(
            "\x19\x01",
            spUsdc.DOMAIN_SEPARATOR(),  // another contract's domain
            keccak256(abi.encode(vault.PERMIT_TYPEHASH(), owner_, bob, 5, 0, deadline_))
        ));
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, digest_);

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner_, bob, 5, deadline_, v_, r_, s_);
    }

}
