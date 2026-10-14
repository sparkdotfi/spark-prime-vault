// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import "./TestBase.t.sol";

contract AuthorizationTestBase is TestBase {

    uint256 public constant RAY = 1e27;

    uint256 internal constant ONE_PCT_VSR  = 1.000000000315522921573372069e27;
    uint256 internal constant FOUR_PCT_VSR = 1.000000001243680656318820312e27;

    address internal user1        = makeAddr("user1");
    address internal unauthorized = makeAddr("unauthorized");

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(admin);
        vault.grantRole(GUARDIAN_ROLE,     guardian);
        vault.grantRole(REBALANCER_ROLE,   rebalancer);
        vault.grantRole(RISK_MANAGER_ROLE, riskManager);
        vault.grantRole(SETTER_ROLE,       setter);
        vault.grantRole(TAKER_ROLE,        taker);
        vault.setCapacity(1_000_000e6);
        vm.stopPrank();

        deal(address(usdc), user1, 1_000_000e6);
    }

    function _notAuthorized(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            account,
            role
        );
    }

    function _requestDeposit(address user, uint256 assets) internal returns (uint256 requestId) {
        vm.startPrank(user);
        usdc.approve(address(vault), assets);

        requestId = vault.requestDeposit(assets, user);
        vm.stopPrank();
    }

}

contract SetCapacityTests is AuthorizationTestBase {

    // Failure tests

    function test_setCapacity_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.setCapacity(2_000_000e6);
    }

    // Success tests

    function test_setCapacity() external {
        assertEq(vault.maxCapacity(),       1_000_000e6);
        assertEq(vault.availableCapacity(), 1_000_000e6);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.CapacitySet(2_000_000e6);

        vm.prank(admin);
        vault.setCapacity(2_000_000e6);

        assertEq(vault.maxCapacity(),       2_000_000e6);
        assertEq(vault.availableCapacity(), 2_000_000e6);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.CapacitySet(type(uint128).max);

        vm.prank(admin);
        vault.setCapacity(type(uint128).max);

        assertEq(vault.maxCapacity(),       type(uint128).max);
        assertEq(vault.availableCapacity(), type(uint128).max);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.CapacitySet(0);

        vm.prank(admin);
        vault.setCapacity(0);

        assertEq(vault.maxCapacity(),       0);
        assertEq(vault.availableCapacity(), 0);
    }

}

contract SetMaxRedeemFeeTests is AuthorizationTestBase {

    // Failure tests

    function test_setMaxRedeemFee_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.setMaxRedeemFeeRate(0.01e18);
    }

    function test_setMaxRedeemFee_feeTooHighBoundary() external {
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.01e18 + 1);

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.01e18);  // MAX_REDEEM_FEE is 1%
    }

    // Success tests

    function test_setMaxRedeemFee() external {
        assertEq(vault.maxRedeemFeeRate(), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MaxRedeemFeeRateSet(0.01e18);

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.01e18);

        assertEq(vault.maxRedeemFeeRate(), 0.01e18);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MaxRedeemFeeRateSet(0);

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0);

        assertEq(vault.maxRedeemFeeRate(), 0);
    }

}

contract SetMinDepositTests is AuthorizationTestBase {

    function test_setMinDeposit_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.setMinDeposit(100e6);
    }

    function test_setMinDeposit() external {
        assertEq(vault.minDeposit(), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MinDepositSet(100e6);

        vm.prank(admin);
        vault.setMinDeposit(100e6);

        assertEq(vault.minDeposit(), 100e6);
    }

}

contract SetMinRedeemTests is AuthorizationTestBase {

    function test_setMinRedeem_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.setMinRedeem(100e6);
    }

    function test_setMinRedeem() external {
        assertEq(vault.minRedeem(), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MinRedeemSet(50e6);

        vm.prank(admin);
        vault.setMinRedeem(50e6);

        assertEq(vault.minRedeem(), 50e6);
    }

}

