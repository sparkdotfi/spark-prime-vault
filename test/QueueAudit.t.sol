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
    uint256 public maxRedeemLimit = type(uint256).max;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Savings Mock USD", "smUSD") {}

    function setMaxRedeemLimit(uint256 limit) external {
        maxRedeemLimit = limit;
    }

    function maxRedeem(address owner) public view virtual override returns (uint256) {
        uint256 bal = balanceOf(owner);
        return bal < maxRedeemLimit ? bal : maxRedeemLimit;
    }
}

contract QueueAuditTest is Test {
    MockAsset internal asset;
    MockSavings internal savings;
    SparkPrimeVault internal vault;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal rebalancer = makeAddr("rebalancer");
    address internal riskManager = makeAddr("riskManager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");
    address internal david = makeAddr("david");
    address internal attacker = makeAddr("attacker");

    bytes32 internal GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 internal RISK_MANAGER_ROLE = keccak256("RISK_MANAGER_ROLE");
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
        vault.grantRole(GUARDIAN_ROLE, guardian);
        vault.grantRole(REBALANCER_ROLE, rebalancer);
        vault.grantRole(RISK_MANAGER_ROLE, riskManager);
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
        vm.prank(alice);
        uint256 reqIdAlice = vault.requestDeposit(1000e18, alice);
        assertEq(reqIdAlice, 0);
        assertEq(vault.balanceOf(alice), 1000e18);
        assertEq(vault.depositHead(), 1, "depositHead advanced to 1");

        vm.prank(bob);
        uint256 reqIdBob = vault.requestDeposit(500e18, bob);
        assertEq(reqIdBob, 1);
        assertEq(vault.balanceOf(bob), 500e18, "Bob instantly filled!");
        assertEq(vault.depositHead(), 2, "depositHead advanced to 2");

        vm.prank(charlie);
        uint256 reqIdCharlie = vault.requestDeposit(250e18, charlie);
        assertEq(reqIdCharlie, 2);
        assertEq(vault.balanceOf(charlie), 250e18, "Charlie instantly filled!");
        assertEq(vault.depositHead(), 3, "depositHead advanced to 3");
    }

    function test_instantDeposit_afterPriorRequestCancelled() public {
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(alice);
        uint256 reqIdAlice = vault.requestDeposit(1000e18, alice);
        assertEq(reqIdAlice, 0);
        assertEq(vault.depositHead(), 0);

        vm.prank(alice);
        vault.requestDepositCancellation(reqIdAlice, alice);
        assertEq(vault.depositHead(), 1);

        vm.prank(admin);
        vault.setCapacity(1_000_000e18);

        vm.prank(bob);
        uint256 reqIdBob = vault.requestDeposit(500e18, bob);
        assertEq(reqIdBob, 1);
        assertEq(vault.balanceOf(bob), 500e18, "Bob instantly filled despite Alice cancellation!");
        assertEq(vault.depositHead(), 2);
    }

    function test_depositQueue_batchProcessingAndPartialFill() public {
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(alice);
        vault.requestDeposit(1000e18, alice);
        vm.prank(bob);
        vault.requestDeposit(500e18, bob);
        vm.prank(charlie);
        vault.requestDeposit(500e18, charlie);

        vm.prank(admin);
        vault.setCapacity(1250e18);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max, 10);

        assertEq(vault.balanceOf(alice), 1000e18);
        assertEq(vault.balanceOf(bob), 250e18);
        assertEq(vault.balanceOf(charlie), 0);
        assertEq(vault.depositHead(), 1);

        vm.prank(admin);
        vault.setCapacity(2250e18);

        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max, 10);

        assertEq(vault.balanceOf(bob), 500e18);
        assertEq(vault.balanceOf(charlie), 500e18);
        assertEq(vault.depositHead(), 3);
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    function test_cancelDepositRequest_flowAndProcessing() public {
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(alice);
        uint256 reqId = vault.requestDeposit(1000e18, alice);

        vm.prank(alice);
        uint256 cancelReqId = vault.requestDepositCancellation(reqId, alice);
        assertEq(cancelReqId, 0);

        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 1000e18);

        uint256 aliceBalBefore = asset.balanceOf(alice);
        vm.prank(rebalancer);
        vault.processCancelledDepositQueue(type(uint256).max, 10);

        uint256 aliceBalAfter = asset.balanceOf(alice);
        assertEq(aliceBalAfter - aliceBalBefore, 1000e18, "Alice received 100% refund of deposit!");
        assertEq(vault.depositCancellationHead(), 1);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    function test_processCancelledDepositQueue_respectsMaxRedeem() public {
        // Alice deposits 1000 while capacity is 0
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(alice);
        uint256 reqId = vault.requestDeposit(1000e18, alice);

        vm.prank(alice);
        vault.requestDepositCancellation(reqId, alice);

        // Savings has maxRedeem limited to 400
        savings.setMaxRedeemLimit(400e18);

        // Rebalancer processes cancelled queue
        uint256 balBefore = asset.balanceOf(alice);
        vm.prank(rebalancer);
        vault.processCancelledDepositQueue(type(uint256).max, 10);

        // Alice receives only 400 (partial cancellation fill)
        uint256 balAfter = asset.balanceOf(alice);
        assertEq(balAfter - balBefore, 400e18);
        // depositCancellationHead remains 0 because request is partially filled
        assertEq(vault.depositCancellationHead(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 600e18);

        // Savings liquidity frees up: maxRedeem restored to 1000
        savings.setMaxRedeemLimit(1000e18);

        vm.prank(rebalancer);
        vault.processCancelledDepositQueue(type(uint256).max, 10);

        // Alice receives remaining 600
        assertEq(asset.balanceOf(alice) - balBefore, 1000e18);
        assertEq(vault.depositCancellationHead(), 1);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    function test_redeemQueue_partialFillAndCancel() public {
        vm.prank(alice);
        vault.requestDeposit(10_000e18, alice);
        assertEq(vault.balanceOf(alice), 10_000e18);

        vm.prank(alice);
        uint256 reqId = vault.requestRedeem(1000e18, alice);
        assertEq(reqId, 0);

        vm.prank(rebalancer);
        vault.take(9_500e18);

        vm.prank(rebalancer);
        vault.processRedeemQueue(type(uint256).max, 1);

        assertEq(asset.balanceOf(alice), 90_500e18);
        assertEq(vault.redeemHead(), 0);

        uint256 aliceSharesBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.cancelRedeemRequest(reqId, alice);
        uint256 aliceSharesAfter = vault.balanceOf(alice);

        assertEq(aliceSharesAfter - aliceSharesBefore, 500e18);
        assertEq(vault.redeemHead(), 1, "redeemHead advanced after cancel");
        assertEq(vault.pendingRedeemShares(), 0);
    }

    function test_updateRecipient_authorizationEnforced() public {
        vm.prank(admin);
        vault.setCapacity(0);

        vm.prank(alice);
        uint256 depReqId = vault.requestDeposit(1000e18, alice);

        // Attacker attempts to hijack recipient
        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositRecipient(depReqId, attacker);

        // Alice successfully updates recipient to Bob
        vm.prank(alice);
        vault.updateDepositRecipient(depReqId, bob);

        // Non-owner (even guardian) cannot update recipient - owner only
        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositRecipient(depReqId, charlie);

        // Cancel deposit and test updateCancelledDepositRecipient
        vm.prank(alice);
        uint256 cancelReqId = vault.requestDepositCancellation(depReqId, alice);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateCancelledDepositRecipient(cancelReqId, attacker);

        vm.prank(alice);
        vault.updateCancelledDepositRecipient(cancelReqId, david);

        // Redeem queue recipient update
        vm.prank(admin);
        vault.setCapacity(100_000e18);

        vm.prank(alice);
        vault.requestDeposit(1000e18, alice);

        vm.prank(alice);
        uint256 redReqId = vault.requestRedeem(500e18, alice);

        vm.prank(attacker);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateRedeemRecipient(redReqId, attacker);

        vm.prank(alice);
        vault.updateRedeemRecipient(redReqId, bob);
    }

    function test_realizeGain_and_realizeLoss() public {
        vm.prank(alice);
        vault.requestDeposit(10_000e18, alice);

        uint256 assetsBefore = vault.totalAssets();
        uint192 chiBefore = vault.chi();

        // Admin realizes gain of 1000
        vm.prank(admin);
        vault.realizeGain(1000e18);

        assertGt(vault.chi(), chiBefore);
        assertGt(vault.totalAssets(), assetsBefore);

        // Risk manager realizes loss while paused
        vm.prank(guardian);
        vault.pause();

        uint192 chiAfterGain = vault.chi();
        vm.prank(riskManager);
        vault.realizeLoss(500e18);

        assertLt(vault.chi(), chiAfterGain);

        // Unpause by admin
        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }
}
