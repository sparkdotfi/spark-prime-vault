# Deposit-queue campaign report

Worker: DEPOSIT-QUEUE. File: `test/DepositQueue.t.sol` (`DepositQueueTest is LocalTestBase`), branch `campaign/deposit-queue`.
Result: 45 tests, 45 pass (42 unit, 3 fuzz at 5000 runs). No deliberately failing test. The two `test_BUG_*` tests pass by asserting the buggy behaviour.

Harness indexes (frozen at RAY): spUSDC `chi_s = 1.047633055711877768967605062e27`, spPRIME `chi_p = 1.009687768242461209408770821e27`.
Reference: `1_000_000e6` USDC -> `954_532_691_143` spUSDC shares -> instant fill mints `990_405_184_109` spPRIME (assets `999_999_999_999`). `100_000e6` -> `95_453_269_114` -> `99_040_518_410`.

## (a) Bugs and suspicious behaviour

### DQ-1 · Low (new) · Exact-fit capacity leaves a 1-share dust entry at the head that disables instant fills for everyone
- Location: `src/SparkPrimeVault.sol:633-636` (capacity -> spUSDC shares, two floors) together with `:357` (`depositInstantly_ = pendingDepositSavingsShares == 0`).
- Scenario: `maxCapacity = 990_405_184_109` (exactly the spPRIME value of a 1_000_000e6 deposit). Alice deposits 1_000_000e6. `remaining_ = floor(floor(cap * chi_p / RAY) * RAY / chi_s) = 954_532_691_142`, one short of her `954_532_691_143` spUSDC shares. She gets `990_405_184_107` spPRIME (2 short), her entry keeps `1` spUSDC share, `pendingDepositSavingsShares = 1`, `availableCapacity() = 2`. Admin raises capacity to `type(uint128).max`; Bob deposits 100_000e6 and is fully queued (`balanceOf(bob) = 0`, entry `95_453_269_114`) behind 1 wei of dust. Only a rebalancer `processDepositQueue` clears it, and that fill mints 0 (F-4, `Deposit(alice, alice, 1, 0)`).
- Impact: any depositor sized to the remaining capacity (a natural thing for a whale to do) silently switches the vault from instant to queued mode for all later depositors until the planner runs. Capacity set in spPRIME shares must exceed the intended fill by 2 shares to be usable (`_remainingForCapacity(SH + 2) == S`, `_remainingForCapacity(SH + 1) == S - 1`, `_remainingForCapacity(SH) == S - 1`).
- Fix: round the capacity conversion up (`_divup`) or drop a remainder that cannot mint a share (`if (shares_ == 0) break;` before mutating state, which also fixes F-4 and would leave the dust entry open, so additionally treat entries below 2 spUSDC shares as filled).
- Tests: `test_BUG_exactFitCapacityLeavesDustThatBlocksInstantFills`, `test_requestDeposit_instantFillCapacityBoundary`.

### DQ-2 · Low (sharpens known F-4) · Dust fill boundary is exactly `remaining_ == 1` spUSDC share; on the instant path it is a total loss of the deposit
- Location: `src/SparkPrimeVault.sol:650-662`.
- Boundary at the harness indexes: `_fillOf(1) = (assets 1, shares 0)`, `_fillOf(2) = (2, 1)`. So `remaining_ == 1` is the only value that mints 0. Reachable by `maxSavingsShares_ == 1` or by `availableCapacity() == 2` (-> `remaining_ == 1`; `availableCapacity() == 1` gives `remaining_ == 0`, a no-op).
- Queued path: with Alice queued (`954_532_691_143`), `processDepositQueue(1, 10)` then two calls at capacity 2 deduct 3 spUSDC shares and mint 0 each time (`Deposit(alice, alice, 1, 0)`); her final fill is `990_405_184_105`, 4 spPRIME shares below instant. The 3 spUSDC shares stay in the vault as equity. Repeatable on every call by the rebalancer while capacity sits at supply + 2.
- Instant path: with `availableCapacity() == 2`, Bob's `requestDeposit(2, bob)` (1 spUSDC share) mints 0, his entry is zeroed and `cancelDepositRequest` reverts `SparkPrimeVault/no-request`. Loss: 2 USDC wei, 100% of the deposit.
- Tests: `test_BUG_dustFillMintsZeroShares`, `test_requestDeposit_instantFillCapacityBoundary`.

### DQ-3 · Info · Cancelled entries consume the `maxRequests_` budget
- Location: `src/SparkPrimeVault.sol:641` (`end_` budgets by index, `:648` `continue` does not refund the slot).
- Scenario: entries [alice cancelled, bob 95_453_269_114, carol 95_453_269_114], ample capacity, `processDepositQueue(max, 1)`: nothing minted, `depositHead` 0 -> 1. A second call with `maxRequests_ = 1` fills bob. Combined with F-5 (free zero-share entries), an attacker can make each `maxRequests_` slot do nothing.
- Test: `test_processDepositQueue_cancelledEntriesConsumeMaxRequests`.

