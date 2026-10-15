# FRESH-EYES worker report

## Round 5 (`master` @ `0ebb452`)

Independent attacker pass over `src/SparkPrimeVault.sol` @ `0ebb452`, written after a cold read of
the contract and of the real spUSDC code (`test/ai/lib/spusdc/SparkVault.sol`) and before reading
other workers' views. File: `test/ai/FreshEyes.t.sol` (34 tests, all PASS; the two fuzz
properties pass at `FOUNDRY_FUZZ_RUNS=20000`). Harness constants: chi_s =
1.047633055711877768967605062e27, chi_p = 1.009687768242461209408770821e27, 1_000_000e6 USDC =
954_532_691_143 spUSDC = 990_405_184_109 spPRIME, `assetsOf` of that = 999_999_999_998.
Every `test_BUG_` test passes by construction (it asserts the bad behaviour); none fails
deliberately.

### (a) Findings

**FE-1. Redeem head can be left with unpayable dust; the deficit migrates to the last redeemer.**
`src/SparkPrimeVault.sol:903` bounds a batch by `convertToShares(spUSDC.maxWithdraw(vault))`
(floor), each fill computes `convertToAssets(shares_)` (floor, `:914`) and `spUSDC.withdraw`
ceil-burns spUSDC (`:922`, SparkVault `_divup`). Scenario: alice deposits 1M, redeems all
(990_405_184_109 shares). spUSDC liquidity limited to 250k: slice 1 pays 249_999_999_999 and
burns `divUp(249_999_999_999 * RAY / chi_s)` spUSDC. Liquidity returns; the vault's remaining
spUSDC is worth exactly the 749_999_999_999 still owed, but re-flooring it into shares gives one
share less than the entry, the fill of (owed - 1) shares ceil-burns the vault's last spUSDC wei,
and 1 share stays at the head with `firstPendingRedeemId == 0`. From then on `remaining_ == 0`
means the loop never runs, so no call can move the head until spUSDC arrives from outside. When
bob deposits 100e6 and redeems, his backing pays alice's dust and bob ends 1 wei short
(99_999_997 vs 99_999_998) with his own dust at the head. Impact: the redeem queue is always
behind by the accumulated ceil-burn (1 spUSDC wei per partial fill) and the last redeemer in a
quiet vault is stuck until the taker donates; dust-sized, but it is a liveness property auditors
will ask about. Severity: low. Tests: `test_BUG_partialFills_leaveUnpayableDustAtRedeemHead`,
`test_property_spUsdcLiquidityDrain_partialFillsExact_noRevert` (1 spUSDC wei returned is still
not enough: 1 USDC wei = 0 spPRIME shares, 2 wei clears it).

**FE-2. `setCapacity(type(uint256).max)` bricks every deposit fill (Panic 0x11).**
`:829` computes `convertToAssets(availableCapacity())` = `cap * chi / RAY` in checked arithmetic.
Threshold with `totalSupply == 0` is exactly `type(uint256).max / chi` (~1.147e50 shares);
`cap = threshold + totalSupply` works, `+1` panics in both `requestDeposit` (instant-fill path,
`:415`) and `processPendingDeposits`. "Unlimited" is the obvious value an operator reaches for.
No funds at risk (the request itself reverts), but the vault takes no deposits until the admin
lowers the cap. Severity: low (admin footgun; fix: cap the conversion or the setter).
Test: `test_BUG_setCapacity_uint256Max_bricksDepositFills`.

**FE-3. Ghost entries + unbounded instant-fill walk: measured.** With `minDeposit == 0`
(the default) and `availableCapacity() == 0`, `requestDeposit(0, x, ref)` costs 77_270 gas, pushes
a zero entry (`:406`) and does not advance the head (`remaining_ == 0` short-circuits `:837`).
When capacity returns, the first depositor whose request satisfies `:414` walks every ghost at
2_393 gas each (cold slots, `vm.cool`): 2_000 ghosts turn a 352_428-gas deposit into 5_140_322.
~1.3e4 ghosts (~1e9 gas for the attacker) push the walk past a 30M block and `requestDeposit`
reverts for everyone until the rebalancer chunks the head with `processPendingDeposits(1, k)`
(works, pinned). With `minDeposit > 0` the same ghost is produced by request-then-cancel (`:432`)
and the attacker's capital is recycled through the cancellation queue (5 cycles of 1_000e6 cost 5
wei). Ghosts also count against `maxRequests_` (`:835`): a budget of k walks k ghosts and fills
nothing. Severity: low (gas griefing, recoverable; fix: `require(savingsShares_ != 0)` and a
bounded walk in `requestDeposit`). Tests: `test_BUG_ghostEntries_autoWalkGasGriefsNextDepositor`,
`test_BUG_ghostEntries_viaCancelWithMinDeposit`, `test_property_rebalancerCanChunkGhostsOnceCapacityReturns`.

