# CANCEL-FEES worker report: `test/ai/CancelAndFees.t.sol`

## Round 6 (`master` @ `c512609`)

96 tests, all passing (88 unit + 8 fuzz; the 8 fuzz properties verified at
`FOUNDRY_FUZZ_RUNS=20000`) against `src/SparkPrimeVault.sol` on `master` @ `c512609`. Four
`test_BUG_` tests remain, all passing proofs of open low/info behaviour (C-7, V2-13 for spUSDC,
R5-14, R5-9 residual). Line numbers below are on c512609. Harness indexes and the 100e6 /
1_000_000e6 constants are unchanged (chi_s `1.047633055711877768967605062e27`, chi_p
`1.009687768242461209408770821e27`; 100e6 -> 95_453_269 spUSDC -> 99_040_517 spPRIME;
1_000_000e6 -> 954_532_691_143 -> 990_405_184_109). Run:
`FOUNDRY_OFFLINE=true forge test --skip test/ai/TestBase.t.sol --match-path test/ai/CancelAndFees.t.sol`
(`test/ai/TestBase.t.sol`, not mine, does not compile on this master; `--skip` excludes it).

### (a) New findings

- **R6-1 Self-skip walk is unbounded: dead entries behind a live head make the head's cancel
  (and the next deposit) cost ~2_355 gas each. Low / liveness.**
  `requestDepositCancellation` ends with `_processPendingDeposits(0, type(uint256).max)`
  (`src/SparkPrimeVault.sol:445`) and `requestDeposit` with `_processPendingDeposits(max, max)`
  when its predicate holds (`:400-402`); both walk every zero entry from the head to the first
  live one (`:872-878`), unbounded in `maxRequests_`. A griefer who queues N minDeposit-sized
  requests behind a live depositor and cancels each (each cancel's own walk breaks immediately at
  the live head: cheap) makes that depositor's full cancel walk N dead entries: measured
  211_363 gas for 1 entry, 2_567_187 for 1_001, **2_355 gas per dead entry** (cold SLOAD), i.e.
  ~12_650 entries put a full cancel over 30M gas. Once the live head is gone the same entries sit
  at the head and the next `requestDeposit` whose predicate holds pays for all of them
  (2_663_036 gas for 1_000). Mitigations that exist: the depositor can partially cancel all but
  `minDepositCancellation` (the walk breaks at their own live remainder: 900_000-share remainder
  left, cost within 20k gas of the baseline), and the operator clears dead runs with budget 0 in
  bounded batches (`processPendingDeposits(0, 100)` advances the head by exactly 100 per call).
  Cost to the griefer: ~150k gas + 1 wei per cycle with minDeposit = 1e6 (capital recycled by
  settlement); 1-wei ghosts (R5-15) are the same thing for free when minDeposit = 1.
  `test_BUG_requestDepositCancellation_deadEntriesBehindHeadMakeCancelUnboundedGas`.
- **R6-2 Redeem ghosts are now 16x more expensive for the operator. Low.** The redeem loop has
  no `continue` for zero entries (`:950-973`): an all-fee ghost (R5-14, 1 share at any non-zero
  fee with `minRedeem == 1`) is "filled" with a zero burn, an external `spUSDC.withdraw(0)`, a
  `Redeem(id, owner, recipient, 0, 0, 0)` and a `Transfer(vault, 0, 0)`: **37_275 gas per ghost**
  (2_396 at 0ebb452), 18.8M gas for 500. With liquidity at 0 the ghost also stops the walk
  (`fillable_ == 0 -> break`). `test_processPendingRedeems_gasWith500GhostEntries`,
  `test_processPendingRedeems_walksGhostsAsZeroFills`.
- **R6-3 Partial-cancel remainder below `minDepositCancellation` cannot be cancelled. Info.**
  Three partial cancels of 30_000_000 shares each from a 95_453_269-share entry (min 30_000_000)
  leave 5_453_269 shares that revert `BelowMinDepositCancellation` for their own amount and
  `SavingsSharesTooHigh` for the minimum; the remainder stays a live, repointable entry at the
  head and is filled normally (5_658_208 shares worth 5_713_023); lowering the minimum frees it.
  Value out across 3 chunks + fill: 3 x 31_428_991 + 5_713_023 = 99_999_996 vs 99_999_999 for a
  one-shot refund (one floor per leg). `test_requestDepositCancellation_partialCancels_remainderBelowMinIsStuck`.
- **R6-4 `minDepositCancellation` is in spUSDC share units. Info.** A launch value of "100 USDC"
  set as 100e6 means 100e6 spUSDC shares = 104_763_305 USDC at the harness index: a 100 USDC
  deposit (95_453_269 shares) can never be cancelled, the smallest cancellable deposit is
  104_763_306 USDC (-> exactly 100_000_000 shares, refund 104_763_305), and the USDC value of
  the minimum drifts up with spUSDC's chi (> 110 USDC after a year at 5%).
  `test_setMinDepositCancellation_isInSpUsdcShareUnits`.
- **Cancel-vs-partial-fill race, info**: a cancel for the full amount that lands after a partial
  fill fails `SavingsSharesTooHigh` (not `NoRequest`); the owner must re-read (57_271_963 left
  after a 38_181_306 fill) and cancel the remainder. `test_requestDepositCancellation_raceWithPartialFill_amountTooHigh`.
- **Cancel-vs-full-fill race**: unchanged (`NoRequest`, exit via the fee-paying redeem queue,
  1_000_002 USDC on 100e6 at 1%). `test_processPendingDeposits_frontRunsCancel_ownerHasNoDefence`.
- **Blacklisted owners / recipients, info**: no `isBlacklisted` check exists anywhere any more.
  A blacklisted depositor cancels to a clean address (paid) or to themselves (parked as
  `claimableAssets`, `totalClaimable` tracked); same on the redeem side (49_999_998 parked for
  carol, 49_999_999 paid to bob). Queued capital is never frozen by a blacklist, only the final
  USDC leg. `test_requestDepositCancellation_blacklistedOwnerRoutesRefundToCleanRecipient`.

### (b) Prior findings touched, status at c512609

