// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import "./TestBase.t.sol";

contract AuthorizationTestBase is TestBase {

    uint256 internal constant ONE_PCT_VSR  = 1.000000000315522921573372069e27;
    uint256 internal constant FOUR_PCT_VSR = 1.000000001243680656318820312e27;

    address internal user1 = makeAddr("user1");

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
    }

    function _notAuthorized(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            account,
            role
        );
    }

    // Deposits `assets` USDC from `user` and returns the shares credited (zero when queued).
    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        uint256 balanceBefore = vault.balanceOf(user);

        deal(address(usdc), user, assets);

        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        vault.requestDeposit(assets, user);
        vm.stopPrank();

        shares = vault.balanceOf(user) - balanceBefore;
    }

}

/**************************************************************************************************/
/*** setCapacity                                                                                ***/
/**************************************************************************************************/

contract SparkPrimeVaultSetCapacityFailureTests is AuthorizationTestBase {

    function test_setCapacity_notAdmin() public {
        vm.expectRevert(_notAuthorized(address(this), DEFAULT_ADMIN_ROLE));
        vault.setCapacity(2_000_000e6);
    }

    function test_setCapacity_capacityTooHighBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/capacity-too-high");
        vault.setCapacity(uint256(type(uint128).max) + 1);

        vault.setCapacity(type(uint128).max);
    }

}

contract SparkPrimeVaultSetCapacitySuccessTests is AuthorizationTestBase {

    function test_setCapacity() public {
        assertEq(vault.maxCapacity(),       1_000_000e6);
        assertEq(vault.availableCapacity(), 1_000_000e6);

        vm.startPrank(admin);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.CapacitySet(2_000_000e6);
        vault.setCapacity(2_000_000e6);

        assertEq(vault.maxCapacity(),       2_000_000e6);
        assertEq(vault.availableCapacity(), 2_000_000e6);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.CapacitySet(type(uint128).max);
        vault.setCapacity(type(uint128).max);

        assertEq(vault.maxCapacity(),       type(uint128).max);
        assertEq(vault.availableCapacity(), type(uint128).max);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.CapacitySet(0);
        vault.setCapacity(0);

        vm.stopPrank();

        assertEq(vault.maxCapacity(),       0);
        assertEq(vault.availableCapacity(), 0);
    }

}

/**************************************************************************************************/
/*** setMaxRedeemFee                                                                            ***/
/**************************************************************************************************/

contract SparkPrimeVaultSetMaxRedeemFeeFailureTests is AuthorizationTestBase {

    function test_setMaxRedeemFee_notAdmin() public {
        vm.expectRevert(_notAuthorized(address(this), DEFAULT_ADMIN_ROLE));
        vault.setMaxRedeemFee(0.01e18);
    }

    function test_setMaxRedeemFee_feeTooHighBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setMaxRedeemFee(0.01e18 + 1);

        vault.setMaxRedeemFee(0.01e18);  // MAX_REDEEM_FEE is 1%
    }

}

contract SparkPrimeVaultSetMaxRedeemFeeSuccessTests is AuthorizationTestBase {

    function test_setMaxRedeemFee() public {
        assertEq(vault.maxRedeemFee(), 0);
        assertEq(vault.redeemFee(),    0);

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MaxRedeemFeeSet(0.01e18);
        vault.setMaxRedeemFee(0.01e18);

        assertEq(vault.maxRedeemFee(), 0.01e18);
        assertEq(vault.redeemFee(),    0);

        vm.prank(riskManager);
        vault.setRedeemFee(0.01e18);

        assertEq(vault.maxRedeemFee(), 0.01e18);
        assertEq(vault.redeemFee(),    0.01e18);

        // Lowering the max fee below the live fee leaves the live fee untouched
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MaxRedeemFeeSet(0.002e18);
        vault.setMaxRedeemFee(0.002e18);

        assertEq(vault.maxRedeemFee(), 0.002e18);
        assertEq(vault.redeemFee(),    0.01e18);

        // The risk manager can only move the live fee down to the new max
        vm.startPrank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFee(0.002e18 + 1);

        vault.setRedeemFee(0.002e18);
        vm.stopPrank();

        assertEq(vault.redeemFee(), 0.002e18);
    }

}

/**************************************************************************************************/
/*** setMinimums                                                                                ***/
/**************************************************************************************************/

