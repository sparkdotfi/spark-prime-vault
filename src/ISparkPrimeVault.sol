// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import {
    IAccessControlEnumerable
} from "../lib/oz/contracts/access/extensions/IAccessControlEnumerable.sol";

import { IERC20Metadata } from "../lib/oz/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20Permit }   from "../lib/oz/contracts/token/ERC20/extensions/IERC20Permit.sol";

interface ISparkPrimeVault is IERC20Metadata, IERC20Permit, IAccessControlEnumerable {

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/

    /**
     * @notice Represents a request in one of the vault's queues.
     * @param  owner     The address that created the request and can update its recipient or, for
     *                   deposit requests, cancel it.
     * @param  recipient The address that receives the proceeds when the request is filled.
     * @param  shares    The unfilled shares of the request, savings shares for deposit and deposit
     *                   cancellation requests, vault shares for redeem requests.
     */
    struct Request {
        address owner;
        address recipient;
        uint256 shares;
    }

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    /**
     * @notice Emitted when the maximum capacity is updated.
     * @param  capacity The new maximum capacity [share units]
     */
    event CapacitySet(uint256 capacity);

    /**
     * @notice Emitted when claimable assets are transferred to their recipient.
     * @param  recipient The address receiving the assets
     * @param  assets    The amount of assets transferred [asset units]
     */
    event Claim(address indexed recipient, uint256 assets);

    /**
     * @notice Emitted when assets that could not be sent to a recipient are credited to them as
     *         claimable assets.
     * @param  recipient The address credited with the claimable assets
     * @param  increase  The amount of claimable assets credited [asset units]
     */
    event ClaimableAssetsIncreased(address indexed recipient, uint256 increase);

    /**
     * @notice Emitted when a deposit request is filled, fully or partially.
     * @param  requestId             The ID of the deposit request
     * @param  owner                 The owner of the deposit request
     * @param  recipient             The address receiving the minted shares
     * @param  savingsSharesConsumed The amount of savings shares filled [savings share units]
     * @param  assetsConverted       The asset value of the filled savings shares [asset units]
     * @param  sharesMinted          The amount of vault shares minted to the recipient
     *                               [share units]
     */
    event Deposit(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         savingsSharesConsumed,
        uint256         assetsConverted,
        uint256         sharesMinted
    );

    /**
     * @notice Emitted when a deposit cancellation request is filled, fully or partially.
     * @param  requestId           The ID of the deposit cancellation request
     * @param  owner               The owner of the deposit cancellation request
     * @param  recipient           The address receiving the assets
     * @param  savingsSharesBurned The amount of savings shares redeemed [savings share units]
     * @param  assetsReceived      The amount of assets sent to, or made claimable by, the
     *                             recipient [asset units]
     */
    event DepositCancellation(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         savingsSharesBurned,
        uint256         assetsReceived
    );

    /**
     * @notice Emitted when the recipient of a deposit cancellation request is updated.
     * @param  requestId The ID of the deposit cancellation request
     * @param  recipient The new recipient of the request
     */
    event DepositCancellationRecipientUpdated(uint256 indexed requestId, address indexed recipient);

    /**
     * @notice Emitted when savings shares of a deposit request are cancelled, fully or partially,
     *         and moved to the deposit cancellation queue.
     * @param  depositRequestId The ID of the deposit request
     * @param  cancelRequestId  The ID of the new deposit cancellation request
     * @param  recipient        The address to receive the assets when the cancellation is filled
     * @param  sharesCancelled  The amount of savings shares cancelled [savings share units]
     */
    event DepositCancellationRequest(
        uint256 indexed depositRequestId,
        uint256 indexed cancelRequestId,
        address indexed recipient,
        uint256         sharesCancelled
    );

    /**
     * @notice Emitted when the recipient of a deposit request is updated.
     * @param  requestId The ID of the deposit request
     * @param  recipient The new recipient of the request
     */
    event DepositRecipientUpdated(uint256 indexed requestId, address indexed recipient);

    /**
     * @notice Emitted when a deposit is requested.
     * @param  requestId           The ID of the deposit request
     * @param  owner               The address that created the request
     * @param  recipient           The address to receive the shares when the request is filled
     * @param  assetsDeposited     The amount of assets deposited [asset units]
     * @param  savingsSharesMinted The amount of savings shares received for the assets
     *                             [savings share units]
     */
    event DepositRequest(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         assetsDeposited,
        uint256         savingsSharesMinted
    );

    /**
     * @notice Emitted every time drip() is called at a new rho.
     * @param  chi  The new rate accumulator value after the drip operation [ray]
     * @param  diff The difference in total assets due to the rate accumulation [asset units]
     */
    event Drip(uint192 chi, uint256 diff);