- **V2-13 / R5-7 (vault / spUSDC as recipient)**: **fixed for the vault**:
  `requestDepositCancellation` (`:415`), `updateDepositCancellationRecipient` (`:500`),
  `requestRedeem` (`:455`), `updateRedeemRecipient` (`:516`) revert `VaultIsRecipient`, checked
  before the id read (a stranger with a bad id gets it too); nothing moves, no USDC ever lands
  in the vault except via the claimable fallback. `test_fixed_requestDepositCancellation_vaultRecipientRejected`,
  `test_fixed_updateRedeemRecipient_vaultRecipientRejected`. **Open for spUSDC (low, self-harm)**:
  a cancel to `spUsdc` makes spUSDC pay itself: liability -99_999_999, USDC balance unchanged,
  100_000_000 of unaccounted liquidity. `test_BUG_requestDepositCancellation_recipientSpUsdcDonatesRefund`.
- **Pause gating of cancels (R5-B, round 4)**: **fixed**. `requestDepositCancellation` and
  `processPendingDepositCancellations` have no `whenNotPaused` (`:405-446`, `:326-332`). While
  paused: partial cancel (40_000_000 shares to bob) and full cancel of the rest work, the
  budget-0 walk moves the head to the next live entry and mints nothing (`totalSupply` stays 0),
  settlement pays 41_905_322 + 58_094_677 = 99_999_999; a blacklisted recipient falls back to
  claimable during the pause; `claim` and `take` are not gated either; `requestDeposit`,
  `processPendingDeposits`, `processPendingRedeems` stay blocked.
  `test_fixed_requestDepositCancellation_worksWhilePaused`,
  `test_fixed_processPendingDepositCancellations_worksWhilePaused`.
- **R5-9 ghosts / frozen head**: **partially fixed**. A cancelled entry AT the head is walked by
  the cancel itself (head 0 -> 2 when alice cancels with bob already dead behind her and carol
  live at 2; -> 3 when carol cancels); a cancelled entry BEHIND a live head is not (head stays 0
  when bob at 1 cancels), and it later costs one operator request slot or is skipped by the next
  instant-fill walk. Budget-0 walks advance over zero entries, so 1-wei ghosts at the head are
  self-clearing even with capacity 0 (head i + 1 after each of 10 ghosts); dead entries behind a
  live head remain the griefing surface (R6-1). `requestDeposit(0)` is `BelowMinDeposit`; 1 wei
  still mints 0 spUSDC shares and is donated to spUSDC (10 wei for 10 ghosts).
  `test_requestDepositCancellation_selfSkipClearsHeadOnly`,
  `test_requestDepositCancellation_deadEntryBehindLiveHeadIsWalkedLater`,
  `test_requestDeposit_walksGhostsAtHead`, `test_requestDepositCancellation_cycleLosesOneWeiPerRound`
  (head i + 1 per cycle, 10 wei lost over 10 cycles, no dead entries pile up),
  `test_requestDepositCancellation_cancelledEntriesConsumeRequestBudget` (50 dead entries behind
  bob still cost 50 slots), `test_processPendingDeposits_gasWith500GhostEntries` (2_253 gas per
  deposit ghost, unchanged).
- **R4-A / R4-B (blacklist fallback)**: **fixed by try/catch** (`_redeemSavings` `:978-995`,
  `_withdrawSavings` `:997-1014`). Recipient blacklisted after the cancel: `ClaimableAssetsIncreased(alice,
  99_999_999)` then `DepositCancellation(0, alice, alice, SS_100, 99_999_999)`, bob behind her
  paid in the same call, `claimableAssets[alice] == totalClaimable == 99_999_999`, parked USDC
  invisible to `totalAssets` / `availableLiquidAssets`, `claim` reverts in USDC while
  blacklisted and pays exactly 99_999_999 afterwards, `totalClaimable` back to 0. Partial then
  blacklist: 39_999_998 direct + 60_000_001 claimable. Repointing to a blacklisted address is
  accepted. A non-recipient revert still propagates: with the vault itself blacklisted the
  fallback `redeem(ss, vault, vault)` reverts `BLACKLISTED` and the entry stays (`leftD ==
  SS_100`). `test_fixed_processPendingDepositCancellations_recipientBlacklistedAfterCancel`,
  `test_processPendingDepositCancellations_partialThenBlacklistSplitsPayout`,
  `test_claim_parkedUsdcIsIsolatedFromDepositsAndTake`,
  `test_processPendingDepositCancellations_vaultBlacklistedStillPaysCleanRecipients`.
- **C-7 / R5-11 (max below live fee)**: **open, low**. `setMaxRedeemFeeRate(0.001e18)` leaves
  `redeemFeeRate == 0.01e18`; the next `requestRedeem(SH_1M)` still burns 9_904_051_842.
  `test_BUG_setMaxRedeemFeeRate_belowCurrentFeeDoesNotClamp`, `test_setRedeemFeeRate_boundariesAndEvents`.
- **R5-14 (all-fee `minRedeem` entry)**: **open, low**. With `minRedeem == 1`, `requestRedeem(1)`
  at 1% emits `RedeemRequest(0, alice, alice, 1, 1)`, queues 0 shares, `pendingRedeemShares`
  unchanged, `updateRedeemRecipient` -> `NoRequest`; the planner walks it as a zero fill (R6-2).
  1 share is the only all-fee amount (ceil(n/100) >= n only for n == 1): `minRedeem >= 2` makes
  it unreachable (`BelowMinRedeem`), a launch-parameter question. 100 one-share requests cost
  alice 100 shares and the operator 100 slots. `test_BUG_requestRedeem_minRedeemAllFeeLeavesZeroShareEntry`,
  `testFuzz_requestRedeem_oneShareAtAnyNonzeroFeeIsFullyBurnedGhost`.
- **R5-3 / C-3 (no loss floor, LOSS_MANAGER role)**: re-pinned on the cancel side only:
  `adjustTotalAssets` is `LOSS_MANAGER_ROLE` (admin, operator, fee setter all get
  `AccessControlUnauthorizedAccount(who, LOSS_MANAGER_ROLE)`), paused only, `-99_999_998` on
  99_999_998 is `LossTooHigh`, `-50e6` halves chi; division-by-zero panic with no holders is
  unchanged. `test_adjustTotalAssets_escrowedRedeemTakesLoss_cancelledDepositDoesNot`,
  `test_adjustTotalAssets_panicsWithNoHolders`, `test_roles_cancelAndFeeSurface`.
