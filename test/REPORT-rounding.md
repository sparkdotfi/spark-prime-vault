# Rounding campaign report: `src/SparkPrimeVault.sol`

Branch `campaign/rounding`. File `test/Rounding.t.sol` (38 tests, 37 pass, 1 deliberate failing
proof), reference generator `test/tables/drip_reference.py` -> `test/tables/drip.csv`,
`test/tables/DripTable.sol`. Final run: `FOUNDRY_FUZZ_RUNS=10000 forge test --match-path
test/Rounding.t.sol`: 37 passed, 1 failed (`test_BUG_...`), 0 skipped.

Notation: `c_s = chi_s / RAY` (spUSDC index), `c_p = chi_p / RAY` (spPRIME index), both >= 1.
"Harness chis" = `chi_s = 1047633055711877768967605062`, `chi_p = 1009687768242461209408770821`
(verified equal to the python `_rpow` mirror in `test_R11_harnessIndexesMatchReference`).
Random chis = VSR anywhere in `[RAY, MAX_VSR]` on both vaults, up to 10 years of accrual.

## (a) Findings

### N-1 · Medium · `processRedeemQueue` batch reverts when per-fill ceil burns exceed the vault's spUSDC

**Location:** `src/SparkPrimeVault.sol:675` (clamp `convertToShares(availableLiquidAssets())`) and
`:698` (`spUSDC.withdraw(assets_, ...)`, which burns `ceil(assets * RAY / chi_s)` spUSDC shares).

**What happens:** `availableLiquidAssets()` is `spUSDC.maxWithdraw(vault) = min(liquidity,
floor(bal_s * c_s))`. That bound is correct for ONE fill: `ceil(paid / c_s) <= bal_s` whenever
`paid <= floor(bal_s * c_s)`. For `n` fills in one call the vault burns
`sum ceil(paid_i / c_s)`, which can exceed `bal_s` by up to `n - 1` shares. The `n`-th `withdraw`
then reverts with `SparkVault/insufficient-balance` and the whole batch is undone.

**Exact example (harness chis, `test_BUG_processRedeemQueue_batchCeilBurnsExceedSpUsdcBalance`):**
vault holds 3548 spUSDC shares (after `take()`), `maxWithdraw = 3717` USDC, clamp
`remaining_ = 3681` spPRIME shares. Two queued requests of 2396 and 1285 shares (= 3681) pay
2419 + 1297 USDC and burn `ceil(2419/1.0476) + ceil(1297/1.0476) = 2310 + 1239 = 3549 > 3548`.
`processRedeemQueue(max, 2)` reverts. `processRedeemQueue(max, 1)` twice works (second call
re-clamps to 1283 shares, leaves 2 shares queued and 1 spUSDC share in the vault):
`test_processRedeemQueue_batchCeilBurn_oneRequestPerCallSucceeds`.

**When it triggers:** only when the batch consumes the vault's whole spUSDC balance (queue larger
than liquidity, the normal state of a redeem queue) and `c_s > 1`. Frequency over random splits
at harness chis with the balance exhausted: 2 requests 0.04%, 3 requests 3.2%, 5 requests 7.8%,
10 requests 17%. Over random chis in `[1, 3]` and 2..5 requests: 22%.

**Impact:** no funds at risk; batch processing reverts unpredictably, the rebalancer must fall
back to `maxRequests_ = 1` or pass a `maxShares_` a few shares under the clamp. Breaks any
automation that calls `processRedeemQueue(max, max)`.

**Fix options:** clamp in spUSDC shares instead of assets: track `remainingSavings_ = bal_s`
and per fill require `ceil(assets_ * RAY / chi_s) <= remainingSavings_` (or
`min(assets_, spUSDC.convertToAssets(remainingSavings_ - 1))`); or call
`spUSDC.redeem(min(bal_s, ceil(...)))` and pay what that returns (underpays the user by < 1 wei
instead); or simply `break` before the fill when `spUSDC.previewWithdraw(assets_) >
spUSDC.balanceOf(vault)`.

### N-2 · Low · Deposits below `c_s` USDC wei buy 0 spUSDC shares and are unrecoverable

**Location:** `src/SparkPrimeVault.sol:366` (`spUSDC.deposit`) with `minDeposit = 0` (line 353).

**What happens:** `requestDeposit(X)` with `X < c_s` (at harness chis: `X = 1`) transfers X USDC
into spUSDC, receives 0 spUSDC shares, pushes a 0-share entry; `cancelDepositRequest` reverts
`no-request`, nothing is minted. The USDC is donated to spUSDC holders. Refinement of F-5 (there
the request amount itself is 0). Test: `test_R1_dustDeposit_belowOneSpUsdcShare_isLostToSpUsdc`.
Also observed in `testFuzz_R3_R4_fillConversion_roundsInFavourOfVault` for random chis (e.g. 50
wei at `c_s > 50`). **Fix:** `minDeposit >= ceil(c_s)` at deploy, or require `savingsShares_ != 0`.

### Refuted or corrected rows of R1..R12

No row is refuted on direction. Two bounds in the review are tightened or corrected:

- **R9** "<= 1 wei spUSDC share per fill, acceptable": true per fill, but the review did not note
  that the `maxWithdraw` clamp is per-call while the ceil is per-fill, so a batch can need up to
  `n - 1` shares more than the vault holds (N-1 above).
- **R10 / R2 / round trip**: the review's bounds assume `c_s, c_p ~ 1`. The exact bounds scale
  with the indexes (`1 + c_s`, `1 + 1/c_s`, `2 + c_s + c_p`), which matters once the indexes grow
  (at `c_s = 2`, a cancel can lose 2 wei; at harness chis everything stays at the stated 1-2 wei).

## (b) Proven rounding table

All sites fuzzed over random chis (10000 runs) with the exact rational checked by
cross-multiplication (`value * den <= num` and `num - value * den < den`, or the reverse for ceil).

| # | Site (`src/SparkPrimeVault.sol`) | Direction | Favours | Proven bound | Test |
|---|---|---|---|---|---|
| R1 | `:366` spUSDC `deposit`: `floor(X * RAY / chi_s)` | down | spUSDC | `< 1` spUSDC share below exact; `X < c_s` gives 0 (N-2) | `testFuzz_R1_spUsdcDeposit_roundsInFavourOfSpUsdc` |
| R2 | `:633-636` `spUSDC.convertToShares(convertToAssets(A))` | down, down | vault | admitted `<= A c_p / c_s`, gap `< 1 + 1/c_s <= 2` spUSDC shares; `totalSupply <= cap` | `testFuzz_R2_capacityToSavingsShares_roundsInFavourOfVault` |
| R3 | `:653` `spUSDC.convertToAssets(s)` | down | vault | `< 1` USDC wei below `s c_s`; vault's spUSDC always worth `>=` assets credited | `testFuzz_R3_R4_fillConversion_roundsInFavourOfVault` |
| R4 | `:654` `convertToShares(assets)` | down | vault | `< 1` share below `assets / c_p`; zero-mint region exactly `s <= sMax` (section c) | same, `testFuzz_F4_zeroMintRegion_exactCharacterisation` |
| R5 | `:426` `shares * chi / RAY >= minWithdraw` | down | vault (stricter) | floor never admits what the exact check rejects; rejects exact values in `[min - 0.5, min)` | `testFuzz_R5_minWithdraw_floorIsStricterThanExact`, `test_R5_minWithdraw_floorRejectsRequestWithinHalfWeiOfMinimum` |
| R6 | `:435` `_divup(shares * fee, WAD)` | up | vault | `>= exact`, `< 1` share above; never 0 for `fee > 0` | `testFuzz_R6_redeemFee_roundsInFavourOfVault`, `testFuzz_fee_isCeilAndAtMostOneWeiAbove` |
| R7 | `:675` `convertToShares(maxWithdraw)` | down | vault | clamp `<= L / c_p`, `< 1` share below; paid `<= L` | `testFuzz_R7_liquidityClamp_roundsInFavourOfVault` |
| R8 | `:688` `convertToAssets(shares)` | down | vault | paid `< 1` wei below `shares c_p`; `>= shares >= 1` | `testFuzz_R8_R9_redeemFill_floorPayoutCeilBurn` |
| R9 | `:698` spUSDC `withdraw`: `ceil(paid * RAY / chi_s)` | up | spUSDC, against vault | `< 1` spUSDC share above per fill, `<= bal_s` for a single fill; batch of `n` can exceed `bal_s` by `n - 1` (N-1) | same, `test_BUG_processRedeemQueue_batchCeilBurnsExceedSpUsdcBalance` |
| R10 | `:411` spUSDC `redeem(shares)`: `floor(s * chi_s / RAY)` | down | spUSDC, against user | refund `<= X`, loss `< 1 + c_s` wei (harness: `<= 2`) | `testFuzz_R10_cancelDeposit_roundsAgainstCancellingUser` |
| R11 | `:575`, `:621` `_rpow(vsr, dt) * chi / RAY` | half-up per step | neutral | equals the python mirror exactly on 112 (vsr, dt, chi0) rows; daily vs yearly drip differ by 172 RAY units at 5% | `test_R11_dripMatchesReferenceTable`, `test_R11_rpowDriftVsContinuous`, `test_R11_dripPathDependenceIsBounded` |
| R12 | `:590`, `:594` `convertToAssets` / `convertToShares` | down / down | vault | `assets >= shares`, `shares <= assets`; `a - A(S(a)) < 1 + c_p`; `s - S(A(s)) <= 1` | `testFuzz_R12_*` (4 tests) |

`_divup`: `_divup(0, y) == 0` for every `y` including 0 (the `x_ != 0` guard stops the unchecked
underflow), `_divup(k y, y) == k`, `_divup(k y + 1, y) == k + 1`, `_divup(1, 0)` panics with
division-by-zero: `test_divup_*`, `testFuzz_divup_*`.

## (c) Quantities