### DQ-4 · Low (known I-6, quantified) · Shares minted to `recipient_ == address(vault)` are unrecoverable and occupy capacity forever
- Location: `src/SparkPrimeVault.sol:352` (only `address(0)` is rejected), `:660`.
- Scenario: `requestDeposit(1_000_000e6, address(vault))` mints `990_405_184_109` to the vault; `pendingRedeemShares == 0`, `processRedeemQueue` does nothing, no function moves `balanceOf[vault]` outside redeem entries. With capacity `990_405_184_109`, `availableCapacity() == 0` and Bob's deposit is fully queued.
- Fix: `require(recipient_ != address(this))` like spUSDC's `SparkVault/invalid-address`.
- Test: `test_requestDeposit_recipientIsVaultSharesAreStuck`.

### DQ-5 · Medium (known F-2, consequence proven) · `processDepositQueue` mints against backing that already left; cancel reverts inside spUSDC
- Location: `src/SparkPrimeVault.sol:294-303`, `:629-668`.
- Scenario: Alice (954_532_691_143) and Bob (95_453_269_114) queued, `take()` removes all `1_049_985_960_257` spUSDC. Bob's cancel reverts `SparkVault/insufficient-balance`. `processDepositQueue(max, 10)` does not revert and mints `990_405_184_109` + `99_040_518_410`; `totalAssets() = 1_099_999_999_997` with `availableLiquidAssets() == 0`. Alice's redeem of all shares pays 0 until `_returnToVault`, then pays `999_999_999_998`.
- Also: with 2 depositors queued and one depositor's worth taken, the earlier cancel is paid from the later depositor's spUSDC and the later cancel reverts (last one out is stuck).
- Tests: `test_processDepositQueue_fillsAfterTakeRemovedBacking`, `test_processDepositQueue_partialTakeStillFillsFully`, `test_cancelDepositRequest_earlyCancelAfterTakeStrandsLaterDepositor`.

### DQ-6 · Info · Chunked partial fills cost the depositor up to `2*(k-1)` spPRIME shares
- Location: `src/SparkPrimeVault.sol:653-654` (two floors per fill).
- Example: 954_532_691_143 filled as 400e9 + rest gives `415_032_483_768 + 575_372_700_340 = 990_405_184_108`, 1 below instant. Fuzzed bound `instant - queued <= 2*(k-1)` holds at 5000 runs; `k == 1` is exact.
- Tests: `test_processDepositQueue_partialThenCompleteFill`, `testFuzz_requestDeposit_queuedDepositorGetsAtLeastAsManySharesAsInstant`.

### Known findings touched (not re-reported)
- F-1 patch verified: guardian cancel refunds `request.owner`; owner may choose the refund address (`test_cancelDepositRequest_guardianCancelAlwaysRefundsOwner`, `test_requestDeposit_recipientNotOwnerQueuedFillAndCancel`).
- F-3 patch verified: `maxRequests_` fills exactly N entries (`test_processDepositQueue_maxRequestsHonouredExactly`).
- F-5: `requestDeposit(0)` behind a queue creates a ghost entry whose cancel reverts `no-request` (`test_requestDeposit_zeroAssetsCreatesGhostEntry`).
- F-7: `take()` works while paused and can remove a queued depositor's backing (`test_pause_blocksRequestCancelProcessButNotTake`).

## (b) Properties that held