- **R5-2 (deposit before pause captures gain)**: **open**, unchanged numbers (bob 9_999_000_103
  of 10_000_000_003). `test_adjustTotalAssets_depositBeforePauseCapturesGain`.
- **R5-5 / F-2 (fills and `take` spend queued backing)**: **open**, unchanged
  (`_spendsOtherQueuedDepositorsBacking`, `_afterTakeSettlesWhatIsThere_restWaits`,
  `_takeExceedsOneRequest_partialThenWait`, `_feeSurplusCoversRefund`, `_stillMintsAfterTakeSpentBacking`).
- **C-11 (dust deposits donate to spUSDC)**: **open** (1 wei -> ghost, `NoRequest` on cancel,
  the wei unaccounted in spUSDC). `testFuzz_requestDepositCancellation_roundTripExact` (amount 1).
- **C-8 minimums**: `setMinDepositCancellation(0)` -> `ZeroMinDepositCancellation`; unbounded
  above (100e6 shares accepted). `test_setMinDepositCancellation_isInSpUsdcShareUnits`.
- **B-3 (cancellation budget vs spUSDC liquidity)**: still fixed and fuzzed
  (`testFuzz_processPendingDepositCancellations_liquidityClampNeverReverts`).
- **V2-1 / V2-2 / F-1 / F-8 / B-2 (privileged cancel paths, updaters)**: still fixed by removal /
  owner-only; blacklisted recipients now accepted by the updater.
  `test_fixed_requestDepositCancellation_privilegedCancelRemoved`,
  `test_fixed_updateDepositCancellationRecipient_ownerOnly`, `test_requestRedeem_pauserCannotTouchEscrow`.

### (c) Code paths in this area and the tests that cover them

- `requestDepositCancellation` `:405-446`, every revert in check order (`ZeroRecipient`,
  `VaultIsRecipient`, `InvalidRequestId` at length / max, `NoRequest` on cancelled / filled /
  ghost, `NotRequestOwner` before the amount checks, `BelowMinDepositCancellation` at 0 and
  min - 1, `SavingsSharesTooHigh` at shares + 1 and max), both boundaries succeeding, nothing
  moving on failure: `test_requestDepositCancellation_revertMatrix_checkOrder`,
  `_revertsOutOfRange`, `_revertsNoRequest_alreadyCancelled`, `_alreadyFilled` (raw storage read
  of the deleted entry, getter `InvalidRequestId` below the head), `_ghost`, `_revertsZeroRecipient`,
  `_revertsNotAuthorized`, `_fillRecipientCannotCancel`.
- Full cancel (`delete`, `:435`) and partial cancel (`shares -= `, `:437`), multiple partials of
  one entry, each with its own cancelled entry / recipient / `DepositCancellationRequest(id, cid,
  recipient, amount)`, `getPendingDepositCancellationRequests()` listing, head unchanged while
  live: `_partialCancels_remainderBelowMinIsStuck`, `testFuzz_requestDepositCancellation_partialCancelsAccounting`
  (3 random chunks, `pendingDeposit + pendingCancelled == ss` after every step, settlement pays
  `sum floor(chunk * chi_s / RAY)`, at most k wei under one-shot, remainder fills within 2 wei
  of its value, total loss <= k + 3 wei), `_fixed_requestDepositCancellation_worksWhilePaused`.
- The self-skip walk `:445` -> `:858-900` (`continue` on zero `:875`, `break` on budget 0
  `:878`): `_selfSkipClearsHeadOnly`, `_deadEntryBehindLiveHeadIsWalkedLater`, `_cycleLosesOneWeiPerRound`,
  `_thenReRequestFillsInstantlyWhenQueueEmpty`, `_thenReRequestQueuesBehindOthers`,
  `_partialFillRefundsRemainder` (head id + 1 after cancelling a partially filled head),
  `_partialFillCancelThenRefillOrdering`, `test_requestDeposit_walksGhostsAtHead`,
  `test_BUG_..._deadEntriesBehindHeadMakeCancelUnboundedGas` (gas, bounded operator recovery).
- `processPendingDepositCancellations` `:326-332`, `:902-940`: operator only (8 other actors,
  exact error), `maxRequests_` / `maxSavingsShares_` honoured, partial settlement keeps the head,
  liquidity clamp by `maxRedeem` (fuzzed, never reverts, shortfall <= n + 2 wei), pause-free,
  FIFO across cancel order, `pendingCancelledDepositSavingsShares` tracks open entries:
  `_maxRequestsHonoured`, `_maxSavingsSharesPartialFill`, `_revertsNotOperator`, `_clampsToSpUsdcLiquidity`,
  `_liquidityClampRespectsMaxRequests`, `testFuzz_..._liquidityClampNeverReverts`,
  `test_pendingCancelledDepositSavingsShares_tracksOpenEntries`, `_gasPerEntry` (153_434 for one,
  marginal 32_398 per settled entry), `_fixed_..._worksWhilePaused`.
- `_redeemSavings` try/catch `:978-995` and `claim` `:531-543` (`totalClaimable` up and down):
  the four blacklist tests in (b) plus `_blacklistedOwnerRoutesRefundToCleanRecipient`.
- `updateDepositCancellationRecipient` `:495-512`: owner-only, zero / vault rejected,
  blacklisted accepted, settled entry `NoRequest` (length-bounded only, `:501`):
  `test_fixed_updateDepositCancellationRecipient_ownerOnly`.
- `requestRedeem` fee `:463-467`: `_divUp` exactness (`testFuzz_requestRedeem_feeIsCeil`,
  `_feeOverchargesAtMostOneWei`: `shares * rate <= fee * WAD < shares * rate + WAD` for shares in
  [1, 1e30]), 1e-18 rounds to 1 share, cap exact (9_904_051_842 on SH_1M, payout
  989_999_999_997, `RedeemRequest(0, alice, alice, SH_1M, 9_904_051_842)`), burned at request and
  ignored by later changes (alice 989_999_999_997 at 1% then bob 999_999_999_998 at 0%), sunk
  (no refund on repoint), splitting never reduces it (+159 shares over 1000 chunks, fuzzed
  `<= single + n - 1`), transfers do not avoid it (+8 over 10 addresses), the burn frees exactly
  `fee` shares of capacity, chi and every other holder's claim unchanged (fuzzed over amounts and
  fee: `testFuzz_requestRedeem_feeBurnLeavesOtherHoldersUnchanged`), surplus == fee value within
  6 wei of floors, `adjustTotalAssets(+surplus)` credits it pro-rata within 1 wei (bob 999_900 /
  carol 9_999_000_103 of 10_000_000_003; chi `1.019783636340772882610822844e27`): tests of
  sections 5, 6, 11, 14, 16, 19.
