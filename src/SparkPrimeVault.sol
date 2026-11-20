// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ERC1967Utils }    from "../lib/oz/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { UUPSUpgradeable } from "../lib/oz/contracts/proxy/utils/UUPSUpgradeable.sol";

import { SafeERC20, IERC20 as IERC20OZ } from "../lib/oz/contracts/token/ERC20/utils/SafeERC20.sol";

import { AccessControlEnumerableUpgradeable }
    from "../lib/oz-upgradeable/contracts/access/extensions/AccessControlEnumerableUpgradeable.sol";

import { ISparkPrimeVault } from "./ISparkPrimeVault.sol";

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

    function asset() external view returns (address);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function convertToShares(uint256 assets) external view returns (uint256 shares);

    function maxRedeem(address owner) external view returns (uint256);

    function maxWithdraw(address owner) external view returns (uint256);

}

/*

  ███████╗██████╗  █████╗ ██████╗ ██╗  ██╗
  ██╔════╝██╔══██╗██╔══██╗██╔══██╗██║ ██╔╝
  ███████╗██████╔╝███████║██████╔╝█████╔╝
  ╚════██║██╔═══╝ ██╔══██║██╔══██╗██╔═██╗
  ███████║██║     ██║  ██║██║  ██║██║  ██╗
  ╚══════╝╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝

  ██████╗ ██████╗ ██╗███╗   ███╗███████╗
  ██╔══██╗██╔══██╗██║████╗ ████║██╔════╝
  ██████╔╝██████╔╝██║██╔████╔██║█████╗
  ██╔═══╝ ██╔══██╗██║██║╚██╔╝██║██╔══╝
  ██║     ██║  ██║██║██║ ╚═╝ ██║███████╗
  ╚═╝     ╚═╝  ╚═╝╚═╝╚═╝     ╚═╝╚══════╝

  ██╗   ██╗ █████╗ ██╗   ██╗██╗  ████████╗
  ██║   ██║██╔══██╗██║   ██║██║  ╚══██╔══╝
  ██║   ██║███████║██║   ██║██║     ██║
  ╚██╗ ██╔╝██╔══██║██║   ██║██║     ██║
   ╚████╔╝ ██║  ██║╚██████╔╝███████╗██║
    ╚═══╝  ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝

*/

