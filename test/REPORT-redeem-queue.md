# Redeem-queue campaign report (`test/RedeemQueue.t.sol`)

Branch `campaign/redeem-queue`. 32 tests, all pass (`FOUNDRY_FUZZ_RUNS=5000`). The two
`test_BUG_*` tests prove the new bug with `vm.expectRevert`, so they pass while the bug exists and
will fail once it is fixed.

Harness indexes after `setUp` (both VSRs frozen at RAY): chi_s = 1.047633055711877768967605062e27,
chi_p = 1.009687768242461209408770821e27. A 1_000_000e6 deposit gives the vault 954_532_691_143
spUSDC and mints 990_405_184_109 spPRIME. Notation: L = USDC in spUSDC, S = spUSDC held by the
vault, A = `spUSDC.maxWithdraw(vault)` = min(L, floor(S * chi_s / RAY)), rem = floor(A * RAY / chi_p).

## (a) Bugs and suspicious behaviour

### RQ-1 · Medium · A multi-request `processRedeemQueue` batch can revert on spUSDC ceil-rounding

**Location:** `src/SparkPrimeVault.sol:675` (budget computed once from `maxWithdraw`) and
`src/SparkPrimeVault.sol:698` (`spUSDC.withdraw(assets_)` per fill, burns `ceil(assets * RAY / chi_s)`).

**What happens:** The share budget `remaining_` is derived once from `A`, and each of the N fills
burns spUSDC rounded up independently. The sum of the per-fill burns can exceed the single
aggregate burn by up to N-1 wei of spUSDC. When the budget is fully consumed (the vault's spUSDC
claim or the USDC liquidity is binding, which is the normal state once `take()` has deployed
capital and the queue exceeds what is left), the last fill's `withdraw` reverts inside spUSDC
with `SparkVault/insufficient-balance`, rolling back the whole batch. For a single fill the
bound always holds (proved by fuzz), so the revert needs N >= 2.

**Scenario 1 (vault-share bound), `test_BUG_processRedeemQueue_batchRevertsOnCeilRounding_vaultSharesBound`:**
alice deposits 1_000_000e6; the taker takes 954_531_688_310 spUSDC leaving S = 1_002_833
(worth A = 1_050_601 USDC, rem = 1_040_520 shares). alice queues two redeems of 520_260 shares.
Each pays 525_300 USDC (sum 1_050_600 <= A) but burns 501_417 spUSDC each, 1_002_834 total,
one more than held. `processRedeemQueue(max, 2)` reverts `SparkVault/insufficient-balance`.
Processing one request per call works: first pays 525_300 and leaves 501_416 spUSDC; the second
call re-derives a budget of 520_258 shares, pays 525_298 USDC and leaves 2 shares queued and
1 wei spUSDC in the vault.

**Scenario 2 (USDC-liquidity bound), `test_BUG_processRedeemQueue_batchRevertsOnCeilRounding_liquidityBound`:**
alice deposits 1_000_000e6, spUSDC's taker drains 2 wei so L = 999_999_999_998 (vault claim
999_999_999_999). Three requests of 22_947_880_715 / 299_586_688_493 / 667_870_614_900 shares
(sum = rem = 990_405_184_108) pay 23_170_194_465 + 302_489_014_899 + 674_340_790_633 =
999_999_999_997 USDC (fits L) but burn 22_116_708_078 + 288_735_653_434 + 643_680_329_632 =
954_532_691_144 spUSDC against S = 954_532_691_143. `processRedeemQueue(max, 3)` reverts
`SparkVault/insufficient-balance`. Split 2 + 1 it succeeds; carol is paid 674_340_790_631
(2 wei less than in the batch) and 2 shares remain queued.

**Frequency (Python model at the harness indexes, budget fully consumed, random request sizes):**
2 fills 0.05 %, 3 fills 3.2 %, 5 fills 7.5 %, 10 fills 17 %, 50 fills 45 % of batches revert.
`testFuzz_processRedeemQueue_batchOverburnBoundedByFillsMinusOne` reaches the revert branch on
its first fuzz run when the prime VSR has grown the claim past the backing.

**Impact:** The rebalancer's batch call reverts non-deterministically whenever the queue is
drained to the last wei of available backing, which is exactly the situation after a `take()`
or a liquidity crunch. Funds are never lost (the revert is atomic). Workaround is
`maxRequests_ = 1` or a `maxShares_` a few wei below the budget. Gas is wasted per failed
attempt; a full-drain batch of 50 fails about half the time.

**Fix:** Re-read the bound inside the loop so each fill is individually safe, e.g. before line 687
`uint256 cap_ = convertToShares(IERC4626Like(savings).maxWithdraw(address(this))); if (cap_ < remaining_) remaining_ = cap_; if (remaining_ == 0) break;`
(the single-fill bound then applies to every iteration). Alternatively subtract `maxRequests_ - 1`
spUSDC-equivalents from the initial budget, or burn via `redeem(convertToShares(assets_))` and
accept paying 1 wei less per fill.