    /**
     * @notice Emitted when the maximum redeem fee rate is updated.
     * @param  fee The new maximum redeem fee rate [wad]
     */
    event MaxRedeemFeeRateSet(uint256 fee);

    /**
     * @notice Emitted when the minimum deposit cancellation is updated.
     * @param  minDepositCancellation The new minimum deposit cancellation [savings share units]
     */
    event MinDepositCancellationSet(uint256 minDepositCancellation);

    /**
     * @notice Emitted when the minimum deposit is updated.
     * @param  minDeposit The new minimum deposit [asset units]
     */
    event MinDepositSet(uint256 minDeposit);

    /**
     * @notice Emitted when the minimum redeem is updated.
     * @param  minRedeem The new minimum redeem [share units]
     */
    event MinRedeemSet(uint256 minRedeem);

    /// @notice Emitted when the vault is paused.
    event Paused();

    /**
     * @notice Emitted when a redeem request is filled, fully or partially.
     * @param  requestId           The ID of the redeem request
     * @param  owner               The owner of the redeem request
     * @param  recipient           The address receiving the assets
     * @param  sharesBurned        The amount of vault shares burned [share units]
     * @param  savingsSharesBurned The amount of savings shares withdrawn [savings share units]
     * @param  assetsReceived      The amount of assets sent to, or made claimable by, the
     *                             recipient [asset units]
     */
    event Redeem(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         sharesBurned,
        uint256         savingsSharesBurned,
        uint256         assetsReceived
    );

    /**
     * @notice Emitted when the redeem fee rate is updated.
     * @param  fee The new redeem fee rate [wad]
     */
    event RedeemFeeRateSet(uint256 fee);

    /**
     * @notice Emitted when the recipient of a redeem request is updated.
     * @param  requestId The ID of the redeem request
     * @param  recipient The new recipient of the request
     */
    event RedeemRecipientUpdated(uint256 indexed requestId, address indexed recipient);

    /**
     * @notice Emitted when a redemption is requested.
     * @param  requestId       The ID of the redeem request
     * @param  owner           The address that created the request
     * @param  recipient       The address to receive the assets when the request is filled
     * @param  sharesToBurn    The amount of vault shares transferred in, including the fee
     *                         [share units]
     * @param  feeSharesBurned The amount of vault shares burned as the redeem fee [share units]
     */
    event RedeemRequest(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         sharesToBurn,
        uint256         feeSharesBurned
    );

    /**
     * @notice Emitted when a deposit is requested with referral tracking.
     * @param  referral  The referral ID (16-bit) used for tracking user acquisition
     * @param  requestId The ID of the deposit request
     * @param  owner     The address that created the request
     * @param  recipient The address to receive the shares when the request is filled
     * @param  assets    The amount of underlying assets deposited [asset units]
     */
    event Referral(
        uint16  indexed referral,
        uint256 indexed requestId,
        address         owner,
        address         recipient,
        uint256         assets
    );

    /**
     * @notice Emitted when savings shares are withdrawn from the vault by accounts with TAKER_ROLE.
     * @param  shares The amount of savings shares withdrawn from the vault [savings share units]
     */
    event Take(uint256 shares);

    /**
     * @notice Emitted when the total assets of the vault are adjusted.
     * @param  chi              The new rate accumulator value after the adjustment [ray]
     * @param  deltaTotalAssets The signed change in total assets [asset units]
     */
    event TotalAssetsAdjusted(uint192 chi, int256 deltaTotalAssets);

    /// @notice Emitted when the vault is unpaused.
    event Unpaused();

    /**
     * @notice Emitted when the bounds for the Vault Savings Rate (VSR) are updated.
     * @param  minVSR The new minimum allowed VSR value [ray]
     * @param  maxVSR The new maximum allowed VSR value [ray]
     */
    event VSRBoundsSet(uint256 minVSR, uint256 maxVSR);

    /**
     * @notice Emitted when the Vault Savings Rate (VSR) is updated.
     * @param  vsr The new VSR value after the update [ray]
     */
    event VSRSet(uint256 vsr);

    /**********************************************************************************************/
    /*** Custom Errors                                                                          ***/
    /**********************************************************************************************/

    /// @notice Thrown when the deposit amount is below the minimum deposit.
    error BelowMinDeposit();

    /// @notice Thrown when the deposit cancellation amount is below the minimum deposit
    ///         cancellation.
    error BelowMinDepositCancellation();

