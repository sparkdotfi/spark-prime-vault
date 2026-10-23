# spPRIME review & testing campaign: hand-off package

Written 2026-10-14 00:05 UTC for a Claude session with zero context. Everything you need is in
this repo; paths below are on Lucas's Mac mini unless marked (fork).

> **Status 2026-10-23, round 6:** target `master` @ `c512609` (the code with the auditors) merged into `review/poc-tests-v2` (PR #17). Harness ported (seven roles: admin, lossManager, operator, pauser, unpauser, redeemFeeSetter, taker; 7-arg `initialize` with 1-wei minimums; custom errors). Whole suite ported and extended: 1,022 tests, all green; invariants rewritten into the `handlers/` + `InvariantsBase` + `Invariants` layout (14 invariants, 250k calls). Worker worktrees `~/code/spprime-campaign-v6/<name>` on `campaign-v6/<name>`, all merged. Report: `AUDIT-REPORT.md` round 6 on top. Headline: `adjustTotalAssets` unbounded both ways on a hot-wallet `LOSS_MANAGER` (High), chi brick, pause sandwich plus cancel-during-pause free option, operator rate+processing, F-2; fixed: C-1, vault-recipient strand, zero-asset ghosts, pause gating of cancels.

> **Status 2026-10-15, round 5 (pre-audit):** target `master` @ `0ebb452` merged into `review/poc-tests-v2` (PR #17). Harness ported (roles `REDEEM_FEE_SETTER_ROLE` / `VSR_SETTER_ROLE`, `adjustTotalAssets`, `MockUSDC` with a real `isBlacklisted` blacklist). Suite under `test/ai/`: ten workers in `~/code/spprime-campaign-v5/<name>` (branches `campaign-v5/<name>`, all merged). New files: `Headline.t.sol` (coordinator's independent reproductions), `Blacklist.t.sol`, `AdjustTotalAssets.t.sol`, `FreshEyes.t.sol`, `REPORT-upgrade-views.md`, `REPORT-fresh-eyes.md`. Report: `AUDIT-REPORT.md` round 5 on top. Run with `FOUNDRY_OFFLINE=true` in worktrees. Headline: G-1 chi brick (exact threshold), gain sandwich around the pause, no loss floor, C-1, backing not ring-fenced; R4-A/R4-B fixed by the blacklist fallback.

> **Status 2026-10-14, round 4:** target `fix/update-guardian-transfer` @ `bf93b0d` (guardian deposit cancels refund the owner; `cancelRedeemRequest` removed). Suite under `test/ai/`: 627 tests, 626 pass, 1 deliberate failing proof. F-1 closed both sides. New: permanent blacklist block of the redeem queue (High) and of the cancellation queue at zero fee (Medium). Report: `AUDIT-REPORT.md` round 4 on top.

> **Status 2026-10-14, round 3 (+ rename sync):** upstream now `refactor/more-simplifying` @ `072e8d0` (renames, internal queue arrays, `getPending*Requests` views; then `731c1c8`: planner calls renamed `processPending*`, `UNPAUSER_ROLE` removed). The suite lives under `test/ai/` (595 tests). Branch pushed to `origin/review/poc-tests-v2`. Suite on
> `review/poc-tests-v2`: 597 tests, 596 pass, 1 deliberate failing proof. Fixed upstream: recipient
> updaters (owner-only), full-loss brick, cancelled-queue liquidity revert. New High: `realizeGain`
> sandwich. Still open: F-1 guardian redirect, `realizeLoss` floor, capacity bound, C-1, C-2.
> Business Rules v3 drafted in Notion (private draft page, to be moved next to v2).

> **Status 2026-10-14, round 2:** upstream moved to `refactor/more-simplifying` @ `0bc9288`. The whole
> suite was ported and extended on branch `review/poc-tests-v2` (worktree `~/code/spprime-review-v2`,
> worker worktrees `~/code/spprime-campaign-v2/<name>`): 520 tests, 519 pass, 1 deliberate failing
> proof. Report: `AUDIT-REPORT.md` (round 2 on top, round 1 as appendix). Headline: unauthenticated
> `update*Recipient` (Critical), F-1 regression (High), `realizeLoss` zeroes chi (High).

> **Status 2026-10-14:** campaign complete. All seven `campaign/*` branches are merged into
> `review/poc-tests`; the final report is `AUDIT-REPORT.md`; per-worker reports are `test/REPORT-*.md`.
> Local suite: 373 passed, 1 deliberate failing proof (`test_BUG_processRedeemQueue_batchCeilBurnsExceedSpUsdcBalance`).
> Worktrees live at `~/code/spprime-campaign/<name>` on Lucas's machine. Not pushed: the
> `lucas-manuel` GitHub account has no push access to `lucas-clawdbot/spark-prime-vault-1`.

## 1. What this is

Spark (Lucas) is reviewing **`src/SparkPrimeVault.sol`** (spPRIME), an index-priced vault token
built by Michael DeLuca on branch `lucas/refactor-vault` of `sparkdotfi/spark-prime-vault`.
Deposits go straight into spUSDC (Spark Savings USDC V2, index-priced ERC-4626); a TAKER role
(the PAU controller) pulls spUSDC out to allocate into Arkis; a planner (REBALANCER) fills FIFO
deposit/redeem queues. Lucas wants bugs surfaced NOW, before the design is frozen and before
external audit tooling runs. Deliverable: a professional-tier audit-style report with findings,
PoCs, invariants to keep, suggested changes and open questions for the business team.

Thread owner: Lucas (lucas-manuel). He reads from his phone: lead every message with counts and
the top items, keep it short, no questions he cannot answer in one word.

## 2. Where things are

- Main clone / review branch: `~/work/spprime-review`, branch **`review/poc-tests`** (based on
  `lucas/refactor-vault` @ 807739f). Pushed to the bot's fork:
  **https://github.com/lucas-clawdbot/spark-prime-vault-1/tree/review/poc-tests**
  (`gh` on the Mac mini is logged in as `lucas-clawdbot`; `git remote fork` points there; the
  bot's other fork `spark-prime-vault` is of the OLD repo, ignore it). Lucas asked for everything
  to be pushed to this fork so he can give Michael access.
- Submodules use SSH URLs; clone/init with
  `git -c url."https://github.com/".insteadOf="git@github.com:" submodule update --init --recursive`.
- `MAINNET_RPC_URL` is set in the environment (only `test/TestBase.t.sol` + `test/Review.t.sol`
  fork mainnet at block 26148600; everything else is local).
- Reference suite for test style: `~/work/spark-vaults-v2/test/` (Spark Vaults V2; its
  `src/SparkVault.sol` is byte-identical to the deployed spUSDC implementation).
- Worker worktrees: `~/work/spprime-campaign/{deposit-queue,redeem-queue,cancel-fees,invariants,
  adversarial,rounding,roles}` on branches `campaign/<name>`, each with its own copied `lib/`.
  Their state when this was written: see `git -C <worktree> status` and `git log`. Each is
  supposed to produce `test/<File>.t.sol` + `test/REPORT-<name>.md` committed on its branch.

## 3. Files on `review/poc-tests` (all mine)

| File | What |
|---|---|
| `REVIEW-2026-10-13.md` | First-pass review: accounting model, rounding table R1..R12, findings F-1..F-8 + I-1..I-8, business-team questions. **Read first.** |
| `CAMPAIGN.md` | Worker briefing: contract model, known findings, harness API, conventions, deliverable format. |
| `test/LocalTestBase.t.sol` | Local harness: 6-dec `MockUSDC`, REAL spUSDC code (`test/lib/spusdc/SparkVault.sol`) behind a proxy, `SparkPrimeVault` proxy with every role granted. Both indexes start "ugly" (spUSDC chi ≈ 1.0476e27, spPRIME chi ≈ 1.0098e27) with VSR then frozen at RAY. Helpers for deposits, redeems, draining spUSDC liquidity, taking/returning spUSDC, warps. |
| `test/LocalSmoke.t.sol` | Harness smoke test. |
| `test/Review.t.sol` | Mainnet-fork PoCs for F-1..F-5 (F-1/F-3 now assert the PATCHED behaviour). |
| `src/SparkPrimeVault.sol` | Upstream + two review patches marked `REVIEW PATCH F-1` (cancel refunds go to `request.owner` unless the owner calls) and `REVIEW PATCH F-3` (`if (request.shares != 0) break;`). Lucas approved patching both. |

Commands: `forge build`; `forge test --match-contract LocalSmokeTest`; fork PoCs:
`forge test --match-contract ReviewTest`.

## 4. Findings so far (severity after Lucas's answers)

- **F-1 High (patched):** guardian cancel could redirect refunds to any `recipient_`. Fix: owner-only recipient. Lucas: "legit, must fix".
- **F-2 Medium (design):** `cancelDepositRequest` reverts once `take()`/`processRedeemQueue` spent the queue's spUSDC. Lucas: NOT ring-fenced by design; a planner-handled deposit-cancel queue is coming (new feature, review it when it lands).
- **F-3 Medium (patched):** `_processDepositQueue` broke after one request (`requestSavingsShares_` vs `request.shares`). Lucas: must fix.
- **F-4 Low:** dust fills mint 0 shares while deducting spUSDC from the head request. Fix `if (shares_ == 0) break;`.
- **F-5 Low:** zero-amount deposit / 1-wei redeem requests create 0-share ghost entries. Reject zero net amounts.
- **F-6 Info:** no USDC→spUSDC path; Lucas: USDC never sits in the contract (capital returns as spUSDC); optional `sweepToSavings()`.
- **F-7 Low:** cancels blocked while paused, `take` not. Open question.
- **F-8 Low:** redeem fee charged at request, kept on guardian cancel. Lucas: fee up front is the current business position.
- Rounding verdict: every division in the vault rounds in the protocol's favour; only vault-unfavourable site is spUSDC's `withdraw` ceil-burn (≤1 wei spUSDC share per fill).

Decisions from Lucas (2026-10-13): instant redemptions are gone for good; ERC-7540 dropped
entirely; chi keeps accruing during pause (set VSR to RAY to freeze); only spUSDC is ever
custodied; `take()` may spend deposit-queue spUSDC; loss realisation (`setChi`) is OUT OF SCOPE for
this campaign (comes later).

Trust model: users adversarial; TAKER honest (PAU controller); DEFAULT_ADMIN and GUARDIAN honest;
REBALANCER, RISK_MANAGER, SETTER are hot-wallet roles under an administered agent that may be
temporarily compromised until revoked, damage must be bounded by admin-set bounds.

## 5. The campaign (what Lucas asked for)

"Super long, intense testing campaign": stress deposit queue, redeem queue, cancellations, fees;
users entering/exiting; insufficient USDC inside spUSDC; insufficient spUSDC inside the vault;
try to freeze/lock/lose funds, bad UX, value extraction; fuzz + invariant tests in the style of
Spark Vaults V2; expose rounding; parallel workers on separate files. Ignore loss realisation.

Worker assignments (full prompts are reproduced in spirit in `CAMPAIGN.md`; the per-worker
hypothesis lists were):
1. deposit-queue: instant vs queued, partial fills, capacity below supply, head/cancel bookkeeping, FIFO fairness, yield while queued, recipient edge cases, pause, fuzz, dust boundary.
2. redeem-queue: liquidity-limited fills (both constraints), **hypothesis: batch fill can revert because spUSDC `withdraw` ceil-rounds each burn so N fills need up to N-1 wei more spUSDC than `availableLiquidAssets` implies**, FIFO, yield while queued, fee interplay, recipient == vault stuck USDC, pause + take, rounding bounds, 200-entry queues.
3. cancel-fees: cancel permissions/ordering/partial fills, F-2 multi-depositor stuck case, fee ceil fuzz, fee economics (burned fee accrues to equity), minWithdraw gross vs net, ghost entries gas, donated shares stuck.
4. invariants: handler suite (users, admin, rebalancer, taker, spUSDC side, time) with invariants A..K: balance sums, `balanceOf(vault)==pendingRedeemShares`, pending == sum of open entries, head bookkeeping, no mint above capacity, chi/drip consistency, solvency when spUSDC rate ≥ prime rate, users never extract more than deposits + real yield, per-user balance provenance, backing exists somewhere, availableCapacity formula. `fail_on_revert=true` in foundry.toml, so handlers must never revert; configure runs/depth via `FOUNDRY_INVARIANT_RUNS/DEPTH`.
5. adversarial: rounding extraction round-trips, **instant-path jamming** (deposit capacity+1 wei then redeem to leave a 1-wei queue entry that disables instant fills for everyone), escrow confusion (recipient == vault), spUSDC donations, capacity races/fairness, permit/allowance, overflow at extremes, planner griefing with thousands of ghost entries, role mistakes, reentrancy (USDC has no hooks), compromised setter/risk-manager/rebalancer worst cases.
6. rounding: per-site direction proofs for R1..R12, round-trip bounds at 6 decimals, capacity chain, zero-mint region, drip drift vs python reference, fee ceil, minWithdraw boundaries, conversion symmetry bounds, rate-mismatch economics.
7. roles: full authorization matrix, role bounds under compromise, pause scope, admin setter validation gaps, revocation mid-flight, upgrade storage-layout check, taker.

## 6. How to resume

1. In each worktree: `git status`, `git log --oneline -3` (ensure commit d402570 "ugly indexes +
   patches" is present; if not, `git cherry-pick d402570`), run
   `forge test --match-path 'test/<File>.t.sol' -vv`, finish the file, commit, write
   `test/REPORT-<name>.md`.
2. Merge all `campaign/*` branches into `review/poc-tests` (they only add files; `CAMPAIGN.md`
   and harness are shared and unchanged). Run the whole suite:
   `forge test --no-match-contract ReviewTest` (local) and `forge test --match-contract ReviewTest`
   (fork). Long invariant run: `FOUNDRY_INVARIANT_RUNS=100 FOUNDRY_INVARIANT_DEPTH=1000 forge test --match-path 'test/invariants/*.t.sol'`.
3. Push: `git push -u fork review/poc-tests` (and the campaign branches if useful).
4. Write the final report `AUDIT-REPORT.md` in the repo root: executive summary with counts by
   severity and the top issues; scope and method; accounting model; findings (title, severity,
   location file:line, description, impact, PoC test name, recommendation); rounding table;
   invariants discovered (as a list reusable in their test suite, with the test that checks each);
   suggested code changes; open questions for the business team (the 10 in
   `REVIEW-2026-10-13.md` plus anything new). Post a phone-readable summary in the thread with the
   path and the fork link, then commit and push the report.

## 7. Things learned the hard way

- `vm.prank` is consumed by the next external call including a view used as an argument; cache first.
- Worktrees: git does not populate submodules; copy `lib/` from the main clone and delete the
  nested `.git` files, or `git status` breaks.
- Workers die on account usage limits; check `git status` in the worktrees and resume rather than
  restart.
- Never modify `~/hermes-console` (Mac mini remote-access lifeline). Work in `~/work`.
