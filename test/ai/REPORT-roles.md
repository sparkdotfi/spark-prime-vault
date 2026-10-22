# ROLES-ADMIN worker report

## Round 6 (`master` @ `c512609`): seven-role matrix, pause scope, admin bounds, `adjustTotalAssets` as a hot-wallet role

Branch `campaign-v6/roles-admin`, upstream `src/SparkPrimeVault.sol` = `master` @ `c512609` ("test: Small fix and improve coverage (#51)"), unpatched. Files: `test/ai/Authorization.t.sol` (85 tests), `test/ai/Admin.t.sol` (110 tests, 11 of them fuzz), both on `test/ai/LocalTestBase.t.sol`.

Run: `FOUNDRY_OFFLINE=true forge test --skip test/ai/TestBase.t.sol --match-path 'test/ai/{Authorization,Admin}.t.sol'`. Result: 85 passed / 110 passed, 0 failed; every `testFuzz_` also green at `FOUNDRY_FUZZ_RUNS=20000`. `--skip test/ai/TestBase.t.sol` is needed because the ported fork harness in the worktree does not compile (duplicate `operator` / `OPERATOR_ROLE` identifiers left by the sed rename, lines 28-38); it is not this worker's file. Every `test_BUG_` test in this scope PASSES: it is a proof of the behaviour, not a deliberately failing test.

Line numbers refer to `src/SparkPrimeVault.sol` @ `c512609`.

Port notes. Both files were rewritten rather than patched: the sed `guardian -> pauser`, `rebalancer -> operator`, `vsrSetter -> operator` renames were wrong for `setCapacity` (admin -> operator), `unpause` (admin -> unpauser), `adjustTotalAssets` (admin -> lossManager) and every actor list (8 actors / 7 roles now). All revert strings became selectors; `recipient-cannot-receive` tests were rewritten to assert that blacklisted recipients and spUSDC ARE accepted by `requestDepositCancellation` and the three updaters (the check no longer exists). `requestDepositCancellation` gained the `savingsShares` argument and its event the `sharesCancelled` field; `initialize` the three minimums. Tests asserting `pause` blocks `requestDepositCancellation` / `processPendingDepositCancellations` became `test_fixed_R5B_*` asserting the opposite. Tests reading a cancelled entry by id after a full cancel at the head were changed to assert the head moved (the single-entry getter now reverts `InvalidRequestId` below the head). Removed outright with no replacement: nothing. The old `CHI_SLOT = 8` constant became a packed write to slot 7 (`rho` offset 0, `chi` offset 8), checked by `forge inspect`.

### (a) New findings