    /// @notice Thrown when the redeem amount is below the minimum redeem.
    error BelowMinRedeem();

    /// @notice Thrown when a total assets adjustment would make chi exceed type(uint192).max.
    error ChiTooHigh();

    /// @notice Thrown when a total assets adjustment would make chi zero.
    error ChiTooLow();

    /// @notice Thrown when the redeem fee rate is above the maximum redeem fee rate.
    error FeeTooHigh();

    /// @notice Thrown when taking more savings shares than the vault holds.
    error InsufficientShares();

    /// @notice Thrown when a request ID is past the end of the queue or, in the single-request
    ///         getters, before the first pending request.
    error InvalidRequestId();

    /// @notice Thrown when an action requires the vault to be paused.
    error IsNotPaused();

    /// @notice Thrown when an action is attempted while the vault is paused.
    error IsPaused();

    /// @notice Thrown when a requested range of requests extends past the end of the queue.
    error LengthTooLarge();

    /// @notice Thrown when a total assets adjustment would reduce total assets to zero or below.
    error LossTooHigh();

    /// @notice Thrown when the maximum redeem fee rate is above MAX_REDEEM_FEE.
    error MaxFeeTooHigh();

    /// @notice Thrown when the maximum VSR bound is above MAX_VSR.
    error MaxVSRTooHigh();

    /// @notice Thrown when the VSR bounds are set such that the minimum is greater than the
    ///         maximum.
    error MinVSRGtMaxVSR();

    /// @notice Thrown when the minimum VSR bound is below RAY.
    error MinVSRTooLow();

    /// @notice Thrown when the request has no unfilled shares because it was cancelled or
    ///         already filled.
    error NoRequest();

    /// @notice Thrown when the recipient has no claimable assets.
    error NothingToClaim();

    /// @notice Thrown when the caller is not the owner of the request.
    error NotRequestOwner();

    /// @notice Thrown when cancelling more savings shares than the deposit request has.
    error SavingsSharesTooHigh();

    /// @notice Thrown when a requested range of requests starts before the first pending request.
    error StartIdTooSmall();

    /// @notice Thrown when the recipient is the vault itself.
    error VaultIsRecipient();

    /// @notice Thrown when the VSR is above the maximum allowed bound.
    error VSRTooHigh();

    /// @notice Thrown when the VSR is below the minimum allowed bound.
    error VSRTooLow();

    /// @notice Thrown when the total assets adjustment is zero.
    error ZeroDeltaTotalAssets();

    /// @notice Thrown when the minimum deposit is set to zero.
    error ZeroMinDeposit();

    /// @notice Thrown when the minimum deposit cancellation is set to zero.
    error ZeroMinDepositCancellation();

    /// @notice Thrown when the minimum redeem is set to zero.
    error ZeroMinRedeem();

    /// @notice Thrown when the recipient is address(0).
    error ZeroRecipient();

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    /// @notice Returns the identifier of the role that can adjust the total assets.
    function LOSS_MANAGER_ROLE() external view returns (bytes32);

    /// @notice Returns the absolute maximum allowed redeem fee rate [wad].
    function MAX_REDEEM_FEE() external view returns (uint256);

    /// @notice Returns the absolute maximum allowed Vault Savings Rate (VSR).
    function MAX_VSR() external view returns (uint256);

    /**
     * @notice Returns the identifier of the role that can process the request queues set VSR, and
     *         set capacity.
     */
    function OPERATOR_ROLE() external view returns (bytes32);

    /// @notice Returns the identifier of the role that can pause the vault.
    function PAUSER_ROLE() external view returns (bytes32);

    /// @notice Returns the EIP-712 typehash of the permit struct.
    function PERMIT_TYPEHASH() external view returns (bytes32);

    /// @notice Returns the precision multiplier representing 1.0 (1e27).
    function RAY() external view returns (uint256);

    /// @notice Returns the identifier of the role that can set the redeem fee rate.
    function REDEEM_FEE_SETTER_ROLE() external view returns (bytes32);

    /// @notice Returns the identifier of the role that can take savings shares.
    function TAKER_ROLE() external view returns (bytes32);

    /// @notice Returns the identifier of the role that can unpause the vault.
    function UNPAUSER_ROLE() external view returns (bytes32);

    /// @notice Returns the precision multiplier representing 1.0 (1e18).
    function WAD() external view returns (uint256);

    /**
     * @notice Returns the version of the vault implementation.
     * @return The version string.
     */
    function version() external view returns (string memory);

    /**********************************************************************************************/
    /*** Storage variables                                                                      ***/
    /**********************************************************************************************/

