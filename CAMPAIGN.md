# spPRIME testing campaign: worker briefing (round 6, `master` @ `c512609`)

You are one of several parallel workers porting and extending the `test/ai/` suite of
`src/SparkPrimeVault.sol` to `master` @ `c512609` ("test: Small fix and improve coverage (#51)",
2026-10-22), the code that is currently with the external auditors. Goal of this round, in order:
(1) every suite compiles and passes against this code, (2) every previously reported finding is
pinned as fixed or still open, (3) every code path in your area is covered, including the paths
that are NEW on this master (listed below), with unit tests, fuzz tests and, where it fits,
end-to-end flows. Each worker owns specific files in its own git worktree. Do not edit `src/`,
`test/ai/LocalTestBase.t.sol`, `test/ai/lib/`, `foundry.toml`, anything under `test/` outside
`test/ai/`, or another worker's files. Never run commands outside your worktree. Never push.

Always set `FOUNDRY_OFFLINE=true` (or pass `--offline`). Files you do not own have been moved out
of your worktree so the build is fast; `git status` shows them as deleted. **Commit only your own
files** (`git add test/ai/<YourFile>`; `git -c user.name=campaign -c user.email=campaign@local
commit`), never `git add -A` or `git commit -a`.

## What changed on `master` since `0ebb452` (the round-5 target)

Read `src/SparkPrimeVault.sol` and `src/ISparkPrimeVault.sol` in full first. Then:

- **Roles.** `DEFAULT_ADMIN_ROLE`: upgrade, `setMaxRedeemFeeRate`, `setMinDeposit`,
  `setMinDepositCancellation`, `setMinRedeem`, `setVSRBounds`. `LOSS_MANAGER_ROLE`:
  `adjustTotalAssets`. `OPERATOR_ROLE`: `setCapacity`, `setVSR`, the three `processPending*`.
  `PAUSER_ROLE`: `pause`. `UNPAUSER_ROLE`: `unpause`. `REDEEM_FEE_SETTER_ROLE`:
  `setRedeemFeeRate`. `TAKER_ROLE`: `take`. `GUARDIAN_ROLE`, `REBALANCER_ROLE`, `VSR_SETTER_ROLE`
  are gone. The sed `guardian->pauser`, `rebalancer->operator`, `vsrSetter->operator` was applied
  to your files and is wrong wherever the old actor did something the new one cannot (e.g. the
  admin used to call `setCapacity` and `unpause`; the operator does `setCapacity`, the unpauser
  `unpause`; `adjustTotalAssets` moved from admin to `lossManager`).
- **Custom errors** (`ISparkPrimeVault`): `IsPaused`, `IsNotPaused`, `ZeroRecipient`,
  `VaultIsRecipient`, `BelowMinDeposit`, `BelowMinDepositCancellation`, `BelowMinRedeem`,
  `InvalidRequestId`, `NoRequest`, `NotRequestOwner`, `SavingsSharesTooHigh`, `NothingToClaim`,
  `InsufficientShares`, `FeeTooHigh` (setRedeemFeeRate), `MaxFeeTooHigh` (setMaxRedeemFeeRate),
  `VSRTooLow`/`VSRTooHigh` (setVSR), `MinVSRTooLow`/`MaxVSRTooHigh`/`MinVSRGtMaxVSR`
  (setVSRBounds), `ZeroDeltaTotalAssets`, `LossTooHigh`, `ChiTooLow`, `ChiTooHigh`,
  `ZeroMinDeposit`, `ZeroMinDepositCancellation`, `ZeroMinRedeem`, `StartIdTooSmall`,
  `LengthTooLarge`. Use `vm.expectRevert(ISparkPrimeVault.X.selector)`. The unambiguous strings
  were rewritten by sed; `below-minimum`, `fee-too-high`, `vsr-too-low`, `vsr-too-high`,
  `invalid-range` and `recipient-cannot-receive` were left for you (the last one no longer exists).
  ERC20/permit strings are unchanged (`SparkPrimeVault/invalid-address`,
  `insufficient-balance`, `insufficient-allowance`, `permit-expired`, `invalid-owner`,
  `invalid-permit`).
- **`initialize(savings, name, symbol, admin, minDeposit, minDepositCancellation, minRedeem)`**,
  all three minimums must be non-zero; the setters reject zero too. The harness uses 1 wei for
  all three so every amount stays reachable; tests that want launch values set them.
- **`requestDepositCancellation(requestId, recipient, savingsShares)`**: partial cancels
  (`savingsShares >= minDepositCancellation`, `<= request.shares`; the entry is deleted only when
  fully cancelled), `requestId < length` (`InvalidRequestId`), owner only, vault rejected as
  recipient, NOT pause-gated, and it ends with `_processPendingDeposits(0, max)`, which walks
  cancelled (zero) entries at the head and stops at the first live one ("cancels self-skip").
  `processPendingDepositCancellations` is NOT pause-gated either. `minDepositCancellation` is in
  spUSDC share units.
