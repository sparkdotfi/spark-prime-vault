// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError }               from "../../lib/forge-std/src/StdError.sol";
import { stdStorage, StdStorage } from "../../lib/forge-std/src/StdStorage.sol";

import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../src/SparkPrimeVault.sol";

import { NewSurfaceBase } from "./NewSurface.t.sol";

/// @dev Upgrade target used to prove that only `upgradeToAndCall` recovers a bricked index.
contract ChiResetImpl is SparkPrimeVault {

    function resetChi(uint192 chi_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chi = chi_;
        rho = uint64(block.timestamp);
    }

}

/// @dev `adjustTotalAssets(int256)` (:262-283) on `master` @ c512609: LOSS_MANAGER_ROLE only (a
///      hot-wallet role now, no longer the governance admin), requires `paused` (`IsNotPaused`),
///      `delta != 0` (`ZeroDeltaTotalAssets`), drips first, writes
///      `chi = (totalAssets + delta) * RAY / totalSupply` with `result > 0` (`LossTooHigh`),
///      `chi != 0` (`ChiTooLow`), `chi <= type(uint192).max` (`ChiTooHigh`).
abstract contract AdjustTotalAssetsBase is NewSurfaceBase {

    event TotalAssetsAdjusted(uint192 chi, int256 deltaTotalAssets);
    event Drip(uint192 chi, uint256 diff);

    // chi after -100k / +100k at supply SH_1M, totalAssets R_1M.
    uint256 constant CHI_LOSS_100K = 908_718_991_417_304_243_366_635_929;
    uint256 constant CHI_GAIN_100K = 1_110_656_545_066_042_825_345_107_777;

    // Smallest delta for which (R_1M + delta) * RAY / SH_1M > type(uint192).max.
    uint256 constant GAIN_TRUNCATE = 6_216_874_099_906_568_962_213_193_772_734_343_774_180_112;

    // Largest chi that drip() can multiply by RAY (vsr == RAY) without overflowing.
    uint256 constant CHI_DRIP_MAX = 115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640;

    // Smallest delta that pushes chi above CHI_DRIP_MAX at the harness supply (G-1).
    uint256 constant GAIN_BRICK = 114_681_085_459_449_903_921_528_244_645_760_029;
    uint256 constant CHI_BRICK  = 115_792_089_237_316_195_423_570_985_008_687_908_517_705_232_418_866;
    uint256 constant CHI_BELOW  = 115_792_089_237_316_195_423_570_985_008_687_907_508_017_464_175_173;

    // Smallest delta for which (R_1M + delta) * RAY overflows uint256 (panic, not chi-too-high).
    uint256 constant GAIN_OVERFLOW = 115_792_089_237_316_195_423_570_985_008_687_907_852_269_984_665_643;

    function _depositAndPause(address who, uint256 amt) internal {
        _deposit(who, amt);
        _pause();
    }

    function _adjust(int256 delta) internal {
        vm.prank(lossManager);
        vault.adjustTotalAssets(delta);
    }

}

