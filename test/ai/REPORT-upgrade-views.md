# UPGRADE-VIEWS worker report

## Round 6 (`master` @ `c512609`)

Branch `campaign-v6/upgrade-views`. Files: `test/ai/Upgrade.t.sol` (19 tests), `test/ai/Views.t.sol`
(38), `test/ai/Headline.t.sol` (16), `test/ai/LocalSmoke.t.sol` (2), `test/ai/mocks/SparkPrimeVaultV2Mock.sol`,
plus the fork-only `test/ai/TestBase.t.sol` and `test/ai/Review.t.sol` (10 PoCs, compile only: no RPC here).

Run: `FOUNDRY_OFFLINE=true forge test --match-path 'test/ai/{Upgrade,Views,Headline,LocalSmoke}.t.sol'`.
Result: 75 passed, 0 failed (also at `FOUNDRY_FUZZ_RUNS=2000`). `forge build` with the fork files: 0
errors. Line numbers refer to `src/SparkPrimeVault.sol` @ `c512609`. No test fails deliberately; every
`test_BUG_` asserts the open behaviour exactly, every `test_fixed_` asserts the fix exactly.

### (a) New findings

| # | Location | Scenario (exact) | Impact | Severity | Test |
|---|---|---|---|---|---|
| UV6-1 | `:707`, `:755`, `:802` | Range getters check `length_ <= array.length - startId_` after `startId_ >= head`; with `startId_ > array.length` the subtraction underflows, so `getPendingDepositRequests(length + 1, 0)` and `(type(uint256).max, *)` revert with panic 0x11 instead of `LengthTooLarge`. `startId_ == length` with `length_ == 0` is a legal empty read. | Integrators get a panic instead of the documented custom error for an out-of-range start. | Info | `test_getPendingDepositRequests_range_failure`, `test_getPendingDepositCancellationRequests_range`, `test_getPendingRedeemRequests_range`, the three `testFuzz_getPending*Requests_range` |
| UV6-2 | `:942-976` (`:953`) | H4 follow-up: the (11, 11, rest) batch from one 1M holder now pays in ONE call (no revert), alice receives 999_999_999_996 (same as the old three single calls), but entry 2 keeps 2 shares at the head backed by 1 spUSDC share: `availableLiquidAssets() == 1`, `convertToShares(1) == 0`, so every later call breaks at `fillable_ == 0` until spUSDC arrives from outside; 10 spUSDC shares from outside clear it (2 wei paid). A single whole-balance entry has no dust (999_999_999_998 paid, 0 spUSDC left). | R5-10 unchanged: the per-entry bound removes the revert, not the dust; one unpayable entry at the head blocks the queue behind it. | Low | `test_fixed_H4_batchedRedeems_payInOneCall`, `test_BUG_H4_dustAtHeadUnpayableUntilTopUp`, `testFuzz_fixed_H4_anySplitPaysInOneCall` (any split into <= 8 entries: no revert, at most the last entry keeps <= 2n shares) |
| UV6-3 | `:445`, `:872-879` | H6 follow-up: `requestDepositCancellation` self-skips only the run of zero entries AT the head. With a live entry at the head (alice 1M queued at capacity 0), 300 `minDeposit`-sized (1e6) request-then-cancel loops by `mal` leave `getPendingDepositRequests().length == 301`, the operator's `processPendingDeposits(max, max)` at capacity 0 breaks at alice (`:878`), and after the operator fills only the live head (`maxRequests == 1`) the 300 ghosts are at the head: bob's next `requestDeposit` instant-fill walks all of them: 990_016 gas vs 287_560 clean (~2.3k per ghost). `mal` gets 300e6 - 300 back from the cancellation queue (1 wei of spUSDC floor per loop), so the capital cost is zero. Without a live head the self-skip works: 50 loops leave an empty window, head 50. | Bounded griefing of the first walk with capacity; operator can bound it with `maxRequests`; the next depositor cannot. | Low | `test_BUG_H6_ghostsBehindLiveHead_taxFirstWalkWithCapacity`, `test_fixed_H6_cancelAtHeadSelfSkips_zeroDepositRejected`, `test_getPendingDepositRequests_cancelledBehindLiveHeadStaysVisible` |
| UV6-4 | `:1001`, `:1011` | H5 follow-up: `requestRedeem(shares, address(spUsdc))` is accepted; the fill is `spUSDC.withdraw(assets, spUSDC, vault)`, a USDC transfer from spUSDC to itself that succeeds, so the try branch returns and nothing is credited: 999_999_999_998 USDC stay in spUSDC with 954_532_691_143 spUSDC shares burned (`usdc.balanceOf(spUSDC) > spUSDC.totalAssets()` afterwards), `claimableAssets[spUSDC] == 0`, `totalClaimable == 0`, `claim(spUSDC)` reverts `NothingToClaim`. | User-triggered donation to spUSDC holders; same shape as V2-13 for the vault, now only reachable with `savings` as recipient. | Low | `test_BUG_H5_spUsdcRecipient_donatesPayout` |
| UV6-5 | `:196` | `initialize(..., admin = address(0), ...)` is accepted: `getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1` with member `address(0)`, nobody can grant a role. Last-admin `renounceRole` leaves a vault where no actor can grant/revoke, upgrade, or touch `setMinDeposit`/`setVSRBounds`; the existing roles keep working and losing any one of them is permanent. The old "stuck paused" consequence is gone (separate `UNPAUSER_ROLE`). | Operational; R5-6 / V2-8 unchanged. | Low | `test_BUG_H7_zeroAdminAcceptedAtInitialize`, `test_BUG_H7_lastAdminRenounces_noRoleOrUpgradeEverAgain` |
| UV6-6 (info) | `ISparkPrimeVault.sol` | The interface extends `IERC20Metadata`, `IERC20Permit`, `IAccessControlEnumerable`; every function of those is callable through it with the vault's semantics. Not on the interface but on the ABI: `DEFAULT_ADMIN_ROLE()`, `getRoleMembers()`, `supportsInterface()` (OZ parents). `supportsInterface` answers true for ERC165, IAccessControl and IAccessControlEnumerable (`0x5a05180f`). | None. | Info | `test_interface_erc20Surface`, `test_interface_accessControlSurface` |

