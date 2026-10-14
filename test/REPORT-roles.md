# ROLES worker report: authorization, admin bounds, pause scope, upgrade

Branch `campaign/roles`. Files: `test/Authorization.t.sol` (62 tests), `test/Admin.t.sol` (61), `test/Upgrade.t.sol` (11), `test/mocks/SparkPrimeVaultV2Mock.sol`. Run: `forge test --match-path 'test/{Authorization,Upgrade,Admin}.t.sol'`. Result: 134 passed, 0 failed. No `test_BUG_` tests: nothing in this scope breaks a stated property; the items below are validation gaps and operational risks, each with a passing test that pins the behaviour.

## (a) Findings

| # | Location | Scenario | Impact | Test | Severity |
|---|----------|----------|--------|------|----------|
| R-1 | `src/SparkPrimeVault.sol:327-332` (`setChi`) | Guardian pauses; a compromised RISK_MANAGER calls `setChi(1)`. Only checks are `paused` and `0 < chi_ < drip()`. | One call writes the index down to 1 wei: `assetsOf(alice)` goes from 1,000,000e6 to 0, `totalAssets()` to 0, while the vault still holds ~1,000,000e6 of spUSDC. The spUSDC is then "unowned" and `take` can remove all of it. Loss realisation is unbounded for a hot-wallet role. Recommend a floor (e.g. `chi_ >= drip() * (1 - maxDrawdown)` with `maxDrawdown` set by DEFAULT_ADMIN) or move `setChi` to DEFAULT_ADMIN. | `test_setChi_oneWeiRealisesTotalLoss` | High (needs GUARDIAN pause + RISK_MANAGER key; pause is routine during incidents, exactly when a hot key is most likely to be abused) |
| R-2 | `src/SparkPrimeVault.sol:62` (`AccessControlEnumerableUpgradeable`, no `AccessControlDefaultAdminRules`) | The only DEFAULT_ADMIN calls `renounceRole(DEFAULT_ADMIN_ROLE, self)` or `revokeRole(DEFAULT_ADMIN_ROLE, self)`. | `getRoleMembers(DEFAULT_ADMIN_ROLE).length == 0` forever: no `unpause`, no `upgradeToAndCall`, no `grantRole`, no setter changes. Proven while paused: the vault stays paused for good. Recommend `AccessControlDefaultAdminRulesUpgradeable` (2-step transfer, renounce delay, single admin) or override `renounceRole`/`revokeRole` to refuse removing the last admin. | `test_renounceDefaultAdmin_vaultHasNoAdminForever`, `test_revokeDefaultAdmin_self_vaultHasNoAdminForever` | Medium (operational) |
| R-3 | `src/SparkPrimeVault.sol:217-242` (`initialize`) | `initialize(..., admin = address(0))`. OZ `_grantRole(role, address(0))` returns true and records the zero address as a member. | `hasRole(DEFAULT_ADMIN_ROLE, address(0)) == true` and no usable admin: same dead state as R-2 from block one. Add `require(admin != address(0))`. Same applies to `grantRole(DEFAULT_ADMIN_ROLE, address(0))` by a live admin. | `test_initialize_zeroAdminNotGuarded` | Low |
| R-4 | `src/SparkPrimeVault.sol:261-266` (`setMinimums`) | No validation. `setMinimums(0, type(uint256).max)` makes every `requestRedeem` revert `below-minimum` (even 1 share); `setMinimums(type(uint256).max, 0)` makes every `requestDeposit` revert; `minDeposit` above `maxCapacity` forces every deposit to partially queue behind an unreachable cap. | DEFAULT_ADMIN only, so not an attack, but a fat-finger freezes all exits until the same admin resets it. Cancels and `processRedeemQueue` still work. Recommend sanity bounds. | `test_setMinimums_noValidation_minWithdrawBlocksAllRedeems`, `test_setMinimums_noValidation_minDepositBlocksAllDeposits`, `test_setMinimums_minDepositAboveCapacity` | Low |
| R-5 | `src/SparkPrimeVault.sol:268-274` (`setVSRBounds`) | `vsr = 10%`, admin sets bounds `[RAY, 1%]`. Accepted; `vsr` stays 10%. | `drip` keeps accruing at 10% (measured 9-11% over 365 days) until SETTER moves it. Admin cannot force the rate down itself; if the SETTER key is the one being contained, the admin must first grant SETTER to itself. Consider clamping `vsr` into the new bounds inside `setVSRBounds` (after a `drip()`). | `test_setVSRBounds_currentVsrOutsideNewBounds` | Low |
| R-6 | `src/SparkPrimeVault.sol:256-259` (`setMaxRedeemFee`) | `redeemFee = 1%`, admin lowers `maxRedeemFee` to 0.1%. Accepted; `redeemFee` stays 1% and new redeem requests are charged 1%. | Same pattern as R-5: a tightened bound does not take effect until RISK_MANAGER acts. Consider clamping `redeemFee` in `setMaxRedeemFee`. | `test_setMaxRedeemFee_belowCurrentFeeLeavesFeeAboveMax` | Low |
| R-7 (I-3) | `src/SparkPrimeVault.sol:153, 276` | `UNPAUSER_ROLE` is declared and granted in the harness; `unpause` is `onlyRole(DEFAULT_ADMIN_ROLE)`. | The unpauser reverts with `AccessControlUnauthorizedAccount(unpauser, 0x00)`. Either gate `unpause` on `UNPAUSER_ROLE` or delete the constant. As is, every unpause needs the cold admin key. | `test_unpause_unpauserRoleCannotUnpause` | Info |
| R-8 | `src/SparkPrimeVault.sol:294-303` (`take`) | `take` has no `whenNotPaused` and ignores `pendingDepositSavingsShares` (F-2, known). | Taker can pull all spUSDC during a pause, including deposit-queue backing; after that the queued depositor's cancel reverts. Documented, not re-reported. | `test_take_whilePaused`, `test_pause_doesNotBlockTake`, `test_take_ignoresPendingDepositSavingsShares` | Known (F-2 / F-7) |
| R-9 | `src/SparkPrimeVault.sol:251-254` (`setCapacity`) | `setCapacity(0)`: deposits are still accepted (USDC moves into spUSDC, entry queued) but nothing mints. `setCapacity(totalSupply - 1)` tolerated, `availableCapacity() == 0`. | Fine as designed; note "capacity 0" is not "deposits rejected": users' USDC enters the queue and sits in spUSDC. | `test_setCapacity_zeroFreezesMinting`, `test_setCapacity_belowTotalSupply` | Info |

