# Rounding campaign report: `src/SparkPrimeVault.sol`

## Round 5 (`master` @ `0ebb452`)

Branch `campaign-v5/rounding`, source = `master` @ `0ebb452`. File `test/ai/Rounding.t.sol`:
95 tests, 93 pass, 2 deliberate failing proofs of C-1 (`SparkVault/insufficient-balance`), 53
fuzz tests. `test/ai/tables/*` unchanged: `drip_reference.py` regenerates `drip.csv` and
`DripTable.sol` byte-identical (`drip` `:630-645`, `nowChi` `:808-813`, `_rpow` `:1070-1092` are
the same code), and the 112-row table still matches `nowChi()`/`drip()`/`chi()` exactly. Final
runs: `FOUNDRY_FUZZ_RUNS=20000 forge test --match-path test/ai/Rounding.t.sol`: 93 passed,
2 failed (the two C-1 proofs), 0 skipped.

Notation: `c_s = chi_s / RAY`, `c_p = chi_p / RAY`, `S = totalSupply`, `TA = floor(S chi_p / RAY)`,
`C = floor((2^256 - 1) / RAY) = 115792089237316195423570985008687907853269984665640` (1.158e50),
harness chis `chi_s = 1047633055711877768967605062`, `chi_p = 1009687768242461209408770821`.

### Port notes

- `realizeLoss(L)` / `realizeGain(G)` are one function, `adjustTotalAssets(int256)` (`:278-295`),
  admin only, `paused` required (`:279`). Every R13/R14 test now pauses first. Revert strings:
  `invalid-loss`/`invalid-gain` -> `delta-total-assets-zero` (`:280`) for `delta == 0`,
  `loss-too-high` (`:286`) for `L >= TA`; `no-shares` is gone: `S == 0` with a gain panics with a
  division by zero at `:289` (`testFuzz_R13_adjustTotalAssets_zeroSupply_lossRevertsGainPanics`).
- `test_BUG_realizeGain_uint192TruncationCollapsesChi` and the truncation-threshold fuzz became
  `test_fixed_adjustTotalAssets_uint192WrapRevertsChiTooHigh*`: the wrap is now rejected
  `chi-too-high` (`:292`). The drip-overflow brick (G-1/G-2) is still open and keeps its
  `test_BUG_G1_*` names.
- `test_R14_realizeGain_dripsFirst_worksPausedAndUnpaused` became
  `test_fixed_R3_1_adjustTotalAssets_requiresPause_dripsFirst` plus
  `test_R3_1_depositBeforePause_capturesProRataGain_quantified`.
- `SETTER_ROLE` -> `VSR_SETTER_ROLE` in `_freshVault`; `GainRealized` -> `TotalAssetsAdjusted`.
- New helpers `_setPrimeChi` / `_setSpUsdcChi` write `chi` through storage (prime slot 8, spUSDC
  slot 3 offset 64 bits, verified by read-back) so properties can be fuzzed at arbitrary index
  pairs, including `chi_p < RAY`.
- Nothing deleted: every round-4 test has a round-5 counterpart.

### (a) Findings and suspicious behaviour

| # | Where (`0ebb452`) | What | Severity | Test |
|---|---|---|---|---|
| C-1 (open) | clamp `:903` once per call in spPRIME shares vs ceil burn per fill `:922` -> `_withdrawSavings:952` -> spUSDC `withdraw` `:311` | **Minimal reproduction at the harness chis**: vault holds 3401 spUSDC (`maxWithdraw` 3563 USDC, clamp 3528 shares); two redeem entries 108 + 3420 = 3528 pay 109 + 3453 USDC and burn ceil(109 / c_s) + ceil(3453 / c_s) = 105 + 3297 = **3402 spUSDC, 1 short**: `processPendingRedeems(max, 2)` reverts `SparkVault/insufficient-balance` and the batch is undone. Brute force over every balance below 3401 and every two-way split: no smaller balance reverts (the two floors in the clamp leave >= 2 USDC of slack until then). Three entries can be 2 short (13625 spUSDC, 7036 + 6840 + 261 burn 13627). General law, fuzzed at arbitrary indexes `chi_s in [RAY, 10 RAY]`, `chi_p in [RAY/1000, 10 RAY]`, n in [2, 4]: the batch reverts **iff** sum ceil burns > balance, shortfall <= n - 1; a single entry never reverts; `chi_s == RAY` never reverts for any n. Workaround one-per-call: at 3401 it pays 109 then 3451, leaves 1 spUSDC share and 2 spPRIME shares queued until the taker returns backing (clamp of 1 USDC is 0 shares). | medium (liveness of the redeem queue when the vault is nearly drained by `take`; operator can split calls) | `test_BUG_C1_batchRedeem_minimalReproduction_3401_shortfall1` (FAILS), `test_BUG_C1_batchRedeem_minimalReproduction_expectRevert_thenOneByOne`, `test_BUG_C1_batchRedeem_threeEntries_shortfall2`, `testFuzz_BUG_C1_batchRedeem_revertIffCeilBurnsExceedBalance_shortfallAtMostNMinusOne`, `testFuzz_C1_chiSEqualsRay_batchNeverReverts`, `test_BUG_processPendingRedeems_batchCeilBurnsExceedSpUsdcBalance` (FAILS, round-3 numbers 3548 / 2396 + 1285) |
| G-1 / G-2 (open) | `:289` + `:292` vs `drip` `:637` | The only bound on `chi` is `uint192` (6.3e57); `drip` needs `_rpow(vsr, dt) * chi < 2^256`. **Exact smallest `chi` that bricks `drip()` at VSR == RAY: `C + 1 = 115792089237316195423570985008687907853269984665641`** (set through storage; `C` drips for 10 years). At MAX_VSR after 1 s: `floor((2^256 - 1) / MAX_VSR) + 1 = 115792086692257871478197290620423733568884919991399`. Via `adjustTotalAssets` at the harness (S = 990_405_184_109, TA = 999_999_999_998) the largest safe gain is `G_drip = 114_681_085_459_449_903_921_528_244_645_760_028`; `G_drip + 1` lands chi on `C + 664_435_247_753_226` and from the next second every dripping call (`drip`, `nowChi`, `totalAssets`, `requestDeposit`, `requestRedeem`, `processPending*`, `setVSR`, `adjustTotalAssets` itself since it drips first at `:282`) panics 0x11. Only an upgrade recovers. The `:292` bound is `type(uint192).max / C = 54_210_108` times too loose. | low (admin-only, one-shot, irreversible) | `testFuzz_BUG_G1_adjustTotalAssets_dripOverflowThreshold_exact`, `test_BUG_G1_adjustTotalAssets_dripOverflow_oneWeiBricks_thresholdShrinksWithVsr`, `test_BUG_G1_drip_smallestRevertingChi_exact`, `test_drip_uint192CastNeverTruncates` |
| C-3 (open) | `:286` | No loss floor: the largest admissible loss is `TA - 1`, leaving `chi = floor(RAY / S)` (harness `1_009_687_768_243_692`, 1e-12 of a USDC per share) and `totalAssets() in {0, 1}` in one call. `chi-too-low` (`:291`) only fires for `S > RAY` (1e21 USDC of supply; pinned with a 1.1e27-share deposit: `TA - 1` reverts `chi-too-low`, the smallest surviving notional is `ceil(S / RAY)` and lands `chi == 1`). | high (admin only; one call wipes holders) | `testFuzz_BUG_C3_adjustTotalAssets_largestLossIsTotalAssetsMinusOne_noFloor`, `test_R13_adjustTotalAssets_chiTooLow_onlyAboveRaySupply` |
| V2-12 (open) | `:289` | Per-call 1-wei drift: each `adjustTotalAssets` floors once more. Harness: a 1_000_000-wei loss in one call drops `totalAssets` by 1_000_001; in six calls (166_666 x 5 + 166_670) by 1_000_006. k calls vs one: `0 <= TA_single - TA_k <= k`, never in the holders' favour, for losses and for gains. Loss-then-gain of the same amount is not the identity: ends in `[TA - 2, TA]`; harness loss 1 then gain 1 ends 2 wei down (the gain recomputes the very same chi `1009687768240663846587628160`); the exact-drop loss `TA - S` round-trips 1 wei down. | low | `test_BUG_V2_12_adjustTotalAssets_oneWeiDriftPerCall_harness`, `testFuzz_BUG_V2_12_adjustTotalAssets_{loss,gain}_sequenceVsSingle_driftsAtMostKWei`, `testFuzz_R13_R14_adjustTotalAssets_lossGainRoundTrip_losesAtMostTwoWei`, `test_R13_R14_adjustTotalAssets_lossGainRoundTrip_harnessExact` |
| R13-c (open, consequence of C-3) | `:914` after a loss | With `chi_p < RAY` a redeem of `s < ceil(RAY / chi_p)` shares burns the shares (and the fee) and pays 0; exactly `ceil(RAY / chi_p)` pays 1 wei. Harness after `TA - 1`: `ceil(RAY / chi) = 990_405_184_110 = S + 1`, so nobody holds enough to be paid anything; 1e9 shares redeemed -> 0 USDC, 0 spUSDC burnt. Fuzzed over every loss that lands chi below RAY. | low (needs C-3) | `test_R13_afterLoss_chiBelowRay_smallRedeemPaysZero`, `testFuzz_R13_afterLoss_zeroPayoutRegion_isExact` |
| C-11 (open) | `:402`, `:406`, `:414`, `:429`/`:485` | Dust donation, exact region: `requestDeposit(X)` with `X RAY < chi_s`, i.e. `X <= floor((chi_s - 1) / RAY)`, buys 0 spUSDC, donates X to spUSDC, pushes a 0-share ghost that satisfies the instant-fill predicate, mints nothing, cannot be cancelled or repointed (`no-request`). `X + 1` buys exactly 1 share. Harness: X = 1 only; at `chi_s = 10 RAY` everything below 10 wei. Guard: `minDeposit >= ceil(c_s)`. | low | `testFuzz_BUG_C11_dustDeposit_exactRegion`, `test_R1_dustDeposit_belowOneSpUsdcShare_isLostToSpUsdc` |
| F-4 (open) | `:845-:852` | Zero-mint region of a fill, exact at arbitrary pairs: `s <= sMax = ceil((K + 1) RAY / chi_s) - 1`, `K = floor((chi_p - 1) / RAY)`; empty once `chi_p <= RAY`. The admitted spUSDC shares are consumed from the head entry (`:849`) and mint nothing, repeatable while the headroom stays below the region (harness: capacity 2 burns 1 spUSDC share per call). Driven at random pairs by choosing a capacity whose admitted amount lies in the region. | low | `testFuzz_BUG_F4_zeroMintRegion_arbitraryIndexes`, `testFuzz_F4_zeroMintRegion_exactCharacterisation`, `test_F4_zeroMintRegion_table`, `test_capacity_residualTwo_isUnfillable_andDustBurnsSpUsdc` |
| R3-1 residual | `:279` vs `pause` `:380` | Fixed in the contract, residual in the process: `pause()` is a separate GUARDIAN tx, so a deposit between the public payload and the pause captures the gain pro rata. Harness: alice and bob 1_000_000e6 each, gain 50_000e6 realised as 49_999_999_999 (R14 floor); bob's notional rises by exactly 25_000_000_000, half; a depositor after the unpause gets 0 of it. | info (process) | `test_R3_1_depositBeforePause_capturesProRataGain_quantified` |
| `S == 0` panic | `:289` | `adjustTotalAssets(+G)` with no supply is a division-by-zero panic (0x12), not a clean revert (`G > C` overflows first, 0x11); a loss is `loss-too-high`. The NOTE at `:288` says it is assumed. | info | `testFuzz_R13_adjustTotalAssets_zeroSupply_lossRevertsGainPanics`, `test_R13_adjustTotalAssets_int256Edges` (`type(int256).min` -> `loss-too-high`; `type(int256).max` -> 0x11 at `:284`) |

