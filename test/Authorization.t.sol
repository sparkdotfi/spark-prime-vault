// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl } from "../lib/oz/contracts/access/IAccessControl.sol";

import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

/// @dev Authorization matrix, pause scope and mid-flight role revocation for `SparkPrimeVault`.
///      Every role-gated function is exercised by all seven role holders plus a stranger: the
///      authorized actor succeeds, every other actor reverts with the exact OZ custom error.
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
            vault.setMaxRedeemFee(0.005e18);
        }
    }

    function test_setMaxRedeemFee_authorized() public {
        vm.prank(admin);
        vault.setMaxRedeemFee(0.005e18);
        assertEq(vault.maxRedeemFee(), 0.005e18);
    }

    function test_setMinimums_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == admin) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], DEFAULT_ADMIN_ROLE);
            vault.setMinimums(1e6, 1e6);
        }
    }

    function test_setMinimums_authorized() public {
        vm.prank(admin);
        vault.setMinimums(1e6, 2e6);
        assertEq(vault.minDeposit(),  1e6);
        assertEq(vault.minWithdraw(), 2e6);
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

    function test_processDepositQueue_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == rebalancer) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], REBALANCER_ROLE);
            vault.processDepositQueue(type(uint256).max, 10);
        }
    }

    function test_processDepositQueue_authorized() public {
        vm.prank(rebalancer);
        vault.processDepositQueue(type(uint256).max, 10);
    }

    function test_processRedeemQueue_notAuthorized() public {
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == rebalancer) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], REBALANCER_ROLE);
            vault.processRedeemQueue(type(uint256).max, 10);
        }
    }

    function test_processRedeemQueue_authorized() public {
        vm.prank(rebalancer);
        vault.processRedeemQueue(type(uint256).max, 10);
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
            vault.setRedeemFee(0.001e18);
        }
    }

    function test_setRedeemFee_authorized() public {
        vm.prank(riskManager);
        vault.setRedeemFee(0.001e18);
        assertEq(vault.redeemFee(), 0.001e18);
    }

    function test_setChi_notAuthorized() public {
        _pause();
        uint192 chi_ = vault.chi();
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == riskManager) continue;
            vm.prank(actors_[i]);
            _expectUnauthorized(actors_[i], RISK_MANAGER_ROLE);
            vault.setChi(chi_ - 1);
        }
        assertEq(vault.chi(), chi_);
    }

    function test_setChi_authorized() public {
        _pause();
        uint192 chi_ = vault.chi();
        vm.prank(riskManager);
        vault.setChi(chi_ - 1);
        assertEq(vault.chi(), chi_ - 1);
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

    function test_unpause_idempotent() public {
        assertFalse(vault.paused());
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit Unpaused();
        vault.unpause();
        assertFalse(vault.paused());
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

    function test_cancelDepositRequest_notAuthorized() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        address[8] memory actors_ = _actors();
        for (uint256 i; i < actors_.length; ++i) {
            if (actors_[i] == guardian) continue;
            vm.prank(actors_[i]);
            vm.expectRevert("SparkPrimeVault/not-authorized");
            vault.cancelDepositRequest(id_, actors_[i]);
        }
        (, , uint256 shares_) = _depositRequest(id_);
        assertGt(shares_, 0);
    }

    function test_cancelDepositRequest_owner() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        vm.prank(alice);
        vault.cancelDepositRequest(id_, alice);
        (, , uint256 shares_) = _depositRequest(id_);
        assertEq(shares_, 0);
        assertEq(usdc.balanceOf(alice), 100e6 - 1);  // spUSDC redeem rounds down (R10)
    }

    function test_cancelDepositRequest_guardian() public {
        uint256 id_ = _queueDeposit(alice, 100e6);
        vm.prank(guardian);
        vault.cancelDepositRequest(id_, guardian);  // F-1 patch: refund goes to the owner
        (, , uint256 shares_) = _depositRequest(id_);
        assertEq(shares_, 0);
        assertEq(usdc.balanceOf(alice),    100e6 - 1);
        assertEq(usdc.balanceOf(guardian), 0);
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

    function test_cancelRedeemRequest_guardian() public {
        _deposit(alice, 100e6);
        uint256 shares_ = vault.balanceOf(alice);
        uint256 id_     = _requestRedeem(alice, shares_);
        vm.prank(guardian);
        vault.cancelRedeemRequest(id_, guardian);  // F-1 patch: refund goes to the owner
        assertEq(vault.balanceOf(alice),      shares_);
        assertEq(vault.balanceOf(guardian),   0);
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
        vault.cancelDepositRequest(id2_, stranger);
        (, , uint256 left_) = _depositRequest(id2_);
        assertEq(left_, 0);
    }

    /**********************************************************************************************/
    /*** Pause scope                                                                            ***/
    /**********************************************************************************************/

    // alice holds shares, a deposit is queued (bob), a redeem is queued (alice), then pause.
    function _pausedFixture() internal returns (uint256 depId_, uint256 redId_) {
        _deposit(alice, 1_000e6);
        redId_ = _requestRedeem(alice, 100e6);
        _setCapacity(vault.totalSupply());
        depId_ = _deposit(bob, 100e6);
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

    function test_pause_blocksCancelDepositRequest() public {
        (uint256 depId_, ) = _pausedFixture();
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelDepositRequest(depId_, bob);
        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelDepositRequest(depId_, bob);
    }

    function test_pause_blocksRequestRedeem() public {
        _pausedFixture();
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.requestRedeem(1e6, alice);
    }

    function test_pause_blocksCancelRedeemRequest() public {
        (, uint256 redId_) = _pausedFixture();
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
        vault.processDepositQueue(type(uint256).max, 10);
    }

    function test_pause_blocksProcessRedeemQueue() public {
        _pausedFixture();
        vm.prank(rebalancer);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.processRedeemQueue(type(uint256).max, 10);
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

    function test_pause_doesNotBlockSetChi() public {
        _pausedFixture();
        uint192 chi_ = vault.chi();
        vm.prank(riskManager);
        vault.setChi(chi_ - 1);
        assertEq(vault.chi(), chi_ - 1);
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
        vault.setMaxRedeemFee(0.005e18);
        vault.setMinimums(1, 2);
        vault.setVSRBounds(RAY, FOUR_PCT_VSR);
        vault.grantRole(SETTER_ROLE, alice);
        vault.revokeRole(SETTER_ROLE, alice);
        vm.stopPrank();
        vm.prank(riskManager);
        vault.setRedeemFee(0.005e18);

        assertEq(vault.maxCapacity(),   5);
        assertEq(vault.maxRedeemFee(),  0.005e18);
        assertEq(vault.minDeposit(),    1);
        assertEq(vault.minWithdraw(),   2);
        assertEq(vault.maxVSR(),        FOUR_PCT_VSR);
        assertEq(vault.redeemFee(),     0.005e18);
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

    function test_revokeRebalancer_queueFrozenUntilNewRebalancer() public {
        _deposit(alice, 1_000e6);
        uint256 redId_ = _requestRedeem(alice, 100e6);
        _setCapacity(vault.totalSupply());
        uint256 depId_ = _deposit(bob, 100e6);
        _setCapacity(type(uint128).max);

        vm.prank(admin);
        vault.revokeRole(REBALANCER_ROLE, rebalancer);

        vm.prank(rebalancer);
        _expectUnauthorized(rebalancer, REBALANCER_ROLE);
        vault.processDepositQueue(type(uint256).max, 10);

        vm.prank(rebalancer);
        _expectUnauthorized(rebalancer, REBALANCER_ROLE);
        vault.processRedeemQueue(type(uint256).max, 10);

        // Queues are intact and frozen; users can still cancel.
        (, , uint256 depShares_) = _depositRequest(depId_);
        (, , uint256 redShares_) = _redeemRequest(redId_);
        assertGt(depShares_, 0);
        assertEq(redShares_, 100e6);

        address newRebalancer_ = makeAddr("newRebalancer");
        vm.prank(admin);
        vault.grantRole(REBALANCER_ROLE, newRebalancer_);

        vm.startPrank(newRebalancer_);
        vault.processDepositQueue(type(uint256).max, 10);
        vault.processRedeemQueue(type(uint256).max, 10);
        vm.stopPrank();

        (, , depShares_) = _depositRequest(depId_);
        (, , redShares_) = _redeemRequest(redId_);
        assertEq(depShares_, 0);
        assertEq(redShares_, 0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.pendingRedeemShares(),         0);
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

    function test_revokeGuardian_whilePaused_adminCanStillUnpause() public {
        _pause();
        vm.prank(admin);
        vault.revokeRole(GUARDIAN_ROLE, guardian);
        assertTrue(vault.paused());

        vm.prank(guardian);
        _expectUnauthorized(guardian, GUARDIAN_ROLE);
        vault.pause();

        _unpause();
        assertFalse(vault.paused());
    }

    // The only DEFAULT_ADMIN can renounce and leave the vault without any admin forever:
    // no unpause, no upgrade, no role changes. Operational risk, see report.
    function test_renounceDefaultAdmin_vaultHasNoAdminForever() public {
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
