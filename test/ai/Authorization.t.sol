// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../../lib/forge-std/src/StdError.sol";

import { IAccessControl } from "../../lib/oz/contracts/access/IAccessControl.sol";

import { SparkPrimeVault } from "../../src/SparkPrimeVault.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

/// @dev Authorization matrix, pause scope and mid-flight role revocation for `SparkPrimeVault`
///      on `refactor/more-simplifying`. Every role-gated function is exercised by all seven role
///      holders plus a stranger: the authorized actor succeeds, every other actor reverts with the
///      exact OZ custom error. Round 2 changes: `realizeLoss` replaces `setChi`,
///      `setMinDeposit`/`setMinRedeem` replace `setMinimums`, `processPendingDepositCancellations` is a
///      new REBALANCER entry point. `pause` is GUARDIAN again as of 0bc9288. Round 3 (ff828d2):
///      the three `update*Recipient` functions are owner-only and `realizeGain` is a new
///      DEFAULT_ADMIN entry point that is not gated on `paused`.
contract AuthorizationTest is LocalTestBase {

    event Paused();
    event Unpaused();
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address stranger = makeAddr("stranger");

    // All actors that hold exactly one role, plus a stranger with none.
    function _actors() internal view returns (address[8] memory actors_) {
        actors_ = [admin, guardian, rebalancer, riskManager, setter, taker, unpauser, stranger];
    }

    function _expectUnauthorized(address caller_, bytes32 role_) internal {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            caller_,
            role_
        ));
    }

    /**********************************************************************************************/
    /*** DEFAULT_ADMIN_ROLE functions                                                           ***/
    /**********************************************************************************************/

    function test_setCapacity_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.setCapacity(1_000_000e6);
        }
    }

    function test_setCapacity_authorized() public {
        vm.prank(admin);
        vault.setCapacity(1_000_000e6);
        assertEq(vault.maxCapacity(), 1_000_000e6);
    }

    function test_setMaxRedeemFee_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.setMaxRedeemFeeRate(0.005e18);
        }
    }

    function test_setMaxRedeemFee_authorized() public {
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.005e18);
        assertEq(vault.maxRedeemFeeRate(), 0.005e18);
    }

    function test_setMinDeposit_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.setMinDeposit(1e6);
        }
    }

    function test_setMinDeposit_authorized() public {
        vm.prank(admin);
        vault.setMinDeposit(1e6);
        assertEq(vault.minDeposit(), 1e6);
    }

    function test_setMinRedeem_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.setMinRedeem(1e6);
        }
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
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.setVSRBounds(RAY, FOUR_PCT_VSR);
        }
    }

    function test_setVSRBounds_authorized() public {
        vm.prank(admin);
        vault.setVSRBounds(ONE_PCT_VSR, FOUR_PCT_VSR);
        assertEq(vault.minVSR(), ONE_PCT_VSR);
        assertEq(vault.maxVSR(), FOUR_PCT_VSR);
    }

    // Round 3: `realizeGain` is DEFAULT_ADMIN only and does not require `paused`.
    function test_realizeGain_notAuthorized() public {
        _deposit(alice, 1_000e6);
        uint192 chi_ = vault.chi();
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.realizeGain(1e6);
        }
        assertEq(vault.chi(), chi_);

        // Same answer while paused: the gate is the role, not the pause flag.
        _pause();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.realizeGain(1e6);
        }
        assertEq(vault.chi(), chi_);
    }

    function test_realizeGain_authorized() public {
        _deposit(alice, 1_000e6);
        uint192 chi_ = vault.chi();
        assertFalse(vault.paused());
        vm.prank(admin);
        vault.realizeGain(1e6);
        assertGt(vault.chi(), chi_);
    }

    function test_unpause_notAuthorized() public {
        _pause();
        address[8] memory actors_ = _actors();
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

    // I-3: UNPAUSER_ROLE is declared and granted but `unpause` is gated on DEFAULT_ADMIN_ROLE.
    function test_unpause_unpauserRoleCannotUnpause() public {
        _pause();
        assertTrue(vault.hasRole(UNPAUSER_ROLE, unpauser));

        vm.prank(unpauser);
        _expectUnauthorized(unpauser, DEFAULT_ADMIN_ROLE);
        vault.unpause();

        assertTrue(vault.paused());
    }

    function test_upgradeToAndCall_notAuthorized() public {
        address newImpl_ = makeAddr("newImplementation");
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.upgradeToAndCall(newImpl_, "");
        }
    }

    function test_upgradeToAndCall_authorized() public {
        address newImpl_ = address(new SparkPrimeVault());
        vm.prank(admin);
        vault.upgradeToAndCall(newImpl_, "");
        assertEq(vault.implementation(), newImpl_);
    }

    function test_grantRole_notAuthorized() public {
        bytes32[7] memory roles_ = [
            DEFAULT_ADMIN_ROLE, GUARDIAN_ROLE, REBALANCER_ROLE, RISK_MANAGER_ROLE,
            SETTER_ROLE, TAKER_ROLE, UNPAUSER_ROLE
        ];
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            for (uint256 j; j < roles_.length; ++j) {
                vm.prank(actors_[i]);
                _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
                vault.grantRole(roles_[j], alice);
            }
        }
    }

    function test_grantRole_authorized() public {
        bytes32[7] memory roles_ = [
            DEFAULT_ADMIN_ROLE, GUARDIAN_ROLE, REBALANCER_ROLE, RISK_MANAGER_ROLE,
            SETTER_ROLE, TAKER_ROLE, UNPAUSER_ROLE
        ];
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

    function test_revokeRole_notAuthorized() public {
        bytes32[7] memory roles_ = [
            DEFAULT_ADMIN_ROLE, GUARDIAN_ROLE, REBALANCER_ROLE, RISK_MANAGER_ROLE,
            SETTER_ROLE, TAKER_ROLE, UNPAUSER_ROLE
        ];
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            for (uint256 j; j < roles_.length; ++j) {
                vm.prank(actors_[i]);
                _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
                vault.revokeRole(roles_[j], admin);
            }
        }
    }

    function test_revokeRole_authorized() public {
        bytes32[6]  memory roles_ = [
            GUARDIAN_ROLE, REBALANCER_ROLE, RISK_MANAGER_ROLE, SETTER_ROLE, TAKER_ROLE,
            UNPAUSER_ROLE
        ];
        address[6] memory holders_ = [guardian, rebalancer, riskManager, setter, taker, unpauser];

        vm.startPrank(admin);
        for (uint256 j; j < roles_.length; ++j) {
            assertTrue(vault.hasRole(roles_[j], holders_[j]));

            vm.expectEmit(address(vault));
            emit RoleRevoked(roles_[j], holders_[j], admin);
            vault.revokeRole(roles_[j], holders_[j]);

            assertFalse(vault.hasRole(roles_[j], holders_[j]));
            assertEq(vault.getRoleMembers(roles_[j]).length, 0);
        }
        vm.stopPrank();
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    // Anyone can renounce their own role; renouncing for someone else reverts.
    function test_renounceRole_badConfirmation() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlBadConfirmation.selector));
        vault.renounceRole(SETTER_ROLE, setter);

        assertTrue(vault.hasRole(SETTER_ROLE, setter));
    }

    function test_renounceRole_self() public {
        vm.prank(setter);
        vm.expectEmit(address(vault));
        emit RoleRevoked(SETTER_ROLE, setter, setter);
        vault.renounceRole(SETTER_ROLE, setter);

        assertFalse(vault.hasRole(SETTER_ROLE, setter));
    }

    /**********************************************************************************************/
    /*** SETTER_ROLE                                                                            ***/
    /**********************************************************************************************/

    function test_setVSR_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == setter) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], SETTER_ROLE);
            vault.setVSR(FOUR_PCT_VSR);
        }
    }

    function test_setVSR_authorized() public {
        vm.prank(setter);
        vault.setVSR(FOUR_PCT_VSR);
        assertEq(vault.vsr(), FOUR_PCT_VSR);
    }

    /**********************************************************************************************/
    /*** TAKER_ROLE                                                                             ***/
    /**********************************************************************************************/

    function test_take_notAuthorized() public {
        _deposit(alice, 100e6);
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == taker) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], TAKER_ROLE);
            vault.take(1);
        }
    }

    function test_take_authorized() public {
        _deposit(alice, 100e6);
        uint256 bal_ = _vaultSpUsdc();
        vm.prank(taker);
        vault.take(bal_);
        assertEq(spUsdc.balanceOf(taker), bal_);
        assertEq(_vaultSpUsdc(),          0);
    }

    /**********************************************************************************************/
    /*** REBALANCER_ROLE                                                                        ***/
    /**********************************************************************************************/

    function test_processPendingDeposits_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == rebalancer) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], REBALANCER_ROLE);
            vault.processPendingDeposits(type(uint256).max, 10);
        }
    }

    function test_processPendingDeposits_authorized() public {
        vm.prank(rebalancer);
        vault.processPendingDeposits(type(uint256).max, 10);
    }

    function test_processPendingRedeems_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == rebalancer) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], REBALANCER_ROLE);
            vault.processPendingRedeems(type(uint256).max, 10);
        }
    }

    function test_processPendingRedeems_authorized() public {
        vm.prank(rebalancer);
        vault.processPendingRedeems(type(uint256).max, 10);
    }

    function test_processPendingDepositCancellations_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == rebalancer) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], REBALANCER_ROLE);
            vault.processPendingDepositCancellations(type(uint256).max, 10);
        }
    }

    function test_processPendingDepositCancellations_authorized() public {
        vm.prank(rebalancer);
        vault.processPendingDepositCancellations(type(uint256).max, 10);
    }

    /**********************************************************************************************/
    /*** RISK_MANAGER_ROLE                                                                      ***/
    /**********************************************************************************************/

    function test_setRedeemFee_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == riskManager) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], RISK_MANAGER_ROLE);
            vault.setRedeemFeeRate(0.001e18);
        }
    }

    function test_setRedeemFee_authorized() public {
        vm.prank(riskManager);
        vault.setRedeemFeeRate(0.001e18);
        assertEq(vault.redeemFeeRate(), 0.001e18);
    }

    function test_realizeLoss_notAuthorized() public {
        _deposit(alice, 1_000e6);
        _pause();
        uint192 chi_ = vault.chi();
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == riskManager) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], RISK_MANAGER_ROLE);
            vault.realizeLoss(1e6);
        }
        assertEq(vault.chi(), chi_);
    }

    function test_realizeLoss_authorized() public {
        _deposit(alice, 1_000e6);
        _pause();
        uint192 chi_ = vault.chi();
        vm.prank(riskManager);
        vault.realizeLoss(1e6);
        assertLt(vault.chi(), chi_);
    }

    /**********************************************************************************************/
    /*** GUARDIAN_ROLE                                                                          ***/
    /**********************************************************************************************/

    function test_pause_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == guardian) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], GUARDIAN_ROLE);
            vault.pause();
        }
        assertFalse(vault.paused());
    }

    function test_pause_authorized() public {
        vm.prank(guardian);
        vm.expectEmit(address(vault));
        emit Paused();
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_pause_idempotent() public {
        _pause();
        assertTrue(vault.paused());
        vm.prank(guardian);
        vm.expectEmit(address(vault));
        emit Paused();
        vault.pause();
        assertTrue(vault.paused());
    }

    /**********************************************************************************************/
    /*** Cancel functions: owner or GUARDIAN_ROLE                                               ***/
    /**********************************************************************************************/

    function _queueDeposit(address who_, uint256 amt_) internal returns (uint256 id_) {
        // Capacity == totalSupply so the request cannot fill and stays queued.
        _setCapacity(vault.totalSupply());
        id_ = _deposit(who_, amt_);
        (, , uint256 shares_) = _depositRequest(id_);
        assertGt(shares_, 0);
    }

    function test_requestDepositCancellation_notAuthorized() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == guardian) continue;
            vm.prank(actors_[i]);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.requestDepositCancellation(id_, actors_[i]);
        }
        (, , uint256 shares_) = _depositRequest(id_);
        assertGt(shares_, 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // Round 2: cancel no longer pays; it moves the entry to the cancelled-deposit queue and the
    // rebalancer settles it with `processPendingDepositCancellations`.
    function test_requestDepositCancellation_owner() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        (, , uint256 queued_) = _depositRequest(id_);

        vm.prank(alice);
        uint256 cancelId_ = vault.requestDepositCancellation(id_, alice);

        (, , uint256 shares_) = _depositRequest(id_);
        assertEq(shares_,   0);
        assertEq(cancelId_, 0);
        assertEq(usdc.balanceOf(alice), 0);  // Nothing paid yet

        (address owner_, address recipient_, uint256 cShares_) = _cancelledDepositRequest(cancelId_);
        assertEq(owner_,     alice);
        assertEq(recipient_, alice);
        assertEq(cShares_,   queued_);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), queued_);

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 100e6 - 1);  // spUSDC redeem rounds down
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // Guardian cancel with a guardian-chosen recipient: the refund goes to `recipient_` on
    // settlement (F-1 regression, CANCEL-FEES owns the finding; asserted here for the matrix).
    function test_requestDepositCancellation_guardian() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        vm.prank(guardian);
        uint256 cancelId_ = vault.requestDepositCancellation(id_, guardian);

        (, , uint256 shares_) = _depositRequest(id_);
        assertEq(shares_, 0);

        (address owner_, address recipient_, ) = _cancelledDepositRequest(cancelId_);
        assertEq(owner_,     alice);
        assertEq(recipient_, guardian);

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice),    0);
        assertEq(usdc.balanceOf(guardian), 100e6 - 1);
    }

    function test_cancelRedeemRequest_notAuthorized() public {
        _deposit(alice, 100e6);
        uint256 shares_ = vault.balanceOf(alice);
        uint256 id_     = _requestRedeem(alice, shares_);
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == guardian) continue;
            vm.prank(actors_[i]);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.cancelRedeemRequest(id_, actors_[i]);
        }
        assertEq(vault.pendingRedeemShares(), shares_);
    }

    function test_cancelRedeemRequest_owner() public {
        _deposit(alice, 100e6);
        uint256 shares_ = vault.balanceOf(alice);
        uint256 id_     = _requestRedeem(alice, shares_);
        vm.prank(alice);
        vault.cancelRedeemRequest(id_, alice);
        assertEq(vault.balanceOf(alice),      shares_);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    // Guardian cancel with a guardian-chosen recipient: escrowed shares go to `recipient_`
    // (F-1 regression, CANCEL-FEES owns the finding; asserted here for the matrix).
    function test_cancelRedeemRequest_guardian() public {
        _deposit(alice, 100e6);
        uint256 shares_ = vault.balanceOf(alice);
        uint256 id_     = _requestRedeem(alice, shares_);
        vm.prank(guardian);
        vault.cancelRedeemRequest(id_, guardian);
        assertEq(vault.balanceOf(alice),      0);
        assertEq(vault.balanceOf(guardian),   shares_);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    /**********************************************************************************************/
    /*** Permissionless functions                                                               ***/
    /**********************************************************************************************/

    function test_permissionless_stranger() public {
        _fund(stranger, 200e6);

        vm.startPrank(stranger);
        uint256 id0_ = vault.requestDeposit(100e6, stranger);
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
        vault.cancelRedeemRequest(rid_, stranger);
        vault.drip();
        vm.stopPrank();

        assertEq(vault.balanceOf(stranger), shares_ - 2);
        assertEq(vault.balanceOf(bob),      2);

        // A queued deposit can be cancelled by its owner without any role.
        _setCapacity(vault.totalSupply());
        usdc.mint(stranger, 50e6);
        vm.prank(stranger);
        uint256 id2_ = vault.requestDeposit(50e6, stranger);
        vm.prank(stranger);
        vault.requestDepositCancellation(id2_, stranger);
        (, , uint256 left_) = _depositRequest(id2_);
        assertEq(left_, 0);
    }

    // Round 3 (R2-7 fixed): `updateDepositRecipient`, `updateDepositCancellationRecipient` and
    // `updateRedeemRecipient` are owner-only. Every role holder (admin and guardian included)
    // and a stranger revert `not-authorized` on someone else's entry; the owner succeeds; a dead
    // entry reverts `no-request` before the owner check; an out-of-range id panics (0x32).
    function test_updateRecipient_ownerOnly() public {
        _deposit(alice, 1_000e6);
        uint256 redId_ = _requestRedeem(alice, 100e6);

        _setCapacity(vault.totalSupply());
        uint256 depId_  = _deposit(bob, 100e6);
        uint256 dep2Id_ = _deposit(bob, 50e6);
        vm.prank(bob);
        uint256 cancelId_ = vault.requestDepositCancellation(dep2Id_, bob);

        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            vm.startPrank(actors_[i]);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.updateDepositRecipient(depId_, actors_[i]);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.updateDepositCancellationRecipient(cancelId_, actors_[i]);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.updateRedeemRecipient(redId_, actors_[i]);
            vm.stopPrank();
        }

        // The other depositor is not authorized either (owner check, not "any owner").
        vm.startPrank(alice);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositRecipient(depId_, alice);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositCancellationRecipient(cancelId_, alice);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/not-authorized");
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

        // Dead entries: `no-request` for the owner and for a stranger alike (checked before
        // the owner check, so a stranger learns nothing beyond "empty").
        vm.prank(bob);
        vault.requestDepositCancellation(depId_, bob);
        vm.prank(alice);
        vault.cancelRedeemRequest(redId_, alice);
        _processCancelledDeposits(type(uint256).max, 10);

        address[2] memory callers_ = [bob, stranger];
        for (uint256 i; i < callers_.length; ++i) {
            vm.startPrank(callers_[i]);
            vm.expectRevert("SparkPrimeVault/no-request");
            vault.updateDepositRecipient(depId_, callers_[i]);
            vm.expectRevert("SparkPrimeVault/no-request");
            vault.updateDepositCancellationRecipient(cancelId_, callers_[i]);
            vm.expectRevert("SparkPrimeVault/no-request");
            vault.updateRedeemRecipient(redId_, callers_[i]);
            vm.stopPrank();
        }

        // Out of range: array index panic, no custom message.
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

    // The zero-recipient check runs first, for the owner and for a stranger alike.
    function test_updateRecipient_zeroRecipient() public {
        _deposit(alice, 1_000e6);
        uint256 redId_ = _requestRedeem(alice, 100e6);
        _setCapacity(vault.totalSupply());
        uint256 depId_  = _deposit(bob, 100e6);
        uint256 dep2Id_ = _deposit(bob, 50e6);
        vm.prank(bob);
        uint256 cancelId_ = vault.requestDepositCancellation(dep2Id_, bob);

        vm.startPrank(stranger);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateDepositRecipient(depId_, address(0));
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateDepositCancellationRecipient(cancelId_, address(0));
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateRedeemRecipient(redId_, address(0));
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateDepositRecipient(depId_, address(0));
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateDepositCancellationRecipient(cancelId_, address(0));
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-recipient");
        vault.updateRedeemRecipient(redId_, address(0));
    }

    /**********************************************************************************************/
    /*** Pause scope                                                                            ***/
    /**********************************************************************************************/

    // alice holds shares, a deposit is queued (bob), a cancelled deposit awaits settlement (bob),
    // a redeem is queued (alice), then the guardian pauses.
    function _pausedFixture()
        internal
        returns (uint256 depId_, uint256 cancelId_, uint256 redId_)
    {
        _deposit(alice, 1_000e6);
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
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(1e6, alice);
    }

    function test_pause_blocksRequestDepositWithReferral() public {
        _pausedFixture();
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDeposit(1e6, alice, 1);
    }

    function test_pause_blocksDepositCancellationRequest() public {
        (uint256 depId_, , ) = _pausedFixture();
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDepositCancellation(depId_, bob);
        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestDepositCancellation(depId_, bob);
    }

    function test_pause_blocksRequestRedeem() public {
        _pausedFixture();
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestRedeem(1e6, alice);
    }

    function test_pause_blocksCancelRedeemRequest() public {
        (, , uint256 redId_) = _pausedFixture();
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelRedeemRequest(redId_, alice);
        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelRedeemRequest(redId_, alice);
    }

    function test_pause_blocksProcessDepositQueue() public {
        _pausedFixture();
        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processPendingDeposits(type(uint256).max, 10);
    }

    function test_pause_blocksProcessRedeemQueue() public {
        _pausedFixture();
        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processPendingRedeems(type(uint256).max, 10);
    }

    function test_pause_blocksProcessCancelledDepositQueue() public {
        (, uint256 cancelId_, ) = _pausedFixture();
        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processPendingDepositCancellations(type(uint256).max, 10);
        (, , uint256 left_) = _cancelledDepositRequest(cancelId_);
        assertGt(left_, 0);
    }

    // The recipient updates are not paused: the owner can still rewrite its own payout address
    // mid-incident; nobody else can (round 3).
    function test_pause_doesNotBlockUpdateRecipient() public {
        (uint256 depId_, uint256 cancelId_, uint256 redId_) = _pausedFixture();
        address payout_ = makeAddr("payout");

        vm.startPrank(stranger);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositRecipient(depId_, stranger);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.updateDepositCancellationRecipient(cancelId_, stranger);
        vm.expectRevert("SparkPrimeVault/not-authorized");
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

    function test_pause_doesNotBlockTake() public {
        _pausedFixture();
        uint256 bal_ = _vaultSpUsdc();
        assertGt(bal_, 0);
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

    function test_pause_doesNotBlockSetVSR() public {
        _pausedFixture();
        vm.prank(setter);
        vault.setVSR(FOUR_PCT_VSR);
        assertEq(vault.vsr(), FOUR_PCT_VSR);
    }

    function test_pause_doesNotBlockRealizeLoss() public {
        _pausedFixture();
        uint256 totalAssets_ = vault.totalAssets();
        uint256 supply_      = vault.totalSupply();
        vm.prank(riskManager);
        vault.realizeLoss(1e6);
        assertEq(vault.chi(), (totalAssets_ - 1e6) * RAY / supply_);
    }

    // Round 3: `realizeGain` has no pause requirement either way (see Admin.t.sol for unpaused).
    function test_pause_doesNotBlockRealizeGain() public {
        _pausedFixture();
        uint256 totalAssets_ = vault.totalAssets();
        uint256 supply_      = vault.totalSupply();
        vm.prank(admin);
        vault.realizeGain(1e6);
        assertEq(vault.chi(), (totalAssets_ + 1e6) * RAY / supply_);
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
    }

    function test_pause_doesNotBlockAdminSetters() public {
        _pausedFixture();
        vm.startPrank(admin);
        vault.setCapacity(5);
        vault.setMaxRedeemFeeRate(0.005e18);
        vault.setMinDeposit(1);
        vault.setMinRedeem(2);
        vault.setVSRBounds(RAY, FOUR_PCT_VSR);
        vault.grantRole(SETTER_ROLE, alice);
        vault.revokeRole(SETTER_ROLE, alice);
        vm.stopPrank();
        vm.prank(riskManager);
        vault.setRedeemFeeRate(0.005e18);

        assertEq(vault.maxCapacity(),   5);
        assertEq(vault.maxRedeemFeeRate(),  0.005e18);
        assertEq(vault.minDeposit(),    1);
        assertEq(vault.minRedeem(),     2);
        assertEq(vault.maxVSR(),        FOUR_PCT_VSR);
        assertEq(vault.redeemFeeRate(),     0.005e18);
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
        vault.revokeRole(REBALANCER_ROLE, rebalancer);

        vm.prank(rebalancer);
        _expectUnauthorized(rebalancer, REBALANCER_ROLE);
        vault.processPendingDeposits(type(uint256).max, 10);

        vm.prank(rebalancer);
        _expectUnauthorized(rebalancer, REBALANCER_ROLE);
        vault.processPendingRedeems(type(uint256).max, 10);

        vm.prank(rebalancer);
        _expectUnauthorized(rebalancer, REBALANCER_ROLE);
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
        vault.grantRole(REBALANCER_ROLE, newRebalancer_);

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

        // The vault can pay redeems again.
        uint256 redId_ = _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems(type(uint256).max, 10);
        (, , uint256 left_) = _redeemRequest(redId_);
        assertEq(left_, 0);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000e6, 2);
    }

    // A revoked guardian loses pause and the compliance cancels; the admin can still unpause.
    function test_revokeGuardian_whilePaused_adminCanStillUnpause() public {
        _deposit(alice, 1_000e6);
        uint256 redId_ = _requestRedeem(alice, 100e6);
        _pause();
        vm.prank(admin);
        vault.revokeRole(GUARDIAN_ROLE, guardian);
        assertTrue(vault.paused());

        vm.prank(guardian);
        _expectUnauthorized(guardian, GUARDIAN_ROLE);
        vault.pause();

        _unpause();
        assertFalse(vault.paused());

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelRedeemRequest(redId_, alice);
    }

    // C-4: the only DEFAULT_ADMIN can renounce and leave the vault without any admin forever:
    // no unpause, no upgrade, no role changes. Proven while paused: paused for good.
    function test_renounceDefaultAdmin_vaultHasNoAdminForever() public {
        _deposit(alice, 1_000e6);
        _pause();
        assertEq(vault.getRoleMembers(DEFAULT_ADMIN_ROLE).length, 1);

        vm.prank(admin);
        vault.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        assertEq(vault.getRoleMembers(DEFAULT_ADMIN_ROLE).length, 0);
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));

        address newImpl_ = address(new SparkPrimeVault());
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.unpause();

            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.upgradeToAndCall(newImpl_, "");

            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.grantRole(DEFAULT_ADMIN_ROLE, actors_[i]);

            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.realizeGain(1e6);
        }
        assertTrue(vault.paused());
    }

    // Same outcome through revokeRole on self (no confirmation argument at all).
    function test_revokeDefaultAdmin_self_vaultHasNoAdminForever() public {
        vm.prank(admin);
        vault.revokeRole(DEFAULT_ADMIN_ROLE, admin);
        assertEq(vault.getRoleMembers(DEFAULT_ADMIN_ROLE).length, 0);

        vm.prank(admin);
        _expectUnauthorized(admin, DEFAULT_ADMIN_ROLE);
        vault.grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

}