## (b) Tables

### Authorization matrix

Columns are the single role each actor holds. OK = succeeds; X = reverts `AccessControlUnauthorizedAccount(caller, <required role>)`. All cells are asserted by `test_<fn>_notAuthorized` / `test_<fn>_authorized` in `Authorization.t.sol`.

| Function | required role | ADMIN | GUARDIAN | REBALANCER | RISK_MGR | SETTER | TAKER | UNPAUSER | stranger |
|---|---|---|---|---|---|---|---|---|---|
| setCapacity | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setMaxRedeemFee | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
| setMinimums | DEFAULT_ADMIN | OK | X | X | X | X | X | X | X |
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
| setRedeemFee | RISK_MANAGER | X | X | X | OK | X | X | X | X |
| setChi (paused) | RISK_MANAGER | X | X | X | OK | X | X | X | X |
| pause | GUARDIAN | X | OK | X | X | X | X | X | X |
| cancelDepositRequest (not owner) | owner or GUARDIAN | `not-authorized` | OK (refund to owner) | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` |
| cancelRedeemRequest (not owner) | owner or GUARDIAN | `not-authorized` | OK (refund to owner) | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` | `not-authorized` |
| requestDeposit (x2), requestRedeem, cancel own request, approve, transfer, transferFrom, permit, drip | none | OK | OK | OK | OK | OK | OK | OK | OK (`test_permissionless_stranger`) |

`getRoleAdmin(role) == DEFAULT_ADMIN_ROLE` for all 7 roles (asserted in `test_grantRole_authorized`).

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
| take | allowed | `test_pause_doesNotBlockTake` |
| drip | allowed, chi keeps accruing | `test_pause_doesNotBlockDrip` |
| setVSR | allowed | `test_pause_doesNotBlockSetVSR` |
| setChi | allowed (requires paused) | `test_pause_doesNotBlockSetChi` |
| approve / transfer / transferFrom | allowed | `test_pause_doesNotBlockERC20` |
| permit | allowed | `test_pause_doesNotBlockPermit` |
| setCapacity, setMaxRedeemFee, setMinimums, setVSRBounds, grantRole, revokeRole, setRedeemFee | allowed | `test_pause_doesNotBlockAdminSetters` |
| upgradeToAndCall | allowed, `paused` survives the upgrade | `test_pause_doesNotBlockUpgrade` |
| pause when paused / unpause when not paused | idempotent, event still emitted | `test_pause_idempotent`, `test_unpause_idempotent` |

