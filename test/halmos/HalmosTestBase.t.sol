// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { SymTest } from "../../lib/halmos-cheatcodes/src/SymTest.sol";

import { ERC1967Proxy } from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MockERC20, MockSavings } from "../mocks/Mocks.sol";

import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../src/SparkPrimeVault.sol";

abstract contract HalmosTestBase is SymTest, Test {

    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;

    bytes32 internal constant DEFAULT_ADMIN_ROLE     = 0x00;
    bytes32 internal constant LOSS_MANAGER_ROLE      = keccak256("LOSS_MANAGER_ROLE");
    bytes32 internal constant OPERATOR_ROLE          = keccak256("OPERATOR_ROLE");
    bytes32 internal constant PAUSER_ROLE            = keccak256("PAUSER_ROLE");
    bytes32 internal constant REDEEM_FEE_SETTER_ROLE = keccak256("REDEEM_FEE_SETTER_ROLE");
    bytes32 internal constant TAKER_ROLE             = keccak256("TAKER_ROLE");
    bytes32 internal constant UNPAUSER_ROLE          = keccak256("UNPAUSER_ROLE");

    address internal admin           = address(0x1001);
    address internal lossManager     = address(0x1002);
    address internal operator        = address(0x1003);
    address internal pauser          = address(0x1004);
    address internal redeemFeeSetter = address(0x1005);
    address internal taker           = address(0x1006);
    address internal unpauser        = address(0x1007);

    address internal userA = address(0xAAA1);
    address internal userB = address(0xBBB1);
    address internal userC = address(0xCCC1);

    MockERC20       internal asset;
    MockSavings     internal savings;
    SparkPrimeVault internal vault;

    uint256 internal seededDepositId;

    // halmos makes block.timestamp symbolic: pin it so drip() short-circuits and
    // _rpow never runs with a symbolic exponent.
    modifier frozenTime() {
        vm.warp(vault.rho());
        _;
    }

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

        _setCapacity(type(uint128).max);
    }

    // State after seeding: userA holds shares, userB has a partially cancelled pending deposit,
    // each queue holds one live request. Amounts are concrete: halmos requires a single-path setUp.
    function _seedVault() internal {
        _deposit(userA, 1_000_000e6);

        _setCapacity(vault.totalSupply());

        seededDepositId = _deposit(userB, 1_000_000e6);

        vm.prank(userB);
        vault.requestDepositCancellation(seededDepositId, userB, 400_000e6);

        vm.prank(userA);
        vault.requestRedeem(300_000e6, userA);

        asset.mint(userC, 1e30);
        vm.prank(userC);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(userA);
        vault.approve(userC, 500_000e6);
    }

    function _deposit(address user, uint256 assets_) internal returns (uint256 requestId) {
        asset.mint(user, assets_);

        vm.startPrank(user);
        asset.approve(address(vault), assets_);
        requestId = vault.requestDeposit(assets_, user, 0);
        vm.stopPrank();
    }

    function _pause() internal {
        vm.prank(pauser);
        vault.pause();
    }

    function _setCapacity(uint256 capacity) internal {
        vm.prank(operator);
        vault.setCapacity(capacity);
    }

    function _setRedeemFeeRate(uint256 feeRate) internal {
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(feeRate);
    }

    // rho (uint64) and chi (uint192) are packed into slot 7, verified by the assertion.
    // Rates range over a grid of literal constants via if/else forks: division by a symbolic
    // rate is intractable for SMT solvers, so each halmos path gets a concrete divisor.
    function _symbolicRates() internal {
        uint192 chi = uint192(_gridValue(svm.createUint(8, "chiIdx")));
        vm.store(address(vault), bytes32(uint256(7)), bytes32(uint256(chi) << 64 | vault.rho()));
        assertEq(vault.chi(), chi);

        savings.setRate(_gridValue(svm.createUint(8, "rateIdx")));
    }

    function _gridValue(uint256 index) internal pure returns (uint256) {
        uint256 i = index % 5;
        if (i == 0) return RAY / 10;
        if (i == 1) return RAY;
        if (i == 2) return RAY + 1;
        if (i == 3) return 2 * RAY;
        return 100 * RAY;
    }

    function _gridFeeRate(uint256 index) internal pure returns (uint256) {
        uint256 i = index % 5;
        if (i == 0) return 0;
        if (i == 1) return 1;
        if (i == 2) return 1e14;
        if (i == 3) return 0.01e18 - 1;
        return 0.01e18;
    }

    function _anyCall() internal returns (bytes4 selector) {
        return _anyCall(svm.createAddress("sender"));
    }

    // The vault never calls itself; upgrades replace the code, so no invariant survives them.
    function _anyCall(address sender) internal returns (bytes4 selector) {
        vm.assume(sender != address(vault));

        bytes memory data = svm.createCalldata("SparkPrimeVault");
        selector = bytes4(data);
        vm.assume(selector != vault.upgradeToAndCall.selector);

        vm.prank(sender);
        ( bool success, ) = address(vault).call(data);
        vm.assume(success);
    }

    function _senderWithoutRoles() internal returns (address sender) {
        sender = svm.createAddress("sender");
        vm.assume(!vault.hasRole(DEFAULT_ADMIN_ROLE,     sender));
        vm.assume(!vault.hasRole(LOSS_MANAGER_ROLE,      sender));
        vm.assume(!vault.hasRole(OPERATOR_ROLE,          sender));
        vm.assume(!vault.hasRole(PAUSER_ROLE,            sender));
        vm.assume(!vault.hasRole(REDEEM_FEE_SETTER_ROLE, sender));
        vm.assume(!vault.hasRole(TAKER_ROLE,             sender));
        vm.assume(!vault.hasRole(UNPAUSER_ROLE,          sender));
    }

    function _queueLengths()
        internal view
        returns (uint256 deposits, uint256 cancellations, uint256 redeems)
    {
        deposits      = vault.firstPendingDepositId()             + vault.getPendingDepositRequests().length;
        cancellations = vault.firstPendingDepositCancellationId() + vault.getPendingDepositCancellationRequests().length;
        redeems       = vault.firstPendingRedeemId()              + vault.getPendingRedeemRequests().length;
    }

}

abstract contract SeededHalmosTestBase is HalmosTestBase {

    function setUp() public virtual override {
        super.setUp();
        _seedVault();
    }

}
