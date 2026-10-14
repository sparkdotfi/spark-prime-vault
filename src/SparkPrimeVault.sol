// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ERC1967Utils }    from "../lib/oz/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { UUPSUpgradeable } from "../lib/oz/contracts/proxy/utils/UUPSUpgradeable.sol";

import { SafeERC20, IERC20 as IERC20OZ } from "../lib/oz/contracts/token/ERC20/utils/SafeERC20.sol";

import { AccessControlEnumerableUpgradeable }
    from "../lib/oz-upgradeable/contracts/access/extensions/AccessControlEnumerableUpgradeable.sol";

interface IERC20Like {

    function balanceOf(address account) external view returns (uint256 balance);

    function decimals() external view returns (uint8);

}

interface IERC1271 {

    function isValidSignature(bytes32, bytes memory) external view returns (bytes4);

}

interface IERC4626Like {

    function deposit(uint256 amount, address recipient) external returns (uint256 shares);

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    function asset() external view returns (address);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function convertToShares(uint256 assets) external view returns (uint256 shares);

    function maxWithdraw(address owner) external view returns (uint256);

}

// TODO: Clean up roles
// TODO: Add more validation to setters
// TODO: Should processDepositQueue and processRedeemQueue both be permissioned, if so, should we make all withdrawals async?
// TODO: Refactor setChi to use nominal
// TODO: requestDepositWithPermit?
// TODO: Get pendingOfReceiver()/getPendingOfOwner() even needed?
// TODO: Ask Sam if we need to add capability for reducing deposit/redeem request amounts
// TODO: Ask Sam if we need to add capability for updating receiver in deposit/redeem requests
// TODO: Separate role based functions into dedicated sections?
// TODO: Remove functions in Liquidity internal helper functions?