contract SetVSRBoundsTests is AuthorizationTestBase {

    // Failure tests

    function test_setVSRBounds_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.setVSRBounds({ minVSR_ : RAY, maxVSR_ : FOUR_PCT_VSR });
    }

    function test_setVSRBounds_vsrTooLowBoundary() external {
        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : RAY - 1, maxVSR_ : FOUR_PCT_VSR });

        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : RAY, maxVSR_ : FOUR_PCT_VSR });
    }

    function test_setVSRBounds_vsrTooHighBoundary() external {
        uint256 maxVsr = vault.MAX_VSR();

        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : RAY, maxVSR_ : maxVsr + 1 });

        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : RAY, maxVSR_ : maxVsr });
    }

    function test_setVSRBounds_minVSRGtMaxVSRBoundary() external {
        vm.expectRevert("SparkPrimeVault/min-vsr-gt-max-vsr");
        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : FOUR_PCT_VSR + 1, maxVSR_ : FOUR_PCT_VSR });

        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : FOUR_PCT_VSR, maxVSR_ : FOUR_PCT_VSR });
    }

    // Success tests

    function test_setVSRBounds() external {
        assertEq(vault.minVSR(), RAY);
        assertEq(vault.maxVSR(), RAY);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.VSRBoundsSet(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.prank(admin);
        vault.setVSRBounds({ minVSR_ : ONE_PCT_VSR, maxVSR_ : FOUR_PCT_VSR });

        assertEq(vault.minVSR(), ONE_PCT_VSR);
        assertEq(vault.maxVSR(), FOUR_PCT_VSR);
    }

}

contract SetVSRTests is AuthorizationTestBase {

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);
    }

    // Failure tests

    function test_setVSR_notSetter() external {
        vm.expectRevert(_notAuthorized(unauthorized, SETTER_ROLE));
        vm.prank(unauthorized);
        vault.setVSR(ONE_PCT_VSR);
    }

    function test_setVSR_vsrTooLowBoundary() external {
        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vm.prank(setter);
        vault.setVSR(ONE_PCT_VSR - 1);

        vm.prank(setter);
        vault.setVSR(ONE_PCT_VSR);
    }

    function test_setVSR_vsrTooHighBoundary() external {
        vm.prank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVSR(FOUR_PCT_VSR + 1);

        vm.prank(setter);
        vault.setVSR(FOUR_PCT_VSR);
    }

    // Success tests

    function test_setVSR() external {
        uint256 deployTimestamp = block.timestamp;

        skip(10 days);

        assertEq(uint256(vault.chi()), RAY);
        assertEq(uint256(vault.rho()), deployTimestamp);
        assertEq(vault.vsr(),          RAY);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Drip(uint192(RAY), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.VSRSet(FOUR_PCT_VSR);

        vm.prank(setter);
        vault.setVSR(FOUR_PCT_VSR);

        assertEq(uint256(vault.chi()), RAY);
        assertEq(uint256(vault.rho()), block.timestamp);
        assertEq(vault.vsr(),          FOUR_PCT_VSR);
    }

}

contract TakeTests is AuthorizationTestBase {

    // Failure tests

    function test_take_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, TAKER_ROLE));
        vm.prank(unauthorized);
        vault.take(1_000_000e6);
    }

    function test_take_insufficientSharesBoundary() external {
        uint256 expectedSavingsShares = spUsdc.convertToShares(1_000_000e6);

        _requestDeposit(user1, 1_000_000e6);  // Instant fill

        vm.expectRevert("SparkPrimeVault/insufficient-shares");
        vm.prank(taker);
        vault.take(expectedSavingsShares + 1);

        vm.prank(taker);
        vault.take(expectedSavingsShares);
    }

    // Success tests

    function test_take() external {
        uint256 expectedSavingsShares = spUsdc.convertToShares(1_000_000e6);

        _requestDeposit(user1, 1_000_000e6); // Instant fill

        assertEq(spUsdc.balanceOf(address(vault)), expectedSavingsShares);
        assertEq(spUsdc.balanceOf(taker),          0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Take(expectedSavingsShares);

        vm.prank(taker);
        vault.take(expectedSavingsShares);

        assertEq(spUsdc.balanceOf(address(vault)), 0);
        assertEq(spUsdc.balanceOf(taker),          expectedSavingsShares);
    }

}