contract AdjustTotalAssetsFailureTests is AdjustTotalAssetsBase {

    using stdStorage for StdStorage;

    // LOSS_MANAGER_ROLE only (:265): the admin included.
    function test_adjustTotalAssets_notLossManager() public {
        _depositAndPause(alice, ONE_M);
        address[7] memory who =
            [admin, operator, pauser, unpauser, redeemFeeSetter, taker, alice];
        for (uint256 i; i < 7; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(_unauthorized(who[i], LOSS_MANAGER_ROLE));
            vault.adjustTotalAssets(-1e6);
        }
        assertEq(vault.chi(), CHI_P);

        // The admin can grant itself the role; the role is enumerable.
        assertEq(vault.getRoleMemberCount(LOSS_MANAGER_ROLE), 1);
        assertEq(vault.getRoleMember(LOSS_MANAGER_ROLE, 0), lossManager);
        vm.prank(admin);
        vault.grantRole(LOSS_MANAGER_ROLE, admin);
        vm.prank(admin);
        vault.adjustTotalAssets(-1e6);
        assertLt(vault.chi(), CHI_P);
    }

    // R3-1 pin: the adjustment is only possible while paused, and while paused every request
    // and every fill walk is blocked. Changed on c512609: cancellations and their settlement are
    // NOT blocked any more (R5-B), so a queued depositor can leave during the pause window.
    function test_fixed_R3_1_adjustTotalAssets_requiresPause_requestsAndFillsBlockedWhilePaused() public {
        _deposit(alice, ONE_M);
        _setCapacity(0);
        uint256 id = _deposit(bob, HUNDRED_K);  // queued

        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(-1e6);
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(1e6);

        _pause();
        _fund(carol, ONE_M);
        vm.prank(carol);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDeposit(ONE_M, carol, 0);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestRedeem(1, alice);
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);

        // What still works while paused: drip, transfer, take, setVSR, cancellations and their
        // settlement, the adjustment itself.
        vault.drip();
        vm.prank(alice);
        assertTrue(vault.transfer(bob, 1));
        _take(1);
        _setPrimeVsr(ONE_PCT_VSR);
        _cancel(bob, id, bob, S_100K);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), A_100K);
        _adjust(1e6);
        assertGt(vault.chi(), CHI_P);
    }

    function test_adjustTotalAssets_zeroDelta() public {
        _depositAndPause(alice, ONE_M);
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.ZeroDeltaTotalAssets.selector);
        vault.adjustTotalAssets(0);

        // The paused check comes first.
        _unpause();
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(0);
    }

    // `totalAssets_ > 0` (:286): the whole totalAssets and anything beyond is rejected, one wei
    // less is accepted (C-3, see the BUG test).
    function test_adjustTotalAssets_lossTooHighBoundary() public {
        _depositAndPause(alice, ONE_M);
        int256 ta = int256(vault.totalAssets());
        assertEq(ta, int256(R_1M));

        int256[4] memory deltas = [-ta, -ta - 1, -int256(ONE_M), type(int256).min];
        for (uint256 i; i < 4; ++i) {
            vm.prank(lossManager);
            vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
            vault.adjustTotalAssets(deltas[i]);
        }
        assertEq(vault.chi(), CHI_P);

        _adjust(-ta + 1);
        assertEq(vault.chi(), 1_009_687_768_243_692);
        assertEq(vault.totalAssets(), 0);
    }

    // `totalSupply == 0` (:289): a positive delta divides by zero, a negative one is caught by
    // `loss-too-high` first (totalAssets is 0).
    function test_adjustTotalAssets_zeroSupplyPanics() public {
        _pause();
        assertEq(vault.totalSupply(), 0);

        vm.prank(lossManager);
        vm.expectRevert(stdError.divisionError);
        vault.adjustTotalAssets(1);
        vm.prank(lossManager);
        vm.expectRevert(stdError.arithmeticError);  // `* RAY` overflows before the division
        vault.adjustTotalAssets(type(int256).max);

        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(-1);
    }

    // `chi-too-low` (:291) is only reachable when totalSupply > totalAssets * RAY, i.e. with
    // more than ~1e27 shares; the supply is inflated through storage like upstream does.
    function test_adjustTotalAssets_chiTooLowBoundary() public {
        _pause();
        uint256 supply = 1e28;
        stdstore.target(address(vault)).sig("totalSupply()").checked_write(supply);

        int256 ta = int256(vault.totalAssets());
        assertEq(ta, 10_096_877_682_424_612_094_087_708_210);  // 1e28 * CHI_P / RAY

        // totalAssets -> 9: chi = 9e27 / 1e28 = 0
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.ChiTooLow.selector);
        vault.adjustTotalAssets(-(ta - 9));
        assertEq(vault.chi(), CHI_P);

        // totalAssets -> 10: chi = 10e27 / 1e28 = 1
        vm.expectEmit(address(vault));
        emit TotalAssetsAdjusted(1, -(ta - 10));
        _adjust(-(ta - 10));
        assertEq(vault.chi(), 1);
        assertEq(vault.totalAssets(), 10);
    }

    // G-2 fixed: the `uint192` cast (:294) is guarded by `chi-too-high` (:292). The old wrap to
    // 458_233_707_431_279 is gone; one wei below the threshold writes the largest fitting chi.
    function test_fixed_G2_adjustTotalAssets_chiTooHighBoundary() public {
        _depositAndPause(alice, ONE_M);

        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.ChiTooHigh.selector);
        vault.adjustTotalAssets(int256(GAIN_TRUNCATE));
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.ChiTooHigh.selector);
        vault.adjustTotalAssets(int256(GAIN_OVERFLOW - 1));
        assertEq(vault.chi(), CHI_P);

        uint256 fits = ((R_1M + GAIN_TRUNCATE - 1) * RAY) / SH_1M;
        assertEq(fits, 6_277_101_735_386_680_763_835_789_423_207_666_416_102_354_893_009_973_700_482);
        assertLe(fits, type(uint192).max);
        assertGt(fits, CHI_DRIP_MAX);  // fits the cast but already far above the drip bound (G-1)

        vm.expectEmit(address(vault));
        emit TotalAssetsAdjusted(uint192(fits), int256(GAIN_TRUNCATE - 1));
        _adjust(int256(GAIN_TRUNCATE - 1));
        assertEq(vault.chi(), fits);
    }

    // Above GAIN_OVERFLOW the multiplication `(totalAssets + delta) * RAY` (:289) panics before
    // the `chi-too-high` check; `type(int256).max` already panics in the signed addition (:284).
    function test_adjustTotalAssets_overflowPanicsAboveThreshold() public {
        _depositAndPause(alice, ONE_M);
        assertEq(GAIN_OVERFLOW, type(uint256).max / RAY - R_1M + 1);

        vm.prank(lossManager);
        vm.expectRevert(stdError.arithmeticError);
        vault.adjustTotalAssets(int256(GAIN_OVERFLOW));
        vm.prank(lossManager);
        vm.expectRevert(stdError.arithmeticError);
        vault.adjustTotalAssets(type(int256).max);
        assertEq(vault.chi(), CHI_P);
    }

}

