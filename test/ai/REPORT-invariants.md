# spPRIME invariant campaign report

## Round 4 (bf93b0d)

Branch `campaign-v4/invariants`, files `test/ai/invariants/{a_init,b_flows_user,c_flows_admin}.sol`,
`test/ai/invariants/d_invariants.t.sol`. Target: upstream `src/SparkPrimeVault.sol` from
`fix/update-guardian-transfer` @ `bf93b0d` (`cancelRedeemRequest` removed; guardian
`requestDepositCancellation` requires `recipient_ == owner`; planner entry points
`processPendingDeposits` / `processPendingRedeems` / `processPendingDepositCancellations`; queue
reads via `getPending*Requests(start, end)`; heads `firstPending*Id`). Harness:
`test/ai/LocalTestBase.t.sol` (real spUSDC code, 6-decimal mock USDC, ugly starting indexes
chi_s = 1.0476e27, chi_p = 1.0097e27).

Final run: `FOUNDRY_INVARIANT_RUNS=100 FOUNDRY_INVARIANT_DEPTH=500 forge test --match-path
'test/ai/invariants/*.t.sol' -vv` (with the `--skip` list for the review files that do not compile
against bf93b0d) -> **23 passed, 0 failed** (21 invariants x 100 runs x 500 calls = 50,000 handler
calls per invariant, 0 handler reverts, plus 2 unit proofs).

### (a) Violations and findings

No invariant A..U was violated in any run. No new finding.

- `cancelRedeemRequest` is gone (`src/SparkPrimeVault.sol`: no such function; the
  `CancelRedeemRequest` event at `:101` is now dead). The handler and J's refund term are removed;
  escrowed shares can only leave the vault through `_processPendingRedeems` (`:905`). New
  `invariant_U`: the vault's own share balance never decreased in any handler call other than
  `processPendingRedeems` (127 such decreases in the 21 sampled last-runs, 0 elsewhere).
  `requestRedeem` (`:461`-`:466`) moves `shares` in and burns `fee <= shares` out of the escrow,
  a net increase, so it never trips U.
- Guardian deposit cancels (`src/SparkPrimeVault.sol:422`-`:425`): the handler now cancels as the
  guardian with `recipient_ == owner` in 1 of 3 cancels and, right before each, probes the same
  cancel with a non-owner recipient: 29 of 29 probes reverted with exactly
  `SparkPrimeVault/invalid-recipient` (asserted inline in the handler, counts
  `guardianCancelProbes` / `guardianCancelProbeReverts`). The cancelled entry carries the owner
  as recipient and the refund (`processPendingDepositCancellations`) pays the owner.
- N-1 (round 1, `processPendingRedeems` reverts `SparkVault/insufficient-balance` when the vault's
  spUSDC balance binds and the per-entry ceil burns add up) is **still present** at
  `src/SparkPrimeVault.sol:886` / `:909`. `test_BUG_processPendingRedeemsRevertsOnCeilBurnWhenBalanceBinds`
  unchanged and passing; the random walk did not hit it (`redeemProcessReverts` 0).
- N-2 (round 2) stays fixed: `_processPendingDepositCancellations` budgets by
  `spUSDC.maxRedeem(vault)` (`:848`), 0 reverts in 50,000 calls (`invariant_P`),
  `test_processPendingDepositCancellationsPaysUpToSpUsdcLiquidity` passing.
- `update*Recipient` (`:483`, `:494`, `:508`) owner-only: 25 of 25 stranger attempts reverted
  `SparkPrimeVault/not-authorized` (`invariant_S`); 119 owner updates moved only the recipient
  field (`invariant_R`).
- `realizeGain` (`:293`) 371 calls and `realizeLoss` (`:365`) 125 calls in the sampled last-runs,
  `totalAssets()` moved by exactly the amount within 1 wei every time (`invariant_T`,
  `maxGainLossError` 1 in every run).

### (b) Invariants that held (100 runs x depth 500, 50,000 calls each, 0 reverts)

