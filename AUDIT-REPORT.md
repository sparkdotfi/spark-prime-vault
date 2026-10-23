# spPRIME (`src/SparkPrimeVault.sol`) review and testing campaign: final report, round 6

Target: `master` @ `c512609` ("test: Small fix and improve coverage (#51)", 2026-10-22), the code that is with the external auditors. Branch `review/poc-tests-v2` (PR #17), suite under `test/ai/`. Earlier rounds follow as appendices. Round 6 ports the whole suite to this master, pins every earlier finding as fixed or open, and covers the paths that are new since `0ebb452`: the seven-role model, custom errors, partial deposit cancellations with the self-skipping head, the per-entry liquidity bound in the redeem loop, the try/catch blacklist fallback, `totalClaimable`, the `(startId, length)` getters and the repacked storage.

## 1. Executive summary

1,022 tests across 18 suites, all passing, no deliberate failing proof left (the two C-1 proofs became regressions because the bug is fixed). 14 invariants held over 250,000 handler calls (500 runs x depth 500, 32 handler flows, 0 reverts), in the handlers / InvariantsBase / Invariants layout used by the other Spark vault repos. Coverage of `src/SparkPrimeVault.sol` by the suite (`forge coverage`, legacy pipeline; `Authorization`, `Admin`, `Upgrade`, `Adversarial` and `CancelAndFees` excluded because they hit the coverage compiler's stack limit, they run normally): 100% of lines (374/374), 100% of functions (64/64), 97.5% of statements (393/403), 97.6% of branches (161/165). The uncovered branches are the `_rpow` zero-base cases and the ERC-1271 decode fallbacks, which are unreachable through the public surface with a sane `vsr`.

Fixed since round 5 and pinned with `test_fixed_*` regressions: **C-1** (batched redeem fills no longer revert; the bound is recomputed per entry), **V2-13** for the vault (rejected as recipient on all six paths), **R5-9** in part (zero-asset requests are impossible, a cancelled head is skipped by the cancel itself, a budget-0 walk advances the head), **R4-A / R4-B** (fallback now by try/catch, same amounts), **C-8** (zero minimums rejected), cancellations and their settlement no longer pause-gated (the round-4 ask).

No Critical. Two things moved up because of the role split: `adjustTotalAssets` now sits on a `LOSS_MANAGER_ROLE` hot wallet with no bound in either direction, and the `OPERATOR_ROLE` holds both the rate and the queue processing.

| Severity | Count | Items |
|---|---|---|
| Critical | 0 | |
| High | 1 | R6-1 (`adjustTotalAssets` unbounded on a hot wallet: wipe holders, or let one holder drain the backing) |
| Medium | 4 | R6-2 (G-1 chi brick), R6-3 (gain sandwich around the pause, plus the cancel-during-pause free option), R6-4 (operator sets `MAX_VSR` and redeems first), R6-5 (F-2 backing not ring-fenced) |
| Low | 10 | R6-6 (uncancellable remainder below `minDepositCancellation`), R6-7 (unbounded self-skip walk), R6-8 (capacity overflow now bricks cancels too), R6-9 (redeem loop has no zero-share skip), R6-10 (redeem-head dust, per-entry bound double-floors), R6-11 (spUSDC as recipient donates), R6-12 (zero admin / last-admin renounce), R6-13 (bounds do not clamp live values), R6-14 (minimums unbounded above), R6-15 (1-wei and 2-wei dust entries) |
| Informational | 9 | section 4 |

Fix before the audit report lands, in this order (patches in section 7):

1. **R6-1.** Cap `adjustTotalAssets` relative to `totalAssets` in both directions, and bound `chi` by `type(uint256).max / RAY` (R6-2). Both are one line each.
2. **R6-6.** Exempt the emptying cancel from `minDepositCancellation` (`savingsShares_ == request.shares`), and document that the minimum is in spUSDC share units.
3. **R6-7.** Bound the self-skip walk at the end of `requestDepositCancellation` (a `maxRequests_` constant), and give the redeem loop the same `continue` on zero entries the deposit loop has (R6-9).
4. **R6-11.** Reject `savings` as recipient alongside `address(this)`.
5. **R6-3 / R6-4.** Operational: pause before the payload is public; keep the operator key cold or split `setVSR` from processing; cap `maxVSR` well under 100% APY.
6. **R6-8, R6-12, R6-13, R6-14.** `setCapacity` bound, `require(admin != 0)` plus two-step admin, clamp live values when bounds tighten, bound minimums.

## 2. Scope and method

Ten parallel workers on the local harness (`test/ai/LocalTestBase.t.sol`: real spUSDC `SparkVault` code behind a proxy over a 6-decimal `MockUSDC` whose blacklist reverts transfers like Circle's; minimums 1 wei so every amount stays reachable). Each worker ported its suite, pinned each prior finding, then covered every code path in its area including the new ones; one worker read the contract cold. Per-area reports with line maps on `c512609`: `test/ai/REPORT-<area>.md`. `test/ai/Headline.t.sol` is the one-file entry point.

| Suite | File | Tests | Fuzz |
|---|---|---|---|
| Headline reproductions | `Headline.t.sol` | 16 | 1 |
| Authorization / Admin | `Authorization.t.sol`, `Admin.t.sol` | 195 | 11 |
| Upgrade / Views / Review / Smoke | `Upgrade.t.sol`, `Views.t.sol`, `Review.t.sol` (fork, compile only), `LocalSmoke.t.sol` | 69 | 7 |
| Deposit and cancellation queues | `DepositQueue.t.sol`, `CancelledDepositQueue.t.sol` | 113 | 8 |
| Redeem queue | `RedeemQueue.t.sol` | 84 | 9 |
| Cancels and fees | `CancelAndFees.t.sol` | 96 | 8 |
| New surface / Blacklist / AdjustTotalAssets | `NewSurface.t.sol`, `Blacklist.t.sol`, `AdjustTotalAssets.t.sol` | 156 | 2 |
| Adversarial | `Adversarial.t.sol` | 142 | 11 |
| Rounding | `Rounding.t.sol` | 102 | 58 |
| Fresh eyes | `FreshEyes.t.sol` | 51 | 6 |
| Invariants | `invariants/Invariants.t.sol` (+ `InvariantsBase.t.sol`, `handlers/`) | 1 (14 invariants) | 250,000 calls |

Run: `FOUNDRY_OFFLINE=true forge test --match-path 'test/ai/*.t.sol'` (about 6 minutes with the default invariant config) and `FOUNDRY_OFFLINE=true FOUNDRY_INVARIANT_RUNS=500 FOUNDRY_INVARIANT_DEPTH=500 forge test --match-path 'test/ai/invariants/Invariants.t.sol'` (3 minutes). Fuzz properties were re-run at 20,000 runs by each worker.

## 3. What changed upstream (round 5 -> round 6)

- Roles: `DEFAULT_ADMIN_ROLE` (upgrade, max fee, minimums, VSR bounds), `LOSS_MANAGER_ROLE` (`adjustTotalAssets`), `OPERATOR_ROLE` (`setCapacity`, `setVSR`, the three `processPending*`), `PAUSER_ROLE`, `UNPAUSER_ROLE`, `REDEEM_FEE_SETTER_ROLE`, `TAKER_ROLE`.
- Custom errors throughout (ERC20 and permit strings unchanged); `ISparkPrimeVault` with NatSpec; `initialize` takes three non-zero minimums.
- `requestDepositCancellation(requestId, recipient, savingsShares)`: partial cancels, owner only, not pause-gated, ends with `_processPendingDeposits(0, max)` which walks cancelled entries at the head. `processPendingDepositCancellations` not pause-gated. `minDepositCancellation` in spUSDC share units.
- `_processPendingDeposits`: `continue` on cancelled entries before the `remaining_ == 0` break. `_processPendingRedeems`: `fillable_ = min(remaining_, convertToShares(availableLiquidAssets()))` per entry, `break` at 0.
- Blacklist fallback by `try/catch` on spUSDC `redeem` / `withdraw`; no `isBlacklisted` check; `totalClaimable` counter; `claim` decrements it.
- Vault rejected as recipient in every request and update path. Range getters `(startId, length)`. Events carry `requestId`. Storage: `rho`/`chi` packed in slot 7, `decimals` packed in slot 4, `totalClaimable` slot 18, `allowance` slot 28.

## 4. Findings (line numbers on `c512609`)

#### R6-1 · High (trust model, hot wallet) · `adjustTotalAssets` is unbounded in both directions
- **Location:** lines 262-283 (`LOSS_MANAGER_ROLE`, only `totalAssets_ > 0`, `chi != 0`, `chi <= uint192.max`).
- **Down:** `-(totalAssets - 1)` is accepted; on 1M + 100k of holders `chi` becomes 917,897,971,131,388, every `assetsOf` reads 0, the spUSDC backing is untouched and fully `take`-able. One `PAUSER` plus one `LOSS_MANAGER` key.
- **Up (new this round):** a gain is also unbounded, and the per-entry redeem bound (line 953) is the whole vault spUSDC, so after `+1e18` the first redeemer in the queue is paid everything: a 1,000 USDC position redeems 1,000,998,999,890 USDC (the other holder's 1M plus its own), the next redeem pays 0. On 1.1M TVL with a +1M write-up the key's own 100k position takes 190,909,090,907 and leaves 1,000,000,000,000 unpayable.
- **Why it moved up:** in round 5 this was the admin (a governance spell). Now it is a separate role that cannot be the spell if it is meant to react to losses, and no floor, cap, or delay exists.
- **Fix:** `require(|delta| <= totalAssets * MAX_ADJUST_RATE / WAD)` per call (10% or admin-set), or a timelock on the role.
- **Tests:** `AdjustTotalAssets.t.sol: test_BUG_C3_*`; `Admin.t.sol: test_BUG_C3_lossFloorAbsent_hotWalletsOnly`, `test_BUG_C3_gainUnbounded_hotWalletLetsOneHolderDrainBacking`; `Adversarial.t.sol: test_BUG_C3_lossManagerHotWallet_*` (2); `FreshEyes.t.sol: test_BUG_lossManager_unboundedGain_dustHolderDrainsAllBacking`; `RedeemQueue.t.sol: test_BUG_adjustTotalAssets_wipesQueuedRedeemer_C3`; `Headline.t.sol: test_BUG_H3_*`.

#### R6-2 · Medium · `chi` above `type(uint256).max / RAY` bricks the vault (G-1, unchanged, now a hot-wallet call)
- Line 280 bounds `chi` by `uint192` (~6.3e57); `drip` (line 655) and `nowChi` (line 846) multiply by `_rpow(vsr, dt) >= RAY` in uint256. Exact threshold unchanged: 115792089237316195423570985008687907853269984665640 drips, +1 panics one second later; `adjustTotalAssets` drips first so it cannot undo; same-block undo only; only an upgrade recovers. New consequence: `requestDepositCancellation` also reverts (its walk drips). Five workers re-derived the same number.
- **Fix:** `updatedChi_ <= type(uint256).max / _rpow(maxVSR, horizon)`.
- **Tests:** `AdjustTotalAssets.t.sol: test_BUG_G1_*`; `Admin.t.sol: test_BUG_G1_*` (4); `Rounding.t.sol: test_BUG_G1_*`; `Upgrade.t.sol: test_BUG_adjustTotalAssets_chiAboveRpowBoundBricksVault`; `FreshEyes.t.sol: test_BUG_adjustTotalAssets_chiAboveDripBound_bricksVaultPermanently`; `Headline.t.sol: test_BUG_H1_*`.

#### R6-3 · Medium (process) · Gains realised through `adjustTotalAssets` are capturable around the pause; cancels are a free option during it
- Unchanged numbers: 1M vault, 1M attacker deposit one block before the pause, +50k: profit 24,999,999,998 at 0% fee, 14,749,999,997 at 1%, the honest holder loses 25,000,000,000. New: because `requestDepositCancellation` is not pause-gated, a queued depositor who sees a loss coming can cancel out during the pause before `adjustTotalAssets` lands (`test_BUG_R5_2_queuedDepositorExitsDuringPauseBeforeLoss`).
- **Fix:** pause before publishing, or pin capacity in the same spell, or require a minimum pause duration before `adjustTotalAssets`; decide whether cancels should be allowed while paused.
- **Tests:** `Adversarial.t.sol: test_BUG_R3_1_*`; `AdjustTotalAssets.t.sol: test_BUG_R3_1_*`, `test_BUG_R5_2_*`; `FreshEyes.t.sol: test_BUG_adjustTotalAssets_gainSandwich_depositBeforePause`; `Headline.t.sol: test_BUG_H2_*`.

#### R6-4 · Medium · The operator sets the rate and processes the queue
- `OPERATOR_ROLE` holds `setVSR` (line 308, bounded only by `maxVSR`, which may be `MAX_VSR` = 100% APY) and `processPendingRedeems`. Own 1M deposit, `setVSR(MAX_VSR)` for one day, own redeem processed first: profit 1,900,837,676; the other holder is short 3,801,675,355 of backing. Ordering and capacity games alone extract nothing (`test_operator_orderingAndCapacity_cannotExtractValue`).
- **Fix:** a low `maxVSR` at launch (this is C-9 re-rated), or split rate-setting from processing.
- **Tests:** `Adversarial.t.sol: test_BUG_C9_operatorSetsMaxVsr_frontOfQueueProfit`; `Admin.t.sol: test_BUG_C9_*`.

#### R6-5 · Medium (design) · Queue backing is not ring-fenced (F-2, unchanged)
- `take` (line 289) ignores the pending counters; the per-entry redeem bound (line 953) is the vault's whole spUSDC, so redeem fills spend spUSDC owed to queued deposits and cancellations whenever notional exceeds backing; the operator decides who is paid. `take` works while paused.
- **Tests:** `Adversarial.t.sol: test_BUG_F2_*`, `test_pause_matrix`; `FreshEyes.t.sol: test_BUG_redeemsConsumeQueuedDepositBacking_cancellerStuck`; `DepositQueue.t.sol: test_priority_*`; invariant J (gap opened only by `take` or redeem fills).

#### Low

- **R6-6 (new)** · A remainder below `minDepositCancellation` cannot be cancelled: line 422 applies the minimum to every cancel including the emptying one, line 423 caps at the remainder, so a leftover from a partial cancel or a partial fill (e.g. 5,453,269 of 95,453,269 shares) returns `BelowMinDepositCancellation` for less and `SavingsSharesTooHigh` for more; only an operator fill releases it. Because `minDeposit` is USDC and `minDepositCancellation` is spUSDC shares, a `minDepositCancellation` above `convertToShares(minDeposit)` makes minimum-sized deposits uncancellable outright (100e6 shares = 104.76 USDC at the harness index). Fix: `require(savingsShares_ >= minDepositCancellation || savingsShares_ == depositRequest_.shares)`. `FreshEyes.t.sol: test_BUG_cancelRemainderBelowMinDepositCancellation_isUncancellable`; `Admin.t.sol: test_BUG_R6_1_*`; `CancelAndFees.t.sol: *_partialCancels_remainderBelowMinIsStuck`, `test_setMinDepositCancellation_isInSpUsdcShareUnits`.
- **R6-7 (new shape of R5-9)** · The self-skip walk at the end of `requestDepositCancellation` (line 445, `maxRequests_ = max`) only clears zero entries at the head and is charged to whoever triggers it. A griefer parks N `minDeposit`-sized request-then-cancel pairs behind a live head (each cancel is O(1)); the head owner's full cancel then walks them all at about 2,400 gas per slot (1,000 slots: 2,552,242 gas vs 153,513; ~12,500 slots exceed a block), and if the operator fills the head first, the next instant-filling depositor pays instead (200 slots: 750,964 vs 272,961). Escapes: a partial cancel is O(1); the operator pre-clears with `processPendingDeposits(0, k)`. Griefer cost ~360k gas per slot plus 1 wei. Fix: bound the walk. `Adversarial.t.sol: test_BUG_R6_1_selfSkipWalkChargedToHeadOwnerCancel_partialCancelEscapes`; `CancelAndFees.t.sol: test_BUG_requestDepositCancellation_deadEntriesBehindHeadMakeCancelUnboundedGas`; `DepositQueue.t.sol: test_BUG_cancelledRunBehindLiveHeadTaxesNextInstantFill`; `FreshEyes.t.sol: test_BUG_ghostsBehindLiveHead_fullCancelWalksThemAll`; `Upgrade.t.sol: test_BUG_H6_*`.
- **R6-8 (V2-7, wider)** · `setCapacity` is unbounded (now an operator call); above `totalSupply + type(uint256).max / nowChi()` the walk's `convertToAssets(availableCapacity())` (line 864) panics, which now also bricks `requestDepositCancellation` because it runs the walk: queued users can neither be filled nor leave until the operator lowers capacity. `FreshEyes.t.sol: test_BUG_setCapacity_uint256Max_bricksDepositFillsAndCancels`; `Rounding.t.sol: test_BUG_V2_7_capacityOverflow_alsoBricksRequestDepositCancellation`; `Admin.t.sol: test_BUG_V2_7_*`.
- **R6-9 (new)** · The redeem loop has no `continue` for zero-share entries (lines 950-973): an all-fee entry (`requestRedeem(1)` at any fee, only reachable with `minRedeem == 1`) is "filled" with a `maxWithdraw` read, `spUSDC.withdraw(0)` and a zero USDC transfer: 37,275 gas per ghost (about 800 per block) against ~2,400 for a deposit skip, and each consumes a `maxRequests_` slot. `CancelAndFees.t.sol: test_processPendingRedeems_gasWith500GhostEntries`; `Adversarial.t.sol: test_BUG_R6_2_*`; `RedeemQueue.t.sol: test_requestRedeem_oneShareAtAnyFee_zeroShareEntry_R5_14`.
- **R6-10 (R5-10, exact)** · The per-entry bound floors twice (`maxWithdraw`, then `convertToShares`), so the last entry of an exactly backed queue can be 1 share short, and a fully drained vault leaves 1-2 shares at the head behind 1 spUSDC wei that converts to 0 shares; every later call breaks at `fillable_ == 0` until outside spUSDC arrives. No revert. The per-entry clamp is strictly more conservative than the old one: 21 spUSDC with requests (1, 20) settled on `0ebb452` and now strands 1 + 1. `Rounding.t.sol: test_fixed_C1_perEntryClamp_strandsWhereSingleClampWasSafe`; `RedeemQueue.t.sol: test_BUG_*_unpayableDustAtHeadFreezesQueue_R5_10`; `FreshEyes.t.sol: test_BUG_partialFills_leaveUnpayableDustAtRedeemHead`; `Upgrade.t.sol: test_BUG_H4_dustAtHeadUnpayableUntilTopUp`.
- **R6-11 (V2-13 residual)** · `savings` is accepted as redeem and cancellation recipient and in the updaters; spUSDC's `withdraw` to itself is a USDC self-transfer that succeeds, so 999,999,999,998 USDC is donated to spUSDC with no claimable entry. One check next to `VaultIsRecipient` closes it. `RedeemQueue.t.sol`, `CancelAndFees.t.sol`, `DepositQueue.t.sol`, `Blacklist.t.sol`, `Upgrade.t.sol: *spUsdc*`.
- **R6-12 (V2-8)** · `initialize(..., address(0), ...)` accepted; the last admin can renounce; afterwards no role can ever be rotated, so the next lost hot key is permanent. `Admin.t.sol: test_BUG_V2_8_*`; `Upgrade.t.sol: test_BUG_H7_*`.
- **R6-13 (C-7)** · `setMaxRedeemFeeRate` and `setVSRBounds` do not clamp the live `redeemFeeRate` / `vsr`, and the admin cannot lower them itself (wrong role). `Admin.t.sol: test_BUG_C7_*`; `CancelAndFees.t.sol: test_BUG_setMaxRedeemFeeRate_belowCurrentFeeDoesNotClamp`.
- **R6-14 (C-8)** · Minimums reject zero but are unbounded above. `Admin.t.sol: test_BUG_C8_*`.
- **R6-15 (C-11, V2-11)** · A 1-wei deposit at `minDeposit == 1` mints 0 spUSDC shares and leaves an uncancellable zero-share slot (closed by `minDeposit >= ceil(chi_s / RAY)`); 2-wei deposits cancelled into 1-share entries cost the operator 35,453 gas each. `DepositQueue.t.sol: test_BUG_oneWeiDepositIsAGhostAndDonatesToSpUsdc`, `test_BUG_twoWeiCancellationsBloatQueue`; `Rounding.t.sol: testFuzz_C11_minDepositCeilChiS_closesDustRegion`.

#### Informational

- Range getters (lines 707, 755, 802) compute `length - startId` before `LengthTooLarge`, so `startId > length` panics 0x11; `(length, 0)` is a legal empty read, contrary to the NatSpec.
- NatSpec for `requestDepositCancellation` and `processPendingDepositCancellations` still says pause-gated; neither is. Both work while paused, including the fallback path; the cancel's walk drips but mints nothing.
- `adjustTotalAssets` at `totalSupply == 0` panics 0x12; `int256.max` panics 0x11 before `ChiTooHigh`. Relative-and-post-drip semantics: a spell computed off-chain overshoots by the interest accrued before execution.
- Vault itself blacklisted by Circle: clean payouts still work, deposits and `claim` die in USDC, and a blacklisted recipient at the head makes the fallback revert and block the walk until the owner repoints.
- Cancel-vs-fill race: a cancel for the full amount after an operator partial fill reverts `SavingsSharesTooHigh`; the owner must re-read.
- The try/catch surface is settled: USDC has no hooks so a contract recipient is always paid directly; a USDC-wide revert fails both legs and the batch reverts with nothing credited; a 63/64 gas starvation of the try leg cannot leave the catch leg with enough gas (scanned 30k-600k); `transferFrom` reorder only changes the revert reason when both balance and allowance are short.
- `Referral` is emitted at request time and inflated by request-then-cancel loops; the owner picks the refund recipient of each cancel slice.
- Dead slots count against `maxRequests_` in both loops; a batch stops at the first partial fill, so a second `(max, 1)` call can scrape floor dust.
- The V2 mock's comment says its appended variable is slot 28; it is 29.

## 5. Rounding table (round 6)

Re-pinned on `c512609` (full table in `test/ai/REPORT-rounding.md`): spUSDC `deposit` floors (line 388); the deposit fill floors twice (lines 883-884); the fee ceils (463); the redeem loop floors the per-entry bound then the assets (953, 958) and spUSDC `withdraw` ceil-burns, with `burn_i <= bal_i` proven for every entry so a batch cannot revert; cancellation settlement floors (924) under a `maxRedeem` budget; partial cancels move `savingsShares` verbatim, so the k-chunk refund loss (up to k-1 wei) is now user-reachable; `adjustTotalAssets` floors `chi` with the 1-wei per-call drift; `drip` matches the Python reference byte for byte. Capacity never over-mints at any index pair (20,000 runs, instant and batch, after a loss). Round trips lose `< 2 + c_s + c_p` wei.

## 6. Invariants

14 invariants (A-N) in `test/ai/invariants/`, mirroring the fork suite's layout on the local harness: sum of balances plus escrow == `totalSupply`; escrow == `pendingRedeemShares`; conversion formulas; pending counters == sums of the pending windows; head + window == requests made; vault USDC == `totalClaimable` == sum of `claimableAssets`; config bounds; capacity formula and `totalSupply <= maxCapacity` unless lowered; `chi`/`rho`/`drip` consistency; backing covers the queues unless `take` or a redeem fill opened the gap; roles intact; escrow == escrowed minus burned by fills; cumulative redeem payouts <= `convertToAssets` of the shares burned; cumulative refunds <= spUSDC value of the shares redeemed. Handlers only bound, prank, call and bump ghost counters; the two modifiers `chiNeverDecreases` and `headsNeverMoveBack` run on every call. `afterInvariant` settles everything from every end state (unpause, un-blacklist, return taken spUSDC and drained USDC, freeze rates, open capacity, drain all three queues, claim for all) and asserts supply, escrow, claimables, vault USDC and `totalAssets` all reach zero. Final run: 500 runs x depth 500 = 250,000 calls, 32 flows, 0 reverts.

## 7. Suggested code changes (round 6)

1. `adjustTotalAssets` (R6-1, R6-2):
```solidity
uint256 public constant MAX_ADJUST_RATE = 0.10e18;  // or admin-set

uint256 magnitude_ = deltaTotalAssets_ < 0 ? uint256(-deltaTotalAssets_) : uint256(deltaTotalAssets_);
require(magnitude_ <= totalAssets_ * MAX_ADJUST_RATE / WAD, AdjustmentTooLarge());
...
require(updatedChi_ <= type(uint256).max / _rpow(MAX_VSR, 10 * 365 days), ChiTooHigh());
```
2. `requestDepositCancellation` (R6-6, R6-7):
```solidity
require(
    savingsShares_ >= minDepositCancellation || savingsShares_ == depositRequest_.shares,
    BelowMinDepositCancellation()
);
...
_processPendingDeposits(0, MAX_SELF_SKIP);  // e.g. 50
```
3. `_processPendingRedeems`: `if (request_.shares == 0) continue;` before the bound (R6-9); optionally pay `divUp` shares when `convertToShares(availableLiquidAssets()) == 0` but `availableLiquidAssets() >= convertToAssets(request_.shares)` (R6-10).
4. One `_checkRecipient` rejecting `address(0)`, `address(this)` and `savings` (R6-11).
5. `setCapacity`: `require(capacity_ <= type(uint128).max)` (R6-8). `require(admin != address(0))` and two-step admin (R6-12). Clamp live values when bounds tighten (R6-13). Bound minimums and launch with `minDeposit >= ceil(chi_s / RAY)`, `minRedeem >= 2` (R6-14, R6-15).
6. NatSpec: pause gating of the cancellation paths; `length_ == 0` on the range getters; `LengthTooLarge` before the subtraction.

## 8. Open questions for the business team

36. Should `LOSS_MANAGER_ROLE` be a timelocked or governance key, and what per-call drawdown or write-up is acceptable?
37. Should cancellations stay open during a pause (free option before a loss) or be gated like the other requests?
38. Is the operator expected to hold both the rate and the processing, and what `maxVSR` will be set at launch?
39. Should `savings` be rejected as a recipient, or is the donation acceptable?
40. `minDepositCancellation`: share units are intended? Should the emptying cancel be exempt?

## 9. Limitations

Blacklist behaviour is mocked (the fork suite in PR #65 covers real USDC; the fork PoCs in `test/ai/Review.t.sol` compile but were not executed). Gas figures are cold-slot Foundry measurements. The G-1 threshold is exact at `vsr == RAY`. R6-10 is proven with a frozen spUSDC index. Four suite files hit the coverage tool's stack limit under instrumentation and were excluded from the coverage measurement only (they run normally).

---

# Appendix A00: round 5 report (`0ebb452`)

Target: `master` @ `0ebb452` ("refactor: More Cleanup (#26)", 2026-10-15), unpatched. Branch `review/poc-tests-v2` (PR #17), suite under `test/ai/`.
Earlier rounds follow as appendices. Round 5 was run overnight before the external audit hand-off and covers everything that changed between `bf93b0d` and `master`: the `adjustTotalAssets` rewrite, the blacklist fallback (`claimableAssets` / `claim`), the role split, the removal of guardian cancels and the queue-head changes.

## 1. Executive summary

857 tests across 33 suites: 855 pass, 2 are deliberate failing proofs (C-1). 28 invariants held over 500,000 handler calls each (1,000 runs x depth 500, 27 handler flows, 0 unexpected reverts); the random walk independently rediscovered R5-5 and shrank it to a 9-call sequence.

No new Critical or High in the code as written. The two biggest items are carried over and are both one-line bounds: `adjustTotalAssets` can still write a `chi` that bricks every dripping entry point (G-1, now with the exact threshold), and it still has no loss floor (C-3). The blacklist redesign fixed both round-4 Highs. The remaining material issue is a process one: gains realised through `adjustTotalAssets` are capturable by anyone who deposits between the spell being public and the guardian pausing.

| Severity | Count | Items |
|---|---|---|
| Critical | 0 | |
| High | 0 | |
| Medium | 5 | R5-1 (G-1 chi brick), R5-2 (gain sandwich, process), R5-3 (C-3 no loss floor), R5-4 (C-1 batched redeem revert), R5-5 (F-2 backing not ring-fenced; rebalancer picks who is paid) |
| Low | 10 | R5-6 (V2-8 admin), R5-7 (V2-13 vault/spUSDC recipients), R5-8 (V2-7 capacity overflow), R5-9 (ghosts / frozen head gas), R5-10 (redeem-head dust), R5-11 (C-7 bounds do not clamp), R5-12 (C-8 minimums), R5-13 (C-9 MAX_VSR), R5-14 (V2-9 / V2-11 ghosts and bloat), R5-15 (F-4 / C-11 zero mints and dust) |
| Informational | 11 | section 4 |

Fixed since round 4 and pinned with `test_fixed_*` regressions: R4-A and R4-B (blacklisted recipient no longer blocks a queue; payout parks in `claimableAssets`), R3-1 partially (`adjustTotalAssets` requires `paused`), V2-2 / F-1 (guardian cancel path removed), V2-1 (owner-only recipient updaters), G-2 (`uint192` wrap now reverts `chi-too-high`), vault as deposit recipient rejected, `transfer` to the vault rejected, dead event and unreachable checks removed.

Fix before the audit starts, in this order (patches in section 7):

1. **R5-1.** Bound `chi` in `adjustTotalAssets` by `type(uint256).max / RAY` (better: by `type(uint256).max / _rpow(maxVSR, horizon)`), not by `uint192`. Exact threshold: `chi = 115792089237316195423570985008687907853269984665640` drips for ten years, `+1` reverts one second later, and `adjustTotalAssets` cannot undo it because it drips first. Only an upgrade recovers.
2. **R5-2.** Decide the operational order for gains: guardian pauses before the payload is public, or pin capacity, or stream gains through the rate. At 1M TVL / 1M attacker / 50k gain the attacker takes 24,999.999998 USDC (14,749.999997 at a 1% fee) for one block of exposure.
3. **R5-3.** Add a relative floor to losses (`-delta <= totalAssets * MAX_LOSS / WAD`). `-(totalAssets - 1)` is accepted today and leaves every holder at 0 with the backing untouched.
4. **R5-4.** Budget `_processPendingRedeems` in spUSDC shares via `maxRedeem` and pay with `redeem`, as the cancellation queue already does; or re-clamp inside the loop. Minimal reproduction: 3401 spUSDC held, two entries, burn 3402, `SparkVault/insufficient-balance`. One-per-call works but strands 1 spUSDC wei and 2 shares.
5. **R5-7.** Reject `address(this)` and `savings` as redeem and cancellation recipients (and in the two updaters). Today 999,999,999,998 USDC parks in the vault with `claimableAssets == 0` and no path out.
6. **R5-6, R5-8, R5-11, R5-12.** `require(admin != 0)` and two-step admin; `require(capacity_ <= totalSupply + type(uint256).max / nowChi())` or a hard cap; clamp live `vsr` / `redeemFeeRate` when bounds tighten; bound minimums.
7. **Launch parameters.** `minDeposit >= 1e6`, `minRedeem >= 100`, fee > 0, `maxVSR` well under 100% APY; a rebalancer runbook for ghosts (`processPendingDeposits(1, N)` after capacity is opened) and for C-1 (one entry per call when a batch reverts).

## 2. Scope and method

Ten parallel workers, each owning one area in its own worktree, on the local harness (`test/ai/LocalTestBase.t.sol`: real spUSDC `SparkVault` code behind a proxy over a 6-decimal mock USDC that now carries a Circle-style blacklist the vault consults through `isBlacklisted`). Every worker first ported its suite to `master`, then pinned each previous finding as fixed or open, then attacked its area with new hypotheses; a tenth worker read the contract cold with no prior findings. Each worker's full report is in `test/ai/REPORT-<area>.md` (Round 5 section on top). `test/ai/Headline.t.sol` is an independent one-file reproduction of the headline items, written by the coordinator, for auditors to start from.

| Suite | File | Tests | Result |
|---|---|---|---|
| Headline reproductions | `test/ai/Headline.t.sol` | 10 | pass |
| Authorization / Admin | `test/ai/{Authorization,Admin}.t.sol` | 163 | pass |
| Upgrade / Views / Review / Smoke | `test/ai/{Upgrade,Views,Review,LocalSmoke}.t.sol` | 58 | pass (Review and the fork base compile only) |
| Deposit and cancellation queues | `test/ai/{DepositQueue,CancelledDepositQueue}.t.sol` | 100 | pass |
| Redeem queue | `test/ai/RedeemQueue.t.sol` | 60 | pass |
| Cancels and fees | `test/ai/CancelAndFees.t.sol` | 85 | pass |
| New surface / Blacklist / AdjustTotalAssets | `test/ai/{NewSurface,Blacklist,AdjustTotalAssets}.t.sol` | 103 | pass |
| Adversarial | `test/ai/Adversarial.t.sol` | 120 | pass |
| Rounding | `test/ai/Rounding.t.sol` | 95 | 93 pass, 2 deliberate failing proofs (C-1) |
| Fresh eyes | `test/ai/FreshEyes.t.sol` | 34 | pass |
| Invariants | `test/ai/invariants/` | 31 | pass (28 invariants x 1,000 runs x depth 500 + 3 units) |

Run: `FOUNDRY_OFFLINE=true forge test --match-path 'test/ai/*.t.sol'` (everything but invariants, about 10 s) and `FOUNDRY_OFFLINE=true forge test --match-path 'test/ai/invariants/d_invariants.t.sol'`.

## 3. What changed upstream (round 4 -> round 5)

- `realizeGain` / `realizeLoss` replaced by `adjustTotalAssets(int256)`: DEFAULT_ADMIN only, requires `paused`, drips first, `chi = (totalAssets + delta) * RAY / totalSupply`, checks `totalAssets_ > 0`, `chi != 0`, `chi <= type(uint192).max`.
- Blacklist handling: `requestRedeem`, `requestDepositCancellation` and the two payout updaters require `!asset.isBlacklisted(recipient)`; at payout time a blacklisted recipient's USDC is withdrawn to the vault and credited to `claimableAssets`; `claim(recipient)` is permissionless and pays the recipient.
- Roles: `RISK_MANAGER_ROLE` and `SETTER_ROLE` replaced by `REDEEM_FEE_SETTER_ROLE` and `VSR_SETTER_ROLE`; guardian can only pause; `requestDepositCancellation` is owner-only.
- Queues: no head-advance loop anywhere; the instant-fill predicate is `pendingDepositSavingsShares == savingsShares_` and the walk is `(max, max)`; `firstPendingDepositId` moves only inside `_processPendingDeposits` and only when `remaining_ != 0`.
- `transfer` / `transferFrom` reject the vault; `requestDeposit` rejects the vault as recipient; single-entry getters added; events renamed; storage layout reordered (the three arrays are now slots 0-2; full layout pinned in `test/ai/Upgrade.t.sol`).

## 4. Findings (line numbers on `0ebb452`)

#### R5-1 · Medium (admin input, irrecoverable) · `adjustTotalAssets` can brick every dripping entry point
- **Location:** `adjustTotalAssets` line 292 (`updatedChi_ <= type(uint192).max`), `drip` line 637 and `nowChi` line 811 (`_rpow(vsr, dt) * chi` in uint256).
- **What happens:** the only bound on the new `chi` is `uint192` (~6.28e57), but `drip`/`nowChi` multiply `chi` by `_rpow(vsr, dt) >= RAY` in uint256, so any `chi > type(uint256).max / RAY = 115792089237316195423570985008687907853269984665640` (~1.16e50) panics one second later. The `uint192` check is about 5.4e7 times too loose. Five workers measured the same threshold independently. After the write, `drip`, `nowChi`, `totalAssets`, `convertTo*`, `assetsOf`, `requestDeposit`, `requestRedeem`, all three `processPending*`, `setVSR` and `adjustTotalAssets` itself (it drips first, line 282) revert with panic 0x11; `transfer`, `approve`, `pause`, `claim` and `take` still work, so the backing can still be moved out. Only `upgradeToAndCall` to a chi-resetting implementation recovers; a second `adjustTotalAssets` in the same block also works (costs 2 wei). The bound shrinks with `vsr`: at `MAX_VSR` the RAY bound fails after one second. A second bound exists at `chi <= type(uint256).max / totalSupply` (line 640). Reaching it needs a delta of ~1.1e29 USDC at 1M supply, so this is an input-validation and fat-finger issue, not an exploit.
- **Fix:** `require(updatedChi_ <= type(uint256).max / RAY)` at minimum; better `<= type(uint256).max / _rpow(maxVSR, 10 years)` and a relative cap on the write-up.
- **Tests:** `Headline.t.sol: test_headline_H1_*`; `Admin.t.sol: test_BUG_G1_*` (4); `AdjustTotalAssets.t.sol: test_BUG_G1_*` (2); `Rounding.t.sol: test_BUG_G1_*` (3); `Upgrade.t.sol: test_BUG_adjustTotalAssets_chiAboveRpowBoundBricksVault`, `test_BUG_nowChi_exactRpowOverflowThreshold`, `test_BUG_adjustTotalAssets_chiBrickRecoverableOnlyInSameBlock`; `Adversarial.t.sol: test_BUG_G1_adjustTotalAssets_chiAboveDripBoundBricks_exactThreshold`.

#### R5-2 · Medium (process) · Gains realised through `adjustTotalAssets` are capturable by a deposit placed before the pause
- **Location:** `adjustTotalAssets` line 279 (`require(paused)`), `requestDeposit` lines 414-415 (instant fill at the old `chi`).
- **What happens:** the pause requirement closes the same-block sandwich, but the pause is a separate GUARDIAN transaction and the spell payload is public before it lands. A deposit that instant-fills in that window holds shares at the old `chi` and takes a pro-rata slice of the gain. 1M vault, 1M attacker, +50,000 gain: attacker exits with 1,024,999,999,998 (profit 24,999,999,998) at 0% fee and 1,014,749,999,997 (profit 14,749,999,997) at the 1% cap; the honest holder loses exactly 25,000,000,000. The take scales as `gain * c / (TVL + c)`. Pausing before the deposit kills it (`requestDeposit` reverts `paused`); pinning capacity before the payload is public also kills it (the queued deposit fills after the gain at the higher `chi`). A `maxRequests`-starved rebalancer only defers the payout, it does not remove the dilution. Gains stay "unassigned" in the backing: after the sandwich alice's claim exceeds the remaining backing by 49,999,999,999.
- **Fix:** operational (pause, then publish), or a capacity pin in the same spell, or stream gains through `vsr`. Alternatively require `paused` for a minimum duration before `adjustTotalAssets` can be called.
- **Tests:** `Headline.t.sol: test_headline_H2_*` (3); `Adversarial.t.sol: test_BUG_R3_1_*` (5), `test_fixed_R3_1_pauseBeforeDepositKillsSandwich`, `test_adjustTotalAssets_queuedDepositFilledAfterGainGetsNoProfit`; `AdjustTotalAssets.t.sol: test_BUG_R3_1_governanceSandwich_{zeroFee,onePctFee}`; `FreshEyes.t.sol: test_BUG_adjustTotalAssets_gainSandwich_depositBeforePause`; `Rounding.t.sol: test_R3_1_depositBeforePause_capturesProRataGain_quantified`.

#### R5-3 · Medium (trust model) · `adjustTotalAssets` has no loss floor
- **Location:** line 286 (`totalAssets_ > 0` only).
- **What happens:** `-(totalAssets - 1)` is accepted; `chi` becomes `floor(RAY / totalSupply)` (1,009,687,768,243,692 at the harness supply), `totalAssets()` and every `assetsOf` read 0 while the spUSDC backing is untouched and fully `take`-able; a year at `MAX_VSR` yields 1 wei. `chi-too-low` is only reachable above `RAY` shares. Escrowed redeem shares take the loss pro rata; queued spUSDC deposits do not. The admin is a spell, so this is a trust-model finding, but the floor is one line.
- **Fix:** `require(-deltaTotalAssets_ <= totalAssets_ * MAX_LOSS_RATE / WAD)` with a constant or admin-set rate.
- **Tests:** `Headline.t.sol: test_headline_H3_*`; `Admin.t.sol: test_BUG_C3_lossFloorAbsent`; `AdjustTotalAssets.t.sol: test_BUG_C3_*`; `RedeemQueue.t.sol: test_BUG_adjustTotalAssets_wipesQueuedRedeemer_C3`; `Rounding.t.sol: testFuzz_BUG_C3_*`; `Adversarial.t.sol: test_BUG_C3_*`.

#### R5-4 · Medium (liveness) · Batched redeem fills can revert on spUSDC ceil-rounding (C-1, unchanged)
- **Location:** `_processPendingRedeems` line 903 (bound computed once, in spPRIME shares, from `maxWithdraw`), line 922 (`withdraw(assets_)` per entry; spUSDC ceil-burns shares).
- **What happens:** across several entries the ceil-rounded spUSDC burns can exceed the vault's balance by up to `n - 1` wei, and the whole call reverts `SparkVault/insufficient-balance`. Minimal reproduction at harness indexes: 3401 spUSDC held, entries 108 + 3420 shares, burns 105 + 3297 = 3402. Fuzzed law (chi_s in [RAY, 10 RAY], chi_p in [RAY/1000, 10 RAY], n in [2, 4]): reverts iff the sum of ceil burns exceeds the balance; never for one entry; never when chi_s == RAY. Workaround: one entry per call, which strands 1 spUSDC wei and 2 spPRIME shares at the head and pays 2-8 wei less. Not reproducible while the vault is over-backed by its own deposits' floor rounding (the adversarial worker could not trigger it on a fully backed vault), so it bites only when liquidity is the binding constraint, which is exactly the stressed case.
- **Fix:** budget in spUSDC shares with `maxRedeem` and pay with `redeem`, mirroring `_processPendingDepositCancellations` (lines 869-888); or re-clamp `remaining_` inside the loop.
- **Tests:** `Headline.t.sol: test_headline_H4_*`; `Rounding.t.sol: test_BUG_C1_*` (3, two deliberately failing), `testFuzz_BUG_C1_*`, `testFuzz_C1_chiSEqualsRay_batchNeverReverts`; `RedeemQueue.t.sol: test_BUG_processPendingRedeems_batchRevertsOnCeilRounding_*`; `FreshEyes.t.sol: test_BUG_redeemBatch_ceilRounding_revertsWhenDrainingAllBacking`; `Adversarial.t.sol: test_C1_batchedRedeemNeverRevertsAtOrBelowFullBacking`.

#### R5-5 · Medium (design) · Queue backing is not ring-fenced; the rebalancer chooses who gets paid
- **Location:** `take` lines 340-349 (ignores the pending counters), `availableLiquidAssets` line 789 (all vault spUSDC), `_processPendingDeposits` line 852 (mints without reading the backing).
- **What happens:** known as F-2 and accepted by design for `take`. New this round: the rebalancer alone can produce the same state. After `take` leaves only a cancelled deposit's spUSDC in the vault, `processPendingRedeems` pays a redeemer 999,999,998 from it and the canceller's refund becomes unpayable; the reverse order refunds the canceller and starves the redeemer. After `takeAll`, deposits still instant-fill and mint unbacked shares that then back other people's exits. `take` is not pause-gated, so it works during an incident.
- **Exact scenario (invariant walk, shrunk to 9 calls):** alice deposits 1,000 USDC (backing 954,532,691 spUSDC); admin `adjustTotalAssets(+100e6)` while paused, so notional exceeds backing by 100 USDC; alice queues a full redeem; capacity equals supply so bob's 500 USDC deposit queues and bob cancels; `processPendingRedeems` budgets 1,350,552,523 shares against `maxWithdraw` 1,499,999,999 (bob's backing included) and pays alice 1,099,999,997; the vault keeps 381,813,078 spUSDC against 477,266,345 owed to bob; `processPendingDepositCancellations` pays bob 400,000,001 and 95,453,267 spUSDC stay pending at the head: bob is short 99,999,997 USDC with the vault at 0 spUSDC. Any state where notional exceeds backing (gain written up, spPRIME VSR above spUSDC VSR, capital taken) produces it.
- **Fix (if wanted):** bound the redeem budget and `take` by held spUSDC minus `pendingDepositSavingsShares + pendingCancelledDepositSavingsShares`; or document the trust assumption explicitly for the auditors.
- **Tests:** `invariants/d_invariants.t.sol: test_BUG_processPendingRedeemsSpendsCancellationQueueBacking`, invariant W/Z; `Adversarial.t.sol: test_BUG_F2_redeemsCanConsumeCancellationBacking_afterTake`, `test_taker_takeAll_thenThreeQueues`, `test_pause_matrix`; `FreshEyes.t.sol: test_BUG_redeemsConsumeQueuedDepositBacking_cancellerStuck`; `DepositQueue.t.sol: test_requestDeposit_instantFillAfterTakeAllStillMints`, `test_priority_*`.

#### Low

- **R5-6 (V2-8)** · `initialize(..., address(0))` is accepted and the last admin can `renounceRole` / revoke itself; proven while paused: paused forever, `take` still live. Add `require(admin != 0)` and a two-step admin. `Admin.t.sol: test_BUG_V2_8_*` (4); `Headline.t.sol: test_headline_H7_*`.
- **R5-7 (V2-13)** · `address(this)` and `savings` are accepted as redeem and cancellation recipients (lines 452, 425, 493, 508 only check the blacklist). `_canReceiveAsset(vault)` is true, so the USDC is withdrawn to the vault with no `claimableAssets` entry: 999,999,999,998 stranded on a 1M redeem, `claim` reverts `nothing-to-claim`, nothing moves it; spUSDC as recipient donates the payout to spUSDC. One check as on line 395 closes it. `Headline.t.sol: test_headline_H5_*`; `Blacklist.t.sol: test_BUG_V2_13_*` (3); `RedeemQueue.t.sol`, `CancelAndFees.t.sol`, `DepositQueue.t.sol`, `Adversarial.t.sol: *V2_13*`.
- **R5-8 (V2-7)** · `setCapacity` is unbounded; `convertToAssets(availableCapacity())` on line 829 overflows above `totalSupply + type(uint256).max / nowChi()` (~1.15e50), after which `requestDeposit` and `processPendingDeposits` panic until the admin lowers it. The real invariant couples capacity and `chi`. `Admin.t.sol: test_BUG_V2_7_*`, `test_setCapacity_coupledWithChi`; `FreshEyes.t.sol: test_BUG_setCapacity_uint256Max_bricksDepositFills`; `Upgrade.t.sol: test_BUG_availableCapacity_overflowInConvertToAssets`.
- **R5-9 (new)** · Capacity 0 freezes the deposit head: `remaining_ == 0` skips the loop (line 837) so cancelled and zero-asset entries pile up at and above the head; the next request that satisfies the predicate walks all of them `(max, max)` at about 2.3k gas per cold slot. 300 ghosts: 1,032,216 gas vs ~350k; about 12,700 ghosts exceed a 30M block and `requestDeposit` reverts for everyone until the rebalancer chunks with `processPendingDeposits(1, N)`, which only works once capacity converts to at least one spUSDC share. `minDeposit > 0` does not close it: request-then-cancel builds the same ghosts with recycled capital (1 wei per cycle). Griefer cost is ~80-130k gas per ghost, so bricking one victim transaction costs about 1e9 gas; a nuisance, not an exploit. `Headline.t.sol: test_headline_H6_*`; `DepositQueue.t.sol: test_BUG_ghostsAboveFrozenHeadTaxNextInstantFill`, `test_BUG_cancelledSlotsAboveHeadTaxNextInstantFillDespiteMinDeposit`, `test_processPendingDeposits_oneShareBudgetClearsGhostsOnlyWithCapacity`; `FreshEyes.t.sol: test_BUG_ghostEntries_*`; `Adversarial.t.sol: test_griefing_*`; `Upgrade.t.sol: test_getPendingDepositRequests_includesCancelledWhileCapacityIsZero`.
- **R5-10 (new, FE-1)** · Partial redeem fills can leave unpayable dust at the head: the per-call bound floors in spPRIME shares, the fill floors assets, spUSDC ceil-burns; after the last slice 1-2 shares stay at `firstPendingRedeemId` with `remaining_ == 0` on every later call until spUSDC arrives from outside, and the deficit migrates to the next redeemer (paid 1 wei short, own dust at the head). `FreshEyes.t.sol: test_BUG_partialFills_leaveUnpayableDustAtRedeemHead`; `Rounding.t.sol`, `RedeemQueue.t.sol: *manyPartialFills*`.
- **R5-11 (C-7)** · `setMaxRedeemFeeRate` and `setVSRBounds` do not clamp the live `redeemFeeRate` / `vsr`; the admin cannot lower them itself (wrong role) and a revoked setter leaves the old value in force. `Admin.t.sol: test_BUG_C7_*`, `test_revokeVsrSetter_rateStaysInForce`; `CancelAndFees.t.sol: test_BUG_setMaxRedeemFeeRate_belowCurrentFeeDoesNotClamp`.
- **R5-12 (C-8)** · Minimums unvalidated (`type(uint256).max` blocks all requests; `minRedeem` is gross of fee). `Admin.t.sol: test_BUG_C8_*`.
- **R5-13 (C-9)** · `MAX_VSR` doubles the notional in a year with no backing check (1,900.84 USDC/day on 1M). `Admin.t.sol: test_BUG_C9_*`.
- **R5-14 (V2-9, V2-11)** · `requestRedeem(0)` and `requestDeposit(0)` create permanent ghost entries that consume `maxRequests_` slots (about 2.4k gas each); 2-wei deposits cancelled into 1-share cancellation entries cost the planner ~27k gas each and delay real refunds by one slot each. `RedeemQueue.t.sol: test_BUG_requestRedeem_zeroSharesCreatesGhostEntry`; `DepositQueue.t.sol: test_BUG_twoWeiCancellationsBloatQueue`; `CancelAndFees.t.sol: testFuzz_requestRedeem_oneShareAtAnyNonzeroFeeIsFullyBurnedGhost`.
- **R5-15 (F-4, C-11)** · Exact regions re-pinned at arbitrary index pairs: deposits of `X <= floor((chi_s - 1) / RAY)` USDC buy 0 spUSDC shares (donated to spUSDC, ghost entry); fills of `s <= ceil((K + 1) RAY / chi_s) - 1` spUSDC shares mint 0 spPRIME shares and consume the head's shares for nothing; exact-fit capacity leaves 1 dust share at the head that switches everyone to queued mode. `Rounding.t.sol: testFuzz_BUG_F4_*`, `testFuzz_BUG_C11_*`; `DepositQueue.t.sol: test_BUG_dustFillMintsZeroShares`, `test_BUG_exactFitCapacityLeavesDustThatBlocksInstantFills`; `Adversarial.t.sol: test_BUG_F4_zeroShareMint_exactThreshold`.

#### Informational

- **Vault itself blacklisted by Circle:** deposits die in USDC, clean payouts still work (spUSDC pushes directly), but the blacklisted-recipient fallback (withdraw to the vault, line 955) reverts and that entry blocks the queue again (round-4 shape) until the owner repoints; `claim` is dead. `Blacklist.t.sol`, `CancelAndFees.t.sol`, `Adversarial.t.sol`, `FreshEyes.t.sol: *vaultBlacklisted*`.
- **`adjustTotalAssets` at `totalSupply == 0`** panics with division by zero (0x12) on a positive delta; `int256.max` and `1e60` panic 0x11 at line 289 before `chi-too-high`; `int256.min` reverts `loss-too-high`. Upstream's own test accepts the panic.
- **`adjustTotalAssets` is relative and post-drip:** a spell computed off-chain as "+1M" and executed three days late overshoots by 40,109,546,524 wei at 5% on 100M; gains are written up short by `< ceil(totalSupply / RAY)` wei; loss + gain round trips lose 1-2 wei per call (V2-12). `FreshEyes.t.sol: test_info_adjustTotalAssets_relativeDelta_spellLagDrift`; `Rounding.t.sol: *V2_12*`.
- **Blacklist is a liveness mechanism, not compliance:** only recipients are checked; a blacklisted holder or depositor exits through `updateRedeemRecipient`, a clean recipient or `transfer`; a blacklisted deposit recipient still receives and can transfer shares. Same posture as spUSDC. `Blacklist.t.sol`, `FreshEyes.t.sol: test_info_blacklistedOwner_*`.
- **Claimable USDC** is invisible to `totalAssets` / `availableLiquidAssets` and is untouched by `requestDeposit`, `take`, `adjustTotalAssets`, pause and every queue; `claim` zeroes before transferring, works while paused, and reverts in USDC while the recipient is still blacklisted with the credit retained. Proven exhaustively; no issue found in `claim` itself.
- **Cancel vs fill ordering:** the rebalancer (or an instant walk) can fill a request in the block before its owner's cancel lands; the owner is then in spPRIME with a 1% fee and a liquidity-bound exit, with no defence. `CancelAndFees.t.sol: test_processPendingDeposits_frontRunsCancel_ownerHasNoDefence`.
- **Dead slots cost the planner:** cancelled and ghost entries count against `maxRequests_` (lines 835, 840) and a cancelled head is never skipped on cancel; a 1-request batch after a cancel fills nobody.
- **The cancellation queue is a fee-free spUSDC-rate position** without capacity: 1,000 in, 1,099,999,998 out after a year at 10% spUSDC VSR. spPRIME itself has no fee-free exit.
- **`Referral`** is emitted at request time with any recipient and never reconciled; request-then-cancel loops inflate referred volume for 1 wei each.
- **`requestRedeem(1)`** at any non-zero fee is a 100% fee plus a ghost; `minRedeem >= 100` at the 1% cap removes it. `minRedeem` is gross of fee.
- **`requestDepositCancellation(id >= length)`** panics 0x32 instead of a clean revert. `permit` accepts the high-s twin of a signature (nonce makes it harmless).
- **Comment on the V2 mock** says slot 27 for the appended variable; it is 28 (`allowance` is 27). Mock only.

## 5. Rounding table (round 5)

Every site keeps its direction on `0ebb452` (full table with formulas in `test/ai/REPORT-rounding.md`): spUSDC `deposit` floors; `_processPendingDeposits` floors twice (spUSDC `convertToAssets`, then `convertToShares`); `requestRedeem` fee ceils; `_processPendingRedeems` floors assets, spUSDC `withdraw` ceil-burns against the vault; `_processPendingDepositCancellations` floors (spUSDC `redeem`) against the canceller; `adjustTotalAssets` floors `chi`; `drip` matches the Python reference table (112 rows, byte-identical). Capacity can never be over-minted by one share at any index pair (fuzzed 20,000 runs, chi_s in [RAY, 10 RAY], chi_p in [RAY/1000, 10 RAY], capacity in [1, 1e12]). Round trips lose `< 2 + c_s + c_p` wei (4 at the harness indexes). Overflow bounds: `convertToAssets` panics iff `shares > type(uint256).max / chi`; `_rpow(MAX_VSR, dt)` reverts from `dt = 2,416,158,483 s` (76.6 years); the `uint192` casts in `drip` / `nowChi` never truncate.

## 6. Invariants

28 invariants, each over 1,000 runs x depth 500 = 500,000 handler calls, 0 handler reverts outside the classified allow-list (755 s). 27 handler flows drawn uniformly, including the new surface: `adjustTotalAssets` with bounded positive and negative deltas while paused, USDC blacklisting and un-blacklisting of users and recipients, `claim`, recipient updates to blacklisted and clean addresses, cancellation processing, `take` and return, spUSDC liquidity drain and return, VSR changes on both vaults, capacity cuts below supply, minimum and fee changes.

Held (letters as in `test/ai/REPORT-invariants.md`): A sum of balances plus escrow == `totalSupply`; B escrow == `pendingRedeemShares`; C/D/Q each pending ledger == sum of its open entries; E/V heads never move backwards and never exceed length; F/X no mint above capacity unless capacity was lowered; G `chi` moves only in warps and `adjustTotalAssets`, `drip` == `nowChi`; H solvency against the deficit ledger while the rate order holds; I/K USDC conserved, vault USDC == sum of `claimableAssets` after every call (exact); N spUSDC shares conserved; W a backing gap is opened only by `take` or by redeem fills (R5-5); M zero-share fills counted (3 in 14,000 sampled calls); O/P processing never reverts except the classified C-1 class (0 hits); Y every payout is exactly the floor conversion (excess 0); R/S recipient updates move only the recipient, strangers always rejected; T `adjustTotalAssets` accounting within 1 wei, zero-supply panics; U escrow leaves only through fills; AA `claim` never pays while blacklisted and pays exactly after; AB 0 unexpected reverts; Z settle-everything terminal: after un-blacklisting everyone and restoring liquidity, the deposit queue empties, every claimable balance is paid, the vault's USDC goes to 0, and the unpaid cancel plus redeem remainder is bounded by the deficit ledger.

Sampled counters: 182 negative / 178 positive adjustments, 123 `not-paused` probes rejected, 39 zero-supply probes panicked, 327 blacklist sets / 165 clears, 181 blacklisted-recipient probes rejected, 53 fills parked in `claimableAssets`, 35 claims paid, 26 claims rejected while blacklisted with state unchanged, 407 takes, 90 capacity cuts below supply, 0 C-1 reverts.

## 7. Suggested code changes (round 5)

1. `adjustTotalAssets` (R5-1, R5-3):
```solidity
uint256 constant MAX_LOSS_RATE = 0.10e18; // or admin-set

require(
    deltaTotalAssets_ >= 0 ||
    uint256(-deltaTotalAssets_) <= totalAssets_ * MAX_LOSS_RATE / WAD,
    "SparkPrimeVault/loss-too-high"
);
...
require(updatedChi_ <= type(uint256).max / _rpow(MAX_VSR, 10 * 365 days), "SparkPrimeVault/chi-too-high");
```
   (`type(uint256).max / RAY` is the minimum that stops the brick; the `_rpow` form also covers accrual.)
2. `_processPendingRedeems` (R5-4): budget in spUSDC shares via `IERC4626Like(savings).maxRedeem(address(this))` and pay with `redeem`, as `_processPendingDepositCancellations` does; or recompute `remaining_ = _min(remaining_, convertToShares(availableLiquidAssets()))` at the top of each iteration.
3. One `_checkRecipient` rejecting `address(0)`, `address(this)` and `savings`, used in `requestRedeem`, `requestDepositCancellation` and the three updaters (R5-7).
4. `require(admin != address(0))` in `initialize`; use OZ `AccessControlDefaultAdminRules` or an equivalent two-step admin (R5-6).
5. `setCapacity`: `require(capacity_ <= type(uint128).max)` (R5-8). Bound setters clamp live values (R5-11). `setMinDeposit` / `setMinRedeem` bounded (R5-12). `maxVSR` constant well under 100% APY (R5-13).
6. `require(savingsShares_ != 0)` in `requestDeposit` and `require(queuedShares_ != 0)` in `requestRedeem` (R5-14, R5-15).
7. Gains (R5-2): either an operational rule (pause before the spell payload is public, or pin capacity in the same spell) or `require(block.timestamp >= pausedAt + MIN_PAUSE)` in `adjustTotalAssets`.
8. Optional (R5-5): make `take` and the redeem budget respect `pendingDepositSavingsShares + pendingCancelledDepositSavingsShares`, or document the trust assumption.

## 8. Open questions for the business team

31. Gains through `adjustTotalAssets`: is the operational order (pause, then publish) guaranteed, or should the contract enforce a minimum pause before an adjustment?
32. Loss floor: what per-call drawdown is acceptable for a hot-wallet-free spell? 10%? Admin-set?
33. Is the rebalancer allowed to pay redeemers out of spUSDC that backs queued deposits and pending cancellations (R5-5), or should those be ring-fenced?
34. Should the vault and spUSDC be rejected as payout recipients, or routed through `claimableAssets`?
35. Runbooks: ghosts (`processPendingDeposits(1, N)` after capacity is opened), C-1 (one entry per call), and the vault-blacklisted scenario (owner repoints).

## 9. Limitations

Blacklist behaviour is mocked (a fork test against `FiatTokenV2` is still recommended; the fork PoCs in `test/ai/Review.t.sol` compile but were not executed, no `MAINNET_RPC_URL`). Gas numbers are Cancun cold-slot measurements via `vm.cool`. The R5-1 threshold is exact at `vsr == RAY`; with accrual the bound is lower. R5-10 is proven with a frozen spUSDC index only. R5-2 exploitability depends on off-chain ordering.

---

# Appendix A0: round 4 report (`bf93b0d`)

Target: `fix/update-guardian-transfer` @ `bf93b0d` (2026-10-14), unpatched. Branch `review/poc-tests-v2`, suite under `test/ai/`.
Earlier rounds follow as appendices. Round 4 covers the guardian-refund fix and the removal of `cancelRedeemRequest`.

## 1. Executive summary

627 tests across 16 suites: 626 pass, 1 is a deliberate failing proof (C-1). 21 invariants held over 50,000 handler calls each. The guardian-redirect bug (F-1) is closed on both sides: deposit cancels by the guardian must refund the owner, and redeem cancels no longer exist. Removing the cancel also closed the free exit option and the free capacity hog, but it turned the blacklisted-recipient block from a guardian-fixable nuisance into a permanent freeze of all exits.

| Severity | Count | Items |
|---|---|---|
| Critical | 0 | |
| High | 3 | R4-A (permanent redeem-queue block), R3-1 (`realizeGain` sandwich), C-3 (`realizeLoss` floor) |
| Medium | 5 | R4-B (cancellation-queue block, zero fee), C-1, V2-7, V2-8, F-2 (design) |
| Low | 13 | V2-9..V2-14, C-7, C-8, C-9, C-11, G-1, G-2, DQ-10 |
| Informational | 15 | see section 4 |

Fixed or closed since round 3: V2-2 (F-1 regression, both sides), E-2 free option (requests are final), C-10 capacity hog (now costs the position), I-3 (`UNPAUSER_ROLE` removed).

Fix before the external campaign, in this order (patches in section 7):

1. **R4-A High.** One queued redeem to a USDC-blacklisted recipient blocks every exit behind it. With cancels gone, only the request owner can repoint it; guardian, admin and rebalancer have no tool; pause does not help. Cost at launch defaults: 1 share, refunded on release, so it is repeatable. Fix: guardian repoint-to-owner with a one-way lock, plus a way to park an entry whose owner is itself blacklisted.
2. **R4-B Medium.** Same shape on the cancellation queue, where no fee is charged: cancel a queued `minDeposit` to a blacklisted refund address and every pending refund is stuck. Same fix.
3. **R3-1 High.** `realizeGain` is sandwichable; upstream's own TODO notes the admin is a spell with a public payload, so the front-run is deterministic. Require `paused`.
4. **C-3 High (trust model).** `realizeLoss(totalAssets - 1)` still wipes holders in one hot-wallet call. Cap the per-call write-down.
5. **C-1 Medium.** Batched redeem revert on spUSDC ceil-rounding; the cancellation queue now shows the safe pattern.
6. **V2-7, G-1, G-2.** Restore the capacity bound; bound `realizeGain` so it cannot brick `drip` or wrap the cast.
7. **Hygiene.** Delete the dead `CancelRedeemRequest` event; fix the stale overflow comment in `drip`; reject the vault and spUSDC as recipients; reject zero-share requests; launch with `minDeposit >= 1e6`, `minRedeem >= 100`, fee > 0.

## 2. Scope and method

Five workers, one or two files each, each with a "Round 4" section in its `test/ai/REPORT-*.md`. Harness unchanged. Fork PoCs ported, compile, not executed.

| Suite | File | Tests | Result |
|---|---|---|---|
| New surface | `test/ai/NewSurface.t.sol` | 55 | pass |
| Cancelled-deposit queue | `test/ai/CancelledDepositQueue.t.sol` | 22 | pass |
| Views | `test/ai/Views.t.sol` | 7 | pass |
| Deposit queue | `test/ai/DepositQueue.t.sol` | 62 | pass |
| Redeem queue | `test/ai/RedeemQueue.t.sol` | 49 | pass |
| Cancels and fees | `test/ai/CancelAndFees.t.sol` | 63 | pass |
| Invariants | `test/ai/invariants/` | 23 | pass (100 runs x depth 500) |
| Adversarial | `test/ai/Adversarial.t.sol` | 102 | pass |
| Rounding | `test/ai/Rounding.t.sol` | 71 | 70 pass, 1 deliberate fail (C-1) |
| Authorization / Admin / Upgrade | `test/ai/{Authorization,Admin,Upgrade}.t.sol` | 171 | pass |
| Harness smoke | `test/ai/LocalSmoke.t.sol` | 2 | pass |

## 3. What changed upstream (round 3 -> round 4)

- Guardian `requestDepositCancellation` must pass `recipient_ == request_.owner` (`invalid-recipient`), checked after `not-authorized`. Owner path unchanged.
- `cancelRedeemRequest` removed. A redeem request is final; `updateRedeemRecipient` (owner only) is the only user action. The `CancelRedeemRequest` event is still declared and never emitted.
- View functions reordered; no storage change (27 slots, verified).

## 4. Findings (line numbers on `bf93b0d`)

#### R4-A · High · A blacklisted redeem recipient blocks the queue permanently; only the owner can clear it
- **Location:** `_processPendingRedeems` line 909 (`withdraw` to `request_.recipient` inside strict FIFO, no skip), `updateRedeemRecipient` line 514 (owner only), no cancel.
- **What happens:** attacker deposits, queues `minRedeem` shares to a blacklisted address, honest users queue behind. Every `processPendingRedeems` call reverts for any `maxRequests`; guardian, admin, rebalancer and risk manager get `not-authorized` on the updater; pause adds `paused` and the jam survives unpause; `take`, `realizeLoss`, `realizeGain` do not move the queue. A year later the honest users are still unpaid and cannot leave (finality). When the attacker repoints, the next pass pays them 1 wei and clears the queue; they re-jam at once. A jam at index 1 behind a live head makes `(max, 10)` revert too, so the planner must size batches to stop exactly before each jam.
- **Cost:** fee on `minRedeem` shares plus gas; escrow refunded on release. 1 share at `minRedeem = 0`, fee 0; about 10 USDC at `minRedeem = 1,000e6` and 1%.
- **Honest variant:** a redeemer blacklisted after queueing can self-rescue by repointing; the call moves no tokens and works while paused.
- **Fix:** guardian repoint-to-owner with a one-way lock (section 7); plus a park or skip for an owner who is itself blacklisted.
- **Tests:** `test_BUG_blacklistedRecipientBlocksRedeemQueuePermanently`, `..._withMinRedeemAndFee`, `test_BUG_blacklistedRecipient_latentJamForcesExactBatchSizing`, `test_BUG_blacklistedRedeemRecipient_costIsFeeOnMinRedeemOnly`, `test_updateRedeemRecipient_blacklistedOwnerSelfRescuesQueue`.

#### R4-B · Medium · The cancellation queue can be blocked at zero fee
- **Location:** `requestDepositCancellation` line 409 (owner names any recipient), `_processPendingDepositCancellations` line 869 (`redeem` to recipient, strict FIFO), `updateDepositCancellationRecipient` line 500 (owner only).
- **What happens:** with the vault full, attacker queues `minDeposit`, victim queues behind; attacker cancels to a blacklisted address, victim cancels to self. Every settlement call reverts; no third party can repoint; attacker repoints when convenient, is refunded 999,999 of 1,000,000, and re-jams with the same dollar. Cost: gas.
- **Fix:** same as R4-A.
- **Test:** `test_BUG_blacklistedCancelRecipientBlocksCancellationQueue_zeroFee`.

#### R3-1 · High · `realizeGain` sandwich (unchanged)
- Line 293; upstream TODO at lines 290-292 confirms the admin is a spell with a public payload. Numbers unchanged: 1M vault, 1M attacker capital, 50,000 gain: attacker profit 24,999.999998, honest holder loses exactly that; 14,750 net of a 1% fee. Removing cancel changed nothing (the exit was always through the queue). Tests: `test_BUG_realizeGain_sandwich*`, `test_realizeGain_pauseBeforeGainKillsSandwich`.

#### C-3 · High (trust model) · `realizeLoss` has no floor (unchanged)
- Line 372: `loss < totalAssets` only. `totalAssets - 1` leaves `chi = floor(RAY / S)`, holders at 0, `realizeGain` the only repair. Tests: `test_BUG_realizeLoss_noFloor_totalAssetsMinusOneWipesHolders`, `test_realizeLoss_fullLossRejected`.

#### C-1 · Medium · Batched redeem revert on spUSDC ceil-rounding (unchanged)
- Lines 886 and 909. Chunking also costs the redeemer: 13 chunks on a 100k request pay 8 wei less than one fill and strand 2 shares behind 1 wei of spUSDC. Tests: `test_BUG_processPendingRedeems_batchCeilBurnsExceedSpUsdcBalance` (deliberately failing), `test_BUG_processPendingRedeems_batchRevertsOnCeilRounding_*`, `test_processPendingRedeems_manyPartialFills_sumNeverExceedsOneFill`.

#### V2-7 · Medium · `setCapacity` unbounded (unchanged). V2-8 · Medium · last admin can renounce, zero admin at init (unchanged).

#### F-2 · Medium (design) · Queues not ring-fenced; the rebalancer is the single point of exit
- After `take()`, fills still mint and refunds wait silently. New this round: with no cancel, a missing rebalancer locks every queued dollar in all three queues; no role can release it except by granting `REBALANCER_ROLE` to a new address, which then pays everything in two calls. Tests: `test_compromised_rebalancer_starvedUsersAreLockedInAllThreeQueues`, `test_requestRedeem_isFinal_noPathRecoversEscrow`.

#### Low

- **V2-9** `requestRedeem(0)` ghosts, now permanent. **V2-10** unbounded head walk in the deposit cancel (~2,900 gas per ghost). **V2-11** cancellation-queue bloat with 2-wei deposits (~18k planner gas per entry). **V2-12** `realizeLoss` / `realizeGain` off by 1 wei per call. **V2-13** vault and spUSDC accepted as recipients everywhere (self-harm now). **V2-14** dust at the deposit head switches everyone to queued mode. **C-7** tightened bounds do not clamp live values. **C-8** minimums unvalidated. **C-9** SETTER at MAX_VSR over-credits ~0.19%/day. **C-11** deposits below one spUSDC share are donated to spUSDC. **G-1** `realizeGain` above ~1.15e29 USDC bricks `drip` one second later, irrecoverable. **G-2** `realizeGain` casts to `uint192` unchecked; a large enough gain wraps `chi` to dust and the event reports it as a gain. **DQ-10** owner can repoint a refund to the vault and strand it (`test_updateDepositCancellationRecipient_toVaultStrandsRefund`).

#### Informational

- `CancelRedeemRequest` event declared, never emitted. The `drip` overflow comment ("limited to maxUint256/RAY") only holds with the G-1 bound. `Deposit` event's fourth parameter is misnamed. `no-shares` in `realizeLoss` is unreachable.
- Guardian deposit cancel is blocked while paused, so the compliance tool is unavailable exactly during an incident.
- `requestRedeem(1)` at any non-zero fee is a 100% fee and a ghost; `minRedeem >= 100` at the 1% cap removes it.
- `Referral` is spoofable for any recipient (the caller chooses `recipient_`).
- `transfer(address(vault))` parks shares outside the escrow forever (I-6).
- After a loss takes `chi` below RAY, small redeems pay 0 and headroom under one USDC wei is unfillable; no over-mint is possible (proven).
- The redeem head never walks (no cancel-time walk), so a ghost at the head costs a `maxRequests` slot.
- `uint192` casts enumerated: only `realizeGain` can wrap.
- Cancellation-queue settlement at exact liquidity strands 1 wei per call (`maxRedeem` floors).
- `minRedeem` is gross of fee and drifts up in USDC terms.
- Fork PoCs compile against the new API but were not executed.

## 5. Rounding table (round 4)

All rows re-pinned at `bf93b0d`; no direction changed. The after-loss regime (`chi < RAY`) adds no new direction: the capacity chain stays a floor composition and cannot over-mint; the F-4 zero-mint region is empty there. Full table in `test/ai/REPORT-rounding.md`.

## 6. Invariants (21, all held, 100 runs x depth 500, 0 handler reverts)

A..T as in round 3, with J's redeem-cancel term removed and the guardian cancel handler probing `invalid-recipient` before every call; plus **U** the vault's escrow balance never decreases outside `processPendingRedeems`.

## 7. Suggested code changes (round 4)

1. Guardian repoint with a one-way lock, in `updateRedeemRecipient` and `updateDepositCancellationRecipient` (R4-A, R4-B). Do not transfer ownership to the guardian: that reopens F-1 on the second call.
```solidity
if (msg.sender == request_.owner) {
    require(!recipientLocked[requestId_], "SparkPrimeVault/recipient-locked");
} else {
    require(hasRole(GUARDIAN_ROLE, msg.sender), "SparkPrimeVault/not-authorized");
    require(recipient_ == request_.owner,       "SparkPrimeVault/invalid-recipient");
    recipientLocked[requestId_] = true;
}
```
   Plus a guardian `park` (move the entry out of the FIFO path) or a try/catch skip for the case where the owner itself is blacklisted.
2. `realizeGain`: `require(paused)`; compute `chi_` in `uint256` and `require(chi_ <= type(uint256).max / RAY)` before the cast (R3-1, G-1, G-2).
3. `realizeLoss`: cap the per-call loss, e.g. `loss_ <= totalAssets_ * MAX_LOSS_RATE / WAD` with a 10% constant or an admin-set rate (C-3).
4. `_processPendingRedeems`: re-clamp `remaining_` to `convertToShares(availableLiquidAssets())` inside the loop, or mirror the cancellation queue (`maxRedeem` budget, `redeem` payout) (C-1).
5. `setCapacity`: `require(capacity_ <= type(uint128).max)` (V2-7).
6. `require(shares_ != 0)` in `requestRedeem`; `require(savingsShares_ != 0)` in `_requestDeposit`; one `_checkRecipient` rejecting `address(0)`, `address(this)` and `savings`, used in both requests and all three updaters (V2-9, V2-13, C-11, DQ-10).
7. Delete `event CancelRedeemRequest`; fix the `drip` comment; rename the `Deposit` event parameter; drop the unreachable `no-shares` check in `realizeLoss`.
8. Carry-overs: clamp live values in bound setters (C-7), bounds on minimums (C-8), `require(admin != address(0))` in `initialize` and two-step admin (V2-8), `maxVSR` 10-15% APY (C-9), launch `minDeposit >= 1e6`, `minRedeem >= 100`, fee > 0.

## 8. Open questions for the business team

Earlier questions remain (appendices). New or changed:
27. Compliance on queued redeems: with cancels gone the guardian has no tool. Repoint-to-owner with a lock, park, or pause-all?
28. Failed payouts: skip, park, or pay the owner, for both the redeem and the cancellation queue?
29. The rebalancer is the single point of exit for all three queues. Is a permissionless `processPending*` fallback after a delay wanted?
30. `realizeGain` under a spell is a guaranteed transfer to whoever holds at that block. Pause-gate it or stream it through the rate?

## 9. Limitations

Blacklist behaviour is mocked; a fork test against real USDC is recommended. Fork PoCs not executed. Invariant H covers the prefix of each run before the rate order breaks. Netting is not on this branch.

---

# Appendix A: round 3 report (`9269fe0`, with `072e8d0` and `731c1c8` notes)


> **Update for `731c1c8` (2026-10-14):** the review suite now lives under `test/ai/` (paths in the per-worker reports are relative to that directory). Upstream renamed the planner calls to `processPendingDeposits`, `processPendingRedeems`, `processPendingDepositCancellations`, dropped the unused `UNPAUSER_ROLE` (closes I-3 / V2-18), changed `Take` to `Take(uint256 shares)`, removed its own `test/QueueAudit.t.sol`, and added a code comment acknowledging that `realizeGain` is front-runnable (R3-1). Suite: 595 tests, 594 pass, 1 deliberate failing proof. Findings otherwise unchanged.

> **Update for `072e8d0` (2026-10-14):** pure renames and read-only additions, no behaviour change. `cancelDepositRequest` is now `requestDepositCancellation`, `updateCancelledDepositRecipient` is `updateDepositCancellationRecipient`, events `DepositCancellationRequest` / `DepositCancellationRecipientUpdated`, heads are `firstPendingDepositId` / `firstPendingDepositCancellationId` / `firstPendingRedeemId`. The queue arrays became internal; new views `getPending{Deposit,DepositCancellation,Redeem}Requests()` (head to end) and `(startId, endId)` (any range, `invalid-range` past the end) replace the public array getters. Suite re-based on the new names plus `test/Views.t.sol` (6 tests): 603 tests, 602 pass, 1 deliberate failing proof. Findings and severities unchanged from round 3.


Target: upstream `refactor/more-simplifying` @ `9269fe0` (2026-10-14), unpatched. Branch `review/poc-tests-v2`.
Rounds 2 and 1 are kept below as appendices. Round 3 covers the pushes `ff828d2` (owner-only recipient updaters, `realizeLoss` bounds, cancelled-queue budget via `maxRedeem`, new `realizeGain`) and `9269fe0` (rename of `redeemFee` to `redeemFeeRate`).

## 1. Executive summary

597 tests across 15 suites: 596 pass, 1 is a deliberate failing proof. 20 invariants held over 50,000 handler calls each. The push fixed the Critical and two Mediums from round 2 and added one new High.

| Severity | Count | Items |
|---|---|---|
| Critical | 0 | |
| High | 3 | R3-1 (new), V2-2 (F-1 regression, still open), V2-3' (`realizeLoss` floor) |
| Medium | 5 | V2-4 (C-1), V2-5 (C-2), V2-7, V2-8 (C-4), F-2 (design) |
| Low | 13 | V2-9..V2-14, C-7..C-11, G-1, G-2 |
| Informational | 11 | see section 4 (I-3 closed at `731c1c8`) |

Fixed by the push (regression tests now pin the fix): V2-1 Critical (recipient updaters are owner-only and reject dead entries), V2-3 brick (full loss rejected, `chi` can no longer reach zero at 6-decimal supply), V2-6 (cancelled-queue settlement budgets by `spUSDC.maxRedeem`, pays what liquidity allows, proven batch-safe).

Act on these next:

1. **R3-1 High.** `realizeGain` is sandwichable. It is admin-only but not pause-gated, and deposits fill instantly, so any user can deposit one block before an honest gain, take a pro-rata slice, and queue an exit. On a 1M vault with 1M of attacker capital, 25,000 of a 50,000 gain goes to the attacker and the honest holder loses exactly that; a 1% fee leaves 14,750 of profit. Pausing before the gain kills it; a full deposit queue kills it. Fix: require `paused` in `realizeGain` (as `realizeLoss`), or stream gains through the rate instead of a step.
2. **V2-2 High.** Guardian-chosen `recipient_` on both cancels is still upstream. Redeem cancels pay the guardian's address immediately. Deposit cancels are now repairable by the owner before settlement, since only the owner can repoint the cancelled entry. Fix unchanged: refund `request_.owner` unless the owner is the caller.
3. **V2-3' High (trust model).** `realizeLoss` now rejects a full loss but has no floor: `loss = totalAssets - 1` leaves every holder worth 0 in one hot-wallet call while paused. `realizeGain` is the only repair. Fix: an admin-set per-call drawdown cap, or admin-only.
4. **V2-7 Medium.** `setCapacity` still unbounded; `type(uint256).max` bricks deposits by overflow.
5. **V2-4 / V2-5 Medium.** C-1 (batched redeem revert on spUSDC ceil-rounding) and C-2 (blacklisted recipient blocks the queue) are unchanged. C-2 is back to needing the attacker's own request; the owner can now self-rescue by repointing.

## 2. Scope and method

As in round 2: local harness with the real spUSDC code, seven parallel workers, one file and one report each (`test/REPORT-*.md`, each with a "Round 3" section on top). Fork PoCs ported, compile, not executed.

| Suite | File | Tests | Result |
|---|---|---|---|
| New surface | `test/NewSurface.t.sol` | 54 | pass |
| Cancelled-deposit queue | `test/CancelledDepositQueue.t.sol` | 22 | pass |
| Deposit queue | `test/DepositQueue.t.sol` | 58 | pass |
| Redeem queue | `test/RedeemQueue.t.sol` | 47 | pass |
| Cancels and fees | `test/CancelAndFees.t.sol` | 68 | pass |
| Invariants | `test/invariants/` | 22 | pass (100 runs x depth 500) |
| Adversarial | `test/Adversarial.t.sol` | 87 | pass |
| Rounding | `test/Rounding.t.sol` | 68 | 67 pass, 1 deliberate fail (C-1) |
| Authorization / Admin / Upgrade | `test/{Authorization,Admin,Upgrade}.t.sol` | 161 | pass |
| Upstream queue tests | `test/QueueAudit.t.sol` | 8 | pass |
| Harness smoke | `test/LocalSmoke.t.sol` | 2 | pass |

## 3. What changed upstream (round 2 -> round 3)

- `updateDepositRecipient`, `updateCancelledDepositRecipient`, `updateRedeemRecipient`: `recipient != 0`, open entry (`no-request`), `msg.sender == owner` (`not-authorized`).
- `realizeLoss`: `require(paused)`, drip, `require(0 < loss < totalAssets)` (`invalid-loss`), `require(totalSupply != 0)` (`no-shares`, unreachable since `totalAssets == 0` fires `invalid-loss` first).
- New `realizeGain(gain)`: DEFAULT_ADMIN, no pause requirement, `gain > 0`, drip, `totalSupply != 0`, `chi = (totalAssets + gain) * RAY / totalSupply`, event `GainRealized`.
- `_processCancelledDepositQueue` budget is `spUSDC.maxRedeem(vault)` (min of share balance and shares redeemable with spUSDC's USDC liquidity).
- `redeemFee` / `maxRedeemFee` and their setters and events renamed to `redeemFeeRate` / `maxRedeemFeeRate`. `_requestDeposit` moved. Storage layout unchanged from round 2 (27 slots).

## 4. Findings (line numbers on `9269fe0`)

#### R3-1 · High · `realizeGain` can be sandwiched through the instant deposit path
- **Location:** `realizeGain` (around line 297), `_requestDeposit` instant fill (around line 733).
- **What happens:** the gain is spread over whoever holds shares in that block. Deposits fill instantly with no delay and no entry fee when nobody is queued. Attacker front-runs the admin's `realizeGain(50_000e6)` with `requestDeposit(1_000_000e6)` into a 1M vault, holds half the supply when the gain lands (`assetsOf` 1,024,999.999998), queues an exit and is paid from the vault's spUSDC: profit 24,999.999998 USDC; the honest holder ends at 1,024,999.999998 instead of 1,049,999.999998. With a 1% fee profit is 14,749.999997. Take = gain x c / (TVL + c). Capital is at risk only for the planner's turnaround.
- **Does not work when:** the vault is paused before the gain (deposit reverts, gain lands, unpause: honest holder gets the full gain), or the attacker's deposit is queued (filled after the gain at the new price, zero profit).
- **Related:** escrowed redeem shares receive gains pro rata; queued and cancelled deposits do not; phantom shares on the vault address receive gains too.
- **Fix:** require `paused` in `realizeGain`; or stream gains through `setVSR`; or a minimum holding period before exit.
- **Tests:** `test_BUG_realizeGain_sandwichExtractsFromHolders`, `test_BUG_realizeGain_sandwichSurvivesOnePercentFee`, `test_BUG_realizeGain_sandwichTakeScalesWithCapital_*`, `test_realizeGain_queuedDepositFilledAfterGainGetsNoProfit`, `test_realizeGain_pauseBeforeGainKillsSandwich`, `test_processRedeemQueue_realizeGainWhileQueued_escrowSharesGainProRata`, `test_processDepositQueue_queuedDepositorDoesNotShareRealizedGain`.

#### V2-2 · High · Guardian cancel pays the guardian-chosen recipient (F-1, still open)
- Deposit side: the cancelled entry keeps `owner = depositor`, so the depositor can repoint it to themselves before the planner settles (new owner-only updater). Downgradable to Medium only if the planner never settles blindly. Redeem side: shares transfer immediately, no repair. Tests: `test_BUG_cancelDepositRequest_guardianCanRedirectRefund`, `test_BUG_cancelRedeemRequest_guardianCanRedirectShares`, `test_cancelDepositRequest_guardianRedirectRepairedByOwnerBeforeSettlement`, `test_cancelDepositRequest_guardianRedirectNotRepairableAfterSettlement`.

#### V2-3' · High (trust model) · `realizeLoss` has no floor
- Full loss now reverts `invalid-loss`; `loss = totalAssets - 1` is accepted and leaves `chi = RAY / totalSupply`, every holder at 0, backing intact and takeable; `realizeGain` is the only repair; the brick is gone. `totalSupply == 0` reverts `invalid-loss`; the `no-shares` branch is dead code. `chi == 0` remains reachable only above 1e27 shares (not at 6 decimals). Tests: `test_BUG_realizeLoss_noFloor_totalAssetsMinusOneWipesHolders`, `test_realizeLoss_fullLossRejected`, `test_realizeLoss_zeroSupplyRevertsInvalidLossNotNoShares`, `test_realizeLoss_chiZeroStillReachableAboveRaySupply`.

#### V2-4 · Medium · Batched `processRedeemQueue` reverts on spUSDC ceil-rounding (C-1, unchanged)
- Budget once at the top, `withdraw` ceil per fill. The cancelled queue now shows the safe pattern (floor budget via `maxRedeem`, floor payouts via `redeem`): proven batch-safe (`testFuzz_R10_batchSettle_neverExceedsSpUsdcLiquidity`). The redeem queue could use the same shape. Tests: `test_BUG_processRedeemQueue_batchCeilBurnsExceedSpUsdcBalance` (deliberately failing), `test_BUG_processRedeemQueue_batchRevertsOnCeilRounding_*`.

#### V2-5 · Medium · Blacklisted recipient blocks the redeem queue (C-2, unchanged)
- Unblock set is now owner (repoint) or guardian (cancel, costs the owner the fee). Tests: `test_BUG_blacklistedRecipientBlocksRedeemQueue`, `test_updateRedeemRecipient_strangerCannotRepointBlacklistedHead`, `test_updateRedeemRecipient_ownerSelfRescuesBlacklistedHead`.

#### V2-7 · Medium · `setCapacity` unbounded (unchanged)
- Safe bound `type(uint256).max / nowChi()`, shrinks as `chi` grows. Test: `test_BUG_setCapacity_maxUint256BricksDeposits`.

#### V2-8 · Medium · Last admin can renounce; zero admin at init (C-4, unchanged)

#### F-2 · Medium (design) · Queued and cancelled deposits are not ring-fenced
- After `take()` settlement is a silent no-op until spUSDC returns; cancelled and redeem queues compete for the same spUSDC and the planner's order decides; fills mint against backing that left. Unchanged. Tests as in round 2 plus `test_priority_*`.

#### Low

- **V2-9** `requestRedeem(0)` ghosts. `test_BUG_requestRedeem_zeroSharesCreatesGhostEntry`.
- **V2-10** Unbounded head walk in `cancelDepositRequest` (~2,900 gas per ghost; ~10k ghosts block the head depositor's cancel). `test_cancelDepositRequest_headWalkGasGrowsWithGhosts`.
- **V2-11** Cancelled-queue bloat with 2-wei deposits (~20k planner gas per entry). `test_cancelQueue_dustCancelsGasPerEntry`.
- **V2-12** `realizeLoss` over-realises and `realizeGain` under-credits by exactly 1 wei per call in the generic case (two floors through `totalAssets()`); events misreport by 1 wei; k small steps cost holders up to k wei vs one. `testFuzz_R13_*`, `testFuzz_R14_*`.
- **V2-13** `recipient == address(vault)` or `== spUSDC` still accepted in requests, cancels and updaters (self-harm only now).
- **V2-14** Dust at the deposit head switches everyone to queued mode (C-5). `test_BUG_twoWeiDepositAtFullCapacityJamsInstantPath`.
- **G-1** `realizeGain` above `G_drip` (gain such that `chi > type(uint256).max / RAY`, about 1.15e29 USDC at the harness supply) bricks every drip-calling function one second later; irrecoverable without an upgrade; the bound shrinks with the VSR. Admin-only. `test_BUG_realizeGain_aboveDripThresholdBricksVault`, `test_BUG_realizeGain_dripThresholdShrinksWithVsr`.
- **G-2** `realizeGain` casts to `uint192` unchecked: gains in [6.2e42, 1.16e50) wrap `chi` to dust (holders read 0, event reports the wrapped value); recoverable with another gain. Admin-only. `test_BUG_realizeGain_uint192TruncationWrapsChiToDust`. Fix for G-1/G-2: `require(gain_ <= totalAssets())` or a cap on the resulting `chi`.
- Carried: **C-7** bounds do not clamp live values, **C-8** minimums unvalidated, **C-9** SETTER at MAX_VSR over-credits ~0.19%/day, **C-10** capacity hogging at fee 0, **C-11** deposits below one spUSDC share are donated to spUSDC.

#### Informational

- **I3-1** `realizeGain` is not pause-gated while `realizeLoss` requires a pause; a gain can land between a `requestRedeem` and its fill (the asymmetry behind R3-1).
- **I3-2** `realizeGain` with no backing is purely notional: paid first come first served, last redeemer short. `test_compromised_admin_realizeGainOverCreditIsInsolvency`.
- **I3-3** `(totalAssets + gain) * RAY` overflows above ~1.16e50 with a clean panic.
- **I3-4** `no-shares` in `realizeLoss` is unreachable (dead code); reachable in `realizeGain`.
- **I3-5** After a loss takes `chi` below RAY, small redeems pay 0 (R13-c).
- **I3-6** Cancelled-queue settlement at exact liquidity leaves 1 wei queued because `maxRedeem` floors; closes on the next wei of liquidity.
- **I3-7** Burned-fee surplus can be credited to remaining holders with `realizeGain(surplus)` to the wei; with no holders left it is `take`-only. `test_realizeGain_distributesFeeSurplusToRemainingHolders`.
- **I3-8** Cancelled entries behind a live head still consume `maxRequests_` (C-12); head cancels no longer do.
- **I3-9** `UNPAUSER_ROLE` unused (I-3); `Deposit` event param name; `requestDeposit` natspec return value; storage layout incompatible with round 1 (unchanged by round 3).
- **I3-10** Dead-entry writes via the updaters are gone (`no-request`).
- **I3-11** `minRedeem` in shares drifts upward in USDC terms (+5% after a year at 5%) and is gross of fee.
- **I3-12** Fork PoCs compile against the new API but were not executed.

## 5. Rounding table (round 3)

R1..R12 re-pinned, directions unchanged. R13 (`realizeLoss`) and new R14 (`realizeGain`) both floor against holders by at most 1 wei; R14 thresholds at the harness supply: `G_drip` 1.1468e35 wei (drip brick), `G_trunc` 6.2169e42 (cast wrap), `G_ovf` 1.1579e50 (clean panic). R10 (cancelled queue) gained a floor in the budget and is proven batch-safe; stranded liquidity per call `< c_s + n` wei. Full table in `test/REPORT-rounding.md`.

## 6. Invariants (20, all held, 100 runs x depth 500, 0 handler reverts)

A..R as in round 2 (H now carries an index-scaled deficit ledger for realised gains and losses; P tightened to "cancelled-queue settlement never reverts"), plus **S** every non-owner recipient update reverts `not-authorized`, **T** every `realizeGain` / `realizeLoss` moves `totalAssets()` by the stated amount within 1 wei.

## 7. Suggested code changes (round 3)

1. `realizeGain`: require `paused` (or stream via the rate), `require(gain_ <= totalAssets())` or cap the resulting `chi`, compute in `uint256` before the cast (R3-1, G-1, G-2).
2. Both cancels: refund `request_.owner` unless the owner is the caller (V2-2).
3. `realizeLoss`: admin-set per-call drawdown cap or admin-only; drop the dead `no-shares` check (V2-3', I3-4).
4. `_processRedeemQueue`: budget by `maxRedeem` in spUSDC shares and pay with `redeem`, mirroring the cancelled queue; skip or park entries whose payout fails (V2-4, V2-5).
5. Restore `capacity_ <= type(uint128).max` (V2-7).
6. `require(shares_ != 0)` in `requestRedeem`, `require(savingsShares_ != 0)` in `_requestDeposit`, reject `address(this)` and `savings` as recipients everywhere; launch `minDeposit >= 1e6`, `minRedeem >= 1` (V2-9..V2-14).
7. Round-1/2 carry-overs: default-admin rules, clamp live values in bound setters, bounds on minimums, `maxVSR` 10-15% APY, non-zero launch fee or netting, `UNPAUSER_ROLE` cleanup.

## 8. Open questions for the business team

Rounds 1 and 2 questions 1-23 remain (appendices). New:
24. Is `realizeGain` meant to be a step while the vault is open? If so, who bears the sandwich risk; if not, pause-gate it or stream it.
25. Should gains be bounded by the spUSDC actually in the vault?
26. Should the redeem queue adopt the cancelled queue's floor-budget pattern (pay with `redeem`, user absorbs < 1 wei) to remove C-1?

## 9. Limitations

As in round 2: fork PoCs not executed; blacklist mocked; invariant H covers the prefix of each run before the rate order breaks and treats realised gains as notional via an upper-bound ledger; `processQueues` netting not on this branch.

---

# Appendix B: round 2 report (`0bc9288`)


Target: upstream `refactor/more-simplifying` @ `0bc9288` (2026-10-14), unpatched. Branch `review/poc-tests-v2`.
Round 1 (branch `review/poc-tests`, commit `807739f` with two review patches) is kept below as an appendix.

## 1. Executive summary

520 tests across 13 suites: 519 pass, 1 is a deliberate failing proof. 18 invariants held over 50,000 handler calls each on the new code. The refactor fixed F-3 and turned the deposit-cancel revert (F-2) into a planner-settled queue, but it introduced one Critical and regressed one High.

| Severity | Count | Items |
|---|---|---|
| Critical | 1 | V2-1 |
| High | 2 | V2-2 (F-1 regression), V2-3 |
| Medium | 6 | V2-4 (C-1), V2-5 (C-2), V2-6, V2-7, V2-8 (C-4), F-2 (design) |
| Low | 12 | V2-9..V2-14, C-5, C-7, C-8, C-9, C-10, C-11 |
| Informational | 9 | V2-15..V2-23 |

Act on these before anything else:

1. **V2-1 Critical.** `updateDepositRecipient`, `updateCancelledDepositRecipient` and `updateRedeemRecipient` have no authorization. Anyone can point any queued deposit, refund or redeem at themselves in the block before the planner fills it. Every queued dollar in all three queues is stealable; the victim has no safe exit because cancelling only moves the money to another queue the attacker can also repoint.
2. **V2-2 High.** The round-1 F-1 fix is not upstream: a guardian can still name any `recipient_` on both cancels. Deposit refunds settle to that address; redeem shares transfer to it immediately.
3. **V2-3 High.** `realizeLoss` has no floor. `loss == totalAssets()` sets `chi` to 0 permanently: `processRedeemQueue` divides by zero forever, deposits are accepted but can never be filled, no role can recover, only an upgrade. `loss == totalAssets() - 1` leaves holders 1 wei in total. Reachable by a hot-wallet role while paused.
4. **V2-6 Medium.** `processCancelledDepositQueue` budgets by the vault's spUSDC balance but spUSDC `redeem` needs USDC liquidity, so it reverts `SparkVault/insufficient-liquidity` instead of paying what it can; a whale cancel at the head starves everyone behind it.
5. **V2-7 Medium.** `setCapacity` lost its `uint128` bound. `setCapacity(type(uint256).max)` makes every deposit revert by overflow; the safe bound shrinks as `chi` grows, so a value that works today can brick deposits later.
6. **V2-4 / V2-5 Medium.** C-1 (batched redeem reverts on spUSDC ceil-rounding) and C-2 (blacklisted recipient blocks the redeem queue) persist unchanged; C-2 now costs nothing because the attacker can repoint a victim's entry instead of using their own.

Fixed since round 1: F-3 (batch deposit loop), cancel recipient `address(0)` rejected, heads auto-advance past dead entries (narrows C-12), deposit cancel no longer reverts after `take()` (replaced by deferred settlement).

## 2. Scope and method

Local harness (`test/LocalTestBase.t.sol`): 6-decimal mock USDC, the real spUSDC `SparkVault` code behind a proxy, `SparkPrimeVault` behind a proxy, both indexes started at non-trivial values. Eight parallel workers each owned one file and one report (`test/REPORT-*.md`). Style mirrors Spark Vaults V2.

| Suite | File | Tests | Result |
|---|---|---|---|
| New surface | `test/NewSurface.t.sol` | 33 | pass |
| Cancelled-deposit queue | `test/CancelledDepositQueue.t.sol` | 20 | pass |
| Deposit queue | `test/DepositQueue.t.sol` | 55 | pass |
| Redeem queue | `test/RedeemQueue.t.sol` | 45 | pass |
| Cancels and fees | `test/CancelAndFees.t.sol` | 62 | pass |
| Invariants | `test/invariants/` | 20 | pass (100 runs x depth 500) |
| Adversarial | `test/Adversarial.t.sol` | 76 | pass |
| Rounding | `test/Rounding.t.sol` | 53 | 52 pass, 1 deliberate fail (V2-4) |
| Authorization / Admin / Upgrade | `test/{Authorization,Admin,Upgrade}.t.sol` | 149 | pass |
| Upstream queue tests | `test/QueueAudit.t.sol` | 5 | pass |
| Harness smoke | `test/LocalSmoke.t.sol` | 2 | pass |
| Fork PoCs | `test/Review.t.sol` | 10 | ported to the new API, compile, not executed (no RPC here) |

`test_BUG_*` tests prove a bug; they pass by asserting the broken behaviour unless noted. Commands: `forge test --no-match-contract ReviewTest`; `FOUNDRY_INVARIANT_RUNS=100 FOUNDRY_INVARIANT_DEPTH=500 forge test --match-path 'test/invariants/*.t.sol'`; fork: `forge test --match-contract ReviewTest` with `MAINNET_RPC_URL`.

## 3. What changed upstream (round 1 -> round 2)

- `cancelDepositRequest` no longer refunds; it moves the entry to `cancelledDepositQueue` and REBALANCER settles it with `processCancelledDepositQueue` (budget = vault spUSDC balance, pays via spUSDC `redeem`).
- Three new permissionless functions `update*Recipient` rewrite the payout address of any entry.
- `setChi` replaced by `realizeLoss(loss)`: `chi = (totalAssets() - loss) * RAY / totalSupply`, paused only.
- Heads auto-advance past zero entries on request and on head cancel; filled entries are deleted.
- `setMinimums` split into `setMinDeposit` (assets) and `setMinRedeem` (shares); `requestRedeem` no longer requires non-zero shares.
- `setCapacity` lost its `uint128` bound. `pause` briefly moved to admin, then back to GUARDIAN.
- Storage layout changed (four new slots inserted mid-layout); not compatible with round 1, nothing deployed.

## 4. Findings (line numbers on `0bc9288`)

#### V2-1 · Critical · Recipient updaters have no authorization
- **Location:** lines 423, 467, 534. Only `recipient_ != 0` is checked.
- **What happens:** mallory, no role and no balance, calls `updateRedeemRecipient(id, mallory)` in the same block as the planner's `processRedeemQueue`; the planner pays mallory alice's 1,000,000 USDC. Same on queued deposits (shares minted to mallory) and on cancelled-deposit refunds. Cancelling to escape moves the money into the cancelled queue, which mallory repoints too. Last writer before the planner's call wins; the owner has no priority. Works while paused.
- **Also enables:** blocking the redeem queue for free by repointing a victim to a blacklisted address (V2-5), stranding a victim's USDC by repointing to the vault, burning a victim's deposit into dead capacity.
- **Fix:** `require(msg.sender == request.owner)` (or owner-or-guardian) in all three, and reject `address(this)`.
- **Tests:** `test_BUG_updateDepositRecipient_anyoneCanStealQueuedDeposit`, `test_BUG_updateRedeemRecipient_anyoneCanStealQueuedRedeem`, `test_BUG_updateCancelledDepositRecipient_anyoneCanStealRefund`, `test_BUG_updateRecipient_frontRunPlannerStealsRedeemPayout`, `test_BUG_updateRecipient_victimHasNoSafeExitFromDepositQueue`, `test_BUG_updateRecipient_blacklistBlocksRedeemQueueAtZeroCost`, `test_BUG_updateRecipient_strandsVictimRedeemInVault`, `test_BUG_updateRecipient_burnsVictimDepositIntoDeadCapacity`.

#### V2-2 · High · Guardian cancel pays whoever the guardian names (F-1 regression)
- **Location:** lines 441-450 (deposit), 511-518 (redeem).
- **What happens:** `cancelDepositRequest(id, guardian)` creates a cancelled entry with recipient guardian; settlement pays the guardian 999,999,999,999 USDC of alice's deposit. `cancelRedeemRequest(id, guardian)` transfers alice's 990,405,184,109 escrowed shares to the guardian at once.
- **Fix:** `msg.sender == request_.owner ? recipient_ : request_.owner` in both.
- **Tests:** `test_BUG_cancelDepositRequest_guardianCanRedirectRefund`, `test_BUG_cancelRedeemRequest_guardianCanRedirectShares`, `test_BUG_guardianCancelRefundsToArbitraryRecipient`.

#### V2-3 · High · `realizeLoss` is unbounded and a full loss zeroes the index permanently
- **Location:** line 357.
- **What happens:** `realizeLoss(totalAssets())` sets `chi = 0`. `nowChi()` stays 0 after 10 years at MAX_VSR; `convertToShares` divides by zero so `processRedeemQueue` can never run; `requestDeposit` still succeeds but fills are impossible (capacity converts to 0); `realizeLoss(1)` then underflows. ~1,000,000 USDC of spUSDC remains, reachable only by `take`. `realizeLoss(totalAssets() - 1)` leaves holders 1 wei in total. `totalSupply == 0` and `loss > totalAssets` revert by arithmetic panic rather than a check. With `totalSupply == 1` share, a 1-wei loss is a full loss.
- **Fix:** `require(loss_ < totalAssets())`, an admin-set per-call drawdown floor, or admin-only.
- **Tests:** `test_BUG_realizeLoss_fullLossSetsChiZeroAndBricksVault`, `test_BUG_realizeLoss_oneWeiLossOnOneShareSupplyZeroesChi`, `test_compromised_riskManager_fullLossBricksVault`, `test_realizeLoss_totalAssetsMinusOneWipesHolders`.

#### V2-4 · Medium · Batched `processRedeemQueue` reverts on spUSDC ceil-rounding (C-1, unchanged)
- Lines 782 and 805. Same mechanism, numbers and fix as round 1 (re-clamp inside the loop). Tests: `test_BUG_processRedeemQueue_batchCeilBurnsExceedSpUsdcBalance` (deliberately failing), `test_BUG_processRedeemQueue_batchRevertsOnCeilRounding_*`.

#### V2-5 · Medium · Blacklisted recipient blocks the redeem queue (C-2, now zero-cost)
- Line 805, strict FIFO, no skip. Attacker no longer needs their own request: repoint a victim's entry (V2-1). Guardian cancel unblocks but costs the victim the up-front fee (F-8). Tests: `test_BUG_blacklistedRecipientBlocksRedeemQueue`, `test_BUG_updateRecipient_blacklistBlocksRedeemQueueAtZeroCost`, `test_updateRedeemRecipient_anyoneUnblocksBlacklistedHeadAndTakesThePayout`.

#### V2-6 · Medium · Cancelled-deposit settlement reverts when spUSDC is illiquid; whale starvation
- **Location:** line 744 (budget = `spUSDC.balanceOf(vault)`), line 765 (`spUSDC.redeem`).
- **What happens:** spUSDC `redeem` needs USDC. With 500k of 1M drained from spUSDC, settling alice's 1M refund reverts `SparkVault/insufficient-liquidity` although 499,999,999,998 could be paid; a batch whose second entry does not fit reverts entirely; a 10M cancel at the head with 1,000 USDC of liquidity starves a 100 USDC cancel behind it. The redeem loop already clamps to `maxWithdraw` and degrades gracefully. Hit live by the invariant campaign.
- **Fix:** budget by `spUSDC.maxRedeem(address(this))` and break when the next payout exceeds it.
- **Tests:** `test_BUG_processCancelledDepositQueue_revertsWhenSpUsdcIlliquid`, `test_BUG_processCancelledDepositQueue_batchRevertsWhenSecondEntryIlliquid`, `test_cancelQueue_whaleCancelStarvesQueueWhenSpUsdcShort`, `invariant_P_processCancelledDepositQueueRevertsOnlyOnKnownReasons`.

#### V2-7 · Medium · `setCapacity` is unbounded; large values brick deposits
- **Location:** line 268 (setter), line 704 (`availableCapacity() * chi`).
- **What happens:** `setCapacity(type(uint256).max)` makes every `requestDeposit` and `processDepositQueue` panic with overflow. Safe bound is `type(uint256).max / nowChi()` (1.1468e50 today) and shrinks as `chi` grows: a capacity at the exact bound today bricks deposits after one day at MAX_VSR. Admin can recover by lowering the cap.
- **Fix:** restore `capacity_ <= type(uint128).max`.
- **Tests:** `test_BUG_setCapacity_maxUint256BricksDeposits`, `test_capacity_overflowThreshold_shrinksAsChiGrows`.

#### V2-8 · Medium · Last admin can brick the vault; zero admin accepted at init (C-4, unchanged)
- Tests: `test_renounceDefaultAdmin_vaultHasNoAdminForever`, `test_initialize_zeroAdminNotGuarded`.

#### F-2 · Medium (design) · Cancelled queue is not ring-fenced from `take()` or from other depositors
- After `take()`, settlement is a silent no-op (no revert, no event) until spUSDC returns; an early cancel settles from a later depositor's spUSDC; deposit fills still mint against backing that left; redeem and cancelled queues compete for the same spUSDC and the planner's call order decides who is paid. Tests: `test_take_afterCancel_settleIsNoOpUntilSpUsdcReturned`, `test_processCancelledDepositQueue_spendsOtherQueuedDepositorsBacking`, `test_priority_*`, `test_processDepositQueue_fillsAfterTakeRemovedBacking`.

#### Low

- **V2-9** `requestRedeem(0)` creates a zero-share ghost (the `shares_ != 0` check was dropped); free throughput griefing with no balance and no fee; `minRedeem >= 1` closes it. `test_BUG_requestRedeem_zeroSharesCreatesGhostEntry`.
- **V2-10** Head walk in `cancelDepositRequest` is unbounded: ~2,900 gas per ghost behind a live head; ~10,300 ghosts (about 0.8 ETH at 1 gwei) make the head depositor's cancel exceed 30M gas and the planner cannot pre-clear them without capacity. `test_cancelDepositRequest_headWalkGasGrowsWithGhosts`. The walk in `_requestDeposit` is a one-time charge, not a DoS (`test_griefing_headWalkChargedToNextDepositorAfterPlannerClosesHead`).
- **V2-11** Cancelled-queue bloat: a 2-wei deposit plus cancel costs the attacker ~250k gas and the planner ~20k per entry to settle; 500 of them push a victim's refund behind one full planner call. `minDeposit >= 1e6` removes it. `test_cancelQueue_dustCancelsGasPerEntry`.
- **V2-12** `realizeLoss` over-realises by exactly 1 wei per call in the generic case (two floors), so `LossRealized.loss` understates the holders' loss; a stream of k small losses costs holders up to k wei more than one aggregated loss. `testFuzz_R13_realizeLoss_floorsAgainstHolders_overRealisesAtMostOneWei`.
- **V2-13** `recipient == address(vault)` or `== spUSDC` still accepted in `requestDeposit`, `requestRedeem`, both cancels and all three updaters (C-6; only `address(0)` is now rejected on cancels). Combined with V2-1 it is third-party destruction of funds.
- **V2-14** Dust at the deposit head still switches everyone to queued mode (C-5); after a guardian cancel of the dust, requests already queued behind it stay queued until the planner runs. `test_BUG_twoWeiDepositAtFullCapacityJamsInstantPath`.
- Carried unchanged: C-7 (tightened bounds do not clamp live values), C-8 (`setMinDeposit`/`setMinRedeem` unvalidated; `minRedeem` in shares drifts up in USDC terms, +5% after a year at 5%), C-9 (SETTER at MAX_VSR over-credits 1,900 USDC per day per 1M), C-10 (free capacity hogging at fee 0), C-11 (deposits below one spUSDC share are donated to spUSDC).

#### Informational

- **V2-15** `update*Recipient` on a filled (deleted) id writes a recipient into a dead slot; harmless. Also allowed while paused.
- **V2-16** `Deposit` event's fourth parameter is named `savingsShares` but carries spPRIME shares; `requestDeposit` natspec says it returns `uint256.max` when nothing was queued, it always returns the index.
- **V2-17** Storage layout is not upgrade-compatible with round 1 (four slots inserted mid-layout, `decimals` moved). Nothing deployed.
- **V2-18** `UNPAUSER_ROLE` still unused; `unpause` is admin-only (I-3).
- **V2-19** `realizeLoss` edge cases revert with arithmetic panics (`totalSupply == 0`, `loss > totalAssets`) instead of a require string.
- **V2-20** After a loss that takes `chi` below RAY, `convertToAssets(s)` is 0 for small `s`; the redeem loop burns such shares and pays 0.
- **V2-21** Cancelled entries behind a live head still consume `maxRequests_` (C-12, narrowed: head cancels no longer cost a slot).
- **V2-22** `minRedeem` is gross of fee: a request exactly at the minimum pays 1% less than the minimum's value (I-4).
- **V2-23** Fee burned at request accrues to vault equity and now also funds cancelled-deposit refunds after a full `take()` (I-2).

## 5. Rounding table (round 2)

All rows re-proven at 10,000 fuzz runs on the new line numbers. R5 is gone (the redeem minimum is an exact share comparison). R10 moved into `_processCancelledDepositQueue`; k-chunk settlement loses at most k-1 wei versus one shot. New R13: `realizeLoss` rounds against holders by at most 1 wei (exactly 1 in the generic case), the cast cannot truncate, `loss == totalAssets` gives `chi = 0`. Round-trip loss bound unchanged: at most 4 wei at current indexes. Capacity overflow bound: `maxCapacity - totalSupply <= type(uint256).max / nowChi()`. Full table in `test/REPORT-rounding.md`.

## 6. Invariants (18, all held, 100 runs x depth 500, 0 handler reverts)

A sum of balances == `totalSupply`; B vault balance == `pendingRedeemShares`; C/D/Q pending counters == sums of open entries for all three queues; E everything strictly before each of the three heads is zero; F no mint above capacity at mint time; G `chi` only decreases via `realizeLoss` and `drip() == nowChi()`; H real backing minus value owed to deposit and cancelled queues covers `totalAssets()` plus realised losses within one spUSDC share per redeem fill, while spUSDC rate >= prime rate and nothing is taken; I users never extract more than deposits plus real yield (fills plus refunds); J balance provenance with recipients captured at fill time; K USDC conservation; L `availableCapacity()` formula; M zero-share fills counted; N spUSDC supply == vault + taker; O `processRedeemQueue` reverts only on the ceil-burn (V2-4); P `processCancelledDepositQueue` reverts only on `insufficient-liquidity` (V2-6); R a recipient update changes no balance, total, head or entry amount (keccak digest of full state before == after).

## 7. Suggested code changes (round 2)

1. Authorize the three `update*Recipient` functions to the entry owner (or owner-or-guardian) and reject `address(this)` and `savings` as recipients everywhere (V2-1, V2-13).
2. In both cancels, use `request_.owner` as recipient unless the owner is the caller (V2-2).
3. `realizeLoss`: `require(loss_ < totalAssets())` plus an admin-set per-call drawdown floor, or make it admin-only (V2-3, V2-12, V2-19).
4. `_processRedeemQueue`: re-clamp the budget inside the loop and skip or park entries whose payout fails (V2-4, V2-5).
5. `_processCancelledDepositQueue`: budget by `spUSDC.maxRedeem(address(this))` (V2-6).
6. Restore `capacity_ <= type(uint128).max` (V2-7).
7. `require(shares_ != 0)` in `requestRedeem` and `require(savingsShares_ != 0)` in `_requestDeposit`; launch with `minDeposit >= 1e6`, `minRedeem >= 1` (V2-9, V2-10, V2-11, C-11).
8. Keep the round-1 items: default-admin rules (V2-8), clamp live values in bound setters (C-7), sanity bounds on minimums (C-8), `maxVSR` 10-15% APY (C-9), non-zero launch fee or netting (C-10), gate `unpause` on UNPAUSER_ROLE or delete it (V2-18).

## 8. Open questions for the business team

1-17 from round 1 remain (see appendix). New:
18. Are the `update*Recipient` functions wanted at all? If yes, owner-only or owner-or-guardian, and should they work while paused?
19. Should guardian cancels be forced to refund the owner (round-1 F-1 answer was yes; upstream dropped it)?
20. What per-call loss floor is acceptable for `realizeLoss`, and should a full loss ever be expressible?
21. Should the cancelled-deposit queue be settled before or after the redeem queue when spUSDC is short? Today the planner decides per call.
22. Should refunds be allowed to consume other queued depositors' spUSDC (today yes, in a REBALANCER call)?
23. Launch values for `minDeposit` and `minRedeem`, given that `minRedeem` is now in shares and drifts up in USDC terms.

## 9. Limitations

- Fork PoCs were ported but not executed (no RPC in this environment).
- Blacklist behaviour is simulated with a mocked USDC revert.
- Invariant H covers the prefix of each run before the spUSDC/prime rate order first breaks; realised losses are modelled as notional only.
- `processQueues` netting is not on this branch and was not tested here.

---

# Appendix C: round 1 report (branch `review/poc-tests`, `807739f` + review patches F-1, F-3)


Branch `review/poc-tests` (based on `lucas/refactor-vault` @ `807739f`), 2026-10-14.
Scope: `src/SparkPrimeVault.sol` as implemented on that commit, with two review patches applied (F-1, F-3).
Out of scope by decision of the product owner: loss realisation (`setChi` economics), ERC-7540, instant redemptions, the coming planner-handled deposit-cancel queue.

## 1. Executive summary

374 tests across 10 suites (373 pass, 1 is a deliberate failing proof). 15 invariants held over 50,000 handler calls each. No way was found for a user to extract value, and no accounting invariant broke.

Severity counts (first pass + campaign, deduplicated):

| Severity | Count | Items |
|---|---|---|
| High | 2 | F-1 (patched), C-3 |
| Medium | 5 | F-2 (design), F-3 (patched), C-1, C-2, C-4 |
| Low | 13 | F-4, F-5, F-7, F-8, C-5, C-6, C-7, C-8, C-9, C-10, C-11, E-1, E-3 |
| Informational | 14 | F-6, I-1..I-8, C-12..C-15, E-2 |

Top items to act on before freezing the design:

1. **C-1 Medium.** `processRedeemQueue` with more than one request reverts whenever the batch drains the vault's spUSDC to the last wei, because each spUSDC `withdraw` rounds its share burn up. Model estimate at current indexes: 3% of 3-request batches, 17% of 10, 45% of 50. One-line fix in the loop.
2. **C-2 Medium.** A redeem request whose recipient is USDC-blacklisted blocks the whole redeem queue (strict FIFO, no skip). Anyone can set it up for gas; a guardian cancel per occurrence is the only unblock.
3. **C-3 High under the stated trust model.** `setChi` (hot-wallet RISK_MANAGER) has no floor: one call to `1` while paused zeroes every holder and leaves the spUSDC backing takeable. Needs a per-call floor or an admin-only path.
4. **C-4 Medium.** The only DEFAULT_ADMIN can renounce or revoke itself, leaving no unpause and no upgrade forever; `initialize` also accepts `admin = address(0)`.
5. **F-2 Medium (design).** `take()` and `processRedeemQueue` spend queued depositors' spUSDC; their cancel then reverts and fills mint shares against backing that already left. Acknowledged; the planner-handled cancel queue should close it.
6. **C-5 / C-6 Low.** Dust at the head of the deposit queue silently switches the vault to queued mode for everyone (2 wei to trigger); `recipient == address(vault)` strands shares or USDC and consumes capacity forever. Both are one `require` each.

Suggested launch parameters: `minDeposit >= 2 USDC wei` (really: a sane minimum like 1e6), `minWithdraw > 0`, `maxVSR <= 10-15% APY`, non-zero `redeemFee`, `maxRedeemFee` set deliberately.

## 2. Scope and method

- First pass (2026-10-13): line-by-line review against a mainnet fork (block 26148600), 10 PoCs in `test/Review.t.sol`, findings F-1..F-8 and I-1..I-8 in `REVIEW-2026-10-13.md`.
- Campaign (2026-10-14): seven parallel workers, each owning one test file on a local harness (`test/LocalTestBase.t.sol`: 6-decimal mock USDC, the real spUSDC `SparkVault` code behind a proxy, `SparkPrimeVault` behind a proxy, both indexes started at non-trivial values, VSR then frozen). Per-worker reports are in `test/REPORT-*.md`.
- Test style mirrors Spark Vaults V2: `test_<fn>_<case>`, `testFuzz_`, `invariant_<letter>_<claim>`, exact balance assertions before and after every step, exact revert strings.

| Suite | File | Tests | Result |
|---|---|---|---|
| Deposit queue | `test/DepositQueue.t.sol` | 45 | pass |
| Redeem queue | `test/RedeemQueue.t.sol` | 32 | pass |
| Cancels and fees | `test/CancelAndFees.t.sol` | 48 | pass |
| Invariants | `test/invariants/` | 16 | pass (100 runs x depth 500) |
| Adversarial | `test/Adversarial.t.sol` | 59 | pass |
| Rounding | `test/Rounding.t.sol` | 38 | 37 pass, 1 deliberate fail (C-1) |
| Authorization / Admin / Upgrade | `test/{Authorization,Admin,Upgrade}.t.sol` | 134 | pass |
| Harness smoke | `test/LocalSmoke.t.sol` | 2 | pass |
| Fork PoCs | `test/Review.t.sol` | 10 | pass (2026-10-13 run) |

Commands: `forge test --no-match-contract ReviewTest` (local), `forge test --match-contract ReviewTest` (fork, needs `MAINNET_RPC_URL`), `FOUNDRY_INVARIANT_RUNS=100 FOUNDRY_INVARIANT_DEPTH=500 forge test --match-path 'test/invariants/*.t.sol'`.

## 3. Accounting model (as implemented)

- Shares are index-priced: `assets = shares * chi / RAY`, `chi` compounds at `vsr` per second. `totalAssets()` is notional; nothing on-chain ties it to backing.
- Every deposit goes straight into spUSDC. The vault's only backing is its spUSDC balance; capital deployed by the TAKER leaves as spUSDC and returns as spUSDC by plain transfer. USDC never sits in the contract by design.
- Deposit queue entries are in spUSDC shares. A request fills instantly only when nobody is queued ahead and capacity allows. A fill converts spUSDC shares to USDC to spPRIME shares and mints; the spUSDC stays as general backing.
- Redeem queue entries are in spPRIME shares, escrowed in the vault, fee burned up front. A fill burns shares and calls spUSDC `withdraw` straight to the recipient, bounded by `spUSDC.maxWithdraw(vault)`.
- Capacity caps `totalSupply` in shares (escrowed redeem shares included) and may sit below it.
- Pause blocks requests, cancels and queue processing; `take`, `drip`, ERC20 and all setters keep working.

## 4. Findings

Line numbers refer to `src/SparkPrimeVault.sol` on `review/poc-tests`.

### First-pass findings (status after the campaign)

| # | Sev | Title | Status |
|---|---|---|---|
| F-1 | High | Guardian cancel could redirect refunds to any `recipient_` | Patched (line 408, 463); verified by `test_cancel*Request_guardianRefundsOwnerIgnoringRecipient` |
| F-2 | Medium | `cancelDepositRequest` reverts once `take()`/redeems spent the queue's spUSDC; fills still mint | Design; quantified in `test_cancelDepositRequest_revertsAfterTakeSpentBacking`, `test_processDepositQueue_stillMintsAfterTakeSpentBacking`, `test_cancelDepositRequest_earlyCancelAfterTakeStrandsLaterDepositor` |
| F-3 | Medium | Deposit loop broke after one request | Patched (line 664); verified by `test_processDepositQueue_maxRequestsHonouredExactly` |
| F-4 | Low | Dust fills consume spUSDC and mint 0 | Boundary is exactly `remaining_ == 1` spUSDC share at current indexes; on the instant path it is a 100% loss of a 2-wei deposit (`test_BUG_dustFillMintsZeroShares`, `test_requestDeposit_instantFillCapacityBoundary`) |
| F-5 | Low | Zero and dust requests create ghost entries | 2.3-2.4k gas per ghost cold, ~12,000 ghosts per 30M block; `setMinimums(1e6,1e6)` blocks both kinds (`test_processDepositQueue_gasWith500GhostEntries`, `test_griefing_ghostsBlockedByMinimums`) |
| F-6 | Info | No path for USDC landing in the contract | Now user-triggerable via C-6 |
| F-7 | Low | Cancels blocked while paused, `take` not | Quantified (`test_processRedeemQueue_pausedBlocksRedeemsNotTake`) |
| F-8 | Low | Redeem fee kept on guardian cancel | 1% of 1,000,000 USDC = 10,000 USDC lost on a compliance cancel (`test_cancelRedeemRequest_guardianCancelKeepsFee`) |

### Campaign findings

#### C-1 · Medium · Multi-request `processRedeemQueue` reverts on spUSDC ceil-rounding
- **Location:** line 675 (budget computed once from `maxWithdraw`), line 698 (`spUSDC.withdraw(assets_)` burns `ceil(assets * RAY / chi_s)` per fill).
- **What happens:** the per-call budget is correct for one fill. Over N fills the burns can exceed the vault's spUSDC by up to N-1 shares, and the last `withdraw` reverts with `SparkVault/insufficient-balance`, rolling back the batch. Triggers only when the batch consumes the whole available backing, which is the normal state once capital is deployed and the queue exceeds what is left.
- **Example:** vault holds 3,548 spUSDC (worth 3,717 USDC, budget 3,681 spPRIME). Two requests of 2,396 and 1,285 shares pay 2,419 + 1,297 USDC and burn 2,310 + 1,239 = 3,549 spUSDC. `processRedeemQueue(max, 2)` reverts; `(max, 1)` twice works.
- **Frequency (model at current indexes, budget fully consumed):** 2 fills 0.05%, 3 fills 3.2%, 5 fills 7.5%, 10 fills 17%, 50 fills 45%.
- **Impact:** no funds at risk; batch automation reverts unpredictably and the planner must fall back to one request per call.
- **Fix:** re-clamp inside the loop, e.g. before the fill: `uint256 cap_ = convertToShares(IERC4626Like(savings).maxWithdraw(address(this))); if (cap_ < remaining_) remaining_ = cap_; if (remaining_ == 0) break;`. Alternatives: pay via `redeem(convertToShares_s(assets_))` (user absorbs < 1 wei), or `break` when `previewWithdraw(assets_) > balance`.
- **Tests:** `test_BUG_processRedeemQueue_batchCeilBurnsExceedSpUsdcBalance` (deliberately failing), `test_BUG_processRedeemQueue_batchRevertsOnCeilRounding_vaultSharesBound`, `..._liquidityBound`, `test_BUG_processRedeemQueueRevertsOnCeilBurnWhenBalanceBinds`, `testFuzz_processRedeemQueue_singleFillNeverReverts`, `testFuzz_processRedeemQueue_batchOverburnBoundedByFillsMinusOne`.

#### C-2 · Medium · A redeem to a USDC-blacklisted recipient blocks the whole queue
- **Location:** line 698; strict FIFO loop with no skip-on-failure.
- **What happens:** mainnet USDC reverts transfers to blacklisted addresses. Attacker deposits 1 USDC and calls `requestRedeem(1, blacklisted)`. Every `processRedeemQueue` call reverts with `Blacklistable: account is blacklisted`; nobody behind is paid. Guardian cancel refunds the attacker's share, who resubmits. Also hits honest users blacklisted while queued.
- **Cost:** gas only (the share is refunded; with a fee, 1 wei).
- **Fix:** on fill failure skip or park the entry (or pay `request.owner`), and reject recipients for which `USDC.isBlacklisted()` holds at request time.
- **Test:** `test_BUG_blacklistedRecipientBlocksRedeemQueue` (mocked revert; a fork test against real USDC is recommended).

#### C-3 · High (trust model) · `setChi` is unbounded for a hot-wallet role
- **Location:** lines 327-332; only `paused` and `0 < chi_ < drip()`.
- **What happens:** with the vault paused (routine during incidents), a compromised RISK_MANAGER calls `setChi(1)`: every holder's `assetsOf` becomes 0, `totalAssets() == 0`, 1,000,000 USDC of spUSDC remains and is takeable. Nothing can raise chi back (10 years at MAX_VSR gives chi = 1024 wei).
- **Fix:** a per-call floor set by DEFAULT_ADMIN (e.g. `chi_ >= drip() * (1 - maxDrawdown)`), a two-step or timelocked path, or admin-only.
- **Tests:** `test_setChi_oneWeiRealisesTotalLoss`, `test_compromised_riskManager_setChiToOneWeiWipesHolders`.

#### C-4 · Medium · Last admin can brick the vault; zero admin accepted at init
- **Location:** line 62 (plain `AccessControlEnumerableUpgradeable`), lines 217-242.
- **What happens:** the only DEFAULT_ADMIN calls `renounceRole` or `revokeRole` on itself: no unpause, no upgrade, no role changes, ever (proven while paused: paused forever). `initialize(..., address(0))` yields the same dead state from block one.
- **Fix:** `AccessControlDefaultAdminRulesUpgradeable`, or refuse removing the last admin; `require(admin != address(0))`.
- **Tests:** `test_renounceDefaultAdmin_vaultHasNoAdminForever`, `test_revokeDefaultAdmin_self_vaultHasNoAdminForever`, `test_initialize_zeroAdminNotGuarded`.

#### C-5 · Low · Dust at the deposit head switches the vault to queued mode for everyone
- **Location:** lines 633-636 (capacity converted with two floors), line 357 (`depositInstantly_ = pendingDepositSavingsShares == 0`).
- **What happens:** a deposit sized exactly to the remaining capacity leaves 1 spUSDC share queued (the two floors admit one share less than the request). Equivalent attack: at full capacity, `requestDeposit(2 wei)` leaves 1 share queued. From then on every deposit is queued, even after redeems free capacity, until the planner runs; that planner fill mints 0 shares (F-4) and closes the entry.
- **Cost:** 2 wei + gas.
- **Fix:** `if (shares_ == 0) break;` before mutating state together with closing entries below 2 spUSDC shares, or round the capacity conversion up; netting deposits against redeems (TODO line 48) removes the dependency on planner cadence.
- **Tests:** `test_BUG_exactFitCapacityLeavesDustThatBlocksInstantFills`, `test_jam_fullCapacityTwoWeiDepositBlocksInstantPath`, `test_jam_clearedByOnePlannerCall`.

#### C-6 · Low · `recipient_ == address(vault)` (or spUSDC, or zero on cancel) strands value and capacity
- **Location:** line 352 (only `address(0)` rejected in `requestDeposit`), 423 (`requestRedeem`), 450-465 (`cancelRedeemRequest` rejects nothing).
- **What happens:** deposit to the vault mints shares nobody can burn; they sit in `totalSupply` and consume capacity forever. Redeem to the vault pays USDC into the contract where nothing counts or moves it (F-6 made user-triggerable). Redeem to spUSDC burns the vault's spUSDC and donates the USDC to spUSDC holders. `cancelRedeemRequest(id, address(0))` moves escrowed shares to the zero address with `totalSupply` unchanged.
- **Fix:** `require(recipient_ != address(this) && recipient_ != savings && recipient_ != address(0))` in `requestDeposit`, `requestRedeem` and both cancels.
- **Tests:** `test_requestDeposit_recipientIsVaultSharesAreStuck`, `test_processRedeemQueue_recipientIsVault_usdcStuck`, `test_processRedeemQueue_recipientIsSpUsdc_donatesToSpUsdc`, `test_cancelRedeemRequest_zeroRecipientNotRejected`, `test_escrow_depositRecipientVaultPermanentlyConsumesCapacity`.

#### C-7 · Low · Tightened bounds do not take effect until the hot-wallet role acts
- **Location:** lines 256-259 (`setMaxRedeemFee`), 268-274 (`setVSRBounds`).
- **What happens:** lowering `maxRedeemFee` below the live `redeemFee` leaves the higher fee in force; narrowing VSR bounds below the live `vsr` leaves the higher rate accruing. The admin cannot contain a compromised SETTER or RISK_MANAGER without first granting itself that role.
- **Fix:** clamp the live value inside the bound setter (after a `drip()` for VSR).
- **Tests:** `test_setMaxRedeemFee_belowCurrentFeeLeavesFeeInForce`, `test_setVSRBounds_currentVsrOutsideNewBounds`.

#### C-8 · Low · `setMinimums` has no validation
- **Location:** lines 261-266. `minWithdraw = uint256.max` makes every redeem revert; `minDeposit = uint256.max` every deposit; `minDeposit > maxCapacity` forces every deposit to queue behind an unreachable cap. Admin only, so a fat-finger risk. Add sanity bounds.
- **Tests:** `test_setMinimums_noValidation_*`, `test_setMinimums_minDepositAboveCapacity`.

#### C-9 · Low · Compromised SETTER at `MAX_VSR` over-credits ~0.19% per day
- **Location:** lines 285-292; bound is whatever `maxVSR` the admin set (harness: 100% APY).
- **What happens:** on 1,000,000 USDC the over-credit is 1,900.84 USDC per day, 58,625 USDC per 30 days, and it becomes real on the first honest fill (after 7 days the planner pays everything the vault holds and 13,382 USDC of the request is unpayable). At a 10% bound: 261 USDC per day.
- **Fix:** launch `maxVSR` at 10-15% APY.
- **Tests:** `test_compromised_setter_maxVsrOverCreditsPerDay`, `test_compromised_setter_overCreditRealisedOnRedeem`.

#### C-10 · Low · Free capacity hogging when `redeemFee == 0`
- **Location:** lines 432-445 (escrowed shares stay in `totalSupply`).
- **What happens:** deposit the whole free capacity and request a redeem in the same block; later depositors queue until the planner pays; the attacker is refunded in full and repeats. Cost is time value only; the fee is the only deterrent.
- **Fix:** netting (TODO line 48) or a non-zero launch fee.
- **Test:** `test_capacityHog_depositThenRedeemHoldsCapacityForFree`.

#### C-11 · Low · Deposits below one spUSDC share are donated to spUSDC
- **Location:** line 366 with `minDeposit = 0`. `requestDeposit(1)` at chi_s > 1 receives 0 spUSDC shares, pushes a 0-share entry, cannot be cancelled (`no-request`). Refinement of F-5.
- **Fix:** `require(savingsShares_ != 0)` or a non-zero `minDeposit`.
- **Test:** `test_R1_dustDeposit_belowOneSpUsdcShare_isLostToSpUsdc`.

#### C-12 · Info · Cancelled entries consume `maxRequests_`; cancel/re-request griefing is free
- Lines 641/648 and 678/685: a cancelled entry uses a `maxRequests_` slot and ~2.3k gas cold. Deposit cancel has no fee and `minDeposit` does not stop the cycle (one 100 USDC recycled through 50 request/cancel cycles costs 50 wei). Throughput griefing only; the head always advances when anything is processable.
- Tests: `test_processDepositQueue_cancelledEntriesConsumeMaxRequests`, `test_cancelDepositRequest_cancelledEntriesConsumeRequestBudget`, `test_processRedeemQueue_cancelledEntryCountsTowardMaxRequests`, `test_griefing_headDoesNotAdvanceWithoutCapacityOrLiquidity`.

#### C-13 · Info · Chunked partial fills cost the depositor up to `2(k-1)` shares
- Lines 653-654, two floors per fill. Fuzzed bound holds at 5000 runs. Test: `testFuzz_requestDeposit_queuedDepositorGetsAtLeastAsManySharesAsInstant`.

#### C-14 · Info · spUSDC dependencies surface as reverts here
- `requestDeposit` reverts `SparkVault/deposit-cap-exceeded` when spUSDC's cap is hit; `cancelDepositRequest` reverts `SparkVault/insufficient-liquidity` when spUSDC has no USDC even though the vault holds the spUSDC (different cause from F-2). Tests: `test_requestDeposit_revertsWhenSpUsdcCapHit`, `test_cancelDepositRequest_revertsWhenSpUsdcIlliquid`.

#### C-15 · Info · `drip` overflow bounds
- chi is capped by `_rpow(vsr, dt) * chi < 2^256`: 76 cumulative years at 100% APY work, 77 revert. With `totalSupply` near `uint128.max`, line 579 overflows after 38 years at MAX_VSR and bricks every entry point (all drip first). Unreachable with a sane `maxVSR`. Tests: `test_extremes_*`.


### Post-campaign edge cases (`test/EdgeCases.t.sol`, 13 tests, requires the uncommitted `processQueues`)

#### E-1 · Low · Netting (`processQueues`) inherits C-1 and C-2 for both legs
- `processQueues` runs the redeem loop then the deposit loop in one transaction, so the redeem leg's ceil-burn revert (C-1) or a blacklisted recipient (C-2) also undoes the deposit leg. With netting the deposit queue is hostage to the redeem queue.
- Netting pays redeemers out of queued depositors' spUSDC and then mints those depositors shares against backing that left in the same transaction: after one netted call, bob holds 99,040.518408 shares (100k notional) against 1 wei of spUSDC in the vault until the taker returns capital. Intended under F-2, but it is now a single-call path.
- The deposit leg is bounded by request count only; it fills any pre-existing capacity, not just what the redeem leg freed.
- Tests: `test_processQueues_redeemLegCeilBurnRevertKillsDepositLeg`, `test_processQueues_blacklistedRedeemRecipientKillsDepositLeg`, `test_processQueues_mintsAgainstBackingPaidOutInSameTx`, `test_processQueues_depositLegFillsPreexistingCapacity`.

#### E-2 · Info · Cancels are a free timing option
- With fee 0, requesting a redeem costs nothing: a user queued for a year and then cancelling ends identical to one who never queued (104,999.999998 USDC each). With a 1% fee the option costs exactly the fee (1,050.000001 USDC on 100k). A rational user at fee 0 queues a redeem for everything and cancels if they change their mind; the queue carries no commitment (see C-10).
- A queued depositor earns the spUSDC rate and may cancel for free, so they get `max(spUSDC rate, prime rate)` while filled holders get the prime rate: 104,999.999999 vs 103,999.999998 USDC after a year at 5% / 4%.
- A queued depositor can front-run the planner's fill with a cancel and re-enter instantly at no cost in shares.
- Pause blocks cancels, so a `setChi` loss cannot be front-run from either queue. Escrowed redeem shares take the loss (alice: 49,999.999999 after a 50% cut); queued deposits do not (bob: 99,999.999999 back).
- Tests: `test_cancelRedeemRequest_isFreeOptionWhenFeeZero`, `test_cancelRedeemRequest_feeIsTheOnlyCostOfTheOption`, `test_cancelDepositRequest_queuedDepositorEarnsSpUsdcRateAndKeepsTheChoice`, `test_cancelDepositRequest_frontRunsPlannerFillAtNoCost`, `test_pause_blocksCancelSoLossIsNotFrontRunnable`.

#### E-3 · Low · Capacity zero is not "deposits closed": the queue is an uncapped spUSDC router
- `requestDeposit` never checks capacity. With `maxCapacity = 0`, ten 1M deposits put 9,999,999.99999 USDC into spUSDC under the vault's name with `totalSupply == 0`. Depositors earn spUSDC yield fee-free and leave by cancel whenever they like; the planner can never fill them.
- Those deposits consume spUSDC's own deposit cap: with spUSDC's cap 5M above its level, the sixth 1M request reverts `SparkVault/deposit-cap-exceeded`. Anyone can use the prime queue to exhaust spUSDC's cap.
- A queued cancel also needs USDC liquidity inside spUSDC for the grown amount (C-14): after a year at 5% bob's cancel reverts `SparkVault/insufficient-liquidity` until spUSDC is topped up.
- Fix: reject requests when `availableCapacity() == 0` (or cap the queue in spUSDC shares), and decide whether queued deposits should count against spUSDC's cap.
- Tests: `test_setCapacity_zero_redeemsDrainAndDepositsNeverFill`, `test_requestDeposit_capacityZeroStillAcceptsUnlimitedDepositsIntoSpUsdc`, `test_requestDeposit_queueConsumesSpUsdcDepositCap`.

### Informational items quantified
- I-2: a 1% fee on a 1,000,000 USDC redeem leaves 10,000 USDC of spUSDC in the vault with `totalSupply == 0`; `take` extracts it; chi is unchanged (`test_requestRedeem_feeLeavesChiUnchangedAndRaisesBackingPerShare`).
- I-3: UNPAUSER_ROLE cannot unpause (`test_unpause_unpauserRoleCannotUnpause`).
- I-4: `minWithdraw` is gross of fee; net payout can be 1% below it (`test_requestRedeem_minWithdrawIsGrossOfFee`).
- I-6: donated spPRIME is stuck and consumes capacity; queues are unaffected (`test_transfer_toVaultStrandsSharesWithoutBreakingQueues`).
- I-7: prime yield paid to a queued redeemer comes from other holders' backing when spUSDC earns less: 5,000 USDC on 100,000 after a year at 5% vs 0% (`test_processRedeemQueue_primeYieldAccruesWhileQueued`). Rate-mismatch table (1,000,000 USDC, 365 days, surplus = backing minus notional):

| spUSDC \ spPRIME | 0% | 4% | 5% |
|---|---|---|---|
| 0% | +1 wei | -40,000 USDC | -50,000 USDC |
| 4% | +40,000 | 0 | -10,000 |
| 5% | +50,000 | +10,000 | 0 |

## 5. Rounding table (proven)

All sites fuzzed over random indexes (10,000 runs) against the exact rational. No row's direction was refuted; the R9 bound is per fill, which is what produces C-1.

| # | Site | Direction | Favours | Proven bound | Test |
|---|---|---|---|---|---|
| R1 | spUSDC `deposit` (366) | down | spUSDC | < 1 spUSDC share; 0 when X < chi_s (C-11) | `testFuzz_R1_*` |
| R2 | capacity to spUSDC shares (633-636) | down, down | vault | gap < 1 + 1/c_s; `totalSupply <= cap` | `testFuzz_R2_*` |
| R3 | `spUSDC.convertToAssets` (653) | down | vault | < 1 USDC wei | `testFuzz_R3_R4_*` |
| R4 | `convertToShares` (654) | down | vault | < 1 share; zero-mint iff s <= ceil((K+1)RAY/chi_s) - 1 | `testFuzz_F4_zeroMintRegion_*` |
| R5 | `minWithdraw` check (426) | down | vault | rejects exact values in [min - 0.5, min) | `testFuzz_R5_*` |
| R6 | fee `_divup` (435) | up | vault | < 1 share above; never 0 for fee > 0 | `testFuzz_R6_*` |
| R7 | liquidity clamp (675) | down | vault | paid <= L | `testFuzz_R7_*` |
| R8 | payout `convertToAssets` (688) | down | vault | < 1 wei below; >= 1 | `testFuzz_R8_R9_*` |
| R9 | spUSDC `withdraw` burn (698) | up | spUSDC | < 1 share per fill; batch of n can exceed balance by n-1 (C-1) | `test_BUG_processRedeemQueue_batchCeilBurnsExceedSpUsdcBalance` |
| R10 | spUSDC `redeem` on cancel (411) | down | spUSDC | loss < 1 + c_s wei | `testFuzz_R10_*` |
| R11 | `_rpow` drip (575, 621) | half-up | neutral | equals python mirror exactly on 112 rows; drift < 1e-18 relative after 10y at 100% | `test_R11_*` |
| R12 | `convertToAssets`/`convertToShares` (590, 594) | down | vault | a - A(S(a)) < 1 + c_p; s - S(A(s)) <= 1 | `testFuzz_R12_*` |

Round trip (deposit, redeem all, fee 0): loss < 2 + c_s + c_p wei, so at most 4 wei at current indexes (observed max 4 wei, first at X = 836). Capacity under-use after repeated processing: at most 2 shares at current indexes.

## 6. Invariants (reusable list)

Held over 100 runs x depth 500 (50,000 calls each, 0 handler reverts) in `test/invariants/d_invariants.t.sol`:

| Invariant | Claim |
|---|---|
| A `sumOfBalancesEqualsTotalSupply` | sum of all balances including vault escrow == `totalSupply` |
| B `vaultBalanceEqualsPendingRedeemShares` | `balanceOf(vault) == pendingRedeemShares` (absent donations) |
| C `pendingDepositEqualsSumOfOpenDepositEntries` | `pendingDepositSavingsShares == sum(depositQueue[i].shares)` |
| D `pendingRedeemEqualsSumOfOpenRedeemEntries` | `pendingRedeemShares == sum(redeemQueue[i].shares)` |
| E `headBookkeeping` | every entry strictly before a head has `shares == 0`; heads <= length |
| F `totalSupplyNeverExceedsCapacityViaMint` | no mint pushes `totalSupply` above `maxCapacity` at mint time |
| G `chiMonotonicAndDripConsistent` | `nowChi()` never decreases; `drip() == nowChi()` |
| H `solvencyWhenSpUsdcRateGePrimeRate` | spUSDC value held minus value owed to open deposit entries >= `totalAssets()` minus one spUSDC share per redeem fill, while spUSDC VSR >= prime VSR and nothing is taken |
| I `usersNeverExtractMoreThanDepositsPlusYield` | USDC paid out <= USDC deposited + USDC minted into spUSDC |
| J `balanceProvenance` | each balance == minted + transfers in + cancel refunds - transfers out - escrowed |
| K `backingExistsSomewhere` | USDC conservation across spUSDC, takers, users, vault |
| L `availableCapacityFormula` | `availableCapacity() == max(0, maxCapacity - totalSupply)` |
| M `noMintOfZeroSharesExceptDust` | zero-share fills counted (F-4) |
| N `spUsdcSharesHeldByVaultAndTaker` | spUSDC supply == vault + taker balances |
| O `processRedeemQueueRevertsOnlyOnCeilBurn` | the only revert from `processRedeemQueue` is `SparkVault/insufficient-balance` (C-1) |

Properties from the unit suites worth keeping as invariants: single redeem fill never reverts (`testFuzz_processRedeemQueue_singleFillNeverReverts`); round-trip loss <= 4 wei (`testFuzz_roundTrip_userNeverProfits`); queued fill never exceeds instant fill (`testFuzz_requestDeposit_queuedDepositorGetsAtLeastAsManySharesAsInstant`); every payout == `convertToAssets(filled)` and every mint == `convertToShares(assets)` regardless of planner parameters (`test_compromised_rebalancer_cannotExtractValue`).

## 7. Suggested code changes

1. `_processRedeemQueue`: re-clamp `remaining_` to `convertToShares(spUSDC.maxWithdraw(this))` on every iteration and `break` at 0 (C-1).
2. `_processRedeemQueue`: wrap the spUSDC `withdraw` so a failing recipient is skipped or paid to `request.owner` instead of blocking the queue (C-2).
3. `setChi`: admin-set floor per call, or admin-only (C-3).
4. Admin: `AccessControlDefaultAdminRulesUpgradeable` or refuse removing the last admin; `require(admin != address(0))` in `initialize` (C-4).
5. `_processDepositQueue`: `if (shares_ == 0) break;` before mutating state, and close entries below 2 spUSDC shares; or `_divup` in the capacity conversion (C-5, F-4).
6. Reject `recipient_ == address(this)`, `== savings`, `== address(0)` in both requests and both cancels (C-6).
7. `setMaxRedeemFee` clamps `redeemFee`; `setVSRBounds` drips then clamps `vsr` (C-7).
8. Sanity bounds in `setMinimums`; `require(savingsShares_ != 0)` in `requestDeposit` (C-8, C-11, F-5).
9. Gate `unpause` on `UNPAUSER_ROLE` or delete the constant (I-3).
10. Netting deposits against redeems (existing TODO) removes C-5, C-10 and most instant-path fragility.
11. Launch values: `maxVSR` 10-15% APY, non-zero `redeemFee`, `minDeposit`/`minWithdraw` >= 1e6.

## 8. Open questions for the business team

From the first pass (still open unless noted):
1. When a queued depositor cancels after the planner took their spUSDC: wait in a queue, or revert until liquidity returns?
2. Should a deposit cancel carry the same fee as a redeem request?
3. Should cancels work while paused?
4. Should `take()` work while paused?
5. Does a guardian compliance-cancel still forfeit the up-front fee?
6. Is the burned fee meant to accrue to vault equity (takeable) or to a fee receiver?
7. Launch `minDeposit` / `minWithdraw`, and reject zero amounts outright?
8. Does `minWithdraw` apply gross or net of fee?
9. Can the planner lower capacity below `totalSupply` at will?
10. Who holds GUARDIAN, UNPAUSER and DEFAULT_ADMIN?

New:
11. Is RISK_MANAGER a hot key in production? If yes, what loss floor per `setChi` call is acceptable (C-3)?
12. What `maxVSR` is acceptable as the blast radius of a SETTER compromise (C-9)?
13. When a redeem recipient cannot receive USDC (blacklist), should the entry be skipped, parked, or paid to the owner (C-2)?
14. Should capacity hogging via free redeem requests be tolerated until netting lands, or does launch require a non-zero fee (C-10)?
15. Is "instant deposits only while the planner runs regularly" an acceptable product property (C-5)?
16. Compliance can only cancel open queue entries. Once a sanctioned address is filled (instantly, the common case), the only tool is pausing everyone. Is that acceptable, or does the guardian need a per-address freeze?
17. Should `requestDeposit` be rejected outright when capacity is zero, and should the deposit queue be capped so it cannot exhaust spUSDC's deposit cap (E-3)?

## 9. Known limitations of this campaign

- Local harness uses a mock USDC without blacklist; C-2 is simulated with a mocked revert. A fork test against real USDC is recommended.
- Invariant H is only checked while spUSDC rate >= prime rate and nothing is taken; the random walk breaks that order early in most runs.
- Frequencies for C-1 come from a Python model at current indexes; direction (0 for one fill, growing with N) is proven by tests.
- Loss realisation economics, ERC-7540 and the coming deposit-cancel queue were not reviewed.
