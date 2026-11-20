# Spark Prime Vault (`spPRIME`)

An upgradeable (UUPS), yield-accruing vault token denominated in an underlying asset (e.g., USDC) that holds its liquidity in an ERC-4626 savings sleeve (e.g., `spUSDC`), featuring asynchronous FIFO queues for deposits, deposit cancellations, and redemptions in capacity- and liquidity-constrained environments, and operator-controlled suspension of individual requests.

`totalAssets()` (`totalSupply * chi`) is the value owed to share holders at the administered rate, not the assets held by the vault. The vault's savings share balance also backs pending and suspended deposits and cancellations, and `TAKER_ROLE` can move it out for external allocation, so it does not track `totalAssets()`.

The vault token is a standard ERC-20 (with EIP-2612-style `permit`, supporting both ECDSA and ERC-1271 signatures) whose `decimals` match the underlying asset. Transfers to the zero address or to the vault itself are rejected. `permit` uses the ERC-1271 path for any `owner` that has code, which includes EOAs that delegated to a contract via EIP-7702, so such accounts must implement ERC-1271 to sign permits.

> [!WARNING]
> **THIS VAULT IS INTENDED TO BE USED WITH `spark-vaults-v2@v1.0.1` AS THE `savings` VAULT. ANY OTHER `savings` IMPLEMENTATION SHOULD BE REVIEWED FROM FIRST PRINCIPLES.**
>
> If another vault is used, it must AT LEAST adhere to these standards:
>
> **Savings vault**
>
> - `redeem(shares, receiver, owner)` succeeds for any amount, including zero shares, or shares that round to zero assets. This is because processing the redeem and cancellation queues can call `redeem` with 0 or dust amounts that are worth zero assets.
> - `maxWithdraw(address(this))` and `maxRedeem(address(this))` return amounts that a `redeem` in the same block will honour in full.
> - No deposit or exit fee. `convertToAssets`, `convertToShares`, and the executed amounts agree up to rounding, and the full asset amount reaches the receiver.
> - The share price never decreases.
> - Redemptions are synchronous and pay out to an arbitrary receiver.
> - `deposit` accepts the vault as both caller and receiver.
>
> **Underlying asset**
>
> - `transfer` succeeds for any amount, including zero.

## Core Mechanisms

### 1. Rate Accumulator (`chi` & `vsr`)

- Yield accrues continuously via the Vault Savings Rate (`vsr`), a per-second compounding factor (ray).
- `drip()` (public) compounds accumulated interest into the accumulator `chi` and emits `Drip`. It does nothing when called again in the same block (`block.timestamp <= rho`). It is also invoked by `setVSR`, `impair`, `requestDeposit`, `requestRedeem`, and all `process*` functions. `requestDepositCancellation` and the suspend/unsuspend functions do **not** drip.
- Share-to-asset conversion: `assets = shares * nowChi() / RAY`, where `nowChi()` is the up-to-date `chi` without writing state.
- Initialized with `chi = vsr = minVSR = maxVSR = RAY` (0% yield) until the admin sets bounds and `OPERATOR_ROLE` sets a rate.
- `vsr` must stay within `[minVSR, maxVSR]`. Bounds are configured by `DEFAULT_ADMIN_ROLE` with `minVSR >= RAY` and `maxVSR <= MAX_VSR` (100% APY). Changing the bounds does not change the current `vsr`, even if it falls outside the new bounds.
- **Loss Realization**: While paused, `LOSS_MANAGER_ROLE` can call `impair(assets_)` to settle the pending drip and rewrite `chi` so that `totalAssets` is decremented by `assets_`. Pausing first blocks deposit and redeem requests and their processing so they cannot front-run the impairment; deposit cancellations remain available while paused. `assets_` must be nonzero and at most `totalAssets` (so `totalSupply` must be non-zero). Impairing the full `totalAssets` sets `chi` to zero, after which `convertToShares` reverts (breaking deposit and redeem processing) and `convertToAssets` returns zero until an upgrade. Gains are not booked on-chain; yield reaches holders only through the VSR.

### 2. Deposits & Deposit Queue

Deposits are always two-step and asynchronous (there is no instant fill): the user's assets go to the savings sleeve immediately, and vault shares are minted when the operator processes the request, subject to capacity.