contract SparkPrimeVaultSetMinimumsFailureTests is AuthorizationTestBase {

    function test_setMinimums_notAdmin() public {
        vm.expectRevert(_notAuthorized(address(this), DEFAULT_ADMIN_ROLE));
        vault.setMinimums({
            minDeposit_  : 100e6,
            minWithdraw_ : 50e6
        });
    }

}

contract SparkPrimeVaultSetMinimumsSuccessTests is AuthorizationTestBase {

    function test_setMinimums() public {
        assertEq(vault.minDeposit(),  0);
        assertEq(vault.minWithdraw(), 0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.MinimumsSet(100e6, 50e6);
        vm.prank(admin);
        vault.setMinimums({
            minDeposit_  : 100e6,
            minWithdraw_ : 50e6
        });

        assertEq(vault.minDeposit(),  100e6);
        assertEq(vault.minWithdraw(), 50e6);
    }

}

/**************************************************************************************************/
/*** setVSRBounds                                                                               ***/
/**************************************************************************************************/

contract SparkPrimeVaultSetVSRBoundsFailureTests is AuthorizationTestBase {

    function test_setVSRBounds_notAdmin() public {
        vm.expectRevert(_notAuthorized(address(this), DEFAULT_ADMIN_ROLE));
        vault.setVSRBounds(1e27, FOUR_PCT_VSR);
    }

    function test_setVSRBounds_belowRayBoundary() public {
        vm.startPrank(admin);

        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vault.setVSRBounds(1e27 - 1, FOUR_PCT_VSR);

        vault.setVSRBounds(1e27, FOUR_PCT_VSR);

        vm.stopPrank();
    }

    function test_setVSRBounds_aboveMaxVSRBoundary() public {
        uint256 maxVsr = vault.MAX_VSR();

        vm.startPrank(admin);

        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVSRBounds(1e27, maxVsr + 1);

        vault.setVSRBounds(1e27, maxVsr);

        vm.stopPrank();
    }

    function test_setVSRBounds_minVSRGtMaxVSRBoundary() public {
        vm.startPrank(admin);

        vm.expectRevert("SparkPrimeVault/min-vsr-gt-max-vsr");
        vault.setVSRBounds(FOUR_PCT_VSR + 1, FOUR_PCT_VSR);

        vault.setVSRBounds(FOUR_PCT_VSR, FOUR_PCT_VSR);

        vm.stopPrank();
    }

}

contract SparkPrimeVaultSetVSRBoundsSuccessTests is AuthorizationTestBase {

    function test_setVSRBounds() public {
        assertEq(vault.minVSR(), 1e27);
        assertEq(vault.maxVSR(), 1e27);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.VSRBoundsSet(ONE_PCT_VSR, FOUR_PCT_VSR);
        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        assertEq(vault.minVSR(), ONE_PCT_VSR);
        assertEq(vault.maxVSR(), FOUR_PCT_VSR);
    }

}

/**************************************************************************************************/
/*** setVSR                                                                                     ***/
/**************************************************************************************************/

contract SparkPrimeVaultSetVSRFailureTests is AuthorizationTestBase {

    function test_setVSR_notSetter() public {
        vm.expectRevert(_notAuthorized(address(this), SETTER_ROLE));
        vault.setVSR(ONE_PCT_VSR);
    }

    function test_setVSR_belowMinVSRBoundary() public {
        vm.startPrank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vault.setVSR(1e27 - 1);

        vault.setVSR(1e27);  // Min is 1e27 on deployment
        vm.stopPrank();

        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.startPrank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vault.setVSR(ONE_PCT_VSR - 1);

        vault.setVSR(ONE_PCT_VSR);
        vm.stopPrank();
    }

    function test_setVSR_aboveMaxVSRBoundary() public {
        vm.startPrank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVSR(1e27 + 1);  // Can't raise the VSR until admin sets bounds

        vault.setVSR(1e27);  // Max is 1e27 on deployment
        vm.stopPrank();

        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.startPrank(setter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVSR(FOUR_PCT_VSR + 1);

        vault.setVSR(FOUR_PCT_VSR);
        vm.stopPrank();
    }

}

contract SparkPrimeVaultSetVSRSuccessTests is AuthorizationTestBase {

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setVSRBounds(1e27, FOUR_PCT_VSR);
    }

    function test_setVSR() public {
        uint256 deployTimestamp = block.timestamp;

        skip(10 days);

        assertEq(uint256(vault.chi()), 1e27);
        assertEq(uint256(vault.rho()), deployTimestamp);
        assertEq(vault.vsr(),          1e27);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Drip(1e27, 0);
        vm.expectEmit(address(vault));
        emit SparkPrimeVault.VSRSet(FOUR_PCT_VSR);

        vm.prank(setter);
        vault.setVSR(FOUR_PCT_VSR);

        assertEq(uint256(vault.chi()), 1e27);
        assertEq(uint256(vault.rho()), block.timestamp);
        assertEq(vault.vsr(),          FOUR_PCT_VSR);

        assertEq(uint256(vault.nowChi()), 1e27);

        skip(10 days);

        assertGt(uint256(vault.nowChi()), 1e27);
    }

}

/**************************************************************************************************/
/*** take                                                                                       ***/
/**************************************************************************************************/

contract SparkPrimeVaultTakeFailureTests is AuthorizationTestBase {

    function test_take_notTaker() public {
        vm.expectRevert(_notAuthorized(address(this), TAKER_ROLE));
        vault.take(1_000_000e6);
    }

    function test_take_insufficientUnencumberedSharesBoundary() public {
        _deposit(user1, 1_000_000e6);

        uint256 maxShares = vault.maxRedeemableUnencumberedShares();

        assertEq(maxShares, spUsdc.balanceOf(address(vault)));  // spUSDC has enough idle liquidity

        vm.startPrank(taker);
        vm.expectRevert("SparkPrimeVault/insufficient-unencumbered-shares");
        vault.take(maxShares + 1);

        vault.take(maxShares);
        vm.stopPrank();
    }

}

contract SparkPrimeVaultTakeSuccessTests is AuthorizationTestBase {

    function test_take() public {
        _deposit(user1, 1_000_000e6);

        uint256 spShares = spUsdc.balanceOf(address(vault));

        assertGt(spShares,                 0);
        assertEq(spUsdc.balanceOf(taker),  0);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Take(taker, spShares);
        vm.prank(taker);
        vault.take(spShares);

        assertEq(spUsdc.balanceOf(address(vault)), 0);
        assertEq(spUsdc.balanceOf(taker),          spShares);
    }

}

/**************************************************************************************************/
/*** processDepositQueue                                                                        ***/
/**************************************************************************************************/

contract SparkPrimeVaultProcessDepositQueueFailureTests is AuthorizationTestBase {

    function test_processDepositQueue_notRebalancer() public {
        vm.expectRevert(_notAuthorized(address(this), REBALANCER_ROLE));
        vault.processDepositQueue(type(uint256).max);
    }

    function test_processDepositQueue_paused() public {
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert("SparkPrimeVault/paused");
        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);
    }

}

