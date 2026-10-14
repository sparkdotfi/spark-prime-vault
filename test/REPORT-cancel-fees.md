# CANCEL-FEES worker report, round 3: `test/CancelAndFees.t.sol` @ `ff828d2`

68 tests, all passing (67 unit + 1 fuzz at 5000 runs) against `src/SparkPrimeVault.sol` on
`refactor/more-simplifying` at `ff828d2`. Line numbers in this section refer to that file.
Harness indexes and the 100e6 / 1_000_000e6 constants are unchanged from round 2.

## Fixed at ff828d2

- B-3 (cancelled-queue budget ignored spUSDC liquidity): `_processCancelledDepositQueue` now
  budgets `min(maxSavingsShares_, spUSDC.maxRedeem(vault))` (`src/SparkPrimeVault.sol:784`).
  With alice and bob cancelled at 100e6 each and 40e6 USDC left in spUSDC: `maxRedeem` is
  38_181_307, alice is paid 39_999_999 and stays at the head with 57_271_962 shares, bob is
  untouched, spUSDC keeps 1 wei; a second call is a no-op (no revert); after 200e6 returns one
  call completes alice (99_999_999 total, chunking cost 0) and bob (99_999_999), head 2.
  `maxRequests_` still binds under the clamp (150e6 liquid, 1 request: alice only; next call pays
  bob 50_000_000 of the 50_000_001 left). The settlement costs 1_584 more gas per call for the
  extra `maxRedeem` (99_408 for one entry, was 97_824), marginal per entry unchanged at 22_931.
  Regression tests: `test_processCancelledDepositQueue_clampsToSpUsdcLiquidity`,
  `test_processCancelledDepositQueue_liquidityClampRespectsMaxRequests`
  (replace `test_processCancelledDepositQueue_revertsWhenSpUsdcIlliquid`).
- Unauthenticated `updateCancelledDepositRecipient` (NEWSURFACE's finding, which made B-1's repair
  path a race): the three recipient updaters are now owner-only
  (`SparkPrimeVault/not-authorized`, lines 416-425, 465-477, 537-546), need an open entry
  (`no-request`) and a non-zero recipient. Test:
  `test_cancelDepositRequest_guardianRedirectRepairedByOwnerBeforeSettlement` (owner repairs, the
  guardian and a stranger revert `not-authorized`, zero address reverts `invalid-recipient`, a
  second guardian cancel reverts `no-request`, settlement pays alice 99_999_999 and the guardian 0,
  the settled entry rejects further updates with `no-request`).

## Persisting: F-1, both sides (both `test_BUG_` proofs still pass by asserting the theft)

