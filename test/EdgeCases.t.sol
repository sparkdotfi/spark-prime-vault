// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { LocalTestBase } from "./LocalTestBase.t.sol";

/// @dev Edge cases raised after the campaign: netting (`processQueues`), the timing option that
///      cancels give users, and the capacity-zero wind-down state.
contract EdgeCasesTestBase is LocalTestBase {

    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address carol   = makeAddr("carol");
    address mallory = makeAddr("mallory");

    function _processQueues(uint256 maxShares, uint256 maxRedeems, uint256 maxDeposits) internal {
        vm.prank(rebalancer);
        vault.processQueues(maxShares, maxRedeems, maxDeposits);
    }

    function _requestRedeemTo(address who, uint256 shares, address to) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.requestRedeem(shares, to);
    }

    function _cancelDeposit(address who, uint256 id) internal {
        vm.prank(who);
        vault.cancelDepositRequest(id, who);
    }

    function _cancelRedeem(address who, uint256 id) internal {
        vm.prank(who);
        vault.cancelRedeemRequest(id, who);
    }

    function _blacklist(address who) internal {
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(usdc.transfer.selector, who),
            "Blacklistable: account is blacklisted"
        );
    }

    function _backing() internal view returns (uint256) {
        return spUsdc.convertToAssets(_vaultSpUsdc());
    }

}

/**********************************************************************************************/
/*** 1. Netting: processQueues                                                              ***/
/**********************************************************************************************/

contract NettingEdgeTest is EdgeCasesTestBase {

    // C-1 inside netting: the redeem leg's ceil-burn revert also undoes the deposit leg.
    function test_processQueues_redeemLegCeilBurnRevertKillsDepositLeg() public {
        _deposit(alice, 100e6);
        _setCapacity(vault.totalSupply());        // bob will be queued
        _deposit(bob, 100e6);

        for (uint256 i; i < 110; ++i) _requestRedeem(alice, 1);   // 110 one-share redeems, fee 0

        _take(_vaultSpUsdc() - 100);              // vault keeps exactly 100 spUSDC shares

        assertEq(spUsdc.maxWithdraw(address(vault)), 104);
        assertEq(vault.convertToShares(104),         103);   // budget covers 103 one-share fills

        // Each fill pays 1 USDC wei and burns 1 spUSDC share: the 101st fill overdraws.
        vm.expectRevert("SparkVault/insufficient-balance");
        _processQueues(type(uint256).max, 110, 1);

        assertEq(vault.balanceOf(bob), 0);        // deposit leg never ran

        // A batch that fits works and frees 99 shares of capacity, which bob's deposit fills.
        _processQueues(type(uint256).max, 99, 1);
        assertEq(usdc.balanceOf(alice),       99);
        assertEq(vault.balanceOf(bob),        97);    // 99 shares freed, two floors
        assertEq(vault.availableCapacity(),   2);
    }

    // C-2 inside netting: a blacklisted redeem recipient holds the deposit queue hostage too.
    function test_processQueues_blacklistedRedeemRecipientKillsDepositLeg() public {
        _deposit(alice, 100e6);
        _setCapacity(vault.totalSupply());
        _deposit(bob, 100e6);

        _blacklist(mallory);
        uint256 id = _requestRedeemTo(alice, vault.balanceOf(alice), mallory);

        vm.expectRevert("Blacklistable: account is blacklisted");
        _processQueues(type(uint256).max, 1, 1);

        assertEq(vault.balanceOf(bob), 0);

        // Guardian cancel refunds alice; capacity is full again so bob is still stuck.
        vm.prank(guardian);
        vault.cancelRedeemRequest(id, guardian);
        _processQueues(type(uint256).max, 1, 1);
        assertEq(vault.balanceOf(bob),        0);
        assertEq(vault.availableCapacity(),   0);
    }

    // Netting pays redeemers out of the queued depositors' spUSDC, then mints the depositors
    // shares against backing that left in the same transaction.
    function test_processQueues_mintsAgainstBackingPaidOutInSameTx() public {
        _deposit(alice, 100_000e6);
        _setCapacity(vault.totalSupply());
        _takeAll();
        uint256 aliceShares = vault.balanceOf(alice);
        _requestRedeem(alice, aliceShares);
        _deposit(bob, 100_000e6);

        assertEq(_backing(), 99_999_999_999);     // only bob's spUSDC is in the vault

        _processQueues(type(uint256).max, 1, 1);

        assertEq(usdc.balanceOf(alice),       99_999_999_998);
        assertEq(vault.balanceOf(bob),        99_040_518_408);
        assertEq(vault.assetsOf(bob),         99_999_999_996);
        assertEq(_vaultSpUsdc(),              1);
        assertEq(_backing(),                  1);
        assertEq(vault.availableLiquidAssets(), 1);

        // bob's claim is now 100k notional against 1 wei of backing until the taker returns.
        uint256 id = _requestRedeem(bob, vault.balanceOf(bob));
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob), 0);
        ( , , uint256 open) = _redeemRequest(id);
        assertEq(open, 99_040_518_408);
    }

    // The deposit leg is bounded only by request count: it fills any pre-existing capacity,
    // not just what the redeem leg freed.
    function test_processQueues_depositLegFillsPreexistingCapacity() public {
        _deposit(alice, 100e6);
        _setCapacity(vault.totalSupply());
        _deposit(bob, 50_000e6);                  // queued: capacity full
        _deposit(carol, 50_000e6);                // queued behind bob
        _setCapacity(type(uint128).max);          // capacity opens, nobody redeems

        _processQueues(0, 0, 10);                 // redeem leg disabled

        assertEq(vault.balanceOf(bob),                49_520_259_204);
        assertEq(vault.balanceOf(carol),              49_520_259_204);
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    function test_processQueues_emptyQueuesAreNoop() public {
        _deposit(alice, 100e6);
        uint256 supply = vault.totalSupply();
        _processQueues(type(uint256).max, 10, 10);
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.redeemHead(),  0);
        assertEq(vault.depositHead(), 1);
    }

}