contract SparkPrimeVaultProcessDepositQueueSuccessTests is AuthorizationTestBase {

    function test_processDepositQueue() public {
        vm.prank(admin);
        vault.setCapacity(0);

        _deposit(user1, 1000e6);  // Queued

        uint256 spShares = spUsdc.balanceOf(address(vault));

        assertEq(spShares, 964.193241e6);

        assertEq(vault.balanceOf(user1),                       0);
        assertEq(vault.sparkVaultSharesEncumberedByDeposits(), spShares);
        assertEq(vault.depositHead(),                          0);

        vm.prank(admin);
        vault.setCapacity(1_000_000e6);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max);

        assertEq(vault.balanceOf(user1),                       spUsdc.convertToAssets(spShares));
        assertEq(vault.sparkVaultSharesEncumberedByDeposits(), 0);
        assertEq(vault.depositHead(),                          1);
    }

}

/**************************************************************************************************/
/*** processRedeemQueue                                                                         ***/
/**************************************************************************************************/

contract SparkPrimeVaultProcessRedeemQueueFailureTests is AuthorizationTestBase {

    function test_processRedeemQueue_notRebalancer() public {
        vm.expectRevert(_notAuthorized(address(this), REBALANCER_ROLE));
        vault.processRedeemQueue(type(uint256).max);
    }

    function test_processRedeemQueue_paused() public {
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert("SparkPrimeVault/paused");
        vm.prank(rebalancer);
        vault.processRedeemQueue(type(uint256).max);
    }

}