No new rounding finding beyond the exact numbers above: every conversion site keeps its round-4
direction (table below), and no (chi_s, chi_p, capacity) pair over-mints.

### (b) Previously reported findings, status now

| Finding | Status on 0ebb452 | Pinning test |
|---|---|---|
| R4-A/R4-B uint192 wrap of `chi` on a gain (round 3 `test_BUG_realizeGain_uint192TruncationCollapsesChi`) | **fixed**: `chi-too-high` at `:292`; harness gain `6_216_874_099_906_568_962_213_193_772_735_334_179_364_221` (quotient `2^192 + RAY + 458_233_707_431_279`) now reverts, `G_trunc - 1` stores exactly | `testFuzz_fixed_adjustTotalAssets_uint192WrapRevertsChiTooHigh`, `test_fixed_adjustTotalAssets_uint192WrapRevertsChiTooHigh_harness` |
| R3-1 gain sandwich | **fixed** in the contract (`not-paused` at `:279`; `requestDeposit`/`requestRedeem`/planners revert `paused`), residual quantified above | `test_fixed_R3_1_adjustTotalAssets_requiresPause_dripsFirst`, `test_R3_1_depositBeforePause_capturesProRataGain_quantified` |
| C-1 batch ceil burn | **open**, minimal reproduction and exact shortfall law added | see (a) |
| G-1/G-2 drip brick | **open**, exact smallest bricking chi `C + 1` added | see (a) |
| C-3 no loss floor | **open** (`loss-too-high` is the only bound) | see (a) |
| V2-12 per-call drift | **open** | see (a) |
| C-11 dust donation, F-4 zero mint, R13-c zero payout after loss | **open**, exact regions at arbitrary indexes | see (a) |
| CAP-1 `availableCapacity() * chi` overflow (`:829`) | **open**: usable bound `maxCapacity <= totalSupply + type(uint256).max / nowChi()`, shrinks with chi | `testFuzz_capacity_overflowThreshold_isMaxUintOverChi`, `test_capacity_overflowThreshold_shrinksAsChiGrows` |
| N-2 single-share supply cannot lose | **unchanged** (`TA + delta > 0`) | `test_R13_adjustTotalAssets_singleShareSupply_noLossIsPossible`, `test_R13_adjustTotalAssets_twoShareSupply_oneWeiLossHalvesChi` |
| `no-shares` reachability (round 4) | **changed**: check removed; `S == 0` + gain panics | `testFuzz_R13_adjustTotalAssets_zeroSupply_lossRevertsGainPanics` |
| `CancelRedeemRequest` dead event | gone (not re-tested here) | n/a |

### (c) Properties that held (re-pinned rounding table on 0ebb452)

