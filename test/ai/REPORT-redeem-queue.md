## Round 6 (`master` @ `c512609`)

Worker: REDEEM-QUEUE. File: `test/ai/RedeemQueue.t.sol` (nine contracts over an abstract `RedeemQueueTestBase is LocalTestBase`: `RequestRedeem{Failure,Success}Tests`, `ProcessPendingRedeems{Failure,,Fallback,AdjustTotalAssets}Tests`, `UpdateRedeemRecipient{Failure,Success}Tests`, `RedeemQueueGetterTests`, `RedeemQueueFuzzTests`), branch `campaign-v6/redeem-queue`, source `src/SparkPrimeVault.sol` at `c512609`.
Result: 84 tests, 84 pass (75 unit, 9 fuzz; fuzz re-run at `FOUNDRY_FUZZ_RUNS=20000`, see (d)). Five `test_BUG_*` tests pass by asserting the exact open state; 18 `test_fixed_*` tests pin C-1, R4-A/R4-B and the claimable path as fixed. Run with `--skip test/ai/TestBase.t.sol --skip test/ai/LocalSmoke.t.sol`: the tracked fork harness `test/ai/TestBase.t.sol` (not mine) does not compile on this worktree (duplicate `operator`/`OPERATOR_ROLE`, 4-arg `initialize`). Harness indexes and reference conversions unchanged (chi_s `1.047633055711877768967605062e27`, chi_p `1.009687768242461209408770821e27`, 100_000e6 = `95_453_269_114` spUSDC / `99_040_518_410` spPRIME, one 100k fill pays `99_999_999_998` and burns `95_453_269_113`).

Line map on c512609: `requestRedeem` :448-476 (`whenNotPaused` :451, `ZeroRecipient` :454, `VaultIsRecipient` :455, `BelowMinRedeem` :456, `drip` :458, escrow :460, fee :463-465, push :471, event :475); `updateRedeemRecipient` :514-525 (`InvalidRequestId` :517, `NoRequest` :521, `NotRequestOwner` :522); `claim` :531-543; `_processPendingRedeems` :942-976 (loop :950, per-entry bound :953, `break` :955, `_burn` :964, `_withdrawSavings` :966, `Redeem` :968, partial `break` :970, `delete` :972); `_withdrawSavings` :997-1014 (try :1001, fallback :1011, credit :1013); `_incrementClaimableAssets` :1100-1105; `adjustTotalAssets` :262-283; `take` :289-298; getters :764-809.

Port notes (behaviour removed on c512609, tests rewritten or deleted): `requestRedeem(0)` ghosts are impossible (`ZeroMinRedeem` at init/setter, `BelowMinRedeem` at :456), so `test_BUG_requestRedeem_zeroSharesCreatesGhostEntry` and the `_ghost` helper are gone; the only dead entry left is the R5-14 1-share-at-any-fee entry (`_zeroShareEntry`), and every ghost test became a zero-share-entry test. `test_fixed_requestRedeem_rejectsBlacklistedRecipient` deleted (the check is gone; replaced by `test_requestRedeem_blacklistedRecipientAccepted` and `test_fixed_blacklistedAtRequest_acceptedAndCreditedAtFill`). `test_BUG_processPendingRedeems_recipientIsVault_usdcStranded_V2_13` became the `VaultIsRecipient` failure tests. The two C-1 `test_BUG_` tests and `testFuzz_..._batchOverburnBoundedByFillsMinusOne` became `test_fixed_C1_*` / `testFuzz_fixed_C1_*`. The round-4 `cancelRedeemRequest` selector probe and `test_cancelRedeemRequest_selectorRemovedAndEventDead` deleted (two releases gone; finality is pinned by `test_requestRedeem_isFinal_noPathRecoversEscrow`). Events are emitted through `ISparkPrimeVault.X` with `vm.expectEmit(address(vault))` as on master's `test/`. Reads below the head use `vm.load` on slot 2 (`_rawRedeem`).

### (a) New findings on c512609

- **R6-1 · Info · per-entry bound double-floors and strands 1 share on an exactly-backed queue.** `:953` floors twice (`maxWithdraw` floors `S * chi_s / RAY`, `convertToShares` floors again), so after each fill the next entry's budget can be 1 share short of what the backing pays for. `test_fixed_C1_elevenElevenRest_settleInOneCall`: three entries (11, 11, 99_040_518_388 shares) on a fully liquid 100k vault; the three ceil burns add up to EXACTLY `95_453_269_114` (one aggregate withdraw, or the round-5 single budget, settles all three), but after the two 11-fills the bound is `99_040_518_387`, carol is paid `99_999_999_975` instead of `99_999_999_976`, and 1 share sticks at the head behind 1 wei of spUSDC that `maxWithdraw` floors to 1 USDC wei = 0 shares (R5-10). Cost: <= 1 USDC wei per entry; consequence: R5-10 dust is now reachable without any `take`/drain, and the whole queue behind it waits for new backing. Fix sketch in (e).
- **R6-2 · Info · a batch halts at the first partial fill; a repeat call scrapes floor dust.** After a partial head fill the loop `break`s (:970) even though the floors can leave `A' >= chi_p / RAY` behind; `(max, 1)` again then pays a few more wei (fuzz counterexample: bob `5_010_493_101 -> 5_010_493_105`, 1 more share). Not a bug (the next call gets it) but "one `(max, n)` call == n `(max, 1)` calls" only holds up to the first non-advancing call; `testFuzz_fixed_C1_batchedEqualsOnePerCall` is stated that way and passes at 20000 runs.
- **R6-3 · Info · zero-share entries are filled, not skipped.** The `continue` is gone: a 0-share entry costs a `maxRequests_` slot AND a `spUSDC.withdraw(0)` call, emits `Redeem(id, owner, recipient, 0, 0, 0)` and, with a blacklisted recipient, goes through the fallback and emits `ClaimableAssetsIncreased(recipient, 0)` (`test_processPendingRedeems_zeroShareEntry_blacklistedRecipient_creditsZero`). It is NOT walked when `maxShares_ == 0` (loop condition) or when liquidity is 0 (`break` at :955 fires first): a zero entry then sits at the head, harmless since nothing could be paid anyway (`test_processPendingRedeems_zeroShareEntry_filledForZeroAndDeleted`). Only reachable with `minRedeem == 1` (R5-14).
- **R6-4 · Info · gas.** The per-entry `maxWithdraw` re-read costs ~6k per fill: 200 fills in 4 batches of 50 now average `65_926` gas per fill (round 5: < 60k). `test_processPendingRedeems_200UsersIn4BatchesOf50` bounds it at 70k.

### (b) Status of prior findings

