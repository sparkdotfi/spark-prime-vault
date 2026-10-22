// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../../lib/forge-std/src/Test.sol";

import { ISparkPrimeVault } from "../../../src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../../src/SparkPrimeVault.sol";

// Full surface of the spUSDC (Spark Vault V2) savings vault the handlers need. The implementation
// deployed at the fork block exposes every one of these (verified against the cached fork state).
interface ISavingsVaultLike {

    function approve(address spender, uint256 amount) external returns (bool);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function drip() external returns (uint256 nChi);

    function grantRole(bytes32 role, address account) external;

    function setDepositCap(uint256 newCap) external;

    function setVsr(uint256 newVsr) external;

    function setVsrBounds(uint256 minVsr, uint256 maxVsr) external;

    function take(uint256 value) external;

    function transfer(address to, uint256 amount) external returns (bool);

    function asset() external view returns (address);

    function assetsOf(address owner) external view returns (uint256);

    function assetsOutstanding() external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function depositCap() external view returns (uint256);

    function getRoleMember(bytes32 role, uint256 index) external view returns (address);

    function hasRole(bytes32 role, address account) external view returns (bool);

    function maxDeposit(address receiver) external view returns (uint256);

    function maxRedeem(address owner) external view returns (uint256);

    function maxVsr() external view returns (uint256);

    function maxWithdraw(address owner) external view returns (uint256);

    function minVsr() external view returns (uint256);

    function nowChi() external view returns (uint256);

    function totalAssets() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function vsr() external view returns (uint256);

}