contract ProcessPendingDepositsTests is AuthorizationTestBase {

    // Failure tests

    function test_processPendingDeposits_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, REBALANCER_ROLE));
        vm.prank(unauthorized);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);
    }

    function test_processPendingDeposits_paused() external {
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert("SparkPrimeVault/paused");
        vm.prank(rebalancer);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);
    }

    // Success tests

    function test_processPendingDeposits() external {
        vm.prank(admin);
        vault.setCapacity(0);

        uint256 expectedSavingsShares = spUsdc.convertToShares(1_000_000e6);

        _requestDeposit(user1, 1_000_000e6);  // Queued

        assertEq(vault.balanceOf(user1),              0);
        assertEq(vault.pendingDepositSavingsShares(), expectedSavingsShares);
        assertEq(vault.firstPendingDepositId(),       0);

        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.balanceOf(user1),              1_000_000e6 - 1); // Rounding
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),       1);
    }

}

contract ProcessPendingRedeemsTests is AuthorizationTestBase {

    // Failure tests

    function test_processPendingRedeems_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, REBALANCER_ROLE));
        vm.prank(unauthorized);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);
    }

    function test_processPendingRedeems_paused() external {
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert("SparkPrimeVault/paused");
        vm.prank(rebalancer);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);
    }

    // Success tests

    function test_processPendingRedeems() external {
        _requestDeposit(user1, 1_000_000e6);  // Instant fill

        uint256 shares        = vault.balanceOf(user1);
        uint256 savingsShares = spUsdc.balanceOf(address(vault));

        vm.prank(taker);
        vault.take(savingsShares);  // All liquidity leaves the vault

        vm.prank(user1);
        vault.requestRedeem(shares, user1);  // Queued

        assertEq(usdc.balanceOf(user1),        0);
        assertEq(vault.pendingRedeemShares(),  shares);
        assertEq(vault.firstPendingRedeemId(), 0);

        vm.prank(taker);
        spUsdc.transfer(address(vault), savingsShares);  // Liquidity returns

        vm.prank(rebalancer);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(user1),        shares);
        assertEq(vault.totalSupply(),          0);
        assertEq(vault.pendingRedeemShares(),  0);
        assertEq(vault.firstPendingRedeemId(), 1);
    }

}

contract SetRedeemFeeRateTests is AuthorizationTestBase {

    // Failure tests

    function test_setRedeemFeeRate_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, RISK_MANAGER_ROLE));
        vm.prank(unauthorized);
        vault.setRedeemFeeRate(0.005e18);
    }

    function test_setRedeemFeeRate_feeTooHighBoundary() external {
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vm.prank(riskManager);
        vault.setRedeemFeeRate(1);  // Can't set a fee until admin sets the max fee

        vm.prank(riskManager);
        vault.setRedeemFeeRate(0);  // Max is 0 on deployment

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.005e18);

        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vm.prank(riskManager);
        vault.setRedeemFeeRate(0.005e18 + 1);

        vm.prank(riskManager);
        vault.setRedeemFeeRate(0.005e18);
    }

    // Success tests

    function test_setRedeemFeeRate() external {
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.01e18);

        assertEq(vault.redeemFeeRate(), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.RedeemFeeRateSet(0.005e18);

        vm.prank(riskManager);
        vault.setRedeemFeeRate(0.005e18);

        assertEq(vault.redeemFeeRate(), 0.005e18);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.RedeemFeeRateSet(0.01e18);

        vm.prank(riskManager);
        vault.setRedeemFeeRate(0.01e18);

        assertEq(vault.redeemFeeRate(), 0.01e18);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.RedeemFeeRateSet(0);

        vm.prank(riskManager);
        vault.setRedeemFeeRate(0);

        assertEq(vault.redeemFeeRate(), 0);
    }

}

