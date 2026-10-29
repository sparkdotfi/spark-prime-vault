# Deposit-queue griefing vectors

Status: **known and accepted**. This document describes the ways a depositor can make the
deposit queue expensive to walk, measures what each costs the attacker, the affected users
and the operator, and explains why the vault keeps atomic processing in the request
functions rather than mitigating these vectors in code.

Reported as Pashov L-01 (tombstone run), Pashov I-17 (cancellation-queue fragmentation),
ChainSecurity #002 / OQ2 (dust can enter the queues) and Certora's "gas griefing" attack
vector. All numbers below are produced by `test/DepositQueueGriefing.t.sol` on the mainnet
fork pinned in `test/TestBase.t.sol`, with access lists reset before every measured call so
that storage reads are cold, as they are for a real transaction. Rerun that file and refresh
this document when `SparkPrimeVault.sol` changes.

---

## 1. Background: how the deposit queue is walked

`_depositRequests` is an append-only array. A request that is cancelled in full is deleted
in place and becomes a zero-share tombstone. `_processPendingDeposits(maxSavingsShares,
maxRequests)` walks from `firstPendingDepositId`, skips tombstones, and stops at the first
live entry it cannot fill. Three callers walk the queue:

| Caller | Budget | `maxRequests` | Pause-gated |
|---|---|---|---|
| `processPendingDeposits` (OPERATOR_ROLE) | caller's choice | caller's choice | yes |
| instant fill at the end of `requestDeposit`, only when nothing live is queued ahead | unlimited | unlimited | yes (via `requestDeposit`) |
| cleanup at the end of `requestDepositCancellation` | zero (skip tombstones only) | unlimited | no |

The two automatic walks are what make small deposits atomic for users and keep the
operator from having to process every request by hand. They are also what the vectors
below target.

---

## 2. Vector A: tombstone run behind a live head

### Mechanics

1. The vault is at capacity, so new deposits queue instead of filling. Some live request
   sits at the head of the queue. It can be the attacker's own, or anyone else's, or a dust
   remainder that its owner cannot cancel because it is below `minDepositCancellation`.
2. The attacker repeats: `requestDeposit` of the smallest cancellable amount, then
   `requestDepositCancellation` of the whole request. Each pair leaves one tombstone behind
   the head. The cleanup at the end of the cancellation starts at the head, finds it live
   with no budget to fill it, and stops immediately, so it never reaches the tombstones.
3. Later, capacity opens and the operator fills the head. `firstPendingDepositId` now
   points at the run of tombstones.
4. Until the run is cleared, any transaction that walks the queue without a bound pays the
   full run: every `requestDepositCancellation` by any depositor queued behind it, and
   every instant fill in `requestDeposit`. Past roughly 7,600 tombstones that exceeds the
   per-transaction gas cap and those calls revert out of gas.

The operator clears the run with `processPendingDeposits(0, n)` in batches. That function
is `whenNotPaused`; see section 5 for the pause interaction.

### Measured costs

| Quantity | Measured | Notes |
|---|---|---|
| Smallest cancellable deposit | 103.713650 USDC | `convertToAssets(minDepositCancellation) + 1` at the pinned block, with both minimums at 100 |
| Attacker gas per tombstone | 273,214 | one `requestDeposit` (queued) plus one full `requestDepositCancellation`, cold |
| Victim gas per tombstone skipped in `requestDepositCancellation` | 2,191 | cold `SLOAD` of `shares` plus loop overhead |
| New depositor gas per tombstone skipped in the instant fill | 2,390 | |
| Operator gas per tombstone cleared, `processPendingDeposits(0, 200)` | 2,527 | includes fixed overhead of a drip and two spUSDC view calls |
| Operator gas per tombstone cleared, batches of 1,000 | 2,419 | |
| Tombstones to exceed the 16,777,216 gas transaction cap (EIP-7825) | ~7,600 | victim cancellation with no run costs 148,536 |

### End-to-end scenario

`test_griefing_unboundedWalkExceedsTxGasCap` calibrates the per-tombstone cost, builds a
run just past the cap, and checks the whole lifecycle:

