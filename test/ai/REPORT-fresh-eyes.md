# FRESH-EYES worker report

## Round 6 (`master` @ `c512609`)

Independent attacker pass over `src/SparkPrimeVault.sol` @ `c512609`, written after a cold
re-read of the contract, the interface and the real spUSDC code, before re-reading the campaign
finding lists. File: `test/ai/FreshEyes.t.sol` (51 tests, all PASS; the 6 fuzz properties pass at
`FOUNDRY_FUZZ_RUNS=20000`). Run with
`FOUNDRY_OFFLINE=true forge test --skip test/ai/TestBase.t.sol --match-path test/ai/FreshEyes.t.sol`
(`test/ai/TestBase.t.sol`, not mine, does not compile on this worktree: duplicate `operator`
identifiers and a 4-arg `initialize`). Harness pins: chi_s = 1.047633055711877768967605062e27,
chi_p = 1.009687768242461209408770821e27, 1_000_000e6 USDC = 954_532_691_143 spUSDC =
990_405_184_109 spPRIME, `assetsOf` of that = 999_999_999_998. No `test_BUG_` test fails
deliberately: each asserts the bad behaviour exactly.

### (a) New findings on the new surface

**R6-1. A cancel remainder below `minDepositCancellation` is uncancellable (new partial-cancel
surface).** `:422` requires `savingsShares_ >= minDepositCancellation` on EVERY cancel, including
the one that would empty the entry, and `:423` caps it at `request.shares`. Any remainder below
the minimum, whether left by the owner's own partial cancel or by an operator partial fill
(`:880`, budgeted `maxSavingsShares_`), can never be cancelled by the owner; only an operator fill
releases it. With launch minimums the trap is wider: `minDeposit` is in USDC, `minDepositCancellation`
in spUSDC shares (`:133`), so if `minDepositCancellation > convertToShares_spUSDC(minDeposit)` a
minimum-size deposit cannot be cancelled at all. Exact: `minDeposit = 1_000e6`,
`minDepositCancellation = 100e6`: a 1_000e6 deposit is 954_532_691 shares; cancelling
`954_532_691 - 50e6` leaves 50e6, then `requestDepositCancellation(id, 50e6)` reverts
`BelowMinDepositCancellation` and `100e6` reverts `SavingsSharesTooHigh`; an operator fill of
`954_532_691 - 50e6` on a fresh entry leaves the same trap; with `minDepositCancellation = 1_000e6`
a 1_000e6 deposit (954_532_691 shares) cannot be cancelled by any amount. Impact: liveness of a
depositor's capital depends on the operator filling the dust (needs capacity). Severity: low.
Fix: allow `savingsShares_ == request.shares` regardless of the minimum (and/or require
`minDepositCancellation <= convertToShares(minDeposit)`).
Test: `test_BUG_cancelRemainderBelowMinDepositCancellation_isUncancellable`.

**R6-2. FE-2 escalates: an over-large capacity now also bricks every cancellation.**
`requestDepositCancellation` ends in `_processPendingDeposits(0, max)` (`:445`) which evaluates
`convertToAssets(availableCapacity())` (`:864`) in checked arithmetic. With
`maxCapacity > type(uint256).max / chi + totalSupply` (e.g. `setCapacity(type(uint256).max)`,
`:304`), `processPendingDeposits` panics 0x11 as in round 5 and now so does every
`requestDepositCancellation` (bob, queued 1M, cannot cancel 954_532_691_143 shares; carol cannot
cancel 1 share). Queueing itself still works (a newcomer behind a live entry only pushes), so
users can enter but neither be filled nor leave until the operator lowers the cap. Exact edge
re-pinned: `cap = threshold + totalSupply` works, `+1` panics. Severity: low (operator footgun;
"unlimited" is the obvious value). Fix: bound `setCapacity` or compute the bound with a
saturating conversion. Test: `test_BUG_setCapacity_uint256Max_bricksDepositFillsAndCancels`.

**R6-3. `adjustTotalAssets` is unbounded upwards and a dust holder then drains all backing
(R5-3 / C-3 re-rated for the `LOSS_MANAGER` hot wallet).** `:262-283` only requires
`totalAssets_ > 0` and `chi <= uint192.max`. A compromised `LOSS_MANAGER` cannot pause (needs
`PAUSER_ROLE`), but during any legitimate pause window it can mark chi up by any factor; after
unpause the per-entry redeem bound (`:953`) is the vault's whole spUSDC, so a 1_000e6 position
redeems alice's 1M: mal receives 1_000_998_999_890 USDC (everything but ~1 USDC lost to the
fillable floor at the inflated chi), alice's redeem then pays 0. Severity: high if the role is a
hot wallet (as the briefing says it now is), otherwise medium. Fix: bound `|delta|` relative to
`totalAssets()` (e.g. a max loss/gain bps per call) or time-lock gains.
Test: `test_BUG_lossManager_unboundedGain_dustHolderDrainsAllBacking`.

