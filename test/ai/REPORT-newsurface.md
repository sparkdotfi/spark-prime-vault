# NEWSURFACE worker report

## Round 6 (`master` @ `c512609`)

Target: `src/SparkPrimeVault.sol` on `master` @ c512609. Files: `test/ai/NewSurface.t.sol` (58
tests), `test/ai/Blacklist.t.sol` (53), `test/ai/AdjustTotalAssets.t.sol` (21). All 153 test
runs pass (`test_BUG_` tests are passing proofs that pin the behaviour; two fuzz properties at
20000 runs). Harness constants unchanged (chi_s = 1.047633055711877768967605062e27, chi_p =
1.009687768242461209408770821e27, 1_000_000e6 USDC = S_1M = 954_532_691_143 spUSDC = SH_1M =
990_405_184_109 spPRIME; a full redeem of SH_1M pays R_1M = 999_999_999_998 and burns all S_1M; a
full cancellation refunds A_1M = 999_999_999_999).

Porting notes: every `recipient-cannot-receive` test became an "accepted at request, parked at
fill" test (there is no blacklist check any more); `requestDepositCancellation` takes
`(id, recipient, savingsShares)` everywhere; `adjustTotalAssets` moved to `lossManager`; `pause`
PAUSER / `unpause` UNPAUSER; events carry `requestId` first (asserted through
`ISparkPrimeVault.X`); ids below the head are read with `vm.load` on slots 0-2 (`_rawRequest`);
the two deferred-head-walk tests were rewritten for the cancel self-skip; `test_BUG_V2_9_*`
(zero-share redeem ghosts) became `test_fixed_V2_9_*` + `test_BUG_R5_14_*`; the ghost-deposit
walk tests became `test_fixed_R5_9_*` + `test_BUG_R5_15_*`; `test_BUG_V2_13_vault*` became
`test_fixed_V2_13_*` (spUSDC variants stay `test_BUG_`). Deleted: `test_requestRedeem_zeroSharesRevertsWithMinRedeem`
(subsumed by `test_fixed_V2_9_*`), `test_updateRecipient_outOfRangePanics` (ids past the end are
`InvalidRequestId` now, covered in `test_updateRecipient_zeroRecipientThenInvalidId`).

### (a) New findings on c512609

#### N6-1 (info): range getters panic on `startId_ > length`, accept `length_ == 0`
`getPending{Deposit,DepositCancellation,Redeem}Requests(startId_, length_)` (:707, :755, :802)
compute `_requests.length - startId_` before the `LengthTooLarge` check, so a `startId_` past the
end panics 0x11 instead of reverting `LengthTooLarge`. The natspec (`ISparkPrimeVault` :855,
:893, :925) says `length_ == 0` reverts; it returns an empty array (`(0, 0)` on an empty queue,
`(length, 0)` on a full one). `test_getPendingRequests_range_zeroLengthAndStartPastEnd`.

#### N6-2 (info): natspec still says cancellations are pause-gated
`requestDepositCancellation` (`ISparkPrimeVault` :723) and `processPendingDepositCancellations`
(:642) are documented as "while the vault is not paused"; neither has `whenNotPaused` (:405,
:326). Both work while paused, including the blacklist fallback inside the settlement.
`test_fixed_R5B_requestDepositCancellation_worksWhilePaused`,
`test_processPendingDepositCancellations_fallbackWhilePaused`.

#### N6-3 (info, consequence of G-1): a bricked index now also blocks cancellations
`requestDepositCancellation` ends in `_processPendingDeposits(0, max)` (:445) which drips (:859),
so once chi is above the drip bound (G-1) the cancel path reverts too; on 0ebb452 it survived.
Updaters, `transfer` and `claim` still work. Pinned inside
`test_BUG_G1_adjustTotalAssets_aboveDripBoundBricksVault_onlyUpgradeRecovers`.

#### N6-4 (low): double blacklist (vault + recipient) parks the queue, owner can self-rescue
If USDC blacklists the vault itself: approvals to the vault and deposits die in USDC, clean
redeems and cancellations still pay (spUSDC pushes USDC straight to the recipient), `claim` is
dead, and a blacklisted recipient at the head makes the fallback withdraw-to-vault revert inside
USDC (`Blacklistable: account is blacklisted`), so the walk reverts with any `maxRequests`
(dave behind bob gets nothing). The entry is not settled, so its owner can `updateRedeemRecipient`
to a clean address and the queue moves again. Needs both blacklists.
`test_blacklistedVault_cleanPayoutsWork_fallbackRevertsAndEntrySticks`,
`test_blacklistedVault_claimDeadUntilUnblacklisted`.

#### R5-14 (open, info): `requestRedeem(minRedeem)` at a nonzero fee queues a zero-share entry
With `minRedeem == 1` and any fee > 0 (even 0.01%), `_divUp(1 * fee, WAD) == 1` (:463) burns the
whole share and queues `shares == 0`: `RedeemRequest(0, mallory, mallory, 1, 1)`, entry
`(mallory, mallory, 0)`, `NoRequest` on the updater. Changed vs round 5: the walk clears such
ghosts (a zero-share fill is a `withdraw(0)` no-op and the entry is deleted), so they are not
permanent, but each still costs one unit of `maxRequests` (three ghosts, `maxRequests == 3`:
alice unpaid, head 3). `minRedeem >= 2` makes it impossible at the 1% cap.
`test_BUG_R5_14_requestRedeem_minRedeemAtNonzeroFeeQueuesZeroShareEntry`,
`test_requestRedeem_minRedeemTwoCannotGhost`. 1-share cancellations at `minDepositCancellation
== 1` bloat the cancellation queue (50 entries, 1 wei USDC each):
`test_BUG_R5_14_oneShareCancellationsBloatTheCancellationQueue`.

#### R5-15 (open, low at launch minimums): 1-wei deposits mint 0 spUSDC shares, leave dead slots
`requestDeposit(1)` at `minDeposit == 1`: `spUSDC.deposit(1)` mints `1 * RAY / chi_s == 0`
shares, the wei stays in spUSDC (donation), the entry `(mallory, mallory, 0)` is pushed behind
the live head and cannot be cancelled or re-pointed (`NoRequest`); it is walked as a cancelled
slot and costs one unit of `maxRequests`. Cheapest dead slot a griefer can make; gone with a
`minDeposit` of 1 USDC or more. `test_BUG_R5_15_requestDeposit_dustMintsZeroSharesAndLeavesDeadSlot`.

#### R5-9 residue (measured): dead slots behind a live head
Self-skip only clears entries AT the head: with alice live at the head, 500 `minDeposit`-sized
(100 USDC) request-then-cancel loops leave 500 dead slots behind her (each loop refunds
99_999_999, 1 wei of spUSDC floor lost). After alice fills, the first walk past them pays:
`requestDeposit` walking 500 dead slots costs 1_468_029 gas vs 273_029 with no walk
(~2.4k per slot, i.e. cold-SLOAD cost; ~1.2M for 500), once. The operator can drain them in
chunks with `processPendingDeposits(0, n)` first, so the instant-fill depositor only pays if the
operator does not. `test_requestDepositCancellation_deadSlotsBehindLiveHeadCostTheFirstWalkOnce`,
`test_processPendingDeposits_operatorDrainsDeadSlotsInChunks`,
`test_processPendingDeposits_maxRequestsCountsCancelledEntries`.

#### C-3 / R5-3 re-rated (open, HIGH): no loss floor, now a hot-wallet role
Unchanged numbers (alice 1M + bob 100k: `-(TA - 1)` writes chi = 917_897_971_131_388, every
`assetsOf` and `totalAssets()` read 0 with S_1M + S_100K spUSDC still backing; MAX_VSR for a year
lifts `totalAssets()` to 1 wei; `+ (TA - 1)` recovers to 1_099_999_999_996). What changed: the
caller is `LOSS_MANAGER_ROLE`, an operational key, not a governance spell, so one compromised key
(plus `PAUSER`) zeroes the index in one call, and the same key can deliberately run the sandwich
below. `test_BUG_C3_adjustTotalAssets_noFloor_totalAssetsMinusOneWipesHolders`.

