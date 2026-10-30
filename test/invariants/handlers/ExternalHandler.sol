// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { HandlerBase } from "./HandlerBase.sol";
import { UserHandler } from "./UserHandler.sol";

contract ExternalHandler is HandlerBase {

    UserHandler internal userHandler;

    bool public ratesMoved;

    constructor(address vault_, address userHandler_) HandlerBase(vault_) {
        userHandler = UserHandler(userHandler_);
    }

    function warp(uint256 secs) public accountingCheck {
        vm.warp(block.timestamp + _bound(secs, 0, 10 days));
    }

    function drip() public accountingCheck {
        vault.drip();
    }

    // Savings yield: rate grows and the earned assets appear in the savings vault.
    function accrue(uint256 bps) public accountingCheck {
        bps = _bound(bps, 0, 100);

        if (bps == 0) return;

        ratesMoved = true;

        uint256 newRate = savings.rate() * (10_000 + bps) / 10_000;

        asset.mint(address(savings), savings.convertToAssets(savings.balanceOf(address(vault))) * bps / 10_000 + 1);

        savings.setRate(newRate);
    }

    function blockUser(uint32 userIndex) public accountingCheck {
        asset.setBlocked(_randomUser(userIndex), true);
    }

    function unblockUser(uint32 userIndex) public accountingCheck {
        asset.setBlocked(_randomUser(userIndex), false);
    }

    function _randomUser(uint256 userIndex) internal view returns (address) {
        return userHandler.users(_bound(userIndex, 0, userHandler.numUsers() - 1));
    }

}