**R6-4. R5-1 / G-1 proven end to end: a chi above `2^256 / RAY` bricks the vault permanently.**
`:280` allows chi up to `uint192.max` (6.3e57) but `drip()` computes `_rpow(vsr, dt) * chi_`
(`:655`) in checked uint256, which overflows for any `chi > type(uint256).max / RAY` (1.16e50)
one second later, even at `vsr == RAY`. The adjustment that gets there is accepted (alice 1M,
`delta = divUp(targetChi * ts, RAY) - totalAssets`); after `warp(1)`: `drip`, `nowChi`,
`assetsOf`, `requestDeposit`, `requestRedeem`, `processPendingRedeems`, `setVSR` and
`adjustTotalAssets` itself (it drips first, so it cannot undo) all panic 0x11. Only the dripless
paths survive (`transfer`, `take`, `pause`/`unpause`, `upgradeToAndCall`): recovery needs an
upgrade. Severity: medium (one bad/compromised `LOSS_MANAGER` tx, irreversible without upgrade).
Fix: `require(updatedChi_ <= type(uint256).max / RAY)` (and ideally much lower).
Test: `test_BUG_adjustTotalAssets_chiAboveDripBound_bricksVaultPermanently`.

**R6-5. Ghosts behind a live head: the victim's FULL cancel pays for the whole walk (R5-9
residue, measured).** The self-skip only clears entries at the head (`:875`), so an attacker who
queues N entries behind a victim's live head and cancels each (each cancel's walk breaks at the
victim immediately: 174_009 gas avg) leaves N ghosts the victim walks when their own entry is
deleted: full cancel after 2_000 ghosts = 4_937_676 gas, 2_384 gas per ghost (cold slots);
~12_000 ghosts push it past a 30M block. Mitigations that exist: a PARTIAL cancel by the victim is
O(1) (168_743 gas: the entry stays live and the walk breaks at it), so the victim can pull out
everything but `minDepositCancellation`; the operator cannot skip a live head with budget 0 but
can fill it and then chunk ghosts with `processPendingDeposits(0, k)`. Attacker cost per ghost:
one `minDeposit`-sized request + cancel, capital recycled through the cancellation queue (1 wei
lost per cycle). Severity: low (gas griefing, recoverable). Fix: bound `maxRequests_` in the
self-skip walk (e.g. 1 + a small constant) and let the operator clear the rest.
Tests: `test_BUG_ghostsBehindLiveHead_fullCancelWalksThemAll`,
`test_property_operatorChunksGhosts_afterFillingLiveHead`.

**R6-6 (info). The batched redeem can stop one share short after a partial fill.** After a
partial fill the loop `break`s (`:970`) even though the floored leftover liquidity converts to 1
share again; a second `processPendingRedeems` call pays it. The fuzz property is stated after
calls stop making progress (never more than 2 productive calls were needed).
Test: `testFuzz_property_redeemBatch_neverReverts_stopsOnlyAtZeroLiquidity`.

**R6-7 (info). `adjustTotalAssets` with `totalSupply == 0` panics 0x12 (`:277`, the NOTE admits
it).** Test: `test_BUG_adjustTotalAssets_zeroSupply_panicsDivByZero`.

**R6-8 (info).** Observations without a separate finding: the owner of a deposit request picks
the refund recipient of each cancel slice, so funds destined to another `recipient` are
redirectable by the payer (by design; pinned in the slices test: slice 1 to carol while the
deposit recipient is bob). `Referral` (`:396`) is still emitted at request time with the request
id and attaches a code to any `recipient` for the price of a request + cancel (3 x 1M of
"referred volume" for 3 wei, 0 shares minted): off-chain accounting must use `Deposit`.
1 wei of USDC (the harness `minDeposit`) mints 0 spUSDC shares, pushes a zero-share entry that
the instant-fill predicate (0 == 0) walks at once, donates the wei to spUSDC and cannot be
cancelled (`NoRequest`); launch `minDeposit` prevents it. `requestRedeem(minRedeem = 1)` at a 1%
fee queues a zero-share entry (R5-14): skipped by the next fill, costs one iteration.
Tests: `test_info_referral_emittedOnRequest_cancelLoopInflates`,
`test_info_oneWeiDeposit_zeroShareEntry_isWalkedAndUncancellable`,
`test_BUG_oneWeiRedeemWithFee_isAllFee_zeroShareEntryQueued`.

