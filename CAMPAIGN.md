# spPRIME testing campaign: worker briefing

You are one of several parallel workers stress-testing `src/SparkPrimeVault.sol` (branch
`lucas/refactor-vault`). Each worker owns ONE test file in its own git worktree. Do not edit
`src/`, `test/LocalTestBase.t.sol`, `test/lib/`, `foundry.toml`, or any other worker's file.
Never run commands outside your worktree. Never push. Never call any `mcp__hearthbot__` tool.

## What the contract does (as implemented, verified)

- Shares priced by an index: `assets = shares * chi / RAY`; `chi` compounds at `vsr` per second via
  `drip()`. `totalAssets()` is notional (`totalSupply * chi / RAY`), nothing ties it to real backing.
- Every deposit goes straight into spUSDC (`requestDeposit` -> spUSDC.deposit). The vault's only
  on-chain backing is its spUSDC balance; "active capital" is what the TAKER_ROLE has `take()`n
  (denominated in spUSDC shares). Capital comes back as spUSDC by plain ERC20 transfer. USDC never
  sits in the contract by design.
- Deposit queue entries are in spUSDC shares. `requestDeposit` fills instantly only when
  `pendingDepositSavingsShares == 0` (nobody queued ahead) and capacity allows; the remainder waits.
  A fill converts spUSDC shares -> USDC (spUSDC.convertToAssets) -> spPRIME shares
  (convertToShares) and mints to the recipient. The spUSDC stays in the vault.
- Redeem queue entries are in spPRIME shares, escrowed in the vault; the redeem fee is burned up
  front at request time (`_divup(shares * redeemFee, WAD)`) and never refunded. There is NO instant
  redeem path (intentional). `processRedeemQueue` (REBALANCER only) burns shares and calls
  spUSDC.withdraw(assets) straight to the recipient, bounded by `spUSDC.maxWithdraw(vault)`.
- Capacity (`maxCapacity`) caps `totalSupply` in shares (escrowed redeem shares count) and may be set
  below `totalSupply`. `availableCapacity()` floors at 0.
- `pause()` (GUARDIAN) blocks requests, cancels and queue processing; `take()` and `drip()` are not
  gated. `setChi` (RISK_MANAGER, only while paused) lowers the index to realise a loss. Loss
  realisation is OUT OF SCOPE for this campaign (do not test setChi).
- Decisions from the product owner: deposit-queue spUSDC is intentionally NOT ring-fenced from
  `take()`; ERC-7540 compliance is dropped; fee is charged up front; chi accrues during pause.

## Known findings (do not re-discover; isolate them so they don't mask other issues)

- F-1 High: `cancelDepositRequest`/`cancelRedeemRequest` pay to a caller-chosen `recipient_`, so a
  GUARDIAN can redirect anyone's refund. Will be fixed to refund `request.owner`.
- F-2 Medium: `cancelDepositRequest` reverts once `take()`/`processRedeemQueue` spent the queue's
  spUSDC (by design the spUSDC is takeable; a planner-handled cancel queue is coming).
- F-3 Medium: `_processDepositQueue` line 658 checks `requestSavingsShares_` instead of
  `request.shares`, so it fills at most ONE request per call and `maxRequests_` is inert.
- F-4 Low: dust fills can mint 0 shares while deducting spUSDC from the head request.
- F-5 Low: zero-amount deposit requests and 1-wei redeem requests create 0-share ghost entries.
- F-7/F-8 Low: cancels blocked while paused; fee kept on guardian cancel.

## Harness: `test/LocalTestBase.t.sol`

Inherit `LocalTestBase`. It deploys a 6-decimal `MockUSDC`, the REAL spUSDC `SparkVault` code
(`test/lib/spusdc/SparkVault.sol`, index-priced ERC-4626 with a TAKER that can drain its USDC) and
the `SparkPrimeVault` proxy with every role granted, capacity `type(uint128).max`, maxRedeemFee 1%,
VSR bounds `[RAY, MAX_VSR]` on both vaults, fee 0, minimums 0, both VSRs at RAY (0%).

Actors: `spAdmin, spSetter, spTaker` (spUSDC) and `admin, guardian, rebalancer, riskManager,
setter, taker, unpauser` (spPRIME). Constants: `RAY, WAD, ONE_PCT_VSR, FOUR_PCT_VSR, FIVE_PCT_VSR,
TEN_PCT_VSR, FORTY_PCT_VSR, MAX_VSR`.

Helpers: `_fund(who, amt)`, `_deposit(who, amt) -> id`, `_requestRedeem(who, shares) -> id`,
`_setCapacity`, `_setRedeemFee`, `_setMinimums`, `_setPrimeVsr`, `_setSpUsdcVsr`,
`_processDeposits(maxSavingsShares, maxRequests)`, `_processRedeems(maxShares, maxRequests)`,
`_pause`, `_unpause`, `_drainSpUsdcLiquidity(amt)`, `_drainAllSpUsdcLiquidity()`,
`_returnSpUsdcLiquidity(amt)`, `_take(savingsShares)`, `_takeAll()`, `_returnToVault(savingsShares)`,
`_warp(secs)`, `_warpAndDrip(secs)`, `_depositRequest(id)`, `_redeemRequest(id)`, `_vaultSpUsdc()`.

Gotcha: `vm.prank` is consumed by the next external call, including view calls like
`spUsdc.balanceOf(...)` used as an argument. Cache values in locals first.

Style reference: `~/work/spark-vaults-v2/test/` (Spark Vaults V2). Mirror its naming
(`test_<fn>_<case>`, `testFuzz_`, `invariant_<letter>_<claim>`), its handler/invariant layout
(`test/invariants/` with `HandlerBase`, `UserHandler`, `AdminHandler`), and its habit of asserting
exact balances before and after each step.

Run only your file: `forge test --match-path test/<YourFile>.t.sol -vv`. Fuzz runs default to
1000; pass `FOUNDRY_FUZZ_RUNS=20000` for a longer run when a property matters. Build is ~1 min
cold; `forge test` thereafter is fast. Everything is local; no RPC.

## Deliverable

1. Your test file(s), committed on your branch (`git add` + `git commit`; set
   `-c user.name=campaign -c user.email=campaign@local`). Every test must either PASS, or be a
   deliberate failing proof of a bug named `test_BUG_<slug>` (failing is fine for those, say so).
2. A final report (your last message) with: (a) each bug or suspicious behaviour you found, with
   file:line in `src/SparkPrimeVault.sol`, a concrete scenario, impact, the proving test name, and
   a severity (critical/high/medium/low/info); (b) hypotheses you tested that held, as a list of
   invariants / properties with the test that checks each one; (c) anything you could not settle.
   Be concrete and quantitative (exact wei amounts, exact revert reasons). No speculation without a
   test behind it.
