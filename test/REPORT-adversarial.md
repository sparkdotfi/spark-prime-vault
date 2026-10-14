# spPRIME adversarial campaign: report

Worker: adversarial. File: `test/Adversarial.t.sol` (contract `AdversarialTest is LocalTestBase`),
59 tests, all passing (`forge test --match-path test/Adversarial.t.sol`, fuzz at 1000 and 5000
runs). Line numbers refer to `src/SparkPrimeVault.sol` on `campaign/adversarial` (carries review
patches F-1 and F-3). Known findings F-1..F-8 / I-1..I-8 are not re-reported.

Counts: new findings 1 Medium, 3 Low, 5 Info. Everything else held as a property.

## (a) Successful or partially successful attacks

### A-1 Medium: a redeem whose recipient cannot receive USDC blocks the whole redeem queue
`_processRedeemQueue` line 698: `IERC4626Like(savings).withdraw(assets_, request.recipient, address(this))`.
Mainnet USDC reverts on transfers to blacklisted addresses. The loop is strict FIFO with no
skip-on-failure, so once such an entry is at `redeemHead` every `processRedeemQueue` call reverts
and nobody behind it can be paid.

Scenario (test `test_BUG_blacklistedRecipientBlocksRedeemQueue`): attacker deposits 1 USDC,
calls `requestRedeem(1, <blacklisted address>)`; Alice queues 1_000_000 USDC behind. Both
`processRedeemQueue(max, 10)` and `(max, 1)` revert with `Blacklistable: account is blacklisted`;
`redeemHead` stays 0, Alice receives 0. A guardian `cancelRedeemRequest` unblocks it; the attacker
gets the 1 share back (F-1 patch refunds the owner) and resubmits at once; the next honest
redeemer (Bob) is blocked again.
Cost to attacker: gas only (~105k per request, the share is refunded on cancel; with a non-zero
fee the cost is the fee on 1 share, i.e. 1 wei). Impact: repeatable DoS of the only exit path,
needing a guardian transaction per occurrence; also hits honest users who get blacklisted while
queued. Fix: on fill, if the spUSDC `withdraw` to the recipient fails, skip or park the entry
(or pay to `request.owner`), and reject `recipient_` for which `USDC.isBlacklisted()` is true at
request time.

### A-2 Low: compromised SETTER at the admin bound MAX_VSR drains vault equity through honest fills
`setVSR` lines 285-292 (bound `maxVSR`, harness sets it to MAX_VSR = 100% APY).
On 1_000_000 USDC the over-credit is exactly 1_900.837678 USDC per day and 58_625.111031 USDC per
30 days (`test_compromised_setter_maxVsrOverCreditsPerDay`); at a 10% bound it is 261.157876 USDC
per day (7.28x less). The over-credit becomes real on the first honest fill: after 7 days at
MAX_VSR Alice is owed 1_013_381.981440 USDC, the planner pays everything the vault holds
(1_000_000 minus 2 wei), the vault's spUSDC drops to 1 share and 13_381.981442 USDC of her
request is unpayable forever (`test_compromised_setter_overCreditRealisedOnRedeem`). Recommend
`maxVSR` of at most ~10-15% APY, so a key compromise is bounded to ~0.03%/day.

### A-3 Low: compromised RISK_MANAGER during an honest pause can wipe every holder with `setChi(1)`
`setChi` lines 327-332: only `chi_ > 0 && chi_ < drip()`. `test_compromised_riskManager_setChiToOneWeiWipesHolders`:
Alice's 1_000_000 USDC position becomes 0 (`shares * 1 / 1e27`), `totalAssets() == 0`, and
nothing can raise chi back: 10 years at MAX_VSR afterwards gives chi 1024 (wei), still 0 assets.
The spUSDC backing (1_000_000 USDC) is untouched and takeable. Recommend a floor per call
(e.g. `chi_ >= chi * 0.9`), a two-step/timelocked loss realisation, or admin-only.
(Loss realisation is out of scope for the campaign; reported here only for the compromised-role bound.)

