// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../../lib/forge-std/src/StdError.sol";

import { ERC1967Proxy }   from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "../../lib/oz/contracts/access/IAccessControl.sol";

import { SparkPrimeVault } from "../../src/SparkPrimeVault.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";
import { ISparkPrimeVault } from "src/ISparkPrimeVault.sol";

/// @dev Authorization matrix, pause scope and mid-flight role revocation for `SparkPrimeVault`
///      on `master` @ 0ebb452. Every role-gated function is exercised by all six role holders
///      plus a stranger: the authorized actor succeeds, every other actor reverts with the exact
///      OZ custom error `AccessControlUnauthorizedAccount(account, role)`.
///
///      Round 5 (0ebb452): roles are DEFAULT_ADMIN, GUARDIAN, REBALANCER, REDEEM_FEE_SETTER,
///      TAKER, VSR_SETTER (`RISK_MANAGER_ROLE`, `SETTER_ROLE`, `UNPAUSER_ROLE` are gone).
///      `realizeGain` / `realizeLoss` are replaced by `adjustTotalAssets(int256)` (DEFAULT_ADMIN,
///      requires `paused`). `requestDepositCancellation` is owner-only (pauser path removed),
///      `claim(recipient)` is new and permissionless, the 2-arg `requestDeposit` is gone.
contract AuthorizationTest is LocalTestBase {

    event Paused();
    event Unpaused();
    event Claim(address indexed recipient, uint256 assets);
    event Take(uint256 shares);
    event TotalAssetsAdjusted(uint192 chi, int256 deltaTotalAssets);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address stranger = makeAddr("stranger");

    // All actors that hold exactly one role, plus a stranger with none.
    function _actors() internal view returns (address[7] memory actors_) {
        actors_ = [admin, pauser, operator, redeemFeeSetter, taker, operator, stranger];
    }

    function _roles() internal view returns (bytes32[6] memory roles_) {
        roles_ = [
            DEFAULT_ADMIN_ROLE, PAUSER_ROLE, OPERATOR_ROLE, REDEEM_FEE_SETTER_ROLE,
            TAKER_ROLE, OPERATOR_ROLE
        ];
    }

    function _expectUnauthorized(address caller_, bytes32 role_) internal {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            caller_,
            role_
        ));
    }

    /// @dev Capacity == totalSupply so the request cannot fill and stays queued.
    function _queueDeposit(address who_, uint256 amt_) internal returns (uint256 id_) {
        _setCapacity(vault.totalSupply());
        id_ = _deposit(who_, amt_);
        (, , uint256 shares_) = _depositRequest(id_);
        assertGt(shares_, 0);
    }

    /// @dev alice redeems `shares_` to bob, bob is blacklisted at settlement, so the payout lands
    ///      in `claimableAssets[bob]`. Returns the exact USDC amount credited.
    function _creditClaimable(uint256 shares_) internal returns (uint256 assets_) {
        _unblacklist(bob);
        uint256 before_ = vault.claimableAssets(bob);
        assets_ = vault.convertToAssets(shares_);
        vm.prank(alice);
        vault.requestRedeem(shares_, bob);
        _blacklist(bob);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.claimableAssets(bob), before_ + assets_);
    }

    /**********************************************************************************************/
    /*** DEFAULT_ADMIN_ROLE functions                                                           ***/
    /**********************************************************************************************/

    function test_setCapacity_notAuthorized() public {
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.setCapacity(1_000_000e6);
        }
        assertEq(vault.maxCapacity(), type(uint128).max);
    }

    function test_setCapacity_authorized() public {
        vm.prank(admin);
        vault.setCapacity(1_000_000e6);
        assertEq(vault.maxCapacity(), 1_000_000e6);
    }

    function test_setMaxRedeemFeeRate_notAuthorized() public {
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.setMaxRedeemFeeRate(0.005e18);
        }
        assertEq(vault.maxRedeemFeeRate(), 0.01e18);
    }

    function test_setMaxRedeemFeeRate_authorized() public {
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.005e18);
        assertEq(vault.maxRedeemFeeRate(), 0.005e18);
    }

    function test_setMinDeposit_notAuthorized() public {
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.setMinDeposit(1e6);
        }
        assertEq(vault.minDeposit(), 0);
    }

    function test_setMinDeposit_authorized() public {
        vm.prank(admin);
        vault.setMinDeposit(1e6);
        assertEq(vault.minDeposit(), 1e6);
    }

    function test_setMinRedeem_notAuthorized() public {
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.setMinRedeem(1e6);
        }
        assertEq(vault.minRedeem(), 0);
    }

    function test_setMinRedeem_authorized() public {
        vm.prank(admin);
        vault.setMinRedeem(2e6);
        assertEq(vault.minRedeem(), 2e6);
    }

    function test_setVSRBounds_notAuthorized() public {
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.setVSRBounds(RAY, FOUR_PCT_VSR);
        }
        assertEq(vault.minVSR(), RAY);
        assertEq(vault.maxVSR(), MAX_VSR);
    }

    function test_setVSRBounds_authorized() public {
        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);
        assertEq(vault.minVSR(), ONE_PCT_VSR);
        assertEq(vault.maxVSR(), FOUR_PCT_VSR);
    }

    // Round 5: `adjustTotalAssets` is DEFAULT_ADMIN only. The `onlyRole` modifier runs before
    // the `paused` check, so a non-admin gets the role error whether paused or not, and the
    // index never moves.
    function test_adjustTotalAssets_notAuthorized() public {
        _deposit(alice, 1_000e6);
        uint192 chi_ = vault.chi();
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.adjustTotalAssets(1e6);
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.adjustTotalAssets(-1e6);
        }
        assertEq(vault.chi(), chi_);

        _pause();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.adjustTotalAssets(1e6);
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.adjustTotalAssets(-1e6);
        }
        assertEq(vault.chi(), chi_);
    }

    function test_adjustTotalAssets_authorized() public {
        _deposit(alice, 1_000e6);
        uint192 chi_ = vault.chi();
        _pause();
        vm.prank(admin);
        vault.adjustTotalAssets(1e6);
        assertGt(vault.chi(), chi_);

        vm.prank(admin);
        vault.adjustTotalAssets(-2e6);
        assertLt(vault.chi(), chi_);
    }

    // The role check precedes the pause check: an admin unpaused gets `not-paused`, a stranger
    // unpaused gets the role error (nothing about the pause state leaks before authorization).
    function test_adjustTotalAssets_roleCheckBeforePauseCheck() public {
        _deposit(alice, 1_000e6);
        assertFalse(vault.paused());

        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(1e6);

        vm.prank(stranger);
        _expectUnauthorized(stranger, DEFAULT_ADMIN_ROLE);
        vault.adjustTotalAssets(1e6);
    }

    function test_unpause_notAuthorized() public {
        _pause();
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.unpause();
        }
        assertTrue(vault.paused());
    }

    function test_unpause_authorized() public {
        _pause();
        assertTrue(vault.paused());
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit Unpaused();
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_unpause_idempotent() public {
        assertFalse(vault.paused());
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit Unpaused();
        vault.unpause();
        assertFalse(vault.paused());
    }

    // The pauser can pause but never unpause: an incident always needs the admin to resume.
    function test_unpause_guardianCannotUnpause() public {
        _pause();
        vm.prank(pauser);
        _expectUnauthorized(pauser, DEFAULT_ADMIN_ROLE);
        vault.unpause();
        assertTrue(vault.paused());
    }

    function test_upgradeToAndCall_notAuthorized() public {
        address newImpl_ = makeAddr("newImplementation");
        address impl_    = vault.implementation();
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.upgradeToAndCall(newImpl_, "");
        }
        assertEq(vault.implementation(), impl_);
    }

    function test_upgradeToAndCall_authorized() public {
        address newImpl_ = address(new SparkPrimeVault());
        vm.prank(admin);
        vault.upgradeToAndCall(newImpl_, "");
        assertEq(vault.implementation(), newImpl_);
    }

    // `initialize` cannot be re-run through the upgrade data path: the whole call reverts and the
    // implementation is unchanged. The implementation contract itself is locked by
    // `_disableInitializers`.
    function test_upgradeToAndCall_reinitializeReverts() public {
        address newImpl_ = address(new SparkPrimeVault());
        address impl_    = vault.implementation();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vault.upgradeToAndCall(
            newImpl_,
            abi.encodeCall(SparkPrimeVault.initialize, (address(spUsdc), "x", "x", stranger))
        );
        assertEq(vault.implementation(), impl_);
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, stranger));

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        SparkPrimeVault(newImpl_).initialize(address(spUsdc), "x", "x", stranger);

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        vault.initialize(address(spUsdc), "x", "x", stranger);
    }

    function test_grantRole_notAuthorized() public {
        bytes32[6] memory roles_  = _roles();
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            for (uint256 j; j < roles_.length; ++j) {
                vm.prank(actors_[i]);
                _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
                vault.grantRole(roles_[j], alice);
                assertFalse(vault.hasRole(roles_[j], alice));
            }
        }
    }

    function test_grantRole_authorized() public {
        bytes32[6] memory roles_ = _roles();
        vm.startPrank(admin);
        for (uint256 j; j < roles_.length; ++j) {
            assertFalse(vault.hasRole(roles_[j], alice));

            vm.expectEmit(address(vault));
            emit RoleGranted(roles_[j], alice, admin);
            vault.grantRole(roles_[j], alice);

            assertTrue(vault.hasRole(roles_[j], alice));
            assertEq(vault.getRoleAdmin(roles_[j]), DEFAULT_ADMIN_ROLE);
        }
        vm.stopPrank();
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    // Granting an already-held role is a silent no-op (no event).
    function test_grantRole_alreadyHeldIsNoOp() public {
        vm.prank(admin);
        vm.recordLogs();
        vault.grantRole(PAUSER_ROLE, pauser);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(vault.getRoleMemberCount(PAUSER_ROLE), 1);
    }

    function test_revokeRole_notAuthorized() public {
        bytes32[6] memory roles_  = _roles();
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            for (uint256 j; j < roles_.length; ++j) {
                vm.prank(actors_[i]);
                _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
                vault.revokeRole(roles_[j], admin);
            }
        }
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_revokeRole_authorized() public {
        bytes32[5] memory roles_   = [
            PAUSER_ROLE, OPERATOR_ROLE, REDEEM_FEE_SETTER_ROLE, TAKER_ROLE, OPERATOR_ROLE
        ];
        address[5] memory holders_ = [pauser, operator, redeemFeeSetter, taker, operator];

        vm.startPrank(admin);
        for (uint256 j; j < roles_.length; ++j) {
            assertTrue(vault.hasRole(roles_[j], holders_[j]));

            vm.expectEmit(address(vault));
            emit RoleRevoked(roles_[j], holders_[j], admin);
            vault.revokeRole(roles_[j], holders_[j]);

            assertFalse(vault.hasRole(roles_[j], holders_[j]));
            assertEq(vault.getRoleMembers(roles_[j]).length, 0);
            assertEq(vault.getRoleMemberCount(roles_[j]),    0);
        }
        vm.stopPrank();
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    // Anyone can renounce their own role; renouncing for someone else reverts, admin included.
    function test_renounceRole_badConfirmation() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlBadConfirmation.selector));
        vault.renounceRole(OPERATOR_ROLE, operator);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlBadConfirmation.selector));
        vault.renounceRole(OPERATOR_ROLE, operator);

        assertTrue(vault.hasRole(OPERATOR_ROLE, operator));
    }

    function test_renounceRole_self() public {
        vm.prank(operator);
        vm.expectEmit(address(vault));
        emit RoleRevoked(OPERATOR_ROLE, operator, operator);
        vault.renounceRole(OPERATOR_ROLE, operator);

        assertFalse(vault.hasRole(OPERATOR_ROLE, operator));
        assertEq(vault.getRoleMemberCount(OPERATOR_ROLE), 0);

        // A stranger renouncing a role it never held is a silent no-op.
        vm.prank(stranger);
        vm.recordLogs();
        vault.renounceRole(OPERATOR_ROLE, stranger);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // `_setRoleAdmin` is never called: every role (including DEFAULT_ADMIN itself) is
    // administered by DEFAULT_ADMIN, and nothing in the ABI can change that.
    function test_getRoleAdmin_allDefaultAdmin() public view {
        bytes32[6] memory roles_ = _roles();
        for (uint256 j; j < roles_.length; ++j) {
            assertEq(vault.getRoleAdmin(roles_[j]), DEFAULT_ADMIN_ROLE);
        }
        assertEq(vault.getRoleAdmin(keccak256("ANY_OTHER_ROLE")), DEFAULT_ADMIN_ROLE);
    }

    // A second admin granted by the first has the full admin surface, including revoking the
    // first one.
    function test_grantRole_secondAdminHasFullPower() public {
        vm.prank(admin);
        vault.grantRole(DEFAULT_ADMIN_ROLE, alice);
        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 2);
        assertEq(vault.getRoleMember(DEFAULT_ADMIN_ROLE, 0),   admin);
        assertEq(vault.getRoleMember(DEFAULT_ADMIN_ROLE, 1),   alice);

        vm.startPrank(alice);
        vault.setCapacity(7);
        vault.revokeRole(DEFAULT_ADMIN_ROLE, admin);
        vm.stopPrank();

        assertEq(vault.maxCapacity(), 7);
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(vault.getRoleMember(DEFAULT_ADMIN_ROLE, 0),   alice);

        vm.prank(admin);
        _expectUnauthorized(admin, DEFAULT_ADMIN_ROLE);
        vault.setCapacity(8);
    }

    // AccessControlEnumerable: `getRoleMember(role, i)` / `getRoleMemberCount` / `getRoleMembers`
    // agree, enumerate in grant order, swap-and-pop on revoke, and panic 0x32 out of range.
    function test_getRoleMember_enumeration() public {
        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(vault.getRoleMember(DEFAULT_ADMIN_ROLE, 0),   admin);
        assertEq(vault.getRoleMembers(DEFAULT_ADMIN_ROLE).length, 1);
        assertEq(vault.getRoleMembers(DEFAULT_ADMIN_ROLE)[0],     admin);

        bytes32[6] memory roles_   = _roles();
        address[6] memory holders_ = [admin, pauser, operator, redeemFeeSetter, taker, operator];
        for (uint256 j; j < roles_.length; ++j) {
            assertEq(vault.getRoleMemberCount(roles_[j]), 1);
            assertEq(vault.getRoleMember(roles_[j], 0),   holders_[j]);
            vm.expectRevert(stdError.indexOOBError);
            vault.getRoleMember(roles_[j], 1);
        }

        vm.startPrank(admin);
        vault.grantRole(PAUSER_ROLE, alice);
        vault.grantRole(PAUSER_ROLE, bob);
        vm.stopPrank();
        assertEq(vault.getRoleMemberCount(PAUSER_ROLE), 3);
        assertEq(vault.getRoleMember(PAUSER_ROLE, 0),   pauser);
        assertEq(vault.getRoleMember(PAUSER_ROLE, 1),   alice);
        assertEq(vault.getRoleMember(PAUSER_ROLE, 2),   bob);

        // Revoking the first member moves the last one into its slot (EnumerableSet swap-pop).
        vm.prank(admin);
        vault.revokeRole(PAUSER_ROLE, pauser);
        assertEq(vault.getRoleMemberCount(PAUSER_ROLE), 2);
        assertEq(vault.getRoleMember(PAUSER_ROLE, 0),   bob);
        assertEq(vault.getRoleMember(PAUSER_ROLE, 1),   alice);
        address[] memory members_ = vault.getRoleMembers(PAUSER_ROLE);
        assertEq(members_.length, 2);
        assertEq(members_[0], bob);
        assertEq(members_[1], alice);

        vm.expectRevert(stdError.indexOOBError);
        vault.getRoleMember(PAUSER_ROLE, 2);
        vm.expectRevert(stdError.indexOOBError);
        vault.getRoleMember(keccak256("NEVER_GRANTED"), 0);
        assertEq(vault.getRoleMemberCount(keccak256("NEVER_GRANTED")), 0);
    }

    /**********************************************************************************************/
    /*** OPERATOR_ROLE                                                                        ***/
    /**********************************************************************************************/

    function test_setVSR_notAuthorized() public {
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == operator) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], OPERATOR_ROLE);
            vault.setVSR(FOUR_PCT_VSR);
        }
        assertEq(vault.vsr(), RAY);
    }

    function test_setVSR_authorized() public {
        vm.prank(operator);
        vault.setVSR(FOUR_PCT_VSR);
        assertEq(vault.vsr(), FOUR_PCT_VSR);
    }

    /**********************************************************************************************/
    /*** TAKER_ROLE                                                                             ***/
    /**********************************************************************************************/

    function test_take_notAuthorized() public {
        _deposit(alice, 100e6);
        uint256 bal_ = _vaultSpUsdc();
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == taker) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], TAKER_ROLE);
            vault.take(1);
        }
        assertEq(_vaultSpUsdc(), bal_);
    }

    function test_take_authorized() public {
        _deposit(alice, 100e6);
        uint256 bal_ = _vaultSpUsdc();
        vm.prank(taker);
        vm.expectEmit(address(vault));
        emit Take(bal_);
        vault.take(bal_);
        assertEq(spUsdc.balanceOf(taker), bal_);
        assertEq(_vaultSpUsdc(),          0);
    }

    /**********************************************************************************************/
    /*** OPERATOR_ROLE                                                                        ***/
    /**********************************************************************************************/

    function test_processPendingDeposits_notAuthorized() public {
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == operator) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], OPERATOR_ROLE);
            vault.processPendingDeposits(type(uint256).max, 10);
        }
    }

    function test_processPendingDeposits_authorized() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        _setCapacity(type(uint128).max);
        vm.prank(operator);
        vault.processPendingDeposits(type(uint256).max, 10);
        (, , uint256 left_) = _depositRequest(id_);
        assertEq(left_, 0);
        assertGt(vault.balanceOf(alice), 0);
    }

    function test_processPendingRedeems_notAuthorized() public {
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == operator) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], OPERATOR_ROLE);
            vault.processPendingRedeems(type(uint256).max, 10);
        }
    }

    function test_processPendingRedeems_authorized() public {
        _deposit(alice, 100e6);
        uint256 id_ = _requestRedeem(alice, vault.balanceOf(alice));
        vm.prank(operator);
        vault.processPendingRedeems(type(uint256).max, 10);
        (, , uint256 left_) = _redeemRequest(id_);
        assertEq(left_, 0);
        assertApproxEqAbs(usdc.balanceOf(alice), 100e6, 2);
    }

    function test_processPendingDepositCancellations_notAuthorized() public {
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == operator) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], OPERATOR_ROLE);
            vault.processPendingDepositCancellations(type(uint256).max, 10);
        }
    }

    function test_processPendingDepositCancellations_authorized() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        vm.prank(alice);
        uint256 cancelId_ = vault.requestDepositCancellation(id_, alice);
        vm.prank(operator);
        vault.processPendingDepositCancellations(type(uint256).max, 10);
        (, , uint256 left_) = _cancelledDepositRequest(cancelId_);
        assertEq(left_, 0);
        assertEq(usdc.balanceOf(alice), 100e6 - 1);  // spUSDC redeem rounds down
    }

    /**********************************************************************************************/
    /*** REDEEM_FEE_SETTER_ROLE                                                                 ***/
    /**********************************************************************************************/

    function test_setRedeemFeeRate_notAuthorized() public {
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == redeemFeeSetter) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], REDEEM_FEE_SETTER_ROLE);
            vault.setRedeemFeeRate(0.001e18);
        }
        assertEq(vault.redeemFeeRate(), 0);
    }

    function test_setRedeemFeeRate_authorized() public {
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.001e18);
        assertEq(vault.redeemFeeRate(), 0.001e18);
    }

    /**********************************************************************************************/
    /*** PAUSER_ROLE                                                                          ***/
    /**********************************************************************************************/

    function test_pause_notAuthorized() public {
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == pauser) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], PAUSER_ROLE);
            vault.pause();
        }
        assertFalse(vault.paused());
    }

    function test_pause_authorized() public {
        vm.prank(pauser);
        vm.expectEmit(address(vault));
        emit Paused();
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_pause_idempotent() public {
        _pause();
        assertTrue(vault.paused());
        vm.prank(pauser);
        vm.expectEmit(address(vault));
        emit Paused();
        vault.pause();
        assertTrue(vault.paused());
    }

    /**********************************************************************************************/
    /*** Owner-only request functions                                                          ***/
    /**********************************************************************************************/

    // V2-2 / F-1 fixed at 0ebb452: `requestDepositCancellation` is owner-only. The pauser (and
    // every other role holder) reverts `not-authorized` even when naming the owner as recipient;
    // the entry, both pending counters and the cancellation queue are untouched.
    function test_fixed_F1_requestDepositCancellation_ownerOnly() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        (, , uint256 queued_) = _depositRequest(id_);
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            vm.prank(actors_[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.requestDepositCancellation(id_, actors_[i]);

            vm.prank(actors_[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.requestDepositCancellation(id_, alice);  // owner as recipient does not help
        }
        (, , uint256 shares_) = _depositRequest(id_);
        assertEq(shares_, queued_);
        assertEq(vault.pendingDepositSavingsShares(),          queued_);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_cancelledDepositQueueLength(),               0);
    }

    // The owner cancels: the entry moves to the cancellation queue, nothing is paid until the
    // operator settles it, and the owner may name any non-blacklisted recipient.
    function test_requestDepositCancellation_owner() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        (, , uint256 queued_) = _depositRequest(id_);

        vm.prank(alice);
        uint256 cancelId_ = vault.requestDepositCancellation(id_, bob);

        (, , uint256 shares_) = _depositRequest(id_);
        assertEq(shares_,   0);
        assertEq(cancelId_, 0);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob),   0);

        (address owner_, address recipient_, uint256 cShares_) = _cancelledDepositRequest(cancelId_);
        assertEq(owner_,     alice);
        assertEq(recipient_, bob);
        assertEq(cShares_,   queued_);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), queued_);

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob),   100e6 - 1);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // Check order in `requestDepositCancellation` (:424-430): zero recipient, blacklisted
    // recipient, dead entry, caller. An out-of-range id panics in the array read before the
    // entry checks.
    function test_requestDepositCancellation_checkOrder() public {
        uint256 id_ = _queueDeposit(alice, 100e6);

        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.requestDepositCancellation(id_, address(0));

        _blacklist(bob);
        vm.prank(stranger);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestDepositCancellation(id_, bob);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.requestDepositCancellation(id_, bob);
        _unblacklist(bob);

        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id_, alice);

        vm.prank(stranger);
        vm.expectRevert(stdError.indexOOBError);
        vault.requestDepositCancellation(type(uint256).max, alice);

        vm.prank(alice);
        vault.requestDepositCancellation(id_, bob);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id_, alice);
        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id_, alice);
    }

    // V2-1 fixed: the three `update*Recipient` functions are owner-only. Every role holder and a
    // stranger revert `not-authorized` on someone else's entry; the owner succeeds; a dead entry
    // reverts `no-request` before the owner check; an out-of-range id panics (0x32).
    function test_fixed_V2_1_updateRecipient_ownerOnly() public {
        _deposit(alice, 1_000e6);
        uint256 redId_ = _requestRedeem(alice, 100e6);

        _setCapacity(vault.totalSupply());
        uint256 depId_  = _deposit(bob, 100e6);
        uint256 dep2Id_ = _deposit(bob, 50e6);
        vm.prank(bob);
        uint256 cancelId_ = vault.requestDepositCancellation(dep2Id_, bob);

        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            vm.startPrank(actors_[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.updateDepositRecipient(depId_, actors_[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.updateDepositCancellationRecipient(cancelId_, actors_[i]);
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vault.updateRedeemRecipient(redId_, actors_[i]);
            vm.stopPrank();
        }

        // The other depositor is not authorized either (owner check, not "any owner").
        vm.startPrank(alice);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositRecipient(depId_, alice);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(cancelId_, alice);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(redId_, bob);

        (, address depRecipient_, )    = _depositRequest(depId_);
        (, address cancelRecipient_, ) = _cancelledDepositRequest(cancelId_);
        (, address redRecipient_, )    = _redeemRequest(redId_);
        assertEq(depRecipient_,    bob);
        assertEq(cancelRecipient_, bob);
        assertEq(redRecipient_,    alice);

        // Owners succeed; owner field is untouched, only the payout address moves.
        address payout_ = makeAddr("payout");
        vm.startPrank(bob);
        vault.updateDepositRecipient(depId_, payout_);
        vault.updateDepositCancellationRecipient(cancelId_, payout_);
        vm.stopPrank();
        vm.prank(alice);
        vault.updateRedeemRecipient(redId_, payout_);

        address depOwner_;
        address cancelOwner_;
        address redOwner_;
        (depOwner_,    depRecipient_, )    = _depositRequest(depId_);
        (cancelOwner_, cancelRecipient_, ) = _cancelledDepositRequest(cancelId_);
        (redOwner_,    redRecipient_, )    = _redeemRequest(redId_);
        assertEq(depOwner_,        bob);
        assertEq(cancelOwner_,     bob);
        assertEq(redOwner_,        alice);
        assertEq(depRecipient_,    payout_);
        assertEq(cancelRecipient_, payout_);
        assertEq(redRecipient_,    payout_);

        // Dead entries: `no-request` for the owner and for a stranger alike.
        vm.prank(bob);
        vault.requestDepositCancellation(depId_, bob);
        _processRedeems(type(uint256).max, 10);
        _processCancelledDeposits(type(uint256).max, 10);

        address[2] memory callers_ = [bob, stranger];
        for (uint256 i; i < callers_.length; ++i) {
            vm.startPrank(callers_[i]);
            vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
            vault.updateDepositRecipient(depId_, callers_[i]);
            vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
            vault.updateDepositCancellationRecipient(cancelId_, callers_[i]);
            vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
            vault.updateRedeemRecipient(redId_, callers_[i]);
            vm.stopPrank();
        }

        uint256 oob_ = type(uint256).max;
        vm.startPrank(stranger);
        vm.expectRevert(stdError.indexOOBError);
        vault.updateDepositRecipient(oob_, stranger);
        vm.expectRevert(stdError.indexOOBError);
        vault.updateDepositCancellationRecipient(oob_, stranger);
        vm.expectRevert(stdError.indexOOBError);
        vault.updateRedeemRecipient(oob_, stranger);
        vm.stopPrank();
    }

    // Recipient validation runs before the owner check: zero recipient everywhere, the vault
    // itself for the deposit updater, a blacklisted recipient for the asset-paying updaters.
    function test_updateRecipient_recipientChecksFirst() public {
        _deposit(alice, 1_000e6);
        uint256 redId_ = _requestRedeem(alice, 100e6);
        _setCapacity(vault.totalSupply());
        uint256 depId_  = _deposit(bob, 100e6);
        uint256 dep2Id_ = _deposit(bob, 50e6);
        vm.prank(bob);
        uint256 cancelId_ = vault.requestDepositCancellation(dep2Id_, bob);

        address[2] memory callers_ = [stranger, bob];
        for (uint256 i; i < callers_.length; ++i) {
            vm.startPrank(callers_[i]);
            vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
            vault.updateDepositRecipient(depId_, address(0));
            vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
            vault.updateDepositCancellationRecipient(cancelId_, address(0));
            vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
            vault.updateRedeemRecipient(redId_, address(0));

            vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
            vault.updateDepositRecipient(depId_, address(vault));
            vm.stopPrank();
        }

        _blacklist(stranger);
        vm.startPrank(bob);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.updateDepositCancellationRecipient(cancelId_, stranger);
        vault.updateDepositRecipient(depId_, stranger);  // deposit recipients are not blacklist-checked
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/recipient-cannot-receive");
        vault.updateRedeemRecipient(redId_, stranger);

        (, address depRecipient_, ) = _depositRequest(depId_);
        assertEq(depRecipient_, stranger);
    }

    /**********************************************************************************************/
    /*** Permissionless functions                                                               ***/
    /**********************************************************************************************/

    function test_permissionless_stranger() public {
        _fund(stranger, 200e6);

        vm.startPrank(stranger);
        uint256 id0_ = vault.requestDeposit(100e6, stranger, 0);
        uint256 id1_ = vault.requestDeposit(100e6, stranger, 42);
        vm.stopPrank();

        assertEq(id0_, 0);
        assertEq(id1_, 1);

        uint256 shares_ = vault.balanceOf(stranger);
        assertGt(shares_, 0);

        vm.startPrank(stranger);
        assertTrue(vault.approve(bob, 1));
        assertTrue(vault.transfer(bob, 1));
        assertTrue(vault.transferFrom(stranger, bob, 1));
        uint256 rid_ = vault.requestRedeem(shares_ - 2, stranger);
        vault.drip();
        vm.stopPrank();

        assertEq(rid_,                            0);
        assertEq(vault.balanceOf(stranger),       0);
        assertEq(vault.balanceOf(address(vault)), shares_ - 2);
        assertEq(vault.pendingRedeemShares(),     shares_ - 2);
        assertEq(vault.balanceOf(bob),            2);

        // A queued deposit can be cancelled by its owner without any role.
        _setCapacity(vault.totalSupply());
        usdc.mint(stranger, 50e6);
        vm.prank(stranger);
        uint256 id2_ = vault.requestDeposit(50e6, stranger, 0);
        vm.prank(stranger);
        vault.requestDepositCancellation(id2_, stranger);
        (, , uint256 left_) = _depositRequest(id2_);
        assertEq(left_, 0);
    }

    // `claim(recipient)` is permissionless: any actor (admin, each hot role, a stranger) can push
    // bob's claimable USDC to bob; the caller never receives anything and the exact amount moves.
    function test_claim_permissionless() public {
        _deposit(alice, 1_000e6);
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            uint256 assets_ = _creditClaimable(10e6);
            _unblacklist(bob);
            uint256 bobBefore_    = usdc.balanceOf(bob);
            uint256 callerBefore_ = usdc.balanceOf(actors_[i]);
            uint256 vaultBefore_  = usdc.balanceOf(address(vault));

            vm.prank(actors_[i]);
            vm.expectEmit(address(vault));
            emit Claim(bob, assets_);
            uint256 claimed_ = vault.claim(bob);

            assertEq(claimed_,                       assets_);
            assertEq(usdc.balanceOf(bob),            bobBefore_ + assets_);
            assertEq(usdc.balanceOf(actors_[i]),     callerBefore_);
            assertEq(usdc.balanceOf(address(vault)), vaultBefore_ - assets_);
            assertEq(vault.claimableAssets(bob),     0);

            vm.prank(actors_[i]);
            vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
            vault.claim(bob);
        }
    }

    // While bob is still blacklisted the USDC transfer reverts inside the asset and the credit is
    // preserved (state rolls back); nobody can redirect it.
    function test_claim_blacklistedRecipientReverts() public {
        _deposit(alice, 1_000e6);
        uint256 assets_ = _creditClaimable(10e6);
        assertTrue(usdc.isBlacklisted(bob));

        vm.prank(stranger);
        vm.expectRevert(BLACKLISTED);
        vault.claim(bob);
        assertEq(vault.claimableAssets(bob), assets_);

        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(stranger);

        _unblacklist(bob);
        vm.prank(stranger);
        vault.claim(bob);
        assertEq(usdc.balanceOf(bob), assets_);
    }

    // `drip` is permissionless and identical for every caller.
    function test_drip_permissionless() public {
        _deposit(alice, 1_000e6);
        _setPrimeVsr(FOUR_PCT_VSR);
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            _warp(1 days);
            uint192 expected_ = vault.nowChi();
            assertGt(expected_, vault.chi());
            vm.prank(actors_[i]);
            uint192 got_ = vault.drip();
            assertEq(got_,        expected_);
            assertEq(vault.chi(), expected_);
            assertEq(vault.rho(), block.timestamp);
        }
    }

    // Removed surface at 0ebb452: `realizeGain`, `realizeLoss`, `cancelRedeemRequest`, the 2-arg
    // `requestDeposit`, and the `RISK_MANAGER_ROLE` / `SETTER_ROLE` / `UNPAUSER_ROLE` constants
    // all miss the dispatcher (empty revert) for every actor. I-3 and the dead
    // `CancelRedeemRequest` event are gone with them.
    function test_fixed_removedSurface_selectorsGone() public {
        bytes[7] memory calls_ = [
            abi.encodeWithSignature("realizeGain(uint256)", 1),
            abi.encodeWithSignature("realizeLoss(uint256)", 1),
            abi.encodeWithSignature("cancelRedeemRequest(uint256,address)", 0, alice),
            abi.encodeWithSignature("requestDeposit(uint256,address)", 1, alice),
            abi.encodeWithSignature("RISK_MANAGER_ROLE()"),
            abi.encodeWithSignature("SETTER_ROLE()"),
            abi.encodeWithSignature("UNPAUSER_ROLE()")
        ];
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            for (uint256 j; j < calls_.length; ++j) {
                vm.prank(actors_[i]);
                (bool ok_, bytes memory ret_) = address(vault).call(calls_[j]);
                assertFalse(ok_);
                assertEq(ret_.length, 0);
            }
        }
        // The old harness roles are arbitrary bytes32 values the contract does not know: holding
        // them gates nothing (the admin surface still needs DEFAULT_ADMIN).
        vm.prank(admin);
        vault.grantRole(keccak256("UNPAUSER_ROLE"), stranger);
        _pause();
        vm.prank(stranger);
        _expectUnauthorized(stranger, DEFAULT_ADMIN_ROLE);
        vault.unpause();
    }

    /**********************************************************************************************/
    /*** Pause scope                                                                            ***/
    /**********************************************************************************************/

    // alice holds shares, a deposit is queued (bob), a cancelled deposit awaits settlement (bob),
    // a redeem is queued (alice), bob has a claimable balance, then the pauser pauses.
    function _pausedFixture()
        internal
        returns (uint256 depId_, uint256 cancelId_, uint256 redId_)
    {
        _deposit(alice, 1_000e6);
        _creditClaimable(10e6);
        _unblacklist(bob);  // credit stays; bob can be funded again
        redId_ = _requestRedeem(alice, 100e6);
        _setCapacity(vault.totalSupply());
        depId_ = _deposit(bob, 100e6);
        uint256 dep2Id_ = _deposit(bob, 50e6);
        vm.prank(bob);
        cancelId_ = vault.requestDepositCancellation(dep2Id_, bob);
        _fund(alice, 100e6);
        _pause();
    }

    function test_pause_blocksRequestDeposit() public {
        _pausedFixture();
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDeposit(1e6, alice, 0);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDeposit(1e6, alice, 1);
    }

    function test_pause_blocksRequestDepositCancellation() public {
        (uint256 depId_, , ) = _pausedFixture();
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDepositCancellation(depId_, bob);
        _unpause();
        vm.prank(bob);
        vault.requestDepositCancellation(depId_, bob);
    }

    function test_pause_blocksRequestRedeem() public {
        _pausedFixture();
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestRedeem(1e6, alice);
    }

    // `onlyRole` runs before `whenNotPaused`: the operator sees `paused`, a stranger sees the
    // role error.
    function test_pause_blocksProcessPendingDeposits() public {
        (uint256 depId_, , ) = _pausedFixture();
        _setCapacity(type(uint128).max);
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingDeposits(type(uint256).max, 10);
        vm.prank(stranger);
        _expectUnauthorized(stranger, OPERATOR_ROLE);
        vault.processPendingDeposits(type(uint256).max, 10);
        (, , uint256 left_) = _depositRequest(depId_);
        assertGt(left_, 0);
    }

    function test_pause_blocksProcessPendingRedeems() public {
        (, , uint256 redId_) = _pausedFixture();
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingRedeems(type(uint256).max, 10);
        vm.prank(stranger);
        _expectUnauthorized(stranger, OPERATOR_ROLE);
        vault.processPendingRedeems(type(uint256).max, 10);
        (, , uint256 left_) = _redeemRequest(redId_);
        assertEq(left_, 100e6);
    }

    function test_pause_blocksProcessPendingDepositCancellations() public {
        (, uint256 cancelId_, ) = _pausedFixture();
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingDepositCancellations(type(uint256).max, 10);
        vm.prank(stranger);
        _expectUnauthorized(stranger, OPERATOR_ROLE);
        vault.processPendingDepositCancellations(type(uint256).max, 10);
        (, , uint256 left_) = _cancelledDepositRequest(cancelId_);
        assertGt(left_, 0);
    }

    // The recipient updates are not paused: the owner can still rewrite its own payout address
    // mid-incident; nobody else can.
    function test_pause_doesNotBlockUpdateRecipient() public {
        (uint256 depId_, uint256 cancelId_, uint256 redId_) = _pausedFixture();
        address payout_ = makeAddr("payout");

        vm.startPrank(stranger);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositRecipient(depId_, stranger);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(cancelId_, stranger);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(redId_, stranger);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.updateDepositRecipient(depId_, payout_);
        vault.updateDepositCancellationRecipient(cancelId_, payout_);
        vm.stopPrank();
        vm.prank(alice);
        vault.updateRedeemRecipient(redId_, payout_);

        (, address r1_, ) = _depositRequest(depId_);
        (, address r2_, ) = _cancelledDepositRequest(cancelId_);
        (, address r3_, ) = _redeemRequest(redId_);
        assertEq(r1_, payout_);
        assertEq(r2_, payout_);
        assertEq(r3_, payout_);
        assertTrue(vault.paused());
    }

    // F-2: `take` is not paused; the whole backing (queued deposits included) can leave during
    // an incident.
    function test_pause_doesNotBlockTake() public {
        _pausedFixture();
        uint256 bal_ = _vaultSpUsdc();
        assertGt(bal_, 0);
        assertGt(vault.pendingDepositSavingsShares() + vault.pendingCancelledDepositSavingsShares(), 0);
        vm.prank(taker);
        vault.take(bal_);
        assertEq(_vaultSpUsdc(), 0);
        assertEq(spUsdc.balanceOf(taker), bal_);
    }

    function test_pause_doesNotBlockDrip() public {
        _pausedFixture();
        _setPrimeVsr(FOUR_PCT_VSR);
        uint192 chi_ = vault.chi();
        _warp(1 days);
        vm.prank(stranger);
        uint192 nChi_ = vault.drip();
        assertGt(nChi_,       chi_);
        assertEq(vault.chi(), nChi_);
    }

    // `claim` is not paused: a de-blacklisted recipient can be paid out during the pause.
    function test_pause_doesNotBlockClaim() public {
        _pausedFixture();
        uint256 assets_ = vault.claimableAssets(bob);
        assertGt(assets_, 0);
        _unblacklist(bob);
        vm.prank(stranger);
        vault.claim(bob);
        assertEq(usdc.balanceOf(bob),        assets_);
        assertEq(vault.claimableAssets(bob), 0);
        assertTrue(vault.paused());
    }

    function test_pause_doesNotBlockSetVSR() public {
        _pausedFixture();
        vm.prank(operator);
        vault.setVSR(FOUR_PCT_VSR);
        assertEq(vault.vsr(), FOUR_PCT_VSR);
    }

    // `adjustTotalAssets` is the one function that requires the pause.
    function test_pause_enablesAdjustTotalAssets() public {
        _pausedFixture();
        uint256 totalAssets_ = vault.totalAssets();
        uint256 supply_      = vault.totalSupply();
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit TotalAssetsAdjusted(uint192((totalAssets_ - 1e6) * RAY / supply_), -1e6);
        vault.adjustTotalAssets(-1e6);
        assertEq(vault.chi(), (totalAssets_ - 1e6) * RAY / supply_);
        assertTrue(vault.paused());
    }

    function test_pause_doesNotBlockERC20() public {
        _pausedFixture();
        uint256 bal_ = vault.balanceOf(alice);
        vm.startPrank(alice);
        vault.approve(bob, 10);
        vault.transfer(bob, 5);
        vm.stopPrank();
        vm.prank(bob);
        vault.transferFrom(alice, bob, 5);
        assertEq(vault.balanceOf(alice), bal_ - 10);
        assertEq(vault.balanceOf(bob),   10);
    }

    function test_pause_doesNotBlockPermit() public {
        _pausedFixture();
        (address owner_, uint256 key_) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        bytes32 digest_ = keccak256(abi.encodePacked(
            "\x19\x01",
            vault.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(vault.PERMIT_TYPEHASH(), owner_, bob, 7, 0, deadline_))
        ));
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(key_, digest_);
        vault.permit(owner_, bob, 7, deadline_, v_, r_, s_);
        assertEq(vault.allowance(owner_, bob), 7);
        assertEq(vault.nonces(owner_),         1);
    }

    function test_pause_doesNotBlockAdminSetters() public {
        _pausedFixture();
        vm.startPrank(admin);
        vault.setCapacity(5);
        vault.setMaxRedeemFeeRate(0.005e18);
        vault.setMinDeposit(1);
        vault.setMinRedeem(2);
        vault.setVSRBounds(RAY, FOUR_PCT_VSR);
        vault.grantRole(OPERATOR_ROLE, alice);
        vault.revokeRole(OPERATOR_ROLE, alice);
        vm.stopPrank();
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.005e18);

        assertEq(vault.maxCapacity(),      5);
        assertEq(vault.maxRedeemFeeRate(), 0.005e18);
        assertEq(vault.minDeposit(),       1);
        assertEq(vault.minRedeem(),        2);
        assertEq(vault.maxVSR(),           FOUR_PCT_VSR);
        assertEq(vault.redeemFeeRate(),    0.005e18);
        assertTrue(vault.paused());
    }

    function test_pause_doesNotBlockUpgrade() public {
        _pausedFixture();
        address newImpl_ = address(new SparkPrimeVault());
        vm.prank(admin);
        vault.upgradeToAndCall(newImpl_, "");
        assertEq(vault.implementation(), newImpl_);
        assertTrue(vault.paused());
    }

    /**********************************************************************************************/
    /*** Revocation mid-flight                                                                  ***/
    /**********************************************************************************************/

    function test_revokeRebalancer_queuesFrozenUntilNewRebalancer() public {
        _deposit(alice, 1_000e6);
        uint256 redId_ = _requestRedeem(alice, 100e6);
        _setCapacity(vault.totalSupply());
        uint256 depId_  = _deposit(bob, 100e6);
        uint256 dep2Id_ = _deposit(bob, 50e6);
        vm.prank(bob);
        uint256 cancelId_ = vault.requestDepositCancellation(dep2Id_, bob);
        _setCapacity(type(uint128).max);

        vm.prank(admin);
        vault.revokeRole(OPERATOR_ROLE, operator);

        vm.prank(operator);
        _expectUnauthorized(operator, OPERATOR_ROLE);
        vault.processPendingDeposits(type(uint256).max, 10);

        vm.prank(operator);
        _expectUnauthorized(operator, OPERATOR_ROLE);
        vault.processPendingRedeems(type(uint256).max, 10);

        vm.prank(operator);
        _expectUnauthorized(operator, OPERATOR_ROLE);
        vault.processPendingDepositCancellations(type(uint256).max, 10);

        // All three queues are intact and frozen; bob's refund is unpaid until a planner exists.
        (, , uint256 depShares_)    = _depositRequest(depId_);
        (, , uint256 cancelShares_) = _cancelledDepositRequest(cancelId_);
        (, , uint256 redShares_)    = _redeemRequest(redId_);
        assertGt(depShares_,    0);
        assertGt(cancelShares_, 0);
        assertEq(redShares_,    100e6);
        assertEq(usdc.balanceOf(bob), 0);

        address newRebalancer_ = makeAddr("newRebalancer");
        vm.prank(admin);
        vault.grantRole(OPERATOR_ROLE, newRebalancer_);

        vm.startPrank(newRebalancer_);
        vault.processPendingDeposits(type(uint256).max, 10);
        vault.processPendingRedeems(type(uint256).max, 10);
        vault.processPendingDepositCancellations(type(uint256).max, 10);
        vm.stopPrank();

        (, , depShares_)    = _depositRequest(depId_);
        (, , cancelShares_) = _cancelledDepositRequest(cancelId_);
        (, , redShares_)    = _redeemRequest(redId_);
        assertEq(depShares_,    0);
        assertEq(cancelShares_, 0);
        assertEq(redShares_,    0);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.pendingRedeemShares(),                  0);
        assertEq(usdc.balanceOf(bob), 50e6 - 1);
    }

    function test_revokeTaker_afterTake_returnStillWorks() public {
        _deposit(alice, 1_000e6);
        uint256 bal_ = _vaultSpUsdc();
        _take(bal_);
        assertEq(spUsdc.balanceOf(taker), bal_);

        vm.prank(admin);
        vault.revokeRole(TAKER_ROLE, taker);

        vm.prank(taker);
        _expectUnauthorized(taker, TAKER_ROLE);
        vault.take(0);

        // Return is a plain ERC20 transfer; no role needed.
        vm.prank(taker);
        spUsdc.transfer(address(vault), bal_);
        assertEq(_vaultSpUsdc(),          bal_);
        assertEq(spUsdc.balanceOf(taker), 0);

        uint256 redId_ = _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems(type(uint256).max, 10);
        (, , uint256 left_) = _redeemRequest(redId_);
        assertEq(left_, 0);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000e6, 2);
    }

    // A revoked pauser loses pause; the admin can still unpause.
    function test_revokeGuardian_whilePaused_adminCanStillUnpause() public {
        _deposit(alice, 1_000e6);
        _pause();
        vm.prank(admin);
        vault.revokeRole(PAUSER_ROLE, pauser);
        assertTrue(vault.paused());

        vm.prank(pauser);
        _expectUnauthorized(pauser, PAUSER_ROLE);
        vault.pause();

        _unpause();
        assertFalse(vault.paused());
    }

    // A revoked VSR setter leaves the live rate in force (C-7 flavour): only a new setter, not
    // the admin, can change `vsr`.
    function test_revokeVsrSetter_rateStaysInForce() public {
        _deposit(alice, 1_000e6);
        _setPrimeVsr(TEN_PCT_VSR);
        vm.prank(admin);
        vault.revokeRole(OPERATOR_ROLE, operator);

        vm.prank(admin);
        _expectUnauthorized(admin, OPERATOR_ROLE);
        vault.setVSR(RAY);

        uint256 before_ = vault.assetsOf(alice);
        _warpAndDrip(365 days);
        assertGt(vault.assetsOf(alice), before_ * 109 / 100);
        assertEq(vault.vsr(), TEN_PCT_VSR);
    }

    /**********************************************************************************************/
    /*** V2-8: admin can vanish                                                                 ***/
    /**********************************************************************************************/

    // V2-8 (open): the only DEFAULT_ADMIN can renounce and leave the vault without any admin
    // forever: no unpause, no upgrade, no role changes, no adjustTotalAssets, no setters. Proven
    // while paused: paused for good, with queued requests stuck and `take` still live.
    function test_BUG_V2_8_lastAdminCanRenounce() public {
        _deposit(alice, 1_000e6);
        _requestRedeem(alice, 100e6);
        _pause();
        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit RoleRevoked(DEFAULT_ADMIN_ROLE, admin, admin);
        vault.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 0);
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));

        address newImpl_ = address(new SparkPrimeVault());
        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            vm.startPrank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.unpause();
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.upgradeToAndCall(newImpl_, "");
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.grantRole(DEFAULT_ADMIN_ROLE, actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.adjustTotalAssets(1e6);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.setCapacity(1);
            vm.stopPrank();
        }
        assertTrue(vault.paused());

        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingRedeems(type(uint256).max, 10);

        // The backing can still leave.
        uint256 bal_ = _vaultSpUsdc();
        vm.prank(taker);
        vault.take(bal_);
        assertEq(_vaultSpUsdc(), 0);
    }

    // Same outcome through revokeRole on self (no confirmation argument at all).
    function test_BUG_V2_8_lastAdminCanRevokeSelf() public {
        vm.prank(admin);
        vault.revokeRole(DEFAULT_ADMIN_ROLE, admin);
        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 0);

        vm.prank(admin);
        _expectUnauthorized(admin, DEFAULT_ADMIN_ROLE);
        vault.grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // V2-8 (open): `initialize(..., address(0))` is accepted. The zero address is the only admin
    // member: no setters, no pause (no pauser can ever be appointed), no upgrade, from block
    // one.
    function test_BUG_V2_8_zeroAdminAtInit() public {
        SparkPrimeVault fresh_ = SparkPrimeVault(address(new ERC1967Proxy(
            address(new SparkPrimeVault()),
            abi.encodeCall(
                SparkPrimeVault.initialize,
                (address(spUsdc), "Spark Prime USDC", "spPRIME", address(0))
            )
        )));

        assertTrue(fresh_.hasRole(DEFAULT_ADMIN_ROLE, address(0)));
        assertEq(fresh_.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(fresh_.getRoleMember(DEFAULT_ADMIN_ROLE, 0),   address(0));
        assertFalse(fresh_.hasRole(DEFAULT_ADMIN_ROLE, admin));

        address[7] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            vm.startPrank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            fresh_.setCapacity(1);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            fresh_.grantRole(PAUSER_ROLE, actors_[i]);
            _expectUnauthorized(actors_[i], PAUSER_ROLE);
            fresh_.pause();
            vm.stopPrank();
        }
        assertEq(fresh_.maxCapacity(), 0);
    }

}
