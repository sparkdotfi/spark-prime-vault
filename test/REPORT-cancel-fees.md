# CANCEL-FEES worker report: `test/CancelAndFees.t.sol`

48 tests, all passing (47 unit + 1 fuzz at 5000 runs). No new bug severe enough for a
`test_BUG_` failing proof; three new low/info items below, the rest quantifies known findings.

Harness indexes at `setUp`: `chi_s = 1.047633055711877768967605062e27`,
`chi_p = 1.009687768242461209408770821e27`. 100e6 USDC in = 95_453_269 spUSDC shares
(worth 99_999_999) = 99_040_517 spPRIME shares (worth 99_999_998). 1_000_000e6 in =
954_532_691_143 spUSDC = 990_405_184_109 spPRIME (worth 999_999_999_998).

## (a) Bugs and suspicious behaviour

### N-1 Low: request/cancel cycles create dead queue entries that `minDeposit` does not stop
`src/SparkPrimeVault.sol:403` (`delete depositQueue[requestId_]`), `:648` (`continue` on
cancelled entry inside the `maxRequests_` window).
Scenario: minDeposit 100e6, capacity 0, bob queued at id 0. A griefer recycles one 100e6
through 50 request/cancel cycles (ids 1..50, cost 1 wei USDC each plus gas), then alice queues
at id 51. `processDepositQueue(max, 50)` fills bob only and stops at head 50; two more calls
are needed to reach alice. Cancelled entries consume `maxRequests_` budget and ~2.3k gas each
on a cold pass, exactly like the F-5 ghosts, but this path cannot be closed with `minDeposit`
or a non-zero-amount check. Deposit cancel is fee-free so the cost is pure gas.
Impact: throughput griefing of the planner (bounded by `maxRequests_`, no fund risk).
Tests: `test_cancelDepositRequest_cancelledEntriesConsumeRequestBudget`,
`test_cancelDepositRequest_thenReRequestQueuesBehindOthers`.
Fix option: charge a deposit-cancel fee, or count only fills against `maxRequests_` and keep a
separate iteration cap for gas.

### N-2 Low: `cancelRedeemRequest` accepts `recipient_ == address(0)` and `address(vault)`
`src/SparkPrimeVault.sol:450-465`. `requestRedeem` (line 423) and `transfer` (line 485) reject
address(0); the cancel path does not. Owner cancel with recipient 0 moves 99_040_517 escrowed
shares to `balanceOf[address(0)]` with `totalSupply` unchanged (99_040_517), so they keep
consuming capacity forever. Recipient == vault strands the shares in the vault with
`pendingRedeemShares` 0 (same stuck state as I-6 donations). Deposit cancel to address(0) is
caught by USDC (`ERC20InvalidReceiver(0x0)` from the mock; mainnet USDC also reverts).
Impact: self-inflicted loss only; capacity leak.
Tests: `test_cancelRedeemRequest_zeroRecipientNotRejected`,
`test_cancelRedeemRequest_recipientVaultStrandsShares`,
`test_cancelDepositRequest_zeroRecipientRevertsInAsset`.
Fix: `require(recipient_ != address(0) && recipient_ != address(this))` in both cancels.

### N-3 Info: `setMaxRedeemFee` below the live `redeemFee` leaves the higher fee in force
`src/SparkPrimeVault.sol:256-259`, `:322-325`. With `redeemFee` 1%, admin sets `maxRedeemFee`
to 0.1%: `redeemFee` stays 1% and new requests still burn 9_904_051_842 of 990_405_184_109
shares; the risk manager can no longer re-set 1% (reverts `SparkPrimeVault/fee-too-high`), only
values <= 0.1%. Operational foot-gun, no fund risk.
Test: `test_setMaxRedeemFee_belowCurrentFeeLeavesFeeInForce`.
Fix: clamp `redeemFee = _min(redeemFee, fee_)` inside `setMaxRedeemFee`.

### Known findings, now quantified

