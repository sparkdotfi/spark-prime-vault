# spPRIME testing campaign: worker briefing (round 5, `master` @ `0ebb452`)

You are one of several parallel workers stress-testing `src/SparkPrimeVault.sol` as it stands on
`master` @ `0ebb452` ("refactor: More Cleanup (#26)"). The contract goes to an external audit
tomorrow: the goal tonight is (1) port the existing `test/ai/` suite so it compiles and passes
against this code, (2) pin every previously reported finding as fixed or still open, and (3) go
hard at breaking the code in your area with new hypotheses. Each worker owns specific files in its
own git worktree. Do not edit `src/`, `test/ai/LocalTestBase.t.sol`, `test/ai/lib/`,
`foundry.toml`, or any other worker's files. Never run commands outside your worktree. Never push.

Always set `FOUNDRY_OFFLINE=true` (or pass `--offline`) so forge does not try to re-clone
submodules. Files you do not own have been moved out of your worktree so the build is fast and
only your files matter; `git status` will show them as deleted. **Commit only your own files**
(`git add test/ai/<YourFile>`), never `git add -A` or `git commit -a`.

## The contract as implemented on `master` (verified by reading the code)

- Shares priced by an index: `assets = shares * chi / RAY`; `chi` compounds at `vsr` per second via
  `drip()` (public, never pause-gated). `totalAssets()` is notional (`totalSupply * chi / RAY`).
- Every deposit goes straight into spUSDC (`requestDeposit(assets, recipient, referral)` ->
  spUSDC.deposit). Vault backing = its spUSDC balance; `TAKER_ROLE.take(savingsShares)` moves
  spUSDC out to the taker (deposit-queue spUSDC is intentionally NOT ring-fenced).
- Deposit queue entries are in spUSDC shares. A request fills instantly only when
  `pendingDepositSavingsShares == savingsShares_` after the push, i.e. nothing non-zero is queued
  ahead; it then runs `_processPendingDeposits(max, max)` which walks from `firstPendingDepositId`
  (skipping zero entries) and fills up to `availableCapacity()` (in shares, converted through both
  indexes). Partial fills leave the entry at the head. No head-advance loop exists any more in
  `requestDeposit` or `requestDepositCancellation`.
- `requestDepositCancellation(id, recipient)` is OWNER ONLY now (guardian path removed). It moves
  the remaining spUSDC shares of the entry into a separate cancellation queue, paid by
  `processPendingDepositCancellations` (REBALANCER) bounded by `spUSDC.maxRedeem(vault)`.
- Redeem queue entries are in spPRIME shares escrowed in the vault; fee burned up front
  (`_divUp(shares * redeemFeeRate, WAD)`). No cancel. `processPendingRedeems` (REBALANCER) burns
  shares and calls `spUSDC.withdraw(assets, recipient, vault)`, bounded by
  `convertToShares(spUSDC.maxWithdraw(vault))`.
- NEW blacklist handling: `requestRedeem`, `requestDepositCancellation`,
  `updateDepositCancellationRecipient`, `updateRedeemRecipient` require
  `!asset.isBlacklisted(recipient)` (`recipient-cannot-receive`). At payout time, if the recipient
  is blacklisted, the vault withdraws/redeems to ITSELF and credits `claimableAssets[recipient]`
  (`ClaimableAssetsIncreased`); `claim(recipient)` is permissionless and sends USDC to the
  recipient (reverts in USDC while still blacklisted). USDC therefore can sit inside the vault.
- NEW `adjustTotalAssets(int256 delta)`: DEFAULT_ADMIN only, requires `paused`, drips, sets
  `chi = (totalAssets + delta) * RAY / totalSupply`; requires result > 0, `chi != 0`,
  `chi <= type(uint192).max`. Replaces `realizeGain`/`realizeLoss`. Panics (div by zero) at
  `totalSupply == 0`.
- Roles: `DEFAULT_ADMIN_ROLE` (upgrade, adjustTotalAssets, setCapacity, setMaxRedeemFeeRate,
  setMinDeposit, setMinRedeem, setVSRBounds, unpause), `GUARDIAN_ROLE` (pause only),
  `REBALANCER_ROLE` (the three `processPending*`), `REDEEM_FEE_SETTER_ROLE` (setRedeemFeeRate),
  `TAKER_ROLE` (take), `VSR_SETTER_ROLE` (setVSR). `RISK_MANAGER_ROLE`, `SETTER_ROLE`,
  `UNPAUSER_ROLE` are gone.
