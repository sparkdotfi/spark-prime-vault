# Round 4 (bf93b0d)

Worker: QUEUES-ROUNDING. File: `test/ai/DepositQueue.t.sol` (`DepositQueueTest is LocalTestBase`), branch `campaign-v4/queues-rounding`, source `src/SparkPrimeVault.sol` at upstream `fix/update-guardian-transfer` `bf93b0d`.
Result: 62 tests, 62 pass (59 unit, 3 fuzz at 5000 runs). No `test_BUG_` test fails in this file; the three remaining `test_BUG_*` (DQ-1 x2, DQ-2) pass by asserting the known behaviour. Harness indexes and reference conversions unchanged.

Line remap (ff828d2 -> bf93b0d): `_requestDeposit` 706-736 -> 760-793 (head walk 782-787, instant decision 790-792); `requestDepositCancellation` (was `cancelDepositRequest`) 428-463 -> 409-449 (auth 422-425, push 431-433, head walk 440-445); `updateDepositRecipient` 416-425 -> 483-492; `updateDepositCancellationRecipient` (was `updateCancelledDepositRecipient`) 465-477 -> 494-506; `_processPendingDeposits` 738-779 -> 799-840 (capacity conversion 803-806, loop 813, `continue` 818, fill math 823-824, mint 830, partial `break` 834, `delete` 836); `_processPendingDepositCancellations` 781-815 -> 842-879 (budget 847-848, `redeem` 868-869); `realizeLoss` 369-385 -> 365-381; `realizeGain` 297-309 -> 293-305; `totalAssets` 675-677 -> 752-754. The `requestDeposit` natspec with the stale `type(uint256).max` note is gone (no natspec on the function any more).

## Fixed since round 3

