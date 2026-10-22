// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../../../lib/forge-std/src/Test.sol";

import { ISparkPrimeVault } from "../../../../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../../../src/SparkPrimeVault.sol";

import { SparkVault } from "../../lib/spusdc/SparkVault.sol";
import { MockUSDC }   from "../../LocalTestBase.t.sol";

// Local-harness complement of `test/invariants/handlers/HandlerBase.sol`: the real spUSDC code
// over the 6-decimal `MockUSDC` (blacklist by `setBlacklisted`), no RPC.
contract HandlerBase is Test {

    enum Queue { DEPOSIT, DEPOSIT_CANCELLATION, REDEEM }

    uint256 public constant RAY = 1e27;
    uint256 public constant WAD = 1e18;

    uint256 public constant MAX_AMOUNT = 100_000_000e6;  // 100M USDC per action

    bytes32 internal constant DEFAULT_ADMIN_ROLE     = 0x00;
    bytes32 internal constant LOSS_MANAGER_ROLE      = keccak256("LOSS_MANAGER_ROLE");
    bytes32 internal constant OPERATOR_ROLE          = keccak256("OPERATOR_ROLE");
    bytes32 internal constant PAUSER_ROLE            = keccak256("PAUSER_ROLE");
    bytes32 internal constant REDEEM_FEE_SETTER_ROLE = keccak256("REDEEM_FEE_SETTER_ROLE");
    bytes32 internal constant TAKER_ROLE             = keccak256("TAKER_ROLE");
    bytes32 internal constant UNPAUSER_ROLE          = keccak256("UNPAUSER_ROLE");

    SparkPrimeVault internal vault;
    SparkVault      internal spUsdc;
    MockUSDC        internal usdc;

    // Every owner and recipient is drawn from this set, so every balance the invariants sum over
    // belongs to a tracked address. `makeAddr` is deterministic, so every handler sees the same set.
    address[] public users;

    modifier chiNeverDecreases() {
        uint256 chiBefore_ = vault.nowChi();
        _;
        assertGe(vault.nowChi(), chiBefore_, "invariant: nowChi decreased");
    }

    modifier headsNeverMoveBack() {
        uint256 depositHead_ = vault.firstPendingDepositId();
        uint256 cancelHead_  = vault.firstPendingDepositCancellationId();
        uint256 redeemHead_  = vault.firstPendingRedeemId();

        _;

        assertGe(vault.firstPendingDepositId(),             depositHead_, "invariant: deposit head moved back");
        assertGe(vault.firstPendingDepositCancellationId(), cancelHead_,  "invariant: cancellation head moved back");
        assertGe(vault.firstPendingRedeemId(),              redeemHead_,  "invariant: redeem head moved back");
    }

    constructor(address vault_, uint256 numUsers_) {
        vault  = SparkPrimeVault(vault_);
        spUsdc = SparkVault(vault.savings());
        usdc   = MockUSDC(vault.asset());

        for (uint256 i = 0; i < numUsers_; i++) {
            users.push(makeAddr(string(abi.encodePacked("user", vm.toString(i)))));
        }
    }

    function numUsers() external view returns (uint256) {
        return users.length;
    }

    /**********************************************************************************************/
    /*** Internal Helpers                                                                       ***/
    /**********************************************************************************************/

    function _pendingRequests(Queue queue_)
        internal view returns (uint256 head_, ISparkPrimeVault.Request[] memory requests_)
    {
        if (queue_ == Queue.DEPOSIT) {
            return ( vault.firstPendingDepositId(), vault.getPendingDepositRequests() );
        }

        if (queue_ == Queue.DEPOSIT_CANCELLATION) {
            return (
                vault.firstPendingDepositCancellationId(),
                vault.getPendingDepositCancellationRequests()
            );
        }

        return ( vault.firstPendingRedeemId(), vault.getPendingRedeemRequests() );
    }

    // A random request with nonzero shares in the pending window of a queue, or `found_ == false`.
    function _randomOpenRequest(Queue queue_, uint256 seed_)
        internal view returns (bool found_, uint256 requestId_, ISparkPrimeVault.Request memory request_)
    {
        ( uint256 head_, ISparkPrimeVault.Request[] memory requests_ ) = _pendingRequests(queue_);

        if (requests_.length == 0) return ( false, 0, request_ );

        uint256 start_ = _bound(seed_, 0, requests_.length - 1);

        for (uint256 i = 0; i < requests_.length; i++) {
            uint256 index_ = (start_ + i) % requests_.length;

            if (requests_[index_].shares != 0) {
                return ( true, head_ + index_, requests_[index_] );
            }
        }
    }

    // spUSDC owed to the deposit and cancellation queues that the vault does not hold.
    function _backingGap() internal view returns (uint256) {
        uint256 owed_ =
            vault.pendingDepositSavingsShares() + vault.pendingCancelledDepositSavingsShares();
        uint256 held_ = spUsdc.balanceOf(address(vault));

        return owed_ > held_ ? owed_ - held_ : 0;
    }

    // USDC paid out to the tracked set so far: what users hold plus what is parked for them.
    function _usersUsdcPlusClaimable() internal view returns (uint256 sum_) {
        for (uint256 i = 0; i < users.length; i++) {
            sum_ += usdc.balanceOf(users[i]);
        }

        sum_ += vault.totalClaimable();
    }

    function _randomUser(uint256 seed_) internal view returns (address) {
        return users[_bound(seed_, 0, users.length - 1)];
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return a_ < b_ ? a_ : b_;
    }

}