1. Instant fill only when `pendingDepositSavingsShares == 0`; a later depositor is queued behind an open entry even with free capacity. `test_requestDeposit_instantFillWhenNobodyQueued`, `test_requestDeposit_secondDepositorQueuedBehindPendingEvenWithFreeCapacity`.
2. After the queue drains (by fill or by cancel) `depositHead` is reset to the new entry and instant fills resume. `test_requestDeposit_instantFillResumesAfterQueueDrains`, `test_requestDeposit_instantFillResumesAfterCancelDrainsQueue`.
3. Partial fills decrement `request.shares` by exactly `min(request.shares, remaining_)`, head stays on the entry, later processing completes it; fills never move spUSDC. `test_requestDeposit_partialInstantFillLeavesRemainderAtHead`, `test_processDepositQueue_partialThenCompleteFill`, `test_processDepositQueue_partialFillFromCapacityThenRaise`.
4. Capacity below `totalSupply`: `availableCapacity() == 0`, process is a no-op (no revert, head unchanged), new deposits fully queue; raising capacity fills. `test_processDepositQueue_capacityBelowTotalSupplyIsNoop`, `test_requestDeposit_capacityBelowTotalSupplyQueuesWholeDeposit`.
5. Cancel at head / middle / tail refunds `floor(shares * chi_s / RAY)` USDC, zeroes the entry, leaves `depositHead` untouched; processing skips zeroed entries and the head walks past them. `test_cancelDepositRequest_atHead|inMiddle|atTail`, `test_processDepositQueue_skipsRunOfCancelledEntries`, `test_cancelDepositRequest_afterPartialFillRefundsRemainderOnly`.
6. Cancel reverts `SparkPrimeVault/no-request` on a second cancel and on a filled entry; `SparkPrimeVault/not-authorized` for non-owner non-guardian (bob, rebalancer, admin); index out of bounds panics. `test_cancelDepositRequest_revertsSecondCancel|revertsFilledEntry|revertsNotAuthorized|revertsOutOfBounds`.
7. FIFO: 5 depositors of 100_000e6 and capacity `247_601_296_025` (2.5x) fills exactly the first two (`99_040_518_410` each), Carol partially (`49_520_259_202`, entry keeps `47_726_634_559`), Dave and Eve nothing; a later call sized for Carol's remainder never touches Dave. `test_processDepositQueue_fifoFiveDepositorsCapacityForTwoAndAHalf`.
8. spUSDC yield while queued goes to the depositor: 5% for 365 days turns `954_532_691_143` spUSDC into `1_049_999_999_998` USDC and the fill mints `1_039_925_443_313` spPRIME (`49_520_259_204` more than instant); the vault's spUSDC balance is unchanged by the fill; cancel refunds the grown `1_049_999_999_998`. `test_processDepositQueue_queuedDepositorReceivesSpUsdcYield`, `test_cancelDepositRequest_refundsWithSpUsdcYield`.
9. Recipient != owner: shares go to the recipient on instant and queued fills; only the owner (or guardian) can cancel; `address(0)` reverts `SparkPrimeVault/invalid-recipient` on both overloads; `minDeposit` boundary is exact (`HUNDRED_K - 1` reverts `below-minimum`). `test_requestDeposit_recipientNotOwnerInstant`, `test_requestDeposit_recipientNotOwnerQueuedFillAndCancel`, `test_requestDeposit_revertsZeroRecipient`, `test_requestDeposit_revertsBelowMinimumBoundary`.
10. Pause blocks `requestDeposit` (both overloads), `cancelDepositRequest` (owner and guardian) and `processDepositQueue` with `SparkPrimeVault/paused`; `take()` is not blocked. `test_pause_blocksRequestCancelProcessButNotTake`.
11. `maxRequests_` and `maxSavingsShares_` are honoured exactly (`S_1M + 10` fills Alice and 10 wei of Bob -> 9 spPRIME); `maxSavingsShares_ = 0`, `maxRequests_ = 0`, empty queue and drained queue are no-ops; non-rebalancer reverts with `AccessControlUnauthorizedAccount`. `test_processDepositQueue_maxRequestsHonouredExactly`, `test_processDepositQueue_maxSavingsSharesHonouredExactlyAcrossEntries`, `test_processDepositQueue_maxSavingsSharesZeroIsNoop`, `test_processDepositQueue_maxRequestsZeroIsNoop`, `test_processDepositQueue_emptyQueueIsNoop`, `test_processDepositQueue_revertsNotRebalancer`.
12. Fuzz (5000 runs each): instant fills never exceed capacity and the filled amount is exactly `min(s, remainingForCapacity)` for the first depositor and 0 for anyone behind (`testFuzz_requestDeposit_instantFillNeverExceedsCapacity`); over random deposit / cancel / process / capacity-raise sequences `pendingDepositSavingsShares == sum(open entries)`, every entry before `depositHead` is zero, `depositHead <= length`, `depositHead` never decreases on process, `totalSupply <= maxCapacity` (`testFuzz_processDepositQueue_pendingEqualsSumOfOpenEntries`); queued fill never exceeds instant and loses at most `2*(k-1)` wei over k chunks (`testFuzz_requestDeposit_queuedDepositorGetsAtLeastAsManySharesAsInstant`).

## (c) Unsettled

- Whether DQ-1 should be fixed by rounding the capacity conversion up (slightly over-filling capacity by at most 1 spPRIME share) or by treating sub-2-share remainders as filled: product decision.
- Fuzz 2 never lowers capacity below `totalSupply` mid-sequence, so `totalSupply <= maxCapacity` is only shown for monotone capacity; the below-supply case is covered by the unit tests only.
- spPRIME VSR > RAY while queued (fewer shares, same value) was not tested; only spUSDC yield was.