- DQ-7 · High · FIXED. `requestDepositCancellation` (`src/SparkPrimeVault.sol:422-425`) now requires `recipient_ == request_.owner` for a non-owner caller, checked after `not-authorized`. The cancelled entry is `(owner, owner, shares)` and settlement (`:869`) pays the owner. `test_BUG_guardianCancelRefundsToArbitraryRecipient` became three regression tests: `test_requestDepositCancellation_guardianRefundsOwner` (guardian names alice: entry `(alice, alice, 954_532_691_143)`, head walks to 1, settlement pays alice `999_999_999_999`, bob and the guardian 0, both pending counters 0); `test_requestDepositCancellation_guardianRevertsNonOwnerRecipient` (bob the share recipient, the guardian, carol and the vault all revert `invalid-recipient`; carol and bob naming alice revert `not-authorized`, so the order is auth first; the entry, counters, head and cancelled-queue length are untouched); `test_requestDepositCancellation_ownerNamesAnyRecipient_andRepointsAfterGuardian` (owner cancels to carol; after a guardian cancel the owner repoints the refund to dave through `updateDepositCancellationRecipient` because the cancelled entry keeps `owner = alice` (`:432`, `:500`), the guardian's repoint reverts `not-authorized`; carol and dave each receive `999_999_999_999`).
- `cancelRedeemRequest` removed: no deposit-queue test used it. Redeem requests are final.

## New findings (round 4)

- DQ-10 · Low · Refund repointed to the vault is stranded. `updateDepositCancellationRecipient` (`src/SparkPrimeVault.sol:495`) only rejects `address(0)`, so the owner can set the vault itself as the refund recipient; `spUSDC.redeem(shares, vault, vault)` (`:869`) then leaves the USDC in the vault, where nothing reads it (`_requestDeposit` pulls `assets_` from the caller and deposits exactly `assets_`, `:769-771`; there is no sweep). Mirror of DQ-4 on the refund side; self-inflicted. `test_updateDepositCancellationRecipient_toVaultStrandsRefund`: `999_999_999_999` USDC sits in the vault, a later deposit by bob neither uses nor frees it. Same shape for `address(savings)` as the recipient (USDC donated to spUSDC's liquidity, not tested) and for the redeem recipient on the redeem side (RedeemQueue worker's file).
- No new bug on the guardian path. The check is placed so a stranger cannot probe it (`not-authorized` first), the owner's choice is unrestricted, and the cancelled entry's `owner` is never the guardian, so the guardian never gains a repoint right either.

## Persisting (re-confirmed at bf93b0d)

- DQ-8 · Low · unbounded head walk in the cancel (`:440-445`); planner loop skipped at `:813` when `remaining_ == 0`, so a ghost head is only walked by a cancel or by the next request; ghosts still creatable (`:765`, `minDeposit == 0`). Per ghost the walk costs one cold SLOAD plus one warm SSTORE (`++firstPendingDepositId` writes every step), about 2.3k gas. The victim is never locked: the planner fill at the head does not need the walk. `test_requestDepositCancellation_headWalkGasGrowsWithGhosts`, `test_requestDeposit_zeroAssetsCreatesGhostEntry`.
- DQ-1 · Low · exact-fit capacity leaves a 1-share dust head (`:803-806` double floor, `:782-787` walk stops on it, `:834` keeps it). `test_BUG_exactFitCapacityLeavesDustThatBlocksInstantFills`, `test_BUG_twoWeiDepositAtFullCapacityJamsInstantPath`.
- DQ-2 · Low (F-4) · 1-share fill mints 0 and burns the spUSDC share (`:823-836`). After a realised loss (`chi < RAY`) this region is empty (see REPORT-rounding round 4). `test_BUG_dustFillMintsZeroShares`.
- DQ-3 · Info · cancelled entries behind a live head consume `maxRequests_` (`:811`, `:818`).
- DQ-4 · Low · `recipient_ == address(vault)` shares are stuck (`:764`, `:830`).
- DQ-5 · Medium (F-2) · fills mint against backing that left (`:799-840` never reads the spUSDC balance); refunds after a `take()` are paid from others' spUSDC or deferred silently (`:847-848`).
- DQ-6 · Info · chunked fills cost up to `2*(k-1)` shares (`:823-824`).
- DQ-9 · Info · a queued depositor does not share a `realizeGain` (`:293-305`); unchanged.

## Properties held (round 4)

Properties 1-16 of rounds 2 and 3 re-held on bf93b0d (same tests, same exact values, 5000 fuzz runs). New:

17. Guardian cancel: succeeds only with the owner as recipient, settles to the owner, cannot be repointed by the guardian; the owner may name any non-zero recipient and may repoint afterwards. Tests above.
18. The fill recipient is read at each fill (`:830`): after a partial fill the owner can repoint the remainder, the first part stays with the old recipient, each `Deposit` event carries the recipient in force, and the two parts lose at most 2 shares against a single fill. `test_updateDepositRecipient_afterPartialFillRedirectsRemainder` (capacity `99_040_518_410` first, bob gets the first part, carol the rest, entry deleted, head 1).
19. A refund repointed to the vault strands exactly `floor(shares * chi_s / RAY)` USDC in the vault and nothing else moves. `test_updateDepositCancellationRecipient_toVaultStrandsRefund`.

## Unsettled

- DQ-8 cost model unchanged (30M gas, cold slots, `minDeposit == 0`); the number above assumes Cancun gas costs.
- Fuzz 2 never calls `take()` or drains spUSDC, so the `maxRedeem` partial-settlement path is covered by unit tests only.
- `address(savings)` as the refund or fill recipient (USDC or spPRIME sent to spUSDC itself) is not tested.
- spPRIME VSR > RAY while queued still untested on the deposit side.

---

# Round 3 (ff828d2)

Worker: QUEUES. File: `test/DepositQueue.t.sol` (`DepositQueueTest is LocalTestBase`), branch `campaign-v3/queues`, source `src/SparkPrimeVault.sol` at upstream `refactor/more-simplifying` `ff828d2`.
Result: 58 tests, 58 pass (55 unit, 3 fuzz at 5000 runs). `test/QueueAudit.t.sol` (8 upstream tests) passes. The four `test_BUG_*` tests still pass by asserting the buggy behaviour. Harness indexes and reference conversions are unchanged from round 2.

Line remap (round-2 numbers in the sections below -> ff828d2): `_requestDeposit` 373-398 -> 706-736 (head walk 728-730, instant decision 733-735); `cancelDepositRequest` 428-463 unchanged (push :450, head walk :455-460); `updateDepositRecipient` -> 416-425; `updateCancelledDepositRecipient` -> 465-477; `_processDepositQueue` 696-737 -> 738-779 (capacity conversion :742-745, loop :752, `continue` :757, fill math :762-763, mint :769, partial `break` :773, `delete` :775); `_processCancelledDepositQueue` 739-773 -> 781-815 (budget :784, `redeem` :805); `realizeLoss` -> 369-385; `realizeGain` (new) 297-309; natspec return note -> 396-398.

## Fixed since round 2

- `updateDepositRecipient` (`src/SparkPrimeVault.sol:416-425`) is now owner-only on a live entry with a non-zero recipient (NEWSURFACE's round-2 finding; the order is recipient check :417, `no-request` :421, `not-authorized` :422). `updateCancelledDepositRecipient` (`:465-477`) got the same guards, which closes the second write path of DQ-7's `recipient` field. Tests: `test_updateDepositRecipient_ownerRedirectsQueuedFill` (unchanged), `test_updateDepositRecipient_revertsNotOwner` (carol, the recipient bob and the guardian all revert `not-authorized`; owner to `address(0)` reverts `invalid-recipient`; entry untouched), `test_updateDepositRecipient_revertsDeadEntryAndOutOfRange` (filled and cancelled entries revert `no-request` for the former owner too; `id + 1` panics 0x32; the cancelled copy is owner-only and the owner's repoint to carol pays carol `99_999_999_999`).
- C-14 (settlement reverts when spUSDC lacks USDC) is gone: the refund budget is `spUSDC.maxRedeem(vault)` (`:784`) = `min(balanceOf(vault), floor(usdcLiquidity * RAY / chi_s))`. `test_cancelDepositRequest_refundsWithSpUsdcYield` rewritten with exact amounts: after a year at 5% spUSDC holds the `1_000_000e6` principal, the cancelled entry carries `954_532_691_143` shares worth `1_049_999_999_998`; the budget is `909_078_753_470` shares, the first pass pays `999_999_999_999` USDC, leaves 1 wei in spUSDC, `45_453_937_673` shares at the cancelled head (`cancelledDepositHead` unchanged, `pendingCancelledDepositSavingsShares == 45_453_937_673`); a second pass is a silent no-op (1 wei converts to 0 shares); after `_returnSpUsdcLiquidity(60_000e6)` the remainder pays `49_999_999_999`, total `1_049_999_999_998`, the same as a single payout.

## Persisting (re-confirmed at ff828d2)

- DQ-7 · High · guardian cancel pays whoever the guardian names: `src/SparkPrimeVault.sol:450` still pushes `recipient_` for a guardian caller (`:441-444`); settlement pays `request_.recipient` (`:805`). `test_BUG_guardianCancelRefundsToArbitraryRecipient` passes unchanged (guardian receives `999_999_999_999`, alice and bob 0). The owner-only `updateCancelledDepositRecipient` does not help the owner here because the guardian-written entry has `owner = alice`, so alice can repoint it back before settlement, but only if she notices before the planner runs.
- DQ-8 · Low · unbounded head walk in cancel (`:455-460`, planner loop skipped at `:752` when `remaining_ == 0`); ghosts still creatable (`:711`, `minDeposit == 0`). `test_cancelDepositRequest_headWalkGasGrowsWithGhosts`, `test_requestDeposit_zeroAssetsCreatesGhostEntry`.
- DQ-1 · Low · exact-fit capacity leaves a 1-share dust head (`:742-745` double floor, `:728` walk stops on it, `:773` keeps it). `test_BUG_exactFitCapacityLeavesDustThatBlocksInstantFills`, `test_BUG_twoWeiDepositAtFullCapacityJamsInstantPath`.
- DQ-2 · Low (F-4) · `_fillOf(1) = (1, 0)`: 2-wei instant deposit at capacity 2 mints 0 and is deleted (`:759-775`). `test_BUG_dustFillMintsZeroShares`, `test_requestDeposit_instantFillCapacityBoundary`.
- DQ-3 · Info · cancelled entries behind a live head consume `maxRequests_` (`:750`, `:757`). `test_processDepositQueue_cancelledEntriesConsumeMaxRequests`.
- DQ-4 · Low · `recipient_ == address(vault)` shares are stuck (`:710` only rejects zero, `:769`). `test_requestDeposit_recipientIsVaultSharesAreStuck`.
- DQ-5 · Medium (F-2) · fills mint against backing that left (`:738-779` never reads the spUSDC balance); refunds after a `take()` are paid from others' spUSDC or deferred. The silent partial settlement now has two causes: the vault's spUSDC balance and spUSDC's USDC liquidity, both folded into `maxRedeem` (`:784`); neither emits anything for the unpaid part. `test_processDepositQueue_fillsAfterTakeRemovedBacking`, `test_processDepositQueue_partialTakeStillFillsFully`, `test_cancelDepositRequest_earlyCancelAfterTakeStrandsLaterDepositor`, `test_processCancelledDepositQueue_partialRefundWhenBackingShort`, `test_cancelDepositRequest_refundsWithSpUsdcYield`.
- DQ-6 · Info · chunked fills cost up to `2*(k-1)` shares (`:762-763`). Fuzz bound holds at 5000 runs.
- Note: `requestDeposit` natspec (`:396-398`) still says `type(uint256).max` when nothing was queued; the code returns the index.

## New gain/loss observations

- DQ-9 · Info · A queued depositor does not share in a `realizeGain` (`src/SparkPrimeVault.sol:297-309`, DEFAULT_ADMIN, callable while unpaused). `totalAssets()` (`:675-677`) counts minted shares only, so `chi = (totalAssets + gain) * RAY / totalSupply` spreads the gain over holders; the queued spUSDC is filled later at the higher chi (`:763`). `test_processDepositQueue_queuedDepositorDoesNotShareRealizedGain`: alice and carol filled instantly (`99_040_518_410` each, carol one block before the gain), bob queued `95_453_269_114` spUSDC; `realizeGain(10_000e6)` sets chi `1.060172156650366224592543507e27`, alice and carol `104_999_999_998` each (+`5_000_000_000`), bob's entry untouched; bob's fill mints `94_324_303_248` (`4_716_215_162` fewer than alice) worth `99_999_999_998`. `totalAssets` ends `309_999_999_995` against `299_999_999_998` USDC of spUSDC: the gain is a claim on backing that has not arrived (same notional-index gap as RQ-5). The instant-before-gain sandwich is ADVERSARIAL's.
- `realizeLoss` (`:369-385`) now requires `paused`, `0 < loss < totalAssets` and non-zero supply, so the `loss == totalAssets` brick and the zero-supply division from the round-2 unsettled list are closed. No deposit-queue test uses it; queued spUSDC is outside `totalAssets`, so a loss while queued does not touch the entry either (mirror of DQ-9, not separately tested).
- `realizeGain` has no upper bound and no pause requirement; a gain realised with a live deposit queue immediately raises the share price every queued fill pays. Factual only; the ordering risk is ADVERSARIAL's.

## Properties held (round 3)

Properties 1-13 of the round-2 section below re-held unchanged on ff828d2 (same tests, same exact values, 5000 fuzz runs). New:

14. `updateDepositRecipient` and `updateCancelledDepositRecipient` are owner-only, reject dead entries and `address(0)`, and the owner's repoint drives both the `Deposit` event and the refund payee. `test_updateDepositRecipient_ownerRedirectsQueuedFill`, `test_updateDepositRecipient_revertsNotOwner`, `test_updateDepositRecipient_revertsDeadEntryAndOutOfRange`.
15. Cancelled-queue settlement under spUSDC liquidity pays exactly `floor(maxRedeem * chi_s / RAY)`, keeps the head on the partial entry, is a no-op at 1 wei of liquidity, and the two-step total equals the one-step total. `test_cancelDepositRequest_refundsWithSpUsdcYield`.
16. A realised gain changes neither a queued entry's spUSDC shares nor the spUSDC held; it changes only the spPRIME minted at fill, and the filled depositor's `assetsOf` equals the fill's asset value. `test_processDepositQueue_queuedDepositorDoesNotShareRealizedGain`.

## Unsettled

- DQ-7 is still open at ff828d2; the `test_BUG_` test will start failing once `:450` uses `request_.owner` for non-owner callers.
- DQ-8 cost model (30M gas, cold slots, `minDeposit == 0`) unchanged.
- Fuzz 2 never calls `take()` or drains spUSDC, so the `maxRedeem` partial-settlement path is covered by unit tests only.
- `realizeGain` while a cancelled entry is unsettled: the cancelled entry is in spUSDC shares and is unaffected; not separately tested.
- spPRIME VSR > RAY while queued still untested on the deposit side.

---

# Deposit-queue campaign report (round 2)

Worker: DEPOSIT-QUEUE. File: `test/DepositQueue.t.sol` (`DepositQueueTest is LocalTestBase`), branch `campaign-v2/deposit-queue`, source `src/SparkPrimeVault.sol` on `refactor/more-simplifying`.
Result: 55 tests, 55 pass (52 unit, 3 fuzz at 5000 runs). `test/QueueAudit.t.sol` (5 upstream tests) still passes. The four `test_BUG_*` tests pass by asserting the buggy behaviour.

Harness indexes (frozen at RAY): spUSDC `chi_s = 1.047633055711877768967605062e27`, spPRIME `chi_p = 1.009687768242461209408770821e27`.
Reference: `1_000_000e6` USDC -> `954_532_691_143` spUSDC shares -> instant fill mints `990_405_184_109` spPRIME (assets `999_999_999_999`). `100_000e6` -> `95_453_269_114` -> `99_040_518_410`.

## What changed since round 1 and how the suite was ported

- Instant-fill decision is now `depositHead == requestId_` after walking the head over zero-share entries (`src/SparkPrimeVault.sol:391-398`), no longer `pendingDepositSavingsShares == 0`. Properties 1 and 2 were re-derived: a live (non-zero) head still blocks instant fills; a cancelled, filled or ghost head no longer does. The 1-share dust entry of DQ-1 is non-zero, so it still jams the instant path (confirmed, `test_BUG_exactFitCapacityLeavesDustThatBlocksInstantFills`).
- `cancelDepositRequest` moves the entry to `cancelledDepositQueue`, returns a cancel id, and walks the head if the entry was the head (`:446-460`). Refunds are paid by `processCancelledDepositQueue` (`:739-773`), bounded by the vault's spUSDC balance (`:742`). Every round-1 cancel test now asserts the intermediate state (both pending counters, cancelled entry, no USDC moved) and then settles.
- Fully filled entries are `delete`d (`:733`); the getter returns zeros (owner included).
- `_pause` pranks admin, `_setMinimums` became `_setMinDeposit`, `DepositRequest` has a 5th arg, `setCapacity` is unbounded (tests keep `type(uint128).max` as unlimited).
- New tests: head walk (ghosts at head, cancelled run behind a live head, cancel-to-length, partially filled head stays), `test_requestDeposit_instantFillAfterHeadEntryCancelled`, head-walk gas, `updateDepositRecipient` by the owner, partial refund settlement, zero cancel recipient, the 2-wei jam, and a fuzz over deposits/ghosts/cancels/settlements/fills/capacity raises.

## (a) Bugs and suspicious behaviour

### DQ-7 · High (regression of F-1) · Guardian cancel pays the refund to any address the guardian names
- Location: `src/SparkPrimeVault.sol:450` (`cancelledDepositQueue.push(Request(request_.owner, recipient_, ...))`) with `:441-444` (guardian authorised) and `:762-763` (settlement pays `request_.recipient`).
- Scenario: Alice queues 1_000_000e6 for recipient Bob. Guardian calls `cancelDepositRequest(id, guardian)`. The cancelled entry is `(owner alice, recipient guardian, 954_532_691_143)`; `processCancelledDepositQueue` pays `999_999_999_999` USDC to the guardian, Alice and Bob get 0.
- Impact: the round-1 F-1 patch ("guardian cancel refunds `request.owner`") is gone. A compromised or malicious guardian drains every queued deposit through cancel + settle. The same field is also writable by anyone through `updateCancelledDepositRecipient` (`:465-472`, NEWSURFACE owns that finding), so the fix must cover both.
- Fix: for non-owner callers push `request_.owner` as the recipient (`msg.sender == request_.owner ? recipient_ : request_.owner`).
- Test: `test_BUG_guardianCancelRefundsToArbitraryRecipient`.

### DQ-8 · Low (new) · Unbounded head walk in cancel lets ghost entries block the head depositor's cancel
- Location: `src/SparkPrimeVault.sol:455-460` (walk to `depositQueue.length`), `:710` (planner loop skipped when `remaining_ == 0`).
- Scenario: capacity is 0 (or exhausted), Alice is the live head. Attacker pushes ghosts behind her (`requestDeposit(0)`, allowed while `minDeposit == 0`; F-5). Alice's (or the guardian's) cancel must walk every ghost in one transaction: measured `2_909` gas per ghost cold, so ~`10_300` ghosts put the cancel above 30M gas. The planner cannot clear the ghosts first: with no capacity `_processDepositQueue` never enters the loop, and with capacity it fills Alice before reaching them. The same walk runs in `_requestDeposit` (`:391-393`) once Alice's slot is zero, but there the planner can chunk through the ghosts with `maxRequests_`.
- Cost: ~`75k` gas per ghost to create (3 storage slots), ~`0.8` ETH at 1 gwei for 10k ghosts.
- Fix: `require(savingsShares_ != 0)` in `_requestDeposit` (also closes F-5 / C-11) or a non-zero `minDeposit` at launch; optionally bound the walk and let the planner finish it.
- Test: `test_cancelDepositRequest_headWalkGasGrowsWithGhosts`.

### DQ-1 · Low (still present) · Exact-fit capacity leaves a 1-share dust entry at the head that disables instant fills for everyone
- Location: `src/SparkPrimeVault.sol:700-703` (capacity -> spUSDC shares, two floors), `:391` (walk stops at a non-zero entry), `:731` (partial fill keeps the entry).
- Scenario unchanged: `maxCapacity = 990_405_184_109`, Alice deposits 1_000_000e6, gets `990_405_184_107`, keeps `1` spUSDC share at the head. Capacity raised to unlimited; Bob's 100_000e6 is fully queued. Only the planner clears it (minting 0, F-4). New in round 2: a guardian or owner cancel of the dust also clears it, but requests already queued behind it stay queued until the planner runs (`test_BUG_twoWeiDepositAtFullCapacityJamsInstantPath`: eve's 4-wei deposit at full capacity jams Bob; after the guardian cancels eve, Carol is still queued behind Bob).
- Fix: `if (shares_ == 0) break;` before mutating state plus closing entries below 2 spUSDC shares, or round the capacity conversion up.
- Tests: `test_BUG_exactFitCapacityLeavesDustThatBlocksInstantFills`, `test_BUG_twoWeiDepositAtFullCapacityJamsInstantPath`, `test_requestDeposit_instantFillCapacityBoundary`.

### DQ-2 · Low (known F-4) · Dust fill boundary is exactly `remaining_ == 1` spUSDC share; on the instant path it is a total loss of the deposit
- Location: `src/SparkPrimeVault.sol:717-733`.
- Unchanged: `_fillOf(1) = (1, 0)`, `_fillOf(2) = (2, 1)`. Queued path: `processDepositQueue(1, 10)` and two calls at `availableCapacity() == 2` deduct 3 spUSDC shares and mint 0 each time; Alice's final fill is `990_405_184_105`. Instant path: Bob's `requestDeposit(2)` at `availableCapacity() == 2` mints 0, the entry is deleted, cancel reverts `no-request`. Loss 100% of 2 wei.
- Tests: `test_BUG_dustFillMintsZeroShares`, `test_requestDeposit_instantFillCapacityBoundary`.

### DQ-3 · Info (narrowed) · Cancelled entries behind a live head consume `maxRequests_`
- Location: `src/SparkPrimeVault.sol:708` (budget by index), `:715` (`continue` keeps the slot).
- Head cancels no longer cost a slot because the cancel walks the head itself. Middle cancels still do: entries [alice, bob cancelled, carol], `processDepositQueue(max, 2)` fills Alice and spends the second slot on Bob's zeroed entry; Carol waits for the next call.
- Test: `test_processDepositQueue_cancelledEntriesConsumeMaxRequests`.

### DQ-4 · Low (known I-6 / C-6) · Shares minted to `recipient_ == address(vault)` are unrecoverable and occupy capacity forever
- Location: `src/SparkPrimeVault.sol:373` (only `address(0)` rejected), `:727`.
- Unchanged. Test: `test_requestDeposit_recipientIsVaultSharesAreStuck`.

### DQ-5 · Medium (known F-2, reshaped) · Fills mint against backing that left; refunds after a `take()` are paid from other depositors' spUSDC or silently deferred
- Location: `src/SparkPrimeVault.sol:696-737` (fill never checks the spUSDC balance), `:742` (`remaining_ = min(max, balanceOf(vault))`), `:762-763`.
- Scenario: Alice (954_532_691_143) and Bob (95_453_269_114) queued, `take()` removes everything. Bob's cancel succeeds; `processCancelledDepositQueue` is a silent no-op (balance 0, no revert), his cancelled entry stays open. `processDepositQueue` mints Alice `990_405_184_109` against 0 spUSDC (`totalAssets() = 999_999_999_998`, `availableLiquidAssets() == 0`). Alice's redeem pays 0 until `_returnToVault`, then `999_999_999_998`; Bob's refund settles only after the return.
- With one depositor's worth taken, Alice's cancel settles from Bob's spUSDC and Bob's own refund is deferred. With half taken, the settlement pays half (`49_999_999_999` USDC) and leaves `47_726_634_557` shares open at the cancelled head; the second half pays once backing returns, 1 wei below a single refund.
- The settlement never reverts on the vault's own balance; it reverts only when spUSDC itself lacks USDC (`SparkVault/insufficient-liquidity`, C-14, `test_cancelDepositRequest_refundsWithSpUsdcYield`). The silent partial/no-op settlement has no event or return value for the unpaid part, so off-chain tooling must diff `pendingCancelledDepositSavingsShares`.
- Tests: `test_processDepositQueue_fillsAfterTakeRemovedBacking`, `test_processDepositQueue_partialTakeStillFillsFully`, `test_cancelDepositRequest_earlyCancelAfterTakeStrandsLaterDepositor`, `test_processCancelledDepositQueue_partialRefundWhenBackingShort`.

### DQ-6 · Info · Chunked partial fills cost the depositor up to `2*(k-1)` spPRIME shares
- Location: `src/SparkPrimeVault.sol:720-721`. Unchanged; fuzzed bound holds at 5000 runs.
- Tests: `test_processDepositQueue_partialThenCompleteFill`, `testFuzz_requestDeposit_queuedDepositorGetsAtLeastAsManySharesAsInstant`.

### Notes (not findings)
- `requestDeposit` natspec (`:401-403`) says it returns `type(uint256).max` when nothing was queued; the code always returns the queue index (`test_requestDeposit_instantFillWhenNobodyQueued` asserts `id == 0`).
- F-3 fix verified upstream (`:731`, `test_processDepositQueue_maxRequestsHonouredExactly`). F-5 ghosts still creatable (`test_requestDeposit_zeroAssetsCreatesGhostEntry`). F-7 `take()` works while paused (`test_pause_blocksRequestCancelProcessButNotTake`).
- `updateDepositRecipient` without auth is NEWSURFACE's; here only the owner path is pinned (`test_updateDepositRecipient_ownerRedirectsQueuedFill`: fill and `Deposit` event go to the new recipient).

## (b) Properties that held

1. First depositor with nobody live ahead is filled instantly up to capacity; a depositor behind a live entry is fully queued even with free capacity. `test_requestDeposit_instantFillWhenNobodyQueued`, `test_requestDeposit_secondDepositorQueuedBehindPendingEvenWithFreeCapacity`.
2. After the queue drains by fill or by cancel, the head sits on the new entry and instant fills resume; a head cancel walks the head to the next live entry or to length. `test_requestDeposit_instantFillResumesAfterQueueDrains`, `test_requestDeposit_instantFillResumesAfterCancelDrainsQueue`, `test_requestDeposit_instantFillAfterHeadEntryCancelled`, `test_cancelDepositRequest_atHeadAdvancesToLengthWhenRestIsZero`.
3. Partial fills decrement `request.shares` by exactly `min(request.shares, remaining_)`, the head stays on the entry, neither a cancel elsewhere nor a new request moves it, later processing completes it; fills never move spUSDC. `test_requestDeposit_partialInstantFillLeavesRemainderAtHead`, `test_processDepositQueue_partialThenCompleteFill`, `test_processDepositQueue_partialFillFromCapacityThenRaise`, `test_cancelDepositRequest_partiallyFilledHeadNotAdvanced`.
4. Capacity below `totalSupply`: `availableCapacity() == 0`, process is a no-op (head unchanged), new deposits fully queue; raising capacity fills. `test_processDepositQueue_capacityBelowTotalSupplyIsNoop`, `test_requestDeposit_capacityBelowTotalSupplyQueuesWholeDeposit`.
5. Cancel at head / middle / tail deletes the entry, moves exactly its shares from `pendingDepositSavingsShares` to `pendingCancelledDepositSavingsShares`, pushes `(owner, recipient, shares)` with sequential cancel ids, moves no USDC; settlement refunds `floor(shares * chi_s / RAY)` in cancel order, deletes the cancelled entry and advances `cancelledDepositHead`; only a head cancel moves `depositHead`. `test_cancelDepositRequest_atHead|inMiddle|atTail`, `test_processDepositQueue_skipsRunOfCancelledEntries`, `test_cancelDepositRequest_afterPartialFillRefundsRemainderOnly`.
6. Cancel reverts `SparkPrimeVault/no-request` on a second cancel and on a filled (deleted) entry; `SparkPrimeVault/not-authorized` for non-owner non-guardian (bob, rebalancer, admin); `SparkPrimeVault/invalid-recipient` for a zero recipient (owner and guardian); index out of bounds panics. `test_cancelDepositRequest_revertsSecondCancel|revertsFilledEntry|revertsNotAuthorized|revertsZeroRecipient|revertsOutOfBounds`.
7. FIFO: 5 depositors of 100_000e6 and capacity `247_601_296_025` fill exactly the first two, Carol partially (`49_520_259_202`, entry keeps `47_726_634_559`), Dave and Eve nothing; a later call sized for Carol's remainder never touches Dave. `test_processDepositQueue_fifoFiveDepositorsCapacityForTwoAndAHalf`.
8. spUSDC yield while queued goes to the depositor: 5% for 365 days makes the fill mint `1_039_925_443_313` spPRIME; the cancelled entry carries the shares so the settled refund is the grown `1_049_999_999_998`. `test_processDepositQueue_queuedDepositorReceivesSpUsdcYield`, `test_cancelDepositRequest_refundsWithSpUsdcYield`.
9. Recipient != owner: shares go to the recipient on instant and queued fills; only the owner (or guardian) can cancel; the owner may choose the refund address; `address(0)` reverts on both deposit overloads; `minDeposit` boundary is exact. `test_requestDeposit_recipientNotOwnerInstant`, `test_requestDeposit_recipientNotOwnerQueuedFillAndCancel`, `test_requestDeposit_revertsZeroRecipient`, `test_requestDeposit_revertsBelowMinimumBoundary`.
10. Pause blocks `requestDeposit` (both overloads), `cancelDepositRequest` (owner and guardian), `processDepositQueue` and `processCancelledDepositQueue` with `SparkPrimeVault/paused`; `take()` is not blocked. `test_pause_blocksRequestCancelProcessButNotTake`.
11. `maxRequests_` and `maxSavingsShares_` are honoured exactly; `maxSavingsShares_ = 0`, `maxRequests_ = 0`, empty and drained queues are no-ops; non-rebalancer reverts `AccessControlUnauthorizedAccount`. `test_processDepositQueue_maxRequestsHonouredExactly`, `test_processDepositQueue_maxSavingsSharesHonouredExactlyAcrossEntries`, `test_processDepositQueue_maxSavingsSharesZeroIsNoop`, `test_processDepositQueue_maxRequestsZeroIsNoop`, `test_processDepositQueue_emptyQueueIsNoop`, `test_processDepositQueue_revertsNotRebalancer`.
12. Head walk: ghosts at the head are skipped by the next request (head lands on the new entry); the walk stops at the first live entry; with no capacity the fill loop is skipped and the head stays on the ghost. `test_requestDeposit_headWalkSkipsGhostsAtHead`, `test_requestDeposit_headWalkStopsAtLiveEntry`.
13. Fuzz (5000 runs each): instant fills never exceed capacity, the filled amount is exactly `min(s, remainingForCapacity)` when every entry from the head is zero and 0 otherwise, and the head lands on `id + 1` iff the entry ends zero and capacity was non-zero (`testFuzz_requestDeposit_instantFillNeverExceedsCapacity`); over random deposits (1 in 7 a ghost), cancels, refund settlements, fills and capacity raises, `pendingDepositSavingsShares == sum(open)`, `pendingCancelledDepositSavingsShares == sum(open cancelled)`, every entry before each head is zero, both heads `<= length` and never decrease, a head cancel strictly advances the head and a non-head cancel leaves it, fills never move spUSDC, settlements move exactly the settled spUSDC and pay within `maxRequests_` wei of its value, `totalSupply <= maxCapacity` (`testFuzz_processDepositQueue_pendingEqualsSumOfOpenEntries`); queued fill never exceeds instant and loses at most `2*(k-1)` wei over k chunks (`testFuzz_requestDeposit_queuedDepositorGetsAtLeastAsManySharesAsInstant`).

## (c) Unsettled

- The coordinator's `git merge review/poc-tests-v2` (pause back on GUARDIAN_ROLE, new `realizeLoss` formula) was blocked by the sandbox permission system in this worker; the suite was run on the pre-merge source. Nothing in this file calls `pause()` directly (it uses `_pause()` from the harness) or `realizeLoss`, so the port is expected to pass unchanged after the merge; it still needs a re-run.
- Whether DQ-7 is duplicated by the cancel-fees worker: it sits on the deposit-cancel path so it is reported here regardless.
- DQ-8 cost model assumes a 30M gas block and cold slots; the exact ghost count on mainnet depends on the base fee and on whether `minDeposit` is set at launch.
- Fuzz 2 never lowers capacity below `totalSupply` and never calls `take()`, so settlement always has backing there; the take paths are covered by unit tests only.
- spPRIME VSR > RAY while queued was not tested; only spUSDC yield was.
