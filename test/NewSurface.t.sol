// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../lib/forge-std/src/StdError.sol";

import { IAccessControl } from "../lib/oz/contracts/access/IAccessControl.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

/// @dev Tests for every surface that is NEW on `refactor/more-simplifying` @ ff828d2: owner-only
///      recipient updaters, `realizeLoss` with its new bounds, `realizeGain`, unbounded
///      `setCapacity`, `requestRedeem(0)`, head-advance loops, `delete` after fill, `pause` on
///      GUARDIAN, getters and event shapes.
///
///      Harness indexes (frozen at RAY after setUp):
///        spUSDC  chi_s = 1.047633055711877768967605062e27
///        spPRIME chi_p = 1.009687768242461209408770821e27
abstract contract NewSurfaceBase is LocalTestBase {

    event DepositRequest(
        address indexed owner,
        address indexed recipient,
        uint256 indexed requestId,
        uint256         assets,
        uint256         savingsShares
    );
    event Deposit(address indexed owner, address indexed recipient, uint256 assets, uint256 savingsShares);
    event Redeem(address indexed owner, address indexed recipient, uint256 shares, uint256 assets);
    event RedeemRequest(
        address indexed owner,
        address indexed recipient,
        uint256 indexed requestId,
        uint256         shares,
        uint256         fee
    );
    event DepositRecipientUpdated(uint256 indexed requestId, address indexed recipient);
    event CancelledDepositRecipientUpdated(uint256 indexed requestId, address indexed recipient);
    event RedeemRecipientUpdated(uint256 indexed requestId, address indexed recipient);
    event LossRealized(uint192 chi, uint256 loss);
    event GainRealized(uint192 chi, uint256 gain);
    event Paused();
    event Unpaused();

    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address carol   = makeAddr("carol");
    address mallory = makeAddr("mallory");

    uint256 constant CHI_S = 1.047633055711877768967605062e27;
    uint256 constant CHI_P = 1.009687768242461209408770821e27;

    uint256 constant ONE_M     = 1_000_000e6;
    uint256 constant HUNDRED_K = 100_000e6;

    uint256 constant S_1M   = 954_532_691_143;
    uint256 constant S_100K = 95_453_269_114;
    uint256 constant A_1M   = 999_999_999_999;
    uint256 constant A_100K = 99_999_999_999;
    uint256 constant SH_1M   = 990_405_184_109;
    uint256 constant SH_100K = 99_040_518_410;

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _depositLength() internal view returns (uint256 len) {
        while (true) {
            try vault.depositQueue(len) { len++; } catch { return len; }
        }
    }

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, who, role
        );
    }

    function test_harnessConstants() public view {
        assertEq(spUsdc.nowChi(), CHI_S);
        assertEq(vault.nowChi(),  CHI_P);
        assertEq(spUsdc.convertToShares(ONE_M), S_1M);
        assertEq(spUsdc.convertToAssets(S_1M),  A_1M);
        assertEq(vault.convertToShares(A_1M),   SH_1M);
    }

}