/**********************************************************************************************/
/*** 2. Cancel timing: what the free cancel is worth                                         ***/
/**********************************************************************************************/

contract CancelTimingTest is EdgeCasesTestBase {

    // With fee 0, a redeem request is a free option: queue, keep earning, cancel.
    // Alice (queued for a year) ends identical to bob (never queued).
    function test_cancelRedeemRequest_isFreeOptionWhenFeeZero() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _setPrimeVsr(FIVE_PCT_VSR);

        uint256 id = _requestRedeem(alice, vault.balanceOf(alice));
        _warpAndDrip(365 days);
        _cancelRedeem(alice, id);

        assertEq(vault.balanceOf(alice), vault.balanceOf(bob));
        assertEq(vault.assetsOf(alice),  vault.assetsOf(bob));
        assertEq(vault.assetsOf(alice),  104_999_999_998);
    }

    // With a 1% fee the option costs exactly the fee and nothing else.
    function test_cancelRedeemRequest_feeIsTheOnlyCostOfTheOption() public {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _setRedeemFee(0.01e18);
        _setPrimeVsr(FIVE_PCT_VSR);

        uint256 shares = vault.balanceOf(alice);
        uint256 id = _requestRedeem(alice, shares);
        _warpAndDrip(365 days);
        _cancelRedeem(alice, id);

        assertEq(vault.balanceOf(bob) - vault.balanceOf(alice), 990_405_185);   // ceil(1%)
        assertEq(vault.assetsOf(bob)  - vault.assetsOf(alice),  1_050_000_001);
    }

    // A queued depositor earns the spUSDC rate and may cancel for free, so they get
    // max(spUSDC rate, prime rate) while filled holders get the prime rate.
    function test_cancelDepositRequest_queuedDepositorEarnsSpUsdcRateAndKeepsTheChoice() public {
        _deposit(alice, 100_000e6);
        _setCapacity(vault.totalSupply());
        uint256 id = _deposit(bob, 100_000e6);    // queued
        _setSpUsdcVsr(FIVE_PCT_VSR);
        _setPrimeVsr(FOUR_PCT_VSR);
        _warpAndDrip(365 days);

        assertEq(vault.assetsOf(alice), 103_999_999_998);         // filled holder: 4%
        ( , , uint256 s) = _depositRequest(id);
        assertEq(spUsdc.convertToAssets(s), 104_999_999_999);     // queued: 5%

        _cancelDeposit(bob, id);
        assertEq(usdc.balanceOf(bob), 104_999_999_999);
    }

    // A queued depositor can front-run the planner's fill with a cancel, then re-enter and be
    // filled instantly (the queue is empty after the cancel). No position is lost.
    function test_cancelDepositRequest_frontRunsPlannerFillAtNoCost() public {
        _deposit(alice, 100_000e6);
        _setCapacity(vault.totalSupply());
        uint256 id = _deposit(bob, 100_000e6);
        _setCapacity(type(uint128).max);           // planner is about to fill bob

        _cancelDeposit(bob, id);                   // front-run
        _processDeposits(type(uint256).max, 10);   // planner call is a no-op
        assertEq(vault.balanceOf(bob), 0);

        uint256 refund = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.requestDeposit(refund, bob);
        assertEq(vault.balanceOf(bob), 99_040_518_409);   // instant; the cycle cost 1 wei of USDC, not shares
    }

    // Pause blocks cancels, so a loss realisation cannot be front-run from either queue.
    // Escrowed redeem shares take the loss; queued deposits (spUSDC) do not.
    function test_pause_blocksCancelSoLossIsNotFrontRunnable() public {
        _deposit(alice, 100_000e6);
        _setCapacity(vault.totalSupply());
        uint256 rid = _requestRedeem(alice, vault.balanceOf(alice));
        uint256 did = _deposit(bob, 100_000e6);

        _pause();
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelRedeemRequest(rid, alice);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelDepositRequest(did, bob);

        uint192 chi = vault.drip();
        vm.prank(riskManager);
        vault.setChi(chi / 2);
        _unpause();

        _cancelRedeem(alice, rid);
        assertEq(vault.assetsOf(alice), 49_999_999_999);      // alice took the loss
        _cancelDeposit(bob, did);
        assertEq(usdc.balanceOf(bob),   99_999_999_999);      // bob did not
    }

}