- `transfer`/`transferFrom` reject `to == address(this)` (and zero). `requestDeposit` and
  `updateDepositRecipient` reject the vault as recipient; the redeem/cancellation recipients are only
  blacklist-checked (vault and spUSDC still accepted there).
- Events renamed (`DepositRequest(owner, recipient, id, assetsDeposited, savingsSharesMinted)`,
  `Deposit(owner, recipient, assetsConverted, sharesMinted)`,
  `DepositCancellationRequest(depositRequestId, cancelRequestId, recipient)` all indexed,
  `DepositCancellation(owner, recipient, savingsSharesBurned, assetsReceived)`,
  `RedeemRequest(owner, recipient, id, sharesToBurn, feeSharesBurned)`,
  `Redeem(owner, recipient, sharesBurned, savingsSharesBurned, assetsReceived)`,
  `TotalAssetsAdjusted(chi, deltaTotalAssets)`, `Claim`, `ClaimableAssetsIncreased`,
  `Take(uint256 shares)`). Storage layout changed: the three `Request[]` arrays are now the FIRST
  storage slots, `paused` sits after `asset`, `decimals` after `symbol`, `claimableAssets` after
  `nonces`. Single-entry getters `getPending{Deposit,DepositCancellation,Redeem}Request(id)` exist
  (require `firstPending.. <= id < length`).
- Read `src/SparkPrimeVault.sol` yourself before writing anything. Line numbers in reports must be
  on `0ebb452`.

## Status of previously reported findings (pin each one you touch with a test)

Fixed upstream (write a regression test that proves the fix, named `test_fixed_<slug>`):
- R4-A / R4-B (blacklisted recipient blocks the redeem / cancellation queue): payouts now fall back
  to `claimableAssets`. Prove the queue keeps moving, the escrow is correct, `claim` pays after
  un-blacklisting, and `claim` reverts while blacklisted. Then try to break the new path (see
  hypotheses).
- R3-1 (`realizeGain` sandwich): `adjustTotalAssets` requires `paused`. Prove deposit/redeem
  requests are blocked while paused. Note: the admin is a governance spell with a public payload;
  `pause` is a separate GUARDIAN tx, so a deposit between "payload public" and "pause" still
  captures the gain. Quantify it.
- V2-2 / F-1 (guardian-chosen refund recipient): guardian cancel path removed entirely.
- V2-1 (unauthenticated recipient updaters): owner-only, pin it.
- I-3, `CancelRedeemRequest` dead event, `no-shares` unreachable check: gone.

Still open on `master` as far as we can see (re-prove, re-measure, keep `test_BUG_` names):
- C-3 (no loss floor): `adjustTotalAssets(-(totalAssets - 1))` still wipes holders in one call.
- G-1 / G-2 (`chi` overflow brick): the only bound is `chi <= type(uint192).max` (~6.3e57). `drip`
  computes `_rpow(vsr, dt) * chi` in uint256, so any `chi > ~1.15e50` makes `drip()` revert on the
  next second, and `adjustTotalAssets` itself calls `drip()` first so it cannot undo it. Prove the
  exact threshold and that only an upgrade recovers it. Also check `convertToAssets` overflow with
  large supply.
- C-1 (batched redeem ceil-rounding revert): `_processPendingRedeems` still bounds by
  `convertToShares(maxWithdraw)` once at the top and calls `withdraw(assets)` per entry.
- V2-7 (`setCapacity` unbounded), V2-8 (zero admin at init / last admin renounce), C-7 (bounds do
  not clamp live values: `setVSRBounds` below current `vsr`, `setMaxRedeemFeeRate` below current
  `redeemFeeRate`), C-8 (minimums unvalidated), C-9 (MAX_VSR 100% APY), C-11 (dust deposits donate
  to spUSDC), V2-9 (`requestRedeem(0)` ghosts), V2-11 (cancellation-queue bloat), V2-13 (vault and
  spUSDC as redeem/cancel recipients strand USDC), V2-14 (dust at the head switches to queued
  mode), F-2 (rebalancer is the single exit; `take()` can drain queue backing), DQ-10.

