# spPRIME adversarial campaign

## Round 5 (`master` @ `0ebb452`)

Worker: adversarial. File: `test/ai/Adversarial.t.sol`, three contracts: `AdversarialTest` (87),
`AdversarialRound4Test` (14), new `AdversarialRound5Test` (19); 120 tests, all passing at 1000
fuzz runs. No deliberately failing test: every open finding is a passing proof of the behaviour.
Line numbers refer to `src/SparkPrimeVault.sol` @ 0ebb452. Port notes: `realizeGain`/`realizeLoss`
tests rewritten against `adjustTotalAssets` (paused-only); the `vm.mockCallRevert` blacklist is
replaced by the harness's real `_blacklist` (the vault consults `isBlacklisted` at :1052);
`test_BUG_realizeGain_sandwichUnchangedWithoutCancel` deleted (superseded by the governance-flow
test below); guardian-cancel and `UNPAUSER_ROLE` cases rewritten as owner-only / admin-only pins;
`requestDeposit(x, vault)` cases became `test_fixed_` since :395 rejects them.

### (a) Findings

#### R5-1 High (R3-1, changed not fixed): a deposit between "payload public" and "pause" captures the gain
`adjustTotalAssets` :278-295 requires `paused` (:279), but the pause is a separate GUARDIAN tx and
the spell payload is public before it; `requestDeposit` :389-417 fills instantly (:414-415) at the
old chi. Real flow, 1M TVL (alice), 1M attacker, 50_000 gain:
- fee 0: attacker out 1_024_999_999_998, profit 24_999_999_998; alice loses 25_000_000_000
  (`test_BUG_R3_1_adjustTotalAssets_depositBeforePauseCapturesGain_0pctFee`).
- fee 1%: out 1_014_749_999_997, profit 14_749_999_997; alice still loses 25_000_000_000
  (`..._1pctFee`). Take = gain * c / (TVL + c): 4_545_454_544 for 1M vs 10M TVL
  (`..._takeScalesWithCapital_1MvsTVL10M`, `..._10MvsTVL10M`).
- Four orders from one snapshot (`test_BUG_R3_1_governanceFlow_fourOrders_exactProfit`):
  (i) deposit -> pause -> adjust -> unpause -> redeem: 24_999_999_998 / 14_749_999_997;
  (ii) pause BEFORE the deposit: deposit reverts `paused`, alice gets 1_049_999_999_997
  (`test_fixed_R3_1_pauseBeforeDepositKillsSandwich`);
  (iii) capacity pinned to totalSupply before the payload: deposit queued, filled after the gain at
  the new chi, attacker <= 1_000_000e6 (`test_adjustTotalAssets_queuedDepositFilledAfterGainGetsNoProfit`);
  (iv) rebalancer never pays: alice is already diluted on paper (assetsOf attacker 1_024_999_999_998).
  What kills it: pause (or capacity pin) landing before any deposit can see the payload, i.e. the
  guardian must pause at payload deployment, not at execution. Escrowed redeemers also receive the
  gain (`test_adjustTotalAssets_escrowedRedeemersReceiveGain_cancelledDepositsDoNot`: 1_049_999_999_997).

#### R5-2 Medium (C-3, open): no loss floor
`adjustTotalAssets(-(totalAssets - 1))` passes :286 and sets `chi = RAY / totalSupply` (:289):
alice's 1_000_000 USDC -> `assetsOf == 0`, `totalAssets == 0`; only `-totalAssets` and `0` are
rejected (`loss-too-high`, `delta-total-assets-zero`); 10 years at MAX_VSR recover < 2_000 wei
(`test_BUG_C3_adjustTotalAssets_nearFullLossWipesHolders`). The vault keeps operating afterwards
(`test_adjustTotalAssets_nearWipeStillOperates`). A gain at `totalSupply == 0` panics with
division by zero at :289 (`test_adjustTotalAssets_boundsAreChecks_gainAtZeroSupplyPanics`).