| Name | Claim |
|---|---|
| `invariant_A_sumOfBalancesEqualsTotalSupply` | sum of balances over 6 users + vault escrow == totalSupply |
| `invariant_B_vaultBalanceEqualsPendingRedeemShares` | balanceOf(vault) == pendingRedeemShares |
| `invariant_C_pendingDepositEqualsSumOfOpenDepositEntries` | pendingDepositSavingsShares == sum of open deposit entries |
| `invariant_D_pendingRedeemEqualsSumOfOpenRedeemEntries` | pendingRedeemShares == sum of open redeem entries |
| `invariant_E_headBookkeeping` | every entry strictly before firstPendingDepositId / firstPendingDepositCancellationId / firstPendingRedeemId has shares == 0; heads <= lengths |
| `invariant_F_totalSupplyNeverExceedsCapacityViaMint` | no mint ever pushed totalSupply above maxCapacity as set at mint time |
| `invariant_G_chiMonotonicAndDripConsistent` | nowChi() only changes inside warp (up), realizeGain (up) and realizeLoss (down); nowChi() == the handler's last observation, >= stored chi, > 0; drip() == nowChi(), chi/rho updated |
| `invariant_H_solvencyWhenSpUsdcRateGePrimeRate` | while spUSDC VSR >= spPRIME VSR always held and the taker holds nothing: value(held spUSDC) - value(open deposit entries) - value(open cancelled entries) + epsilon >= totalAssets() - deficit ledger (ledger as in round 3) |
| `invariant_I_usersNeverExtractMoreThanDepositsPlusYield` | sum of users' USDC <= USDC deposited + USDC minted into spUSDC + taker top-ups, and == USDC paid by redeem fills + cancelled-deposit refunds |
| `invariant_J_balanceProvenance` | balanceOf(user) == minted (attributed to the entry recipient at fill time) + transfers in - transfers out - escrowed (no refund term: redeems cannot be cancelled) |
| `invariant_K_backingExistsSomewhere` | USDC in spUSDC + spUSDC taker + users + vault + spPRIME taker == USDC ever minted; vault holds 0 USDC |
| `invariant_L_availableCapacityFormula` | availableCapacity() == max(0, maxCapacity - totalSupply) |
| `invariant_M_noMintOfZeroSharesExceptDust` | zero-share fills counted (F-4), reported in afterInvariant() |
| `invariant_N_spUsdcSharesHeldByVaultAndTaker` | spUSDC totalSupply == vault + taker balances; taker balance == handler ledger |
| `invariant_O_processPendingRedeemsRevertsOnlyOnCeilBurn` | the only revert reason ever seen from processPendingRedeems is `SparkVault/insufficient-balance` |
| `invariant_P_processPendingDepositCancellationsNeverReverts` | processPendingDepositCancellations never reverted (any reason is counted and kept) |
| `invariant_Q_pendingCancelledEqualsSumOfOpenCancelledEntries` | pendingCancelledDepositSavingsShares == sum of open cancelled-deposit entries |
| `invariant_R_recipientUpdatesNeverChangeTotals` | an owner recipient update leaves totals, pendings, heads, chi/rho, every share and USDC balance, the vault's spUSDC and every entry's owner/shares byte-identical (keccak digest before == after) |
| `invariant_S_recipientUpdateByNonOwnerAlwaysReverts` | every recipient update attempted by a non-owner on an open entry reverted with exactly `SparkPrimeVault/not-authorized` (attempts == such reverts) |
| `invariant_T_gainAndLossAccounting` | after every realizeGain / realizeLoss, totalAssets() == before +/- amount within 1 wei (running max error <= 1, out-of-bound count 0) |
| `invariant_U_redeemEscrowOnlyLeavesThroughFills` | balanceOf(vault) never decreased across any handler call other than processPendingRedeems (checked in the `counted` modifier around every call) |

Handler coverage (foundry selector metrics, `invariant_A`, 100 runs x 500 calls, 0 reverts,
0 discards): drainSpUsdcLiquidity 2002, pause 1943, processPendingDepositCancellations 2012,
processPendingDeposits 1953, processPendingRedeems 1933, realizeGain 2019, realizeLoss 2013,
requestDeposit 2031, requestDepositCancellation 2035, requestDepositWithReferral 1954,
requestRedeem 2013, returnSpUsdcLiquidity 1997, returnToVault 1963, setCapacity 2018,
setMinDeposit 1970, setMinRedeem 2010, setPrimeVsr 2013, setRedeemFeeRate 2027, setSpUsdcVsr 2057,
take 2016, transfer 2044, transferFrom 2025, unpause 2006, updateRecipient 1940, warp 2006.

