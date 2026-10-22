// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../../lib/forge-std/src/Test.sol";

import { ISparkPrimeVault } from "../../../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../../src/SparkPrimeVault.sol";

// The part of the spUSDC (Spark Vault V2) surface the handlers use.
interface ISavingsVaultLike {

    function approve(address spender, uint256 amount) external returns (bool);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function grantRole(bytes32 role, address account) external;

    function setDepositCap(uint256 newCap) external;

    function setVsr(uint256 newVsr) external;

    function setVsrBounds(uint256 minVsr, uint256 maxVsr) external;

    function take(uint256 value) external;

    function transfer(address to, uint256 amount) external returns (bool);

    function assetsOf(address owner) external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function getRoleMember(bytes32 role, uint256 index) external view returns (address);

    function hasRole(bytes32 role, address account) external view returns (bool);

    function maxDeposit(address receiver) external view returns (uint256);

    function maxVsr() external view returns (uint256);

    function minVsr() external view returns (uint256);

    function nowChi() external view returns (uint256);

}

// The part of the Circle FiatToken surface the handlers use.
interface IUSDCLike {

    function approve(address spender, uint256 amount) external returns (bool);

    function blacklist(address account) external;

    function transfer(address to, uint256 amount) external returns (bool);

    function unBlacklist(address account) external;

    function balanceOf(address account) external view returns (uint256);

    function blacklister() external view returns (address);

    function isBlacklisted(address account) external view returns (bool);

}

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

    SparkPrimeVault   internal spPrime;
    ISavingsVaultLike internal spUSDC;
    IUSDCLike         internal usdc;

    // Every owner and recipient is drawn from this set, so every balance the invariants sum over
    // belongs to a tracked address. `makeAddr` is deterministic, so every handler sees the same set.
    address[] public users;

    modifier chiNeverDecreases() {
        uint256 chiBefore_ = spPrime.nowChi();
        _;
        assertGe(spPrime.nowChi(), chiBefore_, "invariant: nowChi decreased");
    }

    modifier headsNeverMoveBack() {
        uint256 depositHead_ = spPrime.firstPendingDepositId();
        uint256 cancelHead_  = spPrime.firstPendingDepositCancellationId();
        uint256 redeemHead_  = spPrime.firstPendingRedeemId();

        _;

        assertGe(spPrime.firstPendingDepositId(),             depositHead_, "invariant: deposit head moved back");
        assertGe(spPrime.firstPendingDepositCancellationId(), cancelHead_,  "invariant: cancellation head moved back");
        assertGe(spPrime.firstPendingRedeemId(),              redeemHead_,  "invariant: redeem head moved back");
    }

    constructor(address spPrime_, uint256 numUsers_) {
        spPrime = SparkPrimeVault(spPrime_);
        spUSDC  = ISavingsVaultLike(spPrime.savings());
        usdc    = IUSDCLike(spPrime.asset());

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
            return ( spPrime.firstPendingDepositId(), spPrime.getPendingDepositRequests() );
        }

        if (queue_ == Queue.DEPOSIT_CANCELLATION) {
            return (
                spPrime.firstPendingDepositCancellationId(),
                spPrime.getPendingDepositCancellationRequests()
            );
        }

        return ( spPrime.firstPendingRedeemId(), spPrime.getPendingRedeemRequests() );
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
            spPrime.pendingDepositSavingsShares() + spPrime.pendingCancelledDepositSavingsShares();
        uint256 held_ = spUSDC.balanceOf(address(spPrime));

        return owed_ > held_ ? owed_ - held_ : 0;
    }

    function _randomUser(uint256 seed_) internal view returns (address) {
        return users[_bound(seed_, 0, users.length - 1)];
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return a_ < b_ ? a_ : b_;
    }

}