- **C-1 / R5-4 (batched fills over-burn and revert): FIXED.** `test_fixed_C1_twoEntriesVaultSharesBound_settleInOneCall` (S = `1_002_833`, two 520_260-share entries: `(max, 2)` emits `Redeem(0, alice, alice, 520_260, 501_417, 525_300)` and `Redeem(1, alice, bob, 520_258, 501_415, 525_298)`, 2 shares and 1 spUSDC wei of dust, paid 1 + 1 share after 1 and 2 more spUSDC wei). `test_fixed_C1_threeEntriesLiquidityBound_settleInOneCall` (L = `999_999_999_998`: alice `23_170_194_465`, bob `302_489_014_899`, carol `674_340_790_631` = full fill - 2, 2 shares queued, 1 spUSDC wei, 3 USDC wei in spUSDC). `test_fixed_C1_elevenElevenRest_settleInOneCall` (R6-1 above). `test_fixed_C1_batchEqualsOnePerCall` (snapshot: `(max, 3)` == three `(max, 1)`). `testFuzz_fixed_C1_batchNeverReverts` (random indexes, 1-20 entries, random `take`: never reverts, every recipient paid exactly `floor(filled * chi_p / RAY)`, burn within `fills` wei of the aggregate ceil, and if anything is left the head remainder exceeds the liquid shares). `testFuzz_fixed_C1_batchedEqualsOnePerCall` (R6-2 statement, blacklisted recipients included, 20000 runs). The single-fill bound is now the per-iteration bound: `assets <= A` and `ceil(assets * RAY / chi_s) <= S` (`testFuzz_processPendingRedeems_singleFillNeverReverts`, `..._singleFillRoundingBounds`).
- **V2-13 / R5-7 (vault / spUSDC as recipient): vault FIXED, spUSDC OPEN (Low).** `test_requestRedeem_vaultIsRecipient`, `test_updateRedeemRecipient_vaultIsRecipient` (`VaultIsRecipient`, :455 / :516). `test_BUG_processPendingRedeems_recipientIsSpUsdc_donatesToSpUsdc_V2_13` and `test_BUG_updateRedeemRecipient_spUsdcAccepted_V2_13`: `Redeem(0, alice, spUSDC, 99_040_518_410, 95_453_269_113, 99_999_999_998)`, spUSDC's USDC unchanged, its `totalSupply` 1, no credit: value donated to spUSDC holders.
- **R4-A / R4-B (blacklist jam, fallback): FIXED by `try/catch`.** `test_fixed_R4A_blacklistedAfterRequest_queueKeepsMoving_claimableExact` (exact event order: USDC `Transfer(spUSDC, vault, 99_999_999_998)`, `ClaimableAssetsIncreased(alice, 99_999_999_998)`, `Redeem(0, ...)`, then bob paid directly; `totalClaimable == usdc.balanceOf(vault) == 99_999_999_998`; `claim` reverts in USDC while blacklisted, pays the exact credit once clean, `totalClaimable` back to 0, `NothingToClaim` after). Blacklisted AT request time is now accepted and credited at fill (`test_requestRedeem_blacklistedRecipientAccepted`, `test_fixed_blacklistedAtRequest_acceptedAndCreditedAtFill`, `test_updateRedeemRecipient_blacklistedRecipientAccepted_creditedAtFill`). Mid-batch no rollback, accumulation across partial fills and entries (`50_484_388_412 + 49_515_611_586 + 99_999_999_998` for alice, `99_999_999_998` for carol, `totalClaimable` exact at every step), un-blacklisted before fill paid directly, no self-rescue needed, credits inert under `adjustTotalAssets`/`take`/deposits/pause. A reverting-contract recipient is paid directly (ERC20 transfers never call the receiver: `test_processPendingRedeems_revertingContractRecipient_paidDirectly`). Non-recipient reverts propagate through both branches: `test_processPendingRedeems_nonRecipientRevert_propagatesThroughBothBranches` (every `withdraw` mocked to revert `SparkVault/insufficient-liquidity`: the call reverts with that reason, no burn, no credit, head unchanged) and the natural variant `test_processPendingRedeems_vaultBlacklisted_directPayoutWorks_fallbackJams` (vault blacklisted: direct payouts work, a blacklisted recipient at the head reverts `Blacklistable` in both branches until the owner repoints). Fuzz: `testFuzz_processPendingRedeems_blacklistFallback_sameMathAsDirectPayout` (credit == `floor(fill * chi_p / RAY)`, burn == `ceil(credit * RAY / chi_s)`, `totalClaimable` exact) and `testFuzz_blacklistFallback_vaultUsdcEqualsTotalClaimable` (random ops with blacklist toggles, requests aimed at blacklisted recipients, claims, drains, takes: `usdc.balanceOf(vault) == totalClaimable == sum(claimableAssets)` after every step, processing never reverts).
- **R5-10 (unpayable dust at the head): OPEN, Info, re-checked with the per-entry bound.** `test_BUG_processPendingRedeems_unpayableDustAtHeadFreezesQueue_R5_10`: `take` leaves S = `95_453_269_113` (1 wei short); alice is paid `99_999_999_997`, her last share (worth 1 USDC wei, `convertToAssets(1) == 1`) is unpayable because `maxWithdraw` floors the 1 spUSDC wei to 1 USDC wei and `convertToShares(1) == 0`; bob behind is frozen; time does not help; 1 more spUSDC wei (`A = 2`) pays it and unfreezes the queue. Bound: the stuck remainder is at most the shares worth `< 2 * chi_p / RAY` USDC wei; it self-heals on any new backing. R6-1 shows it is reachable on an exactly backed vault with no `take`; `test_processPendingRedeems_manyPartialFills_sumNeverExceedsOneFill` shows the chunking route (13 chunks of `7_777_777_777`: `99_999_999_990` paid, 2 shares stuck, `99_999_999_992` after 2 spUSDC wei).
- **R5-5 / F-2 (`take` spends queued backing, not pause-gated): OPEN.** `test_BUG_processPendingRedeems_pausedBlocksRedeemsNotTake_R5_5` (alice frozen by the pause while `takeAll` removes `95_453_269_114`; after unpause her `99_999_999_998` claim is intact and unpayable). `test_requestRedeem_isFinal_noPathRecoversEscrow` (nothing but a fill moves the escrow: `transferFrom` from the vault hits `insufficient-balance` before `insufficient-allowance` on c512609, `permit(owner = vault)` is `invalid-permit`, roles, pause and time release nothing).
- **R5-3 / C-3 (no loss floor): OPEN, High, and now a `LOSS_MANAGER_ROLE` hot wallet instead of the admin (`test_processPendingRedeems_lossWhileQueued_escrowTakesLossProRata` proves the admin lost the power: `AccessControlUnauthorizedAccount(admin, LOSS_MANAGER_ROLE)`).** `test_BUG_adjustTotalAssets_wipesQueuedRedeemer_C3` unchanged: `TotalAssetsAdjusted(5_048_438_841_264_340, -199_999_999_996)`, `Redeem(0, alice, alice, 99_040_518_410, 0, 0)`, backing `199_999_999_999` left unassigned, `takeAll`, a `+199_999_999_996` adjustment hands bob `199_999_999_995`. Re-rated: the role that can do this is operational, not governance.
- **R5-2 (window between payload and pause): OPEN residual.** `test_adjustTotalAssets_queueingBeforePauseCapturesNothing` (a request queued before the pause: `94_999_999_998`, same as bob's claim; no escape, no capture). Gain and loss while queued pro rata: `test_processPendingRedeems_{loss,gain}WhileQueued_*` (`0.959203379825079411152892409e27` / `94_999_999_998` / `90_680_605_657` burned; `1.060172156650366224592543507e27` / `104_999_999_998` / `100_225_932_569` burned, bob's `104_999_999_998` backed by `95_000_000_000`). After a loss `chi_p < RAY` so 1-share chunks pay 0 (`test_processPendingRedeems_oneShareChunksAfterLossPayZero`, 5 shares burned for 0).
- **R5-14 (1-share request at any fee leaves a 0-share entry): OPEN, Info, `minRedeem == 1` only.** `test_requestRedeem_oneShareAtAnyFee_zeroShareEntry_R5_14` (fee rate 1 wei: `RedeemRequest(0, alice, alice, 1, 1)`, entry `(alice, alice, 0)`, `NoRequest` on the updater; `minRedeem = 2` closes it) and `testFuzz_requestRedeem_zeroShareEntryOnlyWhenSharesIsOne` (for `shares >= 2` and any `rate <= MAX_REDEEM_FEE` the queued amount is >= 1). Slot cost and `withdraw(0)` in R6-3.
- **V2-9 (`requestRedeem(0)` ghosts): FIXED** (`ZeroMinRedeem`, `BelowMinRedeem`): `test_requestRedeem_belowMinRedeemBoundary`, `test_requestRedeem_checkOrder`.
- **V2-1 (updaters owner-only): still fixed**, `test_updateRedeemRecipient_notRequestOwner` (stranger, operator, and the new recipient are not owners), fuzz random repoints.
- Pause: `processPendingRedeems` and `requestRedeem` gated (`test_processPendingRedeems_isPaused`, `test_requestRedeem_isPaused`); `updateRedeemRecipient` and `claim` are not (`test_updateRedeemRecipient_whilePaused`, `test_fixed_claimableAssets_unaffected...`).

### (c) Code paths and the test that covers each

- `requestRedeem`: `IsPaused` :451 (`test_requestRedeem_isPaused`), `ZeroRecipient` :454, `VaultIsRecipient` :455, `BelowMinRedeem` :456 boundary in shares (`..._belowMinRedeemBoundary`, `..._minRedeemDriftsInAssetTerms`), `insufficient-balance` boundary :1037, check order (`test_requestRedeem_checkOrder`), `drip` :458 (`test_requestRedeem_dripsFirst`: `Drip(1.060172156654584269839902363e27, 5_000_000_000)`), escrow + `Transfer` + `RedeemRequest(id, owner, recipient, shares, fee)` exact (`..._escrowsSharesAndEmits`), fee burn exact and rounds up (`..._feeOnePercent_exactAmounts`: fee `10_000_000_000`, `totalAssets` `1_089_903_122_316` after the burn, paid `999_590_890_560`, `95_843_777_448` spUSDC left; `..._feeRoundsUp`; `..._fullBalanceWithFee`: fee `990_405_185`), blacklisted/spUSDC recipients accepted, 1-share zero entry, sequential ids, finality, capacity occupied until fill.
- `_processPendingRedeems`: operator-only (`..._notOperator` for all six other actors), paused, empty queue, `maxShares_ == 0`, `maxRequests_` 0/2/1/clamped, `maxShares_` partial head then 1 + 10, `maxShares_` vs liquidity interplay (`..._maxSharesVsLiquidity`: 120e9 binds first, then liquidity `28_837_467_812` -> `28_560_777_617` shares, then `maxShares_` 1_000 again), per-entry bound re-read (FIFO under 150k liquidity: bob `50_000_000_001`, 1 wei more than the old budget), head blocks later smaller requests, spUSDC-liquidity and vault-share partial fills (`299_999_999_999` then `999_999_999_997`; `314_289_916_712` then `+685_710_083_285`), zero liquidity and full `take` no-ops, `break` at `fillable_ == 0` with a zero entry at the head, full fill `delete`, partial head keeps owner/recipient, `Redeem` + share burn + USDC transfer events exact, 200 fills in 4 batches, C-1 fixed cases, R5-10 dust, chunking, zero-share entries (slot, `withdraw(0)`, credit 0), yield while queued (prime `104_999_999_998`; spUSDC surplus `5_000_000_000` stays), loss/gain/C-3, one-share chunks after a loss.
- `_withdrawSavings` try/catch: direct branch (every payout test), fallback on blacklist after request / at request / via updater / mid-batch / partial fills / zero entry, both branches reverting (mocked `withdraw`, vault blacklisted), contract recipient paid directly, spUSDC recipient donation.
- `_incrementClaimableAssets` / `claim`: credit and `totalClaimable` exact, `Claim` event, permissionless, `NothingToClaim`, reverts in USDC while blacklisted, works paused, `totalClaimable` decremented, inert under `adjustTotalAssets`/`take`/deposits.
- `updateRedeemRecipient`: `ZeroRecipient`, `VaultIsRecipient`, `InvalidRequestId` boundary (`id + 1` reverts, `id` passes), `NoRequest` for a filled and a zero-share entry, `NotRequestOwner` (stranger, operator, new recipient), owner repoint + event + fill pays the new recipient, while paused, blacklisted accepted and credited, spUSDC accepted (open), blacklisted owner repoints after a credited chunk (`50_484_388_412` credited + `49_515_611_586` direct = one fill), mid-fill repoint splits one fill to the wei (`299_999_999_999 + 699_999_999_998`).
- Getters: `getPendingRedeemRequest` head/length window (`InvalidRequestId` below the head and at length, partial head readable, deleted slot via `vm.load`); `getPendingRedeemRequests()` window; `(startId, length)` with `StartIdTooSmall`, `LengthTooLarge` (both `start + length > length` and `start > length`), one-element page, empty pages at the end and at the head.
- `take` interplay: dust freeze, full take no-op, paused take, take mid-queue in fuzz.

### (d) Properties that held