Ghost counters summed over the 21 sampled last-runs (one 500-call run per invariant test):
depositQueueLength 647, cancelledQueueLength 90, redeemQueueLength 246, depositFills 457,
cancelledFills 122, redeemFills 190, escrowDecreases 127 (all inside processPendingRedeems),
zeroShareFills 3, ghostDepositEntries 67, ghostRedeemEntries 52, recipientUpdates 119,
strangerUpdateAttempts 25 (all 25 reverted `not-authorized`), guardianCancelProbes 29 (all 29
reverted `invalid-recipient`), lossRealizations 125 (realizedLossUsdc 1.60e16),
gainRealizations 371 (realizedGainUsdc 5.99e16), maxGainLossError 1 in every run,
redeemProcessReverts 0, cancelProcessReverts 0, usersRedeemedUsdc 3.35e16,
usersRefundedUsdc 2.46e16, rateOrderBroken true in 19 of 21.

Handler changes this round: `cancelRedeemRequest` handler and `ghostRefunded` removed.
`requestDepositCancellation` passes the owner as recipient whenever it pranks the guardian and
first probes the guardian cancel with a non-owner recipient (must revert `invalid-recipient`).
The `counted` modifier snapshots `balanceOf(vault)` around every handler call and flags any
decrease outside `processPendingRedeems` (invariant U). Everything else as round 3.

### (c) Unsettled

- H is only checked while the taker holds nothing and the rate order never broke; the random walk
  breaks the order in most runs (19 of 21 sampled), so H's effective coverage is the prefix of
  each run before the first order break.
- The deficit ledger is an upper bound (gains are notional, no backing arrives in the harness), so
  H does not prove the deficit equals the gains exactly.
- `realizeGain` accepts any `gain_ > 0`; the handler keeps chi below 1e30. Overflow of
  `(totalAssets + gain) * RAY` or chi past `type(uint192).max` is not exercised.
- N-1 with large, non-uniform entries was not reproduced in the random walk.
- With no redeem cancel, shares queued for redeem behind illiquid spUSDC stay escrowed until
  liquidity returns; the guardian has no lever on the redeem queue. Observed, by design.
- `afterInvariant()` logs are printed once per invariant test (last run only), so ghost counters
  are sampled, not totals; the selector table is the exact coverage.
- Donations of spPRIME to the vault (I-6) are excluded by design.

---

## Round 3 (ff828d2)

Branch `campaign-v3/invariants`, files `test/invariants/{a_init,b_flows_user,c_flows_admin}.sol`,
`test/invariants/d_invariants.t.sol`. Target: upstream `src/SparkPrimeVault.sol` from
`refactor/more-simplifying` @ `ff828d2` (owner-only `update*Recipient`, `realizeLoss` requires
`0 < loss < totalAssets` and a live supply, `_processCancelledDepositQueue` budgets by
`spUSDC.maxRedeem(vault)`, new `realizeGain`). Harness: `test/LocalTestBase.t.sol` (real spUSDC
code, 6-decimal mock USDC, ugly starting indexes chi_s = 1.0476e27, chi_p = 1.0097e27).

Final run: `FOUNDRY_INVARIANT_RUNS=100 FOUNDRY_INVARIANT_DEPTH=500 forge test --match-path
'test/invariants/*.t.sol' -vv` -> **22 passed, 0 failed** (20 invariants x 100 runs x 500 calls =
50,000 handler calls per invariant, 0 handler reverts, plus 2 unit proofs).

### (a) Violations and findings

No invariant A..T was violated in any run. No new finding.

- N-2 (round 2, `processCancelledDepositQueue` reverting on spUSDC illiquidity) is **fixed**:
  `src/SparkPrimeVault.sol:784` now bounds `remaining_` by `spUSDC.maxRedeem(vault)`
  (= min(balance, floor(liquidity * RAY / chi_s))). The handler wraps the call and counts every
  revert; `invariant_P` now asserts 0 reverts and held over 50,000 calls with the spUSDC taker
  draining all liquidity in 1 of 4 drain calls and refunds queued in 68 entries of the 20 sampled
  last-runs. Unit proof renamed to `test_processCancelledDepositQueuePaysUpToSpUsdcLiquidity`:
  two 100 USDC refunds queued, 150 USDC liquidity, `(max, 2)` pays alice 99,999,999 and bob
  49,999,999 (partial, stays at the head), a call with 0 liquidity is a no-op, the remainder is
  paid once 100 USDC is back (bob ends at 99,999,999).
- N-1 (round 1, `processRedeemQueue` reverts `SparkVault/insufficient-balance` when the vault's
  spUSDC balance binds and the per-entry ceil burns add up) is **still present** at
  `src/SparkPrimeVault.sol:822` / `:845`. `test_BUG_processRedeemQueueRevertsOnCeilBurnWhenBalanceBinds`
  unchanged and passing; the random walk did not hit it (`redeemProcessReverts` 0).