- `setRedeemFeeRate` `:347-350` / `setMaxRedeemFeeRate` `:219-222`: exact cap boundaries with
  `RedeemFeeRateSet` / `MaxRedeemFeeRateSet` events, `FeeTooHigh` / `MaxFeeTooHigh` one wei
  above, max 0 accepts only 0, role matrix: `test_setRedeemFeeRate_boundariesAndEvents`,
  `test_setRedeemFee_revertsAboveMax`, `test_setMaxRedeemFee_revertsAboveOnePercent`,
  `test_setRedeemFeeRate_accessAndZeroMax`, `test_roles_cancelAndFeeSurface`.
- `minRedeem` gross of fee (minimum worth 99_999_999, net 98_999_998; `BelowMinRedeem`), drift
  with chi, `minDeposit` boundary (`BelowMinDeposit`): `test_requestRedeem_minRedeemIsGrossOfFee`,
  `_minRedeemValueDriftsWithChi`, `test_requestDeposit_minDepositBoundary`.
- Roles: `pause` PAUSER only (unpauser / admin cannot), `unpause` UNPAUSER only (pauser / admin
  cannot), the three admin setters, fee setter, operator, loss manager, all with the exact
  `AccessControlUnauthorizedAccount(account, role)`: `test_roles_cancelAndFeeSurface`.
- Free option after `adjustTotalAssets`: none. Cancel refund 99_999_999 before, during (paused,
  after the loss) and after a -50e6 loss; filled after the loss: 198_081_039 shares worth
  99_999_998 at chi `0.504843871119937711956814603e27`; after a +100e6 gain a queued deposit is
  filled for 49_520_258 shares worth 99_999_997 and a cancel refunds 99_999_999, while escrowed
  redeem shares take both the loss (49_999_997) and the gain: `_queuedDepositIsImmuneToLoss`,
  `_queuedDepositDoesNotShareGain`, `test_adjustTotalAssets_escrowedRedeemTakesLoss_cancelledDepositDoesNot`.
- Round trip at the ugly indexes: `floor(floor(a * RAY / chi_s) * chi_s' / RAY)`, <= 2 wei
  under with no accrual, up to 10 years of accrual, amounts in [1, 1e15]:
  `testFuzz_requestDepositCancellation_roundTripExact`; yield while queued == direct spUSDC
  (1_049_999_999_998 after a year at 5%): `_queuedDepositEarnsSpUsdcYield`,
  `test_processPendingDeposits_fillCreditsSpUsdcYieldAccruedWhileQueued`, `test_requestRedeem_escrowAccruesVsrUntilFill`.
- `transfer` / `transferFrom` to the vault rejected, escrow == `pendingRedeemShares`:
  `test_fixed_transfer_toVaultRejected`.

### (d) Properties that held (fuzzed at 20000 runs)

- `fee == ceil(shares * rate / WAD)` and `shares * rate <= fee * WAD < shares * rate + WAD`,
  shares in [1, 1e30], rate in [0, 1%]; a 1-share request at any rate in (0, 1%] is a ghost;
  split fee in `[single, single + n - 1]` for n in [1, 64].
- The fee burn never changes `assetsOf` of another holder or `nowChi`; the surplus it leaves is
  the fee's value within 6 wei; `adjustTotalAssets(+surplus)` credits it within 1 wei.
- Partial-cancel accounting: `pendingDepositSavingsShares + pendingCancelledDepositSavingsShares
  == ss` after every step, the entry holds exactly the remainder and keeps the head while live,
  the head moves to id + 1 only when it hits 0, settlement pays `sum floor(chunk * chi_s / RAY)`
  (<= k wei under one-shot), total value out <= deposit and >= deposit - (k + 3).
- Cancellation settlement never reverts under any spUSDC liquidity, pays at most the liquidity,
  shortfall <= n + 2 wei.
- Round trip refund is exact (`floor(floor(a * RAY / chi) * chi' / RAY)`) and never above the
  deposit plus accrual.

### (e) Unsettled

- Whether the unbounded self-skip walk in `requestDepositCancellation` / `requestDeposit` should
  be capped (R6-1): it is only a liveness cost and the operator can always recover, but a user's
  cancel can be made to exceed the block gas limit by a griefer with ~12_650 dead entries.
- Whether the redeem loop should `continue` over zero entries like the deposit loop does
  (R6-2); only reachable with `minRedeem == 1`.
- `test/ai/TestBase.t.sol` (fork harness, not owned here) does not compile on this master
  (duplicate `operator` / `OPERATOR_ROLE`, 4-arg `initialize`); every run of this file needs
  `--skip test/ai/TestBase.t.sol`.

### Ported / retired at c512609

- `_recipientVaultStrandsUsdc` (cancel and redeem) -> `test_fixed_..._vaultRecipientRejected`.
- `_revertsWhilePaused` (cancel and settlement) -> `test_fixed_..._worksWhilePaused`.
- `_headDoesNotMoveOnCancel` -> `_selfSkipClearsHeadOnly` + `_deadEntryBehindLiveHeadIsWalkedLater`.
- `test_processPendingRedeems_headDoesNotWalkOverGhosts` (`requestRedeem(0)`) ->
  `_walksGhostsAsZeroFills` (1-share ghosts at a fee).
- `_revertsRecipientBlacklisted_checkOrder` -> `_revertMatrix_checkOrder` (blacklist accepted).
- `_blacklistedOwnerRoutesRefundToCleanRecipient` rewritten (self-recipient now parks).
- `requestDeposit(0)` ghosts -> 1-wei ghosts everywhere; `stdError.indexOOBError` ->
  `InvalidRequestId`; `below-minimum` / `fee-too-high` strings -> selectors; `admin` ->
  `lossManager` on every `adjustTotalAssets`; `guardian` / `rebalancer` names dropped; entries
  below the head read with `vm.load` (`_rawDepositRequest` etc.); all emits carry `requestId`
  first and `DepositCancellationRequest` its share amount.

---