contract NewSurfaceTest is NewSurfaceBase {

    /**********************************************************************************************/
    /*** 11. Recipient updaters are owner-only (V2-1 fixed at ff828d2)                          ***/
    /**********************************************************************************************/

    // `updateDepositRecipient` (lines 416-424): the owner redirects the fill and the exact spPRIME
    // amount that anyone used to be able to steal goes to the owner's choice.
    function test_updateDepositRecipient_ownerRedirectsQueuedDeposit() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);

        ( address owner, address recipient, uint256 shares ) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    S_1M);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit DepositRecipientUpdated(id, bob);
        vault.updateDepositRecipient(id, bob);

        ( owner, recipient, shares ) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);

        vm.roll(block.number + 1);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.balanceOf(bob),   SH_1M);   // 990_405_184_109 spPRIME, ~999_999.99 USDC
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.depositHead(),    1);
    }

    function test_updateDepositRecipient_strangerGuardianAdminAndRecipientRevert() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);

        address[3] memory who = [mallory, guardian, admin];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.updateDepositRecipient(id, who[i]);
        }

        // Being the current recipient grants nothing either: only `owner` may re-point.
        vm.prank(alice);
        vault.updateDepositRecipient(id, bob);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositRecipient(id, mallory);

        ( address owner, address recipient, uint256 shares ) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.balanceOf(bob),     SH_1M);
        assertEq(vault.balanceOf(mallory), 0);
    }

    // A partially filled head entry still has `shares != 0`, so the owner can redirect the rest.
    function test_updateDepositRecipient_ownerRedirectsRemainderOfPartialFill() public {
        _setCapacity(SH_100K);  // room for ~100k of alice's 1M
        uint256 fillable = spUsdc.convertToShares(vault.convertToAssets(SH_100K));
        assertEq(fillable, S_100K - 2);
        uint256 id = _deposit(alice, ONE_M);
        uint256 aliceShares = vault.balanceOf(alice);
        assertEq(aliceShares, SH_100K - 2);
        ( ,, uint256 left ) = _depositRequest(id);
        assertEq(left, S_1M - fillable);

        vm.prank(mallory);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositRecipient(id, mallory);

        vm.prank(alice);
        vault.updateDepositRecipient(id, bob);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.balanceOf(alice), aliceShares);
        assertEq(vault.balanceOf(bob),   vault.totalSupply() - aliceShares);
        assertGt(vault.balanceOf(bob),   890_000e6);
    }

    // A filled entry is deleted (owner 0, shares 0): `no-request` fires before the owner check,
    // and nothing is written into the dead slot any more.
    function test_updateDepositRecipient_filledEntryRevertsNoRequest() public {
        uint256 id = _deposit(alice, ONE_M);  // instant fill, deleted
        assertEq(vault.balanceOf(alice), SH_1M);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateDepositRecipient(id, bob);

        vm.prank(mallory);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateDepositRecipient(id, mallory);

        ( address o, address r, uint256 s ) = _depositRequest(id);
        assertEq(o, address(0));
        assertEq(r, address(0));
        assertEq(s, 0);
    }

    function test_updateDepositRecipient_cancelledEntryRevertsNoRequest() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        vault.cancelDepositRequest(id, alice);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateDepositRecipient(id, bob);
    }

    // `updateRedeemRecipient` (lines 537-545): same shape, for the USDC paid on a queued redeem.
    function test_updateRedeemRecipient_ownerRedirectsQueuedRedeem() public {
        _deposit(alice, ONE_M);
        assertEq(vault.balanceOf(alice), SH_1M);
        uint256 id = _requestRedeem(alice, SH_1M);

        uint256 expectedAssets = vault.convertToAssets(SH_1M);
        assertEq(expectedAssets, 999_999_999_998);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit RedeemRecipientUpdated(id, bob);
        vault.updateRedeemRecipient(id, bob);

        ( address owner, address recipient, uint256 shares ) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    SH_1M);

        vm.roll(block.number + 1);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(bob),    expectedAssets);
        assertEq(usdc.balanceOf(alice),  0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.redeemHead(),     1);
    }

    function test_updateRedeemRecipient_strangerGuardianAndRecipientRevert() public {
        _deposit(alice, ONE_M);
        uint256 id = _requestRedeem(alice, SH_1M);

        address[3] memory who = [mallory, guardian, admin];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.updateRedeemRecipient(id, who[i]);
        }

        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateRedeemRecipient(id, mallory);

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),     999_999_999_998);
        assertEq(usdc.balanceOf(mallory), 0);
    }

    function test_updateRedeemRecipient_filledAndCancelledEntriesRevertNoRequest() public {
        _deposit(alice, ONE_M);
        uint256 filled = _requestRedeem(alice, SH_100K);
        _processRedeems(type(uint256).max, type(uint256).max);
        ( ,, uint256 s ) = _redeemRequest(filled);
        assertEq(s, 0);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateRedeemRecipient(filled, bob);

        uint256 cancelled = _requestRedeem(alice, SH_100K);
        vm.prank(alice);
        vault.cancelRedeemRequest(cancelled, alice);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.updateRedeemRecipient(cancelled, bob);
    }

    // `updateCancelledDepositRecipient` (lines 465-477): same shape, for the USDC refund.
    function test_updateCancelledDepositRecipient_ownerRedirectsRefund() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        uint256 cid = vault.cancelDepositRequest(id, alice);

        vm.prank(mallory);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateCancelledDepositRecipient(cid, mallory);

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateCancelledDepositRecipient(cid, guardian);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit CancelledDepositRecipientUpdated(cid, bob);
        vault.updateCancelledDepositRecipient(cid, bob);

        ( address owner, address recipient, uint256 shares ) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    S_1M);

        vm.roll(block.number + 1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(bob),   A_1M);
        assertEq(usdc.balanceOf(alice), 0);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");  // settled entry
        vault.updateCancelledDepositRecipient(cid, alice);
    }

    // The cancelled entry keeps the depositor as `owner` even when the GUARDIAN cancelled and
    // named itself as recipient (F-1), so the depositor can re-point the refund to themselves
    // before settlement. This is the first user-side mitigation of F-1.
    function test_updateCancelledDepositRecipient_ownerReclaimsGuardianChosenRecipient() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);

        vm.prank(guardian);
        uint256 cid = vault.cancelDepositRequest(id, guardian);
        ( address owner, address recipient, ) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, guardian);

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateCancelledDepositRecipient(cid, guardian);

        vm.prank(alice);
        vault.updateCancelledDepositRecipient(cid, alice);

        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice),    A_1M);
        assertEq(usdc.balanceOf(guardian), 0);
    }

    // `invalid-recipient` is checked before the entry is loaded, so it fires even on ids that do
    // not exist.
    function test_updateRecipient_zeroRecipientReverts() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateDepositRecipient(id, address(0));
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateDepositRecipient(99, address(0));
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateCancelledDepositRecipient(0, address(0));
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateRedeemRecipient(0, address(0));
    }

    /**********************************************************************************************/
    /*** 12. realizeLoss                                                                        ***/
    /**********************************************************************************************/

    // chi' = floor((totalAssets - L) * RAY / S); the floor is against holders (line 382).
    function test_realizeLoss_exactChiAndTotalAssets() public {
        _deposit(alice, ONE_M);
        _pause();

        uint256 loss      = HUNDRED_K;
        uint256 chiBefore = vault.nowChi();
        uint256 taBefore  = vault.totalAssets();
        uint256 supply    = vault.totalSupply();

        assertEq(chiBefore, CHI_P);
        assertEq(taBefore,  999_999_999_998);
        assertEq(supply,    SH_1M);

        uint256 expectedChi = ((taBefore - loss) * RAY) / supply;
        assertEq(expectedChi, 908_718_991_417_304_243_366_635_929);
        assertLt(expectedChi, chiBefore);

        vm.expectEmit(address(vault));
        emit LossRealized(uint192(expectedChi), loss);
        _realizeLoss(loss);

        assertEq(vault.chi(),    expectedChi);
        assertEq(vault.nowChi(), expectedChi);
        assertEq(vault.rho(),    block.timestamp);

        uint256 drop = taBefore - vault.totalAssets();
        assertGe(drop, loss);       // floor: holders never lose less than L
        assertLe(drop, loss + 1);   // and at most 1 wei more
        assertEq(drop, loss + 1);   // exact at these indexes
    }

    function test_realizeLoss_revertsWhenNotPaused() public {
        _deposit(alice, ONE_M);
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/not-paused");
        vault.realizeLoss(1);
    }

    function test_realizeLoss_revertsOnZeroLoss() public {
        _deposit(alice, ONE_M);
        _pause();
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(0);
    }

    function test_realizeLoss_revertsForNonRiskManager() public {
        _deposit(alice, ONE_M);
        _pause();
        address[3] memory who = [admin, guardian, alice];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(_unauthorized(who[i], RISK_MANAGER_ROLE));
            vault.realizeLoss(1);
        }
    }

    // totalSupply == 0 implies totalAssets() == 0, so `loss_ < totalAssets_` (line 376) fails for
    // every loss before the `no-shares` check (line 380) is reached: that require is dead code.
    function test_realizeLoss_zeroSupplyRevertsInvalidLossNotNoShares() public {
        _pause();
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);

        uint256[3] memory losses = [uint256(1), 1e12, type(uint256).max];
        for (uint256 i; i < 3; ++i) {
            vm.prank(riskManager);
            vm.expectRevert("SparkPrimeVault/invalid-loss");
            vault.realizeLoss(losses[i]);
        }
    }

    // V2-3 regression: a full loss and anything above it is a clean revert, the index survives.
    function test_realizeLoss_fullLossAndAboveRevertInvalidLoss() public {
        _deposit(alice, ONE_M);
        _pause();
        uint256 ta = vault.totalAssets();
        assertEq(ta, 999_999_999_998);

        uint256[3] memory losses = [ta, ta + 1, type(uint256).max];
        for (uint256 i; i < 3; ++i) {
            vm.prank(riskManager);
            vm.expectRevert("SparkPrimeVault/invalid-loss");
            vault.realizeLoss(losses[i]);
        }

        assertEq(vault.chi(), CHI_P);
        _unpause();
        _deposit(bob, HUNDRED_K);
        assertEq(vault.balanceOf(bob), SH_100K);
    }

    // C-3 persists: there is no floor below `loss < totalAssets`. `loss = totalAssets - 1` leaves
    // chi = floor(RAY / S) = 1_009_687_768_243_692 (~1e-12 USDC per share); every holder reads 0
    // and even totalAssets() reads 0 because S * floor(RAY / S) < RAY. A hot-wallet RISK_MANAGER
    // can do this in one call while paused. Recovery now exists through `realizeGain`.
    function test_BUG_realizeLoss_noFloor_totalAssetsMinusOneWipesHolders() public {
        _deposit(alice, ONE_M);
        _pause();

        uint256 ta = vault.totalAssets();
        assertEq(ta, 999_999_999_998);

        uint256 expectedChi = RAY / SH_1M;
        assertEq(expectedChi, 1_009_687_768_243_692);

        vm.expectEmit(address(vault));
        emit LossRealized(uint192(expectedChi), ta - 1);
        _realizeLoss(ta - 1);

        assertEq(vault.chi(),            expectedChi);
        assertEq(vault.totalAssets(),    0);        // S * chi / RAY floors to 0
        assertEq(vault.assetsOf(alice),  0);
        assertEq(vault.balanceOf(alice), SH_1M);
        assertEq(_vaultSpUsdc(),         S_1M);     // ~1M USDC of backing still in the vault

        // Nothing further can be realized as a loss (totalAssets is 0).
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(1);

        // The VSR cannot undo it in any useful time: 100% APY for a year doubles 1e15 to 2e15.
        _setPrimeVsr(MAX_VSR);
        _warpAndDrip(365 days);
        assertLt(vault.chi(), 3 * expectedChi);
        assertEq(vault.totalAssets(), 1);
        _setPrimeVsr(RAY);

        // `realizeGain` is the only recovery: admin writes the value back.
        vm.prank(admin);
        vault.realizeGain(ta - 1);
        assertGe(vault.totalAssets(), ta - 1);
        assertLe(vault.totalAssets(), ta);
        assertGe(vault.assetsOf(alice), ta - 1);
    }

    // With totalSupply == 1 share totalAssets() is 1 wei, so `loss < 1` admits no loss at all.
    function test_realizeLoss_oneShareSupplyAdmitsNoLoss() public {
        _deposit(alice, 3);  // 3 wei USDC -> 2 spUSDC shares -> 2 wei -> 1 spPRIME share
        assertEq(vault.totalSupply(), 1);
        assertEq(vault.totalAssets(), 1);

        _pause();
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(1);
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/invalid-loss");
        vault.realizeLoss(0);
        assertEq(vault.chi(), CHI_P);
    }

    // chi == 0 is still reachable once totalSupply > RAY (1e27 shares = ~1e21 USDC here): then
    // floor(1 * RAY / S) == 0 and the old V2-3 shape (division by zero in convertToShares,
    // dead index) returns until admin calls `realizeGain`. Info: needs a 1e21 USDC vault.
    function test_realizeLoss_chiZeroStillReachableAboveRaySupply() public {
        _deposit(alice, 1.2e27);
        uint256 supply = vault.totalSupply();
        assertGt(supply, RAY);
        uint256 ta = vault.totalAssets();

        _pause();
        _realizeLoss(ta - 1);
        assertEq(vault.chi(),    0);
        assertEq(vault.nowChi(), 0);
        assertEq(vault.totalAssets(), 0);
        vm.expectRevert(stdError.divisionError);
        vault.convertToShares(1);

        vm.prank(admin);
        vault.realizeGain(ta);
        assertEq(vault.chi(), (ta * RAY) / supply);
        assertGt(vault.chi(), 0);
    }

    function test_realizeLoss_escrowedRedeemSharesTakeLossQueuedDepositsDoNot() public {
        _deposit(alice, ONE_M);
        _deposit(bob,   ONE_M);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 redeemId  = _requestRedeem(bob, bobShares);
        assertEq(vault.balanceOf(address(vault)), bobShares);

        _setCapacity(vault.totalSupply());           // close capacity
        uint256 carolId = _deposit(carol, HUNDRED_K);
        assertEq(vault.balanceOf(carol), 0);
        ( ,, uint256 carolQueued ) = _depositRequest(carolId);
        assertEq(carolQueued, S_100K);

        uint256 aliceBefore  = vault.assetsOf(alice);
        uint256 escrowBefore = vault.convertToAssets(bobShares);
        assertEq(aliceBefore,  999_999_999_998);
        assertEq(escrowBefore, 999_999_999_998);

        _pause();
        _realizeLoss(200_000e6);
        _unpause();

        uint256 aliceDrop  = aliceBefore  - vault.assetsOf(alice);
        uint256 escrowDrop = escrowBefore - vault.convertToAssets(bobShares);
        assertGe(aliceDrop,  HUNDRED_K);
        assertLe(aliceDrop,  HUNDRED_K + 2);
        assertGe(escrowDrop, HUNDRED_K);
        assertLe(escrowDrop, HUNDRED_K + 2);

        // Carol's queued spUSDC is untouched and fills at the post-loss price (more shares).
        ( ,, uint256 carolAfter ) = _depositRequest(carolId);
        assertEq(carolAfter, S_100K);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        assertGt(vault.balanceOf(carol), SH_100K);
        uint256 carolValue = vault.assetsOf(carol);
        assertGe(carolValue, A_100K - 2);
        assertLe(carolValue, A_100K);

        // Bob's escrowed redeem pays the post-loss value.
        _processRedeems(type(uint256).max, type(uint256).max);
        ( ,, uint256 remaining ) = _redeemRequest(redeemId);
        assertEq(remaining, 0);
        assertGe(usdc.balanceOf(bob), 899_999_999_990);
        assertLe(usdc.balanceOf(bob), 900_000_000_000);
    }

    // uint192 cast (line 382): chi' <= chi for every admitted loss and chi' >= floor(RAY / S) > 0
    // while S < RAY, so the cast cannot truncate and chi cannot hit 0. Info only.
    function testFuzz_realizeLoss_newChiNeverExceedsOld(uint256 loss) public {
        _deposit(alice, ONE_M);
        _pause();
        uint256 ta  = vault.totalAssets();
        uint256 chi = vault.chi();
        loss = bound(loss, 1, ta - 1);

        _realizeLoss(loss);

        assertLe(vault.chi(), chi);
        assertGe(vault.chi(), RAY / SH_1M);
        assertLe(vault.totalAssets(), ta - loss);
        assertGe(vault.totalAssets() + 1, ta - loss);
        assertLt(vault.chi(), 2 ** 192);
    }

}

