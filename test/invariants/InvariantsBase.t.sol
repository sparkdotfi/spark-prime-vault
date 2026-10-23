// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { ERC1967Proxy } from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MockERC20, MockSavings } from "../mocks/Mocks.sol";

import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../src/SparkPrimeVault.sol";

import { AdminHandler }    from "./handlers/AdminHandler.sol";
import { ExternalHandler } from "./handlers/ExternalHandler.sol";
import { OperatorHandler } from "./handlers/OperatorHandler.sol";
import { UserHandler }     from "./handlers/UserHandler.sol";

abstract contract SparkPrimeInvariantTestBase is Test {

    uint256 internal constant RAY = 1e27;

    bytes32 internal constant LOSS_MANAGER_ROLE      = keccak256("LOSS_MANAGER_ROLE");
    bytes32 internal constant OPERATOR_ROLE          = keccak256("OPERATOR_ROLE");
    bytes32 internal constant PAUSER_ROLE            = keccak256("PAUSER_ROLE");
    bytes32 internal constant REDEEM_FEE_SETTER_ROLE = keccak256("REDEEM_FEE_SETTER_ROLE");
    bytes32 internal constant TAKER_ROLE             = keccak256("TAKER_ROLE");
    bytes32 internal constant UNPAUSER_ROLE          = keccak256("UNPAUSER_ROLE");

    address internal admin           = makeAddr("admin");
    address internal lossManager     = makeAddr("lossManager");
    address internal operator        = makeAddr("operator");
    address internal pauser          = makeAddr("pauser");
    address internal redeemFeeSetter = makeAddr("redeemFeeSetter");
    address internal taker           = makeAddr("taker");
    address internal unpauser        = makeAddr("unpauser");

    MockERC20       internal asset;
    MockSavings     internal savings;
    SparkPrimeVault internal vault;

    AdminHandler    internal adminHandler;
    ExternalHandler internal externalHandler;
    OperatorHandler internal operatorHandler;
    UserHandler     internal userHandler;

    function setUp() public virtual {
        asset   = new MockERC20();
        savings = new MockSavings(asset);

        vault = SparkPrimeVault(address(new ERC1967Proxy(
            address(new SparkPrimeVault()),
            abi.encodeCall(
                ISparkPrimeVault.initialize,
                (address(savings), "Spark Prime USDC", "spPRIME", admin, 1, 1, 1)
            )
        )));

        vm.startPrank(admin);
        vault.grantRole(LOSS_MANAGER_ROLE,      lossManager);
        vault.grantRole(OPERATOR_ROLE,          operator);
        vault.grantRole(PAUSER_ROLE,            pauser);
        vault.grantRole(REDEEM_FEE_SETTER_ROLE, redeemFeeSetter);
        vault.grantRole(TAKER_ROLE,             taker);
        vault.grantRole(UNPAUSER_ROLE,          unpauser);
        vault.setVSRBounds(RAY, vault.MAX_VSR());
        vault.setMaxRedeemFeeRate(vault.MAX_REDEEM_FEE());
        vm.stopPrank();

        vm.prank(operator);
        vault.setCapacity(1e30);
    }

    // Everyone exits: process all queues with ample liquidity, redeem all shares, claim all.
    function _unwind() internal {
        if (vault.paused()) {
            vm.prank(unpauser);
            vault.unpause();
        }

        vm.startPrank(admin);
        vault.setMinDeposit(1);
        vault.setMinDepositCancellation(1);
        vault.setMinRedeem(1);
        vm.stopPrank();

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            asset.setBlocked(userHandler.users(i), false);
        }

        vm.prank(operator);
        vault.setCapacity(1e30);

        // Return taken backing and cover any shortfall from vsr outrunning the savings rate,
        // so the queues can always fill (mirrors _give in the spark-vaults-v2 suite).
        uint256 takerShares = savings.balanceOf(taker);

        vm.prank(taker);
        savings.transfer(address(vault), takerShares);

        asset.mint(address(savings), 1e45);

        uint256 required = vault.pendingCancelledDepositSavingsShares()
            + savings.convertToShares(
                vault.totalAssets() + savings.convertToAssets(vault.pendingDepositSavingsShares())
            )
            + 1e12;

        uint256 held = savings.balanceOf(address(vault));

        if (held < required) {
            uint256 topUpAssets = savings.convertToAssets(required - held) + 1;
            asset.mint(address(this), topUpAssets);
            asset.approve(address(savings), topUpAssets);
            savings.deposit(topUpAssets, address(vault));
        }

        vm.startPrank(operator);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);
        vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);
        vm.stopPrank();

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            address user    = userHandler.users(i);
            uint256 balance = vault.balanceOf(user);

            if (balance == 0) continue;

            vm.prank(user);
            vault.requestRedeem(balance, user);
        }

        vm.prank(operator);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            address user = userHandler.users(i);

            if (vault.claimableAssets(user) == 0) continue;

            vault.claim(user);
        }
    }

    function _assertUnwound() internal view {
        assertEq(vault.pendingDepositSavingsShares(),          0, "pendingDeposit");
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0, "pendingCancel");
        assertEq(vault.pendingRedeemShares(),                  0, "pendingRedeem");

        assertEq(vault.getPendingDepositRequests().length,             0, "deposit queue");
        assertEq(vault.getPendingDepositCancellationRequests().length, 0, "cancel queue");
        assertEq(vault.getPendingRedeemRequests().length,              0, "redeem queue");

        assertEq(vault.balanceOf(address(vault)),  0, "vault escrow");
        assertEq(vault.totalSupply(),              0, "totalSupply");
        assertEq(vault.totalClaimable(),           0, "totalClaimable");
        assertEq(asset.balanceOf(address(vault)),  0, "vault asset balance");
    }

}