### A-4 Low: capacity hogging at zero cost when `redeemFee == 0`
Lines 432-445 escrow redeem shares inside `totalSupply`; capacity stays full until the planner
pays (I-7 touches this). `test_capacityHog_depositThenRedeemHoldsCapacityForFree`: attacker
deposits the entire free capacity (1_000_000 USDC) and requests a redeem in the same block; the
victim's 1_000 USDC deposit is queued; after the planner pays, the attacker is refunded in full
(fee 0, within 4 wei) and re-deposits, needing another planner cycle. Cost: time value only.
The fee is the only deterrent (1% at the cap). Recommend netting (TODO line 48) or a non-zero
launch fee.

### A-5 Info: instant-path jam for 2 wei
`requestDeposit` line 357 (`depositInstantly_ = pendingDepositSavingsShares == 0`).
With capacity exactly full, `requestDeposit(2 wei)` leaves 1 spUSDC share queued (1 wei would
round to 0 shares and jam nothing). From then on every deposit is queued even after redeems
free capacity (`test_jam_fullCapacityTwoWeiDepositBlocksInstantPath`: Alice redeems 10%, the
victim's 50_000 USDC is queued). The jam clears on the first planner call that has capacity:
the share converts to 1 USDC and 0 spPRIME shares (F-4 path) and the entry closes, the victim is
filled in the same call (`test_jam_clearedByOnePlannerCall`). Re-jamming with capacity > 0
requires the attacker to fill the free capacity with their own capital first
(`test_jam_rejamRequiresFillingFreeCapacity`). Attacker cost 2 wei + gas (1 wei comes back on
cancel). Not a bug beyond F-4/F-5; it does mean "instant deposits" are only reliable while the
planner runs regularly.

### A-6 Info: `recipient_ == address(vault)` burns the user's money and consumes capacity forever
`requestDeposit(x, address(vault))` mints to the vault: 100_000 USDC becomes ~99_026 phantom
shares inside `totalSupply`, never burnable (the redeem loop burns at most `request.shares`),
still there after 100 years, capacity reduced by that amount until the admin raises it
(`test_escrow_depositRecipientVaultPermanentlyConsumesCapacity`, `test_escrow_phantomSharesCannotBeBurnedByRedeemQueue`).
`requestRedeem(x, address(vault))` pays USDC to the vault where nothing counts it or can move it
(`test_escrow_redeemRecipientVaultStrandsUsdcInVault`). Attacker pays full principal, so it is
self-harm plus a capacity grief. Recommend `require(recipient_ != address(this))` in both.

### A-7 Info: ghost entries are gas griefing only, planner always makes progress when it can
Lines 643-648 / 680-685 (`continue` on zero entries, head updated at loop end).
Measured (`test_griefing_*`): attacker pays 75_122 gas per `requestDeposit(0)` ghost and
105_356 gas per `requestRedeem(1)` ghost (1% fee); the planner pays 493 / 518 gas per skipped
ghost with warm slots (one test tx), about 2_500 cold on mainnet, i.e. ~12_000 ghosts per 30M
block, and the head advances across calls (`maxRequests` 1001 then 1000 then 1 reaches the victim).
A 1-wei real redeem (fee 0) costs the planner 20_313 gas per fill (warm). Ghost deposits made
while the queue is empty are skipped instantly by the head reset (line 379). The head cannot
advance past ghosts while `availableCapacity()==0` / liquidity is 0, but nothing could be
processed then anyway (`test_griefing_headDoesNotAdvanceWithoutCapacityOrLiquidity`).
`setMinimums(1e6, 1e6)` blocks both ghost types (`test_griefing_ghostsBlockedByMinimums`).

### A-8 Info: external dependencies on spUSDC make deposits/cancels revert
`requestDeposit` reverts with `SparkVault/deposit-cap-exceeded` when spUSDC's cap is hit, nothing
is queued (`test_requestDeposit_revertsWhenSpUsdcCapHit`). `cancelDepositRequest` reverts with
`SparkVault/insufficient-liquidity` when spUSDC has no USDC even though the vault still holds the
spUSDC (`test_cancelDepositRequest_revertsWhenSpUsdcIlliquid`); distinct cause from F-2.

### A-9 Info: `drip()` overflow bound (comment on line 574 is right, but there is a brick)
chi is capped by the checked product `_rpow(vsr, dt) * chi < 2^256`, i.e. chi < 1.16e50 = 2^76.6
growth: 76 cumulative years at 100% APY work, 77 revert (`test_extremes_chiLimit_76YearsAtMaxVsrOk`,
`..._77YearsAtMaxVsrReverts`). uint192 truncation is unreachable (`test_extremes_chiCannotExceedUint192`).
With `totalSupply` near `uint128.max`, line 579 `totalSupply_ * nChi_` overflows earlier: 38 years
at MAX_VSR drips, 39 reverts with Panic(0x11), and because every entry point drips first
(including `setVSR`) the vault is bricked (`test_extremes_dripOverflowBoundAtMaxSupply`). Since
`shares_ <= totalSupply`, drip is always the first thing to overflow; no user-level product can
overflow before it. Unreachable with a sane `maxVSR`; recorded for completeness.
Also: a malicious ERC-1271 signer that writes state inside `isValidSignature` consumes all
forwarded gas before the staticcall fails (test gas 992M); the permit caller pays. Inherent.

## (b) Attacks that failed, as properties

| Property | Test |
|---|---|
| Instant deposit + redeem round trip never returns more than deposited; loss <= chi_s/RAY + chi_p/RAY + 4 wei (observed max 4 wei with chi up to ~2.1) over random amounts and ugly indexes | `testFuzz_roundTrip_userNeverProfits` |
| Queued deposit + cancel (up to 5 cycles) never refunds more than put in; loss <= 1 spUSDC share (observed max 2 wei) | `testFuzz_depositCancelCycle_userNeverProfits` |
| Three consecutive round trips: cumulative out <= in | `testFuzz_roundTrip_repeatedCyclesNeverProfit` |
| 1 wei deposit gives 0 spUSDC shares: ghost, no jam, `no-request` on cancel | `test_jam_oneWeiDepositGivesZeroSavingsSharesNoJam` |
| 1-share free capacity converts to 0 spUSDC shares: nothing processable, clears once capacity >= 3 | `test_jam_capacityOneShareRemainderIsNotProcessable` |
| spUSDC donations raise `availableLiquidAssets` by exactly `convertToAssets(donated)`, mint nothing, are takeable, leave `pendingDepositSavingsShares` and queued fills unchanged | `test_donation_spUsdcRaisesLiquidityAndIsTakeable`, `test_donation_doesNotAffectDepositQueueAccounting` |
| First-come wins the last capacity; the loser (and any later depositor) stays queued after a redeem frees capacity until the planner runs | `test_race_firstComeWins_loserQueuedEvenAfterRedeemFreesCapacity` |
| Capacity lowered below supply with an open queue: processing no-op, cancel and redeems work, `availableCapacity` floors at 0 | `test_race_capacityLoweredBelowSupplyWhileQueueOpen` |
| Front-running a deposit requires locking capital equal to the free capacity; victim queued, attacker exits via the queue at fee 0 | `test_race_frontRunJamQueuesVictim` |
| Permit: valid sig accepted (nonce 0 -> 1, Approval emitted); replay, expired (`deadline == now` accepted), wrong signer, wrong spender/value/nonce, zero owner all rejected with exact strings | `test_permit_validSignature`, `test_permit_replayRejected`, `test_permit_expiredRejected`, `test_permit_wrongSignerRejected` |
| ERC-1271: accepted on magic value (non-65-byte sig path), rejected on wrong value, 65-byte garbage, 64-byte return, EOA with short sig | `test_permit_erc1271Accepted`, `test_permit_erc1271Rejected` |
| ERC-1271 signer runs under staticcall: state writes make the check fail, nonce untouched | `test_reentrancy_erc1271SignerCannotMutateState` |
| `transferFrom`: max allowance not decremented; finite allowance decrements exactly; `insufficient-allowance`, `insufficient-balance`, `invalid-address` strings; self-transferFrom needs no allowance | `test_transferFrom_*` |
| Standard approve race exists (info) | `test_approve_raceStandard` |
| `uint128.max` USDC deposit, 1% fee redeem and payout all fit; payout <= deposit | `test_extremes_maxCapacityDepositAndRedeem` |
| 10 years at MAX_VSR: chi = 1024x within 1e-9, `totalAssets` and `requestRedeem` fine | `test_extremes_chiAfterTenYearsAtMaxVsr` |
| `shares * redeemFee` cannot overflow; fee on `uint128.max` shares = 3402823669209384634633746074317682115 | `test_extremes_feeMultiplicationCannotOverflow` |
| `take` by non-taker: `AccessControlUnauthorizedAccount`; `take` above balance: `SparkPrimeVault/insufficient-unencumbered-shares` | `test_take_notTaker`, `test_take_moreThanBalance` |
| `setChi` unpaused: `SparkPrimeVault/not-paused`; `unpause` by guardian or UNPAUSER_ROLE: unauthorized (admin only); `upgradeToAndCall` by non-admin: unauthorized, by admin works | `test_setChi_notPaused`, `test_unpause_guardianCannot`, `test_upgradeToAndCall_notAdmin` |
| REBALANCER / RISK_MANAGER / SETTER cannot grant roles, set capacity, bounds, max fee or take | `test_hotWalletRoles_cannotEscalate` |
| No callback ever reaches a recipient contract on instant mint, queued fill, redeem fill or cancel | `test_reentrancy_noCallbackToRecipient` |
| RISK_MANAGER fee capped at `maxRedeemFee` (`fee-too-high` at 1% + 1 wei); worst case 1% on every exit (990_000 of 1_000_000); lowering the max does not reset the current fee | `test_compromised_riskManager_maxFeeOnEveryExit` |
| REBALANCER with arbitrary `maxShares/maxRequests` order and 1-share starvation: every payout = `convertToAssets(shares)`, every mint = `convertToShares(assets)` (within one floor per partial fill), rebalancer balances unchanged, starved users can cancel | `test_compromised_rebalancer_cannotExtractValue` |
| 1-share partial fills cost the vault exactly 1 spUSDC share each (R9), bounded by gas (~1_500 fills per block), dust | `test_compromised_rebalancer_partialFillsLeakAtMostOneSpUsdcShareEach` |
| Random 24-step op sequences (deposits, redeems, cancels, partial processing, capacity changes, warps): `pendingDepositSavingsShares == sum(open deposit entries)`, `pendingRedeemShares == sum(open redeem entries) == balanceOf(vault)`, every entry before `depositHead`/`redeemHead` is closed, heads <= lengths | `testFuzz_queueInvariants_randomOps` |
| The head reset on the instant path (line 379) happens only when pending == 0, which (by the sum invariant) means every earlier entry is closed; new deposits while an entry is open are queued and do not touch the head | `test_requestDeposit_headResetSkipsOnlyClosedEntries` |
| Ghosts created while the queue is empty are skipped by the instant path immediately | `test_griefing_ghostDepositsWhileQueueEmptyAreSkippedInstantly` |

## (c) Unsettled items and recommendations

1. A-1 needs a design decision: skip/park failed payouts vs. pay `request.owner` vs. pre-check
   `isBlacklisted`. The harness mocks USDC without a blacklist; the test simulates it with
   `vm.mockCallRevert` on `transfer(recipient)`. Worth a fork test against real USDC.
2. `maxVSR` and `maxRedeemFee` launch values decide the hot-wallet blast radius (A-2, A-4):
   suggest `maxVSR` <= 10-15% APY and a non-zero `redeemFee` at launch.
3. `setChi` has no floor (A-3). Even if loss realisation is out of scope, the role bound is not.
4. Block `recipient_ == address(this)` in `requestDeposit`, `requestRedeem` and the cancels (A-6, I-6).
5. The instant path depends on a planner cadence: any 2-wei remainder (A-5), any legitimately
   queued user, or any escrowed redeem (A-4) turns deposits async until `processDepositQueue`
   runs. Netting deposits against redeems (TODO line 48) removes most of this.
6. Gas numbers in A-7 are warm-slot numbers from a single test transaction; add ~2_000 per
   cold SLOAD for mainnet estimates.
7. Not tested: real-USDC behaviour on a fork (blacklist, A-1).