- **Request**: `requestDeposit(assets, recipient, referral)` drips, pulls `assets` from the caller, deposits them into the savings vault (`spUSDC`), and appends a request denominated in **savings shares** to the FIFO `_pendingDeposits` queue. Requires the vault to be unpaused, `assets >= minDeposit`, and that `recipient` is neither the zero address nor the vault. Emits `Referral` (with the integrator's `referral` code) and `DepositRequest`.
- **Queueing**: Requests wait in `_pendingDeposits` until processed. Queued depositors keep earning savings yield while waiting, since the vault holds their savings shares.
- **Capacity**: Fills are bounded by `availableCapacity() = maxCapacity - totalSupply` (floored at 0), converted to savings shares.
- **Processing**: `OPERATOR_ROLE` calls `processPendingDeposits(maxSavingsShares, maxRequests)` while unpaused. It drips, then converts savings shares to assets and mints `spPrime` to each request's `recipient` at the current `chi`. Fully filled requests are unlinked and deleted; requests can be **partially filled**, in which case the partially filled request stays at the head of the queue.
- **Updating the recipient**: The request `owner` can call `updateDepositRecipient(requestId, recipient)` on a pending deposit request to change who receives the minted shares.

### 3. Deposit Cancellation & Cancellation Queue

- **Request**: The request `owner` (only) calls `requestDepositCancellation(requestId, recipient, savingsShares)` on a pending deposit request (`NoRequest` otherwise, including if suspended, already filled, or cancelled). `recipient` must be neither the zero address nor the vault. `savingsShares` must be at least `minDepositCancellation` and at most the deposit request's unfilled savings shares; a new request is appended to the FIFO `_pendingDepositCancellations` queue.
- **Partial cancellation**: If all unfilled savings shares are cancelled, the deposit request is immediately unlinked from `_pendingDeposits` and deleted (leaving no tombstone). Otherwise it keeps the rest and its position in the deposit queue.
- **Processing**: `OPERATOR_ROLE` calls `processPendingDepositCancellations(maxSavingsShares, maxRequests)`, which drips, redeems the savings shares for the underlying asset, and sends it to the `recipient`. Bounded by what the savings vault can redeem (`maxRedeem`). Because the refund is made from the queued savings shares, it includes all savings yield accrued while queued. Fully filled requests are unlinked and deleted; partial fills are supported and remain at the head of the queue.
- **Updating the recipient**: The `owner` can call `updateDepositCancellationRecipient(requestId, recipient)` on a pending cancellation request.

### 4. Redemptions & Redeem Queue

Redemptions are always asynchronous (there is no instant fill).

- **Request**: `requestRedeem(shares, recipient)` drips, transfers `shares` from the caller into the vault, and requires the vault to be unpaused, `shares >= minRedeem` (checked before the fee), and that `recipient` is neither the zero address nor the vault.
- **Redeem Fee**: The fee is taken **upfront in shares**: `fee = ceil(shares * redeemFeeRate / WAD)` is burned immediately, and only `shares - fee` is queued. The rate is locked in at request time. Emits `RedeemRequest(requestId, owner, recipient, sharesToBurn, feeSharesBurned)`.
- **Queueing**: Queued shares are escrowed in the vault (counted in `pendingRedeemShares()`) and keep earning vault yield until processed.
- **Processing**: `OPERATOR_ROLE` calls `processPendingRedeems(maxShares, maxRequests)` while unpaused. It drips first. Bounded by `availableLiquidAssets()` (the savings vault's `maxWithdraw` for the vault), which is re-checked before each request. For each fill, the escrowed shares are burned, their value is converted to savings shares (rounding down, so rounding stays with the vault), and those savings shares are redeemed from the savings vault straight to the `recipient`. Fully filled requests are unlinked and deleted; partial fills are supported and remain at the head of the queue.
- **Updating the recipient**: The `owner` can call `updateRedeemRecipient(requestId, recipient)` on a pending redeem request.

### 5. Handling Failing Redemptions & Claims

- Assets are paid out to recipients by the savings vault directly. If the redemption of savings shares to a recipient fails, the assets are instead redeemed to the vault and credited to `claimableAssetsOf[recipient]`, so a failing request cannot block the queue. Emits `ClaimableAssetsIncreased`.
- `claim(recipient)` is permissionless and always sends the assets to `recipient`; it reverts while transferring the assets to the recipient fails.
- If the fallback redemption to the vault also fails (e.g. the savings vault reverts for some reason or the vault itself cannot receive), the whole `process*` call reverts.

### 6. Liquidity

- **`take(savingsShares)`**: The `TAKER_ROLE` can transfer any **savings shares** (e.g., `spUSDC`) held by the vault, including those backing pending and suspended deposits and cancellations, to itself for external allocation. Reverts if the amount exceeds the vault's balance. Emits `Take`.

### 7. Suspending Requests

`OPERATOR_ROLE` can suspend individual pending requests, for instance one whose recipient is problematic, removing them from their pending queue without blocking the rest of the queue.

- **Suspend**: `suspendDepositRequest`, `suspendDepositCancellationRequest`, and `suspendRedeemRequest` take a `uint48 requestId` (`NoRequest` if not in the corresponding pending queue). The request is unlinked from its pending queue and appended to its corresponding suspended doubly-linked list, moving its unfilled shares from `pending*` to `suspended*` (`suspendedDepositSavingsShares()`, `suspendedDepositCancellationSavingsShares()`, `suspendedRedeemShares()`). The underlying savings shares or vault shares stay in the vault. Emits `*RequestSuspended`.
- **While suspended**: Because the request is no longer in the pending queue, processing does not encounter it, and it cannot be cancelled or have its recipient updated (`NoRequest`). It does not count in `pending*` share totals or `pending*RequestsLength()`.
- **Unsuspend**: `unsuspendDepositRequest`, `unsuspendDepositCancellationRequest`, and `unsuspendRedeemRequest` take the suspended `uint48 requestId` (`NoRequest` if not in the corresponding suspended list). The request is unlinked from the suspended list and appended to the end of its pending queue under the **same ID** (preserving its original `id`, `owner`, `recipient`, `timestamp`, and `shares`), moving its shares from `suspended*` back to `pending*`. Emits `*RequestUnsuspended`.
- **Inspecting**: `suspended{Deposit,DepositCancellation,Redeem}RequestsLength()`, `getSuspended{Deposit,DepositCancellation,Redeem}Request(requestId)` (reverts with `NoRequest` if not in that suspended list), `suspended*Requests()` (full list in suspension order), and `getSuspended*Requests(startIndex, length)` (0-based slice in suspension order; reverts with `StartIndexTooLarge` if `startIndex` exceeds the list length; `length` is clamped). Suspended lists preserve insertion (suspension) order.
- Suspending and unsuspending do not drip and are not blocked by pausing.

### 8. Queue Mechanics

- All requests are stored in a single `_requests` mapping keyed by a globally unique, monotonic non-zero `uint48` ID (starting at `1`; `0` is reserved as the null sentinel). Each `Request` struct contains `(id, owner, recipient, timestamp, shares)`.
- All six collections — three pending queues (`_pendingDeposits`, `_pendingDepositCancellations`, `_pendingRedeems`) and three suspended lists (`_suspendedDeposits`, `_suspendedDepositCancellations`, `_suspendedRedeems`) — are FIFO doubly-linked lists tracking `head`, `tail`, `length`, aggregate `shares`, and per-ID `(prev, next)` links.
- Fully filled or fully cancelled requests are immediately unlinked and deleted from `_requests`, and suspended requests are unlinked from their pending list, so pending queues contain **no tombstones** and `maxRequests` bounds the exact number of active requests processed per call.
- Aggregate pending shares are returned by `pendingDepositSavingsShares()`, `pendingDepositCancellationSavingsShares()`, and `pendingRedeemShares()`; suspended shares by `suspendedDepositSavingsShares()`, `suspendedDepositCancellationSavingsShares()`, and `suspendedRedeemShares()`. `totalClaimable` tracks the sum of `claimableAssetsOf`.
- Pending requests can be inspected with `pending{Deposit,DepositCancellation,Redeem}RequestsLength()`, `getPending{Deposit,DepositCancellation,Redeem}Request(requestId)` (returns a `Request` struct; reverts with `NoRequest` if `requestId` is not in that pending queue), `pending*Requests()` (full pending list in queue order), or `getPending*Requests(startIndex, length)` (0-based slice in queue order). The slice getter reverts with `StartIndexTooLarge` if `startIndex` is greater than the list length; `length` is clamped to the entries available, so overshooting or a `length` of zero returns a shorter or empty array rather than reverting.

### 9. Pausing

- `PAUSER_ROLE` can `pause`; `UNPAUSER_ROLE` can `unpause`.
- While paused, `requestDeposit`, `requestRedeem`, `processPendingDeposits`, and `processPendingRedeems` revert.
- Deposit cancellations stay available so depositors can always exit: `requestDepositCancellation` and `processPendingDepositCancellations` work while paused. Suspending and unsuspending requests, recipient updates, `claim`, `take`, `drip`, and ERC-20 transfers/approvals also remain available.
- `impair` can only be called while paused.

### 10. Savings Vault Assumptions

The vault is designed for Spark Vault V2 savings vaults (e.g., `spUSDC`) and relies on the following:

- **Deposits from the vault are accepted**: `requestDeposit` deposits into the savings vault with the vault as caller and receiver. It reverts if the vault holds the savings vault's `TAKER_ROLE` (Spark Vault V2 rejects deposits from takers) or if the deposit would exceed the savings vault's deposit cap.
- **No fees**: `convertToShares`/`convertToAssets` are used for pricing, so deposits and redemptions must not charge fees.
- **Share price never falls**: savings shares are worth at least as many assets over time.
- **`maxRedeem`/`maxWithdraw` are honoured**: amounts within these bounds can be redeemed in the same transaction (`maxWithdraw` sizes redeem fills, `maxRedeem` sizes cancellation fills).
- **Synchronous payout**: `redeem` delivers assets in the same call.
- **Zero amounts succeed**: `redeem` of zero (or of dust that converts to zero assets) does not revert, and the asset accepts zero-value transfers. Queue remainders can produce such calls.

---

## Configuration

| Parameter                | Setter (role)                                      | Notes                                                                                       |
| ------------------------ | -------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `maxCapacity`            | `setCapacity` (`OPERATOR_ROLE`)                    | Max `totalSupply` used to size deposit fills. At most `uint128` max.                        |
| `minDeposit`             | `setMinDeposit` (`DEFAULT_ADMIN_ROLE`)             | Minimum assets per `requestDeposit`. Nonzero.                                               |
| `minDepositCancellation` | `setMinDepositCancellation` (`DEFAULT_ADMIN_ROLE`) | Minimum savings shares per `requestDepositCancellation`. Nonzero.                           |
| `minRedeem`              | `setMinRedeem` (`DEFAULT_ADMIN_ROLE`)              | Minimum shares per `requestRedeem`. Nonzero.                                                |
| `minVSR`/`maxVSR`        | `setVSRBounds` (`DEFAULT_ADMIN_ROLE`)              | `RAY <= minVSR <= maxVSR <= MAX_VSR`. Does not change current `vsr`.                        |
| `vsr`                    | `setVSR` (`OPERATOR_ROLE`)                         | Must be within `[minVSR, maxVSR]`; drips before updating.                                   |
| `maxRedeemFeeRate`       | `setMaxRedeemFeeRate` (`DEFAULT_ADMIN_ROLE`)       | Wad; capped by the `MAX_REDEEM_FEE` constant (1%). Does not change current `redeemFeeRate`. |
| `redeemFeeRate`          | `setRedeemFeeRate` (`REDEEM_FEE_SETTER_ROLE`)      | Wad; must be `<= maxRedeemFeeRate`.                                                         |

---

## Roles & Permissions

| Role                         | Permitted Actions                                                                                                                                                                | Description                                                                                                                             |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| **`DEFAULT_ADMIN_ROLE`**     | `setMaxRedeemFeeRate`, `setMinDeposit`, `setMinDepositCancellation`, `setMinRedeem`, `setVSRBounds`, `upgradeToAndCall` (`_authorizeUpgrade`)                                    | Governs vault parameters, bounds, and contract upgrades.                                                                                |
| **`LOSS_MANAGER_ROLE`**      | `impair`                                                                                                                                                                         | Writes down `totalAssets` (and by extension `chi`) to realize a loss (only while paused). Cannot increase `chi`.                        |
| **`OPERATOR_ROLE`**          | `setCapacity`, `setVSR`                                                                                                                                                          | Sets the deposit capacity and the Vault Savings Rate within configured bounds (`[minVSR, maxVSR]`).                                     |
| **`OPERATOR_ROLE`**          | `processPendingDeposits`, `processPendingDepositCancellations`, `processPendingRedeems`                                                                                          | Settles the deposit, deposit-cancellation, and redeem queues (deposits and redeems only while unpaused).                                |
| **`OPERATOR_ROLE`**          | `suspendDepositRequest`, `suspendDepositCancellationRequest`, `suspendRedeemRequest`, `unsuspendDepositRequest`, `unsuspendDepositCancellationRequest`, `unsuspendRedeemRequest` | Moves individual pending requests to their suspended list, and re-queues suspended requests at the end of their queue under the same ID. |
| **`TAKER_ROLE`**             | `take`                                                                                                                                                                           | Withdraws any savings shares held by the vault, including those backing pending and suspended deposits and cancellations, for allocation. |
| **`REDEEM_FEE_SETTER_ROLE`** | `setRedeemFeeRate`                                                                                                                                                               | Configures the redemption fee rate (≤ `maxRedeemFeeRate`).                                                                              |
| **`PAUSER_ROLE`**            | `pause`                                                                                                                                                                          | Emergency pause of deposit/redeem requests and their processing (deposit cancellations and suspend/unsuspend stay available).           |
| **`UNPAUSER_ROLE`**          | `unpause`                                                                                                                                                                        | Unpause of requests and queue processing.                                                                                               |
| **Request owner**            | `requestDepositCancellation`, `updateDepositRecipient`, `updateDepositCancellationRecipient`, `updateRedeemRecipient`                                                            | Only the `owner` of a pending request can cancel it or change its recipient.                                                            |
| **Public / Permissionless**  | `requestDeposit`, `requestRedeem`, `claim`, `drip`, ERC-20 (`approve`, `transfer`, `transferFrom`), `permit`, view functions                                                     | Standard user interactions, rate accrual, and claiming assets owed to recipients whose requests failed at process-time.                 |

`AccessControlEnumerable` is used, so role members can be enumerated on-chain.

---