### (b) Status of prior findings

- **FE-1 / R5-10 (redeem head dust): OPEN, unchanged outcome.** The loop now runs
  (`fillable_ == 0 -> break` at `:955`) but the bound is still `convertToShares(maxWithdraw)`
  (floor) against ceil-burning withdraws: slice 1 at 250k liquidity pays 249_999_999_999, slice 2
  is bounded 1 share below what is owed, 1 share stays at the head with the vault holding 1
  spUSDC wei (= 1 USDC wei = 0 shares). bob's 100e6 deposit then pays alice's dust and bob ends
  99_999_997 (1 short) with his own dust at the head: the deficit still migrates.
  `test_BUG_partialFills_leaveUnpayableDustAtRedeemHead`.
- **FE-2 (capacity overflow): OPEN and wider** (R6-2).
- **FE-3 / R5-9 (ghosts): PARTIALLY FIXED.** Zero-asset requests are gone (`BelowMinDeposit`),
  ghosts at the head are cleared by the cancel's own walk (5 request+cancel cycles leave
  `getPendingDepositRequests().length == 0`, next deposit 270_442 gas): `test_fixed_ghostsAtHead_clearedByCancelSelfSkip`.
  Ghosts behind a live head remain (R6-5).
- **FE-6 / C-1 / R5-4 (batched redeem revert): FIXED.** Every (k, k, rest) split for k in 1..39
  settles in one call; the one-entry 990_405_184_109 redeem pays 999_999_999_998 and leaves 0
  spUSDC; dust after the 3-entry split is at most 2 shares (each small entry ceil-burns ~0.5
  spUSDC wei of value), alice at most 3 wei short: `test_fixed_C1_redeemBatch_drainingAllBacking_noRevert_dustMeasured`,
  plus the fuzz above and `testFuzz_property_ceilBurn_neverExceedsBalance` (the algebraic reason
  `withdraw` cannot revert when `fillable_ > 0`).