- B-1, deposit side, severity High -> Medium. `cancelDepositRequest` (lines 441-450) still
  accepts `owner || GUARDIAN` and pushes the caller's `recipient_` into the cancelled entry. The
  guardian can still queue a 999_999_999_999 USDC refund to itself
  (`test_BUG_cancelDepositRequest_guardianCanRedirectRefund`). What changed: the owner now has a
  real repair path. Because the refund is settled by REBALANCER in a later transaction, the owner
  can call `updateCancelledDepositRecipient(cid, owner)` in the window between the guardian's
  cancel and the planner's settlement, and nobody can flip it back. Downgraded to Medium because
  the theft needs the guardian key AND a planner settlement before the depositor reacts (the
  settlement is observable in the mempool / on chain, the cancel emits `CancelDepositRequest`),
  so it degrades from "unconditional loss" to "loss if two roles act, or one role and an
  inattentive depositor". It stays above Low because the depositor has no notification other
  than watching events, the planner settles the queue routinely, and after settlement there is
  nothing to repair (`test_cancelDepositRequest_guardianRedirectNotRepairableAfterSettlement`:
  guardian paid 99_999_999, owner's update reverts `no-request`). Fix unchanged: push
  `msg.sender == request_.owner ? recipient_ : request_.owner` as the recipient.
- B-2, redeem side, stays High. `cancelRedeemRequest` (lines 516-523) pays
  `_transfer(address(this), recipient_, shares)` in the same transaction. The guardian takes
  990_405_184_109 shares (999_999_999_998 USDC of claim) and there is no window and no updater
  that can touch a paid-out entry (`test_BUG_cancelRedeemRequest_guardianCanRedirectShares`).
  Fix unchanged: `address to_ = msg.sender == request_.owner ? recipient_ : request_.owner;`.

## New: fee economics with `realizeGain` (lines 297-309, DEFAULT_ADMIN, not pause-gated)

- The burned redeem fee's surplus spUSDC (I-2) can now be credited to the remaining holders.
  Scenario: bob 100e6, alice 1_000_000e6, 1% fee, alice's redeem fills. Backing 10_100_000_001
  USDC against `totalAssets` 99_999_998, surplus 10_000_000_003. `realizeGain(10_000_000_003)`
  sets chi to 101.978466055462937456192802386e27 (from 1.0097e27: a 101x jump for a single
  holder), bob's claim becomes 10_100_000_000, `totalAssets` 10_100_000_000, 1 wei under the
  backing, spUSDC balance unchanged. Bob redeems the full 10_100_000_000 and 1 spUSDC wei of dust
  remains. Test: `test_realizeGain_distributesFeeSurplusToRemainingHolders`.
- The gain amount must be measured at call time: `realizeGain(10_000_000_001)` (the surplus as
  measured in the alice-only scenario) leaves 3 wei uncredited (`test_realizeGain_roundNumberLeavesDust`).
- With no holders left (`totalSupply == 0`, the alice-only scenario) the 10_000_000_001 USDC of
  fee cannot be distributed: `realizeGain` reverts `no-shares`; `take()` remains the only exit.
  `realizeGain(0)` reverts `invalid-gain`; RISK_MANAGER cannot call it.
  Test: `test_realizeGain_revertsWithNoHolders`.
- Mirror, Info: `realizeGain` is not checked against backing and is not pause-gated. Alice holds
  99_040_517 shares (backing 99_999_999); `realizeGain(100e6)` unpaused doubles chi to
  2.019375545061017805470462154e27 and her claim to 199_999_997 with nothing behind the second
  half. A full redeem pays 99_999_997 from the real liquidity, leaves 49_520_259 shares (worth
  exactly 100_000_000 on paper) at the redeem head with 2 spUSDC wei behind them, and further
  settlement calls make no progress. Also accepted while paused. The loss side is symmetric in
  the other direction (`realizeLoss` requires paused and `0 < loss < totalAssets`), so the
  asymmetry is: admin can inflate claims live and unbounded, risk manager can only cut them
  while paused and never to zero. Test: `test_realizeGain_withoutBackingIsNotional`.
- `realizeLoss` bounds pinned (lines 369-385): with `totalAssets` 99_999_998, `realizeLoss(0)` and
  `realizeLoss(99_999_998)` revert `invalid-loss`; 99_999_997 is the maximum. The round-2
  `realizeLoss(50e6)` assertion is unaffected
  (`test_realizeLoss_escrowedRedeemTakesLoss_cancelledDepositDoesNot`).

## Properties re-checked and held at ff828d2

Everything in round 2 section (c) re-ran unchanged on the new code (same exact values, same gas
for the deposit and redeem queues: 2_328 / 2_408 gas per ghost entry, 22_931 marginal per
settled cancellation). B-4 (settlement spends other queued depositors' backing), N-1 (dead
entries consume `maxRequests_`), F-2, F-5, F-7, F-8, I-2, I-4, I-6, C-6, N-3 all reproduce with
the round-2 numbers; their line references moved: `_processCancelledDepositQueue` budget `:784`,
loop `continue` `:796`; `_processDepositQueue` `continue` `:757`; `_processRedeemQueue` clamp
`:822`; `take` `:329-338`; cancel delete/push `:446` / `:450`.

## Unsettled

- B-1 severity: Medium assumes a depositor who watches `CancelDepositRequest` events or a planner
  that does not settle blindly. If the planner settles on a timer with no review, the practical
  window is the timer period and the finding is closer to High. Decide with the ops design.
- Whether `realizeGain` should be bounded by `backing - totalAssets()` (it has the data: the
  vault can read `spUSDC.convertToAssets(balanceOf(this))`) or at least require `paused` like
  `realizeLoss`, is a design question for NEWSURFACE / the admin-surface owner.
- The 1 wei of spUSDC that `maxRedeem` leaves behind (floor rounding) accumulates one wei per
  liquidity-constrained settlement; harmless, noted for completeness.

---

# Round 2 (history, `0bc9288`): `test/CancelAndFees.t.sol`

62 tests, all passing (61 unit + 1 fuzz at 5000 runs) against `src/SparkPrimeVault.sol` on
`refactor/more-simplifying` (worktree HEAD `dbb633b`). The two `test_BUG_` tests pass by asserting
the theft. Line numbers refer to that file.

Harness indexes at `setUp`: `chi_s = 1.047633055711877768967605062e27`,
`chi_p = 1.009687768242461209408770821e27`. 100e6 USDC in = 95_453_269 spUSDC shares
(worth 99_999_999) = 99_040_517 spPRIME shares (worth 99_999_998). 1_000_000e6 in =
954_532_691_143 spUSDC = 990_405_184_109 spPRIME (worth 999_999_999_998).

Note on the late upstream push (`review/poc-tests-v2`: `pause()` back on GUARDIAN, `realizeLoss`
formula): the merge command was blocked by the session's permission policy, so the file was run
against the pre-merge HEAD. The tests do not depend on the differences: pause goes through the
harness `_pause` helper, and the one `realizeLoss` assertion tolerates the 1 wei the formula change
can move. Re-run after merging to confirm.

## (a) What changed upstream in this area, and how the tests moved

- `cancelDepositRequest(id, recipient)` no longer pays. It deletes the deposit entry, pushes
  `(owner, recipient, savingsShares)` onto `cancelledDepositQueue`, moves the shares from
  `pendingDepositSavingsShares` to `pendingCancelledDepositSavingsShares`, returns the cancel id and
  emits `CancelDepositRequest(depositId, cancelId)`. The refund happens when REBALANCER calls
  `processCancelledDepositQueue(maxSavingsShares, maxRequests)`: budget
  `min(max, spUSDC.balanceOf(vault))`, one `spUSDC.redeem` per entry, event
  `DepositCancellation(owner, recipient, savingsShares, assets)`, partial fills keep the head.
  Every deposit-cancel test now does cancel then settle and checks both queues.
- `recipient == 0` reverts `SparkPrimeVault/invalid-recipient` in both cancels (round-1 N-2 closed
  for the zero address; `recipient == vault` is still accepted on both).
- Cancelling the head entry walks the head past dead entries; `_requestDeposit` walks the head
  before deciding on the instant fill. Filled entries are `delete`d.
- `setMinimums` split into `setMinDeposit(assets)` and `setMinRedeem(shares)`; `minRedeem` is a
  share count checked as `shares_ >= minRedeem`, so `requestRedeem(0)` is a ghost when `minRedeem`
  is 0 (REDEEM-QUEUE owns it; the old zero-shares revert test is replaced by a `minRedeem` test).
- The F-1 patch is not upstream. Both guardian tests are now `test_BUG_` proofs.

## (b) Bugs and suspicious behaviour

### B-1 High: guardian can redirect a cancelled deposit refund to any address (F-1, deposit side)
`src/SparkPrimeVault.sol:441-450`. The authorization check accepts `owner || GUARDIAN`, and the
cancelled entry is pushed with the caller's `recipient_`, not `request_.owner`.
Scenario: alice queues 1_000_000e6 (954_532_691_143 spUSDC). Guardian calls
`cancelDepositRequest(id, guardian)`. Entry `cancelledDepositQueue[0] = (alice, guardian, SS_1M)`.
`processCancelledDepositQueue` pays 999_999_999_999 USDC to the guardian; alice gets 0.
Impact: full loss of any queued deposit by a hot-wallet role. The owner can repair it only in the
window before settlement, through `updateCancelledDepositRecipient` (line 465), which at 0bc9288 was
unauthenticated: anyone, including the guardian, could flip it back (owner-only since ff828d2, see round 3).
Tests: `test_BUG_cancelDepositRequest_guardianCanRedirectRefund`,
`test_cancelDepositRequest_guardianRedirectRepairedByOwnerBeforeSettlement`.
Fix: push `Request(request_.owner, msg.sender == request_.owner ? recipient_ : request_.owner, ...)`
and authenticate `updateCancelledDepositRecipient` to the entry owner.

### B-2 High: guardian can redirect escrowed redeem shares to any address (F-1, redeem side)
`src/SparkPrimeVault.sol:516-523` at ff828d2. Same check; `_transfer(address(this), recipient_, shares)` pays
whoever the guardian names, immediately, with no repair path.
Scenario: alice escrows 990_405_184_109 shares (fee 0). Guardian calls
`cancelRedeemRequest(id, guardian)`: guardian balance 990_405_184_109 (worth 999_999_999_998),
alice 0, `pendingRedeemShares` 0.
Impact: full loss of any queued redeem by a hot-wallet role.
Test: `test_BUG_cancelRedeemRequest_guardianCanRedirectShares`.
Fix: `address to_ = msg.sender == request_.owner ? recipient_ : request_.owner;`.

### B-3 Low: `processCancelledDepositQueue` budgets by spUSDC share balance, not spUSDC liquidity
`src/SparkPrimeVault.sol:784` (`balanceOf` at 0bc9288; now `maxRedeem`, FIXED in round 3) versus `:822` (`maxWithdraw` in the redeem loop).
When spUSDC itself is short of USDC the per-entry `redeem` reverts `SparkVault/insufficient-liquidity`
and the whole call rolls back; nothing is paid, including entries that would fit.
Scenario: alice and bob each cancel 100e6; spUSDC holds 40e6 USDC against the vault's 190_906_538
shares. `processCancelledDepositQueue(max, 10)` and `(max, 1)` both revert. The planner can
hand-size the budget: `convertToShares(40e6) = 38_181_307` pays alice 39_999_999 and leaves her at
the head; after 200e6 of liquidity returns, one call completes both (alice 99_999_999, bob 99_999_999).
Impact: operational stall of all refunds behind an illiquid spUSDC, no fund risk. The redeem loop
does not have this shape (it clamps to `maxWithdraw`).
Test: `test_processCancelledDepositQueue_revertsWhenSpUsdcIlliquid`.
Fix: `remaining_ = _min(maxSavingsShares_, _min(balanceOf, convertToShares(maxWithdraw)))`.

### B-4 Low: a cancelled-deposit settlement spends other queued depositors' backing
`src/SparkPrimeVault.sol:784`. The budget is the vault's whole spUSDC balance (now clamped to spUSDC liquidity, same shape), which is also the
backing of deposits still queued (`pendingDepositSavingsShares`) and of minted shares.
Scenario: alice and bob queue 100e6 each; `take(95_453_269)` removes one depositor's worth. Alice
cancels and settles: 99_999_999 USDC paid, vault spUSDC 0, bob's entry still says 95_453_269
`pendingDepositSavingsShares` with nothing behind it until the taker returns capital.
Impact: same shape as F-2 (design, queued deposits are unsecured against `take`), but the loss of
backing now happens in a REBALANCER call rather than a user cancel, so it is planner-controlled.
Test: `test_processCancelledDepositQueue_spendsOtherQueuedDepositorsBacking`.

### N-1 re-measured (Low -> Info): cancel/re-request griefing
`src/SparkPrimeVault.sol:446` (`delete`), `:757` (`continue`), `:450` (push to the cancelled queue).
Dead entries behind a live head still consume `maxRequests_` and 2_328 gas each (cold). Bob at id 0,
50 griefer cycles at ids 1..50, alice at 51: `processDepositQueue(max, 50)` fills bob only and
stops at head 50, two more calls reach alice. Dead entries at the head cost nothing now: both the
cancel and the next request walk over them (`test_cancelDepositRequest_thenReRequestQueuesBehindOthers`
needs 2 planner calls instead of 3, `test_requestDeposit_walksGhostsAtHead`).
What changed the economics: each cycle appends an entry to `cancelledDepositQueue` that only
REBALANCER can settle, at 22_931 gas marginal per entry cold (97_824 for one, 1_221_464 for 50),
and the griefer gets the 100e6 back only after that settlement. Recycling one 100e6 through 50
cycles therefore needs either the rebalancer to settle between cycles (50 settlements, planner
pays ~1.15M gas) or 50 x `minDeposit` of capital parked until settlement. Cost to the griefer is
still 1 wei of USDC per cycle plus gas. Throughput griefing only, now with a gas bill for the
planner on the cancelled side as well.
Tests: `test_cancelDepositRequest_cancelledEntriesConsumeRequestBudget`,
`test_processCancelledDepositQueue_gasPerEntry`.

### Known findings, now quantified on the new code

- F-2 (design): A and B queue 100e6 each, `take(95_453_269)`, both cancel (no revert, head 2,
  `pendingCancelledDepositSavingsShares` 190_906_538). Settle: A gets 99_999_999, B untouched,
  `cancelledDepositHead` 1, a second settle call is a no-op (budget 0, no revert).
  `_returnToVault(95_453_269)` then completes B. With `take(143_179_903)` (150e6 worth,
  47_726_635 left): settle pays A 50_000_000 and leaves A at the head with 47_726_634 shares;
  returning 47_726_634 completes A (99_999_999 total); returning 95_453_269 completes B.
  Fills still mint in full after the take: `totalAssets()` 199_999_997 against 50_000_000 of
  backing. Tests: `test_cancelDepositRequest_afterTakeSettlesWhatIsThere_restWaits`,
  `test_cancelDepositRequest_takeExceedsOneRequest_partialThenWait`,
  `test_processDepositQueue_stillMintsAfterTakeSpentBacking`.
- F-5 ghost gas (cold via `vm.cool`): `processDepositQueue(max, 502)` 143_950 gas for 2 real
  requests, 1_308_365 with 500 zero-asset ghosts between them (2_328 per ghost).
  `processRedeemQueue(max, 501)`: 107_072 vs 1_311_293 with 500 one-wei fee ghosts (2_408 per
  ghost). Ghost cancel reverts `no-request`. Ten ghosts at the head are walked by the next request
  (head 9 after the ghosts, alice at id 10 fills instantly, head 11).
  Tests: `test_processDepositQueue_gasWith500GhostEntries`, `test_processRedeemQueue_gasWith500GhostEntries`,
  `test_requestDeposit_walksGhostsAtHead`.
- F-7: both cancels and `processCancelledDepositQueue` revert `SparkPrimeVault/paused`; `take()`
  pulls the full 95_453_269 during the pause; after unpause a refund already in the cancelled queue
  is a no-op until the spUSDC is returned. Tests: `test_cancelDepositRequest_revertsWhilePaused`,
  `test_processCancelledDepositQueue_revertsWhilePaused`, `test_cancelRedeemRequest_revertsWhilePaused`.
- F-8: guardian cancel of a 1_000_000e6 redeem at 1% fee returns 980_501_132_267 shares to the
  owner (guardian must name the owner, see B-2); 9_904_051_842 shares = 10_000_000_001 USDC of claim
  are gone. Test: `test_cancelRedeemRequest_guardianCancelKeepsFee`.
- I-2: fee leaves chi and the spUSDC balance unchanged; after alice's 1% redeem fills,
  9_545_326_913 spUSDC (10_000_000_001 USDC) remain with `totalSupply == 0` and `take` extracts
  all of it; bob's claim stays 99_999_998 next to a 10_000_000_003 surplus. New: that surplus also
  settles cancelled deposits after a full `take` (bob queues 100e6, taker takes 95_453_269, bob
  cancels and is paid 99_999_999 from the fee surplus). Tests:
  `test_requestRedeem_feeLeavesChiUnchangedAndRaisesBackingPerShare`,
  `test_requestRedeem_feeNotCreditedToRemainingHolders`,
  `test_processCancelledDepositQueue_feeSurplusCoversRefund`.
- I-4 rewritten in shares: `minRedeem = convertToShares(100e6) = 99_040_518` (worth 99_999_999),
  fee 1%. 99_040_517 reverts `below-minimum`; 99_040_518 queues 98_050_112 and pays 98_999_998 USDC,
  1_000_001 wei below the value the minimum represents. Because the minimum is a share count its
  USDC value drifts with chi: after a year at 5% the same `minRedeem` is worth 104_999_998 and a
  100 USDC redeem reverts. `minDeposit` 100e6: 99_999_999 reverts, 100e6 passes.
  Tests: `test_requestRedeem_minRedeemIsGrossOfFee`, `test_requestRedeem_minRedeemValueDriftsWithChi`,
  `test_requestDeposit_minDepositBoundary`.
- I-6: donated shares to the vault (`transfer`/`transferFrom`) leave `balanceOf(vault)` 1_000_000
  with `pendingRedeemShares` 0; fills and cancels around them are unaffected; they consume capacity.
  Tests: `test_transfer_toVaultStrandsSharesWithoutBreakingQueues`, `test_transferFrom_toVaultStrandsShares`.
- C-6 remnants: `cancelDepositRequest(id, vault)` settles 99_999_999 USDC into the prime vault
  contract where nothing moves it; `cancelRedeemRequest(id, vault)` strands 99_040_517 shares.
  Tests: `test_cancelDepositRequest_recipientVaultStrandsUsdc`, `test_cancelRedeemRequest_recipientVaultStrandsShares`.
- N-3 / C-7: `setMaxRedeemFee(0.001e18)` under a live 1% fee leaves 1% in force (new requests burn
  9_904_051_842 of 990_405_184_109) and the risk manager can only go down. Unchanged.
  Test: `test_setMaxRedeemFee_belowCurrentFeeLeavesFeeInForce`.

## (c) Properties that held

- Owner can cancel own deposit/redeem to any non-zero recipient; stranger and the fill recipient
  revert `not-authorized`; cancelled, filled and ghost ids revert `no-request`; out-of-range ids
  revert `Panic(0x32)`; zero recipient reverts `invalid-recipient` for owner and guardian.
- Cancel of a deposit emits `CancelDepositRequest(id, cancelId)`, creates exactly one cancelled
  entry with `(owner, recipient, savingsShares)`, moves the shares between the two pending
  counters, leaves the spUSDC balance untouched until settlement; settlement emits
  `DepositCancellation(owner, recipient, savingsShares, assets)`, deletes the entry and advances
  `cancelledDepositHead`. Cancel of a redeem emits `CancelRedeemRequest(id, shares)`.
- `processCancelledDepositQueue` honours `maxRequests_` exactly (0 fills nothing, 2 of 3 pays
  the first two in cancel order), is a no-op on an empty queue, partially fills on
  `maxSavingsShares_` (38_181_306 shares pay 39_999_998, remainder 57_271_963 pays 60_000_001,
  total 99_999_999 like a single refund), and reverts for non-REBALANCER callers.
- Settlement order is cancel order, independent of deposit order (bob cancelled first is paid
  first although he queued second).
- Partial deposit fill then cancel: 39_616_205 shares minted, 57_271_963 spUSDC moved to the
  cancelled queue and paid as 60_000_001; minted value + refund = 99_999_998. Partial redeem fill
  then cancel: 39_999_999 paid, 59_424_310 shares returned, head advanced to 1.
- Head walking: cancelling a non-head entry leaves the head; cancelling the head walks over every
  dead slot to the next live entry (0 -> 2 with bob dead at 1) and to `length` when nothing is
  live; the same for the redeem head. A re-request after an unsettled cancel fills instantly.
- Fee math (fuzz, shares in [1, 1e30], rate in [0, 1e16], 5000 runs): fee ==
  ceil(shares * rate / 1e18), fee <= shares, fee == 0 iff rate == 0, queued == shares - fee,
  `totalSupply` drops by the fee, owner balance by shares, vault balance and
  `pendingRedeemShares` rise by queued. Rate 1e-18 on 99_040_517 shares charges 1 wei.
  `minRedeem = SH_100`: SH_100 - 1 reverts `below-minimum`, SH_100 queues in full.
- Fee locked at request: lowering the fee from 1% to 0 after alice's request does not change her
  payout (989_999_999_997); bob requesting after pays 0 (999_999_999_998).
- `setRedeemFee(0.01e18 + 1)` and `setMaxRedeemFee(0.01e18 + 1)` revert `fee-too-high`; exactly
  1% is accepted by both.
- Yield while queued: a 1_000_000e6 deposit queued 182 days, cancelled, and settled 183 days
  later at 5% spUSDC VSR pays 1_049_999_999_998, identical to the wei to holding spUSDC directly;
  the cancelled queue earns the same rate as the deposit queue. Filled instead, it mints
  1_039_925_443_313 shares (49_520_259_204 more than the earlier depositor). Escrowed redeem
  shares return intact after a year at 5% (980_501_132_267 worth 1_039_499_999_997).
- `realizeLoss(50e6)` while paused halves the escrowed redeemer's claim (49_999_998 +/- 1 wei)
  and leaves a cancelled deposit awaiting settlement untouched (99_999_999 paid).
- Deposit/cancel/settle cycles lose exactly 1 wei per cycle (10 cycles: 100e6 -> 99_999_990) and
  both heads advance one slot per cycle. Redeem/cancel cycles lose exactly the fee each time
  (960_989_159_734 after 3 cycles at 1%) with backing untouched.

## (d) Unsettled

- Run against the pre-merge HEAD (see the note at the top); the `review/poc-tests-v2` diff only
  moves `pause()` to GUARDIAN and changes the `realizeLoss` formula, both abstracted in this file.
- Gas figures come from the local harness with `vm.cool`; mainnet will differ slightly, but the
  per-entry costs (2.3-2.4k per dead entry, ~23k per settled cancellation) are structural.
- Whether the cancelled queue should clamp to spUSDC liquidity (B-3) and whether cancelled
  entries should count against `maxRequests_` (N-1) are planner design questions.