# CANCEL-FEES worker report, round 5: `test/ai/CancelAndFees.t.sol` @ `master` 0ebb452

85 tests, all passing (79 unit + 6 fuzz, verified at `FOUNDRY_FUZZ_RUNS=5000`) against
`src/SparkPrimeVault.sol` on `master` @ `0ebb452`. Two `test_BUG_` tests remain, both passing
proofs of still-open low-severity behaviour (C-7, V2-13). Line numbers below are on 0ebb452.
Harness indexes and the 100e6 / 1_000_000e6 constants are unchanged from earlier rounds
(chi_s `1.047633055711877768967605062e27`, chi_p `1.009687768242461209408770821e27`;
100e6 -> 95_453_269 spUSDC -> 99_040_517 spPRIME; 1_000_000e6 -> 954_532_691_143 -> 990_405_184_109).

## (a) Findings and suspicious behaviour

- **C-7 still open, low** (`setMaxRedeemFeeRate`, `src/SparkPrimeVault.sol:301-304`): the max only
  bounds future `setRedeemFeeRate` calls (`:376`); a live 1% fee stays in force after the max is
  lowered to 0.1% (or to 0): the next `requestRedeem(SH_1M)` still burns 9_904_051_842 shares.
  `test_BUG_setMaxRedeemFeeRate_belowCurrentFeeDoesNotClamp`.
- **V2-13 still open, low (self-harm)**: the spUSDC address and the vault address pass
  `_canReceiveAsset` (`:1051-1053`), so a cancellation (or redeem) recipient of `spUsdc` makes
  `spUsdc.redeem(ss, spUsdc, vault)` pay spUSDC itself: spUSDC's liability drops by 99_999_999 while
  its USDC balance does not move (100_000_000 of unaccounted liquidity afterwards); a recipient of
  the vault parks 99_999_999 USDC in the vault with no `claimableAssets` entry.
  `test_BUG_requestDepositCancellation_recipientSpUsdcDonatesRefund`,
  `test_requestDepositCancellation_recipientVaultStrandsUsdc`,
  `test_updateRedeemRecipient_recipientVaultStrandsUsdc`.
- **Cancel-vs-fill ordering, info/design** (`requestDepositCancellation` `:429` after
  `_processPendingDeposits` `:823-862`): the rebalancer (or the instant walk of a later request
  when the queue is otherwise empty) can fill an entry in the block before its owner's cancel; the
  cancel then fails `no-request` and the owner holds spPRIME. Exit cost at the 1% fee on 100e6:
  1_000_002 USDC (cancel refund 99_999_999 vs redeem payout 98_999_997) plus a wait bounded by
  spUSDC liquidity. There is no owner-side parameter (min shares, deadline) to defend with.
  `test_processPendingDeposits_frontRunsCancel_ownerHasNoDefence`.
- **Blacklisted owner can route out, info** (`:425`, `:452`): only the recipient is
  blacklist-checked, so a depositor or holder blacklisted after queuing cancels / redeems to a
  clean address and is paid there (99_999_999 / 99_999_998). The vault never moves USDC to or from
  the blacklisted owner so USDC's own checks never fire. Compliance question, not a vault bug.
  `test_requestDepositCancellation_blacklistedOwnerRoutesRefundToCleanRecipient`.
- **R3-1 residual, info**: `adjustTotalAssets` needs `paused` (`:279`), but a deposit that
  instant-fills before the guardian's pause takes its pro-rata share of a public gain: bob's
  1_000_000e6 just before a +10_000_000_003 fee-surplus distribution captures 9_999_000_103 of it
  (carol, 100e6, keeps 999_900). At the 1% fee the round trip is unprofitable
  (payout 999_899_010_099 < 1_000_000e6); at fee 0 it is free money.
  `test_adjustTotalAssets_depositBeforePauseCapturesGain`.
- **Dead entries now cost the planner** (`:840` `continue` counts against `maxRequests_`; no
  head walk anywhere but `:861`): a cancelled head entry stays in front of the head until a
  processing walk with non-zero capacity skips it. With capacity 0 the head never moves even over
  an all-dead queue (`remaining_ == 0` short-circuits `:837`). A 1-request batch after a cancel
  skips the dead slot and fills nobody. `test_requestDepositCancellation_headDoesNotMoveOnCancel`,
  `test_requestDepositCancellation_thenReRequestQueuesBehindOthers`,
  `test_requestDepositCancellation_cycleLosesOneWeiPerRound` (ten dead entries at the head),
  `test_requestDeposit_walksGhostsAtHead` (ghosts cleared only by an instant fill with capacity).
- **1-share redeem is a 100% fee + ghost** (`:460-468`): `_divUp(1 * fee, WAD) == 1` for every
  fee in (0, 1%]; the entry has shares 0, cannot be updated (`no-request`), and costs the
  planner a slot (2_396 gas per ghost, re-measured). Two shares at 1%: fee 1 (50%).
  `testFuzz_requestRedeem_oneShareAtAnyNonzeroFeeIsFullyBurnedGhost`, V2-9 shape.
- **Vault itself blacklisted** (new blacklist path): the cancellation and redeem queues keep
  paying clean recipients (USDC moves spUSDC -> recipient), new deposits revert in USDC, and a
  blacklisted recipient's fallback (`redeem` to the vault, `:942`) reverts `BLACKLISTED`, leaving
  that entry at the head. `test_processPendingDepositCancellations_vaultBlacklistedStillPaysCleanRecipients`.

## (b) Previously reported findings, status at 0ebb452

- V2-2 / F-1 (guardian-chosen refund recipient): **fixed by removal**. Guardian, admin,
  rebalancer, taker and stranger all get `not-authorized` for every recipient; nothing moves.
  `test_fixed_requestDepositCancellation_guardianCancelRemoved`,
  `test_requestDepositCancellation_fillRecipientCannotCancel`.
- V2-1 (unauthenticated recipient updaters): **fixed**, owner-only, zero and blacklisted
  recipients rejected, settled entries `no-request`.
  `test_fixed_updateDepositCancellationRecipient_ownerOnly`.