contract RealizeGainTests is AuthorizationTestBase {

    // Failure tests

    function test_realizeGain_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.realizeGain(1);
    }

    function test_realizeGain_invalidGainBoundary() external {
        _requestDeposit(user1, 1_000_000e6);  // Instant fill

        vm.expectRevert("SparkPrimeVault/invalid-gain");
        vm.prank(admin);
        vault.realizeGain(0);

        vm.prank(admin);
        vault.realizeGain(1);
    }

    function test_realizeGain_noShares() external {
        vm.expectRevert("SparkPrimeVault/no-shares");
        vm.prank(admin);
        vault.realizeGain(1);
    }

    // Success tests

    function test_realizeGain() external {
        _requestDeposit(user1, 1_000_000e6);  // Instant fill

        uint256 shares = vault.balanceOf(user1);
        uint256 assets = vault.totalAssets();

        assertEq(shares, 1_000_000e6 - 1);  // Rounding
        assertEq(assets, 1_000_000e6 - 1);  // Rounding

        assertEq(uint256(vault.chi()),  RAY);
        assertEq(vault.totalSupply(),   shares);
        assertEq(vault.assetsOf(user1), assets);

        uint256 expectedChi = ((assets + 100_000e6) * RAY) / shares;

        assertEq(expectedChi, 1.100000000000100000000000100e27);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.GainRealized(uint192(expectedChi), 100_000e6);

        vm.prank(admin);
        vault.realizeGain(100_000e6);

        assertEq(uint256(vault.chi()),  expectedChi);
        assertEq(uint256(vault.rho()),  block.timestamp);
        assertEq(vault.totalSupply(),   shares);
        assertEq(vault.totalAssets(),   (shares * expectedChi) / RAY);
        assertEq(vault.assetsOf(user1), (shares * expectedChi) / RAY);

        assertApproxEqAbs(vault.totalAssets(), assets + 100_000e6, 1);
    }

    function test_realizeGain_dripsFirst() external {
        _requestDeposit(user1, 1_000_000e6);  // Instant fill

        uint256 startAssets = vault.totalAssets();

        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.prank(setter);
        vault.setVSR(FOUR_PCT_VSR);

        skip(365 days);

        uint256 nowChi        = vault.nowChi();
        uint256 accruedAssets = vault.totalAssets();

        assertEq(nowChi, 1.039999999999999999955174055e27);

        uint256 expectedChi = ((accruedAssets + 100_000e6) * RAY) / vault.totalSupply();

        assertEq(expectedChi, 1.139999999999139999999999139e27);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Drip(uint192(nowChi), accruedAssets - startAssets);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.GainRealized(uint192(expectedChi), 100_000e6);

        vm.prank(admin);
        vault.realizeGain(100_000e6);

        assertEq(uint256(vault.chi()), expectedChi);
        assertEq(uint256(vault.rho()), block.timestamp);
        assertEq(vault.totalAssets(),  (vault.totalSupply() * expectedChi) / RAY);

        assertApproxEqAbs(vault.totalAssets(), accruedAssets + 100_000e6, 1);
    }

}