- **FE-10 / V2-13 / R5-7 (vault as recipient): FIXED for the vault** on all 6 paths
  (`VaultIsRecipient`, `ZeroRecipient`): `test_fixed_vaultAsRecipient_rejectedOnEveryPath`.
  spUSDC as deposit recipient still strands 990_405_184_109 shares forever
  (`test_info_depositRecipientSpUsdc_strandsShares`); spUSDC as redeem/cancel recipient is paid
  by a USDC self-transfer inside spUSDC (shares burned, liquidity unchanged: a donation to
  spUSDC's holders, not claimable): `test_property_fallback_recipientKinds_andNonRecipientRevertPropagates`.
  `requestDepositCancellation(id >= length)` now reverts `InvalidRequestId`, below the head
  `NoRequest`: `test_fixed_requestDepositCancellation_outOfRange_revertsInvalidRequestId`.
- **FE-4 / R5-2 (gain sandwich): OPEN**, same numbers (1_004_999_999_998 each; 1% fee =
  9_904_051_842 shares makes mal end below 1M): `test_BUG_adjustTotalAssets_gainSandwich_depositBeforePause`.
- **FE-5 / R5-5 / F-2 (redeems spend queued-deposit backing): OPEN**, same numbers:
  `test_BUG_redeemsConsumeQueuedDepositBacking_cancellerStuck`.
- **R5-1 / G-1: OPEN**, now proven to brick (R6-4). **R5-3 / C-3: OPEN**, re-rated (R6-3).
- **R5-6 / V2-8 (zero admin): OPEN**: `initialize(..., admin = address(0), ...)` is accepted and
  `getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1` for address(0); minimums are unbounded above
  (`type(uint256).max` accepted); zero minimums rejected at init and in setters (C-8 fixed):
  `test_property_initialize_rejectsZeroMinimums_acceptsZeroAdmin`.
- **R5-11 / C-7 (bounds do not clamp live values): OPEN**: `setVSRBounds(RAY, 5%)` leaves
  `vsr == MAX_VSR`: `test_property_operator_rateChangeHasNoSameBlockEffect_andIsBounded`.
- **R4-A / R4-B (blacklist fallback): FIXED by try/catch**, see (c).
- **Pause no longer gates cancellations** (R5-B): proven harmless, see (c).
- **Storage layout** re-pinned slot by slot (`test_property_storageLayout_c512609_pinned`):
  4 = `asset | paused << 160 | decimals << 168`, 7 = `rho | chi << 64`, 18 `totalClaimable`,
  25 `balanceOf`, 27 `claimableAssets`, 28 `allowance`; the upgrade mock's appended var lands in
  29 (its comment still says 28): `test_property_upgrade_adminOnly_statePreserved_slot29Appended`.
- Deleted round-5 tests: `test_BUG_ghostEntries_autoWalkGasGriefsNextDepositor` (needs
  `requestDeposit(0)`, impossible now; replaced by R6-5), `test_info_redeemRecipientVault_strandsUsdcForever`
  (now `VaultIsRecipient`, folded into the fixed test), `test_property_spUsdcLiquidityDrain_partialFillsExact_noRevert`
  (folded into the FE-1 test).

### (c) New code paths and the test covering each

| Path (`c512609`) | Test |
|---|---|
| Partial cancel, decrement branch `:437`, delete branch `:435`, per-slice recipients, walk only on delete | `test_property_partialCancel_slicesAreExact_deleteOnlyWhenEmpty` (slices 100 / 400k / rest: carol 104, bob 999_999_999_893, 2 wei lost to 3 floors) |
| Operator partial fill then partial cancel then full cancel | `test_property_partialFill_thenPartialCancel_thenFullCancel_exact` (minted 247_601_296_025, refund 749_999_999_999, 4 wei short in total) |
| `minDepositCancellation` floor on every cancel `:422` | `test_BUG_cancelRemainderBelowMinDepositCancellation_isUncancellable` |
| Self-skip walk while paused `:445` (drips, mints nothing, stops at live head) | `test_property_cancelWhilePaused_walkDripsButMintsNothing` (chi written = `nowChi()` any `drip()` would write; loss applied on the dripped chi either way) |
| Self-skip gas, ghosts behind a live head | `test_BUG_ghostsBehindLiveHead_fullCancelWalksThemAll`, `test_property_operatorChunksGhosts_afterFillingLiveHead` |
| `continue` on ghost then `break` on `remaining_ == 0` `:875-878`, budget-0 walk, ghosts count against `maxRequests_` | `test_property_operatorChunksGhosts_afterFillingLiveHead`, `test_fixed_ghostsAtHead_clearedByCancelSelfSkip`, `testFuzz_property_queueCountersMatchArrays` |
| Instant-fill predicate with partial cancels | `test_property_instantFill_neverSkipsLiveEntry_partialHeadThenCancel` |
| Per-entry redeem bound `:953`, `break` at 0 `:955`, partial `break` `:970` | `test_fixed_C1_...`, `testFuzz_property_redeemBatch_neverReverts_stopsOnlyAtZeroLiquidity`, `testFuzz_property_ceilBurn_neverExceedsBalance`, `test_BUG_partialFills_leaveUnpayableDustAtRedeemHead` |
| try/catch `_withdrawSavings` `:1001-1013` and `_redeemSavings` `:982-994`: blacklisted EOA (claimable), contract recipient (paid), spUSDC (paid, donation), vault blacklisted (non-recipient revert propagates as `Blacklistable: account is blacklisted` from the fallback), `claim` blocked while the vault is blacklisted | `test_property_fallback_recipientKinds_andNonRecipientRevertPropagates` |
| 63/64 gas starvation of the inner call | `testFuzz_property_lowGasOperatorCall_cannotForceClaimable` (30k..400k gas: either reverts or pays 999_999_999_998 directly; `claimableAssets` stays 0) |
| `totalClaimable` under redeem fallback, cancel fallback, deposits, `claim` | `testFuzz_property_totalClaimable_tracksEscrowExactly` (== sum(claimableAssets) == USDC held, 20 random ops), `test_property_claimableEscrow_untouchedByDeposits_exactWei` |
| `LOSS_MANAGER` unbounded gain / drip bound / zero supply | `test_BUG_lossManager_...`, `test_BUG_adjustTotalAssets_chiAboveDripBound_...`, `test_BUG_adjustTotalAssets_zeroSupply_panicsDivByZero` |
| `PAUSER` vs `UNPAUSER` disjoint, idempotent, unpause front-runs the loss tx (`IsNotPaused`) | `test_property_pauserAndUnpauser_areDisjoint_andUnpauseFrontrunsLoss` |
| Operator rate + processing powers, bounds, no access to fee/min/loss | `test_property_operator_rateChangeHasNoSameBlockEffect_andIsBounded` (MAX_VSR set in the same block: payout 100_968_776 unchanged) |
| `transferFrom` ordering `:572-584` | `test_property_transferFrom_balanceCheckedBeforeAllowance` (balance error wins over allowance; infinite allowance not decremented) |
| `initialize` minimums `:184-186`, zero admin `:196`, USDC approval | `test_property_initialize_rejectsZeroMinimums_acceptsZeroAdmin` |
| `rho`/`chi` repack `:125-126` (adjust writes chi only, drip writes both) | `test_property_rhoChiRepack_slot7_writesPreserveEachOther` |
| `Referral` `:396` | `test_info_referral_emittedOnRequest_cancelLoopInflates` |
| Custom errors on every new path (`VaultIsRecipient`, `ZeroRecipient`, `InvalidRequestId`, `NoRequest`, `NotRequestOwner`, `BelowMinDepositCancellation`, `SavingsSharesTooHigh`, `BelowMinDeposit`, `IsNotPaused`, `VSRTooHigh`, `NothingToClaim`, `ZeroMin*`) | the tests above |

### (d) Properties that held (attacks ruled out)

- Queue accounting under 24 random ops incl. random partial-cancel slices x 20_000 seeds: every
  `pendingX` counter equals the sum of its array from the head, redeem escrow `== balanceOf(vault)`,
  vault spUSDC `>=` queued deposit + cancellation shares (no take), heads never exceed raw
  lengths, every slot below a head is dead (raw `vm.load`), a budget-0 walk never leaves a ghost
  at the head: `testFuzz_property_queueCountersMatchArrays`.
- Cancellation batches (two slices per deposit, half of spUSDC's liquidity drained half the
  time) never revert and always walk the deposit queue to its end: `testFuzz_property_cancellationBatch_neverRevertsOnRounding`.
- Batched redeems never revert under random entries, liquidity drains and `take`s; they stop only
  when `convertToShares(availableLiquidAssets()) == 0` (R6-6 caveat): fuzz above.
- Gas starvation cannot turn a direct payout into a claimable credit; the fallback is reached only
  by a recipient-side revert: `testFuzz_property_lowGasOperatorCall_cannotForceClaimable`.
- `totalClaimable == sum(claimableAssets) == USDC held by the vault` under every path; only
  blacklisted recipients are ever credited: `testFuzz_property_totalClaimable_tracksEscrowExactly`.
- Cancelling while paused drips (as anyone can) and mints nothing; the loss is applied on the
  dripped chi regardless: `test_property_cancelWhilePaused_walkDripsButMintsNothing`.
- Instant fill cannot skip a live entry after partial fills and cancels; FIFO exact wei.
- Fee not bypassable by transfer or recipient (9_904_051_842 shares; carol 989_999_999_997).
- `take` of everything turns all settlements into no-ops; deposits still fill; returns resume with
  exact wei: `test_property_takeAll_settlementsAreNoOps_notReverts`.
- spUSDC deposit cap propagates as `SparkVault/deposit-cap-exceeded`; queued deposits accrue the
  spUSDC index, queued redeems the spPRIME index; a 50% loss hits holders and escrowed redeemers
  (499_999_999_999) but not queued deposits or cancellations (999_999_999_999).
- Permit: nonce only advances on success, replay/expiry rejected, ERC1271 owners work (also for
  65-byte garbage), high-s malleability harmless (shared nonce); ERC20 self-transfer and vault
  targets; initializer cannot re-run on proxy or implementation; upgrade is admin-only and
  state-preserving; `drip()` at MAX_VSR survives 60 years idle, overflows at 77.
- Role separation exact (`AccessControlUnauthorizedAccount(who, role)` for pauser/unpauser,
  admin, lossManager, operator on each other's functions).

### (e) Not settled

- Whether the dust in R6-6 / FE-1 can exceed 1-2 shares per entry under spUSDC VSR accrual
  between slices (each slice re-floors at a new chi_s); only the frozen-index case is pinned
  (<= 2 shares for a 3-entry drain, 1 share per partial-fill slice).
- Whether `requestDepositCancellation`'s self-skip walk should be bounded (R6-5) or the operator
  is expected to keep the head clear operationally.
- Whether `minDepositCancellation` is meant to apply to the emptying cancel (R6-1) or only to
  slices.

---

## Round 5 (`master` @ `0ebb452`)

Independent attacker pass over `src/SparkPrimeVault.sol` @ `0ebb452`, written after a cold read of
the contract and of the real spUSDC code (`test/ai/lib/spusdc/SparkVault.sol`) and before reading
other workers' views. File: `test/ai/FreshEyes.t.sol` (34 tests, all PASS; the two fuzz
properties pass at `FOUNDRY_FUZZ_RUNS=20000`). Harness constants: chi_s =
1.047633055711877768967605062e27, chi_p = 1.009687768242461209408770821e27, 1_000_000e6 USDC =
954_532_691_143 spUSDC = 990_405_184_109 spPRIME, `assetsOf` of that = 999_999_999_998.
Every `test_BUG_` test passes by construction (it asserts the bad behaviour); none fails
deliberately.

### (a) Findings

**FE-1. Redeem head can be left with unpayable dust; the deficit migrates to the last redeemer.**
`src/SparkPrimeVault.sol:903` bounds a batch by `convertToShares(spUSDC.maxWithdraw(vault))`
(floor), each fill computes `convertToAssets(shares_)` (floor, `:914`) and `spUSDC.withdraw`
ceil-burns spUSDC (`:922`, SparkVault `_divup`). Scenario: alice deposits 1M, redeems all
(990_405_184_109 shares). spUSDC liquidity limited to 250k: slice 1 pays 249_999_999_999 and
burns `divUp(249_999_999_999 * RAY / chi_s)` spUSDC. Liquidity returns; the vault's remaining
spUSDC is worth exactly the 749_999_999_999 still owed, but re-flooring it into shares gives one
share less than the entry, the fill of (owed - 1) shares ceil-burns the vault's last spUSDC wei,
and 1 share stays at the head with `firstPendingRedeemId == 0`. From then on `remaining_ == 0`
means the loop never runs, so no call can move the head until spUSDC arrives from outside. When
bob deposits 100e6 and redeems, his backing pays alice's dust and bob ends 1 wei short
(99_999_997 vs 99_999_998) with his own dust at the head. Impact: the redeem queue is always
behind by the accumulated ceil-burn (1 spUSDC wei per partial fill) and the last redeemer in a
quiet vault is stuck until the taker donates; dust-sized, but it is a liveness property auditors
will ask about. Severity: low. Tests: `test_BUG_partialFills_leaveUnpayableDustAtRedeemHead`,
`test_property_spUsdcLiquidityDrain_partialFillsExact_noRevert` (1 spUSDC wei returned is still
not enough: 1 USDC wei = 0 spPRIME shares, 2 wei clears it).

**FE-2. `setCapacity(type(uint256).max)` bricks every deposit fill (Panic 0x11).**
`:829` computes `convertToAssets(availableCapacity())` = `cap * chi / RAY` in checked arithmetic.
Threshold with `totalSupply == 0` is exactly `type(uint256).max / chi` (~1.147e50 shares);
`cap = threshold + totalSupply` works, `+1` panics in both `requestDeposit` (instant-fill path,
`:415`) and `processPendingDeposits`. "Unlimited" is the obvious value an operator reaches for.
No funds at risk (the request itself reverts), but the vault takes no deposits until the admin
lowers the cap. Severity: low (admin footgun; fix: cap the conversion or the setter).
Test: `test_BUG_setCapacity_uint256Max_bricksDepositFills`.

**FE-3. Ghost entries + unbounded instant-fill walk: measured.** With `minDeposit == 0`
(the default) and `availableCapacity() == 0`, `requestDeposit(0, x, ref)` costs 77_270 gas, pushes
a zero entry (`:406`) and does not advance the head (`remaining_ == 0` short-circuits `:837`).
When capacity returns, the first depositor whose request satisfies `:414` walks every ghost at
2_393 gas each (cold slots, `vm.cool`): 2_000 ghosts turn a 352_428-gas deposit into 5_140_322.
~1.3e4 ghosts (~1e9 gas for the attacker) push the walk past a 30M block and `requestDeposit`
reverts for everyone until the rebalancer chunks the head with `processPendingDeposits(1, k)`
(works, pinned). With `minDeposit > 0` the same ghost is produced by request-then-cancel (`:432`)
and the attacker's capital is recycled through the cancellation queue (5 cycles of 1_000e6 cost 5
wei). Ghosts also count against `maxRequests_` (`:835`): a budget of k walks k ghosts and fills
nothing. Severity: low (gas griefing, recoverable; fix: `require(savingsShares_ != 0)` and a
bounded walk in `requestDeposit`). Tests: `test_BUG_ghostEntries_autoWalkGasGriefsNextDepositor`,
`test_BUG_ghostEntries_viaCancelWithMinDeposit`, `test_property_rebalancerCanChunkGhostsOnceCapacityReturns`.