- **`_processPendingDeposits`**: the loop no longer stops on `remaining_ == 0` before skipping
  zero entries: `continue` on a cancelled entry, then `break` if `remaining_ == 0`, so a walk with
  budget 0 still advances the head past cancelled entries.
- **`_processPendingRedeems`**: the liquidity bound is now recomputed per entry
  (`fillable_ = min(remaining_, convertToShares(availableLiquidAssets()))`, `break` at 0), which
  is the fix for C-1 (batched fills no longer revert on spUSDC ceil-rounding). `remaining_` is
  only `maxShares_`.
- **Blacklist fallback by `try/catch`**: `_redeemSavings` / `_withdrawSavings` try the payout to
  the recipient, and on ANY revert redeem/withdraw to the vault and credit `claimableAssets`
  (+ new `totalClaimable`). There is no `isBlacklisted` check anywhere any more: `requestRedeem`,
  `requestDepositCancellation` and the updaters accept blacklisted recipients. The harness
  `MockUSDC` still reverts transfers to blacklisted addresses, so the fallback triggers the same
  way. `claim` decrements `totalClaimable`.
- **Vault as recipient** is rejected in `requestDeposit`, `requestDepositCancellation`,
  `requestRedeem` and all three updaters (`VaultIsRecipient`): V2-13 is fixed for the vault;
  `savings` (spUSDC) is still accepted.
- **Getters**: single-entry getters unchanged (`InvalidRequestId` below head or at length); range
  getters are now `(startId, length)` with `StartIdTooSmall` (below head) and `LengthTooLarge`.
  No raw read of ids below the head exists; tests that need one use `vm.load` on the array slot
  (slots 0, 1, 2; element `i` at `keccak256(slot) + 3i + {0 owner, 1 recipient, 2 shares}`).
- **Events** all carry `requestId` first: `DepositRequest(requestId, owner, recipient,
  assetsDeposited, savingsSharesMinted)`, `Deposit(requestId, owner, recipient,
  savingsSharesConsumed, assetsConverted, sharesMinted)`, `DepositCancellationRequest(
  depositRequestId, cancelRequestId, recipient, sharesCancelled)`, `DepositCancellation(requestId,
  owner, recipient, savingsSharesBurned, assetsReceived)`, `RedeemRequest(requestId, owner,
  recipient, sharesToBurn, feeSharesBurned)`, `Redeem(requestId, owner, recipient, sharesBurned,
  savingsSharesBurned, assetsReceived)`, `Referral(referral, requestId, owner, recipient, assets)`.
- **Storage** (pinned by `forge inspect`): 0-2 the three arrays, 3 `savings`, 4 `asset`(0) +
  `paused`(20) + `decimals`(21), 5 `name`, 6 `symbol`, 7 `rho`(0) + `chi`(8) packed, 8 `vsr`,
  9 `minVSR`, 10 `maxVSR`, 11 `maxCapacity`, 12 `minDeposit`, 13 `minDepositCancellation`,
  14 `minRedeem`, 15 `redeemFeeRate`, 16 `maxRedeemFeeRate`, 17 `totalSupply`, 18
  `totalClaimable`, 19-21 the three pending counters, 22-24 the three heads, 25 `balanceOf`,
  26 `nonces`, 27 `claimableAssets`, 28 `allowance`.
- `transferFrom` calls `_transfer` before the allowance check (the balance check lives in
  `_transfer`). `ISparkPrimeVault` extends `IERC20Metadata`, `IERC20Permit`,
  `IAccessControlEnumerable`.

## Status of round-5 findings on this master (pin each one you touch)

Fixed, write `test_fixed_<slug>` regressions: **C-1 / R5-4** (per-entry liquidity bound; prove the
3401-spUSDC and the (11, 11, rest) batches now pay in one call and what dust, if any, remains);
**V2-13 / R5-7** for the vault (all request and update paths revert `VaultIsRecipient`; spUSDC
as recipient still donates: keep that as open low); **R5-9 ghosts / frozen head** partially
(zero-asset deposits are impossible with `minDeposit != 0`, cancelled entries are skipped at
cancel time and a budget-0 walk advances the head; measure what a griefer can still do with
`minDeposit`-sized request-then-cancel loops: the self-skip only clears entries AT the head, so a
cancelled entry behind a live head is still walked later); **R4-A/R4-B** (fallback now by
try/catch: prove a recipient that is a reverting contract, a blacklisted address, or spUSDC
itself behaves as expected, and that a non-recipient revert such as drained spUSDC liquidity still
propagates); **C-8 minimums** (zero rejected; still unbounded above); **pause** no longer gates
cancellations (R5-B in round 4 wanted this).