#### R5-3 Medium (G-1/G-2, open): the uint192 bound is 5.4e7 times above the real overflow bound
:292 allows chi up to 6.27e57; `drip` :637 computes `_rpow(vsr, dt) * chi` checked, so the largest
surviving chi is exactly `type(uint256).max / RAY` = 115792089237316195423570985008687907508017464175173
(1.157e50): one second later `drip`, `nowChi`, `totalAssets`, `requestDeposit`, `requestRedeem`,
`processPendingRedeems`, `setVSR` and `adjustTotalAssets` itself (:282 drips first) all panic 0x11;
only `transfer`, `approve`, `pause`, `take` and `claim` work. Over 1M TVL the bricking gain is
1.1468e35 USDC-wei, one chi-step (`+totalSupply` assets) above the safe one. Only an upgrade repairs
(`test_BUG_G1_adjustTotalAssets_chiAboveDripBoundBricks_exactThreshold`).

#### R5-4 Medium (F-2, open): queue backing is not ring-fenced; the rebalancer picks who is paid
After `take` leaves only bob's cancelled-deposit backing (bQ shares), `availableLiquidAssets` :789
still counts it and `processPendingRedeems` pays alice 999_999_998 from it; bob's refund is then
unpayable (`pendingCancelledDepositSavingsShares` stays bQ). The reverse order refunds bob
999_999_999 and leaves alice waiting (`test_BUG_F2_redeemsCanConsumeCancellationBacking_afterTake`).
`takeAll` then the three queues: deposits still fill (unbacked mint :852), redeems and
cancellations are no-ops, nothing lost once backing returns (`test_taker_takeAll_thenThreeQueues`).
`take` works while paused (`test_pause_matrix`).

#### R5-5 Low (V2-13, open, cancellation variant new): vault / spUSDC as recipients strand USDC with no claim path
`_canReceiveAsset` only checks the blacklist (:425, :452, :1052), so the vault and spUSDC are
accepted. Redeem to vault: 99_999_999_998 USDC in the vault, `claimableAssets[vault] == 0`,
`claim` says `nothing-to-claim`, `take` cannot move it
(`test_BUG_V2_13_redeemRecipientVaultStrandsUsdcInVault`). Cancellation to vault / spUSDC:
`spUSDC.redeem(.., vault, vault)` :939 strands 99_999_999 and the spUSDC leg nets to 0 in spUSDC's
balance while spUSDC's totalAssets drops by both (`test_BUG_V2_13_cancelRecipientVaultOrSpUsdc_strandedNotClaimable`).
Owner's own choice only (`not-authorized` for everyone else).

#### R5-6 Low (F-4, open): zero-share mints at a high chi
`convertToShares` :797 floors; after a gain to chi = 2e33, a 1 USDC deposit mints 0 shares (:852),
the entry is deleted (:858) and the USDC becomes vault equity; 3 USDC mints 1 share worth 2 USDC,
1 USDC lost (`test_BUG_F4_zeroShareMint_exactThreshold`). Threshold: deposit < chi / RAY wei.

#### R5-7 Info: the cancellation queue is a fee-free spUSDC-rate position without capacity
Refunds are `spUSDC.redeem` at the live spUSDC index (:939): a 1_000 USDC deposit queued
(capacity full), cancelled, settled a year later at 10% spUSDC VSR returns 1_099_999_998, no fee,
no spPRIME shares ever held. Not a spPRIME holder loss (the yield is spUSDC's on queue backing
that would otherwise be vault equity). spPRIME itself has no fee-free exit: a transfer to a fresh
address pays the same 1% at :460 (`test_extremes_noFeeFreeExit_cancelQueueEarnsSpUsdcRate`).

#### R5-8 Info (USDC risk): if Circle sanctions the vault itself
Deposits revert in USDC; payouts to clean recipients still work (spUSDC -> recipient); but a
recipient blacklisted mid-flight makes the fallback `withdraw(.., vault, vault)` :955 revert and
blocks that queue (R4-A re-emerges), and `claim` is dead. The owner's repoint to a clean address
unblocks it (`test_blacklist_vaultItselfSanctioned_fallbackBlocksQueue`).