- R4-B (blacklisted cancellation recipient blocks the queue): **fixed**. Alice blacklisted after
  her cancel: settlement redeems to the vault, `ClaimableAssetsIncreased(alice, 99_999_999)`,
  bob behind her is paid in the same call, head 2, `pendingCancelledDepositSavingsShares` 0, the
  parked USDC is invisible to `totalAssets` / `availableLiquidAssets`, `claim` reverts in USDC
  while blacklisted and pays exactly 99_999_999 (permissionless) afterwards; second claim
  `nothing-to-claim`. Partial-then-blacklist splits 39_999_998 direct + 60_000_001 claimable.
  Parked USDC is untouched by deposits, `take` and fills; two blacklisted payouts stack.
  `test_fixed_processPendingDepositCancellations_recipientBlacklistedAfterCancel`,
  `test_processPendingDepositCancellations_partialThenBlacklistSplitsPayout`,
  `test_claim_parkedUsdcIsIsolatedFromDepositsAndTake`.
- R3-1 (`realizeGain` sandwich): **changed**: `adjustTotalAssets` requires `paused`,
  `requestDeposit` / cancels are blocked while paused; pre-pause capture quantified above.
  `test_adjustTotalAssets_withoutBackingIsNotional`, `test_adjustTotalAssets_depositBeforePauseCapturesGain`.
- Share donation to the vault (round-2 F-5 shape): **fixed**, `transfer` / `transferFrom` to the
  vault or zero revert `invalid-address`; the escrow equals `pendingRedeemShares` exactly.
  `test_fixed_transfer_toVaultRejected`.
- B-3 (cancellation budget ignores spUSDC liquidity): **still fixed**, now also fuzzed: with any
  liquidity L and up to 8 entries the settlement never reverts, pays at most L, and the clamped
  shortfall is at most `n + 2` wei. `testFuzz_processPendingDepositCancellations_liquidityClampNeverReverts`,
  `test_processPendingDepositCancellations_clampsToSpUsdcLiquidity`.
- `realizeGain` with no holders (`no-shares`): **changed** to a division-by-zero panic in
  `adjustTotalAssets` (`:289`); the fee surplus of 10_000_000_001 USDC is then only reachable by
  `take`. `test_adjustTotalAssets_panicsWithNoHolders`.
- C-11 (dust deposits donate to spUSDC): **open**, 1 wei of USDC mints 0 spUSDC shares, the
  entry is a ghost (`no-request` on cancel) and the wei is unaccounted in spUSDC.
  `testFuzz_requestDepositCancellation_roundTripExact` (amount 1 branch).
- F-2 (`take` drains queue backing), I-2 (fee surplus uncounted by chi), V2-9 (ghost redeems),
  N-1 (dead entries consume request budget): **open**, re-measured unchanged (section c).
- Removed with their code: B-2 / F-8 (`cancelRedeemRequest`), guardian repoint, `invalid-recipient`.

## (c) Properties that held (exact values)

- Fee exactness: `fee == ceil(shares * rate / WAD)` for shares in [1, 1e30], rate in [0, 1%]
  (`testFuzz_requestRedeem_feeIsCeil`); `shares * rate <= fee * WAD < shares * rate + WAD`
  (`testFuzz_requestRedeem_feeOverchargesAtMostOneWei`); 1e-18 fee rounds to 1 share
  (`test_requestRedeem_feeRoundsUpToOneWei`); at the cap SH_1M -> fee 9_904_051_842 shares
  (10_000_000_000 USDC), payout 989_999_999_997, `RedeemRequest(alice, alice, 0, SH_1M, 9_904_051_842)`
  (`test_requestRedeem_feeAtCapExact`).
- Fee economics: splitting never reduces the fee and adds at most one share per extra request
  (1000 chunks of SH_1M: 9_904_052_001 vs 9_904_051_842, +159; 100 one-share requests: 100%),
  fuzzed for n in [1, 64] (`test_requestRedeem_splittingIntoManyRequestsNeverReducesFee`,
  `testFuzz_requestRedeem_splitFeeBoundedBySingleFeePlusRequests`); transferring to a fresh
  address changes nothing (ten addresses: 9_904_051_850, +8)
  (`test_requestRedeem_feeCannotBeAvoidedByTransfer`); the fee is burned at request and a later
  fee change does not touch the fill (alice 989_999_999_997 at 1% then bob 999_999_999_998 at 0%)
  (`test_processPendingRedeems_feeChangeAfterRequestHasNoEffect`, `test_requestRedeem_feeIsSunkAtRequest`);
  the burn frees exactly `fee` shares of capacity (9_904_051_842; a 10_000e6 deposit then fills
  instantly leaving 2) (`test_requestRedeem_feeBurnFreesCapacity`); the burn leaves chi and every
  holder's claim unchanged, the surplus is 10_000_000_002 USDC of spUSDC in the vault
  (`test_requestRedeem_feeLeavesChiUnchangedAndRaisesBackingPerShare`,
  `test_requestRedeem_feeNotCreditedToRemainingHolders`); `adjustTotalAssets(+surplus)` credits it
  pro-rata within 1 wei: bob 999_900 / carol 9_999_000_103 of 10_000_000_003, chi
  `1.019783636340772882610822844e27`, `totalAssets` 1 wei under target
  (`test_adjustTotalAssets_feeSurplusIsProRataToRemainingHolders`,
  `test_adjustTotalAssets_distributesFeeSurplusToRemainingHolders`).
- Minimums: `minRedeem` is gross of fee (minimum worth 99_999_999, net payout 98_999_998)
  (`test_requestRedeem_minRedeemIsGrossOfFee`), drifts with chi
  (`test_requestRedeem_minRedeemValueDriftsWithChi`); `setRedeemFeeRate` above max and
  `setMaxRedeemFeeRate` above 1% revert `fee-too-high`; only REDEEM_FEE_SETTER sets the fee, with
  max 0 only 0 is accepted (`test_setRedeemFee_revertsAboveMax`, `test_setMaxRedeemFee_revertsAboveOnePercent`,
  `test_setRedeemFeeRate_accessAndZeroMax`).
- Cancel permissions and checks, in order `:424-430`: zero recipient, blacklisted recipient
  (also before `not-authorized` and before the out-of-range read), `no-request`, `not-authorized`
  (`test_requestDepositCancellation_revertsRecipientBlacklisted_checkOrder`,
  `test_requestDepositCancellation_revertsZeroRecipient`, `_revertsNotAuthorized`,
  `_revertsNoRequest_alreadyCancelled`, `_alreadyFilled`, `_ghost`, `_revertsOutOfRange`,
  `_revertsWhilePaused`, `test_processPendingDepositCancellations_revertsWhilePaused`,
  `_revertsNotRebalancer`).
