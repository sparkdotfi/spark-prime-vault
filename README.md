# Spark Prime Vault (`spPrime`)

An upgradeable (UUPS), yield-accruing vault token backed by an underlying asset (e.g., USDC) and an ERC-4626 savings sleeve (e.g., `spUSDC`), featuring asynchronous FIFO queues for deposits, deposit cancellations, and redemptions in capacity- and liquidity-constrained environments.

The vault token is a standard ERC-20 (with EIP-2612-style `permit`, supporting both EOA and ERC-1271 signatures) whose `decimals` match the underlying asset. Transfers to the zero address or to the vault itself are rejected.

---

## Core Mechanisms

### 1. Rate Accumulator (`chi` & `vsr`)

- Yield accrues continuously via the Vault Savings Rate (`vsr`), a per-second compounding factor (ray).
- `drip()` (public) compounds accumulated interest into the accumulator `chi`. It is also invoked by `setVSR`, `adjustTotalAssets`, `requestDeposit`, `requestRedeem`, and all `process*` functions.
- Share-to-asset conversion: `assets = shares * nowChi() / RAY`, where `nowChi()` is the up-to-date `chi` without writing state.
- Initialized with `chi = vsr = minVSR = maxVSR = RAY` (0% yield) until the admin sets bounds and the VSR setter sets a rate.
- `vsr` must stay within `[minVSR, maxVSR]`. Bounds are configured by `DEFAULT_ADMIN_ROLE` with `minVSR >= RAY` and `maxVSR <= MAX_VSR` (100% APY).
- **Gain/Loss Realization**: While paused, `DEFAULT_ADMIN_ROLE` can call `adjustTotalAssets(delta)` to settle the pending drip and rewrite `chi` so that `totalAssets` moves by `delta` (positive or negative). Pausing first blocks request/processing activity so nobody can front-run the adjustment. `delta` must be nonzero, the resulting total assets must be positive, and the resulting `chi` must be non-zero and fit in `uint192`. Requires a non-zero `totalSupply`.

### 2. Deposits & Deposit Queue

Deposits are two-step: the user's assets go to the savings sleeve immediately, and vault shares are minted once there is capacity.