#### R5-9 Info: griefing numbers on 0ebb452
- Capacity-0 head freeze (`remaining_ == 0` at :837 skips the walk): ghosts placed while capacity
  is full are never walked, by anyone, until capacity returns; the first real depositor then pays
  548 gas per ghost warm (310_700 for 300), 11_773 ghosts to push one deposit past 30M at a cold
  estimate; attacker pays 83_233 per ghost (`test_griefing_capacityZeroFreezesHead_nextDepositorPaysWalk`).
  `processPendingDeposits(1, N)` clears them once capacity exists.
- Owner cancel at the head is O(1) now (117_536 gas with 1000 ghosts behind, :419-444 has no
  loop); the next depositor walks the 1001 closed entries for 643_666
  (`test_griefing_ownerCancelAtHeadIsO1_nextDepositorWalksGhosts`).
- Planner skips: 480 per deposit ghost, 504-506 per redeem ghost; `requestRedeem(0)` ghosts cost
  92_426 and are permanent; dust cancels 19_671 planner gas per entry, 254_035 attacker gas each
  (`test_griefing_ghostDepositEntriesGasPerSkip`, `test_griefing_zeroRedeemGhostsAreFree`,
  `test_cancelQueue_dustCancelsGasPerEntry`). `minDeposit >= 1e6`, `minRedeem >= 100` remove all.

#### R5-10 Info (C-1 re-examined, not reproducible)
A full fill burns at most the entry's own deposited spUSDC (deposit floors twice at :402 and
:845-846; withdraw ceils once at :955/:952) and the partial tail is bounded by the live balance, so
the batched call never needs more spUSDC than the vault holds. Searched 8 odd-sized entries with
backing from exact to 400 shares short: no revert; batched and chunked pay identical amounts; 7
surplus shares remain (`test_C1_batchedRedeemNeverRevertsAtOrBelowFullBacking`). C-1 only
materialises under an under-backed vault (after `take`), where it is F-2.

### (b) Previously reported findings, status now

| Finding | Status | Pinning test |
|---|---|---|
| R4-A blacklisted redeem recipient blocks the queue | fixed: rejected at :452, fallback to `claimableAssets` :955-957, queue moves, `claim` reverts in USDC while blacklisted and pays after; exact 99_959_089 for the 99e6-share jam, alice 989_999_999_997 | `test_fixed_R4A_blacklistedRedeemRecipient_rejectedAtRequest_claimableAtPayout`, `test_fixed_R4A_blacklistedRedeemRecipientDoesNotBlockQueue`, `test_fixed_R4A_nobodyCanRepointToBlacklisted_checkOrder` (blacklist check :508 precedes the owner check :513) |
| R4-B blacklisted cancel recipient blocks the cancellation queue | fixed: :425 rejects, :942-944 credits `claimableAssets` with the floored `redeem` amount (999_999), victim 999_999_999_999 | `test_fixed_R4B_blacklistedCancelRecipient_rejectedAtRequest_claimableAtSettlement` |
| R3-1 realizeGain sandwich | changed: pause-gated (:279) but the deposit before the pause still captures (R5-1) | `test_fixed_R3_1_pauseBeforeDepositKillsSandwich`, `test_BUG_R3_1_*` |
| V2-2 / F-1 guardian-chosen refund recipient | fixed: cancel is owner-only (:430), guardian has `pause` only, cancel blocked while paused | `test_fixed_V2_2_guardianHasNoCancelPath`, fuzz op 4 in `testFuzz_queueInvariants_randomOps` |
| V2-1 unauthenticated recipient updaters | fixed, owner-only | `test_updateRecipient_strangerCannotRepoint{Redeem,Deposit,Cancelled}_*`, `test_updateRecipient_onlyOwnerWritesCountAtFill` |
| A-5 / R2-2 vault as deposit recipient, phantom shares, `transfer(vault)` | fixed (:395, :481, :549, :557) | `test_fixed_depositRecipientVaultRejected`, `test_fixed_updateDepositRecipientVaultRejected`, `test_fixed_noPhantomSharesOutsideEscrow`, `test_fixed_transferToVaultRejected_escrowInvariantHolds` |
| UNPAUSER_ROLE / hot-wallet unpause | gone; admin-only | `test_unpause_guardianCannot` |
| C-3, G-1/G-2, F-2, V2-13, F-4 | open, re-measured above | R5-2..R5-6 |
| C-7 live fee not clamped by a lower max | open | `test_compromised_redeemFeeSetter_maxFeeOnEveryExit` |
| C-9 MAX_VSR 100% APY | open: 1_900.837678 USDC/day on 1M | `test_compromised_setter_maxVsrOverCreditsPerDay`, `..._overCreditRealisedOnRedeem` |
| V2-9 `requestRedeem(0)` ghosts, V2-11 cancel bloat | open, numbers in R5-9 | see R5-9 |
| R4-3 capacity hog is a commitment | unchanged | `test_capacityHog_isACommitmentUntilPlannerPays` |
| R4-5 rebalancer lock-in in all three queues | unchanged | `test_compromised_rebalancer_starvedUsersAreLockedInAllThreeQueues` |
| C-1 batched redeem revert | not reproducible on a backed vault (R5-10) | `test_C1_batchedRedeemNeverRevertsAtOrBelowFullBacking` |

