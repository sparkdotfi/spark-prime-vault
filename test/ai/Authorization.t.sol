// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../../lib/forge-std/src/StdError.sol";

import { ERC1967Proxy }    from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl }  from "../../lib/oz/contracts/access/IAccessControl.sol";
import { IERC1967 }        from "../../lib/oz/contracts/interfaces/IERC1967.sol";
import { Initializable }   from "../../lib/oz/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "../../lib/oz/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ERC1967Utils }    from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Utils.sol";

import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../src/SparkPrimeVault.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

/// @dev Authorization matrix, pause scope, role administration and mid-flight role revocation
///      for `SparkPrimeVault` on `master` @ c512609. Every role-gated function is exercised by
///      all seven role holders plus a stranger: the authorized actor succeeds, every other actor
///      reverts with the exact OZ custom error `AccessControlUnauthorizedAccount(account, role)`.
///
///      Round 6 (c512609): seven roles. DEFAULT_ADMIN (upgrade, setMaxRedeemFeeRate,
///      setMinDeposit, setMinDepositCancellation, setMinRedeem, setVSRBounds, grant/revoke),
///      LOSS_MANAGER (adjustTotalAssets), OPERATOR (setCapacity, setVSR, processPending*),
///      PAUSER (pause), UNPAUSER (unpause), REDEEM_FEE_SETTER (setRedeemFeeRate), TAKER (take).
///      GUARDIAN / REBALANCER / VSR_SETTER are gone. `requestDepositCancellation` and
///      `processPendingDepositCancellations` are no longer pause-gated.
contract AuthorizationTest is LocalTestBase {

    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address stranger = makeAddr("stranger");

    // All actors that hold exactly one role, plus a stranger with none.
    function _actors() internal view returns (address[8] memory actors_) {
        actors_ = [
            admin, lossManager, operator, pauser, unpauser, redeemFeeSetter, taker, stranger
        ];
    }

    function _roles() internal view returns (bytes32[7] memory roles_) {
        roles_ = [
            DEFAULT_ADMIN_ROLE, LOSS_MANAGER_ROLE, OPERATOR_ROLE, PAUSER_ROLE, UNPAUSER_ROLE,
            REDEEM_FEE_SETTER_ROLE, TAKER_ROLE
        ];
    }

    function _holders() internal view returns (address[7] memory holders_) {
        holders_ = [admin, lossManager, operator, pauser, unpauser, redeemFeeSetter, taker];
    }

    function _notAuthorized(address account_, bytes32 role_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            account_,
            role_
        );
    }

    /// @dev Capacity == totalSupply so the request cannot fill and stays queued.
    function _queueDeposit(address who_, uint256 amt_) internal returns (uint256 id_) {
        _setCapacity(vault.totalSupply());
        id_ = _deposit(who_, amt_);
        ( , , uint256 shares_ ) = _depositRequest(id_);
        assertGt(shares_, 0);
    }

    /// @dev Owner cancels the whole remaining request to `recipient_`.
    function _cancelTo(address who_, uint256 id_, address recipient_)
        internal
        returns (uint256 cancelId_)
    {
        ( , , uint256 shares_ ) = _depositRequest(id_);
        vm.prank(who_);
        cancelId_ = vault.requestDepositCancellation(id_, recipient_, shares_);
    }

    /// @dev alice redeems `shares_` to bob, bob is blacklisted at settlement, so the payout lands
    ///      in `claimableAssets[bob]` through the try/catch fallback. Returns the exact USDC
    ///      amount credited.
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
    /*** Role separation                                                                        ***/
    /**********************************************************************************************/

    // Every actor holds exactly its own role; in particular the admin holds none of the hot
    // roles, so the matrix below is a genuine separation of powers.
    function test_roles_eachActorHoldsExactlyOneRole() public view {
        bytes32[7] memory roles_   = _roles();
        address[8] memory actors_  = _actors();
        address[7] memory holders_ = _holders();
        for (uint256 i; i < actors_.length; ++i) {
            for (uint256 j; j < roles_.length; ++j) {
                assertEq(vault.hasRole(roles_[j], actors_[i]), actors_[i] == holders_[j]);
            }
        }
        for (uint256 j; j < roles_.length; ++j) {
            assertEq(vault.getRoleMemberCount(roles_[j]), 1);
            assertEq(vault.getRoleMember(roles_[j], 0),   holders_[j]);
        }
    }

    function test_roles_constantsMatchHarness() public view {
        assertEq(vault.DEFAULT_ADMIN_ROLE(),     DEFAULT_ADMIN_ROLE);
        assertEq(vault.LOSS_MANAGER_ROLE(),      LOSS_MANAGER_ROLE);
        assertEq(vault.OPERATOR_ROLE(),          OPERATOR_ROLE);
        assertEq(vault.PAUSER_ROLE(),            PAUSER_ROLE);
        assertEq(vault.UNPAUSER_ROLE(),          UNPAUSER_ROLE);
        assertEq(vault.REDEEM_FEE_SETTER_ROLE(), REDEEM_FEE_SETTER_ROLE);
        assertEq(vault.TAKER_ROLE(),             TAKER_ROLE);
        assertEq(DEFAULT_ADMIN_ROLE, bytes32(0));
    }

    /**********************************************************************************************/
    /*** DEFAULT_ADMIN_ROLE functions                                                           ***/
    /**********************************************************************************************/

    function test_setMaxRedeemFeeRate_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            vm.prank(actors_[i]);
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
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            vm.prank(actors_[i]);
            vault.setMinDeposit(1e6);
        }
        assertEq(vault.minDeposit(), MIN_DEPOSIT);
    }

    function test_setMinDeposit_authorized() public {
        vm.prank(admin);
        vault.setMinDeposit(1e6);
        assertEq(vault.minDeposit(), 1e6);
    }

    function test_setMinDepositCancellation_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            vm.prank(actors_[i]);
            vault.setMinDepositCancellation(1e6);
        }
        assertEq(vault.minDepositCancellation(), MIN_DEPOSIT_CANCELLATION);
    }

    function test_setMinDepositCancellation_authorized() public {
        vm.prank(admin);
        vault.setMinDepositCancellation(1e6);
        assertEq(vault.minDepositCancellation(), 1e6);
    }

    function test_setMinRedeem_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            vm.prank(actors_[i]);
            vault.setMinRedeem(1e6);
        }
        assertEq(vault.minRedeem(), MIN_REDEEM);
    }

    function test_setMinRedeem_authorized() public {
        vm.prank(admin);
        vault.setMinRedeem(2e6);
        assertEq(vault.minRedeem(), 2e6);
    }

    function test_setVSRBounds_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            vm.prank(actors_[i]);
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

    function test_upgradeToAndCall_notAuthorized() public {
        address newImpl_ = makeAddr("newImplementation");
        address impl_    = vault.implementation();
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            vm.prank(actors_[i]);
            vault.upgradeToAndCall(newImpl_, "");
        }
        assertEq(vault.implementation(), impl_);
    }

    function test_upgradeToAndCall_authorized() public {
        address newImpl_ = address(new SparkPrimeVault());
        assertNotEq(vault.implementation(), newImpl_);

        vm.expectEmit(address(vault));
        emit IERC1967.Upgraded(newImpl_);

        vm.prank(admin);
        vault.upgradeToAndCall(newImpl_, "");

        assertEq(vault.implementation(), newImpl_);
    }

    // The authorization check runs before the implementation is validated: a bad target is
    // rejected only once the caller is the admin. A contract without `proxiableUUID` reverts
    // `ERC1967InvalidImplementation`; an EOA reverts with empty data (the return-data decode of
    // `proxiableUUID()` fails in the caller, outside the `try`).
    function test_upgradeToAndCall_invalidImplementation() public {
        address eoa_ = makeAddr("eoa");

        vm.expectRevert(_notAuthorized(stranger, DEFAULT_ADMIN_ROLE));
        vm.prank(stranger);
        vault.upgradeToAndCall(eoa_, "");
        vm.expectRevert(_notAuthorized(stranger, DEFAULT_ADMIN_ROLE));
        vm.prank(stranger);
        vault.upgradeToAndCall(address(usdc), "");

        vm.expectRevert(abi.encodeWithSelector(
            ERC1967Utils.ERC1967InvalidImplementation.selector, address(usdc)
        ));
        vm.prank(admin);
        vault.upgradeToAndCall(address(usdc), "");

        vm.expectRevert(bytes(""));
        vm.prank(admin);
        vault.upgradeToAndCall(eoa_, "");
    }

    // `upgradeToAndCall` on the implementation itself is refused before any role check.
    function test_upgradeToAndCall_notThroughProxy() public {
        SparkPrimeVault impl_ = SparkPrimeVault(vault.implementation());
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        vm.prank(admin);
        impl_.upgradeToAndCall(address(new SparkPrimeVault()), "");
    }

    // `initialize` cannot be re-run through the upgrade data path: the whole call reverts and the
    // implementation is unchanged. The implementation contract itself is locked by
    // `_disableInitializers`.
    function test_upgradeToAndCall_reinitializeReverts() public {
        address newImpl_ = address(new SparkPrimeVault());
        address impl_    = vault.implementation();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(admin);
        vault.upgradeToAndCall(
            newImpl_,
            abi.encodeCall(
                SparkPrimeVault.initialize,
                (address(spUsdc), "x", "x", stranger, 1, 1, 1)
            )
        );
        assertEq(vault.implementation(), impl_);
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, stranger));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        SparkPrimeVault(newImpl_).initialize(address(spUsdc), "x", "x", stranger, 1, 1, 1);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(address(spUsdc), "x", "x", stranger, 1, 1, 1);
    }

    function test_grantRole_notAuthorized() public {
        bytes32[7] memory roles_  = _roles();
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            for (uint256 j; j < roles_.length; ++j) {
                vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
                vm.prank(actors_[i]);
                vault.grantRole(roles_[j], alice);
                assertFalse(vault.hasRole(roles_[j], alice));
            }
        }
    }

    function test_grantRole_authorized() public {
        bytes32[7] memory roles_ = _roles();
        vm.startPrank(admin);
        for (uint256 j; j < roles_.length; ++j) {
            assertFalse(vault.hasRole(roles_[j], alice));

            vm.expectEmit(address(vault));
            emit IAccessControl.RoleGranted(roles_[j], alice, admin);
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
        bytes32[7] memory roles_  = _roles();
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            for (uint256 j; j < roles_.length; ++j) {
                vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
                vm.prank(actors_[i]);
                vault.revokeRole(roles_[j], admin);
            }
        }
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_revokeRole_authorized() public {
        bytes32[7] memory roles_   = _roles();
        address[7] memory holders_ = _holders();

        vm.startPrank(admin);
        for (uint256 j = 1; j < roles_.length; ++j) {  // every hot role, admin last below
            assertTrue(vault.hasRole(roles_[j], holders_[j]));

            vm.expectEmit(address(vault));
            emit IAccessControl.RoleRevoked(roles_[j], holders_[j], admin);
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
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        vm.prank(stranger);
        vault.renounceRole(OPERATOR_ROLE, operator);

        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        vm.prank(admin);
        vault.renounceRole(OPERATOR_ROLE, operator);

        assertTrue(vault.hasRole(OPERATOR_ROLE, operator));
    }

    function test_renounceRole_self() public {
        vm.expectEmit(address(vault));
        emit IAccessControl.RoleRevoked(OPERATOR_ROLE, operator, operator);
        vm.prank(operator);
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
        bytes32[7] memory roles_ = _roles();
        for (uint256 j; j < roles_.length; ++j) {
            assertEq(vault.getRoleAdmin(roles_[j]), DEFAULT_ADMIN_ROLE);
        }
        assertEq(vault.getRoleAdmin(keccak256("ANY_OTHER_ROLE")), DEFAULT_ADMIN_ROLE);
    }

    // A second admin granted by the first has the full admin surface, including revoking the
    // first one. It still holds none of the hot roles.
    function test_grantRole_secondAdminHasFullPower() public {
        vm.prank(admin);
        vault.grantRole(DEFAULT_ADMIN_ROLE, alice);
        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 2);
        assertEq(vault.getRoleMember(DEFAULT_ADMIN_ROLE, 0),   admin);
        assertEq(vault.getRoleMember(DEFAULT_ADMIN_ROLE, 1),   alice);

        vm.startPrank(alice);
        vault.setMinDeposit(7);
        vault.revokeRole(DEFAULT_ADMIN_ROLE, admin);
        vm.stopPrank();

        assertEq(vault.minDeposit(), 7);
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(vault.getRoleMember(DEFAULT_ADMIN_ROLE, 0),   alice);

        vm.expectRevert(_notAuthorized(admin, DEFAULT_ADMIN_ROLE));
        vm.prank(admin);
        vault.setMinDeposit(8);

        vm.expectRevert(_notAuthorized(alice, OPERATOR_ROLE));
        vm.prank(alice);
        vault.setCapacity(8);
    }

    // AccessControlEnumerable: `getRoleMember(role, i)` / `getRoleMemberCount` / `getRoleMembers`
    // agree, enumerate in grant order, swap-and-pop on revoke, and panic 0x32 out of range.
    function test_getRoleMember_enumeration() public {
        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(vault.getRoleMember(DEFAULT_ADMIN_ROLE, 0),   admin);
        assertEq(vault.getRoleMembers(DEFAULT_ADMIN_ROLE).length, 1);
        assertEq(vault.getRoleMembers(DEFAULT_ADMIN_ROLE)[0],     admin);

        bytes32[7] memory roles_   = _roles();
        address[7] memory holders_ = _holders();
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
    /*** LOSS_MANAGER_ROLE                                                                      ***/
    /**********************************************************************************************/

    // `adjustTotalAssets` is LOSS_MANAGER only (round 6: moved off the admin). The `onlyRole`
    // modifier runs before the `paused` check, so a non-manager gets the role error whether
    // paused or not, and the index never moves. The admin is one of the unauthorized actors.
    function test_adjustTotalAssets_notAuthorized() public {
        _deposit(alice, 1_000e6);
        uint192 chi_ = vault.chi();
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == lossManager) continue;
            vm.expectRevert(_notAuthorized(actors_[i], LOSS_MANAGER_ROLE));
            vm.prank(actors_[i]);
            vault.adjustTotalAssets(1e6);
            vm.expectRevert(_notAuthorized(actors_[i], LOSS_MANAGER_ROLE));
            vm.prank(actors_[i]);
            vault.adjustTotalAssets(-1e6);
        }
        assertEq(vault.chi(), chi_);

        _pause();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == lossManager) continue;
            vm.expectRevert(_notAuthorized(actors_[i], LOSS_MANAGER_ROLE));
            vm.prank(actors_[i]);
            vault.adjustTotalAssets(1e6);
            vm.expectRevert(_notAuthorized(actors_[i], LOSS_MANAGER_ROLE));
            vm.prank(actors_[i]);
            vault.adjustTotalAssets(-1e6);
        }
        assertEq(vault.chi(), chi_);
    }

    function test_adjustTotalAssets_authorized() public {
        _deposit(alice, 1_000e6);
        uint192 chi_ = vault.chi();
        _pause();
        vm.prank(lossManager);
        vault.adjustTotalAssets(1e6);
        assertGt(vault.chi(), chi_);

        vm.prank(lossManager);
        vault.adjustTotalAssets(-2e6);
        assertLt(vault.chi(), chi_);
    }

    // The role check precedes the pause check: the loss manager unpaused gets `IsNotPaused`, a
    // stranger unpaused gets the role error (nothing about the pause state leaks before
    // authorization).
    function test_adjustTotalAssets_roleCheckBeforePauseCheck() public {
        _deposit(alice, 1_000e6);
        assertFalse(vault.paused());

        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vm.prank(lossManager);
        vault.adjustTotalAssets(1e6);

        vm.expectRevert(_notAuthorized(stranger, LOSS_MANAGER_ROLE));
        vm.prank(stranger);
        vault.adjustTotalAssets(1e6);
    }

    /**********************************************************************************************/
    /*** OPERATOR_ROLE                                                                          ***/
    /**********************************************************************************************/

    // Round 6: `setCapacity` moved from the admin to the operator.
    function test_setCapacity_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == operator) continue;
            vm.expectRevert(_notAuthorized(actors_[i], OPERATOR_ROLE));
            vm.prank(actors_[i]);
            vault.setCapacity(1_000_000e6);
        }
        assertEq(vault.maxCapacity(), type(uint128).max);
    }

    function test_setCapacity_authorized() public {
        vm.prank(operator);
        vault.setCapacity(1_000_000e6);
        assertEq(vault.maxCapacity(), 1_000_000e6);
    }

    // Round 6: `setVSR` moved from VSR_SETTER to the operator.
    function test_setVSR_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == operator) continue;
            vm.expectRevert(_notAuthorized(actors_[i], OPERATOR_ROLE));
            vm.prank(actors_[i]);
            vault.setVSR(FOUR_PCT_VSR);
        }
        assertEq(vault.vsr(), RAY);
    }

    function test_setVSR_authorized() public {
        vm.prank(operator);
        vault.setVSR(FOUR_PCT_VSR);
        assertEq(vault.vsr(), FOUR_PCT_VSR);
    }

    function test_processPendingDeposits_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == operator) continue;
            vm.expectRevert(_notAuthorized(actors_[i], OPERATOR_ROLE));
            vm.prank(actors_[i]);
            vault.processPendingDeposits(type(uint256).max, 10);
        }
    }

    function test_processPendingDeposits_authorized() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        _setCapacity(type(uint128).max);
        vm.prank(operator);
        vault.processPendingDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(), id_ + 1);
        assertGt(vault.balanceOf(alice), 0);
    }

    function test_processPendingRedeems_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == operator) continue;
            vm.expectRevert(_notAuthorized(actors_[i], OPERATOR_ROLE));
            vm.prank(actors_[i]);
            vault.processPendingRedeems(type(uint256).max, 10);
        }
    }

    function test_processPendingRedeems_authorized() public {
        _deposit(alice, 100e6);
        uint256 shares_ = vault.balanceOf(alice);
        uint256 id_     = _requestRedeem(alice, shares_);
        uint256 assets_ = vault.convertToAssets(shares_);
        vm.prank(operator);
        vault.processPendingRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), id_ + 1);
        assertEq(usdc.balanceOf(alice),        assets_);
        assertApproxEqAbs(assets_, 100e6, 2);
    }

    function test_processPendingDepositCancellations_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == operator) continue;
            vm.expectRevert(_notAuthorized(actors_[i], OPERATOR_ROLE));
            vm.prank(actors_[i]);
            vault.processPendingDepositCancellations(type(uint256).max, 10);
        }
    }

    function test_processPendingDepositCancellations_authorized() public {
        uint256 id_       = _queueDeposit(alice, 100e6);
        uint256 cancelId_ = _cancelTo(alice, id_, alice);
        vm.prank(operator);
        vault.processPendingDepositCancellations(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositCancellationId(), cancelId_ + 1);
        assertEq(usdc.balanceOf(alice), 100e6 - 1);  // spUSDC redeem rounds down
    }

    /**********************************************************************************************/
    /*** TAKER_ROLE                                                                             ***/
    /**********************************************************************************************/

    function test_take_notAuthorized() public {
        _deposit(alice, 100e6);
        uint256 bal_ = _vaultSpUsdc();
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == taker) continue;
            vm.expectRevert(_notAuthorized(actors_[i], TAKER_ROLE));
            vm.prank(actors_[i]);
            vault.take(1);
        }
        assertEq(_vaultSpUsdc(), bal_);
    }

    function test_take_authorized() public {
        _deposit(alice, 100e6);
        uint256 bal_ = _vaultSpUsdc();
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Take(bal_);
        vm.prank(taker);
        vault.take(bal_);
        assertEq(spUsdc.balanceOf(taker), bal_);
        assertEq(_vaultSpUsdc(),          0);
    }

    /**********************************************************************************************/
    /*** REDEEM_FEE_SETTER_ROLE                                                                 ***/
    /**********************************************************************************************/

    function test_setRedeemFeeRate_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == redeemFeeSetter) continue;
            vm.expectRevert(_notAuthorized(actors_[i], REDEEM_FEE_SETTER_ROLE));
            vm.prank(actors_[i]);
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
    /*** PAUSER_ROLE / UNPAUSER_ROLE                                                            ***/
    /**********************************************************************************************/

    function test_pause_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == pauser) continue;
            vm.expectRevert(_notAuthorized(actors_[i], PAUSER_ROLE));
            vm.prank(actors_[i]);
            vault.pause();
        }
        assertFalse(vault.paused());
    }

    function test_pause_authorized() public {
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Paused();
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_pause_idempotent() public {
        _pause();
        assertTrue(vault.paused());
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Paused();
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());
    }

    // Round 6: `unpause` is UNPAUSER only; the admin and the pauser are among the unauthorized.
    function test_unpause_notAuthorized() public {
        _pause();
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == unpauser) continue;
            vm.expectRevert(_notAuthorized(actors_[i], UNPAUSER_ROLE));
            vm.prank(actors_[i]);
            vault.unpause();
        }
        assertTrue(vault.paused());
    }

    function test_unpause_authorized() public {
        _pause();
        assertTrue(vault.paused());
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Unpaused();
        vm.prank(unpauser);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_unpause_idempotent() public {
        assertFalse(vault.paused());
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Unpaused();
        vm.prank(unpauser);
        vault.unpause();
        assertFalse(vault.paused());
    }

    // The pauser can pause but never unpause, the unpauser can unpause but never pause, and the
    // admin can do neither: an incident always needs two separate keys to open and close.
    function test_pauseUnpause_strictSeparation() public {
        vm.expectRevert(_notAuthorized(pauser, UNPAUSER_ROLE));
        vm.prank(pauser);
        vault.unpause();

        vm.expectRevert(_notAuthorized(unpauser, PAUSER_ROLE));
        vm.prank(unpauser);
        vault.pause();

        vm.expectRevert(_notAuthorized(admin, PAUSER_ROLE));
        vm.prank(admin);
        vault.pause();

        _pause();
        vm.expectRevert(_notAuthorized(admin, UNPAUSER_ROLE));
        vm.prank(admin);
        vault.unpause();
        assertTrue(vault.paused());
    }

    /**********************************************************************************************/
    /*** Owner-only request functions                                                           ***/
    /**********************************************************************************************/

    // V2-2 / F-1 fixed: `requestDepositCancellation` is owner-only. Every role holder and a
    // stranger revert `NotRequestOwner` even when naming the owner as recipient; the entry, both
    // pending counters and the cancellation queue are untouched.
    function test_fixed_F1_requestDepositCancellation_ownerOnly() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        ( , , uint256 queued_ ) = _depositRequest(id_);
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vm.prank(actors_[i]);
            vault.requestDepositCancellation(id_, actors_[i], queued_);

            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
            vm.prank(actors_[i]);
            vault.requestDepositCancellation(id_, alice, queued_);  // owner as recipient does not help
        }
        ( , , uint256 shares_ ) = _depositRequest(id_);
        assertEq(shares_, queued_);
        assertEq(vault.pendingDepositSavingsShares(),          queued_);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_cancelledDepositQueueLength(),               0);
    }

    // The owner cancels: the entry moves to the cancellation queue, nothing is paid until the
    // operator settles it, and the owner may name any recipient but the vault.
    function test_requestDepositCancellation_owner() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        ( , , uint256 queued_ ) = _depositRequest(id_);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRequest(id_, 0, bob, queued_);
        vm.prank(alice);
        uint256 cancelId_ = vault.requestDepositCancellation(id_, bob, queued_);

        // Fully cancelled at the head: the entry is deleted and the head moves past it.
        assertEq(vault.firstPendingDepositId(), id_ + 1);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingDepositRequest(id_);
        assertEq(cancelId_, 0);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob),   0);

        ( address owner_, address recipient_, uint256 cShares_ ) = _cancelledDepositRequest(cancelId_);
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

    // Check order in `requestDepositCancellation` (:414-423): zero recipient, vault recipient,
    // id past the end (`InvalidRequestId`, no longer a panic), dead entry, caller, minimum,
    // amount above the entry. A blacklisted recipient is accepted (no `isBlacklisted` check any
    // more; the payout falls back to `claimableAssets` at settlement).
    function test_requestDepositCancellation_checkOrder() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        ( , , uint256 queued_ ) = _depositRequest(id_);
        _setMinDepositCancellation(2);

        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vm.prank(stranger);
        vault.requestDepositCancellation(type(uint256).max, address(0), queued_);

        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vm.prank(stranger);
        vault.requestDepositCancellation(type(uint256).max, address(vault), queued_);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vm.prank(stranger);
        vault.requestDepositCancellation(id_ + 1, alice, queued_);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vm.prank(alice);
        vault.requestDepositCancellation(type(uint256).max, alice, queued_);

        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vm.prank(stranger);
        vault.requestDepositCancellation(id_, alice, 0);  // owner check before the minimum

        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, 1);

        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, queued_ + 1);

        _blacklist(bob);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, bob, queued_);  // accepted
        _unblacklist(bob);

        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(alice);
        vault.requestDepositCancellation(id_, alice, queued_);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vm.prank(stranger);
        vault.requestDepositCancellation(id_, alice, queued_);
    }

    // V2-1 fixed: the three `update*Recipient` functions are owner-only. Every role holder and a
    // stranger revert `NotRequestOwner` on someone else's entry; the owner succeeds; a dead
    // entry reverts `NoRequest` before the owner check; an id past the end reverts
    // `InvalidRequestId`.
    function test_fixed_V2_1_updateRecipient_ownerOnly() public {
        _deposit(alice, 1_000e6);
        uint256 redId_ = _requestRedeem(alice, 100e6);

        _setCapacity(vault.totalSupply());
        uint256 depId_    = _deposit(bob, 100e6);
        uint256 dep2Id_   = _deposit(bob, 50e6);
        uint256 cancelId_ = _cancelTo(bob, dep2Id_, bob);

        address[8] memory actors_ = _actors();
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
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vm.prank(bob);
        vault.updateRedeemRecipient(redId_, bob);

        ( , address depRecipient_, )    = _depositRequest(depId_);
        ( , address cancelRecipient_, ) = _cancelledDepositRequest(cancelId_);
        ( , address redRecipient_, )    = _redeemRequest(redId_);
        assertEq(depRecipient_,    bob);
        assertEq(cancelRecipient_, bob);
        assertEq(redRecipient_,    alice);

        // Owners succeed; owner field is untouched, only the payout address moves.
        address payout_ = makeAddr("payout");
        vm.startPrank(bob);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositRecipientUpdated(depId_, payout_);
        vault.updateDepositRecipient(depId_, payout_);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellationRecipientUpdated(cancelId_, payout_);
        vault.updateDepositCancellationRecipient(cancelId_, payout_);
        vm.stopPrank();
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRecipientUpdated(redId_, payout_);
        vm.prank(alice);
        vault.updateRedeemRecipient(redId_, payout_);

        address depOwner_;
        address cancelOwner_;
        address redOwner_;
        ( depOwner_,    depRecipient_, )    = _depositRequest(depId_);
        ( cancelOwner_, cancelRecipient_, ) = _cancelledDepositRequest(cancelId_);
        ( redOwner_,    redRecipient_, )    = _redeemRequest(redId_);
        assertEq(depOwner_,        bob);
        assertEq(cancelOwner_,     bob);
        assertEq(redOwner_,        alice);
        assertEq(depRecipient_,    payout_);
        assertEq(cancelRecipient_, payout_);
        assertEq(redRecipient_,    payout_);

        // Dead entries: `NoRequest` for the owner and for a stranger alike.
        _cancelTo(bob, depId_, bob);
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
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.updateDepositRecipient(oob_, stranger);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.updateDepositCancellationRecipient(oob_, stranger);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.updateRedeemRecipient(oob_, stranger);
        vm.stopPrank();
    }

    // Recipient validation runs before the owner check: zero recipient and the vault itself
    // everywhere (V2-13 fixed for the vault). A blacklisted recipient and spUSDC itself are
    // accepted by all three updaters (no `isBlacklisted` check any more).
    function test_updateRecipient_recipientChecksFirst() public {
        _deposit(alice, 1_000e6);
        uint256 redId_ = _requestRedeem(alice, 100e6);
        _setCapacity(vault.totalSupply());
        uint256 depId_    = _deposit(bob, 100e6);
        uint256 dep2Id_   = _deposit(bob, 50e6);
        uint256 cancelId_ = _cancelTo(bob, dep2Id_, bob);

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
            vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
            vault.updateDepositCancellationRecipient(cancelId_, address(vault));
            vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
            vault.updateRedeemRecipient(redId_, address(vault));
            vm.stopPrank();
        }

        _blacklist(stranger);
        vm.startPrank(bob);
        vault.updateDepositCancellationRecipient(cancelId_, stranger);
        vault.updateDepositRecipient(depId_, stranger);
        vm.stopPrank();
        vm.prank(alice);
        vault.updateRedeemRecipient(redId_, stranger);

        ( , address depRecipient_, )    = _depositRequest(depId_);
        ( , address cancelRecipient_, ) = _cancelledDepositRequest(cancelId_);
        ( , address redRecipient_, )    = _redeemRequest(redId_);
        assertEq(depRecipient_,    stranger);
        assertEq(cancelRecipient_, stranger);
        assertEq(redRecipient_,    stranger);

        // spUSDC as a recipient is still accepted (open low: a donation to spUSDC holders).
        vm.prank(alice);
        vault.updateRedeemRecipient(redId_, address(spUsdc));
        ( , redRecipient_, ) = _redeemRequest(redId_);
        assertEq(redRecipient_, address(spUsdc));
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

        // A queued deposit can be cancelled (fully or partially) by its owner without any role.
        _setCapacity(vault.totalSupply());
        usdc.mint(stranger, 50e6);
        vm.prank(stranger);
        uint256 id2_ = vault.requestDeposit(50e6, stranger, 0);
        ( , , uint256 queued_ ) = _depositRequest(id2_);
        vm.prank(stranger);
        vault.requestDepositCancellation(id2_, stranger, queued_ / 2);
        ( , , uint256 left_ ) = _depositRequest(id2_);
        assertEq(left_, queued_ - queued_ / 2);
        vm.prank(stranger);
        vault.requestDepositCancellation(id2_, stranger, left_);
        assertEq(vault.firstPendingDepositId(), id2_ + 1);  // self-skipped at the head
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    // `claim(recipient)` is permissionless: any actor (admin, each hot role, a stranger) can push
    // bob's claimable USDC to bob; the caller never receives anything and the exact amount moves.
    function test_claim_permissionless() public {
        _deposit(alice, 1_000e6);
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            uint256 assets_ = _creditClaimable(10e6);
            _unblacklist(bob);
            uint256 bobBefore_    = usdc.balanceOf(bob);
            uint256 callerBefore_ = usdc.balanceOf(actors_[i]);
            uint256 vaultBefore_  = usdc.balanceOf(address(vault));
            uint256 totalBefore_  = vault.totalClaimable();

            vm.expectEmit(address(vault));
            emit ISparkPrimeVault.Claim(bob, assets_);
            vm.prank(actors_[i]);
            uint256 claimed_ = vault.claim(bob);

            assertEq(claimed_,                       assets_);
            assertEq(usdc.balanceOf(bob),            bobBefore_ + assets_);
            assertEq(usdc.balanceOf(actors_[i]),     callerBefore_);
            assertEq(usdc.balanceOf(address(vault)), vaultBefore_ - assets_);
            assertEq(vault.claimableAssets(bob),     0);
            assertEq(vault.totalClaimable(),         totalBefore_ - assets_);

            vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
            vm.prank(actors_[i]);
            vault.claim(bob);
        }
        assertEq(vault.totalClaimable(), 0);
    }

    // While bob is still blacklisted the USDC transfer reverts inside the asset and the credit is
    // preserved (state rolls back); nobody can redirect it.
    function test_claim_blacklistedRecipientReverts() public {
        _deposit(alice, 1_000e6);
        uint256 assets_ = _creditClaimable(10e6);
        assertTrue(usdc.isBlacklisted(bob));

        vm.expectRevert(BLACKLISTED);
        vm.prank(stranger);
        vault.claim(bob);
        assertEq(vault.claimableAssets(bob), assets_);
        assertEq(vault.totalClaimable(),     assets_);

        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vm.prank(stranger);
        vault.claim(stranger);

        _unblacklist(bob);
        vm.prank(stranger);
        vault.claim(bob);
        assertEq(usdc.balanceOf(bob),    assets_);
        assertEq(vault.totalClaimable(), 0);
    }

    // `drip` is permissionless and identical for every caller.
    function test_drip_permissionless() public {
        _deposit(alice, 1_000e6);
        _setPrimeVsr(FOUR_PCT_VSR);
        address[8] memory actors_ = _actors();
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

    // Removed surface at c512609: the old role constants, `realizeGain` / `realizeLoss`,
    // `cancelRedeemRequest`, the 2-arg `requestDeposit`, the 2-arg `requestDepositCancellation`
    // and the 4-arg `initialize` all miss the dispatcher (empty revert) for every actor.
    function test_fixed_removedSurface_selectorsGone() public {
        bytes[9] memory calls_ = [
            abi.encodeWithSignature("realizeGain(uint256)", 1),
            abi.encodeWithSignature("realizeLoss(uint256)", 1),
            abi.encodeWithSignature("cancelRedeemRequest(uint256,address)", 0, alice),
            abi.encodeWithSignature("requestDeposit(uint256,address)", 1, alice),
            abi.encodeWithSignature("requestDepositCancellation(uint256,address)", 0, alice),
            abi.encodeWithSignature("initialize(address,string,string,address)", spUsdc, "x", "x", alice),
            abi.encodeWithSignature("GUARDIAN_ROLE()"),
            abi.encodeWithSignature("REBALANCER_ROLE()"),
            abi.encodeWithSignature("VSR_SETTER_ROLE()")
        ];
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            for (uint256 j; j < calls_.length; ++j) {
                vm.prank(actors_[i]);
                ( bool ok_, bytes memory ret_ ) = address(vault).call(calls_[j]);
                assertFalse(ok_);
                assertEq(ret_.length, 0);
            }
        }
        // The old role names are arbitrary bytes32 values the contract does not know: holding
        // them gates nothing.
        vm.startPrank(admin);
        vault.grantRole(keccak256("GUARDIAN_ROLE"),   stranger);
        vault.grantRole(keccak256("REBALANCER_ROLE"), stranger);
        vault.grantRole(keccak256("VSR_SETTER_ROLE"), stranger);
        vm.stopPrank();
        vm.startPrank(stranger);
        vm.expectRevert(_notAuthorized(stranger, PAUSER_ROLE));
        vault.pause();
        vm.expectRevert(_notAuthorized(stranger, OPERATOR_ROLE));
        vault.processPendingDeposits(1, 1);
        vm.expectRevert(_notAuthorized(stranger, OPERATOR_ROLE));
        vault.setVSR(RAY);
        vm.stopPrank();
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
        cancelId_ = _cancelTo(bob, dep2Id_, bob);
        _fund(alice, 100e6);
        _pause();
    }

    function test_pause_blocksRequestDeposit() public {
        _pausedFixture();
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(alice);
        vault.requestDeposit(1e6, alice, 0);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(alice);
        vault.requestDeposit(1e6, alice, 1);
    }

    function test_pause_blocksRequestRedeem() public {
        _pausedFixture();
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(alice);
        vault.requestRedeem(1e6, alice);
    }

    // `onlyRole` runs before `whenNotPaused`: the operator sees `IsPaused`, a stranger sees the
    // role error.
    function test_pause_blocksProcessPendingDeposits() public {
        ( uint256 depId_, , ) = _pausedFixture();
        _setCapacity(type(uint128).max);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(operator);
        vault.processPendingDeposits(type(uint256).max, 10);
        vm.expectRevert(_notAuthorized(stranger, OPERATOR_ROLE));
        vm.prank(stranger);
        vault.processPendingDeposits(type(uint256).max, 10);
        ( , , uint256 left_ ) = _depositRequest(depId_);
        assertGt(left_, 0);
    }

    function test_pause_blocksProcessPendingRedeems() public {
        ( , , uint256 redId_ ) = _pausedFixture();
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(operator);
        vault.processPendingRedeems(type(uint256).max, 10);
        vm.expectRevert(_notAuthorized(stranger, OPERATOR_ROLE));
        vm.prank(stranger);
        vault.processPendingRedeems(type(uint256).max, 10);
        ( , , uint256 left_ ) = _redeemRequest(redId_);
        assertEq(left_, 100e6);
    }

    // R5-B / round-4 ask, fixed at c512609 (#61): the owner can cancel a queued deposit (fully
    // or partially) during the pause; nobody else can. The internal `_processPendingDeposits(0,
    // max)` walk it triggers is not pause-gated either and only advances past cancelled heads.
    function test_fixed_R5B_pause_doesNotBlockRequestDepositCancellation() public {
        ( uint256 depId_, , ) = _pausedFixture();
        ( , , uint256 queued_ ) = _depositRequest(depId_);
        uint256 head_ = vault.firstPendingDepositId();
        assertEq(head_, depId_);  // bob's live deposit is the head

        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vm.prank(stranger);
        vault.requestDepositCancellation(depId_, stranger, queued_);

        vm.prank(bob);
        uint256 c1_ = vault.requestDepositCancellation(depId_, bob, queued_ / 2);
        ( , , uint256 left_ ) = _depositRequest(depId_);
        assertEq(left_, queued_ - queued_ / 2);
        assertEq(vault.firstPendingDepositId(), head_);  // live head, walk stops

        vm.prank(bob);
        uint256 c2_ = vault.requestDepositCancellation(depId_, bob, left_);
        assertEq(c2_, c1_ + 1);
        // Fully cancelled at the head: the budget-0 walk advances past it AND past the already
        // cancelled entry behind it (dep2 from the fixture), even while paused.
        assertEq(vault.firstPendingDepositId(), head_ + 2);
        assertEq(vault.getPendingDepositRequests().length, 0);
        assertTrue(vault.paused());
    }

    // Round 6 (#61): settling cancellations is not pause-gated either, so refunds keep flowing
    // during an incident while deposits and redeems are frozen.
    function test_fixed_R5B_pause_doesNotBlockProcessPendingDepositCancellations() public {
        ( , uint256 cancelId_, ) = _pausedFixture();
        ( , , uint256 shares_ ) = _cancelledDepositRequest(cancelId_);
        assertGt(shares_, 0);

        vm.expectRevert(_notAuthorized(stranger, OPERATOR_ROLE));
        vm.prank(stranger);
        vault.processPendingDepositCancellations(type(uint256).max, 10);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.DepositCancellation(cancelId_, bob, bob, shares_, 50e6 - 1);
        vm.prank(operator);
        vault.processPendingDepositCancellations(type(uint256).max, 10);

        assertEq(vault.firstPendingDepositCancellationId(), cancelId_ + 1);
        assertEq(usdc.balanceOf(bob), 50e6 - 1);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertTrue(vault.paused());
    }

    // The recipient updates are not paused: the owner can still rewrite its own payout address
    // mid-incident; nobody else can.
    function test_pause_doesNotBlockUpdateRecipient() public {
        ( uint256 depId_, uint256 cancelId_, uint256 redId_ ) = _pausedFixture();
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

        ( , address r1_, ) = _depositRequest(depId_);
        ( , address r2_, ) = _cancelledDepositRequest(cancelId_);
        ( , address r3_, ) = _redeemRequest(redId_);
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

    // `adjustTotalAssets` is the one function that requires the pause.
    function test_pause_enablesAdjustTotalAssets() public {
        _pausedFixture();
        uint256 totalAssets_ = vault.totalAssets();
        uint256 supply_      = vault.totalSupply();
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.TotalAssetsAdjusted(uint192((totalAssets_ - 1e6) * RAY / supply_), -1e6);
        vm.prank(lossManager);
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
        ( address owner_, uint256 key_ ) = makeAddrAndKey("permitOwner");
        uint256 deadline_ = block.timestamp + 1 hours;
        bytes32 digest_ = keccak256(abi.encodePacked(
            "\x19\x01",
            vault.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(vault.PERMIT_TYPEHASH(), owner_, bob, 7, 0, deadline_))
        ));
        ( uint8 v_, bytes32 r_, bytes32 s_ ) = vm.sign(key_, digest_);
        vault.permit(owner_, bob, 7, deadline_, v_, r_, s_);
        assertEq(vault.allowance(owner_, bob), 7);
        assertEq(vault.nonces(owner_),         1);
    }

    // Every setter and the role administration keep working during the pause, each from its
    // own role: admin (minimums, max fee, bounds, roles), operator (capacity, VSR), fee setter.
    function test_pause_doesNotBlockSetters() public {
        _pausedFixture();
        vm.startPrank(admin);
        vault.setMaxRedeemFeeRate(0.005e18);
        vault.setMinDeposit(3);
        vault.setMinDepositCancellation(4);
        vault.setMinRedeem(2);
        vault.setVSRBounds(RAY, FOUR_PCT_VSR);
        vault.grantRole(OPERATOR_ROLE, alice);
        vault.revokeRole(OPERATOR_ROLE, alice);
        vm.stopPrank();
        vm.startPrank(operator);
        vault.setCapacity(5);
        vault.setVSR(FOUR_PCT_VSR);
        vm.stopPrank();
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.005e18);

        assertEq(vault.maxCapacity(),            5);
        assertEq(vault.maxRedeemFeeRate(),       0.005e18);
        assertEq(vault.minDeposit(),             3);
        assertEq(vault.minDepositCancellation(), 4);
        assertEq(vault.minRedeem(),              2);
        assertEq(vault.maxVSR(),                 FOUR_PCT_VSR);
        assertEq(vault.vsr(),                    FOUR_PCT_VSR);
        assertEq(vault.redeemFeeRate(),          0.005e18);
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

    function test_revokeOperator_queuesFrozenUntilNewOperator() public {
        _deposit(alice, 1_000e6);
        uint256 redId_ = _requestRedeem(alice, 100e6);
        _setCapacity(vault.totalSupply());
        uint256 depId_    = _deposit(bob, 100e6);
        uint256 dep2Id_   = _deposit(bob, 50e6);
        uint256 cancelId_ = _cancelTo(bob, dep2Id_, bob);
        _setCapacity(type(uint128).max);

        vm.prank(admin);
        vault.revokeRole(OPERATOR_ROLE, operator);

        vm.startPrank(operator);
        vm.expectRevert(_notAuthorized(operator, OPERATOR_ROLE));
        vault.processPendingDeposits(type(uint256).max, 10);
        vm.expectRevert(_notAuthorized(operator, OPERATOR_ROLE));
        vault.processPendingRedeems(type(uint256).max, 10);
        vm.expectRevert(_notAuthorized(operator, OPERATOR_ROLE));
        vault.processPendingDepositCancellations(type(uint256).max, 10);
        vm.expectRevert(_notAuthorized(operator, OPERATOR_ROLE));
        vault.setCapacity(1);
        vm.expectRevert(_notAuthorized(operator, OPERATOR_ROLE));
        vault.setVSR(RAY);
        vm.stopPrank();

        // All three queues are intact and frozen; bob's refund is unpaid until a successor exists.
        ( , , uint256 depShares_ )    = _depositRequest(depId_);
        ( , , uint256 cancelShares_ ) = _cancelledDepositRequest(cancelId_);
        ( , , uint256 redShares_ )    = _redeemRequest(redId_);
        assertGt(depShares_,    0);
        assertGt(cancelShares_, 0);
        assertEq(redShares_,    100e6);
        assertEq(usdc.balanceOf(bob), 0);

        // The admin cannot step in itself: it has to grant a new operator.
        vm.expectRevert(_notAuthorized(admin, OPERATOR_ROLE));
        vm.prank(admin);
        vault.processPendingRedeems(type(uint256).max, 10);

        address newOperator_ = makeAddr("newOperator");
        vm.prank(admin);
        vault.grantRole(OPERATOR_ROLE, newOperator_);

        vm.startPrank(newOperator_);
        vault.processPendingDeposits(type(uint256).max, 10);
        vault.processPendingRedeems(type(uint256).max, 10);
        vault.processPendingDepositCancellations(type(uint256).max, 10);
        vm.stopPrank();

        assertEq(vault.firstPendingDepositId(),             dep2Id_ + 1);  // past the cancelled dep2
        assertEq(vault.firstPendingDepositCancellationId(), cancelId_ + 1);
        assertEq(vault.firstPendingRedeemId(),              redId_ + 1);
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

        vm.expectRevert(_notAuthorized(taker, TAKER_ROLE));
        vm.prank(taker);
        vault.take(0);

        // Return is a plain ERC20 transfer; no role needed.
        vm.prank(taker);
        spUsdc.transfer(address(vault), bal_);
        assertEq(_vaultSpUsdc(),          bal_);
        assertEq(spUsdc.balanceOf(taker), 0);

        uint256 shares_ = vault.balanceOf(alice);
        uint256 redId_  = _requestRedeem(alice, shares_);
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), redId_ + 1);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000e6, 2);
    }

    // A revoked pauser loses pause; the unpauser can still unpause.
    function test_revokePauser_whilePaused_unpauserCanStillUnpause() public {
        _deposit(alice, 1_000e6);
        _pause();
        vm.prank(admin);
        vault.revokeRole(PAUSER_ROLE, pauser);
        assertTrue(vault.paused());

        vm.expectRevert(_notAuthorized(pauser, PAUSER_ROLE));
        vm.prank(pauser);
        vault.pause();

        _unpause();
        assertFalse(vault.paused());
    }

    // Losing the unpauser mid-incident leaves the vault paused until the admin appoints a new
    // one: the admin cannot unpause itself. Requests and the deposit / redeem queues stay
    // frozen meanwhile; cancellations, claims and `take` do not.
    function test_revokeUnpauser_whilePaused_adminMustAppointSuccessor() public {
        _deposit(alice, 1_000e6);
        _pause();
        vm.prank(admin);
        vault.revokeRole(UNPAUSER_ROLE, unpauser);

        vm.expectRevert(_notAuthorized(unpauser, UNPAUSER_ROLE));
        vm.prank(unpauser);
        vault.unpause();
        vm.expectRevert(_notAuthorized(admin, UNPAUSER_ROLE));
        vm.prank(admin);
        vault.unpause();
        vm.expectRevert(_notAuthorized(pauser, UNPAUSER_ROLE));
        vm.prank(pauser);
        vault.unpause();
        assertTrue(vault.paused());

        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(alice);
        vault.requestRedeem(1e6, alice);

        address newUnpauser_ = makeAddr("newUnpauser");
        vm.prank(admin);
        vault.grantRole(UNPAUSER_ROLE, newUnpauser_);
        vm.prank(newUnpauser_);
        vault.unpause();
        assertFalse(vault.paused());
    }

    // A revoked operator leaves the live rate in force (C-7 flavour): only a new operator, not
    // the admin, can change `vsr`.
    function test_revokeOperator_rateStaysInForce() public {
        _deposit(alice, 1_000e6);
        _setPrimeVsr(TEN_PCT_VSR);
        vm.prank(admin);
        vault.revokeRole(OPERATOR_ROLE, operator);

        vm.expectRevert(_notAuthorized(admin, OPERATOR_ROLE));
        vm.prank(admin);
        vault.setVSR(RAY);

        uint256 before_ = vault.assetsOf(alice);
        _warpAndDrip(365 days);
        assertGt(vault.assetsOf(alice), before_ * 109 / 100);
        assertEq(vault.vsr(), TEN_PCT_VSR);
    }

    // A revoked loss manager during the pause: the index can no longer be written, the pause
    // can still be lifted by the unpauser, and the admin cannot write the index itself.
    function test_revokeLossManager_whilePaused_indexFrozen() public {
        _deposit(alice, 1_000e6);
        _pause();
        uint192 chi_ = vault.chi();
        vm.prank(admin);
        vault.revokeRole(LOSS_MANAGER_ROLE, lossManager);

        vm.expectRevert(_notAuthorized(lossManager, LOSS_MANAGER_ROLE));
        vm.prank(lossManager);
        vault.adjustTotalAssets(-1e6);
        vm.expectRevert(_notAuthorized(admin, LOSS_MANAGER_ROLE));
        vm.prank(admin);
        vault.adjustTotalAssets(-1e6);
        assertEq(vault.chi(), chi_);

        _unpause();
        assertFalse(vault.paused());
    }

    /**********************************************************************************************/
    /*** V2-8: admin can vanish                                                                 ***/
    /**********************************************************************************************/

    // V2-8 (open): the only DEFAULT_ADMIN can renounce and leave the vault without any admin
    // forever: no upgrade, no role changes, no minimum / bound / max-fee changes. Round 6 softens
    // the blast radius: the hot roles keep working (the unpauser can still unpause, the operator
    // still processes), but none of them can ever be rotated, so the loss of any one hot key is
    // then permanent. Proven while paused with a queued redeem.
    function test_BUG_V2_8_lastAdminCanRenounce() public {
        _deposit(alice, 1_000e6);
        uint256 redId_ = _requestRedeem(alice, 100e6);
        _pause();
        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);

        vm.expectEmit(address(vault));
        emit IAccessControl.RoleRevoked(DEFAULT_ADMIN_ROLE, admin, admin);
        vm.prank(admin);
        vault.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        assertEq(vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 0);
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));

        address newImpl_ = address(new SparkPrimeVault());
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            vm.startPrank(actors_[i]);
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            vault.upgradeToAndCall(newImpl_, "");
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            vault.grantRole(DEFAULT_ADMIN_ROLE, actors_[i]);
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            vault.grantRole(UNPAUSER_ROLE, actors_[i]);
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            vault.revokeRole(TAKER_ROLE, taker);
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            vault.setMinDeposit(1);
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            vault.setVSRBounds(RAY, RAY);
            vm.stopPrank();
        }

        // Hot roles still function...
        vm.prank(lossManager);
        vault.adjustTotalAssets(-1);
        _unpause();
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), redId_ + 1);

        // ...but cannot be rotated: once the unpauser renounces, the next pause is permanent.
        vm.prank(unpauser);
        vault.renounceRole(UNPAUSER_ROLE, unpauser);
        _pause();
        for (uint256 i; i < actors_.length; ++i) {
            vm.expectRevert(_notAuthorized(actors_[i], UNPAUSER_ROLE));
            vm.prank(actors_[i]);
            vault.unpause();
        }
        assertTrue(vault.paused());

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

        vm.expectRevert(_notAuthorized(admin, DEFAULT_ADMIN_ROLE));
        vm.prank(admin);
        vault.grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // V2-8 (open): `initialize(..., address(0), 1, 1, 1)` is accepted. The zero address is the
    // only admin member: no role can ever be granted, so no pauser, operator or unpauser exists
    // and no upgrade is possible, from block one.
    function test_BUG_V2_8_zeroAdminAtInit() public {
        SparkPrimeVault fresh_ = SparkPrimeVault(address(new ERC1967Proxy(
            address(new SparkPrimeVault()),
            abi.encodeCall(
                SparkPrimeVault.initialize,
                (address(spUsdc), "Spark Prime USDC", "spPRIME", address(0), 1, 1, 1)
            )
        )));

        assertTrue(fresh_.hasRole(DEFAULT_ADMIN_ROLE, address(0)));
        assertEq(fresh_.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(fresh_.getRoleMember(DEFAULT_ADMIN_ROLE, 0),   address(0));
        assertFalse(fresh_.hasRole(DEFAULT_ADMIN_ROLE, admin));

        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            vm.startPrank(actors_[i]);
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            fresh_.setMinDeposit(1);
            vm.expectRevert(_notAuthorized(actors_[i], DEFAULT_ADMIN_ROLE));
            fresh_.grantRole(PAUSER_ROLE, actors_[i]);
            vm.expectRevert(_notAuthorized(actors_[i], PAUSER_ROLE));
            fresh_.pause();
            vm.expectRevert(_notAuthorized(actors_[i], OPERATOR_ROLE));
            fresh_.setCapacity(1);
            vm.stopPrank();
        }
        assertEq(fresh_.maxCapacity(), 0);
    }

}