// Circle FiatToken v2.2 surface used by the handlers (balance, blacklist administration).
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

    uint256 public constant RAY = 1e27;
    uint256 public constant WAD = 1e18;

    uint256 public constant MAX_AMOUNT = 100_000_000e6;  // 100M USDC per action

    // Storage slots of the three request arrays, the first declared variables of the vault
    // (every inherited OZ base uses ERC-7201 namespaced storage). Checked against
    // `forge inspect SparkPrimeVault storage-layout` and cross-checked at runtime by the
    // getter-consistency queue invariant.
    uint256 internal constant DEPOSIT_SLOT = 0;
    uint256 internal constant CANCEL_SLOT  = 1;
    uint256 internal constant REDEEM_SLOT  = 2;

    bytes32 internal constant DEFAULT_ADMIN_ROLE     = 0x00;
    bytes32 internal constant LOSS_MANAGER_ROLE      = keccak256("LOSS_MANAGER_ROLE");
    bytes32 internal constant OPERATOR_ROLE          = keccak256("OPERATOR_ROLE");
    bytes32 internal constant PAUSER_ROLE            = keccak256("PAUSER_ROLE");
    bytes32 internal constant REDEEM_FEE_SETTER_ROLE = keccak256("REDEEM_FEE_SETTER_ROLE");
    bytes32 internal constant TAKER_ROLE             = keccak256("TAKER_ROLE");
    bytes32 internal constant UNPAUSER_ROLE          = keccak256("UNPAUSER_ROLE");

    string internal constant USDC_BLACKLISTED = "Blacklistable: account is blacklisted";

    SparkPrimeVault   internal spPrime;
    ISavingsVaultLike internal spUSDC;
    IUSDCLike         internal usdc;

    // Every request owner and every recipient is drawn from this set, so every balance the
    // invariants sum over belongs to a tracked address.
    address[] public users;

    /**********************************************************************************************/
    /*** Per-call checks                                                                        ***/
    /**********************************************************************************************/

    // One modifier with a flag set instead of one modifier per check keeps the stack shallow.
    uint256 internal constant CHECK_CHI_UNCHANGED         = 1 << 0;  // nowChi only moves in warp and adjustTotalAssets
    uint256 internal constant CHECK_CHI_NON_DECREASING    = 1 << 1;
    uint256 internal constant CHECK_SUPPLY_UNCHANGED      = 1 << 2;
    uint256 internal constant CHECK_ESCROW_NON_DECREASING = 1 << 3;  // the redeem escrow only falls in processPendingRedeems
    uint256 internal constant CHECK_HEADS_NON_DECREASING  = 1 << 4;
    uint256 internal constant CHECK_GAP_NEVER_WIDENS      = 1 << 5;  // only take and processPendingRedeems may widen the backing gap

    uint256 internal constant CHECK_ALL =
        CHECK_CHI_UNCHANGED
        | CHECK_SUPPLY_UNCHANGED
        | CHECK_ESCROW_NON_DECREASING
        | CHECK_HEADS_NON_DECREASING
        | CHECK_GAP_NEVER_WIDENS;

    struct Before {
        uint256 chi;
        uint256 supply;
        uint256 escrow;
        uint256 depositHead;
        uint256 cancelHead;
        uint256 redeemHead;
        uint256 gap;
    }

    modifier checked(uint256 checks_) {
        Before memory b_ = _before();
        _;
        _after(b_, checks_);
    }

    function _before() internal view returns (Before memory b_) {
        b_.chi         = spPrime.nowChi();
        b_.supply      = spPrime.totalSupply();
        b_.escrow      = spPrime.balanceOf(address(spPrime));
        b_.depositHead = spPrime.firstPendingDepositId();
        b_.cancelHead  = spPrime.firstPendingDepositCancellationId();
        b_.redeemHead  = spPrime.firstPendingRedeemId();
        b_.gap         = _backingGap();
    }

    function _after(Before memory b_, uint256 checks_) internal view {
        if (checks_ & CHECK_CHI_UNCHANGED != 0) {
            assertEq(spPrime.nowChi(), b_.chi, "check: nowChi changed");
        }
        if (checks_ & CHECK_CHI_NON_DECREASING != 0) {
            assertGe(spPrime.nowChi(), b_.chi, "check: nowChi decreased");
        }
        if (checks_ & CHECK_SUPPLY_UNCHANGED != 0) {
            assertEq(spPrime.totalSupply(), b_.supply, "check: totalSupply changed");
        }
        if (checks_ & CHECK_ESCROW_NON_DECREASING != 0) {
            assertGe(spPrime.balanceOf(address(spPrime)), b_.escrow, "check: escrow decreased");
        }
        if (checks_ & CHECK_HEADS_NON_DECREASING != 0) {
            assertGe(spPrime.firstPendingDepositId(),             b_.depositHead, "check: deposit head moved back");
            assertGe(spPrime.firstPendingDepositCancellationId(), b_.cancelHead,  "check: cancellation head moved back");
            assertGe(spPrime.firstPendingRedeemId(),              b_.redeemHead,  "check: redeem head moved back");
        }
        if (checks_ & CHECK_GAP_NEVER_WIDENS != 0) {
            assertLe(_backingGap(), b_.gap, "check: backing gap widened");
        }
    }

    constructor(address spPrime_) {
        spPrime = SparkPrimeVault(spPrime_);
        spUSDC  = ISavingsVaultLike(spPrime.savings());
        usdc    = IUSDCLike(spPrime.asset());
    }

    function numUsers() external view returns (uint256) {
        return users.length;
    }

    /**********************************************************************************************/
    /*** Raw queue reads (the getters refuse ids below a head)                                  ***/
    /**********************************************************************************************/

    function _rawLength(uint256 slot_) internal view returns (uint256) {
        return uint256(vm.load(address(spPrime), bytes32(slot_)));
    }

    function _rawRequest(uint256 slot_, uint256 id_)
        internal view returns (address owner_, address recipient_, uint256 shares_)
    {
        uint256 base_ = uint256(keccak256(abi.encode(slot_))) + 3 * id_;

        owner_     = address(uint160(uint256(vm.load(address(spPrime), bytes32(base_)))));
        recipient_ = address(uint160(uint256(vm.load(address(spPrime), bytes32(base_ + 1)))));
        shares_    = uint256(vm.load(address(spPrime), bytes32(base_ + 2)));
    }

    function _rawShares(uint256 slot_, uint256 id_) internal view returns (uint256 shares_) {
        ( , , shares_ ) = _rawRequest(slot_, id_);
    }

    function _head(uint256 slot_) internal view returns (uint256) {
        if (slot_ == DEPOSIT_SLOT) return spPrime.firstPendingDepositId();
        if (slot_ == CANCEL_SLOT)  return spPrime.firstPendingDepositCancellationId();
        return spPrime.firstPendingRedeemId();
    }

    // A random entry with nonzero shares in the pending window of a queue, or `NONE`.
    uint256 internal constant NONE = type(uint256).max;

    function _randomOpenRequest(uint256 slot_, uint256 seed_) internal view returns (uint256) {
        uint256 head_   = _head(slot_);
        uint256 length_ = _rawLength(slot_);

        if (head_ >= length_) return NONE;

        uint256 window_ = length_ - head_;
        uint256 start_  = _bound(seed_, 0, window_ - 1);

        for (uint256 i = 0; i < window_; i++) {
            uint256 id_ = head_ + (start_ + i) % window_;
            if (_rawShares(slot_, id_) != 0) return id_;
        }

        return NONE;
    }

    /**********************************************************************************************/
    /*** State digest (everything a recipient update must leave alone)                          ***/
    /**********************************************************************************************/

    function _stateDigest() internal view returns (bytes32 digest_) {
        digest_ = keccak256(abi.encode(
            spPrime.totalSupply(),
            spPrime.totalClaimable(),
            spPrime.pendingDepositSavingsShares(),
            spPrime.pendingCancelledDepositSavingsShares(),
            spPrime.pendingRedeemShares(),
            spPrime.firstPendingDepositId(),
            spPrime.firstPendingDepositCancellationId(),
            spPrime.firstPendingRedeemId(),
            spPrime.chi(),
            spPrime.rho(),
            spPrime.balanceOf(address(spPrime)),
            spUSDC.balanceOf(address(spPrime)),
            usdc.balanceOf(address(spPrime))
        ));

        for (uint256 i = 0; i < users.length; i++) {
            digest_ = keccak256(abi.encode(
                digest_,
                spPrime.balanceOf(users[i]),
                usdc.balanceOf(users[i]),
                spPrime.claimableAssets(users[i])
            ));
        }

        digest_ = _digestQueue(digest_, DEPOSIT_SLOT);
        digest_ = _digestQueue(digest_, CANCEL_SLOT);
        digest_ = _digestQueue(digest_, REDEEM_SLOT);
    }

    function _digestQueue(bytes32 digest_, uint256 slot_) internal view returns (bytes32) {
        uint256 length_ = _rawLength(slot_);

        for (uint256 i = 0; i < length_; i++) {
            ( address owner_, , uint256 shares_ ) = _rawRequest(slot_, i);
            digest_ = keccak256(abi.encode(digest_, owner_, shares_));
        }

        return digest_;
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _backingGap() internal view returns (uint256) {
        uint256 owed_ =
            spPrime.pendingDepositSavingsShares() + spPrime.pendingCancelledDepositSavingsShares();
        uint256 held_ = spUSDC.balanceOf(address(spPrime));

        return owed_ > held_ ? owed_ - held_ : 0;
    }

    function _randomUser(uint256 seed_) internal view returns (address) {
        return users[_bound(seed_, 0, users.length - 1)];
    }

    function _divUp(uint256 x_, uint256 y_) internal pure returns (uint256) {
        return x_ != 0 ? ((x_ - 1) / y_) + 1 : 0;
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return a_ < b_ ? a_ : b_;
    }

    function _max(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return a_ > b_ ? a_ : b_;
    }

}