## Hypotheses to attack (pick the ones in your area, add your own)

1. Blacklist path: USDC credited to `claimableAssets` sits in the vault. Can anything else move it?
   (`requestDeposit` pulls exactly `assets_` then deposits `assets_`; `take` moves spUSDC only.)
   Can a recipient blacklisted at request time but un-blacklisted at process time, or vice versa,
   break accounting? Can `claim` be griefed or front-run? Does `claimableAssets` interact with
   `adjustTotalAssets` (USDC in the vault is NOT counted in `totalAssets`)? Can a blacklisted
   `owner` still `updateRedeemRecipient`? Is a blacklisted *vault* or *spUSDC* address a brick?
   What if the recipient of a deposit cancellation is blacklisted at settlement: `redeem` to vault
   then claimable: correct amounts, exact wei?
2. `adjustTotalAssets` edge cases: `totalSupply == 0` (panic), delta that makes `chi` round, loss
   then gain round trip not identity, pending redeem escrow absorbs loss while pending deposits
   (spUSDC-denominated) do not, capacity in shares shrinks in USD terms after a loss, `uint192`
   bound vs the real overflow bound in `drip`/`nowChi`/`convertToAssets`, interaction with `vsr`
   accrual during the pause (drip happens first), events.
3. Instant-fill predicate `pendingDepositSavingsShares == savingsShares_`: zero-asset requests
   (`minDeposit == 0`) push ghost entries and still trigger a full walk; with `availableCapacity()
   == 0` the walk never advances the head (`remaining_ == 0` short-circuits the loop), so ghosts
   accumulate until capacity returns; measure the gas a griefer can impose on the next depositor
   and whether `processPendingDeposits(1, N)` clears them. Can two live requests ever both see the
   predicate true? Can a partially filled head plus a cancel make the predicate true for a
   newcomer while someone else is still owed?
4. Queue head semantics: `firstPendingDepositId` only moves inside `_processPendingDeposits`, and
   only when `remaining_ != 0`. `getPendingDepositRequest(id)` and the array views for
   cancelled/filled ids. Any way to double-fill, skip, or starve an entry? Partial fill then
   cancel then refill ordering. `maxRequests_` counting ghosts.
5. Rounding: deposit path (`spUSDC.deposit` floor -> `convertToAssets` floor -> `convertToShares`
   floor); redeem path (`convertToAssets` floor -> `withdraw` ceil-burns spUSDC); cancellation path
   (`redeem` floors assets). Who eats each wei, can the vault pay out more spUSDC than it holds
   across many partial fills (C-1), can capacity be exceeded by 1 share, can `totalSupply` exceed
   `maxCapacity` via instant fill, zero-share mints (F-4) at ugly indexes.
6. ERC20/permit: `permit` with ERC1271 contracts, malleable signatures, nonce handling on revert,
   `transferFrom` self-approval path, `_transfer` unchecked add, `DOMAIN_SEPARATOR` after a name
   change (no setter) and chain fork.
7. Access control: full matrix for every external function including `claim`, `drip`,
   `adjustTotalAssets`, the three `updateXRecipient`, role admin, `renounceRole` of last admin,
   `_authorizeUpgrade`, initializer re-entry on the implementation and the proxy.
8. Pause semantics: what still works while paused (`drip`, `take`, `claim`, `updateXRecipient`,
   `transfer`, `permit`, `setVSR`, `adjustTotalAssets`), what does not, and whether anything that
   works while paused is a problem (e.g. `take()` during an incident).
9. Upgrade: storage layout of `0ebb452` (the arrays moved to the front). Write a layout test that
   pins slot numbers via `forge inspect`-equivalent assertions (`vm.load`) so an auditor sees them.
10. Economic: sandwich around `adjustTotalAssets` (deposit instant-fill before pause, redeem queue
    after), value transfer between queued redeemers and holders when `chi` changes, fee bypass via
    transfer to a fresh address, referral spoofing, griefing via `minDeposit`-sized requests.

## Harness: `test/ai/LocalTestBase.t.sol`