**Proving tests:** the two `test_BUG_*` above; `testFuzz_processRedeemQueue_singleFillNeverReverts`
(the N = 1 bound, 5000 runs over random VSRs, warps, drains and takes);
`testFuzz_processRedeemQueue_batchOverburnBoundedByFillsMinusOne` (burn excess <= N-1 when the
batch succeeds, revert reason and no state change when it does not).

### RQ-2 · Low · USDC paid to `recipient == address(vault)` is stuck

**Location:** `src/SparkPrimeVault.sol:698` (no check on `request.recipient`), `src/SparkPrimeVault.sol:611`
(`availableLiquidAssets` only counts spUSDC), `src/SparkPrimeVault.sol:294` (`take` moves spUSDC only).

**Scenario, `test_processRedeemQueue_recipientIsVault_usdcStuck`:** alice deposits 100_000e6 and
requests all 99_040_518_410 shares with recipient = the vault. The fill pays 99_999_999_998 USDC
to the vault contract. `availableLiquidAssets()` stays at 1 wei, `take()` leaves the USDC
untouched, and a later redeemer (bob) cannot be paid from it when spUSDC is illiquid. No
function in the contract moves USDC out except through the spUSDC deposit in `requestDeposit`
(which pulls from `msg.sender`, not from the vault's own balance). Same class as F-6
(informational there because USDC is not meant to be custodied); this is a user-triggerable way
to put USDC there. Self-inflicted only; a proxy upgrade recovers it.

**Companion, `test_processRedeemQueue_recipientIsSpUsdc_donatesToSpUsdc`:** recipient = spUSDC
burns the vault's 95_453_269_113 spUSDC while spUSDC's USDC balance does not change: the
99_999_999_998 USDC is donated to spUSDC holders. Also self-inflicted.

**Fix:** `require(recipient_ != address(this) && recipient_ != savings, "SparkPrimeVault/invalid-recipient")`
in `requestRedeem` (and the same for `requestDeposit`).

### RQ-3 · Info · Cancelled and ghost entries consume `maxRequests_`

**Location:** `src/SparkPrimeVault.sol:678` (`end_` sized by index) and `:685` (`continue`).

**Scenario, `test_processRedeemQueue_cancelledEntryCountsTowardMaxRequests`:** alice, bob, carol
queue 99_040_518_410 shares each; alice cancels. `processRedeemQueue(max, 1)` pays nobody and
moves the head from 0 to 1; the next call pays bob 99_999_999_998. Combined with F-5 ghosts this
lets anyone make a bounded number of rebalancer calls no-ops (one wasted call per `maxRequests_`
ghosts); the head still advances so it is throughput griefing, already covered by F-5.

### RQ-4 · Info · `pause` freezes redeemers while `take` keeps working (quantified F-7)

`test_processRedeemQueue_pausedBlocksRedeemsNotTake`: alice queues 99_040_518_410 shares (claim
99_999_999_998 USDC); guardian pauses; `processRedeemQueue` and `cancelRedeemRequest` revert
`SparkPrimeVault/paused`; the taker removes all 95_453_269_114 spUSDC; after unpause
`availableLiquidAssets() == 0` and the claim stays queued in full. Known (F-7), no new finding.

### RQ-5 · Info · Notional index: queue-time prime yield is paid from other holders' backing

`test_processRedeemQueue_primeYieldAccruesWhileQueued`: alice and bob deposit 100_000e6 each;
prime VSR 5 %; alice queues 99_040_518_410 shares (99_999_999_998 USDC at request time). After
365 days chi_p = 1.060172156654584269839902363e27 and the fill pays 104_999_999_998 USDC
(5_000_000_000 more). spUSDC VSR was RAY so backing did not grow: bob's notional claim is
104_999_999_998 against 95_000_000_000 USDC worth of spUSDC. Known as I-7; the test quantifies it.

Conversely `test_processRedeemQueue_spUsdcYieldStaysInVault`: spUSDC at 5 % for a year, prime
flat: alice is paid 99_999_999_998 and 5_000_000_000 USDC worth of spUSDC stays in the vault with
`totalSupply == 0` and `totalAssets() == 0`.

## (b) Properties that held (each with its test)

1. Single fill never reverts and pays `floor(fill * chi_p / RAY)`, burning exactly
   `ceil(paid * RAY / chi_s)` spUSDC, under random VSRs in [RAY, MAX_VSR], warps up to 5 years,
   random drains and takes: `testFuzz_processRedeemQueue_singleFillNeverReverts` (5000 runs).
2. Single-fill rounding: `0 <= fill * chi_p - paid * RAY < RAY` and
   `0 <= burned * chi_s - paid * RAY < chi_s`; spUSDC value given up `< paid + chi_s / RAY + 1`:
   `testFuzz_processRedeemQueue_singleFillRoundingBounds` (5000 runs).
3. Batch over-burn is bounded by N-1 wei of spUSDC above the aggregate burn when the batch
   succeeds: `testFuzz_processRedeemQueue_batchOverburnBoundedByFillsMinusOne`.
4. Total USDC withdrawn in a batch never exceeds `A` (so `SparkVault/insufficient-liquidity` is
   unreachable from the queue; only the share-balance revert of RQ-1 is): follows from
   `sum floor(s_i * chi_p / RAY) <= rem * chi_p / RAY <= A`, checked in
   `testFuzz_processRedeemQueue_neverPaysMoreThanSharesTimesChi` (`liqBefore - liqAfter == sum payouts`).
5. Liquidity-bound partial fill (L = 300_000e6): pays 299_999_999_999, leaves 1 wei USDC in
   spUSDC, request remainder 693_283_628_876, head stays at 0; after liquidity returns the claim
   binds (699_999_999_999) and the rest pays 699_999_999_998, head 1, vault keeps 1 wei spUSDC:
   `test_processRedeemQueue_partialFill_spUsdcLiquidityBound`.
6. Share-bound partial fill (S = 300_000e6 spUSDC): pays 314_289_916_712, burns 299_999_999_999,
   remainder 679_130_821_283; a 1-wei spUSDC claim converts to 0 prime shares and is a no-op:
   `test_processRedeemQueue_partialFill_vaultSharesBound`.
7. FIFO with cancelled entries skipped; partial entry stays at the head; later entries never fill
   before an earlier open one even when they would fit: `test_processRedeemQueue_fifo_skipsCancelled`,
   `test_processRedeemQueue_headBlocksLaterSmallerRequests`.
8. `maxRequests_` honoured exactly (0 is a no-op, values above the queue length clamp);
   `maxShares_` honoured to the share (q-1 then 11 across two entries); `maxShares_ = 0` and empty
   queue are no-ops: `test_processRedeemQueue_maxRequests`, `test_processRedeemQueue_maxShares`,
   `test_processRedeemQueue_maxSharesZero_noop`, `test_processRedeemQueue_emptyQueue_noop`.
9. Fee: 1 % on 1_000_000e6 shares burns exactly 10_000_000_000, queues 990_000_000_000, pays
   999_590_890_560 and burns 954_142_182_810 spUSDC; 999_999_999_999 shares also burn
   10_000_000_000 (rounds up); full balance with fee is accepted (fee 990_405_185 on
   99_040_518_410); 1-wei request becomes a ghost (F-5, referenced, not re-reported):
   `test_requestRedeem_feeOnePercent_exactAmounts`, `test_requestRedeem_feeRoundsUp`,
   `test_requestRedeem_fullBalanceWithFee`, `test_requestRedeem_oneWeiWithFee_ghostEntry_F5`.
10. 200 users x 5_000e6, 4 batches of 50: every user paid 4_999_999_998, head 200,
    `pendingRedeemShares == 0`, `balanceOf(vault) == 0`, `totalSupply == 0`, 200 wei spUSDC dust
    left; 8_046_221 gas for 200 fills, 40_231 gas per fill:
    `test_processRedeemQueue_200UsersIn4BatchesOf50`.
11. `availableLiquidAssets() == 0` (drained spUSDC or full `take()`) makes processing a no-op
    without revert; 1 wei spUSDC returned is still a no-op:
    `test_processRedeemQueue_zeroLiquidity_noop`, `test_processRedeemQueue_afterFullTake_noop`.
12. `requestRedeem` reverts `SparkPrimeVault/insufficient-balance` at balance + 1,
    `SparkPrimeVault/below-minimum` for 0 shares and for 990_405_184 shares when
    `minWithdraw = 1_000e6` (999_999_999 wei), `SparkPrimeVault/invalid-recipient` for
    address(0): `test_requestRedeem_revertsInsufficientBalanceBoundary`,
    `test_requestRedeem_revertsZeroShares`, `test_requestRedeem_minWithdrawBoundary`,
    `test_requestRedeem_revertsRecipientZero`.
13. Invariants over random 24-step sequences (deposit, request, cancel, process with random
    `maxShares_`/`maxRequests_`, drain, return, take, warp with both VSRs > RAY and a 0.1 % fee):
    `balanceOf(vault) == pendingRedeemShares == sum of open request shares`, every entry before
    `redeemHead` has 0 shares, `redeemHead <= queue length`:
    `testFuzz_processRedeemQueue_balanceOfVaultEqualsPendingRedeemShares` (5000 runs).
14. Every batch pays each recipient exactly `sum floor(filled_i * chi_p / RAY)`, burns exactly
    the filled shares from `totalSupply`, respects `maxShares_`, and the spUSDC given up is worth
    at most 1 wei USDC per fill above what was paid:
    `testFuzz_processRedeemQueue_neverPaysMoreThanSharesTimesChi` (5000 runs).

## (c) Unsettled

- RQ-1 frequency numbers come from a Python model at the harness indexes; the on-chain rate
  depends on the live chi_s/chi_p fractional parts and request-size distribution. The direction
  (grows with N, zero for N = 1) is proven by the tests.
- Whether queue-time prime yield paid from other holders' backing (RQ-5) is acceptable is a
  product decision (I-7); the tests only quantify it.
