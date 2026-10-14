// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test, console } from "../../../lib/forge-std/src/Test.sol";

import { SparkVault }      from "../lib/spusdc/SparkVault.sol";
import { SparkPrimeVault } from "../../../src/SparkPrimeVault.sol";

import { MockUSDC } from "../LocalTestBase.t.sol";

// Handler base for the spPRIME invariant campaign (round 4, `fix/update-guardian-transfer` @ bf93b0d).
// Holds the actors (read from the roles granted by `LocalTestBase`), N users, and the ghost bookkeeping
// every invariant reads.
//
// Conventions shared by every handler flow:
//   - every input is bounded and every action that would revert is skipped (fail_on_revert=true);
//   - `vm.startPrank`/`vm.stopPrank` only, never `vm.prank`;
//   - users are never the vault, the takers or any role holder;
//   - transfers never target the vault (invariant B relies on it; `vaultDonations` flags it);
//   - every recipient the handler passes (requests, cancels, recipient updates) is a user, so
//     every USDC payout and every share refund lands in the user set the invariants sum over.
contract Init is Test {

    uint256 constant RAY = 1e27;
    uint256 constant WAD = 1e18;

    uint256 constant ONE_PCT_VSR   = 1.000000000315522921573372069e27;
    uint256 constant FOUR_PCT_VSR  = 1.000000001243680656318820312e27;
    uint256 constant FIVE_PCT_VSR  = 1.000000001547125957863212448e27;
    uint256 constant TEN_PCT_VSR   = 1.000000003022265980097387650e27;
    uint256 constant FORTY_PCT_VSR = 1.000000010669464688489416886e27;
    uint256 constant MAX_VSR       = 1.000000021979553151239153027e27;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant GUARDIAN_ROLE      = keccak256("GUARDIAN_ROLE");
    bytes32 constant REBALANCER_ROLE    = keccak256("REBALANCER_ROLE");
    bytes32 constant RISK_MANAGER_ROLE  = keccak256("RISK_MANAGER_ROLE");
    bytes32 constant SETTER_ROLE        = keccak256("SETTER_ROLE");
    bytes32 constant TAKER_ROLE         = keccak256("TAKER_ROLE");

    uint256 constant MAX_DEPOSIT = 1_000_000_000e6;  // 1bn USDC per request

    MockUSDC        public usdc;
    SparkVault      public spUsdc;
    SparkPrimeVault public vault;

    // spPRIME actors
    address public admin;
    address public guardian;
    address public rebalancer;
    address public riskManager;
    address public setter;
    address public taker;

    // spUSDC actors
    address public spSetter;
    address public spTaker;

    /**********************************************************************************************/
    /*** Users                                                                                  ***/
    /**********************************************************************************************/

    uint256 public constant N = 6;

    address[N] public users;

    /**********************************************************************************************/
    /*** Ghost bookkeeping                                                                      ***/
    /**********************************************************************************************/

    // USDC level
    uint256 public totalUsdcMinted;        // every USDC wei ever minted by the handler
    uint256 public usersDepositedUsdc;     // USDC users pushed into requestDeposit
    uint256 public spUsdcYieldMinted;      // USDC minted straight into spUSDC (returned liquidity)
    uint256 public takerInjectedUsdc;      // USDC minted for the taker to mint spUSDC it returns

    // USDC paid to users, by source (invariant I). Users never hold USDC otherwise.
    uint256 public usersRedeemedUsdc;      // paid by processPendingRedeems fills
    uint256 public usersRefundedUsdc;      // paid by processPendingDepositCancellations fills

    mapping (address user => uint256) public depositedUsdc;

    // spUSDC level
    uint256 public takerOutstandingSpUsdc; // spUSDC taken by TAKER_ROLE and not yet returned
    uint256 public takerReturnedSpUsdc;

    // spPRIME share provenance per user (invariant J)
    mapping (address user => uint256) public ghostMinted;
    mapping (address user => uint256) public ghostTransferIn;
    mapping (address user => uint256) public ghostTransferOut;
    mapping (address user => uint256) public ghostEscrowed;    // requestRedeem, fee included

    // Invariant U: the vault's own share balance (redeem escrow) only ever falls inside
    // processPendingRedeems. The `counted` modifier compares the balance around every handler call.
    bool    public escrowFellOutsideRedeemFill;
    string  public escrowFellIn;
    uint256 public escrowDecreases;        // processPendingRedeems calls that lowered the escrow

    // Capacity / chi / fills
    bool    public mintedAboveCapacity;    // invariant F
    uint256 public lastChi;                // invariant G
    bool    public chiDecreasedOutsideLoss;// invariant G: chi fell in a non-realizeLoss action
    bool    public chiRoseOutsideWarpOrGain;// invariant G: chi rose in a non-warp, non-realizeGain action
    uint256 public lossRealizations;       // realizeLoss calls
    uint256 public realizedLossUsdc;       // sum of every `loss_` passed to realizeLoss
    uint256 public gainRealizations;       // realizeGain calls
    uint256 public realizedGainUsdc;       // sum of every `gain_` passed to realizeGain

    // Invariant T: |delta totalAssets - amount| per realizeGain / realizeLoss call.
    uint256 public maxGainLossError;       // largest error seen (must stay <= 1)
    uint256 public gainLossOutOfBound;     // calls whose error exceeded 1 wei

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

    // Queue ghosts (only the handler pushes entries)
    uint256 public depositQueueLength;
    uint256 public cancelledQueueLength;
    uint256 public redeemQueueLength;
    uint256 public ghostDepositEntries;    // F-5: zero-amount deposit requests
    uint256 public ghostRedeemEntries;     // F-5: zero-share or fee-eaten redeem requests

    // Recipient updates (invariants R and S)
    uint256 public recipientUpdates;                 // successful updates (always by the owner)
    bool    public recipientUpdateChangedState;      // anything but the recipient field moved
    uint256 public recipientUpdateStrangerAttempts;  // deliberate non-owner attempts
    uint256 public recipientUpdateStrangerReverts;   // ... that reverted with exactly not-authorized
    string  public lastStrangerUpdateRevert;

    // Guardian deposit cancels to a non-owner recipient (must revert `invalid-recipient`, bf93b0d);
    // asserted inline by the cancel handler, reported in afterInvariant().
    uint256 public guardianCancelProbes;
    uint256 public guardianCancelProbeReverts;
    string  public lastGuardianCancelProbe;

    // Revert observations (the handler wraps calls the contract itself may make revert)
    uint256 public redeemProcessReverts;       // "SparkVault/insufficient-balance"
    uint256 public redeemProcessRevertsOther;  // anything else (must stay 0)
    string  public lastRedeemProcessRevert;

    uint256 public cancelProcessReverts;       // any revert at all (must stay 0 since ff828d2)
    string  public lastCancelProcessRevert;

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

        admin       = vault.getRoleMember(DEFAULT_ADMIN_ROLE, 0);
        guardian    = vault.getRoleMember(GUARDIAN_ROLE,      0);
        rebalancer  = vault.getRoleMember(REBALANCER_ROLE,    0);
        riskManager = vault.getRoleMember(RISK_MANAGER_ROLE,  0);
        setter      = vault.getRoleMember(SETTER_ROLE,        0);
        taker       = vault.getRoleMember(TAKER_ROLE,         0);

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
        _;
        _chiCheck();
        _escrowCheck(name_, escrowBefore);
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

    // No handler moves time except `warp`, so nowChi() may only change inside the warp (up),
    // realizeGain (up) and realizeLoss (down) handlers, each of which resets `lastChi` itself.
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

    function getRandomUser(uint256 userIndex) internal view returns (address user) {
        return users[_bound(userIndex, 0, N - 1)];
    }

    function callNamesLength() external view returns (uint256) {
        return callNames.length;
    }

    // Snapshot of every user's share balance, used to attribute mints (invariant J).
    function _balances() internal view returns (uint256[N] memory bals) {
        for (uint256 i = 0; i < N; i++) bals[i] = vault.balanceOf(users[i]);
    }

    function _usersUsdc() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < N; i++) sum += usdc.balanceOf(users[i]);
    }

    // Mints land on whatever `recipient` each entry carries at fill time (anyone can repoint it
    // via updateDepositRecipient), so provenance is attributed by balance diff, not by request.
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

    function _countCancelledFills(uint256 head, uint256[] memory sharesBefore) internal {
        for (uint256 i = 0; i < sharesBefore.length; i++) {
            (, , uint256 s) = _cancelledDepositRequest(head + i);
            if (s < sharesBefore[i]) cancelledFills++;
        }
    }

    function _countRedeemFills(uint256 head, uint256[] memory sharesBefore) internal {
        for (uint256 i = 0; i < sharesBefore.length; i++) {
            (, , uint256 s) = _redeemRequest(head + i);
            if (s < sharesBefore[i]) redeemFills++;
        }
    }

    /**********************************************************************************************/
    /*** State digest (invariant R)                                                             ***/
    /**********************************************************************************************/

    // Hash of everything a recipient update must leave alone: totals, pendings, heads, every
    // share and USDC balance in the campaign, the vault's spUSDC, and the owner/shares of every
    // queue entry (recipients excluded on purpose).
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
            spUsdc.totalSupply(),
            usdc.balanceOf(address(spUsdc))
        ));
        for (uint256 i = 0; i < N; i++) {
            digest = keccak256(abi.encode(
                digest, vault.balanceOf(users[i]), usdc.balanceOf(users[i])
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

    function _depositQueueLength() internal view returns (uint256) {
        return vault.firstPendingDepositId() + vault.getPendingDepositRequests().length;
    }

    function _redeemQueueLength() internal view returns (uint256) {
        return vault.firstPendingRedeemId() + vault.getPendingRedeemRequests().length;
    }

    function _cancelledDepositQueueLength() internal view returns (uint256) {
        return vault.firstPendingDepositCancellationId() + vault.getPendingDepositCancellationRequests().length;
    }

}