    /// @notice Returns the address of the ERC-4626 savings vault the deposited assets are held in.
    function savings() external view returns (address);

    /// @notice Returns the address of the underlying asset.
    function asset() external view returns (address);

    /// @notice Returns whether the vault is paused.
    function paused() external view returns (bool);

    /**
     * @notice Returns the timestamp of the last drip operation.
     * @dev    rho tracks when the rate accumulator was last updated.
     * @return The timestamp of the last drip [unix epoch time]
     */
    function rho() external view returns (uint64);

    /**
     * @notice Returns the current rate accumulator value [ray].
     * @dev    Chi represents the cumulative growth factor for all shares. It starts at 1e27 (RAY) and
     *         increases exponentially over time based on the Vault Savings Rate (VSR). The formula is:
     *         chi = chi_old * (vsr)^(time_delta) / RAY where time_delta is the time since last drip.
     *         User assets = user_shares * nowChi() / RAY
     *         It can also be set directly by adjustTotalAssets().
     */
    function chi() external view returns (uint192);

    /**
     * @notice Returns the current Vault Savings Rate [ray].
     * @dev    The VSR is the rate at which the vault's shares appreciate in value over time.
     *         It's expressed in ray (1e27).
     */
    function vsr() external view returns (uint256);

    /// @notice Returns the minimum allowed VSR value.
    function minVSR() external view returns (uint256);

    /// @notice Returns the maximum allowed VSR value.
    function maxVSR() external view returns (uint256);

    /// @notice Returns the maximum total supply of shares [share units].
    function maxCapacity() external view returns (uint256);

    /// @notice Returns the minimum amount of assets for a deposit request [asset units].
    function minDeposit() external view returns (uint256);

    /**
     * @notice Returns the minimum amount of savings shares for a deposit cancellation request
     *         [savings share units].
     */
    function minDepositCancellation() external view returns (uint256);

    /// @notice Returns the minimum amount of shares for a redeem request [share units].
    function minRedeem() external view returns (uint256);

    /// @notice Returns the fee rate burned from the shares of redeem requests [wad].
    function redeemFeeRate() external view returns (uint256);

    /// @notice Returns the maximum allowed redeem fee rate [wad].
    function maxRedeemFeeRate() external view returns (uint256);

    /// @notice Returns the total savings shares in the deposit queue [savings share units].
    function pendingDepositSavingsShares() external view returns (uint256);

    /**
     * @notice Returns the total savings shares in the deposit cancellation queue
     *         [savings share units].
     */
    function pendingCancelledDepositSavingsShares() external view returns (uint256);

    /// @notice Returns the total vault shares in the redeem queue [share units].
    function pendingRedeemShares() external view returns (uint256);

    /// @notice Returns the first unfilled request ID of the deposit queue.
    function firstPendingDepositId() external view returns (uint256);

    /// @notice Returns the first unfilled request ID of the deposit cancellation queue.
    function firstPendingDepositCancellationId() external view returns (uint256);

    /// @notice Returns the first unfilled request ID of the redeem queue.
    function firstPendingRedeemId() external view returns (uint256);

    /**
     * @notice Returns the assets of `account` that are claimable via claim().
     * @param  account The address of the recipient
     * @return assets  The amount of claimable assets [asset units]
     */
    function claimableAssets(address account) external view returns (uint256 assets);

    /**********************************************************************************************/
    /*** Initialization and upgradeability                                                      ***/
    /**********************************************************************************************/

    /**
     * @notice Initializes the vault implementation with core configuration.
     * @dev    Can only be called once. Sets the asset and decimals from `savings_`, sets
     *         chi/vsr/minVSR/maxVSR to RAY, sets rho to block.timestamp, grants DEFAULT_ADMIN_ROLE
     *         to `admin`, sets the minimum deposit, deposit cancellation and redeem amounts, and
     *         approves `savings_` to spend the vault's assets. All minimums must be nonzero.
     * @param  savings_                The address of the ERC-4626 savings vault the deposited
     *                                 assets are held in
     * @param  name_                   The name of the vault token
     * @param  symbol_                 The symbol of the vault token
     * @param  admin                   The address to be granted the admin role
     * @param  minDeposit_             The minimum amount of assets for a deposit request
     *                                 [asset units]
     * @param  minDepositCancellation_ The minimum amount of savings shares for a deposit
     *                                 cancellation request [savings share units]
     * @param  minRedeem_              The minimum amount of shares for a redeem request
     *                                 [share units]
     */
    function initialize(
        address        savings_,
        string  memory name_,
        string  memory symbol_,
        address        admin,
        uint256        minDeposit_,
        uint256        minDepositCancellation_,
        uint256        minRedeem_
    ) external;

