# spPRIME invariant campaign report

Branch `campaign/invariants`, files `test/invariants/{a_init,b_flows_user,c_flows_admin}.sol`,
`test/invariants/d_invariants.t.sol`. Harness: `test/LocalTestBase.t.sol` (real spUSDC code,
6-decimal mock USDC, ugly starting indexes chi_s = 1.0476e27, chi_p = 1.0097e27, `src/` with the
F-1 and F-3 review patches).

Final run: `FOUNDRY_INVARIANT_RUNS=100 FOUNDRY_INVARIANT_DEPTH=500 forge test --match-path
'test/invariants/*.t.sol' -vv` -> **16 passed, 0 failed** (15 invariants x 100 runs x 500 calls =
50,000 handler calls per invariant, 0 handler reverts, plus 1 unit PoC).

## (a) Violations and findings

### N-1 Low: `processRedeemQueue` reverts when the vault's spUSDC balance is the binding limit

- Location: `src/SparkPrimeVault.sol:675` (`remaining_ = _min(maxShares_, convertToShares(availableLiquidAssets()))`)
  and `src/SparkPrimeVault.sol:698` (`IERC4626Like(savings).withdraw(assets_, request.recipient, address(this))`).
- Mechanism: `remaining_` is sized from `spUSDC.maxWithdraw(vault)` in USDC (a single floor), but
  every entry is paid with spUSDC `withdraw(assets_)`, which burns `ceil(assets_ * RAY / chi_s)`
  spUSDC shares (review rounding site R9). Across k entries the ceilings can add up to k-1 shares
  more than the balance; when the limit is the vault's spUSDC balance rather than spUSDC's USDC
  liquidity, the last fill reverts with `SparkVault/insufficient-balance` and the whole call
  (including the entries already paid in that call) is rolled back.
- Exact sequence (harness numbers): alice `requestDeposit(100e6)`; alice `requestRedeem(1)` x110
  (fee 0); taker `take(vaultSpUsdc - 100)` so the vault holds exactly 100 spUSDC shares;
  `spUsdc.maxWithdraw(vault) == 104`, `convertToShares(104) == 103`; rebalancer
  `processRedeemQueue(type(uint256).max, 110)` reverts `SparkVault/insufficient-balance` on the
  101st entry (each entry pays 1 USDC-wei and burns 1 spUSDC share). Workaround
  `processRedeemQueue(max, 1)` x110 succeeds 99 times, pays alice 99 wei, leaves `redeemHead = 99`,
  1 spUSDC share stranded (`convertToShares(maxWithdraw = 1) == 0`) and 11 open entries.
- Impact: operational. The rebalancer's batch call reverts instead of paying what it can; no
  funds at risk; the safe `maxShares_`/`maxRequests_` must be computed off-chain. With many
  large entries the same over-burn happens with probability driven by rounding fractions, not
  only with 1-wei entries. Zero-fee 1-share entries (F-5) make it deterministic and cheap to set
  up for a user.
- Test: `test_BUG_processRedeemQueueRevertsOnCeilBurnWhenBalanceBinds` (passes by asserting the
  revert). The handler also wraps `processRedeemQueue` in try/catch and counts this reason
  (`redeemProcessReverts`); any other reason fails `invariant_O`.
- Fix options: pay with `redeem(convertToShares_s(assets_))` (user takes the <=1 wei rounding
  instead of the vault), or clamp `remaining_` by
  `convertToShares(spUSDC.convertToAssets(balance - k))`, or break out of the loop when the next
  ceil-burn exceeds the remaining balance.
- Severity: Low.

No invariant A..O was violated in any run. Known findings observed live by the handler counters
(not re-reported): F-4 zero-share dust fills (`zeroShareFills`, 4 occurrences in the 15 sampled
last-runs), F-5 ghost entries (65 zero-amount deposit entries, 38 fee-eaten redeem entries),
F-2 cancels blocked after the backing was taken/spent (`cancelDepositBlockedF2`, 18 skips).

## (b) Invariants that held (100 runs x depth 500, 50,000 calls each, 0 reverts)