1. Escrow: `balanceOf(vault) == pendingRedeemShares == sum of open raw entries`, every slot below the head is zero, escrow + user balances == `totalSupply`, escrow only shrinks inside `processPendingRedeems`, processing never reverts: `testFuzz_escrowEqualsPendingRedeemShares_randomSequence` (deposits, own/third-party requests, zero-share entries, repoints with the exact reverts, drains, returns, takes, random `(maxShares_, maxRequests_)`), 20000 runs.
2. Nobody is paid more than `floor(shares * chi_p / RAY)`; each fill pays exactly that to its recipient, burns exactly the filled shares, spUSDC given up <= paid + 1 wei per fill: `testFuzz_processPendingRedeems_neverPaysMoreThanSharesTimesChi` (third-party recipients, drains, takes), `..._singleFillRoundingBounds`, 20000 runs.
3. Batched vs one-per-call identical up to the first non-advancing call, blacklisted recipients included: `testFuzz_fixed_C1_batchedEqualsOnePerCall`, 20000 runs. Batch never reverts, payouts exact, burn within `fills` wei of the aggregate ceil: `testFuzz_fixed_C1_batchNeverReverts`.
4. Parked USDC: `usdc.balanceOf(vault) == totalClaimable == sum(claimableAssets)` at all times; credits only grow outside `claim`; the fallback is wei-identical to the direct path: `testFuzz_blacklistFallback_vaultUsdcEqualsTotalClaimable`, `..._blacklistFallback_sameMathAsDirectPayout`.
5. Per-iteration bound: `assets <= A` and `ceil(assets * RAY / chi_s) <= S` for every fill (`testFuzz_processPendingRedeems_singleFillNeverReverts`).
6. Zero-share entries only from a 1-share request; with `minRedeem >= 2` no fee up to 1% burns a request to zero (`testFuzz_requestRedeem_zeroShareEntryOnlyWhenSharesIsOne`).
7. FIFO, partial fills at the head, `maxRequests_` and `maxShares_` bounds, zero entries counted: exact values in (c).
8. Events exact on every path: `RedeemRequest`, `Redeem`, `RedeemRecipientUpdated`, `ClaimableAssetsIncreased`, `Claim`, `TotalAssetsAdjusted`, `Drip`, ERC20 `Transfer`s on the vault and on USDC.

### (e) Unsettled

- R6-1 / R5-10 fix sketch (not applied, `src/` untouched): when `convertToShares(A) == 0` but `A != 0` and `request_.shares != 0`, pay `assets_ = min(A, convertToAssets(request_.shares))` for `shares_ = min(request_.shares, divUp(assets_ * RAY, chi_p))`; `shares_ * chi_p / RAY >= assets_` so the redeemer is never overpaid and the dust clears. Alternatively compute the bound once in assets (`A`) and track `remaining_` in assets. Product call whether 1 wei of dust per entry matters.
- The blacklist is the harness `MockUSDC` (reverts on 0-value transfers to blacklisted addresses too, like `FiatTokenV2`); a fork test against mainnet USDC is still recommended for the fallback path.
- `test/ai/TestBase.t.sol` is tracked but broken on this worktree; whoever owns it should fix or delete it, I only `--skip` it.
- Whether the operator should loop `processPendingRedeems` until the head stops advancing (R6-2) is an ops note, not a contract change.

---

# Round 5 (`master` @ `0ebb452`)

Worker: REDEEM-QUEUE. File: `test/ai/RedeemQueue.t.sol` (`RedeemQueueTest is LocalTestBase`), branch `campaign-v5/redeem-queue`, source `src/SparkPrimeVault.sol` at upstream `master` `0ebb452`.
Result: 60 tests, 60 pass (53 unit, 7 fuzz, re-run at 5000 runs). Five `test_BUG_*` tests pass by asserting the revert or the exact buggy state; seven `test_fixed_*` tests pin R4-A as fixed. Harness indexes and reference conversions unchanged (chi_s `1.047633055711877768967605062e27`, chi_p `1.009687768242461209408770821e27`, 100_000e6 = `95_453_269_114` spUSDC / `99_040_518_410` spPRIME, 1_000_000e6 = `954_532_691_143` / `990_405_184_109`).

Line map on 0ebb452: `requestRedeem` 446-473 (zero recipient :451, blacklist :452, `minRedeem` :453, escrow `_transfer` :457, fee :460-462, push :468); `updateRedeemRecipient` 506-516 (blacklist :508, `no-request` :512, owner :513); `claim` 524-534; `_processPendingRedeems` 900-932 (budget :903, loop :908-929, `continue` :911, `_burn` :920, `_withdrawSavings` :922, `delete` :928); `_withdrawSavings` 947-958 (direct :952, fallback :955-957); `_incrementClaimableAssets` 1044-1048; `_canReceiveAsset` 1051-1053; `adjustTotalAssets` 278-295; `take` 340-349; `getPendingRedeemRequest` 736-749; `Redeem` event 115-121.

Port notes: `realizeLoss`/`realizeGain` tests rewritten against `adjustTotalAssets` (paused only; `TotalAssetsAdjusted(chi, delta)` asserted); the round-4 `_blacklist` mock (`vm.mockCallRevert`) dropped for the harness `MockUSDC` blacklist (which the vault now consults via `isBlacklisted`); `_expectBlocked` and the three round-4 `test_BUG_blacklisted*` tests deleted (behaviour fixed) and replaced by section 14; `Redeem` emits now carry `savingsSharesBurned` (exact ceil burns, e.g. `95_453_269_113` for a `99_999_999_998` payout); `CancelRedeemRequest` dead-event assertion kept (topic never emitted; the declaration is gone too).

## (a) Findings on 0ebb452

### RQ-1 = C-1 · Medium · still open · batched fills over-burn spUSDC and revert
- `src/SparkPrimeVault.sol:903` sizes `remaining_` once from `convertToShares(spUSDC.maxWithdraw(vault))`; each fill then calls `spUSDC.withdraw(assets_)` (:922 -> :952/:955) which burns `ceil(assets * RAY / chi_s)`. Across N fills the burn can exceed the vault's spUSDC balance by up to N-1 wei and the whole batch reverts `SparkVault/insufficient-balance`.
- `test_BUG_processPendingRedeems_batchRevertsOnCeilRounding_vaultSharesBound`: vault holds `1_002_833` spUSDC (worth `1_050_601` USDC, budget `1_040_520` shares); two requests of `520_260` shares pay `525_300` each (sum `1_050_600` <= budget) but burn `501_417 + 501_417 = 1_002_834` > `1_002_833`; `(max, 2)` reverts, nothing moves; `(max, 1)` twice works, second request fills `520_258` of `520_260` (2 shares stranded behind 1 wei of spUSDC).
- `..._liquidityBound`: spUSDC liquidity `999_999_999_998`, three requests summing to `990_405_184_108` shares pay `999_999_999_997` (fits) but burn `954_532_691_144` vs `954_532_691_143` held; batch reverts; `2 + 1` works and carol is paid `674_340_790_631`, 2 wei less than the batch would have.
- Chunking cost to the redeemer, `test_processPendingRedeems_manyPartialFills_sumNeverExceedsOneFill`: a `99_040_518_410`-share request paid in 13 chunks of `7_777_777_777` yields `99_999_999_990` vs `99_999_999_998` in one fill (6 wei of floors), then 2 shares are stranded behind 1 spUSDC wei until new backing; `99_999_999_992` in the end. `testFuzz_processPendingRedeems_batchOverburnBoundedByFillsMinusOne` bounds the over-burn to N-1 wei. `testFuzz_processPendingRedeems_singleFillNeverReverts`: `maxRequests_ = 1` never reverts under random indexes, liquidity and `take`.
- The blacklist fallback (:955) uses the same `withdraw(assets_)` and therefore the same bound: `testFuzz_processPendingRedeems_blacklistFallback_sameMathAsDirectPayout` (credit == `floor(fill * chi_p / RAY)`, burn == `ceil(credit * RAY / chi_s)`).

### C-3 · High (product) · still open · `adjustTotalAssets` wipes a queued redeemer for 0 USDC
- Only floors: `totalAssets_ > 0` (:286), `updatedChi_ != 0` (:291). `test_BUG_adjustTotalAssets_wipesQueuedRedeemer_C3`: alice (`99_040_518_410` escrowed) and bob (same, held), `totalAssets` `199_999_999_997`; `adjustTotalAssets(-199_999_999_996)` emits `TotalAssetsAdjusted(5_048_438_841_264_340, -199_999_999_996)`; `convertToAssets(99_040_518_410) == 0`. The next pass emits `Redeem(alice, alice, 99_040_518_410, 0, 0)`: her shares are burned (:920), `withdraw(0)` burns 0 spUSDC, the entry is deleted (:928), she is paid 0, `totalSupply` becomes `99_040_518_410` (bob). The full backing (`190_906_538_228` spUSDC = `199_999_999_999` USDC) is unassigned; `takeAll` removes it. A `+199_999_999_996` adjustment afterwards gives bob `199_999_999_995` and alice nothing: the wipe is irreversible for anyone whose fill landed in the window.

### V2-13 · Low · still open · vault / spUSDC accepted as redeem recipient, USDC stranded with no `claimableAssets` credit
- `:452` / `:508` only blacklist-check the recipient; `address(vault)` passes, `_withdrawSavings` takes the direct branch (:952) and spUSDC pays the vault with no credit. `test_BUG_processPendingRedeems_recipientIsVault_usdcStranded_V2_13`: `99_999_999_998` USDC in the vault, `claimableAssets(vault) == 0`, `claim(vault)` reverts `nothing-to-claim`, `availableLiquidAssets` stays 1, `take` cannot move it, a later redeem cannot be paid from it. One `recipient_ != address(this)` check (as `requestDeposit` :395 has) closes it; alternatively routing the vault address through the fallback would make it claimable. spUSDC variant `..._recipientIsSpUsdc_donatesToSpUsdc_V2_13`: `1` spUSDC left, value donated to spUSDC holders.

### V2-9 · Low · still open · `requestRedeem(0)` ghosts
- `:453` with `minRedeem` 0. `test_BUG_requestRedeem_zeroSharesCreatesGhostEntry`: `RedeemRequest(alice, alice, 0, 0, 0)`, 11 ghosts cost 11 `maxRequests_` slots, `setMinRedeem(1)` closes it. New on 0ebb452: a ghost cannot be aimed at a blacklisted recipient either (`recipient-cannot-receive`, `test_fixed_requestRedeem_rejectsBlacklistedRecipient`). Ghosts are `continue`d before any payout (:911), so they never touch the blacklist path.

