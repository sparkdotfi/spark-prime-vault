# spPRIME (`src/SparkPrimeVault.sol`) review and testing campaign: final report

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