- **Request**: `requestDeposit(assets, recipient, referral)` pulls `assets` from the caller, deposits them into the savings vault (`spUSDC`) and queues a request denominated in **savings shares**. Requires `assets >= minDeposit` and that `recipient` is neither the zero address nor the vault. Emits `Referral` (with the integrator's `referral` code) and `DepositRequest`.
- **Instant Fill**: If the new request is the only pending deposit (nothing queued ahead of it) and capacity is available, it is processed within the same transaction.
- **Queueing**: Otherwise the request waits in the FIFO `_depositRequests` queue. Queued depositors keep earning savings yield while waiting, since the vault holds their savings shares.
- **Capacity**: Fills are bounded by `availableCapacity() = maxCapacity - totalSupply` (floored at 0), converted to savings shares.
- **Processing**: `PROCESSOR_ROLE` calls `processPendingDeposits(maxSavingsShares, maxRequests)`. Savings shares are converted to assets and then minted as `spPrime` to each request's `recipient` at the current `chi`. Requests can be **partially filled**; a partially filled request stays at the head of the queue.
- **Updating the recipient**: The request `owner` can call `updateDepositRecipient(requestId, recipient)` to change who receives the minted shares.

### 3. Deposit Cancellation & Cancellation Queue

- **Request**: The request `owner` (only) calls `requestDepositCancellation(requestId, recipient)` on a still-pending deposit. The deposit request is removed from the deposit queue and its remaining savings shares move to the FIFO `_depositCancellationRequests` queue. `recipient` must be able to receive the asset (not blacklisted).
- **Processing**: `PROCESSOR_ROLE` calls `processPendingDepositCancellations(maxSavingsShares, maxRequests)`, which redeems the savings shares for the underlying asset and sends it to the `recipient`. Bounded by what the savings vault can redeem (`maxRedeem`). Because the refund is made from the queued savings shares, it includes all savings yield accrued while queued. Partial fills are supported.
- **Updating the recipient**: The `owner` can call `updateDepositCancellationRecipient(requestId, recipient)`.

### 4. Redemptions & Redeem Queue

Redemptions are always asynchronous (there is no instant fill).

- **Request**: `requestRedeem(shares, recipient)` transfers `shares` from the caller into the vault, requires `shares >= minRedeem`, and requires that `recipient` can receive the asset (not blacklisted).
- **Redeem Fee**: The fee is taken **upfront in shares**: `fee = ceil(shares * redeemFeeRate / WAD)` is burned immediately, and only `shares - fee` is queued. The rate is locked in at request time. Emits `RedeemRequest(requestId, owner, recipient, sharesToBurn, feeSharesBurned)`.
- **Queueing**: Queued shares are escrowed in the vault (counted in `pendingRedeemShares`) and keep earning vault yield until processed.
- **Processing**: `PROCESSOR_ROLE` calls `processPendingRedeems(maxShares, maxRequests)`. Bounded by `availableLiquidAssets()` (the savings vault's `maxWithdraw` for the vault). For each fill, the escrowed shares are burned and the corresponding assets are withdrawn from the savings vault straight to the `recipient`. Partial fills are supported.
- **Updating the recipient**: The `owner` can call `updateRedeemRecipient(requestId, recipient)`.

### 5. Blacklist Handling & Claims

- Assets are paid out to recipients by the savings vault directly. If the recipient is blacklisted by the asset at processing time (`isBlacklisted`, as with USDC/EURC), the assets are instead withdrawn to the vault and credited to `claimableAssets[recipient]`, so a blacklisted recipient cannot block the queue. Emits `ClaimableAssetsIncreased`.
- `claim(recipient)` is permissionless and always sends the assets to `recipient`; it reverts while the recipient is still blacklisted by the asset.
- The blacklist check is `_canReceiveAsset`, which assumes the asset exposes `isBlacklisted(address)` and is `virtual` so it can be overridden for other assets.

### 6. Liquidity

- **`take(savingsShares)`**: The `TAKER_ROLE` can transfer any **savings shares** (e.g., `spUSDC`) held by the vault, including those backing pending deposits and cancellations, to itself for external allocation. Reverts if the amount exceeds the vault's balance. Emits `Take`.

### 7. Queue Mechanics

- All three queues (deposit, deposit cancellation, redeem) are FIFO and are processed with `maxRequests` bounding the number of entries visited per call, so processing can be batched.
- Each queue tracks its head (`firstPendingDepositId`, `firstPendingDepositCancellationId`, `firstPendingRedeemId`); fully filled or cancelled entries are deleted and skipped.
- Aggregate pending amounts are tracked in `pendingDepositSavingsShares`, `pendingCancelledDepositSavingsShares`, and `pendingRedeemShares`.
- Pending requests can be inspected with `getPending{Deposit,DepositCancellation,Redeem}Request(requestId)` and `getPending...Requests()` (full pending list or a `[startId, endId)` range).

### 8. Pausing

- `GUARDIAN_ROLE` can `pause`; `DEFAULT_ADMIN_ROLE` can `unpause`.
- While paused, `requestDeposit`, `requestDepositCancellation`, `requestRedeem`, and all `process*` functions revert. Recipient updates, `claim`, `take`, `drip`, and ERC-20 transfers/approvals remain available.

---

## Configuration

| Parameter          | Setter (role)                                 | Notes                                                     |
| ------------------ | --------------------------------------------- | --------------------------------------------------------- |
| `maxCapacity`      | `setCapacity` (`DEFAULT_ADMIN_ROLE`)          | Maximum `totalSupply` used to size deposit fills.         |
| `minDeposit`       | `setMinDeposit` (`DEFAULT_ADMIN_ROLE`)        | Minimum assets per `requestDeposit`.                      |
| `minRedeem`        | `setMinRedeem` (`DEFAULT_ADMIN_ROLE`)         | Minimum shares per `requestRedeem`.                       |
| `minVSR`/`maxVSR`  | `setVSRBounds` (`DEFAULT_ADMIN_ROLE`)         | `RAY <= minVSR <= maxVSR <= MAX_VSR`.                     |
| `vsr`              | `setVSR` (`VSR_SETTER_ROLE`)                  | Must be within `[minVSR, maxVSR]`; drips before updating. |
| `maxRedeemFeeRate` | `setMaxRedeemFeeRate` (`DEFAULT_ADMIN_ROLE`)  | Wad; capped by the `MAX_REDEEM_FEE` constant (1%).        |
| `redeemFeeRate`    | `setRedeemFeeRate` (`REDEEM_FEE_SETTER_ROLE`) | Wad; must be `<= maxRedeemFeeRate`.                       |

---

## Roles & Permissions

| Role                         | Permitted Actions                                                                                                                          | Description                                                                                                                           |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| **`DEFAULT_ADMIN_ROLE`**     | `setCapacity`, `setMaxRedeemFeeRate`, `setMinDeposit`, `setMinRedeem`, `setVSRBounds`, `unpause`, `adjustTotalAssets`, `_authorizeUpgrade` | Governs vault parameters, caps, bounds, and contract upgrades. Realizes gains/losses by writing `chi` while paused.                   |
| **`VSR_SETTER_ROLE`**        | `setVSR`                                                                                                                                   | Updates the compounding Vault Savings Rate within configured bounds (`[minVSR, maxVSR]`).                                             |
| **`PROCESSOR_ROLE`**         | `processPendingDeposits`, `processPendingDepositCancellations`, `processPendingRedeems`                                                    | Settles the deposit, deposit-cancellation, and redeem queues (only while unpaused).                                                   |
| **`TAKER_ROLE`**             | `take`                                                                                                                                     | Withdraws any savings shares held by the vault, including those backing pending deposits and cancellations, for portfolio allocation. |
| **`REDEEM_FEE_SETTER_ROLE`** | `setRedeemFeeRate`                                                                                                                         | Configures the redemption fee rate (≤ `maxRedeemFeeRate`).                                                                            |
| **`GUARDIAN_ROLE`**          | `pause`                                                                                                                                    | Emergency pause of requests and queue processing.                                                                                     |
| **Request owner**            | `requestDepositCancellation`, `updateDepositRecipient`, `updateDepositCancellationRecipient`, `updateRedeemRecipient`                      | Only the `owner` of a request can cancel it or change its recipient.                                                                  |
| **Public / Permissionless**  | `requestDeposit`, `requestRedeem`, `claim`, `drip`, ERC-20 (`approve`, `transfer`, `transferFrom`), `permit`, view functions               | Standard user interactions, rate accrual, and claiming assets owed to blacklisted-at-payout recipients.                               |

`AccessControlEnumerable` is used, so role members can be enumerated on-chain.