### Info · vault blacklisted by Circle: fallback path reverts
- `test_processPendingRedeems_vaultBlacklisted_directPayoutWorks_fallbackJams`: with `address(vault)` blacklisted, direct payouts still work (USDC moves spUSDC -> recipient), `requestDeposit` reverts in USDC (:400), and a blacklisted recipient at the head reverts (`withdraw` to the blacklisted vault, :955) until the owner repoints. Not a vault bug; recorded so nobody rates the fallback as unconditional.

## (b) Previously reported findings

- R4-A / RQ-10 (blacklisted recipient jams the redeem queue permanently): FIXED. `test_fixed_requestRedeem_rejectsBlacklistedRecipient` (request, 0-share ghost and repoint all revert `recipient-cannot-receive`; check order zero-recipient > blacklist > minimum). `test_fixed_blacklistedAfterRequest_queueKeepsMoving_claimableExact` (alice blacklisted after queueing: `ClaimableAssetsIncreased(alice, 99_999_999_998)`, `Redeem(alice, alice, 99_040_518_410, 95_453_269_113, 99_999_999_998)`, vault USDC `99_999_999_998`, bob paid directly, head 2, escrow 0; `claim(alice)` reverts `Blacklistable: account is blacklisted` with the credit intact; after un-blacklisting carol calls `claim(alice)`, `Claim(alice, 99_999_999_998)`, alice paid, vault USDC 0, second claim `nothing-to-claim`). `test_fixed_blacklistedRecipient_midBatch_noRollback` (jam in the middle of `(max, 10)`: alice and carol paid, bob credited, one transaction). `test_fixed_blacklistedRecipients_accumulateAcrossPartialFillsAndEntries` (chunks `50_484_388_412 + 49_515_611_586 + 99_999_999_998 = 199_999_999_996` for alice, `99_999_999_998` for carol, vault USDC equals the sum at every step, each claim pays its exact total). `test_fixed_blacklistedThenUnblacklistedBeforeFill_paidDirectly`. `test_fixed_blacklistedOwnerNoLongerNeedsToSelfRescue` (no role needed; a year of accrual adds nothing to a USDC credit). `testFuzz_blacklistFallback_vaultUsdcEqualsSumOfClaimable` (random deposits, requests, blacklist toggles, claims, drains, takes: `usdc.balanceOf(vault) == sum(claimableAssets)` and `balanceOf(vault) == pendingRedeemShares` after every step; credits only grow outside `claim`; `claim` reverts `nothing-to-claim` at 0 and in USDC while blacklisted).
- R3-1 (gain sandwich): CHANGED. `adjustTotalAssets` requires `paused` (:279): `test_processPendingRedeems_gainWhileQueued_escrowSharesGainProRata` asserts `not-paused` unpaused, `paused` on `requestRedeem` and `requestDeposit` during the pause, `TotalAssetsAdjusted(1.060172156650366224592543507e27, 10_000e6)`, alice paid `104_999_999_998` (+`5_000_000_000`, half the gain), bob's claim `104_999_999_998` backed by `95_000_000_000` USDC of spUSDC. Residual: a request queued before the pause captures nothing on the gain side and cannot escape on the loss side, `test_adjustTotalAssets_queueingBeforePauseCapturesNothing` (alice queued before a `-10_000e6` loss: `94_999_999_998`, same as bob's claim). The deposit-side window is DEPOSIT-QUEUE's.
- V2-1 (unauthenticated recipient updaters): FIXED, owner-only (:513), pinned by the random-ops fuzz (`not-authorized` for non-owners, `no-request` for dead entries) and `test_updateRedeemRecipient_deadEntryAndOutOfRange`. New: the OWNER is never blacklist-checked, so a blacklisted owner can repoint to a clean address (`test_updateRedeemRecipient_blacklistedOwnerRepoints_mixedCreditAndDirectPayout`: first chunk credited `50_484_388_412`, repoint to bob, rest paid directly `Redeem(alice, bob, 49_040_518_410, 47_264_269_981, 49_515_611_586)`; repointing to herself while blacklisted reverts).
- `cancelRedeemRequest` removed (round 4): unchanged, `test_cancelRedeemRequest_selectorRemovedAndEventDead`, `test_requestRedeem_isFinal_*`; dead event declaration now gone from the source.
- C-1, C-3, V2-9, V2-13: open, see (a).
- F-2 / RQ-4 (`take` is not pause-gated and can drain the queue's backing): open, `test_processPendingRedeems_pausedBlocksRedeemsNotTake` (alice frozen while `takeAll` removes `95_453_269_114` spUSDC; after unpause her `99_999_999_998` claim is intact and unpayable). Also during a pause after a loss: `test_fixed_claimableAssets_unaffectedByAdjustTotalAssetsTakeDepositsAndPause`.
- RQ-5 / RQ-9 (notional index both directions): unchanged shape with `adjustTotalAssets`, `test_processPendingRedeems_lossWhileQueued_escrowTakesLossProRata` (`TotalAssetsAdjusted(0.959203379825079411152892409e27, -10_000e6)`, `Redeem(alice, alice, 99_040_518_410, 90_680_605_657, 94_999_999_998)`, `105_000_000_000` USDC of spUSDC left behind bob's `94_999_999_998`).
- F-5 fee ghosts, RQ-3 ghosts cost `maxRequests_` slots: unchanged tests.

## (c) Properties held

1. Escrow: `balanceOf(vault) == pendingRedeemShares == sum of open entries` after every step of two random-ops fuzzes (one with blacklist toggles), escrow only shrinks inside `processPendingRedeems`. `transfer`/`transferFrom` to the vault are rejected by the ERC20 (`invalid-address`), so nothing else can land there.
2. Parked USDC: `usdc.balanceOf(vault) == sum(claimableAssets)` at all times; `adjustTotalAssets`, `take`, `requestDeposit`, pause and time leave a credit at exactly `99_999_999_998`; `totalAssets` and `availableLiquidAssets` exclude it. `test_fixed_claimableAssets_unaffectedByAdjustTotalAssetsTakeDepositsAndPause`, fuzz above.
3. Nobody is paid more than `floor(shares * chi_p / RAY)`, and the credit path is wei-identical to the direct path. `testFuzz_processPendingRedeems_neverPaysMoreThanSharesTimesChi`, `..._singleFillRoundingBounds`, `..._blacklistFallback_sameMathAsDirectPayout`.
4. `claim` is permissionless, pays only `recipient_`, zeroes before transfer, reverts `nothing-to-claim` at 0; a front-run just pays the recipient. Not pause-gated.
5. FIFO, partial fills at the head, `maxRequests_`/`maxShares_` bounds, ghosts skipped and counted: sections 3 and 10, exact values unchanged from round 4.
6. Yield while queued at the prime VSR (`104_999_999_998` after a year at 5%), spUSDC yield stays in the vault: section 4.
7. Fee burned up front, rounds up, full-balance request accepted, 1-wei-with-fee ghost: section 5.
8. `updateRedeemRecipient`: owner-only, rejects zero and blacklisted, allows vault and spUSDC (V2-13), works while paused, repoint mid-fill splits one fill to the wei (`299_999_999_999 + 699_999_999_998`).
9. Loss asymmetry: a queued redeem (spPRIME escrow) takes the loss, a queued deposit (spUSDC) does not, and capacity in shares shrinks in USD: `test_adjustTotalAssets_queuedRedeemTakesLoss_queuedDepositDoesNot` (after `-10_000e6` on alice's `99_999_999_998` book, chi `0.908718991407387565591802519e27`, alice paid `89_999_999_997`; bob's queued `95_453_269_114` spUSDC fills `85_907_942_200` for `99_040_518_407` shares worth `89_999_999_995`, `9_545_326_914` spUSDC worth `10_000_000_002` stays queued).
10. `getPendingRedeemRequest(id)` enforces `head <= id < length`; filled ids below the head revert `invalid-request-id`, partial head readable. `test_getPendingRedeemRequest_rangeAndContents`.
11. Events exact: `RedeemRequest(owner, recipient, id, sharesToBurn, feeSharesBurned)`, `Redeem(owner, recipient, sharesBurned, savingsSharesBurned, assetsReceived)`, `ClaimableAssetsIncreased`, `Claim`, `RedeemRecipientUpdated`, `TotalAssetsAdjusted`.
12. Gas: 200 fills in 4 batches of 50 stay under 60k gas per fill (`test_processPendingRedeems_200UsersIn4BatchesOf50`).

## (d) Unsettled

- Attack hypotheses tried without finding a bug: double payment via `claim` (impossible, zeroed first, credit exact); repointing a partially filled head to a blacklisted address (rejected); spUSDC-side payout failures other than the blacklist (spUSDC has no pause, `maxWithdraw` and `withdraw` agree for one fill, `_pushAsset` checks liquidity which `maxWithdraw` already bounds); moving parked USDC with `take` or `requestDeposit` (cannot).
- Whether the vault should refuse `address(this)` / `savings` as redeem recipient (V2-13) or route them through the credit path is a product call; either is a one-line change.
- C-1 frequency numbers remain the round-1 Python model; the code path is unchanged on 0ebb452.
- The blacklist is modelled with the harness `MockUSDC`; a fork test against `FiatTokenV2` is still recommended (it also blocks 0-value transfers to blacklisted addresses, same outcome).

---

# Round 4 (bf93b0d)

Worker: REDEEM-CANCEL-FEES. File: `test/ai/RedeemQueue.t.sol` (`RedeemQueueTest is LocalTestBase`), branch `campaign-v4/redeem-cancel-fees`, source `src/SparkPrimeVault.sol` at upstream `fix/update-guardian-transfer` `bf93b0d`.
Result: 49 tests, 49 pass (44 unit, 5 fuzz at 5000 runs). Six `test_BUG_*` tests pass by asserting the revert or the exact buggy state. Harness indexes and reference conversions unchanged (chi_s `1.047633055711877768967605062e27`, chi_p `1.009687768242461209408770821e27`, 100_000e6 = `95_453_269_114` spUSDC / `99_040_518_410` spPRIME, 1_000_000e6 = `954_532_691_143` / `990_405_184_109`).

Line remap (ff828d2 -> bf93b0d): `requestRedeem` 481-507 -> 451-477 (recipient :456, `minRedeem` :457, escrow transfer :461, fee burn :466); `updateRedeemRecipient` 537-546 -> 508-517 (owner check :514); `_processPendingRedeems` 819-853 -> 883-917 (budget :886, loop :891-914, `continue` :896, `withdraw` :909, `delete` :913); `realizeLoss` 369-385 -> 365-381; `realizeGain` 297-309 -> 293-305; `take` 329-338 -> 325-334; `CancelRedeemRequest` event decl :101. `cancelRedeemRequest` (was 509-535): removed.

## Removed since round 3

- `cancelRedeemRequest` is gone. A redeem request is now a commitment: the only user action on a queued entry is `updateRedeemRecipient` (owner only). Consequences, each proven:
  - F-1 redeem side (B-2 in CANCEL-FEES) and F-8 (guardian cancel keeps the fee) are closed by removal: no function moves escrowed shares to anyone but the fill recipient. `test_cancelRedeemRequest_selectorRemovedAndEventDead` (the old selector fails for owner, guardian and admin; escrow unchanged).
  - E-2 "free option" is closed: a loss realised after the request is taken by the escrow with no way out. `test_requestRedeem_isFinal_cannotStepOutOfARealizedLoss` (alice paid `94_999_999_998` after `realizeLoss(10_000e6)`, the removed selector fails, her balance stays 0).
  - C-10 "free capacity hog via redeem request" is closed: escrowed shares stay in `totalSupply` until the fill burns them, so the capacity a request occupies is released only by exiting. `test_requestRedeem_capacityStaysOccupiedUntilFill` (capacity == supply, alice queues, `availableCapacity` stays 0, bob is queued, the fill frees `99_040_518_410` of capacity and bob fills `99_040_518_408`; the 2-wei shortfall is the deposit-side capacity round-trip).
  - Round 3 properties 15-18 (head advance on cancel, partial-then-cancel refund, cancel of the last entry, zero-recipient cancel) no longer have a code path; replaced by the finality properties 25-31 below.
  - The redeem head never walks: there is no cancel-time walk and `requestRedeem` has none (the deposit queue walks at :438-446 and :782-787). A ghost at the head now costs a `maxRequests_` slot, same as a ghost behind it. `test_processPendingRedeems_ghostEntryCountsTowardMaxRequests` (two head ghosts then bob: `(max, 2)` pays nobody, head 3 -> 5; `(max, 1)` pays bob).
- The `CancelRedeemRequest` event (`src/SparkPrimeVault.sol:101`) is still declared but nothing emits it. Info, dead code; `test_cancelRedeemRequest_selectorRemovedAndEventDead` records every log of a request / repoint / fill lifecycle and finds no log with its topic.

## New finding

### RQ-10 (escalates RQ-6 / C-2) · High · A blacklisted recipient blocks the redeem queue PERMANENTLY; only the entry owner can clear it

- **Location:** `src/SparkPrimeVault.sol:909` (`spUSDC.withdraw(assets_, request_.recipient, ...)` inside the strict FIFO loop :891-914, no skip-on-failure) combined with `:514` (`updateRedeemRecipient` requires `msg.sender == request_.owner`) and the removal of `cancelRedeemRequest`.
- **What changed:** in round 3 the guardian could cancel the jamming entry (shares back to the owner, head advanced). That tool is gone. The set of addresses that can unblock a jam is now exactly one: the owner of the jamming request. A hostile owner never repoints; an honest owner whose address gets blacklisted after queueing can.
- **Scenario, `test_BUG_blacklistedRecipientBlocksRedeemQueuePermanently`:** attacker deposits 1e6 (990_404 shares), queues 1 share to a USDC-blacklisted address (`vm.mockCallRevert` on `usdc.transfer(blacklisted, *)`), alice queues 990_405_184_109 and bob 99_040_518_410 behind. Then: (1) `processPendingRedeems` reverts `Blacklistable: account is blacklisted` for `(max, 10)`, `(max, 1)`, `(1, 1)`, `(1, max)`; `(0, 10)` is a silent no-op; head stays 0. (2) guardian, admin and rebalancer all get `not-authorized` on `updateRedeemRecipient(0, ...)`; the old cancel selector fails for guardian and admin. (3) pause adds `paused` on top; after unpause the jam is intact. (4) `take`, `realizeLoss`, `realizeGain` do not move the queue. (5) alice cannot leave the queue (finality) and her own repoint changes nothing. (6) a year later still blocked, alice and bob paid 0. (7) the attacker repoints to a clean address and the next pass pays the attacker 1 wei and clears alice and bob (head 3). (8) the attacker re-queues 1 share to the blacklisted address; carol, queued behind, is locked again; attacker balance 990_402.
- **Cost to the attacker:** `minRedeem` shares escrowed (returned in full when they choose to release, step 7) plus the burned fee plus gas. With launch defaults (`minRedeem` 0, fee 0) the jam costs 1 share = 1e-6 USDC and is repeatable. With `minRedeem = 1_000e6` shares and a 1% fee the sunk cost is 10e6 shares = `10_096_877` wei USDC (~10.10 USDC) and 990e6 shares are parked, not lost: `test_BUG_blacklistedRecipientBlocksRedeemQueuePermanently_withMinRedeemAndFee` (attacker gets `999_590_890` USDC back on release, alice `989_999_999_997`).
- **Latent variant, `test_BUG_blacklistedRecipient_latentJamForcesExactBatchSizing`:** a jam at index 1 behind a live alice at 0: `(max, 10)` reverts as one transaction, so alice is NOT paid either; `(max, 1)` pays alice; everything after is locked. The planner has to size `maxRequests_` to stop exactly before each jam.
- **Honest-victim variant, `test_updateRedeemRecipient_blacklistedOwnerSelfRescuesQueue`:** alice blacklisted after queueing; bob locked; mallory, bob, guardian, admin and rebalancer all `not-authorized`; alice repoints to carol during a pause (`updateRedeemRecipient` has no `whenNotPaused`), `RedeemRecipientUpdated(0, carol)`, then `Redeem(alice, carol, 99_040_518_410, 99_999_999_998)`, carol and bob each paid `99_999_999_998`, head 2.
- **Impact:** every exit behind the jam is locked until an upgrade. Combined with finality (section 12), the honest users behind the jam cannot withdraw their requests either. Round 3 rated C-2 Medium because the guardian had a one-transaction fix; that is no longer true.
- **Fix options:** (a) a guardian/admin-callable `updateRedeemRecipient(id, request_.owner)` (recipient forced to the owner, mirroring the new deposit-cancel guardian rule at :422-425); or (b) a role-gated "skip and refund to owner" that transfers the entry's shares back to `request_.owner` and deletes the entry; or (c) pay with a try/catch and park failed entries. (a) is the smallest and keeps the escrow model; it does not help when the owner itself is blacklisted and the owner key is lost, which (b) does.

## Persisting (re-confirmed at bf93b0d)

- RQ-1 (= C-1) · Medium · multi-request batch reverts on spUSDC ceil-rounding: budget once at `:886`, `spUSDC.withdraw(assets_)` per fill at `:909`. Both `test_BUG_processPendingRedeems_batchRevertsOnCeilRounding_*` pass by asserting `SparkVault/insufficient-balance` (same numbers as round 2); the payout fuzz still reaches the revert branch. New angle, `test_processPendingRedeems_manyPartialFills_sumNeverExceedsOneFill`: 13 chunks of 7_777_777_777 shares on a 99_040_518_410 request pay `99_999_999_990` (one fill: `99_999_999_998`), and the per-chunk ceil burns leave 1 wei of spUSDC behind 2 queued shares, which are a no-op until 2 spUSDC wei of backing arrive; then `99_999_999_992` total. The redeemer, not the vault, pays for chunking.
- RQ-7 · Low · `requestRedeem(0)` ghosts (`:457` with `minRedeem` 0). `test_BUG_requestRedeem_zeroSharesCreatesGhostEntry` (updated: the ghost rejects `updateRedeemRecipient` with `no-request`; `setMinRedeem(1)` closes it). Ghosts cannot jam (0 shares -> `continue`), checked in the fuzz.
- RQ-2 · Low · USDC to `recipient == address(vault)` stuck, `:456` only rejects zero. Unchanged tests.
- RQ-3 · Info · dead entries consume `maxRequests_` (`:889`, `:896`), now including dead entries at the head (see Removed).
- RQ-4 · Info · pause freezes redeemers and new requests, `take` (`:325-334`) keeps working; `updateRedeemRecipient` is not pause-gated. `test_processPendingRedeems_pausedBlocksRedeemsNotTake`.
- RQ-5 / RQ-9 · Info · notional index both directions (`realizeLoss` :365-381, `realizeGain` :293-305) with the round-3 values.
- F-5 fee ghosts (`test_requestRedeem_oneWeiWithFee_ghostEntry_F5`): the burned wei is unrecoverable; the dead entry rejects the updater.

## Design property established: exits are 100% planner-dependent

`test_requestRedeem_isFinal_noPathRecoversEscrow`: after `requestRedeem` the shares sit at `address(vault)`. `transferFrom(vault, alice, 1)` reverts `insufficient-allowance` (the vault never approves); `permit(owner = vault, ...)` reverts `invalid-permit` (ecrecover cannot yield the proxy address, and the proxy has no `isValidSignature`, so the ERC-1271 staticcall fails); `updateRedeemRecipient` moves the recipient, never the shares; `take` moves spUSDC only; pause does nothing to the escrow; a year without a planner call leaves the escrow in place and accruing (`104_999_999_998` claim at 5%); only `processPendingRedeems` releases it, paying `floor(shares * chi / RAY)` at fill time. The random-ops fuzz asserts on every step that the removed selector fails and that `balanceOf(vault)` only decreases inside `processPendingRedeems`.

## Hunt notes (no new bug)

- `requestRedeem` ordering: `_transfer` to the vault, then `_burn` of the fee from the vault, then push. A 1-share request at a 1% fee burns the share and queues 0 (F-5); a 2-share request queues 1 share (enough to jam, see RQ-10). `minRedeem` is gross of fee (unchanged).
- `_processPendingRedeems` is CEI-clean: `pendingRedeemShares`, `request_.shares`, `remaining_` and `_burn` are all updated before `spUSDC.withdraw` (`:901-909`). A reverting recipient rolls back the whole call (the jam), it cannot desynchronise state.
- `delete` after a full fill (`:913`) happens after the external call; with the state already reduced to 0 this is only a refund of gas. A repoint of a deleted entry reverts `no-request` for everyone (`test_updateRedeemRecipient_deadEntryAndOutOfRange`, `test_processPendingRedeems_fullFillDeletesEntry`).
- Repoint on the head mid-fill: `test_requestRedeem_afterPartialFill_remainderStaysQueued_repointMidFill` (alice paid `299_999_999_999` to herself, repoints, bob gets `699_999_999_998`, sum `999_999_999_997`, head then stops on the ghost at 1 because nothing walks it).
- Nothing pays more than `floor(shares * chi / RAY)`: `testFuzz_processPendingRedeems_neverPaysMoreThanSharesTimesChi` and `..._singleFillRoundingBounds` re-held at 5000 runs; chunking only loses.
- `withdraw(0)` (1 share after a loss takes chi below RAY) is accepted by spUSDC and by the mock USDC; on mainnet USDC a 0-value transfer to a blacklisted address still reverts (`notBlacklisted`), so a 0-value jam is the same jam.

## Properties held (round 4)

Properties 1-14 and 19-24 of the round-2/round-3 sections re-held with the same exact values (5000 fuzz runs); 13 restated: the random-ops fuzz has no cancel action, adds third-party-recipient requests, asserts the removed selector fails for owner and guardian on every such request, and asserts the escrow is non-increasing across every planner call. Properties 15-18 (cancel) are retired. New:

25. The `cancelRedeemRequest` selector fails for owner, guardian and admin; no `CancelRedeemRequest` log is ever emitted. `test_cancelRedeemRequest_selectorRemovedAndEventDead`.
26. No ERC20, permit, role or time path recovers escrowed shares; only a fill does. `test_requestRedeem_isFinal_noPathRecoversEscrow`.
27. A realised loss after the request is borne by the escrow with no exit. `test_requestRedeem_isFinal_cannotStepOutOfARealizedLoss`.
28. Capacity occupied by a queued redeem is released only by its fill. `test_requestRedeem_capacityStaysOccupiedUntilFill`.
29. The remainder of a partial fill stays queued; the owner can repoint it mid-fill; old and new recipient sum to one fill. `test_requestRedeem_afterPartialFill_remainderStaysQueued_repointMidFill`.
30. Chunked fills never pay more than one fill, lose at most one wei per chunk, and can strand up to a few shares behind ceil-burn dust until backing arrives. `test_processPendingRedeems_manyPartialFills_sumNeverExceedsOneFill`.
31. Ghosts at the head cost a slot (no head walk in the redeem queue). `test_processPendingRedeems_ghostEntryCountsTowardMaxRequests`, `test_processPendingRedeems_fifo_skipsGhosts`.
32. `updateRedeemRecipient` works while paused and is the owner's rescue from a blacklisted address. `test_updateRedeemRecipient_blacklistedOwnerSelfRescuesQueue`, `test_processPendingRedeems_pausedBlocksRedeemsNotTake`.

## Unsettled

- RQ-10 severity assumes mainnet USDC blacklist semantics (proven with `vm.mockCallRevert`); a fork test against real `FiatTokenV2` `Blacklistable` is still recommended. Any other reason the recipient cannot receive (none exists for a plain USDC `transfer` apart from the blacklist) would have the same effect.
- Whether the fix should be a guardian repoint-to-owner (keeps the owner's capital in the queue) or a guardian skip-and-refund (returns it) is a product decision; both close RQ-10.
- RQ-1 frequency numbers remain the round-1 model; the code path is unchanged.
- The product questions from round 3 (queue-time payouts funded from others' backing, `realizeGain` ordering) are unchanged and owned by ADVERSARIAL.

---

# Round 3 (ff828d2)

Worker: QUEUES. File: `test/RedeemQueue.t.sol` (`RedeemQueueTest is LocalTestBase`), branch `campaign-v3/queues`, source `src/SparkPrimeVault.sol` at upstream `refactor/more-simplifying` `ff828d2`.
Result: 47 tests, 47 pass (42 unit, 5 fuzz at 5000 runs). The three `test_BUG_*` tests still pass by asserting the revert or the exact buggy state. Harness indexes and reference conversions are unchanged from round 2.

Line remap (round-2 numbers in the sections below -> ff828d2): `minRedeem` decl 195 -> 199; `requestRedeem` 481-507 (recipient :486, `minRedeem` :487); `cancelRedeemRequest` 506-532 -> 509-535 (`delete` :521, head walk :527-532); `updateRedeemRecipient` 534-538 -> 537-546; `realizeLoss` 351-360 -> 369-385; `realizeGain` (new) 297-309; `_processRedeemQueue` 782-810 -> 819-853 (budget :822, loop :827-850, `continue` :832, `withdraw` :845, `delete` :849); `Redeem` event 110-115; `take` 329-338.

## Fixed since round 2

- RQ-8 (NEWSURFACE's High) is fixed: `updateRedeemRecipient` (`src/SparkPrimeVault.sol:537-546`) requires a non-zero recipient (:538), a live entry (`no-request`, :542) and `msg.sender == request_.owner` (`not-authorized`, :543). Consequence for C-2: the stranger unblock-and-steal path is gone, the owner can self-rescue, and the guardian cancel is the only third-party unblock. `test_updateRedeemRecipient_anyoneUnblocksBlacklistedHeadAndTakesThePayout` split into `test_updateRedeemRecipient_strangerCannotRepointBlacklistedHead` (mallory, bob behind her and the guardian all revert `not-authorized`; entry unchanged; queue still reverts on the blacklist; guardian cancel returns `99_040_518_410` shares to alice, head 1, bob paid `99_999_999_998`, mallory 0) and `test_updateRedeemRecipient_ownerSelfRescuesBlacklistedHead` (alice repoints to carol, `RedeemRecipientUpdated(0, carol)`, `Redeem(alice, carol, 99_040_518_410, 99_999_999_998)`, carol and bob paid `99_999_999_998` each, head 2). `test_updateRedeemRecipient_deadEntryAndOutOfRange`: a filled entry reverts `no-request` for the former owner and a stranger, a cancelled entry reverts `no-request` for its owner, `id + 1` panics 0x32. The random-ops fuzz repoints only through the entry owner and asserts `not-authorized` for a non-owner and `no-request` for a dead entry (5000 runs).
- `realizeLoss` (`:369-385`) now requires `0 < loss < totalAssets` (:376) and `totalSupply != 0` (:380): the `loss == totalAssets` brick and the zero-supply division from the round-2 unsettled list are closed. RQ-5's loss test used `10_000e6` of `199_999_999_997` and is unaffected (same chi `0.959203379825079411152892409e27`, alice paid `94_999_999_998`).

## Persisting (re-confirmed at ff828d2)

- RQ-1 (= C-1) · Medium · multi-request batch reverts on spUSDC ceil-rounding: budget once at `src/SparkPrimeVault.sol:822`, `spUSDC.withdraw(assets_)` per fill at `:845`. `test_BUG_processRedeemQueue_batchRevertsOnCeilRounding_vaultSharesBound` (2 x 520_260 shares, `SparkVault/insufficient-balance`, nothing moves, one per call works) and `..._liquidityBound` (3 requests summing to `990_405_184_108`, batch reverts, 2 + 1 works) pass by asserting the revert; the payout fuzz still reaches the revert branch.
- RQ-6 (= C-2) · Medium · blacklisted recipient at the head blocks the queue: `:845` inside the strict FIFO loop (`:827-850`). `test_BUG_blacklistedRecipientBlocksRedeemQueue` passes by asserting the revert on `(max, 10)`, `(max, 1)` and `(1, 1)`; the guardian cancel unblocks, the attacker re-jams for gas. Round 3 narrows the unblock set to owner-or-guardian (see Fixed).
- RQ-7 · Low · `requestRedeem(0)` ghosts: `:487` with `minRedeem` 0 (`:199`). `test_BUG_requestRedeem_zeroSharesCreatesGhostEntry`.
- RQ-2 · Low · USDC to `recipient == address(vault)` stuck, `:486` only rejects zero. `test_processRedeemQueue_recipientIsVault_usdcStuck`, `..._recipientIsSpUsdc_donatesToSpUsdc`.
- RQ-3 · Info · non-head holes and ghosts consume `maxRequests_` (`:825`, `:832`); head cancels do not (`:527`). `test_processRedeemQueue_cancelledEntryCountsTowardMaxRequests`.
- RQ-4 · Info · pause freezes redeemers, `take` (`:329-338`) keeps working. `test_processRedeemQueue_pausedBlocksRedeemsNotTake`.
- RQ-5 · Info · notional index both directions; the loss leg unchanged (`:369-385`), the yield leg unchanged.

## New gain/loss observations

- RQ-9 · Info · A queued redeemer is paid MORE after `realizeGain` (`src/SparkPrimeVault.sol:297-309`, DEFAULT_ADMIN, no pause requirement, `chi = (totalAssets + gain) * RAY / totalSupply`, event `GainRealized(chi, gain)` :308). Escrowed shares are in `totalSupply`, so the gain is pro rata with holders. `test_processRedeemQueue_realizeGainWhileQueued_escrowSharesGainProRata`: alice and bob hold `99_040_518_410` each (`totalAssets` `199_999_999_997`), alice queued; `realizeGain(10_000e6)` unpaused sets chi `1.060172156650366224592543507e27`, `totalAssets` `209_999_999_996`; the fill emits `Redeem(alice, alice, 99_040_518_410, 104_999_999_998)` and pays alice `104_999_999_998` (+`5_000_000_000`), bob's `assetsOf` is `104_999_999_998`. The backing did not grow: the vault burns `100_225_932_569` spUSDC and keeps `90_680_605_659` worth `95_000_000_000` USDC against bob's `104_999_999_998` claim. A gain realised before the capital arrives is paid to the first redeemer out of the common spUSDC, exactly the RQ-5 yield shape; if the gain never arrives the last redeemer is short by it.
- Asymmetry: `realizeLoss` needs `paused` and `loss < totalAssets`; `realizeGain` needs neither pause nor an upper bound, so a gain can land between a `requestRedeem` and its fill in the same block. Factual only; the sandwich is ADVERSARIAL's.

## Properties held (round 3)

Properties 1-20 of the round-2 section below re-held on ff828d2 with the same exact values (5000 fuzz runs), with property 13 restated: the random-ops fuzz now repoints only via the entry owner and asserts the two new reverts. New:

21. Only the entry owner can repoint a live redeem; the recipient, a stranger and the guardian get `not-authorized`; the entry is unchanged after the attempts. `test_updateRedeemRecipient_strangerCannotRepointBlacklistedHead`.
22. The owner repoint of a blacklisted head unblocks the queue in one pass and pays the new recipient the full `floor(shares * chi_p / RAY)`. `test_updateRedeemRecipient_ownerSelfRescuesBlacklistedHead`.
23. Dead entries (filled or cancelled) reject repoints with `no-request` for every caller; past-the-end panics 0x32. `test_updateRedeemRecipient_deadEntryAndOutOfRange`.
24. A realised gain of `g` on `n` equal holders (escrow included) raises each claim by exactly `g / n` to the wei, the queued redeemer's payout included. `test_processRedeemQueue_realizeGainWhileQueued_escrowSharesGainProRata`.

## Unsettled

- RQ-1 frequency numbers (2 fills 0.05%, 10 fills 17%, 50 fills 45%) are still the round-1 Python model; the code path is byte-for-byte the round-2 logic.
- C-2 is proven with a mocked USDC revert; a fork test against real USDC `Blacklistable` is still recommended.
- `realizeGain` has no upper bound and no pause requirement; whether a gain should be realisable with an open redeem queue, and the ordering between `realizeGain` and `processRedeemQueue` in one block, are ADVERSARIAL's.
- Whether queue-time payouts funded from others' backing (yield, loss surplus, realised gain) are acceptable remains a product decision (I-7).

---

# Redeem-queue campaign report, round 2 (`test/RedeemQueue.t.sol`)

Branch `campaign-v2/redeem-queue`, `src/SparkPrimeVault.sol` from upstream `refactor/more-simplifying`
merged with `review/poc-tests-v2` (`pause()` on GUARDIAN, `realizeLoss` floor formula). 45 tests,
all pass (`FOUNDRY_FUZZ_RUNS=5000`). The three `test_BUG_*` tests prove bugs with `vm.expectRevert`
or exact state, so they pass while the bug exists and fail once it is fixed.

Harness indexes after `setUp` are unchanged from round 1: chi_s = 1.047633055711877768967605062e27,
chi_p = 1.009687768242461209408770821e27; 1_000_000e6 deposited = 954_532_691_143 spUSDC /
990_405_184_109 spPRIME; 100_000e6 = 95_453_269_114 / 99_040_518_410. Notation: L = USDC in spUSDC,
S = spUSDC held by the vault, A = `spUSDC.maxWithdraw(vault)`, rem = floor(A * RAY / chi_p).

## Round-2 delta (what changed upstream on the redeem side)

| Change | Line | Effect on round-1 tests |
|---|---|---|
| `requestRedeem` only checks `shares_ >= minRedeem`; `minRedeem` is in shares; `shares_ != 0` gone | 195, 484 | `test_requestRedeem_revertsZeroShares` inverted (now a bug test); `minWithdraw` boundary rewritten in shares |
| `cancelRedeemRequest` requires `recipient_ != 0`, `delete`s the entry, advances `redeemHead` past zero entries when the head is cancelled | 506-532 | RQ-3 narrowed: a cancelled head no longer costs a `maxRequests_` slot |
| Full fills `delete` the entry (getter returns zeros) | 809 | `_expectedPayouts` in the payout fuzz now snapshots recipients before the call |
| New unauthenticated `updateRedeemRecipient(id, r)` | 534-538 | New tests, section 13 |
| `setChi` replaced by `realizeLoss(loss)` (paused only, `chi = floor((totalAssets - loss) * RAY / totalSupply)`) | 351-360 | New RQ-5 mirror test |
| `Redeem(owner, recipient, shares, assets)` argument order; `_divup` -> `_divUp`; `take` string `insufficient-shares`; `pause` GUARDIAN | 108-113, 905 | Event test added; helper renamed |

## (a) Bugs and suspicious behaviour

### RQ-1 (= C-1) · Medium · Re-confirmed: a multi-request `processRedeemQueue` batch reverts on spUSDC ceil-rounding

**Location:** `src/SparkPrimeVault.sol:782` (share budget computed once from `availableLiquidAssets()`),
`src/SparkPrimeVault.sol:805` (`spUSDC.withdraw(assets_)` per fill burns `ceil(assets * RAY / chi_s)`).
Both lines are the round-1 logic unchanged.

**Scenario 1 (vault-share bound), `test_BUG_processRedeemQueue_batchRevertsOnCeilRounding_vaultSharesBound`:**
alice deposits 1_000_000e6; the taker leaves S = 1_002_833 (A = 1_050_601, rem = 1_040_520). Two
requests of 520_260 shares pay 525_300 each (1_050_600 <= A) but burn 501_417 each = 1_002_834 > S.
`processRedeemQueue(max, 2)` reverts `SparkVault/insufficient-balance`, nothing moves. One request
per call works: 525_300 then 525_298 paid, 2 shares and 1 wei spUSDC left.

**Scenario 2 (liquidity bound), `test_BUG_processRedeemQueue_batchRevertsOnCeilRounding_liquidityBound`:**
L = 999_999_999_998 (2 wei drained). Three requests summing to rem = 990_405_184_108 pay
999_999_999_997 USDC (fits L) but burn 954_532_691_144 against S = 954_532_691_143. Batch of 3
reverts; split 2 + 1 works, carol gets 674_340_790_631 (2 wei less than the batch would pay).

**Impact and fix:** unchanged from round 1 (batch automation reverts non-deterministically when the
queue drains the last wei of backing; funds safe; re-clamp `remaining_` inside the loop from
`availableLiquidAssets()` or burn via `redeem(convertToShares(assets_))`). The payout fuzz still
reaches the revert branch (`testFuzz_processRedeemQueue_batchOverburnBoundedByFillsMinusOne` asserts
reason and no state change).

### RQ-6 (= C-2) · Medium · Re-confirmed: a redeem to a USDC-blacklisted recipient blocks the whole queue

**Location:** `src/SparkPrimeVault.sol:805` inside the strict FIFO loop (lines 787-810), no skip-on-failure.

**Scenario, `test_BUG_blacklistedRecipientBlocksRedeemQueue`:** attacker deposits 1e6 and queues 1 share
to a blacklisted address (USDC `transfer` mocked to revert `Blacklistable: account is blacklisted`);
alice queues 990_405_184_109 behind. `processRedeemQueue(max, 10)`, `(max, 1)` and `(1, 1)` all
revert; head stays 0, alice unpaid. Guardian cancel to the owner refunds the attacker's share and,
new this round, advances the head to 1, so alice is paid 999_999_999_998 with a single slot; the
attacker re-queues and bob is stuck behind the new jam again. Cost to the attacker: gas.

**New this round:** the jam can also be cleared by anyone through `updateRedeemRecipient`, see RQ-8.

### RQ-7 · Low · `requestRedeem(0)` succeeds and pushes a zero-share ghost entry

**Location:** `src/SparkPrimeVault.sol:484` (`require(shares_ >= minRedeem)` with `minRedeem`
initialised to 0 at line 195; the round-1 `shares_ != 0` check is gone).

**Scenario, `test_BUG_requestRedeem_zeroSharesCreatesGhostEntry`:** with the 1 % fee set,
`requestRedeem(0, alice)` emits `RedeemRequest(alice, alice, 0, 0, 0)`, moves no shares, burns no
fee, and pushes entry 0 with 0 shares. `cancelRedeemRequest(0)` reverts `SparkPrimeVault/no-request`.
carol, who holds no shares, pushes 10 more. bob's real request lands at index 11 and needs
`maxRequests_ = 12` to be reached: `(max, 11)` pays nobody and moves the head to 11, `(max, 1)` then
pays bob 98_999_999_998. `setMinRedeem(1)` closes the path (`requestRedeem(0)` reverts
`below-minimum`).

**Impact:** free throughput griefing (same class as F-5 but now needs no shares and no fee; ~2.3k gas
per ghost cold, one wasted `maxRequests_` slot each until the head passes). The head still advances,
so no funds are blocked. **Fix:** `require(shares_ != 0)` or launch with `minRedeem >= 1`.

### RQ-8 · Info here (High, owned by NEWSURFACE) · `updateRedeemRecipient` is unauthenticated: it both unblocks a blacklisted head and lets anyone take the payout

**Location:** `src/SparkPrimeVault.sol:534-538` (only `recipient_ != 0`; no owner check, no liveness check).

**Scenario, `test_updateRedeemRecipient_anyoneUnblocksBlacklistedHeadAndTakesThePayout`:** alice and
bob queue 99_040_518_410 each; alice is blacklisted after queueing, so processing reverts and bob is
stuck. mallory (unrelated) calls `updateRedeemRecipient(0, mallory)`. The next pass pays mallory
99_999_999_998 (alice's whole request), pays bob 99_999_999_998, head 2. The queue is unblocked and
alice is robbed in the same transaction. The intended path works:
`test_updateRedeemRecipient_ownerRepointsAndFillPaysNewRecipient` (owner repoints to bob, owner
field unchanged, fill pays bob, `address(0)` rejected). Repointing a filled or cancelled entry is
accepted and harmless (shares are 0), an index past the array panics 0x32:
`test_updateRedeemRecipient_deadEntryAndOutOfRange`. Not re-reported as a finding; the tests pin both
sides for whoever patches it (`msg.sender == owner` keeps the unblock property only for the owner,
so the guardian cancel remains the planner's tool for C-2).

### RQ-2 · Low · USDC paid to `recipient == address(vault)` is stuck (unchanged)

`test_processRedeemQueue_recipientIsVault_usdcStuck`, `test_processRedeemQueue_recipientIsSpUsdc_donatesToSpUsdc`:
same numbers as round 1 (99_999_999_998 USDC in the vault contract, invisible to
`availableLiquidAssets`, untouched by `take`; recipient = spUSDC donates the value to spUSDC
holders). `requestRedeem` still only rejects `address(0)` (line 483).

### RQ-3 · Info · Only non-head cancelled and ghost entries consume `maxRequests_` (narrowed)

`test_processRedeemQueue_cancelledEntryCountsTowardMaxRequests`: bob (index 1) cancels; `(max, 2)`
pays alice and spends the second slot on the hole (carol unpaid, head 2); `(max, 1)` pays carol.
Contrast: alice cancels at the head, head jumps to the next live entry and one slot reaches bob.
Round-1 wording "cancelled entries consume a slot" now holds only for holes behind the head.

### RQ-4 · Info · `pause` freezes redeemers while `take` keeps working (unchanged)

`test_processRedeemQueue_pausedBlocksRedeemsNotTake`: guardian pauses, `processRedeemQueue` and
`cancelRedeemRequest` revert `SparkPrimeVault/paused`, taker removes all 95_453_269_114 spUSDC, after
unpause the 99_999_999_998 claim stays queued in full.

### RQ-5 · Info · Notional index, both directions (quantified)

Yield: `test_processRedeemQueue_primeYieldAccruesWhileQueued`, unchanged: a year at 5 % pays the
queued redeemer 104_999_999_998 (5_000_000_000 more than at request time) out of bob's backing,
leaving bob's 104_999_999_998 claim on 95_000_000_000 USDC of spUSDC.

Loss (new mirror): `test_processRedeemQueue_realizeLossWhileQueued_escrowTakesLossProRata`: alice and
bob hold 99_040_518_410 each (`totalAssets` 199_999_999_997); alice is queued. Guardian pauses,
risk manager calls `realizeLoss(10_000e6)`: chi = floor((199_999_999_997 - 10_000e6) * RAY /
198_081_036_820) = 0.959203379825079411152892409e27, `totalAssets` 189_999_999_996. The fill pays
alice 94_999_999_998 instead of 99_999_999_998 and bob's `assetsOf` is 94_999_999_998: the escrow
takes exactly half of the loss. Because spUSDC was intact in this scenario the vault still holds
105_000_000_000 USDC worth of spUSDC against bob's 94_999_999_998 claim; a loss realised before the
capital actually disappears leaves a surplus that `take` can remove and chi never gives back
(`loss == totalAssets` sets chi to 0; NEWSURFACE proves the brick).

## (b) Properties that held (each with its test)

1. Single fill never reverts and pays `floor(fill * chi_p / RAY)`, burning exactly
   `ceil(paid * RAY / chi_s)` spUSDC, under random VSRs in [RAY, MAX_VSR], warps up to 5 years,
   random drains and takes: `testFuzz_processRedeemQueue_singleFillNeverReverts` (5000 runs).
2. Single-fill rounding: `0 <= fill * chi_p - paid * RAY < RAY`, `0 <= burned * chi_s - paid * RAY < chi_s`,
   spUSDC value given up `< paid + chi_s / RAY + 1`: `testFuzz_processRedeemQueue_singleFillRoundingBounds` (5000).
3. Batch over-burn bounded by N-1 wei of spUSDC above the aggregate burn when the batch succeeds;
   revert reason and no state change when it does not: `testFuzz_processRedeemQueue_batchOverburnBoundedByFillsMinusOne` (5000).
4. Total USDC withdrawn in a batch never exceeds A (`liqBefore - liqAfter == sum payouts`):
   `testFuzz_processRedeemQueue_neverPaysMoreThanSharesTimesChi` (5000).
5. Liquidity-bound partial fill (L = 300_000e6): pays 299_999_999_999, remainder 693_283_628_876,
   head stays 0; after liquidity returns the claim binds and pays 699_999_999_998, head 1, 1 wei
   spUSDC left: `test_processRedeemQueue_partialFill_spUsdcLiquidityBound`.
6. Share-bound partial fill (S = 300_000e6): pays 314_289_916_712, burns 299_999_999_999, remainder
   679_130_821_283; 1 wei spUSDC converts to 0 shares and is a no-op: `test_processRedeemQueue_partialFill_vaultSharesBound`.
7. FIFO with cancelled entries skipped; partial entry stays at the head; later entries never fill
   before an earlier open one: `test_processRedeemQueue_fifo_skipsCancelled`, `test_processRedeemQueue_headBlocksLaterSmallerRequests`.
8. `maxRequests_` honoured exactly (0 no-op, clamps to the queue); `maxShares_` to the share (q-1 then
   11 across two entries); `maxShares_ = 0` and empty queue are no-ops: `test_processRedeemQueue_maxRequests`,
   `test_processRedeemQueue_maxShares`, `test_processRedeemQueue_maxSharesZero_noop`, `test_processRedeemQueue_emptyQueue_noop`.
9. Fee: 1 % on 1_000_000e6 shares burns exactly 10_000_000_000, pays 999_590_890_560;
   999_999_999_999 shares also burn 10_000_000_000; full balance with fee accepted (fee 990_405_185);
   1-wei request with fee is a ghost (F-5): `test_requestRedeem_feeOnePercent_exactAmounts`,
   `test_requestRedeem_feeRoundsUp`, `test_requestRedeem_fullBalanceWithFee`, `test_requestRedeem_oneWeiWithFee_ghostEntry_F5`.
10. 200 users x 5_000e6 in 4 batches of 50: every user paid 4_999_999_998, head 200,
    `pendingRedeemShares == balanceOf(vault) == totalSupply == 0`, 200 wei spUSDC dust;
    8_198_733 gas for 200 fills, 40_993 per fill (round 1: 40_231; the `delete` costs ~760 gas
    more per fill net of refunds): `test_processRedeemQueue_200UsersIn4BatchesOf50`.
11. `availableLiquidAssets() == 0` (drained or fully taken) is a no-op without revert, 1 wei spUSDC
    too: `test_processRedeemQueue_zeroLiquidity_noop`, `test_processRedeemQueue_afterFullTake_noop`.
12. `requestRedeem` reverts `insufficient-balance` at balance + 1, `invalid-recipient` for
    `address(0)`; `minRedeem` is in shares: `minRedeem - 1` reverts `below-minimum`, exactly
    `minRedeem` passes, independent of chi; the minimum is gross of fee (1_000e6 requested at 1 %
    queues 990_000_000): `test_requestRedeem_revertsInsufficientBalanceBoundary`,
    `test_requestRedeem_revertsRecipientZero`, `test_requestRedeem_minRedeemBoundary_inShares`.
    Drift note: 1_000e6 shares = 1_009_687_768 USDC today and 1_060_172_156 USDC after a year at 5 %
    (+5.0 %); a request worth 1_050e6 USDC (990_405_184 shares) is still rejected then:
    `test_requestRedeem_minRedeemDriftsInAssetTerms`.
13. Invariants over random 24-step sequences (deposit, request, zero-share ghost, cancel,
    `updateRedeemRecipient` by anyone to any entry, process with random `maxShares_`/`maxRequests_`,
    drain, return, take, warp with both VSRs > RAY and a 0.1 % fee): `balanceOf(vault) ==
    pendingRedeemShares == sum of open request shares`, every entry before `redeemHead` has 0 shares,
    `redeemHead <= length`, `balanceOf(vault) + user balances == totalSupply`:
    `testFuzz_processRedeemQueue_balanceOfVaultEqualsPendingRedeemShares` (5000).
14. Every batch pays each recipient (snapshotted before the call, since filled entries are deleted)
    exactly `sum floor(filled_i * chi_p / RAY)`, burns exactly the filled shares from `totalSupply`,
    respects `maxShares_`, spUSDC given up worth at most 1 wei per fill above what was paid:
    `testFuzz_processRedeemQueue_neverPaysMoreThanSharesTimesChi` (5000).
15. (new) Cancelling the head advances `redeemHead` past it and past zero-share entries behind it
    (0 -> 3 over two ghosts), the entry reads as `(0, 0, 0)` and cannot be cancelled twice, one slot
    then reaches the next live entry: `test_cancelRedeemRequest_headCancelSkipsGhostsBehindIt`.
16. (new) Cancelling a non-head entry leaves the head; holes are walked later:
    `test_cancelRedeemRequest_nonHeadCancelLeavesHead`. Cancelling the only entry sets
    `redeemHead == length == 1`, processing is a no-op, the next request is at the head:
    `test_cancelRedeemRequest_lastEntryCancelMovesHeadToLength`.
17. (new) Partial fill (299_999_999_999 paid), then owner cancels the remainder: exactly
    693_283_628_876 shares refunded, head 0 -> 2 (past a ghost), the next entry fills with one slot:
    `test_cancelRedeemRequest_afterPartialFill_refundsRemainderAndAdvancesHead`.
18. (new) `cancelRedeemRequest(id, address(0))` reverts `invalid-recipient` (closes the C-6 cancel
    leg): `test_cancelRedeemRequest_revertsRecipientZero`.
19. (new) A full fill `delete`s the entry (getter `(0, 0, 0)`, cancel reverts `no-request`, slot
    still counted in the array); a partial fill keeps owner, recipient and remainder:
    `test_processRedeemQueue_fullFillDeletesEntry`.
20. (new) `Redeem(owner, recipient, shares, assets)` emitted as `(alice, bob, 99_040_518_410,
    99_999_999_998)`: `test_processRedeemQueue_emitsRedeemSharesThenAssets`.

## (c) Unsettled

- RQ-1 frequency (2 fills 0.05 %, 10 fills 17 %, 50 fills 45 % at the harness indexes) is the
  round-1 Python model; the code path is unchanged so the numbers carry over, but they were not
  re-sampled against the merged source.
- C-2 is proven with a mocked USDC revert; a fork test against real USDC `Blacklistable` is still
  recommended.
- `realizeLoss` with `totalSupply == 0` divides by zero and `loss > totalAssets` underflows; both
  revert (panic) rather than brick, but neither is covered here (NEWSURFACE scope).
- Whether queue-time prime yield paid from others' backing, and the symmetric surplus left after a
  `realizeLoss` that precedes the actual capital loss, are acceptable remains a product decision (I-7).
