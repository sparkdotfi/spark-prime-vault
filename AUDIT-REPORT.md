# spPRIME (`src/SparkPrimeVault.sol`) review and testing campaign: final report, round 3

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
| Informational | 12 | see section 4 |

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

# Appendix A: round 2 report (`0bc9288`)


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

# Appendix B: round 1 report (branch `review/poc-tests`, `807739f` + review patches F-1, F-3)


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