### (b) Status of prior findings touched

| Finding | Status at c512609 | Pinning test |
|---|---|---|
| R5-1 / G-1 chi brick (`:280` uint192 check vs `:655`/`:846` `_rpow * chi` in uint256) | **Open**, unchanged. Exact bound `type(uint256).max / RAY`; chi at bound+1 panics from the next second in every dripping path; undo only in the same block (costs 2 wei); `lossManager` is now the trigger. | `test_BUG_adjustTotalAssets_chiAboveRpowBoundBricksVault`, `test_BUG_adjustTotalAssets_chiBrickRecoverableOnlyInSameBlock`, `test_BUG_nowChi_exactRpowOverflowThreshold`, `test_BUG_H1_*` |
| R5-2 pause sandwich | **Open**: +24_999.999998 at 0 fee, +14_749.999997 at 1% fee for one block of risk | `test_BUG_H2_*`, `test_H2_pauseBeforeDeposit_killsSandwich` |
| R5-3 / C-3 no loss floor | **Open, re-rated**: `LOSS_MANAGER_ROLE` is a separate non-admin role, needs only the pauser; admin cannot adjust; `-(totalAssets - 1)` accepted, chi -> 1_009_687_768_243_692, alice -> 0 | `test_BUG_H3_lossOfTotalAssetsMinusOne_wipesHolders`, `test_BUG_H3_lossManagerIsNotAdmin` |
| C-1 / R5-4 / H4 batched redeem revert | **Fixed** (per-entry bound) | `test_fixed_H4_batchedRedeems_payInOneCall`, `testFuzz_fixed_H4_anySplitPaysInOneCall` |
| R5-10 dust at the redeem head | **Open**, exact dust measured (UV6-2) | `test_BUG_H4_dustAtHeadUnpayableUntilTopUp` |
| V2-13 / R5-7 / H5 vault as recipient | **Fixed** for the vault: `VaultIsRecipient` in `requestDeposit`, `requestRedeem`, `requestDepositCancellation`, all three updaters. spUSDC as recipient **open** (UV6-4) | `test_fixed_H5_vaultRejectedAsRecipientEverywhere`, `test_BUG_H5_spUsdcRecipient_donatesPayout` |
| R5-9 / F-5 / H6 ghosts | **Partly fixed**: zero-asset deposits impossible (`BelowMinDeposit`, `ZeroMinDeposit` in the setter), self-skip at the head works; ghosts behind a live head **open** (UV6-3). Redeem ghosts (R5-14) still reachable when the admin sets `minRedeem < WAD / fee` (fork PoC) | `test_fixed_H6_*`, `test_BUG_H6_*`, `test_fixed_F5_zeroDepositRequestRejected`, `test_BUG_F5_tinyRedeemRequestsBecomeGhostEntries` (fork), `test_getPendingRedeemRequest_bounds` (local, `minRedeem` 1) |
| R5-6 / V2-8 admin renounce / zero admin | **Open** (UV6-5) | `test_BUG_H7_*` |
| R5-8 / V2-7 `setCapacity` unbounded | **Open**, unchanged (`totalSupply + uint256.max / nowChi` fine, +1 panics; operator recovers) | `test_BUG_availableCapacity_overflowInConvertToAssets` |
| R4-A / R4-B blacklist fallback | **Fixed by try/catch** as seen from these suites: redeem and cancellation payouts to blacklisted recipients credit `claimableAssets` + `totalClaimable` (40_387_510 and 49_999_999 exact), survive V1 -> V2 -> V1, `claim` pays after un-blacklisting and reverts "Blacklistable" while blacklisted without decrementing | `test_totalClaimable_tracksClaimableAssets`, `test_upgradeToAndCall`, `test_totalAssets_isNotionalOnly` |
| F-1, F-3 (fork) | **Fixed** (owner-only cancel with chosen recipient, `maxRequests` honoured) | `test_fixed_F1_privilegedRolesCannotCancelDeposit`, `test_fixed_F1_cancelRedeemRequestRemoved`, `test_fixed_F3_processPendingDepositsFillsAllRequestsInOneCall` |
| F-2, F-4 (fork) | **Open** (compile only) | `test_BUG_F2_*`, `test_BUG_F4_dustFillMintsZeroShares` |
| Round-5 layout (`decimals|rho` at 7, `chi` at 8, `allowance` at 27) | **Changed**: not compatible (nothing deployed) | `test_storageLayout_notCompatibleWithRoundFive` |
| `GUARDIAN_ROLE`, `REBALANCER_ROLE`, `VSR_SETTER_ROLE` | **Gone** from the ABI; seven live roles | `test_roleAdmins_unchangedByUpgrade` |

