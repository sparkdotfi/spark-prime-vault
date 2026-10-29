# Spark Prime Vault (`spPrime`)

An upgradeable (UUPS), yield-accruing vault token denominated in an underlying asset (e.g., USDC) that holds its liquidity in an ERC-4626 savings sleeve (e.g., `spUSDC`), featuring asynchronous FIFO queues for deposits, deposit cancellations, and redemptions in capacity- and liquidity-constrained environments.

`totalAssets()` (`totalSupply * chi`) is the value owed to share holders at the administered rate, not the assets held by the vault. The vault's savings share balance also backs pending deposits and cancellations, and `TAKER_ROLE` can move it out for external allocation, so it does not track `totalAssets()`.

The vault token is a standard ERC-20 (with EIP-2612-style `permit`, supporting both EOA and ERC-1271 signatures) whose `decimals` match the underlying asset. Transfers to the zero address or to the vault itself are rejected.

---

## Core Mechanisms

### 1. Rate Accumulator (`chi` & `vsr`)

- Yield accrues continuously via the Vault Savings Rate (`vsr`), a per-second compounding factor (ray).
- `drip()` (public) compounds accumulated interest into the accumulator `chi`. It is also invoked by `setVSR`, `adjustTotalAssets`, `requestDeposit`, `requestDepositCancellation`, `requestRedeem`, and all `process*` functions.
- Share-to-asset conversion: `assets = shares * nowChi() / RAY`, where `nowChi()` is the up-to-date `chi` without writing state.
- Initialized with `chi = vsr = minVSR = maxVSR = RAY` (0% yield) until the admin sets bounds and `OPERATOR_ROLE` sets a rate.
- `vsr` must stay within `[minVSR, maxVSR]`. Bounds are configured by `DEFAULT_ADMIN_ROLE` with `minVSR >= RAY` and `maxVSR <= MAX_VSR` (100% APY).
- **Gain/Loss Realization**: While paused, `LOSS_MANAGER_ROLE` can call `adjustTotalAssets(delta)` to settle the pending drip and rewrite `chi` so that `totalAssets` moves by `delta` (positive or negative). Pausing first blocks request/processing activity so nobody can front-run the adjustment. `delta` must be nonzero, the resulting total assets must be positive, and the resulting `chi` must be non-zero and fit in `uint192`. Requires a non-zero `totalSupply`.

### 2. Deposits & Deposit Queue

Deposits are two-step: the user's assets go to the savings sleeve immediately, and vault shares are minted once there is capacity.