#### R5-2 (open, medium): sandwich around the pause, re-quantified
Alice 1M, attacker deposits 1M (instant fill) before the pause, loss manager adjusts +50k,
unpause, attacker queues a full redeem: chi 1_034_929_962_448_270_700_987_302_681, payout
1_024_999_999_998 (profit 24_999_999_998 at 0% fee; 1_014_749_999_997 / 14_749_999_997 at the 1%
cap); alice's claim exceeds the backing by 49_999_999_999 (39_749_999_998 at 1%). New on
c512609: cancellations are not pause-gated, so a queued depositor who sees a loss coming walks out
during the pause at A_1M while alice takes the whole 50k (949_999_999_997).
`test_BUG_R5_2_governanceSandwich_zeroFee`, `_onePctFee`,
`test_BUG_R5_2_queuedDepositorExitsDuringPauseBeforeLoss`.

#### G-1 / R5-1 (open, high): unchanged numbers, now one LOSS_MANAGER call
`GAIN_BRICK = 114_681_085_459_449_903_921_528_244_645_760_029` at supply SH_1M writes chi
`115_792_089_237_316_195_423_570_985_008_687_908_517_705_232_418_866` (664_435_247_753_226 above
`maxUint256 / RAY`); one wei less survives. Every path that drips or converts then panics 0x11,
including `adjustTotalAssets` and (new) `requestDepositCancellation`; only `upgradeToAndCall`
(admin) recovers. `test_BUG_G1_*` (two tests).

### (b) Status of prior findings touched

| Finding | Status on c512609 | Pinning test |
|---|---|---|
| R4-A blacklisted redeem recipient blocks the queue | fixed (try/catch) | `test_fixed_R4A_processPendingRedeems_queueContinuesPastBlacklistedRecipient` |
| R4-B blacklisted cancellation recipient blocks the queue | fixed | `test_fixed_R4B_processPendingDepositCancellations_queueContinues` |
| R4-A/B residue: reverting contract / blacklisted / spUSDC recipients | contract recipient paid directly (USDC never calls it); blacklisted parked; spUSDC donates | `test_processPending*_revertingContractRecipient_paidDirectly`, `_catchBranch`, `test_BUG_V2_13_savingsAs*` |
| Non-recipient revert must propagate | holds: stale liquidity bound reverts both calls with `SparkVault/insufficient-liquidity`, nothing parked; selector-wide revert propagates | `test_drainedLiquidity_staleBound_bothCallsRevertAndPropagate`, `test_spUsdcRevertsForEveryReceiver_walkReverts` |
| V2-13 / R5-7 vault as recipient | fixed for the vault in all 6 paths (`VaultIsRecipient`, before id/owner checks) | `test_fixed_V2_13_{requestDeposit,requestRedeem,requestDepositCancellation,updaters}_vaultRecipientReverts` |
| V2-13 spUSDC as recipient | open (low): 1_000_000_000_001 surplus donated to spUSDC, redeem and cancellation | `test_BUG_V2_13_savingsAs{Redeem,Cancellation}Recipient_donatesToSpUsdc` |
| R5-9 ghosts / frozen head | partially fixed: zero-asset deposits impossible, head cancel self-skips, budget-0 walk advances; dead slots behind a live head remain (measured above); 1-wei deposits still make 0-share slots at `minDeposit == 1` | `test_fixed_R5_9_*` (2), `test_requestDepositCancellation_cancelledEntryBehindLiveHeadWaits`, `test_processPendingDeposits_zeroBudgetAdvancesHeadPastCancelledEntries`, `test_BUG_R5_15_*` |
| R5-B pause traps queued depositors | fixed (cancellations and settlement not gated) | `test_fixed_R5B_requestDepositCancellation_worksWhilePaused` |
| C-8 minimums | zero rejected at init and in the setters; unbounded above (`type(uint256).max` blocks every cancel / deposit / redeem) | `test_fixed_C8_minimums_zeroRejectedAtInit_unboundedAbove` |
| V2-1 recipient updaters | fixed (owner-only, incl. partial fills and partial cancels) | `test_fixed_V2_1_*` (3) |
| V2-2 / F-1 pauser cancel | fixed (6 roles rejected) | `test_fixed_V2_2_rolesCannotCancelDeposits` |
| V2-9 `requestRedeem(0)` | fixed by `minRedeem != 0`; R5-14 remains at `minRedeem == 1` | `test_fixed_V2_9_requestRedeem_zeroSharesRevertsBelowMinRedeem`, `test_BUG_R5_14_*` |
| V2-7 / R5-8 unbounded `setCapacity` | open; also bricks the cancel self-skip walk | `test_BUG_V2_7_setCapacity_maxUint256BricksDeposits` |
| G-2 `uint192` wrap | fixed (`ChiTooHigh`) | `test_fixed_G2_adjustTotalAssets_chiTooHighBoundary` |
| G-1 / R5-1 | open, high | `test_BUG_G1_*` |
| C-3 / R5-3 | open, re-rated high | `test_BUG_C3_*` |
| R3-1 / R5-2 | changed (pause required; cancellations not gated) / open | `test_fixed_R3_1_adjustTotalAssets_requiresPause_requestsAndFillsBlockedWhilePaused`, `test_BUG_R5_2_*` (3) |

### (c) Code paths and the test that covers each

Blacklist / claim (`Blacklist.t.sol`):
- `requestRedeem` accepts blacklisted recipient (:454-456): `test_requestRedeem_blacklistedRecipient_acceptedAndParkedAtFill`; blacklisted owner: `_blacklistedOwner_success`; un-blacklisted between request and fill: `_unblacklistedBetweenRequestAndFill_paysDirectly`; spUSDC accepted: `_savingsRecipient_accepted`.
- `requestDepositCancellation` (:414-446): accepted/parked, partial parked, blacklisted owner, bad id is `InvalidRequestId`: `RequestDepositCancellationBlacklistTests` (3).
- Updaters (:482-525) to/away from blacklisted, blacklisted owner, parked entry `NoRequest`: `UpdateRecipientBlacklistTests` (7).
- `requestDeposit` (:386) blacklisted sender dies in `transferFrom`, blacklisted recipient minted and transfers, `updateDepositRecipient` to blacklisted: `RequestDepositBlacklistTests` (3).
- `_withdrawSavings` try branch (:1001-1004) / catch branch (:1011-1013): `test_processPendingRedeems_cleanRecipient_directBranch`, `_blacklistedRecipient_catchBranch` (events `ClaimableAssetsIncreased(alice, 999_999_999_998)` then `Redeem(0, alice, alice, SH_1M, 954_532_691_143, 999_999_999_998)`, `claimableAssets`, `totalClaimable`, vault USDC all exact); partial fills 299_999_999_999 + 699_999_999_998 (1 spUSDC share of dust left); flips; same recipient x2 = 199_999_999_996; three recipients (bob 2x, carol, dave clean) total 3 * R_100K: `ProcessPendingRedeemsBlacklistTests` (9).
- `_redeemSavings` try / catch (:982-994): the same shapes for the cancellation queue (299_999_999_999 + 699_999_999_999): `ProcessPendingDepositCancellationsBlacklistTests` (8).
- Non-recipient reverts: `NonRecipientRevertTests` (3).
- `claim` (:531-543): `NothingToClaim` (0, address(0), vault, after a clean payout), reverts in USDC while blacklisted with state retained, permissionless exact payout + `Claim` event, `totalClaimable` decremented per recipient, works while paused, sums both queues (199_999_999_997): `ClaimTests` (6).
- Claimable isolation: invisible to `totalAssets`, `availableLiquidAssets`, `availableCapacity`; untouched by every other external function (deposit instant/queued, updaters, partial cancels, redeem, `take`, `_returnToVault`, `adjustTotalAssets` both signs, both VSRs + drip, fee / minimum / bound setters): `ClaimableIsolationTests` (2 + fuzz).
- Fuzz (20000 runs): two redeem entries + two cancellation entries to four recipients, any blacklist mask, any liquidity fraction over two rounds, claims in order: vault USDC == `totalClaimable` == sum of `claimableAssets` at every step, parked == payout (±2 wei of floor), zero at the end: `testFuzz_fallbackAccounting_vaultUsdcEqualsTotalClaimableEqualsSum`.
- Vault / spUSDC as recipient: `VaultAsRecipientTests` (6). Blacklisted vault: `BlacklistedVaultTests` (2).