    /**********************************************************************************************/
    /*** Admin external functions                                                               ***/
    /**********************************************************************************************/

    /**
     * @notice Sets the maximum redeem fee rate.
     * @dev    This function can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *         The rate must be less than or equal to MAX_REDEEM_FEE. The current redeem fee rate
     *         is not changed, even if it is above the new maximum.
     * @param  feeRate_ The new maximum redeem fee rate [wad]
     */
    function setMaxRedeemFeeRate(uint256 feeRate_) external;

    /**
     * @notice Sets the minimum amount of assets for a deposit request.
     * @dev    This function can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *         The minimum must be nonzero.
     * @param  minDeposit_ The new minimum deposit [asset units]
     */
    function setMinDeposit(uint256 minDeposit_) external;

    /**
     * @notice Sets the minimum amount of savings shares for a deposit cancellation request.
     * @dev    This function can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *         The minimum must be nonzero.
     * @param  minDepositCancellation_ The new minimum deposit cancellation [savings share units]
     */
    function setMinDepositCancellation(uint256 minDepositCancellation_) external;

    /**
     * @notice Sets the minimum amount of shares for a redeem request.
     * @dev    This function can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *         The minimum must be nonzero.
     * @param  minRedeem_ The new minimum redeem [share units]
     */
    function setMinRedeem(uint256 minRedeem_) external;

    /**
     * @notice Sets the bounds for the Vault Savings Rate (VSR).
     * @dev    This function can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *         `minVSR_` must be at least RAY, `maxVSR_` at most MAX_VSR, and `minVSR_` at most
     *         `maxVSR_`. The current VSR is not changed, even if it falls outside the new bounds.
     * @param  minVSR_ The new minimum allowed VSR value [ray]
     * @param  maxVSR_ The new maximum allowed VSR value [ray]
     */
    function setVSRBounds(uint256 minVSR_, uint256 maxVSR_) external;

    /**********************************************************************************************/
    /*** Loss Manager external functions                                                        ***/
    /**********************************************************************************************/

    /**
     * @notice Adjusts the total assets of the vault by updating the rate accumulator (chi).
     * @dev    This function can only be called by accounts with LOSS_MANAGER_ROLE while the vault
     *         is paused. Drips before computing the new chi as:
     *         chi = (totalAssets() + deltaTotalAssets_) * RAY / totalSupply
     *         `deltaTotalAssets_` must be nonzero and the resulting total assets must be positive.
     *         Reverts if totalSupply is zero.
     * @param  deltaTotalAssets_ The signed change in total assets [asset units]
     */
    function adjustTotalAssets(int256 deltaTotalAssets_) external;

    /**********************************************************************************************/
    /*** Taker external functions                                                               ***/
    /**********************************************************************************************/

    /**
     * @notice Allows authorized accounts to withdraw savings shares from the vault.
     * @dev    This function can only be called by accounts with TAKER_ROLE.
     *         The function transfers the specified amount of savings shares to the caller.
     * @param  savingsShares_ The amount of savings shares to withdraw [savings share units]
     */
    function take(uint256 savingsShares_) external;

    /**********************************************************************************************/
    /*** Operator external functions                                                            ***/
    /**********************************************************************************************/

    /**
     * @notice Sets the maximum capacity of the vault.
     * @dev    This function can only be called by accounts with OPERATOR_ROLE.
     *         Deposit requests are only filled while totalSupply is below this value.
     * @param  capacity_ The new maximum capacity [share units]
     */
    function setCapacity(uint256 capacity_) external;

    /**
     * @notice Sets the Vault Savings Rate (VSR) within the configured bounds.
     * @dev    This function can only be called by accounts with OPERATOR_ROLE.
     *         Drips before updating the VSR, so the previous rate applies up to the current block.
     *         The VSR determines the rate at which user shares grow over time. A higher VSR
     *         means faster share growth and higher yields for depositors.
     * @param  vsr_ The new VSR value [ray]
     */
    function setVSR(uint256 vsr_) external;

    /**
     * @notice Fills pending deposit requests in queue order, minting shares to their recipients.
     * @dev    This function can only be called by accounts with OPERATOR_ROLE while the vault is
     *         not paused. Processing is limited by `maxSavingsShares_`, `maxRequests_`, and the
     *         available capacity. The last processed request may be partially filled.
     * @param  maxSavingsShares_ The maximum amount of savings shares to process
     *                           [savings share units]
     * @param  maxRequests_      The maximum number of queue entries to visit, counting fully
     *                           cancelled ones
     */
    function processPendingDeposits(uint256 maxSavingsShares_, uint256 maxRequests_) external;