- F-2 Medium (`:294-303`, `:410-411`): A and B each queue 100e6 (95_453_269 spUSDC each).
  Taker takes 95_453_269. A cancels and receives 99_999_999 USDC, vault spUSDC drops to 0.
  B's cancel reverts `SparkVault/insufficient-balance` (owner and guardian alike).
  `_returnToVault(95_453_269)` unblocks B (99_999_999 USDC). With 143_179_903 taken (150e6
  worth) both cancels revert; returning 47_726_634 lets exactly one of them out. After the take,
  `processDepositQueue` still mints 99_040_517 to each: `totalAssets()` 199_999_997 against
  50_000_000 USDC of real backing. Tests: `test_cancelDepositRequest_revertsAfterTakeSpentBacking`,
  `test_cancelDepositRequest_bothStuckWhenTakeExceedsOneRequest`,
  `test_processDepositQueue_stillMintsAfterTakeSpentBacking`.
- F-5 Low (ghost gas, cold storage via `vm.cool`): `processDepositQueue(max, 502)` costs
  142_397 gas for 2 real requests and 1_306_812 with 500 zero-asset ghosts between them
  (2_328 gas per ghost). `processRedeemQueue(max, 501)`: 106_281 vs 1_310_502 with 500 one-wei
  redeem ghosts at 1% fee (2_408 per ghost; each ghost burns 1 wei of the attacker's shares).
  Cancel of a ghost reverts `SparkPrimeVault/no-request`. Tests:
  `test_processDepositQueue_gasWith500GhostEntries`, `test_processRedeemQueue_gasWith500GhostEntries`.
- F-7 Low: both cancels revert `SparkPrimeVault/paused` for owner and guardian; `take()` still
  pulls the full 95_453_269 spUSDC during the pause; after `unpause` cancels succeed. Tests:
  `test_cancelDepositRequest_revertsWhilePaused`, `test_cancelRedeemRequest_revertsWhilePaused`.
- F-8 Low: guardian cancel of a 1_000_000e6 redeem at 1% fee returns 980_501_132_267 shares;
  the user permanently loses 9_904_051_842 shares = 10_000_000_001 USDC of claim.
  Test: `test_cancelRedeemRequest_guardianCancelKeepsFee`.
- I-2: the burned fee does not move `chi` (`convertToAssets(1e6)` identical before and after)
  and does not change the spUSDC balance. After alice's 1_000_000e6 redeem at 1% fills
  (989_999_999_997 USDC paid), 9_545_326_913 spUSDC worth 10_000_000_001 USDC remain with
  `totalSupply == 0`, and `take(9_545_326_913)` extracts all of it. With bob holding 100e6
  alongside, bob's claim stays 99_999_998 while real backing minus notional is 10_000_000_003.
  Tests: `test_requestRedeem_feeLeavesChiUnchangedAndRaisesBackingPerShare`,
  `test_requestRedeem_feeNotCreditedToRemainingHolders`.
- I-4: minWithdraw 100e6 at 1% fee. 99_040_518 shares (99_999_999 USDC gross) reverts
  `SparkPrimeVault/below-minimum`; 99_040_519 (exactly 100_000_000 gross) passes, queues
  98_050_113 and pays 98_999_999 USDC: 1_000_001 wei below the configured minimum.
  minDeposit 100e6: 99_999_999 reverts, 100e6 passes.
  Tests: `test_requestRedeem_minWithdrawIsGrossOfFee`, `test_requestDeposit_minDepositBoundary`.
- I-6: `transfer`/`transferFrom` of 1_000_000 shares to the vault leaves
  `balanceOf(vault) = 1_000_000`, `pendingRedeemShares = 0`; redeem fills and cancels around it
  are unaffected (fills only burn `request.shares` from the vault balance), no function recovers
  them, and they consume capacity: with `maxCapacity == totalSupply` a new 100e6 deposit queues.
  Tests: `test_transfer_toVaultStrandsSharesWithoutBreakingQueues`, `test_transferFrom_toVaultStrandsShares`.

## (b) Properties that held

- Owner can cancel own deposit/redeem to any recipient; stranger and the fill recipient revert
  `SparkPrimeVault/not-authorized`; guardian can cancel anyone's and the refund always goes to
  `request.owner` regardless of `recipient_` (F-1 patch).
  `test_cancel{Deposit,Redeem}Request_ownerCanChooseRecipient`, `_revertsNotAuthorized`,
  `_guardianRefundsOwnerIgnoringRecipient`.
- Cancelled, filled, and ghost ids revert `SparkPrimeVault/no-request`; out-of-range ids revert
  with `Panic(0x32)`. `_revertsNoRequest_alreadyCancelled`, `_revertsNoRequest_alreadyFilled`,
  `_revertsOutOfRange` for both queues.
- Partial deposit fill: capacity 39_616_207 shares fills 38_181_306 spUSDC and mints 39_616_205
  (2 shares of capacity unused by rounding); cancel refunds the remaining 57_271_963 spUSDC as
  60_000_001 USDC; minted value + refund = 99_999_998 (1 wei lost at deposit, 1 at fill).
  `test_cancelDepositRequest_partialFillRefundsRemainder`.
- Partial redeem fill: 40e6 of spUSDC liquidity pays 39_999_999 USDC for 39_616_207 shares,
  cancel returns the remaining 59_424_310 shares exactly; `totalSupply` and
  `pendingRedeemShares` consistent throughout. `test_cancelRedeemRequest_partialFillRefundsRemainder`.
- Cancelling the head entry leaves `depositHead`/`redeemHead` untouched; the next process
  skips it and advances the head past the filled entries (head 2 after filling id 1).
  `test_cancel{Deposit,Redeem}Request_headEntryThenProcessSkipsIt`.
- After cancel with an empty queue, a re-request fills instantly and the head is reset then
  advanced (head 2 for id 1). `test_cancelDepositRequest_thenReRequestFillsInstantlyWhenQueueEmpty`.
- Fee math (fuzz, shares in [1, 1e30], rate in [0, 1e16], 5000 runs): fee ==
  ceil(shares * rate / 1e18), fee <= shares, fee == 0 iff rate == 0, queued == shares - fee,
  `totalSupply` drops by exactly fee, owner balance drops by shares, vault balance and
  `pendingRedeemShares` rise by queued. `testFuzz_requestRedeem_feeIsCeil`. Rate 1e-18 on
  99_040_517 shares charges 1 wei. `test_requestRedeem_feeRoundsUpToOneWei`. Shares 0 reverts
  `SparkPrimeVault/below-minimum`. `test_requestRedeem_revertsZeroShares`.
- Fee is locked at request: lowering `redeemFee` from 1% to 0 after alice's request does not
  change her payout (989_999_999_997); bob requesting after the change pays 0 (999_999_999_998).
  `test_processRedeemQueue_feeChangeAfterRequestHasNoEffect`.
- `setRedeemFee(0.01e18 + 1)` and `setMaxRedeemFee(0.01e18 + 1)` revert
  `SparkPrimeVault/fee-too-high`; exactly 1% is accepted by both.
  `test_setRedeemFee_revertsAboveMax`, `test_setMaxRedeemFee_revertsAboveOnePercent`.
- Yield while queued: a 1_000_000e6 deposit queued for 365 days at 5% spUSDC VSR cancels to
  1_049_999_999_998 USDC, identical to the wei to holding spUSDC directly; a spPRIME holder at
  VSR RAY stays at 999_999_999_998. Filled instead of cancelled, it mints 1_039_925_443_313
  shares (worth 1_049_999_999_997), 49_520_259_204 more than the holder who deposited the same
  USDC earlier. No extraction beyond spUSDC's own yield; the queue is spUSDC exposure with no
  fee. `test_cancelDepositRequest_queuedDepositEarnsSpUsdcYield`,
  `test_processDepositQueue_fillCreditsSpUsdcYieldAccruedWhileQueued`.
- Escrowed redeem shares keep accruing: request 1_000_000e6 at 1% fee, 365 days at 5% VSR,
  cancel returns exactly 980_501_132_267 shares worth 1_039_499_999_997.
  `test_cancelRedeemRequest_afterChiGrowthReturnsSharesIntact`.
- Deposit/cancel cycles lose exactly 1 wei USDC per cycle (spUSDC floor on the way in), 10
  cycles: 100e6 -> 99_999_990. Redeem/cancel cycles lose exactly the fee each time (3 cycles at
  1%: 990_405_184_109 -> 960_989_159_734) with backing untouched.
  `test_cancelDepositRequest_cycleLosesOneWeiPerRound`, `test_cancelRedeemRequest_cycleLosesFeeEachRound`.

## (c) Unsettled

- Gas figures come from the local harness with `vm.cool` on the three contracts before each
  measured call; mainnet numbers will differ slightly (proxy, real USDC) but the per-entry cost
  (~2.3-2.4k gas, one cold SLOAD plus loop overhead) is structural.
- Whether cancelled entries should count against `maxRequests_` (N-1) is a planner design
  question: a planner that sizes `maxRequests_` by the number of live requests can be starved by
  a griefer at 1 wei per entry.