/**********************************************************************************************/
/*** 3. Wind-down: capacity zero with open queues                                            ***/
/**********************************************************************************************/

contract WindDownTest is EdgeCasesTestBase {

    function test_setCapacity_zero_redeemsDrainAndDepositsNeverFill() public {
        _deposit(alice, 100_000e6);
        _setCapacity(vault.totalSupply());
        uint256 did = _deposit(bob, 100_000e6);   // queued
        _setCapacity(0);

        _requestRedeem(alice, vault.balanceOf(alice));
        _processQueues(type(uint256).max, 1, 1);

        assertEq(usdc.balanceOf(alice),       99_999_999_998);
        assertEq(vault.totalSupply(),         0);
        assertEq(vault.balanceOf(bob),        0);
        assertEq(vault.availableCapacity(),   0);

        // bob sits in spUSDC, fee-free, earning spUSDC yield, and can leave whenever he wants.
        _setSpUsdcVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(bob), 0);

        // The exit still needs USDC liquidity inside spUSDC for the grown amount (C-14).
        vm.prank(bob);
        vm.expectRevert("SparkVault/insufficient-liquidity");
        vault.cancelDepositRequest(did, bob);
        _returnSpUsdcLiquidity(5_000e6);
        _cancelDeposit(bob, did);
        assertEq(usdc.balanceOf(bob), 104_999_999_999);
    }

    // requestDeposit never checks capacity: with capacity 0 the vault still routes unlimited
    // USDC into spUSDC under its own name, with totalSupply 0.
    function test_requestDeposit_capacityZeroStillAcceptsUnlimitedDepositsIntoSpUsdc() public {
        _setCapacity(0);
        for (uint256 i; i < 10; ++i) _deposit(makeAddr(string(abi.encodePacked("u", i))), 1_000_000e6);

        assertEq(vault.totalSupply(), 0);
        assertEq(_backing(),          9_999_999_999_990);
        assertEq(vault.pendingDepositSavingsShares(), _vaultSpUsdc());
    }

    // The queue therefore consumes spUSDC's own deposit cap: the 6th 1M deposit reverts inside
    // spUSDC once its cap (5M above the current level) is reached, for depositors and for the
    // spUSDC product alike.
    function test_requestDeposit_queueConsumesSpUsdcDepositCap() public {
        _setCapacity(0);
        uint256 cap = spUsdc.totalAssets() + 5_000_000e6;
        vm.prank(spAdmin);
        spUsdc.setDepositCap(cap);

        for (uint256 i; i < 5; ++i) _deposit(makeAddr(string(abi.encodePacked("u", i))), 1_000_000e6);

        _fund(carol, 1_000_000e6);
        vm.prank(carol);
        vm.expectRevert("SparkVault/deposit-cap-exceeded");
        vault.requestDeposit(1_000_000e6, carol);
    }

}