| # | Site (`src/SparkPrimeVault.sol`) | Direction | Favours | Proven bound | Test |
|---|---|---|---|---|---|
| R1 | `:402` spUSDC `deposit`: `floor(X RAY / chi_s)` | down | spUSDC | `< 1` spUSDC share below exact; `X RAY < chi_s` gives 0 (C-11) | `testFuzz_R1_*`, `test_R1_*`, `testFuzz_BUG_C11_*` |
| R2 | `:827-830` `spUSDC.convertToShares(convertToAssets(availableCapacity()))` | down, down | vault | admitted `<= A c_p / c_s`, gap `< 1 + 1/c_s <= 2` spUSDC shares; `totalSupply <= maxCapacity` after instant fill and batch fill for every `chi_s in [RAY, 10 RAY]`, `chi_p in [RAY/1000, 10 RAY]`, capacity in `[1, 1e12]`; mint equals the two-floor composition exactly | `testFuzz_R2_*`, `testFuzz_capacity_arbitraryIndexes_{instantFill,batchFill}_neverOverMints`, `testFuzz_capacity_totalSupplyNeverExceedsMaxCapacity`, `testFuzz_capacity_afterLoss_chiBelowRay_neverOverMints`, `testFuzz_capacity_underUseBound*` (residual `< 1 + (2 + c_s) / c_p` shares, 2 at harness) |
| R3 | `:845` `spUSDC.convertToAssets(s)` | down | vault | `< 1` USDC wei below `s c_s` | `testFuzz_R3_R4_*` |
| R4 | `:846` `convertToShares(assets)` | down | vault | `< 1` share below; zero-mint region exactly `s <= sMax`, empty for `chi_p <= RAY` | same, `testFuzz_BUG_F4_*`, `testFuzz_F4_*` |
| R5 | `:453` `shares_ >= minRedeem` (shares) | none | n/a | exact in shares; asset value `floor(minRedeem c_p)` grows with chi (1000e6 shares: 1_009_687_768 -> 1_060_172_156 after 365 d at 5%); `shares_ == 0` accepted, dead entry skipped (`:911`) only once `remaining_ != 0` (`:908`) | `testFuzz_R5_*`, `test_R5_*` |
| R6 | `:460` `_divUp(shares * fee, WAD)` | up | vault | `>= exact`, `< 1` share above; `s < WAD / fee` pays exactly 1 share; 1-share request at any fee > 0 is entirely fee | `testFuzz_R6_*`, `test_R6_*`, `testFuzz_fee_*`, `test(Fuzz)_divUp_*` (5) |
| R7 | `:903` `convertToShares(maxWithdraw)` | down | vault | clamp `<= L / c_p`, `< 1` share below; paid `<= L` | `testFuzz_R7_*` |
| R8 | `:914` `convertToAssets(shares)` | down | vault | paid `< 1` wei below `shares c_p`; `>= 1` while `chi_p >= RAY`; after a loss 0 for `s < ceil(RAY / chi_p)` | `testFuzz_R8_R9_*`, `testFuzz_R13_afterLoss_zeroPayoutRegion_isExact` |
| R9 | `:922`/`:952` spUSDC `withdraw`: `ceil(paid RAY / chi_s)` | up | spUSDC, against vault | `< 1` spUSDC share above per fill; single fill `<= bal_s`; batch of n short by `<= n - 1` (C-1); after a full redeem the vault keeps `leftover c_s < c_p + 2` spUSDC shares (<= 2 at harness, X = 836 keeps 2) | same, `test_BUG_C1_*`, `testFuzz_fullRedeem_leftoverSpUsdc_*` |
| R10 | `:888`/`:939` spUSDC `redeem(s)`: `floor(s chi_s / RAY)`; budget `:869-870` `min(max, spUSDC.maxRedeem)` = `min(floor(L RAY / chi_s), bal_s)` | down; down | spUSDC, against canceller | one-shot refund `<= X`, loss `< 1 + c_s`; k chunks `<= k - 1` wei below one shot (harness 1000e6: 17 one-share chunks still refund 999_999_999, 18 refund 999_999_998); batch of n fills pays `<= L`, never reverts; stranded `< c_s + n` per call, `< c_s` after repeats | `testFuzz_R10_*` (4), `test_R10_*` (3) |
| R11 | `:637`, `:811` `_rpow(vsr, dt) * chi / RAY` | half-up per step | neutral | equals the python mirror on 112 rows; drift vs continuous `< 1e-18` relative over 10 y at MAX_VSR; daily vs yearly drip within 400 RAY units | `test_R11_*` (4) |
| R12 | `:793`, `:797` `convertToAssets` / `convertToShares` | down / down | vault | `a - A(S(a)) < 1 + c_p`; `s - S(A(s)) <= 1`; `convertToAssets` panics iff `shares > floor((2^256 - 1) / nowChi())` (harness `1.1468e50`), `convertToShares` iff `assets > C` | `testFuzz_R12_*` (4), `testFuzz_convertToAssets_overflowThreshold_isMaxUintOverChi`, `test_convertToAssets_overflowThreshold_harness` |
| R13 | `:289` loss: `chi = uint192((TA - L) RAY / S)`, `0 < L < TA` (`:280`, `:286`) | down, down | against holders | drop in `{L, L + 1}` for `S < RAY`, exactly `L` iff `S \| (TA - L) RAY`; over-reduction `< RAY / S + 1` chi units; cast cannot truncate (`chi' <= chi`); largest loss `TA - 1` leaves `chi = floor(RAY / S) >= 1` | `testFuzz_R13_*` (4), `test_R13_*` (6), `testFuzz_BUG_C3_*` |
| R14 | `:289` gain: `chi = uint192((TA + G) RAY / S)`, `G > 0`, `chi <= 2^192 - 1` (`:292`) | down, down | against holders | rise in `{G - 1, G}` for `S < RAY`, exactly `G` iff `S \| (TA + G) RAY`; `chi' >= chi`; thresholds `G_drip < G_trunc < G_ovf` with `G_trunc` now a clean `chi-too-high` and `G_ovf + 1` a 0x11 | `testFuzz_R14_*` (3), `test_R14_*` (2), `test(Fuzz)_fixed_*` (3), `test(Fuzz)_BUG_G1_*` (3) |
| `_rpow` | `:1070` at `MAX_VSR` | n/a | n/a | reverts (empty data) from `dt = 2_416_158_483 s` (76.62 y); last value `115792088269848880294669100449313013875845939851551`; `nowChi` at the harness chi overflows the product (0x11) from `dt = 2_415_719_841 s`, 438_642 s earlier | `test_rpow_maxVsr_revertBound_exact` |
| `uint192` cast in `drip`/`nowChi` | `:637`, `:811` | n/a | n/a | never truncates: value `< C < 2^192` whenever the product fits | `test_drip_uint192CastNeverTruncates` |
| `maxWithdraw` boundary | spUSDC `:354-358` vs `withdraw` `:311` | n/a | n/a | a single `withdraw(maxWithdraw(vault))` never reverts for any (bal_s, L, chis): burns `ceil(maxWithdraw / c_s) <= bal_s`; when L binds on the redeem queue, repeated calls strand `< c_p` USDC (`convertToShares == 0`, loop skipped) while shares stay queued, `< c_p + 1` per call | `testFuzz_availableLiquidAssets_withdrawOfMaxWithdraw_neverReverts`, `testFuzz_redeemQueue_liquidityBinds_strandBelowOneShare` |
| round trips | R1 -> R3 -> R4 -> R8 | | against user | `X - out < 2 + c_s + c_p`, `<= 4` wei at harness (max at X = 836), queued or instant | `testFuzz_roundTrip_*` (4), `test_roundTrip_maxLossExample_836wei` |
| rate mismatch | 3x3 at 365 d | | | surplus table unchanged (`+-40e9 / 50e9 / 10e9`, 1 wei at RAY/RAY) | `test_rateMismatch_3x3_surplusAfter365d` |

Who eats each wei, in one line per path: deposit: spUSDC keeps `< c_s` (R1), the vault keeps
`< 1 + c_p` (R3+R4); redeem: the vault keeps `< c_p` of notional (R8) and spUSDC takes `< c_s`
extra from the vault's backing (R9); cancellation: spUSDC keeps `< c_s` per chunk (R10);
`adjustTotalAssets`: holders lose `<= 1` wei per call either way (R13/R14); fee: the vault
over-collects `< 1` share (R6).

### (d) Unsettled

- C-1 fix shape still open (clamp in spUSDC shares via `maxRedeem` + `redeem`, as the cancelled
  queue does at `:869-870`/`:888`, would remove it; the exact law above is the spec for a test of
  the fix).
- The C-1 "minimal" balance 3401 is minimal at the harness chis for two entries; at other index
  pairs the smallest reverting balance differs (the fuzz proves the law, not a global minimum).
- R13/R14 `{L, L + 1}` bounds assume `S < RAY`; the `chi-too-low` test is the only `S > RAY` case.
- The strand test conditions on spUSDC liquidity being the binding term; the under-backed regime
  (`vsrP > vsrS`, vault's own spUSDC binds) is observed but its strand is not bounded here (it is
  the backing deficit, not a rounding effect).
- `_rpow` monotonicity near the revert bound was checked at a handful of points in the python
  mirror, not proven.

---

## Round 4 (bf93b0d)

Branch `campaign-v4/queues-rounding`, source = `fix/update-guardian-transfer` @ `bf93b0d`. File
`test/ai/Rounding.t.sol`: 71 tests, 70 pass, 1 deliberate failing proof (C-1), 41 fuzz tests.
`test/ai/tables/*` unchanged (`drip`/`nowChi`/`_rpow` are identical, the 112-row table still
matches). Final run: `FOUNDRY_FUZZ_RUNS=10000 forge test --match-path test/ai/Rounding.t.sol`:
70 passed, 1 failed (`test_BUG_processPendingRedeems_batchCeilBurnsExceedSpUsdcBalance`, still
`SparkVault/insufficient-balance`, same 3548 / 2396 + 1285 numbers; the clamp `:886` is in assets
per call, the burn `:909` a ceil per fill), 0 skipped.

### What changed in the file

- `cancelRedeemRequest` is gone. The two R5/R6 tests that used it to prove a 0-share redeem entry
  is dead now prove it through `updateRedeemRecipient` (`no-request`, `:513`) and the planner:
  the dead entry is skipped (`:896`) and the head moves past it, but only when the vault holds
  spUSDC, because `remaining_ == 0` skips the loop (`:891`) before the `continue`. With no
  liquidity a dead head stays at 0 (`test_R5_zeroShareRequest_isAcceptedWhenMinRedeemIsZero`).
- Every row re-pinned (table below). No formula changed; all proofs carry over.

### Changed rows

| Row | Round 3 | Round 4 | Status |
|---|---|---|---|
| R1 | `:717` | `:771` | re-pinned |
| R2 | `:744` | `:805` | re-pinned; after-loss case added (no over-mint) |
| R3, R4 | `:762`, `:763` | `:823`, `:824` | re-pinned; F-4 region after a loss characterised |
| R5 | `:487` | `:457` | re-pinned; dead-entry proof rewritten without cancel |
| R6 | `:494` | `:464` | re-pinned; same |
| R7 | `:822` | `:886` | re-pinned |
| R8, R9 | `:835`, `:845` | `:899`, `:909` | re-pinned; C-1 persists |
| R10 | refund `:805`, budget `:784` | refund `:869`, budget `:847-848` | re-pinned; batch-safety proof and chunk bounds unchanged |
| R11 | `:649`, `:698` | `:620`, `:748` | re-pinned, table unchanged |
| R12 | `:668`, `:672` | `:730`, `:734` | re-pinned |
| R13 | `:382`, `:376`, `:380` | `:378`, `invalid-loss` `:372`, `no-shares` `:376` | re-pinned; the round-3 harness value "chi = 1_009_687" after `loss = TA - 1` was a unit slip: `floor(RAY / S) = 1_009_687_768_241_653` (1.0097e15) |
| R14 | `:306`, `:298`, `:304` | `:302`, `invalid-gain` `:294`, `no-shares` `:300` | re-pinned |
| cap | `:744` | `:805` | re-pinned |

