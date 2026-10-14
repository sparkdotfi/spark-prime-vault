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
