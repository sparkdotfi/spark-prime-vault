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
        vault.grantRole(UNPAUSER_ROLE,     unpauser);
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

    function test_setCapacity_capacityTooHighBoundary() external {
        vm.expectRevert("SparkPrimeVault/capacity-too-high");
        vm.prank(admin);
        vault.setCapacity(uint256(type(uint128).max) + 1);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.CapacitySet(type(uint128).max);

        vm.prank(admin);
        vault.setCapacity(type(uint128).max);
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
        vault.setMaxRedeemFee(0.01e18);
    }

    function test_setMaxRedeemFee_feeTooHighBoundary() external {
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vm.prank(admin);
        vault.setMaxRedeemFee(0.01e18 + 1);

        vm.prank(admin);
        vault.setMaxRedeemFee(0.01e18);  // MAX_REDEEM_FEE is 1%
    }

    // Success tests

    function test_setMaxRedeemFee() external {
        assertEq(vault.maxRedeemFee(), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MaxRedeemFeeSet(0.01e18);

        vm.prank(admin);
        vault.setMaxRedeemFee(0.01e18);

        assertEq(vault.maxRedeemFee(), 0.01e18);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MaxRedeemFeeSet(0);

        vm.prank(admin);
        vault.setMaxRedeemFee(0);

        assertEq(vault.maxRedeemFee(), 0);
    }

}

contract SetMinimumsTests is AuthorizationTestBase {

    // Failure tests

    function test_setMinimums_notAdmin() external {
        vm.expectRevert(_notAuthorized(unauthorized, DEFAULT_ADMIN_ROLE));
        vm.prank(unauthorized);
        vault.setMinimums({ minDeposit_ : 100e6, minWithdraw_ : 50e6 });
    }

    // Success tests

    function test_setMinimums() external {
        assertEq(vault.minDeposit(),  0);
        assertEq(vault.minWithdraw(), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MinimumsSet(100e6, 50e6);

        vm.prank(admin);
        vault.setMinimums({ minDeposit_ : 100e6, minWithdraw_ : 50e6});

        assertEq(vault.minDeposit(),  100e6);
        assertEq(vault.minWithdraw(), 50e6);
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

    function test_take_insufficientUnencumberedSharesBoundary() external {
        uint256 expectedSavingsShares = spUsdc.convertToShares(1_000_000e6);

        _requestDeposit(user1, 1_000_000e6); // Instant fill

        uint256 maxUnencumberedShares = vault.maxRedeemableUnencumberedShares();

        assertEq(maxUnencumberedShares, expectedSavingsShares);

        vm.expectRevert("SparkPrimeVault/insufficient-unencumbered-shares");
        vm.prank(taker);
        vault.take(maxUnencumberedShares + 1);

        vm.prank(taker);
        vault.take(maxUnencumberedShares);
    }

    // Success tests

    function test_take() external {
        uint256 expectedSavingsShares = spUsdc.convertToShares(1_000_000e6);

        _requestDeposit(user1, 1_000_000e6); // Instant fill

        assertEq(spUsdc.balanceOf(address(vault)), expectedSavingsShares);
        assertEq(spUsdc.balanceOf(taker),          0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Take(taker, expectedSavingsShares);

        vm.prank(taker);
        vault.take(expectedSavingsShares);

        assertEq(spUsdc.balanceOf(address(vault)), 0);
        assertEq(spUsdc.balanceOf(taker),          expectedSavingsShares);
    }

}

contract ProcessDepositQueueTests is AuthorizationTestBase {

    // Failure tests

    function test_processDepositQueue_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, REBALANCER_ROLE));
        vm.prank(unauthorized);
        vault.processDepositQueue(type(uint256).max);
    }

    function test_processDepositQueue_paused() external {
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert("SparkPrimeVault/paused");
        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);
    }

    // Success tests

    function test_processDepositQueue() external {
        vm.prank(admin);
        vault.setCapacity(0);

        uint256 expectedSavingsShares = spUsdc.convertToShares(1_000_000e6);

        _requestDeposit(user1, 1_000_000e6);  // Queued

        assertEq(vault.balanceOf(user1),                       0);
        assertEq(vault.sparkVaultSharesEncumberedByDeposits(), expectedSavingsShares);
        assertEq(vault.depositHead(),                          0);

        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.balanceOf(user1),                       1_000_000e6 - 1); // Rounding
        assertEq(vault.sparkVaultSharesEncumberedByDeposits(), 0);
        assertEq(vault.depositHead(),                          1);
    }

}

contract ProcessRedeemQueueTests is AuthorizationTestBase {

    // Failure tests

    function test_processRedeemQueue_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, REBALANCER_ROLE));
        vm.prank(unauthorized);
        vault.processRedeemQueue(type(uint256).max);
    }

    function test_processRedeemQueue_paused() external {
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert("SparkPrimeVault/paused");
        vm.prank(rebalancer);
        vault.processRedeemQueue(type(uint256).max);
    }

    // Success tests

    function test_processRedeemQueue() external {
        _requestDeposit(user1, 1_000_000e6);  // Instant fill

        uint256 shares        = vault.balanceOf(user1);
        uint256 savingsShares = spUsdc.balanceOf(address(vault));

        vm.prank(taker);
        vault.take(savingsShares);  // All liquidity leaves the vault

        vm.prank(user1);
        vault.requestRedeem(shares, user1);  // Queued

        assertEq(usdc.balanceOf(user1),             0);
        assertEq(vault.sharesEncumberedByRedeems(), shares);
        assertEq(vault.redeemHead(),                0);

        deal(address(usdc), address(vault), shares);  // Liquidity returns, chi is RAY

        vm.prank(rebalancer);
        vault.processRedeemQueue(type(uint256).max);

        assertEq(usdc.balanceOf(user1),             shares);
        assertEq(vault.totalSupply(),               0);
        assertEq(vault.sharesEncumberedByRedeems(), 0);
        assertEq(vault.redeemHead(),                1);
    }

}