contract AdjustTotalAssetsSuccessTests is AdjustTotalAssetsBase {

    // chi' = floor((totalAssets - L) * RAY / S) (:289); the floor is against holders.
    function test_adjustTotalAssets_loss() public {
        _depositAndPause(alice, ONE_M);

        uint256 loss      = HUNDRED_K;
        uint256 chiBefore = vault.nowChi();
        uint256 taBefore  = vault.totalAssets();
        uint256 supply    = vault.totalSupply();

        assertEq(chiBefore, CHI_P);
        assertEq(taBefore,  R_1M);
        assertEq(supply,    SH_1M);
        assertEq(vault.assetsOf(alice), R_1M);
        assertEq(_vaultSpUsdc(), S_1M);

        uint256 expectedChi = ((taBefore - loss) * RAY) / supply;
        assertEq(expectedChi, CHI_LOSS_100K);

        vm.expectEmit(address(vault));
        emit TotalAssetsAdjusted(uint192(expectedChi), -int256(loss));
        _adjust(-int256(loss));

        assertEq(vault.chi(),           expectedChi);
        assertEq(vault.nowChi(),        expectedChi);
        assertEq(vault.rho(),           block.timestamp);
        assertEq(vault.totalAssets(),   899_999_999_997);  // taBefore - loss - 1
        assertEq(vault.assetsOf(alice), 899_999_999_997);
        assertEq(vault.totalSupply(),   SH_1M);
        assertEq(_vaultSpUsdc(),        S_1M);  // backing untouched: the loss is notional
        assertTrue(vault.paused());
    }

    function test_adjustTotalAssets_gain() public {
        _depositAndPause(alice, ONE_M);

        uint256 gain     = HUNDRED_K;
        uint256 taBefore = vault.totalAssets();
        assertEq(taBefore, R_1M);

        uint256 expectedChi = ((taBefore + gain) * RAY) / SH_1M;
        assertEq(expectedChi, CHI_GAIN_100K);

        vm.expectEmit(address(vault));
        emit TotalAssetsAdjusted(uint192(expectedChi), int256(gain));
        _adjust(int256(gain));

        assertEq(vault.chi(),           expectedChi);
        assertEq(vault.rho(),           block.timestamp);
        assertEq(vault.totalAssets(),   1_099_999_999_997);  // taBefore + gain - 1
        assertEq(vault.assetsOf(alice), 1_099_999_999_997);
        assertEq(_vaultSpUsdc(),        S_1M);  // no backing arrived: the gain is notional
    }

    // Accrued but undripped yield is settled first (:282): the delta applies on top of nowChi(),
    // the `Drip` event precedes `TotalAssetsAdjusted`, and accrual resumes from the new chi.
    function test_adjustTotalAssets_dripsAccruedInterestBeforeAdjusting() public {
        _deposit(alice, ONE_M);
        _setPrimeVsr(TEN_PCT_VSR);
        _warp(365 days);
        _pause();

        uint256 chiNow    = vault.nowChi();
        uint256 taAccrued = vault.totalAssets();
        assertEq(chiNow,    1_110_656_545_066_707_330_303_098_475);
        assertEq(taAccrued, 1_099_999_999_998);
        assertEq(vault.chi(), CHI_P);
        assertEq(vault.rho(), block.timestamp - 365 days);

        uint256 expectedChi = ((taAccrued - HUNDRED_K) * RAY) / SH_1M;

        vm.expectEmit(address(vault));
        emit Drip(uint192(chiNow), taAccrued - R_1M);
        vm.expectEmit(address(vault));
        emit TotalAssetsAdjusted(uint192(expectedChi), -int256(HUNDRED_K));
        _adjust(-int256(HUNDRED_K));

        assertEq(vault.chi(), expectedChi);
        assertEq(vault.rho(), block.timestamp);
        assertEq(vault.totalAssets(), taAccrued - HUNDRED_K - 1);

        // Accrual continues from the new chi while still paused (drip is never pause-gated).
        _warp(365 days);
        assertGt(vault.nowChi(), expectedChi);
        assertApproxEqRel(vault.nowChi(), expectedChi * 11 / 10, 1e12);  // ~10% on the new chi
    }

    // -L then +L is not the identity: two floors cost holders 2 wei at these indexes.
    function test_adjustTotalAssets_roundTripNotIdentity() public {
        _depositAndPause(alice, ONE_M);

        _adjust(-int256(HUNDRED_K));
        assertEq(vault.chi(),         CHI_LOSS_100K);
        assertEq(vault.totalAssets(), 899_999_999_997);

        _adjust(int256(HUNDRED_K));
        assertEq(vault.chi(),         1_009_687_768_240_663_846_587_628_160);
        assertLt(vault.chi(),         CHI_P);
        assertEq(vault.totalAssets(), 999_999_999_996);
        assertEq(vault.totalAssets(), R_1M - 2);

        // +G then -G: same drift, same direction.
        _adjust(int256(HUNDRED_K));
        _adjust(-int256(HUNDRED_K));
        assertEq(vault.totalAssets(), 999_999_999_994);
    }

    function test_adjustTotalAssets_repeatedAdjustmentsCompose() public {
        _depositAndPause(alice, ONE_M);
        _adjust(int256(HUNDRED_K));
        uint256 ta1  = vault.totalAssets();
        uint256 chi2 = ((ta1 + HUNDRED_K) * RAY) / SH_1M;
        _adjust(int256(HUNDRED_K));
        assertEq(vault.chi(),         chi2);
        assertEq(vault.totalAssets(), 1_199_999_999_996);
        _adjust(-int256(50_000e6));
        assertEq(vault.totalAssets(), 1_149_999_999_995);
    }

    // Who takes the hit: holders and escrowed redeem shares (spPRIME-denominated) do, queued
    // deposits, pending cancellations (spUSDC-denominated) and parked claimables (USDC) do not.
    function test_adjustTotalAssets_lossHitsHoldersAndEscrowNotQueuedSpUsdcNorClaimable() public {
        _deposit(alice,   ONE_M);
        _deposit(bob,     ONE_M);
        _deposit(mallory, HUNDRED_K);
        _requestRedeem(mallory, SH_100K);              // id 0, parked below
        uint256 redeemId = _requestRedeem(bob, SH_1M); // id 1, stays escrowed
        _blacklist(mallory);
        _processRedeems(type(uint256).max, 1);
        assertEq(vault.claimableAssets(mallory), R_100K);
        assertEq(vault.balanceOf(address(vault)), SH_1M);

        _setCapacity(vault.totalSupply());             // close capacity
        uint256 carolId = _deposit(carol, HUNDRED_K);  // queued in spUSDC
        uint256 daveId  = _deposit(dave,  HUNDRED_K);  // queued, then cancelled
        uint256 daveCid = _cancel(dave, daveId, dave, S_100K);

        assertEq(vault.totalSupply(), 2 * SH_1M);
        assertEq(vault.totalAssets(), 1_999_999_999_997);
        assertEq(vault.assetsOf(alice),            R_1M);
        assertEq(vault.convertToAssets(SH_1M),     R_1M);     // bob's escrow
        ( ,, uint256 carolQueued ) = _depositRequest(carolId);
        ( ,, uint256 daveQueued  ) = _cancelledDepositRequest(daveCid);
        assertEq(carolQueued, S_100K);
        assertEq(daveQueued,  S_100K);
        assertEq(spUsdc.convertToAssets(S_100K), A_100K);

        _pause();
        _adjust(-200_000e6);
        _unpause();

        assertEq(vault.chi(),                  908_718_991_417_809_087_250_757_776);
        assertEq(vault.totalAssets(),          1_799_999_999_996);
        assertEq(vault.assetsOf(alice),        899_999_999_998);  // -100_000_000_000 exactly
        assertEq(vault.convertToAssets(SH_1M), 899_999_999_998);  // bob's escrow, same
        ( ,, carolQueued ) = _depositRequest(carolId);
        ( ,, daveQueued  ) = _cancelledDepositRequest(daveCid);
        assertEq(carolQueued, S_100K);                             // untouched
        assertEq(daveQueued,  S_100K);
        assertEq(spUsdc.convertToAssets(S_100K), A_100K);
        assertEq(vault.claimableAssets(mallory), R_100K);          // untouched, in USDC
        assertEq(vault.totalClaimable(),         R_100K);
        assertEq(usdc.balanceOf(address(vault)), R_100K);

        // Carol fills at the post-loss price: more shares, same USD value.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.balanceOf(carol), 110_045_020_455);
        assertEq(vault.assetsOf(carol),  99_999_999_998);

        // Dave's refund is the full spUSDC value.
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(dave), A_100K);

        // Bob's escrow pays the post-loss value.
        _processRedeems(type(uint256).max, type(uint256).max);
        ( ,, uint256 left ) = _rawRedeem(redeemId);
        assertEq(left, 0);
        assertEq(usdc.balanceOf(bob), 899_999_999_998);

        // Mallory's parked USDC pays in full.
        _unblacklist(mallory);
        assertEq(vault.claim(mallory), R_100K);
    }

    // Capacity is in shares (:784), so after a loss the same free capacity is worth fewer USDC
    // and a deposit sized to the old USD headroom is only partially filled.
    function test_adjustTotalAssets_capacityInUsdShrinksAfterLoss() public {
        _deposit(alice, ONE_M);
        _setCapacity(SH_1M + SH_100K);
        assertEq(vault.availableCapacity(), SH_100K);
        assertEq(vault.convertToAssets(vault.availableCapacity()), R_100K);

        _adjustTotalAssetsWhilePaused(-int256(HUNDRED_K));
        assertEq(vault.availableCapacity(), SH_100K);
        assertEq(vault.convertToAssets(vault.availableCapacity()), 89_999_999_998);

        uint256 id = _deposit(bob, HUNDRED_K);
        assertEq(vault.balanceOf(bob), 99_040_518_407);  // SH_100K - 3
        assertEq(vault.assetsOf(bob),  89_999_999_996);
        ( ,, uint256 left ) = _depositRequest(id);
        assertEq(left, S_100K - 85_907_942_201);
        assertEq(vault.firstPendingDepositId(), 1);  // partial fill stays at the head
    }

    /**********************************************************************************************/
    /*** Open findings                                                                          ***/
    /**********************************************************************************************/

    // C-3 / R5-3 open, re-rated HIGH: there is no loss floor below `totalAssets_ > 0` (:274).
    // `-(totalAssets - 1)` leaves chi = floor(RAY / S) (~1e-12 USDC per share); every holder reads
    // 0 and even totalAssets() reads 0 because S * floor(RAY / S) < RAY. On c512609 this is one
    // call from LOSS_MANAGER_ROLE, a hot-wallet operational role (plus PAUSER for the pause), no
    // longer a governance spell. Recovery exists (a positive delta from the same role), but a
    // compromised key can also sandwich itself (see `AdjustTotalAssetsSandwichTests`).
    function test_BUG_C3_adjustTotalAssets_noFloor_totalAssetsMinusOneWipesHolders() public {
        _deposit(alice, ONE_M);
        _deposit(bob,   HUNDRED_K);
        _pause();

        uint256 ta = vault.totalAssets();
        assertEq(ta, 1_099_999_999_997);
        uint256 supply = vault.totalSupply();
        assertEq(supply, SH_1M + SH_100K);

        uint256 expectedChi = RAY / supply;
        assertEq(expectedChi, 917_897_971_131_388);

        vm.expectEmit(address(vault));
        emit TotalAssetsAdjusted(uint192(expectedChi), -int256(ta - 1));
        _adjust(-int256(ta - 1));

        assertEq(vault.chi(),            expectedChi);
        assertEq(vault.totalAssets(),    0);
        assertEq(vault.assetsOf(alice),  0);
        assertEq(vault.assetsOf(bob),    0);
        assertEq(vault.balanceOf(alice), SH_1M);
        assertEq(_vaultSpUsdc(),         S_1M + S_100K);  // ~1.1M USDC of backing still here

        // Nothing further can be taken (totalAssets is 0) and any gain divides the whole supply.
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(-1);

        // The VSR cannot undo it in any useful time: 100% APY for a year doubles 9e14 to 1.8e15.
        _setPrimeVsr(MAX_VSR);
        _warpAndDrip(365 days);
        assertLt(vault.chi(), 3 * expectedChi);
        assertEq(vault.totalAssets(), 1);
        _setPrimeVsr(RAY);

        // Recovery: admin writes the value back (1 wei short because totalAssets() reads 1).
        _adjust(int256(ta - 1));
        assertEq(vault.totalAssets(), 1_099_999_999_996);
        assertEq(vault.assetsOf(alice), 999_999_999_998);
    }

    // G-1 / R5-1 open: the only upper bound is `chi <= type(uint192).max` (:280), but `drip()`
    // (:655) and `nowChi()` (:846) compute `_rpow(vsr, dt) * chi` in uint256, so any chi above
    // CHI_DRIP_MAX = maxUint256 / RAY reverts one second later even at vsr == RAY. The smallest
    // delta reaching it at the harness supply is binary-searched here with snapshots: GAIN_BRICK,
    // writing CHI_BRICK (one wei less writes CHI_BELOW, which survives). Every entry point that
    // drips or converts then reverts, `adjustTotalAssets` included (it drips first, :270), so the
    // loss manager cannot undo it; only `upgradeToAndCall` (admin) recovers. A LOSS_MANAGER key
    // can therefore brick the vault in one call.
    function test_BUG_G1_adjustTotalAssets_aboveDripBoundBricksVault_onlyUpgradeRecovers() public {
        _deposit(alice, ONE_M);
        _setCapacity(0);
        uint256 bobId = _deposit(bob, HUNDRED_K);  // queued entry for the cancel path later
        _setCapacity(type(uint128).max);
        _pause();
        assertEq(CHI_DRIP_MAX, type(uint256).max / RAY);

        // Binary search the smallest delta after which drip() reverts one second later.
        uint256 lo = 1;
        uint256 hi = GAIN_TRUNCATE - 1;  // largest delta that passes `chi-too-high`
        while (lo < hi) {
            uint256 mid  = lo + (hi - lo) / 2;
            uint256 snap = vm.snapshotState();
            _adjust(int256(mid));
            _warp(1);
            bool ok;
            try vault.drip() { ok = true; } catch { ok = false; }
            vm.revertToState(snap);
            if (ok) lo = mid + 1; else hi = mid;
        }
        assertEq(lo, GAIN_BRICK);

        // One wei below: chi <= CHI_DRIP_MAX, drip survives the next second.
        uint256 snap2 = vm.snapshotState();
        _adjust(int256(GAIN_BRICK - 1));
        assertEq(vault.chi(), CHI_BELOW);
        assertLe(vault.chi(), CHI_DRIP_MAX);
        _warp(1);
        vault.drip();
        vault.nowChi();
        vm.revertToState(snap2);

        _adjust(int256(GAIN_BRICK));
        assertEq(vault.chi(), CHI_BRICK);
        assertGt(vault.chi(), CHI_DRIP_MAX);
        assertEq(vault.chi() - CHI_DRIP_MAX, 664_435_247_753_226);  // first reachable chi past the bound

        // Same second: views still answer (no multiplication by _rpow yet).
        assertEq(vault.totalAssets(), 114_681_085_459_449_903_921_529_244_645_760_026);

        _warp(1);

        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
        vm.expectRevert(stdError.arithmeticError);
        vault.nowChi();
        vm.expectRevert(stdError.arithmeticError);
        vault.totalAssets();
        vm.expectRevert(stdError.arithmeticError);
        vault.convertToShares(1);

        vm.prank(lossManager);
        vm.expectRevert(stdError.arithmeticError);
        vault.adjustTotalAssets(-1);
        vm.prank(lossManager);
        vm.expectRevert(stdError.arithmeticError);
        vault.adjustTotalAssets(type(int256).min);

        vm.prank(operator);
        vm.expectRevert(stdError.arithmeticError);
        vault.setVSR(RAY);

        _unpause();

        _fund(carol, ONE_M);
        vm.prank(carol);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(ONE_M, carol, 0);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestRedeem(1, alice);
        vm.prank(operator);
        vm.expectRevert(stdError.arithmeticError);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);
        vm.prank(operator);
        vm.expectRevert(stdError.arithmeticError);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);
        vm.prank(operator);
        vm.expectRevert(stdError.arithmeticError);
        vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);

        // Shares still move and the updaters work (no drip), but the cancel request drips now
        // through its self-skip walk (:445 -> :859), so bob's queued entry is stuck too; `claim`
        // still works.
        vm.prank(alice);
        assertTrue(vault.transfer(carol, 1));
        vm.prank(bob);
        vault.updateDepositRecipient(bobId, carol);
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDepositCancellation(bobId, bob, S_100K);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);

        // Only an upgrade recovers: `_authorizeUpgrade` (:213) does not drip.
        address impl = address(new ChiResetImpl());
        vm.prank(admin);
        vault.upgradeToAndCall(impl, abi.encodeCall(ChiResetImpl.resetChi, (uint192(CHI_P))));
        assertEq(vault.implementation(), impl);
        assertEq(vault.chi(), CHI_P);
        assertEq(vault.rho(), block.timestamp);
        _warp(1);
        vault.drip();
        assertEq(vault.totalAssets(), R_1M);
        assertEq(vault.assetsOf(alice), vault.convertToAssets(SH_1M - 1));
        vm.prank(bob);
        vault.requestDepositCancellation(bobId, bob, S_100K);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), A_100K);
    }

    // The safe band shrinks with the VSR: _rpow(vsr, dt) > RAY, so a chi that survives at
    // vsr == RAY overflows one second after any positive rate is set (setVSR drips in-block).
    function test_BUG_G1_adjustTotalAssets_dripBoundShrinksWithVsr() public {
        _depositAndPause(alice, ONE_M);
        _adjust(int256(GAIN_BRICK - 1));
        assertEq(vault.chi(), CHI_BELOW);

        _setPrimeVsr(ONE_PCT_VSR);  // same block: drip() returns early, no overflow yet
        _warp(1);
        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
        vm.expectRevert(stdError.arithmeticError);
        vault.nowChi();
    }

}