### (c) Code paths and the test covering each

Storage layout (every assertion against `forge inspect SparkPrimeVault storage-layout` at c512609, both
directions: `vm.load` vs getters and `vm.store` then getters):

| Slot | Variable | Pinned by |
|---|---|---|
| 0 / 1 / 2 | the three `Request[]` lengths; element `i` at `keccak256(slot) + 3i + {0 owner, 1 recipient, 2 shares}` | `test_storageLayout_readEverySlot`, `test_storageLayout_storeEverySlot`, `test_upgradeToAndCall_v2ReadsEveryQueueSlot` |
| 3 | `savings` | same |
| 4 | `asset` (0) + `paused` (20) + `decimals` (21) | same (`vm.store` of `18 << 168 | 1 << 160 | asset` reads back as `decimals 18`, `paused`) |
| 5 / 6 | `name` / `symbol` inline short strings (`len*2` low byte: 32, 14) | same |
| 7 | `rho` (0, uint64) + `chi` (8, uint192) packed | same (`vm.store` of `2e27 << 64 | 1234` reads back `rho 1234`, `chi 2e27`) |
| 8..10 | `vsr`, `minVSR`, `maxVSR` | same |
| 11..16 | `maxCapacity`, `minDeposit`, `minDepositCancellation`, `minRedeem`, `redeemFeeRate`, `maxRedeemFeeRate` | same |
| 17 / 18 | `totalSupply` / `totalClaimable` | same |
| 19..21 | the three pending counters | same |
| 22..24 | the three heads | same |
| 25..28 | `balanceOf`, `nonces`, `claimableAssets`, `allowance` | same |
| 29 | first free slot (V2 mock `newVar`) | `test_upgradeToAndCall_withReinitializer`, `test_upgradeToAndCall` (empty after a plain upgrade) |
| ERC-7201 | `openzeppelin.storage.{Initializable, AccessControl, AccessControlEnumerable}` roots equal the derived constants, hold `_initialized == 1`, `hasRole`, `adminRole == 0`, enumerable `_values`/`_positions` for all seven roles; clobbering slots 0..29 leaves every role intact | `test_storageLayout_erc7201Namespaces` |

Upgrade: authorization (`DEFAULT_ADMIN_ROLE` only, seven other actors rejected with
`AccessControlUnauthorizedAccount`), works while paused, rejected on the implementation, wrong UUID,
non-UUPS target, ETH without data, ETH with non-payable initializer (rolled back), re-running
`initialize` through upgrade calldata (rolled back), implementation `_initialized == uint64.max` with
empty storage and no roles, proxy re-init rejected before and after upgrade, `reinitializer(2)` once,
60-field snapshot (every getter incl. `totalClaimable`, `minDepositCancellation`, the three head-to-end
views and raw hashes of every array element incl. ids below the head) + all 29 raw slots + all seven
role member lists byte-identical across V1 -> V2 -> V1, all three queues process and `claim` pays
afterwards (`totalClaimable` -> 0). Tests: `test_upgradeToAndCall*` (10), `test_initialize_*` (2),
`test_roleAdmins_unchangedByUpgrade`, `test_storageLayout_*` (4).