`adjustTotalAssets` (`AdjustTotalAssets.t.sol`):
- Access from the seven non-holders (admin included) + enumerable role: `test_adjustTotalAssets_notLossManager`; `IsNotPaused` (both signs, before `ZeroDeltaTotalAssets`), `ZeroDeltaTotalAssets`, `LossTooHigh` boundary (`-TA`, `-TA-1`, `-1M`, `int256.min` revert; `-(TA-1)` writes 1_009_687_768_243_692), zero-supply panics (0x12 on +1, 0x11 on `int256.max`, `LossTooHigh` on -1), `ChiTooLow` at 1e28 supply via stdstore (`-> 9` reverts, `-> 10` writes chi 1), `ChiTooHigh` (`GAIN_TRUNCATE`, one less writes 6_277_101_735_386_680_763_835_789_423_207_666_416_102_354_893_009_973_700_482), overflow panics above `GAIN_OVERFLOW`.
- Loss -100k (chi 908_718_991_417_304_243_366_635_929, TA 899_999_999_997), gain +100k (chi 1_110_656_545_066_042_825_345_107_777), exact `TotalAssetsAdjusted` both signs, drip-first (`Drip(1_110_656_545_066_707_330_303_098_475, 99_999_999_999)` precedes), round trip -2 wei, compose, per party under -200k (holder and escrow -100_000_000_000 each, queued deposit / pending cancellation / parked claimable R_100K untouched, carol fills 110_045_020_455 shares), capacity in shares (89_999_999_998 after the loss).
- Sandwich (3), C-3, G-1 (2).

NewSurface (`NewSurface.t.sol`):
- Updaters (:482-525): `UpdateRecipientTests` (13) incl. `ZeroRecipient` -> `VaultIsRecipient` -> `InvalidRequestId` -> `NoRequest` -> `NotRequestOwner` order, partial-fill and partial-cancel remainders.
- Pause (:356-368, `whenNotPaused` on :377/:451/:321/:338): `PauseTests` (6): roles, events, idempotent pause, gates vs non-gates, cancellations + settlement + fallback while paused.
- `setCapacity` (:304): `CapacityTests` (2).
- `minRedeem` (:456, :463): `RedeemMinimumTests` (3).
- Head walk (:445, :858-900): `HeadWalkTests` (9): self-skip at head, cancelled behind live head waits, budget-0 and capacity-0 walks advance, `maxRequests` counts dead slots, griefing measured, chunked drain.
- `requestDepositCancellation` (:405-446) + `setMinDepositCancellation` (:230): `DepositCancellationTests` (12): admin-only, zero rejected (all three setters and `initialize`), event, revert order (7 errors), partial keeps position / counters / three cancel entries / 799_999_999_999 + 2 x A_100K, remainder fills for 891_364_665_698 shares, cancel after a partial fill (900_000_000_001 refund), minimum in spUSDC share units, 1-share bloat, fuzz split sums to A_1M - 1 at most.
- Getters (:669-809): `GetterTests` (11): single window, range window for the three queues, zero length / start past end, storage layout (slots 0-2, 18), `asset`/`savings`/`decimals`/`version`, `DOMAIN_SEPARATOR`, `take` + `InsufficientShares` + `Take` event, `delete` after fill in all three queues.
- Events (requestId first): `EventShapeTests` (6): `Referral(7, 0, ..)` -> `DepositRequest(0, ..)` -> `Deposit(0, .., S_1M, A_1M, SH_1M)` order, queued deposit emits no `Deposit`, `RedeemRequest(0, alice, bob, SH_1M, 9_904_051_842)` at 1% then `Redeem(0, .., 980_501_132_267, 944_987_364_230, 989_999_999_997)`, partial redeem `(SH_100K, 95_453_269_113, 99_999_999_998)`, `DepositCancellationRequest(id, 0, bob, S_100K)` / `DepositCancellation(0, alice, bob, S_100K, A_100K)`, `Drip` first on every walk.

### (d) Properties that held
- No blacklist check exists at request time: all four recipient-taking entry points accept a
  blacklisted address and the fallback parks the exact clean-path payout; `Redeem` /
  `DepositCancellation` carry identical amounts on both branches.
- The catch is recipient-only in effect: liquidity reverts and selector-wide reverts propagate
  with no state change and nothing parked.
- vault USDC == `totalClaimable` == sum of `claimableAssets` across both queues, partial
  liquidity, blacklist flips and claims (20000 fuzz runs); nothing but `claim` moves vault USDC.
- The self-skip clears every dead slot at the head in the cancel call itself (three dead slots in
  one cancel), and `_processPendingDeposits(0, max)` with capacity 0 does the same.
- Cancellation splits sum to the whole: `convertToAssets(first) + convertToAssets(S_1M - first)`
  is within 1 wei of A_1M for every split (20000 runs).
- `claim` is reentrancy-safe by construction (state zeroed before the transfer, :536-542) and
  the USDC revert leaves `claimableAssets` / `totalClaimable` untouched.
- Storage: arrays at slots 0-2, `totalClaimable` at 18, as pinned in CAMPAIGN.md.

### (e) Unsettled
- The "drained liquidity" non-recipient revert cannot be reached naturally in one tx (both
  walks bound themselves by `maxWithdraw` / `maxRedeem` first); it is proven with mocked bound
  views over really-drained liquidity, which exercises the real `SparkVault/insufficient-liquidity`
  revert in both the try and the fallback.
- The dead-slot gas figure (~2.4k per slot) is as measured by forge 1.8.6 inside one test tx;
  mainnet cold-SLOAD cost is 2_100 + loop overhead, so the order of magnitude stands.
- C-1 / R5-4 (per-entry liquidity bound) is pinned by the redeem-queue worker, not here; this
  suite only relies on it for the partial-fill numbers, which did not change for single entries.


## Round 5 (`master` @ `0ebb452`)

Target: `src/SparkPrimeVault.sol` on `master` @ 0ebb452. Files: `test/ai/NewSurface.t.sol` (32
tests, ported), `test/ai/AdjustTotalAssets.t.sol` (23 tests, new), `test/ai/Blacklist.t.sol` (48
tests, new). All 103 pass (`test_BUG_` tests are passing proofs that pin the behaviour). Harness
constants unchanged (chi_s = 1.047633055711877768967605062e27, chi_p =
1.009687768242461209408770821e27, 1_000_000e6 USDC = S_1M = 954_532_691_143 spUSDC = SH_1M =
990_405_184_109 spPRIME; a full redeem of SH_1M pays R_1M = 999_999_999_998 and burns all S_1M; a
full cancellation refunds A_1M = 999_999_999_999).

Porting notes: `realizeGain`/`realizeLoss` tests rewritten against `adjustTotalAssets` (moved to
`AdjustTotalAssets.t.sol`); the guardian-cancel test became `test_fixed_V2_2_*`; the two
head-advance-loop tests were rewritten for the deferred walk (the head only moves inside
`_processPendingDeposits`, :861); `Redeem` now carries `savingsSharesBurned`; the old
`test_uint192Casts_onlyRealizeGainCanWrap` became `test_fixed_G2_*` (the cast is now guarded).

### (a) Bugs and suspicious behaviour

#### G-1 (open, high): `chi` above `maxUint256 / RAY` bricks the vault; only an upgrade recovers
`adjustTotalAssets` (:278-295) bounds `chi` by `type(uint192).max` (:292) but `drip` (:637) and
`nowChi` (:811) compute `_rpow(vsr, dt) * chi` in uint256, so any `chi > CHI_DRIP_MAX =
115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640` reverts one second later at
`vsr == RAY`. Binary-searched with `vm.snapshotState`: at supply SH_1M the smallest delta is
`GAIN_BRICK = 114_681_085_459_449_903_921_528_244_645_760_029` (~1.15e29 USDC), writing chi =
`115_792_089_237_316_195_423_570_985_008_687_908_517_705_232_418_866` (664_435_247_753_226 above
the bound; one wei less writes `..._907_508_017_464_175_173`, which survives). Afterwards `drip`,
`nowChi`, `totalAssets`, `convertToShares`, `requestDeposit`, `requestRedeem`, all three
`processPending*`, `setVSR` and `adjustTotalAssets` itself (it drips first, :282) revert with
panic 0x11; `transfer` and `requestDepositCancellation` still work. Recovery proven only through
`upgradeToAndCall` to an implementation that rewrites `chi` (`_authorizeUpgrade` :272 does not
drip). The band shrinks with the VSR: a chi that survives at `vsr == RAY` overflows one second
after `setVSR(ONE_PCT)`. Tests: `test_BUG_G1_adjustTotalAssets_aboveDripBoundBricksVault_onlyUpgradeRecovers`,
`test_BUG_G1_adjustTotalAssets_dripBoundShrinksWithVsr`. Fix: bound `updatedChi_` by
`type(uint256).max / RAY` (or lower) instead of `uint192`.

