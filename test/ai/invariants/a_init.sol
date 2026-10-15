// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test, console } from "../../../lib/forge-std/src/Test.sol";

import { SparkVault }      from "../lib/spusdc/SparkVault.sol";
import { SparkPrimeVault } from "../../../src/SparkPrimeVault.sol";

import { MockUSDC } from "../LocalTestBase.t.sol";

// Handler base for the spPRIME invariant campaign (round 5, `master` @ 0ebb452).
// Holds the actors (read from the roles granted by `LocalTestBase`), N holders, and the ghost
// bookkeeping every invariant reads.
//
// Conventions shared by every handler flow:
//   - every input is bounded; an action that would revert is either skipped or *probed* through
//     try/catch against an explicit allow-list of expected revert reasons (fail_on_revert=true).
//     Anything outside the allow-list lands in `unexpectedReverts` (invariant AB asserts 0);
//   - `vm.startPrank`/`vm.stopPrank` only, never `vm.prank`;
//   - holders are never the vault, the takers or any role holder;
//   - `users[0..ACTIVE-1]` act (deposit, redeem, cancel, transfer, claim); `users[ACTIVE..N-1]`
//     are "fresh" addresses that only ever appear as recipients (of requests and of
//     `update*Recipient`), so every USDC payout, every claimable credit and every share mint
//     lands in the holder set the invariants sum over;
//   - any holder can be USDC-blacklisted / un-blacklisted at any time by the `setBlacklisted`
//     flow; payouts to a blacklisted recipient stay in the vault as `claimableAssets`.
contract Init is Test {

    uint256 constant RAY = 1e27;
    uint256 constant WAD = 1e18;

    uint256 constant ONE_PCT_VSR   = 1.000000000315522921573372069e27;
    uint256 constant FOUR_PCT_VSR  = 1.000000001243680656318820312e27;
    uint256 constant FIVE_PCT_VSR  = 1.000000001547125957863212448e27;
    uint256 constant TEN_PCT_VSR   = 1.000000003022265980097387650e27;
    uint256 constant FORTY_PCT_VSR = 1.000000010669464688489416886e27;
    uint256 constant MAX_VSR       = 1.000000021979553151239153027e27;

    bytes32 constant DEFAULT_ADMIN_ROLE     = 0x00;
    bytes32 constant GUARDIAN_ROLE          = keccak256("GUARDIAN_ROLE");
    bytes32 constant REBALANCER_ROLE        = keccak256("REBALANCER_ROLE");
    bytes32 constant REDEEM_FEE_SETTER_ROLE = keccak256("REDEEM_FEE_SETTER_ROLE");
    bytes32 constant VSR_SETTER_ROLE        = keccak256("VSR_SETTER_ROLE");
    bytes32 constant SETTER_ROLE            = keccak256("SETTER_ROLE");  // spUSDC
    bytes32 constant TAKER_ROLE             = keccak256("TAKER_ROLE");

    uint256 constant MAX_DEPOSIT = 1_000_000_000e6;  // 1bn USDC per request

    string constant BLACKLISTED = "Blacklistable: account is blacklisted";

    MockUSDC        public usdc;
    SparkVault      public spUsdc;
    SparkPrimeVault public vault;

    // spPRIME actors
    address public admin;
    address public guardian;
    address public rebalancer;
    address public redeemFeeSetter;
    address public vsrSetter;
    address public taker;

    // spUSDC actors
    address public spSetter;
    address public spTaker;

    /**********************************************************************************************/
    /*** Holders                                                                                ***/
    /**********************************************************************************************/

    uint256 public constant N      = 8;  // every holder the invariants sum over
    uint256 public constant ACTIVE = 6;  // users[0..5] act, users[6..7] only ever receive

    address[N] public users;

    /**********************************************************************************************/
    /*** Ghost bookkeeping                                                                      ***/
    /**********************************************************************************************/

    // USDC level
    uint256 public totalUsdcMinted;        // every USDC wei ever minted by the handler
    uint256 public usersDepositedUsdc;     // USDC users pushed into requestDeposit
    uint256 public spUsdcYieldMinted;      // USDC minted straight into spUSDC (returned liquidity)
    uint256 public takerInjectedUsdc;      // USDC minted for the taker to mint spUSDC it returns

    // USDC paid out by fills, by source (invariant I). A fill pays the recipient directly or, when
    // the recipient is blacklisted, parks the USDC in the vault as `claimableAssets`; both count.
    uint256 public usersRedeemedUsdc;      // paid by processPendingRedeems fills
    uint256 public usersRefundedUsdc;      // paid by processPendingDepositCancellations fills
    uint256 public claimableCreditedUsdc;  // the part of the above that went to claimableAssets
    uint256 public usersClaimedUsdc;       // moved vault -> recipient by claim()

    mapping (address user => uint256) public depositedUsdc;

    // spUSDC level
    uint256 public takerOutstandingSpUsdc; // spUSDC taken by TAKER_ROLE and not yet returned
    uint256 public takerReturnedSpUsdc;
    bool    public takeCalled;             // invariant W: backing gap is only allowed after take()
    uint256 public takes;
    uint256 public maxBackingGapSpUsdc;    // max(pendingDeposit + pendingCancelled - held) seen

    // spPRIME share provenance per holder (invariant J)
    mapping (address user => uint256) public ghostMinted;
    mapping (address user => uint256) public ghostTransferIn;
    mapping (address user => uint256) public ghostTransferOut;
    mapping (address user => uint256) public ghostEscrowed;    // requestRedeem, fee included

    // Invariant U: the vault's own share balance (redeem escrow) only ever falls inside
    // processPendingRedeems. The `counted` modifier compares the balance around every handler call.
    bool    public escrowFellOutsideRedeemFill;
    string  public escrowFellIn;
    uint256 public escrowDecreases;        // processPendingRedeems calls that lowered the escrow

    // Invariant V: queue heads never move backwards (compared around every handler call).
    bool    public headMovedBackwards;
    string  public headMovedBackwardsIn;

    // Capacity (invariants F and X)
    bool    public mintedAboveCapacity;          // F: a mint pushed totalSupply above maxCapacity
    bool    public capacityLoweredBelowSupply;   // X: setCapacity(cap < totalSupply) happened
    uint256 public capacityBelowSupplyEvents;

    // chi (invariant G)
    uint256 public lastChi;
    bool    public chiDecreasedOutsideLoss;      // chi fell outside a negative adjustTotalAssets
    bool    public chiRoseOutsideWarpOrGain;     // chi rose outside warp / positive adjustTotalAssets

    // adjustTotalAssets (invariants T and H)
    uint256 public adjustNegatives;        // adjustTotalAssets(delta < 0) calls
    uint256 public adjustedLossUsdc;       // sum of |delta| over negative calls
    uint256 public adjustPositives;        // adjustTotalAssets(delta > 0) calls
    uint256 public adjustedGainUsdc;       // sum of delta over positive calls
    uint256 public maxGainLossError;       // largest |delta totalAssets - amount| seen (<= 1)
    uint256 public gainLossOutOfBound;     // calls whose error exceeded 1 wei
    uint256 public adjustNotPausedProbes;  // probes of the `not-paused` guard
    uint256 public adjustZeroSupplyProbes; // probes of the totalSupply == 0 division
    uint256 public adjustZeroSupplyPanics; // ... that panicked with 0x12 (division by zero)

    // Invariant H: upper bound (USDC) on the notional deficit `totalAssets() - real backing`
    // created by fictitious gains (+) and losses (-). Scaled on every warp: by spUSDC's index
    // while positive, by spPRIME's index while negative (both are upper bounds while the spUSDC
    // rate is >= the spPRIME rate, see invariant H).
    int256  public ghostDeficitUsdc;
    uint256 public depositFills;           // entries touched by a deposit fill (incl. partial)
    uint256 public cancelledFills;         // entries touched by a cancelled-deposit fill
    uint256 public redeemFills;            // entries touched by a redeem fill (incl. partial)
    uint256 public zeroShareFills;         // F-4: spUSDC consumed, 0 shares minted
    bool    public rateOrderBroken;        // spUSDC VSR < spPRIME VSR at some point (invariant H)
    bool    public vaultDonations;         // spPRIME transferred to the vault itself (never set)

    // Invariant Y: payouts are exactly the converted amounts. `paid` is users' USDC delta plus the
    // vault's USDC delta (claimable credits) per processing call; `expected` is the per-entry
    // floor conversion of the consumed shares, summed. The excess must be 0; the max is kept.
    uint256 public redeemPayoutMaxExcess;
    uint256 public redeemPayoutMismatches;   // calls where paid != expected
    uint256 public cancelPayoutMaxExcess;
    uint256 public cancelPayoutMismatches;

    // Queue ghosts (only the handler pushes entries)
    uint256 public depositQueueLength;
    uint256 public cancelledQueueLength;
    uint256 public redeemQueueLength;
    uint256 public ghostDepositEntries;    // F-5: zero-amount deposit requests
    uint256 public ghostRedeemEntries;     // F-5: zero-share or fee-eaten redeem requests

    // Recipient updates (invariants R and S)
    uint256 public recipientUpdates;                 // successful updates (always by the owner)
    uint256 public recipientUpdatesToBlacklisted;    // deposit-queue updates to a blacklisted recipient (allowed)
    uint256 public recipientUpdatesToFresh;          // updates to users[ACTIVE..N-1]
    bool    public recipientUpdateChangedState;      // anything but the recipient field moved
    uint256 public recipientUpdateStrangerAttempts;  // deliberate non-owner attempts
    uint256 public recipientUpdateStrangerReverts;   // ... that reverted with exactly not-authorized
    string  public lastStrangerUpdateRevert;

    // Blacklist (invariant AA and the recipient guards)
    uint256 public blacklistSets;
    uint256 public blacklistClears;
    uint256 public blacklistRecipientProbes;         // request / update with a blacklisted recipient
    uint256 public blacklistRecipientProbeReverts;   // ... that reverted `recipient-cannot-receive`
    string  public lastBlacklistProbeRevert;
    uint256 public skippedBlacklistedDepositors;     // requestDeposit skipped (USDC pull would revert)
    uint256 public fillsToBlacklisted;               // fills whose USDC went to claimableAssets

    // claim (invariant AA)
    uint256 public claims;                           // successful claims
    uint256 public claimNothingProbes;               // claim(x) with claimableAssets[x] == 0
    uint256 public claimNothingProbeReverts;         // ... that reverted `nothing-to-claim`
    uint256 public claimWhileBlacklistedAttempts;
    uint256 public claimWhileBlacklistedReverts;     // ... that reverted in USDC with BLACKLISTED
    bool    public claimPaidWhileBlacklisted;        // must stay false
    bool    public claimChangedStateWhileBlacklisted;// must stay false

    // Revert observations (the handler wraps calls the contract itself may make revert)
    uint256 public redeemProcessReverts;       // "SparkVault/insufficient-balance" (C-1)
    uint256 public redeemProcessRevertsOther;  // anything else (must stay 0)
    string  public lastRedeemProcessRevert;

    uint256 public cancelProcessReverts;       // any revert at all (must stay 0)
    string  public lastCancelProcessRevert;

    // Every revert the handler caught, by reason, plus the ones outside the allow-list (AB).
    mapping (string reason => uint256) public revertsByReason;
    string[] public revertReasons;
    uint256  public unexpectedReverts;
    string   public lastUnexpectedRevert;

    // Call counts per handler function
    mapping (string fn => uint256) public calls;

    string[] public callNames;

    /**********************************************************************************************/
    /*** Setup                                                                                  ***/
    /**********************************************************************************************/

    constructor(address vault_) {
        vault  = SparkPrimeVault(vault_);
        spUsdc = SparkVault(vault.savings());
        usdc   = MockUSDC(spUsdc.asset());

        admin           = vault.getRoleMember(DEFAULT_ADMIN_ROLE,     0);
        guardian        = vault.getRoleMember(GUARDIAN_ROLE,          0);
        rebalancer      = vault.getRoleMember(REBALANCER_ROLE,        0);
        redeemFeeSetter = vault.getRoleMember(REDEEM_FEE_SETTER_ROLE, 0);
        vsrSetter       = vault.getRoleMember(VSR_SETTER_ROLE,        0);
        taker           = vault.getRoleMember(TAKER_ROLE,             0);

        spSetter = spUsdc.getRoleMember(SETTER_ROLE, 0);
        spTaker  = spUsdc.getRoleMember(TAKER_ROLE,  0);

        for (uint256 i = 0; i < N; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", vm.toString(i))));
        }

        lastChi = vault.nowChi();
    }

    /**********************************************************************************************/
    /*** Shared helpers                                                                         ***/
    /**********************************************************************************************/

    modifier counted(string memory name_) {
        if (calls[name_] == 0) callNames.push(name_);
        calls[name_]++;
        uint256 escrowBefore = vault.balanceOf(address(vault));
        uint256[3] memory headsBefore = _heads();
        _;
        _chiCheck();
        _escrowCheck(name_, escrowBefore);
        _headCheck(name_, headsBefore);
        _backingGapCheck();
    }

    function _heads() internal view returns (uint256[3] memory h) {
        h[0] = vault.firstPendingDepositId();
        h[1] = vault.firstPendingDepositCancellationId();
        h[2] = vault.firstPendingRedeemId();
    }

    // Invariant U bookkeeping: `balanceOf(vault)` may only decrease inside processPendingRedeems
    // (requestRedeem moves `shares` in and burns `fee <= shares` out of it, a net increase).
    function _escrowCheck(string memory name_, uint256 escrowBefore) internal {
        uint256 escrowAfter = vault.balanceOf(address(vault));
        if (escrowAfter >= escrowBefore) return;
        if (keccak256(bytes(name_)) == keccak256("processPendingRedeems")) {
            escrowDecreases++;
            return;
        }
        escrowFellOutsideRedeemFill = true;
        escrowFellIn                = name_;
    }

    // Invariant V bookkeeping: no head ever moves backwards.
    function _headCheck(string memory name_, uint256[3] memory before) internal {
        uint256[3] memory after_ = _heads();
        for (uint256 i = 0; i < 3; i++) {
            if (after_[i] < before[i]) {
                headMovedBackwards   = true;
                headMovedBackwardsIn = name_;
            }
        }
    }

    // Invariant W bookkeeping: the largest shortfall of the vault's spUSDC against what the two
    // spUSDC-denominated queues are owed, observed after any handler call.
    function _backingGapCheck() internal {
        uint256 owed = vault.pendingDepositSavingsShares() + vault.pendingCancelledDepositSavingsShares();
        uint256 held = spUsdc.balanceOf(address(vault));
        if (owed > held && owed - held > maxBackingGapSpUsdc) maxBackingGapSpUsdc = owed - held;
    }

    // No handler moves time except `warp`, so nowChi() may only change inside the warp (up) and
    // adjustTotalAssets (up or down) handlers, each of which resets `lastChi` itself.
    function _chiCheck() internal {
        uint256 nowChi_ = vault.nowChi();
        if (nowChi_ < lastChi) chiDecreasedOutsideLoss  = true;
        if (nowChi_ > lastChi) chiRoseOutsideWarpOrGain = true;
        lastChi = nowChi_;
    }

    // Invariant T bookkeeping: `after` must be `before +/- amount` within 1 wei.
    function _recordGainLossError(uint256 before, uint256 after_, uint256 amount, bool gain) internal {
        uint256 expected = gain ? before + amount : before - amount;
        uint256 err      = after_ > expected ? after_ - expected : expected - after_;
        if (err > maxGainLossError) maxGainLossError = err;
        if (err > 1) gainLossOutOfBound++;
    }

    // Scales the deficit ledger by `after_ / before` (indexes), rounding so the result stays an
    // upper bound: up when positive, towards zero when negative.
    function _scaleDeficit(uint256 before, uint256 after_) internal {
        if (ghostDeficitUsdc == 0 || before == after_) return;
        if (ghostDeficitUsdc > 0) {
            uint256 d = uint256(ghostDeficitUsdc);
            ghostDeficitUsdc = int256((d * after_ + before - 1) / before);
        } else {
            uint256 d = uint256(-ghostDeficitUsdc);
            ghostDeficitUsdc = -int256((d * after_) / before);
        }
    }

    // Revert classification: every caught revert is recorded by reason; the caller says whether
    // the reason was on its allow-list. Returns true when it was.
    function _recordRevert(string memory reason, bool expected) internal returns (bool) {
        if (revertsByReason[reason] == 0) revertReasons.push(reason);
        revertsByReason[reason]++;
        if (!expected) {
            unexpectedReverts++;
            lastUnexpectedRevert = reason;
        }
        return expected;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function getRandomUser(uint256 userIndex) internal view returns (address user) {
        return users[_bound(userIndex, 0, ACTIVE - 1)];
    }

    // Any holder, including the fresh ones.
    function getRandomHolder(uint256 index) internal view returns (address holder) {
        return users[_bound(index, 0, N - 1)];
    }

    function callNamesLength() external view returns (uint256) {
        return callNames.length;
    }

    function revertReasonsLength() external view returns (uint256) {
        return revertReasons.length;
    }

    // Snapshot of every holder's share balance, used to attribute mints (invariant J).
    function _balances() internal view returns (uint256[N] memory bals) {
        for (uint256 i = 0; i < N; i++) bals[i] = vault.balanceOf(users[i]);
    }

    function _usersUsdc() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < N; i++) sum += usdc.balanceOf(users[i]);
    }

    function _usersClaimable() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < N; i++) sum += vault.claimableAssets(users[i]);
    }

    // Mints land on whatever `recipient` each entry carries at fill time (the owner can repoint
    // it), so provenance is attributed by balance diff, not by request.
    function _attributeMints(uint256[N] memory before) internal {
        for (uint256 i = 0; i < N; i++) {
            uint256 after_ = vault.balanceOf(users[i]);
            assertGe(after_, before[i], "handler: balance fell during a mint-only action");
            ghostMinted[users[i]] += after_ - before[i];
        }
    }

    // Records whether a mint-only action pushed totalSupply above maxCapacity (invariant F).
    function _capacityCheck(uint256 supplyBefore) internal {
        uint256 supplyAfter = vault.totalSupply();
        if (supplyAfter > supplyBefore && supplyAfter > vault.maxCapacity()) {
            mintedAboveCapacity = true;
        }
    }

    /**********************************************************************************************/
    /*** Queue snapshots (fill counting)                                                        ***/
    /**********************************************************************************************/

    function _snapshotDepositQueue(uint256 head) internal view returns (uint256[] memory shares) {
        shares = new uint256[](depositQueueLength - head);
        for (uint256 i = head; i < depositQueueLength; i++) {
            (, , shares[i - head]) = _depositRequest(i);
        }
    }

    function _snapshotCancelledQueue(uint256 head) internal view returns (uint256[] memory shares) {
        shares = new uint256[](cancelledQueueLength - head);
        for (uint256 i = head; i < cancelledQueueLength; i++) {
            (, , shares[i - head]) = _cancelledDepositRequest(i);
        }
    }

    function _snapshotRedeemQueue(uint256 head) internal view returns (uint256[] memory shares) {
        shares = new uint256[](redeemQueueLength - head);
        for (uint256 i = head; i < redeemQueueLength; i++) {
            (, , shares[i - head]) = _redeemRequest(i);
        }
    }

    // Counts deposit-queue entries whose `shares` shrank, and zero-share fills (F-4). Only entries
    // in `sharesBefore` (those that existed at the snapshot) are compared.
    function _countDepositFills(
        uint256 head,
        uint256[] memory sharesBefore,
        uint256 supplyBefore
    ) internal {
        uint256 minted = vault.totalSupply() - supplyBefore;
        uint256 consumed;
        uint256 lastConsumed;
        for (uint256 i = 0; i < sharesBefore.length; i++) {
            (, , uint256 s) = _depositRequest(head + i);
            if (s < sharesBefore[i]) {
                depositFills++;
                lastConsumed = sharesBefore[i] - s;
                consumed    += lastConsumed;
            }
        }
        if (consumed == 0) return;
        if (minted == 0) { zeroShareFills++; return; }
        // Only the last touched entry can be a dust fill (remaining_ is exhausted on it).
        if (vault.convertToShares(spUsdc.convertToAssets(lastConsumed)) == 0) zeroShareFills++;
    }

    // Counts cancelled-deposit fills and returns the exact USDC the fills must have paid: each
    // entry is paid `spUSDC.redeem(consumed)` = floor(consumed * chi_s / RAY).
    function _countCancelledFills(uint256 head, uint256[] memory sharesBefore)
        internal returns (uint256 expectedPaid)
    {
        for (uint256 i = 0; i < sharesBefore.length; i++) {
            (, , uint256 s) = _cancelledDepositRequest(head + i);
            if (s < sharesBefore[i]) {
                cancelledFills++;
                expectedPaid += spUsdc.convertToAssets(sharesBefore[i] - s);
            }
        }
    }

    // Counts redeem fills and returns the exact USDC the fills must have paid: each entry is paid
    // `convertToAssets(consumed)` = floor(consumed * chi / RAY).
    function _countRedeemFills(uint256 head, uint256[] memory sharesBefore)
        internal returns (uint256 expectedPaid)
    {
        for (uint256 i = 0; i < sharesBefore.length; i++) {
            (, , uint256 s) = _redeemRequest(head + i);
            if (s < sharesBefore[i]) {
                redeemFills++;
                expectedPaid += vault.convertToAssets(sharesBefore[i] - s);
            }
        }
    }

    /**********************************************************************************************/
    /*** State digest (invariant R)                                                             ***/
    /**********************************************************************************************/

    // Hash of everything a recipient update must leave alone: totals, pendings, heads, every
    // share, USDC and claimable balance in the campaign, the vault's spUSDC and USDC, and the
    // owner/shares of every queue entry (recipients excluded on purpose).
    function _stateDigest() internal view returns (bytes32 digest) {
        digest = keccak256(abi.encode(
            vault.totalSupply(),
            vault.pendingDepositSavingsShares(),
            vault.pendingCancelledDepositSavingsShares(),
            vault.pendingRedeemShares(),
            vault.firstPendingDepositId(),
            vault.firstPendingDepositCancellationId(),
            vault.firstPendingRedeemId(),
            vault.chi(),
            vault.rho(),
            vault.balanceOf(address(vault)),
            spUsdc.balanceOf(address(vault)),
            usdc.balanceOf(address(vault)),
            spUsdc.totalSupply(),
            usdc.balanceOf(address(spUsdc))
        ));
        for (uint256 i = 0; i < N; i++) {
            digest = keccak256(abi.encode(
                digest, vault.balanceOf(users[i]), usdc.balanceOf(users[i]), vault.claimableAssets(users[i])
            ));
        }
        for (uint256 i = 0; i < depositQueueLength; i++) {
            (address owner, , uint256 shares) = _depositRequest(i);
            digest = keccak256(abi.encode(digest, owner, shares));
        }
        for (uint256 i = 0; i < cancelledQueueLength; i++) {
            (address owner, , uint256 shares) = _cancelledDepositRequest(i);
            digest = keccak256(abi.encode(digest, owner, shares));
        }
        for (uint256 i = 0; i < redeemQueueLength; i++) {
            (address owner, , uint256 shares) = _redeemRequest(i);
            digest = keccak256(abi.encode(digest, owner, shares));
        }
    }

    function _depositRequest(uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        SparkPrimeVault.Request[] memory r = vault.getPendingDepositRequests(id, id + 1);
        return (r[0].owner, r[0].recipient, r[0].shares);
    }

    function _redeemRequest(uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        SparkPrimeVault.Request[] memory r = vault.getPendingRedeemRequests(id, id + 1);
        return (r[0].owner, r[0].recipient, r[0].shares);
    }

    function _cancelledDepositRequest(uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        SparkPrimeVault.Request[] memory r = vault.getPendingDepositCancellationRequests(id, id + 1);
        return (r[0].owner, r[0].recipient, r[0].shares);
    }

}