    /**
     * @notice Fills pending deposit cancellation requests in queue order, redeeming their savings
     *         shares for their recipients.
     * @dev    This function can only be called by accounts with OPERATOR_ROLE while the vault is
     *         not paused. Processing is limited by `maxSavingsShares_`, `maxRequests_`, and the
     *         savings shares the vault can redeem. The last processed request may be partially
     *         filled. Assets that cannot be sent to a recipient are credited as claimable assets.
     * @param  maxSavingsShares_ The maximum amount of savings shares to process
     *                           [savings share units]
     * @param  maxRequests_      The maximum number of queue entries to visit
     */
    function processPendingDepositCancellations(uint256 maxSavingsShares_, uint256 maxRequests_)
        external;

    /**
     * @notice Fills pending redeem requests in queue order, burning their shares and withdrawing
     *         assets for their recipients.
     * @dev    This function can only be called by accounts with OPERATOR_ROLE while the vault is
     *         not paused. Processing is limited by `maxShares_`, `maxRequests_`, and the available
     *         liquid assets, which are re-checked before each request. The last processed request
     *         may be partially filled. Assets that cannot be sent to a recipient are credited as
     *         claimable assets.
     * @param  maxShares_   The maximum amount of vault shares to process [share units]
     * @param  maxRequests_ The maximum number of queue entries to visit
     */
    function processPendingRedeems(uint256 maxShares_, uint256 maxRequests_) external;

    /**********************************************************************************************/
    /*** Redeem Fee Setter external functions                                                   ***/
    /**********************************************************************************************/

    /**
     * @notice Sets the redeem fee rate within the configured maximum.
     * @dev    This function can only be called by accounts with REDEEM_FEE_SETTER_ROLE.
     *         The rate must be less than or equal to maxRedeemFeeRate.
     * @param  feeRate_ The new redeem fee rate [wad]
     */
    function setRedeemFeeRate(uint256 feeRate_) external;

    /**********************************************************************************************/
    /*** Pauser external functions                                                              ***/
    /**********************************************************************************************/

    /**
     * @notice Pauses the vault.
     * @dev    This function can only be called by accounts with PAUSER_ROLE.
     *         While paused, new requests and queue processing are disabled.
     */
    function pause() external;

    /**********************************************************************************************/
    /*** Unpauser external functions                                                            ***/
    /**********************************************************************************************/

    /**
     * @notice Unpauses the vault.
     * @dev    This function can only be called by accounts with UNPAUSER_ROLE.
     */
    function unpause() external;

    /**********************************************************************************************/
    /*** Request functions                                                                      ***/
    /**********************************************************************************************/

    /**
     * @notice Requests a deposit of assets, which are deposited into the savings vault and queued
     *         to be converted into shares.
     * @dev    Can only be called while the vault is not paused. `assets_` must be at least
     *         minDeposit. Updates the rate accumulator (drips) before depositing.
     *         If no unfilled deposit requests are queued ahead, the request is filled immediately,
     *         up to the available capacity, in which case the returned request may already be
     *         fully filled.
     * @param  assets_    The amount of assets to deposit [asset units]
     * @param  recipient_ The address to receive the minted shares
     * @param  referral_  The referral ID (16-bit) for tracking
     * @return requestId_ The ID of the deposit request
     */
    function requestDeposit(uint256 assets_, address recipient_, uint16 referral_)
        external
        returns (uint256 requestId_);

    /**
     * @notice Cancels `savingsShares_` of a deposit request and queues them to be redeemed for
     *         `recipient_`.
     * @dev    Can only be called by the owner of the request while the vault is not paused.
     *         `savingsShares_` must be at least minDepositCancellation and at most the unfilled
     *         savings shares of the request. If all of them are cancelled the deposit request is
     *         removed, otherwise it keeps the rest and its position in the queue.
     * @param  requestId_     The ID of the deposit request to cancel
     * @param  recipient_     The address to receive the assets when the cancellation is filled
     * @param  savingsShares_ The amount of savings shares to cancel [savings share units]
     * @return newRequestId_  The ID of the deposit cancellation request
     */
    function requestDepositCancellation(
        uint256 requestId_,
        address recipient_,
        uint256 savingsShares_
    ) external returns (uint256 newRequestId_);