Still open as far as we can see (re-prove with exact numbers, keep `test_BUG_` names):
**R5-1 / G-1** (`chi <= uint192.max` vs the real `drip` bound `type(uint256).max / RAY`),
**R5-2** (deposit between public payload and pause captures the gain), **R5-3 / C-3** (no loss
floor; now a `LOSS_MANAGER` hot-wallet role, which makes it worse: re-rate), **R5-5 / F-2**
(redeem fills and `take` spend queued backing), **R5-6 / V2-8** (zero admin at init, last admin
renounce), **R5-8 / V2-7** (`setCapacity` unbounded, overflow at `totalSupply +
uint256.max / nowChi()`), **R5-10** (unpayable dust at the redeem head: re-check with the
per-entry bound), **R5-11 / C-7** (bounds do not clamp live values), **R5-13 / C-9**,
**R5-14** (`requestRedeem` of `minRedeem` shares at a fee that burns everything leaves a
zero-share entry; 1-share cancellations bloat), **R5-15** (zero-share mints, dust deposits).

## Harness: `test/ai/LocalTestBase.t.sol`

Inherit `LocalTestBase`. It deploys a 6-decimal `MockUSDC` (`setBlacklisted(address,bool)`,
`isBlacklisted`; transfers and approvals involving a blacklisted address revert with
"Blacklistable: account is blacklisted"), the REAL spUSDC `SparkVault` code
(`test/ai/lib/spusdc/SparkVault.sol`) and the `SparkPrimeVault` proxy with every role granted,
minimums 1 wei, capacity `type(uint128).max`, maxRedeemFee 1%, VSR bounds `[RAY, MAX_VSR]` on
both vaults, fee 0, both VSRs at RAY with "ugly" starting indexes.

Actors: `spAdmin, spSetter, spTaker` (spUSDC) and `admin, lossManager, operator, pauser,
unpauser, redeemFeeSetter, taker` (spPRIME). Role constants: `DEFAULT_ADMIN_ROLE,
LOSS_MANAGER_ROLE, OPERATOR_ROLE, PAUSER_ROLE, UNPAUSER_ROLE, REDEEM_FEE_SETTER_ROLE, TAKER_ROLE`
(and `SETTER_ROLE` for spUSDC). Constants `MIN_DEPOSIT`, `MIN_DEPOSIT_CANCELLATION`,
`MIN_REDEEM` (all 1).

Helpers: `_fund`, `_deposit(who, amt) -> id`, `_requestRedeem(who, shares) -> id`, `_setCapacity`
(operator), `_setRedeemFeeRate`, `_setMinDeposit`, `_setMinRedeem`, `_setMinDepositCancellation`,
`_adjustTotalAssets(int256)` (lossManager, needs pause), `_adjustTotalAssetsWhilePaused(int256)`,
`_setPrimeVsr` (operator), `_setSpUsdcVsr`, `_processDeposits`, `_processRedeems`,
`_processCancelledDeposits` (operator), `_cancelDeposit(who, id)` (full cancel to self),
`_cancelDepositAndSettle(who, id)`, `_pause` (pauser), `_unpause` (unpauser), `_blacklist`,
`_unblacklist`, `BLACKLISTED`, `_drainSpUsdcLiquidity`, `_drainAllSpUsdcLiquidity`,
`_returnSpUsdcLiquidity`, `_take`, `_takeAll`, `_returnToVault`, `_warp`, `_warpAndDrip`,
`_depositRequest(id)` / `_redeemRequest(id)` / `_cancelledDepositRequest(id)` (single-entry
getters: revert below the head), `_depositQueueLength()`, `_redeemQueueLength()`,
`_cancelledDepositQueueLength()`, `_vaultSpUsdc()`.

Gotcha: `vm.prank` is consumed by the next external call, including view calls used as
arguments. Cache values in locals first.

Porting rules: tests for removed behaviour are rewritten against the replacement or deleted with
a one-line note in your report, never left commented out. Old `test_BUG_` tests whose bug is fixed
become `test_fixed_` tests asserting the fix precisely. Exact-value assertions (exact wei, exact
selectors). Style: mirror `test/*.t.sol` on master and `~/work/spark-vaults-v2/test/` (naming
`test_<fn>_<case>`, `_failure`/`_success` groupings, `testFuzz_`, `vm.expectEmit` with exact
args, assert exact balances before and after each step).

Run only your files: `FOUNDRY_OFFLINE=true forge test --match-path 'test/ai/<YourFile>.t.sol' -vv`.
`FOUNDRY_FUZZ_RUNS=20000` for properties that matter.

## Deliverable

1. Your files committed on your branch (own files only). Every test must PASS, or be a deliberate
   failing proof named `test_BUG_<slug>` (say so in the report).
2. A "## Round 6 (`master` @ `c512609`)" section at the TOP of your `test/ai/REPORT-<area>.md`
   with: (a) new findings (file:line on `c512609`, exact scenario, impact, severity, test);
   (b) status of every prior finding you touched (fixed / open / changed) with the pinning test;
   (c) the code paths in your area and the test that covers each, including the new paths;
   (d) properties that held; (e) anything you could not settle.
3. Your final message: the same report, compact.