**FE-4. `adjustTotalAssets` gain sandwich, quantified.** `:278-295` requires `paused`, but the
pause is a separate GUARDIAN tx and the spell payload is public. alice holds 1M; mal deposits 1M
(instant fill at `:415`) in the block before the pause; admin applies +10_000e6; after unpause
each holds 1_004_999_999_998. With the default `redeemFeeRate == 0` mal redeems to
1_004_999_999_998 USDC (+4_999.999998 for one block of exposure). With the fee at the 1% maximum
the fee is 9_904_051_842 shares and mal nets 994_949_999_997 (< 1M): the fee only deters gains
below ~2% of the sandwich stake, and it is 0 unless set. Severity: medium (economic; operational
mitigation is pause-then-publish or a non-zero fee). Test:
`test_BUG_adjustTotalAssets_gainSandwich_depositBeforePause`.

**FE-5. Redeem liquidity is not ring-fenced from queued-deposit / cancellation backing.**
`availableLiquidAssets()` (`:788-790`) is `spUSDC.maxWithdraw(vault)`, i.e. ALL of the vault's
spUSDC. After `take()` empties the vault, bob's queued 1M (capacity exhausted) is the only spUSDC
on the balance; alice's redeem of 990_405_184_109 shares is paid 999_999_999_998 out of it and
the vault holds 0 spUSDC. bob's cancellation then settles 0 (`maxRedeem == 0`, `:870`) until the
taker returns `S` spUSDC, after which he gets 999_999_999_999. CAMPAIGN.md states the deposit
queue is intentionally not ring-fenced from `take`; this shows the rebalancer can produce the same
state without the taker. Severity: low (no value lost, canceller liveness depends on the operator).
Test: `test_BUG_redeemsConsumeQueuedDepositBacking_cancellerStuck`.

