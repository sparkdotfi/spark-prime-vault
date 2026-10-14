// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../lib/forge-std/src/Test.sol";
import { ERC1967Proxy } from "../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 } from "../lib/oz/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "../lib/oz/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "../lib/oz/contracts/token/ERC20/IERC20.sol";
import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

contract MockAsset is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSavings is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Savings Mock USD", "smUSD") {}
}

contract QueueAuditTest is Test {
    MockAsset internal asset;
    MockSavings internal savings;
    SparkPrimeVault internal vault;

    address internal admin = makeAddr("admin");
    address internal rebalancer = makeAddr("rebalancer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");
    address internal david = makeAddr("david");

    bytes32 internal REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 internal TAKER_ROLE = keccak256("TAKER_ROLE");

    function setUp() public {
        asset = new MockAsset();
        savings = new MockSavings(IERC20(address(asset)));

        SparkPrimeVault impl = new SparkPrimeVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(SparkPrimeVault.initialize, (address(savings), "Spark Prime", "spPRIME", admin))
        );
        vault = SparkPrimeVault(address(proxy));

        vm.startPrank(admin);
        vault.setCapacity(1_000_000e18);
        vault.grantRole(REBALANCER_ROLE, rebalancer);
        vault.grantRole(TAKER_ROLE, rebalancer);
        vm.stopPrank();

        asset.mint(alice, 100_000e18);
        asset.mint(bob, 100_000e18);
        asset.mint(charlie, 100_000e18);
        asset.mint(david, 100_000e18);

        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(charlie);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(david);
        asset.approve(address(vault), type(uint256).max);
    }

    function test_instantDeposit_consecutiveUsers() public {
        // Alice deposits 1000
        vm.prank(alice);
        uint256 reqIdAlice = vault.requestDeposit(1000e18, alice);
        assertEq(reqIdAlice, 0);
        assertEq(vault.balanceOf(alice), 1000e18);
        assertEq(vault.depositHead(), 1, "depositHead advanced to 1");

        // Bob deposits 500
        vm.prank(bob);
        uint256 reqIdBob = vault.requestDeposit(500e18, bob);
        assertEq(reqIdBob, 1);
        assertEq(vault.balanceOf(bob), 500e18, "Bob instantly filled!");
        assertEq(vault.depositHead(), 2, "depositHead advanced to 2");

        // Charlie deposits 250
        vm.prank(charlie);
        uint256 reqIdCharlie = vault.requestDeposit(250e18, charlie);
        assertEq(reqIdCharlie, 2);
        assertEq(vault.balanceOf(charlie), 250e18, "Charlie instantly filled!");
        assertEq(vault.depositHead(), 3, "depositHead advanced to 3");
    }

    function test_instantDeposit_afterPriorRequestCancelled() public {
        // Cap capacity so deposits don't fill instantly
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(alice);
        uint256 reqIdAlice = vault.requestDeposit(1000e18, alice);
        assertEq(reqIdAlice, 0);
        assertEq(vault.depositHead(), 0);

        // Alice cancels her deposit
        vm.prank(alice);
        vault.cancelDepositRequest(reqIdAlice, alice);
        // depositHead should have advanced past slot 0
        assertEq(vault.depositHead(), 1);

        // Now open capacity
        vm.prank(admin);
        vault.setCapacity(1_000_000e18);

        // Bob deposits - Bob should be instantly filled because nobody is queued ahead!
        vm.prank(bob);
        uint256 reqIdBob = vault.requestDeposit(500e18, bob);
        assertEq(reqIdBob, 1);
        assertEq(vault.balanceOf(bob), 500e18, "Bob instantly filled despite Alice cancellation!");
        assertEq(vault.depositHead(), 2);
    }

    function test_depositQueue_batchProcessingAndPartialFill() public {
        // Set capacity to 0
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(alice);
        vault.requestDeposit(1000e18, alice);
        vm.prank(bob);
        vault.requestDeposit(500e18, bob);
        vm.prank(charlie);
        vault.requestDeposit(500e18, charlie);

        // Now open capacity for 1250 (fills Alice: 1000, partially fills Bob: 250)
        vm.prank(admin);
        vault.setCapacity(1250e18);

        // Rebalancer processes with maxRequests = 10
        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max, 10);

        // Alice fully filled
        assertEq(vault.balanceOf(alice), 1000e18);
        // Bob partially filled with 250
        assertEq(vault.balanceOf(bob), 250e18);
        // Charlie unfilled
        assertEq(vault.balanceOf(charlie), 0);
        // depositHead stays at Bob (index 1)
        assertEq(vault.depositHead(), 1);

        // Now add more capacity (1000 more)
        vm.prank(admin);
        vault.setCapacity(2250e18);

        // Rebalancer processes again
        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max, 10);

        // Bob gets his remaining 250 -> total 500
        assertEq(vault.balanceOf(bob), 500e18);
        // Charlie gets his 500
        assertEq(vault.balanceOf(charlie), 500e18);
        // depositHead moves to 3
        assertEq(vault.depositHead(), 3);
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    function test_cancelDepositRequest_flowAndProcessing() public {
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(alice);
        uint256 reqId = vault.requestDeposit(1000e18, alice);

        // Alice cancels
        vm.prank(alice);
        uint256 cancelReqId = vault.cancelDepositRequest(reqId, alice);
        assertEq(cancelReqId, 0);

        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 1000e18);

        // Check refund
        uint256 aliceBalBefore = asset.balanceOf(alice);
        vm.prank(rebalancer);
        vault.processCancelledDepositQueue(type(uint256).max, 10);

        uint256 aliceBalAfter = asset.balanceOf(alice);
        assertEq(aliceBalAfter - aliceBalBefore, 1000e18, "Alice received 100% refund of deposit!");
        assertEq(vault.cancelledDepositHead(), 1);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    function test_redeemQueue_partialFillAndCancel() public {
        // Alice deposits 10_000
        vm.prank(alice);
        vault.requestDeposit(10_000e18, alice);
        assertEq(vault.balanceOf(alice), 10_000e18);

        // Alice requests redeem of 1000 shares
        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(1000e18, alice);
        assertEq(reqId, 0);

        // Rebalancer takes 9_500 savings shares, leaving 500
        vm.prank(rebalancer);
        vault.take(9_500e18);

        // Rebalancer processes redeem queue
        vm.prank(rebalancer);
        vault.processRedeemQueue(type(uint256).max, 1);

        // Alice gets 500 assets
        assertEq(asset.balanceOf(alice), 90_500e18);
        // Partial fill stays at redeemHead = 0
        assertEq(vault.redeemHead(), 0);

        // Alice cancels the remaining 500 shares
        uint256 aliceSharesBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.cancelRedeemRequest(reqId, alice);
        uint256 aliceSharesAfter = vault.balanceOf(alice);

        assertEq(aliceSharesAfter - aliceSharesBefore, 500e18);
        assertEq(vault.redeemHead(), 1, "redeemHead advanced after cancel");
        assertEq(vault.pendingRedeemShares(), 0);
    }
}