- Partial fills: cancelling a partially filled head moves only the remainder (57_271_963 shares,
  60_000_001 USDC; minted 39_999_997 + refund = 99_999_998) and the next live entry fills
  without double counting (`test_requestDepositCancellation_partialFillRefundsRemainder`,
  `test_requestDepositCancellation_partialFillCancelThenRefillOrdering`).
- `pendingCancelledDepositSavingsShares` equals the sum of open cancelled entries through a mixed
  sequence of cancels, partial and full settlements
  (`test_pendingCancelledDepositSavingsShares_tracksOpenEntries`); `maxRequests_` and
  `maxSavingsShares_` honoured (`_maxRequestsHonoured`, `_maxSavingsSharesPartialFill`,
  `_liquidityClampRespectsMaxRequests`).
- Round trip: deposit / cancel / settle returns `floor(floor(a * RAY / chi_s) * chi_s' / RAY)`,
  never above the deposit plus accrual, at most 2 wei under with no accrual, for any amount in
  [2, 1e15] and 0-10 years of spUSDC accrual (`testFuzz_requestDepositCancellation_roundTripExact`);
  ten 100e6 cycles lose exactly 10 wei (`test_requestDepositCancellation_cycleLosesOneWeiPerRound`).
- Free option: none. A queued deposit is spUSDC; a cancel returns 99_999_999 before and after a
  50% `adjustTotalAssets` loss, cancel is blocked while paused so nobody acts between loss and
  unpause, and a post-loss fill mints 198_081_039 shares worth the same 99_999_998 at chi
  `0.504843871119937711956814603e27` (`test_requestDepositCancellation_queuedDepositIsImmuneToLoss`).
  Escrowed redeem shares do take the loss (49_999_997 on 100e6) while a cancelled deposit does
  not (`test_adjustTotalAssets_escrowedRedeemTakesLoss_cancelledDepositDoesNot`).
- Yield while queued and in the cancelled queue equals direct spUSDC holding
  (1_049_999_999_998 after a year at 5%) (`test_requestDepositCancellation_queuedDepositEarnsSpUsdcYield`,
  `test_processPendingDeposits_fillCreditsSpUsdcYieldAccruedWhileQueued`,
  `test_requestRedeem_escrowAccruesVsrUntilFill`).
- F-2 shape unchanged: settlement spends the vault's whole spUSDC balance (other depositors'
  backing, fee surplus), pays what is there and waits for the rest without reverting
  (`_spendsOtherQueuedDepositorsBacking`, `_afterTakeSettlesWhatIsThere_restWaits`,
  `_takeExceedsOneRequest_partialThenWait`, `_feeSurplusCoversRefund`, `_stillMintsAfterTakeSpentBacking`).
- Gas, cold (re-measured on 0ebb452): deposit ghost 2_315 / redeem ghost 2_396 per entry;
  one settled cancellation 107_299, marginal 24_759 per settled entry
  (`test_processPendingDeposits_gasWith500GhostEntries`, `test_processPendingRedeems_gasWith500GhostEntries`,
  `test_processPendingDepositCancellations_gasPerEntry`); 50 cancel cycles behind a live head
  leave 50 dead entries that each cost a request slot (`_cancelledEntriesConsumeRequestBudget`).

## (d) Unsettled

- Whether the planner's "dead entries count against `maxRequests_`" (no head walk outside
  `_processPendingDeposits`) is intended; it is only a liveness cost for the rebalancer, not a
  user-facing loss.
- Whether a blacklisted owner routing a queued deposit / redeem to a clean recipient is the
  intended compliance posture (USDC would freeze the same funds if they were held as USDC).
- Mainnet `FiatToken` semantics for `approve` with a blacklisted spender are mirrored by the mock;
  the vault-blacklisted scenario is only as accurate as that mirror.

## Ported / retired at 0ebb452

- `test_requestDepositCancellation_guardianMustRefundOwner`, `_guardianRefundsOwnerNotFillRecipient`,
  `_ownerCanRepointAfterGuardianCancel` -> `test_fixed_requestDepositCancellation_guardianCancelRemoved`,
  `test_requestDepositCancellation_fillRecipientCannotCancel`, `test_fixed_updateDepositCancellationRecipient_ownerOnly`.
- `test_requestDepositCancellation_headEntryAdvancesHead` -> `_headDoesNotMoveOnCancel`.
- `test_realizeLoss_*`, `test_realizeGain_*` -> `test_adjustTotalAssets_*` (five tests).
- `test_transfer_toVaultStrandsSharesWithoutBreakingQueues`, `test_transferFrom_toVaultStrandsShares`
  -> `test_fixed_transfer_toVaultRejected`.
- `test_setMaxRedeemFee_belowCurrentFeeLeavesFeeInForce` -> `test_BUG_setMaxRedeemFeeRate_belowCurrentFeeDoesNotClamp`.
- `DepositCancellationRequest` now carries the recipient as a third indexed topic; all emits updated.

---

# CANCEL-FEES worker report, round 4: `test/ai/CancelAndFees.t.sol` @ `bf93b0d`

63 tests, all passing (62 unit + 1 fuzz at 5000 runs) against `src/SparkPrimeVault.sol` on
`fix/update-guardian-transfer` at `bf93b0d`. No `test_BUG_` test is left in this file: B-1 is
fixed and B-2 is removed with its function. Line numbers in this section refer to bf93b0d.
Harness indexes and the 100e6 / 1_000_000e6 constants are unchanged.

## Fixed at bf93b0d