Inherit `LocalTestBase`. It deploys a 6-decimal `MockUSDC` (with `isBlacklisted(address)`,
`setBlacklisted(address,bool)`; transfers/approvals involving a blacklisted address revert with
"Blacklistable: account is blacklisted" like mainnet USDC), the REAL spUSDC `SparkVault` code
(`test/ai/lib/spusdc/SparkVault.sol`) and the `SparkPrimeVault` proxy with every role granted,
capacity `type(uint128).max`, maxRedeemFee 1%, VSR bounds `[RAY, MAX_VSR]` on both vaults, fee 0,
minimums 0, both VSRs at RAY (0%) with "ugly" starting indexes.

Actors: `spAdmin, spSetter, spTaker` (spUSDC) and `admin, guardian, rebalancer, redeemFeeSetter,
taker, vsrSetter` (spPRIME). Role constants: `DEFAULT_ADMIN_ROLE, GUARDIAN_ROLE, REBALANCER_ROLE,
REDEEM_FEE_SETTER_ROLE, TAKER_ROLE, VSR_SETTER_ROLE` (and `SETTER_ROLE` for spUSDC).

Helpers: `_fund(who, amt)`, `_deposit(who, amt) -> id`, `_requestRedeem(who, shares) -> id`,
`_setCapacity`, `_setRedeemFeeRate`, `_setMinDeposit`, `_setMinRedeem`,
`_adjustTotalAssets(int256)` (admin, needs pause), `_adjustTotalAssetsWhilePaused(int256)`,
`_setPrimeVsr`, `_setSpUsdcVsr`, `_processDeposits(maxSavingsShares, maxRequests)`,
`_processRedeems(maxShares, maxRequests)`, `_processCancelledDeposits(..)`,
`_cancelDepositAndSettle(who, id)`, `_pause`, `_unpause`, `_blacklist(who)`, `_unblacklist(who)`,
`BLACKLISTED` (revert bytes), `_drainSpUsdcLiquidity(amt)`, `_drainAllSpUsdcLiquidity()`,
`_returnSpUsdcLiquidity(amt)`, `_take(savingsShares)`, `_takeAll()`,
`_returnToVault(savingsShares)`, `_warp(secs)`, `_warpAndDrip(secs)`, `_depositRequest(id)`,
`_redeemRequest(id)`, `_cancelledDepositRequest(id)`, `_depositQueueLength()`,
`_redeemQueueLength()`, `_cancelledDepositQueueLength()`, `_vaultSpUsdc()`.

Gotcha: `vm.prank` is consumed by the next external call, including view calls like
`spUsdc.balanceOf(...)` used as an argument. Cache values in locals first.

Porting rules: tests for removed behaviour (`realizeGain`, `realizeLoss`, `cancelRedeemRequest`,
guardian cancels, `UNPAUSER_ROLE`, 2-arg `requestDeposit`) are rewritten against the replacement
behaviour or deleted with a one-line note in your report, never left commented out. Old
`test_BUG_` tests for findings that are now fixed become `test_fixed_` tests asserting the fix.
Keep exact-value assertions (exact wei, exact revert strings). Style: mirror
`~/work/spark-vaults-v2/test/` (naming `test_<fn>_<case>`, `testFuzz_`, `invariant_<letter>_<claim>`,
assert exact balances before and after each step).

Run only your files: `FOUNDRY_OFFLINE=true forge test --match-path 'test/ai/<YourFile>.t.sol' -vv`.
Fuzz runs default to 1000; `FOUNDRY_FUZZ_RUNS=20000` for a property that matters.

## Deliverable

1. Your test file(s), committed on your branch (`git add test/ai/<file>`; `git -c user.name=campaign
   -c user.email=campaign@local commit`). Every test must PASS, or be a deliberate failing proof
   of a bug named `test_BUG_<slug>` (say so in the report).
2. Append a "## Round 5 (`master` @ `0ebb452`)" section at the TOP of your `test/ai/REPORT-<area>.md`
   (create it if missing) with: (a) each bug or suspicious behaviour, with `file:line` in
   `src/SparkPrimeVault.sol`, a concrete scenario with exact amounts, impact, the proving test
   name, and a severity (critical/high/medium/low/info); (b) previously reported findings and their
   status now (fixed / open / changed), each with the pinning test; (c) properties that held, each
   with its test; (d) anything you could not settle. No speculation without a test behind it.
3. Your final message: the same report, compact.