contract SparkPrimeVaultProcessRedeemQueueSuccessTests is AuthorizationTestBase {

    function test_processRedeemQueue() public {
        uint256 shares   = _deposit(user1, 1000e6);
        uint256 spShares = spUsdc.balanceOf(address(vault));

        vm.prank(taker);
        vault.take(spShares);  // All liquidity leaves the vault

        assertEq(vault.availableLiquidAssets(), 0);

        vm.prank(user1);
        vault.requestRedeem(500e6, user1);  // Queued, nothing can be paid

        assertEq(usdc.balanceOf(user1),             0);
        assertEq(vault.balanceOf(user1),            shares - 500e6);
        assertEq(vault.balanceOf(address(vault)),   500e6);
        assertEq(vault.sharesEncumberedByRedeems(), 500e6);
        assertEq(vault.redeemHead(),                0);

        deal(address(usdc), address(vault), 500e6);  // Liquidity returns

        vm.prank(rebalancer);
        vault.processRedeemQueue(type(uint256).max);

        assertEq(usdc.balanceOf(user1),             500e6);
        assertEq(vault.balanceOf(user1),            shares - 500e6);
        assertEq(vault.balanceOf(address(vault)),   0);
        assertEq(vault.totalSupply(),               shares - 500e6);
        assertEq(vault.sharesEncumberedByRedeems(), 0);
        assertEq(vault.redeemHead(),                1);
    }

}

/**************************************************************************************************/
/*** setRedeemFee                                                                               ***/
/**************************************************************************************************/

contract SparkPrimeVaultSetRedeemFeeFailureTests is AuthorizationTestBase {

    function test_setRedeemFee_notRiskManager() public {
        vm.expectRevert(_notAuthorized(address(this), RISK_MANAGER_ROLE));
        vault.setRedeemFee(0.005e18);
    }

    function test_setRedeemFee_feeTooHighBoundary() public {
        vm.startPrank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFee(1);  // Can't set a fee until admin sets the max fee

        vault.setRedeemFee(0);  // Max is 0 on deployment
        vm.stopPrank();

        vm.prank(admin);
        vault.setMaxRedeemFee(0.005e18);

        vm.startPrank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFee(0.005e18 + 1);

        vault.setRedeemFee(0.005e18);
    }

}

contract SparkPrimeVaultSetRedeemFeeSuccessTests is AuthorizationTestBase {

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setMaxRedeemFee(0.01e18);
    }

    function test_setRedeemFee() public {
        assertEq(vault.redeemFee(), 0);

        vm.startPrank(riskManager);
        vm.expectEmit(address(vault));
        emit SparkPrimeVault.RedeemFeeSet(0.005e18);
        vault.setRedeemFee(0.005e18);

        assertEq(vault.redeemFee(), 0.005e18);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.RedeemFeeSet(0.01e18);
        vault.setRedeemFee(0.01e18);

        assertEq(vault.redeemFee(), 0.01e18);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.RedeemFeeSet(0);
        vault.setRedeemFee(0);

        assertEq(vault.redeemFee(), 0);
    }

}

/**************************************************************************************************/
/*** setChi                                                                                     ***/
/**************************************************************************************************/

contract SparkPrimeVaultSetChiFailureTests is AuthorizationTestBase {

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setVSRBounds(1e27, FOUR_PCT_VSR);

        vm.prank(setter);
        vault.setVSR(FOUR_PCT_VSR);
    }

    function test_setChi_notRiskManager() public {
        vm.expectRevert(_notAuthorized(address(this), RISK_MANAGER_ROLE));
        vault.setChi(0.9e27);
    }

    function test_setChi_notPaused() public {
        vm.expectRevert("SparkPrimeVault/not-paused");
        vm.prank(riskManager);
        vault.setChi(0.9e27);

        vm.prank(guardian);
        vault.pause();

        vm.prank(riskManager);
        vault.setChi(0.9e27);
    }

    function test_setChi_zeroChi() public {
        vm.prank(guardian);
        vault.pause();

        vm.startPrank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-chi");
        vault.setChi(0);

        vault.setChi(1);
        vm.stopPrank();
    }

}