| Step | Result |
|---|---|
| Tombstones built | 7,789 |
| Attacker gas, total | 2,126,891,104 (about 15,600 transactions' worth of the 136k average, or 127 transactions at the cap) |
| Capital cycled through the cancellation queue | 807,826 USDC |
| Victim `requestDepositCancellation` at the cap | reverts out of gas |
| New `requestDeposit` while a live victim entry exists | queued, not reverted (the live entry disables the instant fill) |
| Same while paused | operator processing reverts `IsPaused`; victim cancellation still reverts out of gas |
| Operator clearing after unpause, batches of 1,000 | 8 transactions, 18,839,168 gas total |
| Victim cancellation afterwards | succeeds |

### Economics

ETH at $2,400. Mainnet base fee was about 0.3 gwei when this was written; the other columns
are stress cases.

| Party and cost | Gas | 0.3 gwei | 1 gwei | 5 gwei | 20 gwei |
|---|---|---|---|---|---|
| Attacker: build the run | 2,127M | $1,530 | $5,100 | $25,500 | $102,000 |
| Operator: clear the run | 18.8M | $14 | $45 | $226 | $904 |
| Operator: process the attacker's 7,789 cancellations | 219M | $157 | $525 | $2,630 | $10,500 |

The attacker spends about 113 times the gas the operator needs to clear the run, and about
9 times the operator's total including refunding the attacker's own cancellations. The
cancellation refunds are routine operator work that would happen for honest users too, and
the operator chooses when to perform them.

Capital: 807,826 USDC passes through the cancellation queue. It is refunded in full, with
the spUSDC yield earned while queued, so the attacker's capital cost is time value only.
How much has to be held at once depends on how quickly the operator processes
cancellations. If the operator refunds promptly the attacker recycles a small float; if the
operator delays, the attacker must fund the whole amount upfront and it sits idle in the
cancellation queue, exposed to the same liquidity risk as any pending request (see the
README on funds of unprocessed requests not being reserved).

### Impact

- No funds are at risk. Tombstones hold no value and no accounting changes.
- While the run is at the front: depositors queued behind it cannot cancel, and new
  deposits are queued instead of instantly filled. Both resume once the operator has
  cleared the run.
- Clearing takes 8 transactions at the transaction cap, which a keeper can land within a
  few blocks. The operator's cost is tens of dollars at current gas prices.
- The attack can be repeated whenever capacity is full again, at the same cost each time.
- The attack is visible while it is being built: thousands of small deposit and
  cancellation requests from one address, and the cancellation queue growing by the same
  count. Section 6 covers monitoring.

### Why this is accepted

The attacker pays two orders of magnitude more gas than the defender, locks up roughly
eight hundred thousand dollars to do it, gains nothing, and achieves a delay measured in
blocks for a subset of depositors. Removing the automatic walks would push every deposit,
however small, onto the operator, which is a worse outcome for every honest user every
day. Bounding the automatic walks (sibling PR) or changing the queue data structure
(sibling PR) are both viable and were evaluated alongside this document; the choice between
them and this acknowledgement is a product decision recorded on those PRs.

---

## 3. Vector B: cancellation-queue fragmentation

### Mechanics

A depositor with a pending request of `S` savings shares can call
`requestDepositCancellation` repeatedly for `minDepositCancellation` shares each time,
creating up to `S / minDepositCancellation` entries in the cancellation queue, all of which
are processed before later users' cancellations. Each entry costs the operator one spUSDC
redeem when processed.

### Measured costs

| Quantity | Measured |
|---|---|
| Attacker gas per cancellation entry | 108,857 |
| Operator gas per processed entry | 28,092 |

The attacker pays about 4 times the operator's cost per entry and must have the capital
queued as a pending deposit first (100 spUSDC shares per entry). Later cancellations are
delayed by however many entries the operator processes per transaction, not blocked. The
operator bounds the work with `maxRequests` and can process the queue as fast as liquidity
allows.

### Why this is accepted

`minDepositCancellation` prices this vector directly and is a governance parameter.
Aggregating repeated cancellations of one deposit into a single entry would change the
FIFO semantics (a top-up would inherit an earlier position) for a griefing vector that costs
the attacker more than the defender and is fully collateralised.

---

## 4. Vector C: dust head

A partial cancellation can leave a remainder below `minDepositCancellation` at the head of
the deposit queue. Its owner cannot cancel it. While capacity is zero it cannot be filled,
so it disables instant fills for everyone behind it and, combined with vector A, is the
cheapest live head to shield a tombstone run.

The remainder is filled by the operator as soon as capacity allows, which removes it. It is
otherwise harmless: it costs the attacker a locked deposit of at least `minDeposit` and
earns the vault the rounding. A request-time check that the remainder is either zero or at
least `minDepositCancellation` is a separate, cheap hardening tracked with the other
minimum-size fixes.

---

## 5. Interaction with pausing

Deposit cancellations are deliberately allowed while the vault is paused, so that pending
depositors keep an exit during an incident. `processPendingDeposits` is not. If a tombstone
run reaches the front of the queue and the vault is then paused, depositors behind the run
cannot cancel until the vault is unpaused and the operator has cleared the run.

The operator can avoid this window by clearing any run before pausing (the run is visible
on-chain, see below), and a pause is expected to be short. This is the one residual effect
of vector A that is not purely a gas cost, and it is the main argument for the bounded-walk
alternative.

---

## 6. Monitoring and operator runbook

Detect a growing run:

- `getPendingDepositRequests()` returns every entry from `firstPendingDepositId` to the end
  of the array, tombstones included. The number of entries with `shares == 0` is the current
  tombstone count. A count in the thousands, or growing by hundreds per hour, is the attack
  in progress.
- `DepositRequest` followed by `DepositCancellationRequest` for the same request id from
  the same owner, repeated, is the attacker's signature.

Clear it:

- `processPendingDeposits(0, 1000)` repeatedly until `firstPendingDepositId` reaches the
  first live entry. Each call costs about 2.4M gas. A zero savings-share budget skips
  tombstones without filling anything, so it is safe to run at any capacity.
- Do this before pausing if a run exists.

Price it:

- Raising `minDepositCancellation` raises the per-tombstone capital linearly. At 1,000
  spUSDC shares the run in section 2 would need about 8 million USDC in flight.

---

## 7. Alternatives evaluated

| Option | Effect on vector A | Cost | Where |
|---|---|---|---|
| Keep as is, document (this PR) | none; operator clears | none | this document |
| Admin-set bound on the automatic walks | cancellations never revert; instant fill becomes best-effort when a run is longer than the bound | one storage slot, one setter, small behaviour change | sibling PR |
| Linked-list deposit queue | no tombstones to walk; cancellation unlinks in O(1) | two extra slots per request, larger diff, getters change | sibling PR |
| Remove the automatic walks | vector disappears | every deposit needs operator processing | rejected |