#### C-3 (open, medium): no loss floor
`-(totalAssets - 1)` is accepted (:286). With alice 1M + bob 100k (supply 1_089_445_702_519, TA
1_099_999_999_997) one admin call writes chi = floor(RAY / S) = 917_897_971_131_388; `totalAssets()`
and every `assetsOf` read 0 while S_1M + S_100K spUSDC still back the vault. MAX_VSR for a year
lifts `totalAssets()` to 1 wei. Recovery via `+ (TA - 1)` lands at 1_099_999_999_996.
`test_BUG_C3_adjustTotalAssets_noFloor_totalAssetsMinusOneWipesHolders`. The `loss-too-high`
boundary itself is exact: `-TA`, `-TA-1`, `type(int256).min` all revert, `-(TA-1)` passes
(`test_adjustTotalAssets_lossTooHighBoundary`).

#### R3-1 residue (open, medium): governance-flow sandwich
`adjustTotalAssets` requires `paused`, but the admin is a spell whose payload is public before the
GUARDIAN's `pause` tx. Alice 1M, attacker deposits 1M (instant fill) before the pause, admin
adjusts +50k, unpause, attacker queues a full redeem: chi 1_034_929_962_448_270_700_987_302_681,
payout 1_024_999_999_998 (profit 24_999_999_998 at 0% fee; 1_014_749_999_997 / profit
14_749_999_997 at the 1% max fee). The gain is notional, so alice's claim exceeds the remaining
backing by exactly 49_999_999_999 (39_749_999_998 at 1%).
`test_BUG_R3_1_governanceSandwich_zeroFee`, `_onePctFee`. Mitigation is procedural (pause
before the payload is public) or a withdrawal delay after unpause.

#### V2-13 (open, low): vault / spUSDC as redeem or cancellation recipient strands USDC
`requestRedeem`, `requestDepositCancellation` and both updaters accept the vault and spUSDC
(only the blacklist is checked). `_canReceiveAsset(vault)` is true (:938/:951) so the withdraw
goes to the vault with NO `claimableAssets` entry: R_1M (redeem) / A_1M (cancellation) of USDC
sits in the vault, `claim(vault)` and `claim(alice)` say `nothing-to-claim`, and no later
deposit or `take` moves it. With spUSDC as recipient, spUSDC burns S_1M of the vault's shares
and transfers R_1M to itself: its USDC balance is unchanged, its supply drops, its index does not
move, leaving 1_000_000_000_001 of unaccounted surplus in spUSDC (donation to spUSDC holders).
`test_BUG_V2_13_vaultAsRedeemRecipient_strandsUsdc`, `_vaultAsCancellationRecipient_strandsUsdc`,
`_savingsAsRedeemRecipient_donatesToSpUsdc`, `test_updateRedeemRecipient_vaultRecipient_accepted`.
Fix: reject `address(this)` and `savings` in the three blacklist-checked recipient paths like
`requestDeposit` already does (:395).

#### Double blacklist (info): vault blacklisted + blacklisted recipient at the head
If USDC blacklists the vault itself, deposits die at the pull (:400) and `claim` reverts, but
clean redeems/cancellations still pay (spUSDC pushes USDC straight to the recipient). The fallback
path withdraws to the vault and reverts inside USDC, so a blacklisted recipient at the head blocks
the walk again (R4-A shape, needs both blacklists; a bounded `maxRequests` cannot skip it).
`test_blacklistedVault_cleanRedeemsPay_fallbackEntryBlocksWalk`.

#### V2-7, V2-9 (open, unchanged)
`setCapacity(type(uint256).max)` bricks `requestDeposit`/`processPendingDeposits` (safe bound at
supply 0: 114_681_085_459_589_801_375_833_087_904_206_311_575_507_395_147_570 shares, shrinking
with chi); `requestRedeem(0)` ghosts are permanent and consume `maxRequests`.
`test_BUG_setCapacity_maxUint256BricksDeposits`, `test_BUG_V2_9_*`.

### (b) Previously reported findings, status on 0ebb452

| Finding | Status | Pinning test |
|---|---|---|
| R4-A blacklisted redeem recipient blocks the queue | fixed | `test_fixed_R4A_processPendingRedeems_queueContinuesPastBlacklistedRecipient` |
| R4-B blacklisted cancellation recipient blocks the queue | fixed | `test_fixed_R4B_processPendingDepositCancellations_queueContinues` |
| R3-1 `realizeGain` without pause | changed: `not-paused` required, requests blocked while paused; sandwich remains around the pause tx | `test_fixed_R3_1_adjustTotalAssets_notPaused_andRequestsBlockedWhilePaused`, `test_BUG_R3_1_*` |
| V2-1 unauthenticated recipient updaters | fixed (owner-only) | `test_fixed_V2_1_update{Deposit,Redeem,DepositCancellation}Recipient_*` |
| V2-2 / F-1 guardian cancel path | fixed (removed) | `test_fixed_V2_2_guardianCannotCancelDeposits` |
| G-2 `uint192` wrap in gain | fixed (`chi-too-high`) | `test_fixed_G2_adjustTotalAssets_chiTooHighBoundary` (GAIN_TRUNCATE = 6_216_874_099_906_568_962_213_193_772_734_343_774_180_112 reverts; one less writes 6_277_101_735_386_680_763_835_789_423_207_666_416_102_354_893_009_973_700_482) |
| G-1 drip overflow brick | open | see (a) |
| C-3 no loss floor | open | see (a) |
| V2-13 vault / spUSDC recipients | open | see (a) |
| V2-7 unbounded `setCapacity` | open | `test_BUG_setCapacity_maxUint256BricksDeposits` |
| V2-9 `requestRedeem(0)` ghosts | open | `test_BUG_V2_9_*` |
| `cancelRedeemRequest` / `no-shares` / dead event | gone | `test_updateRedeemRecipient_filledEntryRevertsNoRequest` (selector reverts) |

### (c) Properties that held

Blacklist (`Blacklist.t.sol`):
- `recipient-cannot-receive` on `requestRedeem` (:452, after `zero-recipient`, before
  `below-minimum`), `requestDepositCancellation` (:425, before the entry load, fires on bad ids),
  `updateDepositCancellationRecipient` (:493), `updateRedeemRecipient` (:508); each with the
  `_failure` / `_success` pair.
- The owner is never consulted: a blacklisted holder redeems, cancels and re-points to a clean
  recipient; `requestDeposit` / `updateDepositRecipient` do not consult it at all: a blacklisted
  recipient is minted SH_1M, holds and transfers it; a blacklisted depositor is rejected by USDC's
  own `transferFrom` (`Blacklistable: account is blacklisted`).
- Fallback exactness: redeem of SH_1M to a recipient blacklisted after the request emits
  `ClaimableAssetsIncreased(alice, 999_999_999_998)` then `Redeem(alice, alice, SH_1M,
  954_532_691_143, 999_999_999_998)`; vault USDC == claimable; cancellation emits
  `ClaimableAssetsIncreased(alice, 999_999_999_999)` + `DepositCancellation(alice, alice, S_1M,
  999_999_999_999)`. Partial fills (300k liquidity then the rest) accrue twice: 299_999_999_999 +
  699_999_999_998 = 999_999_999_997 (redeem, 1 spUSDC share left in the vault), 299_999_999_999 +
  699_999_999_999 = 999_999_999_998 (cancellation). Blacklist flipped between fills: first pays,
  second accrues. Three entries, one blacklisted recipient: 2 * R_100K summed, clean entry paid.
- `claim`: `nothing-to-claim` for 0 / address(0) / after a clean payout; reverts in USDC while
  blacklisted with claimable and vault USDC retained; after un-blacklisting a stranger's call
  pays alice exactly with `Claim(alice, R_1M)`, zeroes the entry, second call `nothing-to-claim`;
  works while paused; sums redeem + cancellation accruals (199_999_999_997).
- Claimable USDC is invisible to `totalAssets` / `availableLiquidAssets` and untouched by
  `requestDeposit` (instant and queued), `processPendingDeposits`, `requestDepositCancellation` +
  `processPendingDepositCancellations`, `requestRedeem` + `processPendingRedeems`, `take` (all
  spUSDC), `adjustTotalAssets` (-100k/+100k), `setVSR` + drip. Fuzz: vault USDC >= claimable for
  any later deposit and take (1000 runs).

