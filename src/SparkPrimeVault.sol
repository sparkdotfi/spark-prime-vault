// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC4626 }        from "../lib/oz/contracts/interfaces/IERC4626.sol";
import { ERC1967Utils }    from "../lib/oz/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { UUPSUpgradeable } from "../lib/oz/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 }          from "../lib/oz/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata }  from "../lib/oz/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 }       from "../lib/oz/contracts/token/ERC20/utils/SafeERC20.sol";

import { AccessControlEnumerableUpgradeable }
    from "../lib/oz-upgradeable/contracts/access/extensions/AccessControlEnumerableUpgradeable.sol";

interface IERC1271 {
    function isValidSignature(bytes32, bytes memory) external view returns (bytes4);
}

// TODO: Remove spUSDC and make generic
// TODO: _processDepositQueue and _processWithdrawQueue should take in a variable that allows netting withdrawals against deposits (there should be a third function)
// TODO: Remove USDC custodying altogether, just use take() to get spUSDC
// TODO: Clean up roles
// TODO: Add more validation to setters
// TODO: Change Request structs to be bespoke (remove fee)
// TODO: Should processDepositQueue and processWithdrawQueue both be permissioned, if so, should we make all withdrawals async?
// TODO: Refactor setChi to use nominal
// TODO: requestDepositWithPemrit?
// TODO: Cancel should take in a receiver and only the owner should be able to call
// TODO: Take only up to spUSDC.balanceOf(address(this)) - totalQueuedDepositShares in take()
// TODO: Get pendingOfReceiver() and getPendingOfOwner()
// TODO: depositFromSavings withdrawFromSavings() should be gone
// TODO: Ask Sam if we need to add capability for reducing deposit/withdraw request amounts
// TODO: Ask Sam if we need to add capability for updating receiver in deposit/withdraw requests
// TODO: Prevent access to totalQueuedDepositShares in _withdrawFromSavings() (remove?)
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

    // Emitted when spPRIME is minted to `receiver`, instantly or when a queued deposit is filled
    event Deposit(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    // Emitted when USDC is paid to `receiver`, instantly or when a queued redeem is filled
    event Withdraw(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    event DepositRequest(
        address indexed owner,
        address indexed receiver,
        uint256 indexed requestId,
        uint256 assets
    );

    event RedeemRequest(
        address indexed owner,
        address indexed receiver,
        uint256 indexed requestId,
        uint256 shares
    );

    event CancelDepositRequest(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 assets
    );

    event Referral(uint16 indexed referral, address indexed receiver, uint256 assets);

    event CapacitySet(uint256 oldCapacity, uint256 newCapacity);
    event ChiSet(uint256 oldChi, uint256 newChi);
    event Drip(uint256 chi, uint256 diff);
    event MaxWithdrawFeeSet(uint256 oldFee, uint256 newFee);
    event MinimumsSet(uint256 minDeposit, uint256 minWithdraw);
    event Paused(address account);
    event Take(address indexed to, uint256 value);
    event Unpaused(address account);
    event VsrBoundsSet(uint256 oldMinVsr, uint256 oldMaxVsr, uint256 newMinVsr, uint256 newMaxVsr);
    event VsrSet(address indexed sender, uint256 oldVsr, uint256 newVsr);
    event WithdrawFeeSet(uint256 oldFee, uint256 newFee);

    struct Request {
        address owner;     // Paid the assets (deposit) or the shares (redeem), refunded on cancel
        address receiver;  // Receives the spPRIME (deposit) or the USDC (redeem)
        uint256 amount;    // spUSDC shares in the deposit queue, spPRIME shares in the withdraw queue
        uint256 fee;       // withdrawFee when the request was made [wad]
    }

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    // This corresponds to a 100% APY, verify here:
    // bc -l <<< 'scale=27; e( l(2)/(60 * 60 * 24 * 365) )'
    uint256 public constant MAX_VSR = 1.000000021979553151239153027e27;
    uint256 public constant RAY     = 1e27;
    uint256 public constant WAD     = 1e18;

    uint256 public constant MAX_WITHDRAW_FEE = 0.01e18;  // 1% [wad]

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

    address  public asset;
    IERC4626 public spUsdc;

    uint8 public decimals;

    string public name;
    string public symbol;

    uint64  public rho;    // Time of last drip              [unix epoch time]
    uint192 public chi;    // The Rate Accumulator           [ray]
    uint256 public vsr;    // The Vault Savings Rate         [ray]
    uint256 public minVsr; // The minimum Vault Savings Rate [ray]
    uint256 public maxVsr; // The maximum Vault Savings Rate [ray]

    bool public paused;

    uint256 public maxCapacity;    // Max totalSupply, escrow included [shares]
    uint256 public minDeposit;     // [asset units]
    uint256 public minWithdraw;    // [asset units]
    uint256 public withdrawFee;    // Fee locked into new redeem requests [wad]
    uint256 public maxWithdrawFee; // [wad]

    uint256 public totalSupply;

    uint256 public totalQueuedDepositShares;  // spUSDC held for queued deposits
    uint256 public totalQueuedRedeemShares;   // spPRIME escrowed for queued redeems

    Request[] public depositQueue;
    Request[] public withdrawQueue;

    uint256 public depositHead;  // First unfilled index of the queue above
    uint256 public withdrawHead;

    mapping (address => uint256) public balanceOf;
    mapping (address => uint256) public nonces;

    mapping (address => uint256) public pendingDepositShares;  // Queued spUSDC shares, by receiver
    mapping (address => uint256) public pendingRedeemShares;   // Queued spPRIME shares, by receiver

    mapping (address => mapping (address => uint256)) public allowance;

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

    // NOTE: Neither UUPSUpgradeable nor AccessControlEnumerableUpgradeable
    //       require init functions to be called.
    function initialize(
        address asset_,
        address spUsdc_,
        string memory name_,
        string memory symbol_,
        address admin
    )
        initializer external
    {
        require(IERC4626(spUsdc_).asset() == asset_, "SparkPrimeVault/asset-mismatch");

        asset  = asset_;
        spUsdc = IERC4626(spUsdc_);
        name   = name_;
        symbol = symbol_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        decimals = IERC20Metadata(asset_).decimals();

        chi = uint192(RAY);
        rho = uint64(block.timestamp);
        vsr = RAY;

        minVsr = RAY;
        maxVsr = RAY;

        SafeERC20.forceApprove(IERC20(asset_), spUsdc_, type(uint256).max);
    }

    // Only DEFAULT_ADMIN_ROLE can upgrade the implementation
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**********************************************************************************************/
    /*** Role-based external functions                                                          ***/
    /**********************************************************************************************/

    function setCapacity(uint256 newCapacity) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newCapacity <= type(uint128).max, "SparkPrimeVault/capacity-too-high");
        emit CapacitySet(maxCapacity, newCapacity);
        maxCapacity = newCapacity;
    }

    function setMaxWithdrawFee(uint256 fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(fee <= MAX_WITHDRAW_FEE, "SparkPrimeVault/fee-too-high");
        emit MaxWithdrawFeeSet(maxWithdrawFee, fee);
        maxWithdrawFee = fee;
        if (withdrawFee > fee) withdrawFee = fee;
    }

    function setMinimums(uint256 minDeposit_, uint256 minWithdraw_)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        minDeposit  = minDeposit_;
        minWithdraw = minWithdraw_;
        emit MinimumsSet(minDeposit_, minWithdraw_);
    }

    function setVsrBounds(uint256 minVsr_, uint256 maxVsr_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(minVsr_ >= RAY,     "SparkPrimeVault/vsr-too-low");
        require(maxVsr_ <= MAX_VSR, "SparkPrimeVault/vsr-too-high");
        require(minVsr_ <= maxVsr_, "SparkPrimeVault/min-vsr-gt-max-vsr");

        emit VsrBoundsSet(minVsr, maxVsr, minVsr_, maxVsr_);

        minVsr = minVsr_;
        maxVsr = maxVsr_;
    }

    function setVsr(uint256 newVsr) external onlyRole(SETTER_ROLE) {
        require(newVsr >= minVsr, "SparkPrimeVault/vsr-too-low");
        require(newVsr <= maxVsr, "SparkPrimeVault/vsr-too-high");

        drip();
        uint256 vsr_ = vsr;
        vsr = newVsr;

        emit VsrSet(msg.sender, vsr_, newVsr);
    }

    function take(uint256 assets) external onlyRole(TAKER_ROLE) {
        require(assets <= IERC20(asset).balanceOf(address(this)), "SparkPrimeVault/insufficient-liquidity");
        SafeERC20.safeTransfer(IERC20(asset), msg.sender, assets);

        emit Take(msg.sender, assets);
    }

    function depositToSavings(uint256 assets) external onlyRole(REBALANCER_ROLE) {
        require(assets <= IERC20(asset).balanceOf(address(this)), "SparkPrimeVault/insufficient-liquidity");
        spUsdc.deposit(assets, address(this));
    }

    function withdrawFromSavings(uint256 assets) external onlyRole(REBALANCER_ROLE) {
        _withdrawFromSavings(assets);
    }

    // Mints spPRIME to queued depositors FIFO, up to `maxAssets` and the available capacity
    function processDepositQueue(uint256 maxAssets)
        external onlyRole(REBALANCER_ROLE) whenNotPaused
    {
        uint256 chi_   = drip();
        uint256 budget = _min(maxAssets, availableCapacity() * chi_ / RAY);
        uint256 i      = depositHead;
        uint256 skipped;

        for (; i < depositQueue.length; ++i) {
            Request storage request = depositQueue[i];

            // Cancelled: skip, but bound the walk so the head still advances over a long run
            if (request.amount == 0) { if (++skipped == 500) break; continue; }

            uint256 value  = spUsdc.convertToAssets(request.amount);
            uint256 assets = _min(value, budget);

            // A partial fill must mint at least one share, else wait for more room
            if (assets * RAY / chi_ == 0 && assets < value) break;

            // Rounds up so the accepted spUSDC is always worth at least the credited assets
            uint256 shares = _divup(request.amount * assets, value);

            pendingDepositShares[request.receiver] -= shares;
            totalQueuedDepositShares               -= shares;
            request.amount                         -= shares;
            budget                                 -= assets;

            _mint(request.owner, request.receiver, assets, chi_);

            if (request.amount != 0) break;  // Partial fill, entry stays at the head
        }

        depositHead = i;
    }

    // Pays queued redeemers FIFO, up to `maxAssets` net USDC and the available liquidity
    function processWithdrawQueue(uint256 maxAssets) external whenNotPaused {
        _processWithdrawQueue(maxAssets, drip());
    }

    function setWithdrawFee(uint256 fee) external onlyRole(RISK_MANAGER_ROLE) {
        require(fee <= maxWithdrawFee, "SparkPrimeVault/fee-too-high");
        emit WithdrawFeeSet(withdrawFee, fee);
        withdrawFee = fee;
    }

    function setChi(uint256 newChi) external onlyRole(RISK_MANAGER_ROLE) {
        require(paused, "SparkPrimeVault/not-paused");

        uint256 chi_ = drip();
        require(newChi > 0 && newChi < chi_, "SparkPrimeVault/invalid-chi");

        chi = uint192(newChi);

        emit ChiSet(chi_, newChi);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyRole(UNPAUSER_ROLE) {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**********************************************************************************************/
    /*** Request functions                                                                      ***/
    /**********************************************************************************************/

    // Mints spPRIME to `receiver` for as much of `assets` as the capacity allows, the rest waits
    // in the deposit queue as spUSDC. Returns the queue index, or `type(uint256).max` when nothing
    // was queued.
    function requestDeposit(uint256 assets, address receiver, address owner)
        public whenNotPaused returns (uint256 requestId)
    {
        require(msg.sender == owner,                                 "SparkPrimeVault/not-owner");
        require(receiver != address(0) && receiver != address(this), "SparkPrimeVault/invalid-receiver");
        require(assets >= minDeposit,                                "SparkPrimeVault/below-minimum");

        uint256 chi_ = drip();

        SafeERC20.safeTransferFrom(IERC20(asset), owner, address(this), assets);

        // Instant part, only while nobody is queued ahead
        uint256 instant = totalQueuedDepositShares == 0
            ? _min(assets, availableCapacity() * chi_ / RAY)
            : 0;

        if (instant * RAY / chi_ == 0) instant = 0;  // Below one share: queue it all instead
        else _mint(owner, receiver, instant, chi_);

        if (instant == assets) return type(uint256).max;

        uint256 shares = spUsdc.deposit(assets - instant, address(this));

        if (shares == 0) return type(uint256).max;  // A remainder below one spUSDC share is absorbed

        requestId = depositQueue.length;

        depositQueue.push(Request(owner, receiver, shares, 0));
        pendingDepositShares[receiver] += shares;
        totalQueuedDepositShares       += shares;

        emit DepositRequest(owner, receiver, requestId, assets - instant);
    }

    function requestDeposit(uint256 assets, address receiver, address owner, uint16 referral)
        external returns (uint256 requestId)
    {
        requestId = requestDeposit(assets, receiver, owner);
        emit Referral(referral, receiver, assets);
    }

    // Refunds a queued deposit to its owner, with the spUSDC yield it earned while waiting
    function cancelDepositRequest(uint256 requestId) external {
        Request memory request = depositQueue[requestId];

        require(request.amount != 0, "SparkPrimeVault/no-request");
        require(
            msg.sender == request.owner || msg.sender == request.receiver
                || hasRole(GUARDIAN_ROLE, msg.sender),
            "SparkPrimeVault/not-authorized"
        );

        delete depositQueue[requestId];

        pendingDepositShares[request.receiver] -= request.amount;
        totalQueuedDepositShares               -= request.amount;

        uint256 assets = spUsdc.redeem(request.amount, request.owner, address(this));

        emit CancelDepositRequest(requestId, request.owner, request.receiver, assets);
    }

    // Escrows `shares` and pays `receiver` as much as the liquidity allows, the rest waits in the
    // withdraw queue. Returns the queue index.
    function requestRedeem(uint256 shares, address receiver, address owner)
        external whenNotPaused returns (uint256 requestId)
    {
        require(msg.sender == owner,                                 "SparkPrimeVault/not-owner");
        require(receiver != address(0) && receiver != address(this), "SparkPrimeVault/invalid-receiver");

        uint256 chi_ = drip();

        require(shares != 0 && shares * chi_ / RAY >= minWithdraw, "SparkPrimeVault/below-minimum");

        bool instant = totalQueuedRedeemShares == 0;

        _transfer(owner, address(this), shares);

        requestId = withdrawQueue.length;

        withdrawQueue.push(Request(owner, receiver, shares, withdrawFee));
        pendingRedeemShares[receiver] += shares;
        totalQueuedRedeemShares       += shares;

        emit RedeemRequest(owner, receiver, requestId, shares);

        // Fill this request from available liquidity, only while nobody is queued ahead
        if (instant) _processWithdrawQueue(type(uint256).max, chi_);
    }

    /**********************************************************************************************/
    /*** ERC20 external mutating functions                                                      ***/
    /**********************************************************************************************/

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;

        emit Approval(msg.sender, spender, value);

        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(to != address(0) && to != address(this), "SparkPrimeVault/invalid-address");

        _transfer(msg.sender, to, value);

        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(to != address(0) && to != address(this), "SparkPrimeVault/invalid-address");
        require(balanceOf[from] >= value,                "SparkPrimeVault/insufficient-balance");

        if (from != msg.sender) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= value, "SparkPrimeVault/insufficient-allowance");

                unchecked {
                    allowance[from][msg.sender] = allowed - value;
                }
            }
        }

        _transfer(from, to, value);

        return true;
    }

    /**********************************************************************************************/
    /*** EIP712 external mutating functions                                                     ***/
    /**********************************************************************************************/

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes memory signature
    ) public {
        require(block.timestamp <= deadline, "SparkPrimeVault/permit-expired");
        require(owner != address(0),         "SparkPrimeVault/invalid-owner");

        uint256 nonce;
        unchecked { nonce = nonces[owner]++; }

        bytes32 digest =
            keccak256(abi.encodePacked(
                "\x19\x01",
                _calculateDomainSeparator(block.chainid),
                keccak256(abi.encode(
                    PERMIT_TYPEHASH,
                    owner,
                    spender,
                    value,
                    nonce,
                    deadline
                ))
            ));

        require(_isValidSignature(owner, digest, signature), "SparkPrimeVault/invalid-permit");

        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        permit(owner, spender, value, deadline, abi.encodePacked(r, s, v));
    }

    /**********************************************************************************************/
    /*** Rate accumulation                                                                      ***/
    /**********************************************************************************************/

    function drip() public returns (uint256 nChi) {
        (uint256 chi_, uint256 rho_) = (chi, rho);
        uint256 diff;
        if (block.timestamp > rho_) {
            nChi = _rpow(vsr, block.timestamp - rho_) * chi_ / RAY;
            uint256 totalSupply_ = totalSupply;
            diff = totalSupply_ * nChi / RAY - totalSupply_ * chi_ / RAY;

            // Safe as nChi is limited to maxUint256/RAY (which is < maxUint192)
            chi = uint192(nChi);
            rho = uint64(block.timestamp);
        } else {
            nChi = chi_;
        }
        emit Drip(nChi, diff);
    }

    /**********************************************************************************************/
    /*** External view functions                                                                ***/
    /**********************************************************************************************/

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * nowChi() / RAY;
    }

    function totalAssets() external view returns (uint256) {
        return convertToAssets(totalSupply);
    }

    function assetsOf(address owner) external view returns (uint256) {
        return convertToAssets(balanceOf[owner]);
    }

    // Current value of the receiver's queued deposits, including the spUSDC yield earned so far
    function pendingDepositRequest(address receiver) external view returns (uint256) {
        return spUsdc.convertToAssets(pendingDepositShares[receiver]);
    }

    function pendingRedeemRequest(address receiver) external view returns (uint256) {
        return pendingRedeemShares[receiver];
    }

    function availableCapacity() public view returns (uint256) {
        return maxCapacity > totalSupply ? maxCapacity - totalSupply : 0;
    }

    // USDC the vault can pay out now without touching queued depositors' spUSDC:
    // idle USDC plus the free spUSDC sleeve, capped by what spUSDC itself can pay.
    function availableLiquidAssets() public view returns (uint256) {
        uint256 free   = spUsdc.balanceOf(address(this)) - totalQueuedDepositShares;
        uint256 sleeve = _min(
            spUsdc.convertToAssets(free),
            IERC20(asset).balanceOf(address(spUsdc))
        );
        return IERC20(asset).balanceOf(address(this)) + sleeve;
    }

    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    function nowChi() public view returns (uint256) {
        return (block.timestamp > rho) ? _rpow(vsr, block.timestamp - rho) * chi / RAY : chi;
    }

    /**********************************************************************************************/
    /*** Request internal helper functions                                                      ***/
    /**********************************************************************************************/

    // Mints spPRIME to `receiver` at the current price
    function _mint(address owner, address receiver, uint256 assets, uint256 chi_) internal {
        uint256 shares = assets * RAY / chi_;

        totalSupply         += shares;
        balanceOf[receiver] += shares;

        emit Transfer(address(0), receiver, shares);
        emit Deposit(owner, receiver, assets, shares);
    }

    // Pays queued redeems FIFO up to `maxAssets` net USDC, burning the escrowed shares
    function _processWithdrawQueue(uint256 maxAssets, uint256 chi_) internal {
        uint256 budget = _min(maxAssets, availableLiquidAssets());
        uint256 i      = withdrawHead;

        for (; i < withdrawQueue.length; ++i) {
            Request storage request = withdrawQueue[i];
            (uint256 shares, uint256 fee) = (request.amount, request.fee);

            // Partial fill: the largest share amount whose net fits the budget, rounded down
            if (_net(shares, fee, chi_) > budget) shares = budget * WAD / (WAD - fee) * RAY / chi_;

            uint256 net = _net(shares, fee, chi_);
            if (net == 0 && shares < request.amount) break;  // Budget too small to pay anything

            balanceOf[address(this)] -= shares;
            totalSupply              -= shares;

            pendingRedeemShares[request.receiver] -= shares;
            totalQueuedRedeemShares               -= shares;
            request.amount                        -= shares;
            budget                                -= net;

            emit Transfer(address(this), address(0), shares);

            _pay(request.receiver, net);

            emit Withdraw(request.owner, request.receiver, net, shares);

            if (request.amount != 0) break;  // Partial fill, entry stays at the head
        }

        withdrawHead = i;
    }

    function _net(uint256 shares, uint256 fee, uint256 chi_) internal pure returns (uint256) {
        uint256 gross = shares * chi_ / RAY;
        return gross - _divup(gross * fee, WAD);  // The fee stays in the vault
    }

    /**********************************************************************************************/
    /*** Liquidity internal helper functions                                                    ***/
    /**********************************************************************************************/

    // Pays `assets` of USDC from idle cash, pulling any shortfall from the free spUSDC sleeve
    function _pay(address receiver, uint256 assets) internal {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < assets) _withdrawFromSavings(assets - balance);

        SafeERC20.safeTransfer(IERC20(asset), receiver, assets);
    }

    function _withdrawFromSavings(uint256 assets) internal {
        spUsdc.withdraw(assets, address(this), address(this));
        require(
            spUsdc.balanceOf(address(this)) >= totalQueuedDepositShares,
            "SparkPrimeVault/queued-shares-locked"
        );
    }

    /**********************************************************************************************/
    /*** Token transfer internal helper functions                                               ***/
    /**********************************************************************************************/

    function _transfer(address from, address to, uint256 value) internal {
        uint256 balance = balanceOf[from];
        require(balance >= value, "SparkPrimeVault/insufficient-balance");

        // NOTE: Don't need an overflow check here b/c sum of all balances == totalSupply
        unchecked {
            balanceOf[from] = balance - value;
            balanceOf[to]  += value;
        }

        emit Transfer(from, to, value);
    }

    /**********************************************************************************************/
    /*** EIP712 internal helper functions                                                       ***/
    /**********************************************************************************************/

    function _calculateDomainSeparator(uint256 chainId) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                address(this)
            )
        );
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _calculateDomainSeparator(block.chainid);
    }

    function _isValidSignature(
        address signer,
        bytes32 digest,
        bytes memory signature
    ) internal view returns (bool valid) {
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            if (signer == ecrecover(digest, v, r, s)) {
                return true;
            }
        }

        if (signer.code.length > 0) {
            (bool success, bytes memory result) = signer.staticcall(
                abi.encodeCall(IERC1271.isValidSignature, (digest, signature))
            );
            valid = (success &&
                result.length == 32 &&
                abi.decode(result, (bytes4)) == IERC1271.isValidSignature.selector);
        }
    }

    /**********************************************************************************************/
    /*** General internal helper functions                                                      ***/
    /**********************************************************************************************/

    function _divup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // NOTE: _divup(0,0) will return 0 differing from natural solidity division
        unchecked {
            z = x != 0 ? ((x - 1) / y) + 1 : 0;
        }
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }

    function _rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        assembly {
            switch x case 0 {switch n case 0 {z := RAY} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := RAY } default { z := x }
                let half := div(RAY, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, RAY)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, RAY)
                    }
                }
            }
        }
    }

}
