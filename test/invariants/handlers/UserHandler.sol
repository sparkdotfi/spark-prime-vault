// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ISparkPrimeVault } from "../../../src/ISparkPrimeVault.sol";

import { HandlerBase } from "./HandlerBase.sol";

contract UserHandler is HandlerBase {

    // Ghost variables tracking every user-driven flow.
    uint256 public ghostDepositedAssets;         // USDC pulled in by requestDeposit
    uint256 public ghostSavingsSharesIn;         // spUSDC minted to the vault by requestDeposit
    uint256 public ghostFeesBurned;              // vault shares burned as redeem fees
    uint256 public ghostMintedTotal;             // vault shares minted by every fill
    uint256 public ghostClaimedTotal;            // USDC moved vault -> recipient by claim
    uint256 public ghostClaimableCreditedTotal;  // USDC parked in the vault for recipients

    mapping (address user => uint256) public ghostMinted;             // shares minted to user
    mapping (address user => uint256) public ghostTransferIn;
    mapping (address user => uint256) public ghostTransferOut;
    mapping (address user => uint256) public ghostEscrowed;           // shares sent to requestRedeem, fee included
    mapping (address user => uint256) public ghostPaidDirect;         // USDC paid straight to user by fills
    mapping (address user => uint256) public ghostClaimableCredited;  // USDC credited to claimableAssets[user]
    mapping (address user => uint256) public ghostClaimed;            // USDC claimed by user
    mapping (address user => uint256) public lastAssetsOf;            // last value after a sanctioned decrease

    mapping (address user => bool)    public isBlacklisted;
    mapping (address user => uint256) public userIndexPlusOne;

    // Queue mirrors: only the handlers push entries.
    uint256 public depositQueueLength;
    uint256 public cancelQueueLength;
    uint256 public redeemQueueLength;

    mapping (uint256 id => address) public depositOwner;
    mapping (uint256 id => address) public depositRecipient;
    mapping (uint256 id => address) public cancelOwner;
    mapping (uint256 id => address) public cancelRecipient;
    mapping (uint256 id => address) public redeemOwner;
    mapping (uint256 id => address) public redeemRecipient;

    constructor(address spPrime_, uint256 numUsers_) HandlerBase(spPrime_) {
        for (uint256 i = 0; i < numUsers_; i++) {
            address user_ = makeAddr(string(abi.encodePacked("user", vm.toString(i))));

            users.push(user_);
            userIndexPlusOne[user_] = i + 1;
        }
    }

    /**********************************************************************************************/
    /*** Fuzzed actions                                                                         ***/
    /**********************************************************************************************/

    struct DepositState {
        address user;
        address recipient;
        uint256 assets;
        uint256 requestId;
        uint256 pendingBefore;
        uint256 capacityBefore;
        uint256 supplyBefore;
        uint256 savingsBefore;
        uint256 recipientBefore;
    }

    function requestDeposit(uint256 assets_, uint256 userSeed_, uint256 recipientSeed_, uint16 referral_)
        public
        checked(CHECK_ALL & ~CHECK_SUPPLY_UNCHANGED)
    {
        DepositState memory s_;

        s_.user      = _randomUser(userSeed_);
        s_.recipient = _randomUser(recipientSeed_);

        uint256 minDeposit_ = spPrime.minDeposit();

        if (spPrime.paused()) {
            vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
            vm.prank(s_.user);
            spPrime.requestDeposit(minDeposit_, s_.recipient, referral_);
            return;
        }

        if (isBlacklisted[s_.user]) return;  // USDC approve / transferFrom would revert

        uint256 maxDeposit_ = _min(MAX_AMOUNT, spUSDC.maxDeposit(address(spPrime)));

        if (maxDeposit_ < minDeposit_) return;

        s_.assets = _bound(assets_, minDeposit_, maxDeposit_);

        s_.pendingBefore   = spPrime.pendingDepositSavingsShares();
        s_.capacityBefore  = spPrime.availableCapacity();
        s_.supplyBefore    = spPrime.totalSupply();
        s_.savingsBefore   = spUSDC.balanceOf(address(spPrime));
        s_.recipientBefore = spPrime.balanceOf(s_.recipient);

        // Additive: users accumulate payouts, and `deal` overwrites the balance slot.
        deal(address(usdc), s_.user, usdc.balanceOf(s_.user) + s_.assets);

        vm.startPrank(s_.user);
        usdc.approve(address(spPrime), s_.assets);
        s_.requestId = spPrime.requestDeposit(s_.assets, s_.recipient, referral_);
        vm.stopPrank();

        _assertDeposit(s_);
    }

    function _assertDeposit(DepositState memory s_) internal {
        assertEq(s_.requestId, depositQueueLength, "requestDeposit: id not sequential");

        uint256 savingsShares_ = spUSDC.balanceOf(address(spPrime)) - s_.savingsBefore;
        uint256 minted_        = spPrime.totalSupply() - s_.supplyBefore;

        ( address owner_, address rec_, uint256 remaining_ ) = _rawRequest(DEPOSIT_SLOT, s_.requestId);

        if (s_.pendingBefore == 0) {
            // Nothing nonzero ahead: the request is filled right away, as far as capacity allows.
            uint256 budget_   = spUSDC.convertToShares(spPrime.convertToAssets(s_.capacityBefore));
            uint256 consumed_ = _min(savingsShares_, budget_);

            assertEq(remaining_, savingsShares_ - consumed_, "requestDeposit: auto-fill remainder");

            assertEq(
                minted_,
                spPrime.convertToShares(spUSDC.convertToAssets(consumed_)),
                "requestDeposit: auto-fill mint"
            );
            assertEq(
                spPrime.pendingDepositSavingsShares(),
                savingsShares_ - consumed_,
                "requestDeposit: pending after auto-fill"
            );

            if (remaining_ != 0 || savingsShares_ == 0) {
                assertEq(owner_, s_.user,      "requestDeposit: owner");
                assertEq(rec_,   s_.recipient, "requestDeposit: recipient");
            } else {
                assertEq(owner_, address(0), "requestDeposit: filled entry not deleted");
            }

            _assertDepositHeadClean();
        } else {
            assertEq(remaining_, savingsShares_, "requestDeposit: entry shares");
            assertEq(minted_,    0,              "requestDeposit: minted without auto-fill");
            assertEq(owner_,     s_.user,        "requestDeposit: owner");
            assertEq(rec_,       s_.recipient,   "requestDeposit: recipient");

            assertEq(
                spPrime.pendingDepositSavingsShares(),
                s_.pendingBefore + savingsShares_,
                "requestDeposit: pending delta"
            );
        }

        assertEq(
            spPrime.balanceOf(s_.recipient) - s_.recipientBefore,
            minted_,
            "requestDeposit: recipient balance delta"
        );

        ghostDepositedAssets     += s_.assets;
        ghostSavingsSharesIn     += savingsShares_;
        ghostMinted[s_.recipient] += minted_;
        ghostMintedTotal         += minted_;

        depositOwner[s_.requestId]     = s_.user;
        depositRecipient[s_.requestId] = s_.recipient;
        depositQueueLength++;
    }

    function requestDepositCancellation(uint256 idSeed_, uint256 recipientSeed_, uint256 sharesSeed_)
        public
        checked(CHECK_ALL)
    {
        uint256 requestId_ = _randomOpenRequest(DEPOSIT_SLOT, idSeed_);

        if (requestId_ == NONE) return;

        ( address owner_, , uint256 shares_ ) = _rawRequest(DEPOSIT_SLOT, requestId_);

        assertEq(owner_, depositOwner[requestId_], "requestDepositCancellation: owner mirror");

        uint256 minCancel_ = spPrime.minDepositCancellation();

        if (shares_ < minCancel_) return;  // remainder below the minimum cannot be cancelled

        uint256 savingsShares_ =
            sharesSeed_ % 3 == 0 ? shares_ : _bound(sharesSeed_, minCancel_, shares_);

        address recipient_ = _randomUser(recipientSeed_);

        uint256 pendingDepositBefore_ = spPrime.pendingDepositSavingsShares();
        uint256 pendingCancelBefore_  = spPrime.pendingCancelledDepositSavingsShares();
        uint256 savingsBefore_        = spUSDC.balanceOf(address(spPrime));

        // Not pause-gated.
        vm.prank(owner_);
        uint256 newId_ = spPrime.requestDepositCancellation(requestId_, recipient_, savingsShares_);

        assertEq(newId_, cancelQueueLength, "requestDepositCancellation: id not sequential");

        assertEq(
            spPrime.pendingDepositSavingsShares(),
            pendingDepositBefore_ - savingsShares_,
            "requestDepositCancellation: pending deposit delta"
        );
        assertEq(
            spPrime.pendingCancelledDepositSavingsShares(),
            pendingCancelBefore_ + savingsShares_,
            "requestDepositCancellation: pending cancelled delta"
        );
        assertEq(
            spUSDC.balanceOf(address(spPrime)),
            savingsBefore_,
            "requestDepositCancellation: spUSDC moved"
        );

        ( address ownerAfter_, , uint256 sharesAfter_ ) = _rawRequest(DEPOSIT_SLOT, requestId_);

        if (savingsShares_ == shares_) {
            assertEq(ownerAfter_,  address(0), "requestDepositCancellation: entry not deleted");
            assertEq(sharesAfter_, 0,          "requestDepositCancellation: entry not deleted");
        } else {
            assertEq(ownerAfter_,  owner_,                   "requestDepositCancellation: owner changed");
            assertEq(sharesAfter_, shares_ - savingsShares_, "requestDepositCancellation: entry shares");
        }

        ( address cOwner_, address cRecipient_, uint256 cShares_ ) = _rawRequest(CANCEL_SLOT, newId_);

        assertEq(cOwner_,     owner_,         "requestDepositCancellation: cancel owner");
        assertEq(cRecipient_, recipient_,     "requestDepositCancellation: cancel recipient");
        assertEq(cShares_,    savingsShares_, "requestDepositCancellation: cancel shares");

        _assertDepositHeadClean();

        cancelOwner[newId_]     = owner_;
        cancelRecipient[newId_] = recipient_;
        cancelQueueLength++;
    }

    function requestRedeem(uint256 shares_, uint256 userSeed_, uint256 recipientSeed_)
        public
        checked(CHECK_ALL & ~CHECK_SUPPLY_UNCHANGED)
    {
        address user_      = _randomUser(userSeed_);
        address recipient_ = _randomUser(recipientSeed_);

        uint256 minRedeem_ = spPrime.minRedeem();

        if (spPrime.paused()) {
            vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
            vm.prank(user_);
            spPrime.requestRedeem(minRedeem_, recipient_);
            return;
        }

        uint256 balance_ = spPrime.balanceOf(user_);

        if (balance_ < minRedeem_) return;

        shares_ = shares_ % 10 == 0 ? balance_ : _bound(shares_, minRedeem_, balance_);

        _requestRedeem(user_, recipient_, shares_);
    }

    function updateDepositRecipient(uint256 idSeed_, uint256 recipientSeed_)
        public
        checked(CHECK_ALL)
    {
        _updateRecipient(DEPOSIT_SLOT, idSeed_, recipientSeed_);
    }

    function updateDepositCancellationRecipient(uint256 idSeed_, uint256 recipientSeed_)
        public
        checked(CHECK_ALL)
    {
        _updateRecipient(CANCEL_SLOT, idSeed_, recipientSeed_);
    }

    function updateRedeemRecipient(uint256 idSeed_, uint256 recipientSeed_)
        public
        checked(CHECK_ALL)
    {
        _updateRecipient(REDEEM_SLOT, idSeed_, recipientSeed_);
    }

    function claim(uint256 recipientSeed_)
        public
        checked(CHECK_ALL)
    {
        address recipient_ = _randomUser(recipientSeed_);

        // Prefer a user that has something to claim.
        uint256 n_     = users.length;
        uint256 start_ = _bound(recipientSeed_, 0, n_ - 1);

        for (uint256 i = 0; i < n_; i++) {
            address candidate_ = users[(start_ + i) % n_];

            if (spPrime.claimableAssets(candidate_) != 0) {
                recipient_ = candidate_;
                break;
            }
        }

        if (spPrime.claimableAssets(recipient_) == 0) {
            vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
            spPrime.claim(recipient_);
            return;
        }

        if (isBlacklisted[recipient_]) {
            bytes32 digest_ = _stateDigest();

            vm.expectRevert(bytes(USDC_BLACKLISTED));
            spPrime.claim(recipient_);

            assertEq(_stateDigest(), digest_, "claim: state moved on blacklisted claim");
            return;
        }

        _claim(recipient_);
    }

    function transfer(uint256 amount_, uint256 fromSeed_, uint256 toSeed_)
        public
        checked(CHECK_ALL)
    {
        address from_ = _randomUser(fromSeed_);
        address to_   = _randomUser(toSeed_);

        amount_ = _bound(amount_, 0, spPrime.balanceOf(from_));

        uint256 fromBefore_ = spPrime.balanceOf(from_);
        uint256 toBefore_   = spPrime.balanceOf(to_);

        vm.prank(from_);
        assertTrue(spPrime.transfer(to_, amount_), "transfer: returned false");

        _assertTransfer(from_, to_, amount_, fromBefore_, toBefore_);
    }

    struct TransferFromState {
        address owner;
        address spender;
        address to;
        uint256 ownerBefore;
        uint256 toBefore;
        uint256 allowance;
    }

    function transferFrom(uint256 amount_, uint256 ownerSeed_, uint256 spenderSeed_, uint256 toSeed_)
        public
        checked(CHECK_ALL)
    {
        TransferFromState memory s_;

        s_.owner   = _randomUser(ownerSeed_);
        s_.spender = _randomUser(spenderSeed_);
        s_.to      = _randomUser(toSeed_);

        amount_ = _bound(amount_, 0, spPrime.balanceOf(s_.owner));

        s_.allowance = amount_ % 2 == 1 ? type(uint256).max : amount_;

        vm.prank(s_.owner);
        spPrime.approve(s_.spender, s_.allowance);

        s_.ownerBefore = spPrime.balanceOf(s_.owner);
        s_.toBefore    = spPrime.balanceOf(s_.to);

        vm.prank(s_.spender);
        assertTrue(spPrime.transferFrom(s_.owner, s_.to, amount_), "transferFrom: returned false");

        _assertTransfer(s_.owner, s_.to, amount_, s_.ownerBefore, s_.toBefore);

        // The allowance is untouched for self-spends and for the infinite allowance.
        assertEq(
            spPrime.allowance(s_.owner, s_.spender),
            s_.owner == s_.spender || s_.allowance == type(uint256).max ? s_.allowance : 0,
            "transferFrom: allowance"
        );
    }

    /**********************************************************************************************/
    /*** Recording hooks (test-driven flows, never fuzz targets)                                ***/
    /**********************************************************************************************/

    function noteMinted(address user_, uint256 shares_) external {
        ghostMinted[user_] += shares_;
        ghostMintedTotal   += shares_;
    }

    function notePaidDirect(address user_, uint256 assets_) external {
        ghostPaidDirect[user_] += assets_;
    }

    function noteClaimableCredited(address user_, uint256 assets_) external {
        ghostClaimableCredited[user_] += assets_;
        ghostClaimableCreditedTotal   += assets_;
    }

    function noteBlacklisted(address user_, bool flag_) external {
        isBlacklisted[user_] = flag_;
    }

    // Called after every sanctioned decrease of assetsOf (losses).
    function refreshLastAssetsOf() external {
        for (uint256 i = 0; i < users.length; i++) {
            lastAssetsOf[users[i]] = spPrime.assetsOf(users[i]);
        }
    }

    function requestRedeemExact(address user_, uint256 shares_) external {
        _requestRedeem(user_, user_, shares_);
    }

    function claimExact(address recipient_) external {
        _claim(recipient_);
    }

    /**********************************************************************************************/
    /*** Internal helpers                                                                       ***/
    /**********************************************************************************************/

    function _requestRedeem(address user_, address recipient_, uint256 shares_) internal {
        uint256 fee_ = _divUp(shares_ * spPrime.redeemFeeRate(), WAD);

        uint256 supplyBefore_  = spPrime.totalSupply();
        uint256 escrowBefore_  = spPrime.balanceOf(address(spPrime));
        uint256 pendingBefore_ = spPrime.pendingRedeemShares();
        uint256 balanceBefore_ = spPrime.balanceOf(user_);

        vm.prank(user_);
        uint256 requestId_ = spPrime.requestRedeem(shares_, recipient_);

        assertEq(requestId_, redeemQueueLength, "requestRedeem: id not sequential");

        assertEq(spPrime.totalSupply(),               supplyBefore_ - fee_,           "requestRedeem: fee burn");
        assertEq(spPrime.balanceOf(address(spPrime)), escrowBefore_ + shares_ - fee_, "requestRedeem: escrow delta");
        assertEq(spPrime.pendingRedeemShares(),       pendingBefore_ + shares_ - fee_, "requestRedeem: pending delta");
        assertEq(spPrime.balanceOf(user_),            balanceBefore_ - shares_,       "requestRedeem: user balance delta");
        assertEq(spPrime.rho(),                       block.timestamp,                "requestRedeem: rho not updated");
        assertEq(uint256(spPrime.chi()),              spPrime.nowChi(),               "requestRedeem: chi not synced");

        ( address owner_, address rec_, uint256 queued_ ) = _rawRequest(REDEEM_SLOT, requestId_);

        assertEq(owner_,  user_,          "requestRedeem: owner");
        assertEq(rec_,    recipient_,     "requestRedeem: recipient");
        assertEq(queued_, shares_ - fee_, "requestRedeem: queued shares");

        ghostFeesBurned       += fee_;
        ghostEscrowed[user_]  += shares_;
        lastAssetsOf[user_]    = spPrime.assetsOf(user_);

        redeemOwner[requestId_]     = user_;
        redeemRecipient[requestId_] = recipient_;
        redeemQueueLength++;
    }

    function _updateRecipient(uint256 slot_, uint256 idSeed_, uint256 recipientSeed_) internal {
        uint256 requestId_ = _randomOpenRequest(slot_, idSeed_);

        if (requestId_ == NONE) return;

        ( address owner_, , uint256 shares_ ) = _rawRequest(slot_, requestId_);

        address recipient_ = _randomUser(recipientSeed_);

        bytes32 digest_ = _stateDigest();

        vm.prank(owner_);

        if (slot_ == DEPOSIT_SLOT) {
            spPrime.updateDepositRecipient(requestId_, recipient_);
            depositRecipient[requestId_] = recipient_;
        } else if (slot_ == CANCEL_SLOT) {
            spPrime.updateDepositCancellationRecipient(requestId_, recipient_);
            cancelRecipient[requestId_] = recipient_;
        } else {
            spPrime.updateRedeemRecipient(requestId_, recipient_);
            redeemRecipient[requestId_] = recipient_;
        }

        assertEq(_stateDigest(), digest_, "updateRecipient: state other than the recipient moved");

        ( address ownerAfter_, address recipientAfter_, uint256 sharesAfter_ ) =
            _rawRequest(slot_, requestId_);

        assertEq(ownerAfter_,     owner_,     "updateRecipient: owner changed");
        assertEq(recipientAfter_, recipient_, "updateRecipient: recipient not set");
        assertEq(sharesAfter_,    shares_,    "updateRecipient: shares changed");
    }

    function _claim(address recipient_) internal {
        uint256 claimable_       = spPrime.claimableAssets(recipient_);
        uint256 usdcBefore_      = usdc.balanceOf(recipient_);
        uint256 vaultUsdcBefore_ = usdc.balanceOf(address(spPrime));
        uint256 totalBefore_     = spPrime.totalClaimable();

        uint256 paid_ = spPrime.claim(recipient_);

        assertEq(paid_,                                claimable_,                      "claim: paid != claimable");
        assertEq(usdc.balanceOf(recipient_),           usdcBefore_ + claimable_,        "claim: recipient USDC delta");
        assertEq(usdc.balanceOf(address(spPrime)),     vaultUsdcBefore_ - claimable_,   "claim: vault USDC delta");
        assertEq(spPrime.claimableAssets(recipient_),  0,                               "claim: claimable not zeroed");
        assertEq(spPrime.totalClaimable(),             totalBefore_ - claimable_,       "claim: totalClaimable delta");

        ghostClaimed[recipient_] += claimable_;
        ghostClaimedTotal        += claimable_;
    }

    function _assertTransfer(
        address from_,
        address to_,
        uint256 amount_,
        uint256 fromBefore_,
        uint256 toBefore_
    )
        internal
    {
        if (from_ == to_) {
            assertEq(spPrime.balanceOf(from_), fromBefore_, "transfer: self transfer moved balance");
        } else {
            assertEq(spPrime.balanceOf(from_), fromBefore_ - amount_, "transfer: sender delta");
            assertEq(spPrime.balanceOf(to_),   toBefore_ + amount_,   "transfer: receiver delta");
        }

        ghostTransferOut[from_] += amount_;
        ghostTransferIn[to_]    += amount_;
        lastAssetsOf[from_]      = spPrime.assetsOf(from_);
    }

    // After `requestDeposit` (auto-fill) and `requestDepositCancellation` (compaction) the deposit
    // head sits on a nonzero entry or at the end of the queue.
    function _assertDepositHeadClean() internal view {
        uint256 head_   = spPrime.firstPendingDepositId();
        uint256 length_ = _rawLength(DEPOSIT_SLOT);

        if (head_ < length_) {
            assertGt(_rawShares(DEPOSIT_SLOT, head_), 0, "deposit head sits on a hole after compaction");
        }
    }

}