| # | Location | Scenario (exact) | Impact | Severity | Test |
|---|---|---|---|---|---|
| R6-1 (new) | `:422-423`, `:434-438` | A partial cancel can strand a remainder below `minDepositCancellation`. Queue a 100 USDC deposit (`S` = 95,45x,xxx spUSDC shares), `minDepositCancellation = S - 5`, cancel `S - 5`: 5 shares remain. Cancelling 5 reverts `BelowMinDepositCancellation`, cancelling `S - 5` reverts `SavingsSharesTooHigh`. The remainder can only leave through an operator fill or an admin lowering the minimum. With a launch minimum of e.g. 50 spUSDC a user who cancels all but 49.99 of a 100 deposit is stuck until the queue moves. Fix: allow `savingsShares_ == request.shares` regardless of the minimum (full cancel always permitted). | User funds stuck in a queue they tried to leave; no loss. | Low | `test_BUG_R6_1_minDepositCancellation_remainderBelowMinimumIsUncancellable` |
| R6-2 (C-3 re-rated, open) | `:262-283` | `adjustTotalAssets` is now `LOSS_MANAGER_ROLE` (hot wallet) and only needs `paused` (`PAUSER_ROLE`, hot wallet). No admin, timelock or governance is in the path, and there is no floor on the loss and no cap on the gain other than `ChiTooHigh`. Down: `-(totalAssets - 1)` on a 1,000,000 USDC vault leaves `totalAssets() <= 1`, the full backing stays and a third hot wallet (`TAKER_ROLE`) takes it during the pause. Up: `+1,000,000e6` on a 2,000 USDC vault (alice 1,000, bob 1,000), unpause, alice redeems all her shares: the per-entry liquidity bound (`:953`) fills her entry with every USDC the vault holds (`2,000e6 - 154` wei, dust below one share's value of 501 wei) against ~0.2% of her shares; bob's later redeem gets 0 and is unfillable. Three hot keys (or two plus a holder) can therefore move the whole backing to any holder of their choosing. | Hot-key compromise = total loss for other holders, no on-chain brake. | High (was High under the admin; re-rated because the key moved from a governance address to an operational one) | `test_BUG_C3_lossFloorAbsent_hotWalletsOnly`, `test_BUG_C3_gainUnbounded_hotWalletLetsOneHolderDrainBacking` |
| R6-3 (info) | `:304-306`, `:213` vs `:365-368` | Role-separation observations for the runbook: the admin holds no hot role and cannot pause, unpause, set capacity or VSR, process, take, set the fee or adjust the index itself (every cell of the matrix below). Losing the unpauser mid-incident leaves the vault paused until the admin grants a successor; losing the only admin makes every hot key unrotatable (V2-8 below). `setCapacity` (V2-7 brick) is now a hot-wallet action. | Operational. | Info | `test_pauseUnpause_strictSeparation`, `test_revokeUnpauser_whilePaused_adminMustAppointSuccessor`, `test_BUG_V2_7_*` |
| R6-4 (info) | `upgradeToAndCall` | An EOA target reverts with EMPTY data (the `proxiableUUID()` return-data decode fails in the caller, outside OZ's `try`), a contract target without `proxiableUUID` reverts `ERC1967InvalidImplementation`; the authorization check runs first in both cases; the implementation itself refuses `upgradeToAndCall` with `UUPSUnauthorizedCallContext` before any role check. | None; documented for the runbook. | Info | `test_upgradeToAndCall_invalidImplementation`, `test_upgradeToAndCall_notThroughProxy` |

### (b) Status of prior findings touched

| Finding | Status at c512609 | Pinning test |
|---|---|---|
| R5-B (round 4): pause should not block cancellations | Fixed (#61): `requestDepositCancellation` (full and partial) and `processPendingDepositCancellations` work while paused, owner-only / operator-only respectively; the budget-0 walk advances past cancelled heads during the pause. | `test_fixed_R5B_pause_doesNotBlockRequestDepositCancellation`, `test_fixed_R5B_pause_doesNotBlockProcessPendingDepositCancellations` |
| C-8 minimums | Partially fixed: zero rejected in `initialize` (`ZeroMinDeposit` / `ZeroMinDepositCancellation` / `ZeroMinRedeem`, checked before the `savings_` call) and in the three setters; still unbounded above: `uint256.max` blocks every deposit / redeem / cancel; `minDeposit > maxCapacity` still partially fills and strands the rest; `minRedeem` still gross of fee. | `test_initialize_zeroMin*`, `testFuzz_initialize_minimums`, `test_setMin*_zero*`, `testFuzz_setMin*`, `test_BUG_C8_*` (4), `test_setMinRedeem_grossOfFee` |
| V2-13 / R5-7 vault as recipient | Fixed for the vault in `requestDepositCancellation` and the three updaters (`VaultIsRecipient`, checked right after `ZeroRecipient`); spUSDC still accepted (open low). | `test_requestDepositCancellation_checkOrder`, `test_updateRecipient_recipientChecksFirst` |
| R4-A / R4-B blacklist | Changed: no `isBlacklisted` check anywhere; blacklisted recipients are accepted by the updaters and by `requestDepositCancellation`; `claim` to a still-blacklisted recipient reverts in USDC and preserves the credit; `totalClaimable` tracks every credit and claim. | `test_updateRecipient_recipientChecksFirst`, `test_claim_blacklistedRecipientReverts`, `test_claim_permissionless`, `test_adjustTotalAssets_doesNotTouchClaimableAssets` |
| R5-1 / G-1 drip overflow | Open, unchanged: bound `type(uint256).max / RAY` (`:655`), second bound `uint256.max / totalSupply` (`:658`), `uint192` check at `:280` is 54,210,108x too loose; the loss manager (hot wallet) can brick every drip-dependent path one second later and cannot undo it; `take` still works; only an admin upgrade (`SparkPrimeVaultChiRescue`) recovers. | `test_BUG_G1_dripOverflowThresholdExact`, `test_BUG_G1_dripOverflowBoundShrinksWithVsr`, `test_BUG_G1_dripDiffOverflowBoundWithLargeSupply`, `test_BUG_G1_adjustTotalAssetsBricksDripAndCannotUndo` |
| R5-2 gain MEV | Open: a deposit between public payload and `pause` takes 50e6 of a 100e6 gain. | `test_BUG_R5_2_adjustTotalAssets_depositBeforePauseCapturesGain` |
| R5-3 / C-3 no floor | Open, re-rated High (R6-2). | see (a) |
| R5-5 / F-2 take ignores queues | Open: `take` of a queued deposit's spUSDC makes the cancellation settle nothing (no revert, waits for the backing); a redeem fill spends a queued depositor's spUSDC. | `test_BUG_F2_take_ignoresPendingDepositSavingsShares`, `test_BUG_F2_redeemFillSpendsQueuedDepositBacking`, `test_pause_doesNotBlockTake` |
| R5-6 / V2-8 admin can vanish | Open, blast radius changed: after the last admin renounces (or revokes itself) no upgrade, no role change, no minimum / bound / max-fee change for any of the 8 actors; the hot roles keep working (unpauser unpauses, loss manager adjusts, operator processes) but can never be rotated, so the next lost hot key is permanent (shown: unpauser renounces, next pause is for ever, backing still takeable). `initialize(..., address(0), 1, 1, 1)` still accepted. Severity stays Medium. | `test_BUG_V2_8_lastAdminCanRenounce`, `test_BUG_V2_8_lastAdminCanRevokeSelf`, `test_BUG_V2_8_zeroAdminAtInit`, `test_BUG_V2_8_initialize_zeroAdminNotGuarded` |
| R5-8 / V2-7 capacity overflow | Open, now operator-reachable: exact threshold `totalSupply + type(uint256).max / nowChi()`; one wei more bricks `requestDeposit` with an empty queue, `processPendingDeposits` for any budget, AND (new) `requestDepositCancellation`, since its budget-0 walk computes the same `convertToAssets(availableCapacity())` (`:864`); lower cap repairs. Coupled index bound (R5-4) unchanged. | `test_BUG_V2_7_setCapacityMaxBricksDeposits`, `test_BUG_V2_7_setCapacityOverflowThresholdExact`, `test_setCapacity_coupledWithChi` |
| R5-11 / C-7 non-clamping | Open: `setMaxRedeemFeeRate` below the live fee leaves a 1% fee charged (exact `RedeemRequest` event with the fee), `setVSRBounds` below the live VSR keeps ~10% accruing; the admin cannot lower either (`AccessControlUnauthorizedAccount(admin, REDEEM_FEE_SETTER_ROLE / OPERATOR_ROLE)`); a revoked operator leaves the rate in force. | `test_BUG_C7_setMaxRedeemFeeRate_belowCurrentFeeLeavesFeeAboveMax`, `test_BUG_C7_setVSRBounds_doesNotClampLiveVsr`, `test_revokeOperator_rateStaysInForce` |
| R5-13 / C-9 MAX_VSR 100% | Open: doubles the notional in a year, operator key. | `test_BUG_C9_setVSR_maxDoublesNotionalInAYear` |
| R4-2 uint192 cast | Fixed: `ChiTooHigh` at the first value above `type(uint192).max`, index untouched. | `test_fixed_R4_2_chiTooHighBoundary` |
| R3-1 realizeGain sandwich | Fixed: `IsNotPaused` before `ZeroDeltaTotalAssets`; requests revert `IsPaused` around the adjustment. | `test_fixed_R3_1_adjustTotalAssetsRequiresPause` |
| V2-2 / F-1, V2-1 | Fixed, re-pinned with selectors (`NotRequestOwner`, `NoRequest`, `InvalidRequestId` instead of a panic). | `test_fixed_F1_requestDepositCancellation_ownerOnly`, `test_fixed_V2_1_updateRecipient_ownerOnly` |
| I-3 removed surface | `GUARDIAN_ROLE()`, `REBALANCER_ROLE()`, `VSR_SETTER_ROLE()`, `realizeGain`, `realizeLoss`, `cancelRedeemRequest`, 2-arg `requestDeposit`, 2-arg `requestDepositCancellation`, 4-arg `initialize` all miss the dispatcher; the old role names gate nothing. | `test_fixed_removedSurface_selectorsGone` |
| R5-9 zero-supply panic | Unchanged (info): positive delta at `totalSupply == 0` panics 0x12, negative reverts `LossTooHigh`, huge delta panics 0x11 before `ChiTooHigh`. | `test_adjustTotalAssets_zeroSupplyPanics` |

### Authorization matrix (c512609)

Columns are the single role each actor holds. OK = succeeds; X = reverts `AccessControlUnauthorizedAccount(caller, <required role>)`. Every cell is asserted by `test_<fn>_notAuthorized` / `test_<fn>_authorized`; `test_roles_eachActorHoldsExactlyOneRole` pins the setup.

| Function | required role | ADMIN | LOSS_MANAGER | OPERATOR | PAUSER | UNPAUSER | REDEEM_FEE_SETTER | TAKER | stranger |
|---|---|---|---|---|---|---|---|---|---|
| setMaxRedeemFeeRate, setMinDeposit, setMinDepositCancellation, setMinRedeem, setVSRBounds | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| upgradeToAndCall | DEFAULT_ADMIN | OK (re-`initialize` via data reverts `InvalidInitialization`) | X | X | X | X | X | X | X |
| grantRole / revokeRole (all 7 roles) | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| renounceRole(role, self) | none | OK | OK | OK | OK | OK | OK | OK | OK (no-op); another account: `AccessControlBadConfirmation()` |
| adjustTotalAssets (paused and unpaused; role checked before `IsNotPaused`) | LOSS_MANAGER | X | OK (paused) | X | X | X | X | X | X |
| setCapacity, setVSR | OPERATOR | X | X | OK | X | X | X | X | X |
| processPendingDeposits / Redeems / DepositCancellations | OPERATOR | X | X | OK | X | X | X | X | X |
| pause | PAUSER | X | X | X | OK | X | X | X | X |
| unpause | UNPAUSER | X | X | X | X | OK | X | X | X |
| setRedeemFeeRate | REDEEM_FEE_SETTER | X | X | X | X | X | OK | X | X |
| take | TAKER | X | X | X | X | X | X | OK | X |
| requestDepositCancellation (not owner) | owner only | `NotRequestOwner` for all 8, owner as recipient does not help; owner may name any recipient but 0 and the vault (blacklisted and spUSDC accepted) |
| updateDepositRecipient / updateDepositCancellationRecipient / updateRedeemRecipient (not owner) | owner only | `NotRequestOwner` for all 8; dead entry `NoRequest`; id past the end `InvalidRequestId`; `ZeroRecipient` / `VaultIsRecipient` first |
| requestDeposit, requestRedeem, claim, drip, approve, transfer, transferFrom, permit (x2) | none | OK for all 8 (`test_permissionless_stranger`, `test_claim_permissionless`, `test_drip_permissionless`) |

`getRoleAdmin(role) == DEFAULT_ADMIN_ROLE` for every role including unknown ones; a second admin has the full admin surface and can revoke the first, and still holds no hot role; enumeration agrees, is in grant order, swap-and-pops on revoke, panics 0x32 out of range.

### Pause scope (c512609)

| Function | While paused | Test |
|---|---|---|
| requestDeposit (any referral), requestRedeem | blocked `IsPaused` | `test_pause_blocksRequestDeposit`, `test_pause_blocksRequestRedeem` |
| processPendingDeposits, processPendingRedeems | blocked for the operator; a stranger gets the role error first | `test_pause_blocksProcessPending*` |
| requestDepositCancellation (owner, full or partial) | ALLOWED (new); head self-skip runs | `test_fixed_R5B_pause_doesNotBlockRequestDepositCancellation` |
| processPendingDepositCancellations (operator) | ALLOWED (new); exact `DepositCancellation` event, bob refunded `50e6 - 1` | `test_fixed_R5B_pause_doesNotBlockProcessPendingDepositCancellations` |
| update*Recipient | allowed for the owner only | `test_pause_doesNotBlockUpdateRecipient` |
| take | allowed (F-2) | `test_pause_doesNotBlockTake`, `test_take_whilePaused` |
| drip, claim | allowed | `test_pause_doesNotBlockDrip`, `test_pause_doesNotBlockClaim` |
| adjustTotalAssets | allowed, and ONLY while paused; exact `TotalAssetsAdjusted(chi, delta)` | `test_pause_enablesAdjustTotalAssets` |
| approve / transfer / transferFrom / permit | allowed | `test_pause_doesNotBlockERC20`, `test_pause_doesNotBlockPermit` |
| every setter from its own role, grant / revoke | allowed | `test_pause_doesNotBlockSetters`, `test_setCapacity_whilePaused`, `test_setVSR_whilePaused` |
| upgradeToAndCall | allowed, `paused` survives | `test_pause_doesNotBlockUpgrade` |
| pause when paused / unpause when not paused | idempotent, event still emitted | `test_pause_idempotent`, `test_unpause_idempotent`, `test_pauseUnpause_eventsExact` |

### (c) Code paths and the test that covers each

| Path (`c512609`) | Test |
|---|---|
| `initialize` `:184-186` zero minimums (order, before the `savings_` call) | `test_initialize_zeroMin*`, `testFuzz_initialize_minimums` |
| `initialize` `:188-209` full state, admin grant event, allowance | `test_initialize`, `test_initialize_defaultsAreSafe` |
| `initializer` on proxy / implementation / via upgrade data | `test_initialize`, `test_initialize_implementationDisabled`, `test_upgradeToAndCall_reinitializeReverts` |
| `_authorizeUpgrade` `:213` | `test_upgradeToAndCall_notAuthorized/authorized/invalidImplementation/notThroughProxy` |
| `setMaxRedeemFeeRate` `:219-222` bound + event | `test_setMaxRedeemFeeRate_maxFeeTooHighBoundary`, `test_setMaxRedeemFeeRate`, `testFuzz_setMaxRedeemFeeRate` |
| `setMinDeposit` `:224-228`, `setMinDepositCancellation` `:230-238`, `setMinRedeem` `:240-244` | `test_setMin*`, `test_setMin*_zero*`, `testFuzz_setMin*`, `test_setMinimums_boundaries`, `test_setMinDepositCancellation_inSavingsShares` |
| `setVSRBounds` `:251-255` three checks in order + event | `test_setVSRBounds_*Boundary`, `test_setVSRBounds`, `testFuzz_setVSRBounds` |
| `adjustTotalAssets` `:267` IsNotPaused, `:268` zero, `:270` drip, `:274` LossTooHigh, `:277` div by zero, `:279` ChiTooLow, `:280` ChiTooHigh, `:282` event | `test_fixed_R3_1_*`, `test_adjustTotalAssets_zeroDeltaTotalAssets`, `_dripsFirst_*`, `_noDripWhenNoTimePassed`, `test_BUG_C3_*`, `_zeroSupplyPanics`, `_chiTooLowOnlyAboveRaySupply`, `test_fixed_R4_2_chiTooHighBoundary`, `_gain`, `_loss`, `_repeated`, `_lossGainRoundTripNotIdentity`, `_gainRoundingBoundedBySupplyOverRay`, `testFuzz_adjustTotalAssets_exactFormula` |
| `adjustTotalAssets` interactions: pending redeems vs deposits, capacity in USD, claimable, take during pause, cancellation during pause, deposit before pause | `_lossHitsPendingRedeemsNotPendingDeposits`, `_lossShrinksCapacityInUsd`, `_doesNotTouchClaimableAssets`, `_takeDuringPauseIsIndependent`, `_cancellationDuringPauseUnaffected`, `test_BUG_R5_2_*` |
| `take` `:290-297` bound, event, zero, paused, pending ignored | `test_take_insufficientSharesBoundary`, `test_take`, `test_take_zero`, `testFuzz_take`, `test_take_whilePaused`, `test_BUG_F2_*` |
| `setCapacity` `:304-306` | `test_setCapacity`, `testFuzz_setCapacity`, `_zeroFreezesMinting`, `_belowTotalSupply`, `_whilePaused`, `test_BUG_V2_7_*`, `_coupledWithChi` |
| `setVSR` `:309-314` bounds, drip-first, event | `test_setVSR_vsrTooLowBoundary/HighBoundary`, `test_setVSR`, `_dripsAtOldRate`, `_lockedWhenBoundsEqual`, `_whilePaused`, `testFuzz_setVSR`, `test_BUG_C9_*` |
| `processPending*` `:317-341` role + pause gating (cancellations NOT gated) | `test_processPending*_notAuthorized/authorized`, `test_pause_blocksProcessPending*`, `test_fixed_R5B_*` |
| `setRedeemFeeRate` `:347-350` | `test_setRedeemFeeRate_feeTooHighBoundary`, `_zeroMaxLocksFee`, `test_setRedeemFeeRate`, `testFuzz_setRedeemFeeRate` |
| `pause` `:356-359`, `unpause` `:365-368` | `test_pause_*`, `test_unpause_*`, `test_pauseUnpause_strictSeparation`, `test_pauseUnpause_eventsExact` |
| `requestDepositCancellation` `:414-445` check order, owner-only, pause, event, self-skip | `test_requestDepositCancellation_checkOrder`, `_owner`, `test_fixed_F1_*`, `test_fixed_R5B_*`, `test_requestDepositCancellation_eventExact`, `test_BUG_R6_1_*` |
| updaters `:482-525` | `test_fixed_V2_1_updateRecipient_ownerOnly`, `test_updateRecipient_recipientChecksFirst`, `test_pause_doesNotBlockUpdateRecipient` |
| `claim` `:531-543` incl. `totalClaimable` | `test_claim_permissionless`, `test_claim_blacklistedRecipientReverts`, `test_pause_doesNotBlockClaim` |
| ERC20 `:549-587`, permit `:593-642` | `test_approve`, `test_transfer*`, `test_transferFrom*`, `test_permit*`, `test_erc20_metadata` |
| `drip` `:648-663` overflow bounds | `test_BUG_G1_*`, `test_drip_permissionless` |
| OZ AccessControlEnumerable (grant, revoke, renounce, admin, enumeration) | `test_grantRole_*`, `test_revokeRole_*`, `test_renounceRole_*`, `test_getRoleAdmin_allDefaultAdmin`, `test_getRoleMember_enumeration` |
| Revocation mid-flight (operator, taker, pauser, unpauser, loss manager) | `test_revokeOperator_*`, `test_revokeTaker_*`, `test_revokePauser_*`, `test_revokeUnpauser_*`, `test_revokeLossManager_*` |

### (d) Properties that held

- Every role-gated function reverts with the exact OZ error for the 7 other actors, paused and unpaused; the admin holds no hot role; `_setRoleAdmin` is unreachable.
- `adjustTotalAssets`: `chi == floor((totalAssets + delta) * RAY / totalSupply)` after a drip for deposits in `[2, 1e9 USDC]` and deltas in `[-(totalAssets - 1), 1e30]` (20,000 runs); notional moves by delta within 1 wei; a loss never raises and a gain never lowers the index; the backing never moves; no `Drip` log when no time passed.
- Setters: every accepted value is stored and emitted exactly and every rejected value leaves the previous one in place, for arbitrary `uint256` inputs (`testFuzz_setCapacity`, `testFuzz_setMaxRedeemFeeRate`, `testFuzz_setRedeemFeeRate`, `testFuzz_setMinDeposit`, `testFuzz_setMinDepositCancellation`, `testFuzz_setMinRedeem`, `testFuzz_setVSRBounds`, `testFuzz_setVSR`, `testFuzz_take`, `testFuzz_initialize_minimums`, 20,000 runs each); `setVSRBounds` and `setVSR` check in the documented order.
- `minDepositCancellation` is in spUSDC share units: a 100 USDC request (95.45e6 shares) cannot be fully cancelled with a 96e6 minimum.
- `claimableAssets` / `totalClaimable` are excluded from `totalAssets`, untouched by `adjustTotalAssets` and `take`, paid exactly by `claim` from any caller.
- Bounds exact: `MaxFeeTooHigh` at `0.01e18 + 1`, `FeeTooHigh` at `max + 1`, `maxRedeemFeeRate = 0` locks the fee; `MinVSRTooLow` at `RAY - 1`, `MaxVSRTooHigh` at `MAX_VSR + 1`, `MinVSRGtMaxVSR`; `VSRTooLow` / `VSRTooHigh` at the bound +/- 1; `InsufficientShares` at `balance + 1`; `LossTooHigh` at `-(totalAssets)`; `ChiTooLow` floor `totalSupply / RAY + 1` once `totalSupply > RAY`; `ChiTooHigh` at the first representable value above `uint192.max`.
- Cancellation self-skip: a full cancel at the head advances `firstPendingDepositId` past it and past any already-cancelled entries behind it, also while paused; a partial cancel leaves the head in place.

### (e) Unsettled

- R6-2 severity depends on the key-management model for `LOSS_MANAGER_ROLE` / `PAUSER_ROLE` / `TAKER_ROLE` (multisig vs EOA, timelock); the on-chain code offers no brake either way. A relative cap per call (e.g. `|delta| <= totalAssets / 10`) plus a cooldown would bound a compromised key.
- G-1 fix shape as in round 5: the right guard is `updatedChi_ * MAX_VSR_RPOW <= uint256.max` and `updatedChi_ * totalSupply <= uint256.max`, or a relative cap on the write-up.
- `int256(totalAssets())` at `:272` wraps silently above `int256.max`; unreachable with `chi <= uint192.max` and any supply below ~1e46 shares, not tested.
- `test/ai/TestBase.t.sol` (fork harness) does not compile in this worktree; not this worker's file, skipped.

---

## Round 5 (`master` @ `0ebb452`): authorization matrix, pause scope, admin bounds, `adjustTotalAssets`

Branch `campaign-v5/roles-admin`, upstream `src/SparkPrimeVault.sol` = `master` @ `0ebb452` ("refactor: More Cleanup (#26)"), unpatched. Files: `test/ai/Authorization.t.sol` (78 tests), `test/ai/Admin.t.sol` (85 tests), both on the local harness `test/ai/LocalTestBase.t.sol` (real spUSDC code, 6-decimal mock USDC with a Circle-style blacklist, "ugly" indexes, VSR frozen at RAY).

Run: `FOUNDRY_OFFLINE=true forge test --match-path 'test/ai/Authorization.t.sol'` and `... 'test/ai/Admin.t.sol'`. Result: 78 passed / 85 passed, 0 failed (`testFuzz_adjustTotalAssets_exactFormula` also at `FOUNDRY_FUZZ_RUNS=20000`). Every `test_BUG_` test in this scope PASSES: it is a proof of the behaviour, not a deliberately failing test.

Line numbers refer to `src/SparkPrimeVault.sol` @ `0ebb452`. Port notes: `realizeGain` / `realizeLoss` tests were rewritten against `adjustTotalAssets(int256)` (DEFAULT_ADMIN, requires `paused`); the `riskManager -> redeemFeeSetter` sed rename was wrong for every loss test (now admin + pause); the guardian-cancel tests became `test_fixed_F1_*`; `cancelRedeemRequest`, `UNPAUSER_ROLE`, the 2-arg `requestDeposit` and the harness `unpauser` actor are gone and are asserted as selector misses in `test_fixed_removedSurface_selectorsGone`. Nothing was deleted without a replacement; `Upgrade.t.sol` is no longer in this worker's scope.

### (a) Findings and suspicious behaviour

| # | Location | Scenario (exact) | Impact | Test | Severity |
|---|---|---|---|---|---|
| R5-1 (G-1, open) | `:637` (`drip`), `:811` (`nowChi`), guarded only by `:292` | `drip()` computes `_rpow(vsr, dt) * chi` in uint256 and `_rpow(RAY, dt) == RAY` for every `dt`, so with `vsr == RAY` the largest index that survives one more second is exactly `type(uint256).max / RAY = 115792089237316195423570985008687907853269984665640` (~1.158e50). At that value `drip` works for ever (365 days later still returns it); at `+1` every `drip`, `nowChi`, `totalAssets`, `assetsOf`, `convertToShares` revert with panic 0x11. Both pass the `chi <= type(uint192).max` check at `:292`, which is 54,210,108 times too loose. `adjustTotalAssets` reaches it: on a 1,000 USDC vault (supply ~9.9e8) the smallest delta is ~1.147e32 base units (~1.1e26 USDC). Same block: all fine. One second later: `requestDeposit`, `requestRedeem`, all three `processPending*`, `setVSR`, `drip`, the views, and `adjustTotalAssets` itself (it calls `drip()` at `:282` before its own checks, so `-delta` cannot undo it) revert. `take` still works. Recovery only through `upgradeToAndCall` to an implementation that writes `chi` without dripping (proven with `SparkPrimeVaultChiRescue`). With `vsr > RAY` the bound is `type(uint256).max / _rpow(vsr, dt)`: the exact `RAY` bound reverts one second after `setVSR(MAX_VSR)`. Second, independent bound: `totalSupply * nChi` at `:640` and `shares * nowChi` at `:793` require `chi <= type(uint256).max / totalSupply`; with 2e27 shares (2e21 USDC) that is ~5.8e49, below the `RAY` bound, and `nowChi()` still works while `drip()` / `totalAssets()` / `adjustTotalAssets` revert. Fix: `require(updatedChi_ <= type(uint256).max / MAX_VSR / ...)` is not enough on its own because of the supply bound; a relative cap on the write-up (e.g. `updatedChi_ <= 2 * chi`) or an explicit `updatedChi_ * totalSupply` and `updatedChi_ * MAX_RPOW` check closes both. | Admin fat-finger, irrecoverable in-contract; holders frozen while the backing can leave. | `test_BUG_G1_dripOverflowThresholdExact`, `test_BUG_G1_dripOverflowBoundShrinksWithVsr`, `test_BUG_G1_dripDiffOverflowBoundWithLargeSupply`, `test_BUG_G1_adjustTotalAssetsBricksDripAndCannotUndo` | Low (admin only), High consequence |
| R5-2 (C-3, open) | `:286-291` | `adjustTotalAssets(-(totalAssets - 1))` on a 1,000,000 USDC vault is accepted: `chi = RAY / totalSupply`, `totalAssets() <= 1`, `assetsOf(alice) <= 1`, all shares still exist, the full ~1,000,000 USDC of spUSDC backing stays in the vault and is takeable in full (`_takeAll`). `-(totalAssets)` and larger revert `loss-too-high`. A later `+(totalAssets - 1)` restores the notional, so the admin alone decides what holders are worth. `chi-too-low` is only reachable once `totalSupply > RAY` (1e21 USDC): the floor is then `totalSupply / RAY + 1` base units (`chi == 1`), proven at 1.1e27 shares. | No drawdown floor on one DEFAULT_ADMIN call. | `test_BUG_C3_lossFloorAbsent`, `test_adjustTotalAssets_chiTooLowOnlyAboveRaySupply` | High (trust model) |
| R5-3 (V2-7, open) | `:297-299` with `:829` -> `:793` | `setCapacity` is unbounded. Exact threshold: the first overflow is `availableCapacity() * nowChi()` in `convertToAssets`, so the largest working `maxCapacity` is `totalSupply + type(uint256).max / nowChi()` (~1.147e50 share units at chi ~1.0098e27); one wei more and `requestDeposit` with an empty queue reverts panic 0x11 (the instant-fill walk runs `_processPendingDeposits`), and `processPendingDeposits` reverts regardless of `maxSavingsShares_` (the overflow is inside `_min`'s argument). With a non-empty queue, `requestDeposit` is accepted (no walk) and the entry can never be processed. Redeems, cancellations, transfers and the admin surface keep working; a lower cap repairs it. spUSDC's `convertToShares(assets)` does not overflow at the threshold (`assets * RAY <= uint256.max`). | Deposit brick by admin typo, reversible. | `test_BUG_V2_7_setCapacityMaxBricksDeposits`, `test_BUG_V2_7_setCapacityOverflowThresholdExact` | Low |
| R5-4 (new, info) | `:829` / `:793` | The real invariant is `availableCapacity() * nowChi() <= type(uint256).max`: cap and index are coupled. With the harness cap of `uint128.max`, a gain that lifts chi to `type(uint256).max / availableCapacity() + 1` (~3.4e38, 3.4e11 times below the drip bound and 1.8e19 times below the `uint192` check) bricks deposits while `drip` still works; `setCapacity(totalSupply + 1e12)` restores them. At that index 1 USDC converts to 0 shares: the request fills, the entry is consumed, bob is minted 0 shares (zero-share mint, F-4, at an admin-made index). | Runbook item: a large `adjustTotalAssets` gain must be paired with a capacity check. | `test_setCapacity_coupledWithChi` | Info |
| R5-5 (C-7, open) | `:301-304`, `:314-320` | `setMaxRedeemFeeRate(0.001e18)` with the live fee at `0.01e18` leaves the fee at 1% (`fee = ceil(shares * 0.01e18 / WAD)` on the next request); `setVSRBounds(RAY, ONE_PCT_VSR)` with the live `vsr` at 10% keeps accruing ~10% for a year. The admin cannot lower either value itself (`AccessControlUnauthorizedAccount(admin, REDEEM_FEE_SETTER_ROLE / VSR_SETTER_ROLE)`); only the hot role can, and a revoked VSR setter leaves the rate in force for ever. | Admin cannot contain a compromised hot key without first granting itself the role. | `test_BUG_C7_setMaxRedeemFeeRate_belowCurrentFeeLeavesFeeAboveMax`, `test_BUG_C7_setVSRBounds_doesNotClampLiveVsr`, `test_revokeVsrSetter_rateStaysInForce` | Low |
| R5-6 (C-8, open) | `:306-312` | `setMinRedeem(uint256.max)` blocks every redeem request (`below-minimum` at `shares_ - 1e6` and at `1`); already-queued redeems still process. `setMinDeposit(uint256.max)` blocks every deposit. `minDeposit (1,000e6) > maxCapacity (100e6)`: a 1,000 USDC request fills 100e6 +/- 2 and queues the rest behind an unreachable cap. `minRedeem` is checked on gross shares: with 1% fee a 100e6 request queues 99e6, below the 100e6 minimum. | Admin fat-finger only. | `test_BUG_C8_setMinRedeem_noValidation_blocksAllRedeems`, `test_BUG_C8_setMinDeposit_noValidation_blocksAllDeposits`, `test_BUG_C8_setMinDeposit_aboveCapacity`, `test_setMinRedeem_grossOfFee` | Low |
| R5-7 (C-9, open) | `:163` | `MAX_VSR` = 100% APY: `setVSR(MAX_VSR)` then 365 days doubles `totalAssets()` (within 2 wei of `2 * before`) while the backing stays at ~1,000 USDC. Bounds `[RAY, RAY]` at deploy lock it until the admin widens them. | Hot-key write-up bounded only by the admin's `maxVSR`. | `test_BUG_C9_setVSR_maxDoublesNotionalInAYear`, `test_setVSR_lockedWhenBoundsEqual` | Low |
| R5-8 (V2-8, open) | `:259`, OZ `renounceRole` / `revokeRole` | The only DEFAULT_ADMIN can `renounceRole(DEFAULT_ADMIN_ROLE, self)` or `revokeRole` itself (`RoleRevoked(0x00, admin, admin)`, member count 0). Proven while paused with a queued redeem: `unpause`, `upgradeToAndCall`, `grantRole`, `adjustTotalAssets`, `setCapacity` revert `AccessControlUnauthorizedAccount(_, 0x00)` for all 7 actors, `processPendingRedeems` reverts `paused`, `take` still drains the backing. `initialize(..., address(0))` is accepted: `getRoleMember(0x00, 0) == address(0)`, no setter, no guardian can ever be appointed, no pause. | Operational: permanent loss of control. OZ `AccessControlDefaultAdminRules` or a two-step would close it. | `test_BUG_V2_8_lastAdminCanRenounce`, `test_BUG_V2_8_lastAdminCanRevokeSelf`, `test_BUG_V2_8_zeroAdminAtInit`, `test_BUG_V2_8_initialize_zeroAdminNotGuarded` | Medium |
| R5-9 (new, info) | `:289` | `adjustTotalAssets` with `totalSupply == 0` and a positive delta panics with division by zero (0x12): fresh vault and after every share is redeemed. Negative delta reverts `loss-too-high` first. `type(int256).max` reverts 0x11 at `:289` (`uint256(totalAssets_) * RAY`) before the division; `1e60` likewise, so `chi-too-high` is unreachable from very large deltas (the message only shows for `uint192.max < chi <= ~1.16e50 * totalSupply / RAY`). | Clean revert strings would help the runbook; no funds at risk. | `test_adjustTotalAssets_zeroSupplyPanics`, `test_fixed_R4_2_chiTooHighBoundary` | Info |
| R5-10 (R3-1 residual, info) | `:278-279` | `adjustTotalAssets` requires `paused`, but the admin is a governance spell whose payload is public before the guardian's separate `pause` tx. bob deposits 1,000 USDC after alice's 1,000 and before the pause; `+100e6` is split 50e6 / 50e6; bob exits with 1,050e6 +/- 3 right after the unpause. | MEV against existing holders on every gain; mitigated only by pausing before the payload is public. | `test_adjustTotalAssets_depositBeforePauseCapturesGain` | Info (acknowledged design) |
| R5-11 (new, info) | `:289` | A gain is floored into `chi`: the write-up is short by less than `ceil(totalSupply / RAY)` wei. Below `RAY` shares that is at most 1 wei (fuzz, 20,000 runs); at 2.2e27 shares `adjustTotalAssets(1)` can leave `totalAssets()` unchanged while `TotalAssetsAdjusted` still fires; `ceil(supply / RAY)` wei always moves the index. Loss-then-gain of 123,456,789 wei on a 1,000 USDC vault ends at or below the start by at most `2 * ceil(RAY / supply)` in chi units. | Dust; events can report a no-op gain. | `test_adjustTotalAssets_gainRoundingBoundedBySupplyOverRay`, `test_adjustTotalAssets_lossGainRoundTripNotIdentity`, `testFuzz_adjustTotalAssets_exactFormula` | Info |
| R5-12 (F-2, known) | `:340-349` | `take` is not paused and ignores both pending counters: while paused with a queued deposit and a queued cancellation it drains the whole spUSDC balance; the later `processPendingDepositCancellations` pays nothing and the refund waits. `take` cannot move USDC parked in `claimableAssets`. | Known single-exit design. | `test_pause_doesNotBlockTake`, `test_take_ignoresPendingDepositSavingsShares`, `test_adjustTotalAssets_doesNotTouchClaimableAssets` | Known |

### (b) Previously reported findings: status at 0ebb452

| Finding | Status | Pinning test |
|---|---|---|
| R3-1 `realizeGain` sandwich | Fixed: `adjustTotalAssets` requires `paused` (`not-paused` checked before `delta-total-assets-zero`); deposit / redeem requests revert `paused` around it; a post-unpause deposit is priced at the new index. Residual R5-10. | `test_fixed_R3_1_adjustTotalAssetsRequiresPause` |
| R4-2 `uint192` truncation | Fixed: `chi-too-high` at the first representable value above `type(uint192).max`, index untouched; `type(uint192).max` itself accepted. | `test_fixed_R4_2_chiTooHighBoundary` |
| R4-1 / G-1 drip brick | Open, re-measured with the exact bound and two independent bounds (R5-1). | `test_BUG_G1_*` |
| V2-2 / F-1 guardian cancel | Fixed: `requestDepositCancellation` is owner-only; guardian and every actor get `not-authorized` even naming the owner; counters and queues untouched. | `test_fixed_F1_requestDepositCancellation_ownerOnly` |
| V2-1 updaters | Fixed: owner-only, `no-request` before the owner check, recipient checks first (`zero-recipient`, `vault-recipient` for deposits, `recipient-cannot-receive` for cancellation / redeem). | `test_fixed_V2_1_updateRecipient_ownerOnly`, `test_updateRecipient_recipientChecksFirst` |
| I-3 `UNPAUSER_ROLE`, `CancelRedeemRequest` event, `no-shares` | Gone: `UNPAUSER_ROLE()`, `RISK_MANAGER_ROLE()`, `SETTER_ROLE()`, `realizeGain`, `realizeLoss`, `cancelRedeemRequest`, 2-arg `requestDeposit` all miss the dispatcher; an arbitrary bytes32 role gates nothing. | `test_fixed_removedSurface_selectorsGone` |
| C-3, C-7, C-8, C-9, V2-7, V2-8, F-2 | Open, see (a). | `test_BUG_*` above |
| R4-4 guardian cancel paused | Moot: the guardian path no longer exists; the owner's cancel is still paused. | `test_pause_blocksRequestDepositCancellation` |

### Authorization matrix (0ebb452)

Columns are the single role each actor holds. OK = succeeds; X = reverts `AccessControlUnauthorizedAccount(caller, <required role>)`. Every cell is asserted by `test_<fn>_notAuthorized` / `test_<fn>_authorized`.

| Function | required role | ADMIN | GUARDIAN | REBALANCER | REDEEM_FEE_SETTER | TAKER | VSR_SETTER | stranger |
|---|---|---|---|---|---|---|---|---|
| setCapacity, setMaxRedeemFeeRate, setMinDeposit, setMinRedeem, setVSRBounds | DEFAULT_ADMIN | OK | X | X | X | X | X | X |
| adjustTotalAssets (paused and unpaused; role checked before `not-paused`) | DEFAULT_ADMIN | OK (paused) | X | X | X | X | X | X |
| unpause | DEFAULT_ADMIN | OK | X | X | X | X | X | X |
| upgradeToAndCall | DEFAULT_ADMIN | OK (re-`initialize` via data reverts `InvalidInitialization()`) | X | X | X | X | X | X |
| grantRole / revokeRole (all 6 roles) | DEFAULT_ADMIN | OK | X | X | X | X | X | X |
| renounceRole(role, self) | none | OK | OK | OK | OK | OK | OK | OK (no-op); another account: `AccessControlBadConfirmation()` |
| setVSR | VSR_SETTER | X | X | X | X | X | OK | X |
| take | TAKER | X | X | X | X | OK | X | X |
| processPendingDeposits / Redeems / DepositCancellations | REBALANCER | X | X | OK | X | X | X | X |
| setRedeemFeeRate | REDEEM_FEE_SETTER | X | X | X | OK | X | X | X |
| pause | GUARDIAN | X | OK | X | X | X | X | X |
| requestDepositCancellation (not owner) | owner only | `not-authorized` for all 7, owner as recipient does not help; owner may name any non-blacklisted recipient |
| updateDepositRecipient / updateDepositCancellationRecipient / updateRedeemRecipient (not owner) | owner only | `not-authorized` for all 7; dead entry `no-request`; out-of-range panic 0x32 |
| requestDeposit, requestRedeem, claim, drip, approve, transfer, transferFrom, permit (x2) | none | OK for all 7 (`test_permissionless_stranger`, `test_claim_permissionless`, `test_drip_permissionless`) |

`getRoleAdmin(role) == DEFAULT_ADMIN_ROLE` for every role including unknown ones; a second admin has the full surface and can revoke the first; `getRoleMember` / `getRoleMemberCount` / `getRoleMembers` agree, enumerate in grant order, swap-and-pop on revoke, panic 0x32 out of range (`test_getRoleAdmin_allDefaultAdmin`, `test_grantRole_secondAdminHasFullPower`, `test_getRoleMember_enumeration`). Granting a held role and renouncing an unheld one are silent no-ops.

### Pause scope (0ebb452)

| Function | While paused | Test |
|---|---|---|
| requestDeposit (any referral) | blocked `SparkPrimeVault/paused` | `test_pause_blocksRequestDeposit` |
| requestDepositCancellation (owner) | blocked | `test_pause_blocksRequestDepositCancellation` |
| requestRedeem | blocked | `test_pause_blocksRequestRedeem` |
| processPendingDeposits / Redeems / DepositCancellations | blocked for the rebalancer; a stranger gets the role error first (`onlyRole` before `whenNotPaused`) | `test_pause_blocksProcessPending*` |
| update*Recipient | allowed for the owner only | `test_pause_doesNotBlockUpdateRecipient` |
| take | allowed (F-2) | `test_pause_doesNotBlockTake` |
| drip | allowed, chi keeps accruing | `test_pause_doesNotBlockDrip` |
| claim | allowed | `test_pause_doesNotBlockClaim` |
| setVSR | allowed | `test_pause_doesNotBlockSetVSR` |
| adjustTotalAssets | allowed, and ONLY while paused; exact `TotalAssetsAdjusted(chi, delta)` | `test_pause_enablesAdjustTotalAssets` |
| approve / transfer / transferFrom / permit | allowed | `test_pause_doesNotBlockERC20`, `test_pause_doesNotBlockPermit` |
| setCapacity, setMaxRedeemFeeRate, setMinDeposit, setMinRedeem, setVSRBounds, grantRole, revokeRole, setRedeemFeeRate | allowed | `test_pause_doesNotBlockAdminSetters` |
| upgradeToAndCall | allowed, `paused` survives | `test_pause_doesNotBlockUpgrade` |
| pause when paused / unpause when not paused | idempotent, event still emitted; guardian can never unpause | `test_pause_idempotent`, `test_unpause_idempotent`, `test_unpause_guardianCannotUnpause` |

### (c) Properties that held

- Every role-gated function reverts with the exact OZ error for the 6 other actors, paused and unpaused; `_setRoleAdmin` is never reachable.
- `adjustTotalAssets`: `chi == floor((totalAssets + delta) * RAY / totalSupply)` after a drip, for deposits in `[2, 1e9 USDC]` and deltas in `[-(totalAssets - 1), 1e30]` (fuzz 20,000 runs); the notional moves by delta within 1 wei; a loss never raises and a gain never lowers the index; the backing never moves; no `Drip` log when no time passed and `rho` untouched; `Drip(nowChi, diff)` then `TotalAssetsAdjusted` when time passed (`test_adjustTotalAssets_*`).
- A loss during the pause hits escrowed redeem shares exactly like holders (500e6 escrowed shares pay `500e6 * newChi / RAY`), while queued deposits (spUSDC shares) keep their USDC value and mint `assets * RAY / newChi` shares afterwards; share capacity is unchanged by a loss and its USD value shrinks pro rata (`test_adjustTotalAssets_lossHitsPendingRedeemsNotPendingDeposits`, `test_adjustTotalAssets_lossShrinksCapacityInUsd`).
- `claimableAssets` USDC is excluded from `totalAssets`, untouched by `adjustTotalAssets` and `take`, paid out exactly by `claim` from any caller once de-blacklisted, and the credit survives a reverting claim while blacklisted (`test_adjustTotalAssets_doesNotTouchClaimableAssets`, `test_claim_permissionless`, `test_claim_blacklistedRecipientReverts`).
- Setter events exact: `CapacitySet`, `MaxRedeemFeeRateSet`, `MinDepositSet`, `MinRedeemSet`, `VSRBoundsSet`, `Drip` + `VSRSet`, `RedeemFeeRateSet`, `TotalAssetsAdjusted`, `Paused`, `Unpaused`, `Take`, `RoleGranted`, `RoleRevoked`, `Claim`, `ClaimableAssetsIncreased`, `DepositCancellationRequest(depositId, cancelId, recipient)` (all indexed), the three `*RecipientUpdated`.
- Bounds exact: `fee-too-high` at `0.01e18 + 1` (admin) and `max + 1` (setter), `maxRedeemFeeRate = 0` locks the fee; `vsr-too-low` at `RAY - 1`, `vsr-too-high` at `MAX_VSR + 1`, `min-vsr-gt-max-vsr`; `setVSR` drips at the old rate first; `take` `insufficient-shares` at `balance + 1`; `setCapacity(0)` queues without minting; capacity below `totalSupply` queues (no revert) and fills once raised.
- `initialize`: full default state (chi = vsr = minVSR = maxVSR = RAY, everything else 0, USDC allowance to spUSDC max, admin sole member of every role list), `InvalidInitialization()` on the proxy, on the implementation, and through `upgradeToAndCall` data (upgrade rolled back).
- Revocation mid-flight: revoked REBALANCER freezes all three queues until a successor drains them (bob refunded `50e6 - 1`); revoked TAKER can still return spUSDC by plain transfer; revoked GUARDIAN loses pause while the admin can still unpause.
- ERC20 / permit: `invalid-address` for zero and the vault itself on `transfer` and `transferFrom`; balance checked before allowance; max allowance not decremented; self `transferFrom` needs no allowance; permit nonce rolls back on a failed signature; `deadline == now` valid; wrong domain / nonce / value / 64-byte EOA signature rejected.

### (d) Unsettled

- R5-1 severity: Low under the trust model (DEFAULT_ADMIN only) but the consequence is a frozen vault with a live `take`; two bounds (`RAY` product and `totalSupply` product) need a guard, and the right one is a relative cap on the write-up rather than a constant.
- R5-10 is a design decision (announce-then-apply vs pause-first); quantified only.
- The harness cap (`uint128.max`) makes R5-4 reachable at chi ~3.4e38; with a production cap of ~1e15 shares the coupled bound is ~1.16e62, above the `uint192` check, so R5-4 is harness-specific unless the cap is ever set absurdly high.
- `int256(totalAssets())` at `:284` wraps silently above `int256.max`; unreachable with `chi <= uint192.max` and any supply below ~1e46 shares, not tested.
- Fork PoCs and `Upgrade.t.sol` are outside this worker's files this round.

---

# ROLES worker report, round 4 (bf93b0d): authorization, admin bounds, pause scope, upgrade

Branch `campaign-v4/roles`, upstream `src/SparkPrimeVault.sol` = `fix/update-guardian-transfer` @ `bf93b0d` (merged unpatched). Files: `test/ai/Authorization.t.sol` (72 tests), `test/ai/Admin.t.sol` (84), `test/ai/Upgrade.t.sol` (15), `test/ai/mocks/SparkPrimeVaultV2Mock.sol`, plus the fork harness `test/ai/TestBase.t.sol` and `test/ai/Review.t.sol` (ported, compile only).

Run: `forge test --match-path 'test/ai/{Authorization,Admin,Upgrade}.t.sol' --skip test/ai/Adversarial.t.sol --skip test/ai/CancelAndFees.t.sol --skip test/ai/CancelledDepositQueue.t.sol --skip test/ai/DepositQueue.t.sol --skip test/ai/NewSurface.t.sol --skip test/ai/RedeemQueue.t.sol --skip test/ai/Rounding.t.sol --skip test/ai/Views.t.sol --skip test/ai/Review.t.sol --skip 'test/ai/invariants/*' -vv`. Result: 171 passed, 0 failed, 0 skipped. `forge build` with the same skips (fork files included): 0 errors.

Line numbers refer to `src/SparkPrimeVault.sol` @ `bf93b0d`.

## Fixed or removed since round 3

| # | Round-3 item | What changed at bf93b0d | Regression tests |
|---|---|---|---|
| R2-8 / F-1 (High, CANCEL-FEES) | Guardian cancel paid a guardian-chosen recipient | `src/SparkPrimeVault.sol:422-425`: for a non-owner caller, `hasRole(GUARDIAN_ROLE)` is checked first (`not-authorized`), then `recipient_ == request_.owner` (`invalid-recipient`). Guardian naming itself or a third party reverts and leaves the entry, both pending counters and the cancellation queue untouched; with the owner as recipient the refund settles to the owner (`100e6 - 1`). The owner path is unchanged and may still name any recipient. `cancelRedeemRequest` (the share-redirect half of F-1) is removed outright. | `test_requestDepositCancellation_guardian`, `test_requestDepositCancellation_checkOrder`, `test_cancelRedeemRequest_removed`, fork `test_F1_guardianCancelDepositRefundsOwnerOnly`, `test_F1_cancelRedeemRequestRemoved` |
| cancelRedeemRequest | Function removed | A queued redeem is final for everyone: owner, guardian and admin have no entry point that returns escrowed shares; only `processPendingRedeems` (REBALANCER) settles it. The selector reverts with empty data for all 8 actors. The `CancelRedeemRequest(uint256,uint256)` event at `:101` is still declared and never emitted (Info, dead code). | `test_cancelRedeemRequest_removed`, `test_cancelRedeemRequest_selectorGone` |
| R2-9 / I-3 (Info) | `UNPAUSER_ROLE` declared, unused | Constant removed at 731c1c8; `UNPAUSER_ROLE()` is no longer in the ABI. `unpause` stays DEFAULT_ADMIN. The harness still grants a local `keccak256("UNPAUSER_ROLE")` to `unpauser`; it gates nothing, so `unpauser` is a stranger with a meaningless role in the matrix below. | `test_unpause_unpauserRoleCannotUnpause`, `test_roleAdmins_unchangedByUpgrade` |

## Re-confirmed, unchanged at bf93b0d

| # | Location | Status | Tests | Severity |
|---|---|---|---|---|
| C-3 / R2-1 | `:372` | `require(loss_ > 0 && loss_ < totalAssets_)`: full loss rejected, `totalAssets - 1` still accepted, holders left with 1 wei in total. No drawdown floor. | `test_realizeLoss_totalAssetsMinusOneWipesHolders`, `test_realizeLoss_fullLossRejected`, `testFuzz_realizeLoss_neverRaisesChi` | High (trust model) |
| C-4 / R2-3 | `:246`, OZ `renounceRole`/`revokeRole` | Only admin can renounce or revoke itself; `initialize(..., address(0))` accepted. Afterwards `unpause`, `upgradeToAndCall`, `grantRole`, `realizeGain` are dead forever. | `test_renounceDefaultAdmin_vaultHasNoAdminForever`, `test_revokeDefaultAdmin_self_vaultHasNoAdminForever`, `test_initialize_zeroAdminNotGuarded` | Medium (operational) |
| C-7 / R2-4 | `:269-272`, `:282-288` | `setMaxRedeemFeeRate` / `setVSRBounds` tightened below the live value leave the live value in force. | `test_setMaxRedeemFee_belowCurrentFeeLeavesFeeAboveMax`, `test_setVSRBounds_currentVsrOutsideNewBounds` | Low |
| C-8 / R2-5 | `:274-280` | `setMinDeposit` / `setMinRedeem` unvalidated (`uint256.max` blocks every request; `minDeposit > maxCapacity`). | `test_setMinRedeem_noValidation_blocksAllRedeems`, `test_setMinDeposit_noValidation_blocksAllDeposits`, `test_setMinDeposit_aboveCapacity`, `test_setMinRedeem_grossOfFee` | Low |
| V2-7 / R2-6 | `:265-267` | `setCapacity` unbounded; `uint256.max` accepted, deposits then revert by overflow in `convertToAssets(availableCapacity())`. | `test_setCapacity_noUpperBound` | Low (NEWSURFACE owns) |
| realizeGain | `:293-305` | DEFAULT_ADMIN only for all 7 other actors paused and unpaused; `invalid-gain` at 0, `no-shares` on empty vault; no pause gate; `1e30` accepted; exact `GainRealized(chi, gain)` preceded by `Drip` when time passed. Upstream TODO at `:290` acknowledges it is front-runnable. | `test_realizeGain_notAuthorized`, `test_realizeGain_authorized`, `test_realizeGain*`, `testFuzz_realizeGain_neverLowersChi` | see R4-1, R4-2, R4-3 |
| F-2 / R2-10 | `:325-334` | `take` ignores both pending counters and is not paused. | `test_take_ignoresPendingDepositSavingsShares`, `test_take_whilePaused`, `test_pause_doesNotBlockTake` | Known |
| R3-1 | `:376` | `no-shares` in `realizeLoss` unreachable (`invalid-loss` runs first and `totalAssets == 0` whenever `totalSupply == 0`). | `test_realizeLoss_zeroSupplyReverts`, `testFuzz_realizeLoss_noSharesBranchUnreachable` | Info |

## New findings (round 4)

| # | Location | Scenario | Impact | Test | Severity |
|---|---|---|---|---|---|
| R4-1 | `src/SparkPrimeVault.sol:302` (`realizeGain`), `:620` (`drip`) | Admin calls `realizeGain(1e35)` on a 1,000 USDC vault (any gain that lands chi above ~`1.16e50` with `vsr == RAY`; the bound shrinks as `vsr` rises). The `uint192` cast does not truncate at this size. | Same timestamp: everything still works (`drip` short-circuits on `block.timestamp <= rho`). One second later `_rpow(vsr, dt) * chi` overflows uint256 and every path that drips reverts with panic 0x11: `requestDeposit`, `requestRedeem`, all three `processPending*`, `setVSR`, `realizeLoss` (drips before its own checks, so it cannot undo the gain), `realizeGain`, `drip`, and the views `nowChi` / `totalAssets` / `convertTo*`. `take` still works, so the backing can leave while holders cannot. Recovery only by `upgradeToAndCall` to a patched implementation. A `require(chi_ <= MAX_CHI)` (or a relative cap on the write-up) in `realizeGain` closes it; the same cap belongs in `realizeLoss` for symmetry even though loss cannot raise chi. | `test_realizeGain_hugeGainBricksDripNextBlock` | Low (admin only, fat-finger; irrecoverable without an upgrade) |
| R4-2 | `src/SparkPrimeVault.sol:302` | Admin passes a gain whose full-precision chi is `2^192 + RAY` (about `6.3e39` USDC on a 1,000 USDC vault). | The `uint192(...)` cast wraps silently: `GainRealized` is emitted, stored chi becomes ~`RAY`, below the previous ~`1.0098e27`, `totalAssets` and every `assetsOf` drop. A "gain" call that lowers the index; `realizeLoss` guards the other direction with `loss_ < totalAssets_`, `realizeGain` has no symmetric check. Same fix as R4-1. | `test_realizeGain_uint192TruncationLowersChi` | Low (admin only, fat-finger) |
| R4-3 | `src/SparkPrimeVault.sol:290-293` | A depositor sees the admin's `realizeGain` transaction (a public spell payload, per the upstream TODO) and deposits in the same block before it; queues a redeem right after. | The gain is spread pro rata over the share holders at that block. With alice and bob holding equal shares, bob's deposit made one block earlier takes `50e6` of a `100e6` gain that was earned before he arrived, and exits with `1_050e6` in the same block (no holding period, no fee at rate 0). `realizeGain` is not gated on `paused`, and a pause would not help since the spell is public before the guardian can act. Owner-acknowledged TODO; pinned as data. | `test_realizeGain_frontRunnable` | Info (acknowledged; MEV against the vault's other holders, not the protocol) |
| R4-4 | `src/SparkPrimeVault.sol:409-410` | Guardian wants to return a queued deposit to its owner during an incident. | `requestDepositCancellation` is `whenNotPaused` for the guardian path too, so the compliance cancel (now owner-refund only) is unavailable exactly when the vault is paused; it works again after `unpause`. Data for the pause-scope table; no funds at risk. | `test_pause_blocksDepositCancellationRequest_guardianWithOwnerRecipient` | Info |
| R4-5 | `src/SparkPrimeVault.sol:101` | `event CancelRedeemRequest(uint256 indexed requestId, uint256 shares)` declared, never emitted. | Dead code in the ABI; indexers listening for it will never see it. | `test_cancelRedeemRequest_selectorGone` | Info |

No `test_BUG_` tests in this scope: every behaviour above is pinned by a passing test.

## Authorization matrix (bf93b0d)

Columns are the single role each actor holds. `unpauser` holds only the harness-local bytes32, which the contract does not know, so it behaves as a stranger. OK = succeeds; X = reverts `AccessControlUnauthorizedAccount(caller, <required role>)`. Every cell is asserted by `test_<fn>_notAuthorized` / `test_<fn>_authorized` in `Authorization.t.sol`.

| Function | required role | ADMIN | GUARDIAN | REBALANCER | RISK_MGR | SETTER | TAKER | "unpauser" | stranger |
|---|---|---|---|---|---|---|---|---|---|
| setCapacity | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setMaxRedeemFeeRate | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setMinDeposit | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setMinRedeem | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setVSRBounds | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| realizeGain | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| unpause | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| upgradeToAndCall | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| grantRole (6 contract roles + harness role) | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| revokeRole (same) | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| renounceRole(role, self) | none | OK | OK | OK | OK | OK | OK | OK | OK (no-op); for another account: `AccessControlBadConfirmation()` |
| setVSR | SETTER | X | X | X | X | OK | X | X | X |
| take | TAKER | X | X | X | X | X | OK | X | X |
| processPendingDeposits | REBALANCER | X | X | OK | X | X | X | X | X |
| processPendingRedeems | REBALANCER | X | X | OK | X | X | X | X | X |
| processPendingDepositCancellations | REBALANCER | X | X | OK | X | X | X | X | X |
| setRedeemFeeRate | RISK_MANAGER | X | X | X | OK | X | X | X | X |
| realizeLoss (paused) | RISK_MANAGER | X | X | X | OK | X | X | X | X |
| pause | GUARDIAN | X | OK | X | X | X | X | X | X |
| requestDepositCancellation (not owner), recipient == owner | owner or GUARDIAN | `not-authorized` | **OK** (refund to owner on settlement) | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` |
| requestDepositCancellation (not owner), recipient != owner | owner only | `not-authorized` | **`invalid-recipient`** | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` |
| requestDepositCancellation (owner), any non-zero recipient | owner | OK | OK | OK | OK | OK | OK | OK | OK |
| cancelRedeemRequest | **removed** | selector miss (empty revert) for every actor and the owner | | | | | | | |
| updateDepositRecipient, updateDepositCancellationRecipient, updateRedeemRecipient (not owner) | owner only | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized`; owner OK; dead entry `no-request`; zero recipient `invalid-recipient` (checked first); out-of-range id panic 0x32 |
| requestDeposit (x2), requestRedeem, update own recipient, approve, transfer, transferFrom, permit (x2), drip | none | OK | OK | OK | OK | OK | OK | OK | OK (`test_permissionless_stranger`, `test_updateRecipient_ownerOnly`) |

Check order in `requestDepositCancellation` (`:414-425`): `invalid-recipient` (zero) -> `no-request` -> `not-authorized` -> `invalid-recipient` (guardian recipient != owner) -> out-of-range panic comes from the array read before any of them (`test_requestDepositCancellation_checkOrder`).

`getRoleAdmin(role) == DEFAULT_ADMIN_ROLE` for DEFAULT_ADMIN and the five contract roles, before and after upgrade; `_setRoleAdmin` is never called (`test_grantRole_authorized`, `test_roleAdmins_unchangedByUpgrade`).

## Pause scope (bf93b0d)

| Function | While paused | Test |
|---|---|---|
| requestDeposit(assets, recipient) | blocked, `SparkPrimeVault/paused` | `test_pause_blocksRequestDeposit` |
| requestDeposit(assets, recipient, referral) | blocked | `test_pause_blocksRequestDepositWithReferral` |
| requestDepositCancellation (owner) | blocked | `test_pause_blocksDepositCancellationRequest` |
| requestDepositCancellation (guardian, recipient == owner) | blocked (R4-4) | `test_pause_blocksDepositCancellationRequest_guardianWithOwnerRecipient` |
| requestRedeem | blocked | `test_pause_blocksRequestRedeem` |
| processPendingDeposits | blocked | `test_pause_blocksProcessDepositQueue` |
| processPendingRedeems | blocked | `test_pause_blocksProcessRedeemQueue` |
| processPendingDepositCancellations | blocked (queued refunds wait) | `test_pause_blocksProcessCancelledDepositQueue` |
| updateDepositRecipient / updateDepositCancellationRecipient / updateRedeemRecipient | allowed for the owner only; strangers `not-authorized` | `test_pause_doesNotBlockUpdateRecipient` |
| take | allowed (F-2) | `test_pause_doesNotBlockTake`, `test_take_whilePaused` |
| drip | allowed, chi keeps accruing | `test_pause_doesNotBlockDrip` |
| setVSR | allowed | `test_pause_doesNotBlockSetVSR` |
| realizeLoss | allowed (requires paused) | `test_pause_doesNotBlockRealizeLoss` |
| realizeGain | allowed (also allowed unpaused); emits only `GainRealized` when no time passed | `test_pause_doesNotBlockRealizeGain`, `test_realizeGain_whilePaused`, `test_realizeGain_whilePausedNoPauseEventSideEffects` |
| approve / transfer / transferFrom | allowed | `test_pause_doesNotBlockERC20` |
| permit | allowed | `test_pause_doesNotBlockPermit` |
| setCapacity, setMaxRedeemFeeRate, setMinDeposit, setMinRedeem, setVSRBounds, grantRole, revokeRole, setRedeemFeeRate | allowed | `test_pause_doesNotBlockAdminSetters` |
| upgradeToAndCall | allowed, `paused` survives the upgrade | `test_pause_doesNotBlockUpgrade` |
| pause when paused / unpause when not paused | idempotent, event still emitted | `test_pause_idempotent`, `test_unpause_idempotent`, `test_pauseUnpause_eventsExact` |

## Storage layout status

`forge inspect SparkPrimeVault storage-layout` at bf93b0d is identical to the round-2 table (below, round-2 section): 27 linear slots, `savings` (0) .. `allowance` (26), `asset` + `decimals` packed in slot 1, `rho` + `chi` in slot 4, `paused` alone in slot 8, queues at 18..20 (`_depositRequests`, `_depositCancellationRequests`, `_redeemRequests`), heads at 21..23 (`firstPendingDepositId`, `firstPendingDepositCancellationId`, `firstPendingRedeemId`), mappings at 24..26. Removing `cancelRedeemRequest` and reordering views changed no state. `SparkPrimeVaultV2Mock.newVar` still lands at slot 27 (empty before `initializeV2`, 777 after; Initializable slot moves 1 -> 2).

Upgrade state preservation now diffs: all 27 raw slots, the three mapping bases via computed keys, 41 scalar getter fields, `availableCapacity`, `assetsOf`, `DOMAIN_SEPARATOR`, and the six queue views (`getPendingDepositRequests()` / `(start, end)`, `getPendingDepositCancellationRequests()` / `(start, end)`, `getPendingRedeemRequests()` / `(start, end)`), hashed before and after the upgrade, plus the three heads and all role member sets. The no-arg views equal the ranged views from the head to the length (`test_upgradeToAndCall`, `test_upgradeToAndCall_withReinitializer`, `test_upgradeToAndCall_roundTrip`, `test_storageLayout_packing`).

## Properties that held

- Every role-gated function reverts with the exact OZ custom error for all other actors and a stranger, paused and unpaused (`realizeGain` both ways).
- `initialize`: `initializer` guard (`InvalidInitialization()` on the proxy before and after upgrade, on both implementation contracts, `_initialized == uint64.max` on implementations); re-running `initialize` through `upgradeToAndCall` data reverts and rolls the upgrade back; the only external calls inside are to the admin-chosen `savings_` / `asset_`; `admin == address(0)` still accepted (C-4).
- `_authorizeUpgrade`: `onlyRole(DEFAULT_ADMIN_ROLE)`, `view`, no other condition; `UUPSUnsupportedProxiableUUID`, `ERC1967InvalidImplementation`, `UUPSUnauthorizedCallContext` exact; `upgradeToAndCall{value: 1}(impl, "")` reverts `ERC1967NonPayable()`; with value and a non-payable initializer the whole call reverts, no ETH is ever left in the proxy (`test_upgradeToAndCall_nonPayableWithoutData`, `test_upgradeToAndCall_valueWithNonPayableInitializer`).
- `renounceRole`: self only (`AccessControlBadConfirmation()` for another account), emits `RoleRevoked(role, self, self)`; the last admin can renounce (C-4).
- Every setter emits its exact event and nothing else: `CapacitySet`, `MaxRedeemFeeRateSet`, `MinDepositSet`, `MinRedeemSet`, `VSRBoundsSet`, `VSRSet`, `RedeemFeeRateSet`, `GainRealized(chi, gain)`, `LossRealized(chi, loss)`, `Paused()`, `Unpaused()`, `Take(uint256 shares)` (no taker address), `RoleGranted`, `RoleRevoked`, `Upgraded`. Request events exact: `DepositCancellationRequest(depositRequestId, cancelRequestId)` with sequential cancel ids for owner and guardian cancels, `DepositRecipientUpdated`, `DepositCancellationRecipientUpdated`, `RedeemRecipientUpdated` (`test_requestDepositCancellation_eventExact`, `test_updateRecipient_eventsExact`, `test_pauseUnpause_eventsExact`).
- Bounds: `fee-too-high` at `0.01e18 + 1` (admin) and `max + 1` (risk manager); `vsr-too-low` / `vsr-too-high` / `min-vsr-gt-max-vsr` exact; `setVSR` drips at the old rate first; `take` bounded by spUSDC balance with `insufficient-shares` at `balance + 1`.
- `realizeLoss`: `not-paused`, `invalid-loss` at 0 and at `totalAssets`, exact chi, drips first, chi strictly decreases (fuzz 1000 runs), accepted range `[1, totalAssets - 1]`.
- Revocation mid-flight: revoked REBALANCER freezes all three queues until a successor drains them; revoked TAKER can still return spUSDC by plain transfer; revoked GUARDIAN loses pause and the owner-refund cancel while the admin can still unpause.
- Fresh defaults: capacity 0, max fee 0, bounds `[RAY, RAY]` lock SETTER and RISK_MANAGER until the admin widens them.

## Unsettled

- R4-1 / R4-2 are the only new code-level items. Both are a single admin typo away and the first is unrecoverable without an upgrade; a `MAX_CHI` style bound in `realizeGain` (and a matching guard on the `uint192` cast) is the suggested fix. NEWSURFACE/ROUNDING previously owned the thresholds; this round pins the exact consequence on the admin surface.
- R4-3 (front-run of `realizeGain`) is acknowledged in the source TODO. Whether a holding period, a fee floor, or an announce-then-apply pattern is wanted is a design decision.
- Fork PoCs (`test/ai/TestBase.t.sol`, `test/ai/Review.t.sol`) compile under `forge build`; F-1 now asserts the fix; still not executed (no RPC).
- C-3 severity stays High under the trust model: a single hot RISK_MANAGER key can still write holders down to 1 wei in total.
- `transfer(address(vault), x)` permanently stuck (I-6) not re-tested here.

---

# ROLES worker report, round 3 (ff828d2): authorization, admin bounds, pause scope, upgrade

Branch `campaign-v3/roles`, upstream `src/SparkPrimeVault.sol` = `refactor/more-simplifying` @ `ff828d2` (merged via `review/poc-tests-v2`, unpatched). Files: `test/Authorization.t.sol` (73 tests), `test/Admin.t.sol` (76), `test/Upgrade.t.sol` (12), `test/mocks/SparkPrimeVaultV2Mock.sol`, plus the fork harness `test/TestBase.t.sol` and `test/Review.t.sol` (compile only; neither references `realizeLoss` or `update*Recipient`, so no port was needed).

Run: `forge test --match-path 'test/{Authorization,Admin,Upgrade}.t.sol' -vv`. Result: 161 passed, 0 failed, 0 skipped. `forge build` of the whole tree (fork files included): 0 errors.

Line numbers refer to `src/SparkPrimeVault.sol` @ `ff828d2`.

## Fixed since round 2

| # | Round-2 item | What changed at ff828d2 | Regression tests |
|---|---|---|---|
| R2-7 (Critical, NEWSURFACE) | `update*Recipient` had no authorization | `src/SparkPrimeVault.sol:416-425, 465-477, 537-546`: `require(recipient_ != 0)`, then `require(shares != 0, "no-request")`, then `require(msg.sender == request_.owner, "not-authorized")`. Every role holder (admin and guardian included), a stranger and the other depositor revert `not-authorized` on someone else's entry; the owner succeeds and only the payout address moves; dead entries revert `no-request` for owner and stranger alike (checked before the owner check); out-of-range ids panic 0x32. | `test_updateRecipient_ownerOnly`, `test_updateRecipient_zeroRecipient`, `test_pause_doesNotBlockUpdateRecipient` |
| R2-1 worst case (chi == 0 brick) | `realizeLoss(totalAssets())` set `chi = 0` for good | `src/SparkPrimeVault.sol:376`: `require(loss_ > 0 && loss_ < totalAssets_, "invalid-loss")`. Full loss is rejected, index and vault untouched, redeems still process after unpause. | `test_realizeLoss_fullLossRejected` |
| R2-2 (Info) | `loss > totalAssets` and empty vault reverted with panic 0x11 | Both revert `SparkPrimeVault/invalid-loss`. Boundary: `totalAssets + 1` and `totalAssets` revert, `totalAssets - 1` accepted. | `test_realizeLoss_aboveTotalAssetsBoundary`, `test_realizeLoss_zeroSupplyReverts` |

## Persisting

| # | Location | Status | Test | Severity |
|---|---|---|---|---|
| R2-1 (C-3) | `src/SparkPrimeVault.sol:369-385` | No floor. `realizeLoss(totalAssets - 1)` is accepted and leaves `chi = RAY / totalSupply`, holders worth 1 wei in total, backing intact and takeable. Pause + one hot RISK_MANAGER key, no admin involvement, no two-step. The brick is gone; the wipe-out is not. | `test_realizeLoss_totalAssetsMinusOneWipesHolders`, `testFuzz_realizeLoss_neverRaisesChi` (accepted range now `[1, totalAssets - 1]`, chi stays `> 0`) | High (trust model) |
| R3-1 (Info) | `src/SparkPrimeVault.sol:380` | The `no-shares` branch in `realizeLoss` is unreachable: `totalAssets() == convertToAssets(totalSupply)` is 0 whenever `totalSupply == 0`, and the `invalid-loss` check (`loss_ < 0` is false for every `loss_`) runs first. Dead code; the string can never be observed. | `test_realizeLoss_zeroSupplyReverts`, `testFuzz_realizeLoss_noSharesBranchUnreachable` | Info |
| R2-3 (C-4) | `:253`, OZ `renounceRole`/`revokeRole` | Only admin can still renounce or revoke itself; zero admin at init still accepted. Unchanged. `realizeGain` joins the list of functions dead forever afterwards. | `test_renounceDefaultAdmin_vaultHasNoAdminForever`, `test_revokeDefaultAdmin_self_vaultHasNoAdminForever`, `test_initialize_zeroAdminNotGuarded` | Medium (operational) |
| R2-4 (C-7) | `:276-279`, `:289-295` | Tightening a bound below the live value leaves the live value in force. Unchanged. | `test_setMaxRedeemFee_belowCurrentFeeLeavesFeeAboveMax`, `test_setVSRBounds_currentVsrOutsideNewBounds` | Low |
| R2-5 (C-8) | `:281-287` | `setMinDeposit` / `setMinRedeem` unvalidated. Unchanged. | `test_setMinRedeem_noValidation_blocksAllRedeems`, `test_setMinDeposit_noValidation_blocksAllDeposits`, `test_setMinDeposit_aboveCapacity`, `test_setMinRedeem_grossOfFee` | Low |
| R2-6 | `:272-274` | `setCapacity` has no upper bound. Unchanged. | `test_setCapacity_noUpperBound` | Low (NEWSURFACE owns the brick) |
| R2-8 | `:428-463`, `:509-535` | Guardian cancel with a guardian-chosen `recipient_` still pays the refund / returns the escrowed shares to `recipient_`. Unchanged (CANCEL-FEES owns). | `test_cancelDepositRequest_guardian`, `test_cancelRedeemRequest_guardian` | High (owned by CANCEL-FEES) |
| R2-9 (I-3) | `:169`, `:311` | `UNPAUSER_ROLE` declared, `unpause` still DEFAULT_ADMIN. Unchanged. | `test_unpause_unpauserRoleCannotUnpause` | Info |
| R2-10 (F-2) | `:329-338` | `take` ignores pending counters and is not paused. Unchanged. | `test_take_ignoresPendingDepositSavingsShares`, `test_take_whilePaused`, `test_pause_doesNotBlockTake` | Known |
| R2-11 | layout | Not compatible with round 1. Unchanged (see storage status below). | `test_storageLayout_notCompatibleWithRoundOne` | Info |

## New: `realizeGain` (`src/SparkPrimeVault.sol:297-309`)

`onlyRole(DEFAULT_ADMIN_ROLE)`, no pause requirement, `require(gain_ > 0, "invalid-gain")`, `drip()`, `require(totalSupply != 0, "no-shares")`, `chi = uint192((totalAssets() + gain_) * RAY / totalSupply)`, `GainRealized(chi, gain)`.

| Aspect | Result | Test |
|---|---|---|
| Matrix | admin OK; guardian, rebalancer, riskManager, setter, taker, unpauser, stranger revert `AccessControlUnauthorizedAccount(caller, DEFAULT_ADMIN_ROLE)`, paused and unpaused alike | `test_realizeGain_notAuthorized`, `test_realizeGain_authorized` |
| Pause scope | allowed unpaused and paused; `paused` flag untouched | `test_realizeGain`, `test_realizeGain_whilePaused`, `test_pause_doesNotBlockRealizeGain` |
| Event | `GainRealized(expectedChi, gain)` exact; preceded by `Drip(nowChi, diff)` when time has passed | `test_realizeGain`, `test_realizeGain_dripsFirst` |
| Formula | `chi == floor((totalAssets + gain) * RAY / totalSupply)`, `rho == now`; write-up in `[gain - 1, gain]`; repeated calls compound; gain then equal loss returns within 3 floors of the start | `test_realizeGain`, `test_realizeGain_repeatedAndRoundTripWithLoss`, `testFuzz_realizeGain_neverLowersChi` (1000 runs, chi strictly increases) |
| Validation | `realizeGain(0)` -> `invalid-gain`; empty vault -> `no-shares` (reachable here, no totalAssets check in front) | `test_realizeGain_zeroGain`, `test_realizeGain_noShares` |
| Admin bound | none. `realizeGain(1e30)` on 1,000 USDC of backing is accepted, chi moves to `~1e45`, `totalAssets() ~= 1e30` while the vault holds ~1,000 USDC of spUSDC. Larger values truncate the `uint192` cast or overflow the next `drip`: NEWSURFACE/ROUNDING own the thresholds. | `test_realizeGain_noUpperBound` |
| Revocation | nothing new: with no admin left, `realizeGain` is dead like `unpause`/upgrade/grantRole | `test_renounceDefaultAdmin_vaultHasNoAdminForever` |
| Trust note | `realizeGain` writes up the index without any backing moving in. With the fresh `realizeLoss` floor (`loss < totalAssets`) the admin can now raise and lower the index freely (gain is unbounded, loss is bounded by `totalAssets - 1`); the admin key is the cold key under the trust model so this is reported as data, not a finding. README lists it under DEFAULT_ADMIN. | |

## Authorization matrix (ff828d2)

Columns are the single role each actor holds. OK = succeeds; X = reverts `AccessControlUnauthorizedAccount(caller, <required role>)`.

| Function | required role | ADMIN | GUARDIAN | REBALANCER | RISK_MGR | SETTER | TAKER | UNPAUSER | stranger |
|---|---|---|---|---|---|---|---|---|---|
| setCapacity | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setMaxRedeemFee | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setMinDeposit | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setMinRedeem | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setVSRBounds | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| **realizeGain (new)** | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| unpause | DEFAULT_ADMIN | OK | X | X | X | X | X | **X** (I-3) | X |
| upgradeToAndCall | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| grantRole (all 7 roles) | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| revokeRole (all 7 roles) | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| renounceRole(role, self) | none | OK | OK | OK | OK | OK | OK | OK | OK (no-op); for another account: `AccessControlBadConfirmation()` |
| setVSR | SETTER | X | X | X | X | OK | X | X | X |
| take | TAKER | X | X | X | X | X | OK | X | X |
| processDepositQueue | REBALANCER | X | X | OK | X | X | X | X | X |
| processRedeemQueue | REBALANCER | X | X | OK | X | X | X | X | X |
| processCancelledDepositQueue | REBALANCER | X | X | OK | X | X | X | X | X |
| setRedeemFee | RISK_MANAGER | X | X | X | OK | X | X | X | X |
| realizeLoss (paused) | RISK_MANAGER | X | X | X | OK | X | X | X | X |
| pause | GUARDIAN | X | OK | X | X | X | X | X | X |
| cancelDepositRequest (not owner) | owner or GUARDIAN | `not-authorized` | OK (refund to guardian-chosen recipient on settlement) | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` |
| cancelRedeemRequest (not owner) | owner or GUARDIAN | `not-authorized` | OK (shares to guardian-chosen recipient) | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` |
| updateDepositRecipient, updateCancelledDepositRecipient, updateRedeemRecipient (not owner) | **owner only** (R2-7 fixed) | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized`; owner OK; dead entry `no-request`; zero recipient `invalid-recipient` (checked first) |
| requestDeposit (x2), requestRedeem, cancel own request, update own recipient, approve, transfer, transferFrom, permit, drip | none | OK | OK | OK | OK | OK | OK | OK | OK (`test_permissionless_stranger`, `test_updateRecipient_ownerOnly`) |

`getRoleAdmin(role) == DEFAULT_ADMIN_ROLE` for all 7 roles (`test_grantRole_authorized`).

## Pause scope (ff828d2)

| Function | While paused | Test |
|---|---|---|
| requestDeposit(assets, recipient) | blocked, `SparkPrimeVault/paused` | `test_pause_blocksRequestDeposit` |
| requestDeposit(assets, recipient, referral) | blocked | `test_pause_blocksRequestDepositWithReferral` |
| cancelDepositRequest (owner and guardian) | blocked | `test_pause_blocksCancelDepositRequest` |
| requestRedeem | blocked | `test_pause_blocksRequestRedeem` |
| cancelRedeemRequest (owner and guardian) | blocked | `test_pause_blocksCancelRedeemRequest` |
| processDepositQueue | blocked | `test_pause_blocksProcessDepositQueue` |
| processRedeemQueue | blocked | `test_pause_blocksProcessRedeemQueue` |
| processCancelledDepositQueue | blocked (queued refunds wait) | `test_pause_blocksProcessCancelledDepositQueue` |
| updateDepositRecipient / updateCancelledDepositRecipient / updateRedeemRecipient | allowed for the **owner** only; strangers `not-authorized` | `test_pause_doesNotBlockUpdateRecipient` |
| take | allowed | `test_pause_doesNotBlockTake` |
| drip | allowed, chi keeps accruing | `test_pause_doesNotBlockDrip` |
| setVSR | allowed | `test_pause_doesNotBlockSetVSR` |
| realizeLoss | allowed (requires paused) | `test_pause_doesNotBlockRealizeLoss` |
| **realizeGain (new)** | allowed (also allowed unpaused) | `test_pause_doesNotBlockRealizeGain`, `test_realizeGain_whilePaused`, `test_realizeGain` |
| approve / transfer / transferFrom | allowed | `test_pause_doesNotBlockERC20` |
| permit | allowed | `test_pause_doesNotBlockPermit` |
| setCapacity, setMaxRedeemFee, setMinDeposit, setMinRedeem, setVSRBounds, grantRole, revokeRole, setRedeemFee | allowed | `test_pause_doesNotBlockAdminSetters` |
| upgradeToAndCall | allowed, `paused` survives the upgrade | `test_pause_doesNotBlockUpgrade` |
| pause when paused / unpause when not paused | idempotent, event still emitted | `test_pause_idempotent`, `test_unpause_idempotent` |

## Storage layout status

`forge inspect SparkPrimeVault storage-layout` at ff828d2 is identical to the round-2 table below: 27 linear slots, `savings` (0) .. `allowance` (26), same packing (`asset`+`decimals` in slot 1, `rho`+`chi` in slot 4), same namespaced OZ slots. `realizeGain` and the `_requestDeposit` move add no state. `SparkPrimeVaultV2Mock.newVar` still lands at slot 27. `test_storageLayout_packing`, `test_upgradeToAndCall` (41 getter fields and 27 raw slots diffed), `test_upgradeToAndCall_withReinitializer`, `test_upgradeToAndCall_roundTrip` pass unchanged. The round-2 table was not edited.

## Unsettled

- Fork PoCs (`test/TestBase.t.sol`, `test/Review.t.sol`) compile under `forge build` and needed no change for ff828d2 (no `realizeLoss` / `update*Recipient` usage); still not executed (no RPC).
- R2-1 severity stays High under the trust model: the chi-to-zero brick is closed, the `totalAssets - 1` wipe-out by a single hot key is not. A drawdown floor (or an admin-only path like `realizeGain`) is still the open question.
- `realizeGain` thresholds (`uint192` truncation of the cast, `drip` overflow after a very large gain) are owned by NEWSURFACE/ROUNDING; only acceptance of `1e30` is asserted here.
- `upgradeToAndCall` with ETH value (`ERC1967NonPayable`) not tested; OZ behaviour.
- `transfer(address(vault), x)` permanently stuck (I-6) not re-tested here.

---

# ROLES worker report, round 2: authorization, admin bounds, pause scope, upgrade

Branch `campaign-v2/roles`, upstream `src/SparkPrimeVault.sol` = `refactor/more-simplifying` @ `0bc9288` (merged via `review/poc-tests-v2`, unpatched). Files: `test/Authorization.t.sol` (70 tests), `test/Admin.t.sol` (67), `test/Upgrade.t.sol` (12), `test/mocks/SparkPrimeVaultV2Mock.sol`, plus the fork harness `test/TestBase.t.sol` and `test/Review.t.sol` (ported to compile; not executed, no RPC in this environment).

Run: `forge test --match-path 'test/{Authorization,Admin,Upgrade}.t.sol' --skip test/Adversarial.t.sol --skip test/CancelAndFees.t.sol --skip test/DepositQueue.t.sol --skip test/RedeemQueue.t.sol --skip test/Rounding.t.sol --skip 'test/invariants/*' --skip test/QueueAudit.t.sol --skip test/LocalSmoke.t.sol --skip test/Review.t.sol`. Result: 149 passed, 0 failed. Fork files: `forge build` only.

Line numbers refer to `src/SparkPrimeVault.sol` @ `0bc9288`.

## (a) Findings

| # | Location | Scenario | Impact | Test | Severity |
|---|----------|----------|--------|------|----------|
| R2-1 (C-3) | `src/SparkPrimeVault.sol:351-360` (`realizeLoss`) | `chi = floor((totalAssets() - loss) * RAY / totalSupply)` with only `paused` and `loss > 0` checked. Guardian pauses; a compromised RISK_MANAGER calls `realizeLoss(totalAssets())`. | `chi == 0`, `nowChi() == 0` forever (`rpow * 0 == 0`, 10 years at MAX_VSR leave it at 0), `totalAssets() == 0`, `convertToShares` reverts by division by zero, `processRedeemQueue` can never run, new deposits queue and never mint (capacity converts to 0 assets). ~1,000,000 USDC of spUSDC stays in the vault, unowned, and only `take` can move it. `realizeLoss(totalAssets() - 1)` leaves holders 1 wei in total. No floor, no two-step, no admin involvement. | `test_realizeLoss_fullLossZeroesChiAndBricksVault`, `test_realizeLoss_totalAssetsMinusOneWipesHolders` | High (trust model; same as round 1, now with a permanent-brick outcome) |
| R2-2 | `src/SparkPrimeVault.sol:357` | `realizeLoss(loss > totalAssets())` and `realizeLoss` on an empty vault. | Revert by arithmetic underflow (panic 0x11) instead of a revert string; no funds at risk. `require(loss_ <= totalAssets())` would give a clean error and is also the natural place for a drawdown floor. | `test_realizeLoss_aboveTotalAssetsUnderflows`, `test_realizeLoss_zeroSupplyReverts` | Info |
| R2-3 (C-4) | `src/SparkPrimeVault.sol:55, 233-258` | The only DEFAULT_ADMIN calls `renounceRole`/`revokeRole` on itself; or `initialize(..., admin = address(0))`. | No `unpause`, no upgrade, no role changes, forever (proven while paused: paused for good). Zero admin at init: same dead state from block one, and no guardian can ever be appointed. Unchanged from round 1. | `test_renounceDefaultAdmin_vaultHasNoAdminForever`, `test_revokeDefaultAdmin_self_vaultHasNoAdminForever`, `test_initialize_zeroAdminNotGuarded` | Medium (operational) |
| R2-4 (C-7) | `src/SparkPrimeVault.sol:271-274` (`setMaxRedeemFee`), `284-290` (`setVSRBounds`) | Admin tightens a bound below the live value. | Live `redeemFee` / `vsr` stay in force until the hot role acts; admin cannot contain a compromised SETTER or RISK_MANAGER without first granting itself the role. Unchanged. | `test_setMaxRedeemFee_belowCurrentFeeLeavesFeeAboveMax`, `test_setVSRBounds_currentVsrOutsideNewBounds` | Low |
| R2-5 (C-8) | `src/SparkPrimeVault.sol:276-282` (`setMinDeposit`, `setMinRedeem`) | No validation. `setMinRedeem(uint256.max)` blocks every redeem request; `setMinDeposit(uint256.max)` every deposit; `minDeposit > maxCapacity` forces every deposit to queue behind an unreachable cap. `minRedeem` is now in shares and gross of the fee (queued amount can land below it). | Admin only, fat-finger risk; cancels and queue processing still work. | `test_setMinRedeem_noValidation_blocksAllRedeems`, `test_setMinDeposit_noValidation_blocksAllDeposits`, `test_setMinDeposit_aboveCapacity`, `test_setMinRedeem_grossOfFee` | Low |
| R2-6 | `src/SparkPrimeVault.sol:267-269` (`setCapacity`) | The `capacity_ <= uint128.max` bound was removed. `setCapacity(type(uint256).max)` is accepted. | Every `requestDeposit` then reverts by overflow in `convertToAssets(availableCapacity())` (panic 0x11) until the admin lowers the cap. NEWSURFACE owns the brick finding; the acceptance is asserted here. | `test_setCapacity_noUpperBound` | Low (admin only; reference NEWSURFACE) |
| R2-7 | `src/SparkPrimeVault.sol:423, 467, 534` (`updateDepositRecipient`, `updateCancelledDepositRecipient`, `updateRedeemRecipient`) | No authorization at all, not paused either. Any address rewrites the payout address of any queued deposit, queued refund or queued redeem; owners are untouched. | Theft of every queued payout on the next planner run. NEWSURFACE owns the finding; matrix row is "anyone" and the pause-scope row is "allowed". | `test_updateRecipient_anyone`, `test_pause_doesNotBlockUpdateRecipient`, `test_updateRecipient_zeroRecipient` | Critical (owned by NEWSURFACE) |
| R2-8 | `src/SparkPrimeVault.sol:430-465, 506-532` | Guardian cancel with a guardian-chosen `recipient_` is back (F-1 regression): deposit refund is paid to `recipient_` on `processCancelledDepositQueue`, escrowed redeem shares go to `recipient_` immediately. | CANCEL-FEES owns the finding; asserted here for the matrix and in the fork PoCs `test_F1_*`. | `test_cancelDepositRequest_guardian`, `test_cancelRedeemRequest_guardian` | High (owned by CANCEL-FEES) |
| R2-9 (I-3) | `src/SparkPrimeVault.sol:165, 292` | `UNPAUSER_ROLE` still declared and granted in the harness; `unpause` is still `onlyRole(DEFAULT_ADMIN_ROLE)`. | Every unpause needs the cold admin key. Delete the constant or gate `unpause` on it. | `test_unpause_unpauserRoleCannotUnpause` | Info |
| R2-10 (F-2) | `src/SparkPrimeVault.sol:311-320` (`take`), `741-775` | `take` ignores `pendingDepositSavingsShares` and `pendingCancelledDepositSavingsShares` and has no `whenNotPaused`. Round 2: the owner's cancel succeeds (entry moves queues), the settlement then pays nothing because `remaining_ = min(max, balanceOf)` is 0; the refund waits, no revert. | Known; the depositor is unpaid until the taker returns spUSDC. Documented, not re-reported. | `test_take_ignoresPendingDepositSavingsShares`, `test_take_whilePaused`, `test_pause_doesNotBlockTake`; fork `test_F2_*` | Known |
| R2-11 | storage layout (see table) | `asset` (slot 1), `pendingCancelledDepositSavingsShares` (16), `cancelledDepositQueue` (19), `cancelledDepositHead` (22) were inserted mid-layout; `decimals` moved from slot 0 to slot 1; `minWithdraw` became `minRedeem`. | Not upgrade-compatible with the round-1 layout: a round-1 implementation behind this proxy misreads every slot from 1 onwards. Nothing is deployed, so informational; relevant only if a round-1 build was ever deployed. | `test_storageLayout_notCompatibleWithRoundOne`, `test_storageLayout_packing` | Info |

No `test_BUG_` tests in this scope: every behaviour above is pinned by a passing test.

## (b) Tables

### Authorization matrix

Columns are the single role each actor holds. OK = succeeds; X = reverts `AccessControlUnauthorizedAccount(caller, <required role>)`. All cells are asserted by `test_<fn>_notAuthorized` / `test_<fn>_authorized` in `Authorization.t.sol`.

| Function | required role | ADMIN | GUARDIAN | REBALANCER | RISK_MGR | SETTER | TAKER | UNPAUSER | stranger |
|---|---|---|---|---|---|---|---|---|---|
| setCapacity | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setMaxRedeemFee | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setMinDeposit | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setMinRedeem | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setVSRBounds | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| unpause | DEFAULT_ADMIN | OK | X | X | X | X | X | **X** (I-3) | X |
| upgradeToAndCall | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| grantRole (all 7 roles) | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| revokeRole (all 7 roles) | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| renounceRole(role, self) | none | OK | OK | OK | OK | OK | OK | OK | OK (no-op); for another account: `AccessControlBadConfirmation()` |
| setVSR | SETTER | X | X | X | X | OK | X | X | X |
| take | TAKER | X | X | X | X | X | OK | X | X |
| processDepositQueue | REBALANCER | X | X | OK | X | X | X | X | X |
| processRedeemQueue | REBALANCER | X | X | OK | X | X | X | X | X |
| processCancelledDepositQueue (new) | REBALANCER | X | X | OK | X | X | X | X | X |
| setRedeemFee | RISK_MANAGER | X | X | X | OK | X | X | X | X |
| realizeLoss (paused) | RISK_MANAGER | X | X | X | OK | X | X | X | X |
| pause | GUARDIAN | X | OK | X | X | X | X | X | X |
| cancelDepositRequest (not owner) | owner or GUARDIAN | `not-authorized` | OK (refund to guardian-chosen recipient on settlement) | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` |
| cancelRedeemRequest (not owner) | owner or GUARDIAN | `not-authorized` | OK (shares to guardian-chosen recipient) | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` |
| updateDepositRecipient, updateCancelledDepositRecipient, updateRedeemRecipient (new) | **anyone** (R2-7, NEWSURFACE) | OK | OK | OK | OK | OK | OK | OK | OK |
| requestDeposit (x2), requestRedeem, cancel own request, approve, transfer, transferFrom, permit, drip | none | OK | OK | OK | OK | OK | OK | OK | OK (`test_permissionless_stranger`) |

`getRoleAdmin(role) == DEFAULT_ADMIN_ROLE` for all 7 roles (`test_grantRole_authorized`). `pause` was DEFAULT_ADMIN on the intermediate `refactor/more-simplifying` head and is GUARDIAN again as of `0bc9288`; the matrix reflects `0bc9288`.

### Pause scope

| Function | While paused | Test |
|---|---|---|
| requestDeposit(assets, recipient) | blocked, `SparkPrimeVault/paused` | `test_pause_blocksRequestDeposit` |
| requestDeposit(assets, recipient, referral) | blocked | `test_pause_blocksRequestDepositWithReferral` |
| cancelDepositRequest (owner and guardian) | blocked | `test_pause_blocksCancelDepositRequest` |
| requestRedeem | blocked | `test_pause_blocksRequestRedeem` |
| cancelRedeemRequest (owner and guardian) | blocked | `test_pause_blocksCancelRedeemRequest` |
| processDepositQueue | blocked | `test_pause_blocksProcessDepositQueue` |
| processRedeemQueue | blocked | `test_pause_blocksProcessRedeemQueue` |
| processCancelledDepositQueue | blocked (queued refunds wait) | `test_pause_blocksProcessCancelledDepositQueue` |
| updateDepositRecipient / updateCancelledDepositRecipient / updateRedeemRecipient | **allowed** (payout addresses can be rewritten mid-incident) | `test_pause_doesNotBlockUpdateRecipient` |
| take | allowed | `test_pause_doesNotBlockTake` |
| drip | allowed, chi keeps accruing | `test_pause_doesNotBlockDrip` |
| setVSR | allowed | `test_pause_doesNotBlockSetVSR` |
| realizeLoss | allowed (requires paused) | `test_pause_doesNotBlockRealizeLoss` |
| approve / transfer / transferFrom | allowed | `test_pause_doesNotBlockERC20` |
| permit | allowed | `test_pause_doesNotBlockPermit` |
| setCapacity, setMaxRedeemFee, setMinDeposit, setMinRedeem, setVSRBounds, grantRole, revokeRole, setRedeemFee | allowed | `test_pause_doesNotBlockAdminSetters` |
| upgradeToAndCall | allowed, `paused` survives the upgrade | `test_pause_doesNotBlockUpgrade` |
| pause when paused / unpause when not paused | idempotent, event still emitted | `test_pause_idempotent`, `test_unpause_idempotent` |

### Storage layout (`forge inspect SparkPrimeVault storage-layout`, solc 0.8.34, `0bc9288`; re-run after the merge, unchanged by it)

| Slot | Offset | Bytes | Name | Type | vs round 1 |
|---|---|---|---|---|---|
| 0 | 0 | 20 | savings | address | `decimals` no longer packed here |
| 1 | 0 | 20 | asset | address | new |
| 1 | 20 | 1 | decimals | uint8 | moved from slot 0 |
| 2 | 0 | 32 | name | string | was 1 |
| 3 | 0 | 32 | symbol | string | was 2 |
| 4 | 0 | 8 | rho | uint64 | was 3 |
| 4 | 8 | 24 | chi | uint192 | was 3 |
| 5 | 0 | 32 | vsr | uint256 | was 4 |
| 6 | 0 | 32 | minVSR | uint256 | was 5 |
| 7 | 0 | 32 | maxVSR | uint256 | was 6 |
| 8 | 0 | 1 | paused | bool (alone, 31 bytes free) | was 7 |
| 9 | 0 | 32 | maxCapacity | uint256 | was 8 |
| 10 | 0 | 32 | minDeposit | uint256 | was 9 |
| 11 | 0 | 32 | minRedeem | uint256 [shares] | was `minWithdraw` at 10 |
| 12 | 0 | 32 | redeemFee | uint256 | was 11 |
| 13 | 0 | 32 | maxRedeemFee | uint256 | was 12 |
| 14 | 0 | 32 | totalSupply | uint256 | was 13 |
| 15 | 0 | 32 | pendingDepositSavingsShares | uint256 | was 14 |
| 16 | 0 | 32 | pendingCancelledDepositSavingsShares | uint256 | new |
| 17 | 0 | 32 | pendingRedeemShares | uint256 | was 15 |
| 18 | 0 | 32 | depositQueue | Request[] | was 16 |
| 19 | 0 | 32 | cancelledDepositQueue | Request[] | new |
| 20 | 0 | 32 | redeemQueue | Request[] | was 17 |
| 21 | 0 | 32 | depositHead | uint256 | was 18 |
| 22 | 0 | 32 | cancelledDepositHead | uint256 | new |
| 23 | 0 | 32 | redeemHead | uint256 | was 19 |
| 24 | 0 | 32 | balanceOf | mapping(address => uint256) | was 20 |
| 25 | 0 | 32 | nonces | mapping(address => uint256) | was 21 |
| 26 | 0 | 32 | allowance | mapping(address => mapping(address => uint256)) | was 22 |
| 27 | 0 | 32 | (next free slot; `SparkPrimeVaultV2Mock.newVar` lands here) | | was 23 |

Namespaced OZ storage (ERC-7201, not in the linear layout): Initializable `0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00`, AccessControl `0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800`, AccessControlEnumerable `0xc1f6fe24621ce81ec5827caf0253cadb74709b061630e6b55e82371705932000`; implementation at ERC-1967 `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`. Packing and every value slot 0..26 (including the three mapping bases via computed keys) are verified on-chain by `test_storageLayout_packing`. `SparkPrimeVaultV2Mock` inherits the new contract (layout identical by construction) and appends `newVar` at slot 27. `test_upgradeToAndCall` diffs all 27 raw slots and 41 getter fields before/after the upgrade and asserts slot 27 is empty; `test_upgradeToAndCall_withReinitializer` asserts slot 27 == 777 and the Initializable slot == 2.

## (c) Properties that held

- Every role-gated function reverts with the exact OZ custom error for all 7 other actors and a stranger (matrix above), including the new `processCancelledDepositQueue` and `realizeLoss`.
- SETTER is bounded by admin bounds: `vsr-too-low` / `vsr-too-high` at `minVSR - 1` / `maxVSR + 1`; with bounds `[RAY, RAY]` the rate cannot move (`test_setVSR_*Boundary`, `test_setVSR_lockedWhenBoundsEqual`).
- RISK_MANAGER is bounded by `maxRedeemFee`: `fee-too-high` at `max + 1`; `maxRedeemFee = 0` locks the fee at 0 (`test_setRedeemFee_tooHighBoundary`, `test_setRedeemFee_zeroMaxLocksFee`).
- `realizeLoss`: `not-paused` when unpaused, `invalid-loss` at 0; exact `chi = floor((totalAssets - loss) * RAY / totalSupply)` and `LossRealized(chi, loss)`; drips first (loss is taken from the dripped value, `rho = now`); repeated calls compound; the write-down is in `[loss, loss + 1]` wei; chi strictly decreases for every accepted loss (fuzz, 1000 runs); the `uint192` cast cannot truncate since the result is at most the previous chi (`test_realizeLoss*`, `testFuzz_realizeLoss_neverRaisesChi`).
- Admin bounds: `fee-too-high` at `0.01e18 + 1`, `vsr-too-low` at `RAY - 1`, `vsr-too-high` at `MAX_VSR + 1`, `min-vsr-gt-max-vsr`; `setCapacity` has no bound (R2-6) (`test_setMaxRedeemFee_tooHighBoundary`, `test_setVSRBounds_*Boundary`, `test_setCapacity_noUpperBound`).
- `minDeposit` checked on assets, `minRedeem` on gross shares with exact boundaries (`test_setMinimums_boundaries`).
- `setVSR` drips at the old rate before switching; `Drip(nChi, diff)` then `VSRSet(vsr)` (`test_setVSR`, `test_setVSR_dripsAtOldRate`).
- Every setter emits its exact event: `CapacitySet(capacity)`, `MaxRedeemFeeSet`, `MinDepositSet`, `MinRedeemSet`, `VSRBoundsSet`, `VSRSet`, `RedeemFeeSet`, `LossRealized`, `Paused`, `Unpaused`, `Take`, `RoleGranted`, `RoleRevoked`, `Upgraded`.
- `take`: bounded by spUSDC balance with `insufficient-shares` at `balance + 1`; `take(0)` emits `Take(taker, 0)`; `totalAssets()` unchanged by take (`test_take*`).
- Cancels: `cancelDepositRequest` returns the cancel id, zeroes the deposit entry, moves the shares between the two pending counters, pays nothing until `processCancelledDepositQueue`; owner refund is `100e6 - 1` (spUSDC redeem rounds down) (`test_cancelDepositRequest_owner`).
- Revocation mid-flight: revoked REBALANCER freezes all three queues (entries intact, refund unpaid) until a new one is granted, who then drains all three (`test_revokeRebalancer_queuesFrozenUntilNewRebalancer`); revoked TAKER can still return spUSDC by plain transfer and redeems resume (`test_revokeTaker_afterTake_returnStillWorks`); revoked GUARDIAN loses pause and the compliance cancels while the admin can still unpause (`test_revokeGuardian_whilePaused_adminCanStillUnpause`).
- Upgrade: admin only; `UUPSUnsupportedProxiableUUID`, `ERC1967InvalidImplementation`, `UUPSUnauthorizedCallContext` exact; 41 getter fields (incl. all three queues, heads, pending counters, `asset`, `minRedeem`) and all 27 raw slots identical before/after; roles identical; `initialize` reverts `InvalidInitialization()` before and after; implementation contracts have `_initialized == uint64.max`; `reinitializer(2)` path works once; round trip V1 -> V2 -> V1 preserves state; all three queues process normally after the upgrade and bob's cancelled deposit settles at `20_000e6 ± 2` (`Upgrade.t.sol`).
- Initialization: `asset` read from `savings.asset()`, decimals 6 from the asset, `chi = vsr = minVSR = maxVSR = RAY`, `rho = now`, capacity/fee/max fee/minimums/pending counters/heads 0, USDC allowance to spUSDC `uint256.max`, admin is the only DEFAULT_ADMIN member, Initializable slot `1`. Fresh defaults lock SETTER and RISK_MANAGER until admin widens them (`test_initialize`, `test_initialize_defaultsAreSafe`).
- ERC20/permit unchanged from round 1 and all re-asserted, plus `asset()` in metadata (`Admin.t.sol`).

## (d) Unsettled

- Fork PoCs (`test/TestBase.t.sol`, `test/Review.t.sol`) were ported to the new API (`setChi` gone, cancel returns an id and settles via `processCancelledDepositQueue`, F-1 asserts the vulnerable guardian-recipient behaviour, F-2 asserts "cancel succeeds, settlement starves", F-3 asserts the fixed loop) and compile under `forge build`, but were **not executed**: no mainnet RPC in this environment. The `test_F2_processRedeemQueuePaysRedeemersWithQueuedDepositBacking` partial-settlement arithmetic (`left == bobShares - held`) assumes mainnet spUSDC has USDC liquidity for the redeem at block 26148600; if not, that single assertion needs an `assertGe`.
- Whether R2-1 is High or accepted depends on whether RISK_MANAGER is a cold key in production; the chi-to-zero brick is new and argues for at least `require(loss_ < totalAssets())` plus a drawdown floor.
- Pause scope for `update*Recipient` (allowed while paused) is reported here as data; the remedy belongs with NEWSURFACE's authorization fix.
- `upgradeToAndCall` with ETH value (`ERC1967NonPayable`) not tested; OZ behaviour.
- `transfer(address(vault), x)` permanently stuck (I-6) not re-tested here.