`adjustTotalAssets` (`AdjustTotalAssets.t.sol`):
- Access (7 non-admins), `not-paused`, `delta-total-assets-zero`, `loss-too-high` boundary,
  `totalSupply == 0`: `+1` panics 0x12, `type(int256).max` panics 0x11 (`* RAY`), `-1` is
  `loss-too-high`; `chi-too-low` at an inflated supply of 1e28 (TA 10_096_877_682_424_612_094_087_708_210;
  `-> 9` reverts, `-> 10` writes chi = 1); deltas in `[GAIN_TRUNCATE, GAIN_OVERFLOW)` are
  `chi-too-high`, `>= GAIN_OVERFLOW = 115_792_089_237_316_195_423_570_985_008_687_907_852_269_984_665_643`
  and `type(int256).max` panic.
- Loss -100k: chi 908_718_991_417_304_243_366_635_929, TA 899_999_999_997 (loss + 1 wei of
  floor), backing untouched; gain +100k: chi 1_110_656_545_066_042_825_345_107_777, TA
  1_099_999_999_997. Event exact with negative and positive delta.
- Drip first: after 10% for a year while unpaused, `nowChi` 1_110_656_545_066_707_330_303_098_475
  / TA 1_099_999_999_998 is settled (`Drip` precedes `TotalAssetsAdjusted`) and the delta applies
  on top; accrual continues from the new chi while paused.
- Round trip -100k/+100k is not the identity: chi 1_009_687_768_240_663_846_587_628_160, TA
  999_999_999_996 (2 wei); +/-/+/- costs 2 more.
- Per party under -200k at supply 2 * SH_1M: holder and escrowed redeemer each lose exactly
  100_000_000_000 (R_1M -> 899_999_999_998); queued deposit (S_100K) and pending cancellation keep
  their spUSDC and settle at A_100K; the queued deposit fills for 110_045_020_455 shares worth
  99_999_999_998; the escrow pays 899_999_999_998.
- Capacity is in shares: SH_100K of headroom is worth R_100K before and 89_999_999_998 after a
  -100k loss; a 100k deposit then fills 99_040_518_407 shares (89_999_999_996 USDC) and leaves
  S_100K - 85_907_942_201 spUSDC at the head.

NewSurface (`NewSurface.t.sol`): owner-only updaters incl. partial-fill remainder (bob gets
891_364_665_700), filled / cancelled slots `no-request`, `getPendingXRequest(id)` rejects ids
below the head, updaters work while paused; ghosts do not move the head until capacity returns;
cancellations do not move the head and dead slots consume `maxRequests` (walk of 500 ghosts
costs the next depositor ~237k gas warm, ~1.1M cold, once); `pause` GUARDIAN / `unpause` admin;
event shapes incl. `Redeem(.., 954_532_691_143, 999_999_999_998)` and the partial
`(SH_100K, 95_453_269_113, 99_999_999_998)`.

### (d) Unsettled
- The G-1 threshold is stated for the harness supply and `vsr == RAY`; the general condition is
  `chi * _rpow(vsr, dt) > maxUint256`, which depends on supply, rate and the gap since `rho`.
- Whether the sandwich is exploitable in practice depends on the spell / pause ordering, which
  is off-chain; the on-chain numbers above are exact for 1M/1M/50k.
- Nothing new found in `claim` itself (permissionless, no reentrancy surface: state is zeroed
  before the transfer, :529-533).


## Round 4 (bf93b0d)

Target: `src/SparkPrimeVault.sol` on `fix/update-guardian-transfer` @ bf93b0d. Files:
`test/ai/NewSurface.t.sol` (55 tests in `NewSurfaceTest`, `NewSurfaceRealizeGainTest`,
`NewSurfaceMiscTest`; split kept for the jump-tag limit), `test/ai/CancelledDepositQueue.t.sol`
(22 tests), `test/ai/Views.t.sol` (7 tests). All 84 pass; the fuzz properties pass at 5_000 runs.
Harness constants unchanged (chi_s = 1.047633055711877768967605062e27, chi_p =
1.009687768242461209408770821e27, 1_000_000e6 USDC = 954_532_691_143 spUSDC = 990_405_184_109
spPRIME).

### Fixed or removed since round 3 (regression tests)

- F-1 deposit side (`:422-425`): a non-owner caller must be GUARDIAN and must name the owner;
  `requestDepositCancellation(id, guardian)` and `(id, bob)` revert `invalid-recipient`, `(id,
  alice)` queues `(owner alice, recipient alice, S_1M)` and settles 999_999_999_999 to alice,
  guardian 0. The owner can still repoint the refund afterwards; the guardian cannot
  (`not-authorized`). `test_requestDepositCancellation_guardianMustRefundOwner`,
  `test_updateDepositCancellationRecipient_guardianCancelRefundsOwnerOnly`. The cancelled-queue
  fuzz asserts `invalid-recipient` for every non-owner recipient and cancels to the owner
  (`testFuzz_cancelledQueue_countersTrackOpenEntries`, 5_000 runs).
- `cancelRedeemRequest` removed: the selector reverts, the entry stays open with its shares
  escrowed (`balanceOf(vault) == SH_100K`), a filled slot still rejects the updater with
  `no-request`. `test_updateRedeemRecipient_filledEntryRevertsNoRequest`. A `requestRedeem(0)`
  ghost is now permanent: no cancel, updater says `no-request`
  (`test_requestRedeem_zeroSharesCreatesGhostEntry`). Event `CancelRedeemRequest` (`:101`) is dead
  code (Info).

### Persists (unchanged numbers)

- C-3 no floor under `realizeLoss`: `loss = totalAssets - 1` leaves chi = 1_009_687_768_243_692,
  every holder at 0 (`test_BUG_realizeLoss_noFloor_totalAssetsMinusOneWipesHolders`).
- G-1 / G-2 / G-3 / G-4 on `realizeGain`: brick above `GAIN_BRICK`, `uint192` wrap at
  `GAIN_TRUNCATE` to chi 458_233_707_431_279, overflow revert above `GAIN_OVERFLOW`, no pause
  requirement. Same tests.
- N-4 unbounded `setCapacity`; ghost entries; head-walk gas (500 ghosts: 553_162 vs 164_662
  baseline). Same tests.

### New this round

#### `uint192` casts enumerated (Info)
`initialize` `:248` casts RAY; `drip` `:620` and `nowChi` `:748` cast a quotient that is at most
`maxUint256 / RAY` whenever the multiplication did not revert, and `2^192 / (maxUint256 / RAY) =
54_210_108`, so a chi that drips at all can never be a wrapped value; `realizeLoss` `:378` only
lowers chi (fuzzed); `realizeGain` `:302` is the one cast that can wrap: the smallest gain whose
quotient reaches 2^192 writes chi = 458_233_707_431_279 (quotient minus 2^192, below one gain
step `RAY / supply`), `totalAssets() == 0`. `test_uint192Casts_onlyRealizeGainCanWrap`.

#### Views: range read of a deleted head entry (property)
In all three queues the deleted slot reads as `(0, 0, 0)` through the range getter, the
head-to-end getter excludes it, `(head, head)` is an empty read, past the end reverts
`invalid-range`, and an open entry behind the deleted head is returned with its exact shares.
`test_getPendingRequests_rangeReadOfDeletedHeadEntry`.

### Properties held (round 4 additions)
- Guardian cancel refunds the owner, every other recipient reverts, owner repoint afterwards
  works and the guardian's does not.
- Removed selector reverts; filled and ghost redeem slots reject the updater; escrow intact.
- Deleted-slot reads are stable across all three queues and range forms.

### Unsettled
- Same three as round 3: bound on `realizeGain` (G-1/G-2) and its pause requirement (G-4);
  floor under `realizeLoss` (C-3); netting not on this branch.
- Delete the dead `CancelRedeemRequest` event.


## Round 3 (ff828d2)