Views (`Views.t.sol`):
- `getPending{Deposit,DepositCancellation,Redeem}Request` (`:669`, `:716`, `:764`): below head, at
  length, max id, in window, cancelled-in-window zeros, partial fill, partial cancel: `test_getPending*Request_bounds` (3).
- `getPending*Requests()` (`:685`, `:733`, `:780`): empty, filled-excluded, cancelled-behind-head,
  partial fill, head agreement with counters for any cancel mask: `test_getPendingRequests_emptyQueues`,
  `test_getPendingDepositRequests_excludesFilledAndStartsAtHead`, `test_getPendingDepositRequests_cancelledBehindLiveHeadStaysVisible`,
  `test_getPendingDepositCancellationRequests_tracksCancelAndSettle`, `test_getPendingRedeemRequests_partialFillKeepsHeadEntry`,
  `testFuzz_getPendingRequests_matchHeadAndCounters`.
- `getPending*Requests(startId, length)` (`:700`, `:748`, `:795`): `StartIdTooSmall`, `LengthTooLarge`,
  length 0 at any legal start incl. `start == length`, exact window, slices equal the full view and the
  single getter, underflow panic past the end (UV6-1): `test_getPendingDepositRequests_range_{failure,success}`,
  `test_getPendingDepositCancellationRequests_range`, `test_getPendingRedeemRequests_range`,
  `testFuzz_getPending{Deposit,Redeem,DepositCancellation}Requests_range` (n <= 10, k filled, any start/length).
- Deleted head entries zero in raw storage, unreachable by every getter: `test_getPendingRequests_deletedHeadEntriesUnreachable`.
- `assetsOf` (`:815`), `availableCapacity` both branches (`:820`), `availableLiquidAssets` (`:824`: spUSDC
  liquidity bound, vault spUSDC bound, parked USDC excluded), `totalAssets` (`:850`), `totalClaimable`
  (credit by redeem and cancellation fallback, accumulation, `claim` decrement, `NothingToClaim`,
  blacklisted claim reverts without decrement): `test_assetsOf`, `test_availableCapacity`,
  `test_availableLiquidAssets_isSpUsdcMaxWithdraw`, `test_totalAssets_isNotionalOnly`, `test_totalClaimable_tracksClaimableAssets`.
- `convertToAssets` / `convertToShares` (`:827`, `:831`): monotone, round-trip bounds over 10 years at
  40%, exact at chi 1.5e27: `testFuzz_convertToAssets_monotonic`, `testFuzz_convert_roundTripBounds`, `test_convert_exactAtKnownChi`.
- `nowChi` both branches (`:843`), `drip` early return and update + `Drip` event (`:648`): `test_nowChi_matchesDrip`,
  `test_nowChi_rhoInFuture`, `test_drip_event`, `test_nowChi_uint192CastCannotTruncate`.
- `DOMAIN_SEPARATOR` (`:835`, live chain id), `implementation` (`:839`): `test_DOMAIN_SEPARATOR`, `test_implementation`.
- ERC20 metadata, constants, `version`: `test_erc20Metadata`.
- `ISparkPrimeVault` surface: IERC20 (6), IERC20Metadata (3), IERC20Permit (both `permit` overloads,
  `nonces`, `DOMAIN_SEPARATOR`, expired / invalid-owner / replay), IAccessControl (5) +
  IAccessControlEnumerable (2) + `getRoleMembers` + `supportsInterface`: `test_interface_erc20Surface`,
  `test_interface_accessControlSurface`.

Headline (`Headline.t.sol`): H1 (2), H2 (3), H3 (2), H4 (3), H5 (2), H6 (2), H7 (2), listed in (a)/(b).

### (d) Properties that held

- Every getter reads the slot `forge inspect` names, at the named offset, and every slot written with
  `vm.store` is read back by exactly one getter; the first free slot is 29.
- Upgrade preserves all 29 linear slots, every array element (including filled / cancelled ids below
  the heads), all seven role sets and all 60 snapshot fields; a V1 -> V2 -> V1 round trip is byte-identical.
- Range getters are pure slices: for every legal `(startId, length)` the result equals the matching
  slice of the head-to-end view and the single-entry getter, for all three queues (fuzzed).
- `totalClaimable == sum(claimableAssets) == USDC held for claimants` across redeem and cancellation
  fallbacks, accumulation and claims.