- `update*Recipient` (`src/SparkPrimeVault.sol:416`, `:465`, `:537`) are owner-only: 17 of 17
  deliberate non-owner attempts in the sampled last-runs reverted with exactly
  `SparkPrimeVault/not-authorized` (new `invariant_S`); the 114 owner updates moved nothing but
  the recipient field (`invariant_R`).
- `realizeGain` (`src/SparkPrimeVault.sol:297`): 380 calls in the sampled last-runs, in any pause
  state, `1 <= gain <= totalAssets / 10`; `totalAssets()` moved by exactly the gain minus at most
  1 wei every time (new `invariant_T`, `maxGainLossError` 1 in every run). The gain is notional:
  nothing arrives in the harness, so after a gain the vault is insolvent by the gain plus its
  yield; `invariant_H` accounts for that with a deficit ledger (below) and still held.
- `realizeLoss` (`src/SparkPrimeVault.sol:369`): 111 calls, same +/-1 wei accounting.

### (b) Invariants that held (100 runs x depth 500, 50,000 calls each, 0 reverts)

| Name | Claim |
|---|---|
| `invariant_A_sumOfBalancesEqualsTotalSupply` | sum of balances over 6 users + vault escrow == totalSupply |
| `invariant_B_vaultBalanceEqualsPendingRedeemShares` | balanceOf(vault) == pendingRedeemShares |
| `invariant_C_pendingDepositEqualsSumOfOpenDepositEntries` | pendingDepositSavingsShares == sum of depositQueue[i].shares |
| `invariant_D_pendingRedeemEqualsSumOfOpenRedeemEntries` | pendingRedeemShares == sum of redeemQueue[i].shares |
| `invariant_E_headBookkeeping` | every entry strictly before depositHead / cancelledDepositHead / redeemHead has shares == 0; heads <= lengths |
| `invariant_F_totalSupplyNeverExceedsCapacityViaMint` | no mint ever pushed totalSupply above maxCapacity as set at mint time |
| `invariant_G_chiMonotonicAndDripConsistent` | nowChi() only changes inside warp (up), realizeGain (up) and realizeLoss (down); nowChi() == the handler's last observation, >= stored chi, > 0; drip() == nowChi(), chi/rho updated |
| `invariant_H_solvencyWhenSpUsdcRateGePrimeRate` | while spUSDC VSR >= spPRIME VSR always held and the taker holds nothing: value(held spUSDC) - value(open deposit entries) - value(open cancelled entries) + epsilon >= totalAssets() - deficit ledger. Ledger: +gain on realizeGain, -loss on realizeLoss, scaled on each warp by spUSDC's index while positive and by spPRIME's index while negative (both upper bounds given the rate order; rounding towards the bound). epsilon = redeemFills * ceil(chi_s/RAY) + 2 wei |
| `invariant_I_usersNeverExtractMoreThanDepositsPlusYield` | sum of users' USDC <= USDC deposited + USDC minted into spUSDC + taker top-ups, and == USDC paid by redeem fills + cancelled-deposit refunds |
| `invariant_J_balanceProvenance` | balanceOf(user) == minted (attributed to the entry recipient at fill time) + transfers in + redeem-cancel refunds - transfers out - escrowed |
| `invariant_K_backingExistsSomewhere` | USDC in spUSDC + spUSDC taker + users + vault + spPRIME taker == USDC ever minted; vault holds 0 USDC |
| `invariant_L_availableCapacityFormula` | availableCapacity() == max(0, maxCapacity - totalSupply) |
| `invariant_M_noMintOfZeroSharesExceptDust` | zero-share fills counted (F-4), reported in afterInvariant() |
| `invariant_N_spUsdcSharesHeldByVaultAndTaker` | spUSDC totalSupply == vault + taker balances; taker balance == handler ledger |
| `invariant_O_processRedeemQueueRevertsOnlyOnCeilBurn` | the only revert reason ever seen from processRedeemQueue is `SparkVault/insufficient-balance` |
| `invariant_P_processCancelledDepositQueueNeverReverts` | processCancelledDepositQueue never reverted (any reason is counted and kept) |
| `invariant_Q_pendingCancelledEqualsSumOfOpenCancelledEntries` | pendingCancelledDepositSavingsShares == sum of cancelledDepositQueue[i].shares |
| `invariant_R_recipientUpdatesNeverChangeTotals` | an owner recipient update leaves totals, pendings, heads, chi/rho, every share and USDC balance, the vault's spUSDC and every entry's owner/shares byte-identical (keccak digest before == after) |
| `invariant_S_recipientUpdateByNonOwnerAlwaysReverts` | every recipient update attempted by a non-owner on an open entry reverted with exactly `SparkPrimeVault/not-authorized` (attempts == such reverts) |
| `invariant_T_gainAndLossAccounting` | after every realizeGain / realizeLoss, totalAssets() == before +/- amount within 1 wei (running max error <= 1, out-of-bound count 0) |