Target: `src/SparkPrimeVault.sol` on `refactor/more-simplifying` @ ff828d2. Files:
`test/NewSurface.t.sol` (54 tests in three contracts: `NewSurfaceTest`, `NewSurfaceRealizeGainTest`,
`NewSurfaceMiscTest`; the single contract no longer fits the compiler's jump-tag space) and
`test/CancelledDepositQueue.t.sol` (22 tests). All 76 pass; the three fuzz properties pass at
5_000 runs. Harness constants unchanged: chi_s = 1.047633055711877768967605062e27, chi_p =
1.009687768242461209408770821e27, 1_000_000e6 USDC = 954_532_691_143 spUSDC = 990_405_184_109
spPRIME, totalAssets after that deposit = 999_999_999_998.

### Fixed since round 2 (regression tests)

- V2-1 / N-1 (recipient updaters had no authorization). `:422`, `:471`, `:543` now require
  `msg.sender == request_.owner` after `invalid-recipient` and `no-request`. Owner path keeps the
  exact amounts: fill pays the new recipient 990_405_184_109 spPRIME / 999_999_999_998 USDC /
  999_999_999_999 USDC refund; stranger, guardian, admin and the current recipient revert
  `not-authorized`; filled and cancelled entries revert `no-request` (nothing is written into dead
  slots any more); zero recipient reverts `invalid-recipient` before the index is touched; out of
  range panics 0x32. `test_updateDepositRecipient_ownerRedirectsQueuedDeposit`,
  `_strangerGuardianAdminAndRecipientRevert`, `_ownerRedirectsRemainderOfPartialFill`,
  `_filledEntryRevertsNoRequest`, `_cancelledEntryRevertsNoRequest`,
  `test_updateRedeemRecipient_ownerRedirectsQueuedRedeem`, `_strangerGuardianAndRecipientRevert`,
  `_filledAndCancelledEntriesRevertNoRequest`,
  `test_updateCancelledDepositRecipient_ownerRedirectsRefund`,
  `test_updateRecipient_zeroRecipientReverts`, `test_updateRecipient_outOfRangePanics`.
  Side effect worth keeping: the cancelled entry keeps the depositor as `owner` even when the
  GUARDIAN cancelled and named itself recipient (F-1), so the depositor can re-point the refund to
  themselves before settlement. `test_updateCancelledDepositRecipient_ownerReclaimsGuardianChosenRecipient`.
- V2-3 / N-2 (full loss zeroed chi). `:376` `loss_ > 0 && loss_ < totalAssets_`. `loss ==
  totalAssets`, `totalAssets + 1` and `max` revert `invalid-loss`, chi untouched, vault keeps
  working. `test_realizeLoss_fullLossAndAboveRevertInvalidLoss`. With one share in supply
  (`totalAssets == 1`) no loss is admissible at all. `test_realizeLoss_oneShareSupplyAdmitsNoLoss`.
- V2-6 / N-3 (cancelled queue reverted on spUSDC illiquidity). `:784` budgets by
  `spUSDC.maxRedeem(vault)`. 500k of 1M deployed: pays 477_266_345_571 shares = 499_999_999_998
  USDC, head stays, 477_266_345_572 shares remain, zero liquidity pays nothing without reverting,
  remainder 500_000_000_000 paid after liquidity returns (two floors lose 1 wei total). Batch with
  1_040_000e6 liquidity: alice 999_999_999_999 in full, bob 38_181_307_646 shares = 40_000_000_000,
  total 1_039_999_999_999 <= liquidity, head 1, bob completed later.
  `test_processCancelledDepositQueue_paysWhatLiquidityAllows`,
  `_batchPaysFirstFullyAndSecondPartially`, `_budgetIsMinOfCapAndMaxRedeem`.

### Persists

- C-3: no floor under `realizeLoss`. `loss = totalAssets - 1` is accepted (`:376`) and leaves
  `chi = floor(RAY / S) = 1_009_687_768_243_692`; because `S * floor(RAY / S) < RAY`, `totalAssets()`,
  `assetsOf(alice)` all read 0 while 954_532_691_143 spUSDC (~1M USDC) still sits in the vault. A
  further loss reverts `invalid-loss`; MAX_VSR for a year only doubles chi (totalAssets 1). The
  one recovery is `realizeGain(ta - 1)`, which restores totalAssets to within 1 wei. A hot-wallet
  RISK_MANAGER can still do this in one call while paused. Severity unchanged (Medium, admin-side).
  `test_BUG_realizeLoss_noFloor_totalAssetsMinusOneWipesHolders`.
- Info: the `no-shares` check at `:380` is unreachable. `totalSupply == 0` forces
  `totalAssets() == 0`, so `loss_ < 0` fails first for every loss (1, 1e12, max all revert
  `invalid-loss`). `test_realizeLoss_zeroSupplyRevertsInvalidLossNotNoShares`.
- Info: chi == 0 is still reachable from `realizeLoss` once `totalSupply > RAY` (1e27 shares, a
  1.2e21 USDC vault in the harness): `floor(1 * RAY / S) == 0`, `convertToShares` panics with
  division by zero until admin calls `realizeGain`. `test_realizeLoss_chiZeroStillReachableAboveRaySupply`.
- N-4 (unbounded `setCapacity`), ghost redeem entries, head-walk gas: unchanged, tests moved to
  `NewSurfaceMiscTest` as is.

### New: `realizeGain` (`src/SparkPrimeVault.sol:297-308`)

Behaviour held: `chi' = floor((totalAssets() + G) * RAY / S)` exactly
(1_110_656_545_066_042_825_345_107_777 for G = 100_000e6 on 990_405_184_109 shares), event
`GainRealized(chi', G)`, totalAssets rises by G or G - 1 (exactly G - 1 here: 1_099_999_999_997);
reverts `AccessControlUnauthorizedAccount(DEFAULT_ADMIN_ROLE)` for riskManager / guardian / setter /
rebalancer / alice, `invalid-gain` for 0 (checked before `no-shares`), `no-shares` for empty supply;
works paused and unpaused; undripped VSR yield is folded in first (rho refreshed); holders and
escrowed redeem shares share the gain pro rata (rise in [100_000e6 - 2, 100_000e6] each for a
200k gain), queued spUSDC deposits do not (entry unchanged, fills for fewer shares, same value);
repeated gains accumulate with exact chi; gain G then loss G ends within [TA - 2, TA] and
`chi' <= chi`. `test_realizeGain_exactChiEventAndTotalAssets`, `_revertsForNonAdmin`,
`_revertsOnZeroGain`, `_revertsOnZeroSupply`, `_worksPausedAndUnpaused`, `_dripsBeforeApplyingGain`,
`_escrowedRedeemSharesAndHoldersShareGainQueuedDepositsDoNot`, `_repeatedGainsAccumulate`,
`_thenLossRoundTripBound`.

#### G-1 Low: gain above the drip bound bricks the vault irrecoverably (A-9 via `realizeGain`)
`src/SparkPrimeVault.sol:306` has no upper bound on `gain_`. Once `chi > maxUint256 / RAY =
115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640`, `_rpow(vsr, dt) * chi` at
`:649` (`drip`) and `:698` (`nowChi`) overflows as soon as one second passes. At the harness
supply the smallest such gain is `GAIN_BRICK = 114_681_085_459_449_903_921_528_244_645_760_029`
(~1.15e29 USDC); one wei less gives chi = ...508_017_464_175_173 and drip survives. Scenario: admin
calls `realizeGain(GAIN_BRICK)` (chi = ...517_705_232_418_866, same-block `totalAssets()` still
answers 114_681_085_459_449_903_921_529_244_645_760_026), one second later `drip`, `nowChi`,
`totalAssets`, `convertToShares`, `requestDeposit`, `requestRedeem`, all three `process*Queue`,
`setVSR`, `realizeGain(1)` and (paused) `realizeLoss(1)` revert with panic 0x11. `transfer` and
`cancelDepositRequest` (no drip) still work. No role can undo it; only an upgrade. The safe band
shrinks with the VSR: a chi that survives at `vsr == RAY` overflows one second after
`setVSR(ONE_PCT_VSR)`. Impact: total freeze of funds on an admin typo; admin-only, so Low.
`test_BUG_realizeGain_aboveDripThresholdBricksVault`, `test_BUG_realizeGain_dripThresholdShrinksWithVsr`.

#### G-2 Low: unchecked `uint192` cast wraps a large gain into dust
`:306` casts the quotient without a check. For gains in [6.2e42, 1.16e50) wei at the harness
supply the quotient is >= 2^192 and wraps modulo 2^192. Smallest case: `GAIN_TRUNCATE =
6_216_874_099_906_568_962_213_193_772_734_343_774_180_112` gives chi = 458_233_707_431_279,
`totalAssets() == 0`, `assetsOf(alice) == 0`, and the event advertises the wrapped chi as if it
were intended; one wei less keeps chi below 2^192 (but already far above the G-1 bound). Backing
stays in the vault; a second `realizeGain(ta)` restores the value, so this one is recoverable,
unlike G-1. Impact: a silent write of holders to zero instead of a revert. Admin-only, Low.
`test_BUG_realizeGain_uint192TruncationWrapsChiToDust`.

#### G-3 Info: `(totalAssets + gain) * RAY` overflows above `GAIN_OVERFLOW`
`GAIN_OVERFLOW = maxUint256 / RAY - totalAssets + 1 =
115_792_089_237_316_195_423_570_985_008_687_907_852_269_984_665_643` and `max` revert with panic
0x11; one less goes through (and wraps per G-2). Clean revert, no state change.
`test_realizeGain_uint256OverflowRevertsAboveThreshold`.

#### G-4 Info: no pause requirement
`realizeGain` has neither `whenNotPaused` nor `require(paused)`, while `realizeLoss` requires the
pause. A gain can be written mid-incident with queues live. The sandwich around it is ADVERSARIAL's.
`test_realizeGain_worksPausedAndUnpaused`.

Suggested bound for all four: `require(chi_ <= type(uint256).max / RAY / MAX_RPOW_PER_DRIP)` or
simply `require(gain_ <= totalAssets())`, and compute into a `uint256` before the cast.

### Residual rounding on the cancelled queue (Info)

`maxRedeem` floors liquidity into shares and each fill pays `floor(s_i * chi_s / RAY)`, so
`sum(floor) <= floor(sum) <= liquidity`: a batch cannot revert on liquidity, in contrast to C-1 on
the redeem queue. Fuzz (6 random cancels, random yield up to a year at 10%, random liquidity kept,
random `maxRequests`, 5_000 runs): the call never reverts, pays at most the kept liquidity and at
most `convertToAssets(maxRedeem)`, counters track open entries, and everything clears once
liquidity returns. `testFuzz_processCancelledDepositQueue_neverRevertsOnLiquidity`.
The direction of the mismatch is the safe one but it is visible: with liquidity equal to the exact
assets owed (yield test, 1 year at 10%: 1_099_999_999_998), `maxRedeem` = S_1M - 1 because
`S_1M * chi_s / RAY` is not an integer, so the fill pays `expected - 1`, leaves one spUSDC share
(1 wei) queued with the head at 0, the leftover 1 wei of liquidity converts to 0 shares, and the
entry needs one more wei of liquidity and one more call to close. The `yieldWhileQueuedGoesToCanceller`
expectation changed from `expected` to `expected - 1` for that reason; the test now walks the two
extra steps and ends at exactly `expected`. `test_processCancelledDepositQueue_yieldWhileQueuedGoesToCanceller`.

### Properties held (round 3 additions)

- Owner-only updaters on all three queues, exact payouts to the new recipient.
- `realizeLoss`: `floor((TA - L) * RAY / S)` exact, chi' in [floor(RAY / S), chi] for every
  admitted loss (fuzz, 5_000 runs), escrowed redeem shares take the loss, queued deposits do not.
- `realizeGain`: exact chi, event, bounds above, pro-rata sharing, drip-before-apply.
- Cancelled queue: partial fills at the liquidity clamp with exact amounts, no batch revert (fuzz).

### Unsettled

- Whether `realizeGain` should carry a sanity bound (G-1/G-2) and the pause requirement (G-4).
- What floor `realizeLoss` should enforce below `loss < totalAssets` (C-3).
- Netting (`processQueues`) is still not on this branch.

## Round 2 (0bc9288, merged through 8bbe02b)

Target: `src/SparkPrimeVault.sol` on `refactor/more-simplifying` as merged through
`review/poc-tests-v2` @ 8bbe02b (pause back on GUARDIAN, `realizeLoss` via `totalAssets()`).
Files: `test/CancelledDepositQueue.t.sol` (20 tests), `test/NewSurface.t.sol` (33 tests). All 53
pass; the `test_BUG_*` tests pass by asserting the bug. Both fuzz properties also pass at 20_000 runs.
Harness indexes: spUSDC chi_s = 1.047633055711877768967605062e27, spPRIME chi_p =
1.009687768242461209408770821e27; 1_000_000e6 USDC = 954_532_691_143 spUSDC = 990_405_184_109
spPRIME; a redeem of those spUSDC pays 999_999_999_999 USDC.

## (a) Bugs

### N-1 Critical: recipient updaters have no authorization
`src/SparkPrimeVault.sol:423` (`updateDepositRecipient`), `:467` (`updateCancelledDepositRecipient`),
`:534` (`updateRedeemRecipient`). The only check is `recipient_ != 0`; there is no owner or role
check. Anyone can point any open queue entry at themselves one block before the planner fills it.
- Queued deposit: alice queues 1_000_000e6 (capacity 0); mallory, no role, no balance, calls
  `updateDepositRecipient(0, mallory)`; planner fills; mallory receives 990_405_184_109 spPRIME
  (~999_999.999998 USDC), alice receives 0. The entry's `owner` stays alice, so the only trace is
  the `DepositRecipientUpdated` event. `test_BUG_updateDepositRecipient_anyoneCanStealQueuedDeposit`.
- Partially filled head entry: the remainder (954_532_691_143 - 95_453_269_112 spUSDC, ~900k USDC)
  goes to mallory. `test_BUG_updateDepositRecipient_stealsRemainderOfPartialFill`.
- Queued redeem: alice escrows 990_405_184_109 shares; mallory redirects; planner pays mallory
  999_999_999_998 USDC. `test_BUG_updateRedeemRecipient_anyoneCanStealQueuedRedeem`.
- Cancelled deposit refund: mallory redirects the cancel entry; settlement pays mallory
  999_999_999_999 USDC. `test_BUG_updateCancelledDepositRecipient_anyoneCanStealRefund`.
Impact: every queued dollar in all three queues is stealable by anyone. Fix: `require(msg.sender
== request.owner)` in all three (or drop the functions).

### N-2 High: `realizeLoss(totalAssets())` sets chi to 0 and bricks the vault
`src/SparkPrimeVault.sol:357`: `chi = uint192(((totalAssets() - loss_) * RAY) / totalSupply)`.
`loss_ == totalAssets()` is accepted and yields `chi = 0`. chi is multiplicative, so `nowChi()` is
still 0 after 365 days at MAX_VSR, `drip` keeps it 0, and a further `realizeLoss` underflows. Shape
after the call (all asserted): `totalAssets() == 0`; alice's 990_405_184_109 shares are worth 0
while the vault still holds 954_532_691_143 spUSDC (~1M USDC, reachable only via `take()`);
`requestDeposit` does NOT revert, bob's 100k is accepted and queued (`pendingDepositSavingsShares
= 95_453_269_114`) and `processDepositQueue` is a silent no-op forever (free capacity converts to 0
assets so the fill loop never runs); `requestRedeem` works (escrows worthless shares) but
`processRedeemQueue` and `convertToShares` panic with division by zero; cancel + settlement still
work. No role can recover; only an upgrade. With `totalSupply == 1` share `totalAssets()` is 1 wei,
so `realizeLoss(1)` is a full loss and zeroes chi the same way.
`test_BUG_realizeLoss_fullLossSetsChiZeroAndBricksVault`,
`test_BUG_realizeLoss_oneWeiLossOnOneShareSupplyZeroesChi`. Fix: `require(loss_ < totalAssets())`
plus a floor on the new chi. C-3 persists under the new formula: a hot-wallet RISK_MANAGER can
write chi down to anything in one call while paused.

### N-3 Medium: `processCancelledDepositQueue` reverts when spUSDC is illiquid
`src/SparkPrimeVault.sol:744` budgets by the vault's spUSDC share balance; the per-entry
`spUSDC.redeem` (`:765`) needs USDC liquidity. Scenario: alice's cancelled 954_532_691_143 spUSDC;
spUSDC's taker deploys 500_000e6 of its 1_000_000e6 USDC; `spUsdc.maxRedeem(vault)` =
477_266_345_571 < entry; the call reverts `SparkVault/insufficient-liquidity` and alice gets
nothing although 499_999_999_998 USDC could have been paid. Batch: liquidity 1_040_000e6 covers
entry 1 (999_999_999_999) but not entry 2 (99_999_999_999); the whole call reverts and even entry 1
is unpaid. The planner can only work around it by computing `maxRedeem` off-chain and passing it
as `maxSavingsShares_`, or by `maxRequests_ = 1`. `_processRedeemQueue` (`:782`) already bounds by
`maxWithdraw` and degrades gracefully. Fix: `remaining_ = _min(maxSavingsShares_,
IERC4626Like(savings).maxRedeem(address(this)))`.
`test_BUG_processCancelledDepositQueue_revertsWhenSpUsdcIlliquid`,
`test_BUG_processCancelledDepositQueue_batchRevertsWhenSecondEntryIlliquid`.

### N-4 Medium: `setCapacity` has no bound; large values brick deposits
`src/SparkPrimeVault.sol:268` accepts any uint256; `:704` computes
`convertToAssets(availableCapacity())` = `(cap - supply) * chi / RAY`. `setCapacity(type(uint256).max)`
makes every `requestDeposit` and `processDepositQueue` revert with an arithmetic overflow panic.
Exact edge at supply 0: `type(uint256).max / chi_p` =
114_681_085_459_589_801_375_833_087_904_206_311_575_507_395_147_570 is safe, +1 panics. The bound
shrinks as chi grows: a capacity set to the exact safe value today bricks deposits after one day
at MAX_VSR (shown), so a value that was valid when set can go bad with no further action. Admin
recovers by lowering capacity. `type(uint128).max` (harness) is always safe.
`test_BUG_setCapacity_maxUint256BricksDeposits`. Fix: restore `capacity_ <= type(uint128).max`.

### N-5 Low: the cancelled-deposit queue is not ring-fenced from `take()` (F-2 in new form)
The round-1 revert is gone, replaced by indefinite delay: after `take(954_532_691_143)` settlement
is a silent no-op (budget = min(max, 0)), head and counters unchanged, no revert and no event; the
refund resumes exactly as spUSDC comes back (95_453_269_114 returned pays 99_999_999_999 USDC).
`test_take_afterCancel_settleIsNoOpUntilSpUsdcReturned`. Likewise the cancelled queue and the
redeem queue draw from the same spUSDC; the planner's call order decides who is paid under a
shortfall (redeems first: alice 899_999_999_998 and bob at most 1 wei; cancels first: bob
99_999_999_999 and alice 799_999_999_998). `test_priority_redeemsFirstStarvesCancelledQueue`,
`test_priority_cancelledFirstStarvesRedeemQueue`.

### N-6 Low: zero-share redeem ghosts and zero-deposit ghosts (F-5 / C-12 persist)
`requestRedeem(0, r)` (`:478`) with `minRedeem == 0` succeeds for anyone with no balance: emits
`RedeemRequest(mallory, mallory, 0, 0, 0)`, pushes a 0-share entry, `cancelRedeemRequest` on it
reverts `no-request`. Three ghosts ahead of a real redeem make `processRedeemQueue(max, 3)` pay
nothing and move the head to 3. `requestDeposit(0)` with `minDeposit == 0` likewise pushes ghosts;
500 ghosts parked between the head and the next real entry cost that depositor one walk of
388_500 gas warm in-test (about 2_100 per ghost cold on mainnet, ~1.1M) and nothing afterwards.
`minRedeem = 1` and `minDeposit = 1` close both. `test_requestRedeem_zeroSharesCreatesGhostEntry`,
`test_requestRedeem_ghostsConsumeMaxRequests`, `test_requestDeposit_gasOfWalkingGhostsPaidOnce`.

### N-7 Info
- `updateDepositRecipient` on a filled (deleted) id writes a recipient into the dead slot
  (`(0, mallory, 0)`); cancel still reverts `no-request` and processing ignores it.
  `test_updateDepositRecipient_onFilledIdWritesDeadSlot`.
- `Deposit`'s 4th argument is named `savingsShares` but carries spPRIME shares (990_405_184_109
  for a 1M deposit). `test_events_depositFourthArgIsPrimeShares`.
- Guardian-chosen `recipient_` on cancel lands in the cancelled queue and is paid to the guardian
  (F-1 persists; CANCEL-FEES owns it). `test_cancelDepositRequest_guardianChoosesRecipient`.
- Public array getters revert with empty data out of range; the three updaters panic 0x32.
- `realizeLoss` rounding is now floor against holders: the `totalAssets()` drop is in [L, L+1]
  (exactly L+1 at the harness indexes for L = 100_000e6). The uint192 cast at `:357` cannot
  truncate: new chi <= old chi for every `loss_ <= totalAssets()` (fuzzed, 20k runs) and chi <
  2^192 by the drip bound.

## (b) Properties that held

- Cancel moves the exact spUSDC amount from `pendingDepositSavingsShares` to
  `pendingCancelledDepositSavingsShares`, zeroes the deposit entry, returns the cancel id, emits
  `CancelDepositRequest(depositId, cancelId)`; settlement pays `floor(shares * chi_s / RAY)`
  (999_999_999_999 for 1M), emits `DepositCancellation(owner, recipient, shares, assets)`, deletes
  the entry, advances the head. `test_cancelDepositRequest_queuesRefundAndSettleIsExact`.
- FIFO; partial settlement keeps the head and a later call completes (two half redeems pay
  499_999_999_998 + 499_999_999_999 >= 999_999_999_998); `maxRequests` honoured; `maxRequests = 0`
  and empty queue are no-ops; zero entries only ever sit behind the head.
  `test_processCancelledDepositQueue_partialThenComplete`, `_maxRequestsHonoured`, `_emptyQueueNoOp`,
  `_zeroEntriesOnlyBehindHead`.
- spUSDC yield accrued while in the cancelled queue goes to the canceller (10% VSR, 1 year: ~1.1M
  paid). `test_processCancelledDepositQueue_yieldWhileQueuedGoesToCanceller`.
- Cancel and settlement revert `SparkPrimeVault/paused` while paused.
  `test_cancelDepositRequest_revertsWhenPaused`, `test_processCancelledDepositQueue_revertsWhenPaused`.
- Double cancel and cancel of a filled id: `no-request`; zero recipient: `invalid-recipient`;
  non-owner: `not-authorized`; out-of-range id: panic 0x32.
- Fuzz (24 random cancel/settle/take/return/warp steps, 20k runs):
  `pendingCancelledDepositSavingsShares == sum(open cancelled entries)`,
  `pendingDepositSavingsShares == sum(open deposit entries)`,
  `vault spUSDC + taken == pendingDeposit + pendingCancelled`, both heads <= length, every entry
  behind a head is zero. `testFuzz_cancelledQueue_countersTrackOpenEntries`.
- `realizeLoss`: exact chi `floor((TA - L) * RAY / S)` = 908_718_991_417_304_243_366_635_929 for
  L = 100_000e6 on 990_405_184_109 shares; event `LossRealized(chi, loss)`; rho refreshed; reverts
  `not-paused`, `invalid-loss`, `AccessControlUnauthorizedAccount` for admin/guardian/alice;
  `totalSupply == 0` and `loss > totalAssets` both panic with arithmetic underflow (0x11, the
  subtraction happens before the division). Escrowed redeem shares take the loss pro rata (drop
  within [100_000e6, 100_000e6 + 2] for alice and for bob's escrow), queued spUSDC deposits do not
  (carol's entry stays 95_453_269_114 spUSDC and fills for ~99_999_999_999 USDC of value
  post-loss). `test_realizeLoss_*`, `testFuzz_realizeLoss_newChiNeverExceedsOld`.
- Head loops: ghosts walk the head one step each; a real request behind ghosts fills instantly;
  cancelling the head skips later ghosts and cancelled entries; cancelling a non-head entry does not
  move the head; `depositHead <= length` throughout.
  `test_requestDeposit_skipsGhostsAndFillsInstantly`,
  `test_cancelDepositRequest_headCancelAdvancesPastGhostsAndCancelled`.
- Entries are deleted after a full fill in both queues. `test_processQueues_entriesDeletedAfterFill`.
- `pause` is GUARDIAN-only (admin reverts), `unpause` is admin-only (unpauser and guardian revert).
  `test_pause_guardianCanAdminCannot`.
- `asset() == USDC`, `decimals == 6`, `DOMAIN_SEPARATOR` matches EIP-712 with name
  "Spark Prime USDC" / version "1"; `take` over balance reverts `SparkPrimeVault/insufficient-shares`.
- Events: `DepositRequest(owner, recipient, id, assets, savingsShares)` carries 954_532_691_143;
  `Redeem(owner, recipient, shares, assets)` order confirmed.

## (c) Unsettled

- Whether the recipient updaters are meant to exist at all (N-1); if they are, whether a GUARDIAN
  path is wanted alongside the owner check.
- What floor `realizeLoss` should enforce (N-2 / C-3); the tests only prove that none exists.
- Netting (`processQueues`) is not on this branch, so the cancelled queue's interaction with
  netting is untested.