- The `(11, 11, rest)` and any <= 8-way split of a 1M redeem pay in one call without reverting.
- `availableCapacity` is share-denominated (a loss leaves it unchanged; burning escrowed redeem
  shares frees it); `availableLiquidAssets` ignores USDC parked for claims.
- `DOMAIN_SEPARATOR` follows the live chain id; `name` has no setter.

### (e) Not settled

- `Review.t.sol` / `TestBase.t.sol` are mainnet-fork tests, compiled only; F-2 / F-4 / F-5(redeem)
  PoCs should be run with `MAINNET_RPC_URL` set before the audit.
- UV6-3: whether the operator will always fill a live head with `maxRequests` large enough to walk the
  ghosts behind it (so the tax lands on the operator, not the next depositor) is operational.
- UV6-4: spUSDC as recipient is "accepted and donates"; whether the product wants `savings` rejected
  like the vault is a design call.

### Porting notes (round 5 -> round 6)

- `Upgrade.t.sol`: slot constants rewritten (`decimals` into 4, `rho|chi` into 7, `minDepositCancellation`
  13, `totalClaimable` 18, mappings 25..28, `V1_SLOTS = 29`); seven roles; `initialize` 7 args; snapshot
  gains `totalClaimable` and `minDepositCancellation`; the "all ids" range hashes (now illegal below the
  head) became raw-storage hashes of every array element; round-four incompatibility test rewritten
  against the round-five layout.
- `Views.t.sol`: `invalid-range` tests rewritten for `(startId, length)` with `StartIdTooSmall` /
  `LengthTooLarge`; the "ghosts at capacity 0 stay in view" test is now split into the self-skip
  (head) case and the behind-live-head case; range reads of deleted entries below the head (now
  illegal) replaced by `vm.load`; `chi` writes go through `_storeChi` (slot 7, offset 8); three range
  fuzzers, `totalClaimable`, ERC20 metadata and the interface-surface tests are new.
- `Headline.t.sol`: H4, H5 -> `test_fixed_` (+ `test_BUG_H4_dust`, `test_BUG_H5_spUsdc`); H6 rewritten
  around `minDeposit`-sized cancels; H7 "stuck paused" no longer applies (UNPAUSER_ROLE), rewritten as
  "no role or upgrade ever again" + zero-admin init; `adjustTotalAssets` by `lossManager`.
- `Review.t.sol`: `test_BUG_F5_zeroDepositRequestsBloatQueue` -> `test_fixed_F5_zeroDepositRequestRejected`;
  tiny-redeem ghosts need `setMinRedeem(1)` now; `setCapacity` by the operator; 3-arg cancels.
- `TestBase.t.sol`: duplicate `operator` removed, `lossManager` / `unpauser` added, 7-arg `initialize`,
  helpers use `(id, 1)`.
- `SparkPrimeVaultV2Mock`: `newVar` at slot 29.


## Round 5 (`master` @ `0ebb452`)

Branch `campaign-v5/upgrade-views`. Files: `test/ai/Upgrade.t.sol` (19 tests), `test/ai/Views.t.sol`
(27), `test/ai/LocalSmoke.t.sol` (2), `test/ai/mocks/SparkPrimeVaultV2Mock.sol`, plus the fork-only
`test/ai/TestBase.t.sol` and `test/ai/Review.t.sol` (10 PoCs, compile only: no RPC here).

Run: `FOUNDRY_OFFLINE=true forge test --match-path 'test/ai/{Upgrade,Views,LocalSmoke}.t.sol'`.
Result: 48 passed, 0 failed. `forge build` (fork files included): 0 errors. Line numbers below refer
to `src/SparkPrimeVault.sol` @ `0ebb452`. No test is a deliberately failing proof; every `test_BUG_`
asserts the bad behaviour exactly as it is.

### (a) Bugs and suspicious behaviour

