# NEWSURFACE worker report (round 2)

Target: `src/SparkPrimeVault.sol` on `refactor/more-simplifying` as merged through
`review/poc-tests-v2` @ 8bbe02b (pause back on GUARDIAN, `realizeLoss` via `totalAssets()`).
Files: `test/CancelledDepositQueue.t.sol` (20 tests), `test/NewSurface.t.sol` (33 tests). All 53
pass; the `test_BUG_*` tests pass by asserting the bug. Both fuzz properties also pass at 20_000 runs.
Harness indexes: spUSDC chi_s = 1.047633055711877768967605062e27, spPRIME chi_p =
1.009687768242461209408770821e27; 1_000_000e6 USDC = 954_532_691_143 spUSDC = 990_405_184_109
spPRIME; a redeem of those spUSDC pays 999_999_999_999 USDC.

## (a) Bugs

### N-1 Critical: recipient updaters have no authorization
`src/SparkPrimeVault.sol:423` (`updateDepositRecipient`), `:467` (`updateCancelledDepositRecipient`),
`:534` (`updateRedeemRecipient`). The only check is `recipient_ != 0`; there is no owner or role
check. Anyone can point any open queue entry at themselves one block before the planner fills it.
- Queued deposit: alice queues 1_000_000e6 (capacity 0); mallory, no role, no balance, calls
  `updateDepositRecipient(0, mallory)`; planner fills; mallory receives 990_405_184_109 spPRIME
  (~999_999.999998 USDC), alice receives 0. The entry's `owner` stays alice, so the only trace is
  the `DepositRecipientUpdated` event. `test_BUG_updateDepositRecipient_anyoneCanStealQueuedDeposit`.
- Partially filled head entry: the remainder (954_532_691_143 - 95_453_269_112 spUSDC, ~900k USDC)
  goes to mallory. `test_BUG_updateDepositRecipient_stealsRemainderOfPartialFill`.
- Queued redeem: alice escrows 990_405_184_109 shares; mallory redirects; planner pays mallory
  999_999_999_998 USDC. `test_BUG_updateRedeemRecipient_anyoneCanStealQueuedRedeem`.
- Cancelled deposit refund: mallory redirects the cancel entry; settlement pays mallory
  999_999_999_999 USDC. `test_BUG_updateCancelledDepositRecipient_anyoneCanStealRefund`.
Impact: every queued dollar in all three queues is stealable by anyone. Fix: `require(msg.sender
== request.owner)` in all three (or drop the functions).