### (c) Properties that held

- Blacklist matrix, both queues, every (request / payout / claim) combination including a partial
  fill while blacklisted and the remainder paid directly afterwards: credited amount equals what a
  clean recipient gets (`withdraw` ceil-burn :955 identical to :952; `redeem` burns exactly the
  shares :942), a failed `claim` leaves the credit intact, a stranger's `claim` pays the recipient
  only, double claim is `nothing-to-claim` (`test_blacklist_redeemQueue_fullMatrix`: 499_999_998 +
  499_999_999; `test_blacklist_cancelQueue_fullMatrix`).
- `claimableAssets` USDC is isolated: `requestDeposit` pulls and forwards exactly `assets_`
  (:400-402), clean payouts go spUSDC -> recipient, `adjustTotalAssets` reads totalSupply * chi
  only, `take` moves spUSDC only; two credits accumulate (249_999_998 + 249_999_999) and `claim`
  works while paused (`test_blacklist_claimableUsdcIsIsolatedAndAccumulates`).
- A blacklisted owner keeps every action that moves no USDC: cancel to a clean recipient, repoint,
  request a redeem, his queued deposit still fills; only his own `requestDeposit` dies in USDC
  (`test_blacklist_ownerBlacklistedMidFlight_ownerActionsStillWork`).
- A loss cannot be dodged through the redeem queue (priced at fill :914: attacker paid
  89_999_999_999 on 100k after a 10% loss); queued spUSDC deposits do not absorb it and get more
  shares when filled after (`test_adjustTotalAssets_lossHitsEscrowAndHolders_notQueuedDeposits`).
  Capacity in shares shrinks in USD after a loss: 500k headroom -> 250k after a 50% loss, a 400k
  deposit is 250k filled / 150k queued (`test_adjustTotalAssets_lossShrinksUsdCapacity`).
- Gain/loss pairs never ratchet chi up; totalAssets drift <= 2 units per pair
  (`testFuzz_adjustTotalAssets_gainLossPairs_noRatchet`). Access/bounds/event/drip-first
  (`test_adjustTotalAssets_accessAndBounds`, `test_adjustTotalAssets_notPaused`).
- Rebalancer ordering and chunking change no payout on a backed vault (three orders from one
  snapshot, within one floor per partial: `test_rebalancer_orderingDoesNotChangePayouts_whenBacked`);
  the rebalancer cannot extract value (`test_compromised_rebalancer_cannotExtractValue`).