| # | Location | Scenario (exact) | Impact | Test | Severity |
|---|---|---|---|---|---|
| UV5-1 (= G-1/G-2, still open) | `:292` bound vs `:637`, `:811` | `adjustTotalAssets` accepts any `chi <= type(uint192).max` (~6.28e57) but `drip`/`nowChi` compute `_rpow(vsr, dt) * chi` in uint256. With `vsr == RAY` the product is exactly `RAY * chi`, so the real ceiling is `type(uint256).max / 1e27 = 115792089237316195423570985008687907853269984665640564039457` (~1.158e50). Harness: alice deposits 1,000,000 USDC (`totalSupply = 990_405_184_109`); while paused the admin passes `delta = +114681085459449903921528244645760029` (~1.147e29 USDC) and chi lands at bound+1. Same block: every read still works. One second later `nowChi`, `drip`, `totalAssets`, `convertToAssets/Shares`, `assetsOf`, `requestDeposit`, `requestRedeem`, all three `processPending*`, `setVSR` and `adjustTotalAssets` itself revert with panic 0x11. `transfer`, `take`, `claim`, pause/roles/upgrade still work. | Permanent brick of every value-bearing path, recoverable only by an upgrade that rewrites slot 8 (or a second `adjustTotalAssets` in the same block). Admin-only trigger, but the `uint192` check at `:292` gives a false sense of safety by a factor ~5.4e7. With `vsr > RAY` the ceiling is lower still (`_rpow(MAX_VSR, 400 days)` ~2.14e27 halves it). | `test_BUG_adjustTotalAssets_chiAboveRpowBoundBricksVault`, `test_BUG_nowChi_exactRpowOverflowThreshold` (bound passes, bound+1 panics), `test_BUG_adjustTotalAssets_chiBrickRecoverableOnlyInSameBlock` (undo works at `timestamp == rho`, panics one second later; round trip costs exactly 2 wei of totalAssets) | Medium (admin-only input, catastrophic and irreversible outcome; replace the `uint192` check with `updatedChi_ <= type(uint256).max / RAY`, better `/ _rpow(maxVSR, horizon)`) |
| UV5-2 (= V2-7, still open) | `:297`, `:829` | `setCapacity` is unbounded; `_processPendingDeposits` evaluates `convertToAssets(availableCapacity())`. With `chi` at the harness index, `maxCapacity = totalSupply + type(uint256).max / nowChi` still works (bob's deposit fills), `+1` more makes `requestDeposit` and `processPendingDeposits` panic 0x11, and the view `convertToAssets(availableCapacity())` itself reverts. Recoverable by `setCapacity` (no drip there). | All deposits blocked until the admin lowers capacity; a front end computing remaining capacity in assets breaks first. | `test_BUG_availableCapacity_overflowInConvertToAssets` | Low |
| UV5-3 (view accuracy, new on master) | `:666-674`, `:837`, `:861` | The head-advance loop was removed from `requestDepositCancellation`, and `_processPendingDeposits` only moves the head when `remaining_ != 0`. With `availableCapacity() == 0`, 50 deposit-then-cancel pairs leave `getPendingDepositRequests().length == 50` (all zero structs), `pendingDepositSavingsShares == 0`, and the rebalancer's `processPendingDeposits(max, max)` cannot clear them. When capacity returns, the next depositor's `requestDeposit` walks all 50 ghosts: 231,756 gas vs 168,206 clean (~1.27k per ghost). | Integrators must filter `shares == 0`; bounded griefing of the next depositor (1e6 minimum deposit per ghost in this harness, free if `minDeposit == 0`). | `test_getPendingDepositRequests_includesCancelledWhileCapacityIsZero`, `test_getPendingDepositCancellationRequests_tracksCancelAndSettle`, `testFuzz_getPendingRequests_matchHeadAndCounters` (head stays 0 for any cancel mask) | Low / Info |
| UV5-4 (info) | `:651-664`, `:736-749` | Single-entry getters accept a cancelled or ghost id inside `[head, length)` and return `(0, 0, 0)` for a cancelled deposit but `(owner, recipient, 0)` for a redeem ghost (`requestRedeem(1)` at 1% fee); a filled or settled id below the head and `id == length` both revert `invalid-request-id`. | Callers cannot distinguish "cancelled" from "never existed in the window" without the range getter; documented behaviour, not a bug. | `test_getPendingDepositRequest_bounds`, `test_getPendingDepositCancellationRequest_bounds`, `test_getPendingRedeemRequest_bounds` | Info |

### (b) Previously reported findings, status at 0ebb452

| Finding | Status | Pinning test |
|---|---|---|
| G-1 / G-2 chi overflow brick | **Open**, exact threshold measured (above) | `test_BUG_adjustTotalAssets_chiAboveRpowBoundBricksVault`, `test_BUG_nowChi_exactRpowOverflowThreshold` |
| V2-7 `setCapacity` unbounded | **Open**, exact threshold measured | `test_BUG_availableCapacity_overflowInConvertToAssets` |
| F-2 queue backing not ring-fenced from `take` / redeems | **Open** (fork PoC, compile only) | `test_BUG_F2_takeSpendsQueuedDepositBacking`, `test_BUG_F2_processPendingRedeemsPaysRedeemersWithQueuedDepositBacking`; local: `test_availableLiquidAssets_isSpUsdcMaxWithdraw` shows `availableLiquidAssets` counts queued backing (149,999,999 for 100e6 filled + 50e6 queued) |
| F-4 dust fill mints zero shares | **Open** (fork PoC) | `test_BUG_F4_dustFillMintsZeroShares` |
| F-5 / V2-9 ghost entries | **Open** | `test_BUG_F5_zeroDepositRequestsBloatQueue`, `test_BUG_F5_tinyRedeemRequestsBecomeGhostEntries` (fork), `test_getPendingRedeemRequest_bounds` (local) |
| F-1 / V2-2 guardian cancel to arbitrary recipient | **Fixed**: guardian and admin get `not-authorized`; only the owner cancels and names the recipient; `cancelRedeemRequest` selector gone | `test_fixed_F1_guardianCannotCancelDeposit`, `test_fixed_F1_cancelRedeemRequestRemoved` (fork) |
| F-3 `maxRequests` honoured | **Fixed** | `test_fixed_F3_processPendingDepositsFillsAllRequestsInOneCall` (fork) |
| R4-A/R4-B blacklisted recipient blocks queue | **Fixed** (seen from the upgrade side): a redeem paid to a blacklisted carol credits `claimableAssets[carol] = 9_989_997` (10e6 in, 0.1% fee, 3 wei of floors), the USDC sits in the vault, survives the upgrade, and `claim` pays after un-blacklisting | `test_upgradeToAndCall` |
| Round-4 layout (`savings` slot 0, `rho|chi` packed at 4, `paused` at 8, no `claimableAssets`) | **Changed**: not compatible (nothing deployed) | `test_storageLayout_notCompatibleWithRoundFour` |
| `UNPAUSER_ROLE`, `SETTER_ROLE`, `RISK_MANAGER_ROLE` | **Gone** from the ABI | `test_roleAdmins_unchangedByUpgrade` |

### (c) Properties that held

Storage layout (every assertion is against `forge inspect SparkPrimeVault storage-layout` at 0ebb452):

| Slot | Variable | Pinned by |
|---|---|---|
| 0 / 1 / 2 | `_depositRequests` / `_depositCancellationRequests` / `_redeemRequests` lengths; elements at `keccak256(slot) + 3*i + {0 owner, 1 recipient, 2 shares}` | `test_storageLayout_readEverySlot`, `test_storageLayout_storeEverySlot`, `test_upgradeToAndCall_v2ReadsEveryQueueSlot` |
| 3 | `savings` | same |
| 4 | `asset` (offset 0) + `paused` (offset 20) | same (`vm.store` of `1 << 160 \| asset` makes `paused()` true) |
| 5 / 6 | `name` / `symbol` as inline short strings (`len*2` in the low byte: 32 and 14) | same |
| 7 | `decimals` (offset 0) + `rho` (offset 1) | same |
| 8 | `chi` alone (uint192 does not fit beside 9 bytes) | same |
| 9..11 | `vsr`, `minVSR`, `maxVSR` | same |
| 12..16 | `maxCapacity`, `minDeposit`, `minRedeem`, `redeemFeeRate`, `maxRedeemFeeRate` | same |
| 17 | `totalSupply` | same |
| 18..20 | `pendingDepositSavingsShares`, `pendingCancelledDepositSavingsShares`, `pendingRedeemShares` | same |
| 21..23 | `firstPendingDepositId`, `firstPendingDepositCancellationId`, `firstPendingRedeemId` | same |
| 24..27 | `balanceOf`, `nonces`, `claimableAssets`, `allowance` | same |
| 28 | first free slot (V2 mock's `newVar`) | `test_upgradeToAndCall_withReinitializer` |
| ERC-7201 | `openzeppelin.storage.{Initializable, AccessControl, AccessControlEnumerable}` roots equal the derived constants, hold `_initialized == 1`, `hasRole`, `adminRole == 0`, enumerable `_values`/`_positions` exactly where the formula says; clobbering slots 0..28 with `0xff..ff` leaves every role intact (no collision) | `test_storageLayout_erc7201Namespaces` |

Upgrade:
- Only `DEFAULT_ADMIN_ROLE` can `upgradeToAndCall` (six other actors rejected with `AccessControlUnauthorizedAccount`); works while paused; rejected on the implementation (`UUPSUnauthorizedCallContext`), for a wrong UUID and for a non-UUPS target; ETH refused without data, rolled back with data. `test_upgradeToAndCall_notAdmin`, `_whilePaused`, `_notProxy`, `_implementationUUIDNotSupported`, `_implementationHasNoUUID`, `_nonPayableWithoutData`, `_valueWithNonPayableInitializer`.
- Implementation has `_initialized == type(uint64).max`, empty linear storage, no roles, `implementation() == 0`; proxy `initialize` cannot re-run before or after the upgrade; upgrade calldata re-running `initialize` reverts and rolls back; `reinitializer(2)` runs once. `test_initialize_implementationCannotBeInitialized`, `test_initialize_alreadyInitialized`, `test_upgradeToAndCall_reinitializeReverts`, `test_upgradeToAndCall_withReinitializer`.
- State preservation: 55-field snapshot (every getter incl. `claimableAssets`, `availableLiquidAssets`, three queue hashes, `DOMAIN_SEPARATOR`), all 28 raw slots and all six role member lists are byte-identical across V1 -> V2 -> V1; afterwards all three queues process and `claim` pays. `test_upgradeToAndCall`, `test_upgradeToAndCall_roundTrip`, `test_roleAdmins_unchangedByUpgrade`.

Views:
- Range getters: `invalid-range` for `start > end`, `end > length`, and `(max, max)`; `(length, length)` is an empty read; deleted head entries read as zero structs. `test_getPendingDepositRequests_rangeValidation`, `test_getPendingRequests_rangeReadOfDeletedHeadEntry`.
- Single-entry getters: partial fills report the remaining shares (deposit, cancellation, redeem). `test_getPendingDepositRequest_bounds`, `test_getPendingDepositCancellationRequest_bounds`, `test_getPendingRedeemRequests_partialFillKeepsHeadEntry`.
- `availableCapacity` clamps to 0 when `maxCapacity < totalSupply`, is share-denominated (a 50e6 loss leaves it unchanged). `test_availableCapacity`.
- `availableLiquidAssets == spUSDC.maxWithdraw(vault)`: bounded by spUSDC's USDC balance and by the vault's spUSDC balance. `test_availableLiquidAssets_isSpUsdcMaxWithdraw`.
- `assetsOf == convertToAssets(balanceOf)` (99,999,998 for 100e6 in: two floors); `totalAssets` is notional only: unchanged by `take` of all spUSDC and excludes USDC parked for blacklisted claimants. `test_assetsOf`, `test_totalAssets_isNotionalOnly`.
- `convertToAssets`/`convertToShares` monotone; shares->assets->shares loses at most 1, assets->shares->assets at most `ceil(chi/RAY)` and never gains (fuzz over 10 years at 40% APY); exact values at `chi = 1.5e27`. `testFuzz_convertToAssets_monotonic`, `testFuzz_convert_roundTripBounds`, `test_convert_exactAtKnownChi`.
- `nowChi == chi` at `rho`, equals what `drip` returns and stores, keeps accruing while paused; `rho` ahead of `block.timestamp` short-circuits. The `uint192` casts at `:637`/`:811` cannot truncate (quotient <= 1.158e50). `test_nowChi_matchesDrip`, `test_nowChi_rhoInFuture`, `test_nowChi_uint192CastCannotTruncate`.
- `DOMAIN_SEPARATOR` equals the EIP-712 formula with name/version "1", is recomputed from the live chain id, `name` has no setter. `test_DOMAIN_SEPARATOR`.
- `implementation()` equals the EIP-1967 slot and follows an upgrade. `test_implementation`.

### (d) Not settled

- `Review.t.sol` / `TestBase.t.sol` are mainnet-fork tests and were compiled only; the F-2 / F-4 / F-5 PoCs should be run with `MAINNET_RPC_URL` set before the audit.
- UV5-1's practical bound with `vsr > RAY` depends on `maxVSR` and the time between drips; one point measured (`bound/2 + 1` panics after 400 days at `MAX_VSR`), not the full curve.
- Whether a fixing implementation can be deployed fast enough in practice (admin-triggered brick, governance-timelocked upgrade) is operational, not testable here.

### Porting notes

- `Upgrade.t.sol`: slot constants rewritten for the new layout (arrays first, `paused` packed with `asset`, `decimals` with `rho`, `chi` alone, `claimableAssets` inserted); `UNPAUSER_ROLE` / `SETTER_ROLE` / `RISK_MANAGER_ROLE` references replaced by the six live roles; setUp now also produces a `claimableAssets` entry.
- `Views.t.sol`: the assertion "head walked past the cancelled entry" was inverted (cancel no longer moves the head); one deposit in `rangeReadOfDeletedHeadEntry` now walks a cancelled entry on its way.
- `Review.t.sol`: `test_F1_guardianCancelDepositRefundsOwnerOnly` rewritten as `test_fixed_F1_guardianCannotCancelDeposit` (guardian path is gone); F-2/F-4/F-5 renamed `test_BUG_`, F-3 `test_fixed_`. Nothing deleted.
- `SparkPrimeVaultV2Mock`: `newVar` now at slot 28; raw queue readers added.
