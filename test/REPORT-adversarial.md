# spPRIME adversarial campaign

## Round 3 (ff828d2)

Worker: adversarial. File: `test/Adversarial.t.sol` (contract `AdversarialTest is LocalTestBase`),
87 tests, all passing at 1000 and 5000 fuzz runs. Line numbers refer to `src/SparkPrimeVault.sol`
at upstream `refactor/more-simplifying` @ ff828d2. Every round-1 and round-2 property is
re-pinned; round-2 attacks that upstream fixed are kept as regression tests under new names.

### Fixed upstream (regression tests)

| Round-2 finding | Fix at ff828d2 | Regression test |
|---|---|---|
| R2-1 Critical: anyone repoints any queued request | `msg.sender == request_.owner` plus open entry in all three `update*Recipient` (lines 416-425, 465-477, 537-546) | `test_updateRecipient_strangerCannotRepointRedeem_victimPaid`, `..._strangerCannotRepointDeposit_victimMinted`, `..._strangerCannotRepointCancelled_victimRefunded`, `..._ownerRepointsAndCancelsSafely`, `..._onlyOwnerWritesCountAtFill`, `..._filledEntryIsHarmless` |
| R2-2 High: zero-cost queue block / strand / dead capacity on victims | same authorization | `test_updateRecipient_strangerCannotBlacklistBlockQueue_ownerStillCan`, `..._onlyOwnerCanStrandOwnRedeemInVault`, `..._onlyOwnerCanBurnOwnDepositIntoDeadCapacity` |
| R2-3 (part): `loss == totalAssets` sets `chi = 0` and bricks redeems; bounds were panics | `require(loss_ > 0 && loss_ < totalAssets_)` line 376, `totalSupply_ != 0` line 380 | `test_compromised_riskManager_fullLossRejected_nearWipeStillOperates`, `test_compromised_riskManager_realizeLossBoundsAreChecks` |
| R2-4 Medium: whale cancel at the head reverts the planner | budget is `spUSDC.maxRedeem(vault)` line 784 | `test_cancelQueue_whaleCancelStarvesQueueWhenSpUsdcShort` (now: no revert, whale drip-fed) |

Notes on the fixes. Roles do not bypass the owner check (guardian, rebalancer, admin all get
`not-authorized`); closed entries are `no-request` for everyone, owner included; the owner can
still repoint the remainder between partial fills. In `realizeLoss` the `no-shares` branch is
unreachable (with `totalSupply == 0`, `totalAssets` is 0 and `invalid-loss` fires first); it is
reachable in `realizeGain`. In the cancel queue the small entry behind a whale still waits in
FIFO order: with 1_000 USDC of spUSDC liquidity the 10_000_000 USDC whale is paid ~1_000 per
planner call and the 100 USDC entry behind it gets nothing until the whale is complete; three
1_000 USDC top-ups pay the whale 4_000 total, the victim still 0.

### Persisting

- C-3 / R2-3 (Medium, trust model): `realizeLoss(totalAssets - 1)` still wipes every holder
  (`chi = RAY / totalSupply`, alice's 1_000_000 USDC is worth 0, 1_023 wei after ten years at
  MAX_VSR), no floor below the full loss (`test_compromised_riskManager_realizeLossWipesHolders`).
  The vault keeps operating afterwards (no panics; redeems pay 0; the next depositor is minted at
  the dust chi) and `realizeGain` is now the only repair path.
- Round-1 self-harm with `recipient == address(this)` persists for owners (strand USDC, phantom
  shares): still not rejected anywhere.
- Round-1 A-1 owner-side blacklist block persists: an owner who repoints their own redeem to a
  blacklisted address blocks everyone behind them until the guardian cancels; the owner loses the
  fee (`test_updateRecipient_strangerCannotBlacklistBlockQueue_ownerStillCan`, second half).
- R2-5 dust cancel bloat, R2-6 head-walk gas, R2-7 two-step cancel, R2-8 SETTER exposure:
  unchanged, same tests, same numbers.

### R3-1 High: `realizeGain` can be sandwiched by any user through the instant deposit path
`realizeGain` `src/SparkPrimeVault.sol:306` sets `chi = (totalAssets + gain) * RAY / totalSupply`
over whoever holds shares in that block. `_requestDeposit` lines 732-735 fills instantly, with no
entry delay and no entry fee, whenever nobody is queued. So the admin's honest `realizeGain`
transaction is a public, front-runnable transfer to the current share set, and the attacker only
has to be in it for one block.