- Extreme indexes: spUSDC chi 1.0728e30 and spPRIME chi 1.0097e15: 1 USDC mints 990_233_844_012_150_035
  shares, round-trip loss 174 wei, never a profit, the depositor never consumes others' backing
  (`test_extremes_spUsdcChiHuge_primeChiTiny_roundTripBounded`); fuzzed round trips bounded by
  chiS/RAY + chiP/RAY + 4 (`testFuzz_roundTrip_userNeverProfits`); supply never exceeds capacity
  (`testFuzz_processDeposits_supplyNeverExceedsCapacity`).
- The redeem escrow cannot be spent: `allowance[vault][x] == 0` is never written (`approve` is
  msg.sender-keyed; `permit(vault, ..)` fails ecrecover and the ERC-1271 staticcall to the vault
  returns `success == false` with empty data, :1030-1037), `transferFrom(vault, ..)` reverts
  `insufficient-allowance`, nonces untouched (`test_erc20_escrowCannotBeSpentViaTransferFromOrPermit`).
  ERC-1271 signers cannot mutate state or reach the queues (`test_reentrancy_erc1271Signer*`).
- External-call ordering: `requestDeposit` makes its two external calls (:400-402) before the push
  (:406); a spUSDC cap revert leaves no entry and no USDC in the vault. The fallback credit is
  written after the withdraw (:955 then :957), so a liquidity shortfall credits nothing. `claim`
  zeroes before transferring (:529-533) and a USDC revert restores the credit. No recipient is ever
  called (`test_cei_externalCallBeforeStateWrite_revertsLeaveNoPartialState`,
  `test_reentrancy_noCallbackToRecipient`). With a hooked asset the pre-push calls in
  `requestDeposit` would be the only reentrancy surface; USDC/spUSDC have none.
- Pause matrix: blocked = three requests + three process*; allowed = drip, claim, transfer,
  approve, updaters, setVSR, adjustTotalAssets, take (`test_pause_matrix`).
- Queue invariants under random ops (sum of open entries == pending, head never skips an open
  entry, escrow == pendingRedeemShares, backing >= queued claims): `testFuzz_queueInvariants_randomOps`.

### (d) Unsettled

- R5-1 is a process question for governance: the only on-chain kill switches are pausing or
  pinning capacity before the payload is actionable; whether the spell pipeline can guarantee that
  ordering is outside this suite.
- The sanctioned-vault case (R5-8) depends on Circle's behaviour toward a contract address; the
  mock mirrors FiatToken's `transfer`/`transferFrom`/`approve` checks only.
- Gas figures are warm-slot numbers from one test tx; cold estimates add ~2_000 per skipped entry.

## Round 4 (bf93b0d)

Worker: adversarial. File: `test/ai/Adversarial.t.sol` (contracts `AdversarialTest`, 87 tests, and
new `AdversarialRound4Test`, 15 tests), all passing at 1000 and 5000 fuzz runs. Line numbers refer
to `src/SparkPrimeVault.sol` at upstream `fix/update-guardian-transfer` @ bf93b0d. Every round-1
to round-3 property is re-pinned under the new API.

### Fixed or removed upstream

| Item | Change at bf93b0d | Effect on this suite |
|---|---|---|
| `cancelRedeemRequest` | removed; a redeem request is final, `updateRedeemRecipient` (`:508-517`, owner-only) is the only user action; event `CancelRedeemRequest` (`:101`) is declared and never emitted (Info, dead code) | six usages ported: the random-ops fuzz drops the cancel action and gains a guardian-cancel action; the redeem-side head-walk measurement moved to the planner; `test_updateRedeemRecipient_filledEntryRevertsNoRequest` proves the selector is gone |
| F-1 deposit side | guardian cancel must name the owner (`:424` `invalid-recipient`) | `testFuzz_queueInvariants_randomOps` asserts the revert on every non-owner recipient and cancels to the owner (5000 runs); REDEEM-CANCEL-FEES owns the regression tests |
| Guardian unblock of a blacklisted redeem | gone with the cancel | `test_BUG_blacklistedRecipientBlocksRedeemQueue` and `test_updateRecipient_strangerCannotBlacklistBlockQueue_ownerStillCan` now prove guardian, rebalancer and admin all get `not-authorized`, pause does not help, only the owner repoints |