Handler coverage (foundry selector metrics, `invariant_A`, 100 runs x 500 calls, 0 reverts,
0 discards): cancelDepositRequest 1941, cancelRedeemRequest 1825, drainSpUsdcLiquidity 1946,
pause 1987, processCancelledDepositQueue 1997, processDepositQueue 1951, processRedeemQueue 1870,
realizeGain 1854, realizeLoss 1904, requestDeposit 1953, requestDepositWithReferral 1935,
requestRedeem 1983, returnSpUsdcLiquidity 1951, returnToVault 1937, setCapacity 1928,
setMinDeposit 1868, setMinRedeem 1940, setPrimeVsr 1899, setRedeemFee 1887, setSpUsdcVsr 1938,
take 1877, transfer 1905, transferFrom 2003, unpause 1875, updateRecipient 1944, warp 1902.

Ghost counters summed over the 20 sampled last-runs (one 500-call run per invariant test):
depositQueueLength 585, cancelledQueueLength 68, redeemQueueLength 215, depositFills 433,
cancelledFills 84, redeemFills 102, zeroShareFills 5, ghostDepositEntries 71, ghostRedeemEntries 37,
recipientUpdates 114, strangerUpdateAttempts 17 (all 17 reverted `not-authorized`),
lossRealizations 111 (realizedLossUsdc 1.36e16), gainRealizations 380 (realizedGainUsdc 5.91e16),
maxGainLossError 1 in every run, redeemProcessReverts 0, cancelProcessReverts 0,
usersRedeemedUsdc 1.84e16, usersRefundedUsdc 1.61e16, rateOrderBroken true in 17 of 20.

Handler changes this round: `updateRecipient` scans forward from a random index for an open entry
and pranks its owner; 1 in 8 calls pranks a different user instead, wrapped in try/catch, and
records the reason. `pause` pranks the guardian only. `realizeLoss` unchanged in bounds
(`totalAssets >= 10`, `1 <= loss <= totalAssets/10`, chi kept > 0) and now feeds T and the deficit
ledger. New `realizeGain` handler (admin, any pause state, `totalSupply > 0`, `totalAssets >= 10`,
`1 <= gain <= totalAssets/10`, skipped when the resulting chi would exceed 1e30). `warp` is the
only handler that moves time and now scales the deficit ledger and resets the chi watermark;
G flags any other chi movement in either direction. `processCancelledDepositQueue` keeps the
try/catch only to capture a reason if the call ever reverts.

### (c) Unsettled

- H is only checked while the taker holds nothing and the rate order never broke; the random walk
  breaks the order in most runs (17 of 20 sampled), so H's effective coverage is the prefix of
  each run before the first order break. A dedicated run with the 1-in-8 branches removed would
  strengthen it, especially now that realized gains make the vault deliberately insolvent.
- The deficit ledger is an upper bound, so H proves "the notional never exceeds backing plus the
  fictitious gains and their worst-case yield"; it does not prove the deficit equals the gains
  exactly. A harness that mints spUSDC into the vault on `realizeGain` would turn H back into a
  tight solvency check.
- `realizeGain` accepts any `gain_ > 0` with no upper bound; the handler keeps chi below 1e30.
  With `gain_` large enough that `(totalAssets + gain) * RAY` overflows, or chi passes
  `type(uint192).max`, the call reverts or truncates; not exercised.
- N-1 with large, non-uniform entries was not reproduced in the random walk.
- `afterInvariant()` logs are printed once per invariant test (last run only), so ghost counters
  are sampled, not totals; the selector table is the exact coverage.
- Donations of spPRIME to the vault (I-6) are excluded by design.

---

## Round 2 (0bc9288)

Branch `campaign-v2/invariants`, files `test/invariants/{a_init,b_flows_user,c_flows_admin}.sol`,
`test/invariants/d_invariants.t.sol`. Target: upstream `src/SparkPrimeVault.sol` from
`refactor/more-simplifying` (cancelled-deposit queue, unauthenticated recipient updates,
`realizeLoss`, `minRedeem` in shares, `requestRedeem(0)` allowed). Harness: `test/LocalTestBase.t.sol`
(real spUSDC code, 6-decimal mock USDC, ugly starting indexes chi_s = 1.0476e27, chi_p = 1.0097e27).