/// @dev R5-2 / R3-1 residue: the adjustment needs `paused`, but a gain that is known (or decided)
///      before the PAUSER's tx lands can be front-run by a deposit that instant-fills, and taken
///      out by a redeem queued right after the unpause. With LOSS_MANAGER a hot-wallet role the
///      same key can do all of it deliberately if it also holds PAUSER / UNPAUSER.
contract AdjustTotalAssetsSandwichTests is AdjustTotalAssetsBase {

    uint256 constant GAIN = 50_000e6;

    function _sandwich(uint256 feeRate) internal returns (uint256 profit, uint256 aliceShortfall) {
        _setRedeemFeeRate(feeRate);
        _deposit(alice, ONE_M);                 // honest holder
        _deposit(mallory, ONE_M);               // attacker, instant fill before the pause
        assertEq(vault.balanceOf(mallory), SH_1M);
        assertEq(vault.totalAssets(), 1_999_999_999_997);

        _pause();                               // PAUSER tx lands after the gain is known
        _adjust(int256(GAIN));
        _unpause();
        assertEq(vault.chi(), 1_034_929_962_448_270_700_987_302_681);

        uint256 id = _requestRedeem(mallory, SH_1M);
        _processRedeems(type(uint256).max, type(uint256).max);
        ( ,, uint256 left ) = _rawRedeem(id);
        assertEq(left, 0);

        profit = usdc.balanceOf(mallory) - ONE_M;

        // The gain was notional: the backing left for alice is short by exactly what left.
        uint256 backing = spUsdc.convertToAssets(_vaultSpUsdc());
        aliceShortfall  = vault.assetsOf(alice) - backing;
    }

    function test_BUG_R5_2_governanceSandwich_zeroFee() public {
        ( uint256 profit, uint256 shortfall ) = _sandwich(0);
        assertEq(usdc.balanceOf(mallory), 1_024_999_999_998);
        assertEq(profit,    24_999_999_998);    // half of the 50k gain
        assertEq(vault.assetsOf(alice), 1_024_999_999_998);
        assertEq(shortfall, 49_999_999_999);
    }

    function test_BUG_R5_2_governanceSandwich_onePctFee() public {
        ( uint256 profit, uint256 shortfall ) = _sandwich(0.01e18);
        assertEq(usdc.balanceOf(mallory), 1_014_749_999_997);
        assertEq(profit,    14_749_999_997);    // 25k gain share minus 1% of 1.025M
        assertEq(shortfall, 39_749_999_998);
    }

    // Cancellations are not pause-gated on c512609: a queued depositor that sees a LOSS coming
    // leaves during the pause window and never takes the hit. Alice (holder) loses the full 50k;
    // mallory's queued 1M walks out at A_1M.
    function test_BUG_R5_2_queuedDepositorExitsDuringPauseBeforeLoss() public {
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());
        uint256 id = _deposit(mallory, ONE_M);  // queued in spUSDC
        _pause();
        _cancel(mallory, id, mallory, S_1M);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(mallory), A_1M);
        _adjust(-int256(GAIN));
        _unpause();
        assertEq(vault.assetsOf(alice), 949_999_999_997);
        assertEq(vault.totalAssets(),   949_999_999_997);
    }

}