### Storage layout (`forge inspect SparkPrimeVault storage-layout`, solc 0.8.34)

| Slot | Offset | Bytes | Name | Type |
|---|---|---|---|---|
| 0 | 0 | 20 | savings | address |
| 0 | 20 | 1 | decimals | uint8 |
| 1 | 0 | 32 | name | string |
| 2 | 0 | 32 | symbol | string |
| 3 | 0 | 8 | rho | uint64 |
| 3 | 8 | 24 | chi | uint192 |
| 4 | 0 | 32 | vsr | uint256 |
| 5 | 0 | 32 | minVSR | uint256 |
| 6 | 0 | 32 | maxVSR | uint256 |
| 7 | 0 | 1 | paused | bool (alone in its slot; 31 bytes free) |
| 8 | 0 | 32 | maxCapacity | uint256 |
| 9 | 0 | 32 | minDeposit | uint256 |
| 10 | 0 | 32 | minWithdraw | uint256 |
| 11 | 0 | 32 | redeemFee | uint256 |
| 12 | 0 | 32 | maxRedeemFee | uint256 |
| 13 | 0 | 32 | totalSupply | uint256 |
| 14 | 0 | 32 | pendingDepositSavingsShares | uint256 |
| 15 | 0 | 32 | pendingRedeemShares | uint256 |
| 16 | 0 | 32 | depositQueue | Request[] |
| 17 | 0 | 32 | redeemQueue | Request[] |
| 18 | 0 | 32 | depositHead | uint256 |
| 19 | 0 | 32 | redeemHead | uint256 |
| 20 | 0 | 32 | balanceOf | mapping(address => uint256) |
| 21 | 0 | 32 | nonces | mapping(address => uint256) |
| 22 | 0 | 32 | allowance | mapping(address => mapping(address => uint256)) |
| 23 | 0 | 32 | (next free slot; `SparkPrimeVaultV2Mock.newVar` lands here) | |

Namespaced OZ storage (ERC-7201, not in the linear layout): Initializable `0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00`, AccessControl `0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800`, AccessControlEnumerable `0xc1f6fe24621ce81ec5827caf0253cadb74709b061630e6b55e82371705932000`; implementation at ERC-1967 `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`. Packing is verified on-chain by `test_storageLayout_packing` (slot 0 = spUSDC address | 6 at byte 20, slot 3 = rho | chi << 64, slot 7 = 0 while unpaused, slots 16/17 = queue lengths). `test_upgradeToAndCall` diffs all 23 raw slots before/after the upgrade and asserts slot 23 is empty.

## (c) Properties that held