Final run: `FOUNDRY_INVARIANT_RUNS=100 FOUNDRY_INVARIANT_DEPTH=500 forge test --match-path
'test/invariants/*.t.sol' -vv` -> **20 passed, 0 failed** (18 invariants x 100 runs x 500 calls =
50,000 handler calls per invariant, 0 handler reverts, plus 2 unit proofs).

The same run was repeated on a scratch copy of the repo with `review/poc-tests-v2` applied
(`pause()` back on GUARDIAN_ROLE, `realizeLoss` sets `chi = floor((totalAssets - loss) * RAY /
totalSupply)`, `totalAssets()` public): **20 passed, 0 failed**, 0 reverts. The handlers are written
for both revisions (pause pranks the guardian and falls back to the admin; the loss handler keeps
`loss <= totalAssets / 10`, requires the resulting chi > 0, and asserts the floor
`totalAssets_after + loss <= totalAssets_before`, which is what H consumes). The `git merge
review/poc-tests-v2` in this worktree was blocked by the sandbox's permission classifier (as was
`git apply` of the same diff), so the committed worktree still carries the pre-merge `src/`; the
merge is a 3-file, conflict-free change to `src/`, `README.md` and `test/LocalTestBase.t.sol`
and is left to the coordinator.

## (a) Violations and findings

### N-1 Low (round 1, still present): `processRedeemQueue` reverts when the vault's spUSDC balance is the binding limit

- Location: `src/SparkPrimeVault.sol:780` (`remaining_ = _min(maxShares_, convertToShares(availableLiquidAssets()))`)
  and `src/SparkPrimeVault.sol:803` (`IERC4626Like(savings).withdraw(assets_, request.recipient, address(this))`).
- Mechanism unchanged from round 1: the budget is a single floor in USDC while every entry burns
  `ceil(assets_ * RAY / chi_s)` spUSDC shares, so k entries can over-burn by up to k-1 shares and
  the whole batch reverts `SparkVault/insufficient-balance` when the balance, not spUSDC's
  liquidity, binds.
- Sequence: alice `requestDeposit(100e6)`; alice `requestRedeem(1)` x110; taker
  `take(vaultSpUsdc - 100)`; rebalancer `processRedeemQueue(max, 110)` reverts; `(max, 1)` x110
  pays 99 wei, strands 1 share, leaves 11 entries open.
- Test: `test_BUG_processRedeemQueueRevertsOnCeilBurnWhenBalanceBinds` (passes by asserting the
  revert). Handler counter `redeemProcessReverts`; any other reason fails `invariant_O`.

### N-2 Low (round 2, known to the coordinator): `processCancelledDepositQueue` reverts when spUSDC is illiquid instead of paying what it can

- Location: `src/SparkPrimeVault.sol:742` (`remaining_ = _min(maxSavingsShares_, IERC20Like(savings).balanceOf(address(this)))`)
  and `src/SparkPrimeVault.sol:763` (`IERC4626Like(savings).redeem(savingsShares_, request_.recipient, address(this))`).
- Mechanism: the budget is the vault's spUSDC balance only. spUSDC `redeem` then needs
  `floor(shares * chi_s / RAY)` USDC of liquidity for every entry; when spUSDC's USDC has been
  taken, the batch reverts inside spUSDC with `SparkVault/insufficient-liquidity` and nothing is
  paid. `processRedeemQueue` does not have this failure because its budget goes through
  `maxWithdraw`, which caps at spUSDC liquidity. The `insufficient-balance` revert cannot happen
  here: `redeem` burns exactly `savingsShares_ <= remaining_ <= balance`, so after `take()` the
  function pays what is left and stops (verified by code read and by the campaign: 0 such reverts
  in 50,000 calls with the taker draining the vault in 1 of 4 `take` calls).
- Sequence (harness numbers): capacity 0; alice `requestDeposit(100e6)`, bob `requestDeposit(100e6)`
  (both queue); each cancels to self; spUSDC taker drains all but 150 USDC;
  rebalancer `processCancelledDepositQueue(max, 2)` reverts `SparkVault/insufficient-liquidity`;
  `(max, 1)` pays alice 99,999,999 (1-wei deposit/redeem floor round trip), then `(max, 1)` reverts
  again for bob until 100 USDC is returned to spUSDC.
- Impact: operational. The rebalancer must size `maxSavingsShares_` off-chain against
  `spUSDC.convertToShares(usdc.balanceOf(spUSDC))`; no funds at risk. Refunds queue behind
  spUSDC liquidity exactly as redeems do, but without the partial-payment behaviour redeems get.