### N-2 High: `realizeLoss(totalAssets())` sets chi to 0 and bricks the vault
`src/SparkPrimeVault.sol:357`: `chi = uint192(((totalAssets() - loss_) * RAY) / totalSupply)`.
`loss_ == totalAssets()` is accepted and yields `chi = 0`. chi is multiplicative, so `nowChi()` is
still 0 after 365 days at MAX_VSR, `drip` keeps it 0, and a further `realizeLoss` underflows. Shape
after the call (all asserted): `totalAssets() == 0`; alice's 990_405_184_109 shares are worth 0
while the vault still holds 954_532_691_143 spUSDC (~1M USDC, reachable only via `take()`);
`requestDeposit` does NOT revert, bob's 100k is accepted and queued (`pendingDepositSavingsShares
= 95_453_269_114`) and `processDepositQueue` is a silent no-op forever (free capacity converts to 0
assets so the fill loop never runs); `requestRedeem` works (escrows worthless shares) but
`processRedeemQueue` and `convertToShares` panic with division by zero; cancel + settlement still
work. No role can recover; only an upgrade. With `totalSupply == 1` share `totalAssets()` is 1 wei,
so `realizeLoss(1)` is a full loss and zeroes chi the same way.
`test_BUG_realizeLoss_fullLossSetsChiZeroAndBricksVault`,
`test_BUG_realizeLoss_oneWeiLossOnOneShareSupplyZeroesChi`. Fix: `require(loss_ < totalAssets())`
plus a floor on the new chi. C-3 persists under the new formula: a hot-wallet RISK_MANAGER can
write chi down to anything in one call while paused.

### N-3 Medium: `processCancelledDepositQueue` reverts when spUSDC is illiquid
`src/SparkPrimeVault.sol:744` budgets by the vault's spUSDC share balance; the per-entry
`spUSDC.redeem` (`:765`) needs USDC liquidity. Scenario: alice's cancelled 954_532_691_143 spUSDC;
spUSDC's taker deploys 500_000e6 of its 1_000_000e6 USDC; `spUsdc.maxRedeem(vault)` =
477_266_345_571 < entry; the call reverts `SparkVault/insufficient-liquidity` and alice gets
nothing although 499_999_999_998 USDC could have been paid. Batch: liquidity 1_040_000e6 covers
entry 1 (999_999_999_999) but not entry 2 (99_999_999_999); the whole call reverts and even entry 1
is unpaid. The planner can only work around it by computing `maxRedeem` off-chain and passing it
as `maxSavingsShares_`, or by `maxRequests_ = 1`. `_processRedeemQueue` (`:782`) already bounds by
`maxWithdraw` and degrades gracefully. Fix: `remaining_ = _min(maxSavingsShares_,
IERC4626Like(savings).maxRedeem(address(this)))`.
`test_BUG_processCancelledDepositQueue_revertsWhenSpUsdcIlliquid`,
`test_BUG_processCancelledDepositQueue_batchRevertsWhenSecondEntryIlliquid`.

### N-4 Medium: `setCapacity` has no bound; large values brick deposits
`src/SparkPrimeVault.sol:268` accepts any uint256; `:704` computes
`convertToAssets(availableCapacity())` = `(cap - supply) * chi / RAY`. `setCapacity(type(uint256).max)`
makes every `requestDeposit` and `processDepositQueue` revert with an arithmetic overflow panic.
Exact edge at supply 0: `type(uint256).max / chi_p` =
114_681_085_459_589_801_375_833_087_904_206_311_575_507_395_147_570 is safe, +1 panics. The bound
shrinks as chi grows: a capacity set to the exact safe value today bricks deposits after one day
at MAX_VSR (shown), so a value that was valid when set can go bad with no further action. Admin
recovers by lowering capacity. `type(uint128).max` (harness) is always safe.
`test_BUG_setCapacity_maxUint256BricksDeposits`. Fix: restore `capacity_ <= type(uint128).max`.

### N-5 Low: the cancelled-deposit queue is not ring-fenced from `take()` (F-2 in new form)
The round-1 revert is gone, replaced by indefinite delay: after `take(954_532_691_143)` settlement
is a silent no-op (budget = min(max, 0)), head and counters unchanged, no revert and no event; the
refund resumes exactly as spUSDC comes back (95_453_269_114 returned pays 99_999_999_999 USDC).
`test_take_afterCancel_settleIsNoOpUntilSpUsdcReturned`. Likewise the cancelled queue and the
redeem queue draw from the same spUSDC; the planner's call order decides who is paid under a
shortfall (redeems first: alice 899_999_999_998 and bob at most 1 wei; cancels first: bob
99_999_999_999 and alice 799_999_999_998). `test_priority_redeemsFirstStarvesCancelledQueue`,
`test_priority_cancelledFirstStarvesRedeemQueue`.

### N-6 Low: zero-share redeem ghosts and zero-deposit ghosts (F-5 / C-12 persist)
`requestRedeem(0, r)` (`:478`) with `minRedeem == 0` succeeds for anyone with no balance: emits
`RedeemRequest(mallory, mallory, 0, 0, 0)`, pushes a 0-share entry, `cancelRedeemRequest` on it
reverts `no-request`. Three ghosts ahead of a real redeem make `processRedeemQueue(max, 3)` pay
nothing and move the head to 3. `requestDeposit(0)` with `minDeposit == 0` likewise pushes ghosts;
500 ghosts parked between the head and the next real entry cost that depositor one walk of
388_500 gas warm in-test (about 2_100 per ghost cold on mainnet, ~1.1M) and nothing afterwards.
`minRedeem = 1` and `minDeposit = 1` close both. `test_requestRedeem_zeroSharesCreatesGhostEntry`,
`test_requestRedeem_ghostsConsumeMaxRequests`, `test_requestDeposit_gasOfWalkingGhostsPaidOnce`.

### N-7 Info
- `updateDepositRecipient` on a filled (deleted) id writes a recipient into the dead slot
  (`(0, mallory, 0)`); cancel still reverts `no-request` and processing ignores it.
  `test_updateDepositRecipient_onFilledIdWritesDeadSlot`.
- `Deposit`'s 4th argument is named `savingsShares` but carries spPRIME shares (990_405_184_109
  for a 1M deposit). `test_events_depositFourthArgIsPrimeShares`.
- Guardian-chosen `recipient_` on cancel lands in the cancelled queue and is paid to the guardian
  (F-1 persists; CANCEL-FEES owns it). `test_cancelDepositRequest_guardianChoosesRecipient`.
- Public array getters revert with empty data out of range; the three updaters panic 0x32.
- `realizeLoss` rounding is now floor against holders: the `totalAssets()` drop is in [L, L+1]
  (exactly L+1 at the harness indexes for L = 100_000e6). The uint192 cast at `:357` cannot
  truncate: new chi <= old chi for every `loss_ <= totalAssets()` (fuzzed, 20k runs) and chi <
  2^192 by the drip bound.

## (b) Properties that held

- Cancel moves the exact spUSDC amount from `pendingDepositSavingsShares` to
  `pendingCancelledDepositSavingsShares`, zeroes the deposit entry, returns the cancel id, emits
  `CancelDepositRequest(depositId, cancelId)`; settlement pays `floor(shares * chi_s / RAY)`
  (999_999_999_999 for 1M), emits `DepositCancellation(owner, recipient, shares, assets)`, deletes
  the entry, advances the head. `test_cancelDepositRequest_queuesRefundAndSettleIsExact`.
- FIFO; partial settlement keeps the head and a later call completes (two half redeems pay
  499_999_999_998 + 499_999_999_999 >= 999_999_999_998); `maxRequests` honoured; `maxRequests = 0`
  and empty queue are no-ops; zero entries only ever sit behind the head.
  `test_processCancelledDepositQueue_partialThenComplete`, `_maxRequestsHonoured`, `_emptyQueueNoOp`,
  `_zeroEntriesOnlyBehindHead`.
- spUSDC yield accrued while in the cancelled queue goes to the canceller (10% VSR, 1 year: ~1.1M
  paid). `test_processCancelledDepositQueue_yieldWhileQueuedGoesToCanceller`.
- Cancel and settlement revert `SparkPrimeVault/paused` while paused.
  `test_cancelDepositRequest_revertsWhenPaused`, `test_processCancelledDepositQueue_revertsWhenPaused`.
- Double cancel and cancel of a filled id: `no-request`; zero recipient: `invalid-recipient`;
  non-owner: `not-authorized`; out-of-range id: panic 0x32.
- Fuzz (24 random cancel/settle/take/return/warp steps, 20k runs):
  `pendingCancelledDepositSavingsShares == sum(open cancelled entries)`,
  `pendingDepositSavingsShares == sum(open deposit entries)`,
  `vault spUSDC + taken == pendingDeposit + pendingCancelled`, both heads <= length, every entry
  behind a head is zero. `testFuzz_cancelledQueue_countersTrackOpenEntries`.
- `realizeLoss`: exact chi `floor((TA - L) * RAY / S)` = 908_718_991_417_304_243_366_635_929 for
  L = 100_000e6 on 990_405_184_109 shares; event `LossRealized(chi, loss)`; rho refreshed; reverts
  `not-paused`, `invalid-loss`, `AccessControlUnauthorizedAccount` for admin/guardian/alice;
  `totalSupply == 0` and `loss > totalAssets` both panic with arithmetic underflow (0x11, the
  subtraction happens before the division). Escrowed redeem shares take the loss pro rata (drop
  within [100_000e6, 100_000e6 + 2] for alice and for bob's escrow), queued spUSDC deposits do not
  (carol's entry stays 95_453_269_114 spUSDC and fills for ~99_999_999_999 USDC of value
  post-loss). `test_realizeLoss_*`, `testFuzz_realizeLoss_newChiNeverExceedsOld`.
- Head loops: ghosts walk the head one step each; a real request behind ghosts fills instantly;
  cancelling the head skips later ghosts and cancelled entries; cancelling a non-head entry does not
  move the head; `depositHead <= length` throughout.
  `test_requestDeposit_skipsGhostsAndFillsInstantly`,
  `test_cancelDepositRequest_headCancelAdvancesPastGhostsAndCancelled`.
- Entries are deleted after a full fill in both queues. `test_processQueues_entriesDeletedAfterFill`.
- `pause` is GUARDIAN-only (admin reverts), `unpause` is admin-only (unpauser and guardian revert).
  `test_pause_guardianCanAdminCannot`.
- `asset() == USDC`, `decimals == 6`, `DOMAIN_SEPARATOR` matches EIP-712 with name
  "Spark Prime USDC" / version "1"; `take` over balance reverts `SparkPrimeVault/insufficient-shares`.
- Events: `DepositRequest(owner, recipient, id, assets, savingsShares)` carries 954_532_691_143;
  `Redeem(owner, recipient, shares, assets)` order confirmed.

## (c) Unsettled

- Whether the recipient updaters are meant to exist at all (N-1); if they are, whether a GUARDIAN
  path is wanted alongside the owner check.
- What floor `realizeLoss` should enforce (N-2 / C-3); the tests only prove that none exists.
- Netting (`processQueues`) is not on this branch, so the cancelled queue's interaction with
  netting is untested.
