// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl } from "../lib/oz/contracts/access/IAccessControl.sol";
import { ERC1967Proxy }   from "../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

import { SparkPrimeVaultV2Mock } from "./mocks/SparkPrimeVaultV2Mock.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

contract InvalidSparkPrimeVault1 {

    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(0);
    }

}

contract InvalidSparkPrimeVault2 {}

/// @dev UUPS upgrade tests: authorization, invalid targets, exact state preservation (every
///      public getter and every raw storage slot 0..22), re-initialization guards, and the
///      implementation contract itself.
contract UpgradeTest is LocalTestBase {

    // keccak256("eip1967.proxy.implementation") - 1
    bytes32 constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    uint256 constant V1_SLOTS = 23;  // savings (0) .. allowance (22)

    event Upgraded(address indexed implementation);

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    SparkPrimeVaultV2Mock newImplementation;

    uint256 depId;
    uint256 redId;
    uint256 setVsrTimestamp;

    // Build non-trivial state: shares, a queued deposit, a queued redeem, a fee, a rate, allowance.
    function setUp() public override {
        super.setUp();

        newImplementation = new SparkPrimeVaultV2Mock();

        _setRedeemFee(0.001e18);
        _setMinimums(1e6, 1e6);
        _setPrimeVsr(FOUR_PCT_VSR);
        setVsrTimestamp = block.timestamp;

        _deposit(alice, 1_000_000e6);
        redId = _requestRedeem(alice, 100_000e6);

        _setCapacity(vault.totalSupply());
        depId = _deposit(bob, 50_000e6);

        vm.prank(alice);
        vault.approve(bob, 123);

        skip(1 days);
    }

    /**********************************************************************************************/
    /*** Failure cases                                                                          ***/
    /**********************************************************************************************/

    function test_upgradeToAndCall_notAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        vault.upgradeToAndCall(address(newImplementation), "");
    }

    function test_upgradeToAndCall_implementationUUIDNotSupported() public {
        address invalidImplementation = address(new InvalidSparkPrimeVault1());

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("UUPSUnsupportedProxiableUUID(bytes32)", bytes32(0)));
        vault.upgradeToAndCall(invalidImplementation, "");
    }

    function test_upgradeToAndCall_implementationHasNoUUID() public {
        address invalidImplementation = address(new InvalidSparkPrimeVault2());

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature(
            "ERC1967InvalidImplementation(address)",
            invalidImplementation
        ));
        vault.upgradeToAndCall(invalidImplementation, "");
    }

    // `upgradeToAndCall` must be called through the proxy, never on the implementation.
    function test_upgradeToAndCall_notProxy() public {
        SparkPrimeVault impl_ = SparkPrimeVault(vault.implementation());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("UUPSUnauthorizedCallContext()"));
        impl_.upgradeToAndCall(address(newImplementation), "");
    }

    function test_initialize_alreadyInitialized() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vault.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vault.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);
    }

    // The implementation contract has `_disableInitializers()` in its constructor.
    function test_initialize_implementationCannotBeInitialized() public {
        SparkPrimeVault impl_ = SparkPrimeVault(vault.implementation());

        // _initialized == type(uint64).max
        assertEq(
            vm.load(address(impl_), INITIALIZABLE_STORAGE),
            bytes32(uint256(type(uint64).max))
        );

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        impl_.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        newImplementation.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        newImplementation.initializeV2(1);
    }

    // Upgrading with calldata that re-runs `initialize` reverts and the upgrade is rolled back.
    function test_upgradeToAndCall_reinitializeReverts() public {
        address oldImpl_ = vault.implementation();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vault.upgradeToAndCall(
            address(newImplementation),
            abi.encodeCall(SparkPrimeVault.initialize, (address(spUsdc), "x", "x", admin))
        );

        assertEq(vault.implementation(), oldImpl_);
    }

    /**********************************************************************************************/
    /*** Success cases                                                                          ***/
    /**********************************************************************************************/

    struct Snapshot {
        address savings;
        uint8   decimals;
        string  name;
        string  symbol;
        uint64  rho;
        uint192 chi;
        uint256 vsr;
        uint256 minVSR;
        uint256 maxVSR;
        bool    paused;
        uint256 maxCapacity;
        uint256 minDeposit;
        uint256 minWithdraw;
        uint256 redeemFee;
        uint256 maxRedeemFee;
        uint256 totalSupply;
        uint256 pendingDepositSavingsShares;
        uint256 pendingRedeemShares;
        uint256 depositHead;
        uint256 redeemHead;
        uint256 totalAssets;
        uint192 nowChi;
        uint256 balAlice;
        uint256 balBob;
        uint256 balVault;
        uint256 nonceAlice;
        uint256 allowanceAliceBob;
        address depOwner;
        address depRecipient;
        uint256 depShares;
        address redOwner;
        address redRecipient;
        uint256 redShares;
        uint256 spUsdcBal;
        bytes32 domainSeparator;
    }

    function _snapshot() internal view returns (Snapshot memory s_) {
        s_.savings                     = vault.savings();
        s_.decimals                    = vault.decimals();
        s_.name                        = vault.name();
        s_.symbol                      = vault.symbol();
        s_.rho                         = vault.rho();
        s_.chi                         = vault.chi();
        s_.vsr                         = vault.vsr();
        s_.minVSR                      = vault.minVSR();
        s_.maxVSR                      = vault.maxVSR();
        s_.paused                      = vault.paused();
        s_.maxCapacity                 = vault.maxCapacity();
        s_.minDeposit                  = vault.minDeposit();
        s_.minWithdraw                 = vault.minWithdraw();
        s_.redeemFee                   = vault.redeemFee();
        s_.maxRedeemFee                = vault.maxRedeemFee();
        s_.totalSupply                 = vault.totalSupply();
        s_.pendingDepositSavingsShares = vault.pendingDepositSavingsShares();
        s_.pendingRedeemShares         = vault.pendingRedeemShares();
        s_.depositHead                 = vault.depositHead();
        s_.redeemHead                  = vault.redeemHead();
        s_.totalAssets                 = vault.totalAssets();
        s_.nowChi                      = vault.nowChi();
        s_.balAlice                    = vault.balanceOf(alice);
        s_.balBob                      = vault.balanceOf(bob);
        s_.balVault                    = vault.balanceOf(address(vault));
        s_.nonceAlice                  = vault.nonces(alice);
        s_.allowanceAliceBob           = vault.allowance(alice, bob);
        (s_.depOwner, s_.depRecipient, s_.depShares) = vault.depositQueue(depId);
        (s_.redOwner, s_.redRecipient, s_.redShares) = vault.redeemQueue(redId);
        s_.spUsdcBal                   = spUsdc.balanceOf(address(vault));
        s_.domainSeparator             = vault.DOMAIN_SEPARATOR();
    }

    function _assertSnapshot(Snapshot memory s_) internal view {
        assertEq(s_.savings,                     address(spUsdc));
        assertEq(s_.decimals,                    6);
        assertEq(s_.name,                        "Spark Prime USDC");
        assertEq(s_.symbol,                      "spPRIME");
        assertEq(s_.rho,                         setVsrTimestamp);
        assertEq(s_.vsr,                         FOUR_PCT_VSR);
        assertEq(s_.minVSR,                      RAY);
        assertEq(s_.maxVSR,                      MAX_VSR);
        assertEq(s_.paused,                      false);
        assertEq(s_.minDeposit,                  1e6);
        assertEq(s_.minWithdraw,                 1e6);
        assertEq(s_.redeemFee,                   0.001e18);
        assertEq(s_.maxRedeemFee,                0.01e18);
        assertEq(s_.pendingRedeemShares,         99_900e6);
        assertEq(s_.depositHead,                 1);
        assertEq(s_.redeemHead,                  0);
        assertEq(s_.balVault,                    99_900e6);
        assertEq(s_.balBob,                      0);
        assertEq(s_.nonceAlice,                  0);
        assertEq(s_.allowanceAliceBob,           123);
        assertEq(s_.depOwner,                    bob);
        assertEq(s_.depRecipient,                bob);
        assertEq(s_.redOwner,                    alice);
        assertEq(s_.redRecipient,                alice);
        assertEq(s_.redShares,                   99_900e6);
        assertGt(s_.chi,                         RAY);
        assertGt(s_.nowChi,                      s_.chi);  // 1 day of undripped accrual
        assertGt(s_.depShares,                   0);
        assertEq(s_.pendingDepositSavingsShares, s_.depShares);
        assertEq(s_.totalSupply,                 s_.balAlice + s_.balVault);
        assertEq(s_.maxCapacity,                 s_.totalSupply);
    }

    function _assertSnapshotsEqual(Snapshot memory a_, Snapshot memory b_) internal pure {
        assertEq(keccak256(abi.encode(a_)), keccak256(abi.encode(b_)));
    }

    function _rawSlots(address target_) internal view returns (bytes32[] memory slots_) {
        slots_ = new bytes32[](V1_SLOTS);
        for (uint256 i; i < V1_SLOTS; ++i) slots_[i] = vm.load(target_, bytes32(i));
    }

    function test_upgradeToAndCall() public {
        Snapshot memory before_ = _snapshot();
        _assertSnapshot(before_);

        bytes32[] memory slotsBefore_ = _rawSlots(address(vault));

        address[] memory admins_      = vault.getRoleMembers(DEFAULT_ADMIN_ROLE);
        address[] memory guardians_   = vault.getRoleMembers(GUARDIAN_ROLE);
        address[] memory rebalancers_ = vault.getRoleMembers(REBALANCER_ROLE);
        address[] memory riskMgrs_    = vault.getRoleMembers(RISK_MANAGER_ROLE);
        address[] memory setters_     = vault.getRoleMembers(SETTER_ROLE);
        address[] memory takers_      = vault.getRoleMembers(TAKER_ROLE);
        address[] memory unpausers_   = vault.getRoleMembers(UNPAUSER_ROLE);

        assertEq(admins_.length,      1); assertEq(admins_[0],      admin);
        assertEq(guardians_.length,   1); assertEq(guardians_[0],   guardian);
        assertEq(rebalancers_.length, 1); assertEq(rebalancers_[0], rebalancer);
        assertEq(riskMgrs_.length,    1); assertEq(riskMgrs_[0],    riskManager);
        assertEq(setters_.length,     1); assertEq(setters_[0],     setter);
        assertEq(takers_.length,      1); assertEq(takers_[0],      taker);
        assertEq(unpausers_.length,   1); assertEq(unpausers_[0],   unpauser);

        address oldImpl_ = vault.implementation();
        assertTrue(oldImpl_ != address(newImplementation));
        assertEq(
            address(uint160(uint256(vm.load(address(vault), IMPLEMENTATION_SLOT)))),
            oldImpl_
        );
        assertEq(vm.load(address(vault), INITIALIZABLE_STORAGE), bytes32(uint256(1)));

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit Upgraded(address(newImplementation));
        vault.upgradeToAndCall(address(newImplementation), "");

        assertEq(vault.implementation(), address(newImplementation));
        assertEq(
            address(uint160(uint256(vm.load(address(vault), IMPLEMENTATION_SLOT)))),
            address(newImplementation)
        );
        assertEq(vm.load(address(vault), INITIALIZABLE_STORAGE), bytes32(uint256(1)));

        // Every public getter is unchanged.
        Snapshot memory after_ = _snapshot();
        _assertSnapshot(after_);
        _assertSnapshotsEqual(before_, after_);

        // Every raw V1 slot is unchanged, the appended slot is empty.
        bytes32[] memory slotsAfter_ = _rawSlots(address(vault));
        for (uint256 i; i < V1_SLOTS; ++i) assertEq(slotsAfter_[i], slotsBefore_[i]);
        assertEq(vm.load(address(vault), bytes32(uint256(V1_SLOTS))), bytes32(0));

        // Roles are unchanged.
        assertEq(vault.getRoleMembers(DEFAULT_ADMIN_ROLE), admins_);
        assertEq(vault.getRoleMembers(GUARDIAN_ROLE),      guardians_);
        assertEq(vault.getRoleMembers(REBALANCER_ROLE),    rebalancers_);
        assertEq(vault.getRoleMembers(RISK_MANAGER_ROLE),  riskMgrs_);
        assertEq(vault.getRoleMembers(SETTER_ROLE),        setters_);
        assertEq(vault.getRoleMembers(TAKER_ROLE),         takers_);
        assertEq(vault.getRoleMembers(UNPAUSER_ROLE),      unpausers_);

        // New code is live, new storage starts empty.
        SparkPrimeVaultV2Mock v2_ = SparkPrimeVaultV2Mock(address(vault));
        assertEq(v2_.version2(), "2");
        assertEq(v2_.newVar(),   0);

        // V1 `initialize` still cannot be called.
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vault.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);

        // The vault keeps working: the open queues can be processed by the rebalancer.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingRedeemShares(),         0);
        assertGt(vault.balanceOf(bob),                0);
        assertGt(usdc.balanceOf(alice),               0);
    }

    function test_upgradeToAndCall_withReinitializer() public {
        bytes32[] memory slotsBefore_ = _rawSlots(address(vault));
        Snapshot memory before_ = _snapshot();

        vm.prank(admin);
        vault.upgradeToAndCall(
            address(newImplementation),
            abi.encodeCall(SparkPrimeVaultV2Mock.initializeV2, (777))
        );

        SparkPrimeVaultV2Mock v2_ = SparkPrimeVaultV2Mock(address(vault));
        assertEq(v2_.newVar(), 777);
        assertEq(vm.load(address(vault), bytes32(uint256(V1_SLOTS))), bytes32(uint256(777)));
        assertEq(vm.load(address(vault), INITIALIZABLE_STORAGE),      bytes32(uint256(2)));

        bytes32[] memory slotsAfter_ = _rawSlots(address(vault));
        for (uint256 i; i < V1_SLOTS; ++i) assertEq(slotsAfter_[i], slotsBefore_[i]);
        _assertSnapshotsEqual(before_, _snapshot());

        // Neither initializer can run again.
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        v2_.initializeV2(1);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vault.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);
    }

    // A second upgrade back to a fresh V1 implementation also preserves state.
    function test_upgradeToAndCall_roundTrip() public {
        Snapshot memory before_ = _snapshot();

        vm.prank(admin);
        vault.upgradeToAndCall(address(newImplementation), "");
        address v1_ = address(new SparkPrimeVault());
        vm.prank(admin);
        vault.upgradeToAndCall(v1_, "");

        assertEq(vault.implementation(), v1_);
        _assertSnapshotsEqual(before_, _snapshot());
    }

    // Storage layout checks that a future upgrade must keep: `savings` and `decimals` pack into
    // slot 0, `rho` and `chi` pack into slot 3.
    function test_storageLayout_packing() public view {
        bytes32 slot0_ = vm.load(address(vault), bytes32(uint256(0)));
        assertEq(address(uint160(uint256(slot0_))),        address(spUsdc));
        assertEq(uint8(uint256(slot0_) >> 160),            6);
        assertEq(uint256(slot0_) >> 168,                   0);

        bytes32 slot3_ = vm.load(address(vault), bytes32(uint256(3)));
        assertEq(uint64(uint256(slot3_)),                  vault.rho());
        assertEq(uint192(uint256(slot3_) >> 64),           vault.chi());

        assertEq(uint256(vm.load(address(vault), bytes32(uint256(4)))),  vault.vsr());
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(7)))),  0);  // paused
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(8)))),  vault.maxCapacity());
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(13)))), vault.totalSupply());
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(16)))), 2);  // depositQueue.length
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(17)))), 1);  // redeemQueue.length
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(18)))), vault.depositHead());
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(19)))), vault.redeemHead());
    }

}
