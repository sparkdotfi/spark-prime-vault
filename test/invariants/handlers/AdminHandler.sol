// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { HandlerBase } from "./HandlerBase.sol";

contract AdminHandler is HandlerBase {

    bytes32 internal constant DEFAULT_ADMIN_ROLE     = 0x00;
    bytes32 internal constant PAUSER_ROLE            = keccak256("PAUSER_ROLE");
    bytes32 internal constant REDEEM_FEE_SETTER_ROLE = keccak256("REDEEM_FEE_SETTER_ROLE");
    bytes32 internal constant TAKER_ROLE             = keccak256("TAKER_ROLE");
    bytes32 internal constant UNPAUSER_ROLE          = keccak256("UNPAUSER_ROLE");

    uint256 internal constant FOUR_PCT_VSR  = 1.000000001243680656318820312e27;
    uint256 internal constant FORTY_PCT_VSR = 1.000000010669464688489416886e27;

    address public admin;
    address public pauser;
    address public redeemFeeSetter;
    address public taker;
    address public unpauser;

    uint256 public ghostTakenSavingsShares;

    constructor(address vault_) HandlerBase(vault_) {
        admin           = vault.getRoleMember(DEFAULT_ADMIN_ROLE,     0);
        pauser          = vault.getRoleMember(PAUSER_ROLE,            0);
        redeemFeeSetter = vault.getRoleMember(REDEEM_FEE_SETTER_ROLE, 0);
        taker           = vault.getRoleMember(TAKER_ROLE,             0);
        unpauser        = vault.getRoleMember(UNPAUSER_ROLE,          0);
    }

    function setVSRBounds(uint256 minVSR, uint256 maxVSR) public accountingCheck {
        minVSR = _bound(minVSR, RAY,    FOUR_PCT_VSR);
        maxVSR = _bound(maxVSR, minVSR, FORTY_PCT_VSR);

        vm.prank(admin);
        vault.setVSRBounds(minVSR, maxVSR);
    }

    function setMaxRedeemFeeRate(uint256 feeRate) public accountingCheck {
        feeRate = _bound(feeRate, 0, vault.MAX_REDEEM_FEE());

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(feeRate);
    }

    function setRedeemFeeRate(uint256 feeRate) public accountingCheck {
        feeRate = _bound(feeRate, 0, vault.maxRedeemFeeRate());

        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(feeRate);
    }

    function setMinDeposit(uint256 minDeposit) public accountingCheck {
        vm.prank(admin);
        vault.setMinDeposit(_bound(minDeposit, 1, 1_000e6));
    }

    function setMinDepositCancellation(uint256 minDepositCancellation) public accountingCheck {
        vm.prank(admin);
        vault.setMinDepositCancellation(_bound(minDepositCancellation, 1, 1_000e6));
    }

    function setMinRedeem(uint256 minRedeem) public accountingCheck {
        vm.prank(admin);
        vault.setMinRedeem(_bound(minRedeem, 1, 1_000e6));
    }

    function pause() public accountingCheck {
        vm.prank(pauser);
        vault.pause();
    }

    function unpause() public accountingCheck {
        vm.prank(unpauser);
        vault.unpause();
    }

    function take(uint256 savingsShares) public accountingCheck {
        savingsShares = _bound(savingsShares, 0, savings.balanceOf(address(vault)));

        ghostTakenSavingsShares += savingsShares;

        vm.prank(taker);
        vault.take(savingsShares);
    }

}