### Re-pinned attacks

#### R4-1 (REDEEM-CANCEL-FEES owns the High): blacklisted redeem recipient, attacker's cost and the missing tools
`requestRedeem` `:451-477` accepts any recipient; `_processPendingRedeems` `:883-917` is strict
FIFO and `:909` ends in `usdc.transfer(recipient)`. With no cancel the only unblock is the owner's
`updateRedeemRecipient` `:514`.
`test_BUG_blacklistedRedeemRecipient_costIsFeeOnMinRedeemOnly` at launch-like parameters
(`minRedeem = 100e6` shares, fee 1%): attacker holds 200 USDC, queues exactly `minRedeem` to a
blacklisted address, alice's 1_000_000 USDC redeem is behind him.
- Cost: fee `divUp(100e6 * 1e16, 1e18) = 1_000_000` shares = 1_009_687 USDC wei, burned once;
  gas 144_881 to jam, 3_816 to unblock; the queued 99e6 shares are paid back in full
  (99_959_089 wei) when he repoints; net loss after the cycle 1_009_690 wei (fee plus three
  floors). At `minRedeem = 0`, fee 0 the cost is 1 share (`test_BUG_blacklistedRecipientBlocksRedeemQueue`).
- Tools: `updateRedeemRecipient` reverts `not-authorized` for guardian, rebalancer, admin and
  risk manager; `cancelRedeemRequest` selector reverts; `processPendingRedeems(1, 1)` reverts the
  same way (no chunking escapes the head); pause turns the revert into `paused` and after the
  unpause the head is still the blacklisted entry; a week later alice is still at 0. The only
  on-chain exit that does not depend on the attacker is an upgrade.
- Victim side (`test_blacklistedOwner_recoversByRepointingWhileBlacklisted`): an honest redeemer
  blacklisted after queueing recovers alone, because `updateRedeemRecipient` moves nothing:
  repoint to a clean address, planner pays it 999_999_999_998, bob behind her is paid.
- Self-harm only (`test_escrow_redeemRecipientVaultStrandsAndSpUsdcDonates`): recipient == vault
  strands 99_999_999_998 USDC in the vault (`take` moves spUSDC only, `takeAll` leaves it);
  recipient == spUSDC pays out and back in, spUSDC's index-based `totalAssets` drops by the
  payout, the 100_000_000_000 excess is spUSDC's taker's to pull. Strangers cannot cause either
  (`not-authorized`).

#### R4-2 High (unchanged R3-1): `realizeGain` sandwich
`realizeGain` `:293-305`; upstream's TODO `:290-292` states the admin is a spell whose payload is
deployed and public before execution, so the front-run needs no mempool race: the attacker
deposits at any time before the spell executes and the result is deterministic. The exit always
went through the redeem queue, so removing cancel changed none of the numbers
(`test_BUG_realizeGain_sandwichUnchangedWithoutCancel`, plus the five round-3 tests): 1M TVL, 1M
capital, 50_000 gain, fee 0: attacker out 1_024_999_999_998, profit 24_999_999_998, alice loses
25_000_000_000; fee 1%: profit 14_749_999_997; take = gain * c / (TVL + c). Pause before the
gain or a full deposit queue kills it. The attacker's commitment to the queue is one planner
turnaround, which an honest planner provides.

#### R4-3 Info (downgraded from C-10 Low): capacity hog is a commitment
`test_capacityHog_isACommitmentUntilPlannerPays`: the hog's escrowed shares cannot be transferred
(balance 0), cancelled (gone) or released by repointing; his capital is illiquid until the
planner pays; the first `processPendingRedeems` releases him FIFO, frees the capacity, and his
re-hog queues behind the victim. One hog buys one planner call of delay for the attacker's whole
position locked.

