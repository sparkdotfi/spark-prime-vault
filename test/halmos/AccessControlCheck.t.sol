// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { SeededHalmosTestBase } from "./HalmosTestBase.t.sol";

contract AccessControlCheck is SeededHalmosTestBase {

    function check_configLockedWithoutRoles() external frozenTime {
        bytes32 configBefore = _configHash();
        uint256 chiBefore    = vault.chi();

        _anyCall(_senderWithoutRoles());

        assertEq(_configHash(), configBefore);
        assertGe(vault.chi(),   chiBefore);
    }

    function check_requestLockedForStrangers() external frozenTime {
        ( address owner, address recipient, uint256 shares_ ) =
            vault.getPendingDepositRequest(seededDepositId);

        address sender = _senderWithoutRoles();
        vm.assume(sender != owner);

        _anyCall(sender);

        ( address owner_, address recipient_, uint256 shares__ ) =
            vault.getPendingDepositRequest(seededDepositId);

        assertEq(owner_,     owner);
        assertEq(recipient_, recipient);
        assertEq(shares__,   shares_);
    }

    function check_fundsLockedWithoutRoles() external frozenTime {
        uint256 savingsBefore = savings.balanceOf(address(vault));
        uint256 assetsBefore  = asset.balanceOf(address(vault));

        _anyCall(_senderWithoutRoles());

        assertGe(savings.balanceOf(address(vault)), savingsBefore);
        assertGe(asset.balanceOf(address(vault)),   assetsBefore);
    }

    function _configHash() internal view returns (bytes32) {
        return keccak256(abi.encode(
            vault.vsr(),
            vault.minVSR(),
            vault.maxVSR(),
            vault.maxCapacity(),
            vault.minDeposit(),
            vault.minDepositCancellation(),
            vault.minRedeem(),
            vault.redeemFeeRate(),
            vault.maxRedeemFeeRate(),
            vault.paused(),
            vault.implementation()
        ));
    }

}