**Round-trip loss (deposit X -> fill -> requestRedeem all, fee 0 -> process).** Four floors
(R1, R3, R4, R8): proven `X - out < 2 + c_s + c_p` wei for any chis
(`testFuzz_roundTrip_instantDepositRedeem_lossBound`, 10000 runs, X in [1, 1e15]). At harness
chis the bound is 4.057 so the loss is **at most 4 wei**; brute force over X in [1, 4e6]: max 4
wei (first at X = 836: 836 -> 797 spUSDC -> 834 USDC -> 825 shares -> 832 USDC), histogram
{1 wei: 1, 2 wei: 3 781 586, 3 wei: 216 766, 4 wei: 1 647}. Fuzz at harness chis asserts `<= 4`
(`testFuzz_roundTrip_instantDepositRedeem_harnessChis_lossAtMost4`,
`test_roundTrip_maxLossExample_836wei`). Queued-deposit path: identical bound and max
(`testFuzz_roundTrip_queuedDepositRedeem_*`). The vault keeps `s - ceil(out / c_s)` spUSDC dust
(2 shares in the X = 836 example); it never goes short on a single round trip.

**Capacity chain.** `totalSupply <= maxCapacity` after any fill and any further queue processing
(`testFuzz_capacity_totalSupplyNeverExceedsMaxCapacity`). Unfillable residual after repeated
processing: `residual < 1 + (2 + c_s) / c_p` shares, i.e. `residual * chi_p < chi_p + 2 RAY +
chi_s` (`testFuzz_capacity_underUseBound`). At harness chis: **at most 2 shares**
(`testFuzz_capacity_underUseBound_harnessChis_atMost2`); residual 1 computes `remaining_ = 0`,
residual 2 computes `remaining_ = 1` spUSDC share which mints 0 and burns 1 spUSDC share from the
head request per call (F-4, `test_capacity_residualTwo_isUnfillable_andDustBurnsSpUsdc`).

**Zero-mint region (F-4).** `convertToShares(spUSDC.convertToAssets(s)) == 0` iff `s <= sMax`
with `K = (chi_p - 1) / RAY` and `sMax = ceil((K + 1) RAY / chi_s) - 1`. For `chi_p in (RAY, 2 RAY)`
this is `sMax = 1` for any `chi_s > RAY` and `0` at `chi_s == RAY`.

| chi_s | chi_p | max zero-mint s |
|---|---|---|
| 1e27 | 1e27 | 0 |
| 1.0476e27 (harness) | 1.0097e27 (harness) | 1 |
| 1e27 | 1.0097e27 | 1 |
| 1.0476e27 | 1e27 | 0 |
| 1.5e27 | 1.5e27 | 1 |
| 1e27 | 2e27 | 1 |
| 1e27 | 2e27 + 1 | 2 |
| 2e27 | 10e27 | 4 |

(`test_F4_zeroMintRegion_table`, brute-forced; `testFuzz_F4_zeroMintRegion_exactCharacterisation`
checks the formula against the live vault for random chis.)

**Drip drift (`_rpow` vs continuous `chi0 * vsr^t`, 80-digit Decimal, RAY units, chi0 = RAY).**

| vsr | 365 d | 10 y |
|---|---|---|
| FOUR_PCT | -318 029 | -4 526 538 |
| FIVE_PCT | -4 298 403 | -66 682 338 |
| MAX_VSR | +1 506 719 | +7 714 388 883 |

Relative drift `< 1e-18` after 10 years at 100% APY (chi = 1.024e30). On a 1e12 USDC-wei position
that is `< 1e-6` wei, invisible at 6 decimals. `nowChi()` / `drip()` equal the reference table
exactly for every VSR constant x {1 s, 60 s, 1 h, 1 d, 30 d, 365 d, 10 y} x {chi0 = RAY, chi0 =
harness} (112 rows).

**Rate mismatch, 1_000_000e6 deposited at harness chis, 365 days, surplus = spUSDC backing -
`totalAssets()` in USDC wei (`test_rateMismatch_3x3_surplusAfter365d`, exact):**

| spUSDC \ spPRIME | 0% | 4% | 5% |
|---|---|---|---|
| 0% | +1 | -39 999 999 999 | -49 999 999 999 |
| 4% | +40 000 000 000 | 0 | -10 000 000 000 |
| 5% | +50 000 000 000 | +10 000 000 000 | 0 |

Backing at 0/4/5%: 999 999 999 999 / 1 039 999 999 998 / 1 049 999 999 998; notional:
999 999 999 998 / 1 039 999 999 998 / 1 049 999 999 998. The 5%/4% spread is exactly 10 000e6;
4%/5% is a 10 000e6 deficit that only a `setChi` can realise (out of scope).

## (d) Unsettled

- N-1 fix choice (clamp in spUSDC shares vs `redeem` vs pre-check) is a design decision; all
  three keep every other row's direction.
- The round-trip and capacity bounds are proven analytically and fuzzed to 10000 runs, not
  exhaustively verified beyond X <= 4e6 at harness chis.
- Drift of chained drips (daily vs yearly) was measured at one rate (5%, 172 RAY units over 365
  days) and bounded loosely at 400; no general bound derived.