contract NewSurfaceRealizeGainTest is NewSurfaceBase {

    /**********************************************************************************************/
    /*** 12b. realizeGain (new at ff828d2)                                                      ***/
    /**********************************************************************************************/

    uint256 constant CHI_GAIN_100K = 1_110_656_545_066_042_825_345_107_777;

    // Smallest gain for which (TA + gain) * RAY / S >= 2^192 at the harness supply.
    uint256 constant GAIN_TRUNCATE = 6_216_874_099_906_568_962_213_193_772_734_343_774_180_112;

    // Largest chi that drip() can multiply by RAY (vsr == RAY) without overflowing.
    uint256 constant CHI_DRIP_MAX = 115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640;

    // Smallest gain that pushes chi above CHI_DRIP_MAX at the harness supply.
    uint256 constant GAIN_BRICK = 114_681_085_459_449_903_921_528_244_645_760_029;

    // Smallest gain for which (TA + gain) * RAY overflows uint256.
    uint256 constant GAIN_OVERFLOW = 115_792_089_237_316_195_423_570_985_008_687_907_852_269_984_665_643;

    function _realizeGain(uint256 gain) internal {
        vm.prank(admin);
        vault.realizeGain(gain);
    }

    // chi' = floor((totalAssets + G) * RAY / S) (line 306); totalAssets rises by G or G - 1.
    function test_realizeGain_exactChiEventAndTotalAssets() public {
        _deposit(alice, ONE_M);

        uint256 gain     = HUNDRED_K;
        uint256 taBefore = vault.totalAssets();
        assertEq(taBefore,            999_999_999_998);
        assertEq(vault.totalSupply(), SH_1M);

        uint256 expectedChi = ((taBefore + gain) * RAY) / SH_1M;
        assertEq(expectedChi, CHI_GAIN_100K);
        assertGt(expectedChi, CHI_P);

        vm.expectEmit(address(vault));
        emit GainRealized(uint192(expectedChi), gain);
        _realizeGain(gain);

        assertEq(vault.chi(),    expectedChi);
        assertEq(vault.nowChi(), expectedChi);

        uint256 rise = vault.totalAssets() - taBefore;
        assertGe(rise, gain - 1);
        assertLe(rise, gain);
        assertEq(rise, gain - 1);  // exact at these indexes: 1_099_999_999_997
        assertEq(vault.assetsOf(alice), 1_099_999_999_997);
    }

    function test_realizeGain_revertsForNonAdmin() public {
        _deposit(alice, ONE_M);
        address[5] memory who = [riskManager, guardian, setter, rebalancer, alice];
        for (uint256 i; i < 5; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(_unauthorized(who[i], DEFAULT_ADMIN_ROLE));
            vault.realizeGain(1);
        }
    }

    function test_realizeGain_revertsOnZeroGain() public {
        _deposit(alice, ONE_M);
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/invalid-gain");
        vault.realizeGain(0);
    }

    // `invalid-gain` is checked before `no-shares`.
    function test_realizeGain_revertsOnZeroSupply() public {
        assertEq(vault.totalSupply(), 0);
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/no-shares");
        vault.realizeGain(1);
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/invalid-gain");
        vault.realizeGain(0);
    }

    // No `whenNotPaused` and no `require(paused)`: a gain can be written mid-incident, while
    // `realizeLoss` is restricted to the paused state.
    function test_realizeGain_worksPausedAndUnpaused() public {
        _deposit(alice, ONE_M);

        _realizeGain(1e6);
        uint256 chiUnpaused = vault.chi();
        assertGt(chiUnpaused, CHI_P);

        _pause();
        _realizeGain(1e6);
        assertGt(vault.chi(), chiUnpaused);
        assertTrue(vault.paused());
    }

    // Accrued but undripped yield is folded in first: the gain is applied on top of nowChi().
    function test_realizeGain_dripsBeforeApplyingGain() public {
        _deposit(alice, ONE_M);
        _setPrimeVsr(TEN_PCT_VSR);
        _warp(365 days);

        uint256 taAccrued = vault.totalAssets();  // uses nowChi()
        assertGt(taAccrued, 1_099_000e6);
        assertEq(vault.rho(), block.timestamp - 365 days);

        uint256 expectedChi = ((taAccrued + HUNDRED_K) * RAY) / SH_1M;
        _realizeGain(HUNDRED_K);

        assertEq(vault.chi(), expectedChi);
        assertEq(vault.rho(), block.timestamp);
        assertGe(vault.totalAssets(), taAccrued + HUNDRED_K - 1);
        assertLe(vault.totalAssets(), taAccrued + HUNDRED_K);
    }

    function test_realizeGain_escrowedRedeemSharesAndHoldersShareGainQueuedDepositsDoNot() public {
        _deposit(alice, ONE_M);
        _deposit(bob,   ONE_M);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 redeemId  = _requestRedeem(bob, bobShares);

        _setCapacity(vault.totalSupply());
        uint256 carolId = _deposit(carol, HUNDRED_K);
        ( ,, uint256 carolQueued ) = _depositRequest(carolId);
        assertEq(carolQueued, S_100K);

        uint256 aliceBefore  = vault.assetsOf(alice);
        uint256 escrowBefore = vault.convertToAssets(bobShares);
        assertEq(aliceBefore,  999_999_999_998);
        assertEq(escrowBefore, 999_999_999_998);

        _realizeGain(200_000e6);

        uint256 aliceRise  = vault.assetsOf(alice) - aliceBefore;
        uint256 escrowRise = vault.convertToAssets(bobShares) - escrowBefore;
        assertGe(aliceRise,  HUNDRED_K - 2);
        assertLe(aliceRise,  HUNDRED_K);
        assertGe(escrowRise, HUNDRED_K - 2);
        assertLe(escrowRise, HUNDRED_K);

        // Carol's queued spUSDC did not participate: fills for fewer shares, same value.
        ( ,, uint256 carolAfter ) = _depositRequest(carolId);
        assertEq(carolAfter, S_100K);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        assertLt(vault.balanceOf(carol), SH_100K);
        assertGe(vault.assetsOf(carol), A_100K - 2);
        assertLe(vault.assetsOf(carol), A_100K);

        // Bob's escrowed redeem pays the post-gain value (needs the extra USDC to exist).
        _returnSpUsdcLiquidity(200_000e6);
        _processRedeems(type(uint256).max, type(uint256).max);
        ( ,, uint256 remaining ) = _redeemRequest(redeemId);
        assertEq(remaining, 0);
        assertGe(usdc.balanceOf(bob), 1_099_999_999_990);
        assertLe(usdc.balanceOf(bob), 1_100_000_000_000);
    }

    function test_realizeGain_repeatedGainsAccumulate() public {
        _deposit(alice, ONE_M);
        uint256 ta0 = vault.totalAssets();

        _realizeGain(HUNDRED_K);
        uint256 ta1  = vault.totalAssets();
        uint256 chi2 = ((ta1 + HUNDRED_K) * RAY) / SH_1M;

        _realizeGain(HUNDRED_K);
        assertEq(vault.chi(), chi2);
        assertGe(vault.totalAssets(), ta0 + 2 * HUNDRED_K - 2);
        assertLe(vault.totalAssets(), ta0 + 2 * HUNDRED_K);
    }

    // gain G then loss G: at most 2 wei of floor drift, never a net gain for holders.
    function test_realizeGain_thenLossRoundTripBound() public {
        _deposit(alice, ONE_M);
        uint256 ta0  = vault.totalAssets();
        uint256 chi0 = vault.chi();

        _realizeGain(HUNDRED_K);
        _pause();
        _realizeLoss(HUNDRED_K);

        assertLe(vault.chi(), chi0);
        assertLe(vault.totalAssets(), ta0);
        assertGe(vault.totalAssets(), ta0 - 2);
    }

    // (a) The uint192 cast on line 306 is unchecked. At the harness supply any gain of at least
    // GAIN_TRUNCATE (~6.2e36 USDC) produces a quotient >= 2^192 that wraps to a tiny chi: holders
    // read 0 and the event advertises the wrapped value. Recoverable by another realizeGain.
    function test_BUG_realizeGain_uint192TruncationWrapsChiToDust() public {
        _deposit(alice, ONE_M);
        uint256 ta = vault.totalAssets();

        // Just below the threshold the quotient fits (and is already far above CHI_DRIP_MAX).
        uint256 snap = vm.snapshotState();
        uint256 fits = ((ta + GAIN_TRUNCATE - 1) * RAY) / SH_1M;
        assertLt(fits, 2 ** 192);
        _realizeGain(GAIN_TRUNCATE - 1);
        assertEq(vault.chi(), fits);
        vm.revertToState(snap);

        uint256 quotient = ((ta + GAIN_TRUNCATE) * RAY) / SH_1M;
        assertGe(quotient, 2 ** 192);
        uint256 wrapped = quotient % (2 ** 192);
        assertEq(wrapped, 458_233_707_431_279);

        vm.expectEmit(address(vault));
        emit GainRealized(uint192(wrapped), GAIN_TRUNCATE);
        _realizeGain(GAIN_TRUNCATE);

        assertEq(vault.chi(),           wrapped);
        assertEq(vault.totalAssets(),   0);
        assertEq(vault.assetsOf(alice), 0);
        assertEq(_vaultSpUsdc(),        S_1M);

        _realizeGain(ta);
        assertGe(vault.totalAssets(), ta - 1);
        assertLe(vault.totalAssets(), ta);
    }

    // (b) Above GAIN_OVERFLOW the multiplication `(totalAssets + gain) * RAY` overflows and the
    // call reverts with a panic; one below still goes through (and wraps per (a)).
    function test_realizeGain_uint256OverflowRevertsAboveThreshold() public {
        _deposit(alice, ONE_M);
        uint256 ta = vault.totalAssets();
        assertEq(GAIN_OVERFLOW, type(uint256).max / RAY - ta + 1);

        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        vault.realizeGain(GAIN_OVERFLOW);

        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        vault.realizeGain(type(uint256).max);

        _realizeGain(GAIN_OVERFLOW - 1);
        assertLt(vault.chi(), 2 ** 192);
    }

    // (c) A-9 brick: once chi > maxUint256 / RAY, `_rpow(vsr, dt) * chi` in drip() (line 649)
    // and nowChi() (line 698) overflows as soon as one second passes. Every entry point that
    // drips or converts reverts, including realizeGain and realizeLoss, so there is no recovery
    // short of an upgrade. Transfers keep working. Threshold gain at the harness supply:
    // GAIN_BRICK (~1.15e29 USDC); one wei below is fine (at vsr == RAY).
    function test_BUG_realizeGain_aboveDripThresholdBricksVault() public {
        _deposit(alice, ONE_M);
        _setCapacity(0);
        uint256 bobId = _deposit(bob, HUNDRED_K);  // queued entry to exercise the cancel path later
        _setCapacity(type(uint128).max);
        uint256 ta = vault.totalAssets();
        assertEq(CHI_DRIP_MAX, type(uint256).max / RAY);

        // One wei below: chi <= CHI_DRIP_MAX, drip survives the next second.
        uint256 snap = vm.snapshotState();
        _realizeGain(GAIN_BRICK - 1);
        assertEq(vault.chi(), 115_792_089_237_316_195_423_570_985_008_687_907_508_017_464_175_173);
        assertLe(vault.chi(), CHI_DRIP_MAX);
        _warp(1);
        vault.drip();
        vault.nowChi();
        vm.revertToState(snap);

        _realizeGain(GAIN_BRICK);
        assertEq(vault.chi(), 115_792_089_237_316_195_423_570_985_008_687_908_517_705_232_418_866);
        assertGt(vault.chi(), CHI_DRIP_MAX);

        // Same block: views still answer (no multiplication by _rpow yet).
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

        _fund(carol, ONE_M);
        vm.prank(carol);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(ONE_M, carol);

        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestRedeem(1, alice);

        vm.prank(rebalancer);
        vm.expectRevert(stdError.arithmeticError);
        vault.processDepositQueue(type(uint256).max, type(uint256).max);
        vm.prank(rebalancer);
        vm.expectRevert(stdError.arithmeticError);
        vault.processRedeemQueue(type(uint256).max, type(uint256).max);
        vm.prank(rebalancer);
        vm.expectRevert(stdError.arithmeticError);
        vault.processCancelledDepositQueue(type(uint256).max, type(uint256).max);

        vm.prank(setter);
        vm.expectRevert(stdError.arithmeticError);
        vault.setVSR(RAY);

        vm.prank(admin);
        vm.expectRevert(stdError.arithmeticError);
        vault.realizeGain(1);

        _pause();
        vm.prank(riskManager);
        vm.expectRevert(stdError.arithmeticError);
        vault.realizeLoss(1);

        // Shares still move; the cancel path (no drip) still works for bob's queued entry.
        vm.prank(alice);
        assertTrue(vault.transfer(carol, 1));
        _unpause();
        vm.prank(bob);
        vault.cancelDepositRequest(bobId, bob);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S_100K);
        assertEq(_vaultSpUsdc(), S_1M + S_100K);
        assertGt(ta, 0);
    }

    // The safe band shrinks with the VSR: _rpow(vsr, dt) > RAY, so a chi that survives at
    // vsr == RAY overflows one second after any positive rate is set.
    function test_BUG_realizeGain_dripThresholdShrinksWithVsr() public {
        _deposit(alice, ONE_M);
        _realizeGain(GAIN_BRICK - 1);
        assertLe(vault.chi(), CHI_DRIP_MAX);

        _setPrimeVsr(ONE_PCT_VSR);  // same block: drip() returns early, no overflow yet
        _warp(1);
        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
        vm.expectRevert(stdError.arithmeticError);
        vault.nowChi();
    }

}