contract SetRedeemFeeTests is AuthorizationTestBase {

    // Failure tests

    function test_setRedeemFee_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, RISK_MANAGER_ROLE));
        vm.prank(unauthorized);
        vault.setRedeemFee(0.005e18);
    }

    function test_setRedeemFee_feeTooHighBoundary() external {
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vm.prank(riskManager);
        vault.setRedeemFee(1);  // Can't set a fee until admin sets the max fee

        vm.prank(riskManager);
        vault.setRedeemFee(0);  // Max is 0 on deployment

        vm.prank(admin);
        vault.setMaxRedeemFee(0.005e18);

        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vm.prank(riskManager);
        vault.setRedeemFee(0.005e18 + 1);

        vm.prank(riskManager);
        vault.setRedeemFee(0.005e18);
    }

    // Success tests

    function test_setRedeemFee() external {
        vm.prank(admin);
        vault.setMaxRedeemFee(0.01e18);

        assertEq(vault.redeemFee(), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.RedeemFeeSet(0.005e18);

        vm.prank(riskManager);
        vault.setRedeemFee(0.005e18);

        assertEq(vault.redeemFee(), 0.005e18);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.RedeemFeeSet(0.01e18);

        vm.prank(riskManager);
        vault.setRedeemFee(0.01e18);

        assertEq(vault.redeemFee(), 0.01e18);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.RedeemFeeSet(0);

        vm.prank(riskManager);
        vault.setRedeemFee(0);

        assertEq(vault.redeemFee(), 0);
    }

}

contract SetChiTests is AuthorizationTestBase {

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setVSRBounds(RAY, FOUR_PCT_VSR);

        vm.prank(setter);
        vault.setVSR(FOUR_PCT_VSR);
    }

    // Failure tests

    function test_setChi_notAuthorized() external {
        vm.expectRevert(_notAuthorized(unauthorized, RISK_MANAGER_ROLE));
        vm.prank(unauthorized);
        vault.setChi(0.9e27);
    }

    function test_setChi_notPaused() external {
        vm.expectRevert("SparkPrimeVault/not-paused");
        vm.prank(riskManager);
        vault.setChi(0.9e27);

        vm.prank(guardian);
        vault.pause();

        vm.prank(riskManager);
        vault.setChi(0.9e27);
    }

    function test_setChi_invalidChiBoundary() external {
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert("SparkPrimeVault/invalid-chi");
        vm.prank(riskManager);
        vault.setChi(0);

        vm.prank(riskManager);
        vault.setChi(1);
    }

    // Success tests

    function test_setChi() external {
        _requestDeposit(user1, 1_000_000e6);  // Instant fill

        skip(1 days);

        vm.prank(guardian);
        vault.pause();

        uint256 supply = vault.totalSupply();
        uint256 nowChi = vault.nowChi();

        assertEq(nowChi,                 1.000107459782027902551816735e27);
        assertEq(uint256(vault.chi()),   RAY);
        assertEq(uint256(vault.rho()),   block.timestamp - 1 days);
        assertEq(vault.totalAssets(),    supply * nowChi / RAY);
        assertEq(vault.assetsOf(user1),  supply * nowChi / RAY);
        assertEq(vault.balanceOf(user1), supply);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Drip(uint192(nowChi), supply * nowChi / RAY - supply);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.ChiSet(0.9e27);

        vm.prank(riskManager);
        vault.setChi(0.9e27);

        assertEq(uint256(vault.nowChi()), 0.9e27);
        assertEq(uint256(vault.chi()),    0.9e27);
        assertEq(uint256(vault.rho()),    block.timestamp);
        assertEq(vault.totalAssets(),     supply * 0.9e27 / RAY);
        assertEq(vault.assetsOf(user1),   supply * 0.9e27 / RAY);
        assertEq(vault.totalSupply(),     supply);
        assertEq(vault.balanceOf(user1),  supply);

        // Accrual continues from the new chi at the same VSR
        skip(1 days);

        assertEq(uint256(vault.nowChi()), 0.900096713803825112296635061e27);
        assertEq(vault.totalAssets(),     supply * 0.900096713803825112296635061e27 / RAY);
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
        vm.expectRevert(_notAuthorized(unauthorized, UNPAUSER_ROLE));
        vm.prank(unauthorized);
        vault.unpause();
    }

    function test_unpause_guardianCannotUnpause() external {
        vm.expectRevert(_notAuthorized(guardian, UNPAUSER_ROLE));
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

        vm.prank(unpauser);
        vault.unpause();

        assertEq(vault.paused(), false);

        vm.prank(user1);
        vault.requestDeposit(1000e6, user1);  // Instant fill

        assertApproxEqAbs(vault.balanceOf(user1), 1000e6, 1);  // spUSDC rounding
    }

}
