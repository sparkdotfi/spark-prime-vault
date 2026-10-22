# spPRIME invariant campaign report

## Round 6 (`master` @ `c512609`)

Branch `campaign-v6/invariants`. The suite was REWRITTEN into the house layout (reference:
`test/invariants/` on the fork, which runs on mainnet; this one is its no-RPC complement over
`test/ai/LocalTestBase.t.sol`: real spUSDC code on a 6-decimal `MockUSDC` with `setBlacklisted`).
Files: `test/ai/invariants/handlers/{HandlerBase,UserHandler,AdminHandler,ExternalHandler}.sol`,
`test/ai/invariants/InvariantsBase.t.sol` (invariant helpers `vaultInvariant_<Letter>_<claim>`),
`test/ai/invariants/Invariants.t.sol` (`invariant_vaultInvariants` + `afterInvariant`). The
round-5 files `a_init.sol`, `b_flows_user.sol`, `c_flows_admin.sol`, `d_invariants.t.sol` are
deleted. Rules kept from the reference: handlers only bound, prank, call and bump ghost counters;
no per-flow post-condition blocks, no bitflag systems, no `vm.load`, no selector lists
(`targetContract` only); the two modifiers `chiNeverDecreases` (all flows but
`adjustTotalAssets`) and `headsNeverMoveBack` (all flows); invariants read public getters only.
`foundry.toml` has `fail_on_revert = true`, so every handler call must succeed. All line numbers
below are on `c512609`.

Final run: `FOUNDRY_OFFLINE=true FOUNDRY_INVARIANT_RUNS=500 FOUNDRY_INVARIANT_DEPTH=500 forge
test --skip 'test/ai/TestBase.t.sol' --match-path 'test/ai/invariants/Invariants.t.sol' -vv`
-> **1 passed, 0 failed: 500 runs x depth 500 = 250,000 handler calls, 0 reverts, 0 discards**,
184 s wall. (`--skip test/ai/TestBase.t.sol` because the fork harness, not owned by this worker,
does not compile on this master: duplicate `operator` / `OPERATOR_ROLE` declarations and the old
4-argument `initialize`; it is not imported by anything under `test/ai/invariants/`.) Earlier
runs: 20 x 100 and 30 x 150, both green after the one fix below. Handler call counts from the
final run (uniform selector draw over 32 flows, all 0 reverts):

| flow | calls | flow | calls | flow | calls |
|---|---|---|---|---|---|
| requestDeposit | 7787 | requestDepositCancellation (partial) | 7792 | requestRedeem | 7803 |
| updateDepositRecipient | 7847 | updateDepositCancellationRecipient | 7812 | updateRedeemRecipient | 7693 |
| claim | 7843 | transfer | 7738 | transferFrom | 7844 |
| setVSRBounds | 7893 | setVSR | 7829 | setCapacity (below supply allowed) | 7790 |
| setMaxRedeemFeeRate | 7718 | setRedeemFeeRate | 8043 | setMinDeposit | 7994 |
| setMinDepositCancellation | 7832 | setMinRedeem | 7652 | pause | 7795 |
| unpause | 7903 | adjustTotalAssets (lossManager, paused) | 7763 | processPendingDeposits | 7735 |
| processPendingDepositCancellations | 7873 | processPendingRedeems | 7767 | take | 7731 |
| warp | 7802 | drip | 7793 | setSavingsVsr | 7801 |
| drainSavingsLiquidity | 7832 | returnSavingsLiquidity | 7797 | returnTakenSavingsShares | 7777 |
| giveSavingsShares | 7865 | setBlacklisted (`usdc.setBlacklisted`) | 7856 | | |

Per-flow ghost counters (fills, claimables credited, gaps opened) are not kept any more by design;
the reference layout records only the flags and counters the invariants read.

### (a) Findings

No invariant broke in 250,000 calls, so no `test_BUG_` test was added. The one failure during
development was in the suite, not the vault: forge re-checks the invariants after
`afterInvariant`, and the settlement walked the queues with the harness helpers instead of the
handlers, so the escrow ledger (L) saw the `requestRedeem`s but not the fills; settlement now
goes through `adminHandler.process*(0, 0)` (the unbounded branch of `_boundProcessing`).

Behaviour recorded by the ghost flags (not violations):

- **R5-1 / F-2 (open, by design, medium)**: `_processPendingRedeems` (`:942`-`:976`) still bounds
  each fill by `convertToShares(availableLiquidAssets())` (`:953`) = `spUSDC.maxWithdraw(vault)`
  (`:823`-`:825`), the vault's whole spUSDC balance, and `take` (`:289`-`:298`) only checks the
  balance (`:291`): neither subtracts `pendingDepositSavingsShares` or
  `pendingCancelledDepositSavingsShares`. `AdminHandler.backingGapOpened` is set by exactly those
  two flows; invariant J (`spUSDC(vault) >= pending deposits + pending cancels`) is asserted in
  every state before the flag is set and never failed, i.e. no other flow opens the gap.
  `afterInvariant` tops the vault up (`_giveSavingsShares`) before draining the cancellation
  queue, which is the operational fix the product relies on.
- **V2-7 / R5-8 family (info)**: `setCapacity` (`:304`-`:306`) is unbounded; the handler cuts it
  below `totalSupply` (`capacityLoweredBelowSupply`) and invariant H's `totalSupply <= maxCapacity`
  is only asserted before that; `availableCapacity()` (`:819`-`:821`) formula asserted always. The
  handler caps capacity at `uint128.max` because `convertToAssets(availableCapacity())` (`:864`)
  overflows near `uint256.max` (R5-8, open, unit-suite topic).
- **`adjustTotalAssets` at `totalSupply == 0`** (`:277`, NOTE at `:276`) still divides by zero;
  the handler skips that state (open, low, unit-suite topic). Chi after an adjustment is kept
  inside [1e21, 1e33] by the handler; the contract allows (0, uint192.max] (R5-1/G-1, R5-3/C-3
  open, unit-suite topics).

### (b) Prior findings touched by this suite, status at `c512609`

