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