contract SparkPrimeVaultSetChiSuccessTests is AuthorizationTestBase {

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        vault.setVSRBounds(1e27, FOUR_PCT_VSR);

        vm.prank(setter);
        vault.setVSR(FOUR_PCT_VSR);

        _deposit(user1, 1_000_000e6);

        skip(1 days);
    }

    function test_setChi() public {
        vm.prank(guardian);
        vault.pause();

        uint256 supply = vault.totalSupply();
        uint256 nowChi = vault.nowChi();

        assertEq(nowChi,                 1.000107459782027902551816735e27);
        assertEq(uint256(vault.chi()),   1e27);
        assertEq(uint256(vault.rho()),   block.timestamp - 1 days);
        assertEq(vault.totalAssets(),    supply * nowChi / 1e27);
        assertEq(vault.assetsOf(user1),  supply * nowChi / 1e27);
        assertEq(vault.balanceOf(user1), supply);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Drip(uint192(nowChi), supply * nowChi / 1e27 - supply);
        vm.expectEmit(address(vault));
        emit SparkPrimeVault.ChiSet(0.9e27);

        vm.prank(riskManager);
        vault.setChi(0.9e27);

        assertEq(uint256(vault.nowChi()), 0.9e27);
        assertEq(uint256(vault.chi()),    0.9e27);
        assertEq(uint256(vault.rho()),    block.timestamp);
        assertEq(vault.totalAssets(),     supply * 0.9e27 / 1e27);
        assertEq(vault.assetsOf(user1),   supply * 0.9e27 / 1e27);
        assertEq(vault.totalSupply(),     supply);
        assertEq(vault.balanceOf(user1),  supply);

        // Accrual continues from the new chi at the same VSR
        skip(1 days);

        assertEq(uint256(vault.nowChi()), 0.900096713803825112296635061e27);
        assertEq(vault.totalAssets(),     supply * 0.900096713803825112296635061e27 / 1e27);
    }

}

/**************************************************************************************************/
/*** pause                                                                                      ***/
/**************************************************************************************************/

contract SparkPrimeVaultPauseFailureTests is AuthorizationTestBase {

    function test_pause_notGuardian() public {
        vm.expectRevert(_notAuthorized(address(this), GUARDIAN_ROLE));
        vault.pause();
    }

}

contract SparkPrimeVaultPauseSuccessTests is AuthorizationTestBase {

    function setUp() public override {
        super.setUp();

        _deposit(user1, 1000e6);
    }

    function test_pause() public {
        assertEq(vault.paused(), false);

        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Paused();
        vm.prank(guardian);
        vault.pause();

        assertTrue(vault.paused());

        // Requests, cancellations and queue processing are blocked
        vm.startPrank(user1);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(1000e6, user1);

        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestRedeem(100e6, user1);

        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelDepositRequest(0, user1);

        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelRedeemRequest(0, user1);
        vm.stopPrank();

        vm.startPrank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processDepositQueue(type(uint256).max);

        vm.expectRevert("SparkPrimeVault/paused");
        vault.processRedeemQueue(type(uint256).max);
        vm.stopPrank();
    }

}

/**************************************************************************************************/
/*** unpause                                                                                    ***/
/**************************************************************************************************/

contract SparkPrimeVaultUnpauseFailureTests is AuthorizationTestBase {

    function test_unpause_notUnpauser() public {
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert(_notAuthorized(address(this), UNPAUSER_ROLE));
        vault.unpause();
    }

    function test_unpause_guardianCannotUnpause() public {
        vm.startPrank(guardian);
        vault.pause();

        vm.expectRevert(_notAuthorized(guardian, UNPAUSER_ROLE));
        vault.unpause();
        vm.stopPrank();
    }

}

contract SparkPrimeVaultUnpauseSuccessTests is AuthorizationTestBase {

    function test_unpause() public {
        vm.prank(guardian);
        vault.pause();

        assertTrue(vault.paused());

        deal(address(usdc), user1, 1000e6);

        vm.startPrank(user1);

        usdc.approve(address(vault), 1000e6);

        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(1000e6, user1);

        vm.stopPrank();

        vm.prank(unpauser);
        vm.expectEmit(address(vault));
        emit SparkPrimeVault.Unpaused();
        vault.unpause();

        assertFalse(vault.paused());

        vm.prank(user1);
        vault.requestDeposit(1000e6, user1);

        assertApproxEqAbs(vault.balanceOf(user1), 1000e6, 1);  // spUSDC rounding
    }

}
