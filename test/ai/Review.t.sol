// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { TestBase } from "./TestBase.t.sol";

interface IERC20Full {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ISpUsdc {
    function balanceOf(address) external view returns (uint256);
    function convertToShares(uint256) external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function nowChi() external view returns (uint256);
    function deposit(uint256, address) external returns (uint256);
    function approve(address, uint256) external returns (bool);
}

// Proof-of-concept tests for the review findings against mainnet spUSDC. Each test name carries
// the finding id. Round 5 (`master` @ 0ebb452): F-1 is fixed upstream (the guardian cancel path
// is gone, `requestDepositCancellation` is owner-only, `cancelRedeemRequest` removed) and F-3 is
// fixed (the walk honours `maxRequests`); both are `test_fixed_`. F-2 (queue backing not
// ring-fenced from `take`), F-4 (dust fill mints zero shares) and F-5 (ghost entries) are still
// open and keep `test_BUG_` names. Not executed in this environment (no RPC); compiled only.
contract ReviewTest is TestBase {

    IERC20Full internal usdcT = IERC20Full(address(usdc));
    ISpUsdc    internal spT   = ISpUsdc(address(spUsdc));

    address internal alice = makeAddr("alice");
    address internal bob   = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal thief = makeAddr("thief");

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        vault.grantRole(GUARDIAN_ROLE,     guardian);
        vault.grantRole(REBALANCER_ROLE,   rebalancer);
        vault.grantRole(REDEEM_FEE_SETTER_ROLE, redeemFeeSetter);
        vault.grantRole(VSR_SETTER_ROLE,       vsrSetter);
        vault.grantRole(TAKER_ROLE,        taker);
        vault.setCapacity(1_000_000e6);
        vault.setMaxRedeemFeeRate(0.01e18);
        vm.stopPrank();

        _fund(alice, 1_000_000e6);
        _fund(bob,   1_000_000e6);
        _fund(carol, 1_000_000e6);
    }

    function _fund(address who, uint256 amt) internal {
        deal(address(usdc), who, amt);
        vm.prank(who);
        usdcT.approve(address(vault), type(uint256).max);
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.requestDeposit(amt, who, 0);
    }

