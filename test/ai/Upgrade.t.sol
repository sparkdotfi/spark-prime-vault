// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl } from "../../lib/oz/contracts/access/IAccessControl.sol";
import { ERC1967Proxy }   from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkPrimeVault } from "../../src/SparkPrimeVault.sol";

import { SparkPrimeVaultV2Mock } from "./mocks/SparkPrimeVaultV2Mock.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

contract InvalidSparkPrimeVault1 {

    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(0);
    }

}

contract InvalidSparkPrimeVault2 {}

/// @dev UUPS upgrade tests on `master` @ 0ebb452: authorization, invalid targets, exact state
///      preservation (every public getter, every raw linear storage slot 0..27, every role), the
///      re-initialization guards on the proxy and on the implementation, and the full storage
///      layout pinned slot by slot against `forge inspect SparkPrimeVault storage-layout`:
///
///        slot  0      _depositRequests.length              (Request[] : 3 slots per element)
///        slot  1      _depositCancellationRequests.length
///        slot  2      _redeemRequests.length
///        slot  3      savings                              (address)
///        slot  4      asset (offset 0, 20 bytes) | paused  (offset 20, 1 byte)
///        slot  5      name                                 (short string, inline)
///        slot  6      symbol                               (short string, inline)
///        slot  7      decimals (offset 0, 1 byte) | rho    (offset 1, 8 bytes)
///        slot  8      chi                                  (uint192, alone: 24 + 9 bytes > 32)
///        slot  9..11  vsr, minVSR, maxVSR
///        slot 12..16  maxCapacity, minDeposit, minRedeem, redeemFeeRate, maxRedeemFeeRate
///        slot 17      totalSupply
///        slot 18..20  pendingDepositSavingsShares, pendingCancelledDepositSavingsShares,
///                     pendingRedeemShares
///        slot 21..23  firstPendingDepositId, firstPendingDepositCancellationId,
///                     firstPendingRedeemId
///        slot 24..27  balanceOf, nonces, claimableAssets, allowance (mappings)
///
///      The OZ-upgradeable parents keep their state in ERC-7201 namespaces
///      (`openzeppelin.storage.Initializable`, `openzeppelin.storage.AccessControl`,
///      `openzeppelin.storage.AccessControlEnumerable`), which the layout test derives from the
///      namespace strings and checks against the live role data.
contract UpgradeTest is LocalTestBase {

    // keccak256("eip1967.proxy.implementation") - 1
    bytes32 constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.AccessControl")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant ACCESS_CONTROL_STORAGE =
        0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.AccessControlEnumerable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant ACCESS_CONTROL_ENUMERABLE_STORAGE =
        0xc1f6fe24621ce81ec5827caf0253cadb74709b061630e6b55e82371705932000;

    uint256 constant V1_SLOTS = 28;  // _depositRequests (0) .. allowance (27)

    // Slot numbers from `forge inspect SparkPrimeVault storage-layout` at 0ebb452.
    uint256 constant SLOT_DEPOSIT_REQUESTS              = 0;
    uint256 constant SLOT_DEPOSIT_CANCELLATION_REQUESTS = 1;
    uint256 constant SLOT_REDEEM_REQUESTS               = 2;
    uint256 constant SLOT_SAVINGS                       = 3;
    uint256 constant SLOT_ASSET_PAUSED                  = 4;
    uint256 constant SLOT_NAME                          = 5;
    uint256 constant SLOT_SYMBOL                        = 6;
    uint256 constant SLOT_DECIMALS_RHO                  = 7;
    uint256 constant SLOT_CHI                           = 8;
    uint256 constant SLOT_VSR                           = 9;
    uint256 constant SLOT_MIN_VSR                       = 10;
    uint256 constant SLOT_MAX_VSR                       = 11;
    uint256 constant SLOT_MAX_CAPACITY                  = 12;
    uint256 constant SLOT_MIN_DEPOSIT                   = 13;
    uint256 constant SLOT_MIN_REDEEM                    = 14;
    uint256 constant SLOT_REDEEM_FEE_RATE               = 15;
    uint256 constant SLOT_MAX_REDEEM_FEE_RATE           = 16;
    uint256 constant SLOT_TOTAL_SUPPLY                  = 17;
    uint256 constant SLOT_PENDING_DEPOSIT               = 18;
    uint256 constant SLOT_PENDING_CANCELLED             = 19;
    uint256 constant SLOT_PENDING_REDEEM                = 20;
    uint256 constant SLOT_FIRST_DEPOSIT_ID              = 21;
    uint256 constant SLOT_FIRST_CANCELLATION_ID         = 22;
    uint256 constant SLOT_FIRST_REDEEM_ID               = 23;
    uint256 constant SLOT_BALANCE_OF                    = 24;
    uint256 constant SLOT_NONCES                        = 25;
    uint256 constant SLOT_CLAIMABLE_ASSETS              = 26;
    uint256 constant SLOT_ALLOWANCE                     = 27;

    event Upgraded(address indexed implementation);

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");

    SparkPrimeVaultV2Mock newImplementation;

    uint256 carolRedId;
    uint256 depId;
    uint256 dep2Id;
    uint256 cancelId;
    uint256 redId;
    uint256 setVsrTimestamp;
    uint256 carolClaimable;

    // Build non-trivial state in every storage variable: shares, a queued deposit, a cancelled
    // deposit awaiting settlement, a queued redeem, a paid-out redeem to a blacklisted recipient
    // (so `claimableAssets` is non-zero and USDC sits in the vault), a fee, minimums, a rate,
    // an allowance, and one day of undripped accrual.
    function setUp() public override {
        super.setUp();

        newImplementation = new SparkPrimeVaultV2Mock();

        _setRedeemFeeRate(0.001e18);
        _setMinDeposit(1e6);
        _setMinRedeem(1e6);
        _setPrimeVsr(FOUR_PCT_VSR);
        setVsrTimestamp = block.timestamp;

        // carol: deposit id 0 (instant), redeem id 0, blacklisted at payout -> claimableAssets.
        _deposit(carol, 10e6);
        uint256 carolShares_ = vault.balanceOf(carol);
        carolRedId = _requestRedeem(carol, carolShares_);
        _blacklist(carol);
        _processRedeems(type(uint256).max, 1);
        carolClaimable = vault.claimableAssets(carol);

        _deposit(alice, 1_000_000e6);                 // deposit id 1 (instant)
        redId = _requestRedeem(alice, 100_000e6);     // redeem id 1

        _setCapacity(vault.totalSupply());
        depId  = _deposit(bob, 50_000e6);             // deposit id 2, queued (capacity full)
        dep2Id = _deposit(bob, 20_000e6);             // deposit id 3, queued
        vm.prank(bob);
        cancelId = vault.requestDepositCancellation(dep2Id, bob);  // cancellation id 0

        vm.prank(alice);
        vault.approve(bob, 123);

        skip(1 days);
    }

    /**********************************************************************************************/
    /*** Failure cases                                                                          ***/
    /**********************************************************************************************/

    function test_upgradeToAndCall_notAdmin() public {
        address[6] memory strangers_ = [
            address(this), pauser, operator, redeemFeeSetter, taker, operator
        ];
        for (uint256 i; i < strangers_.length; ++i) {
            vm.prank(strangers_[i]);
            vm.expectRevert(abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                strangers_[i],
                DEFAULT_ADMIN_ROLE
            ));
            vault.upgradeToAndCall(address(newImplementation), "");
        }
        assertTrue(vault.implementation() != address(newImplementation));
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

    // Pausing does not gate the upgrade (admin can always rotate code during an incident).
    function test_upgradeToAndCall_whilePaused() public {
        _pause();
        vm.prank(admin);
        vault.upgradeToAndCall(address(newImplementation), "");
        assertEq(vault.implementation(), address(newImplementation));
        assertTrue(vault.paused());
    }

    function test_initialize_alreadyInitialized() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vault.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vault.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);

        // The proxy is at initializer version 1 and not initializing.
        assertEq(vm.load(address(vault), INITIALIZABLE_STORAGE), bytes32(uint256(1)));
    }

    // The implementation contract has `_disableInitializers()` in its constructor.
    function test_initialize_implementationCannotBeInitialized() public {
        SparkPrimeVault impl_ = SparkPrimeVault(vault.implementation());

        // _initialized == type(uint64).max
        assertEq(
            vm.load(address(impl_), INITIALIZABLE_STORAGE),
            bytes32(uint256(type(uint64).max))
        );
        assertEq(
            vm.load(address(newImplementation), INITIALIZABLE_STORAGE),
            bytes32(uint256(type(uint64).max))
        );

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        impl_.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        newImplementation.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        newImplementation.initializeV2(1);

        // The implementation holds no state of its own: every linear slot is empty, no roles.
        for (uint256 i; i < V1_SLOTS; ++i) assertEq(vm.load(address(impl_), bytes32(i)), bytes32(0));
        assertEq(impl_.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 0);
        assertEq(impl_.implementation(), address(0));   // ERC1967 slot empty on the impl itself
    }

    // `upgradeToAndCall` is payable (UUPS) but refuses ETH when there is no call data.
    function test_upgradeToAndCall_nonPayableWithoutData() public {
        address oldImpl_ = vault.implementation();
        vm.deal(admin, 1 ether);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("ERC1967NonPayable()"));
        vault.upgradeToAndCall{ value: 1 }(address(newImplementation), "");

        assertEq(vault.implementation(), oldImpl_);
        assertEq(address(vault).balance, 0);
    }

    // With call data the ETH is forwarded to the delegatecall; `initializeV2` is not payable,
    // so it reverts and the upgrade is rolled back. No path leaves ETH inside the proxy.
    function test_upgradeToAndCall_valueWithNonPayableInitializer() public {
        address oldImpl_ = vault.implementation();
        vm.deal(admin, 1 ether);

        vm.prank(admin);
        vm.expectRevert();
        vault.upgradeToAndCall{ value: 1 }(
            address(newImplementation),
            abi.encodeCall(SparkPrimeVaultV2Mock.initializeV2, (777))
        );

        assertEq(vault.implementation(), oldImpl_);
        assertEq(address(vault).balance, 0);
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
        address asset;
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
        uint256 minRedeem;
        uint256 redeemFee;
        uint256 maxRedeemFee;
        uint256 totalSupply;
        uint256 pendingDepositSavingsShares;
        uint256 pendingCancelledDepositSavingsShares;
        uint256 pendingRedeemShares;
        uint256 depositHead;
        uint256 cancelledDepositHead;
        uint256 redeemHead;
        uint256 totalAssets;
        uint192 nowChi;
        uint256 balAlice;
        uint256 balBob;
        uint256 balCarol;
        uint256 balVault;
        uint256 nonceAlice;
        uint256 allowanceAliceBob;
        uint256 claimableCarol;
        uint256 usdcInVault;
        address depOwner;
        address depRecipient;
        uint256 depShares;
        address cancelOwner;
        address cancelRecipient;
        uint256 cancelShares;
        address redOwner;
        address redRecipient;
        uint256 redShares;
        uint256 spUsdcBal;
        bytes32 domainSeparator;
        uint256 availableCapacity;
        uint256 availableLiquidAssets;
        uint256 assetsOfAlice;
        bytes32 pendingDepositsHash;        // getPendingDepositRequests()
        bytes32 pendingCancellationsHash;   // getPendingDepositCancellationRequests()
        bytes32 pendingRedeemsHash;         // getPendingRedeemRequests()
        bytes32 allDepositsHash;            // getPendingDepositRequests(0, length)
        bytes32 allCancellationsHash;       // getPendingDepositCancellationRequests(0, length)
        bytes32 allRedeemsHash;             // getPendingRedeemRequests(0, length)
        uint256 pendingDepositsLen;
        uint256 pendingCancellationsLen;
        uint256 pendingRedeemsLen;
    }

    function _snapshot() internal view returns (Snapshot memory s_) {
        s_.savings                              = vault.savings();
        s_.asset                                = vault.asset();
        s_.decimals                             = vault.decimals();
        s_.name                                 = vault.name();
        s_.symbol                               = vault.symbol();
        s_.rho                                  = vault.rho();
        s_.chi                                  = vault.chi();
        s_.vsr                                  = vault.vsr();
        s_.minVSR                               = vault.minVSR();
        s_.maxVSR                               = vault.maxVSR();
        s_.paused                               = vault.paused();
        s_.maxCapacity                          = vault.maxCapacity();
        s_.minDeposit                           = vault.minDeposit();
        s_.minRedeem                            = vault.minRedeem();
        s_.redeemFee                            = vault.redeemFeeRate();
        s_.maxRedeemFee                         = vault.maxRedeemFeeRate();
        s_.totalSupply                          = vault.totalSupply();
        s_.pendingDepositSavingsShares          = vault.pendingDepositSavingsShares();
        s_.pendingCancelledDepositSavingsShares = vault.pendingCancelledDepositSavingsShares();
        s_.pendingRedeemShares                  = vault.pendingRedeemShares();
        s_.depositHead                          = vault.firstPendingDepositId();
        s_.cancelledDepositHead                 = vault.firstPendingDepositCancellationId();
        s_.redeemHead                           = vault.firstPendingRedeemId();
        s_.totalAssets                          = vault.totalAssets();
        s_.nowChi                               = vault.nowChi();
        s_.balAlice                             = vault.balanceOf(alice);
        s_.balBob                               = vault.balanceOf(bob);
        s_.balCarol                             = vault.balanceOf(carol);
        s_.balVault                             = vault.balanceOf(address(vault));
        s_.nonceAlice                           = vault.nonces(alice);
        s_.allowanceAliceBob                    = vault.allowance(alice, bob);
        s_.claimableCarol                       = vault.claimableAssets(carol);
        s_.usdcInVault                          = usdc.balanceOf(address(vault));
        (s_.depOwner,    s_.depRecipient,    s_.depShares)    = vault.getPendingDepositRequest(depId);
        (s_.cancelOwner, s_.cancelRecipient, s_.cancelShares) = vault.getPendingDepositCancellationRequest(cancelId);
        (s_.redOwner,    s_.redRecipient,    s_.redShares)    = vault.getPendingRedeemRequest(redId);
        s_.spUsdcBal                            = spUsdc.balanceOf(address(vault));
        s_.domainSeparator                      = vault.DOMAIN_SEPARATOR();
        s_.availableCapacity                    = vault.availableCapacity();
        s_.availableLiquidAssets                = vault.availableLiquidAssets();
        s_.assetsOfAlice                        = vault.assetsOf(alice);

        SparkPrimeVault.Request[] memory d_ = vault.getPendingDepositRequests();
        SparkPrimeVault.Request[] memory c_ = vault.getPendingDepositCancellationRequests();
        SparkPrimeVault.Request[] memory r_ = vault.getPendingRedeemRequests();
        s_.pendingDepositsHash      = keccak256(abi.encode(d_));
        s_.pendingCancellationsHash = keccak256(abi.encode(c_));
        s_.pendingRedeemsHash       = keccak256(abi.encode(r_));
        s_.pendingDepositsLen       = d_.length;
        s_.pendingCancellationsLen  = c_.length;
        s_.pendingRedeemsLen        = r_.length;
        s_.allDepositsHash = keccak256(abi.encode(
            vault.getPendingDepositRequests(0, _depositQueueLength())
        ));
        s_.allCancellationsHash = keccak256(abi.encode(
            vault.getPendingDepositCancellationRequests(0, _cancelledDepositQueueLength())
        ));
        s_.allRedeemsHash = keccak256(abi.encode(
            vault.getPendingRedeemRequests(0, _redeemQueueLength())
        ));
    }

    function _assertSnapshot(Snapshot memory s_) internal view {
        assertEq(s_.savings,                              address(spUsdc));
        assertEq(s_.asset,                                address(usdc));
        assertEq(s_.decimals,                             6);
        assertEq(s_.name,                                 "Spark Prime USDC");
        assertEq(s_.symbol,                               "spPRIME");
        assertEq(s_.rho,                                  setVsrTimestamp);
        assertEq(s_.vsr,                                  FOUR_PCT_VSR);
        assertEq(s_.minVSR,                               RAY);
        assertEq(s_.maxVSR,                               MAX_VSR);
        assertEq(s_.paused,                               false);
        assertEq(s_.minDeposit,                           1e6);
        assertEq(s_.minRedeem,                            1e6);
        assertEq(s_.redeemFee,                            0.001e18);
        assertEq(s_.maxRedeemFee,                         0.01e18);
        assertEq(s_.pendingRedeemShares,                  99_900e6);
        assertEq(s_.depositHead,                          2);
        assertEq(s_.cancelledDepositHead,                 0);
        assertEq(s_.redeemHead,                           1);
        assertEq(s_.balVault,                             99_900e6);
        assertEq(s_.balBob,                               0);
        assertEq(s_.balCarol,                             0);
        assertEq(s_.nonceAlice,                           0);
        assertEq(s_.allowanceAliceBob,                    123);
        assertEq(s_.claimableCarol,                       carolClaimable);
        assertEq(s_.claimableCarol,                       9_989_997);   // 10e6 in, 0.1% fee, 3 wei of floors
        assertEq(s_.usdcInVault,                          carolClaimable);
        assertEq(s_.depOwner,                             bob);
        assertEq(s_.depRecipient,                         bob);
        assertEq(s_.cancelOwner,                          bob);
        assertEq(s_.cancelRecipient,                      bob);
        assertEq(s_.redOwner,                             alice);
        assertEq(s_.redRecipient,                         alice);
        assertEq(s_.redShares,                            99_900e6);
        assertGt(s_.chi,                                  RAY);
        assertGt(s_.nowChi,                               s_.chi);  // 1 day of undripped accrual
        assertGt(s_.depShares,                            0);
        assertGt(s_.cancelShares,                         0);
        assertEq(s_.pendingDepositSavingsShares,          s_.depShares);
        assertEq(s_.pendingCancelledDepositSavingsShares, s_.cancelShares);
        assertEq(s_.totalSupply,                          s_.balAlice + s_.balVault);
        assertEq(s_.maxCapacity,                          s_.totalSupply);
        assertEq(s_.availableCapacity,                    0);
        assertEq(s_.availableLiquidAssets,                spUsdc.maxWithdraw(address(vault)));
        assertEq(s_.assetsOfAlice,                        s_.balAlice * s_.nowChi / RAY);
        assertEq(s_.totalAssets,                          s_.totalSupply * s_.nowChi / RAY);
        // Deposit queue: [carol (dead), alice (dead), bob queued, bob cancelled (dead)], head 2.
        assertEq(s_.pendingDepositsLen,                   2);
        assertEq(s_.pendingCancellationsLen,              1);
        assertEq(s_.pendingRedeemsLen,                    1);
        assertEq(s_.pendingDepositsHash, keccak256(abi.encode(
            vault.getPendingDepositRequests(2, 4)
        )));
        assertEq(s_.pendingCancellationsHash,             s_.allCancellationsHash);
        assertEq(s_.pendingRedeemsHash, keccak256(abi.encode(
            vault.getPendingRedeemRequests(1, 2)
        )));
    }

    function _assertSnapshotsEqual(Snapshot memory a_, Snapshot memory b_) internal pure {
        assertEq(keccak256(abi.encode(a_)), keccak256(abi.encode(b_)));
    }

    function _rawSlots(address target_) internal view returns (bytes32[] memory slots_) {
        slots_ = new bytes32[](V1_SLOTS);
        for (uint256 i; i < V1_SLOTS; ++i) slots_[i] = vm.load(target_, bytes32(i));
    }

    function _roleMembers() internal view returns (address[][6] memory members_) {
        members_[0] = vault.getRoleMembers(DEFAULT_ADMIN_ROLE);
        members_[1] = vault.getRoleMembers(PAUSER_ROLE);
        members_[2] = vault.getRoleMembers(OPERATOR_ROLE);
        members_[3] = vault.getRoleMembers(REDEEM_FEE_SETTER_ROLE);
        members_[4] = vault.getRoleMembers(TAKER_ROLE);
        members_[5] = vault.getRoleMembers(OPERATOR_ROLE);
    }

    function test_upgradeToAndCall() public {
        Snapshot memory before_ = _snapshot();
        _assertSnapshot(before_);

        bytes32[] memory slotsBefore_ = _rawSlots(address(vault));

        address[][6] memory rolesBefore_ = _roleMembers();
        address[6]   memory expected_    = [admin, pauser, operator, redeemFeeSetter, taker, operator];
        for (uint256 i; i < 6; ++i) {
            assertEq(rolesBefore_[i].length, 1);
            assertEq(rolesBefore_[i][0],     expected_[i]);
        }

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
        address[][6] memory rolesAfter_ = _roleMembers();
        for (uint256 i; i < 6; ++i) assertEq(rolesAfter_[i], rolesBefore_[i]);

        // New code is live, new storage starts empty.
        SparkPrimeVaultV2Mock v2_ = SparkPrimeVaultV2Mock(address(vault));
        assertEq(v2_.version2(), "2");
        assertEq(v2_.newVar(),   0);

        // V1 `initialize` still cannot be called.
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vault.initialize(address(spUsdc), "Spark Prime USDC", "spPRIME", admin);

        // The vault keeps working: all three open queues can be processed by the operator,
        // and carol's claim pays once she is un-blacklisted.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        _processRedeems(type(uint256).max, 10);
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.pendingRedeemShares(),                  0);
        assertEq(vault.firstPendingDepositId(),                4);
        assertEq(vault.firstPendingDepositCancellationId(),    1);
        assertEq(vault.firstPendingRedeemId(),                 2);
        assertGt(vault.balanceOf(bob),                         0);
        assertGt(usdc.balanceOf(alice),                        0);
        assertApproxEqAbs(usdc.balanceOf(bob), 20_000e6, 2);  // settled refund

        _unblacklist(carol);
        vault.claim(carol);
        assertEq(usdc.balanceOf(carol),         carolClaimable);
        assertEq(vault.claimableAssets(carol),  0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // The new implementation reads the three internal arrays exactly as the old one wrote them:
    // filled entries are zeroed, the open ones carry owner / recipient / shares, lengths match.
    function test_upgradeToAndCall_v2ReadsEveryQueueSlot() public {
        (address depOwner_, address depRecipient_, uint256 depShares_) = vault.getPendingDepositRequest(depId);
        (address cOwner_,   address cRecipient_,   uint256 cShares_)   = vault.getPendingDepositCancellationRequest(cancelId);
        (address rOwner_,   address rRecipient_,   uint256 rShares_)   = vault.getPendingRedeemRequest(redId);

        vm.prank(admin);
        vault.upgradeToAndCall(address(newImplementation), "");
        SparkPrimeVaultV2Mock v2_ = SparkPrimeVaultV2Mock(address(vault));

        assertEq(v2_.depositRequestsLength(),             4);
        assertEq(v2_.depositCancellationRequestsLength(), 1);
        assertEq(v2_.redeemRequestsLength(),              2);

        // Deposit queue: ids 0 (carol) and 1 (alice) filled -> zero; 2 bob open; 3 cancelled -> zero.
        SparkPrimeVault.Request memory r_;
        r_ = v2_.rawDepositRequest(0);
        assertEq(r_.owner, address(0)); assertEq(r_.recipient, address(0)); assertEq(r_.shares, 0);
        r_ = v2_.rawDepositRequest(1);
        assertEq(r_.owner, address(0)); assertEq(r_.recipient, address(0)); assertEq(r_.shares, 0);
        r_ = v2_.rawDepositRequest(2);
        assertEq(r_.owner, depOwner_); assertEq(r_.recipient, depRecipient_); assertEq(r_.shares, depShares_);
        assertEq(r_.owner, bob);
        r_ = v2_.rawDepositRequest(3);
        assertEq(r_.owner, address(0)); assertEq(r_.recipient, address(0)); assertEq(r_.shares, 0);

        r_ = v2_.rawDepositCancellationRequest(0);
        assertEq(r_.owner, cOwner_); assertEq(r_.recipient, cRecipient_); assertEq(r_.shares, cShares_);

        // Redeem queue: id 0 (carol) paid -> zero; id 1 alice open.
        r_ = v2_.rawRedeemRequest(0);
        assertEq(r_.owner, address(0)); assertEq(r_.recipient, address(0)); assertEq(r_.shares, 0);
        r_ = v2_.rawRedeemRequest(1);
        assertEq(r_.owner, rOwner_); assertEq(r_.recipient, rRecipient_); assertEq(r_.shares, rShares_);
        assertEq(r_.shares, 99_900e6);

        vm.expectRevert();  // out of bounds, exactly like the old code
        v2_.rawRedeemRequest(2);
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

    // The roles the contract knows about are exactly DEFAULT_ADMIN plus five named roles; the
    // round-4 names (`RISK_MANAGER_ROLE`, `SETTER_ROLE`, `UNPAUSER_ROLE`) are not in the ABI.
    // Every role's admin is DEFAULT_ADMIN_ROLE, before and after upgrade.
    function test_roleAdmins_unchangedByUpgrade() public {
        bytes32[6] memory roles_ = [
            DEFAULT_ADMIN_ROLE, PAUSER_ROLE, OPERATOR_ROLE, REDEEM_FEE_SETTER_ROLE,
            TAKER_ROLE, OPERATOR_ROLE
        ];
        assertEq(vault.DEFAULT_ADMIN_ROLE(),     bytes32(0));
        assertEq(vault.PAUSER_ROLE(),          PAUSER_ROLE);
        assertEq(vault.OPERATOR_ROLE(),        OPERATOR_ROLE);
        assertEq(vault.REDEEM_FEE_SETTER_ROLE(), REDEEM_FEE_SETTER_ROLE);
        assertEq(vault.TAKER_ROLE(),             TAKER_ROLE);
        assertEq(vault.OPERATOR_ROLE(),        OPERATOR_ROLE);

        string[3] memory gone_ = ["RISK_MANAGER_ROLE()", "SETTER_ROLE()", "UNPAUSER_ROLE()"];
        for (uint256 i; i < gone_.length; ++i) {
            (bool ok_, ) = address(vault).staticcall(abi.encodeWithSignature(gone_[i]));
            assertFalse(ok_);
        }

        for (uint256 i; i < roles_.length; ++i) assertEq(vault.getRoleAdmin(roles_[i]), bytes32(0));

        vm.prank(admin);
        vault.upgradeToAndCall(address(newImplementation), "");

        for (uint256 i; i < roles_.length; ++i) assertEq(vault.getRoleAdmin(roles_[i]), bytes32(0));
    }

    /**********************************************************************************************/
    /*** Storage layout: read every slot via vm.load against the getters                        ***/
    /**********************************************************************************************/

    function _shortString(string memory s_) internal pure returns (bytes32 word_) {
        uint256 len_ = bytes(s_).length;
        require(len_ < 32, "not a short string");
        assembly { word_ := mload(add(s_, 32)) }
        word_ &= bytes32(type(uint256).max << (256 - 8 * len_));
        word_ |= bytes32(len_ * 2);
    }

    function _load(uint256 slot_) internal view returns (uint256) {
        return uint256(vm.load(address(vault), bytes32(slot_)));
    }

    function _mapSlot(address key_, uint256 slot_) internal pure returns (bytes32) {
        return keccak256(abi.encode(key_, slot_));
    }

    function _arrayElem(uint256 slot_, uint256 index_, uint256 member_) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(slot_))) + 3 * index_ + member_);
    }

    // Every linear slot 0..27 read with `vm.load` equals what the getters report, including the
    // packing of `asset | paused` (slot 4) and `decimals | rho` (slot 7), the inline short
    // strings, `chi` alone in slot 8, the array lengths in slots 0..2, and the array / mapping
    // element positions. Slot 28 is the first free slot.
    function test_storageLayout_readEverySlot() public view {
        // Arrays: lengths.
        assertEq(_load(SLOT_DEPOSIT_REQUESTS),              4);
        assertEq(_load(SLOT_DEPOSIT_CANCELLATION_REQUESTS), 1);
        assertEq(_load(SLOT_REDEEM_REQUESTS),               2);

        // Array elements: 3 slots each (owner, recipient, shares) from keccak256(slot).
        (address dOwner_, address dRecipient_, uint256 dShares_) = vault.getPendingDepositRequest(depId);
        assertEq(address(uint160(uint256(vm.load(address(vault), _arrayElem(SLOT_DEPOSIT_REQUESTS, depId, 0))))), dOwner_);
        assertEq(address(uint160(uint256(vm.load(address(vault), _arrayElem(SLOT_DEPOSIT_REQUESTS, depId, 1))))), dRecipient_);
        assertEq(uint256(vm.load(address(vault), _arrayElem(SLOT_DEPOSIT_REQUESTS, depId, 2))), dShares_);
        assertEq(uint256(vm.load(address(vault), _arrayElem(SLOT_DEPOSIT_REQUESTS, 0, 2))),     0);   // filled
        assertEq(uint256(vm.load(address(vault), _arrayElem(SLOT_DEPOSIT_REQUESTS, dep2Id, 2))), 0);  // cancelled

        (address cOwner_, address cRecipient_, uint256 cShares_) = vault.getPendingDepositCancellationRequest(cancelId);
        assertEq(address(uint160(uint256(vm.load(address(vault), _arrayElem(SLOT_DEPOSIT_CANCELLATION_REQUESTS, cancelId, 0))))), cOwner_);
        assertEq(address(uint160(uint256(vm.load(address(vault), _arrayElem(SLOT_DEPOSIT_CANCELLATION_REQUESTS, cancelId, 1))))), cRecipient_);
        assertEq(uint256(vm.load(address(vault), _arrayElem(SLOT_DEPOSIT_CANCELLATION_REQUESTS, cancelId, 2))), cShares_);

        (address rOwner_, address rRecipient_, uint256 rShares_) = vault.getPendingRedeemRequest(redId);
        assertEq(address(uint160(uint256(vm.load(address(vault), _arrayElem(SLOT_REDEEM_REQUESTS, redId, 0))))), rOwner_);
        assertEq(address(uint160(uint256(vm.load(address(vault), _arrayElem(SLOT_REDEEM_REQUESTS, redId, 1))))), rRecipient_);
        assertEq(uint256(vm.load(address(vault), _arrayElem(SLOT_REDEEM_REQUESTS, redId, 2))), rShares_);
        assertEq(rShares_, 99_900e6);
        assertEq(uint256(vm.load(address(vault), _arrayElem(SLOT_REDEEM_REQUESTS, carolRedId, 2))), 0);  // paid

        // savings alone in slot 3.
        assertEq(_load(SLOT_SAVINGS), uint256(uint160(address(spUsdc))));

        // asset (20 bytes) | paused (1 byte at offset 20) in slot 4.
        uint256 slot4_ = _load(SLOT_ASSET_PAUSED);
        assertEq(address(uint160(slot4_)),     address(usdc));
        assertEq(uint8(slot4_ >> 160),         0);         // paused == false
        assertEq(slot4_ >> 168,                0);

        // Short strings inline: data left-aligned, length*2 in the low byte.
        assertEq(vm.load(address(vault), bytes32(SLOT_NAME)),   _shortString("Spark Prime USDC"));
        assertEq(vm.load(address(vault), bytes32(SLOT_SYMBOL)), _shortString("spPRIME"));
        assertEq(uint8(_load(SLOT_NAME)),   32);   // 16 bytes * 2
        assertEq(uint8(_load(SLOT_SYMBOL)), 14);   //  7 bytes * 2

        // decimals (1 byte) | rho (8 bytes at offset 1) in slot 7; chi alone in slot 8.
        uint256 slot7_ = _load(SLOT_DECIMALS_RHO);
        assertEq(uint8(slot7_),              6);
        assertEq(uint64(slot7_ >> 8),        vault.rho());
        assertEq(uint64(slot7_ >> 8),        setVsrTimestamp);
        assertEq(slot7_ >> 72,               0);
        assertEq(_load(SLOT_CHI),            vault.chi());
        assertTrue(_load(SLOT_CHI) >> 192 == 0);

        assertEq(_load(SLOT_VSR),                 FOUR_PCT_VSR);
        assertEq(_load(SLOT_MIN_VSR),             RAY);
        assertEq(_load(SLOT_MAX_VSR),             MAX_VSR);
        assertEq(_load(SLOT_MAX_CAPACITY),        vault.maxCapacity());
        assertEq(_load(SLOT_MIN_DEPOSIT),         1e6);
        assertEq(_load(SLOT_MIN_REDEEM),          1e6);
        assertEq(_load(SLOT_REDEEM_FEE_RATE),     0.001e18);
        assertEq(_load(SLOT_MAX_REDEEM_FEE_RATE), 0.01e18);
        assertEq(_load(SLOT_TOTAL_SUPPLY),        vault.totalSupply());
        assertEq(_load(SLOT_PENDING_DEPOSIT),     vault.pendingDepositSavingsShares());
        assertEq(_load(SLOT_PENDING_DEPOSIT),     dShares_);
        assertEq(_load(SLOT_PENDING_CANCELLED),   cShares_);
        assertEq(_load(SLOT_PENDING_REDEEM),      99_900e6);
        assertEq(_load(SLOT_FIRST_DEPOSIT_ID),      2);
        assertEq(_load(SLOT_FIRST_CANCELLATION_ID), 0);
        assertEq(_load(SLOT_FIRST_REDEEM_ID),       1);

        // Mappings: balanceOf (24), nonces (25), claimableAssets (26), allowance (27).
        assertEq(uint256(vm.load(address(vault), _mapSlot(alice,          SLOT_BALANCE_OF))), vault.balanceOf(alice));
        assertEq(uint256(vm.load(address(vault), _mapSlot(address(vault), SLOT_BALANCE_OF))), 99_900e6);
        assertEq(uint256(vm.load(address(vault), _mapSlot(alice,          SLOT_NONCES))),     0);
        assertEq(uint256(vm.load(address(vault), _mapSlot(carol,          SLOT_CLAIMABLE_ASSETS))), carolClaimable);
        assertEq(
            uint256(vm.load(address(vault), keccak256(abi.encode(bob, _mapSlot(alice, SLOT_ALLOWANCE))))),
            123
        );

        // First free slot.
        assertEq(_load(V1_SLOTS), 0);
    }

    // The other direction: write known values with `vm.store` into each slot and read them back
    // through the public getters. Any getter reading the wrong slot or the wrong offset fails.
    function test_storageLayout_storeEverySlot() public {
        address savings_ = address(0x5a71);
        address asset_   = address(0xa55e);
        address who_     = address(0xbeef);
        address spender_ = address(0xcafe);

        vm.store(address(vault), bytes32(SLOT_DEPOSIT_REQUESTS),              bytes32(uint256(11)));
        vm.store(address(vault), bytes32(SLOT_DEPOSIT_CANCELLATION_REQUESTS), bytes32(uint256(12)));
        vm.store(address(vault), bytes32(SLOT_REDEEM_REQUESTS),               bytes32(uint256(13)));
        vm.store(address(vault), bytes32(SLOT_SAVINGS),                       bytes32(uint256(uint160(savings_))));
        vm.store(address(vault), bytes32(SLOT_ASSET_PAUSED),                  bytes32((uint256(1) << 160) | uint256(uint160(asset_))));
        vm.store(address(vault), bytes32(SLOT_NAME),                          _shortString("N"));
        vm.store(address(vault), bytes32(SLOT_SYMBOL),                        _shortString("SYM"));
        vm.store(address(vault), bytes32(SLOT_DECIMALS_RHO),                  bytes32((uint256(1234) << 8) | 18));
        vm.store(address(vault), bytes32(SLOT_CHI),                           bytes32(uint256(2e27)));
        vm.store(address(vault), bytes32(SLOT_VSR),                           bytes32(uint256(31)));
        vm.store(address(vault), bytes32(SLOT_MIN_VSR),                       bytes32(uint256(32)));
        vm.store(address(vault), bytes32(SLOT_MAX_VSR),                       bytes32(uint256(33)));
        vm.store(address(vault), bytes32(SLOT_MAX_CAPACITY),                  bytes32(uint256(34)));
        vm.store(address(vault), bytes32(SLOT_MIN_DEPOSIT),                   bytes32(uint256(35)));
        vm.store(address(vault), bytes32(SLOT_MIN_REDEEM),                    bytes32(uint256(36)));
        vm.store(address(vault), bytes32(SLOT_REDEEM_FEE_RATE),               bytes32(uint256(37)));
        vm.store(address(vault), bytes32(SLOT_MAX_REDEEM_FEE_RATE),           bytes32(uint256(38)));
        vm.store(address(vault), bytes32(SLOT_TOTAL_SUPPLY),                  bytes32(uint256(39)));
        vm.store(address(vault), bytes32(SLOT_PENDING_DEPOSIT),               bytes32(uint256(40)));
        vm.store(address(vault), bytes32(SLOT_PENDING_CANCELLED),             bytes32(uint256(41)));
        vm.store(address(vault), bytes32(SLOT_PENDING_REDEEM),                bytes32(uint256(42)));
        vm.store(address(vault), bytes32(SLOT_FIRST_DEPOSIT_ID),              bytes32(uint256(5)));
        vm.store(address(vault), bytes32(SLOT_FIRST_CANCELLATION_ID),         bytes32(uint256(6)));
        vm.store(address(vault), bytes32(SLOT_FIRST_REDEEM_ID),               bytes32(uint256(7)));
        vm.store(address(vault), _mapSlot(who_, SLOT_BALANCE_OF),             bytes32(uint256(51)));
        vm.store(address(vault), _mapSlot(who_, SLOT_NONCES),                 bytes32(uint256(52)));
        vm.store(address(vault), _mapSlot(who_, SLOT_CLAIMABLE_ASSETS),       bytes32(uint256(53)));
        vm.store(address(vault), keccak256(abi.encode(spender_, _mapSlot(who_, SLOT_ALLOWANCE))), bytes32(uint256(54)));
        vm.store(address(vault), _arrayElem(SLOT_DEPOSIT_REQUESTS, 10, 0),             bytes32(uint256(uint160(who_))));
        vm.store(address(vault), _arrayElem(SLOT_DEPOSIT_REQUESTS, 10, 1),             bytes32(uint256(uint160(spender_))));
        vm.store(address(vault), _arrayElem(SLOT_DEPOSIT_REQUESTS, 10, 2),             bytes32(uint256(61)));
        vm.store(address(vault), _arrayElem(SLOT_DEPOSIT_CANCELLATION_REQUESTS, 11, 2), bytes32(uint256(62)));
        vm.store(address(vault), _arrayElem(SLOT_REDEEM_REQUESTS, 12, 2),              bytes32(uint256(63)));

        assertEq(vault.savings(),          savings_);
        assertEq(vault.asset(),            asset_);
        assertTrue(vault.paused());
        assertEq(vault.name(),             "N");
        assertEq(vault.symbol(),           "SYM");
        assertEq(vault.decimals(),         18);
        assertEq(vault.rho(),              1234);
        assertEq(vault.chi(),              2e27);
        assertEq(vault.vsr(),              31);
        assertEq(vault.minVSR(),           32);
        assertEq(vault.maxVSR(),           33);
        assertEq(vault.maxCapacity(),      34);
        assertEq(vault.minDeposit(),       35);
        assertEq(vault.minRedeem(),        36);
        assertEq(vault.redeemFeeRate(),    37);
        assertEq(vault.maxRedeemFeeRate(), 38);
        assertEq(vault.totalSupply(),      39);
        assertEq(vault.pendingDepositSavingsShares(),          40);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 41);
        assertEq(vault.pendingRedeemShares(),                  42);
        assertEq(vault.firstPendingDepositId(),                5);
        assertEq(vault.firstPendingDepositCancellationId(),    6);
        assertEq(vault.firstPendingRedeemId(),                 7);
        assertEq(vault.balanceOf(who_),            51);
        assertEq(vault.nonces(who_),               52);
        assertEq(vault.claimableAssets(who_),      53);
        assertEq(vault.allowance(who_, spender_),  54);

        // Array lengths and elements are what the request getters walk.
        assertEq(vault.getPendingDepositRequests().length,             11 - 5);
        assertEq(vault.getPendingDepositCancellationRequests().length, 12 - 6);
        assertEq(vault.getPendingRedeemRequests().length,              13 - 7);
        (address o_, address r_, uint256 s_) = vault.getPendingDepositRequest(10);
        assertEq(o_, who_);
        assertEq(r_, spender_);
        assertEq(s_, 61);
        (, , s_) = vault.getPendingDepositCancellationRequest(11);
        assertEq(s_, 62);
        (, , s_) = vault.getPendingRedeemRequest(12);
        assertEq(s_, 63);

        // Derived views follow the stored chi (rho == 1234 is in the past, vsr == 31 < RAY so
        // `_rpow(31, dt)` underflows to 0 and nowChi() == 0; freeze time at rho to read chi).
        vm.warp(1234);
        assertEq(vault.nowChi(),            2e27);
        assertEq(vault.convertToAssets(10), 20);
        assertEq(vault.totalAssets(),       78);
        assertEq(vault.assetsOf(who_),      102);
        assertEq(vault.availableCapacity(), 0);   // 34 < 39
    }

    // ERC-7201 namespaces of the OZ-upgradeable parents: derived from the namespace strings,
    // equal to the library constants, far from the linear slots, and holding the live role
    // data (`hasRole`, `adminRole`, enumerable members) exactly where the formula says.
    function test_storageLayout_erc7201Namespaces() public {
        assertEq(_erc7201("openzeppelin.storage.Initializable"),            INITIALIZABLE_STORAGE);
        assertEq(_erc7201("openzeppelin.storage.AccessControl"),            ACCESS_CONTROL_STORAGE);
        assertEq(_erc7201("openzeppelin.storage.AccessControlEnumerable"),  ACCESS_CONTROL_ENUMERABLE_STORAGE);

        // Initializable: _initialized (uint64, offset 0) == 1, _initializing (bool, offset 8) == 0.
        uint256 init_ = uint256(vm.load(address(vault), INITIALIZABLE_STORAGE));
        assertEq(uint64(init_),      1);
        assertEq(uint8(init_ >> 64), 0);

        // AccessControl: _roles[role] = RoleData { mapping hasRole; bytes32 adminRole }.
        bytes32[6] memory roles_ = [
            DEFAULT_ADMIN_ROLE, PAUSER_ROLE, OPERATOR_ROLE, REDEEM_FEE_SETTER_ROLE,
            TAKER_ROLE, OPERATOR_ROLE
        ];
        address[6] memory members_ = [admin, pauser, operator, redeemFeeSetter, taker, operator];

        for (uint256 i; i < 6; ++i) {
            bytes32 roleData_ = keccak256(abi.encode(roles_[i], ACCESS_CONTROL_STORAGE));
            bytes32 hasRole_  = keccak256(abi.encode(members_[i], roleData_));
            assertEq(uint256(vm.load(address(vault), hasRole_)),                       1);
            assertEq(vm.load(address(vault), bytes32(uint256(roleData_) + 1)),         bytes32(0));  // adminRole
            assertEq(uint256(vm.load(address(vault), keccak256(abi.encode(alice, roleData_)))), 0);

            // AccessControlEnumerable: _roleMembers[role] = EnumerableSet.AddressSet
            //   { bytes32[] _values; mapping(bytes32 => uint256) _positions }.
            bytes32 set_ = keccak256(abi.encode(roles_[i], ACCESS_CONTROL_ENUMERABLE_STORAGE));
            assertEq(uint256(vm.load(address(vault), set_)), 1);   // _values.length
            assertEq(
                vm.load(address(vault), keccak256(abi.encode(set_))),
                bytes32(uint256(uint160(members_[i])))                 // _values[0]
            );
            assertEq(
                uint256(vm.load(address(vault), keccak256(abi.encode(
                    bytes32(uint256(uint160(members_[i]))), uint256(set_) + 1
                )))),
                1                                                      // _positions[member] == index + 1
            );

            // Each namespace root is far above the linear region.
            assertGt(uint256(roleData_), V1_SLOTS);
            assertGt(uint256(set_),      V1_SLOTS);
        }
        assertGt(uint256(INITIALIZABLE_STORAGE),              V1_SLOTS);
        assertGt(uint256(ACCESS_CONTROL_STORAGE),             V1_SLOTS);
        assertGt(uint256(ACCESS_CONTROL_ENUMERABLE_STORAGE),  V1_SLOTS);
        assertTrue(ACCESS_CONTROL_STORAGE != ACCESS_CONTROL_ENUMERABLE_STORAGE);
        assertTrue(ACCESS_CONTROL_STORAGE != INITIALIZABLE_STORAGE);

        // Clobbering every linear slot (and the appended V2 slot) leaves the roles intact.
        for (uint256 i; i <= V1_SLOTS; ++i) {
            vm.store(address(vault), bytes32(i), bytes32(type(uint256).max));
        }
        for (uint256 i; i < 6; ++i) {
            assertTrue(vault.hasRole(roles_[i], members_[i]));
            assertEq(vault.getRoleMemberCount(roles_[i]), 1);
            assertEq(vault.getRoleMember(roles_[i], 0), members_[i]);
            assertEq(vault.getRoleAdmin(roles_[i]), bytes32(0));
        }
        assertEq(uint64(uint256(vm.load(address(vault), INITIALIZABLE_STORAGE))), 1);
    }

    function _erc7201(string memory id_) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id_))) - 1)) & ~bytes32(uint256(0xff));
    }

    // Informational: the round-4 layout (bf93b0d) had `savings` at slot 0, `asset | decimals`
    // packed in slot 1, `rho | chi` packed in slot 4, `paused` at 8, the three queues at 18..20
    // and the mappings at 24..26. On 0ebb452 the arrays moved to the front, `paused` packs with
    // `asset`, `decimals` packs with `rho`, `chi` is alone, `claimableAssets` is inserted before
    // `allowance`. A round-4 implementation reading this proxy would misread every slot. Nothing
    // is deployed yet, so no migration is needed; this pins that the two layouts differ.
    function test_storageLayout_notCompatibleWithRoundFour() public view {
        // Round 4: slot 0 was `savings`. Now it is the deposit array length (4 here).
        assertEq(_load(0), 4);
        assertTrue(_load(0) != uint256(uint160(address(spUsdc))));

        // Round 4: slot 4 was `rho | chi`; now slot 4 is `asset | paused`.
        assertEq(address(uint160(_load(4))), address(usdc));

        // Round 4: slot 8 was `paused` (0); now it is `chi` (> RAY).
        assertGt(_load(8), RAY);

        // Round 4: slot 26 was the `allowance` base; now allowance is at 27 and 26 is
        // `claimableAssets`. The allowance written in setUp is only found under 27.
        assertEq(uint256(vm.load(address(vault), keccak256(abi.encode(bob, _mapSlot(alice, 27))))), 123);
        assertEq(uint256(vm.load(address(vault), keccak256(abi.encode(bob, _mapSlot(alice, 26))))), 0);
    }

}