- Every role-gated function reverts with the exact OZ custom error for all 7 other actors and a stranger (matrix above).
- SETTER is bounded by admin bounds: `vsr-too-low` / `vsr-too-high` at `minVSR - 1` / `maxVSR + 1`; with bounds `[RAY, RAY]` the rate cannot move at all (`test_setVSR_belowMinVsrBoundary`, `test_setVSR_aboveMaxVsrBoundary`, `test_setVSR_lockedWhenBoundsEqual`).
- RISK_MANAGER is bounded by `maxRedeemFee`: `fee-too-high` at `max + 1`; `maxRedeemFee = 0` locks the fee at 0 (`test_setRedeemFee_tooHighBoundary`, `test_setRedeemFee_zeroMaxLocksFee`).
- RISK_MANAGER cannot raise chi: `setChi(chi)` and `setChi(chi + 1)` revert `invalid-chi`, `setChi(0)` reverts, unpaused reverts `not-paused`; comparison is against the dripped chi (`test_setChi_cannotRaiseBoundary`, `test_setChi_comparesAgainstDrippedChi`, `test_setChi_zero`, `test_setChi_notPaused`).
- Admin bounds: `capacity-too-high` at `uint128.max + 1`, `fee-too-high` at `0.01e18 + 1`, `vsr-too-low` at `RAY - 1`, `vsr-too-high` at `MAX_VSR + 1`, `min-vsr-gt-max-vsr` (`test_setCapacity_tooHighBoundary`, `test_setMaxRedeemFee_tooHighBoundary`, `test_setVSRBounds_*Boundary`).
- `minDeposit` checked on assets, `minWithdraw` on gross shares at `nowChi` with exact boundary (`test_setMinimums_boundaries`).
- `setVSR` drips at the old rate before switching; `Drip(nChi, diff)` then `VSRSet(vsr)` (`test_setVSR`, `test_setVSR_dripsAtOldRate`).
- Every setter emits its exact event: `CapacitySet`, `MaxRedeemFeeSet`, `MinimumsSet`, `VSRBoundsSet`, `VSRSet`, `RedeemFeeSet`, `ChiSet`, `Paused`, `Unpaused`, `Take`, `RoleGranted`, `RoleRevoked`, `Upgraded`.
- `take`: bounded by spUSDC balance with `insufficient-unencumbered-shares` at `balance + 1`; `take(0)` emits `Take(taker, 0)`; taker receives exactly `savingsShares_`; `totalAssets()` unchanged by take (`test_take_insufficientBalanceBoundary`, `test_take_zero`, `test_take`).
- Revocation mid-flight: revoked REBALANCER freezes both queues (entries intact) until a new one is granted, who then drains both (`test_revokeRebalancer_queueFrozenUntilNewRebalancer`); revoked TAKER can still return spUSDC by plain transfer and redeems resume (`test_revokeTaker_afterTake_returnStillWorks`); revoked GUARDIAN while paused leaves admin able to unpause (`test_revokeGuardian_whilePaused_adminCanStillUnpause`).
- Upgrade: admin only; `UUPSUnsupportedProxiableUUID`, `ERC1967InvalidImplementation`, `UUPSUnauthorizedCallContext` (call on the implementation) all exact; every public getter (35 fields incl. queues, heads, pending counters, balances, allowance, nonces, `DOMAIN_SEPARATOR`) and all 23 raw slots identical before/after; roles identical; `implementation()` and ERC-1967 slot updated; `initialize` reverts `InvalidInitialization()` before and after; implementation contracts have `_initialized == uint64.max`; `reinitializer(2)` path works once and sets slot 23; round trip V1 -> V2 -> V1 preserves state; queues process normally after upgrade (`Upgrade.t.sol`).
- Initialization: decimals 6 from the asset, `chi = vsr = minVSR = maxVSR = RAY`, `rho = now`, capacity/fee/max fee/minimums 0, USDC allowance to spUSDC `uint256.max`, admin is the only DEFAULT_ADMIN member, Initializable slot `1`. Fresh defaults lock SETTER (`vsr-too-high` at `RAY + 1`) and RISK_MANAGER (`fee-too-high` at 1) until admin widens them (`test_initialize`, `test_initialize_defaultsAreSafe`).
- ERC20: `transfer`/`transferFrom` exact balances and `Transfer` events; zero-address `invalid-address`; `insufficient-balance` at `balance + 1`; `insufficient-allowance` at `allowance + 1`; max allowance not decremented; self-transferFrom needs no allowance; `approve` overwrites. `permit`: happy path (v,r,s and 65-byte variants), `deadline == now` accepted, `permit-expired` at `deadline + 1`, `invalid-owner` for zero owner, `invalid-permit` for wrong signer/value/nonce/domain/replay and for a 64-byte EOA signature; nonce increments only on success. `name`, `symbol`, `decimals`, `version`, `DOMAIN_SEPARATOR`, `PERMIT_TYPEHASH` exact (`Admin.t.sol`).

## (d) Unsettled

- Whether R-1 should be treated as High or accepted depends on whether RISK_MANAGER is a cold key in production. If it is a hot key under the same agent as SETTER, a floor is needed.
- Guardian `cancel*Request` for any user is allowed and refunds the owner (F-1 patched); the fee is still lost on guardian cancel (F-8, known). Not re-tested here.
- `upgradeToAndCall` with ETH value and empty data (`ERC1967NonPayable`) not tested; OZ behaviour, not vault logic.
- `transfer(address(vault), x)` permanently stuck (I-6) not re-tested.