- **C-1 / R5-4 (batched redeem fills reverted on spUSDC ceil-rounding): fixed.** `fillable_` is
  recomputed per entry (`:953`) and the loop breaks at 0 (`:955`); 7,767 `processPendingRedeems`
  calls, one in four with both axes unbounded, under `fail_on_revert` with spUSDC liquidity
  drained at random and the vault's spUSDC taken at random: 0 reverts. The round-5 proof
  `test_BUG_processPendingRedeemsRevertsOnCeilBurnWhenBalanceBinds` was deleted with the old
  suite (the 100-spUSDC / 110-entry regression is the redeem-queue unit suite's).
- **R4-A / R4-B (blacklisted recipient blocks a queue): fixed, now by `try/catch`**
  (`_redeemSavings` `:978`-`:995`, `_withdrawSavings` `:997`-`:1014`). 7,856 blacklist flips over
  10 users; fills to blacklisted recipients land in `claimableAssets`; invariant F (vault USDC ==
  `totalClaimable` == sum of `claimableAssets`, exact) held after every call, and `afterInvariant`
  un-blacklists everyone, claims and ends with `totalClaimable == 0` and vault USDC == 0 in all
  500 runs. Requests and updaters no longer reject blacklisted recipients (no probe needed).
- **R5-1 / F-2: open**, see (a); invariant J + `backingGapOpened`.
- **N-2 (cancellation processing bounded by spUSDC liquidity): still fixed**, `:907`-`:908`
  (`maxRedeem`); 7,873 calls, 0 reverts, and invariant N (refunds paid <= spUSDC value of the
  shares redeemed) held.
- **R5-9 ghosts / frozen head: changed.** Partial cancels (`:434`-`:438`) and the self-skip walk
  (`:445`, `:875`-`:878`) are exercised by every `requestDepositCancellation`; heads never moved
  back (modifier) and E (`head + window == requests made`) held. 1-wei deposits (0 spUSDC shares,
  R5-15) and 1-share redeems at a nonzero fee (zero-share entries, R5-14) stay reachable because
  the handler minimums go down to 1: both are walked and deleted without reverting, D and E hold
  with them in the queues.
- **T (adjustTotalAssets exactness), R/S (recipient updates), AA/AB (claim and revert
  classification), Y (per-call payout exactness)**: dropped as per-flow post-conditions. Y
  survives as M/N (cumulative `paid <= owed` counters); S is covered by the vault's own
  `NotRequestOwner` check being the only path the handler never exercises (owner-only pranks).
- **Pause no longer gates cancellations (R5-B)**: `requestDepositCancellation` and
  `processPendingDepositCancellations` are called in paused states by the handlers (not
  pause-skipped) with 0 reverts.

### (c) Invariants held (500 runs x depth 500, 250,000 calls, 0 reverts; checked after every call and after `afterInvariant`)

| Helper | Claim |
|---|---|
| `vaultInvariant_A_sumBalancesPlusEscrowEqTotalSupply` | sum of 10 user balances + vault escrow == totalSupply |
| `vaultInvariant_B_escrowEqPendingRedeemShares` | balanceOf(vault) == pendingRedeemShares |
| `vaultInvariant_C_assetConversions` | totalAssets == supply*chi/RAY; assetsOf == balance*chi/RAY <= totalAssets |
| `vaultInvariant_D_pendingSharesEqSumOfQueues` | the three `pending*` counters == sums over the pending windows |
| `vaultInvariant_E_queueHeadsAndLengths` | head + window length == requests made (ghost counters) for all three queues |
| `vaultInvariant_F_claimables` | vault USDC == totalClaimable == sum(claimableAssets), exact |
| `vaultInvariant_G_configBounds` | vsr/minVSR/maxVSR within [RAY, MAX_VSR]; fee rates <= MAX_REDEEM_FEE; minimums nonzero |
| `vaultInvariant_H_capacity` | availableCapacity formula; supply <= maxCapacity unless lowered below supply |
| `vaultInvariant_I_chiRhoDrip` | chi > 0, rho <= now, nowChi >= chi, drip() == nowChi and syncs chi/rho |
| `vaultInvariant_J_backing` | vault spUSDC >= pending deposits + pending cancels until `take` / a redeem fill opens the gap |
| `vaultInvariant_K_roles` | every actor keeps its role; exactly one admin |
| `vaultInvariant_L_escrowOnlyLeavesThroughRedeemFills` | balanceOf(vault) == shares escrowed by requestRedeem - shares burned by redeem fills |
| `vaultInvariant_M_redeemPayoutsNeverExceedSharesBurned` | cumulative USDC paid (direct + claimable) by redeem fills <= convertToAssets(shares burned) |
| `vaultInvariant_N_cancellationPayoutsNeverExceedSavingsSharesRedeemed` | cumulative refunds <= spUSDC.convertToAssets(savings shares redeemed) |
| modifier `chiNeverDecreases` | nowChi never decreases across any flow but `adjustTotalAssets` |
| modifier `headsNeverMoveBack` | no `firstPending*Id` decreases across any flow |
| `afterInvariant` | from every end state: unpause, un-blacklist, return taken spUSDC and drained USDC, freeze both rates, make spUSDC fully liquid, open capacity, drain deposits, top up and drain cancellations, everyone redeems, top up and drain redeems, claim for all -> all three queues empty, totalSupply == 0, escrow == 0, totalClaimable == 0, vault USDC == 0, totalAssets == 0; `sum(assetsOf)` and `totalAssets` non-decreasing over 30 idle minutes at each stage |

Harness-specific points vs the reference: `MockUSDC.mint` instead of `deal`; blacklist via
`usdc.setBlacklisted`; spUSDC actors `spSetter` / `spTaker` from `LocalTestBase`; both rates start
accruing (`FIVE_PCT_VSR` spUSDC, `FOUR_PCT_VSR` spPRIME) so the rate order is broken from the
start and flips with every `setVSR` / `setSavingsVsr`; minimums can be set down to 1 (dust and
zero-share entries reachable); `afterInvariant` additionally mints spUSDC's accrued-interest
shortfall into it because the vault is spUSDC's only depositor here.

### (d) Unsettled

- `test/ai/TestBase.t.sol` (fork harness, another worker's file) does not compile on this master;
  the suite is run with `--skip` for it.
- The campaign does not drive chi outside [1e21, 1e33], capacity above `uint128.max`, or
  `adjustTotalAssets` at zero supply (R5-1/G-1, R5-3/C-3, R5-8 stay unit-suite topics).
- R5-1 is reported, not pinned, by this suite (J is flag-gated); the exact-number proof lives in the
  redeem-queue unit suite.


## Round 5 (`master` @ `0ebb452`)

Branch `campaign-v5/invariants`, files `test/ai/invariants/{a_init,b_flows_user,c_flows_admin}.sol`,
`test/ai/invariants/d_invariants.t.sol`. Target: upstream `src/SparkPrimeVault.sol` from `master` @
`0ebb452` (roles split into `DEFAULT_ADMIN / GUARDIAN / REBALANCER / REDEEM_FEE_SETTER / TAKER /
VSR_SETTER`; `realizeGain`/`realizeLoss` replaced by `adjustTotalAssets(int256)` (admin, requires
`paused`); guardian deposit cancels gone, `requestDepositCancellation` owner-only; 3-arg
`requestDeposit(assets, recipient, referral)`; blacklist handling: `recipient-cannot-receive` guard
at request / update time and a `claimableAssets` fallback at payout time with permissionless
`claim`). Harness: `test/ai/LocalTestBase.t.sol` (real spUSDC code, 6-decimal mock USDC with a
Circle-style blacklist, ugly starting indexes chi_s = 1.0476e27, chi_p = 1.0097e27). All line
numbers below are on `0ebb452`.

Final run: `FOUNDRY_OFFLINE=true FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=500 forge
test --match-path 'test/ai/invariants/d_invariants.t.sol' -vv` -> **31 passed, 0 failed** (28
invariants x 1000 runs x 500 calls = **500,000 handler calls per invariant, 0 reverts**, plus 3
unit proofs; 755 s wall, 11,537 s CPU). An earlier 200 x 500 run of the same suite (before Z was
re-bounded for R5-1) also passed 30/30 in 117 s; the first 1000 x 500 run is the one that broke
Z (see R5-1). Handler call counts summed over the 28 sampled last-runs of the final run (one per
invariant, 14,000 calls; the selector draw is uniform over the 27 flows):

| flow | calls | flow | calls | flow | calls |
|---|---|---|---|---|---|
| requestDeposit | 504 | requestDepositWithReferral | 595 | requestDepositCancellation | 488 |
| requestRedeem | 544 | updateRecipient | 518 | transfer | 520 |
| transferFrom | 531 | setBlacklisted | 481 | claim | 513 |
| setCapacity | 539 | setMaxRedeemFeeRate | 482 | setRedeemFee | 547 |
| setMinDeposit | 470 | setMinRedeem | 494 | setPrimeVsr | 518 |
| setSpUsdcVsr | 551 | pause | 524 | unpause | 502 |
| adjustTotalAssets | 527 | processPendingDeposits | 537 | processPendingDepositCancellations | 562 |
| processPendingRedeems | 510 | take | 506 | returnToVault | 505 |
| drainSpUsdcLiquidity | 499 | returnSpUsdcLiquidity | 521 | warp | 512 |

Ghost counters over the same sample: `adjustTotalAssets` executed 182 negative and 178 positive
deltas (sum |loss| 13,247,342,619,885,996 wei, sum gain 12,165,690,350,117,248 wei), 123
`not-paused` probes (123 reverted `not-paused`), 39 zero-supply probes (39 panics 0x12); 327
blacklist sets, 165 clears, 181 blacklisted-recipient probes (181 reverted
`recipient-cannot-receive`); 53 fills paid into `claimableAssets` (5,795,457,648,531,718 wei
credited), 35 successful `claim`s (3,870,373,927,249,058 wei), 26 `claim` attempts while
blacklisted (26 reverted in USDC, state unchanged), 463 `nothing-to-claim` probes; 342 deposit
fills, 51 cancellation fills, 145 redeem fills, 3 zero-share fills (F-4), 48 ghost deposit
entries and 31 ghost redeem entries (F-5); 88 owner recipient updates (17 to a blacklisted
holder on the deposit queue, 21 to a fresh address), 17 stranger attempts (17 reverted); 407
`take`s, 55 backing gaps opened by `take`, 3 opened by `processPendingRedeems` (R5-1), 0 by any
other flow; 90 `setCapacity` below `totalSupply`; the rate order broke in 26 of 28 sampled runs;
0 C-1 reverts, 0 cancellation-processing reverts, 0 unexpected reverts, `maxGainLossError` 1 in
every run, `redeemPayoutMaxExcess` / `cancelPayoutMaxExcess` 0 in every run.

### (a) Violations and findings

One new finding (R5-1), found by invariant Z at 1000 runs x depth 500 (shrunk to 9 calls) and
pinned as a unit proof; everything else held.

- **R5-1 (medium): redeem fills are paid out of the spUSDC that backs queued deposits and queued
  cancellations.** `_processPendingRedeems` (`src/SparkPrimeVault.sol:900`) sets its budget to
  `convertToShares(availableLiquidAssets())` (`:903`) and `availableLiquidAssets()` (`:788`-`:790`)
  is `spUSDC.maxWithdraw(vault)`, i.e. the vault's whole spUSDC balance; nothing subtracts
  `pendingDepositSavingsShares` or `pendingCancelledDepositSavingsShares`. Whenever the notional
  `totalAssets()` exceeds the real backing, redeemers receive the cancellers' / depositors' spUSDC
  and the cancellation queue can no longer be paid in full (it stalls at the head until new spUSDC
  arrives, with no lever but `returnToVault`-style top-ups). The notional exceeds the backing
  after any positive `adjustTotalAssets` (`:278`) whose USDC has not arrived, whenever the spPRIME
  VSR is above the spUSDC VSR (the product's normal state while capital is deployed), and
  whenever `take` (`:340`) moved capital out. Scenario (exact, harness indexes): alice deposits
  1,000 USDC (990,405,183 shares, backing 954,532,691 spUSDC = 999,999,999 USDC); admin pauses
  and calls `adjustTotalAssets(+100e6)` (totalAssets 1,099,999,997, no USDC arrives); alice queues
  a redeem of all shares; capacity is set to `totalSupply`, so bob's 500 USDC deposit queues as
  477,266,345 spUSDC and bob cancels it; `processPendingRedeems`: budget 1,350,552,523 shares
  (`maxWithdraw` 1,499,999,999 USDC, bob's backing included), alice is paid 1,099,999,997 USDC,
  the vault keeps 381,813,078 spUSDC against 477,266,345 owed; `processPendingDepositCancellations`
  pays bob 400,000,001 USDC and stops: 95,453,267 spUSDC stay pending at head 0, bob is short
  99,999,997 USDC, the vault holds 0 spUSDC. The fictitious gain was paid to alice from bob's
  refund. Impact: cancellation refunds (and, symmetrically, queued deposits waiting for capacity)
  are not senior to redeems; a canceller's principal becomes exit liquidity for redeemers whenever
  the notional runs ahead of the backing. Fix shape: bound the redeem budget by
  `held - pendingDepositSavingsShares - pendingCancelledDepositSavingsShares` (in assets) rather
  than `maxWithdraw(vault)`. Proof: `test_BUG_processPendingRedeemsSpendsCancellationQueueBacking`
  (passes by asserting the shortfall). Random-walk evidence: invariant Z's original form
  ("cancellation queue drains after settling everything") failed at 1000 x 500 with 570,130,850
  spUSDC left; the handler now records which flow opens a backing gap (`gapOpenedByRedeems`,
  `gapOpenedByTake`, `gapOpenedElsewhere` must stay false; invariant W) and Z bounds the unpaid
  remainder of the cancellation + redeem queues by the deficit ledger instead.

Behaviour worth recording (no violation):

- **C-3 (open, high, not re-measured here)**: `adjustTotalAssets` (`:278`-`:295`) only requires
  `totalAssets_ > 0` and `updatedChi_ != 0`; the handler bounds |delta| to `totalAssets / 10`
  and chi to [1, 1e30], so the campaign does not drive the wipe-out. The owning unit suite pins it.
- **`adjustTotalAssets` at `totalSupply == 0` panics (low, open)**: `:289` divides by
  `totalSupply` (NOTE at `:288` "Assuming totalSupply is not zero"). 39 of 39 probes in the sample
  reverted with Panic(0x12). Harmless (nothing to adjust) but an unchecked division in an admin
  path; asserted by `invariant_T_adjustTotalAssetsAccounting` (probes == panics).
- **Deposit-queue backing is not ring-fenced against `take` either (F-2, open, by design)**:
  `take` (`:340`) can move the spUSDC that backs queued deposits and queued cancels out of the
  vault. Invariant W holds strictly (`spUSDC(vault) >= pendingDepositSavingsShares +
  pendingCancelledDepositSavingsShares`) in every run in which neither `take` nor a redeem fill
  (R5-1) opened the gap, and no other flow ever opened one. The queues simply wait until spUSDC
  comes back; no accounting breaks.
- **`totalSupply > maxCapacity` is reachable only through `setCapacity`** (V2-7 family, info):
  90 capacity cuts below supply in the sample; invariant F (no mint ever exceeds the capacity in
  force) and X (supply <= capacity unless the admin lowered it) both held.
- **Blacklist fallback path is accounting-exact**: every fill to a blacklisted recipient
  (`_redeemSavings` `:934`-`:945`, `_withdrawSavings` `:947`-`:958`) credits `claimableAssets`
  by exactly the USDC that landed in the vault (asserted inline per processing call) and the
  vault's USDC balance equals the sum of `claimableAssets` after every single handler call
  (invariant K, exact). `claim` (`:524`-`:534`) zeroes the credit before the transfer; while the
  recipient is still blacklisted the USDC transfer reverts and the credit, the recipient's balance
  and the vault's balance are byte-identical afterwards (invariant AA). Un-blacklisting everyone
  and claiming always empties the vault's USDC (invariant Z, checked from every reachable state).
- **Stranger `update*Recipient` with a blacklisted recipient reverts `recipient-cannot-receive`,
  not `not-authorized`** (info): the guard at `:493` / `:508` runs before the ownership check at
  `:498` / `:513`, so a non-owner can learn whether an address is blacklisted through the vault.
  No state impact. The handler accepts either reason for a stranger (invariant S).
- **`requestDepositCancellation` with the owner as recipient while the owner is blacklisted**
  reverts `recipient-cannot-receive` (`:425`): a blacklisted depositor cannot cancel to itself and
  must name another recipient (or wait for the fill, which mints shares and is not
  blacklist-gated). Observed, by design (`recipient` is free).

### (b) Previously reported findings, status at 0ebb452 (as seen by this suite)

- C-1 / N-1 (round 1): **open**. `_processPendingRedeems` (`:900`) bounds `remaining_` by
  `convertToShares(availableLiquidAssets())` (`:903`) once and pays each entry with spUSDC
  `withdraw(assets_)` (`:922` -> `:952`/`:955`), ceil-burning up to one spUSDC share per entry.
  `test_BUG_processPendingRedeemsRevertsOnCeilBurnWhenBalanceBinds` unchanged and passing (100
  spUSDC held, 110 one-share entries: batched call reverts `SparkVault/insufficient-balance`, one
  entry per call pays 99 and strands 1 share, 11 shares stay pending). Not hit by the random walk
  (0 of 510 sampled `processPendingRedeems` calls), as in rounds 2-4.
- N-2 (round 2): **fixed, still**. `_processPendingDepositCancellations` (`:864`) budgets by
  `spUSDC.maxRedeem(vault)` (`:870`); 0 reverts in 100,000 calls (invariant P),
  `test_processPendingDepositCancellationsPaysUpToSpUsdcLiquidity` passing with the same wei
  (alice 99,999,999; bob 49,999,999 then 99,999,999).
- R4-A / R4-B (blacklisted recipient blocks a queue): **fixed** by the `claimableAssets` fallback;
  53 sampled fills went to blacklisted recipients, the queues kept moving (heads advanced, invariant
  V), escrow exact (B), USDC exact (K), later `claim` paid (35 sampled). Pinned by invariants AA, K,
  Z and the inline asserts in `processPendingRedeems` / `processPendingDepositCancellations`.
- R3-1 (`realizeGain` sandwich): **changed**. `adjustTotalAssets` requires `paused` (`:279`, 123
  of 123 unpaused probes reverted `not-paused`); the handler pauses, adjusts and unpauses. The
  window between a public payload and the guardian's `pause` is a unit-suite topic.
- V2-1 (unauthenticated recipient updaters): **fixed**, 17 of 17 stranger attempts reverted
  (invariant S); 88 owner updates moved only the recipient field (invariant R, the digest now
  also covers USDC and claimable balances).
- V2-2 / F-1 (guardian cancel): **fixed**, the path is gone; the guardian probe flow was deleted.
- F-2 (`take` drains queue backing): **open**, see W above; R5-1 is the same missing ring-fence
  seen from the redeem side.
- T (round 4, gain/loss exactness): **holds for `adjustTotalAssets`**: `totalAssets()` moved by
  exactly |delta| within 1 wei in all 360 sampled executions (`maxGainLossError` 1).
- Removed behaviour: `realizeGain` / `realizeLoss` flows rewritten as `adjustTotalAssets`;
  `cancelRedeemRequest`, the guardian cancel probe and `UNPAUSER_ROLE` references deleted.

### (c) Invariants that held (1000 runs x depth 500, 500,000 calls each, 0 reverts)

| Name | Claim |
|---|---|
| `invariant_A_sumOfBalancesEqualsTotalSupply` | sum of balances over 8 holders + vault escrow == totalSupply |
| `invariant_B_vaultBalanceEqualsPendingRedeemShares` | balanceOf(vault) == pendingRedeemShares (escrow exact) |
| `invariant_C_pendingDepositEqualsSumOfOpenDepositEntries` | pendingDepositSavingsShares == sum of open deposit entries |
| `invariant_D_pendingRedeemEqualsSumOfOpenRedeemEntries` | pendingRedeemShares == sum of open redeem entries |
| `invariant_Q_pendingCancelledEqualsSumOfOpenCancelledEntries` | pendingCancelledDepositSavingsShares == sum of open cancellation entries |
| `invariant_E_headBookkeeping` | every entry before a head is closed; heads <= lengths; contract lengths == handler lengths |
| `invariant_V_headsNeverMoveBackwards` | no `firstPending*Id` ever decreased across a handler call |
| `invariant_F_totalSupplyNeverExceedsCapacityViaMint` | no mint pushed totalSupply above the maxCapacity in force |
| `invariant_X_totalSupplyWithinCapacityUnlessLowered` | totalSupply <= maxCapacity unless setCapacity went below supply |
| `invariant_G_chiMonotonicAndDripConsistent` | nowChi() changes only in warp (up), adjustTotalAssets (down for delta < 0, up for delta > 0); == last observation, >= chi, > 0; drip() == nowChi(), chi/rho updated |
| `invariant_L_availableCapacityFormula` | availableCapacity() == max(0, maxCapacity - totalSupply) |
| `invariant_H_solvencyWhenSpUsdcRateGePrimeRate` | spUSDC value held net of both spUSDC queues >= totalAssets() - deficit ledger - epsilon, while the rate order held and nothing is taken |
| `invariant_I_usersNeverExtractMoreThanDepositsPlusYield` | holder USDC + claimable <= deposits + spUSDC yield + taker top-ups; == redeem fills + refunds; claimable == credited - claimed |
| `invariant_K_backingExistsSomewhereAndVaultUsdcIsClaimable` | every USDC wei minted is in spUSDC / spTaker / vault / taker / holders; **vault USDC == sum of claimableAssets, exact** |
| `invariant_N_spUsdcSharesHeldByVaultAndTaker` | vault + taker hold every spUSDC share; taker balance == ledger |
| `invariant_W_spUsdcCoversQueuesUnlessTakenOrRedeemed` | vault spUSDC >= pending deposits + pending cancels unless `take` or a redeem fill (R5-1) opened the gap; no other flow ever opens one (max gap and opener recorded) |
| `invariant_M_noMintOfZeroSharesExceptDust` | zero-share fills counted (3 sampled, dust only) |
| `invariant_O_processPendingRedeemsRevertsOnlyOnCeilBurn` | processPendingRedeems reverts only with `SparkVault/insufficient-balance` (0 seen) |
| `invariant_P_processPendingDepositCancellationsNeverReverts` | processPendingDepositCancellations never reverts |
| `invariant_Y_payoutsExactlyConvertedShares` | each processing call paid (direct + claimable) exactly sum of floor conversions of consumed shares; nobody received more than convertToAssets(burned) (excess 0, so the "+1 wei per fill" bound holds with margin) |
| `invariant_R_recipientUpdatesNeverChangeTotals` | owner recipient updates move nothing but the recipient field |
| `invariant_S_recipientUpdateByNonOwnerAlwaysReverts` | stranger updates revert `not-authorized` (or `recipient-cannot-receive` when the blacklist guard runs first) |
| `invariant_T_adjustTotalAssetsAccounting` | totalAssets() moves by exactly delta within 1 wei; zero-supply calls panic 0x12 |
| `invariant_U_redeemEscrowOnlyLeavesThroughFills` | balanceOf(vault) never decreased outside processPendingRedeems |
| `invariant_AA_claimNeverPaysWhileBlacklisted` | claim while blacklisted reverts in USDC and moves nothing; claim of 0 reverts `nothing-to-claim`; every blacklisted-recipient request/update reverted `recipient-cannot-receive` |
| `invariant_AB_noUnexpectedReverts` | every revert the handler caught was on its allow-list (counts by reason printed per run) |
| `invariant_Z_settleEverythingPaysEveryClaimable` | terminal: unpause, un-blacklist all, return taken spUSDC, make spUSDC liquid, open capacity, drain the three queues, claim for all -> deposit queue empty, every claimable paid, vault USDC == 0; while the rate order held: cancellation queue empty and redeem queue payable up to the C-1 strand bound when no fictitious gain exists, otherwise unpaid (cancel + redeem) <= deficit ledger + bound (evaluated from every reachable state on a non-committing call) |
| `invariant_J_balanceProvenance` | each holder's balance == minted + in - out - escrowed |

Harness changes vs round 4: 8 holders (6 active, 2 fresh recipient-only addresses); every
blacklist guard is probed rather than avoided and classified by exact reason; `adjustTotalAssets`
pauses itself when drawn unpaused (1 in 4 draws probes `not-paused` instead); `setBlacklisted`
targets the recipient of an open redeem/cancel entry so fills land in `claimableAssets`, and
clears prefer a holder with a claimable; `claim` retries after clearing the blacklist in half of
the blacklisted attempts. The `counted` modifier now also snapshots the three heads (V) and the
spUSDC backing gap (W) around every call.

### (d) Unsettled

- C-1 was not reproduced by the random walk (entries are large and uniform; the unit proof stands).
- H and Z's queue bounds skip the states after the rate order broke (`setPrimeVsr` above the
  spUSDC VSR in 1 of 8 draws; 26 of 28 sampled runs eventually break it, so their effective
  coverage is the prefix before the first break); after a positive `adjustTotalAssets` Z only
  bounds the unpaid remainder by the deficit ledger. The claimable / USDC / deposit-queue
  assertions of Z are evaluated unconditionally.
- R5-1 was hit by the random walk only 3 times in the 28 sampled final runs (the opener counter);
  the exact-number proof is the unit test. Whether the rebalancer is expected to never process
  redeems while cancellations are queued is a process question the contract does not enforce.
- Overflow of `(totalAssets + delta) * RAY`, chi past 1e30 / `type(uint192).max` and the `drip`
  `_rpow` overflow (G-1 / G-2) are deliberately outside the handler bounds.
- Blacklisting the vault or spUSDC itself, USDC donations to the vault, and `permit` are not in
  the handler (unit-suite topics).
- `afterInvariant()` logs are printed once per invariant test (last run only), so ghost counters
  are sampled, not totals; the per-invariant call counts are exact.

---
## Round 4 (bf93b0d)

Branch `campaign-v4/invariants`, files `test/ai/invariants/{a_init,b_flows_user,c_flows_admin}.sol`,
`test/ai/invariants/d_invariants.t.sol`. Target: upstream `src/SparkPrimeVault.sol` from
`fix/update-guardian-transfer` @ `bf93b0d` (`cancelRedeemRequest` removed; guardian
`requestDepositCancellation` requires `recipient_ == owner`; planner entry points
`processPendingDeposits` / `processPendingRedeems` / `processPendingDepositCancellations`; queue
reads via `getPending*Requests(start, end)`; heads `firstPending*Id`). Harness:
`test/ai/LocalTestBase.t.sol` (real spUSDC code, 6-decimal mock USDC, ugly starting indexes
chi_s = 1.0476e27, chi_p = 1.0097e27).

Final run: `FOUNDRY_INVARIANT_RUNS=100 FOUNDRY_INVARIANT_DEPTH=500 forge test --match-path
'test/ai/invariants/*.t.sol' -vv` (with the `--skip` list for the review files that do not compile
against bf93b0d) -> **23 passed, 0 failed** (21 invariants x 100 runs x 500 calls = 50,000 handler
calls per invariant, 0 handler reverts, plus 2 unit proofs).

### (a) Violations and findings

No invariant A..U was violated in any run. No new finding.

- `cancelRedeemRequest` is gone (`src/SparkPrimeVault.sol`: no such function; the
  `CancelRedeemRequest` event at `:101` is now dead). The handler and J's refund term are removed;
  escrowed shares can only leave the vault through `_processPendingRedeems` (`:905`). New
  `invariant_U`: the vault's own share balance never decreased in any handler call other than
  `processPendingRedeems` (127 such decreases in the 21 sampled last-runs, 0 elsewhere).
  `requestRedeem` (`:461`-`:466`) moves `shares` in and burns `fee <= shares` out of the escrow,
  a net increase, so it never trips U.
- Guardian deposit cancels (`src/SparkPrimeVault.sol:422`-`:425`): the handler now cancels as the
  guardian with `recipient_ == owner` in 1 of 3 cancels and, right before each, probes the same
  cancel with a non-owner recipient: 29 of 29 probes reverted with exactly
  `SparkPrimeVault/invalid-recipient` (asserted inline in the handler, counts
  `guardianCancelProbes` / `guardianCancelProbeReverts`). The cancelled entry carries the owner
  as recipient and the refund (`processPendingDepositCancellations`) pays the owner.
- N-1 (round 1, `processPendingRedeems` reverts `SparkVault/insufficient-balance` when the vault's
  spUSDC balance binds and the per-entry ceil burns add up) is **still present** at
  `src/SparkPrimeVault.sol:886` / `:909`. `test_BUG_processPendingRedeemsRevertsOnCeilBurnWhenBalanceBinds`
  unchanged and passing; the random walk did not hit it (`redeemProcessReverts` 0).
- N-2 (round 2) stays fixed: `_processPendingDepositCancellations` budgets by
  `spUSDC.maxRedeem(vault)` (`:848`), 0 reverts in 50,000 calls (`invariant_P`),
  `test_processPendingDepositCancellationsPaysUpToSpUsdcLiquidity` passing.
- `update*Recipient` (`:483`, `:494`, `:508`) owner-only: 25 of 25 stranger attempts reverted
  `SparkPrimeVault/not-authorized` (`invariant_S`); 119 owner updates moved only the recipient
  field (`invariant_R`).
- `realizeGain` (`:293`) 371 calls and `realizeLoss` (`:365`) 125 calls in the sampled last-runs,
  `totalAssets()` moved by exactly the amount within 1 wei every time (`invariant_T`,
  `maxGainLossError` 1 in every run).

### (b) Invariants that held (100 runs x depth 500, 50,000 calls each, 0 reverts)

| Name | Claim |
|---|---|
| `invariant_A_sumOfBalancesEqualsTotalSupply` | sum of balances over 6 users + vault escrow == totalSupply |
| `invariant_B_vaultBalanceEqualsPendingRedeemShares` | balanceOf(vault) == pendingRedeemShares |
| `invariant_C_pendingDepositEqualsSumOfOpenDepositEntries` | pendingDepositSavingsShares == sum of open deposit entries |
| `invariant_D_pendingRedeemEqualsSumOfOpenRedeemEntries` | pendingRedeemShares == sum of open redeem entries |
| `invariant_E_headBookkeeping` | every entry strictly before firstPendingDepositId / firstPendingDepositCancellationId / firstPendingRedeemId has shares == 0; heads <= lengths |
| `invariant_F_totalSupplyNeverExceedsCapacityViaMint` | no mint ever pushed totalSupply above maxCapacity as set at mint time |
| `invariant_G_chiMonotonicAndDripConsistent` | nowChi() only changes inside warp (up), realizeGain (up) and realizeLoss (down); nowChi() == the handler's last observation, >= stored chi, > 0; drip() == nowChi(), chi/rho updated |
| `invariant_H_solvencyWhenSpUsdcRateGePrimeRate` | while spUSDC VSR >= spPRIME VSR always held and the taker holds nothing: value(held spUSDC) - value(open deposit entries) - value(open cancelled entries) + epsilon >= totalAssets() - deficit ledger (ledger as in round 3) |
| `invariant_I_usersNeverExtractMoreThanDepositsPlusYield` | sum of users' USDC <= USDC deposited + USDC minted into spUSDC + taker top-ups, and == USDC paid by redeem fills + cancelled-deposit refunds |
| `invariant_J_balanceProvenance` | balanceOf(user) == minted (attributed to the entry recipient at fill time) + transfers in - transfers out - escrowed (no refund term: redeems cannot be cancelled) |
| `invariant_K_backingExistsSomewhere` | USDC in spUSDC + spUSDC taker + users + vault + spPRIME taker == USDC ever minted; vault holds 0 USDC |
| `invariant_L_availableCapacityFormula` | availableCapacity() == max(0, maxCapacity - totalSupply) |
| `invariant_M_noMintOfZeroSharesExceptDust` | zero-share fills counted (F-4), reported in afterInvariant() |
| `invariant_N_spUsdcSharesHeldByVaultAndTaker` | spUSDC totalSupply == vault + taker balances; taker balance == handler ledger |
| `invariant_O_processPendingRedeemsRevertsOnlyOnCeilBurn` | the only revert reason ever seen from processPendingRedeems is `SparkVault/insufficient-balance` |
| `invariant_P_processPendingDepositCancellationsNeverReverts` | processPendingDepositCancellations never reverted (any reason is counted and kept) |
| `invariant_Q_pendingCancelledEqualsSumOfOpenCancelledEntries` | pendingCancelledDepositSavingsShares == sum of open cancelled-deposit entries |
| `invariant_R_recipientUpdatesNeverChangeTotals` | an owner recipient update leaves totals, pendings, heads, chi/rho, every share and USDC balance, the vault's spUSDC and every entry's owner/shares byte-identical (keccak digest before == after) |
| `invariant_S_recipientUpdateByNonOwnerAlwaysReverts` | every recipient update attempted by a non-owner on an open entry reverted with exactly `SparkPrimeVault/not-authorized` (attempts == such reverts) |
| `invariant_T_gainAndLossAccounting` | after every realizeGain / realizeLoss, totalAssets() == before +/- amount within 1 wei (running max error <= 1, out-of-bound count 0) |
| `invariant_U_redeemEscrowOnlyLeavesThroughFills` | balanceOf(vault) never decreased across any handler call other than processPendingRedeems (checked in the `counted` modifier around every call) |

Handler coverage (foundry selector metrics, `invariant_A`, 100 runs x 500 calls, 0 reverts,
0 discards): drainSpUsdcLiquidity 2002, pause 1943, processPendingDepositCancellations 2012,
processPendingDeposits 1953, processPendingRedeems 1933, realizeGain 2019, realizeLoss 2013,
requestDeposit 2031, requestDepositCancellation 2035, requestDepositWithReferral 1954,
requestRedeem 2013, returnSpUsdcLiquidity 1997, returnToVault 1963, setCapacity 2018,
setMinDeposit 1970, setMinRedeem 2010, setPrimeVsr 2013, setRedeemFeeRate 2027, setSpUsdcVsr 2057,
take 2016, transfer 2044, transferFrom 2025, unpause 2006, updateRecipient 1940, warp 2006.

Ghost counters summed over the 21 sampled last-runs (one 500-call run per invariant test):
depositQueueLength 647, cancelledQueueLength 90, redeemQueueLength 246, depositFills 457,
cancelledFills 122, redeemFills 190, escrowDecreases 127 (all inside processPendingRedeems),
zeroShareFills 3, ghostDepositEntries 67, ghostRedeemEntries 52, recipientUpdates 119,
strangerUpdateAttempts 25 (all 25 reverted `not-authorized`), guardianCancelProbes 29 (all 29
reverted `invalid-recipient`), lossRealizations 125 (realizedLossUsdc 1.60e16),
gainRealizations 371 (realizedGainUsdc 5.99e16), maxGainLossError 1 in every run,
redeemProcessReverts 0, cancelProcessReverts 0, usersRedeemedUsdc 3.35e16,
usersRefundedUsdc 2.46e16, rateOrderBroken true in 19 of 21.

Handler changes this round: `cancelRedeemRequest` handler and `ghostRefunded` removed.
`requestDepositCancellation` passes the owner as recipient whenever it pranks the guardian and
first probes the guardian cancel with a non-owner recipient (must revert `invalid-recipient`).
The `counted` modifier snapshots `balanceOf(vault)` around every handler call and flags any
decrease outside `processPendingRedeems` (invariant U). Everything else as round 3.

### (c) Unsettled

- H is only checked while the taker holds nothing and the rate order never broke; the random walk
  breaks the order in most runs (19 of 21 sampled), so H's effective coverage is the prefix of
  each run before the first order break.
- The deficit ledger is an upper bound (gains are notional, no backing arrives in the harness), so
  H does not prove the deficit equals the gains exactly.
- `realizeGain` accepts any `gain_ > 0`; the handler keeps chi below 1e30. Overflow of
  `(totalAssets + gain) * RAY` or chi past `type(uint192).max` is not exercised.
- N-1 with large, non-uniform entries was not reproduced in the random walk.
- With no redeem cancel, shares queued for redeem behind illiquid spUSDC stay escrowed until
  liquidity returns; the guardian has no lever on the redeem queue. Observed, by design.
- `afterInvariant()` logs are printed once per invariant test (last run only), so ghost counters
  are sampled, not totals; the selector table is the exact coverage.
- Donations of spPRIME to the vault (I-6) are excluded by design.

---

## Round 3 (ff828d2)

Branch `campaign-v3/invariants`, files `test/invariants/{a_init,b_flows_user,c_flows_admin}.sol`,
`test/invariants/d_invariants.t.sol`. Target: upstream `src/SparkPrimeVault.sol` from
`refactor/more-simplifying` @ `ff828d2` (owner-only `update*Recipient`, `realizeLoss` requires
`0 < loss < totalAssets` and a live supply, `_processCancelledDepositQueue` budgets by
`spUSDC.maxRedeem(vault)`, new `realizeGain`). Harness: `test/LocalTestBase.t.sol` (real spUSDC
code, 6-decimal mock USDC, ugly starting indexes chi_s = 1.0476e27, chi_p = 1.0097e27).

Final run: `FOUNDRY_INVARIANT_RUNS=100 FOUNDRY_INVARIANT_DEPTH=500 forge test --match-path
'test/invariants/*.t.sol' -vv` -> **22 passed, 0 failed** (20 invariants x 100 runs x 500 calls =
50,000 handler calls per invariant, 0 handler reverts, plus 2 unit proofs).

### (a) Violations and findings

No invariant A..T was violated in any run. No new finding.

- N-2 (round 2, `processCancelledDepositQueue` reverting on spUSDC illiquidity) is **fixed**:
  `src/SparkPrimeVault.sol:784` now bounds `remaining_` by `spUSDC.maxRedeem(vault)`
  (= min(balance, floor(liquidity * RAY / chi_s))). The handler wraps the call and counts every
  revert; `invariant_P` now asserts 0 reverts and held over 50,000 calls with the spUSDC taker
  draining all liquidity in 1 of 4 drain calls and refunds queued in 68 entries of the 20 sampled
  last-runs. Unit proof renamed to `test_processCancelledDepositQueuePaysUpToSpUsdcLiquidity`:
  two 100 USDC refunds queued, 150 USDC liquidity, `(max, 2)` pays alice 99,999,999 and bob
  49,999,999 (partial, stays at the head), a call with 0 liquidity is a no-op, the remainder is
  paid once 100 USDC is back (bob ends at 99,999,999).
- N-1 (round 1, `processRedeemQueue` reverts `SparkVault/insufficient-balance` when the vault's
  spUSDC balance binds and the per-entry ceil burns add up) is **still present** at
  `src/SparkPrimeVault.sol:822` / `:845`. `test_BUG_processRedeemQueueRevertsOnCeilBurnWhenBalanceBinds`
  unchanged and passing; the random walk did not hit it (`redeemProcessReverts` 0).
- `update*Recipient` (`src/SparkPrimeVault.sol:416`, `:465`, `:537`) are owner-only: 17 of 17
  deliberate non-owner attempts in the sampled last-runs reverted with exactly
  `SparkPrimeVault/not-authorized` (new `invariant_S`); the 114 owner updates moved nothing but
  the recipient field (`invariant_R`).
- `realizeGain` (`src/SparkPrimeVault.sol:297`): 380 calls in the sampled last-runs, in any pause
  state, `1 <= gain <= totalAssets / 10`; `totalAssets()` moved by exactly the gain minus at most
  1 wei every time (new `invariant_T`, `maxGainLossError` 1 in every run). The gain is notional:
  nothing arrives in the harness, so after a gain the vault is insolvent by the gain plus its
  yield; `invariant_H` accounts for that with a deficit ledger (below) and still held.
- `realizeLoss` (`src/SparkPrimeVault.sol:369`): 111 calls, same +/-1 wei accounting.

### (b) Invariants that held (100 runs x depth 500, 50,000 calls each, 0 reverts)

| Name | Claim |
|---|---|
| `invariant_A_sumOfBalancesEqualsTotalSupply` | sum of balances over 6 users + vault escrow == totalSupply |
| `invariant_B_vaultBalanceEqualsPendingRedeemShares` | balanceOf(vault) == pendingRedeemShares |
| `invariant_C_pendingDepositEqualsSumOfOpenDepositEntries` | pendingDepositSavingsShares == sum of depositQueue[i].shares |
| `invariant_D_pendingRedeemEqualsSumOfOpenRedeemEntries` | pendingRedeemShares == sum of redeemQueue[i].shares |
| `invariant_E_headBookkeeping` | every entry strictly before depositHead / cancelledDepositHead / redeemHead has shares == 0; heads <= lengths |
| `invariant_F_totalSupplyNeverExceedsCapacityViaMint` | no mint ever pushed totalSupply above maxCapacity as set at mint time |
| `invariant_G_chiMonotonicAndDripConsistent` | nowChi() only changes inside warp (up), realizeGain (up) and realizeLoss (down); nowChi() == the handler's last observation, >= stored chi, > 0; drip() == nowChi(), chi/rho updated |
| `invariant_H_solvencyWhenSpUsdcRateGePrimeRate` | while spUSDC VSR >= spPRIME VSR always held and the taker holds nothing: value(held spUSDC) - value(open deposit entries) - value(open cancelled entries) + epsilon >= totalAssets() - deficit ledger. Ledger: +gain on realizeGain, -loss on realizeLoss, scaled on each warp by spUSDC's index while positive and by spPRIME's index while negative (both upper bounds given the rate order; rounding towards the bound). epsilon = redeemFills * ceil(chi_s/RAY) + 2 wei |
| `invariant_I_usersNeverExtractMoreThanDepositsPlusYield` | sum of users' USDC <= USDC deposited + USDC minted into spUSDC + taker top-ups, and == USDC paid by redeem fills + cancelled-deposit refunds |
| `invariant_J_balanceProvenance` | balanceOf(user) == minted (attributed to the entry recipient at fill time) + transfers in + redeem-cancel refunds - transfers out - escrowed |
| `invariant_K_backingExistsSomewhere` | USDC in spUSDC + spUSDC taker + users + vault + spPRIME taker == USDC ever minted; vault holds 0 USDC |
| `invariant_L_availableCapacityFormula` | availableCapacity() == max(0, maxCapacity - totalSupply) |
| `invariant_M_noMintOfZeroSharesExceptDust` | zero-share fills counted (F-4), reported in afterInvariant() |
| `invariant_N_spUsdcSharesHeldByVaultAndTaker` | spUSDC totalSupply == vault + taker balances; taker balance == handler ledger |
| `invariant_O_processRedeemQueueRevertsOnlyOnCeilBurn` | the only revert reason ever seen from processRedeemQueue is `SparkVault/insufficient-balance` |
| `invariant_P_processCancelledDepositQueueNeverReverts` | processCancelledDepositQueue never reverted (any reason is counted and kept) |
| `invariant_Q_pendingCancelledEqualsSumOfOpenCancelledEntries` | pendingCancelledDepositSavingsShares == sum of cancelledDepositQueue[i].shares |
| `invariant_R_recipientUpdatesNeverChangeTotals` | an owner recipient update leaves totals, pendings, heads, chi/rho, every share and USDC balance, the vault's spUSDC and every entry's owner/shares byte-identical (keccak digest before == after) |
| `invariant_S_recipientUpdateByNonOwnerAlwaysReverts` | every recipient update attempted by a non-owner on an open entry reverted with exactly `SparkPrimeVault/not-authorized` (attempts == such reverts) |
| `invariant_T_gainAndLossAccounting` | after every realizeGain / realizeLoss, totalAssets() == before +/- amount within 1 wei (running max error <= 1, out-of-bound count 0) |

Handler coverage (foundry selector metrics, `invariant_A`, 100 runs x 500 calls, 0 reverts,
0 discards): cancelDepositRequest 1941, cancelRedeemRequest 1825, drainSpUsdcLiquidity 1946,
pause 1987, processCancelledDepositQueue 1997, processDepositQueue 1951, processRedeemQueue 1870,
realizeGain 1854, realizeLoss 1904, requestDeposit 1953, requestDepositWithReferral 1935,
requestRedeem 1983, returnSpUsdcLiquidity 1951, returnToVault 1937, setCapacity 1928,
setMinDeposit 1868, setMinRedeem 1940, setPrimeVsr 1899, setRedeemFee 1887, setSpUsdcVsr 1938,
take 1877, transfer 1905, transferFrom 2003, unpause 1875, updateRecipient 1944, warp 1902.

Ghost counters summed over the 20 sampled last-runs (one 500-call run per invariant test):
depositQueueLength 585, cancelledQueueLength 68, redeemQueueLength 215, depositFills 433,
cancelledFills 84, redeemFills 102, zeroShareFills 5, ghostDepositEntries 71, ghostRedeemEntries 37,
recipientUpdates 114, strangerUpdateAttempts 17 (all 17 reverted `not-authorized`),
lossRealizations 111 (realizedLossUsdc 1.36e16), gainRealizations 380 (realizedGainUsdc 5.91e16),
maxGainLossError 1 in every run, redeemProcessReverts 0, cancelProcessReverts 0,
usersRedeemedUsdc 1.84e16, usersRefundedUsdc 1.61e16, rateOrderBroken true in 17 of 20.

Handler changes this round: `updateRecipient` scans forward from a random index for an open entry
and pranks its owner; 1 in 8 calls pranks a different user instead, wrapped in try/catch, and
records the reason. `pause` pranks the guardian only. `realizeLoss` unchanged in bounds
(`totalAssets >= 10`, `1 <= loss <= totalAssets/10`, chi kept > 0) and now feeds T and the deficit
ledger. New `realizeGain` handler (admin, any pause state, `totalSupply > 0`, `totalAssets >= 10`,
`1 <= gain <= totalAssets/10`, skipped when the resulting chi would exceed 1e30). `warp` is the
only handler that moves time and now scales the deficit ledger and resets the chi watermark;
G flags any other chi movement in either direction. `processCancelledDepositQueue` keeps the
try/catch only to capture a reason if the call ever reverts.

### (c) Unsettled

- H is only checked while the taker holds nothing and the rate order never broke; the random walk
  breaks the order in most runs (17 of 20 sampled), so H's effective coverage is the prefix of
  each run before the first order break. A dedicated run with the 1-in-8 branches removed would
  strengthen it, especially now that realized gains make the vault deliberately insolvent.
- The deficit ledger is an upper bound, so H proves "the notional never exceeds backing plus the
  fictitious gains and their worst-case yield"; it does not prove the deficit equals the gains
  exactly. A harness that mints spUSDC into the vault on `realizeGain` would turn H back into a
  tight solvency check.
- `realizeGain` accepts any `gain_ > 0` with no upper bound; the handler keeps chi below 1e30.
  With `gain_` large enough that `(totalAssets + gain) * RAY` overflows, or chi passes
  `type(uint192).max`, the call reverts or truncates; not exercised.
- N-1 with large, non-uniform entries was not reproduced in the random walk.
- `afterInvariant()` logs are printed once per invariant test (last run only), so ghost counters
  are sampled, not totals; the selector table is the exact coverage.
- Donations of spPRIME to the vault (I-6) are excluded by design.

---

## Round 2 (0bc9288)

Branch `campaign-v2/invariants`, files `test/invariants/{a_init,b_flows_user,c_flows_admin}.sol`,
`test/invariants/d_invariants.t.sol`. Target: upstream `src/SparkPrimeVault.sol` from
`refactor/more-simplifying` (cancelled-deposit queue, unauthenticated recipient updates,
`realizeLoss`, `minRedeem` in shares, `requestRedeem(0)` allowed). Harness: `test/LocalTestBase.t.sol`
(real spUSDC code, 6-decimal mock USDC, ugly starting indexes chi_s = 1.0476e27, chi_p = 1.0097e27).

Final run: `FOUNDRY_INVARIANT_RUNS=100 FOUNDRY_INVARIANT_DEPTH=500 forge test --match-path
'test/invariants/*.t.sol' -vv` -> **20 passed, 0 failed** (18 invariants x 100 runs x 500 calls =
50,000 handler calls per invariant, 0 handler reverts, plus 2 unit proofs).

The same run was repeated on a scratch copy of the repo with `review/poc-tests-v2` applied
(`pause()` back on GUARDIAN_ROLE, `realizeLoss` sets `chi = floor((totalAssets - loss) * RAY /
totalSupply)`, `totalAssets()` public): **20 passed, 0 failed**, 0 reverts. The handlers are written
for both revisions (pause pranks the guardian and falls back to the admin; the loss handler keeps
`loss <= totalAssets / 10`, requires the resulting chi > 0, and asserts the floor
`totalAssets_after + loss <= totalAssets_before`, which is what H consumes). The `git merge
review/poc-tests-v2` in this worktree was blocked by the sandbox's permission classifier (as was
`git apply` of the same diff), so the committed worktree still carries the pre-merge `src/`; the
merge is a 3-file, conflict-free change to `src/`, `README.md` and `test/LocalTestBase.t.sol`
and is left to the coordinator.

## (a) Violations and findings

### N-1 Low (round 1, still present): `processRedeemQueue` reverts when the vault's spUSDC balance is the binding limit

- Location: `src/SparkPrimeVault.sol:780` (`remaining_ = _min(maxShares_, convertToShares(availableLiquidAssets()))`)
  and `src/SparkPrimeVault.sol:803` (`IERC4626Like(savings).withdraw(assets_, request.recipient, address(this))`).
- Mechanism unchanged from round 1: the budget is a single floor in USDC while every entry burns
  `ceil(assets_ * RAY / chi_s)` spUSDC shares, so k entries can over-burn by up to k-1 shares and
  the whole batch reverts `SparkVault/insufficient-balance` when the balance, not spUSDC's
  liquidity, binds.
- Sequence: alice `requestDeposit(100e6)`; alice `requestRedeem(1)` x110; taker
  `take(vaultSpUsdc - 100)`; rebalancer `processRedeemQueue(max, 110)` reverts; `(max, 1)` x110
  pays 99 wei, strands 1 share, leaves 11 entries open.
- Test: `test_BUG_processRedeemQueueRevertsOnCeilBurnWhenBalanceBinds` (passes by asserting the
  revert). Handler counter `redeemProcessReverts`; any other reason fails `invariant_O`.

### N-2 Low (round 2, known to the coordinator): `processCancelledDepositQueue` reverts when spUSDC is illiquid instead of paying what it can

- Location: `src/SparkPrimeVault.sol:742` (`remaining_ = _min(maxSavingsShares_, IERC20Like(savings).balanceOf(address(this)))`)
  and `src/SparkPrimeVault.sol:763` (`IERC4626Like(savings).redeem(savingsShares_, request_.recipient, address(this))`).
- Mechanism: the budget is the vault's spUSDC balance only. spUSDC `redeem` then needs
  `floor(shares * chi_s / RAY)` USDC of liquidity for every entry; when spUSDC's USDC has been
  taken, the batch reverts inside spUSDC with `SparkVault/insufficient-liquidity` and nothing is
  paid. `processRedeemQueue` does not have this failure because its budget goes through
  `maxWithdraw`, which caps at spUSDC liquidity. The `insufficient-balance` revert cannot happen
  here: `redeem` burns exactly `savingsShares_ <= remaining_ <= balance`, so after `take()` the
  function pays what is left and stops (verified by code read and by the campaign: 0 such reverts
  in 50,000 calls with the taker draining the vault in 1 of 4 `take` calls).
- Sequence (harness numbers): capacity 0; alice `requestDeposit(100e6)`, bob `requestDeposit(100e6)`
  (both queue); each cancels to self; spUSDC taker drains all but 150 USDC;
  rebalancer `processCancelledDepositQueue(max, 2)` reverts `SparkVault/insufficient-liquidity`;
  `(max, 1)` pays alice 99,999,999 (1-wei deposit/redeem floor round trip), then `(max, 1)` reverts
  again for bob until 100 USDC is returned to spUSDC.
- Impact: operational. The rebalancer must size `maxSavingsShares_` off-chain against
  `spUSDC.convertToShares(usdc.balanceOf(spUSDC))`; no funds at risk. Refunds queue behind
  spUSDC liquidity exactly as redeems do, but without the partial-payment behaviour redeems get.
- Test: `test_BUG_processCancelledDepositQueueRevertsWhenSpUsdcIlliquid` (passes by asserting the
  revert). Handler counter `cancelProcessReverts` (18 in the 18 sampled last-runs); any other
  reason fails `invariant_P`.
- Fix options: bound `remaining_` by `_min(balance, spUSDC.convertToShares(usdc.balanceOf(spUSDC)))`,
  or break out of the loop when the next payout exceeds spUSDC's liquidity.

### Observed, not asserted (reported by NEWSURFACE, exercised here)

- `updateDepositRecipient` / `updateCancelledDepositRecipient` / `updateRedeemRecipient`
  (`src/SparkPrimeVault.sol:421`, `:465`, `:532`) have no caller check. The handler lets a random
  user repoint a random entry; 264 of 292 sampled updates were by a non-owner. Every fill paid the
  recipient the entry carried at fill time. `invariant_R` confirms the update itself moves nothing.
- `cancelRedeemRequest` pays the `recipient_` argument whoever the caller is (guardian included);
  J's bookkeeping credits that recipient.
- `setCapacity` (`src/SparkPrimeVault.sol:268`) accepts any `uint256`; the handler keeps it
  `<= type(uint128).max` because `convertToAssets(availableCapacity())` overflows above that and
  bricks `processDepositQueue`.
- `realizeLoss` (`src/SparkPrimeVault.sol:356`) with `loss == totalAssets` zeroes chi and bricks
  every conversion; the handler skips that case (never reachable with `loss <= totalAssets / 10`).

No invariant A..R was violated in any run on either source revision. Known findings observed live
by the handler counters (not re-reported): F-4 zero-share dust fills (`zeroShareFills`, 4 in the 18
sampled last-runs), F-5 ghost entries (80 zero-amount deposit entries, 51 zero-share or fee-eaten
redeem entries, `requestRedeem(0)` now being legal).

## (b) Invariants that held (100 runs x depth 500, 50,000 calls each, 0 reverts)

| Name | Claim |
|---|---|
| `invariant_A_sumOfBalancesEqualsTotalSupply` | sum of balances over 6 users + vault escrow == totalSupply |
| `invariant_B_vaultBalanceEqualsPendingRedeemShares` | balanceOf(vault) == pendingRedeemShares (no donations in the campaign) |
| `invariant_C_pendingDepositEqualsSumOfOpenDepositEntries` | pendingDepositSavingsShares == sum of depositQueue[i].shares |
| `invariant_D_pendingRedeemEqualsSumOfOpenRedeemEntries` | pendingRedeemShares == sum of redeemQueue[i].shares |
| `invariant_E_headBookkeeping` | every entry strictly before depositHead / cancelledDepositHead / redeemHead has shares == 0; heads <= lengths |
| `invariant_F_totalSupplyNeverExceedsCapacityViaMint` | no mint ever pushed totalSupply above maxCapacity as set at mint time |
| `invariant_G_chiMonotonicAndDripConsistent` | chi never decreases outside `realizeLoss` (handler flag), nowChi() >= last observed chi, chi > 0, drip() == nowChi(), chi/rho updated |
| `invariant_H_solvencyWhenSpUsdcRateGePrimeRate` | spUSDC value held minus value owed to open deposit entries minus value owed to open cancelled entries + epsilon >= totalAssets() + sum of realised losses, while spUSDC VSR >= spPRIME VSR always held and the taker holds nothing; epsilon = redeemFills * ceil(chi_s/RAY) + 2 wei (cancel refunds use `redeem`, exact burn, add nothing) |
| `invariant_I_usersNeverExtractMoreThanDepositsPlusYield` | sum of users' USDC <= USDC deposited + USDC minted into spUSDC + taker top-ups, and == USDC paid by redeem fills + USDC paid by cancelled-deposit refunds |
| `invariant_J_balanceProvenance` | balanceOf(user) == minted (attributed to the entry recipient at fill time) + transfers in + redeem-cancel refunds (to the `recipient_` argument) - transfers out - escrowed |
| `invariant_K_backingExistsSomewhere` | USDC in spUSDC + spUSDC taker + users (redeem payouts and cancel refunds) + vault + spPRIME taker == USDC ever minted; vault holds 0 USDC |
| `invariant_L_availableCapacityFormula` | availableCapacity() == max(0, maxCapacity - totalSupply) |
| `invariant_M_noMintOfZeroSharesExceptDust` | zero-share fills counted (F-4), reported in afterInvariant() |
| `invariant_N_spUsdcSharesHeldByVaultAndTaker` | spUSDC totalSupply == vault + taker balances; taker balance == handler ledger |
| `invariant_O_processRedeemQueueRevertsOnlyOnCeilBurn` | the only revert reason ever seen from processRedeemQueue is `SparkVault/insufficient-balance` |
| `invariant_P_processCancelledDepositQueueRevertsOnlyOnKnownReasons` | the only revert reason ever seen from processCancelledDepositQueue is `SparkVault/insufficient-liquidity` |
| `invariant_Q_pendingCancelledEqualsSumOfOpenCancelledEntries` | pendingCancelledDepositSavingsShares == sum of cancelledDepositQueue[i].shares |
| `invariant_R_recipientUpdatesNeverChangeTotals` | a recipient update leaves totals, pendings, heads, chi/rho, every share and USDC balance, the vault's spUSDC and every entry's owner/shares byte-identical (keccak digest before == after) |

Handler coverage (foundry selector metrics, `invariant_A`, 100 runs x 500 calls, 0 reverts,
0 discards; the last six rows come from a second run with the same parameters):
cancelDepositRequest 2059, cancelRedeemRequest 1998, drainSpUsdcLiquidity 2052, pause 2072,
processCancelledDepositQueue 1905, processDepositQueue 1942, processRedeemQueue 2021,
realizeLoss 1941, requestDeposit 2005, requestDepositWithReferral 1974, requestRedeem 2046,
returnSpUsdcLiquidity 2044, returnToVault 2071, setCapacity 2053, setMinDeposit 2022,
setMinRedeem 1995, setPrimeVsr 2002, setRedeemFee 2004, setSpUsdcVsr 1918, take 2018,
transfer 2058, transferFrom 1903, unpause 2085, updateRecipient 2009, warp 2016.

Ghost counters summed over the 18 sampled last-runs (one 500-call run per invariant test):
depositQueueLength 591, cancelledQueueLength 94, redeemQueueLength 225, depositFills 410,
cancelledFills 99, redeemFills 116, zeroShareFills 4, ghostDepositEntries 80, ghostRedeemEntries 51,
recipientUpdates 292 (264 by a non-owner), lossRealizations 85 (realizedLossUsdc 9.45e15),
redeemProcessReverts 0 (N-1 not hit by the random walk; the unit test proves it),
cancelProcessReverts 18 (N-2 hit live), usersRedeemedUsdc 1.50e16, usersRefundedUsdc 2.01e16.
Merged-source copy: lossRealizations 80, cancelProcessReverts 13, otherwise the same shape.

Handler design: 6 users; inputs bounded; actions that would revert are skipped (paused, empty
balance, no open entry); 10% zero-amount deposits and 10% zero-share / minimum-size redeems when
minimums allow; capacity 50% wide open / 30% small headroom / 20% at or below supply; VSRs keep
spUSDC >= spPRIME except in 1 of 8 calls (sticky `rateOrderBroken` flag disables H); pause in 1 of
4 pause calls; losses only while paused, `1 <= loss <= totalAssets/10`, chi kept > 0; warps
1 s..30 days with drips on both vaults; spUSDC liquidity drained and returned (minted); taker takes
and returns spUSDC (minting the shortfall); random users repoint random entries in all three queues;
the two settlement calls that spUSDC can make revert are wrapped and their reasons classified.

## (c) Unsettled

- The committed worktree does not contain the `review/poc-tests-v2` merge (blocked by the sandbox);
  the invariant files pass on both revisions, but the coordinator should run the merge and re-run
  the one-line command above to get the final line on the merged tree.
- `afterInvariant()` logs are printed once per invariant test (last run only), so ghost counters
  are sampled, not totals; the selector table is the exact coverage.
- H is only checked while the taker holds nothing and the rate order never broke; the random walk
  breaks the order in most runs (`rateOrderBroken` true in all 18 sampled last-runs), so H's
  effective coverage is the prefix of each run before the first order break. A dedicated run with
  the 1-in-8 branches removed would strengthen it.
- H treats realised losses as fictitious (the backing never leaves the harness), so it proves
  `realizeLoss` only ever widens the gap; a harness that burns the taker's spUSDC to model a real
  loss would be needed to test "loss realised == loss suffered".
- N-1 with large, non-uniform entries was not reproduced in the random walk; N-2 was.
- Donations of spPRIME to the vault (I-6) are excluded by design.