contract NewSurfaceMiscTest is NewSurfaceBase {

    /**********************************************************************************************/
    /*** 13. setCapacity lost its uint128 bound                                                 ***/
    /**********************************************************************************************/

    // `convertToAssets(availableCapacity())` (line 704) multiplies the free capacity by chi, so
    // any capacity above maxUint256 / chi + totalSupply makes every requestDeposit and
    // processDepositQueue panic. The safe bound shrinks as chi grows.
    function test_BUG_setCapacity_maxUint256BricksDeposits() public {
        _setCapacity(type(uint256).max);
        _fund(alice, ONE_M);

        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(ONE_M, alice);

        vm.prank(rebalancer);
        vm.expectRevert(stdError.arithmeticError);
        vault.processDepositQueue(type(uint256).max, type(uint256).max);

        // Exact edge at supply 0: floor(maxUint256 / chi) is safe, one more is not.
        uint256 safe = type(uint256).max / vault.nowChi();
        assertEq(safe, 114_681_085_459_589_801_375_833_087_904_206_311_575_507_395_147_570);  // ~1.1e50 shares

        _setCapacity(safe + 1);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(ONE_M, alice);

        _setCapacity(safe);
        vm.prank(alice);
        vault.requestDeposit(ONE_M, alice);
        assertEq(vault.balanceOf(alice), SH_1M);

        // A capacity that was safe today bricks deposits once chi has grown.
        _setPrimeVsr(MAX_VSR);
        _warp(1 days);
        _fund(bob, ONE_M);
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        vault.requestDeposit(ONE_M, bob);

        vm.prank(rebalancer);
        vm.expectRevert(stdError.arithmeticError);
        vault.processDepositQueue(type(uint256).max, type(uint256).max);

        // Admin recovers by lowering the capacity.
        _setCapacity(type(uint128).max);
        vm.prank(bob);
        vault.requestDeposit(ONE_M, bob);
        assertGt(vault.balanceOf(bob), 0);
    }

    /**********************************************************************************************/
    /*** 14. requestRedeem(0)                                                                   ***/
    /**********************************************************************************************/

    function test_requestRedeem_zeroSharesCreatesGhostEntry() public {
        _setRedeemFeeRate(vault.MAX_REDEEM_FEE());
        assertEq(vault.minRedeem(),        0);
        assertEq(vault.balanceOf(mallory), 0);

        vm.prank(mallory);
        vm.expectEmit(address(vault));
        emit RedeemRequest(mallory, mallory, 0, 0, 0);
        uint256 id = vault.requestRedeem(0, mallory);

        assertEq(id, 0);
        ( address owner, address recipient, uint256 shares ) = _redeemRequest(id);
        assertEq(owner,     mallory);
        assertEq(recipient, mallory);
        assertEq(shares,    0);
        assertEq(vault.pendingRedeemShares(), 0);

        vm.prank(mallory);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(id, mallory);
    }

    // Ghost entries ahead of a real one consume `maxRequests` (C-12 persists).
    function test_requestRedeem_ghostsConsumeMaxRequests() public {
        _deposit(alice, ONE_M);
        for (uint256 i; i < 3; ++i) {
            vm.prank(mallory);
            vault.requestRedeem(0, mallory);
        }
        uint256 id = _requestRedeem(alice, SH_1M);
        assertEq(id, 3);

        _processRedeems(type(uint256).max, 3);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.redeemHead(),    3);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 999_999_999_998);
        assertEq(vault.redeemHead(),    4);
    }

    function test_requestRedeem_zeroSharesRevertsWithMinRedeem() public {
        _setMinRedeem(1);
        vm.prank(mallory);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(0, mallory);
    }

    /**********************************************************************************************/
    /*** 15. Head-advance loops                                                                 ***/
    /**********************************************************************************************/

    function test_requestDeposit_skipsGhostsAndFillsInstantly() public {
        _setCapacity(0);
        _fund(mallory, 0);
        for (uint256 i; i < 3; ++i) {
            vm.prank(mallory);
            assertEq(vault.requestDeposit(0, mallory), i);
        }
        assertEq(vault.depositHead(), 2);  // each ghost walked one step, none filled
        assertEq(_depositLength(),    3);

        _setCapacity(type(uint128).max);
        uint256 id = _deposit(bob, ONE_M);
        assertEq(id,                     3);
        assertEq(vault.balanceOf(bob),   SH_1M);
        assertEq(vault.depositHead(),    4);
        assertEq(_depositLength(),       4);
    }

    function test_cancelDepositRequest_headCancelAdvancesPastGhostsAndCancelled() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, ONE_M);
        _fund(mallory, 0);
        vm.prank(mallory);
        vault.requestDeposit(0, mallory);        // ghost at 1
        uint256 idB = _deposit(bob,   HUNDRED_K);  // 2
        uint256 idC = _deposit(carol, HUNDRED_K);  // 3
        assertEq(vault.depositHead(), 0);

        vm.prank(bob);
        vault.cancelDepositRequest(idB, bob);   // non-head cancel
        assertEq(vault.depositHead(), 0);

        vm.prank(alice);
        vault.cancelDepositRequest(idA, alice); // head cancel: skips ghost 1 and cancelled 2
        assertEq(vault.depositHead(), 3);

        vm.prank(carol);
        vault.cancelDepositRequest(idC, carol);
        assertEq(vault.depositHead(), 4);
        assertEq(_depositLength(),    4);
        assertLe(vault.depositHead(), _depositLength());
    }

    function test_requestDeposit_gasOfWalkingGhostsPaidOnce() public {
        _setCapacity(0);
        _deposit(alice, ONE_M);  // head stuck at 0
        _fund(mallory, 0);
        for (uint256 i; i < 500; ++i) {
            vm.prank(mallory);
            vault.requestDeposit(0, mallory);
        }
        assertEq(vault.depositHead(), 0);
        assertEq(_depositLength(),    501);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);  // fills alice, head = 1, 500 ghosts ahead
        assertEq(vault.depositHead(), 1);

        _fund(bob, ONE_M);
        vm.prank(bob);
        uint256 g0 = gasleft();
        vault.requestDeposit(ONE_M, bob);
        uint256 gasBob = g0 - gasleft();
        assertEq(vault.depositHead(),  502);
        assertEq(vault.balanceOf(bob), SH_1M);

        _fund(carol, ONE_M);
        vm.prank(carol);
        g0 = gasleft();
        vault.requestDeposit(ONE_M, carol);
        uint256 gasCarol = g0 - gasleft();
        assertEq(vault.depositHead(), 503);

        emit log_named_uint("gas: requestDeposit walking 500 ghosts", gasBob);
        emit log_named_uint("gas: requestDeposit with no walk       ", gasCarol);
        // Slots are warm inside one test tx (~777 gas per ghost here); on mainnet every ghost
        // is a cold SLOAD (2_100) so 500 ghosts cost the next depositor ~1.1M gas, once.
        assertGt(gasBob - gasCarol, 500 * 500);
        assertLt(gasBob - gasCarol, 500 * 2_500);
    }

    /**********************************************************************************************/
    /*** 16. delete after full fill                                                             ***/
    /**********************************************************************************************/

    function test_processQueues_entriesDeletedAfterFill() public {
        uint256 id = _deposit(alice, ONE_M);  // instant
        assertEq(id, 0);
        ( address o, address r, uint256 s ) = _depositRequest(0);
        assertEq(o, address(0)); assertEq(r, address(0)); assertEq(s, 0);

        uint256 rid = _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, type(uint256).max);
        ( o, r, s ) = _redeemRequest(rid);
        assertEq(o, address(0)); assertEq(r, address(0)); assertEq(s, 0);
    }

    function test_updateRecipient_outOfRangePanics() public {
        vm.expectRevert(stdError.indexOOBError);
        vault.updateDepositRecipient(0, mallory);
        vm.expectRevert(stdError.indexOOBError);
        vault.updateCancelledDepositRecipient(0, mallory);
        vm.expectRevert(stdError.indexOOBError);
        vault.updateRedeemRecipient(0, mallory);
        vm.expectRevert();  // public getter reverts with empty data
        vault.depositQueue(0);
    }

    /**********************************************************************************************/
    /*** 17. pause on GUARDIAN, unpause on admin                                                ***/
    /**********************************************************************************************/

    function test_pause_guardianCanAdminCannot() public {
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, GUARDIAN_ROLE));
        vault.pause();

        vm.prank(guardian);
        vm.expectEmit(address(vault));
        emit Paused();
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(unpauser);
        vm.expectRevert(_unauthorized(unpauser, DEFAULT_ADMIN_ROLE));
        vault.unpause();

        vm.prank(guardian);
        vm.expectRevert(_unauthorized(guardian, DEFAULT_ADMIN_ROLE));
        vault.unpause();

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit Unpaused();
        vault.unpause();
        assertFalse(vault.paused());
    }

    /**********************************************************************************************/
    /*** 18. Getters and strings                                                                ***/
    /**********************************************************************************************/

    function test_asset_isUsdc() public view {
        assertEq(vault.asset(),   address(usdc));
        assertEq(vault.savings(), address(spUsdc));
        assertEq(vault.decimals(), 6);
    }

    function test_DOMAIN_SEPARATOR_matchesEip712() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Spark Prime USDC")),
                keccak256(bytes("1")),
                block.chainid,
                address(vault)
            )
        );
        assertEq(vault.DOMAIN_SEPARATOR(), expected);
    }

    function test_take_insufficientSharesString() public {
        _deposit(alice, ONE_M);
        assertEq(_vaultSpUsdc(), S_1M);
        vm.prank(taker);
        vm.expectRevert("SparkPrimeVault/insufficient-shares");
        vault.take(S_1M + 1);
        _take(S_1M);
        assertEq(_vaultSpUsdc(), 0);
    }

    /**********************************************************************************************/
    /*** 19. Event shapes                                                                       ***/
    /**********************************************************************************************/

    function test_events_depositRequestCarriesSavingsShares() public {
        _setCapacity(0);
        _fund(alice, ONE_M);
        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit DepositRequest(alice, alice, 0, ONE_M, S_1M);
        vault.requestDeposit(ONE_M, alice);
    }

    // `Deposit`'s 4th argument is named `savingsShares` but carries spPRIME shares.
    function test_events_depositFourthArgIsPrimeShares() public {
        _fund(alice, ONE_M);
        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit Deposit(alice, alice, A_1M, SH_1M);
        vault.requestDeposit(ONE_M, alice);
    }

    function test_events_redeemOrderIsOwnerRecipientSharesAssets() public {
        _deposit(alice, ONE_M);
        _requestRedeem(alice, SH_1M);
        vm.expectEmit(address(vault));
        emit Redeem(alice, alice, SH_1M, 999_999_999_998);
        _processRedeems(type(uint256).max, type(uint256).max);
    }

}
