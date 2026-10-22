// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../../lib/forge-std/src/StdError.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";
import { ISparkPrimeVault } from "src/ISparkPrimeVault.sol";

/// @dev Round-5 headline proofs on `master` @ 0ebb452, written independently of the worker suites
///      as a one-file entry point for the auditors. Each test is self-contained and asserts the
///      exact numbers quoted in AUDIT-REPORT.md. Nothing here fails deliberately.
contract HeadlineTests is LocalTestBase {

    address alice = makeAddr("alice");
    address mal   = makeAddr("mal");

    uint256 constant ONE_M = 1_000_000e6;

    uint256 constant ALICE_AFTER_CHUNKED = 999_999_999_996;

    // type(uint256).max / RAY: the real `chi` ceiling for `drip()` and `nowChi()` at vsr == RAY.
    uint256 constant CHI_DRIP_MAX = 115792089237316195423570985008687907853269984665640;

    /**********************************************************************************************/
    /*** H-1  adjustTotalAssets can push chi past the drip() overflow bound (brick)              ***/
    /**********************************************************************************************/

    function test_headline_H1_chiAboveDripBound_bricksVault_onlyUpgradeRecovers() public {
        _deposit(alice, ONE_M);

        uint256 supply = vault.totalSupply();
        assertEq(supply, 990_405_184_109);

        _pause();

        // Smallest delta that lands chi above the real bound while passing the uint192 check.
        // chi' = (totalAssets + delta) * RAY / supply  >  CHI_DRIP_MAX
        uint256 assets = vault.totalAssets();
        uint256 delta  = (CHI_DRIP_MAX + 1) * supply / RAY + 1 - assets;

        _adjustTotalAssets(int256(delta));

        assertGt(vault.chi(), CHI_DRIP_MAX);
        assertLe(vault.chi(), type(uint192).max);  // the only bound the contract checks

        // Same block: everything still reads.
        vault.totalAssets();

        // One second later every dripping entry point panics, including the undo.
        _warp(1);

        vm.expectRevert(stdError.arithmeticError);
        vault.drip();

        vm.expectRevert(stdError.arithmeticError);
        vault.nowChi();

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(admin);
        vault.adjustTotalAssets(-int256(delta));

        _unpause();

        _fund(mal, 1e6);
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(mal);
        vault.requestDeposit(1e6, mal, 0);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(alice);
        vault.requestRedeem(1, alice);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(operator);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);

        // Non-dripping paths still work: take() can still move the backing out.
        uint256 backing = _vaultSpUsdc();
        _take(backing);
        assertEq(_vaultSpUsdc(), 0);
    }

    function test_headline_H1_exactThreshold() public {
        _deposit(alice, ONE_M);

        // chi == bound drips fine for ten years; bound + 1 reverts after one second.
        vm.store(address(vault), bytes32(uint256(8)), bytes32(CHI_DRIP_MAX));
        _warp(3650 days);
        vault.drip();

        vm.store(address(vault), bytes32(uint256(8)), bytes32(CHI_DRIP_MAX + 1));
        _warp(1);
        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
    }

    /**********************************************************************************************/
    /*** H-2  Deposit between public payload and pause captures the gain (sandwich)              ***/
    /**********************************************************************************************/

    function test_headline_H2_depositBeforePause_capturesGain_zeroFee() public {
        _deposit(alice, ONE_M);

        // Payload is public: mal instant-fills 1M one block before the pauser pauses.
        _deposit(mal, ONE_M);

        _pause();
        _adjustTotalAssets(50_000e6);
        _unpause();

        uint256 id = _requestRedeem(mal, vault.balanceOf(mal));
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(mal), 1_024_999_999_998);  // +24,999.999998 for one block of risk
        assertEq(vault.assetsOf(alice), 1_024_999_999_998);  // alice got half of her own gain

        ( , , uint256 left ) = _redeemRequest(id);
        assertEq(left, 0);
    }

    function test_headline_H2_depositBeforePause_capturesGain_onePctFee() public {
        _setRedeemFeeRate(0.01e18);

        _deposit(alice, ONE_M);
        _deposit(mal, ONE_M);

        _pause();
        _adjustTotalAssets(50_000e6);
        _unpause();

        _requestRedeem(mal, vault.balanceOf(mal));
        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(mal), 1_014_749_999_997);  // still +14,749.999997 net of the 1% fee
    }

    function test_headline_H2_pauseBeforeDeposit_killsSandwich() public {
        _deposit(alice, ONE_M);

        _pause();

        _fund(mal, ONE_M);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(mal);
        vault.requestDeposit(ONE_M, mal, 0);

        _adjustTotalAssets(50_000e6);
        _unpause();

        assertEq(vault.assetsOf(alice), 1_049_999_999_997);
    }

    /**********************************************************************************************/
    /*** H-3  adjustTotalAssets has no loss floor                                               ***/
    /**********************************************************************************************/

    function test_headline_H3_lossOfTotalAssetsMinusOne_wipesHolders() public {
        _deposit(alice, ONE_M);

        uint256 assets = vault.totalAssets();
        assertEq(assets, 999_999_999_998);

        _pause();

        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vm.prank(admin);
        vault.adjustTotalAssets(-int256(assets));

        _adjustTotalAssets(-int256(assets - 1));  // accepted

        assertEq(vault.chi(), 1_009_687_768_243_692);  // RAY / supply, floored
        assertEq(vault.assetsOf(alice), 0);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 999_999_999_999);  // backing untouched
    }

    /**********************************************************************************************/
    /*** H-4  Batched redeem fills can revert on spUSDC ceil-rounding (C-1)                     ***/
    /**********************************************************************************************/

    function test_headline_H4_batchedRedeems_revertOnCeilRounding_singleFillsWork() public {
        _deposit(alice, ONE_M);

        uint256 shares = vault.balanceOf(alice);

        // Three entries from one holder; the fresh-eyes split (11, 11, rest) reproduces it.
        vm.startPrank(alice);
        vault.requestRedeem(11, alice);
        vault.requestRedeem(11, alice);
        vault.requestRedeem(shares - 22, alice);
        vm.stopPrank();

        vm.expectRevert("SparkVault/insufficient-balance");
        vm.prank(operator);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);

        // One entry per call: each call re-derives the bound and succeeds.
        _processRedeems(type(uint256).max, 1);
        _processRedeems(type(uint256).max, 1);
        _processRedeems(type(uint256).max, 1);

        // The last single fill re-floors the bound: 2 shares stay at the head, unpayable until
        // spUSDC arrives from outside (FE-1 dust), and alice is paid 4 wei less than one fill.
        assertEq(vault.pendingRedeemShares(), 2);
        assertEq(usdc.balanceOf(alice), ALICE_AFTER_CHUNKED);
    }

    /**********************************************************************************************/
    /*** H-5  Vault or spUSDC as a payout recipient strands USDC with no claimable entry        ***/
    /**********************************************************************************************/

    function test_headline_H5_redeemRecipientVault_strandsUsdc() public {
        _deposit(alice, ONE_M);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, address(vault));  // accepted

        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(usdc.balanceOf(address(vault)), 999_999_999_998);
        assertEq(vault.claimableAssets(address(vault)), 0);
        assertEq(vault.claimableAssets(alice), 0);

        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(address(vault));
    }

    /**********************************************************************************************/
    /*** H-6  Capacity 0 freezes the deposit head; ghosts tax the next instant fill             ***/
    /**********************************************************************************************/

    function test_headline_H6_ghostsAtCapacityZero_taxNextDepositor() public {
        _setCapacity(0);

        // Free zero-asset requests at the default minDeposit == 0.
        for (uint256 i; i < 300; ++i) {
            vm.prank(mal);
            vault.requestDeposit(0, mal, 0);
        }
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(vault.getPendingDepositRequests().length, 300);

        _setCapacity(type(uint128).max);

        _fund(alice, ONE_M);
        vm.cool(address(vault));  // cold slots, as in a real block
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.requestDeposit(ONE_M, alice, 0);
        uint256 used = gasBefore - gasleft();

        emit log_named_uint("gas with 300 ghosts", used);
        assertGt(used, 900_000);  // ~2.3k per ghost on top of ~350k for a clean queue
        assertEq(vault.firstPendingDepositId(), 301);
    }

    /**********************************************************************************************/
    /*** H-7  Last admin can renounce; zero admin accepted at initialize                        ***/
    /**********************************************************************************************/

    function test_headline_H7_lastAdminRenounces_vaultStuckPaused() public {
        _pause();

        vm.prank(admin);
        vault.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 0);

        vm.expectRevert();
        vm.prank(admin);
        vault.unpause();

        assertTrue(vault.paused());
    }

}