- **Request**: `requestDeposit(assets, recipient, referral)` pulls `assets` from the caller, deposits them into the savings vault (`spUSDC`) and queues a request denominated in **savings shares**. Requires `assets >= minDeposit` and that `recipient` is neither the zero address nor the vault. Emits `Referral` (with the integrator's `referral` code) and `DepositRequest`.
- **Instant Fill**: If the new request is the only pending deposit (nothing queued ahead of it) and capacity is available, it is processed within the same transaction.
- **Queueing**: Otherwise the request waits in the FIFO `_depositRequests` queue. Queued depositors keep earning savings yield while waiting, since the vault holds their savings shares.
- **Capacity**: Fills are bounded by `availableCapacity() = maxCapacity - totalSupply` (floored at 0), converted to savings shares.
- **Processing**: `OPERATOR_ROLE` calls `processPendingDeposits(maxSavingsShares, maxRequests)`. Savings shares are converted to assets and then minted as `spPrime` to each request's `recipient` at the current `chi`. Requests can be **partially filled**; a partially filled request stays at the head of the queue.
- **Updating the recipient**: The request `owner` can call `updateDepositRecipient(requestId, recipient)` to change who receives the minted shares.

### 3. Deposit Cancellation & Cancellation Queue

- **Request**: The request `owner` (only) calls `requestDepositCancellation(requestId, recipient, savingsShares)` on a still-pending deposit. `savingsShares` must be at least `minDepositCancellation` and at most the request's unfilled savings shares; they move to the FIFO `_depositCancellationRequests` queue.
- **Partial cancellation**: If all unfilled savings shares are cancelled, the deposit request is removed. Otherwise it keeps the rest and its position in the deposit queue.
- **Cleanup**: Each cancellation also clears fully cancelled entries at the front of the deposit queue, so they do not block the next instant fill.
- **Processing**: `OPERATOR_ROLE` calls `processPendingDepositCancellations(maxSavingsShares, maxRequests)`, which redeems the savings shares for the underlying asset and sends it to the `recipient`. Bounded by what the savings vault can redeem (`maxRedeem`). Because the refund is made from the queued savings shares, it includes all savings yield accrued while queued. Partial fills are supported.
- **Updating the recipient**: The `owner` can call `updateDepositCancellationRecipient(requestId, recipient)`.

### 4. Redemptions & Redeem Queue

Redemptions are always asynchronous (there is no instant fill).

- **Request**: `requestRedeem(shares, recipient)` transfers `shares` from the caller into the vault, requires `shares >= minRedeem`.
- **Redeem Fee**: The fee is taken **upfront in shares**: `fee = ceil(shares * redeemFeeRate / WAD)` is burned immediately, and only `shares - fee` is queued. The rate is locked in at request time. Emits `RedeemRequest(requestId, owner, recipient, sharesToBurn, feeSharesBurned)`.
- **Queueing**: Queued shares are escrowed in the vault (counted in `pendingRedeemShares`) and keep earning vault yield until processed.
- **Processing**: `OPERATOR_ROLE` calls `processPendingRedeems(maxShares, maxRequests)`. Bounded by `availableLiquidAssets()` (the savings vault's `maxWithdraw` for the vault). For each fill, the escrowed shares are burned and the corresponding assets are withdrawn from the savings vault straight to the `recipient`. Partial fills are supported.
- **Updating the recipient**: The `owner` can call `updateRedeemRecipient(requestId, recipient)`.

### 5. Handling Failing Redemptions/Withdrawals & Claims

- Assets are paid out to recipients by the savings vault directly. If the redemption or withdrawal of savings shares to a recipient fails, the assets are instead redeemed/withdrawn to the vault and credited to `claimableAssets[recipient]`, so a failing request cannot block the queue. Emits `ClaimableAssetsIncreased`.
- `claim(recipient)` is permissionless and always sends the assets to `recipient`; it reverts while transferring the assets to the recipient fails.
- If the fallback redemption/withdrawal to the vault also fails (e.g. the savings vault is reverted for some reason or the vault itself cannot receive), the whole `process*` call reverts.

### 6. Liquidity

- **`take(savingsShares)`**: The `TAKER_ROLE` can transfer any **savings shares** (e.g., `spUSDC`) held by the vault, including those backing pending deposits and cancellations, to itself for external allocation. Reverts if the amount exceeds the vault's balance. Emits `Take`.

### 7. Queue Mechanics

- All three queues (deposit, deposit cancellation, redeem) are FIFO and are processed with `maxRequests` bounding the number of entries visited per call, so processing can be batched.
- Each queue tracks its head (`firstPendingDepositId`, `firstPendingDepositCancellationId`, `firstPendingRedeemId`); fully filled or cancelled entries are deleted and skipped.
- Aggregate pending amounts are tracked in `pendingDepositSavingsShares`, `pendingCancelledDepositSavingsShares`, and `pendingRedeemShares`.
- Pending requests can be inspected with `getPending{Deposit,DepositCancellation,Redeem}Request(requestId)` and `getPending...Requests()` (full pending list) or `getPending...Requests(startId, length)` (`length` entries from `startId`; an empty array if `length` is zero; reverts if `startId` is before the queue head or the range extends past the end of the queue).

### 8. Pausing

- `PAUSER_ROLE` can `pause`; `UNPAUSER_ROLE` can `unpause`.
- While paused, `requestDeposit`, `requestRedeem`, `processPendingDeposits`, and `processPendingRedeems` revert.
- Deposit cancellations stay available so depositors can always exit: `requestDepositCancellation` and `processPendingDepositCancellations` work while paused. Recipient updates, `claim`, `take`, `drip`, and ERC-20 transfers/approvals also remain available.
- `adjustTotalAssets` can only be called while paused.

### 9. Savings Vault Assumptions

The vault is designed for Spark Vault V2 savings vaults (e.g., `spUSDC`) and relies on the following:

- **Deposits from the vault are accepted**: `requestDeposit` deposits into the savings vault with the vault as caller and receiver. It reverts if the vault holds the savings vault's `TAKER_ROLE` (Spark Vault V2 rejects deposits from takers) or if the deposit would exceed the savings vault's deposit cap.
- **No fees**: `convertToShares`/`convertToAssets` are used for pricing, so deposits, redemptions, and withdrawals must not charge fees.
- **Share price never falls**: savings shares are worth at least as many assets over time.
- **`maxRedeem`/`maxWithdraw` are honoured**: amounts within these bounds can be redeemed or withdrawn in the same transaction.
- **Synchronous payout**: `redeem` and `withdraw` deliver assets in the same call.
- **Zero amounts succeed**: `withdraw`/`redeem` of zero (or of dust that converts to zero assets) do not revert, and the asset accepts zero-value transfers. Queue remainders can produce such calls.

---

## Configuration

| Parameter                | Setter (role)                                      | Notes                                                                  |
| ------------------------ | -------------------------------------------------- | ---------------------------------------------------------------------- |
| `maxCapacity`            | `setCapacity` (`OPERATOR_ROLE`)                    | Maximum `totalSupply` used to size deposit fills.                      |
| `minDeposit`             | `setMinDeposit` (`DEFAULT_ADMIN_ROLE`)             | Minimum assets per `requestDeposit`. Nonzero.                          |
| `minDepositCancellation` | `setMinDepositCancellation` (`DEFAULT_ADMIN_ROLE`) | Minimum savings shares per `requestDepositCancellation`. Nonzero.      |
| `minRedeem`              | `setMinRedeem` (`DEFAULT_ADMIN_ROLE`)              | Minimum shares per `requestRedeem`   |
| `minVSR`/`maxVSR`        | `setVSRBounds` (`DEFAULT_ADMIN_ROLE`)              | `RAY <= minVSR <= maxVSR <= MAX_VSR`.                                  |
| `vsr`                    | `setVSR` (`OPERATOR_ROLE`)                         | Must be within `[minVSR, maxVSR]`; drips before updating.              |
| `maxRedeemFeeRate`       | `setMaxRedeemFeeRate` (`DEFAULT_ADMIN_ROLE`)       | Wad; capped by the `MAX_REDEEM_FEE` constant (1%).                     |
| `redeemFeeRate`          | `setRedeemFeeRate` (`REDEEM_FEE_SETTER_ROLE`)      | Wad; must be `<= maxRedeemFeeRate`.                                    |

---

## Roles & Permissions

| Role                         | Permitted Actions                                                                                                            | Description                                                                                                                           |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **`DEFAULT_ADMIN_ROLE`**     | `setMaxRedeemFeeRate`, `setMinDeposit`, `setMinDepositCancellation`, `setMinRedeem`, `setVSRBounds`, `_authorizeUpgrade`     | Governs vault parameters, bounds, and contract upgrades.                                                                              |
| **`LOSS_MANAGER_ROLE`**      | `adjustTotalAssets`                                                                                                          | Manually changes `totalAssets` (and by extension `chi`) to realize gains or losses (only while paused).                               |
| **`OPERATOR_ROLE`**          | `setCapacity`, `setVSR`                                                                                                      | Sets the deposit capacity and the Vault Savings Rate within configured bounds (`[minVSR, maxVSR]`).                                   |
| **`OPERATOR_ROLE`**          | `processPendingDeposits`, `processPendingDepositCancellations`, `processPendingRedeems`                                      | Settles the deposit, deposit-cancellation, and redeem queues (deposits and redeems only while unpaused).                              |
| **`TAKER_ROLE`**             | `take`                                                                                                                       | Withdraws any savings shares held by the vault, including those backing pending deposits and cancellations, for portfolio allocation. |
| **`REDEEM_FEE_SETTER_ROLE`** | `setRedeemFeeRate`                                                                                                           | Configures the redemption fee rate (≤ `maxRedeemFeeRate`).                                                                            |
| **`PAUSER_ROLE`**            | `pause`                                                                                                                      | Emergency pause of requests and queue processing.                                                                                     |
| **`UNPAUSER_ROLE`**          | `unpause`                                                                                                                    | Unpause of requests and queue processing.                                                                                             |
| **Request owner**            | `requestDepositCancellation`, `updateDepositRecipient`, `updateDepositCancellationRecipient`, `updateRedeemRecipient`        | Only the `owner` of a request can cancel it or change its recipient.                                                                  |
| **Public / Permissionless**  | `requestDeposit`, `requestRedeem`, `claim`, `drip`, ERC-20 (`approve`, `transfer`, `transferFrom`), `permit`, view functions | Standard user interactions, rate accrual, and claiming assets owed to recipients whose requests failed at process-time.               |

`AccessControlEnumerable` is used, so role members can be enumerated on-chain.