#### R4-4 Low (unchanged R2-5 / R2-6, numbers re-pinned)
- `requestRedeem(0)` ghosts are free and now permanent (no cancel ever removed them; the updater
  says `no-request`): 89_139 gas each, planner skip 518 (`test_griefing_zeroRedeemGhostsAreFree`).
- `requestDeposit(0)` ghosts 74_732 gas each, planner skip 493, 60_851 per 30M block
  (`test_griefing_ghostDepositEntriesGasPerSkip`); head walk charged to the next depositor 798
  gas per ghost warm, 10_721 ghosts to push one deposit past 30M, 804M gas of attacker spend
  (`test_griefing_headWalkChargedToNextDepositorAfterPlannerClosesHead`); an owner cancelling at
  the head pays 994_082 gas over 1000 ghosts; the redeem queue has no owner walk left, the
  planner pays 559_066 for one fill plus 1000 skips (`test_griefing_ownerCancelAtHeadPaysWalkOverGhosts`).
- Dust cancel bloat: 250_108 gas per 2-wei deposit + cancel, 17_839 planner gas per entry,
  1_681 per block (`test_cancelQueue_dustCancelsGasPerEntry`).
- `minDeposit >= 1e6` and `minRedeem >= 100` (at a 1% fee cap, see R4-8) remove all of them.

#### R4-5 Medium (trust model, unchanged): compromised roles
- RISK_MANAGER `realizeLoss(totalAssets - 1)` wipes every holder; `realizeGain` is the only
  repair (`test_compromised_riskManager_realizeLossWipesHolders`).
- SETTER at MAX_VSR over-credits 1_900.837678 USDC per day on 1M (unchanged tests).
- REBALANCER lock-in is now total (`test_compromised_rebalancer_starvedUsersAreLockedInAllThreeQueues`):
  with the planner absent, 999_999_999_998 USDC in the redeem queue and 99_999_999_999 in the
  cancel queue are unreachable; the redeemer cannot transfer, cancel or be released by any role
  (guardian, admin, risk manager, setter all revert on the process calls and the updaters);
  pause/unpause and a year of time change nothing; the admin's lever is granting
  REBALANCER_ROLE to a new address, which pays everything out in two calls. The rebalancer still
  cannot extract value in any order or chunking (`test_compromised_rebalancer_cannotExtractValue`).
- GUARDIAN honest (`test_guardian_toolsAreCancelToOwnerAndPauseOnly`): a deposit cancel to any
  address but the owner reverts `invalid-recipient`; no guardian action exists on redeems
  (`not-authorized`); cancel and pause exclude each other (`:410` `whenNotPaused`), so a paused
  vault cannot be cleaned up by the guardian.
- TAKER honest: unchanged.

### New attacks

#### R4-6 Medium: the cancellation queue can be blocked at zero fee with a blacklisted refund address
`requestDepositCancellation` `:409-449` lets the owner name any `recipient_`;
`_processPendingDepositCancellations` `:842-879` is strict FIFO and `:869`
`spUSDC.redeem(shares, recipient, vault)` ends in `usdc.transfer(recipient)`;
`updateDepositCancellationRecipient` `:500` is owner-only. This is the redeem-queue block (C-2)
moved to the refund queue, where no fee is charged.
`test_BUG_blacklistedCancelRecipientBlocksCancellationQueue_zeroFee`: capacity full, attacker
queues `minDeposit` (1 USDC), the victim queues 1_000_000 USDC behind him; attacker cancels to a
blacklisted address (119_494 gas), the victim cancels to himself.
- Every `processPendingDepositCancellations` reverts `Blacklistable: account is blacklisted`,
  including `(1, 1)`; guardian, rebalancer and admin get `not-authorized` on the updater; pause
  gives `paused` and the unpause restores the block; a week later the victim has 0.
- The attacker repoints to himself when he likes and is refunded 999_999 of 1_000_000 (one
  floor, no fee); he re-jams immediately with the same dollar. Cost: gas only.