**FE-4. `adjustTotalAssets` gain sandwich, quantified.** `:278-295` requires `paused`, but the
pause is a separate GUARDIAN tx and the spell payload is public. alice holds 1M; mal deposits 1M
(instant fill at `:415`) in the block before the pause; admin applies +10_000e6; after unpause
each holds 1_004_999_999_998. With the default `redeemFeeRate == 0` mal redeems to
1_004_999_999_998 USDC (+4_999.999998 for one block of exposure). With the fee at the 1% maximum
the fee is 9_904_051_842 shares and mal nets 994_949_999_997 (< 1M): the fee only deters gains
below ~2% of the sandwich stake, and it is 0 unless set. Severity: medium (economic; operational
mitigation is pause-then-publish or a non-zero fee). Test:
`test_BUG_adjustTotalAssets_gainSandwich_depositBeforePause`.

**FE-5. Redeem liquidity is not ring-fenced from queued-deposit / cancellation backing.**
`availableLiquidAssets()` (`:788-790`) is `spUSDC.maxWithdraw(vault)`, i.e. ALL of the vault's
spUSDC. After `take()` empties the vault, bob's queued 1M (capacity exhausted) is the only spUSDC
on the balance; alice's redeem of 990_405_184_109 shares is paid 999_999_999_998 out of it and
the vault holds 0 spUSDC. bob's cancellation then settles 0 (`maxRedeem == 0`, `:870`) until the
taker returns `S` spUSDC, after which he gets 999_999_999_999. CAMPAIGN.md states the deposit
queue is intentionally not ring-fenced from `take`; this shows the rebalancer can produce the same
state without the taker. Severity: low (no value lost, canceller liveness depends on the operator).
Test: `test_BUG_redeemsConsumeQueuedDepositBacking_cancellerStuck`.