- Test: `test_BUG_processCancelledDepositQueueRevertsWhenSpUsdcIlliquid` (passes by asserting the
  revert). Handler counter `cancelProcessReverts` (18 in the 18 sampled last-runs); any other
  reason fails `invariant_P`.
- Fix options: bound `remaining_` by `_min(balance, spUSDC.convertToShares(usdc.balanceOf(spUSDC)))`,
  or break out of the loop when the next payout exceeds spUSDC's liquidity.

### Observed, not asserted (reported by NEWSURFACE, exercised here)

- `updateDepositRecipient` / `updateCancelledDepositRecipient` / `updateRedeemRecipient`
  (`src/SparkPrimeVault.sol:421`, `:465`, `:532`) have no caller check. The handler lets a random
  user repoint a random entry; 264 of 292 sampled updates were by a non-owner. Every fill paid the
  recipient the entry carried at fill time. `invariant_R` confirms the update itself moves nothing.
- `cancelRedeemRequest` pays the `recipient_` argument whoever the caller is (guardian included);
  J's bookkeeping credits that recipient.
- `setCapacity` (`src/SparkPrimeVault.sol:268`) accepts any `uint256`; the handler keeps it
  `<= type(uint128).max` because `convertToAssets(availableCapacity())` overflows above that and
  bricks `processDepositQueue`.
- `realizeLoss` (`src/SparkPrimeVault.sol:356`) with `loss == totalAssets` zeroes chi and bricks
  every conversion; the handler skips that case (never reachable with `loss <= totalAssets / 10`).

No invariant A..R was violated in any run on either source revision. Known findings observed live
by the handler counters (not re-reported): F-4 zero-share dust fills (`zeroShareFills`, 4 in the 18
sampled last-runs), F-5 ghost entries (80 zero-amount deposit entries, 51 zero-share or fee-eaten
redeem entries, `requestRedeem(0)` now being legal).

## (b) Invariants that held (100 runs x depth 500, 50,000 calls each, 0 reverts)

| Name | Claim |
|---|---|
| `invariant_A_sumOfBalancesEqualsTotalSupply` | sum of balances over 6 users + vault escrow == totalSupply |
| `invariant_B_vaultBalanceEqualsPendingRedeemShares` | balanceOf(vault) == pendingRedeemShares (no donations in the campaign) |
| `invariant_C_pendingDepositEqualsSumOfOpenDepositEntries` | pendingDepositSavingsShares == sum of depositQueue[i].shares |
| `invariant_D_pendingRedeemEqualsSumOfOpenRedeemEntries` | pendingRedeemShares == sum of redeemQueue[i].shares |
| `invariant_E_headBookkeeping` | every entry strictly before depositHead / cancelledDepositHead / redeemHead has shares == 0; heads <= lengths |
| `invariant_F_totalSupplyNeverExceedsCapacityViaMint` | no mint ever pushed totalSupply above maxCapacity as set at mint time |
| `invariant_G_chiMonotonicAndDripConsistent` | chi never decreases outside `realizeLoss` (handler flag), nowChi() >= last observed chi, chi > 0, drip() == nowChi(), chi/rho updated |
| `invariant_H_solvencyWhenSpUsdcRateGePrimeRate` | spUSDC value held minus value owed to open deposit entries minus value owed to open cancelled entries + epsilon >= totalAssets() + sum of realised losses, while spUSDC VSR >= spPRIME VSR always held and the taker holds nothing; epsilon = redeemFills * ceil(chi_s/RAY) + 2 wei (cancel refunds use `redeem`, exact burn, add nothing) |
| `invariant_I_usersNeverExtractMoreThanDepositsPlusYield` | sum of users' USDC <= USDC deposited + USDC minted into spUSDC + taker top-ups, and == USDC paid by redeem fills + USDC paid by cancelled-deposit refunds |
| `invariant_J_balanceProvenance` | balanceOf(user) == minted (attributed to the entry recipient at fill time) + transfers in + redeem-cancel refunds (to the `recipient_` argument) - transfers out - escrowed |
| `invariant_K_backingExistsSomewhere` | USDC in spUSDC + spUSDC taker + users (redeem payouts and cancel refunds) + vault + spPRIME taker == USDC ever minted; vault holds 0 USDC |
| `invariant_L_availableCapacityFormula` | availableCapacity() == max(0, maxCapacity - totalSupply) |
| `invariant_M_noMintOfZeroSharesExceptDust` | zero-share fills counted (F-4), reported in afterInvariant() |
| `invariant_N_spUsdcSharesHeldByVaultAndTaker` | spUSDC totalSupply == vault + taker balances; taker balance == handler ledger |
| `invariant_O_processRedeemQueueRevertsOnlyOnCeilBurn` | the only revert reason ever seen from processRedeemQueue is `SparkVault/insufficient-balance` |
| `invariant_P_processCancelledDepositQueueRevertsOnlyOnKnownReasons` | the only revert reason ever seen from processCancelledDepositQueue is `SparkVault/insufficient-liquidity` |
| `invariant_Q_pendingCancelledEqualsSumOfOpenCancelledEntries` | pendingCancelledDepositSavingsShares == sum of cancelledDepositQueue[i].shares |
| `invariant_R_recipientUpdatesNeverChangeTotals` | a recipient update leaves totals, pendings, heads, chi/rho, every share and USDC balance, the vault's spUSDC and every entry's owner/shares byte-identical (keccak digest before == after) |