### New: the capacity chain after a loss (`chi_p < RAY`)

Question from the brief: once a loss puts `chi_p` below RAY, `convertToShares` mints more shares
than USDC wei. Does a capacity remainder then over-mint? No. Both conversions stay floors
(`:730`, `:734`) in either regime and they compose: with `A = floor(cap chi_p / RAY)`,
`s = floor(A RAY / chi_s)`, a fill of `s` pays `a = floor(s chi_s / RAY) <= A` (`:823`) and mints
`floor(a RAY / chi_p) <= floor(A RAY / chi_p) <= cap` (`:824`). Fuzzed over losses down to
`chi = floor(RAY / S)` with random spUSDC/spPRIME chis, random headroom `<= 1e12` and random
deposit size: the instant fill and a follow-up planner call keep `totalSupply <= maxCapacity`, and
the minted amount equals the two-floor composition of `min(request, remaining)` exactly
(`testFuzz_capacity_afterLoss_chiBelowRay_neverOverMints`).

What does change is the other direction: a share of headroom is worth less than one USDC wei.
`test_capacity_afterLoss_headroomBelowOneUsdcWeiIsUnfillable` (1 000 000e6 deposited, loss leaving
45% of the supply in assets, `chi = 0.45e27 - 1` floor):

| headroom (shares) | `convertToAssets` | spUSDC shares (`:805`) | fill |
|---|---|---|---|
| 2 | 0 | 0 | none, deposit queued, planner loop skipped |
| 3 | 1 | 0 (1 wei `< c_s`) | none |
| 5 | 2 | 1 | 1 spUSDC share -> 1 USDC wei -> `floor(RAY / chi) = 2` shares, within capacity |

After the largest admissible loss (`TA - 1`, `chi = floor(RAY / S)`, here
`1_009_687_768_241_653`) a headroom of `9e11` shares, about the whole supply, converts to 0 USDC
and nothing can be filled until the admin raises capacity by at least `RAY / chi + 1` shares (one
share of headroom per share of supply, worth 1 USDC wei). Admin-visible, not a bug: the capacity
is in shares and the share is now worth `~1e-12` USDC.

**F-4 after a loss.** The zero-mint region is empty once `chi_p <= RAY`: `K = (chi_p - 1) / RAY =
0`, `sMax = ceil(RAY / chi_s) - 1 = 0` for any `chi_s > RAY`, so a 1-share fill mints
`floor(RAY / chi_p) >= 1`. The DQ-1 dust head becomes fillable and no spUSDC share is burnt for
nothing after a loss (`testFuzz_F4_afterLoss_zeroMintRegionIsEmpty`, losses from `TA - S` so chi
lands at or below RAY, random spUSDC chi).

### Full re-pinned table

| # | Site (`src/SparkPrimeVault.sol`) | Direction | Favours | Proven bound | Test |
|---|---|---|---|---|---|
| R1 | `:771` spUSDC `deposit`: `floor(X * RAY / chi_s)` | down | spUSDC | `< 1` spUSDC share below exact; `X < c_s` gives 0 (N-2) | `testFuzz_R1_*`, `test_R1_*` |
| R2 | `:805` `spUSDC.convertToShares(convertToAssets(A))` | down, down | vault | admitted `<= A c_p / c_s`, gap `< 1 + 1/c_s <= 2` spUSDC shares; `totalSupply <= cap` for any `chi_p`, above or below RAY | `testFuzz_R2_*`, `testFuzz_capacity_*` (3) |
| R3 | `:823` `spUSDC.convertToAssets(s)` | down | vault | `< 1` USDC wei below `s c_s` | `testFuzz_R3_R4_*` |
| R4 | `:824` `convertToShares(assets)` | down | vault | `< 1` share below; zero-mint region exactly `s <= sMax`, empty for `chi_p <= RAY` | same, `testFuzz_F4_*` (2) |
| R5 | `:457` `shares_ >= minRedeem` (shares) | none | n/a | exact in shares; asset value `floor(minRedeem c_p)` grows with chi; `shares_ == 0` accepted, dead entry skipped only once liquidity exists | `testFuzz_R5_*`, `test_R5_*` |
| R6 | `:464` `_divUp(shares * fee, WAD)` | up | vault | `>= exact`, `< 1` share above; `s < WAD / fee` pays exactly 1 share | `testFuzz_R6_*`, `test_R6_*` |
| R7 | `:886` `convertToShares(maxWithdraw)` | down | vault | clamp `<= L / c_p`, `< 1` share below; paid `<= L` | `testFuzz_R7_*` |
| R8 | `:899` `convertToAssets(shares)` | down | vault | paid `< 1` wei below `shares c_p`; `>= 1` while `chi >= RAY` (not after a loss, R13-c) | `testFuzz_R8_R9_*` |
| R9 | `:909` spUSDC `withdraw`: `ceil(paid * RAY / chi_s)` | up | spUSDC, against vault | `< 1` spUSDC share above per fill; batch of `n` can exceed `bal_s` by `n - 1` (C-1) | same, `test_BUG_processPendingRedeems_*` |
| R10 | `:869` spUSDC `redeem(shares)`: `floor(s * chi_s / RAY)`; budget `:847-848` `min(floor(L RAY / chi_s), bal_s)` | down; down | spUSDC, against canceller | one shot refund `<= X`, loss `< 1 + c_s`; k chunks `<= k - 1` wei below one shot; batch of n fills pays `<= L` (no batch revert); stranded `< c_s + n` per call, `< c_s` after repeats; unsettled `bal_s - floor(L / c_s)` | `testFuzz_R10_*` (4), `test_R10_*` (3) |
| R11 | `:620`, `:748` `_rpow(vsr, dt) * chi / RAY` | half-up per step | neutral | equals the python mirror on 112 rows; daily vs yearly drip differ by 172 RAY units at 5% | `test_R11_*` (4) |
| R12 | `:730`, `:734` `convertToAssets` / `convertToShares` | down / down | vault | `a - A(S(a)) < 1 + c_p`; `s - S(A(s)) <= 1` | `testFuzz_R12_*` (4) |
| R13 | `:378` `chi = uint192(((TA - L) * RAY) / S)`, `0 < L < TA` (`:372`) | down, down | against holders | drop in `{L, L + 1}` for `S < RAY`, exactly `L` iff `S \| (TA - L) RAY`; over-reduction `< RAY / S + 1` chi units; cast cannot truncate; largest loss `TA - 1` leaves `chi = floor(RAY / S) >= 1`; `S == 0` and `L >= TA` revert `invalid-loss`, `no-shares` (`:376`) unreachable; `S == 1` cannot lose; k losses vs one `0 <= TA_single - TA_k <= k` | `testFuzz_R13_*` (5), `test_R13_*` (4) |
| R14 | `:302` `chi = uint192(((TA + G) * RAY) / S)`, `G > 0` (`:294`), `S != 0` (`:300`) | down, down | against holders | rise in `{G - 1, G}` for `S < RAY`, exactly `G` iff `S \| (TA + G) RAY`; under-credit `< RAY / S + 1` chi units; `chi' >= chi`; `G_drip < G_trunc < G_ovf` as in round 3; k gains vs one `0 <= TA_single - TA_k <= k` | `testFuzz_R14_*` (5), `test_R14_*` (3), `testFuzz_BUG_realizeGain_*` (1), `test_BUG_realizeGain_*` (2) |

`_divUp`, round trips, rate mismatch, drip table: unchanged from rounds 2 and 3 (round-trip
tests use fills only; none used the removed cancel).

### Findings status

- C-1 (`:886` vs `:909`) persists, same failing proof, same numbers. Fix shape unchanged: clamp in
  spUSDC shares via `maxRedeem` and `redeem`, as the cancelled queue already does (`:847-848`,
  `:869`).
- R13-a / R13-c / R14-a / R14-b / R14-c / CAP-1 / N-2 persist unchanged at the re-pinned lines.
- Info: `CancelRedeemRequest` event (`:101`) is declared and never emitted.
- No new rounding finding. The after-loss regime adds no new direction: every site stays a floor
  (or the R6/R9 ceils) and the capacity chain cannot over-mint.

### Unsettled

- C-1 fix choice still open.
- R13/R14 bounds assume `S < RAY`; not reachable at 6 decimals.
- The after-loss capacity table is pinned at one loss ratio (45%) plus the extreme; the fuzz
  covers the inequality for all ratios but the exact per-headroom values only at those two.
- Chunk and sequence bounds fuzzed for k, n <= 6, proven analytically for any k.

---

## Round 3 (ff828d2)