contract RealizeLossTests is AuthorizationTestBase {

    function _pause() internal {
        vm.prank(guardian);
        vault.pause();
    }

    // Failure tests

    function test_realizeLoss_notRiskManager() external {
        vm.expectRevert(_notAuthorized(unauthorized, RISK_MANAGER_ROLE));
        vm.prank(unauthorized);
        vault.realizeLoss(1);
    }

    function test_realizeLoss_notPaused() external {
        _requestDeposit(user1, 1_000_000e6);  // Instant fill

        vm.expectRevert("SparkPrimeVault/not-paused");
        vm.prank(riskManager);
        vault.realizeLoss(1);
    }

    function test_realizeLoss_zeroLoss() external {
        _requestDeposit(user1, 1_000_000e6);  // Instant fill
        _pause();

        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vm.prank(riskManager);
        vault.realizeLoss(0);

        vm.prank(riskManager);
        vault.realizeLoss(1);
    }

    function test_realizeLoss_lossTooHighBoundary() external {
        _requestDeposit(user1, 1_000_000e6);  // Instant fill
        _pause();

        uint256 totalAssets = vault.totalAssets();

        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vm.prank(riskManager);
        vault.realizeLoss(totalAssets);

        vm.prank(riskManager);
        vault.realizeLoss(totalAssets - 1);
    }

    function test_realizeLoss_noShares() external {
        _pause();

        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vm.prank(riskManager);
        vault.realizeLoss(1);
    }

    // Success tests

    function test_realizeLoss() external {
        _requestDeposit(user1, 1_000_000e6);  // Instant fill
        _pause();

        uint256 shares = vault.balanceOf(user1);
        uint256 assets = vault.totalAssets();

        assertEq(shares, 1_000_000e6 - 1);  // Rounding
        assertEq(assets, 1_000_000e6 - 1);  // Rounding

        assertEq(uint256(vault.chi()),  RAY);
        assertEq(vault.totalSupply(),   shares);
        assertEq(vault.assetsOf(user1), assets);

        uint256 expectedChi = ((assets - 100_000e6) * RAY) / shares;

        assertEq(expectedChi, 0.899999999999899999999999899e27);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.LossRealized(uint192(expectedChi), 100_000e6);

        vm.prank(riskManager);
        vault.realizeLoss(100_000e6);

        assertEq(uint256(vault.chi()),  expectedChi);
        assertEq(uint256(vault.rho()),  block.timestamp);
        assertEq(vault.totalSupply(),   shares);
        assertEq(vault.totalAssets(),   (shares * expectedChi) / RAY);
        assertEq(vault.assetsOf(user1), (shares * expectedChi) / RAY);

        assertApproxEqAbs(vault.totalAssets(), assets - 100_000e6, 1);
    }

    function test_realizeLoss_dripsFirst() external {
        _requestDeposit(user1, 1_000_000e6);  // Instant fill

        uint256 startAssets = vault.totalAssets();

        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.prank(setter);
        vault.setVSR(FOUR_PCT_VSR);

        skip(365 days);

        _pause();

        uint256 nowChi        = vault.nowChi();
        uint256 accruedAssets = vault.totalAssets();

        assertEq(nowChi, 1.039999999999999999955174055e27);

        uint256 expectedChi = ((accruedAssets - 100_000e6) * RAY) / vault.totalSupply();

        assertEq(expectedChi, 0.939999999998939999999998939e27);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Drip(uint192(nowChi), accruedAssets - startAssets);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.LossRealized(uint192(expectedChi), 100_000e6);

        vm.prank(riskManager);
        vault.realizeLoss(100_000e6);

        assertEq(uint256(vault.chi()), expectedChi);
        assertEq(uint256(vault.rho()), block.timestamp);
        assertEq(vault.totalAssets(),  (vault.totalSupply() * expectedChi) / RAY);

        assertApproxEqAbs(vault.totalAssets(), accruedAssets - 100_000e6, 1);
    }

}

contract PauseTests is AuthorizationTestBase {

    // Failure tests

    function test_pause_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, GUARDIAN_ROLE));
        vm.prank(unauthorized);
        vault.pause();
    }

    // Success tests

    function test_pause() external {
        _requestDeposit(user1, 1000e6);  // Instant fill

        assertEq(vault.paused(), false);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Paused();

        vm.prank(guardian);
        vault.pause();

        assertEq(vault.paused(), true);
    }

}

contract UnpauseTests is AuthorizationTestBase {

    function setUp() public override {
        super.setUp();

        vm.prank(guardian);
        vault.pause();
    }

    // Failure tests

    function test_unpause_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.unpause();
    }

    function test_unpause_guardianCannotUnpause() external {
        vm.expectRevert(_notAuthorized(guardian, DEFAULT_ADMIN_ROLE));
        vm.prank(guardian);
        vault.unpause();
    }

    // Success tests

    function test_unpause() external {
        assertEq(vault.paused(), true);

        vm.prank(user1);
        usdc.approve(address(vault), 1000e6);

        vm.expectRevert("SparkPrimeVault/paused");
        vm.prank(user1);
        vault.requestDeposit(1000e6, user1);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Unpaused();

        vm.prank(admin);
        vault.unpause();

        assertEq(vault.paused(), false);

        vm.prank(user1);
        vault.requestDeposit(1000e6, user1);  // Instant fill

        assertApproxEqAbs(vault.balanceOf(user1), 1000e6, 1);  // spUSDC rounding
    }

}