    function _settleCancels() internal {
        vm.prank(rebalancer);
        vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);
    }

    /*******************************************************************************************/
    /*** F-1 (FIXED at 0ebb452): only the request owner can cancel a deposit                  ***/
    /*******************************************************************************************/

    function test_fixed_F1_guardianCannotCancelDeposit() public {
        _deposit(alice, 1_000_000e6);              // fills capacity exactly
        uint256 id = _deposit(bob, 100_000e6);     // queued (capacity full)

        uint256 queued = vault.pendingDepositSavingsShares();
        assertGt(queued, 0);

        // Guardian and admin have no cancel path at all, whatever recipient they name.
        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(id, thief);
        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(id, bob);
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.requestDepositCancellation(id, bob);

        assertEq(vault.pendingDepositSavingsShares(), queued);
        assertEq(vault.getPendingDepositCancellationRequests().length, 0);

        // The owner cancels and chooses the refund recipient himself.
        vm.prank(bob);
        uint256 cancelId = vault.requestDepositCancellation(id, bob);

        (address owner, address recipient, uint256 shares) = _cancelledDepositRequest(cancelId);
        assertEq(owner,     bob);
        assertEq(recipient, bob);
        assertEq(shares,    queued);

        _settleCancels();

        assertEq(usdcT.balanceOf(thief), 0);
        assertApproxEqAbs(usdcT.balanceOf(bob), 1_000_000e6, 2);
    }

    // Redeems have no cancel entry point any more; the selector is not in the ABI.
    function test_fixed_F1_cancelRedeemRequestRemoved() public {
        _deposit(alice, 500_000e6);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(shares, alice);

        vm.prank(guardian);
        (bool ok, ) = address(vault).call(
            abi.encodeWithSignature("cancelRedeemRequest(uint256,address)", id, thief)
        );
        assertFalse(ok);
        assertEq(vault.balanceOf(thief), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
    }

    /*******************************************************************************************/
    /*** F-2: deposit-queue spUSDC is not ring-fenced from take() / processPendingRedeems        ***/
    /*******************************************************************************************/

    function test_BUG_F2_takeSpendsQueuedDepositBacking() public {
        _deposit(alice, 1_000_000e6);
        uint256 id = _deposit(bob, 100_000e6);     // queued, backed by spUSDC

        uint256 queued = vault.pendingDepositSavingsShares();

        // Taker drains the whole spUSDC balance, including bob's queued backing.
        uint256 bal = spT.balanceOf(address(vault));
        vm.prank(taker);
        vault.take(bal);

        assertEq(spT.balanceOf(address(vault)), 0);
        assertEq(vault.pendingDepositSavingsShares(), queued);

        // Round 2: bob's cancel succeeds (it only moves the entry), but the settlement has no
        // spUSDC to redeem: nothing is paid, the entry stays open, bob is still out 100k.
        vm.prank(bob);
        uint256 cancelId = vault.requestDepositCancellation(id, bob);
        assertEq(vault.pendingCancelledDepositSavingsShares(), queued);

        _settleCancels();

        (, , uint256 left) = _cancelledDepositRequest(cancelId);
        assertEq(left, queued);
        assertEq(vault.firstPendingDepositCancellationId(), 0);
        assertEq(usdcT.balanceOf(bob), 900_000e6);
    }

    function test_BUG_F2_processPendingRedeemsPaysRedeemersWithQueuedDepositBacking() public {
        _deposit(alice, 1_000_000e6);
        uint256 bobId = _deposit(bob, 100_000e6);  // queued

        // Simulate Arkis having taken all of alice's capital (active), leaving only bob's
        // queued spUSDC in the vault.
        uint256 bobShares = vault.pendingDepositSavingsShares();
        uint256 aliceBacking = spT.balanceOf(address(vault)) - bobShares;
        vm.prank(taker);
        vault.take(aliceBacking);

        // alice requests a redeem of 50k; rebalancer processes it.
        vm.prank(alice);
        vault.requestRedeem(50_000e6, alice);

        vm.prank(rebalancer);
        vault.processPendingRedeems(type(uint256).max, 10);

        assertApproxEqAbs(usdcT.balanceOf(alice), 50_000e6, 1);   // paid from bob's backing

        // bob's queued deposit is still recorded in full ...
        assertEq(vault.pendingDepositSavingsShares(), bobShares);
        // ... but only ~half of it is actually held, so the settlement is partial.
        uint256 held = spT.balanceOf(address(vault));
        assertLt(held, bobShares);

        vm.prank(bob);
        uint256 cancelId = vault.requestDepositCancellation(bobId, bob);
        _settleCancels();

        (, , uint256 left) = _cancelledDepositRequest(cancelId);
        assertEq(left, bobShares - held);                 // Partial fill, entry stays at head
        assertEq(vault.firstPendingDepositCancellationId(), 0);
        assertApproxEqAbs(usdcT.balanceOf(bob), 950_000e6, 2);
    }

    /*******************************************************************************************/
    /*** F-3: _processPendingDeposits honours maxRequests (FIXED upstream)                       ***/
    /*******************************************************************************************/

    function test_fixed_F3_processPendingDepositsFillsAllRequestsInOneCall() public {
        _deposit(alice, 1_000_000e6);              // capacity full
        _deposit(bob,   10_000e6);                 // queued
        _deposit(carol, 10_000e6);                 // queued

        vm.prank(admin);
        vault.setCapacity(2_000_000e6);            // plenty of room for both

        vm.prank(rebalancer);
        vault.processPendingDeposits(type(uint256).max, 10);

        // FIXED (F-3): both requests fill in one call.
        assertGt(vault.balanceOf(bob),   0, "bob filled");
        assertGt(vault.balanceOf(carol), 0, "carol filled in the same call");
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(), 3);
    }

    /*******************************************************************************************/
    /*** F-4: dust fill mints zero shares while consuming the request's spUSDC                ***/
    /*******************************************************************************************/

    function test_BUG_F4_dustFillMintsZeroShares() public {
        // Raise spPRIME's index above RAY so convertToShares(1 wei) == 0.
        uint256 maxVsr = vault.MAX_VSR();
        vm.prank(admin);
        vault.setVSRBounds(1e27, maxVsr);
        vm.prank(vsrSetter);
        vault.setVSR(1.000000003022265980097387650e27);  // ~10% APY
        vm.warp(block.timestamp + 365 days);
        vault.drip();
        assertGt(vault.chi(), 1e27);

        _deposit(alice, 1_000_000e6);
        uint256 ts0 = vault.totalSupply();
        vm.prank(admin);
        vault.setCapacity(ts0);                    // capacity exactly full
        uint256 id = _deposit(bob, 10_000e6);      // queued
        uint256 before = vault.pendingDepositSavingsShares();
        assertEq(vault.balanceOf(bob), 0);

        // Give exactly enough capacity that it converts to 1 spUSDC share.
        uint256 ts = vault.totalSupply();
        uint256 cap;
        for (uint256 k = 1; k < 10; ++k) {
            if (spT.convertToShares(vault.convertToAssets(k)) == 1) { cap = ts + k; break; }
        }
        require(cap != 0, "no k found");
        vm.prank(admin);
        vault.setCapacity(cap);

        vm.prank(rebalancer);
        vault.processPendingDeposits(type(uint256).max, 10);

        assertEq(vault.balanceOf(bob), 0,                    "zero shares minted");
        assertEq(vault.pendingDepositSavingsShares(), before - 1, "but 1 spUSDC share consumed");
        (, , uint256 left) = _depositRequest(id);
        assertEq(left, before - 1);
    }

    /*******************************************************************************************/
    /*** F-5: zero / dust requests bloat the queues for free                                  ***/
    /*******************************************************************************************/

    function test_BUG_F5_zeroDepositRequestsBloatQueue() public {
        for (uint256 i; i < 50; ++i) _deposit(alice, 0);
        assertEq(vault.firstPendingDepositId(), 50);
        (, , uint256 s) = _depositRequest(49);
        assertEq(s, 0);
    }

    function test_BUG_F5_tinyRedeemRequestsBecomeGhostEntries() public {
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000e6);

        vm.startPrank(alice);
        for (uint256 i; i < 20; ++i) vault.requestRedeem(1, alice);  // 1 wei share each
        vm.stopPrank();

        assertEq(vault.pendingRedeemShares(), 0);  // every entry is a 0-share ghost
        (, , uint256 s) = _redeemRequest(19);
        assertEq(s, 0);
    }

    /*******************************************************************************************/
    /*** Rounding sanity: fills never exceed capacity; fee rounds up                          ***/
    /*******************************************************************************************/

    function testFuzz_fillNeverExceedsCapacity(uint256 cap, uint256 amt) public {
        cap = bound(cap, 1, 5_000_000e6);
        amt = bound(amt, 1, 1_000_000e6);
        vm.prank(admin);
        vault.setCapacity(cap);
        _deposit(alice, amt);
        assertLe(vault.totalSupply(), cap);
    }

    function test_feeRoundsUp() public {
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000e6);
        vm.prank(alice);
        vault.requestRedeem(101, alice);           // 1% of 101 = 1.01 -> fee 2
        assertEq(vault.pendingRedeemShares(), 99);
    }
}