Branch `campaign-v3/rounding`, source = `refactor/more-simplifying` @ `ff828d2`. File
`test/Rounding.t.sol`: 68 tests, 67 pass, 1 deliberate failing proof (C-1), 39 fuzz tests.
`test/tables/*` unchanged (`drip`/`nowChi`/`_rpow` are identical, the 112-row table still matches).
Final run: `FOUNDRY_FUZZ_RUNS=10000 forge test --match-path test/Rounding.t.sol -vv`: 67 passed,
1 failed (`test_BUG_processRedeemQueue_batchCeilBurnsExceedSpUsdcBalance`, still
`SparkVault/insufficient-balance`, same 3548 / 2396 + 1285 numbers), 0 skipped.

Notation as in round 2: `c_s = chi_s / RAY`, `c_p = chi_p / RAY`, `S = totalSupply`,
`TA = totalAssets() = floor(S chi_p / RAY)`, `C = floor((2^256 - 1) / RAY) = 1.15792e50`.

### Changed rows

| Row | Round 2 | Round 3 | Status |
|---|---|---|---|
| R1 | `:382` | `:717` | re-pinned |
| R2 | `:702-705` | `:744` | re-pinned |
| R3, R4 | `:722`, `:723` | `:762`, `:763` | re-pinned |
| R5 | `:484` | `:487` | re-pinned |
| R6 | `:491` | `:494` | re-pinned |
| R7 | `:782` | `:822` | re-pinned |
| R8, R9 | `:795`, `:805` | `:835`, `:845` | re-pinned; C-1 persists |
| R10 | refund `:765`, budget `:744` `min(max, bal_s)` | refund `:805`, budget `:784` `min(max, spUSDC.maxRedeem(vault))` = `min(max, floor(L RAY / chi_s), bal_s)` | budget gained a floor; batch-safety proof and stranded-liquidity bound added (3 tests) |
| R11 | `:641`, `:690` | `:649`, `:698` | re-pinned, table unchanged |
| R12 | `:660`, `:664` | `:668`, `:672` | re-pinned |
| R13 | `:357`, range `1 <= loss <= TA` | `:382`, range `0 < loss < TA` (`:376` `invalid-loss`), `:380` `no-shares` | tests re-bounded: largest loss `TA - 1`; `loss == TA` and `S == 0` now `invalid-loss`; single-share supply cannot lose; chi can no longer reach 0 for `S < RAY` |
| R14 | n/a | `:306` `chi = uint192(((TA + gain) * RAY) / S)`, `:298` `gain > 0`, `:304` `no-shares` | new row, 11 tests |
| cap | `:704` | `:744` | re-pinned; interaction with R14 noted |

### R13 at ff828d2

The characterisation of round 2 holds unchanged on the new admissible range `0 < loss < TA`
(drop in `{loss, loss + 1}`, exactly `loss` iff `S | (TA - loss) RAY`; over-reduction in chi
`< RAY / S + 1`; cast proof `chi' <= chi < 2^192`; path bound `0 <= TA_single - TA_k <= k`). What
the new requires change:

- Largest succeeding loss is `TA - 1`, leaving `chi = floor(RAY / S) >= 1` for `S < RAY` and
  `totalAssets()` in `{0, 1}`; `convertToShares` keeps working. Harness: `chi = 1_009_687`.
  `loss = TA` and `TA + 1` revert `invalid-loss` instead of chi 0 / panic
  (`testFuzz_R13_realizeLoss_largestSucceedingLossIsTotalAssetsMinusOne`).
- `S == 0`: `TA == 0`, so `loss < 0` is false for every loss and the call reverts `invalid-loss`.
  `no-shares` is unreachable in `realizeLoss`: `S == 0` implies `TA == 0` implies `invalid-loss`,
  and `S != 0` passes the check (`testFuzz_R13_realizeLoss_zeroSupply_revertsInvalidLoss_noSharesUnreachable`,
  any `loss`).
- `S == 1`: `TA = floor(chi / RAY) = 1` for `chi < 2 RAY`, so no loss is possible at all. The
  smallest supply that can realise one is `S = 2` (`TA = 2`): loss 1 gives `chi = RAY / 2` exactly,
  `totalAssets() = 1` (`test_R13_realizeLoss_singleShareSupply_noLossIsPossible`,
  `test_R13_realizeLoss_twoShareSupply_oneWeiLossHalvesChi`). Round-2 R13-b (1-wei loss zeroes chi
  at `S = 1`) is gone; R13-a (generic 1-wei over-realisation) and R13-c (`chi < RAY` after a loss,
  small redeems pay 0) persist.

### R14 `realizeGain` derivation

`chi' = floor((TA + G) RAY / S)` with `TA = floor(S chi / RAY)`. From `S chi' <= (TA + G) RAY`
and `S chi' > (TA + G) RAY - S`: `TA' = floor(S chi' / RAY)` lies in
`[TA + G - ceil(S / RAY), TA + G]`. For `S < RAY`: `TA' in {TA + G - 1, TA + G}`, exactly `TA + G`
iff `S | (TA + G) RAY`. Direction: both floors against holders, who receive `gain` or `gain - 1`
(generic case `gain - 1` for `S` coprime to 10). In chi units the credit is `<= G RAY / S` and
less than `RAY / S + 1` units short. `chi' >= chi` for any `G >= 1` since `(TA + 1) RAY > S chi`
(`testFuzz_R14_realizeGain_floorsAgainstHolders_underCreditsAtMostOneWei` asserts the exact
characterisation). Harness, 1 000 000e6 deposited (`S = 990 405 184 109`, `TA = 999 999 999 998`):

| gain | new `totalAssets` | rise | new chi |
|---|---|---|---|
| 1 | 999 999 999 998 | 0 | 1009687768242683222124115546 |
| 2 | 999 999 999 999 | 1 | |
| 999 999 999 | 1 000 999 999 996 | 999 999 998 | |
| 980 810 368 220 (= 2S - TA) | 1 980 810 368 218 | exact | 2e27 |

Path dependence: `k` gains summing to `G` give `chi_k <= chi_single`, `0 <= TA_single - TA_k <= k`,
`(chi_single - chi_k) S < k (RAY + S)` (`testFuzz_R14_realizeGain_sequenceVsSingle_pathDependenceBound`,
k in [2, 6]). One aggregated gain is better for holders than a stream.

Checks: `gain == 0` reverts `invalid-gain`; `S == 0` reverts `no-shares` for any `gain > 0` (this
check is reachable here, unlike R13); no pause check, admin only; `drip()` runs first so the gain
lands on top of the accrued index (`test_R14_realizeGain_dripsFirst_worksPausedAndUnpaused`).

Thresholds on `gain`, in this order for every supply (`RAY > 2^64`):

| threshold | formula | harness value | effect |
|---|---|---|---|
| `G_drip` | `ceil((C + 1) S / RAY) - 1 - TA` | 114 681 085 459 449 903 921 528 244 645 760 028 (1.1468e35) | largest gain with `chi' <= C`; `drip()` keeps working at VSR = RAY for any dt. `G_drip + 1` gives `chi' > C` and `_rpow(RAY, dt) * chi'` overflows |
| `G_trunc` | `ceil(2^192 S / RAY) - TA` | 6 216 874 099 906 568 962 213 193 772 734 343 774 180 112 (6.2169e42) | smallest gain whose quotient is `>= 2^192`; the `uint192` cast wraps silently, `chi = q mod 2^192` |
| `G_ovf` | `C - TA` | 115 792 089 237 316 195 423 570 985 008 687 907 852 269 984 665 642 (1.1579e50) | largest gain with `(TA + G) RAY < 2^256`; `G_ovf + 1` panics 0x11 |

Harness chi at `G_drip`: 115792089237316195423570985008687907508017464175173 (`<= C`); at
`G_drip + 1`: 115792089237316195423570985008687908517705232418866 (`> C`), `drip()` panics one
second later. General drip bound: `chi <= (2^256 - 1) / _rpow(vsr, dt)`; at VSR = RAY, rpow = RAY
and chi must be `< 1.158e50`. With VSR > RAY the bound shrinks with dt: the same `G_drip` that is
safe for 10 years at VSR = RAY bricks the vault 1 second after `setVSR(MAX_VSR)`
(`test_BUG_realizeGain_dripOverflow_oneWeiBricks_thresholdShrinksWithVsr`). Fuzzed over random
chis and dt in [1, 10y] (`testFuzz_BUG_realizeGain_dripOverflowThreshold_exact`): after
`G_drip + 1`, `drip`, `nowChi`, `totalAssets`, `requestDeposit`, `realizeLoss`, `realizeGain` and
`setVSR` all panic; only an upgrade recovers. Deposits die earlier through CAP-1:
`availableCapacity() * chi` overflows once `chi > type(uint256).max / availableCapacity()`
(3.4e38 at the harness cap, i.e. a gain of about 3.4e38 x S / RAY = 3.4e23 USDC wei).

**R14-a · Low (admin only) · `test_BUG_realizeGain_dripOverflow_*`.** A gain above `G_drip`
bricks the vault permanently as soon as time passes, with no revert at the call.