**FE-6. Batched redeem can revert on ceil-rounding when draining all backing (C-1 re-proved).**
Three entries (11, 11, rest) of alice's 990_405_184_109 shares and `processPendingRedeems(max,
max)` revert `SparkVault/insufficient-balance` (`:922`). Severity: low (rebalancer lowers
`maxShares_`). Test: `test_BUG_redeemBatch_ceilRounding_revertsWhenDrainingAllBacking`.

**FE-7 (info). Referral attribution is emitted at request time (`:410`) and never reconciled.**
Request 1M with code 777, cancel, settle: three loops emit 3M of referred volume, mint 0 shares and
cost 3 wei. `requestDeposit(0, victim, 777)` attaches a code to any address for free. Off-chain
referral accounting must use `Deposit` fills, not `Referral`.
Test: `test_info_referralEmittedOnRequest_notOnFill_cancelLoopInflatesVolume`.

**FE-8 (info). Blacklist handling is a liveness feature, not a compliance gate.** Only recipients
are checked (`:425,:452,:493,:508`). A holder blacklisted after requesting can
`updateRedeemRecipient` to a clean address, `requestRedeem` to a clean address, or `transfer`
shares. spUSDC behaves the same (`redeem(shares, cleanReceiver, owner)`), so this is consistent.
Test: `test_info_blacklistedOwner_canStillExitViaCleanRecipient`. If the VAULT itself is
blacklisted, redeems and cancellations still pay (spUSDC pushes USDC straight to the recipient),
deposits revert in USDC (`approve`/`transferFrom` of a blacklisted spender/receiver) and `claim`
would revert. Test: `test_info_vaultBlacklisted_redeemsAndCancelsStillPay_depositsAndClaimsDont`.

**FE-9 (info). `adjustTotalAssets` is a relative delta applied after `drip()` (`:282-284`).**
A spell computed as "target = t0 + 1M" at 5% VSR on 100M executed 3 days later overshoots by
40_109_546_524 wei (~40.1k USDC). Test: `test_info_adjustTotalAssets_relativeDelta_spellLagDrift`.

**FE-10 (info).** `requestRedeem(shares, address(vault))` strands `convertToAssets(shares)` USDC in
the vault with `claimableAssets[vault] == 0` (V2-13 re-pinned); `requestDeposit(x, address(spUsdc))`
mints 990_405_184_109 shares to spUSDC forever; `requestDepositCancellation(id >= length)` panics
0x32 instead of a string revert (`:427`); `permit` accepts high-s malleated signatures (`:1025`,
harmless: the twin shares the nonce). Tests: `test_info_redeemRecipientVault_strandsUsdcForever`,
`test_info_depositRecipientSpUsdc_strandsShares`, `test_info_requestDepositCancellation_outOfRange_panics`,
`test_info_permit_acceptsMalleatedHighS_signature`. The upgrade mock's comment says the appended
var lands in slot 27; on `0ebb452` `allowance` is 27 and it lands in 28 (mock comment only, not
`src/`): `test_property_upgrade_adminOnly_statePreserved_slot28Appended`.

### (b) Previously reported findings touched

- C-1 open (FE-6). R3-1 "quantify the gain between payload-public and pause": FE-4. V2-13
  open (FE-10). V2-9 / ghost entries open and measured (FE-3). F-2 (`take` drains queue backing):
  confirmed and extended to the redeem path (FE-5). Storage layout (#9) pinned slot by slot with
  `vm.load`: `test_property_storageLayout_0ebb452_pinned` (arrays 0-2, `asset|paused` packed in 4,
  `decimals|rho` in 7, chi 8, ..., `balanceOf` 24, `nonces` 25, `claimableAssets` 26,
  `allowance` 27, redeem entry 0 at `keccak(2)+{0,1,2}`).

### (c) Properties that held (attacks ruled out)

- Queue accounting under 24 random ops x 20_000 seeds: each `pendingX` counter equals the sum of
  its array from the head, redeem escrow `== balanceOf(vault)`, vault spUSDC `>=` queued deposit +
  cancellation shares (no take), heads never exceed lengths, every slot below a head is dead:
  `testFuzz_property_queueCountersMatchArrays`.
- Cancellation batches never revert on rounding (floor bound, floor payouts), including with half
  of spUSDC's liquidity drained, 20_000 runs: `testFuzz_property_cancellationBatch_neverRevertsOnRounding`.
- The instant-fill predicate cannot fill a newcomer ahead of a live entry (partial head, cancel,
  newcomer queued, FIFO fills with exact wei): `test_property_instantFill_neverSkipsLiveEntry_partialHeadThenCancel`.
- Fee cannot be bypassed by transferring to a fresh address or by naming another recipient
  (fee 9_904_051_842 shares, carol receives 989_999_999_997); a 1-share redeem at 1% is 100% fee
  and the resulting ghost is skipped: `test_property_redeemFee_notBypassableByTransferOrRecipient`,
  `test_property_oneWeiRedeemWithFee_isAllFee_ghostIsSkipped`.
- Claimable escrow: `sum(claimableAssets) <= USDC in vault`, `requestDeposit` pulls and re-pushes
  exactly `assets_` so it never touches it, `claim` is permissionless, pays only after
  un-blacklisting, zeroes before transfer: `test_property_claimableEscrow_untouchedByDeposits_exactWei`.
- `take` of everything turns all three settlements into no-ops (no revert, heads unchanged),
  deposits still fill (minting needs no spUSDC), returning funds resumes with exact wei:
  `test_property_takeAll_settlementsAreNoOps_notReverts`.
- spUSDC deposit cap propagates as `SparkVault/deposit-cap-exceeded`; a drained spUSDC never makes
  a settlement revert, only partial: `test_property_spUsdcDepositCap_propagatesAsRevert`,
  `test_property_spUsdcLiquidityDrain_partialFillsExact_noRevert`.
- Queued deposits accrue the spUSDC index, queued redeems the spPRIME index (1y at 10% spUSDC /
  5% spPRIME: 1_099_999_999_997): `test_property_queuedEntries_accrueTheirOwnIndex`.
- A 50% loss hits holders and escrowed redeemers (499_999_999_999 each), not queued deposits
  (999_999_999_998 after fill) or cancellations (999_999_999_999):
  `test_property_loss_hitsHoldersAndQueuedRedeemers_notQueuedDepositsOrCancels`.
- Permit: nonce only advances on success, replay and expiry rejected, ERC1271 contract owners work
  (also for 65-byte garbage), ERC20 self-transfer/self-transferFrom and vault targets:
  `test_property_permit_eoa_nonceOnlyAdvancesOnSuccess`, `test_property_permit_erc1271_contractOwner`,
  `test_property_erc20_selfTransfer_andVaultTargets`.
- Initializer cannot re-run on proxy or implementation, `upgradeToAndCall` on the implementation
  reverts `UUPSUnauthorizedCallContext`, upgrade is DEFAULT_ADMIN only, state and chi preserved,
  `reinitializer(2)` single-shot: `test_property_initializer_cannotRerun_onProxyOrImplementation`,
  `test_property_upgrade_adminOnly_statePreserved_slot28Appended`.
- `drip()` at MAX_VSR survives 60 years idle and only overflows (`_rpow` mul) at 77 years:
  `test_property_drip_maxVsr_survives60YearsIdle_overflowsAt77`.

### (d) Not settled

- Whether FE-1 can be made larger than 1 share per partial fill under spUSDC VSR accrual between
  slices (each slice re-floors at a new chi_s); only the frozen-index case is proved.
- Whether the operator intends `processPendingRedeems` to be allowed to spend queued-deposit
  backing (FE-5) or only `take`.