    /**
     * @notice Requests a redemption of shares, which are transferred to the vault and queued to be
     *         redeemed for assets.
     * @dev    Can only be called while the vault is not paused. `shares_` must be at least
     *         `minRedeem`, checked before the fee is deducted. Updates the rate accumulator (drips)
     *         before transferring. The redeem fee is burned upfront from `shares_`, rounding up,
     *         and the remaining shares are queued.
     * @param  shares_    The amount of shares to redeem, including the fee [share units]
     * @param  recipient_ The address to receive the assets when the request is filled
     * @return requestId_ The ID of the redeem request
     */
    function requestRedeem(uint256 shares_, address recipient_)
        external
        returns (uint256 requestId_);

    /**********************************************************************************************/
    /*** Request update functions                                                               ***/
    /**********************************************************************************************/

    /**
     * @notice Updates the recipient of a deposit request.
     * @dev    Can only be called by the owner of the request.
     * @param  requestId_ The ID of the deposit request
     * @param  recipient_ The new address to receive the shares when the request is filled
     */
    function updateDepositRecipient(uint256 requestId_, address recipient_) external;

    /**
     * @notice Updates the recipient of a deposit cancellation request.
     * @dev    Can only be called by the owner of the request.
     * @param  requestId_ The ID of the deposit cancellation request
     * @param  recipient_ The new address to receive the assets when the request is filled
     */
    function updateDepositCancellationRecipient(uint256 requestId_, address recipient_) external;

    /**
     * @notice Updates the recipient of a redeem request.
     * @dev    Can only be called by the owner of the request.
     * @param  requestId_ The ID of the redeem request
     * @param  recipient_ The new address to receive the assets when the request is filled
     */
    function updateRedeemRecipient(uint256 requestId_, address recipient_) external;

    /**********************************************************************************************/
    /*** Claim functions                                                                        ***/
    /**********************************************************************************************/

    /**
     * @notice Transfers all claimable assets of `recipient_` to `recipient_`.
     * @dev    Permissionless, assets always go to `recipient_`.
     *         Reverts if the asset transfer fails.
     *         Claimable assets cannot be redirected to another address and there is no admin
     *         sweep, so assets of a recipient that can never receive are only recoverable via
     *         an upgrade.
     * @param  recipient_ The address whose claimable assets are transferred to it
     * @return assets_    The amount of assets transferred [asset units]
     */
    function claim(address recipient_) external returns (uint256 assets_);

    /**********************************************************************************************/
    /*** EIP712 external mutating functions                                                     ***/
    /**********************************************************************************************/

    /**
     * @notice Approves `spender_` to spend `value_` shares of `owner_` with an EIP-712 signature.
     * @dev    Supports ECDSA signatures from EOAs and ERC-1271 signatures from contracts.
     * @param  owner_     The address approving the spender
     * @param  spender_   The address being approved
     * @param  value_     The amount of shares approved [share units]
     * @param  deadline_  The timestamp after which the signature is no longer valid
     *                    [unix epoch time]
     * @param  signature_ The signature of `owner_` over the permit
     */
    function permit(
        address        owner_,
        address        spender_,
        uint256        value_,
        uint256        deadline_,
        bytes   memory signature_
    ) external;

    /**********************************************************************************************/
    /*** Rate accumulation                                                                      ***/
    /**********************************************************************************************/

    /**
     * @notice Updates the rate accumulator and returns the new value.
     * @dev    This function calculates the new chi value based on the time elapsed since the last drip
     *         and the current VSR. The formula used is:
     *         new_chi = old_chi * (vsr)^(block.timestamp - rho) / RAY
     * @return nChi_ The new Chi value [ray]
     */
    function drip() external returns (uint192 nChi_);

    /**********************************************************************************************/
    /*** Request getter functions                                                               ***/
    /**********************************************************************************************/

    /**
     * @notice Returns a pending deposit request.
     * @dev    Reverts if `requestId_` is before the first pending request or does not exist.
     * @param  requestId_ The ID of the deposit request
     * @return owner_     The owner of the request
     * @return recipient_ The address to receive the shares when the request is filled
     * @return shares_    The unfilled savings shares of the request [savings share units]
     */
    function getPendingDepositRequest(uint256 requestId_)
        external
        view
        returns (address owner_, address recipient_, uint256 shares_);

    /**
     * @notice Returns the deposit requests from the first pending request to the end of the queue.
     * @dev    Includes fully cancelled requests, which have zero shares.
     * @return requests_ The deposit requests
     */
    function getPendingDepositRequests() external view returns (Request[] memory requests_);

    /**
     * @notice Returns `length_` deposit requests, starting from the request with ID `startId_`.
     * @dev    Reverts if `length_` is zero, `startId_` is before the first pending request, or the
     *         range extends past the end of the queue.
     *         Includes fully cancelled requests, which have zero shares.
     * @param  startId_  The first request ID to return
     * @param  length_   The number of requests to return
     * @return requests_ The deposit requests
     */
    function getPendingDepositRequests(uint256 startId_, uint256 length_)
        external
        view
        returns (Request[] memory requests_);