**R14-b · Low (admin only) · `test_BUG_realizeGain_uint192TruncationCollapsesChi`.** Above
`G_trunc` the cast wraps; the wrapped chi can land back below `C` so the vault stays alive with a
collapsed index. Harness: `gain = ceil((2^192 + RAY) S / RAY) - TA =
6 216 874 099 906 568 962 213 193 772 735 334 179 364 221` gives quotient `2^192 + RAY +
458 233 707 431 279`, stored `chi = 1 000 000 000 000 458 233 707 431 279`, `totalAssets()` falls
from 999 999 999 998 to 990 405 184 109 after a "gain", `GainRealized` reports the collapsed chi,
`drip()` works. A quotient that is an exact multiple of `2^192` gives chi 0 and a
`convertToShares` division by zero. All truncating gains exceed `G_drip`, so the vault is already
in the brick region unless the wrap lands below `C`.

**R14-c · Info.** `realizeGain` under-credits holders by 1 wei in the generic case (mirror of
R13-a); `GainRealized(chi, gain)` overstates the realised rise by 1 wei. Same fix family as R13-a
(compute from `S * chi` without the `totalAssets()` floor).

### R10 batch-safety proof

Budget `:784`: `remaining = min(maxSavingsShares, spUSDC.maxRedeem(vault))`,
`maxRedeem = min(floor(L RAY / chi_s), bal_s)` with `L` = USDC held by spUSDC. Each fill `:805`
redeems `s_i` shares and spUSDC pays `floor(s_i chi_s / RAY)` USDC, `sum s_i <= M = floor(L RAY /
chi_s)`. Because `sum floor(x_i) <= floor(sum x_i)` and `M chi_s / RAY <= L`:

`sum paid_i <= floor(M chi_s / RAY) <= L`.

So `N` settlements in one call never ask spUSDC for more USDC than it holds: there is no C-1-style
batch revert on the cancelled queue (the redeem queue reverts because `:845` is a ceil per fill
against a floor clamp; here both the budget and the fills are floors in the same direction).
`testFuzz_R10_batchSettle_neverExceedsSpUsdcLiquidity` (1 to 6 cancelled entries, random
liquidity, random chis) asserts no revert, the exact FIFO payout and `paid <= L`.
`test_R10_batchSettle_c1StateDoesNotRevert` transposes the C-1 state: liquidity 3717 USDC against
2310 + 1239 = 3549 queued spUSDC, budget `floor(3717 / 1.0476) = 3547`, fills 2420 + 1295 =
3715 <= 3717, no revert.

Stranded liquidity when liquidity binds (`M < bal_s`): `L - sum paid_i < L - sum s_i chi_s / RAY +
n = L - M chi_s / RAY + n < c_s + n` USDC wei for `n` fills in the call (one `< 1` wei floor per
fill, `< c_s` from the budget floor). Harness example: 2 wei after the first call. Repeating the
call keeps settling while `L' >= c_s`; once `maxRedeem` is 0 what remains in spUSDC is `< c_s`
(less than one spUSDC share, 1 wei in the example) and only moves when more liquidity arrives;
the queued shares stay at the head (`_settleUntilBudgetIsZero`). Shares left unsettled when
liquidity binds: `bal_s - M`, within 1 share of the exact `bal_s - L / c_s`
(`testFuzz_R10_budget_liquidityBinds_isFloorOfLiquidityInShares`). With ample liquidity the budget
is `bal_s` exactly as in round 2 (`test_R10_budgetIsVaultSpUsdcBalance_noConversion`).

### Full re-pinned table

| # | Site (`src/SparkPrimeVault.sol`) | Direction | Favours | Proven bound | Test |
|---|---|---|---|---|---|
| R1 | `:717` spUSDC `deposit`: `floor(X * RAY / chi_s)` | down | spUSDC | `< 1` spUSDC share below exact; `X < c_s` gives 0 (N-2) | `testFuzz_R1_*`, `test_R1_*` |
| R2 | `:744` `spUSDC.convertToShares(convertToAssets(A))` | down, down | vault | admitted `<= A c_p / c_s`, gap `< 1 + 1/c_s <= 2` spUSDC shares; `totalSupply <= cap` | `testFuzz_R2_*` |
| R3 | `:762` `spUSDC.convertToAssets(s)` | down | vault | `< 1` USDC wei below `s c_s` | `testFuzz_R3_R4_*` |
| R4 | `:763` `convertToShares(assets)` | down | vault | `< 1` share below; zero-mint region exactly `s <= sMax` | same, `testFuzz_F4_*` |
| R5 | `:487` `shares_ >= minRedeem` (shares) | none | n/a | exact in shares; asset value `floor(minRedeem c_p)` grows with chi; `shares_ == 0` accepted | `testFuzz_R5_*`, `test_R5_*` |
| R6 | `:494` `_divUp(shares * fee, WAD)` | up | vault | `>= exact`, `< 1` share above; `s < WAD / fee` pays exactly 1 share | `testFuzz_R6_*`, `test_R6_*` |
| R7 | `:822` `convertToShares(maxWithdraw)` | down | vault | clamp `<= L / c_p`, `< 1` share below; paid `<= L` | `testFuzz_R7_*` |
| R8 | `:835` `convertToAssets(shares)` | down | vault | paid `< 1` wei below `shares c_p`; `>= 1` while `chi >= RAY` (not after a loss, R13-c) | `testFuzz_R8_R9_*` |
| R9 | `:845` spUSDC `withdraw`: `ceil(paid * RAY / chi_s)` | up | spUSDC, against vault | `< 1` spUSDC share above per fill; batch of `n` can exceed `bal_s` by `n - 1` (C-1) | same, `test_BUG_processRedeemQueue_*` |
| R10 | `:805` spUSDC `redeem(shares)`: `floor(s * chi_s / RAY)`; budget `:784` `min(floor(L RAY / chi_s), bal_s)` | down; down | spUSDC, against canceller | one shot refund `<= X`, loss `< 1 + c_s`; k chunks `<= k - 1` wei below one shot; batch of n fills pays `<= L` (no batch revert); stranded `< c_s + n` per call, `< c_s` after repeats; unsettled `bal_s - floor(L / c_s)` | `testFuzz_R10_*` (4), `test_R10_*` (3) |
| R11 | `:649`, `:698` `_rpow(vsr, dt) * chi / RAY` | half-up per step | neutral | equals the python mirror on 112 rows; daily vs yearly drip differ by 172 RAY units at 5% | `test_R11_*` (4) |
| R12 | `:668`, `:672` `convertToAssets` / `convertToShares` | down / down | vault | `a - A(S(a)) < 1 + c_p`; `s - S(A(s)) <= 1` | `testFuzz_R12_*` (4) |
| R13 | `:382` `chi = uint192(((TA - L) * RAY) / S)`, `0 < L < TA` | down, down | against holders | drop in `{L, L + 1}` for `S < RAY`, exactly `L` iff `S \| (TA - L) RAY`; over-reduction `< RAY / S + 1` chi units; cast cannot truncate; largest loss `TA - 1` leaves `chi = floor(RAY / S) >= 1`; `S == 0` and `L >= TA` revert `invalid-loss`, `no-shares` unreachable; `S == 1` cannot lose; k losses vs one `0 <= TA_single - TA_k <= k` | `testFuzz_R13_*` (5), `test_R13_*` (4) |
| R14 | `:306` `chi = uint192(((TA + G) * RAY) / S)`, `G > 0`, `S != 0` | down, down | against holders | rise in `{G - 1, G}` for `S < RAY`, exactly `G` iff `S \| (TA + G) RAY`; under-credit `< RAY / S + 1` chi units; `chi' >= chi`; `G_drip < G_trunc < G_ovf` as above; k gains vs one `0 <= TA_single - TA_k <= k` | `testFuzz_R14_*` (5), `test_R14_*` (3), `testFuzz_BUG_realizeGain_*` (1), `test_BUG_realizeGain_*` (2) |

`_divUp` and the capacity, round-trip, zero-mint and rate-mismatch sections are unchanged from
round 2 (capacity overflow site now `:744`).

### Unsettled

- C-1 fix choice still open; the cancelled queue shows the floor-budget pattern (`maxRedeem`)
  that avoids it, the redeem queue could use the same shape (clamp in spUSDC shares via
  `maxRedeem`, then `redeem` instead of `withdraw`).
- R13-a / R14-c: 1-wei over-realisation / under-credit per call is a reporting nit; whether the
  events should carry the realised change is a product decision.
- R14-a/b are admin-only input bounds. A `require(chi_ <= type(uint256).max / maxVSR)` style cap
  (or `<= C`) on both `realizeGain` and `setCapacity` would close the brick and the wrap in one
  line; not required for correctness under a trusted admin.