- Precondition: the deposit must be queued (instant fills delete the entry), which is the state
  whenever the cancellation queue is in use at all.
Impact: every pending refund is hostage to one dollar; no third party can clear it. Fix: pay
`request_.owner` on a failed transfer or skip/park the entry; or reject recipients for which
`USDC.isBlacklisted()` holds at request time; the same fix as C-2.

#### R4-7 Info: `transfer(address(vault))` is accepted and parks shares outside the escrow
`transfer` `:531-537` only rejects `address(0)` (spUSDC also rejects itself).
`test_transfer_toVaultCreatesPhantomSharesOutsideEscrow`: the shares count in `totalSupply` and
capacity, `pendingRedeemShares` does not see them, no path burns them, nobody can claim them
(`transferFrom` from the vault has no allowance). Another holder's redeem burns exactly its
entry. Owner's loss only; same shape as the round-1 `recipient == vault` self-harm.

#### R4-8 Info: `requestRedeem(1)` at any non-zero fee is a 100% fee and a ghost
`:464` rounds the fee up. `test_requestRedeem_oneShareAtNonZeroFeeIsAllFeeGhost`: at 1%
`requestRedeem(1)` burns the share, queues 0 (planner skips it), emits `RedeemRequest(.., 1, 1)`;
99 shares pay 1 share of fee (1.01%), 100 pay exactly 1. `minRedeem >= 100` removes it at the 1%
cap.

#### R4-9 Info: `Referral` is spoofable for any recipient
`:405` emits `Referral(referral_, recipient_, assets_)` for a caller-chosen recipient before the
deposit. `test_referral_eventSpoofableForAnyRecipient`: any address can be attributed to any code
for `minDeposit`, which is gifted to it as shares. The recipient gets no control over a queued
entry (`not-authorized` on updater and cancel) and cannot be harmed by it; the attacker can
cancel back to himself (999_999 of 1_000_000).

### Attacks that failed, as properties

| Property | Test |
|---|---|
| `transferFrom` self-transfer edges: `from == to` leaves the balance unchanged, a spender's self-transfer only burns allowance, max allowance never decrements, over-balance and over-allowance revert | `test_transferFrom_selfTransferEdges` |
| A recipient contract with no receive/fallback is minted on the instant path, on a queued fill and after `updateDepositRecipient` right before the fill (mint `:930-935` has no hook) | `test_requestDeposit_recipientContractWithoutHooksIsMinted` |
| An ERC-1271 signer reached from `permit` (`:989` staticcall) cannot `requestRedeem`, repoint its open entry or nest a `permit`; every attempt fails `invalid-permit`, nonce, allowances and queue untouched; the honest signer still works | `test_reentrancy_erc1271SignerCannotTouchQueuesOrPermit` |
| Fills never push `totalSupply` above `maxCapacity` on the instant or planner path, random caps, indexes and sizes (5000 runs) | `testFuzz_processDeposits_supplyNeverExceedsCapacity` |
| Guardian cancel always refunds the owner; random 24-step sequences with guardian cancels, owner repoints and the three planners keep all queue invariants (5000 runs) | `testFuzz_queueInvariants_randomOps` |
| Everything in the round-3 and round-2 tables | same tests, ported |

### Unsettled
1. R4-6: decide the failed-transfer policy for both queues (pay owner, skip, or reject at
   request time). Until then one blacklisted dollar blocks all refunds and one fee blocks all
   redeems.
2. R4-2: `realizeGain` under a spell is a guaranteed transfer to whoever holds at that block;
   require `paused` or stream it.
3. REBALANCER is now the single point of exit for all three queues; a permissionless
   `processPending*` fallback after a delay, or a user-side cancel for redeems, would bound R4-5.
4. Launch parameters: `minDeposit >= 1e6`, `minRedeem >= 100` (R4-8), fee > 0.
5. Dead event `CancelRedeemRequest` `:101`.
6. Not tested: real-USDC behaviour on a fork (blacklist cases use `vm.mockCallRevert`).

---

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