| Name | Claim |
|---|---|
| `invariant_A_sumOfBalancesEqualsTotalSupply` | sum of balances over 6 users + vault escrow == totalSupply |
| `invariant_B_vaultBalanceEqualsPendingRedeemShares` | balanceOf(vault) == pendingRedeemShares (no donations in the campaign) |
| `invariant_C_pendingDepositEqualsSumOfOpenDepositEntries` | pendingDepositSavingsShares == sum of depositQueue[i].shares, i in [0, length) |
| `invariant_D_pendingRedeemEqualsSumOfOpenRedeemEntries` | pendingRedeemShares == sum of redeemQueue[i].shares |
| `invariant_E_headBookkeeping` | every entry strictly before depositHead / redeemHead has shares == 0; heads <= length |
| `invariant_F_totalSupplyNeverExceedsCapacityViaMint` | no mint ever pushed totalSupply above maxCapacity as set at mint time (capacity was set at or below supply in 20% of setCapacity calls) |
| `invariant_G_chiMonotonicAndDripConsistent` | nowChi() >= last observed chi; drip() == nowChi(); chi/rho updated |
| `invariant_H_solvencyWhenSpUsdcRateGePrimeRate` | spUSDC value held minus value owed to open deposit entries + epsilon >= totalAssets(), while spUSDC VSR >= spPRIME VSR always held and taker holds nothing; epsilon = redeemFills * ceil(chi_s/RAY) + 2 wei (one over-burned spUSDC share per redeem fill, R9; deposit side contributes <= 1 wei total) |
| `invariant_I_usersNeverExtractMoreThanDepositsPlusYield` | sum of users' USDC <= USDC deposited + USDC minted into spUSDC + USDC minted for the taker's top-ups |
| `invariant_J_balanceProvenance` | balanceOf(user) == minted + transfers in + cancel refunds - transfers out - escrowed (handler ghosts) |
| `invariant_K_backingExistsSomewhere` | USDC in spUSDC + spUSDC taker + users + vault + spPRIME taker == USDC ever minted; vault holds 0 USDC |
| `invariant_L_availableCapacityFormula` | availableCapacity() == max(0, maxCapacity - totalSupply) |
| `invariant_M_noMintOfZeroSharesExceptDust` | zero-share fills counted (F-4), reported in afterInvariant() |
| `invariant_N_spUsdcSharesHeldByVaultAndTaker` | spUSDC totalSupply == vault + taker balances; taker balance == handler ledger |
| `invariant_O_processRedeemQueueRevertsOnlyOnCeilBurn` | the only revert reason ever seen from processRedeemQueue is `SparkVault/insufficient-balance` |

Handler coverage over the final run (calls per selector, summed over 100 runs, 0 reverts):
cancelDepositRequest 2399, cancelRedeemRequest 2395, drainSpUsdcLiquidity 2366, pause 2430,
processDepositQueue 2484, processRedeemQueue 2346, requestDeposit 2290,
requestDepositWithReferral 2348, requestRedeem 2398, returnSpUsdcLiquidity 2334,
returnToVault 2379, setCapacity 2425, setMinimums 2303, setPrimeVsr 2406, setRedeemFee 2402,
setSpUsdcVsr 2327, take 2386, transfer 2399, transferFrom 2360, unpause 2436, warp 2387.

Sample last-run ghost counters (one 500-call run): depositQueueLength 29, redeemQueueLength 19,
depositFills 28, redeemFills 10, ghostRedeemEntries 6, takerOutstandingSpUsdc 6.78e15,
totalSupply 8.19e15, chi 1.0407e27. Across the 15 sampled last-runs: depositFills 449,
redeemFills 136, zeroShareFills 4, ghostDepositEntries 65, ghostRedeemEntries 38,
cancelDepositBlockedF2 18, redeemProcessReverts 0 (the random walk never hit N-1; the unit test does).

Handler design: 6 users; inputs bounded; actions that would revert are skipped (paused, empty
balance, no open entry, backing spent per F-2); 10% zero-amount deposits and 10% one-wei redeems
when minimums allow; capacity 50% wide open / 30% small headroom / 20% at or below supply; VSRs
keep spUSDC >= spPRIME except in 1 of 8 calls (sticky `rateOrderBroken` flag disables H);
pause in 1 of 4 pause calls; warps 1 s..30 days with drips on both vaults; spUSDC liquidity
drained and returned (minted); taker takes and returns spUSDC (minting the shortfall).

## (c) Unsettled

- `afterInvariant()` logs are printed once per invariant test (last run only), so ghost counters
  are sampled, not totals; the selector table from foundry is the exact coverage.
- H is only checked while the taker holds nothing and the rate order never broke; the random walk
  breaks the order early in most runs (`rateOrderBroken` true in the sampled runs), so H's
  effective coverage is the prefix of each run before the first order break. A dedicated run with
  the 1-in-8 branches removed would strengthen it.
- N-1 with large, non-uniform entries was not reproduced in the random walk; its probability per
  balance-bound multi-entry call depends on rounding fractions and is not quantified here.
- Donations of spPRIME to the vault (I-6) and `setChi` loss realisation were excluded by design.