- R13/R14 bounds assume `S < RAY`; for `S >= RAY` the drop/rise can differ by `ceil(S / RAY)` and
  `realizeLoss(TA - 1)` can reach chi 0. Not reachable at 6 decimals.
- Chunk and sequence bounds are fuzzed for k, n <= 6 and proven analytically for any k.

---

## Round 2 (0bc9288 + review/poc-tests-v2)

Branch `campaign-v2/rounding`, source = `refactor/more-simplifying` merged with
`review/poc-tests-v2` (`realizeLoss` with two floors, `pause()` on GUARDIAN). File
`test/Rounding.t.sol` (53 tests, 52 pass, 1 deliberate failing proof), reference generator
`test/tables/drip_reference.py` -> `test/tables/drip.csv`, `test/tables/DripTable.sol` (unchanged:
`drip`/`nowChi`/`_rpow` are semantically identical, the 112-row table still matches exactly).
Final run: `FOUNDRY_FUZZ_RUNS=10000 forge test --match-path test/Rounding.t.sol ...`: 52 passed,
1 failed (`test_BUG_...`), 0 skipped; 29 fuzz tests at 10000 runs each.

Notation: `c_s = chi_s / RAY` (spUSDC index), `c_p = chi_p / RAY` (spPRIME index), both >= 1
until a loss is realised. `S = totalSupply`, `TA = totalAssets() = floor(S chi_p / RAY)`.
Harness chis `chi_s = 1047633055711877768967605062`, `chi_p = 1009687768242461209408770821`
(`test_R11_harnessIndexesMatchReference`). Random chis = VSR anywhere in `[RAY, MAX_VSR]` on both
vaults, up to 10 years of accrual.

## (a) What changed since round 1

| Row | Round 1 | Round 2 | Status |
|---|---|---|---|
| R1 | `:366` | `:382` | re-pinned, same proof |
| R2 | `:633-636` | `:702-705` | re-pinned, same proof |
| R3, R4 | `:653`, `:654` | `:722`, `:723` | re-pinned, same proof |
| R5 | `:426` floor(shares chi / RAY) >= minWithdraw | `:484` `shares_ >= minRedeem` in shares | row replaced: no rounding at the check; asset value of the minimum drifts up with chi; `shares_ == 0` accepted |
| R6 | `:435` `_divup` | `:491` `_divUp` | re-pinned; new edge test for 1-share requests |
| R7 | `:675` | `:782` | re-pinned |
| R8, R9 | `:688`, `:698` | `:795`, `:805` | re-pinned; C-1 (round-1 N-1) persists, same revert |
| R10 | `:411` refund inside `cancelDepositRequest` | `:765` refund inside `_processCancelledDepositQueue`; budget `:744` | row moved: same floor, same direction; budget exact in spUSDC shares; k-chunk settlement bound added |
| R11 | `:575`, `:621` | `:641`, `:690` | re-pinned, table unchanged |
| R12 | `:590`, `:594` | `:660`, `:664` | re-pinned |
| R13 | n/a | `:357` `chi = uint192(((totalAssets() - loss) * RAY) / totalSupply)` | new row |
| cap | `setCapacity` bounded to `uint128` | unbounded | exact overflow threshold added |

### Findings carried or new

**C-1 (round-1 N-1) persists.** `test_BUG_processRedeemQueue_batchCeilBurnsExceedSpUsdcBalance`
still fails with `SparkVault/insufficient-balance` for the same reason: the clamp at `:782` is in
assets per call, the burn at `:805` is a ceil per fill. Same numbers (3548 spUSDC, 2396 + 1285
shares burn 3549). One-request-per-call workaround unchanged
(`test_processRedeemQueue_batchCeilBurn_oneRequestPerCallSucceeds`).

**N-2 (dust deposit < c_s buys 0 spUSDC) persists** at `:382`, `minDeposit` still defaults to 0
(`test_R1_dustDeposit_belowOneSpUsdcShare_isLostToSpUsdc`).

**R13-a · Low · `realizeLoss` over-realises by 1 wei in the generic case.** With `S` coprime to
10 (every realistic supply), `totalAssets()` drops by `loss + 1` for every `loss` except the
values with `S | (TA - loss) RAY`, which for the harness supply are only `TA - S` (chi lands
exactly on RAY) and `TA` (chi 0). Harness: `realizeLoss(1)` drops `totalAssets` from
999 999 999 998 to 999 999 999 996. One wei per call; a sequence of k calls over-realises up to
k wei. No funds at risk (the spUSDC backing is untouched), but `LossRealized(chi, loss)`
understates the holders' loss by 1 wei. Fix if wanted: `chi -= _divUp(loss * RAY, S)` (the
previous formula; over-realises `< S / RAY`, invisible at 6 decimals) or compute from `S * chi`
without going through the `totalAssets()` floor.

**R13-b · Info · relative error is unbounded for small supply.** The `TA` floor throws away up
to 1 wei, which is `RAY / S` chi units. With `S = 1` share any 1-wei loss sets `chi = 0`
(`test_R13_realizeLoss_singleShareSupply_oneWeiLossZeroesChi`). With `S = 1e6` (one USDC of
supply) a 1-wei loss can move chi by up to 1e21 units on top of the exact 1e21.

**R13-c · Info · post-loss `chi < RAY` breaks R8's `paid >= 1`.** After a loss,
`convertToAssets(s)` is 0 for `s < RAY / chi`; `_processRedeemQueue` burns the shares and pays 0
USDC (`spUSDC.withdraw(0)` burns 0 spUSDC). `test_R13_afterLoss_chiBelowRay_smallRedeemPaysZero`:
1e9 shares burned for 0 wei at `chi ~ 1e15`.

**CAP-1 · Info · exact overflow bound of `setCapacity`.** Every deposit computes
`availableCapacity() * nowChi()` at `:704`; it reverts (panic 0x11) iff
`maxCapacity - totalSupply > type(uint256).max / nowChi()`. The bound shrinks with chi: harness
limit 1.14681e50, after 365 days at 5% 1.09220e50; a capacity set in between bricks deposits a
year later (`test_capacity_overflowThreshold_shrinksAsChiGrows`,
`testFuzz_capacity_overflowThreshold_isMaxUintOverChi`). The harness value `type(uint128).max`
(3.4e38) stays 1e8 times inside the limit even after 10 years at 100% APY.

## (b) Proven rounding table

All sites fuzzed over random chis (10000 runs) with the exact rational checked by
cross-multiplication (`value * den <= num` and `num - value * den < den`, or the reverse for ceil).

