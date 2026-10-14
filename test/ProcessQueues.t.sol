// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { LocalTestBase } from "./LocalTestBase.t.sol";

contract SparkPrimeVaultProcessQueuesTestBase is LocalTestBase {

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    uint256 aliceShares;  // Escrowed in the redeem queue
    uint256 bobShares;    // Queued deposit [spUSDC shares]

    // Capacity is exactly full with alice's shares, all of her spUSDC has been taken, alice is
    // queued to redeem everything and bob is queued to deposit 100k. The only spUSDC in the
    // vault belongs to bob's queued deposit.
    function setUp() public override {
        super.setUp();

        _deposit(alice, 100_000e6);
        _setCapacity(vault.totalSupply());
        _takeAll();

        aliceShares = vault.balanceOf(alice);
        _requestRedeem(alice, aliceShares);

        _deposit(bob, 100_000e6);
        ( , , bobShares ) = _depositRequest(1);

        assertEq(aliceShares,                         99_040.518410e6);
        assertEq(bobShares,                           95_453.269114e6);
        assertEq(vault.availableCapacity(),           0);
        assertEq(vault.pendingRedeemShares(),         aliceShares);
        assertEq(vault.pendingDepositSavingsShares(), bobShares);
        assertEq(_vaultSpUsdc(),                      bobShares);
        assertEq(vault.balanceOf(bob),                0);
    }

    function _processQueues(uint256 maxShares, uint256 maxRedeems, uint256 maxDeposits) internal {
        vm.prank(rebalancer);
        vault.processQueues(maxShares, maxRedeems, maxDeposits);
    }

}

contract SparkPrimeVaultProcessQueuesFailureTests is SparkPrimeVaultProcessQueuesTestBase {

    function test_processQueues_notRebalancer() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            REBALANCER_ROLE
        ));
        vault.processQueues(type(uint256).max, 1, 1);
    }

    function test_processQueues_paused() public {
        _pause();
        vm.expectRevert("SparkPrimeVault/paused");
        _processQueues(type(uint256).max, 1, 1);
    }

}

contract SparkPrimeVaultProcessQueuesSuccessTests is SparkPrimeVaultProcessQueuesTestBase {

    event Deposit(address indexed owner, address indexed recipient, uint256 assets, uint256 shares);
    event Redeem(address indexed owner, address indexed recipient, uint256 assets, uint256 shares);

    // Deposit-first makes no progress: capacity is full until the redeems burn.
    function test_processQueues_depositQueueAloneIsStuck() public {
        _processDeposits(type(uint256).max, 1);

        assertEq(vault.balanceOf(bob),                0);
        assertEq(vault.pendingDepositSavingsShares(), bobShares);
        assertEq(vault.availableCapacity(),           0);
    }

    function test_processQueues_netsFully() public {
        vm.expectEmit(address(vault));
        emit Redeem(alice, alice, 99_999.999998e6, aliceShares);
        vm.expectEmit(address(vault));
        emit Deposit(bob, bob, 99_999.999997e6, 99_040.518408e6);

        _processQueues(type(uint256).max, 1, 1);

        assertEq(usdc.balanceOf(alice),               99_999.999998e6);
        assertEq(vault.balanceOf(alice),              0);
        assertEq(vault.balanceOf(bob),                99_040.518408e6);
        assertEq(vault.assetsOf(bob),                 99_999.999996e6);
        assertEq(vault.totalSupply(),                 99_040.518408e6);
        assertEq(vault.availableCapacity(),           2);
        assertEq(vault.pendingRedeemShares(),         0);
        assertEq(vault.pendingDepositSavingsShares(), 2);  // Rounding dust stays queued
        assertEq(_vaultSpUsdc(),                      1);  // spUSDC `withdraw` ceil-rounds (R9)
        assertEq(vault.redeemHead(),                  1);
        assertEq(vault.depositHead(),                 1);  // Partial fill keeps bob at the head
    }

    // `maxShares_` bounds the redeem side, and the deposit side fills only what that freed.
    function test_processQueues_maxSharesBoundsBothSides() public {
        _processQueues(50_000e6, 1, 1);

        assertEq(usdc.balanceOf(alice),               50_484.388412e6);
        assertEq(vault.balanceOf(bob),                49_999.999998e6);
        assertEq(vault.totalSupply(),                 99_040.518408e6);
        assertEq(vault.availableCapacity(),           2);
        assertEq(vault.pendingRedeemShares(),         49_040.518410e6);
        assertEq(vault.pendingDepositSavingsShares(), 47_264.269983e6);
        assertEq(vault.redeemHead(),                  0);
        assertEq(vault.depositHead(),                 1);

        _processQueues(type(uint256).max, 1, 1);

        assertEq(usdc.balanceOf(alice),               99_999.999998e6);
        assertEq(vault.balanceOf(bob),                99_040.518408e6);
        assertEq(vault.pendingRedeemShares(),         0);
        assertEq(vault.pendingDepositSavingsShares(), 1);
        assertEq(vault.redeemHead(),                  1);
        assertEq(vault.depositHead(),                 1);
    }

}