Handler coverage (foundry selector metrics, `invariant_A`, 100 runs x 500 calls, 0 reverts,
0 discards; the last six rows come from a second run with the same parameters):
cancelDepositRequest 2059, cancelRedeemRequest 1998, drainSpUsdcLiquidity 2052, pause 2072,
processCancelledDepositQueue 1905, processDepositQueue 1942, processRedeemQueue 2021,
realizeLoss 1941, requestDeposit 2005, requestDepositWithReferral 1974, requestRedeem 2046,
returnSpUsdcLiquidity 2044, returnToVault 2071, setCapacity 2053, setMinDeposit 2022,
setMinRedeem 1995, setPrimeVsr 2002, setRedeemFee 2004, setSpUsdcVsr 1918, take 2018,
transfer 2058, transferFrom 1903, unpause 2085, updateRecipient 2009, warp 2016.

Ghost counters summed over the 18 sampled last-runs (one 500-call run per invariant test):
depositQueueLength 591, cancelledQueueLength 94, redeemQueueLength 225, depositFills 410,
cancelledFills 99, redeemFills 116, zeroShareFills 4, ghostDepositEntries 80, ghostRedeemEntries 51,
recipientUpdates 292 (264 by a non-owner), lossRealizations 85 (realizedLossUsdc 9.45e15),
redeemProcessReverts 0 (N-1 not hit by the random walk; the unit test proves it),
cancelProcessReverts 18 (N-2 hit live), usersRedeemedUsdc 1.50e16, usersRefundedUsdc 2.01e16.
Merged-source copy: lossRealizations 80, cancelProcessReverts 13, otherwise the same shape.

Handler design: 6 users; inputs bounded; actions that would revert are skipped (paused, empty
balance, no open entry); 10% zero-amount deposits and 10% zero-share / minimum-size redeems when
minimums allow; capacity 50% wide open / 30% small headroom / 20% at or below supply; VSRs keep
spUSDC >= spPRIME except in 1 of 8 calls (sticky `rateOrderBroken` flag disables H); pause in 1 of
4 pause calls; losses only while paused, `1 <= loss <= totalAssets/10`, chi kept > 0; warps
1 s..30 days with drips on both vaults; spUSDC liquidity drained and returned (minted); taker takes
and returns spUSDC (minting the shortfall); random users repoint random entries in all three queues;
the two settlement calls that spUSDC can make revert are wrapped and their reasons classified.

## (c) Unsettled

- The committed worktree does not contain the `review/poc-tests-v2` merge (blocked by the sandbox);
  the invariant files pass on both revisions, but the coordinator should run the merge and re-run
  the one-line command above to get the final line on the merged tree.
- `afterInvariant()` logs are printed once per invariant test (last run only), so ghost counters
  are sampled, not totals; the selector table is the exact coverage.
- H is only checked while the taker holds nothing and the rate order never broke; the random walk
  breaks the order in most runs (`rateOrderBroken` true in all 18 sampled last-runs), so H's
  effective coverage is the prefix of each run before the first order break. A dedicated run with
  the 1-in-8 branches removed would strengthen it.
- H treats realised losses as fictitious (the backing never leaves the harness), so it proves
  `realizeLoss` only ever widens the gap; a harness that burns the taker's spUSDC to model a real
  loss would be needed to test "loss realised == loss suffered".
- N-1 with large, non-uniform entries was not reproduced in the random walk; N-2 was.
- Donations of spPRIME to the vault (I-6) are excluded by design.