    /**
     * @notice Returns a pending deposit cancellation request.
     * @dev    Reverts if `requestId_` is before the first pending request or does not exist.
     * @param  requestId_ The ID of the deposit cancellation request
     * @return owner_     The owner of the request
     * @return recipient_ The address to receive the assets when the request is filled
     * @return shares_    The unfilled savings shares of the request [savings share units]
     */
    function getPendingDepositCancellationRequest(uint256 requestId_)
        external
        view
        returns (address owner_, address recipient_, uint256 shares_);

    /**
     * @notice Returns the deposit cancellation requests from the first pending request to the end
     *         of the queue.
     * @return requests_ The deposit cancellation requests
     */
    function getPendingDepositCancellationRequests()
        external
        view
        returns (Request[] memory requests_);

    /**
     * @notice Returns `length_` deposit cancellation requests, starting from the request with ID
     *         `startId_`.
     * @dev    Reverts if `length_` is zero, `startId_` is before the first pending request, or the
     *         range extends past the end of the queue.
     * @param  startId_  The first request ID to return
     * @param  length_   The number of requests to return
     * @return requests_ The deposit cancellation requests
     */
    function getPendingDepositCancellationRequests(uint256 startId_, uint256 length_)
        external
        view
        returns (Request[] memory requests_);

    /**
     * @notice Returns a pending redeem request.
     * @dev    Reverts if `requestId_` is before the first pending request or does not exist.
     * @param  requestId_ The ID of the redeem request
     * @return owner_     The owner of the request
     * @return recipient_ The address to receive the assets when the request is filled
     * @return shares_    The unfilled vault shares of the request [share units]
     */
    function getPendingRedeemRequest(uint256 requestId_)
        external
        view
        returns (address owner_, address recipient_, uint256 shares_);

    /**
     * @notice Returns the redeem requests from the first pending request to the end of the queue.
     * @return requests_ The redeem requests
     */
    function getPendingRedeemRequests() external view returns (Request[] memory requests_);

    /**
     * @notice Returns `length_` redeem requests, starting from the request with ID `startId_`.
     * @dev    Reverts if `length_` is zero, `startId_` is before the first pending request, or the
     *         range extends past the end of the queue.
     * @param  startId_  The first request ID to return
     * @param  length_   The number of requests to return
     * @return requests_ The redeem requests
     */
    function getPendingRedeemRequests(uint256 startId_, uint256 length_)
        external
        view
        returns (Request[] memory requests_);

    /**********************************************************************************************/
    /*** External view functions                                                                ***/
    /**********************************************************************************************/

    /**
     * @notice Returns the value of the shares of `owner_`, calculated up to the current block
     *         timestamp.
     * @param  owner_  The address of the share owner
     * @return assets_ The value of the shares. [asset units]
     */
    function assetsOf(address owner_) external view returns (uint256 assets_);

    /**
     * @notice Returns the amount of shares that can still be minted before reaching the maximum
     *         capacity. [share units]
     */
    function availableCapacity() external view returns (uint256);

    /**
     * @notice Returns the amount of assets the vault can currently withdraw from the savings vault.
     *         [asset units]
     */
    function availableLiquidAssets() external view returns (uint256);

    /**
     * @notice Returns the value of `shares_`, calculated up to the current block timestamp.
     * @dev    Rounds down.
     * @param  shares_ The amount of shares [share units]
     * @return assets_ The value of the shares [asset units]
     */
    function convertToAssets(uint256 shares_) external view returns (uint256 assets_);

    /**
     * @notice Returns the amount of shares worth `assets_`, calculated up to the current block
     *         timestamp.
     * @dev    Rounds down.
     * @param  assets_ The amount of assets [asset units]
     * @return shares_ The amount of shares [share units]
     */
    function convertToShares(uint256 assets_) external view returns (uint256 shares_);

    /// @notice Returns the address of the current implementation contract.
    function implementation() external view returns (address);

    /**
     * @notice Returns the current rate accumulator calculated up to the current block timestamp.
     *         [ray]
     */
    function nowChi() external view returns (uint192);

    /**
     * @notice Returns the value of the total supply of shares, calculated up to the current block
     *         timestamp. [asset units]
     */
    function totalAssets() external view returns (uint256);

    /// @notice Returns the total claimable assets in the vault.
    function totalClaimable() external view returns (uint256);

}
