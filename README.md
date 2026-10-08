# Spark Prime Vault (`spPRIME`)

An upgradeable, yield-accruing vault token backed by an underlying asset (e.g., USDC) and an ERC-4626 savings yield sleeve (e.g., `spUSDC`), featuring asynchronous FIFO deposit and withdrawal queues for capacity- and liquidity-constrained environments.

---

## Core Mechanisms

### 1. Rate Accumulator (`chi` & `vsr`)

- Yield accrues continuously via the Vault Savings Rate (`vsr`), a per-second compounding factor.
- `drip()` compounds accumulated interest into the accumulator `chi`.
- Share-to-asset conversion: `assets = shares * chi / RAY`.

### 2. Deposits & Deposit Queue

- **Instant Fill**: If no deposit queue exists and capacity is available (`totalSupply < maxCapacity`), `spPRIME` shares are minted immediately to `receiver`.
- **Queueing**: If capacity is filled or a queue exists, excess assets are deposited into `spUSDC` and pushed to the FIFO `depositQueue`. Queued depositors earn `spUSDC` yield while waiting.
- **Processing**: The `REBALANCER_ROLE` calls `processDepositQueue(maxAssets)` to mint `spPRIME` to queued depositors as vault capacity becomes available.
- **Cancellation**: A queued deposit can be cancelled at any time by the `owner`, `receiver`, or `GUARDIAN_ROLE` via `cancelDepositRequest(requestId)`, returning the underlying assets plus all accrued `spUSDC` yield to the `owner`.

### 3. Redemptions & Withdraw Queue

- **Instant Fill**: If no withdrawal queue exists and sufficient liquid assets are available (`availableLiquidAssets()`), `spPRIME` shares are burned and net assets are paid out immediately to `receiver`.
- **Queueing**: If liquidity is insufficient, requested `spPRIME` shares are escrowed into the FIFO `withdrawQueue`. Escrowed shares continue earning vault yield until processed.
- **Processing**: Anyone can call `processWithdrawQueue(maxAssets)` to fulfill queued withdrawals FIFO as liquidity becomes available.
- **Withdrawal Fee**: Each redemption request locks in the `withdrawFee` active at request time (capped at `maxWithdrawFee` ≤ 1%). The fee is deducted upon settlement and retained by the vault.

### 4. Liquidity & Savings Sleeve

- **`take(assets)`**: The `TAKER_ROLE` can extract idle base assets from the vault for external allocation.
- **Savings Sleeve**: The `REBALANCER_ROLE` manages the `spUSDC` position (`depositToSavings` / `withdrawFromSavings`). Queued deposit shares in `spUSDC` are strictly locked and protected from extraction or unauthorized withdrawals.

---

## Roles & Permissions

| Role                        | Permitted Actions                                                                                                          | Description                                                                                          |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| **`DEFAULT_ADMIN_ROLE`**    | `setCapacity`, `setMaxWithdrawFee`, `setMinimums`, `setVsrBounds`, `_authorizeUpgrade`                                     | Governs vault parameters, caps, bounds, and contract upgrades.                                       |
| **`SETTER_ROLE`**           | `setVsr`                                                                                                                   | Updates the compounding Vault Savings Rate within configured bounds (`[minVsr, maxVsr]`).            |
| **`REBALANCER_ROLE`**       | `depositToSavings`, `withdrawFromSavings`, `processDepositQueue`                                                           | Manages the `spUSDC` savings sleeve and settles queued deposits against available capacity.          |
| **`TAKER_ROLE`**            | `take`                                                                                                                     | Withdraws available idle base assets for portfolio allocation.                                       |
| **`RISK_MANAGER_ROLE`**     | `setWithdrawFee`, `setChi`                                                                                                 | Configures redemption fees (≤ `maxWithdrawFee`) and adjusts `chi` during emergencies (while paused). |
| **`GUARDIAN_ROLE`**         | `pause`, `cancelDepositRequest`                                                                                            | Emergency pause for deposits/withdrawals and compliance cancellation of queued deposits.             |
| **`UNPAUSER_ROLE`**         | `unpause`                                                                                                                  | Resumes vault operations.                                                                            |
| **Public / Permissionless** | `requestDeposit`, `requestRedeem`, `cancelDepositRequest` _(owner/receiver)_, `processWithdrawQueue`, `drip`, ERC20/Permit | Standard user interactions and queue settlement.                                                     |