- B-1 (F-1 deposit side, Medium): `requestDepositCancellation` (`src/SparkPrimeVault.sol:409-449`)
  now requires `recipient_ == request_.owner` when the caller is not the owner (`:424`,
  `SparkPrimeVault/invalid-recipient`), after the guardian check (`:423`, `not-authorized`) and
  after the generic zero check (`:414`). The owner path is unchanged (any non-zero recipient).
  Regression tests:
  - `test_requestDepositCancellation_guardianMustRefundOwner`: guardian naming itself, a
    stranger, or `address(0)` reverts `invalid-recipient`; a stranger naming the owner reverts
    `not-authorized`; nothing moves on the failed attempts; guardian naming alice succeeds,
    emits `DepositCancellationRequest(id, 0)`, the cancelled entry is `(alice, alice, SS_1M)`,
    settlement emits `DepositCancellation(alice, alice, SS_1M, 999_999_999_999)` and pays alice
    `999_999_999_999`, guardian 0.
  - `test_requestDepositCancellation_guardianRefundsOwnerNotFillRecipient`: alice deposits for
    bob; the guardian cannot name bob (`invalid-recipient`), must name alice; alice is paid
    `99_999_999`, bob 0.
  - `test_requestDepositCancellation_ownerCanRepointAfterGuardianCancel`: after a guardian cancel
    the owner repoints to bob (`DepositCancellationRecipientUpdated`), guardian and stranger get
    `not-authorized`, zero gets `invalid-recipient`, a second guardian cancel of the spent id is
    `no-request`, settlement pays bob `99_999_999`, the settled entry rejects further updates.
  - Replaces `test_BUG_requestDepositCancellation_guardianCanRedirectRefund`,
    `..._guardianRedirectRepairedByOwnerBeforeSettlement`, `..._guardianRedirectNotRepairableAfterSettlement`.

## Removed at bf93b0d

- B-2 (F-1 redeem side, High) and F-8 (guardian cancel keeps the fee): `cancelRedeemRequest` no
  longer exists, so no function moves escrowed redeem shares to anyone but the fill recipient.
  `test_requestRedeem_guardianCannotTouchEscrow` (old selector fails for guardian, admin and
  owner; guardian `updateRedeemRecipient` reverts `not-authorized`; escrow `SH_1M` unchanged;
  fill pays alice `999_999_999_998`, guardian 0),
  `test_requestRedeem_noCancel_feeOnlyChargedOnceAndNetIsPaid` (1% fee, fill pays
  `989_999_999_997`, no shares ever return).
- The cancel / re-request cycle on the redeem side is gone: a second request needs the first to
  be paid (`test_requestRedeem_noCycleWithoutAFill`: `requestRedeem(1)` after a full-balance
  request reverts `insufficient-balance`; after the fill `SS_1M - 944_987_364_230` spUSDC of fee
  surplus remain). The round-3 "3 cycles cost 3 fees" test is retired.
- Redeem-side head walking never existed and the cancel-time walk is gone with the cancel:
  `test_processPendingRedeems_headDoesNotWalkOverGhosts` (two ghosts in front of carol cost two
  slots; the deposit head walks over dead entries, the redeem head does not).
- Every other redeem-cancel test was rewritten as a finality or fill test with the same numbers:
  partial fill of `39_999_999` then the remainder `59_424_310` shares stays escrowed and pays
  `59_999_998` when liquidity returns (`99_999_997` total, 1 wei under one fill)
  (`test_requestRedeem_partialFillRemainderStaysQueuedUntilPaid`); `realizeLoss(50e6)` while
  queued pays `49_999_997` with no way out and leaves the cancelled deposit's `99_999_999` intact
  (`test_realizeLoss_escrowedRedeemTakesLoss_cancelledDepositDoesNot`); a year at 5% on a 1%
  escrow pays `1_039_499_999_997` at fill (`test_requestRedeem_escrowAccruesVsrUntilFill`);
  the fee lowered to 0 after the request does not refund it (`test_requestRedeem_feeIsSunkAtRequest`:
  `10_000_000_001` USDC of claim is final); pause blocks new requests and the planner but not the
  owner's repoint (`test_requestRedeem_revertsWhilePaused_repointDoesNot`); donated shares at the
  vault survive fills untouched (`test_transfer_toVaultStrandsSharesWithoutBreakingQueues`);
  `updateRedeemRecipient(id, vault)` strands `99_999_998` USDC in the vault
  (`test_updateRedeemRecipient_recipientVaultStrandsUsdc`, C-6 remnant, owner self-harm).

## New in this area

- The cost of the redeem-side blacklist jam (REDEEM-QUEUE's RQ-10, High) in fee terms: the only
  sunk cost is the fee on `minRedeem` shares; the escrow comes back on release. With `minRedeem`
  0 and fee 0 (launch defaults) a jam costs 1 share. Owned and proven in `RedeemQueue.t.sol`.
- `requestDepositCancellation` ordering for the guardian: `:414` zero check, `:420` `no-request`,
  `:423` role, `:424` owner match. A guardian naming `address(0)` therefore gets
  `invalid-recipient` from `:414`, a stranger naming the owner gets `not-authorized`, a guardian
  naming anyone but the owner gets `invalid-recipient` from `:424`. All three pinned.

## Properties re-checked and held at bf93b0d

Everything in the round-2 section (c) that does not involve a redeem cancel re-ran unchanged
(same exact values; gas unchanged: 2_328 / 2_408 per ghost entry on the deposit / redeem queue,
`99_354` for one settled cancellation, 22_931 marginal per settled entry). B-3 fix, B-4, N-1,
F-2, F-5, F-7, I-2, I-4, I-6, C-6 (deposit side), N-3, the fee fuzz (ceil, 5000 runs), fee locked
at request, `realizeGain` fee-surplus distribution (`101.978466055462937456192802386e27`,
bob `10_100_000_000`, 1 wei dust), `realizeGain` with no holders (`no-shares`), the notional
gain (`2.019375545061017805470462154e27`), and the spUSDC-yield-while-queued tests all reproduce.
Line references moved: `_processPendingDepositCancellations` budget `:848`, loop `continue`
`:860`; `_processPendingDeposits` `continue` `:818`; `_processPendingRedeems` budget `:886`,
`withdraw` `:909`; `take` `:325-334`; `requestDepositCancellation` delete / push `:427` / `:431`.

## Unsettled

- Whether the guardian should also get a repoint-to-owner on the REDEEM queue (the mirror of the
  bf93b0d deposit-cancel rule) is the fix question for RQ-10; this file only shows the guardian
  has nothing on that side.
- `requestDepositCancellation` by the guardian still lets the guardian move a queued deposit
  into the cancelled queue against the depositor's will (refund to the owner, settlement timing
  the planner's). That is the intended emergency tool; noted as a trust assumption, not a finding.
- The 1 wei of spUSDC that `maxRedeem` leaves behind per liquidity-constrained settlement is
  unchanged.

---

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
