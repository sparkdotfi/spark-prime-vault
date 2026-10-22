// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../../lib/forge-std/src/StdError.sol";

import { ERC1967Proxy }   from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "../../lib/oz/contracts/access/IAccessControl.sol";
import { Initializable }  from "../../lib/oz/contracts/proxy/utils/Initializable.sol";
import { IERC20 }         from "../../lib/oz/contracts/token/ERC20/IERC20.sol";

import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../src/SparkPrimeVault.sol";

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
///      events, `adjustTotalAssets` (round 6: LOSS_MANAGER_ROLE, a hot wallet), `take`,
///      `initialize` with non-zero minimums, and ERC20/permit basics, on `master` @ c512609.
contract AdminTest is LocalTestBase {

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    // c512609 storage: slot 7 packs `rho` (uint64, offset 0) and `chi` (uint192, offset 8).
    bytes32 constant RHO_CHI_SLOT = bytes32(uint256(7));

    // The real bound on chi: `drip()` computes `_rpow(vsr, dt) * chi` in uint256 and
    // `_rpow(RAY, dt) == RAY` for every dt, so with `vsr == RAY` the product overflows once
    // `chi > type(uint256).max / RAY`.
    uint256 constant MAX_DRIP_CHI = type(uint256).max / 1e27;  // 115792089237316195423570985008687907853269984665640

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function _expectedChi(uint256 totalAssets_, uint256 supply_) internal pure returns (uint192) {
        return uint192(totalAssets_ * RAY / supply_);
    }

    function _notAuthorized(address account_, bytes32 role_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            account_,
            role_
        );
    }

    /// @dev Writes `chi` directly, preserving the packed `rho`.
    function _storeChi(uint256 chi_) internal {
        uint64 rho_ = uint64(uint256(vm.load(address(vault), RHO_CHI_SLOT)));
        vm.store(address(vault), RHO_CHI_SLOT, bytes32((chi_ << 64) | uint256(rho_)));
        assertEq(uint256(vault.chi()), chi_);
        assertEq(vault.rho(),          rho_);
    }

    /**********************************************************************************************/
    /*** setCapacity (OPERATOR_ROLE, hot wallet)                                                ***/
    /**********************************************************************************************/

    function test_setCapacity() public {
        vm.startPrank(operator);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.CapacitySet(1_000_000e6);
        vault.setCapacity(1_000_000e6);
        assertEq(vault.maxCapacity(),       1_000_000e6);
        assertEq(vault.availableCapacity(), 1_000_000e6);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.CapacitySet(0);
        vault.setCapacity(0);
        assertEq(vault.maxCapacity(),       0);
        assertEq(vault.availableCapacity(), 0);
        vm.stopPrank();
    }

    // No bounds at all: any value is accepted and `availableCapacity` floors at zero.
    function testFuzz_setCapacity(uint256 deposit_, uint256 capacity_) public {
        deposit_ = bound(deposit_, 1, 1_000_000_000e6);
        _deposit(alice, deposit_);
        uint256 supply_ = vault.totalSupply();

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.CapacitySet(capacity_);
        vm.prank(operator);
        vault.setCapacity(capacity_);

        assertEq(vault.maxCapacity(), capacity_);
        assertEq(vault.availableCapacity(), capacity_ > supply_ ? capacity_ - supply_ : 0);
        assertEq(vault.totalSupply(), supply_);
    }

    // Capacity 0 is allowed: deposits are accepted into the queue but nothing is minted.
    function test_setCapacity_zeroFreezesMinting() public {
        _setCapacity(0);
        uint256 id_ = _deposit(alice, 100e6);
        ( , , uint256 queued_ ) = _depositRequest(id_);
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
        ( , , uint256 queued_ ) = _depositRequest(id_);
        assertGt(queued_, 0);
        assertEq(vault.balanceOf(bob), 0);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(bob), 0);

        uint256 redId_ = _requestRedeem(alice, 10e6);
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), redId_ + 1);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertGt(vault.balanceOf(bob), 0);
        assertEq(vault.firstPendingDepositId(), id_ + 1);
    }

    // Capacity can be lowered or raised while paused by the operator alone.
    function test_setCapacity_whilePaused() public {
        _pause();
        _setCapacity(5);
        assertEq(vault.maxCapacity(), 5);
        assertTrue(vault.paused());
    }

    // V2-7 (open): `setCapacity` has no upper bound. At `type(uint256).max` every deposit and
    // every `processPendingDeposits` revert with panic 0x11 in
    // `convertToAssets(availableCapacity())` (:864 -> :828, `availableCapacity * nowChi`).
    // Redeems, cancellations, transfers and the admin surface keep working; a lower cap repairs
    // it. Round 6: the key that can do this is now the operator hot wallet.
    function test_BUG_V2_7_setCapacityMaxBricksDeposits() public {
        _deposit(alice, 1_000e6);

        vm.startPrank(operator);
        vault.setCapacity(uint256(type(uint128).max) + 1);
        assertEq(vault.maxCapacity(), uint256(type(uint128).max) + 1);
        vault.setCapacity(type(uint256).max);
        assertEq(vault.maxCapacity(),       type(uint256).max);
        assertEq(vault.availableCapacity(), type(uint256).max - vault.totalSupply());
        vm.stopPrank();

        // Empty queue: the instant-fill walk overflows and the request reverts outright.
        _fund(alice, 200e6);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(alice);
        vault.requestDeposit(100e6, alice, 0);

        // Non-empty queue: new requests are accepted (no walk) but can never be processed.
        _setCapacity(vault.totalSupply());
        uint256 queuedId_ = _deposit(bob, 100e6);
        _setCapacity(type(uint256).max);
        vm.prank(alice);
        uint256 aliceId_ = vault.requestDeposit(100e6, alice, 0);
        ( , , uint256 aliceQueued_ ) = _depositRequest(aliceId_);
        assertGt(aliceQueued_, 0);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(operator);
        vault.processPendingDeposits(type(uint256).max, 10);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(operator);
        vault.processPendingDeposits(1, 1);  // maxSavingsShares does not help: overflow is before _min

        // Everything else still works.
        uint256 redId_ = _requestRedeem(alice, 10e6);
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), redId_ + 1);
        // A cancel also walks `_processPendingDeposits(0, max)` and overflows the same way.
        ( , , uint256 bobQueued_ ) = _depositRequest(queuedId_);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(bob);
        vault.requestDepositCancellation(queuedId_, bob, bobQueued_);

        // Back inside the bound the vault works again.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(), aliceId_ + 1);
        vm.prank(alice);
        vault.requestDeposit(100e6, alice, 0);
        assertGt(vault.balanceOf(alice), 0);
    }

    // V2-7, exact threshold: the first overflow is `availableCapacity() * nowChi()` in
    // `convertToAssets` (:828). The largest working capacity is
    // `totalSupply + type(uint256).max / nowChi()`; one more wei of capacity reverts.
    function test_BUG_V2_7_setCapacityOverflowThresholdExact() public {
        _deposit(alice, 1_000e6);
        uint256 supply_   = vault.totalSupply();
        uint256 chi_      = vault.nowChi();
        uint256 maxAvail_ = type(uint256).max / chi_;
        uint256 maxCap_   = supply_ + maxAvail_;

        _setCapacity(maxCap_ + 1);
        _fund(alice, 200e6);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(alice);
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
    // the same way while `drip` itself still works. Info for the runbook: a large
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
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(bob);
        vault.requestDeposit(1e6, bob, 0);

        // A smaller capacity restores deposits. At chi ~3.4e38 one USDC is worth
        // 1e6 * 1e27 / 3.4e38 < 1 share: the request fills, the entry is consumed, and bob is
        // minted 0 shares for 1 USDC (zero-share mint, R5-15, at a loss-manager-made index).
        _setCapacity(supply_ + 1_000_000e6);
        vm.prank(bob);
        uint256 id_ = vault.requestDeposit(1e6, bob, 0);
        assertEq(vault.firstPendingDepositId(), id_ + 1);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.convertToShares(1e6), 0);
    }

    /**********************************************************************************************/
    /*** setMaxRedeemFeeRate (DEFAULT_ADMIN_ROLE)                                               ***/
    /**********************************************************************************************/

    function test_setMaxRedeemFeeRate_maxFeeTooHighBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert(ISparkPrimeVault.MaxFeeTooHigh.selector);
        vault.setMaxRedeemFeeRate(0.01e18 + 1);

        vault.setMaxRedeemFeeRate(0.01e18);
        assertEq(vault.maxRedeemFeeRate(), 0.01e18);
        vm.stopPrank();
    }

    function test_setMaxRedeemFeeRate() public {
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.MaxRedeemFeeRateSet(0.005e18);
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.005e18);
        assertEq(vault.maxRedeemFeeRate(), 0.005e18);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.MaxRedeemFeeRateSet(0);
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0);
        assertEq(vault.maxRedeemFeeRate(), 0);
    }

    function testFuzz_setMaxRedeemFeeRate(uint256 feeRate_) public {
        if (feeRate_ > 0.01e18) {
            vm.expectRevert(ISparkPrimeVault.MaxFeeTooHigh.selector);
            vm.prank(admin);
            vault.setMaxRedeemFeeRate(feeRate_);
            assertEq(vault.maxRedeemFeeRate(), 0.01e18);
            return;
        }
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.MaxRedeemFeeRateSet(feeRate_);
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(feeRate_);
        assertEq(vault.maxRedeemFeeRate(), feeRate_);
        assertEq(vault.redeemFeeRate(),    0);  // never touched
    }

    // C-7 (open): lowering the max below the current fee leaves the fee above the max; new
    // redeem requests keep paying the old fee until the fee setter sets a new one. The admin
    // cannot lower the live fee itself.
    function test_BUG_C7_setMaxRedeemFeeRate_belowCurrentFeeLeavesFeeAboveMax() public {
        _setRedeemFeeRate(0.01e18);
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.001e18);
        assertEq(vault.redeemFeeRate(),    0.01e18);
        assertEq(vault.maxRedeemFeeRate(), 0.001e18);
        assertGt(vault.redeemFeeRate(),    vault.maxRedeemFeeRate());

        _deposit(alice, 1_000e6);
        uint256 shares_ = vault.balanceOf(alice);
        uint256 fee_    = (shares_ * 0.01e18 + WAD - 1) / WAD;  // 1% charged, rounded up
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRequest(0, alice, alice, shares_, fee_);
        uint256 id_ = _requestRedeem(alice, shares_);
        ( , , uint256 queued_ ) = _redeemRequest(id_);
        assertEq(shares_ - queued_, fee_);

        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.01e18);

        vm.expectRevert(_notAuthorized(admin, REDEEM_FEE_SETTER_ROLE));
        vm.prank(admin);
        vault.setRedeemFeeRate(0.001e18);

        _setRedeemFeeRate(0.001e18);
        assertEq(vault.redeemFeeRate(), 0.001e18);
    }

    /**********************************************************************************************/
    /*** setMinDeposit / setMinDepositCancellation / setMinRedeem (DEFAULT_ADMIN_ROLE)          ***/
    /**********************************************************************************************/

    function test_setMinDeposit_zeroMinDeposit() public {
        vm.expectRevert(ISparkPrimeVault.ZeroMinDeposit.selector);
        vm.prank(admin);
        vault.setMinDeposit(0);
        assertEq(vault.minDeposit(), MIN_DEPOSIT);
    }

    function test_setMinDeposit() public {
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.MinDepositSet(10e6);
        vm.prank(admin);
        vault.setMinDeposit(10e6);
        assertEq(vault.minDeposit(),             10e6);
        assertEq(vault.minDepositCancellation(), MIN_DEPOSIT_CANCELLATION);
        assertEq(vault.minRedeem(),              MIN_REDEEM);
    }

    function testFuzz_setMinDeposit(uint256 minDeposit_) public {
        if (minDeposit_ == 0) {
            vm.expectRevert(ISparkPrimeVault.ZeroMinDeposit.selector);
            vm.prank(admin);
            vault.setMinDeposit(0);
            return;
        }
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.MinDepositSet(minDeposit_);
        vm.prank(admin);
        vault.setMinDeposit(minDeposit_);
        assertEq(vault.minDeposit(), minDeposit_);
    }

    function test_setMinDepositCancellation_zeroMinDepositCancellation() public {
        vm.expectRevert(ISparkPrimeVault.ZeroMinDepositCancellation.selector);
        vm.prank(admin);
        vault.setMinDepositCancellation(0);
        assertEq(vault.minDepositCancellation(), MIN_DEPOSIT_CANCELLATION);
    }

    function test_setMinDepositCancellation() public {
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.MinDepositCancellationSet(20e6);
        vm.prank(admin);
        vault.setMinDepositCancellation(20e6);
        assertEq(vault.minDepositCancellation(), 20e6);
        assertEq(vault.minDeposit(),             MIN_DEPOSIT);
        assertEq(vault.minRedeem(),              MIN_REDEEM);
    }

    function testFuzz_setMinDepositCancellation(uint256 min_) public {
        if (min_ == 0) {
            vm.expectRevert(ISparkPrimeVault.ZeroMinDepositCancellation.selector);
            vm.prank(admin);
            vault.setMinDepositCancellation(0);
            return;
        }
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.MinDepositCancellationSet(min_);
        vm.prank(admin);
        vault.setMinDepositCancellation(min_);
        assertEq(vault.minDepositCancellation(), min_);
    }

    function test_setMinRedeem_zeroMinRedeem() public {
        vm.expectRevert(ISparkPrimeVault.ZeroMinRedeem.selector);
        vm.prank(admin);
        vault.setMinRedeem(0);
        assertEq(vault.minRedeem(), MIN_REDEEM);
    }

    function test_setMinRedeem() public {
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.MinRedeemSet(20e6);
        vm.prank(admin);
        vault.setMinRedeem(20e6);
        assertEq(vault.minRedeem(),              20e6);
        assertEq(vault.minDeposit(),             MIN_DEPOSIT);
        assertEq(vault.minDepositCancellation(), MIN_DEPOSIT_CANCELLATION);
    }

    function testFuzz_setMinRedeem(uint256 minRedeem_) public {
        if (minRedeem_ == 0) {
            vm.expectRevert(ISparkPrimeVault.ZeroMinRedeem.selector);
            vm.prank(admin);
            vault.setMinRedeem(0);
            return;
        }
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.MinRedeemSet(minRedeem_);
        vm.prank(admin);
        vault.setMinRedeem(minRedeem_);
        assertEq(vault.minRedeem(), minRedeem_);
    }

    // C-8 (partially fixed): zero is rejected, but there is still no upper bound. minRedeem =
    // max blocks every redeem request forever (the operator can still process what is already
    // queued); only a reset by DEFAULT_ADMIN restores exits.
    function test_BUG_C8_setMinRedeem_unboundedAbove_blocksAllRedeems() public {
        _deposit(alice, 1_000e6);
        uint256 shares_ = vault.balanceOf(alice);
        uint256 id_     = _requestRedeem(alice, 1e6);

        _setMinRedeem(type(uint256).max);

        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vm.prank(alice);
        vault.requestRedeem(shares_ - 1e6, alice);

        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vm.prank(alice);
        vault.requestRedeem(type(uint256).max - 1, alice);

        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), id_ + 1);

        _setMinRedeem(1);
        _requestRedeem(alice, shares_ - 1e6);
        assertEq(vault.pendingRedeemShares(), shares_ - 1e6);
    }

    // C-8 (partially fixed): minDeposit = max blocks every deposit request.
    function test_BUG_C8_setMinDeposit_unboundedAbove_blocksAllDeposits() public {
        _setMinDeposit(type(uint256).max);

        _fund(alice, 1_000e6);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, 0);

        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vm.prank(alice);
        vault.requestDeposit(type(uint256).max - 1, alice, 0);
    }

    // C-8 (partially fixed): minDepositCancellation = max makes every queued deposit
    // uncancellable (both the full and any partial amount are below the minimum).
    function test_BUG_C8_setMinDepositCancellation_unboundedAbove_blocksAllCancels() public {
        _setCapacity(0);
        uint256 id_ = _deposit(alice, 1_000e6);
        ( , , uint256 queued_ ) = _depositRequest(id_);

        _setMinDepositCancellation(type(uint256).max);

        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, queued_);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, type(uint256).max - 1);
        // Exactly the minimum passes the minimum check and then fails the entry-size check.
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, type(uint256).max);

        _setMinDepositCancellation(1);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, queued_);
        assertEq(vault.pendingCancelledDepositSavingsShares(), queued_);
    }

    // C-8 (open): minDeposit may exceed the whole capacity; every deposit then partially fills
    // and the remainder queues behind an unreachable capacity.
    function test_BUG_C8_setMinDeposit_aboveCapacity() public {
        _setCapacity(100e6);
        _setMinDeposit(1_000e6);

        _fund(alice, 1_000e6);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vm.prank(alice);
        vault.requestDeposit(999e6, alice, 0);

        uint256 id_ = _deposit(alice, 1_000e6);
        ( , , uint256 queued_ ) = _depositRequest(id_);
        assertApproxEqAbs(vault.totalSupply(),    100e6, 2);
        assertApproxEqAbs(vault.balanceOf(alice), 100e6, 2);
        assertLe(vault.availableCapacity(),       2);
        assertGt(queued_,                         0);
    }

    // Exact boundaries of the three minimums, each with its own error: minDeposit on assets,
    // minRedeem on gross shares, minDepositCancellation on savings shares.
    function test_setMinimums_boundaries() public {
        _setMinDeposit(100e6);
        _setMinRedeem(50e6);
        _setMinDepositCancellation(10e6);

        _fund(alice, 1_000e6);
        vm.startPrank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(100e6 - 1, alice, 0);
        vault.requestDeposit(100e6, alice, 0);

        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(50e6 - 1, alice);
        vault.requestRedeem(50e6, alice);
        vm.stopPrank();
        assertGt(vault.convertToAssets(50e6), 50e6);

        _setCapacity(vault.totalSupply());
        uint256 id_ = _deposit(alice, 100e6);
        vm.startPrank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id_, alice, 10e6 - 1);
        vault.requestDepositCancellation(id_, alice, 10e6);
        vm.stopPrank();
        assertEq(vault.pendingCancelledDepositSavingsShares(), 10e6);
    }

    // `minDepositCancellation` is denominated in spUSDC shares, not USDC: a 100 USDC deposit is
    // only ~95.45 spUSDC shares at the harness index, so a minimum of 96e6 blocks the full
    // cancel of a 100 USDC request although the request is worth more than 96 USDC.
    function test_setMinDepositCancellation_inSavingsShares() public {
        _setCapacity(0);
        uint256 id_ = _deposit(alice, 100e6);
        ( , , uint256 shares_ ) = _depositRequest(id_);
        assertEq(shares_, spUsdc.convertToShares(100e6));
        assertLt(shares_, 96e6);
        assertGt(shares_, 95e6);
        assertGe(spUsdc.convertToAssets(shares_), 100e6 - 1);

        _setMinDepositCancellation(96e6);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, shares_);

        _setMinDepositCancellation(shares_ + 1);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, shares_);

        _setMinDepositCancellation(shares_);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, shares_);
        assertEq(vault.pendingCancelledDepositSavingsShares(), shares_);
    }

    // R6-1 (new, low): a partial cancel can strand a remainder below `minDepositCancellation`
    // that can never be cancelled: asking for less than the minimum reverts
    // `BelowMinDepositCancellation`, asking for the minimum reverts `SavingsSharesTooHigh`. The
    // remainder is stuck until the operator fills it or the admin lowers the minimum.
    function test_BUG_R6_1_minDepositCancellation_remainderBelowMinimumIsUncancellable() public {
        _setCapacity(0);
        uint256 id_ = _deposit(alice, 100e6);
        ( , , uint256 shares_ ) = _depositRequest(id_);
        uint256 min_ = shares_ - 5;
        _setMinDepositCancellation(min_);

        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, min_);
        ( , , uint256 left_ ) = _depositRequest(id_);
        assertEq(left_, 5);

        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, 5);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, min_);

        // Only an admin action unblocks it.
        _setMinDepositCancellation(5);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, 5);
        assertEq(vault.firstPendingDepositId(), id_ + 1);
    }

    // minRedeem is gross of the fee: the queued amount can land below the minimum.
    function test_setMinRedeem_grossOfFee() public {
        _setMinRedeem(100e6);
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000e6);

        uint256 id_ = _requestRedeem(alice, 100e6);
        ( , , uint256 queued_ ) = _redeemRequest(id_);
        assertEq(queued_, 99e6);
        assertLt(queued_, vault.minRedeem());
    }

    /**********************************************************************************************/
    /*** setVSRBounds (DEFAULT_ADMIN_ROLE)                                                      ***/
    /**********************************************************************************************/

    function test_setVSRBounds_minVSRTooLowBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert(ISparkPrimeVault.MinVSRTooLow.selector);
        vault.setVSRBounds(RAY - 1, FOUR_PCT_VSR);

        vault.setVSRBounds(RAY, FOUR_PCT_VSR);
        vm.stopPrank();
    }

    function test_setVSRBounds_maxVSRTooHighBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert(ISparkPrimeVault.MaxVSRTooHigh.selector);
        vault.setVSRBounds(RAY, MAX_VSR + 1);

        vault.setVSRBounds(RAY, MAX_VSR);
        vm.stopPrank();
    }

    function test_setVSRBounds_minVSRGtMaxVSRBoundary() public {
        vm.startPrank(admin);
        vm.expectRevert(ISparkPrimeVault.MinVSRGtMaxVSR.selector);
        vault.setVSRBounds(FOUR_PCT_VSR + 1, FOUR_PCT_VSR);

        vault.setVSRBounds(FOUR_PCT_VSR, FOUR_PCT_VSR);
        vm.stopPrank();
    }

    function test_setVSRBounds() public {
        assertEq(vault.minVSR(), RAY);
        assertEq(vault.maxVSR(), MAX_VSR);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.VSRBoundsSet(ONE_PCT_VSR, FOUR_PCT_VSR);
        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        assertEq(vault.minVSR(), ONE_PCT_VSR);
        assertEq(vault.maxVSR(), FOUR_PCT_VSR);
    }

    // Check order: MinVSRTooLow, then MaxVSRTooHigh, then MinVSRGtMaxVSR; the live vsr is never
    // touched.
    function testFuzz_setVSRBounds(uint256 minVSR_, uint256 maxVSR_) public {
        _setPrimeVsr(FOUR_PCT_VSR);
        if (minVSR_ < RAY) {
            vm.expectRevert(ISparkPrimeVault.MinVSRTooLow.selector);
        } else if (maxVSR_ > MAX_VSR) {
            vm.expectRevert(ISparkPrimeVault.MaxVSRTooHigh.selector);
        } else if (minVSR_ > maxVSR_) {
            vm.expectRevert(ISparkPrimeVault.MinVSRGtMaxVSR.selector);
        } else {
            vm.expectEmit(address(vault));
            emit ISparkPrimeVault.VSRBoundsSet(minVSR_, maxVSR_);
        }
        vm.prank(admin);
        vault.setVSRBounds(minVSR_, maxVSR_);
        assertEq(vault.vsr(), FOUR_PCT_VSR);
    }

    // C-7 (open): bounds may be set so the current vsr is outside them; drip keeps accruing at
    // the old vsr until the operator moves it. The admin cannot bring it back into range.
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

        vm.expectRevert(ISparkPrimeVault.VSRTooHigh.selector);
        vm.prank(operator);
        vault.setVSR(TEN_PCT_VSR);

        vm.expectRevert(_notAuthorized(admin, OPERATOR_ROLE));
        vm.prank(admin);
        vault.setVSR(ONE_PCT_VSR);

        _setPrimeVsr(ONE_PCT_VSR);
        assertEq(vault.vsr(), ONE_PCT_VSR);
    }

    /**********************************************************************************************/
    /*** setVSR (OPERATOR_ROLE, hot wallet)                                                     ***/
    /**********************************************************************************************/

    function test_setVSR_vsrTooLowBoundary() public {
        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.startPrank(operator);
        vm.expectRevert(ISparkPrimeVault.VSRTooLow.selector);
        vault.setVSR(ONE_PCT_VSR - 1);

        vault.setVSR(ONE_PCT_VSR);
        assertEq(vault.vsr(), ONE_PCT_VSR);
        vm.stopPrank();
    }

    function test_setVSR_vsrTooHighBoundary() public {
        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);

        vm.startPrank(operator);
        vm.expectRevert(ISparkPrimeVault.VSRTooHigh.selector);
        vault.setVSR(FOUR_PCT_VSR + 1);

        vault.setVSR(FOUR_PCT_VSR);
        assertEq(vault.vsr(), FOUR_PCT_VSR);
        vm.stopPrank();
    }

    // With bounds [RAY, RAY] (deploy default) a compromised operator cannot move the rate at all.
    function test_setVSR_lockedWhenBoundsEqual() public {
        vm.prank(admin);
        vault.setVSRBounds(RAY, RAY);

        vm.startPrank(operator);
        vm.expectRevert(ISparkPrimeVault.VSRTooHigh.selector);
        vault.setVSR(RAY + 1);
        vm.expectRevert(ISparkPrimeVault.VSRTooLow.selector);
        vault.setVSR(RAY - 1);
        vault.setVSR(RAY);
        vm.stopPrank();
    }

    function test_setVSR() public {
        uint256 rhoBefore_ = vault.rho();
        skip(10 days);

        uint192 nChi_ = vault.nowChi();
        assertEq(nChi_, vault.chi());  // vsr is RAY: no accrual
        assertEq(vault.rho(), rhoBefore_);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Drip(nChi_, 0);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.VSRSet(FOUR_PCT_VSR);
        vm.prank(operator);
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

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Drip(nChi_, diff_);
        vm.prank(operator);
        vault.setVSR(RAY);

        assertEq(vault.assetsOf(alice), expected_);
        assertEq(vault.chi(),           nChi_);
    }

    function test_setVSR_whilePaused() public {
        _pause();
        _setPrimeVsr(FOUR_PCT_VSR);
        assertEq(vault.vsr(), FOUR_PCT_VSR);
        assertTrue(vault.paused());
    }

    // Check order: VSRTooLow then VSRTooHigh, with bounds set by the admin.
    function testFuzz_setVSR(uint256 minVSR_, uint256 maxVSR_, uint256 vsr_) public {
        minVSR_ = bound(minVSR_, RAY, MAX_VSR);
        maxVSR_ = bound(maxVSR_, minVSR_, MAX_VSR);
        vm.prank(admin);
        vault.setVSRBounds(minVSR_, maxVSR_);

        if (vsr_ < minVSR_) {
            vm.expectRevert(ISparkPrimeVault.VSRTooLow.selector);
        } else if (vsr_ > maxVSR_) {
            vm.expectRevert(ISparkPrimeVault.VSRTooHigh.selector);
        } else {
            vm.expectEmit(address(vault));
            emit ISparkPrimeVault.VSRSet(vsr_);
        }
        vm.prank(operator);
        vault.setVSR(vsr_);
        if (vsr_ >= minVSR_ && vsr_ <= maxVSR_) assertEq(vault.vsr(), vsr_);
        else                                    assertEq(vault.vsr(), RAY);
    }

    // C-9 (open): MAX_VSR is 100% APY. With the harness bounds a compromised operator doubles
    // the notional in a year while nothing backs it (the backing stays at ~1,000 USDC).
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

    function test_setRedeemFeeRate_feeTooHighBoundary() public {
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.005e18);

        vm.startPrank(redeemFeeSetter);
        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
        vault.setRedeemFeeRate(0.005e18 + 1);

        vault.setRedeemFeeRate(0.005e18);
        assertEq(vault.redeemFeeRate(), 0.005e18);
        vm.stopPrank();
    }

    function test_setRedeemFeeRate_zeroMaxLocksFee() public {
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0);

        vm.startPrank(redeemFeeSetter);
        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
        vault.setRedeemFeeRate(1);
        vault.setRedeemFeeRate(0);
        vm.stopPrank();
    }

    function test_setRedeemFeeRate() public {
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemFeeRateSet(0.001e18);
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.001e18);
        assertEq(vault.redeemFeeRate(), 0.001e18);
    }

    function testFuzz_setRedeemFeeRate(uint256 maxFee_, uint256 fee_) public {
        maxFee_ = bound(maxFee_, 0, 0.01e18);
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(maxFee_);

        if (fee_ > maxFee_) {
            vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
            vm.prank(redeemFeeSetter);
            vault.setRedeemFeeRate(fee_);
            assertEq(vault.redeemFeeRate(), 0);
            return;
        }
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemFeeRateSet(fee_);
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(fee_);
        assertEq(vault.redeemFeeRate(), fee_);
    }

    /**********************************************************************************************/
    /*** adjustTotalAssets (LOSS_MANAGER_ROLE, requires paused)                                 ***/
    /**********************************************************************************************/

    // :262-283: `onlyRole(LOSS_MANAGER_ROLE)`, `require(paused)`, `require(delta != 0)`,
    // `drip()`, `totalAssets_ = int256(totalAssets()) + delta`, `require(totalAssets_ > 0)`,
    // `chi = totalAssets_ * RAY / totalSupply` with `chi != 0` and `chi <= uint192.max`.

    // R3-1 fixed: `adjustTotalAssets` requires the pause, and while paused no deposit or redeem
    // request can be placed around it. `IsNotPaused` is checked before the zero-delta check.
    function test_fixed_R3_1_adjustTotalAssetsRequiresPause() public {
        _deposit(alice, 1_000e6);
        uint192 chi_ = vault.chi();

        vm.startPrank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(1e6);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(-1e6);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(0);
        vm.stopPrank();
        assertEq(vault.chi(), chi_);

        _pause();
        _fund(bob, 100e6);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(bob);
        vault.requestDeposit(100e6, bob, 0);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(alice);
        vault.requestRedeem(1e6, alice);

        _adjustTotalAssets(100e6);
        assertGt(vault.chi(), chi_);

        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(bob);
        vault.requestDeposit(100e6, bob, 0);
        _unpause();
        vm.prank(bob);
        vault.requestDeposit(100e6, bob, 0);
        // bob did not share in the gain: his shares are priced at the post-gain index.
        assertApproxEqAbs(vault.assetsOf(bob), 100e6, 2);
    }

    function test_adjustTotalAssets_zeroDeltaTotalAssets() public {
        _deposit(alice, 1_000e6);
        _pause();
        vm.expectRevert(ISparkPrimeVault.ZeroDeltaTotalAssets.selector);
        vm.prank(lossManager);
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

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.TotalAssetsAdjusted(expected_, 10e6);
        vm.prank(lossManager);
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

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.TotalAssetsAdjusted(expected_, -10e6);
        vm.prank(lossManager);
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
        vm.prank(lossManager);
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

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Drip(dripped_, totalAssets_ - supply_ * stored_ / RAY);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.TotalAssetsAdjusted(_expectedChi(totalAssets_ - 1e6, supply_), -1e6);
        vm.prank(lossManager);
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
        ( , , uint256 bobSavingsShares_ ) = _depositRequest(depId_);

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
        assertEq(vault.firstPendingRedeemId(), redId_ + 1);
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
        ( , , uint256 queued_ ) = _depositRequest(id_);
        assertGt(queued_, 0);
        assertLe(vault.availableCapacity(), 10);  // a few wei of share capacity lost to floors
        assertApproxEqAbs(vault.assetsOf(bob), 1_000e6 * newChi_ / RAY, 10);
        assertApproxEqAbs(spUsdc.convertToAssets(queued_), 1_000e6 - 1_000e6 * newChi_ / RAY, 10);
    }

    // C-3 (open, re-rated in round 6): no loss floor, and the key is now the LOSS_MANAGER hot
    // wallet plus a PAUSER hot wallet, with no admin, timelock or governance in the path.
    // `adjustTotalAssets(-(totalAssets - 1))` is accepted and leaves holders with at most 1 wei
    // in total while the full spUSDC backing stays in the vault and is takeable by a third hot
    // wallet. `-(totalAssets)` and anything larger revert `LossTooHigh`.
    function test_BUG_C3_lossFloorAbsent_hotWalletsOnly() public {
        _deposit(alice, 1_000_000e6);
        uint256 totalAssets_ = vault.totalAssets();
        uint256 supply_      = vault.totalSupply();
        assertApproxEqAbs(totalAssets_, 1_000_000e6, 2);

        // The admin is not involved at any step.
        assertFalse(vault.hasRole(PAUSER_ROLE,       admin));
        assertFalse(vault.hasRole(LOSS_MANAGER_ROLE, admin));
        assertFalse(vault.hasRole(TAKER_ROLE,        admin));
        vm.prank(pauser);
        vault.pause();

        vm.startPrank(lossManager);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(type(int256).min);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(-int256(totalAssets_ + 1));
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(-int256(totalAssets_));

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.TotalAssetsAdjusted(uint192(RAY / supply_), -int256(totalAssets_ - 1));
        vault.adjustTotalAssets(-int256(totalAssets_ - 1));
        vm.stopPrank();

        assertEq(vault.chi(),            uint192(RAY / supply_));
        assertEq(vault.totalAssets(),    supply_ * (RAY / supply_) / RAY);
        assertLe(vault.totalAssets(),    1);
        assertLe(vault.assetsOf(alice),  1);
        assertEq(vault.balanceOf(alice), supply_);  // shares remain, worth nothing

        // Backing is untouched and still takeable in full, during the pause.
        assertApproxEqAbs(spUsdc.convertToAssets(_vaultSpUsdc()), 1_000_000e6, 2);
        uint256 backing_ = _vaultSpUsdc();
        vm.prank(taker);
        vault.take(backing_);
        assertEq(_vaultSpUsdc(), 0);

        // A later "gain" of the same size restores the index: the loss manager alone decides
        // what holders are worth.
        _adjustTotalAssets(int256(totalAssets_ - 1));
        assertApproxEqAbs(vault.totalAssets(), totalAssets_, 2);
    }

    // C-3 (open), the other direction: a gain is bounded only by `ChiTooHigh`, so the loss
    // manager can write the notional up arbitrarily. After a +1,000,000 USDC "gain" on a 2,000
    // USDC vault, alice (half the shares) redeems: the per-entry liquidity bound fills her
    // request with the WHOLE backing (bob's 1,000 USDC included) against a fraction of her
    // shares, and bob can never be paid. No admin involved.
    function test_BUG_C3_gainUnbounded_hotWalletLetsOneHolderDrainBacking() public {
        _deposit(alice, 1_000e6);
        _deposit(bob,   1_000e6);
        uint256 backing_ = spUsdc.convertToAssets(_vaultSpUsdc());
        assertApproxEqAbs(backing_, 2_000e6, 2);

        vm.prank(pauser);
        vault.pause();
        vm.prank(lossManager);
        vault.adjustTotalAssets(1_000_000e6);
        vm.prank(unpauser);
        vault.unpause();
        assertApproxEqAbs(vault.totalAssets(), 1_002_000e6, 5);
        assertApproxEqAbs(vault.assetsOf(alice), 501_000e6, 3);

        uint256 aliceShares_ = vault.balanceOf(alice);
        uint256 redId_       = _requestRedeem(alice, aliceShares_);
        uint256 liquid_      = vault.availableLiquidAssets();
        assertEq(liquid_, backing_);

        _processRedeems(type(uint256).max, 10);

        // alice got every USDC the vault held, for ~0.2% of her shares; the only dust left is
        // below the value of one share (~501 wei at the inflated index), since the fill is
        // floored to whole shares.
        uint256 shareValue_ = uint256(vault.nowChi()) / RAY + 1;
        assertGt(backing_ - usdc.balanceOf(alice), 0);
        assertLt(backing_ - usdc.balanceOf(alice), shareValue_);
        assertLt(vault.availableLiquidAssets(),    shareValue_);
        ( , , uint256 left_ ) = _redeemRequest(redId_);
        assertGt(left_, aliceShares_ * 99 / 100);
        assertEq(vault.firstPendingRedeemId(), redId_);  // still at the head, partially filled

        // bob's exit is now unfillable: nothing is left and his entry sits behind alice's.
        uint256 bobId_ = _requestRedeem(bob, vault.balanceOf(bob));
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob), 0);
        ( , , uint256 bobLeft_ ) = _redeemRequest(bobId_);
        assertGt(bobLeft_, 0);
    }

    // `ChiTooLow` is reachable only once `totalSupply > RAY` (1e21 USDC at 6 decimals): the
    // floor then becomes `totalSupply / RAY` assets rather than 1 wei.
    function test_adjustTotalAssets_chiTooLowOnlyAboveRaySupply() public {
        _deposit(alice, 1.1e27);
        uint256 supply_ = vault.totalSupply();
        assertGt(supply_, RAY);
        _pause();
        uint256 totalAssets_ = vault.totalAssets();

        vm.startPrank(lossManager);
        vm.expectRevert(ISparkPrimeVault.ChiTooLow.selector);
        vault.adjustTotalAssets(-int256(totalAssets_ - 1));

        uint256 floor_ = supply_ / RAY + 1;  // smallest totalAssets_ with chi >= 1
        vm.expectRevert(ISparkPrimeVault.ChiTooLow.selector);
        vault.adjustTotalAssets(-int256(totalAssets_ - (floor_ - 1)));
        vault.adjustTotalAssets(-int256(totalAssets_ - floor_));
        vm.stopPrank();
        assertEq(vault.chi(), 1);
    }

    // `totalSupply == 0`: a positive delta panics with division by zero (:277, the NOTE
    // acknowledges the assumption); a negative delta reverts `LossTooHigh` first.
    function test_adjustTotalAssets_zeroSupplyPanics() public {
        assertEq(vault.totalSupply(), 0);
        _pause();

        vm.startPrank(lossManager);
        vm.expectRevert(stdError.divisionError);
        vault.adjustTotalAssets(1);
        vm.expectRevert(stdError.divisionError);
        vault.adjustTotalAssets(int256(uint256(1e30)));
        vm.expectRevert(stdError.arithmeticError);  // (int256.max) * RAY overflows before the division
        vault.adjustTotalAssets(type(int256).max);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
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
        vm.expectRevert(stdError.divisionError);
        vm.prank(lossManager);
        vault.adjustTotalAssets(1);
    }

    // R4-2 fixed: the `uint192` cast is guarded. The largest accepted index is exactly
    // `type(uint192).max`; the next representable value reverts `ChiTooHigh` and the index is
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

        vm.startPrank(lossManager);
        vm.expectRevert(ISparkPrimeVault.ChiTooHigh.selector);
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

    // G-1 (open), exact threshold: with `vsr == RAY`, `drip()` (:655) and `nowChi()` (:846)
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

        _storeChi(MAX_DRIP_CHI);
        skip(1);
        assertEq(uint256(vault.nowChi()), MAX_DRIP_CHI);
        assertEq(uint256(vault.drip()),   MAX_DRIP_CHI);
        skip(365 days);
        assertEq(uint256(vault.drip()),   MAX_DRIP_CHI);  // _rpow(RAY, dt) == RAY for every dt

        _storeChi(MAX_DRIP_CHI + 1);
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
    // still: an index that is safe at `vsr == RAY` reverts one second after the operator moves
    // the rate to MAX_VSR.
    function test_BUG_G1_dripOverflowBoundShrinksWithVsr() public {
        _deposit(alice, 1_000e6);
        _storeChi(MAX_DRIP_CHI);
        _setPrimeVsr(MAX_VSR);  // drips at the same timestamp: no-op
        assertEq(uint256(vault.chi()), MAX_DRIP_CHI);

        skip(1);
        vm.expectRevert(stdError.arithmeticError);
        vault.drip();

        uint256 safe_ = type(uint256).max / MAX_VSR;
        _storeChi(safe_);
        assertEq(uint256(vault.drip()), safe_ * MAX_VSR / RAY);
    }

    // G-1 (open), second bound: `drip()` also computes `totalSupply_ * nChi_` (:658) and every
    // view computes `shares * nowChi` (:828), so the index is additionally bounded by
    // `type(uint256).max / totalSupply`. With 2e27 shares (2e21 USDC) that is ~5.8e49, below
    // the `RAY` bound: `nowChi()` still works but `drip()`, `totalAssets()` and therefore
    // `adjustTotalAssets` (:270, :272) revert. `uint192` catches neither.
    function test_BUG_G1_dripDiffOverflowBoundWithLargeSupply() public {
        _deposit(alice, 2e27);
        uint256 supply_ = vault.totalSupply();
        uint256 bound_  = type(uint256).max / supply_;
        assertLt(bound_, MAX_DRIP_CHI);

        _storeChi(bound_);
        skip(1);
        assertEq(uint256(vault.nowChi()), bound_);
        assertEq(uint256(vault.drip()),   bound_);
        assertEq(vault.totalAssets(),     supply_ * bound_ / RAY);

        _storeChi(bound_ + 1);
        skip(1);
        assertEq(uint256(vault.nowChi()), bound_ + 1);  // the RAY product still fits
        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
        vm.expectRevert(stdError.arithmeticError);
        vault.totalAssets();
        _pause();
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(lossManager);
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
    // requests, cancels, all three queues, `setVSR`, `drip`, the views, and `adjustTotalAssets`
    // itself (it drips before its own checks, so the loss manager cannot undo the gain). `take`
    // still works, so the backing can leave while holders cannot. Only an upgrade recovers the
    // vault. Round 6: the key that can do this is the LOSS_MANAGER hot wallet.
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

        // Same timestamp: drip short-circuits, so the loss manager could still undo it in-block.
        vault.drip();
        assertEq(vault.totalAssets(), supply_ * vault.chi() / RAY);

        skip(1);

        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
        vm.expectRevert(stdError.arithmeticError);
        vault.nowChi();
        vm.expectRevert(stdError.arithmeticError);
        vault.totalAssets();

        vm.startPrank(lossManager);
        vm.expectRevert(stdError.arithmeticError);
        vault.adjustTotalAssets(-delta_);
        vm.expectRevert(stdError.arithmeticError);
        vault.adjustTotalAssets(type(int256).min + 1);
        vm.stopPrank();

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(operator);
        vault.setVSR(RAY);

        _unpause();
        _fund(bob, 1e6);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(bob);
        vault.requestDeposit(1e6, bob, 0);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(alice);
        vault.requestRedeem(1e6, alice);
        vm.startPrank(operator);
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

        // Recovery: an upgrade (DEFAULT_ADMIN) to an implementation that writes `chi` without
        // dripping.
        uint192 chiBefore_ = _expectedChi(totalAssets_, supply_);
        address rescue_    = address(new SparkPrimeVaultChiRescue());
        vm.prank(admin);
        vault.upgradeToAndCall(
            rescue_,
            abi.encodeCall(SparkPrimeVaultChiRescue.rescueChi, (chiBefore_))
        );
        assertEq(vault.chi(), chiBefore_);
        skip(1);
        vault.drip();
        assertApproxEqAbs(vault.totalAssets(), totalAssets_, 1);
        vm.prank(alice);
        vault.requestRedeem(1e6, alice);
        _processRedeems(type(uint256).max, 10);
        assertApproxEqAbs(usdc.balanceOf(alice), 1e6 * uint256(chiBefore_) / RAY, 1);
    }

    // `claimableAssets` is USDC parked in the vault for recipients that could not be paid. It is
    // not part of `totalAssets`, so `adjustTotalAssets` neither counts nor touches it, and
    // `take` (spUSDC only) cannot move it either: the exact credit survives a loss, a take, and
    // pays out after de-blacklisting. `totalClaimable` tracks it.
    function test_adjustTotalAssets_doesNotTouchClaimableAssets() public {
        _deposit(alice, 1_000e6);
        uint256 ta0_    = vault.totalAssets();
        uint256 assets_ = vault.convertToAssets(100e6);
        vm.prank(alice);
        vault.requestRedeem(100e6, bob);
        _blacklist(bob);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, assets_);
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.claimableAssets(bob),      assets_);
        assertEq(vault.totalClaimable(),          assets_);
        assertEq(usdc.balanceOf(address(vault)),  assets_);
        uint256 totalAssets_ = vault.totalAssets();
        assertApproxEqAbs(ta0_ - totalAssets_, assets_, 1);  // the ~100.98 USDC of claimable are excluded
        assertEq(totalAssets_, vault.convertToAssets(vault.totalSupply()));

        _adjustTotalAssetsWhilePaused(-int256(totalAssets_ / 2));
        assertEq(vault.claimableAssets(bob),     assets_);
        assertEq(vault.totalClaimable(),         assets_);
        assertEq(usdc.balanceOf(address(vault)), assets_);

        _takeAll();
        assertEq(usdc.balanceOf(address(vault)), assets_);

        _unblacklist(bob);
        vault.claim(bob);
        assertEq(usdc.balanceOf(bob),            assets_);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalClaimable(),         0);
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

    // R5-2 (open): the loss manager's payload is public before the pauser pauses. A deposit
    // that lands between "payload public" and `pause` captures its pro-rata share of the gain
    // and can queue a redeem right after the unpause. alice and bob hold equal shares: bob's
    // last-minute deposit takes 50e6 of a 100e6 gain earned before he arrived.
    function test_BUG_R5_2_adjustTotalAssets_depositBeforePauseCapturesGain() public {
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

    // A queued cancellation during the pause is settled at the spUSDC rate and is not affected
    // by a loss written at the same time (it never entered the spPRIME index).
    function test_adjustTotalAssets_cancellationDuringPauseUnaffected() public {
        _deposit(alice, 1_000e6);
        _setCapacity(vault.totalSupply());
        uint256 id_ = _deposit(bob, 100e6);
        ( , , uint256 shares_ ) = _depositRequest(id_);
        _pause();
        vm.prank(bob);
        uint256 cancelId_ = vault.requestDepositCancellation(id_, bob, shares_);
        uint256 totalAssets_ = vault.totalAssets();
        _adjustTotalAssets(-int256(totalAssets_ / 2));
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositCancellationId(), cancelId_ + 1);
        assertEq(usdc.balanceOf(bob), 100e6 - 1);
        assertTrue(vault.paused());
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
        ( , , uint256 shares1_ ) = _depositRequest(id1_);
        ( , , uint256 shares2_ ) = _depositRequest(id2_);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRequest(id2_, 0, bob, shares2_);
        vm.prank(bob);
        uint256 c0_ = vault.requestDepositCancellation(id2_, bob, shares2_);
        assertEq(c0_, 0);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRequest(id1_, 1, alice, shares1_ / 3);
        vm.prank(bob);
        uint256 c1_ = vault.requestDepositCancellation(id1_, alice, shares1_ / 3);
        assertEq(c1_, 1);
    }

    // `pause` / `unpause` emit argument-less events; nothing else is logged.
    function test_pauseUnpause_eventsExact() public {
        vm.prank(pauser);
        vm.recordLogs();
        vault.pause();
        assertEq(vm.getRecordedLogs().length, 1);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Paused();
        vm.prank(pauser);
        vault.pause();

        vm.prank(unpauser);
        vm.recordLogs();
        vault.unpause();
        assertEq(vm.getRecordedLogs().length, 1);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Unpaused();
        vm.prank(unpauser);
        vault.unpause();
    }

    /**********************************************************************************************/
    /*** take (TAKER_ROLE)                                                                      ***/
    /**********************************************************************************************/

    function test_take_insufficientSharesBoundary() public {
        _deposit(alice, 1_000e6);
        uint256 bal_ = _vaultSpUsdc();

        vm.startPrank(taker);
        vm.expectRevert(ISparkPrimeVault.InsufficientShares.selector);
        vault.take(bal_ + 1);

        vault.take(bal_);
        assertEq(_vaultSpUsdc(),          0);
        assertEq(spUsdc.balanceOf(taker), bal_);
        vm.stopPrank();
    }

    function test_take_zero() public {
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Take(0);
        vm.prank(taker);
        vault.take(0);
        assertEq(spUsdc.balanceOf(taker), 0);
    }

    function test_take() public {
        _deposit(alice, 1_000e6);
        uint256 bal_ = _vaultSpUsdc();
        assertGt(bal_, 0);
        assertEq(spUsdc.balanceOf(taker), 0);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Take(bal_ / 3);
        vm.prank(taker);
        vault.take(bal_ / 3);

        assertEq(_vaultSpUsdc(),          bal_ - bal_ / 3);
        assertEq(spUsdc.balanceOf(taker), bal_ / 3);

        // Notional is unchanged by take.
        assertApproxEqAbs(vault.totalAssets(), 1_000e6, 2);
    }

    function testFuzz_take(uint256 deposit_, uint256 take_) public {
        deposit_ = bound(deposit_, 1, 1_000_000_000e6);
        _deposit(alice, deposit_);
        uint256 bal_         = _vaultSpUsdc();
        uint256 totalAssets_ = vault.totalAssets();

        if (take_ > bal_) {
            vm.expectRevert(ISparkPrimeVault.InsufficientShares.selector);
            vm.prank(taker);
            vault.take(take_);
            assertEq(_vaultSpUsdc(), bal_);
            return;
        }
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Take(take_);
        vm.prank(taker);
        vault.take(take_);
        assertEq(_vaultSpUsdc(),          bal_ - take_);
        assertEq(spUsdc.balanceOf(taker), take_);
        assertEq(vault.totalAssets(),     totalAssets_);
    }

    function test_take_whilePaused() public {
        _deposit(alice, 1_000e6);
        uint256 bal_ = _vaultSpUsdc();
        _pause();
        vm.prank(taker);
        vault.take(bal_);
        assertEq(_vaultSpUsdc(), 0);
        assertTrue(vault.paused());
    }

    // F-2 / R5-5 (known): take ignores pendingDepositSavingsShares and
    // pendingCancelledDepositSavingsShares. The cancel itself succeeds, the settlement then pays
    // nothing because the vault holds no spUSDC (no revert, the refund just waits).
    function test_BUG_F2_take_ignoresPendingDepositSavingsShares() public {
        _setCapacity(0);
        uint256 id_ = _deposit(alice, 1_000e6);
        ( , , uint256 queued_ ) = _depositRequest(id_);
        assertEq(vault.pendingDepositSavingsShares(), queued_);
        assertEq(_vaultSpUsdc(),                      queued_);

        vm.prank(taker);
        vault.take(queued_);

        assertEq(_vaultSpUsdc(),                      0);
        assertEq(vault.pendingDepositSavingsShares(), queued_);

        uint256 cancelId_ = _cancelDeposit(alice, id_);
        assertEq(vault.pendingCancelledDepositSavingsShares(), queued_);

        _processCancelledDeposits(type(uint256).max, 10);
        ( , , uint256 left_ ) = _cancelledDepositRequest(cancelId_);
        assertEq(left_,                   queued_);
        assertEq(usdc.balanceOf(alice),   0);
        assertEq(vault.firstPendingDepositCancellationId(), 0);

        // Once the backing comes back the refund settles.
        _returnToVault(queued_);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositCancellationId(), cancelId_ + 1);
        assertEq(usdc.balanceOf(alice), 1_000e6 - 1);
    }

    // F-2 / R5-5: a redeem fill spends the backing of queued deposits too, so `take` of the
    // remainder leaves the queued depositor unbacked.
    function test_BUG_F2_redeemFillSpendsQueuedDepositBacking() public {
        _deposit(alice, 1_000e6);
        _setCapacity(vault.totalSupply());
        uint256 id_ = _deposit(bob, 1_000e6);
        ( , , uint256 bobShares_ ) = _depositRequest(id_);
        uint256 backing_ = _vaultSpUsdc();

        // Take alice's whole backing; bob's spUSDC is the only thing left.
        _take(backing_ - bobShares_);
        assertEq(_vaultSpUsdc(), bobShares_);

        // alice's redeem is filled out of bob's queued spUSDC.
        _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems(type(uint256).max, 10);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000e6, 2);
        assertLe(_vaultSpUsdc(), 2);
        assertEq(vault.pendingDepositSavingsShares(), bobShares_);  // bob's claim is unbacked
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
        assertEq(fresh_.minDeposit(),             0);
        assertEq(fresh_.minDepositCancellation(), 0);
        assertEq(fresh_.minRedeem(),              0);
        assertEq(usdc.allowance(address(fresh_), address(spUsdc)), 0);
        assertFalse(fresh_.hasRole(DEFAULT_ADMIN_ROLE, admin));

        skip(1234);
        vm.expectEmit(address(fresh_));
        emit IAccessControl.RoleGranted(DEFAULT_ADMIN_ROLE, admin, address(this));
        fresh_.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin, 100e6, 50e6, 10e6);

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
        assertEq(fresh_.minDeposit(),             100e6);
        assertEq(fresh_.minDepositCancellation(), 50e6);
        assertEq(fresh_.minRedeem(),              10e6);
        assertEq(fresh_.redeemFeeRate(),    0);
        assertEq(fresh_.maxRedeemFeeRate(), 0);
        assertEq(fresh_.totalSupply(),      0);
        assertEq(fresh_.totalClaimable(),   0);
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
        assertEq(fresh_.getRoleMemberCount(DEFAULT_ADMIN_ROLE),     1);
        assertEq(fresh_.getRoleMember(DEFAULT_ADMIN_ROLE, 0),       admin);
        assertEq(fresh_.getRoleMemberCount(LOSS_MANAGER_ROLE),      0);
        assertEq(fresh_.getRoleMemberCount(OPERATOR_ROLE),          0);
        assertEq(fresh_.getRoleMemberCount(PAUSER_ROLE),            0);
        assertEq(fresh_.getRoleMemberCount(UNPAUSER_ROLE),          0);
        assertEq(fresh_.getRoleMemberCount(REDEEM_FEE_SETTER_ROLE), 0);
        assertEq(fresh_.getRoleMemberCount(TAKER_ROLE),             0);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fresh_.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin, 1, 1, 1);
    }

    // Round 6: the three minimums must be non-zero, checked in order and before anything else
    // (a zero `savings_` is never called when a minimum is zero).
    function test_initialize_zeroMinDeposit() public {
        SparkPrimeVault fresh_ = _freshProxy();
        vm.expectRevert(ISparkPrimeVault.ZeroMinDeposit.selector);
        fresh_.initialize(address(0), "x", "x", admin, 0, 0, 0);
        vm.expectRevert(ISparkPrimeVault.ZeroMinDeposit.selector);
        fresh_.initialize(address(spUsdc), "x", "x", admin, 0, 1, 1);
        assertEq(vm.load(address(fresh_), INITIALIZABLE_STORAGE), bytes32(0));
    }

    function test_initialize_zeroMinDepositCancellation() public {
        SparkPrimeVault fresh_ = _freshProxy();
        vm.expectRevert(ISparkPrimeVault.ZeroMinDepositCancellation.selector);
        fresh_.initialize(address(0), "x", "x", admin, 1, 0, 0);
        vm.expectRevert(ISparkPrimeVault.ZeroMinDepositCancellation.selector);
        fresh_.initialize(address(spUsdc), "x", "x", admin, 1, 0, 1);
    }

    function test_initialize_zeroMinRedeem() public {
        SparkPrimeVault fresh_ = _freshProxy();
        vm.expectRevert(ISparkPrimeVault.ZeroMinRedeem.selector);
        fresh_.initialize(address(0), "x", "x", admin, 1, 1, 0);
        vm.expectRevert(ISparkPrimeVault.ZeroMinRedeem.selector);
        fresh_.initialize(address(spUsdc), "x", "x", admin, 1, 1, 0);
    }

    function testFuzz_initialize_minimums(uint256 minDep_, uint256 minCancel_, uint256 minRed_)
        public
    {
        SparkPrimeVault fresh_ = _freshProxy();
        if (minDep_ == 0)         vm.expectRevert(ISparkPrimeVault.ZeroMinDeposit.selector);
        else if (minCancel_ == 0) vm.expectRevert(ISparkPrimeVault.ZeroMinDepositCancellation.selector);
        else if (minRed_ == 0)    vm.expectRevert(ISparkPrimeVault.ZeroMinRedeem.selector);
        fresh_.initialize(address(spUsdc), "x", "x", admin, minDep_, minCancel_, minRed_);
        if (minDep_ != 0 && minCancel_ != 0 && minRed_ != 0) {
            assertEq(fresh_.minDeposit(),             minDep_);
            assertEq(fresh_.minDepositCancellation(), minCancel_);
            assertEq(fresh_.minRedeem(),              minRed_);
        }
    }

    function test_initialize_implementationDisabled() public {
        SparkPrimeVault impl_ = SparkPrimeVault(vault.implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl_.initialize(address(spUsdc), "x", "x", admin, 1, 1, 1);
        SparkPrimeVault fresh_ = new SparkPrimeVault();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fresh_.initialize(address(spUsdc), "x", "x", admin, 1, 1, 1);
    }

    // Fresh deployment defaults: capacity 0 and maxRedeemFee 0 mean deposits queue and the fee
    // is locked at 0 until the admin configures them; VSR is locked at RAY.
    function test_initialize_defaultsAreSafe() public {
        SparkPrimeVault fresh_ = _freshProxy();
        fresh_.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin, 1, 1, 1);
        vm.startPrank(admin);
        fresh_.grantRole(OPERATOR_ROLE,          operator);
        fresh_.grantRole(REDEEM_FEE_SETTER_ROLE, redeemFeeSetter);
        vm.stopPrank();

        vm.expectRevert(ISparkPrimeVault.VSRTooHigh.selector);
        vm.prank(operator);
        fresh_.setVSR(RAY + 1);

        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
        vm.prank(redeemFeeSetter);
        fresh_.setRedeemFeeRate(1);

        assertEq(fresh_.availableCapacity(), 0);
    }

    // V2-8 (open): `initialize` does not guard against admin == address(0).
    function test_BUG_V2_8_initialize_zeroAdminNotGuarded() public {
        SparkPrimeVault fresh_ = _freshProxy();
        fresh_.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", address(0), 1, 1, 1);

        assertTrue(fresh_.hasRole(DEFAULT_ADMIN_ROLE, address(0)));
        assertEq(fresh_.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(fresh_.getRoleMember(DEFAULT_ADMIN_ROLE, 0),   address(0));
        assertFalse(fresh_.hasRole(DEFAULT_ADMIN_ROLE, admin));

        vm.expectRevert(_notAuthorized(admin, DEFAULT_ADMIN_ROLE));
        vm.prank(admin);
        fresh_.setMinDeposit(1);

        vm.expectRevert(_notAuthorized(admin, DEFAULT_ADMIN_ROLE));
        vm.prank(admin);
        fresh_.grantRole(PAUSER_ROLE, admin);  // No pauser can ever be appointed either
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
        vm.expectEmit(address(vault));
        emit IERC20.Approval(alice, bob, 100);
        vm.prank(alice);
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

        vm.expectEmit(address(vault));
        emit IERC20.Transfer(alice, bob, 400e6);
        vm.prank(alice);
        assertTrue(vault.transfer(bob, 400e6));

        assertEq(vault.balanceOf(alice), bal_ - 400e6);
        assertEq(vault.balanceOf(bob),   400e6);
        assertEq(vault.totalSupply(),    bal_);
    }

    // Transfers to the zero address and to the vault itself are rejected (the vault balance is
    // the redeem escrow; stray transfers would corrupt `pendingRedeemShares`).
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
        vm.stopPrank();
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

        vm.expectEmit(address(vault));
        emit IERC20.Transfer(alice, bob, 300e6);
        vm.prank(bob);
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
        vm.stopPrank();
    }

    // The balance check (in `_transfer`) runs before the allowance check.
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
        vm.stopPrank();
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
        ( address owner_, uint256 key_ ) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        ( uint8 v_, bytes32 r_, bytes32 s_ ) = vm.sign(key_, _permitDigest(owner_, bob, 100e6, 0, deadline_));

        assertEq(vault.nonces(owner_), 0);

        vm.expectEmit(address(vault));
        emit IERC20.Approval(owner_, bob, 100e6);
        vault.permit(owner_, bob, 100e6, deadline_, v_, r_, s_);

        assertEq(vault.allowance(owner_, bob), 100e6);
        assertEq(vault.nonces(owner_),         1);
    }

    function test_permit_bytesSignature() public {
        ( address owner_, uint256 key_ ) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp;  // deadline == now is still valid
        ( uint8 v_, bytes32 r_, bytes32 s_ ) = vm.sign(key_, _permitDigest(owner_, bob, 5, 0, deadline_));

        vault.permit(owner_, bob, 5, deadline_, abi.encodePacked(r_, s_, v_));
        assertEq(vault.allowance(owner_, bob), 5);
        assertEq(vault.nonces(owner_),         1);
    }

    function test_permit_expiredBoundary() public {
        ( address owner_, uint256 key_ ) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        ( uint8 v_, bytes32 r_, bytes32 s_ ) = vm.sign(key_, _permitDigest(owner_, bob, 5, 0, deadline_));

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
        ( address owner_, )            = makeAddrAndKey("permitOwner");
        ( ,               uint256 k2_ ) = makeAddrAndKey("someoneElse");
        uint256 deadline_ = block.timestamp + 1 hours;
        ( uint8 v_, bytes32 r_, bytes32 s_ ) = vm.sign(k2_, _permitDigest(owner_, bob, 5, 0, deadline_));

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner_, bob, 5, deadline_, v_, r_, s_);
        assertEq(vault.nonces(owner_), 0);
    }

    function test_permit_wrongValue() public {
        ( address owner_, uint256 key_ ) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        ( uint8 v_, bytes32 r_, bytes32 s_ ) = vm.sign(key_, _permitDigest(owner_, bob, 5, 0, deadline_));

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner_, bob, 6, deadline_, v_, r_, s_);
    }

    function test_permit_replay() public {
        ( address owner_, uint256 key_ ) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        ( uint8 v_, bytes32 r_, bytes32 s_ ) = vm.sign(key_, _permitDigest(owner_, bob, 5, 0, deadline_));

        vault.permit(owner_, bob, 5, deadline_, v_, r_, s_);
        assertEq(vault.nonces(owner_), 1);

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner_, bob, 5, deadline_, v_, r_, s_);
        assertEq(vault.nonces(owner_), 1);
    }

    function test_permit_wrongNonce() public {
        ( address owner_, uint256 key_ ) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        ( uint8 v_, bytes32 r_, bytes32 s_ ) = vm.sign(key_, _permitDigest(owner_, bob, 5, 1, deadline_));

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner_, bob, 5, deadline_, v_, r_, s_);
    }

    function test_permit_badSignatureLengthForEOA() public {
        ( address owner_, uint256 key_ ) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        ( , bytes32 r_, bytes32 s_ ) = vm.sign(key_, _permitDigest(owner_, bob, 5, 0, deadline_));

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner_, bob, 5, deadline_, abi.encodePacked(r_, s_));  // 64 bytes
    }

    function test_permit_wrongDomain() public {
        ( address owner_, uint256 key_ ) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        bytes32 digest_ = keccak256(abi.encodePacked(
            "\x19\x01",
            spUsdc.DOMAIN_SEPARATOR(),  // another contract's domain
            keccak256(abi.encode(vault.PERMIT_TYPEHASH(), owner_, bob, 5, 0, deadline_))
        ));
        ( uint8 v_, bytes32 r_, bytes32 s_ ) = vm.sign(key_, digest_);

        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner_, bob, 5, deadline_, v_, r_, s_);
    }

}
