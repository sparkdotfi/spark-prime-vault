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

    function maxRedeem(address owner) external view returns (uint256);

    function maxWithdraw(address owner) external view returns (uint256);

}

interface IBlacklistableLike {

    function isBlacklisted(address account) external view returns (bool);

}

/// @dev If the inheritance is updated, the functions in `initialize` must be updated as well.
///      Last updated for: `Initializable, UUPSUpgradeable, AccessControlEnumerableUpgradeable`.
contract SparkPrimeVault is AccessControlEnumerableUpgradeable, UUPSUpgradeable {

    /**********************************************************************************************/
    /*** Custom Errors                                                                          ***/
    /**********************************************************************************************/

    error BelowMinDeposit();

    error BelowMinRedeem();

    error ChiTooHigh();

    error ChiTooLow();

    error FeeTooHigh();

    error InsufficientShares();

    error InvalidRange();

    error InvalidRequestId();

    error IsNotPaused();

    error IsPaused();

    error LossTooHigh();

    error MaxFeeTooHigh();

    error MaxVSRTooHigh();

    error MinVSRGtMaxVSR();

    error MinVSRTooLow();

    error NoRequest();

    error NothingToClaim();

    error NotRequestOwner();

    error RecipientCannotReceive();

    error VaultIsRecipient();

    error VSRTooHigh();

    error VSRTooLow();

    error ZeroDeltaTotalAssets();

    error ZeroRecipient();

    /**********************************************************************************************/
    /*** Events and structs                                                                     ***/
    /**********************************************************************************************/

    event Approval(address indexed owner, address indexed spender, uint256 value);

    event Transfer(address indexed from, address indexed to, uint256 value);

    event TotalAssetsAdjusted(uint192 chi, int256 deltaTotalAssets);

    event Referral(
        uint16  indexed referral,
        uint256 indexed requestId,
        address         owner,
        address         recipient,
        uint256         assets
    );

    event DepositRequest(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         assetsDeposited,
        uint256         savingsSharesMinted
    );

    event DepositRecipientUpdated(uint256 indexed requestId, address indexed recipient);

    event Deposit(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         savingsSharesConsumed,
        uint256         assetsConverted,
        uint256         sharesMinted
    );

    event DepositCancellationRequest(
        uint256 indexed depositRequestId,
        uint256 indexed cancelRequestId,
        address indexed recipient
    );

    event DepositCancellationRecipientUpdated(uint256 indexed requestId, address indexed recipient);

    event DepositCancellation(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         savingsSharesBurned,
        uint256         assetsReceived
    );

    event RedeemRequest(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         sharesToBurn,
        uint256         feeSharesBurned
    );

    event RedeemRecipientUpdated(uint256 indexed requestId, address indexed recipient);

    event Redeem(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         sharesBurned,
        uint256         savingsSharesBurned,
        uint256         assetsReceived
    );

    event ClaimableAssetsIncreased(address indexed recipient, uint256 increase);

    event Claim(address indexed recipient, uint256 assets);

    event CapacitySet(uint256 capacity);

    event Drip(uint192 chi, uint256 diff);

    event MaxRedeemFeeRateSet(uint256 fee);

    event MinDepositSet(uint256 minDeposit);

    event MinRedeemSet(uint256 minRedeem);

    event Paused();

    event Take(uint256 shares);

    event Unpaused();

    event VSRBoundsSet(uint256 minVSR, uint256 maxVSR);

    event VSRSet(uint256 vsr);

    event RedeemFeeRateSet(uint256 fee);

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

    bytes32 public constant GUARDIAN_ROLE          = keccak256("GUARDIAN_ROLE");
    bytes32 public constant PROCESSOR_ROLE         = keccak256("PROCESSOR_ROLE");
    bytes32 public constant REDEEM_FEE_SETTER_ROLE = keccak256("REDEEM_FEE_SETTER_ROLE");
    bytes32 public constant TAKER_ROLE             = keccak256("TAKER_ROLE");
    bytes32 public constant VSR_SETTER_ROLE        = keccak256("VSR_SETTER_ROLE");

    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );

    string public constant version = "1";

    /**********************************************************************************************/
    /*** Storage variables                                                                      ***/
    /**********************************************************************************************/

    Request[] internal _depositRequests;
    Request[] internal _depositCancellationRequests;
    Request[] internal _redeemRequests;

    address public savings;
    address public asset;

    bool public paused;

    string public name;
    string public symbol;

    uint8 public decimals;

    uint64  public rho;    // Time of last drip              [unix epoch time]
    uint192 public chi;    // The Rate Accumulator           [ray]
    uint256 public vsr;    // The Vault Savings Rate         [ray]
    uint256 public minVSR; // The minimum Vault Savings Rate [ray]
    uint256 public maxVSR; // The maximum Vault Savings Rate [ray]

    uint256 public maxCapacity;      // Max totalSupply
    uint256 public minDeposit;       // [savings asset units]
    uint256 public minRedeem;        // [shares units]
    uint256 public redeemFeeRate;    // Fee rate burned in redeem requests [wad]
    uint256 public maxRedeemFeeRate; // [wad]

    uint256 public totalSupply;

    uint256 public pendingDepositSavingsShares;
    uint256 public pendingCancelledDepositSavingsShares;
    uint256 public pendingRedeemShares;

    uint256 public firstPendingDepositId;              // First unfilled index of the deposit queue
    uint256 public firstPendingDepositCancellationId;  // First unfilled index of the cancelled deposit queue
    uint256 public firstPendingRedeemId;               // First unfilled index of the redeem queue

    mapping (address account => uint256 balance) public balanceOf;
    mapping (address account => uint256 nonce)   public nonces;

    mapping (address account => uint256 assets) public claimableAssets;

    mapping (address account => mapping (address spender => uint256 amount)) public allowance;

    modifier whenNotPaused() {
        require(!paused, IsPaused());
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
        asset    = asset_;
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

    // Only DEFAULT_ADMIN_ROLE can upgrade the implementation.
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**********************************************************************************************/
    /*** Admin external functions                                                               ***/
    /**********************************************************************************************/

    function adjustTotalAssets(int256 deltaTotalAssets_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(paused,                 IsNotPaused());
        require(deltaTotalAssets_ != 0, ZeroDeltaTotalAssets());

        drip();

        int256 totalAssets_ = int256(totalAssets()) + deltaTotalAssets_;

        require(totalAssets_ > 0, LossTooHigh());

        // NOTE: Assuming totalSupply is not zero
        uint256 updatedChi_ = uint256(totalAssets_) * RAY / totalSupply;

        require(updatedChi_ != 0,                 ChiTooLow());
        require(updatedChi_ <= type(uint192).max, ChiTooHigh());

        emit TotalAssetsAdjusted(chi = uint192(updatedChi_), deltaTotalAssets_);
    }

    function setCapacity(uint256 capacity_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit CapacitySet(maxCapacity = capacity_);
    }

    function setMaxRedeemFeeRate(uint256 feeRate_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(feeRate_ <= MAX_REDEEM_FEE, MaxFeeTooHigh());
        emit MaxRedeemFeeRateSet(maxRedeemFeeRate = feeRate_);
    }

    function setMinDeposit(uint256 minDeposit_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit MinDepositSet(minDeposit = minDeposit_);
    }

    function setMinRedeem(uint256 minRedeem_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit MinRedeemSet(minRedeem = minRedeem_);
    }

    function setVSRBounds(uint256 minVSR_, uint256 maxVSR_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(minVSR_ >= RAY,     MinVSRTooLow());
        require(maxVSR_ <= MAX_VSR, MaxVSRTooHigh());
        require(minVSR_ <= maxVSR_, MinVSRGtMaxVSR());

        emit VSRBoundsSet(minVSR = minVSR_, maxVSR = maxVSR_);
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused = false;
        emit Unpaused();
    }

    /**********************************************************************************************/
    /*** VSR Setter external functions                                                          ***/
    /**********************************************************************************************/

    function setVSR(uint256 vsr_) external onlyRole(VSR_SETTER_ROLE) {
        require(vsr_ >= minVSR, VSRTooLow());
        require(vsr_ <= maxVSR, VSRTooHigh());

        drip();

        emit VSRSet(vsr = vsr_);
    }

    /**********************************************************************************************/
    /*** Taker external functions                                                               ***/
    /**********************************************************************************************/

    function take(uint256 savingsShares_) external onlyRole(TAKER_ROLE) {
        require(
            savingsShares_ <= IERC20Like(savings).balanceOf(address(this)),
            InsufficientShares()
        );

        SafeERC20.safeTransfer(IERC20OZ(savings), msg.sender, savingsShares_);

        emit Take(savingsShares_);
    }

    /**********************************************************************************************/
    /*** Processor external functions                                                           ***/
    /**********************************************************************************************/

    function processPendingDeposits(uint256 maxSavingsShares_, uint256 maxRequests_)
        external
        onlyRole(PROCESSOR_ROLE)
        whenNotPaused
    {
        _processPendingDeposits(maxSavingsShares_, maxRequests_);
    }

    function processPendingDepositCancellations(uint256 maxSavingsShares_, uint256 maxRequests_)
        external
        onlyRole(PROCESSOR_ROLE)
        whenNotPaused
    {
        _processPendingDepositCancellations(maxSavingsShares_, maxRequests_);
    }

    function processPendingRedeems(uint256 maxShares_, uint256 maxRequests_)
        external
        onlyRole(PROCESSOR_ROLE)
        whenNotPaused
    {
        _processPendingRedeems(maxShares_, maxRequests_);
    }

    /**********************************************************************************************/
    /*** Redeem Fee Setter external functions                                                   ***/
    /**********************************************************************************************/

    function setRedeemFeeRate(uint256 feeRate_) external onlyRole(REDEEM_FEE_SETTER_ROLE) {
        require(feeRate_ <= maxRedeemFeeRate, FeeTooHigh());
        emit RedeemFeeRateSet(redeemFeeRate = feeRate_);
    }

    /**********************************************************************************************/
    /*** Guardian external functions                                                            ***/
    /**********************************************************************************************/

    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit Paused();
    }

    /**********************************************************************************************/
    /*** Request functions                                                                      ***/
    /**********************************************************************************************/

    function requestDeposit(uint256 assets_, address recipient_, uint16 referral_)
        external
        whenNotPaused
        returns (uint256 requestId_)
    {
        require(recipient_ != address(0),    ZeroRecipient());
        require(recipient_ != address(this), VaultIsRecipient());
        require(assets_ >= minDeposit,       BelowMinDeposit());

        drip();

        SafeERC20.safeTransferFrom(IERC20OZ(asset), msg.sender, address(this), assets_);

        uint256 savingsShares_ = IERC4626Like(savings).deposit(assets_, address(this));

        requestId_ = _depositRequests.length;

        _depositRequests.push(Request(msg.sender, recipient_, savingsShares_));

        pendingDepositSavingsShares += savingsShares_;

        emit Referral(referral_, requestId_, msg.sender, recipient_, assets_);
        emit DepositRequest(requestId_, msg.sender, recipient_, assets_, savingsShares_);

        // Fill this request, only while no nonzero requests are queued ahead.
        if (pendingDepositSavingsShares == savingsShares_) {
            _processPendingDeposits(type(uint256).max, type(uint256).max);
        }
    }

    function requestDepositCancellation(uint256 requestId_, address recipient_)
        whenNotPaused
        external
        returns (uint256 newRequestId_)
    {
        require(recipient_ != address(0),     ZeroRecipient());
        require(recipient_ != address(this),  VaultIsRecipient());
        require(_canReceiveAsset(recipient_), RecipientCannotReceive());

        Request memory request_ = _depositRequests[requestId_];

        require(request_.shares != 0,         NoRequest());
        require(msg.sender == request_.owner, NotRequestOwner());

        delete _depositRequests[requestId_];

        newRequestId_ = _depositCancellationRequests.length;

        _depositCancellationRequests.push(
            Request(request_.owner, recipient_, request_.shares)
        );

        pendingDepositSavingsShares          -= request_.shares;
        pendingCancelledDepositSavingsShares += request_.shares;

        emit DepositCancellationRequest(requestId_, newRequestId_, recipient_);
    }

    function requestRedeem(uint256 shares_, address recipient_)
        external
        whenNotPaused
        returns (uint256 requestId_)
    {
        require(recipient_ != address(0),     ZeroRecipient());
        require(recipient_ != address(this),  VaultIsRecipient());
        require(_canReceiveAsset(recipient_), RecipientCannotReceive());
        require(shares_ >= minRedeem,         BelowMinRedeem());

        drip();

        _transfer(msg.sender, address(this), shares_);

        // The fee is burned upfront in shares.
        uint256 fee_ = _divUp(shares_ * redeemFeeRate, WAD);

        _burn(address(this), fee_);

        uint256 queuedShares_ = shares_ - fee_;

        requestId_ = _redeemRequests.length;

        _redeemRequests.push(Request(msg.sender, recipient_, queuedShares_));

        pendingRedeemShares += queuedShares_;

        emit RedeemRequest(requestId_, msg.sender, recipient_, shares_, fee_);
    }

    /**********************************************************************************************/
    /*** Request update functions                                                               ***/
    /**********************************************************************************************/

    function updateDepositRecipient(uint256 requestId_, address recipient_) external {
        require(recipient_ != address(0),             ZeroRecipient());
        require(recipient_ != address(this),          VaultIsRecipient());
        require(requestId_ < _depositRequests.length, InvalidRequestId());

        Request storage request_ = _depositRequests[requestId_];

        require(request_.shares != 0,         NoRequest());
        require(msg.sender == request_.owner, NotRequestOwner());

        emit DepositRecipientUpdated(requestId_, request_.recipient = recipient_);
    }

    function updateDepositCancellationRecipient(uint256 requestId_, address recipient_) external {
        require(recipient_ != address(0),                         ZeroRecipient());
        require(recipient_ != address(this),                      VaultIsRecipient());
        require(_canReceiveAsset(recipient_),                     RecipientCannotReceive());
        require(requestId_ < _depositCancellationRequests.length, InvalidRequestId());

        Request storage request_ = _depositCancellationRequests[requestId_];

        require(request_.shares != 0,         NoRequest());
        require(msg.sender == request_.owner, NotRequestOwner());

        emit DepositCancellationRecipientUpdated(
            requestId_,
            request_.recipient = recipient_
        );
    }

    function updateRedeemRecipient(uint256 requestId_, address recipient_) external {
        require(recipient_ != address(0),            ZeroRecipient());
        require(recipient_ != address(this),         VaultIsRecipient());
        require(_canReceiveAsset(recipient_),        RecipientCannotReceive());
        require(requestId_ < _redeemRequests.length, InvalidRequestId());

        Request storage request_ = _redeemRequests[requestId_];

        require(request_.shares != 0,         NoRequest());
        require(msg.sender == request_.owner, NotRequestOwner());

        emit RedeemRecipientUpdated(requestId_, request_.recipient = recipient_);
    }

    /**********************************************************************************************/
    /*** Claim functions                                                                        ***/
    /**********************************************************************************************/

    // Permissionless, assets always go to `recipient_`.
    // Reverts in the asset while still blacklisted.
    function claim(address recipient_) external returns (uint256 assets_) {
        assets_ = claimableAssets[recipient_];

        require(assets_ != 0, NothingToClaim());

        claimableAssets[recipient_] = 0;

        emit Claim(recipient_, assets_);

        SafeERC20.safeTransfer(IERC20OZ(asset), recipient_, assets_);
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
        require(to_ != address(0) && to_ != address(this), "SparkPrimeVault/invalid-address");

        _transfer(msg.sender, to_, amount_);

        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        require(to_ != address(0) && to_ != address(this), "SparkPrimeVault/invalid-address");

        _transfer(from_, to_, amount_);

        if (from_ != msg.sender) {
            uint256 allowance_ = allowance[from_][msg.sender];

            if (allowance_ != type(uint256).max) {
                require(allowance_ >= amount_, "SparkPrimeVault/insufficient-allowance");

                unchecked {
                    allowance[from_][msg.sender] = allowance_ - amount_;
                }
            }
        }

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
        uint8   v_,
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
        uint64  rho_ = rho;

        if (block.timestamp <= rho_) return chi_;

        // Safe as `nChi_` is limited to maxUint256/RAY (which is < maxUint192).
        nChi_ = uint192((_rpow(vsr, block.timestamp - rho_) * chi_) / RAY);

        uint256 totalSupply_ = totalSupply;
        uint256 diff_        = (totalSupply_ * nChi_) / RAY - (totalSupply_ * chi_) / RAY;

        rho = uint64(block.timestamp);

        emit Drip(chi = nChi_, diff_);
    }

    /**********************************************************************************************/
    /*** Request getter functions                                                               ***/
    /**********************************************************************************************/

    function getPendingDepositRequest(uint256 requestId_)
        external
        view
        returns (address owner_, address recipient_, uint256 shares_)
    {
        require(
            requestId_ >= firstPendingDepositId && requestId_ < _depositRequests.length,
            InvalidRequestId()
        );

        Request storage request_ = _depositRequests[requestId_];

        return (request_.owner, request_.recipient, request_.shares);
    }

    function getPendingDepositRequests() external view returns (Request[] memory requests_) {
        uint256 pendingLength_ = _depositRequests.length;

        requests_ = new Request[](pendingLength_ - firstPendingDepositId);

        for (uint256 i_ = firstPendingDepositId; i_ < pendingLength_; ++i_) {
            requests_[i_ - firstPendingDepositId] = _depositRequests[i_];
        }
    }

    function getPendingDepositRequests(uint256 startId_, uint256 endId_)
        external
        view
        returns (Request[] memory requests_)
    {
        require((startId_ <= endId_) && (endId_ <= _depositRequests.length), InvalidRange());

        requests_ = new Request[](endId_ - startId_);

        for (uint256 i_ = startId_; i_ < endId_; ++i_) {
            requests_[i_ - startId_] = _depositRequests[i_];
        }
    }

    function getPendingDepositCancellationRequest(uint256 requestId_)
        external
        view
        returns (address owner_, address recipient_, uint256 shares_)
    {
        require(
            requestId_ >= firstPendingDepositCancellationId &&
            requestId_ < _depositCancellationRequests.length,
            InvalidRequestId()
        );

        Request storage request_ = _depositCancellationRequests[requestId_];

        return (request_.owner, request_.recipient, request_.shares);
    }

    function getPendingDepositCancellationRequests()
        external
        view
        returns (Request[] memory requests_)
    {
        uint256 pendingLength_ = _depositCancellationRequests.length;

        requests_ = new Request[](pendingLength_ - firstPendingDepositCancellationId);

        for (uint256 i_ = firstPendingDepositCancellationId; i_ < pendingLength_; ++i_) {
            requests_[i_ - firstPendingDepositCancellationId] = _depositCancellationRequests[i_];
        }
    }

    function getPendingDepositCancellationRequests(uint256 startId_, uint256 endId_)
        external
        view
        returns (Request[] memory requests_)
    {
        require(
            (startId_ <= endId_) && (endId_ <= _depositCancellationRequests.length),
            InvalidRange()
        );

        requests_ = new Request[](endId_ - startId_);

        for (uint256 i_ = startId_; i_ < endId_; ++i_) {
            requests_[i_ - startId_] = _depositCancellationRequests[i_];
        }
    }

    function getPendingRedeemRequest(uint256 requestId_)
        external
        view
        returns (address owner_, address recipient_, uint256 shares_)
    {
        require(
            requestId_ >= firstPendingRedeemId && requestId_ < _redeemRequests.length,
            InvalidRequestId()
        );

        Request storage request_ = _redeemRequests[requestId_];

        return (request_.owner, request_.recipient, request_.shares);
    }

    function getPendingRedeemRequests() external view returns (Request[] memory requests_) {
        uint256 pendingLength_ = _redeemRequests.length;

        requests_ = new Request[](pendingLength_ - firstPendingRedeemId);

        for (uint256 i_ = firstPendingRedeemId; i_ < pendingLength_; ++i_) {
            requests_[i_ - firstPendingRedeemId] = _redeemRequests[i_];
        }
    }

    function getPendingRedeemRequests(uint256 startId_, uint256 endId_)
        external
        view
        returns (Request[] memory requests_)
    {
        require((startId_ <= endId_) && (endId_ <= _redeemRequests.length), InvalidRange());

        requests_ = new Request[](endId_ - startId_);

        for (uint256 i_ = startId_; i_ < endId_; ++i_) {
            requests_[i_ - startId_] = _redeemRequests[i_];
        }
    }

    /**********************************************************************************************/
    /*** External view functions                                                                ***/
    /**********************************************************************************************/

    function assetsOf(address owner_) external view returns (uint256) {
        return convertToAssets(balanceOf[owner_]);
    }

    function availableCapacity() public view returns (uint256) {
        return maxCapacity > totalSupply ? maxCapacity - totalSupply : 0;
    }

    function availableLiquidAssets() public view returns (uint256) {
        return IERC4626Like(savings).maxWithdraw(address(this));
    }

    function convertToAssets(uint256 shares_) public view returns (uint256) {
        return (shares_ * nowChi()) / RAY;
    }

    function convertToShares(uint256 assets_) public view returns (uint256) {
        return (assets_ * RAY) / nowChi();
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _calculateDomainSeparator(block.chainid);
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

    function totalAssets() public view returns (uint256) {
        return convertToAssets(totalSupply);
    }

    /**********************************************************************************************/
    /*** Queue internal helper functions                                                        ***/
    /**********************************************************************************************/

    function _processPendingDeposits(uint256 maxSavingsShares_, uint256 maxRequests_) internal {
        drip();

        // Convert the maximum admissible assets into savings shares denomination
        uint256 remaining_ = _min(
            maxSavingsShares_,
            IERC4626Like(savings).convertToShares(convertToAssets(availableCapacity()))
        );

        // Process the deposit queue up to the maximum number of requests or until there are no more
        // remaining savings shares.
        uint256 i_   = firstPendingDepositId;
        uint256 end_ = i_ + _min(_depositRequests.length - i_, maxRequests_);

        for (; i_ < end_ && remaining_ != 0; ++i_) {
            Request storage request_ = _depositRequests[i_];

            if (request_.shares == 0) continue;  // Cancelled

            uint256 savingsShares_ = _min(request_.shares, remaining_);

            // Convert processed savings shares into vault shares.
            uint256 assets_ = IERC4626Like(savings).convertToAssets(savingsShares_);
            uint256 shares_ = convertToShares(assets_);

            pendingDepositSavingsShares -= savingsShares_;
            request_.shares             -= savingsShares_;
            remaining_                  -= savingsShares_;

            _mint(request_.recipient, shares_);

            emit Deposit(i_, request_.owner, request_.recipient, savingsShares_, assets_, shares_);

            if (request_.shares != 0) break;  // Partial fill, entry stays at the head

            delete _depositRequests[i_];
        }

        firstPendingDepositId = i_;
    }

    function _processPendingDepositCancellations(uint256 maxSavingsShares_, uint256 maxRequests_)
        internal
    {
        drip();

        uint256 remaining_ =
            _min(maxSavingsShares_, IERC4626Like(savings).maxRedeem(address(this)));

        // Process the cancelled deposit queue up to the maximum number of requests or until there
        // are no more remaining savings shares.
        uint256 i_   = firstPendingDepositCancellationId;
        uint256 end_ = i_ + _min(_depositCancellationRequests.length - i_, maxRequests_);

        for (; i_ < end_ && remaining_ != 0; ++i_) {
            Request storage request_ = _depositCancellationRequests[i_];

            if (request_.shares == 0) continue;  // Cancelled

            uint256 savingsShares_ = _min(request_.shares, remaining_);

            pendingCancelledDepositSavingsShares -= savingsShares_;
            request_.shares                      -= savingsShares_;
            remaining_                           -= savingsShares_;

            uint256 assets_ = _redeemSavings(savingsShares_, request_.recipient);

            emit DepositCancellation(
                i_,
                request_.owner,
                request_.recipient,
                savingsShares_,
                assets_
            );

            if (request_.shares != 0) break;  // Partial fill, entry stays at the head

            delete _depositCancellationRequests[i_];
        }

        firstPendingDepositCancellationId = i_;
    }

    function _processPendingRedeems(uint256 maxShares_, uint256 maxRequests_) internal {
        drip();

        uint256 remaining_ = _min(maxShares_, convertToShares(availableLiquidAssets()));

        uint256 i_   = firstPendingRedeemId;
        uint256 end_ = i_ + _min(_redeemRequests.length - i_, maxRequests_);

        for (; i_ < end_ && remaining_ != 0; ++i_) {
            Request storage request_ = _redeemRequests[i_];

            if (request_.shares == 0) continue;  // Empty

            uint256 shares_ = _min(request_.shares, remaining_);
            uint256 assets_ = convertToAssets(shares_);

            pendingRedeemShares -= shares_;
            request_.shares     -= shares_;
            remaining_          -= shares_;

            _burn(address(this), shares_);

            uint256 savingsShares_ = _withdrawSavings(assets_, request_.recipient);

            emit Redeem(i_, request_.owner, request_.recipient, shares_, savingsShares_, assets_);

            if (request_.shares != 0) break;  // Partial fill, entry stays at the head

            delete _redeemRequests[i_];
        }

        firstPendingRedeemId = i_;
    }

    function _redeemSavings(uint256 savingsShares_, address recipient_)
        internal
        returns (uint256 assets_)
    {
        try IERC4626Like(savings).redeem(savingsShares_, recipient_, address(this))
            returns (uint256 assetsRedeemed_)
        {
            return assetsRedeemed_;
        } catch {}

        assets_ = IERC4626Like(savings).redeem(savingsShares_, address(this), address(this));

        _incrementClaimableAssets(recipient_, assets_);
    }

    function _withdrawSavings(uint256 assets_, address recipient_)
        internal
        returns (uint256 savingsShares_)
    {
        try IERC4626Like(savings).withdraw(assets_, recipient_, address(this))
            returns (uint256 savingsSharesBurned_)
        {
            return savingsSharesBurned_;
        } catch {}

        savingsShares_ = IERC4626Like(savings).withdraw(assets_, address(this), address(this));

        _incrementClaimableAssets(recipient_, assets_);
    }

    /**********************************************************************************************/
    /*** ERC20 internal helper functions                                                        ***/
    /**********************************************************************************************/

    function _burn(address account_, uint256 shares_) internal {
        totalSupply         -= shares_;
        balanceOf[account_] -= shares_;

        emit Transfer(account_, address(0), shares_);
    }

    function _mint(address recipient_, uint256 shares_) internal {
        totalSupply           += shares_;
        balanceOf[recipient_] += shares_;

        emit Transfer(address(0), recipient_, shares_);
    }

    function _transfer(address from_, address to_, uint256 amount_) internal {
        uint256 balance_ = balanceOf[from_];

        require(balance_ >= amount_, "SparkPrimeVault/insufficient-balance");

        // NOTE: Don't need an overflow check here b/c sum of all balances == totalSupply.
        unchecked {
            balanceOf[from_] = balance_ - amount_;

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

        ( bool success_, bytes memory result_ ) = signer_.staticcall(
            abi.encodeCall(IERC1271.isValidSignature, (digest_, signature_))
        );

        return
            success_ &&
            result_.length == 32 &&
            abi.decode(result_, (bytes4)) == IERC1271.isValidSignature.selector;
    }

    /**********************************************************************************************/
    /*** Blacklist internal helper functions                                                    ***/
    /**********************************************************************************************/

    function _incrementClaimableAssets(address recipient_, uint256 assets_) internal {
        claimableAssets[recipient_] += assets_;

        emit ClaimableAssetsIncreased(recipient_, assets_);
    }

    // NOTE: Assumes the asset exposes `isBlacklisted` (USDC/EURC). Override for other assets.
    function _canReceiveAsset(address account_) internal view virtual returns (bool) {
        return !IBlacklistableLike(asset).isBlacklisted(account_);
    }

    /**********************************************************************************************/
    /*** General internal helper functions                                                      ***/
    /**********************************************************************************************/

    function _divUp(uint256 x_, uint256 y_) internal pure returns (uint256) {
        // NOTE: _divUp(0,0) will return 0 differing from natural solidity division.
        unchecked {
            return x_ != 0 ? ((x_ - 1) / y_) + 1 : 0;
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
