# NEWSURFACE worker report

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