| # | Site (`src/SparkPrimeVault.sol`) | Direction | Favours | Proven bound | Test |
|---|---|---|---|---|---|
| R1 | `:382` spUSDC `deposit`: `floor(X * RAY / chi_s)` | down | spUSDC | `< 1` spUSDC share below exact; `X < c_s` gives 0 (N-2) | `testFuzz_R1_spUsdcDeposit_roundsInFavourOfSpUsdc` |
| R2 | `:702-705` `spUSDC.convertToShares(convertToAssets(A))` | down, down | vault | admitted `<= A c_p / c_s`, gap `< 1 + 1/c_s <= 2` spUSDC shares; `totalSupply <= cap` | `testFuzz_R2_capacityToSavingsShares_roundsInFavourOfVault` |
| R3 | `:722` `spUSDC.convertToAssets(s)` | down | vault | `< 1` USDC wei below `s c_s` | `testFuzz_R3_R4_fillConversion_roundsInFavourOfVault` |
| R4 | `:723` `convertToShares(assets)` | down | vault | `< 1` share below; zero-mint region exactly `s <= sMax` (section c) | same, `testFuzz_F4_zeroMintRegion_exactCharacterisation` |
| R5 | `:484` `shares_ >= minRedeem` (shares) | none | n/a | exact in shares for any chi; asset value `floor(minRedeem c_p)` grows with chi (harness, 1000e6 shares: 1 009 687 768 -> 1 060 172 156 after 1y at 5% -> 1 644 674 980 after 10y); `shares_ == 0` accepted, creates a dead 0-share entry | `testFuzz_R5_minRedeem_checkIsExactInShares`, `test_R5_minRedeem_assetValueDriftsUpWithChi`, `test_R5_zeroShareRequest_isAcceptedWhenMinRedeemIsZero` |
| R6 | `:491` `_divUp(shares * fee, WAD)` | up | vault | `>= exact`, `< 1` share above; never 0 for `fee > 0`; `s < WAD / fee` pays exactly 1 share (rate `1 / s`), `s = 1` is 100% fee and a dead entry | `testFuzz_R6_redeemFee_roundsInFavourOfVault`, `testFuzz_fee_isCeilAndAtMostOneWeiAbove`, `test_R6_feeCeil_oneShareRequest_isEntirelyFee` |
| R7 | `:782` `convertToShares(maxWithdraw)` | down | vault | clamp `<= L / c_p`, `< 1` share below; paid `<= L` | `testFuzz_R7_liquidityClamp_roundsInFavourOfVault` |
| R8 | `:795` `convertToAssets(shares)` | down | vault | paid `< 1` wei below `shares c_p`; `>= shares >= 1` while `chi >= RAY` (not after a loss, R13-c) | `testFuzz_R8_R9_redeemFill_floorPayoutCeilBurn` |
| R9 | `:805` spUSDC `withdraw`: `ceil(paid * RAY / chi_s)` | up | spUSDC, against vault | `< 1` spUSDC share above per fill, `<= bal_s` for a single fill; batch of `n` can exceed `bal_s` by `n - 1` (C-1) | same, `test_BUG_processRedeemQueue_batchCeilBurnsExceedSpUsdcBalance` |
| R10 | `:765` spUSDC `redeem(shares)` in `_processCancelledDepositQueue`: `floor(s * chi_s / RAY)` | down | spUSDC, against canceller | one shot: refund `<= X`, loss `< 1 + c_s` wei; k chunks: `<= k - 1` wei below one shot, loss `< c_s + k`; budget `:744` `min(max, bal_s)` exact in spUSDC shares | `testFuzz_R10_cancelDepositAndSettle_roundsAgainstCancellingUser`, `testFuzz_R10_cancelDepositSettledInChunks_losesAtMostKMinusOneMore`, `test_R10_chunkedSettlement_example`, `test_R10_budgetIsVaultSpUsdcBalance_noConversion` |
| R11 | `:641`, `:690` `_rpow(vsr, dt) * chi / RAY` | half-up per step | neutral | equals the python mirror exactly on 112 rows; daily vs yearly drip differ by 172 RAY units at 5% | `test_R11_dripMatchesReferenceTable`, `test_R11_rpowDriftVsContinuous`, `test_R11_dripPathDependenceIsBounded` |
| R12 | `:660`, `:664` `convertToAssets` / `convertToShares` | down / down | vault | `assets >= shares`, `shares <= assets` (while `chi >= RAY`); `a - A(S(a)) < 1 + c_p`; `s - S(A(s)) <= 1` | `testFuzz_R12_*` (4 tests) |
| R13 | `:357` `chi = uint192(((TA - L) * RAY) / S)` | down, down (TA floor, then division floor) | against holders | `TA' in {TA - L - 1, TA - L}` for `S < RAY`, exactly `TA - L` iff `S \| (TA - L) RAY`; chi over-reduction `< RAY / S + 1` units; `chi' <= chi` (cast cannot truncate); largest succeeding loss `= TA` (chi 0), `TA + 1` underflows; `S == 0` underflows before dividing; k losses vs one: `0 <= TA_single - TA_k <= k` | `testFuzz_R13_*` (4 tests), `test_R13_*` (4 tests) |

`_divUp`: `_divUp(0, y) == 0` for every `y` including 0, `_divUp(k y, y) == k`,
`_divUp(k y + 1, y) == k + 1`, `_divUp(1, 0)` panics with division-by-zero: `test_divUp_*`,
`testFuzz_divUp_*`.

## (c) Quantities

**R13 `realizeLoss` derivation.** `TA = floor(S chi / RAY)`, `chi' = floor((TA - L) RAY / S)`.
Then `S chi' <= (TA - L) RAY` and `S chi' > (TA - L) RAY - S`, so `S chi' / RAY` lies in
`(TA - L - S / RAY, TA - L]`. For `S < RAY` (any 6-decimal supply below 1e21 USDC) the new
`totalAssets()` is `TA - L` when `S` divides `(TA - L) RAY` and `TA - L - 1` otherwise. In chi
units the reduction exceeds the exact `L RAY / S` by less than `RAY / S + 1`. Holders lose at
least `loss` (direction proven) and at most 1 wei more, and in the generic case exactly 1 wei
more (`testFuzz_R13_realizeLoss_floorsAgainstHolders_overRealisesAtMostOneWei` asserts the exact
characterisation). Harness, 1 000 000e6 deposited (`S = 990 405 184 109`, `TA = 999 999 999 998`):

| loss | new `totalAssets` | drop | new chi |
|---|---|---|---|
| 1 | 999 999 999 996 | 2 | 1009687768240663846587628160 |
| 999 999 999 | 998 999 999 998 | 1 000 000 000 | 1008678080474439529214223187 |
| 9 594 815 889 (= TA - S) | 990 405 184 109 | exact | 1e27 |
| 999 999 999 997 (= TA - 1) | 1 | exact | 1 009 687 (= RAY / S) |
| 999 999 999 998 (= TA) | 0 | exact | 0 (brick: `convertToShares` divides by zero) |
| 999 999 999 999 (= TA + 1) | revert, panic 0x11 | | |

`uint192` cast: `chi' <= (TA - L) RAY / S <= TA RAY / S <= chi < 2^192`, so no value that passes
the subtraction can be truncated (`testFuzz_R13_realizeLoss_castNeverTruncates`, chis up to
1.024e30). `S == 0`: `totalAssets()` is 0 and `0 - loss` underflows before the division
(`test_R13_realizeLoss_zeroSupply_revertsOnUnderflowNotDivision`). Path dependence: `k` losses
summing to `L` leave `chi_k <= chi_single` (floor is monotone and `S chi_i / RAY <= TA_{i-1} -
l_{i-1}`), with `(chi_single - chi_k) S < k (RAY + S)` and `0 <= TA_single - TA_k <= k`
(`testFuzz_R13_realizeLoss_sequenceVsSingle_pathDependenceBound`, k in [2, 6]). One aggregated
loss is strictly better for holders than a stream of small ones.

**Round-trip loss (deposit X -> fill -> requestRedeem all, fee 0 -> process).** Unchanged: four
floors (R1, R3, R4, R8), `X - out < 2 + c_s + c_p` wei for any chis, at most 4 wei at harness
chis (first at X = 836), identical on the queued-deposit path
(`testFuzz_roundTrip_*`, `test_roundTrip_maxLossExample_836wei`).

**Deposit -> cancel -> settle.** One shot: refund `= floor(floor(X / c_s) c_s)`, loss `< 1 + c_s`
(harness: `<= 2`). Settled in k chunks `s_1..s_k`: refund `= sum floor(s_i c_s) >= floor(s c_s) -
(k - 1)`, so at most `k - 1` wei below one shot and `X - refund < c_s + k`. Harness example,
1000e6 -> 954 532 691 spUSDC: one shot 999 999 999; 17 one-share chunks then the rest still
999 999 999; 18 one-share chunks then the rest 999 999 998 (each 1-share chunk leaves 0.0476
USDC in spUSDC, 18 of them tip the remainder's floor). The budget `min(maxSavingsShares,
spUSDC.balanceOf(vault))` has no conversion: with 12 345 spUSDC left in the vault exactly 12 345
shares settle and the entry stays at the head with the rest.

**Capacity chain.** `totalSupply <= maxCapacity` after any fill and any further processing;
unfillable residual `< 1 + (2 + c_s) / c_p` shares (harness: at most 2); residual 2 burns 1
spUSDC share per attempt without minting (F-4). Overflow: deposits revert iff
`maxCapacity - totalSupply > type(uint256).max / nowChi()`:

| chi_p | `type(uint256).max / chi` |
|---|---|
| 1e27 (fresh) | 1.15792e50 |
| 1.0097e27 (harness) | 114681085459589801375833087904206311575507395147570 |
| 1.0602e27 (harness + 1y at 5%) | 109220081390085525123890485623544109152849575647725 |
| 1.024e30 (10y at 100%) | 1.13e47 |

**Zero-mint region (F-4).** Unchanged: `convertToShares(spUSDC.convertToAssets(s)) == 0` iff
`s <= ceil((K + 1) RAY / chi_s) - 1`, `K = (chi_p - 1) / RAY` (8-row table in
`test_F4_zeroMintRegion_table`, harness `sMax = 1`).

**Drip drift and reference table.** Unchanged (112 rows exact; `_rpow` drift vs continuous
`-318 029` RAY units at 4%/365d, `+7 714 388 883` at 100%/10y, relative `< 1e-18`).

**Rate mismatch 3x3 (1 000 000e6, 365 days, surplus in USDC wei).** Unchanged: diagonal +1/0/0,
off-diagonal +-10 000e6 per 1% of spread, exact values in `test_rateMismatch_3x3_surplusAfter365d`.

## (d) Unsettled

- C-1 fix choice (clamp in spUSDC shares vs `redeem` vs pre-check) still open; every option keeps
  the other rows' directions.
- R13-a is a 1-wei accounting nit per call; whether `LossRealized.loss` should report the realised
  drop (loss + 1) or the input is a product decision.
- R13 bounds assume `S < RAY` (below 1e21 USDC of supply). For `S >= RAY` the drop can reach
  `loss + ceil(S / RAY)`; not reachable at 6 decimals.
- The k-chunk and k-loss bounds are fuzzed for k <= 6 and proven analytically for any k; not
  exhaustively verified beyond that.
