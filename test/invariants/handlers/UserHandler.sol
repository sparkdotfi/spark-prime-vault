// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISparkPrimeVault } from "../../../src/ISparkPrimeVault.sol";

import { HandlerBase } from "./HandlerBase.sol";

contract UserHandler is HandlerBase {

    uint256 public numUsers;

    address[] public users;

    uint256 public ghostFeeShares;

    constructor(address vault_, uint256 numUsers_) HandlerBase(vault_) {
        numUsers = numUsers_;
        for (uint256 i = 0; i < numUsers_; i++) {
            users.push(makeAddr(string(abi.encodePacked("user", i))));
        }
    }

    function requestDeposit(uint256 assets_, uint32 userIndex, uint32 recipientIndex) public accountingCheck {
        if (vault.paused()) return;

        address user = _getRandomUser(userIndex);

        assets_ = _bound(assets_, vault.minDeposit(), MAX_AMOUNT);

        asset.mint(user, assets_);

        vm.startPrank(user);
        asset.approve(address(vault), assets_);
        vault.requestDeposit(assets_, _getRandomUser(recipientIndex), 0);
        vm.stopPrank();
    }

    function requestDepositCancellation(
        uint32  userIndex,
        uint256 pickSeed,
        uint256 savingsShares,
        uint32  recipientIndex
    )
        public accountingCheck
    {
        address user = _getRandomUser(userIndex);

        ( uint256 requestId, uint256 maxShares ) = _findDepositRequest(user, pickSeed);

        if (maxShares == 0 || maxShares < vault.minDepositCancellation()) return;

        savingsShares = _bound(savingsShares, vault.minDepositCancellation(), maxShares);

        vm.prank(user);
        vault.requestDepositCancellation(requestId, _getRandomUser(recipientIndex), savingsShares);
    }

    function requestRedeem(uint256 shares_, uint32 userIndex, uint32 recipientIndex) public accountingCheck {
        if (vault.paused()) return;

        address user    = _getRandomUser(userIndex);
        uint256 balance = vault.balanceOf(user);

        if (balance < vault.minRedeem()) return;

        shares_ = _bound(shares_, vault.minRedeem(), balance);

        uint256 supplyBefore = vault.totalSupply();

        vm.prank(user);
        vault.requestRedeem(shares_, _getRandomUser(recipientIndex));

        ghostFeeShares += supplyBefore - vault.totalSupply();
    }

    function claim(uint32 recipientIndex) public accountingCheck {
        address recipient = _getRandomUser(recipientIndex);

        if (vault.claimableAssets(recipient) == 0 || asset.blocked(recipient)) return;

        vault.claim(recipient);
    }

    function transfer(uint32 userIndex, uint32 toIndex, uint256 shares_) public accountingCheck {
        address user = _getRandomUser(userIndex);

        shares_ = _bound(shares_, 0, vault.balanceOf(user));

        vm.prank(user);
        vault.transfer(_getRandomUser(toIndex), shares_);
    }

    function _getRandomUser(uint256 userIndex) internal view returns (address) {
        return users[_bound(userIndex, 0, users.length - 1)];
    }

    function _findDepositRequest(address owner, uint256 pickSeed)
        internal view
        returns (uint256 requestId, uint256 shares_)
    {
        ISparkPrimeVault.Request[] memory requests = vault.getPendingDepositRequests();

        if (requests.length == 0) return (0, 0);

        uint256 start = _bound(pickSeed, 0, requests.length - 1);

        for (uint256 i = 0; i < requests.length; i++) {
            uint256 j = (start + i) % requests.length;
            if (requests[j].owner == owner && requests[j].shares != 0) {
                return (vault.firstPendingDepositId() + j, requests[j].shares);
            }
        }
    }

}
