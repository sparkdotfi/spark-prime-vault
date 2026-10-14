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
