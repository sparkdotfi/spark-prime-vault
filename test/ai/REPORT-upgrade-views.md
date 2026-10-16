# UPGRADE-VIEWS worker report

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