/// @dev If the inheritance is updated, the functions in `initialize` must be updated as well.
///      Last updated for: `Initializable, UUPSUpgradeable, AccessControlEnumerableUpgradeable`.
contract SparkPrimeVault is AccessControlEnumerableUpgradeable, UUPSUpgradeable {

    /**********************************************************************************************/
    /*** Events and structs                                                                     ***/
    /**********************************************************************************************/

    event Approval(address indexed owner, address indexed spender, uint256 value);

    event Transfer(address indexed from, address indexed to, uint256 value);

    // TODO: Might be worth putting the savings shares as well.
    event DepositRequest(
        address indexed owner,
        address indexed recipient,
        uint256 indexed requestId,
        uint256         assets
    );

    event CancelDepositRequest(uint256 indexed requestId, uint256 assets);

    // Emitted when shares are minted to `recipient`, instantly or when a queued deposit is filled.
    event Deposit(address indexed owner, address indexed recipient, uint256 assets, uint256 shares);

    event RedeemRequest(
        address indexed owner,
        address indexed recipient,
        uint256 indexed requestId,
        uint256         shares,
        uint256         fee  // Burned upfront [shares]
    );

    event CancelRedeemRequest(uint256 indexed requestId, uint256 shares);

    // Emitted when savings assets are paid to `recipient`, instantly or when a queued redeem
    // is filled.
    event Redeem(
        address indexed owner,
        address indexed recipient,
        uint256         assets,
        uint256         shares
    );

    event Referral(uint16 indexed referral, address indexed recipient, uint256 assets);

    event CapacitySet(uint256 newCapacity);

    event ChiSet(uint192 chi);

    event Drip(uint192 chi, uint256 diff);

    event MaxRedeemFeeSet(uint256 fee);

    event MinimumsSet(uint256 minDeposit, uint256 minWithdraw);

    event Paused();

    // TODO: Should not have `to` as it can only ever be the caller.
    event Take(address indexed to, uint256 shares);

    event Unpaused();

    event VSRBoundsSet(uint256 minVSR, uint256 maxVSR);

    event VSRSet(uint256 vsr);

    event RedeemFeeSet(uint256 fee);


    struct Request {
        address owner;      // Recipient of refunds on cancel
        address recipient;  // Recipient of proceeds on fill
        uint256 shares;     // Shares in the request, can be savingsShares or shares
    }

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    // This corresponds to a 100% APY, verify here:
    // bc -l <<< 'scale=27; e( l(2)/(60 * 60 * 24 * 365) )'
    uint256 public constant MAX_VSR = 1.000000021979553151239153027e27;
    uint256 public constant RAY     = 1e27;
    uint256 public constant WAD     = 1e18;

    uint256 public constant MAX_REDEEM_FEE = 0.01e18;  // 1% [wad]

    bytes32 public constant GUARDIAN_ROLE     = keccak256("GUARDIAN_ROLE");
    bytes32 public constant REBALANCER_ROLE   = keccak256("REBALANCER_ROLE");
    bytes32 public constant RISK_MANAGER_ROLE = keccak256("RISK_MANAGER_ROLE");
    bytes32 public constant SETTER_ROLE       = keccak256("SETTER_ROLE");
    bytes32 public constant TAKER_ROLE        = keccak256("TAKER_ROLE");
    bytes32 public constant UNPAUSER_ROLE     = keccak256("UNPAUSER_ROLE");

    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );

    string public constant version = "1";

    /**********************************************************************************************/
    /*** Storage variables                                                                      ***/
    /**********************************************************************************************/

    address public savings;

    uint8 public decimals;

    string public name;
    string public symbol;

    uint64  public rho;    // Time of last drip              [unix epoch time]
    uint192 public chi;    // The Rate Accumulator           [ray]
    uint256 public vsr;    // The Vault Savings Rate         [ray]
    uint256 public minVSR; // The minimum Vault Savings Rate [ray]
    uint256 public maxVSR; // The maximum Vault Savings Rate [ray]

    bool public paused;

    uint256 public maxCapacity;  // Max totalSupply, escrow included [shares]
    uint256 public minDeposit;   // [savings asset units]
    uint256 public minWithdraw;  // [savings asset units]
    uint256 public redeemFee;    // Fee locked into new redeem requests [wad]
    uint256 public maxRedeemFee; // [wad]

    uint256 public totalSupply;

    uint256 public pendingDepositSavingsShares;
    uint256 public pendingRedeemShares;

    Request[] public depositQueue;
    Request[] public redeemQueue;

    uint256 public depositHead;  // First unfilled index of the deposit queue
    uint256 public redeemHead;   // First unfilled index of the redeem queue

    mapping (address account => uint256 balance) public balanceOf;
    mapping (address account => uint256 nonce)   public nonces;

    mapping (address account => mapping (address spender => uint256 amount)) public allowance;

    modifier whenNotPaused() {
        require(!paused, "SparkPrimeVault/paused");
        _;
    }

    /**********************************************************************************************/
    /*** Initialization and upgradeability                                                      ***/
    /**********************************************************************************************/

    constructor() {
        _disableInitializers(); // Avoid initializing in the context of the implementation
    }

    // NOTE: Neither UUPSUpgradeable nor AccessControlEnumerableUpgradeable require init functions
    //       to be called.
    function initialize(
        address        savings_,
        string  memory name_,
        string  memory symbol_,
        address        admin
    )
        initializer external
    {
        address asset_ = IERC4626Like(savings_).asset();

        savings  = savings_;
        name     = name_;
        symbol   = symbol_;
        decimals = IERC20Like(asset_).decimals();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        chi = uint192(RAY);
        rho = uint64(block.timestamp);
        vsr = RAY;

        minVSR = RAY;
        maxVSR = RAY;

        SafeERC20.forceApprove(IERC20OZ(asset_), savings_, type(uint256).max);
    }

    // Only DEFAULT_ADMIN_ROLE can upgrade the implementation
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**********************************************************************************************/
    /*** Admin external functions                                                               ***/
    /**********************************************************************************************/

    function setCapacity(uint256 capacity_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(capacity_ <= type(uint128).max, "SparkPrimeVault/capacity-too-high");
        emit CapacitySet(maxCapacity = capacity_);
    }

    function setMaxRedeemFee(uint256 fee_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(fee_ <= MAX_REDEEM_FEE, "SparkPrimeVault/fee-too-high");
        emit MaxRedeemFeeSet(maxRedeemFee = fee_);
    }

    function setMinimums(uint256 minDeposit_, uint256 minWithdraw_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        emit MinimumsSet(minDeposit = minDeposit_, minWithdraw = minWithdraw_);
    }

    function setVSRBounds(uint256 minVSR_, uint256 maxVSR_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(minVSR_ >= RAY,     "SparkPrimeVault/vsr-too-low");
        require(maxVSR_ <= MAX_VSR, "SparkPrimeVault/vsr-too-high");
        require(minVSR_ <= maxVSR_, "SparkPrimeVault/min-vsr-gt-max-vsr");

        emit VSRBoundsSet(minVSR = minVSR_, maxVSR = maxVSR_);
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused = false;
        emit Unpaused();
    }

    /**********************************************************************************************/
    /*** Role-based external functions                                                          ***/
    /**********************************************************************************************/

    function setVSR(uint256 vsr_) external onlyRole(SETTER_ROLE) {
        require(vsr_ >= minVSR, "SparkPrimeVault/vsr-too-low");
        require(vsr_ <= maxVSR, "SparkPrimeVault/vsr-too-high");

        drip();

        emit VSRSet(vsr = vsr_);
    }

    function take(uint256 savingsShares_) external onlyRole(TAKER_ROLE) {
        require(
            savingsShares_ <= IERC20Like(savings).balanceOf(address(this)),
            "SparkPrimeVault/insufficient-unencumbered-shares"
        );

        SafeERC20.safeTransfer(IERC20OZ(savings), msg.sender, savingsShares_);

        emit Take(msg.sender, savingsShares_);
    }

    function processDepositQueue(uint256 maxSavingsShares_, uint256 maxRequests_)
        external
        onlyRole(REBALANCER_ROLE)
        whenNotPaused
    {
        _processDepositQueue(maxSavingsShares_, maxRequests_);
    }

    // Pays queued redeemers FIFO, burning up to `maxShares_` shares within the available liquidity.
    function processRedeemQueue(uint256 maxShares_, uint256 maxRequests_)
        external
        onlyRole(REBALANCER_ROLE)
        whenNotPaused
    {
        _processRedeemQueue(maxShares_, maxRequests_);
    }

    // Nets the two queues against each other in one transaction. Redeems are processed first:
    // they are paid out of the spUSDC the queued depositors already hold in this contract, and
    // burning their shares frees exactly the capacity the queued deposits then fill. Running
    // the loops in the other order would stall on capacity before any redeem is paid.
    function processQueues(
        uint256 maxShares_,
        uint256 maxRedeemRequests_,
        uint256 maxDepositRequests_
    )
        external
        onlyRole(REBALANCER_ROLE)
        whenNotPaused
    {
        _processRedeemQueue(maxShares_, maxRedeemRequests_);
        _processDepositQueue(type(uint256).max, maxDepositRequests_);
    }

    function setRedeemFee(uint256 fee_) external onlyRole(RISK_MANAGER_ROLE) {
        require(fee_ <= maxRedeemFee, "SparkPrimeVault/fee-too-high");
        emit RedeemFeeSet(redeemFee = fee_);
    }

    function setChi(uint192 chi_) external onlyRole(RISK_MANAGER_ROLE) {
        require(paused,                    "SparkPrimeVault/not-paused");
        require(chi_ > 0 && chi_ < drip(), "SparkPrimeVault/invalid-chi");

        emit ChiSet(chi = chi_);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit Paused();
    }

    /**********************************************************************************************/
    /*** Request functions                                                                      ***/
    /**********************************************************************************************/

    // TODO: Make a `_requestDeposit` function instead of internally calling a public function.
    // Mints shares to `recipient_` for as much of `assets_` as the capacity allows, the rest waits
    // in the deposit queue as savings shares. Returns the queue index, or `type(uint256).max`
    // when nothing was queued.
    function requestDeposit(uint256 assets_, address recipient_)
        public
        whenNotPaused
        returns (uint256 requestId_)
    {
        require(recipient_ != address(0), "SparkPrimeVault/invalid-recipient");
        require(assets_ >= minDeposit,    "SparkPrimeVault/below-minimum");

        drip();

        bool depositInstantly_ = pendingDepositSavingsShares == 0;

        SafeERC20.safeTransferFrom(
            IERC20OZ(IERC4626Like(savings).asset()),
            msg.sender,
            address(this),
            assets_
        );

        uint256 savingsShares_ = IERC4626Like(savings).deposit(assets_, address(this));

        requestId_ = depositQueue.length;

        depositQueue
            .push(Request(msg.sender, recipient_, savingsShares_));

        pendingDepositSavingsShares += savingsShares_;

        emit DepositRequest(msg.sender, recipient_, requestId_, assets_);

        // Fill this request, only while nobody is queued ahead.
        if (depositInstantly_) {
            depositHead = requestId_;
            _processDepositQueue(type(uint256).max, 1);
        }
    }

    function requestDeposit(uint256 assets_, address recipient_, uint16 referral_)
        external
        returns (uint256 requestId_)
    {
        emit Referral(referral_, recipient_, assets_);
        return requestDeposit(assets_, recipient_);
    }

    // Refunds a queued deposit to its owner, with the savings yield it earned while waiting.
    function cancelDepositRequest(uint256 requestId_, address recipient_) whenNotPaused external {
        Request memory request_ = depositQueue[requestId_];

        require(request_.shares != 0, "SparkPrimeVault/no-request");

        require(
            msg.sender == request_.owner || hasRole(GUARDIAN_ROLE, msg.sender),
            "SparkPrimeVault/not-authorized"
        );

        delete depositQueue[requestId_];

        pendingDepositSavingsShares -= request_.shares;

        // REVIEW PATCH F-1: only the owner may choose the refund recipient.
        if (msg.sender != request_.owner) recipient_ = request_.owner;

        uint256 assets_ =
            IERC4626Like(savings).redeem(request_.shares, recipient_, address(this));

        emit CancelDepositRequest(requestId_, assets_);
    }

    // Escrows `shares_` and pays `recipient_` as much as the liquidity allows, the rest waits in
    // the redeem queue. Returns the queue index.
    function requestRedeem(uint256 shares_, address recipient_)
        external
        whenNotPaused
        returns (uint256 requestId_)
    {
        require(recipient_ != address(0), "SparkPrimeVault/invalid-recipient");

        require(
            (shares_ != 0) && ((shares_ * drip()) / RAY >= minWithdraw),
            "SparkPrimeVault/below-minimum"
        );

        bool redeemInstantly_ = pendingRedeemShares == 0;

        _transfer(msg.sender, address(this), shares_);

        // The fee is burned upfront in shares and is not refunded on cancel.
        uint256 fee_ = _divup(shares_ * redeemFee, WAD);

        _burn(address(this), fee_);

        uint256 queuedShares_ = shares_ - fee_;

        requestId_ = redeemQueue.length;

        redeemQueue.push(Request(msg.sender, recipient_, queuedShares_));

        pendingRedeemShares += queuedShares_;

        emit RedeemRequest(msg.sender, recipient_, requestId_, shares_, fee_);
    }

    function cancelRedeemRequest(uint256 requestId_, address recipient_) whenNotPaused external {
        Request memory request_ = redeemQueue[requestId_];

        require(request_.shares != 0, "SparkPrimeVault/no-request");

        require(
            msg.sender == request_.owner || hasRole(GUARDIAN_ROLE, msg.sender),
            "SparkPrimeVault/not-authorized"
        );

        delete redeemQueue[requestId_];

        // REVIEW PATCH F-1: only the owner may choose the refund recipient.
        if (msg.sender != request_.owner) recipient_ = request_.owner;

        _transfer(address(this), recipient_, request_.shares);

        pendingRedeemShares -= request_.shares;

        emit CancelRedeemRequest(requestId_, request_.shares);
    }

    /**********************************************************************************************/
    /*** ERC20 external mutating functions                                                      ***/
    /**********************************************************************************************/

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;

        emit Approval(msg.sender, spender_, amount_);

        return true;
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        require(to_ != address(0), "SparkPrimeVault/invalid-address");

        _transfer(msg.sender, to_, amount_);

        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        require(to_ != address(0),           "SparkPrimeVault/invalid-address");
        require(balanceOf[from_] >= amount_, "SparkPrimeVault/insufficient-balance");

        if (from_ != msg.sender) {
            uint256 allowance_ = allowance[from_][msg.sender];

            if (allowance_ != type(uint256).max) {
                require(allowance_ >= amount_, "SparkPrimeVault/insufficient-allowance");

                unchecked {
                    allowance[from_][msg.sender] = allowance_ - amount_;
                }
            }
        }

        _transfer(from_, to_, amount_);

        return true;
    }

    /**********************************************************************************************/
    /*** EIP712 external mutating functions                                                     ***/
    /**********************************************************************************************/

    function permit(
        address        owner_,
        address        spender_,
        uint256        value_,
        uint256        deadline_,
        bytes   memory signature_
    ) public {
        require(block.timestamp <= deadline_, "SparkPrimeVault/permit-expired");
        require(owner_ != address(0),         "SparkPrimeVault/invalid-owner");

        uint256 nonce;

        unchecked { nonce = nonces[owner_]++; }

        bytes32 digest =
            keccak256(abi.encodePacked(
                "\x19\x01",
                _calculateDomainSeparator(block.chainid),
                keccak256(abi.encode(
                    PERMIT_TYPEHASH,
                    owner_,
                    spender_,
                    value_,
                    nonce,
                    deadline_
                ))
            ));

        require(_isValidSignature(owner_, digest, signature_), "SparkPrimeVault/invalid-permit");

        emit Approval(owner_, spender_, allowance[owner_][spender_] = value_);
    }

    function permit(
        address owner_,
        address spender_,
        uint256 value_,
        uint256 deadline_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) external {
        permit(owner_, spender_, value_, deadline_, abi.encodePacked(r_, s_, v_));
    }

    /**********************************************************************************************/
    /*** Rate accumulation                                                                      ***/
    /**********************************************************************************************/

    function drip() public returns (uint192 nChi_) {
        uint192 chi_ = chi;
        uint64 rho_  = rho;

        if (block.timestamp <= rho_) return chi_;

        uint256 diff_;

        // Safe as `nChi_` is limited to maxUint256/RAY (which is < maxUint192).
        nChi_ = uint192((_rpow(vsr, block.timestamp - rho_) * chi_) / RAY);

        uint256 totalSupply_ = totalSupply;

        diff_ = (totalSupply_ * nChi_) / RAY - (totalSupply_ * chi_) / RAY;

        rho = uint64(block.timestamp);

        emit Drip(chi = nChi_, diff_);
    }

    /**********************************************************************************************/
    /*** External view functions                                                                ***/
    /**********************************************************************************************/

    function convertToAssets(uint256 shares_) public view returns (uint256) {
        return (shares_ * nowChi()) / RAY;
    }

    function convertToShares(uint256 assets_) public view returns (uint256) {
        return (assets_ * RAY) / nowChi();
    }

    function totalAssets() external view returns (uint256) {
        return convertToAssets(totalSupply);
    }

    function assetsOf(address owner_) external view returns (uint256) {
        return convertToAssets(balanceOf[owner_]);
    }

    function availableCapacity() public view returns (uint256) {
        return maxCapacity > totalSupply ? maxCapacity - totalSupply : 0;
    }

    function availableLiquidAssets() public view returns (uint256) {
        return IERC4626Like(savings).maxWithdraw(address(this));
    }

    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    function nowChi() public view returns (uint192) {
        return
            block.timestamp > rho
                ? uint192((_rpow(vsr, block.timestamp - rho) * chi) / RAY)
                : chi;
    }

    /**********************************************************************************************/
    /*** Request internal helper functions                                                      ***/
    /**********************************************************************************************/

    function _processDepositQueue(uint256 maxSavingsShares_, uint256 maxRequests_) internal {
        drip();

        // Convert the maximum admissible assets into savings shares denomination
        uint256 remaining_ = _min(
            maxSavingsShares_,
            IERC4626Like(savings).convertToShares(convertToAssets(availableCapacity()))
        );

        // Process the deposit queue up to the maximum number of requests or
        // until there are no more remaining savings shares
        uint256 i_   = depositHead;
        uint256 end_ = i_ + _min(depositQueue.length - i_, maxRequests_);

        for (; i_ < end_ && remaining_ != 0; ++i_) {
            Request storage request = depositQueue[i_];

            uint256 requestSavingsShares_ = request.shares;

            if (requestSavingsShares_ == 0) continue;  // Cancelled

            uint256 savingsShares_ = _min(requestSavingsShares_, remaining_);

            // Convert processed savings shares into vault shares
            uint256 assets_ = IERC4626Like(savings).convertToAssets(savingsShares_);
            uint256 shares_ = convertToShares(assets_);

            pendingDepositSavingsShares -= savingsShares_;
            request.shares       -= savingsShares_;
            remaining_           -= savingsShares_;

            _mint(request.recipient, shares_);

            emit Deposit(request.owner, request.recipient, assets_, shares_);

            if (request.shares != 0) break;  // Partial fill, entry stays at the head (REVIEW PATCH F-3)
        }

        depositHead = i_;
    }

    // Pays queued redeems FIFO, burning up to `maxShares_` held shares within the available
    // liquidity.
    function _processRedeemQueue(uint256 maxShares_, uint256 maxRequests_) internal {
        drip();

        uint256 remaining_ = _min(maxShares_, convertToShares(availableLiquidAssets()));

        uint256 i_   = redeemHead;
        uint256 end_ = i_ + _min(redeemQueue.length - i_, maxRequests_);

        for (; i_ < end_ && remaining_ != 0; ++i_) {
            Request storage request = redeemQueue[i_];

            uint256 requestShares_ = request.shares;

            if (requestShares_ == 0) continue;  // Cancelled

            uint256 shares_ = _min(requestShares_, remaining_);
            uint256 assets_ = convertToAssets(shares_);

            pendingRedeemShares -= shares_;
            request.shares            -= shares_;
            remaining_                -= shares_;

            _burn(address(this), shares_);

            emit Redeem(request.owner, request.recipient, assets_, shares_);

            IERC4626Like(savings).withdraw(assets_, request.recipient, address(this));

            if (request.shares != 0) break;  // Partial fill, entry stays at the head
        }

        redeemHead = i_;
    }

    /**********************************************************************************************/
    /*** ERC20 internal helper functions                                                        ***/
    /**********************************************************************************************/

    // Burns shares from `account_`.
    function _burn(address account_, uint256 shares_) internal {
        totalSupply         -= shares_;
        balanceOf[account_] -= shares_;

        emit Transfer(account_, address(0), shares_);
    }

    // Mints shares to `recipient_` at the current price
    function _mint(address recipient_, uint256 shares_) internal {
        totalSupply           += shares_;
        balanceOf[recipient_] += shares_;

        emit Transfer(address(0), recipient_, shares_);
    }

    function _transfer(address from_, address to_, uint256 amount_) internal {
        uint256 balance = balanceOf[from_];

        require(balance >= amount_, "SparkPrimeVault/insufficient-balance");

        // NOTE: Don't need an overflow check here b/c sum of all balances == totalSupply.
        unchecked {
            balanceOf[from_] = balance - amount_;

            balanceOf[to_] += amount_;
        }

        emit Transfer(from_, to_, amount_);
    }

    /**********************************************************************************************/
    /*** EIP712 internal helper functions                                                       ***/
    /**********************************************************************************************/

    function _calculateDomainSeparator(uint256 chainId_) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId_,
                address(this)
            )
        );
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _calculateDomainSeparator(block.chainid);
    }

    function _isValidSignature(
        address        signer_,
        bytes32        digest_,
        bytes   memory signature_
    ) internal view returns (bool) {
        if (signature_.length == 65) {
            bytes32 r_;
            bytes32 s_;
            uint8   v_;

            assembly {
                r_ := mload(add(signature_, 0x20))
                s_ := mload(add(signature_, 0x40))
                v_ := byte(0, mload(add(signature_, 0x60)))
            }

            if (signer_ == ecrecover(digest_, v_, r_, s_)) return true;
        }

        if (signer_.code.length == 0) return false;

        (bool success, bytes memory result) = signer_.staticcall(
            abi.encodeCall(IERC1271.isValidSignature, (digest_, signature_))
        );

        return
            success &&
            result.length == 32 &&
            abi.decode(result, (bytes4)) == IERC1271.isValidSignature.selector;
    }

    /**********************************************************************************************/
    /*** General internal helper functions                                                      ***/
    /**********************************************************************************************/

    function _divup(uint256 x_, uint256 y_) internal pure returns (uint256 z_) {
        // NOTE: _divup(0,0) will return 0 differing from natural solidity division
        unchecked {
            z_ = x_ != 0 ? ((x_ - 1) / y_) + 1 : 0;
        }
    }

    function _min(uint256 x_, uint256 y_) internal pure returns (uint256) {
        return x_ < y_ ? x_ : y_;
    }

    function _rpow(uint256 x_, uint256 n_) internal pure returns (uint256 z_) {
        assembly {
            switch x_ case 0 {switch n_ case 0 {z_ := RAY} default {z_ := 0}}
            default {
                switch mod(n_, 2) case 0 { z_ := RAY } default { z_ := x_ }
                let half := div(RAY, 2)  // for rounding.
                for { n_ := div(n_, 2) } n_ { n_ := div(n_, 2) } {
                    let xx := mul(x_, x_)
                    if iszero(eq(div(xx, x_), x_)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x_ := div(xxRound, RAY)
                    if mod(n_, 2) {
                        let zx := mul(z_, x_)
                        if and(iszero(iszero(x_)), iszero(eq(div(zx, x_), z_))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z_ := div(zxRound, RAY)
                    }
                }
            }
        }
    }

}
