// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../../lib/forge-std/src/StdError.sol";

import { ERC1967Proxy } from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkPrimeVault } from "../../src/SparkPrimeVault.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

// OZ 5.x refuses an empty-data proxy construction; opt out so `initialize` can be observed.
contract UninitializedERC1967Proxy is ERC1967Proxy {

    constructor(address implementation_) ERC1967Proxy(implementation_, "") {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) { return true; }

}

// Upgrade target used to prove that a drip-overflow brick (G-1) is recoverable only through an
// implementation that writes `chi` without dripping first.
contract SparkPrimeVaultChiRescue is SparkPrimeVault {

    function rescueChi(uint192 chi_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chi = chi_;
        rho = uint64(block.timestamp);
    }

}

/// @dev Setter bounds (what each role can and cannot do once its key is compromised), setter
///      events, `adjustTotalAssets` (round 5: replaces `realizeGain` / `realizeLoss`), `take`,
///      `initialize`, and ERC20/permit basics, on `master` @ 0ebb452.
contract AdminTest is LocalTestBase {

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event DepositCancellationRequest(
        uint256 indexed depositRequestId, uint256 indexed cancelRequestId, address indexed recipient
    );
    event DepositCancellationRecipientUpdated(uint256 indexed requestId, address indexed recipient);
    event DepositRecipientUpdated(uint256 indexed requestId, address indexed recipient);
    event RedeemRecipientUpdated(uint256 indexed requestId, address indexed recipient);
    event Paused();
    event Unpaused();
    event CapacitySet(uint256 capacity);
    event TotalAssetsAdjusted(uint192 chi, int256 deltaTotalAssets);
    event Drip(uint192 chi, uint256 diff);
    event MaxRedeemFeeRateSet(uint256 fee);
    event MinDepositSet(uint256 minDeposit);
    event MinRedeemSet(uint256 minRedeem);
    event Take(uint256 shares);
    event VSRBoundsSet(uint256 minVSR, uint256 maxVSR);
    event VSRSet(uint256 vsr);
    event RedeemFeeRateSet(uint256 fee);
    event ClaimableAssetsIncreased(address indexed recipient, uint256 increase);

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    // `chi` is alone in slot 8 on 0ebb452 (`decimals` + `rho` share slot 7).
    bytes32 constant CHI_SLOT = bytes32(uint256(8));

    // The real bound on chi: `drip()` computes `_rpow(vsr, dt) * chi` in uint256 and
    // `_rpow(RAY, dt) == RAY` for every dt, so with `vsr == RAY` the product overflows once
    // `chi > type(uint256).max / RAY`.
    uint256 constant MAX_DRIP_CHI = type(uint256).max / 1e27;  // 115792089237316195423570985008687907853269984665640

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function _expectedChi(uint256 totalAssets_, uint256 supply_) internal pure returns (uint192) {
        return uint192(totalAssets_ * RAY / supply_);
    }

    /**********************************************************************************************/
    /*** setCapacity                                                                            ***/
    /**********************************************************************************************/

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
        assertEq(vault.firstPendingDepositId(),       0);
    }

    // Capacity below totalSupply: availableCapacity floors at 0, existing shares are untouched,
    // new deposits queue (no revert) and fill once the cap is raised; redeems are unaffected.
    function test_setCapacity_belowTotalSupply() public {
        _deposit(alice, 100e6);
        uint256 supply_ = vault.totalSupply();
        _setCapacity(supply_ - 1);
        assertEq(vault.availableCapacity(), 0);
        assertEq(vault.totalSupply(),       supply_);

        uint256 id_ = _deposit(bob, 50e6);
        (, , uint256 queued_) = _depositRequest(id_);
        assertGt(queued_, 0);
        assertEq(vault.balanceOf(bob), 0);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(bob), 0);

        uint256 redId_ = _requestRedeem(alice, 10e6);
        _processRedeems(type(uint256).max, 10);
        (, , uint256 left_) = _redeemRequest(redId_);
        assertEq(left_, 0);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertGt(vault.balanceOf(bob), 0);
        (, , left_) = _depositRequest(id_);
        assertEq(left_, 0);
    }

    // V2-7 (open): `setCapacity` has no upper bound. At `type(uint256).max` every deposit and
    // every `processPendingDeposits` revert with panic 0x11 in
    // `convertToAssets(availableCapacity())` (:829 -> :793, `availableCapacity * nowChi`).
    // Redeems, cancellations, transfers and the admin surface keep working; a lower cap repairs it.
    function test_BUG_V2_7_setCapacityMaxBricksDeposits() public {
        _deposit(alice, 1_000e6);

        vm.startPrank(admin);
        vault.setCapacity(uint256(type(uint128).max) + 1);
        assertEq(vault.maxCapacity(), uint256(type(uint128).max) + 1);
        vault.setCapacity(type(uint256).max);
        assertEq(vault.maxCapacity(),       type(uint256).max);
        assertEq(vault.availableCapacity(), type(uint256).max - vault.totalSupply());
        vm.stopPrank();

        // Empty queue: the instant-fill walk overflows and the request reverts outright.
        _fund(alice, 200e6);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(100e6, alice, 0);

        // Non-empty queue: new requests are accepted (no walk) but can never be processed.
        _setCapacity(vault.totalSupply());
        uint256 queuedId_ = _deposit(bob, 100e6);
        _setCapacity(type(uint256).max);
        vm.prank(alice);
        uint256 aliceId_ = vault.requestDeposit(100e6, alice, 0);
        (, , uint256 aliceQueued_) = _depositRequest(aliceId_);
        assertGt(aliceQueued_, 0);

        vm.prank(rebalancer);
        vm.expectRevert(stdError.arithmeticError);
        vault.processPendingDeposits(type(uint256).max, 10);
        vm.prank(rebalancer);
        vm.expectRevert(stdError.arithmeticError);
        vault.processPendingDeposits(1, 1);  // maxSavingsShares does not help: overflow is before _min

        // Everything else still works.
        uint256 redId_ = _requestRedeem(alice, 10e6);
        _processRedeems(type(uint256).max, 10);
        (, , uint256 left_) = _redeemRequest(redId_);
        assertEq(left_, 0);
        vm.prank(bob);
        uint256 cancelId_ = vault.requestDepositCancellation(queuedId_, bob);
        _processCancelledDeposits(type(uint256).max, 10);
        (, , left_) = _cancelledDepositRequest(cancelId_);
        assertEq(left_, 0);
        assertEq(usdc.balanceOf(bob), 100e6 - 1);

        // Back inside the bound the vault works again.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        (, , aliceQueued_) = _depositRequest(aliceId_);
        assertEq(aliceQueued_, 0);
        vm.prank(alice);
        vault.requestDeposit(100e6, alice, 0);
        assertGt(vault.balanceOf(alice), 0);
    }

    // V2-7, exact threshold: the first overflow is `availableCapacity() * nowChi()` in
    // `convertToAssets` (:793). The largest working capacity is
    // `totalSupply + type(uint256).max / nowChi()`; one more wei of capacity reverts.
    function test_BUG_V2_7_setCapacityOverflowThresholdExact() public {
        _deposit(alice, 1_000e6);
        uint256 supply_   = vault.totalSupply();
        uint256 chi_      = vault.nowChi();
        uint256 maxAvail_ = type(uint256).max / chi_;
        uint256 maxCap_   = supply_ + maxAvail_;

        _setCapacity(maxCap_ + 1);
        _fund(alice, 200e6);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(100e6, alice, 0);

        _setCapacity(maxCap_);
        assertEq(vault.availableCapacity(), maxAvail_);
        // Both conversions fit: convertToAssets(maxAvail) * RAY <= uint256.max in spUSDC too.
        uint256 assets_ = vault.convertToAssets(maxAvail_);
        assertLe(assets_, type(uint256).max / RAY);
        vm.prank(alice);
        vault.requestDeposit(100e6, alice, 0);
        assertGt(vault.balanceOf(alice), supply_);
    }

    // The real invariant is `availableCapacity() * nowChi() <= type(uint256).max`, so the cap
    // and the index are coupled: with the harness cap of `uint128.max` a gain that lifts chi
    // above `uint256.max / uint128.max` (~3.4e38, far below the uint192 check) bricks deposits
    // the same way while `drip` itself still works. Info for the admin runbook: a large
    // `adjustTotalAssets` gain must be paired with a capacity check.
    function test_setCapacity_coupledWithChi() public {
        _deposit(alice, 1_000e6);
        uint256 supply_      = vault.totalSupply();
        uint256 totalAssets_ = vault.totalAssets();

        uint256 avail_     = vault.availableCapacity();
        uint256 targetChi_ = type(uint256).max / avail_ + 1;  // ~3.4e38
        assertLt(targetChi_, MAX_DRIP_CHI);
        uint256 delta_ = targetChi_ * supply_ / RAY + 1 - totalAssets_;

        _adjustTotalAssetsWhilePaused(int256(delta_));
        uint256 chi_ = uint256(vault.chi());
        assertGe(chi_, targetChi_);
        assertGt(chi_, type(uint256).max / avail_);  // avail * chi overflows
        assertLt(chi_, 3.5e38);

        skip(1);
        vault.drip();  // the index itself is fine

        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(1e6, bob, 0);

        // A smaller capacity restores deposits. At chi ~3.4e38 one USDC is worth
        // 1e6 * 1e27 / 3.4e38 < 1 share: the request fills, the entry is consumed, and bob is
        // minted 0 shares for 1 USDC (zero-share mint, F-4, at an admin-made index).
        _setCapacity(supply_ + 1_000_000e6);
        vm.prank(bob);
        uint256 id_ = vault.requestDeposit(1e6, bob, 0);
        assertEq(vault.firstPendingDepositId(), id_ + 1);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.convertToShares(1e6), 0);
    }

    /**********************************************************************************************/
    /*** setMaxRedeemFeeRate                                                                    ***/
    /**********************************************************************************************/

    function test_setMaxRedeemFeeRate_tooHighBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setMaxRedeemFeeRate(0.01e18 + 1);

        vault.setMaxRedeemFeeRate(0.01e18);
        assertEq(vault.maxRedeemFeeRate(), 0.01e18);
    }

    function test_setMaxRedeemFeeRate() public {
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit MaxRedeemFeeRateSet(0.005e18);
        vault.setMaxRedeemFeeRate(0.005e18);
        assertEq(vault.maxRedeemFeeRate(), 0.005e18);
    }

    // C-7 (open): lowering the max below the current fee leaves the fee above the max; new
    // redeem requests keep paying the old fee until the fee setter sets a new one.
    function test_BUG_C7_setMaxRedeemFeeRate_belowCurrentFeeLeavesFeeAboveMax() public {
        _setRedeemFeeRate(0.01e18);
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.001e18);
        assertEq(vault.redeemFeeRate(),    0.01e18);
        assertEq(vault.maxRedeemFeeRate(), 0.001e18);
        assertGt(vault.redeemFeeRate(),    vault.maxRedeemFeeRate());

        _deposit(alice, 1_000e6);
        uint256 shares_ = vault.balanceOf(alice);
        uint256 id_     = _requestRedeem(alice, shares_);
        (, , uint256 queued_) = _redeemRequest(id_);
        assertEq(shares_ - queued_, (shares_ * 0.01e18 + WAD - 1) / WAD);  // 1% charged

        vm.prank(redeemFeeSetter);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFeeRate(0.01e18);

        // The admin cannot lower the live fee itself.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", admin, REDEEM_FEE_SETTER_ROLE
        ));
        vault.setRedeemFeeRate(0.001e18);

        _setRedeemFeeRate(0.001e18);
        assertEq(vault.redeemFeeRate(), 0.001e18);
    }

    /**********************************************************************************************/
    /*** setMinDeposit / setMinRedeem                                                           ***/
    /**********************************************************************************************/

    function test_setMinDeposit() public {
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit MinDepositSet(10e6);
        vault.setMinDeposit(10e6);
        assertEq(vault.minDeposit(), 10e6);
        assertEq(vault.minRedeem(),  0);
    }

    function test_setMinRedeem() public {
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit MinRedeemSet(20e6);
        vault.setMinRedeem(20e6);
        assertEq(vault.minRedeem(),  20e6);
        assertEq(vault.minDeposit(), 0);
    }

    // C-8 (open): no validation at all. minRedeem = max blocks every redeem request forever
    // (the rebalancer can still process what is already queued).
    function test_BUG_C8_setMinRedeem_noValidation_blocksAllRedeems() public {
        _deposit(alice, 1_000e6);
        uint256 shares_ = vault.balanceOf(alice);
        uint256 id_     = _requestRedeem(alice, 1e6);

        vm.prank(admin);
        vault.setMinRedeem(type(uint256).max);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(shares_ - 1e6, alice);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(1, alice);

        _processRedeems(type(uint256).max, 10);
        (, , uint256 left_) = _redeemRequest(id_);
        assertEq(left_, 0);

        // Only a reset by DEFAULT_ADMIN restores exits.
        _setMinRedeem(0);
        _requestRedeem(alice, shares_ - 1e6);
        assertEq(vault.pendingRedeemShares(), shares_ - 1e6);
    }

    // C-8 (open): minDeposit = max blocks every deposit request.
    function test_BUG_C8_setMinDeposit_noValidation_blocksAllDeposits() public {
        vm.prank(admin);
        vault.setMinDeposit(type(uint256).max);

        _fund(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(1_000e6, alice, 0);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(type(uint256).max - 1, alice, 0);
    }

    // C-8 (open): minDeposit may exceed the whole capacity; every deposit then partially fills
    // and the remainder queues behind an unreachable capacity.
    function test_BUG_C8_setMinDeposit_aboveCapacity() public {
        _setCapacity(100e6);
        _setMinDeposit(1_000e6);

        _fund(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(999e6, alice, 0);

        uint256 id_ = _deposit(alice, 1_000e6);
        (, , uint256 queued_) = _depositRequest(id_);
        assertApproxEqAbs(vault.totalSupply(),    100e6, 2);
        assertApproxEqAbs(vault.balanceOf(alice), 100e6, 2);
        assertLe(vault.availableCapacity(),       2);
        assertGt(queued_,                         0);
    }

    // minDeposit is checked on assets; minRedeem is checked on gross shares (not value).
    function test_setMinimums_boundaries() public {
        _setMinDeposit(100e6);
        _setMinRedeem(50e6);

        _fund(alice, 1_000e6);
        vm.startPrank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(100e6 - 1, alice, 0);
        vault.requestDeposit(100e6, alice, 0);

        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(50e6 - 1, alice);
        vault.requestRedeem(50e6, alice);
        vm.stopPrank();

        assertGt(vault.convertToAssets(50e6), 50e6);
    }

    // minRedeem is gross of the fee: the queued amount can land below the minimum.
    function test_setMinRedeem_grossOfFee() public {
        _setMinRedeem(100e6);
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000e6);

        uint256 id_ = _requestRedeem(alice, 100e6);
        (, , uint256 queued_) = _redeemRequest(id_);
        assertEq(queued_, 99e6);
        assertLt(queued_, vault.minRedeem());
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

    // C-7 (open): bounds may be set so the current vsr is outside them; drip keeps accruing at
    // the old vsr until the vsrSetter moves it. The admin cannot bring it back into range.
    function test_BUG_C7_setVSRBounds_doesNotClampLiveVsr() public {
        _deposit(alice, 1_000e6);
        _setPrimeVsr(TEN_PCT_VSR);

        vm.prank(admin);
        vault.setVSRBounds(RAY, ONE_PCT_VSR);
        assertEq(vault.vsr(), TEN_PCT_VSR);
        assertGt(vault.vsr(), vault.maxVSR());

        uint256 assetsBefore_ = vault.assetsOf(alice);
        _warpAndDrip(365 days);
        uint256 assetsAfter_  = vault.assetsOf(alice);
        // ~10% accrued, far above the 1% ceiling.
        assertGt(assetsAfter_, assetsBefore_ * 109 / 100);
        assertLt(assetsAfter_, assetsBefore_ * 111 / 100);

        vm.prank(vsrSetter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVSR(TEN_PCT_VSR);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", admin, VSR_SETTER_ROLE
        ));
        vault.setVSR(ONE_PCT_VSR);

        _setPrimeVsr(ONE_PCT_VSR);
        assertEq(vault.vsr(), ONE_PCT_VSR);
    }

    /**********************************************************************************************/
    /*** setVSR (VSR_SETTER_ROLE, hot wallet)                                                   ***/
    /**********************************************************************************************/

    function test_setVSR_belowMinVsrBoundary() public {
        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.startPrank(vsrSetter);
        vm.expectRevert("SparkPrimeVault/vsr-too-low");
        vault.setVSR(ONE_PCT_VSR - 1);

        vault.setVSR(ONE_PCT_VSR);
        assertEq(vault.vsr(), ONE_PCT_VSR);
    }

    function test_setVSR_aboveMaxVsrBoundary() public {
        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.startPrank(vsrSetter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        vault.setVSR(FOUR_PCT_VSR + 1);

        vault.setVSR(FOUR_PCT_VSR);
        assertEq(vault.vsr(), FOUR_PCT_VSR);
    }

    // With bounds [RAY, RAY] (deploy default) a compromised vsrSetter cannot move the rate at all.
    function test_setVSR_lockedWhenBoundsEqual() public {
        vm.prank(admin);
        vault.setVSRBounds(RAY, RAY);

        vm.startPrank(vsrSetter);
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

        vm.prank(vsrSetter);
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

        vm.prank(vsrSetter);
        vm.expectEmit(address(vault));
        emit Drip(nChi_, diff_);
        vault.setVSR(RAY);

        assertEq(vault.assetsOf(alice), expected_);
        assertEq(vault.chi(),           nChi_);
    }

    // C-9 (open): MAX_VSR is 100% APY. With the harness bounds a compromised setter doubles the
    // notional in a year while nothing backs it (the backing stays at ~1,000 USDC).
    function test_BUG_C9_setVSR_maxDoublesNotionalInAYear() public {
        _deposit(alice, 1_000e6);
        uint256 before_ = vault.totalAssets();
        _setPrimeVsr(MAX_VSR);
        _warpAndDrip(365 days);
        uint256 after_ = vault.totalAssets();
        assertGe(after_, before_ * 2 - 2);
        assertLe(after_, before_ * 2 + 2);
        assertApproxEqAbs(spUsdc.convertToAssets(_vaultSpUsdc()), 1_000e6, 2);
    }

    /**********************************************************************************************/
    /*** setRedeemFeeRate (REDEEM_FEE_SETTER_ROLE, hot wallet)                                  ***/
    /**********************************************************************************************/

    function test_setRedeemFeeRate_tooHighBoundary() public {
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.005e18);

        vm.startPrank(redeemFeeSetter);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFeeRate(0.005e18 + 1);

        vault.setRedeemFeeRate(0.005e18);
        assertEq(vault.redeemFeeRate(), 0.005e18);
    }

    function test_setRedeemFeeRate_zeroMaxLocksFee() public {
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0);

        vm.startPrank(redeemFeeSetter);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFeeRate(1);
        vault.setRedeemFeeRate(0);
    }

    function test_setRedeemFeeRate() public {
        vm.prank(redeemFeeSetter);
        vm.expectEmit(address(vault));
        emit RedeemFeeRateSet(0.001e18);
        vault.setRedeemFeeRate(0.001e18);
        assertEq(vault.redeemFeeRate(), 0.001e18);
    }

    /**********************************************************************************************/
    /*** adjustTotalAssets (DEFAULT_ADMIN_ROLE, requires paused)                                ***/
    /**********************************************************************************************/

    // :278-295: `require(paused)`, `require(delta != 0)`, `drip()`,
    // `totalAssets_ = int256(totalAssets()) + delta`, `require(totalAssets_ > 0)`,
    // `chi = totalAssets_ * RAY / totalSupply` with `chi != 0` and `chi <= uint192.max`.

    // R3-1 fixed: `adjustTotalAssets` requires the pause, and while paused no deposit or redeem
    // request can be placed around it. `not-paused` is checked before the zero-delta check.
    function test_fixed_R3_1_adjustTotalAssetsRequiresPause() public {
        _deposit(alice, 1_000e6);
        uint192 chi_ = vault.chi();

        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/not-paused");
        vault.adjustTotalAssets(1e6);
        vm.expectRevert("SparkPrimeVault/not-paused");
        vault.adjustTotalAssets(-1e6);
        vm.expectRevert("SparkPrimeVault/not-paused");
        vault.adjustTotalAssets(0);
        vm.stopPrank();
        assertEq(vault.chi(), chi_);

        _pause();
        _fund(bob, 100e6);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(100e6, bob, 0);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestRedeem(1e6, alice);

        _adjustTotalAssets(100e6);
        assertGt(vault.chi(), chi_);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(100e6, bob, 0);
        _unpause();
        vm.prank(bob);
        vault.requestDeposit(100e6, bob, 0);
        // bob did not share in the gain: his shares are priced at the post-gain index.
        assertApproxEqAbs(vault.assetsOf(bob), 100e6, 2);
    }

    function test_adjustTotalAssets_zeroDelta() public {
        _deposit(alice, 1_000e6);
        _pause();
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/delta-total-assets-zero");
        vault.adjustTotalAssets(0);
    }

    // Exact gain formula and event; the write-up is within one wei of the delta.
    function test_adjustTotalAssets_gain() public {
        _deposit(alice, 1_000e6);
        _pause();
        uint256 totalAssets_ = vault.totalAssets();
        uint256 supply_      = vault.totalSupply();
        uint256 before_      = vault.assetsOf(alice);
        uint192 expected_    = _expectedChi(totalAssets_ + 10e6, supply_);
        assertGt(expected_, vault.chi());

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit TotalAssetsAdjusted(expected_, 10e6);
        vault.adjustTotalAssets(10e6);

        assertEq(vault.chi(),           expected_);
        assertEq(vault.assetsOf(alice), vault.balanceOf(alice) * expected_ / RAY);
        assertGe(vault.assetsOf(alice) - before_, 10e6 - 1);
        assertLe(vault.assetsOf(alice) - before_, 10e6);
        assertLe(totalAssets_ + 10e6 - vault.totalAssets(), 1);
        // Backing is untouched: the gain is a bookkeeping write-up, not a transfer in.
        assertApproxEqAbs(spUsdc.convertToAssets(_vaultSpUsdc()), 1_000e6, 2);
    }

    // Exact loss formula and event.
    function test_adjustTotalAssets_loss() public {
        _deposit(alice, 1_000e6);
        _pause();
        uint256 totalAssets_ = vault.totalAssets();
        uint256 supply_      = vault.totalSupply();
        uint256 before_      = vault.assetsOf(alice);
        uint192 expected_    = _expectedChi(totalAssets_ - 10e6, supply_);
        assertLt(expected_, vault.chi());

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit TotalAssetsAdjusted(expected_, -10e6);
        vault.adjustTotalAssets(-10e6);

        assertEq(vault.chi(),           expected_);
        assertEq(vault.assetsOf(alice), vault.balanceOf(alice) * expected_ / RAY);
        assertGe(before_ - vault.assetsOf(alice), 10e6);
        assertLe(before_ - vault.assetsOf(alice), 10e6 + 1);
        assertLe(totalAssets_ - 10e6 - vault.totalAssets(), 1);
        assertApproxEqAbs(spUsdc.convertToAssets(_vaultSpUsdc()), 1_000e6, 2);
    }

    // No time passed: the only log is `TotalAssetsAdjusted`; `rho` is untouched.
    function test_adjustTotalAssets_noDripWhenNoTimePassed() public {
        _deposit(alice, 1_000e6);
        _pause();
        uint64 rho_ = vault.rho();
        vm.prank(admin);
        vm.recordLogs();
        vault.adjustTotalAssets(1e6);
        assertEq(vm.getRecordedLogs().length, 1);
        assertEq(vault.rho(), rho_);
    }

    // `adjustTotalAssets` drips first: vsr accrual during the pause is locked in (`Drip` then
    // `TotalAssetsAdjusted`), the delta lands on the dripped value and `rho` moves.
    function test_adjustTotalAssets_dripsFirst_vsrAccruesDuringPause() public {
        _deposit(alice, 1_000e6);
        _setPrimeVsr(TEN_PCT_VSR);
        _pause();
        uint192 stored_ = vault.chi();
        skip(30 days);
        uint192 dripped_     = vault.nowChi();
        uint256 supply_      = vault.totalSupply();
        uint256 totalAssets_ = vault.totalAssets();  // valued at nowChi
        assertGt(dripped_, stored_);
        assertEq(totalAssets_, supply_ * dripped_ / RAY);

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit Drip(dripped_, totalAssets_ - supply_ * stored_ / RAY);
        vm.expectEmit(address(vault));
        emit TotalAssetsAdjusted(_expectedChi(totalAssets_ - 1e6, supply_), -1e6);
        vault.adjustTotalAssets(-1e6);

        assertEq(vault.chi(), _expectedChi(totalAssets_ - 1e6, supply_));
        assertEq(vault.rho(), block.timestamp);
        assertGt(vault.chi(), stored_);  // the loss is smaller than the accrued interest

        // The pause does not stop accrual afterwards either.
        skip(30 days);
        assertGt(vault.nowChi(), vault.chi());
    }

    // Repeated calls compound through totalAssets().
    function test_adjustTotalAssets_repeated() public {
        _deposit(alice, 1_000e6);
        _pause();
        uint256 supply_ = vault.totalSupply();

        uint192 chi0_ = vault.chi();
        _adjustTotalAssets(-5e6);
        uint192 chi1_ = vault.chi();
        assertEq(chi1_, _expectedChi(supply_ * chi0_ / RAY - 5e6, supply_));
        assertLt(chi1_, chi0_);

        _adjustTotalAssets(5e6);
        uint192 chi2_ = vault.chi();
        assertEq(chi2_, _expectedChi(supply_ * chi1_ / RAY + 5e6, supply_));
        assertGt(chi2_, chi1_);
    }

    // Loss then equal gain (and gain then equal loss) is not the identity: every step floors
    // the new index, so the round trip ends at or below the start. On a 1,000 USDC vault the
    // exact drift is `chi0 - chi2` in [0, 2 * ceil(RAY / supply)].
    function test_adjustTotalAssets_lossGainRoundTripNotIdentity() public {
        _deposit(alice, 1_000e6);
        _pause();
        uint256 supply_ = vault.totalSupply();
        uint192 chi0_   = vault.chi();

        _adjustTotalAssets(-123_456_789);
        _adjustTotalAssets(123_456_789);
        uint192 chi2_ = vault.chi();
        assertLe(chi2_, chi0_);
        assertLe(chi0_ - chi2_, 2 * (RAY / supply_ + 1));

        // Compute the exact drift so it is visible in the report.
        uint256 ta1_ = supply_ * _expectedChi(supply_ * chi0_ / RAY - 123_456_789, supply_) / RAY;
        assertEq(chi2_, _expectedChi(ta1_ + 123_456_789, supply_));

        _adjustTotalAssets(777_777);
        _adjustTotalAssets(-777_777);
        assertLe(vault.chi(), chi2_);
    }

    // Pending redeem shares are escrowed in the vault and still priced by `chi`, so a loss
    // during the pause hits them exactly like any holder; pending deposits are spUSDC shares
    // and are not touched, but they mint more spPRIME shares per USDC afterwards.
    function test_adjustTotalAssets_lossHitsPendingRedeemsNotPendingDeposits() public {
        _deposit(alice, 1_000e6);
        uint256 redId_ = _requestRedeem(alice, 500e6);
        _setCapacity(vault.totalSupply());
        uint256 depId_ = _deposit(bob, 1_000e6);
        (, , uint256 bobSavingsShares_) = _depositRequest(depId_);

        uint256 redeemValueBefore_  = vault.convertToAssets(500e6);
        uint256 depositValueBefore_ = spUsdc.convertToAssets(bobSavingsShares_);
        uint256 totalAssets_        = vault.totalAssets();
        uint256 supply_             = vault.totalSupply();

        _pause();
        _adjustTotalAssets(-int256(totalAssets_ / 2));
        _unpause();
        uint192 newChi_ = vault.chi();
        assertEq(newChi_, _expectedChi(totalAssets_ - totalAssets_ / 2, supply_));

        // Redeem escrow: half the value, exact.
        uint256 redeemValueAfter_ = vault.convertToAssets(500e6);
        assertEq(redeemValueAfter_, 500e6 * newChi_ / RAY);
        assertLt(redeemValueAfter_, redeemValueBefore_ * 51 / 100);
        _processRedeems(type(uint256).max, 10);
        (, , uint256 left_) = _redeemRequest(redId_);
        assertEq(left_, 0);
        assertEq(usdc.balanceOf(alice), redeemValueAfter_);

        // Deposit queue: same USDC value, twice the shares once filled.
        assertEq(spUsdc.convertToAssets(bobSavingsShares_), depositValueBefore_);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(bob), depositValueBefore_ * RAY / newChi_);
        assertGt(vault.balanceOf(bob), 1_900e6);
        assertApproxEqAbs(vault.assetsOf(bob), 1_000e6, 3);
    }

    // Capacity is in shares. After a loss the same share capacity is worth fewer USDC, so a
    // deposit consumes capacity at the new (lower) index: the USD capacity shrinks by the loss.
    function test_adjustTotalAssets_lossShrinksCapacityInUsd() public {
        _deposit(alice, 1_000e6);
        uint256 supply_ = vault.totalSupply();
        _setCapacity(supply_ + 1_000e6);
        uint256 capUsdBefore_ = vault.convertToAssets(vault.availableCapacity());
        assertApproxEqAbs(capUsdBefore_, 1_010e6, 1e6);  // 1,000e6 shares at chi ~1.0098

        uint256 totalAssets_ = vault.totalAssets();
        _adjustTotalAssetsWhilePaused(-int256(totalAssets_ / 2));
        uint192 newChi_ = vault.chi();

        assertEq(vault.availableCapacity(), 1_000e6);  // unchanged in shares
        assertEq(vault.convertToAssets(vault.availableCapacity()), 1_000e6 * newChi_ / RAY);
        assertLt(vault.convertToAssets(vault.availableCapacity()), capUsdBefore_ * 51 / 100);

        // A 1,000 USDC deposit no longer fits: ~505 USDC fill instantly, the rest queues.
        uint256 id_ = _deposit(bob, 1_000e6);
        (, , uint256 queued_) = _depositRequest(id_);
        assertGt(queued_, 0);
        assertLe(vault.availableCapacity(), 10);  // a few wei of share capacity lost to floors
        assertApproxEqAbs(vault.assetsOf(bob), 1_000e6 * newChi_ / RAY, 10);
        assertApproxEqAbs(spUsdc.convertToAssets(queued_), 1_000e6 - 1_000e6 * newChi_ / RAY, 10);
    }

    // C-3 (open): no loss floor. `adjustTotalAssets(-(totalAssets - 1))` is accepted and leaves
    // holders with at most 1 wei in total while the full spUSDC backing stays in the vault and
    // is takeable. `-(totalAssets)` and anything larger revert `loss-too-high`.
    function test_BUG_C3_lossFloorAbsent() public {
        _deposit(alice, 1_000_000e6);
        _pause();
        uint256 totalAssets_ = vault.totalAssets();
        uint256 supply_      = vault.totalSupply();
        assertApproxEqAbs(totalAssets_, 1_000_000e6, 2);

        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/loss-too-high");
        vault.adjustTotalAssets(type(int256).min);
        vm.expectRevert("SparkPrimeVault/loss-too-high");
        vault.adjustTotalAssets(-int256(totalAssets_ + 1));
        vm.expectRevert("SparkPrimeVault/loss-too-high");
        vault.adjustTotalAssets(-int256(totalAssets_));

        vm.expectEmit(address(vault));
        emit TotalAssetsAdjusted(uint192(RAY / supply_), -int256(totalAssets_ - 1));
        vault.adjustTotalAssets(-int256(totalAssets_ - 1));
        vm.stopPrank();

        assertEq(vault.chi(),            uint192(RAY / supply_));
        assertEq(vault.totalAssets(),    supply_ * (RAY / supply_) / RAY);
        assertLe(vault.totalAssets(),    1);
        assertLe(vault.assetsOf(alice),  1);
        assertEq(vault.balanceOf(alice), supply_);  // shares remain, worth nothing

        // Backing is untouched and still takeable in full.
        assertApproxEqAbs(spUsdc.convertToAssets(_vaultSpUsdc()), 1_000_000e6, 2);
        _takeAll();
        assertEq(_vaultSpUsdc(), 0);

        // And a later "gain" of the same size restores the index: the admin alone decides what
        // holders are worth.
        _adjustTotalAssets(int256(totalAssets_ - 1));
        assertApproxEqAbs(vault.totalAssets(), totalAssets_, 2);
    }

    // `chi-too-low` is reachable only once `totalSupply > RAY` (1e21 USDC at 6 decimals): the
    // floor then becomes `totalSupply / RAY` assets rather than 1 wei.
    function test_adjustTotalAssets_chiTooLowOnlyAboveRaySupply() public {
        _deposit(alice, 1.1e27);
        uint256 supply_ = vault.totalSupply();
        assertGt(supply_, RAY);
        _pause();
        uint256 totalAssets_ = vault.totalAssets();

        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/chi-too-low");
        vault.adjustTotalAssets(-int256(totalAssets_ - 1));

        uint256 floor_ = supply_ / RAY + 1;  // smallest totalAssets_ with chi >= 1
        vm.expectRevert("SparkPrimeVault/chi-too-low");
        vault.adjustTotalAssets(-int256(totalAssets_ - (floor_ - 1)));
        vault.adjustTotalAssets(-int256(totalAssets_ - floor_));
        vm.stopPrank();
        assertEq(vault.chi(), 1);
    }

    // `totalSupply == 0`: a positive delta panics with division by zero (:289, the NOTE
    // acknowledges the assumption); a negative delta reverts `loss-too-high` first.
    function test_adjustTotalAssets_zeroSupplyPanics() public {
        assertEq(vault.totalSupply(), 0);
        _pause();

        vm.startPrank(admin);
        vm.expectRevert(stdError.divisionError);
        vault.adjustTotalAssets(1);
        vm.expectRevert(stdError.divisionError);
        vault.adjustTotalAssets(int256(uint256(1e30)));
        vm.expectRevert(stdError.arithmeticError);  // (int256.max) * RAY overflows before the division
        vault.adjustTotalAssets(type(int256).max);
        vm.expectRevert("SparkPrimeVault/loss-too-high");
        vault.adjustTotalAssets(-1);
        vm.stopPrank();
        assertEq(vault.chi(), vault.nowChi());

        // Also after all shares are redeemed.
        _unpause();
        _deposit(alice, 100e6);
        _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.totalSupply(), 0);
        _pause();
        vm.prank(admin);
        vm.expectRevert(stdError.divisionError);
        vault.adjustTotalAssets(1);
    }

    // R4-2 fixed: the `uint192` cast is guarded. The largest accepted index is exactly
    // `type(uint192).max`; the next representable value reverts `chi-too-high` and the index is
    // untouched. (An even larger delta overflows `totalAssets_ * RAY` first: panic 0x11.)
    function test_fixed_R4_2_chiTooHighBoundary() public {
        _deposit(alice, 1_000e6);
        _pause();
        uint256 supply_      = vault.totalSupply();
        uint256 totalAssets_ = vault.totalAssets();
        uint192 chiBefore_   = vault.chi();

        uint256 K_      = uint256(type(uint192).max);
        uint256 taLo_   = K_ * supply_ / RAY;       // floor: chi <= K
        uint256 taHi_   = taLo_ + 1;                // chi > K (granularity RAY/supply = 1e18 here)
        assertLe(taLo_ * RAY / supply_, K_);
        assertGt(taHi_ * RAY / supply_, K_);

        vm.startPrank(admin);
        vm.expectRevert("SparkPrimeVault/chi-too-high");
        vault.adjustTotalAssets(int256(taHi_ - totalAssets_));
        assertEq(vault.chi(), chiBefore_);

        vm.expectRevert(stdError.arithmeticError);  // uint256(totalAssets_) * RAY overflows
        vault.adjustTotalAssets(int256(uint256(1e60)));
        vm.expectRevert(stdError.arithmeticError);  // int256(totalAssets()) + delta overflows
        vault.adjustTotalAssets(type(int256).max);

        vault.adjustTotalAssets(int256(taLo_ - totalAssets_));
        vm.stopPrank();
        assertEq(uint256(vault.chi()), taLo_ * RAY / supply_);
        assertGt(uint256(vault.chi()), K_ - RAY / supply_);
    }

    // G-1 (open), exact threshold: with `vsr == RAY`, `drip()` (:637) and `nowChi()` (:811)
    // compute `_rpow(RAY, dt) * chi == RAY * chi` in uint256, so the largest index that
    // survives a later second is `type(uint256).max / RAY`
    // (= 115792089237316195423570985008687907853269984665640, ~1.158e50). One wei more and
    // every drip reverts with panic 0x11. Both values pass the `chi <= uint192.max` check,
    // which is 54,210,108 times too loose.
    function test_BUG_G1_dripOverflowThresholdExact() public {
        _deposit(alice, 1_000e6);
        assertEq(vault.vsr(), RAY);
        assertEq(MAX_DRIP_CHI, 115792089237316195423570985008687907853269984665640);
        assertLt(MAX_DRIP_CHI, uint256(type(uint192).max));
        assertEq(uint256(type(uint192).max) / MAX_DRIP_CHI, 54_210_108);

        vm.store(address(vault), CHI_SLOT, bytes32(MAX_DRIP_CHI));
        assertEq(uint256(vault.chi()), MAX_DRIP_CHI);
        skip(1);
        assertEq(uint256(vault.nowChi()), MAX_DRIP_CHI);
        assertEq(uint256(vault.drip()),   MAX_DRIP_CHI);
        skip(365 days);
        assertEq(uint256(vault.drip()),   MAX_DRIP_CHI);  // _rpow(RAY, dt) == RAY for every dt

        vm.store(address(vault), CHI_SLOT, bytes32(MAX_DRIP_CHI + 1));
        skip(1);
        vm.expectRevert(stdError.arithmeticError);
        vault.nowChi();
        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
        vm.expectRevert(stdError.arithmeticError);
        vault.totalAssets();
        vm.expectRevert(stdError.arithmeticError);
        vault.assetsOf(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.convertToShares(1);
    }

    // G-1: with `vsr > RAY` the bound is `type(uint256).max / _rpow(vsr, dt)`, i.e. lower
    // still: an index that is safe at `vsr == RAY` reverts one second after the setter moves
    // the rate to MAX_VSR.
    function test_BUG_G1_dripOverflowBoundShrinksWithVsr() public {
        _deposit(alice, 1_000e6);
        vm.store(address(vault), CHI_SLOT, bytes32(MAX_DRIP_CHI));
        _setPrimeVsr(MAX_VSR);  // drips at the same timestamp: no-op
        assertEq(uint256(vault.chi()), MAX_DRIP_CHI);

        skip(1);
        vm.expectRevert(stdError.arithmeticError);
        vault.drip();

        uint256 safe_ = type(uint256).max / MAX_VSR;
        vm.store(address(vault), CHI_SLOT, bytes32(safe_));
        assertEq(uint256(vault.drip()), safe_ * MAX_VSR / RAY);
    }

    // G-1 (open), second bound: `drip()` also computes `totalSupply_ * nChi_` (:640) and every
    // view computes `shares * nowChi` (:793), so the index is additionally bounded by
    // `type(uint256).max / totalSupply`. With 2e27 shares (2e21 USDC) that is ~5.8e49, below
    // the `RAY` bound: `nowChi()` still works but `drip()`, `totalAssets()` and therefore
    // `adjustTotalAssets` (:282, :284) revert. `uint192` catches neither.
    function test_BUG_G1_dripDiffOverflowBoundWithLargeSupply() public {
        _deposit(alice, 2e27);
        uint256 supply_ = vault.totalSupply();
        uint256 bound_  = type(uint256).max / supply_;
        assertLt(bound_, MAX_DRIP_CHI);

        vm.store(address(vault), CHI_SLOT, bytes32(bound_));
        skip(1);
        assertEq(uint256(vault.nowChi()), bound_);
        assertEq(uint256(vault.drip()),   bound_);
        assertEq(vault.totalAssets(),     supply_ * bound_ / RAY);

        vm.store(address(vault), CHI_SLOT, bytes32(bound_ + 1));
        skip(1);
        assertEq(uint256(vault.nowChi()), bound_ + 1);  // the RAY product still fits
        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
        vm.expectRevert(stdError.arithmeticError);
        vault.totalAssets();
        _pause();
        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        vault.adjustTotalAssets(-1);
    }

    // Rounding of a gain: the write-up is short by less than `ceil(totalSupply / RAY)` wei
    // because `chi` is floored. Below `RAY` shares that is at most 1 wei (see the fuzz test);
    // above it a 1-wei "gain" can leave `totalAssets` unchanged while the event still fires.
    function test_adjustTotalAssets_gainRoundingBoundedBySupplyOverRay() public {
        _deposit(alice, 2.2e27);
        uint256 supply_ = vault.totalSupply();
        assertGt(supply_, 2 * RAY);
        _pause();

        uint256 ta_ = vault.totalAssets();
        _adjustTotalAssets(1);
        uint256 after_ = vault.totalAssets();
        assertLe(after_, ta_ + 1);
        assertGe(after_ + supply_ / RAY + 1, ta_ + 1);
        assertEq(vault.chi(), _expectedChi(ta_ + 1, supply_));

        // A gain of ceil(supply / RAY) wei always moves the index.
        uint192 chi_ = vault.chi();
        _adjustTotalAssets(int256(supply_ / RAY + 1));
        assertGt(vault.chi(), chi_);
    }

    // G-1 (open): `adjustTotalAssets` can push the index past the drip bound (the only check is
    // `uint192`). Same block everything works; one second later every path that drips reverts:
    // requests, all three queues, `setVSR`, `drip`, the views, and `adjustTotalAssets` itself
    // (it drips before its own checks, so the admin cannot undo the gain). `take` still works,
    // so the backing can leave while holders cannot. Only an upgrade recovers the vault.
    function test_BUG_G1_adjustTotalAssetsBricksDripAndCannotUndo() public {
        _deposit(alice, 1_000e6);
        uint256 supply_      = vault.totalSupply();
        uint256 totalAssets_ = vault.totalAssets();
        _pause();

        // Smallest delta that lands chi strictly above the drip bound.
        uint256 targetTa_ = (MAX_DRIP_CHI + 1) * supply_ / RAY + 1;
        int256  delta_    = int256(targetTa_ - totalAssets_);
        // ~1.147e32 base units (~1.1e26 USDC) on a 1,000 USDC vault: supply ~9.9e8 shares.
        assertGt(uint256(delta_), 1.1e32);
        assertLt(uint256(delta_), 1.2e32);

        _adjustTotalAssets(delta_);
        assertGt(uint256(vault.chi()), MAX_DRIP_CHI);
        assertLe(uint256(vault.chi()), uint256(type(uint192).max));

        // Same timestamp: drip short-circuits, so the admin could still undo it in-block.
        vault.drip();
        assertEq(vault.totalAssets(), supply_ * vault.chi() / RAY);

        skip(1);

        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
        vm.expectRevert(stdError.arithmeticError);
        vault.nowChi();
        vm.expectRevert(stdError.arithmeticError);
        vault.totalAssets();

        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        vault.adjustTotalAssets(-delta_);
        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        vault.adjustTotalAssets(type(int256).min + 1);

        vm.prank(vsrSetter);
        vm.expectRevert(stdError.arithmeticError);
        vault.setVSR(RAY);

        _unpause();
        _fund(bob, 1e6);
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(1e6, bob, 0);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestRedeem(1e6, alice);
        vm.startPrank(rebalancer);
        vm.expectRevert(stdError.arithmeticError);
        vault.processPendingDeposits(type(uint256).max, 1);
        vm.expectRevert(stdError.arithmeticError);
        vault.processPendingRedeems(type(uint256).max, 1);
        vm.expectRevert(stdError.arithmeticError);
        vault.processPendingDepositCancellations(type(uint256).max, 1);
        vm.stopPrank();

        // Not even `take` is affected, so the backing can still leave; the holders cannot.
        uint256 bal_ = _vaultSpUsdc();
        vm.prank(taker);
        vault.take(bal_);
        assertEq(_vaultSpUsdc(), 0);
        _returnToVault(bal_);

        // Recovery: an upgrade to an implementation that writes `chi` without dripping.
        uint192 chiBefore_ = _expectedChi(totalAssets_, supply_);
        vm.startPrank(admin);
        vault.upgradeToAndCall(
            address(new SparkPrimeVaultChiRescue()),
            abi.encodeCall(SparkPrimeVaultChiRescue.rescueChi, (chiBefore_))
        );
        vm.stopPrank();
        assertEq(vault.chi(), chiBefore_);
        skip(1);
        vault.drip();
        assertApproxEqAbs(vault.totalAssets(), totalAssets_, 1);
        vm.prank(alice);
        vault.requestRedeem(1e6, alice);
        _processRedeems(type(uint256).max, 10);
        assertApproxEqAbs(usdc.balanceOf(alice), 1e6 * uint256(chiBefore_) / RAY, 1);
    }

    // `claimableAssets` is USDC parked in the vault for blacklisted recipients. It is not part
    // of `totalAssets`, so `adjustTotalAssets` neither counts nor touches it, and `take`
    // (spUSDC only) cannot move it either: the exact credit survives a loss, a take, and pays
    // out after de-blacklisting.
    function test_adjustTotalAssets_doesNotTouchClaimableAssets() public {
        _deposit(alice, 1_000e6);
        uint256 ta0_    = vault.totalAssets();
        uint256 assets_ = vault.convertToAssets(100e6);
        vm.prank(alice);
        vault.requestRedeem(100e6, bob);
        _blacklist(bob);
        vm.expectEmit(address(vault));
        emit ClaimableAssetsIncreased(bob, assets_);
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.claimableAssets(bob),      assets_);
        assertEq(usdc.balanceOf(address(vault)),  assets_);
        uint256 totalAssets_ = vault.totalAssets();
        assertApproxEqAbs(ta0_ - totalAssets_, assets_, 1);  // the ~100.98 USDC of claimable are excluded
        assertEq(totalAssets_, vault.convertToAssets(vault.totalSupply()));

        _adjustTotalAssetsWhilePaused(-int256(totalAssets_ / 2));
        assertEq(vault.claimableAssets(bob),     assets_);
        assertEq(usdc.balanceOf(address(vault)), assets_);

        _takeAll();
        assertEq(usdc.balanceOf(address(vault)), assets_);

        _unblacklist(bob);
        vault.claim(bob);
        assertEq(usdc.balanceOf(bob),            assets_);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // `take` during the pause does not change the index or the effect of `adjustTotalAssets`:
    // the notional is bookkeeping, the backing is separate.
    function test_adjustTotalAssets_takeDuringPauseIsIndependent() public {
        _deposit(alice, 1_000e6);
        _pause();
        uint256 totalAssets_ = vault.totalAssets();
        uint256 supply_      = vault.totalSupply();
        _takeAll();
        assertEq(vault.totalAssets(), totalAssets_);
        _adjustTotalAssets(10e6);
        assertEq(vault.chi(), _expectedChi(totalAssets_ + 10e6, supply_));
        assertEq(_vaultSpUsdc(), 0);
    }

    // R3-1 residual (info): the admin's payload is public before the guardian pauses. A deposit
    // that lands between "payload public" and `pause` captures its pro-rata share of the gain
    // and can queue a redeem right after the unpause. alice and bob hold equal shares: bob's
    // last-minute deposit takes 50e6 of a 100e6 gain earned before he arrived.
    function test_adjustTotalAssets_depositBeforePauseCapturesGain() public {
        _deposit(alice, 1_000e6);
        uint256 aliceBefore_ = vault.assetsOf(alice);

        _deposit(bob, 1_000e6);
        assertApproxEqAbs(vault.balanceOf(bob), vault.balanceOf(alice), 1);

        _adjustTotalAssetsWhilePaused(100e6);

        uint256 aliceGain_ = vault.assetsOf(alice) - aliceBefore_;
        uint256 bobGain_   = vault.assetsOf(bob) - 1_000e6;
        assertApproxEqAbs(aliceGain_, 50e6, 2);
        assertApproxEqAbs(bobGain_,   50e6, 2);

        uint256 bobShares_ = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(bobShares_, bob);
        _processRedeems(type(uint256).max, 10);
        assertApproxEqAbs(usdc.balanceOf(bob), 1_050e6, 3);
    }

    // For every accepted delta: chi == floor((totalAssets + delta) * RAY / totalSupply),
    // the notional moves by delta within one wei, a loss never raises and a gain never lowers
    // the index, and the backing never moves.
    function testFuzz_adjustTotalAssets_exactFormula(uint256 deposit_, int256 delta_) public {
        deposit_ = bound(deposit_, 2, 1_000_000_000e6);
        _deposit(alice, deposit_);
        _pause();
        uint256 totalAssets_ = vault.totalAssets();
        uint256 supply_      = vault.totalSupply();
        vm.assume(totalAssets_ > 1);
        delta_ = bound(delta_, -int256(totalAssets_ - 1), int256(uint256(1e30)));
        vm.assume(delta_ != 0);
        uint256 backing_ = _vaultSpUsdc();

        uint192 chiBefore_ = vault.chi();
        uint256 newTa_     = uint256(int256(totalAssets_) + delta_);
        _adjustTotalAssets(delta_);

        assertEq(vault.chi(), _expectedChi(newTa_, supply_));
        assertGt(vault.chi(), 0);
        assertGe(vault.totalAssets() + 1, newTa_);
        assertLe(vault.totalAssets(),     newTa_);
        if (delta_ < 0) assertLt(vault.chi(), chiBefore_);
        else            assertGe(vault.chi(), chiBefore_);
        assertEq(_vaultSpUsdc(), backing_);
    }

    /**********************************************************************************************/
    /*** Request events: exact signatures and values                                            ***/
    /**********************************************************************************************/

    function test_requestDepositCancellation_eventExact() public {
        _deposit(alice, 1_000e6);
        _setCapacity(vault.totalSupply());
        uint256 id1_ = _deposit(bob, 100e6);
        uint256 id2_ = _deposit(bob, 50e6);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true, address(vault));
        emit DepositCancellationRequest(id2_, 0, bob);
        uint256 c0_ = vault.requestDepositCancellation(id2_, bob);
        assertEq(c0_, 0);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true, address(vault));
        emit DepositCancellationRequest(id1_, 1, alice);
        uint256 c1_ = vault.requestDepositCancellation(id1_, alice);
        assertEq(c1_, 1);
    }

    function test_updateRecipient_eventsExact() public {
        _deposit(alice, 1_000e6);
        uint256 redId_ = _requestRedeem(alice, 100e6);
        _setCapacity(vault.totalSupply());
        uint256 depId_  = _deposit(bob, 100e6);
        uint256 dep2Id_ = _deposit(bob, 50e6);
        vm.prank(bob);
        uint256 cancelId_ = vault.requestDepositCancellation(dep2Id_, bob);

        address payout_ = makeAddr("payout");

        vm.prank(bob);
        vm.expectEmit(true, true, true, true, address(vault));
        emit DepositRecipientUpdated(depId_, payout_);
        vault.updateDepositRecipient(depId_, payout_);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true, address(vault));
        emit DepositCancellationRecipientUpdated(cancelId_, payout_);
        vault.updateDepositCancellationRecipient(cancelId_, payout_);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(vault));
        emit RedeemRecipientUpdated(redId_, payout_);
        vault.updateRedeemRecipient(redId_, payout_);
    }

    // `pause` / `unpause` emit argument-less events; nothing else is logged.
    function test_pauseUnpause_eventsExact() public {
        vm.prank(guardian);
        vm.recordLogs();
        vault.pause();
        assertEq(vm.getRecordedLogs().length, 1);

        vm.prank(guardian);
        vm.expectEmit(address(vault));
        emit Paused();
        vault.pause();

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit Unpaused();
        vault.unpause();
    }

    /**********************************************************************************************/
    /*** take (TAKER_ROLE)                                                                      ***/
    /**********************************************************************************************/

    function test_take_insufficientBalanceBoundary() public {
        _deposit(alice, 1_000e6);
        uint256 bal_ = _vaultSpUsdc();

        vm.startPrank(taker);
        vm.expectRevert("SparkPrimeVault/insufficient-shares");
        vault.take(bal_ + 1);

        vault.take(bal_);
        assertEq(_vaultSpUsdc(),          0);
        assertEq(spUsdc.balanceOf(taker), bal_);
    }

    function test_take_zero() public {
        vm.prank(taker);
        vm.expectEmit(address(vault));
        emit Take(0);
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
        emit Take(bal_ / 3);
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

    // F-2 (known): take ignores pendingDepositSavingsShares and
    // pendingCancelledDepositSavingsShares. The cancel itself succeeds, the settlement then pays
    // nothing because the vault holds no spUSDC (no revert, the refund just waits).
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
        uint256 cancelId_ = vault.requestDepositCancellation(id_, alice);
        assertEq(vault.pendingCancelledDepositSavingsShares(), queued_);

        _processCancelledDeposits(type(uint256).max, 10);
        (, , uint256 left_) = _cancelledDepositRequest(cancelId_);
        assertEq(left_,                   queued_);
        assertEq(usdc.balanceOf(alice),   0);
        assertEq(vault.firstPendingDepositCancellationId(), 0);
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
        assertEq(fresh_.asset(),    address(0));
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
        assertEq(fresh_.savings(),          address(spUsdc));
        assertEq(fresh_.asset(),            address(usdc));
        assertEq(fresh_.asset(),            spUsdc.asset());
        assertEq(fresh_.name(),             "Spark Prime USDC");
        assertEq(fresh_.symbol(),           "spPRIME");
        assertEq(fresh_.decimals(),         6);
        assertEq(fresh_.decimals(),         usdc.decimals());
        assertEq(fresh_.chi(),              RAY);
        assertEq(fresh_.rho(),              block.timestamp);
        assertEq(fresh_.vsr(),              RAY);
        assertEq(fresh_.minVSR(),           RAY);
        assertEq(fresh_.maxVSR(),           RAY);
        assertEq(fresh_.maxCapacity(),      0);
        assertEq(fresh_.minDeposit(),       0);
        assertEq(fresh_.minRedeem(),        0);
        assertEq(fresh_.redeemFeeRate(),    0);
        assertEq(fresh_.maxRedeemFeeRate(), 0);
        assertEq(fresh_.totalSupply(),      0);
        assertEq(fresh_.paused(),           false);
        assertEq(fresh_.version(),          "1");
        assertEq(fresh_.pendingDepositSavingsShares(),          0);
        assertEq(fresh_.pendingCancelledDepositSavingsShares(), 0);
        assertEq(fresh_.pendingRedeemShares(),                  0);
        assertEq(fresh_.firstPendingDepositId(),                0);
        assertEq(fresh_.firstPendingDepositCancellationId(),    0);
        assertEq(fresh_.firstPendingRedeemId(),                 0);
        assertEq(fresh_.getPendingDepositRequests().length,             0);
        assertEq(fresh_.getPendingDepositCancellationRequests().length, 0);
        assertEq(fresh_.getPendingRedeemRequests().length,              0);
        assertEq(usdc.allowance(address(fresh_), address(spUsdc)), type(uint256).max);

        assertTrue(fresh_.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertEq(fresh_.getRoleMemberCount(DEFAULT_ADMIN_ROLE),      1);
        assertEq(fresh_.getRoleMember(DEFAULT_ADMIN_ROLE, 0),        admin);
        assertEq(fresh_.getRoleMemberCount(GUARDIAN_ROLE),           0);
        assertEq(fresh_.getRoleMemberCount(REBALANCER_ROLE),         0);
        assertEq(fresh_.getRoleMemberCount(REDEEM_FEE_SETTER_ROLE),  0);
        assertEq(fresh_.getRoleMemberCount(TAKER_ROLE),              0);
        assertEq(fresh_.getRoleMemberCount(VSR_SETTER_ROLE),         0);

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        fresh_.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);
    }

    // Fresh deployment defaults: capacity 0 and maxRedeemFee 0 mean deposits queue and the fee
    // is locked at 0 until the admin configures them; VSR is locked at RAY.
    function test_initialize_defaultsAreSafe() public {
        SparkPrimeVault fresh_ = _freshProxy();
        fresh_.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);
        vm.startPrank(admin);
        fresh_.grantRole(VSR_SETTER_ROLE,        vsrSetter);
        fresh_.grantRole(REDEEM_FEE_SETTER_ROLE, redeemFeeSetter);
        vm.stopPrank();

        vm.prank(vsrSetter);
        vm.expectRevert("SparkPrimeVault/vsr-too-high");
        fresh_.setVSR(RAY + 1);

        vm.prank(redeemFeeSetter);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        fresh_.setRedeemFeeRate(1);

        assertEq(fresh_.availableCapacity(), 0);
    }

    // V2-8 (open): `initialize` does not guard against admin == address(0).
    function test_BUG_V2_8_initialize_zeroAdminNotGuarded() public {
        SparkPrimeVault fresh_ = _freshProxy();
        fresh_.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", address(0));

        assertTrue(fresh_.hasRole(DEFAULT_ADMIN_ROLE, address(0)));
        assertEq(fresh_.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(fresh_.getRoleMember(DEFAULT_ADMIN_ROLE, 0),   address(0));
        assertFalse(fresh_.hasRole(DEFAULT_ADMIN_ROLE, admin));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", admin, DEFAULT_ADMIN_ROLE
        ));
        fresh_.setCapacity(1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", admin, DEFAULT_ADMIN_ROLE
        ));
        fresh_.grantRole(GUARDIAN_ROLE, admin);  // No guardian can ever be appointed either
    }

    /**********************************************************************************************/
    /*** ERC20 basics                                                                           ***/
    /**********************************************************************************************/

    function test_erc20_metadata() public view {
        assertEq(vault.name(),     "Spark Prime USDC");
        assertEq(vault.symbol(),   "spPRIME");
        assertEq(vault.decimals(), 6);
        assertEq(vault.version(),  "1");
        assertEq(vault.asset(),    address(usdc));
        assertEq(vault.savings(),  address(spUsdc));
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

    // Round 5: transfers to the zero address and to the vault itself are rejected (the vault
    // balance is the redeem escrow; stray transfers would corrupt `pendingRedeemShares`).
    function test_transfer_invalidAddress() public {
        _deposit(alice, 1_000e6);
        vm.startPrank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transfer(address(0), 1);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transfer(address(vault), 1);
        vault.approve(alice, type(uint256).max);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transferFrom(alice, address(0), 1);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transferFrom(alice, address(vault), 1);
        vm.stopPrank();
        assertEq(vault.balanceOf(address(vault)), 0);
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

    // The balance check runs before the allowance check.
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

        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.transferFrom(alice, bob, 1);  // no allowance either: balance is checked first
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

    // A failed permit rolls the nonce increment back with the revert.
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