/// @dev If the inheritance is updated, the functions in `initialize` must be updated as well.
///      Last updated for: `Initializable, UUPSUpgradeable, AccessControlEnumerableUpgradeable,
///      ISparkPrimeVault`.
contract SparkPrimeVault is AccessControlEnumerableUpgradeable, UUPSUpgradeable, ISparkPrimeVault {

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/

    struct Links {
        uint48 prev;
        uint48 next;
    }

    struct List {
        uint48  head;
        uint48  tail;
        uint48  length;
        uint256 shares;
        mapping (uint48 id => Links links) links;
    }

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    // This corresponds to a 100% APY, verify here:
    // bc -l <<< 'scale=27; e( l(2)/(60 * 60 * 24 * 365) )'
    uint256 public constant override MAX_VSR = 1.000000021979553151239153027e27;
    uint256 public constant override RAY     = 1e27;
    uint256 public constant override WAD     = 1e18;

    uint256 public constant override MAX_REDEEM_FEE = 0.01e18;  // 1% [wad]

    bytes32 public constant override LOSS_MANAGER_ROLE      = keccak256("LOSS_MANAGER_ROLE");
    bytes32 public constant override OPERATOR_ROLE          = keccak256("OPERATOR_ROLE");
    bytes32 public constant override PAUSER_ROLE            = keccak256("PAUSER_ROLE");
    bytes32 public constant override REDEEM_FEE_SETTER_ROLE = keccak256("REDEEM_FEE_SETTER_ROLE");
    bytes32 public constant override TAKER_ROLE             = keccak256("TAKER_ROLE");
    bytes32 public constant override UNPAUSER_ROLE          = keccak256("UNPAUSER_ROLE");

    bytes32 public constant override PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );

    string public constant override version = "1";

    /**********************************************************************************************/
    /*** Storage variables                                                                      ***/
    /**********************************************************************************************/

    uint48 internal _lastRequestId;

    mapping (uint48 id => Request request) internal _requests;

    List internal _pendingDeposits;
    List internal _pendingDepositCancellations;
    List internal _pendingRedeems;

    List internal _suspendedDeposits;
    List internal _suspendedDepositCancellations;
    List internal _suspendedRedeems;

    address public override savings;
    address public override asset;

    bool public override paused;

    uint8 public override decimals;

    string public override name;
    string public override symbol;

    uint64  public override rho;     // Time of last drip              [unix epoch time]
    uint192 public override chi;     // The Rate Accumulator           [ray]
    uint256 public override vsr;     // The Vault Savings Rate         [ray]
    uint256 public override minVSR;  // The minimum Vault Savings Rate [ray]
    uint256 public override maxVSR;  // The maximum Vault Savings Rate [ray]

    uint256 public override maxCapacity;             // Max `totalSupply`
    uint256 public override minDeposit;              // [savings asset units]
    uint256 public override minDepositCancellation;  // [savings shares units]
    uint256 public override minRedeem;               // [shares units]
    uint256 public override redeemFeeRate;           // Fee rate burned in redeem requests [wad]
    uint256 public override maxRedeemFeeRate;        // [wad]

    uint256 public override totalSupply;
    uint256 public override totalClaimable;

    mapping (address account => uint256 balance) public override balanceOf;
    mapping (address account => uint256 nonce)   public override nonces;

    mapping (address account => uint256 assets) public override claimableAssetsOf;

    mapping (address account => mapping (address spender => uint256 amount))
        public override allowance;

    modifier whenNotPaused() {
        _revertIfPaused();
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
        address        admin,
        uint256        minDeposit_,
        uint256        minDepositCancellation_,
        uint256        minRedeem_
    )
        initializer external override
    {
        address asset_ = IERC4626Like(savings_).asset();

        savings  = savings_;
        asset    = asset_;
        name     = name_;
        symbol   = symbol_;
        decimals = IERC20Like(asset_).decimals();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        rho = uint64(block.timestamp);

        emit Drip(chi = uint192(RAY), 0);
        emit VSRSet(address(this), vsr = RAY);
        emit VSRBoundsSet(address(this), minVSR = RAY, maxVSR = RAY);

        _setMinDeposit(minDeposit_);
        _setMinDepositCancellation(minDepositCancellation_);
        _setMinRedeem(minRedeem_);

        SafeERC20.forceApprove(IERC20OZ(asset_), savings_, type(uint256).max);
    }

    // Only DEFAULT_ADMIN_ROLE can upgrade the implementation.
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**********************************************************************************************/
    /*** Admin external functions                                                               ***/
    /**********************************************************************************************/

    function setMaxRedeemFeeRate(uint256 feeRate_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(feeRate_ <= MAX_REDEEM_FEE, MaxFeeTooHigh());
        emit MaxRedeemFeeRateSet(msg.sender, maxRedeemFeeRate = feeRate_);
    }

    function setMinDeposit(uint256 minDeposit_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMinDeposit(minDeposit_);
    }

    function setMinDepositCancellation(uint256 minDepositCancellation_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setMinDepositCancellation(minDepositCancellation_);
    }

    function setMinRedeem(uint256 minRedeem_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _setMinRedeem(minRedeem_);
    }

    function setVSRBounds(uint256 minVSR_, uint256 maxVSR_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(minVSR_ >= RAY,     MinVSRTooLow());
        require(maxVSR_ <= MAX_VSR, MaxVSRTooHigh());
        require(minVSR_ <= maxVSR_, MinVSRGtMaxVSR());

        emit VSRBoundsSet(msg.sender, minVSR = minVSR_, maxVSR = maxVSR_);
    }

    /**********************************************************************************************/
    /*** Loss Manager external functions                                                        ***/
    /**********************************************************************************************/

    function impair(uint256 assets_) external override onlyRole(LOSS_MANAGER_ROLE) {
        require(paused,       IsNotPaused());
        require(assets_ != 0, ZeroImpairment());

        drip();

        uint256 totalAssets_ = totalAssets();

        require(assets_ <= totalAssets_, ImpairmentTooLarge());

        uint192 chi_ = uint192(((totalAssets_ - assets_) * RAY) / totalSupply);

        emit Impairment(msg.sender, chi = chi_, assets_);
    }

    /**********************************************************************************************/
    /*** Taker external functions                                                               ***/
    /**********************************************************************************************/

    function take(uint256 savingsShares_) external override onlyRole(TAKER_ROLE) {
        require(
            savingsShares_ <= IERC20Like(savings).balanceOf(address(this)),
            InsufficientShares()
        );

        emit Take(msg.sender, savingsShares_);

        SafeERC20.safeTransfer(IERC20OZ(savings), msg.sender, savingsShares_);
    }

    /**********************************************************************************************/
    /*** Operator external functions                                                            ***/
    /**********************************************************************************************/

    function setCapacity(uint256 capacity_) external override onlyRole(OPERATOR_ROLE) {
        require(capacity_ <= type(uint128).max, CapacityTooHigh());

        emit CapacitySet(msg.sender, maxCapacity = capacity_);
    }

    function setVSR(uint256 vsr_) external override onlyRole(OPERATOR_ROLE) {
        require(vsr_ >= minVSR, VSRTooLow());
        require(vsr_ <= maxVSR, VSRTooHigh());

        drip();

        emit VSRSet(msg.sender, vsr = vsr_);
    }

    function processPendingDeposits(uint256 maxSavingsShares_, uint256 maxRequests_)
        external
        override
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
    {
        emit ProcessPendingDeposits(msg.sender, maxSavingsShares_, maxRequests_);
        _processPendingDeposits(maxSavingsShares_, maxRequests_);
    }

    function processPendingDepositCancellations(uint256 maxSavingsShares_, uint256 maxRequests_)
        external
        override
        onlyRole(OPERATOR_ROLE)
    {
        emit ProcessPendingDepositCancellations(msg.sender, maxSavingsShares_, maxRequests_);
        _processPendingDepositCancellations(maxSavingsShares_, maxRequests_);
    }

    function processPendingRedeems(uint256 maxShares_, uint256 maxRequests_)
        external
        override
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
    {
        emit ProcessPendingRedeems(msg.sender, maxShares_, maxRequests_);
        _processPendingRedeems(maxShares_, maxRequests_);
    }

    function suspendDepositRequest(uint48 requestId_) external override {
        _moveRequest(requestId_, _pendingDeposits, _suspendedDeposits);
        emit DepositRequestSuspended(msg.sender, requestId_);
    }

    function suspendDepositCancellationRequest(uint48 requestId_) external override {
        _moveRequest(requestId_, _pendingDepositCancellations, _suspendedDepositCancellations);
        emit DepositCancellationRequestSuspended(msg.sender, requestId_);
    }

    function suspendRedeemRequest(uint48 requestId_) external override {
        _moveRequest(requestId_, _pendingRedeems, _suspendedRedeems);
        emit RedeemRequestSuspended(msg.sender, requestId_);
    }

    function unsuspendDepositRequest(uint48 requestId_) external override {
        _moveRequest(requestId_, _suspendedDeposits, _pendingDeposits);
        emit DepositRequestUnsuspended(msg.sender, requestId_);
    }

    function unsuspendDepositCancellationRequest(uint48 requestId_) external override {
        _moveRequest(requestId_, _suspendedDepositCancellations, _pendingDepositCancellations);
        emit DepositCancellationRequestUnsuspended(msg.sender, requestId_);
    }

    function unsuspendRedeemRequest(uint48 requestId_) external override {
        _moveRequest(requestId_, _suspendedRedeems, _pendingRedeems);
        emit RedeemRequestUnsuspended(msg.sender, requestId_);
    }

    /**********************************************************************************************/
    /*** Redeem Fee Setter external functions                                                   ***/
    /**********************************************************************************************/

    function setRedeemFeeRate(uint256 feeRate_) external override onlyRole(REDEEM_FEE_SETTER_ROLE) {
        require(feeRate_ <= maxRedeemFeeRate, FeeTooHigh());
        emit RedeemFeeRateSet(msg.sender, redeemFeeRate = feeRate_);
    }

    /**********************************************************************************************/
    /*** Pauser external functions                                                              ***/
    /**********************************************************************************************/

    function pause() external override onlyRole(PAUSER_ROLE) {
        paused = true;
        emit Paused(msg.sender);
    }

    /**********************************************************************************************/
    /*** Unpauser external functions                                                            ***/
    /**********************************************************************************************/

    function unpause() external override onlyRole(UNPAUSER_ROLE) {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**********************************************************************************************/
    /*** Request functions                                                                      ***/
    /**********************************************************************************************/

    function requestDeposit(uint256 assets_, address recipient_, uint16 referral_)
        external
        override
        whenNotPaused
        returns (uint48 requestId_)
    {
        _validateRecipient(recipient_);

        require(assets_ >= minDeposit, BelowMinDeposit());

        drip();

        SafeERC20.safeTransferFrom(IERC20OZ(asset), msg.sender, address(this), assets_);

        uint256 savingsShares_ = IERC4626Like(savings).deposit(assets_, address(this));

        requestId_ = _pushPendingRequest(recipient_, savingsShares_, _pendingDeposits);

        emit Referral(referral_, requestId_, msg.sender, recipient_, assets_);
        emit DepositRequest(requestId_, msg.sender, recipient_, assets_, savingsShares_);
    }

    function requestDepositCancellation(
        uint48  requestId_,
        address recipient_,
        uint256 savingsShares_
    )
        external
        override
        returns (uint48 newRequestId_)
    {
        _validateRecipient(recipient_);

        Request storage depositRequest_ = _getRequest(_pendingDeposits, requestId_);

        uint256 depositSavingsShares_ = depositRequest_.shares;

        require(msg.sender == depositRequest_.owner,      NotRequestOwner());
        require(savingsShares_ >= minDepositCancellation, BelowMinDepositCancellation());
        require(savingsShares_ <= depositSavingsShares_,  SavingsSharesTooHigh());

        newRequestId_ =
            _pushPendingRequest(recipient_, savingsShares_, _pendingDepositCancellations);

        _pendingDeposits.shares -= savingsShares_;

        if (depositSavingsShares_ == savingsShares_) {
            _remove(_pendingDeposits, requestId_);
            delete _requests[requestId_];
        } else {
            unchecked {
                depositRequest_.shares = depositSavingsShares_ - savingsShares_;
            }
        }

        emit DepositCancellationRequest(requestId_, newRequestId_, recipient_, savingsShares_);
    }

    function requestRedeem(uint256 shares_, address recipient_)
        external
        override
        whenNotPaused
        returns (uint48 requestId_)
    {
        _validateRecipient(recipient_);

        require(shares_ >= minRedeem, BelowMinRedeem());

        drip();

        _transfer(msg.sender, address(this), shares_);

        // The fee is burned upfront in shares.
        uint256 fee_ = _divUp(shares_ * redeemFeeRate, WAD);

        _burn(address(this), fee_);

        requestId_ = _pushPendingRequest(recipient_, shares_ - fee_, _pendingRedeems);

        emit RedeemRequest(requestId_, msg.sender, recipient_, shares_, fee_);
    }

    /**********************************************************************************************/
    /*** Request update functions                                                               ***/
    /**********************************************************************************************/

    function updateDepositRecipient(uint48 requestId_, address recipient_) external override {
        _updateRecipient(requestId_, recipient_, _pendingDeposits);
        emit DepositRecipientUpdated(requestId_, recipient_);
    }

    function updateDepositCancellationRecipient(uint48 requestId_, address recipient_)
        external
        override
    {
        _updateRecipient(requestId_, recipient_, _pendingDepositCancellations);
        emit DepositCancellationRecipientUpdated(requestId_, recipient_);
    }

    function updateRedeemRecipient(uint48 requestId_, address recipient_) external override {
        _updateRecipient(requestId_, recipient_, _pendingRedeems);
        emit RedeemRecipientUpdated(requestId_, recipient_);
    }

    /**********************************************************************************************/
    /*** Claim functions                                                                        ***/
    /**********************************************************************************************/

    function claim(address recipient_) external override returns (uint256 assets_) {
        assets_ = claimableAssetsOf[recipient_];

        require(assets_ != 0, NothingToClaim());

        claimableAssetsOf[recipient_] = 0;

        totalClaimable -= assets_;

        emit Claim(recipient_, assets_);

        SafeERC20.safeTransfer(IERC20OZ(asset), recipient_, assets_);
    }

    /**********************************************************************************************/
    /*** ERC20 external mutating functions                                                      ***/
    /**********************************************************************************************/

    function approve(address spender_, uint256 amount_) external override returns (bool) {
        allowance[msg.sender][spender_] = amount_;

        emit Approval(msg.sender, spender_, amount_);

        return true;
    }

    function transfer(address to_, uint256 amount_) external override returns (bool) {
        require(to_ != address(0) && to_ != address(this), "SparkPrimeVault/invalid-address");

        _transfer(msg.sender, to_, amount_);

        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_)
        external
        override
        returns (bool)
    {
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
    )
        public
        override
    {
        require(block.timestamp <= deadline_, "SparkPrimeVault/permit-expired");
        require(owner_ != address(0),         "SparkPrimeVault/invalid-owner");

        uint256 nonce;

        unchecked { nonce = nonces[owner_]++; }

        bytes32 digest =
            keccak256(abi.encodePacked(
                "\x19\x01",
                _getDomainSeparator(),
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
    )
        external
        override
    {
        permit(owner_, spender_, value_, deadline_, abi.encodePacked(r_, s_, v_));
    }

    /**********************************************************************************************/
    /*** Rate accumulation                                                                      ***/
    /**********************************************************************************************/

    function drip() public override returns (uint192 nChi_) {
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

    function pendingDepositSavingsShares() external view override returns (uint256) {
        return _pendingDeposits.shares;
    }

    function pendingDepositRequestsLength() external view override returns (uint256) {
        return _pendingDeposits.length;
    }

    function getPendingDepositRequest(uint48 requestId_)
        external
        view
        override
        returns (Request memory)
    {
        return _getRequest(_pendingDeposits, requestId_);
    }

    function pendingDepositRequests() external view override returns (Request[] memory) {
        return _getRequests(_pendingDeposits, 0, type(uint256).max);
    }

    function getPendingDepositRequests(uint256 startIndex_, uint256 length_)
        external
        view
        override
        returns (Request[] memory)
    {
        return _getRequests(_pendingDeposits, startIndex_, length_);
    }

    function pendingDepositCancellationSavingsShares() external view override returns (uint256) {
        return _pendingDepositCancellations.shares;
    }

    function pendingDepositCancellationRequestsLength() external view override returns (uint256) {
        return _pendingDepositCancellations.length;
    }

    function getPendingDepositCancellationRequest(uint48 requestId_)
        external
        view
        override
        returns (Request memory)
    {
        return _getRequest(_pendingDepositCancellations, requestId_);
    }

    function pendingDepositCancellationRequests()
        external
        view
        override
        returns (Request[] memory)
    {
        return _getRequests(_pendingDepositCancellations, 0, type(uint256).max);
    }

    function getPendingDepositCancellationRequests(uint256 startIndex_, uint256 length_)
        external
        view
        override
        returns (Request[] memory)
    {
        return _getRequests(_pendingDepositCancellations, startIndex_, length_);
    }

    function pendingRedeemShares() external view override returns (uint256) {
        return _pendingRedeems.shares;
    }

    function pendingRedeemRequestsLength() external view override returns (uint256) {
        return _pendingRedeems.length;
    }

    function getPendingRedeemRequest(uint48 requestId_)
        external
        view
        override
        returns (Request memory)
    {
        return _getRequest(_pendingRedeems, requestId_);
    }

    function pendingRedeemRequests() external view override returns (Request[] memory) {
        return _getRequests(_pendingRedeems, 0, type(uint256).max);
    }

    function getPendingRedeemRequests(uint256 startIndex_, uint256 length_)
        external
        view
        override
        returns (Request[] memory)
    {
        return _getRequests(_pendingRedeems, startIndex_, length_);
    }

    /**********************************************************************************************/
    /*** Suspended request getter functions                                                     ***/
    /**********************************************************************************************/

    function suspendedDepositSavingsShares() external view override returns (uint256) {
        return _suspendedDeposits.shares;
    }

    function suspendedDepositRequestsLength() external view override returns (uint256) {
        return _suspendedDeposits.length;
    }

    function getSuspendedDepositRequest(uint48 requestId_)
        external
        view
        override
        returns (Request memory)
    {
        return _getRequest(_suspendedDeposits, requestId_);
    }

    function suspendedDepositRequests() external view override returns (Request[] memory) {
        return _getRequests(_suspendedDeposits, 0, type(uint256).max);
    }

    function getSuspendedDepositRequests(uint256 startIndex_, uint256 length_)
        external
        view
        override
        returns (Request[] memory)
    {
        return _getRequests(_suspendedDeposits, startIndex_, length_);
    }

    function suspendedDepositCancellationSavingsShares() external view override returns (uint256) {
        return _suspendedDepositCancellations.shares;
    }

    function suspendedDepositCancellationRequestsLength() external view override returns (uint256) {
        return _suspendedDepositCancellations.length;
    }

    function getSuspendedDepositCancellationRequest(uint48 requestId_)
        external
        view
        override
        returns (Request memory)
    {
        return _getRequest(_suspendedDepositCancellations, requestId_);
    }

    function suspendedDepositCancellationRequests()
        external
        view
        override
        returns (Request[] memory)
    {
        return _getRequests(_suspendedDepositCancellations, 0, type(uint256).max);
    }

    function getSuspendedDepositCancellationRequests(uint256 startIndex_, uint256 length_)
        external
        view
        override
        returns (Request[] memory)
    {
        return _getRequests(_suspendedDepositCancellations, startIndex_, length_);
    }

    function suspendedRedeemShares() external view override returns (uint256) {
        return _suspendedRedeems.shares;
    }

    function suspendedRedeemRequestsLength() external view override returns (uint256) {
        return _suspendedRedeems.length;
    }

    function getSuspendedRedeemRequest(uint48 requestId_)
        external
        view
        override
        returns (Request memory)
    {
        return _getRequest(_suspendedRedeems, requestId_);
    }

    function suspendedRedeemRequests() external view override returns (Request[] memory) {
        return _getRequests(_suspendedRedeems, 0, type(uint256).max);
    }

    function getSuspendedRedeemRequests(uint256 startIndex_, uint256 length_)
        external
        view
        override
        returns (Request[] memory)
    {
        return _getRequests(_suspendedRedeems, startIndex_, length_);
    }

    /**********************************************************************************************/
    /*** External view functions                                                                ***/
    /**********************************************************************************************/

    function DOMAIN_SEPARATOR() external view override returns (bytes32) {
        return _getDomainSeparator();
    }

    function assetsOf(address owner_) external view override returns (uint256) {
        return convertToAssets(balanceOf[owner_]);
    }

    function availableCapacity() public view override returns (uint256) {
        return maxCapacity > totalSupply ? maxCapacity - totalSupply : 0;
    }

    function availableLiquidAssets() public view override returns (uint256) {
        return IERC4626Like(savings).maxWithdraw(address(this));
    }

    function convertToAssets(uint256 shares_) public view override returns (uint256) {
        return (shares_ * nowChi()) / RAY;
    }

    function convertToShares(uint256 assets_) public view override returns (uint256) {
        return (assets_ * RAY) / nowChi();
    }

    function implementation() external view override returns (address) {
        return ERC1967Utils.getImplementation();
    }

    function nowChi() public view override returns (uint192) {
        return
            block.timestamp > rho
                ? uint192((_rpow(vsr, block.timestamp - rho) * chi) / RAY)
                : chi;
    }

    function supportsInterface(bytes4 interfaceId_)
        public
        view
        override(ISparkPrimeVault, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return
            interfaceId_ == type(ISparkPrimeVault).interfaceId ||
            super.supportsInterface(interfaceId_);
    }

    function totalAssets() public view override returns (uint256) {
        return convertToAssets(totalSupply);
    }

    /**********************************************************************************************/
    /*** Config internal helper functions                                                       ***/
    /**********************************************************************************************/

    function _setMinDeposit(uint256 minDeposit_) internal {
        require(minDeposit_ != 0, ZeroMinDeposit());

        emit MinDepositSet(msg.sender, minDeposit = minDeposit_);
    }

    function _setMinDepositCancellation(uint256 minDepositCancellation_) internal {
        require(minDepositCancellation_ != 0, ZeroMinDepositCancellation());

        emit MinDepositCancellationSet(
            msg.sender,
            minDepositCancellation = minDepositCancellation_
        );
    }

    function _setMinRedeem(uint256 minRedeem_) internal {
        require(minRedeem_ != 0, ZeroMinRedeem());

        emit MinRedeemSet(msg.sender, minRedeem = minRedeem_);
    }

    /**********************************************************************************************/
    /*** Process internal helper functions                                                      ***/
    /**********************************************************************************************/

    function _processPendingDeposits(uint256 maxSavingsShares_, uint256 requestsLeft_) internal {
        drip();

        // Convert the maximum admissible assets into savings shares denomination.
        uint256 remaining_ = _min(
            maxSavingsShares_,
            _convertAssetsToSavingsShares(convertToAssets(availableCapacity()))
        );

        // Process the deposit queue up to the maximum number of requests or until there are no more
        // remaining savings shares.
        for (
            uint48 id_ = _pendingDeposits.head;                       // Start at the head
            (requestsLeft_ != 0) && (remaining_ != 0) && (id_ != 0);
            id_ = _remove(_pendingDeposits, id_)                      // Remove and get next
        ) {
            Request storage request_ = _requests[id_];

            // Convert processable savings shares into vault shares.
            uint256 savingsShares_ = _min(request_.shares, remaining_);
            uint256 assets_        = IERC4626Like(savings).convertToAssets(savingsShares_);
            uint256 shares_        = convertToShares(assets_);

            unchecked {
                _pendingDeposits.shares -= savingsShares_;
                request_.shares         -= savingsShares_;
                remaining_              -= savingsShares_;

                --requestsLeft_;
            }

            address recipient_ = request_.recipient;

            _mint(recipient_, shares_);

            emit Deposit(id_, request_.owner, recipient_, savingsShares_, assets_, shares_);

            if (request_.shares != 0) return;  // Partial fill, entry stays at the head

            delete _requests[id_];
        }
    }

    function _processPendingDepositCancellations(uint256 maxSavingsShares_, uint256 requestsLeft_)
        internal
    {
        drip();

        uint256 remaining_ =
            _min(maxSavingsShares_, IERC4626Like(savings).maxRedeem(address(this)));

        // Process the cancelled deposit queue up to the maximum number of requests or until there
        // are no more remaining savings shares.
        for (
            uint48 id_ = _pendingDepositCancellations.head;           // Start at the head
            (requestsLeft_ != 0) && (remaining_ != 0) && (id_ != 0);
            id_ = _remove(_pendingDepositCancellations, id_)          // Remove and get next
        ) {
            Request storage request_ = _requests[id_];

            uint256 savingsShares_ = _min(request_.shares, remaining_);

            unchecked {
                _pendingDepositCancellations.shares -= savingsShares_;
                request_.shares                     -= savingsShares_;
                remaining_                          -= savingsShares_;

                --requestsLeft_;
            }

            address recipient_ = request_.recipient;
            uint256 assets_    = _redeemSavings(savingsShares_, recipient_);

            emit DepositCancellation(id_, request_.owner, recipient_, savingsShares_, assets_);

            if (request_.shares != 0) return;  // Partial fill, entry stays at the head

            delete _requests[id_];
        }
    }

    function _processPendingRedeems(uint256 maxShares_, uint256 requestsLeft_) internal {
        drip();

        uint256 remaining_ = maxShares_;

        // Process the redeem queue up to the maximum number of requests or until there are no more
        // remaining shares or available liquidity.
        for (
            uint48 id_ = _pendingRedeems.head;                        // Start at the head
            (requestsLeft_ != 0) && (remaining_ != 0) && (id_ != 0);
            id_ = _remove(_pendingRedeems, id_)                       // Remove and get next
        ) {
            uint256 fillable_ = _min(remaining_, convertToShares(availableLiquidAssets()));

            if (fillable_ == 0) return;  // Out of liquidity

            Request storage request_ = _requests[id_];

            uint256 shares_ = _min(request_.shares, fillable_);

            unchecked {
                _pendingRedeems.shares -= shares_;
                request_.shares        -= shares_;
                remaining_             -= shares_;

                --requestsLeft_;
            }

            _burn(address(this), shares_);

            // Redeem savings shares rounded down, so that any rounding error stays with the vault.
            uint256 savingsShares_ = _convertAssetsToSavingsShares(convertToAssets(shares_));
            address recipient_     = request_.recipient;
            uint256 assets_        = _redeemSavings(savingsShares_, recipient_);

            emit Redeem(id_, request_.owner, recipient_, shares_, savingsShares_, assets_);

            if (request_.shares != 0) return;  // Partial fill, entry stays at the head

            delete _requests[id_];
        }
    }

    /**********************************************************************************************/
    /*** ERC4626 internal helper functions                                                      ***/
    /**********************************************************************************************/

    function _convertAssetsToSavingsShares(uint256 assets_) internal view returns (uint256) {
        return IERC4626Like(savings).convertToShares(assets_);
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

        // Any recipient-specific reversion of the savings vault or underlying asset transfer that
        // occurs as a result of a user request is added to claimable funds to be handled
        // asynchronously.

        assets_ = IERC4626Like(savings).redeem(savingsShares_, address(this), address(this));

        _incrementClaimableAssets(recipient_, assets_);
    }

    /**********************************************************************************************/
    /*** Request internal helper functions                                                      ***/
    /**********************************************************************************************/

    function _contains(List storage list_, uint48 requestId_) internal view returns (bool) {
        return requestId_ != 0 && (requestId_ == list_.head || list_.links[requestId_].prev != 0);
    }

    function _append(List storage list_, uint48 requestId_) internal {
        uint48 tail_ = list_.tail;

        if (tail_ == 0) {
            list_.head = requestId_;
        } else {
            list_.links[tail_].next      = requestId_;
            list_.links[requestId_].prev = tail_;
        }

        list_.tail = requestId_;

        unchecked {
            ++list_.length;
        }
    }

    function _remove(List storage list_, uint48 requestId_) internal returns (uint48 next_) {
        Links storage links_ = list_.links[requestId_];

        uint48 prev_ = links_.prev;

        next_ = links_.next;

        if (prev_ == 0) {
            list_.head = next_;
        } else {
            list_.links[prev_].next = next_;
        }

        if (next_ == 0) {
            list_.tail = prev_;
        } else {
            list_.links[next_].prev = prev_;
        }

        delete list_.links[requestId_];

        unchecked {
            --list_.length;
        }
    }

    function _getRequest(List storage list_, uint48 requestId_)
        internal
        view
        returns (Request storage)
    {
        require(_contains(list_, requestId_), NoRequest());
        return _requests[requestId_];
    }

    function _getRequests(List storage list_, uint256 startIndex_, uint256 length_)
        internal
        view
        returns (Request[] memory requests_)
    {
        uint256 total_ = list_.length;

        require(startIndex_ <= total_, StartIndexTooLarge());

        unchecked {
            length_ = _min(length_, total_ - startIndex_);
        }

        requests_ = new Request[](length_);

        if (length_ == 0) return requests_;

        uint48 id_ = list_.head;

        for (uint256 i_; i_ < startIndex_; ++i_) {
            id_ = list_.links[id_].next;
        }

        for (uint256 i_; i_ < length_; ++i_) {
            requests_[i_] = _requests[id_];
            id_           = list_.links[id_].next;
        }
    }

    function _pushPendingRequest(address recipient_, uint256 shares_, List storage list_)
        internal
        returns (uint48 requestId_)
    {
        requestId_ = ++_lastRequestId;

        _requests[requestId_] =
            Request(requestId_, msg.sender, recipient_, uint64(block.timestamp), shares_);

        _append(list_, requestId_);

        list_.shares += shares_;
    }

    function _moveRequest(uint48 requestId_, List storage from_, List storage to_)
        internal
        onlyRole(OPERATOR_ROLE)
    {
        uint256 shares_ = _getRequest(from_, requestId_).shares;

        _remove(from_, requestId_);
        _append(to_, requestId_);

        from_.shares -= shares_;
        to_.shares   += shares_;
    }

    function _updateRecipient(uint48 requestId_, address recipient_, List storage list_) internal {
        _validateRecipient(recipient_);

        Request storage request_ = _getRequest(list_, requestId_);

        require(msg.sender == request_.owner, NotRequestOwner());

        request_.recipient = recipient_;
    }

    function _validateRecipient(address recipient_) internal view {
        require(recipient_ != address(0),    ZeroRecipient());
        require(recipient_ != address(this), VaultIsRecipient());
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

    function _getDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                address(this)
            )
        );
    }

    function _isValidSignature(address signer_, bytes32 digest_, bytes memory signature_)
        internal
        view
        returns (bool)
    {
        if (signer_.code.length != 0) {
            ( bool success_, bytes memory result_ ) = signer_.staticcall(
                abi.encodeCall(IERC1271.isValidSignature, (digest_, signature_))
            );

            return
                success_ &&
                result_.length >= 32 &&
                abi.decode(result_, (bytes4)) == IERC1271.isValidSignature.selector;
        }

        if (signature_.length != 65) return false;

        bytes32 r_;
        bytes32 s_;
        uint8   v_;

        assembly {
            r_ := mload(add(signature_, 0x20))
            s_ := mload(add(signature_, 0x40))
            v_ := byte(0, mload(add(signature_, 0x60)))
        }

        return signer_ == ecrecover(digest_, v_, r_, s_);
    }

    /**********************************************************************************************/
    /*** Claimable assets internal helper functions                                             ***/
    /**********************************************************************************************/

    function _incrementClaimableAssets(address recipient_, uint256 assets_) internal {
        claimableAssetsOf[recipient_] += assets_;
        totalClaimable                += assets_;

        emit ClaimableAssetsIncreased(recipient_, assets_);
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

    function _revertIfPaused() internal view {
        require(!paused, IsPaused());
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