`test_BUG_realizeGain_sandwichExtractsFromHolders` (1_000_000 USDC of honest holders, admin
broadcasts `realizeGain(50_000e6)` with the gain's backing delivered as spUSDC, fee 0):
- attacker front-runs `requestDeposit(1_000_000e6)` instantly, now holds exactly alice's share
  count; gain lands; attacker's `assetsOf` = 1_024_999.999998 USDC;
- attacker `requestRedeem` all, the planner pays 1_024_999.999998 USDC from the vault's spUSDC:
  profit 24_999.999998 USDC, one block of capital at risk, no role, no fee;
- alice ends at 1_024_999.999998 instead of 1_049_999.999998: loss 25_000.000000 USDC, exactly
  the attacker's take; what remains in the vault exactly backs her.

Variants:
- fee 1% (`test_BUG_realizeGain_sandwichSurvivesOnePercentFee`): the fee is 1% of the exit,
  10_250.000001 USDC, payout 1_014_749.999997, profit 14_749.999997; alice still loses 25_000.
- capital scales with TVL (`..._sandwichTakeScalesWithCapital_1MvsTVL10M`, `..._10MvsTVL10M`):
  take = gain * c / (TVL + c). 1M against 10M TVL takes 4_545.454544 of 50_000; 10M against 10M
  takes 24_999.999998. Capital is only at risk for the planner's turnaround.
- queued variant (`test_realizeGain_queuedDepositFilledAfterGainGetsNoProfit`): if capacity is
  full the attacker's deposit is queued and filled after the gain at the new chi: 999_999.999998
  USDC back, no profit, alice receives the full gain (1_049_999.999997).
- pause first (`test_realizeGain_pauseBeforeGainKillsSandwich`): guardian pauses, the front-run
  reverts `SparkPrimeVault/paused`, `realizeGain` works while paused, admin unpauses; alice gets
  1_049_999.999997; a deposit after the unpause is priced at the new chi and earns nothing.

Severity: High. Any user, one block, profit linear in capital, loss borne by honest holders. The
only mitigation in the code is the pause (deposits closed) or a full deposit queue; a non-zero fee
reduces the take by `fee * (c + take)`. Fixes, any one of them: require `paused` in `realizeGain`
(same as `realizeLoss`, admin then unpauses after); or stream the gain through `vsr`/`drip` over
time instead of a step (the same sandwich fails against continuous accrual because the attacker's
one-block exposure earns one block of rate); or keep the step but gate the instant deposit path
behind a minimum holding time. Related, legitimate (b): escrowed redeemers (shares parked in the
vault, still in `totalSupply`) receive the gain at fill time, the cancelled-deposit queue does
not (`test_realizeGain_escrowedRedeemersReceiveGain_cancelledDepositsDoNot`: alice's queued
redeem is paid 1_049_999.999997, bob's cancelled deposit is refunded 100_000 flat). Phantom shares
sitting on `address(vault)` take their pro-rata share of every gain too.

### R3-2 Info (out of trust model): admin blast radius of `realizeGain`
- A gain with no backing behind it is an over-credit, paid first come first served
  (`test_compromised_admin_realizeGainOverCreditIsInsolvency`: `realizeGain(1_000_000e6)` on two
  1M holders; alice redeems 1_500_000, bob 500_000, 1_000_000 unpayable).
- A gain of 114_681_085_459_449_903_921_529_244_645_760_026 units (~1.15e29 USDC on a 1M
  supply, i.e. `chi > 2^256 / RAY`) is accepted, and one second later `_rpow * chi` in `drip()`
  line 649 overflows: deposit, redeem, setVSR, realizeGain, realizeLoss all revert; `pause`,
  `unpause` and `take` still work; only an upgrade repairs it
  (`test_compromised_admin_realizeGainCanBrickViaDripOverflow`). NEWSURFACE owns the exact
  `uint192` and overflow thresholds; a `require(chi_ <= some bound)` closes both.

### Properties held (round 3 additions)
| Property | Test |
|---|---|
| Gain/loss pairs in one block, either order, never ratchet `chi` above the start; drift <= 2 units per pair; the holder's round trip never returns more than deposited | `testFuzz_realizeGainLoss_noRatchet` (5000 runs) |
| `realizeGain`: admin only, `invalid-gain` on 0, `no-shares` on empty supply, works while paused, drips before applying, emits the exact post-gain `chi` | `test_realizeGain_accessAndBounds` |
| Random 24-step sequences where only owners repoint their own open entries (strangers and closed entries revert): all queue invariants hold | `testFuzz_queueInvariants_randomOps` (5000 runs) |
| Everything in the round-2 table below | same tests |

### Unsettled
1. R3-1 is the one item that matters this round: decide whether `realizeGain` is a step under
   pause or a streamed rate; today it is a public transfer to whoever is holding at that block.
2. C-3 floor on `realizeLoss` (a per-call drawdown cap) is still open; the brick is gone, the
   wipe is not.
3. `recipient == address(this)` still accepted everywhere (self-harm only now).
4. Launch parameters unchanged from round 2: `minDeposit >= 1e6`, `minRedeem >= 1`.
5. Not tested: real-USDC behaviour on a fork (blacklist cases use `vm.mockCallRevert`).

---

## Round 2 (0bc9288), historical

Worker: adversarial. File: `test/Adversarial.t.sol` (contract `AdversarialTest is LocalTestBase`),
76 tests, all passing (`forge test --match-path test/Adversarial.t.sol ...`, fuzz at 1000 and
5000 runs). Line numbers refer to `src/SparkPrimeVault.sol` on `campaign-v2/adversarial` after
merging `review/poc-tests-v2` (upstream `refactor/more-simplifying` @ 0bc9288: `pause()` back on
GUARDIAN_ROLE, `realizeLoss` via `totalAssets()`). Round-1 attacks were all ported and re-pinned;
only what is new or changed is written up in (a). Round-1 numbers that did not move (A-2 SETTER
over-credit, A-4 capacity hog, A-7 planner ghost skips, A-8, A-9) are re-asserted by the same tests.

Counts: new findings 1 Critical, 1 High, 2 Medium, 1 Low, 3 Info. Everything else held as a property.

## (a) Successful or partially successful attacks

### R2-1 Critical: anyone can repoint any queued request to themselves and the honest planner pays them
`updateDepositRecipient` line 423, `updateCancelledDepositRecipient` line 467,
`updateRedeemRecipient` line 534: the only check is `recipient_ != address(0)`. The fill paths read
`request_.recipient` from storage at fill time (lines 729, 765, 805).

Scenarios (all attacker cost: one ~30k-gas call, no capital, no role):
- Front-run the planner (`test_BUG_updateRecipient_frontRunPlannerStealsRedeemPayout`): alice
  queues a 1_000_000 USDC redeem; mallory sees `processRedeemQueue` in the mempool and calls
  `updateRedeemRecipient(id, mallory)` in the same block; the planner pays mallory 1_009_687.768242
  USDC, alice's shares are burned, she gets 0.
- Deposit queue (`test_BUG_updateRecipient_stealsQueuedDepositShares`): victim's queued 1_000_000
  USDC is minted to mallory on fill; mallory redeems at once at fee 0 and walks away with
  999_999.999998 USDC.
- Cancel queue (`test_BUG_updateRecipient_stealsCancelledDepositRefund`): victim cancels to
  themselves, mallory repoints the cancelled entry, planner's `spUSDC.redeem` pays mallory.
- No safe exit (`test_BUG_updateRecipient_victimHasNoSafeExitFromDepositQueue`): victim notices the
  repoint, cancels to a fresh address; mallory repoints the cancelled entry too. Whichever queue the
  money is in, the last writer before the planner's call gets it. The victim's only defence is to
  win a same-block race on every planner call, forever.
- Last write wins, including across partial fills
  (`test_updateRecipient_raceLastWriteWinsAtFill`): a half fill pays the current recipient, the
  remainder follows the next write. The owner has no priority over a stranger.

Impact: every queued deposit, cancel and redeem is stealable by anyone. Fix: `require(msg.sender ==
request.owner)` (or owner-or-guardian) in all three, and reject `recipient_ == address(this)`.

### R2-2 High: the same three functions turn round-1 self-harm griefs into attacks on victims
- Queue block for free (`test_BUG_updateRecipient_blacklistBlocksRedeemQueueAtZeroCost`): repoint
  alice's redeem to a USDC-blacklisted address; every `processRedeemQueue` reverts
  (`Blacklistable: account is blacklisted`), bob behind her is stuck. Round-1 A-1 / C-2 needed the
  attacker's own share; now it needs nothing. Alice repoints back, the attacker repoints again
  before each planner call. The guardian ends it with `cancelRedeemRequest`, which costs alice the
  1% fee she already paid (F-8): 9_904.051842 shares, about 10_000 USDC, inflicted on the victim at
  zero cost to the attacker.
- Strand a victim's redeem in the vault (`test_BUG_updateRecipient_strandsVictimRedeemInVault`):
  repoint to `address(vault)`; the fill sends 100_968.776824 USDC into the contract where nothing
  counts or moves it (`take` moves spUSDC only). Round-1 A-6 / C-6 was self-harm; it is now
  third-party destruction of funds.
- Burn a victim's deposit into dead capacity
  (`test_BUG_updateRecipient_burnsVictimDepositIntoDeadCapacity`): repoint a queued deposit to
  `address(vault)`; the fill mints 99_040.518410 phantom shares to the vault that no path can burn
  (escrow accounting ignores them, `pendingRedeemShares == 0`), still there after 100 years, and
  they consume capacity permanently.
Fix: same authorization as R2-1 plus `recipient_ != address(this)` in requests and updates.

### R2-3 Medium (trust model): compromised RISK_MANAGER during a pause can zero chi and permanently disable redeems
`realizeLoss` line 357: `chi = (totalAssets() - loss) * RAY / totalSupply`, no floor.
- `loss = totalAssets - 1` leaves `chi = RAY / totalSupply` (1e15 on 1M USDC): every holder is at
  0 assets; after 10 years at MAX_VSR alice's 1_000_000 USDC is worth 1_023 wei
  (`test_compromised_riskManager_realizeLossWipesHolders`).
- `loss = totalAssets` sets `chi == 0` exactly (`test_compromised_riskManager_fullLossBricksVault`).
  Effects, all permanent (no chi setter; `0 * rpow = 0`; `realizeLoss(1)` now underflows):
  `convertToShares` panics (0x12), so `processRedeemQueue` can never run again; deposits do not
  revert but can never be filled (the budget `spUSDC.convertToShares(convertToAssets(capacity))`
  is 0), so they queue until cancelled; cancels still refund; `take` still works. Only an upgrade
  repairs it.
- Bounds are arithmetic only: `totalSupply == 0` and `loss > totalAssets` both revert with
  Panic(0x11), not a designed check (`test_compromised_riskManager_realizeLossBoundsArePanics`).
Round-1 A-3 / C-3 stands with the formula changed; recommend a per-call floor set by the admin,
or admin-only.

### R2-4 Medium: cancel-queue FIFO starvation by a whale when spUSDC is short
`_processCancelledDepositQueue` line 744: budget is `spUSDC.balanceOf(vault)`, not spUSDC's
liquidity; line 765 `spUSDC.redeem` reverts `SparkVault/insufficient-liquidity` at the head.
`test_cancelQueue_whaleCancelStarvesQueueWhenSpUsdcShort`: a 10_000_000 USDC cancel at the head
with 1_000 USDC of liquidity in spUSDC makes `processCancelledDepositQueue(max, n)` revert; the
100 USDC cancel behind it gets nothing. The planner can drip-feed the whale with partial fills
(`maxSavingsShares_`), but the small entry stays behind until liquidity covers the whole whale.
Cost to a griefer: deposit then cancel; capital is returned over time, no fee. NEWSURFACE owns the
revert itself; the starvation is recorded here. Fix: clamp the per-call budget to spUSDC
liquidity and skip/park entries that exceed it.

### R2-5 Low: cancel-queue bloat with dust deposits
`test_cancelQueue_dustCancelsGasPerEntry`: each `requestDeposit(2 wei)` + `cancelDepositRequest`
costs the attacker 250_123 gas and creates a real cancelled entry (1 spUSDC share) that costs the
planner 17_840 gas (warm; ~20k cold) to settle via `spUSDC.redeem`, about 1_681 per 30M block.
500 dust cancels push a victim's refund behind one full planner call. The attacker gets 1 wei back
per 2 wei in. `minDeposit >= 1e6` removes it (the cycle then costs 1 USDC of capital per entry,
still refundable). No ghosts are possible in this queue (cancel requires `shares != 0`).

### R2-6 Info: deposit head walk is a one-time gas charge, not a block-limit DoS
Lines 393-398 (walk in `_requestDeposit`), 459 and 526 (walks in the cancels).
- Ghosts behind an open head entry are not walked until that entry closes. If the planner closes
  it exactly (budget or `maxRequests` ends there, line 738 `depositHead = i_`), the head lands on
  the first ghost and the next depositor pays the whole walk
  (`test_griefing_headWalkChargedToNextDepositorAfterPlannerClosesHead`): 798 gas per ghost warm,
  ~2_800 cold; 1_000 ghosts add ~0.8M (warm) to a 142_728-gas deposit. Pushing one
  `requestDeposit` over 30M needs ~10_721 ghosts, i.e. ~804M gas (~27 full blocks) of attacker
  spend, placed in advance behind an open entry; it is paid once, by whoever deposits next, and
  the planner can pre-walk them at 493 gas each. A wallet that estimated gas before the ghosts
  landed reverts out of gas once (~50 ghosts exceed a 100k buffer).
- Same-block front-running cannot inflate the walk: when the head is already on zero entries
  each new ghost walks the ones before it, so the attacker pays incrementally and the victim pays
  one step (`test_griefing_ghostsWalkThemselvesWhenHeadIsOnZeroEntries`: 133_784 gas behind 300
  ghosts).
- An owner cancelling the entry at the head pays the walk over every ghost behind it, in either
  queue (`test_griefing_ownerCancelAtHeadPaysWalkOverGhosts`: 994_119 gas deposit-side, 927_578
  redeem-side, for 1_000 ghosts, warm).
- `requestRedeem(0)` is a free ghost: no shares, no fee, 89_139 gas, 518 gas for the planner to
  skip, cannot be cancelled (`test_griefing_zeroRedeemGhostsAreFree`). `minRedeem >= 1` blocks it.
Re-confirmed from round 1: a 1-share dust entry at the head still queues everybody
(`test_jam_fullCapacityTwoWeiDepositBlocksInstantPath`), one planner call clears it
(`test_jam_clearedByOnePlannerCall`), re-jamming needs the free capacity filled first.

### R2-7 Info: cancel is now a two-step, planner-dependent refund
`cancelDepositRequest` line 430 moves the entry to `cancelledDepositQueue`; the refund waits for
REBALANCER. Consequences recorded in ported tests: a starved depositor can cancel but still cannot
get money without the planner (`test_compromised_rebalancer_cannotExtractValue`: partial
settlements pay exactly `spUSDC.redeem(shares)`, at most one floor each); the caller-chosen
`recipient_` is back for the guardian (F-1, CANCEL-FEES owns); no callback reaches a contract
recipient on settlement (`test_reentrancy_noCallbackToRecipient`).

### R2-8 Info: pause is GUARDIAN again
`pause` line 362. Hot-wallet roles cannot pause (`test_pause_hotWalletRolesCannot`); unpause stays
admin-only (`test_unpause_guardianCannot`). The round-1 exposure numbers for a compromised SETTER
are unchanged: 1_900.837678 USDC per day on 1M at MAX_VSR, 261.157876 at a 10% bound
(`test_compromised_setter_maxVsrOverCreditsPerDay`), realised on the first honest fill
(`test_compromised_setter_overCreditRealisedOnRedeem`: 13_381.981442 USDC unpayable after 7 days).

## (b) Attacks that failed, as properties

| Property | Test |
|---|---|
| Repointing a filled (deleted) entry writes a recipient onto a 0-share slot: planner skips it, cancel says `no-request`, head walk ignores it, out-of-range ids revert, zero recipient rejected; later users unaffected | `test_updateRecipient_filledEntryIsHarmless` |
| Random 24-step sequences including cancel settlement and arbitrary third-party repoints of all three queues: `pendingDepositSavingsShares`, `pendingCancelledDepositSavingsShares`, `pendingRedeemShares` each equal the sum of open entries; escrow equals pending redeems; vault spUSDC >= queued deposit + cancelled claims; every entry before each head is closed | `testFuzz_queueInvariants_randomOps` (5000 runs) |
| Round trips, deposit/cancel/settle cycles and repeated cycles never return more than deposited; loss within the floor bound | `testFuzz_roundTrip_*`, `testFuzz_depositCancelCycle_userNeverProfits` (5000 runs) |
| 1 wei deposit is a 0-share ghost, no jam; capacity of 1 share is unprocessable, not a jam | `test_jam_oneWeiDepositGivesZeroSavingsSharesNoJam`, `test_jam_capacityOneShareRemainderIsNotProcessable` |
| First-come-first-served, loser stays queued after capacity frees; capacity lowered below supply breaks nothing; front-run jam costs capital equal to free capacity | `test_race_*` |
| Permit, ERC-1271, transferFrom, approve race: unchanged from round 1 | `test_permit_*`, `test_transferFrom_*`, `test_approve_raceStandard`, `test_reentrancy_erc1271SignerCannotMutateState` |
| Extremes: `uint128.max` deposit and 1% redeem fit; 10 years at MAX_VSR; chi caps at 76 years, drip overflow bricks at 38 years with max supply; uint192 unreachable; fee product cannot overflow | `test_extremes_*` |
| Planner ghost skips: 493 / 518 gas warm per skipped deposit / redeem ghost, 21_075 per 1-wei fill, head advances across calls, head cannot move without capacity or liquidity | `test_griefing_ghost*GasPerSkip`, `test_griefing_oneWeiRedeemFillsGas`, `test_griefing_headDoesNotAdvanceWithoutCapacityOrLiquidity` |
| `minDeposit` (assets) and `minRedeem` (shares) block every ghost type including `requestRedeem(0)` | `test_griefing_ghostsBlockedByMinimums` |
| Donated spUSDC is liquidity and takeable, does not touch queue accounting | `test_donation_*` |
| `recipient == vault` on the user's own request: phantom shares never burnable, USDC stranded | `test_escrow_*` |
| `take` by non-taker rejected; above balance `SparkPrimeVault/insufficient-shares`; `realizeLoss` unpaused `not-paused`; upgrade admin-only; hot wallets cannot escalate, pause or unpause | `test_take_*`, `test_realizeLoss_notPaused`, `test_upgradeToAndCall_notAdmin`, `test_hotWalletRoles_cannotEscalate`, `test_pause_hotWalletRolesCannot` |
| REBALANCER cannot extract value in any order or chunking across all three queues; 1-share partial fills leak at most 1 spUSDC share each | `test_compromised_rebalancer_*` |
| RISK_MANAGER fee capped at `maxRedeemFee`; lowering the max does not reset the live fee | `test_compromised_riskManager_maxFeeOnEveryExit` |
| Instant path fills only when the head reaches the new request; it never skips an open entry | `test_requestDeposit_headResetSkipsOnlyClosedEntries`, `test_griefing_ghostDepositsWhileQueueEmptyAreSkippedInstantly` |
| spUSDC cap hit makes `requestDeposit` revert outright | `test_requestDeposit_revertsWhenSpUsdcCapHit` |
| Blacklisted recipient on the attacker's own redeem still blocks the queue (round-1 A-1), guardian cancel to the owner unblocks | `test_BUG_blacklistedRecipientBlocksRedeemQueue` |

## (c) Unsettled items and recommendations

1. R2-1 / R2-2 are the only thing that matters this round: add owner (or owner-or-guardian)
   authorization to all three `update*Recipient` functions and reject `address(this)` as a
   recipient everywhere. Until then no queued request is safe from anyone.
2. `realizeLoss` (R2-3): decide a floor. `loss == totalAssets` is reachable by a hot wallet and
   leaves redeems unprocessable forever; a `require(chi_ > 0)` plus a per-call drawdown cap set by
   the admin bounds it.
3. Cancel queue (R2-4, R2-5): clamp the budget to spUSDC liquidity, skip entries that exceed it,
   and launch with `minDeposit >= 1e6`.
4. Ghost minimums: `minDeposit >= 1e6` and `minRedeem >= 1` remove every ghost primitive used in
   R2-6 at no cost to honest users.
5. Gas numbers are warm-slot numbers from single test transactions; add ~2_000 per cold SLOAD
   for mainnet estimates.
6. Not tested: real-USDC behaviour on a fork (blacklist cases use `vm.mockCallRevert`).
