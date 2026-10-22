// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../../lib/forge-std/src/StdError.sol";

import { LocalTestBase }    from "./LocalTestBase.t.sol";
import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";

/// @dev Headline proofs on `master` @ c512609, written independently of the worker suites as a
///      one-file entry point for the auditors. Each test is self-contained and asserts exact
///      numbers. Nothing here fails deliberately: `test_BUG_` pins behaviour that is still open,
///      `test_fixed_` pins the fix of a previously reported headline.
///
///        H1 chi brick              open   (`test_BUG_H1_*`)
///        H2 pause sandwich         open   (`test_BUG_H2_*`)
///        H3 no loss floor          open   (`test_BUG_H3_*`, now a LOSS_MANAGER hot-wallet role)
///        H4 batched redeem revert  FIXED  (`test_fixed_H4_*`, per-entry liquidity bound);
///                                  the dust left at the head (R5-10) is still open (`test_BUG_H4_*`)
///        H5 vault as recipient     FIXED  (`test_fixed_H5_*`); spUSDC as recipient still open
///        H6 ghost entries          partly (`test_fixed_H6_*` self-skip, `test_BUG_H6_*` behind head)
///        H7 admin renounce         open   (`test_BUG_H7_*`)
contract HeadlineTests is LocalTestBase {

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address mal   = makeAddr("mal");

    uint256 constant ONE_M = 1_000_000e6;

    // c512609 layout: slot 7 = rho (uint64, offset 0) | chi (uint192, offset 8).
    uint256 constant SLOT_RHO_CHI = 7;

    // type(uint256).max / RAY: the real `chi` ceiling for `drip()` and `nowChi()` at vsr == RAY.
    uint256 constant CHI_DRIP_MAX = 115792089237316195423570985008687907853269984665640;

    function _storeChi(uint256 chi_) internal {
        uint256 word_ = uint256(vm.load(address(vault), bytes32(SLOT_RHO_CHI)));
        vm.store(address(vault), bytes32(SLOT_RHO_CHI), bytes32((chi_ << 64) | uint64(word_)));
    }

    /**********************************************************************************************/
    /*** H-1  adjustTotalAssets can push chi past the drip() overflow bound (brick)              ***/
    /**********************************************************************************************/

    function test_BUG_H1_chiAboveDripBound_bricksVault_onlyUpgradeRecovers() public {
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
        vm.prank(lossManager);
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

    function test_BUG_H1_exactThreshold() public {
        _deposit(alice, ONE_M);

        // chi == bound drips fine for ten years; bound + 1 reverts after one second.
        _storeChi(CHI_DRIP_MAX);
        _warp(3650 days);
        vault.drip();

        _storeChi(CHI_DRIP_MAX + 1);
        _warp(1);
        vm.expectRevert(stdError.arithmeticError);
        vault.drip();
    }

    /**********************************************************************************************/
    /*** H-2  Deposit between public payload and pause captures the gain (sandwich)              ***/
    /**********************************************************************************************/

    function test_BUG_H2_depositBeforePause_capturesGain_zeroFee() public {
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

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);  // paid and gone
        _redeemRequest(id);
    }

    function test_BUG_H2_depositBeforePause_capturesGain_onePctFee() public {
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

    function test_H2_pauseBeforeDeposit_killsSandwich() public {
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
    /*** H-3  adjustTotalAssets has no loss floor (LOSS_MANAGER_ROLE, paused only)              ***/
    /**********************************************************************************************/

    function test_BUG_H3_lossOfTotalAssetsMinusOne_wipesHolders() public {
        _deposit(alice, ONE_M);

        uint256 assets = vault.totalAssets();
        assertEq(assets, 999_999_999_998);

        _pause();

        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vm.prank(lossManager);
        vault.adjustTotalAssets(-int256(assets));

        _adjustTotalAssets(-int256(assets - 1));  // accepted

        assertEq(vault.chi(), 1_009_687_768_243_692);  // RAY / supply, floored
        assertEq(vault.assetsOf(alice), 0);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 999_999_999_999);  // backing untouched
    }

    // The loss manager is a separate, non-admin role: it needs only the pauser to cooperate,
    // and neither the admin nor the operator can veto a loss once the vault is paused.
    function test_BUG_H3_lossManagerIsNotAdmin() public {
        _deposit(alice, ONE_M);
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, lossManager));

        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vm.prank(lossManager);
        vault.adjustTotalAssets(-1e6);

        _pause();
        vm.expectRevert();  // admin cannot adjust
        vm.prank(admin);
        vault.adjustTotalAssets(-1e6);

        _adjustTotalAssets(-999_999_000_000);
        assertEq(vault.totalAssets(), 999_997);   // 1 wei of chi floor
        assertEq(vault.assetsOf(alice), 999_997);
    }

    /**********************************************************************************************/
    /*** H-4  Batched redeem fills no longer revert on spUSDC ceil-rounding (C-1 FIXED)          ***/
    /**********************************************************************************************/

    function test_fixed_H4_batchedRedeems_payInOneCall() public {
        _deposit(alice, ONE_M);

        uint256 shares = vault.balanceOf(alice);
        assertEq(shares,        990_405_184_109);
        assertEq(_vaultSpUsdc(), 954_532_691_143);

        // Three entries from one holder; the fresh-eyes split (11, 11, rest) used to revert
        // with "SparkVault/insufficient-balance" on the third fill.
        vm.startPrank(alice);
        vault.requestRedeem(11, alice);
        vault.requestRedeem(11, alice);
        vault.requestRedeem(shares - 22, alice);
        vm.stopPrank();

        _processRedeems(type(uint256).max, type(uint256).max);  // one call, no revert

        // Entries 0 and 1 are paid in full and deleted; entry 2 is paid down to the per-entry
        // liquidity bound: the same 999_999_999_996 the three single calls used to pay.
        assertEq(vault.firstPendingRedeemId(), 2);
        assertEq(usdc.balanceOf(alice),        999_999_999_996);
        assertEq(vault.pendingRedeemShares(),  2);
        assertEq(_vaultSpUsdc(),               1);
    }

    // What is left after the batch is R5-10, unchanged: 2 shares at the head backed by 1 spUSDC
    // share (1 wei of assets), `convertToShares(1) == 0`, so every later call breaks at
    // `fillable_ == 0` until spUSDC arrives from outside. A single whole-balance entry has no
    // such dust (999_999_999_998 paid, 0 spUSDC left).
    function test_BUG_H4_dustAtHeadUnpayableUntilTopUp() public {
        _deposit(alice, ONE_M);
        uint256 shares = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.requestRedeem(11, alice);
        vault.requestRedeem(11, alice);
        vault.requestRedeem(shares - 22, alice);
        vm.stopPrank();
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.pendingRedeemShares(), 2);
        assertEq(vault.availableLiquidAssets(), 1);
        assertEq(vault.convertToShares(1), 0);

        _processRedeems(type(uint256).max, type(uint256).max);  // no-op
        assertEq(vault.firstPendingRedeemId(), 2);
        assertEq(vault.pendingRedeemShares(),  2);
        assertEq(usdc.balanceOf(alice),        999_999_999_996);

        // 10 spUSDC shares from outside clear it: 2 shares -> 2 wei of USDC.
        _returnToVault(10);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingRedeemId(), 3);
        assertEq(vault.pendingRedeemShares(),  0);
        assertEq(usdc.balanceOf(alice),        999_999_999_998);
        assertEq(vault.balanceOf(address(vault)), 0);
    }

    // Any split of a holder's shares into up to eight entries pays in one call without
    // reverting; at most the last entry keeps a few shares of dust.
    function testFuzz_fixed_H4_anySplitPaysInOneCall(uint256 seed) public {
        _deposit(alice, ONE_M);
        uint256 shares = vault.balanceOf(alice);
        uint256 n = bound(seed, 1, 8);
        uint256 left = shares;
        vm.startPrank(alice);
        for (uint256 i; i + 1 < n; ++i) {
            uint256 part = bound(uint256(keccak256(abi.encode(seed, i))), 1, left - (n - i - 1));
            vault.requestRedeem(part, alice);
            left -= part;
        }
        vault.requestRedeem(left, alice);
        vm.stopPrank();

        _processRedeems(type(uint256).max, type(uint256).max);

        assertGe(vault.firstPendingRedeemId(), n - 1);
        assertLe(vault.pendingRedeemShares(),  2 * n);
        assertGe(usdc.balanceOf(alice), 999_999_999_998 - 2 * n);
        assertLe(_vaultSpUsdc(), n);
        assertEq(vault.balanceOf(address(vault)), vault.pendingRedeemShares());
    }

    /**********************************************************************************************/
    /*** H-5  Vault as recipient FIXED; spUSDC as recipient still donates the payout            ***/
    /**********************************************************************************************/

    function test_fixed_H5_vaultRejectedAsRecipientEverywhere() public {
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());
        uint256 depId = _deposit(bob, 100e6);  // queued
        uint256 shares = vault.balanceOf(alice);

        _fund(alice, 1e6);
        vm.startPrank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDeposit(1e6, address(vault), 0);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestRedeem(shares, address(vault));
        uint256 redId = vault.requestRedeem(shares, alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateRedeemRecipient(redId, address(vault));
        vm.stopPrank();

        ( , , uint256 bobShares ) = _depositRequest(depId);
        vm.startPrank(bob);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositRecipient(depId, address(vault));
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDepositCancellation(depId, address(vault), bobShares);
        uint256 cancelId = vault.requestDepositCancellation(depId, bob, bobShares);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositCancellationRecipient(cancelId, address(vault));
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.claimableAssets(address(vault)), 0);
    }

    // spUSDC itself is still accepted as a recipient: the payout is a USDC transfer from spUSDC
    // to spUSDC, which succeeds, so no fallback fires and the USDC is donated to spUSDC's
    // liquidity (its share supply shrinks, its liquidity does not).
    function test_BUG_H5_spUsdcRecipient_donatesPayout() public {
        _deposit(alice, ONE_M);

        uint256 shares   = vault.balanceOf(alice);
        uint256 spSupply = spUsdc.totalSupply();
        uint256 spUsdcLiquidity = usdc.balanceOf(address(spUsdc));

        vm.prank(alice);
        vault.requestRedeem(shares, address(spUsdc));  // accepted

        _processRedeems(type(uint256).max, type(uint256).max);

        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(usdc.balanceOf(alice),          0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.claimableAssets(address(spUsdc)), 0);
        assertEq(vault.claimableAssets(alice),           0);
        assertEq(vault.totalClaimable(),                 0);

        // spUSDC burned the vault's shares but kept the USDC: 999_999_999_998 donated.
        assertEq(usdc.balanceOf(address(spUsdc)), spUsdcLiquidity);
        assertEq(spSupply - spUsdc.totalSupply(), 954_532_691_143);
        assertEq(_vaultSpUsdc(), 0);
        assertGt(usdc.balanceOf(address(spUsdc)), spUsdc.totalAssets());  // surplus in spUSDC

        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(address(spUsdc));
    }

    /**********************************************************************************************/
    /*** H-6  Ghost entries: self-skip at the head FIXED; behind a live head still walked later  ***/
    /**********************************************************************************************/

    // Zero-asset requests are impossible, and a request-then-cancel at the head self-skips:
    // 50 loops leave an empty window and the head at 50.
    function test_fixed_H6_cancelAtHeadSelfSkips_zeroDepositRejected() public {
        _setMinDeposit(1e6);
        _setCapacity(0);

        vm.prank(mal);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(0, mal, 0);

        _fund(mal, 50e6);
        for (uint256 i; i < 50; ++i) {
            vm.prank(mal);
            uint256 id = vault.requestDeposit(1e6, mal, 0);
            _cancelDeposit(mal, id);
        }
        assertEq(vault.firstPendingDepositId(), 50);
        assertEq(vault.getPendingDepositRequests().length, 0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.getPendingDepositCancellationRequests().length, 50);

        // The next depositor walks nothing.
        _setCapacity(type(uint128).max);
        _fund(alice, ONE_M);
        vm.cool(address(vault));
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vault.requestDeposit(ONE_M, alice, 0);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("gas, clean head", used);
        assertLt(used, 400_000);
        assertEq(vault.firstPendingDepositId(), 51);
    }

    // Behind a live head the self-skip breaks at the first live entry, so `minDeposit`-sized
    // request-then-cancel loops still pile zero entries into the window. The operator's walk at
    // capacity 0 cannot clear them; the first walk with capacity (operator or the next instant
    // fill once the live head is gone) pays ~2.3k gas per ghost. Capital cost to the griefer:
    // `minDeposit` per loop, refunded by the cancellation queue.
    function test_BUG_H6_ghostsBehindLiveHead_taxFirstWalkWithCapacity() public {
        _setMinDeposit(1e6);
        _setCapacity(0);

        _deposit(alice, ONE_M);                      // id 0, live head
        _fund(mal, 300e6);
        for (uint256 i; i < 300; ++i) {
            vm.prank(mal);
            uint256 id = vault.requestDeposit(1e6, mal, 0);
            _cancelDeposit(mal, id);
        }
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(vault.getPendingDepositRequests().length, 301);
        assertEq(vault.getPendingDepositCancellationRequests().length, 300);
        assertEq(vault.pendingDepositSavingsShares(), 954_532_691_143);  // alice only

        // Operator at capacity 0: breaks at alice, nothing moves.
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingDepositId(), 0);

        // Operator fills only the live head (maxRequests 1): the 300 ghosts are now AT the head.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(vault.getPendingDepositRequests().length, 300);

        // The next depositor's instant fill walks all 300 ghosts.
        _fund(bob, ONE_M);
        vm.cool(address(vault));
        vm.prank(bob);
        uint256 gasBefore = gasleft();
        vault.requestDeposit(ONE_M, bob, 0);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("gas with 300 ghosts at the head", used);
        assertGt(used, 700_000);
        assertEq(vault.firstPendingDepositId(), 302);

        // The griefer gets every wei back once the operator settles the cancellations.
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(mal), 300e6 - 300);  // 1 wei of spUSDC floor per loop
    }

    /**********************************************************************************************/
    /*** H-7  Last admin can renounce; zero admin accepted at initialize                        ***/
    /**********************************************************************************************/

    function test_BUG_H7_lastAdminRenounces_noRoleOrUpgradeEverAgain() public {
        vm.prank(admin);
        vault.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 0);

        // Nobody can grant, revoke, upgrade or touch the admin-only parameters.
        address[7] memory actors = [admin, lossManager, operator, pauser, unpauser, redeemFeeSetter, taker];
        for (uint256 i; i < actors.length; ++i) {
            vm.startPrank(actors[i]);
            vm.expectRevert();
            vault.grantRole(OPERATOR_ROLE, mal);
            vm.expectRevert();
            vault.revokeRole(OPERATOR_ROLE, operator);
            vm.expectRevert();
            vault.upgradeToAndCall(address(0xdead), "");
            vm.expectRevert();
            vault.setMinDeposit(2);
            vm.expectRevert();
            vault.setVSRBounds(RAY, RAY);
            vm.stopPrank();
        }

        // The existing roles keep working; losing any one of them is now permanent.
        _pause();
        _unpause();
        vm.prank(operator);
        vault.renounceRole(OPERATOR_ROLE, operator);
        assertEq(vault.getRoleMemberCount(OPERATOR_ROLE), 0);
        vm.expectRevert();
        vm.prank(operator);
        vault.processPendingDeposits(1, 1);
    }

    function test_BUG_H7_zeroAdminAcceptedAtInitialize() public {
        ISparkPrimeVault fresh = ISparkPrimeVault(address(new ERC1967ProxyLike(
            vault.implementation(),
            abi.encodeCall(
                ISparkPrimeVault.initialize,
                (address(spUsdc), "x", "x", address(0), 1, 1, 1)
            )
        )));
        assertEq(fresh.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(fresh.getRoleMember(DEFAULT_ADMIN_ROLE, 0), address(0));
        assertTrue(fresh.hasRole(DEFAULT_ADMIN_ROLE, address(0)));
        vm.expectRevert();
        vm.prank(admin);
        fresh.grantRole(OPERATOR_ROLE, operator);
    }

}

import { ERC1967Proxy } from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ERC1967ProxyLike is ERC1967Proxy {
    constructor(address impl_, bytes memory data_) ERC1967Proxy(impl_, data_) {}
}