**FE-6. Batched redeem can revert on ceil-rounding when draining all backing (C-1 re-proved).**
Three entries (11, 11, rest) of alice's 990_405_184_109 shares and `processPendingRedeems(max,
max)` revert `SparkVault/insufficient-balance` (`:922`). Severity: low (rebalancer lowers
`maxShares_`). Test: `test_BUG_redeemBatch_ceilRounding_revertsWhenDrainingAllBacking`.

**FE-7 (info). Referral attribution is emitted at request time (`:410`) and never reconciled.**
Request 1M with code 777, cancel, settle: three loops emit 3M of referred volume, mint 0 shares and
cost 3 wei. `requestDeposit(0, victim, 777)` attaches a code to any address for free. Off-chain
referral accounting must use `Deposit` fills, not `Referral`.
Test: `test_info_referralEmittedOnRequest_notOnFill_cancelLoopInflatesVolume`.

**FE-8 (info). Blacklist handling is a liveness feature, not a compliance gate.** Only recipients
are checked (`:425,:452,:493,:508`). A holder blacklisted after requesting can
`updateRedeemRecipient` to a clean address, `requestRedeem` to a clean address, or `transfer`
shares. spUSDC behaves the same (`redeem(shares, cleanReceiver, owner)`), so this is consistent.
Test: `test_info_blacklistedOwner_canStillExitViaCleanRecipient`. If the VAULT itself is
blacklisted, redeems and cancellations still pay (spUSDC pushes USDC straight to the recipient),
deposits revert in USDC (`approve`/`transferFrom` of a blacklisted spender/receiver) and `claim`
would revert. Test: `test_info_vaultBlacklisted_redeemsAndCancelsStillPay_depositsAndClaimsDont`.

**FE-9 (info). `adjustTotalAssets` is a relative delta applied after `drip()` (`:282-284`).**
A spell computed as "target = t0 + 1M" at 5% VSR on 100M executed 3 days later overshoots by
40_109_546_524 wei (~40.1k USDC). Test: `test_info_adjustTotalAssets_relativeDelta_spellLagDrift`.

**FE-10 (info).** `requestRedeem(shares, address(vault))` strands `convertToAssets(shares)` USDC in
the vault with `claimableAssets[vault] == 0` (V2-13 re-pinned); `requestDeposit(x, address(spUsdc))`
mints 990_405_184_109 shares to spUSDC forever; `requestDepositCancellation(id >= length)` panics
0x32 instead of a string revert (`:427`); `permit` accepts high-s malleated signatures (`:1025`,
harmless: the twin shares the nonce). Tests: `test_info_redeemRecipientVault_strandsUsdcForever`,
`test_info_depositRecipientSpUsdc_strandsShares`, `test_info_requestDepositCancellation_outOfRange_panics`,
`test_info_permit_acceptsMalleatedHighS_signature`. The upgrade mock's comment says the appended
var lands in slot 27; on `0ebb452` `allowance` is 27 and it lands in 28 (mock comment only, not
`src/`): `test_property_upgrade_adminOnly_statePreserved_slot28Appended`.

### (b) Previously reported findings touched

- C-1 open (FE-6). R3-1 "quantify the gain between payload-public and pause": FE-4. V2-13
  open (FE-10). V2-9 / ghost entries open and measured (FE-3). F-2 (`take` drains queue backing):
  confirmed and extended to the redeem path (FE-5). Storage layout (#9) pinned slot by slot with
  `vm.load`: `test_property_storageLayout_0ebb452_pinned` (arrays 0-2, `asset|paused` packed in 4,
  `decimals|rho` in 7, chi 8, ..., `balanceOf` 24, `nonces` 25, `claimableAssets` 26,
  `allowance` 27, redeem entry 0 at `keccak(2)+{0,1,2}`).

### (c) Properties that held (attacks ruled out)

- Queue accounting under 24 random ops x 20_000 seeds: each `pendingX` counter equals the sum of
  its array from the head, redeem escrow `== balanceOf(vault)`, vault spUSDC `>=` queued deposit +
  cancellation shares (no take), heads never exceed lengths, every slot below a head is dead:
  `testFuzz_property_queueCountersMatchArrays`.
- Cancellation batches never revert on rounding (floor bound, floor payouts), including with half
  of spUSDC's liquidity drained, 20_000 runs: `testFuzz_property_cancellationBatch_neverRevertsOnRounding`.
- The instant-fill predicate cannot fill a newcomer ahead of a live entry (partial head, cancel,
  newcomer queued, FIFO fills with exact wei): `test_property_instantFill_neverSkipsLiveEntry_partialHeadThenCancel`.
- Fee cannot be bypassed by transferring to a fresh address or by naming another recipient
  (fee 9_904_051_842 shares, carol receives 989_999_999_997); a 1-share redeem at 1% is 100% fee
  and the resulting ghost is skipped: `test_property_redeemFee_notBypassableByTransferOrRecipient`,
  `test_property_oneWeiRedeemWithFee_isAllFee_ghostIsSkipped`.
- Claimable escrow: `sum(claimableAssets) <= USDC in vault`, `requestDeposit` pulls and re-pushes
  exactly `assets_` so it never touches it, `claim` is permissionless, pays only after
  un-blacklisting, zeroes before transfer: `test_property_claimableEscrow_untouchedByDeposits_exactWei`.
- `take` of everything turns all three settlements into no-ops (no revert, heads unchanged),
  deposits still fill (minting needs no spUSDC), returning funds resumes with exact wei:
  `test_property_takeAll_settlementsAreNoOps_notReverts`.
- spUSDC deposit cap propagates as `SparkVault/deposit-cap-exceeded`; a drained spUSDC never makes
  a settlement revert, only partial: `test_property_spUsdcDepositCap_propagatesAsRevert`,
  `test_property_spUsdcLiquidityDrain_partialFillsExact_noRevert`.
- Queued deposits accrue the spUSDC index, queued redeems the spPRIME index (1y at 10% spUSDC /
  5% spPRIME: 1_099_999_999_997): `test_property_queuedEntries_accrueTheirOwnIndex`.
- A 50% loss hits holders and escrowed redeemers (499_999_999_999 each), not queued deposits
  (999_999_999_998 after fill) or cancellations (999_999_999_999):
  `test_property_loss_hitsHoldersAndQueuedRedeemers_notQueuedDepositsOrCancels`.
- Permit: nonce only advances on success, replay and expiry rejected, ERC1271 contract owners work
  (also for 65-byte garbage), ERC20 self-transfer/self-transferFrom and vault targets:
  `test_property_permit_eoa_nonceOnlyAdvancesOnSuccess`, `test_property_permit_erc1271_contractOwner`,
  `test_property_erc20_selfTransfer_andVaultTargets`.
- Initializer cannot re-run on proxy or implementation, `upgradeToAndCall` on the implementation
  reverts `UUPSUnauthorizedCallContext`, upgrade is DEFAULT_ADMIN only, state and chi preserved,
  `reinitializer(2)` single-shot: `test_property_initializer_cannotRerun_onProxyOrImplementation`,
  `test_property_upgrade_adminOnly_statePreserved_slot28Appended`.
- `drip()` at MAX_VSR survives 60 years idle and only overflows (`_rpow` mul) at 77 years:
  `test_property_drip_maxVsr_survives60YearsIdle_overflowsAt77`.

### (d) Not settled

- Whether FE-1 can be made larger than 1 share per partial fill under spUSDC VSR accrual between
  slices (each slice re-floors at a new chi_s); only the frozen-index case is proved.
- Whether the operator intends `processPendingRedeems` to be allowed to spend queued-deposit
  backing (FE-5) or only `take`.
