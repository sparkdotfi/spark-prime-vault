// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../../lib/forge-std/src/StdError.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";
import { IAccessControl } from "../../lib/oz/contracts/access/IAccessControl.sol";

import { ISparkPrimeVault } from "src/ISparkPrimeVault.sol";

// Cancel permissions, cancel ordering, partial cancels, the cancelled-deposit queue, fee math
// and fee economics for spPRIME. Round 6 (`master` @ c512609): `requestDepositCancellation(id,
// recipient, savingsShares)` is owner-only, supports partial cancels bounded by
// `minDepositCancellation` (spUSDC share units), is NOT pause-gated, rejects the vault as
// recipient, accepts blacklisted recipients, and ends with a budget-0 walk of the deposit queue
// that clears cancelled entries at the head (src/SparkPrimeVault.sol:405-446, :858-900).
// `processPendingDepositCancellations` is not pause-gated either (:326-332). The blacklist
// fallback is a try/catch around the spUSDC payout (:978-1014) crediting `claimableAssets` and
// `totalClaimable`. Custom errors throughout. `adjustTotalAssets` is LOSS_MANAGER_ROLE.
//
// Harness indexes at setUp (see LocalTestBase): chi_s = 1.047633055711877768967605062e27,
// chi_p = 1.009687768242461209408770821e27. All hard-coded numbers below derive from them.
//
//   100e6 USDC deposit        -> 95_453_269 spUSDC shares (worth 99_999_999 USDC)
//                             -> 99_040_517 spPRIME shares when filled
//   1_000_000e6 USDC deposit  -> 954_532_691_143 spUSDC shares (worth 999_999_999_999 USDC)
//                             -> 990_405_184_109 spPRIME shares when filled
contract CancelAndFeesTest is LocalTestBase {

    event DepositCancellationRequest(
        uint256 indexed depositRequestId,
        uint256 indexed cancelRequestId,
        address indexed recipient,
        uint256         sharesCancelled
    );
    event DepositCancellation(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         savingsSharesBurned,
        uint256         assetsReceived
    );
    event Deposit(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         savingsSharesConsumed,
        uint256         assetsConverted,
        uint256         sharesMinted
    );
    event DepositCancellationRecipientUpdated(uint256 indexed requestId, address indexed recipient);
    event TotalAssetsAdjusted(uint192 chi, int256 deltaTotalAssets);
    event ClaimableAssetsIncreased(address indexed recipient, uint256 increase);
    event Claim(address indexed recipient, uint256 assets);
    event RedeemRequest(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         sharesToBurn,
        uint256         feeSharesBurned
    );
    event Redeem(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256         sharesBurned,
        uint256         savingsSharesBurned,
        uint256         assetsReceived
    );
    event RedeemFeeRateSet(uint256 fee);
    event MaxRedeemFeeRateSet(uint256 fee);
    event MinDepositCancellationSet(uint256 minDepositCancellation);

    uint256 constant CHI_S = 1.047633055711877768967605062e27;
    uint256 constant CHI_P = 1.009687768242461209408770821e27;

    uint256 constant SS_100   = 95_453_269;        // spUSDC shares for 100e6
    uint256 constant SH_100   = 99_040_517;        // spPRIME shares for 100e6
    uint256 constant SS_1M    = 954_532_691_143;   // spUSDC shares for 1_000_000e6
    uint256 constant SH_1M    = 990_405_184_109;   // spPRIME shares for 1_000_000e6

    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address carol    = makeAddr("carol");
    address stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        assertEq(spUsdc.nowChi(), CHI_S);
        assertEq(vault.nowChi(),  CHI_P);
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    // Queues a deposit with zero capacity so nothing fills instantly.
    function _queueDeposit(address who, uint256 amt) internal returns (uint256 id) {
        _setCapacity(0);
        id = _deposit(who, amt);
        _setCapacity(type(uint128).max);
    }

    // Full cancel only: the whole remaining entry moves to the cancelled queue, nothing is paid yet.
    function _cancelDeposit(address who, uint256 id, address to) internal returns (uint256 cid) {
        ( , , uint256 shares ) = vault.getPendingDepositRequest(id);
        vm.prank(who);
        cid = vault.requestDepositCancellation(id, to, shares);
    }

    // Partial cancel of `savingsShares` to `to`.
    function _cancelDepositPartial(address who, uint256 id, address to, uint256 savingsShares)
        internal returns (uint256 cid)
    {
        vm.prank(who);
        cid = vault.requestDepositCancellation(id, to, savingsShares);
    }

    function _settleCancelled() internal {
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
    }

    function _ceil(uint256 x, uint256 y) internal pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / y + 1;
    }

    // Foundry runs a test as one transaction, so every slot touched by setup is warm. Cool the
    // contracts so gas measurements reflect a fresh transaction.
    function _cool() internal {
        vm.cool(address(vault));
        vm.cool(address(spUsdc));
        vm.cool(address(usdc));
    }

    // Raw storage reads of queue entries, usable below the head (the getters revert there).
    // Slots: 0 `_depositRequests`, 1 `_depositCancellationRequests`, 2 `_redeemRequests`;
    // element i at keccak256(slot) + 3i + {0 owner, 1 recipient, 2 shares}.
    function _rawEntry(uint256 slot, uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        uint256 base = uint256(keccak256(abi.encode(slot))) + 3 * id;
        owner     = address(uint160(uint256(vm.load(address(vault), bytes32(base)))));
        recipient = address(uint160(uint256(vm.load(address(vault), bytes32(base + 1)))));
        shares    = uint256(vm.load(address(vault), bytes32(base + 2)));
    }

    function _rawDepositRequest(uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        return _rawEntry(0, id);
    }

    function _rawCancelledDepositRequest(uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        return _rawEntry(1, id);
    }

    function _rawRedeemRequest(uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        return _rawEntry(2, id);
    }

    /**********************************************************************************************/
    /*** 1. Cancel permissions: deposits                                                        ***/
    /**********************************************************************************************/

    function test_requestDepositCancellation_ownerCanChooseRecipient() public {
        uint256 id = _queueDeposit(alice, 100e6);

        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    SS_100);

        assertEq(usdc.balanceOf(alice),               0);
        assertEq(usdc.balanceOf(bob),                 0);
        assertEq(_vaultSpUsdc(),                      SS_100);
        assertEq(vault.pendingDepositSavingsShares(), SS_100);

        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 0, bob, SS_100);
        uint256 cid = _cancelDeposit(alice, id, bob);
        assertEq(cid, 0);

        // Deposit entry cleared and the head walked past it (self-skip, :445); cancelled entry
        // created with the caller-chosen recipient.
        assertEq(vault.firstPendingDepositId(), 1);
        (owner, recipient, shares) = _rawDepositRequest(id);
        assertEq(owner,     address(0));
        assertEq(recipient, address(0));
        assertEq(shares,    0);

        (owner, recipient, shares) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    SS_100);

        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100);
        assertEq(vault.firstPendingDepositCancellationId(),                 0);
        assertEq(_vaultSpUsdc(),                               SS_100);  // nothing paid yet
        assertEq(usdc.balanceOf(bob),                          0);

        // Settlement by the operator pays the chosen recipient.
        vm.expectEmit(address(vault));
        emit DepositCancellation(0, alice, bob, SS_100, 99_999_999);
        _settleCancelled();

        (owner, recipient, shares) = _rawCancelledDepositRequest(cid);
        assertEq(owner,     address(0));
        assertEq(recipient, address(0));
        assertEq(shares,    0);

        assertEq(usdc.balanceOf(alice),                        0);
        assertEq(usdc.balanceOf(bob),                          99_999_999);  // 1 wei to spUSDC rounding
        assertEq(_vaultSpUsdc(),                               0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),                 1);
    }

    function test_requestDepositCancellation_revertsNotAuthorized() public {
        uint256 id = _queueDeposit(alice, 100e6);

        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id, stranger, 1);

        // The recipient of the fill is not the owner either.
        _setCapacity(0);
        _fund(alice, 100e6);
        vm.prank(alice);
        uint256 id2 = vault.requestDeposit(100e6, bob, 0);

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id2, bob, 1);
    }

    // V2-2 / F-1 (guardian-chosen refund recipient) stays FIXED by removal: there is no
    // privileged path left in `requestDepositCancellation` (src/SparkPrimeVault.sol:405-446). The
    // only caller is the entry owner (:421); the pauser, the admin, the operator, the taker and a
    // stranger all get `NotRequestOwner` whatever recipient they name, and nothing moves.
    function test_fixed_requestDepositCancellation_privilegedCancelRemoved() public {
        uint256 id = _queueDeposit(alice, 1_000_000e6);

        address[5] memory callers    = [pauser, admin, operator, taker, stranger];
        address[3] memory recipients = [alice, pauser, stranger];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 r; r < recipients.length; ++r) {
                vm.prank(callers[c]);
                vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
                vault.requestDepositCancellation(id, recipients[r], 1);
            }
        }

        // Nothing moved on the failed attempts.
        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    SS_1M);
        assertEq(vault.pendingDepositSavingsShares(),          SS_1M);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_cancelledDepositQueueLength(),               0);

        // The owner can name anyone (including a third party): entry is (alice, bob, SS_1M).
        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 0, bob, SS_1M);
        uint256 cid = _cancelDeposit(alice, id, bob);

        (owner, recipient, shares) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    SS_1M);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_1M);

        vm.expectEmit(address(vault));
        emit DepositCancellation(0, alice, bob, SS_1M, 999_999_999_999);
        _settleCancelled();

        assertEq(usdc.balanceOf(bob),      999_999_999_999);
        assertEq(usdc.balanceOf(alice),    0);
        assertEq(usdc.balanceOf(pauser), 0);
        assertEq(_vaultSpUsdc(),           0);
    }

    // The fill recipient of a deposit has no say: alice pays for bob, only alice can cancel, and
    // the refund goes where alice points it (bob, the fill recipient, has no claim on it).
    function test_requestDepositCancellation_fillRecipientCannotCancel() public {
        _setCapacity(0);
        _fund(alice, 100e6);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(100e6, bob, 0);  // alice pays, bob would get the shares
        _setCapacity(type(uint128).max);

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id, bob, 1);

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id, alice, 1);

        uint256 cid = _cancelDeposit(alice, id, alice);
        (address owner, address recipient, ) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, alice);

        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(usdc.balanceOf(bob),   0);
    }

    // V2-1 pinned on the cancellation queue: `updateDepositCancellationRecipient`
    // (src/SparkPrimeVault.sol:495-512) is owner-only, rejects zero and vault recipients, accepts
    // blacklisted ones, and a settled (deleted) entry rejects every update with `NoRequest`.
    function test_fixed_updateDepositCancellationRecipient_ownerOnly() public {
        uint256 id  = _queueDeposit(alice, 100e6);
        uint256 cid = _cancelDeposit(alice, id, alice);

        vm.prank(pauser);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(cid, pauser);

        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(cid, admin);

        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateDepositCancellationRecipient(cid, stranger);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.updateDepositCancellationRecipient(cid, address(0));

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositCancellationRecipient(cid, address(vault));

        // A blacklisted recipient is accepted (no `isBlacklisted` check left; the payout falls
        // back to `claimableAssets` at settlement).
        _blacklist(carol);
        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cid, carol);
        (, address recipientC, ) = _cancelledDepositRequest(cid);
        assertEq(recipientC, carol);

        vm.expectEmit(address(vault));
        emit DepositCancellationRecipientUpdated(cid, bob);
        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cid, bob);

        (, address recipient, ) = _cancelledDepositRequest(cid);
        assertEq(recipient, bob);

        // The spent deposit id cannot be cancelled twice.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, alice, 1);

        _settleCancelled();
        assertEq(usdc.balanceOf(bob),      99_999_999);
        assertEq(usdc.balanceOf(alice),    0);
        assertEq(usdc.balanceOf(pauser), 0);

        // Settled entries are deleted: the updater only bounds by length (:501), so `NoRequest`.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositCancellationRecipient(cid, alice);
    }

    function test_requestDepositCancellation_revertsNoRequest_alreadyCancelled() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, alice);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, alice, 1);

        vm.prank(pauser);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, alice, 1);
    }

    function test_requestDepositCancellation_revertsNoRequest_alreadyFilled() public {
        uint256 id = _deposit(alice, 100e6);  // instant fill
        assertEq(vault.balanceOf(alice), SH_100);
        assertEq(vault.firstPendingDepositId(), 1);

        (address owner, address recipient, uint256 shares) = _rawDepositRequest(id);
        assertEq(owner,     address(0));  // filled entries are deleted
        assertEq(recipient, address(0));
        assertEq(shares,    0);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);  // below the head
        vault.getPendingDepositRequest(id);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, alice, SS_100);
    }

    function test_requestDepositCancellation_revertsOutOfRange() public {
        uint256 id = _queueDeposit(alice, 100e6);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.requestDepositCancellation(id + 1, alice, SS_100);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.requestDepositCancellation(type(uint256).max, alice, SS_100);

        // Boundary: `id` itself (== length - 1) is in range.
        _cancelDeposit(alice, id, alice);
    }

    function test_requestDepositCancellation_revertsZeroRecipient() public {
        uint256 id = _queueDeposit(alice, 100e6);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.requestDepositCancellation(id, address(0), 1);

        vm.prank(pauser);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.requestDepositCancellation(id, address(0), 1);
    }

    // V2-13 / R5-7 FIXED for the vault at c512609: `requestDepositCancellation` (:415) and
    // `updateDepositCancellationRecipient` (:500) reject the vault as recipient, so a refund can
    // no longer be stranded as USDC inside the prime vault. Nothing moves on the failed calls.
    function test_fixed_requestDepositCancellation_vaultRecipientRejected() public {
        uint256 id = _queueDeposit(alice, 100e6);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDepositCancellation(id, address(vault), SS_100);

        // Checked before the id / ownership / amount checks: a stranger with a bad id gets it too.
        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDepositCancellation(id + 7, address(vault), 0);

        uint256 cid = _cancelDeposit(alice, id, alice);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateDepositCancellationRecipient(cid, address(vault));

        (, address recipient, uint256 shares) = _cancelledDepositRequest(cid);
        assertEq(recipient, alice);
        assertEq(shares,    SS_100);

        _settleCancelled();
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(alice),          99_999_999);
        assertEq(_vaultSpUsdc(),                 0);
    }

    /**********************************************************************************************/
    /*** 1. Redeem side: no cancel (F-1 redeem side and F-8 closed by removal)                  ***/
    /**********************************************************************************************/

    // `cancelRedeemRequest` is gone (bf93b0d). Nobody, the pauser included, has a function
    // that moves escrowed redeem shares: B-2 (pauser redirect of the escrow) and F-8 (pauser
    // cancel keeps the fee) cannot occur. The escrow waits for the planner and is paid to the
    // owner-chosen recipient.
    function test_requestRedeem_pauserCannotTouchEscrow() public {
        _deposit(alice, 1_000_000e6);
        uint256 id = _requestRedeem(alice, SH_1M);

        assertEq(vault.balanceOf(address(vault)), SH_1M);
        assertEq(vault.pendingRedeemShares(),     SH_1M);

        // The old selector fails for every caller.
        bytes memory data = abi.encodeWithSignature("cancelRedeemRequest(uint256,address)", id, pauser);
        address[3] memory callers = [pauser, admin, alice];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            (bool ok, ) = address(vault).call(data);
            assertFalse(ok);
        }

        // The only updater is owner-only.
        vm.prank(pauser);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(id, pauser);

        assertEq(vault.balanceOf(pauser),       0);
        assertEq(vault.balanceOf(alice),          0);
        assertEq(vault.balanceOf(address(vault)), SH_1M);
        (address owner, address recipient, uint256 shares) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    SH_1M);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice),    999_999_999_998);
        assertEq(usdc.balanceOf(pauser), 0);
    }

    // The fee is burned at request time (src/SparkPrimeVault.sol:464-466) and there is no path
    // that gives it back: no cancel, no refund on repoint, and the fill pays the net exactly.
    function test_requestRedeem_feeIsSunkAtRequest() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);

        uint256 id = _requestRedeem(alice, SH_1M);
        assertEq(vault.totalSupply(), SH_1M - 9_904_051_842);
        assertEq(vault.totalSupply(), 980_501_132_267);

        // Lowering the fee afterwards changes nothing for the queued request.
        _setRedeemFeeRate(0);
        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, 980_501_132_267);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),   989_999_999_997);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(999_999_999_998 - usdc.balanceOf(bob), 10_000_000_001);  // the fee, final
    }

    // RQ-2 / C-6 remnant FIXED at c512609: `requestRedeem` (:455) and `updateRedeemRecipient`
    // (:516) reject the vault as recipient; the payout can no longer be parked inside the vault.
    function test_fixed_updateRedeemRecipient_vaultRecipientRejected() public {
        _deposit(alice, 100e6);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestRedeem(SH_100, address(vault));

        uint256 id = _requestRedeem(alice, SH_100);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateRedeemRecipient(id, address(vault));

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(alice),          99_999_998);
        assertEq(vault.availableLiquidAssets(),  1);
    }

    /**********************************************************************************************/
    /*** 2. Cancel ordering and partial fills                                                   ***/
    /**********************************************************************************************/

    function test_requestDepositCancellation_partialFillRefundsRemainder() public {
        uint256 id = _queueDeposit(alice, 100e6);
        assertEq(vault.pendingDepositSavingsShares(), SS_100);

        // Capacity worth 40e6: 40e6 * RAY / chi_p = 39_616_207 shares.
        _setCapacity(39_616_207);
        _processDeposits(type(uint256).max, 1);

        // Capacity -> 39_999_999 USDC -> 38_181_306 spUSDC shares -> 39_999_998 USDC -> 39_616_205 shares.
        assertEq(vault.balanceOf(alice), 39_616_205);
        assertEq(vault.totalSupply(),    39_616_205);
        assertEq(vault.firstPendingDepositId(),    id);  // partial: head stays

        (, , uint256 shares) = _depositRequest(id);
        assertEq(shares, SS_100 - 38_181_306);
        assertEq(shares, 57_271_963);
        assertEq(vault.pendingDepositSavingsShares(), 57_271_963);
        assertEq(_vaultSpUsdc(),                      SS_100);  // fills do not move spUSDC

        uint256 cid = _cancelDeposit(alice, id, alice);
        (, , uint256 cshares) = _cancelledDepositRequest(cid);
        assertEq(cshares, 57_271_963);  // only the unfilled remainder is refundable
        assertEq(vault.firstPendingDepositId(), id + 1);  // self-skip: the dead head is walked
        (, , uint256 dead) = _rawDepositRequest(id);
        assertEq(dead, 0);

        _settleCancelled();

        assertEq(usdc.balanceOf(alice),               60_000_001);  // 57_271_963 * chi_s / RAY
        assertEq(vault.balanceOf(alice),              39_616_205);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(),                      38_181_306);

        // Minted value (39_999_997) + refund == 99_999_998: 1 wei lost at deposit, 1 at the fill.
        assertEq(vault.assetsOf(alice), 39_999_997);
        assertEq(vault.assetsOf(alice) + usdc.balanceOf(alice), 99_999_998);
    }

    // Redeem side of the partial-fill story: the unfilled remainder stays in escrow (no cancel),
    // and is paid when liquidity returns. Chunking across two fills costs 1 wei against one fill.
    function test_requestRedeem_partialFillRemainderStaysQueuedUntilPaid() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);

        // Leave exactly 40e6 USDC of liquidity inside spUSDC.
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 40e6);
        assertEq(vault.availableLiquidAssets(), 40e6);

        _processRedeems(type(uint256).max, 1);

        // convertToShares(40e6) = 39_616_207 shares -> 39_999_999 USDC paid.
        assertEq(usdc.balanceOf(alice),        39_999_999);
        assertEq(vault.totalSupply(),          SH_100 - 39_616_207);
        assertEq(vault.pendingRedeemShares(),  59_424_310);
        assertEq(vault.firstPendingRedeemId(), id);

        (address owner, address recipient, uint256 shares) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    59_424_310);

        // Nothing returns the remainder to alice's balance.
        assertEq(vault.balanceOf(alice),          0);
        assertEq(vault.balanceOf(address(vault)), 59_424_310);
        _processRedeems(type(uint256).max, 1);  // no liquidity: no-op
        assertEq(usdc.balanceOf(alice), 39_999_999);

        _returnSpUsdcLiquidity(100e6);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice),           39_999_999 + 59_999_998);
        assertEq(usdc.balanceOf(alice),           99_999_997);  // one fill would pay 99_999_998
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.totalSupply(),             0);
        assertEq(vault.firstPendingRedeemId(),    1);
    }

    // c512609: a cancel ends with `_processPendingDeposits(0, max)` (src/SparkPrimeVault.sol:445),
    // which `continue`s over zero entries and `break`s at the first live one (:875-878). So the
    // head is cleared only when the cancelled entry is AT the head (and then past every dead
    // entry behind it up to the next live one); a cancelled entry behind a live head stays where
    // it is until the head is filled. R5-9 "frozen head" is therefore fixed for the head itself.
    function test_requestDepositCancellation_selfSkipClearsHeadOnly() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        uint256 idC = _deposit(carol, 100e6);
        assertEq(idA, 0);
        assertEq(idB, 1);
        assertEq(idC, 2);
        assertEq(vault.firstPendingDepositId(), 0);
        assertEq(vault.pendingDepositSavingsShares(), 3 * SS_100);

        // Bob (behind the live head) cancels: the walk breaks at alice, head unchanged.
        _cancelDeposit(bob, idB, bob);
        assertEq(vault.firstPendingDepositId(), 0);
        (, , uint256 deadB) = _depositRequest(idB);
        assertEq(deadB, 0);
        assertEq(vault.getPendingDepositRequests().length, 3);

        // Alice (the head) cancels: the walk skips her dead entry AND bob's, stops at carol.
        _cancelDeposit(alice, idA, alice);
        assertEq(vault.firstPendingDepositId(),                2);
        assertEq(vault.pendingDepositSavingsShares(),          SS_100);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 2 * SS_100);
        assertEq(vault.getPendingDepositRequests().length,     1);
        assertEq(vault.balanceOf(alice), 0);  // budget 0: nothing minted on the walk
        assertEq(vault.balanceOf(bob),   0);
        assertEq(vault.balanceOf(carol), 0);

        // Carol (now the head) cancels: the queue is fully walked, head == length.
        _cancelDeposit(carol, idC, carol);
        assertEq(vault.firstPendingDepositId(),            3);
        assertEq(vault.pendingDepositSavingsShares(),      0);
        assertEq(vault.getPendingDepositRequests().length, 0);

        // Nothing for the operator to walk; even with capacity the head stays at 3.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositId(), 3);

        // The cancelled queue pays in cancel order: bob, alice, carol.
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),   99_999_999);
        assertEq(usdc.balanceOf(alice), 0);
        _processCancelledDeposits(type(uint256).max, 2);
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(usdc.balanceOf(carol), 99_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
        assertEq(_vaultSpUsdc(), 0);
    }

    // The dead entry behind a live head is walked only later, by the operator (costing one
    // request slot) or by the instant walk of a later request.
    function test_requestDepositCancellation_deadEntryBehindLiveHeadIsWalkedLater() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        _cancelDeposit(bob, idB, bob);
        assertEq(vault.firstPendingDepositId(), idA);
        _setCapacity(type(uint128).max);

        // A 1-request batch fills alice and stops: the dead entry is still "pending".
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(alice), SH_100);
        assertEq(vault.firstPendingDepositId(), idB);
        assertEq(vault.getPendingDepositRequests().length, 1);

        // The next 1-request batch only skips it.
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.firstPendingDepositId(), idB + 1);
        assertEq(vault.getPendingDepositRequests().length, 0);

        // A dead entry at the head is also walked by the next request's instant fill.
        _setCapacity(0);
        uint256 idC = _deposit(carol, 100e6);
        uint256 idD = _deposit(stranger, 100e6);
        _cancelDeposit(stranger, idD, stranger);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);  // fills carol, head at the dead entry idD
        assertEq(vault.firstPendingDepositId(), idD);
        uint256 idE = _deposit(bob, 100e6);  // pending == own shares: instant walk skips idD
        assertEq(idE, idD + 1);
        assertEq(vault.balanceOf(bob), SH_100);
        assertEq(vault.firstPendingDepositId(), idE + 1);
        assertEq(idC, 2);
    }

    // `requestRedeem(0)` is gone (`BelowMinRedeem`, minRedeem != 0). The only redeem ghosts left
    // are all-fee entries (R5-14): 1 share at any non-zero fee. The redeem loop has no `continue`
    // for zero entries (src/SparkPrimeVault.sol:950-973): a ghost is "filled" with 0 shares, a
    // `withdraw(0)` on spUSDC, a `Redeem(id, owner, recipient, 0, 0, 0)` event and one request
    // slot; with carol at 2 the planner spends three slots to reach her.
    function test_processPendingRedeems_walksGhostsAsZeroFills() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(carol, 100e6);
        vm.prank(carol);
        vault.transfer(alice, 1);
        vm.prank(carol);
        vault.transfer(bob, 1);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(0, alice);

        _requestRedeem(alice, 1);  // ghost 0
        _requestRedeem(bob,   1);  // ghost 1
        _setRedeemFeeRate(0);
        uint256 idC = _requestRedeem(carol, SH_100 - 2);
        assertEq(idC, 2);
        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(vault.pendingRedeemShares(),  SH_100 - 2);

        _processRedeems(type(uint256).max, 2);
        assertEq(vault.firstPendingRedeemId(), 2);
        assertEq(usdc.balanceOf(carol),        0);

        _processRedeems(type(uint256).max, 1);
        assertEq(vault.firstPendingRedeemId(), 3);
        assertEq(usdc.balanceOf(carol),        99_999_996);
        assertEq(vault.pendingRedeemShares(),  0);
    }

    function test_requestDepositCancellation_thenReRequestFillsInstantlyWhenQueueEmpty() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, alice);
        assertEq(vault.firstPendingDepositId(), 1);  // self-skip cleared the dead slot
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        // `pendingDepositSavingsShares == savingsShares_` again: the re-request fills instantly.
        vm.prank(alice);
        uint256 id2 = vault.requestDeposit(99_999_999, alice, 0);
        assertEq(id2, 1);
        assertEq(vault.firstPendingDepositId(), 2);
        assertEq(vault.balanceOf(alice), 99_040_516);  // 99_999_999 -> 95_453_268 spUSDC -> 99_999_998 -> shares
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    // An unsettled cancel does not block the instant path: the re-request fills even while the
    // refund is still waiting in the cancelled queue (the vault still holds that spUSDC).
    function test_requestDepositCancellation_reRequestFillsInstantlyBeforeSettlement() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, alice);
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100);

        uint256 id2 = _deposit(alice, 100e6);
        assertEq(id2, 1);
        assertEq(vault.balanceOf(alice), SH_100);
        assertEq(_vaultSpUsdc(), 2 * SS_100);

        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(_vaultSpUsdc(), SS_100);
    }

    function test_requestDepositCancellation_thenReRequestQueuesBehindOthers() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        _cancelDeposit(alice, idA, alice);
        assertEq(vault.firstPendingDepositId(), 1);  // self-skip: head now on bob
        _settleCancelled();

        vm.prank(alice);
        uint256 id2 = vault.requestDeposit(99_999_999, alice, 0);
        assertEq(id2, 2);
        assertEq(vault.firstPendingDepositId(), 1);
        assertEq(vault.pendingDepositSavingsShares(), SS_100 + 95_453_268);

        _setCapacity(type(uint128).max);

        // No dead slot in front of bob any more: a 1-request batch fills him directly.
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(bob),   SH_100);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.firstPendingDepositId(),    2);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(alice), 99_040_516);
        assertEq(vault.firstPendingDepositId(),    3);
    }

    /**********************************************************************************************/
    /*** 3. Cancelled-deposit queue mechanics                                                   ***/
    /**********************************************************************************************/

    function test_processPendingDepositCancellations_maxRequestsHonoured() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        uint256 idC = _deposit(carol, 100e6);
        _cancelDeposit(alice, idA, alice);
        _cancelDeposit(bob,   idB, bob);
        _cancelDeposit(carol, idC, carol);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 3 * SS_100);

        _processCancelledDeposits(type(uint256).max, 0);
        assertEq(vault.firstPendingDepositCancellationId(), 0);
        assertEq(usdc.balanceOf(alice), 0);

        _processCancelledDeposits(type(uint256).max, 2);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(usdc.balanceOf(bob),   99_999_999);
        assertEq(usdc.balanceOf(carol), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100);

        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
        assertEq(usdc.balanceOf(carol), 99_999_999);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);

        // Idle call on an empty queue is a no-op.
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
    }

    function test_processPendingDepositCancellations_maxSavingsSharesPartialFill() public {
        uint256 id  = _queueDeposit(alice, 100e6);
        uint256 cid = _cancelDeposit(alice, id, alice);

        // 40e6 worth = 38_181_306 spUSDC shares.
        vm.expectEmit(address(vault));
        emit DepositCancellation(cid, alice, alice, 38_181_306, 39_999_998);
        _processCancelledDeposits(38_181_306, 10);

        assertEq(usdc.balanceOf(alice), 39_999_998);
        assertEq(vault.firstPendingDepositCancellationId(), 0);  // partial: head stays
        (address owner, address recipient, uint256 shares) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    57_271_963);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 57_271_963);
        assertEq(_vaultSpUsdc(), 57_271_963);

        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 39_999_998 + 60_000_001);
        assertEq(usdc.balanceOf(alice), 99_999_999);  // chunking costs nothing extra here
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        assertEq(_vaultSpUsdc(), 0);
    }

    function test_processPendingDepositCancellations_revertsNotOperator() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, alice);

        vm.prank(alice);
        vm.expectRevert();  // AccessControlUnauthorizedAccount
        vault.processPendingDepositCancellations(type(uint256).max, 1);

        vm.prank(pauser);
        vm.expectRevert();
        vault.processPendingDepositCancellations(type(uint256).max, 1);
    }

    // The cancelled queue is settled from the vault's whole spUSDC balance, which includes the
    // backing of deposits still queued: a settlement can spend other depositors' spUSDC.
    function test_processPendingDepositCancellations_spendsOtherQueuedDepositorsBacking() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        _take(SS_100);  // Arkis took 100e6 worth; 2 * 100e6 is still owed to the two queued depositors

        _cancelDeposit(alice, idA, alice);
        _settleCancelled();

        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(_vaultSpUsdc(),        0);
        assertEq(vault.pendingDepositSavingsShares(), SS_100);  // bob: owed, unbacked until return
    }

    /**********************************************************************************************/
    /*** 4. F-2: cancel after take() spent the queue backing                                   ***/
    /**********************************************************************************************/

    function test_requestDepositCancellation_afterTakeSettlesWhatIsThere_restWaits() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        assertEq(_vaultSpUsdc(), 2 * SS_100);

        // Taker pulls 100e6 worth: exactly one depositor's backing by amount, but spUSDC is fungible.
        _take(SS_100);
        assertEq(_vaultSpUsdc(),                      SS_100);
        assertEq(vault.pendingDepositSavingsShares(), 2 * SS_100);  // not reduced by take

        // Both cancel; neither cancel reverts now.
        _cancelDeposit(alice, idA, alice);
        _cancelDeposit(bob,   idB, bob);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 2 * SS_100);
        assertEq(vault.firstPendingDepositId(), 2);

        // Settlement pays alice in full and stops; bob's entry is untouched and no revert.
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(_vaultSpUsdc(),        0);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100);

        // With nothing in the vault the call is a no-op (budget 0), not a revert.
        _settleCancelled();
        assertEq(vault.firstPendingDepositCancellationId(), 1);

        // Returning exactly the shortfall completes bob.
        _returnToVault(SS_100);
        _settleCancelled();
        assertEq(usdc.balanceOf(bob), 99_999_999);
        assertEq(_vaultSpUsdc(),      0);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    function test_requestDepositCancellation_takeExceedsOneRequest_partialThenWait() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);

        // 150e6 worth = 143_179_903 spUSDC shares; 47_726_635 remain (< one request).
        _take(143_179_903);
        assertEq(_vaultSpUsdc(), 47_726_635);

        uint256 cidA = _cancelDeposit(alice, idA, alice);
        uint256 cidB = _cancelDeposit(bob,   idB, bob);

        // Alice is paid the 47_726_635 that is there (50_000_000 USDC) and stays at the head.
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 50_000_000);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(_vaultSpUsdc(),        0);
        assertEq(vault.firstPendingDepositCancellationId(), cidA);
        (, , uint256 leftA) = _cancelledDepositRequest(cidA);
        assertEq(leftA, 47_726_634);
        (, , uint256 leftB) = _cancelledDepositRequest(cidB);
        assertEq(leftB, SS_100);

        // Return alice's remainder: alice completes (49_999_999), bob still waits.
        _returnToVault(47_726_634);
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(vault.firstPendingDepositCancellationId(), cidB);

        _returnToVault(SS_100);
        _settleCancelled();
        assertEq(usdc.balanceOf(bob), 99_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // B-3 (round 2) is fixed: the budget is `spUSDC.maxRedeem(vault)`, so when spUSDC itself is
    // short of USDC the settlement pays what is liquid, FIFO, leaves the head on the partially
    // paid entry, is a no-op while nothing is liquid, and completes once liquidity returns.
    function test_processPendingDepositCancellations_clampsToSpUsdcLiquidity() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        uint256 cidA = _cancelDeposit(alice, idA, alice);
        uint256 cidB = _cancelDeposit(bob,   idB, bob);

        // Leave 40e6 USDC inside spUSDC; the vault still holds 2 * SS_100 spUSDC shares.
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 40e6);
        assertEq(spUsdc.maxRedeem(address(vault)),   38_181_307);  // 40e6 * RAY / chi_s, floor
        assertEq(spUsdc.maxWithdraw(address(vault)), 40e6);

        vm.expectEmit(address(vault));
        emit DepositCancellation(cidA, alice, alice, 38_181_307, 39_999_999);
        _processCancelledDeposits(type(uint256).max, 10);

        // Alice is paid the liquid 39_999_999, stays at the head with the remainder; bob untouched.
        assertEq(usdc.balanceOf(alice), 39_999_999);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(vault.firstPendingDepositCancellationId(), cidA);
        (, , uint256 leftA) = _cancelledDepositRequest(cidA);
        assertEq(leftA, SS_100 - 38_181_307);
        assertEq(leftA, 57_271_962);
        (, , uint256 leftB) = _cancelledDepositRequest(cidB);
        assertEq(leftB, SS_100);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 57_271_962 + SS_100);
        assertEq(usdc.balanceOf(address(spUsdc)),              1);  // 1 wei of dust left in spUSDC
        assertEq(spUsdc.maxRedeem(address(vault)),             0);

        // Nothing liquid: the call is a no-op, no revert.
        _processCancelledDeposits(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 39_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), cidA);

        // Liquidity returns: one call completes alice and bob in order.
        _returnSpUsdcLiquidity(200e6);
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);  // 39_999_999 + 60_000_000: chunking cost nothing
        assertEq(usdc.balanceOf(bob),   99_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(), 0);
    }

    // `maxRequests_` still binds under the liquidity clamp: with 1 request bob is never reached
    // even when liquidity would cover both.
    function test_processPendingDepositCancellations_liquidityClampRespectsMaxRequests() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        _cancelDeposit(alice, idA, alice);
        _cancelDeposit(bob,   idB, bob);
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 150e6);

        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(usdc.balanceOf(bob),   0);
        assertEq(vault.firstPendingDepositCancellationId(), 1);

        // 50e6 + 1 wei left in spUSDC: bob gets a partial fill.
        assertEq(usdc.balanceOf(address(spUsdc)), 50_000_001);
        _processCancelledDeposits(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob), 50_000_000);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
    }

    function test_processPendingDeposits_stillMintsAfterTakeSpentBacking() public {
        _setCapacity(0);
        _deposit(alice, 100e6);
        _deposit(bob,   100e6);

        _take(143_179_903);
        assertEq(_vaultSpUsdc(), 47_726_635);  // worth 50_000_000 USDC

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 2);

        // Both filled in full; fills never touch the spUSDC balance.
        assertEq(vault.balanceOf(alice), SH_100);
        assertEq(vault.balanceOf(bob),   SH_100);
        assertEq(vault.totalAssets(),    199_999_997);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 50_000_000);
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    /**********************************************************************************************/
    /*** 5. Fee math                                                                            ***/
    /**********************************************************************************************/

    function testFuzz_requestRedeem_feeIsCeil(uint256 shares, uint256 feeRate) public {
        shares  = bound(shares,  1, 1e30);
        feeRate = bound(feeRate, 0, 0.01e18);

        _setRedeemFeeRate(feeRate);

        // Mint at least `shares` to alice (rounding loses a few wei on the way in).
        _deposit(alice, vault.convertToAssets(shares) + 10);
        uint256 balance = vault.balanceOf(alice);
        assertGe(balance, shares);

        uint256 supplyBefore = vault.totalSupply();
        uint256 expectedFee  = _ceil(shares * feeRate, WAD);

        uint256 id = _requestRedeem(alice, shares);

        (address owner, address recipient, uint256 queued) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(queued,    shares - expectedFee);

        assertLe(expectedFee, shares);
        assertEq(expectedFee == 0, feeRate == 0);

        assertEq(vault.totalSupply(),             supplyBefore - expectedFee);
        assertEq(vault.balanceOf(alice),          balance - shares);
        assertEq(vault.balanceOf(address(vault)), queued);
        assertEq(vault.pendingRedeemShares(),     queued);
    }

    function test_requestRedeem_revertsBelowMinRedeem() public {
        _setMinRedeem(SH_100);
        _deposit(alice, 200e6);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(SH_100 - 1, alice);

        uint256 id = _requestRedeem(alice, SH_100);
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, SH_100);
    }

    function test_requestRedeem_feeRoundsUpToOneWei() public {
        _setRedeemFeeRate(1);  // 1e-18
        _deposit(alice, 100e6);

        uint256 id = _requestRedeem(alice, SH_100);
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, SH_100 - 1);
        assertEq(vault.totalSupply(), SH_100 - 1);
    }

    /**********************************************************************************************/
    /*** 6. Fee economics                                                                       ***/
    /**********************************************************************************************/

    function test_requestRedeem_feeLeavesChiUnchangedAndRaisesBackingPerShare() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);

        assertEq(vault.balanceOf(alice), SH_1M);
        assertEq(_vaultSpUsdc(),         SS_1M);
        assertEq(vault.totalAssets(),    999_999_999_998);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 999_999_999_999);

        uint256 chiBefore   = vault.nowChi();
        uint256 oneShareVal = vault.convertToAssets(1e6);

        uint256 id = _requestRedeem(alice, SH_1M);

        uint256 fee = 9_904_051_842;  // ceil(990_405_184_109 * 0.01)
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued,                      SH_1M - fee);
        assertEq(queued,                      980_501_132_267);
        assertEq(vault.totalSupply(),         980_501_132_267);
        assertEq(vault.nowChi(),              chiBefore);        // chi is index-based
        assertEq(vault.convertToAssets(1e6),  oneShareVal);      // per-share claim unchanged
        assertEq(_vaultSpUsdc(),              SS_1M);            // backing unchanged

        // Notional liability dropped by the fee's value; real backing did not.
        assertEq(vault.totalAssets(), 989_999_999_997);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()) - vault.totalAssets(), 10_000_000_002);

        // Fill: alice gets the net, the surplus spUSDC stays in the vault and is take-able.
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice),  989_999_999_997);
        assertEq(vault.totalSupply(),    0);
        assertEq(vault.totalAssets(),    0);
        assertEq(_vaultSpUsdc(),         9_545_326_913);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 10_000_000_001);

        _take(9_545_326_913);
        assertEq(_vaultSpUsdc(), 0);
        assertEq(spUsdc.balanceOf(taker), 9_545_326_913);
    }

    function test_requestRedeem_feeNotCreditedToRemainingHolders() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(bob,   100e6);
        _deposit(alice, 1_000_000e6);

        assertEq(vault.assetsOf(bob),  99_999_998);
        assertEq(vault.totalAssets(),  1_000_099_999_997);

        _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems(type(uint256).max, 1);

        // Bob's claim is unchanged; the fee's backing sits in vault equity, uncounted by chi.
        assertEq(vault.assetsOf(bob),  99_999_998);
        assertEq(vault.totalSupply(),  SH_100);
        assertEq(vault.totalAssets(),  99_999_998);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 10_100_000_001);  // bob's 100e6 + the 10_000e6 fee
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()) - vault.totalAssets(), 10_000_000_003);
    }

    // The fee surplus is also what settles cancelled deposits: with alice's fee still in the
    // vault, a cancelled deposit can be refunded even after Arkis took every queued share.
    function test_processPendingDepositCancellations_feeSurplusCoversRefund() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);
        _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, 1);
        assertEq(_vaultSpUsdc(), 9_545_326_913);  // 10_000_000_001 USDC of fee surplus
        assertEq(vault.totalSupply(), 0);

        uint256 id = _queueDeposit(bob, 100e6);
        _take(SS_100);  // takes bob's worth; the fee surplus remains
        _cancelDeposit(bob, id, bob);
        _settleCancelled();

        assertEq(usdc.balanceOf(bob), 99_999_999);
        assertEq(_vaultSpUsdc(), 9_545_326_913 - SS_100);
    }

    /**********************************************************************************************/
    /*** 7. Minimums: gross vs net                                                              ***/
    /**********************************************************************************************/

    // minRedeem is in shares and checked before the fee, so the net payout can land below the
    // value the minimum represents.
    function test_requestRedeem_minRedeemIsGrossOfFee() public {
        _setRedeemFeeRate(0.01e18);
        uint256 minShares = vault.convertToShares(100e6);
        assertEq(minShares, 99_040_518);
        _setMinRedeem(minShares);
        _deposit(alice, 1_000_000e6);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(minShares - 1, alice);

        uint256 id = _requestRedeem(alice, minShares);

        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, minShares - 990_406);
        assertEq(queued, 98_050_112);

        _processRedeems(type(uint256).max, 1);

        // Minimum is worth 99_999_999 USDC; the net payout is 98_999_998: 1_000_001 wei below.
        assertEq(vault.convertToAssets(minShares), 99_999_999);
        assertEq(usdc.balanceOf(alice),            98_999_998);
        assertEq(vault.convertToAssets(minShares) - usdc.balanceOf(alice), 1_000_001);
    }

    // minRedeem is a share count, so the USDC value it enforces drifts up with chi.
    function test_requestRedeem_minRedeemValueDriftsWithChi() public {
        _setMinRedeem(SH_100);
        assertEq(vault.convertToAssets(SH_100), 99_999_998);

        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);

        assertEq(vault.convertToAssets(SH_100), 104_999_998);

        _deposit(alice, 200e6);
        uint256 shares = vault.convertToShares(100e6);  // 100 USDC worth is now below the minimum
        assertLt(shares, SH_100);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(shares, alice);
    }

    function test_requestDeposit_minDepositBoundary() public {
        _setMinDeposit(100e6);
        _fund(alice, 200e6);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(100e6 - 1, alice, 0);

        vm.prank(alice);
        vault.requestDeposit(100e6, alice, 0);
        assertEq(vault.balanceOf(alice), SH_100);
    }

    /**********************************************************************************************/
    /*** 8. Ghost entries and gas                                                               ***/
    /**********************************************************************************************/

    function test_processPendingDeposits_gasWith500GhostEntries() public {
        // Baseline: carol queued, alice behind her, no ghosts.
        _setCapacity(0);
        _deposit(carol, 10e6);
        _deposit(alice, 100e6);
        _setCapacity(type(uint128).max);

        _cool();
        vm.prank(operator);
        uint256 gas = gasleft();
        vault.processPendingDeposits(type(uint256).max, 502);
        uint256 baseline = gas - gasleft();

        assertEq(vault.balanceOf(carol), 9_904_050);
        assertEq(vault.balanceOf(alice), SH_100);
        assertEq(vault.firstPendingDepositId(),    2);

        // Ghosts: carol queued first (so the head cannot walk past them), then 500 zero-asset requests.
        _setCapacity(0);
        uint256 idC = _deposit(carol, 10e6);
        assertEq(idC, 2);

        _fund(stranger, 500);
        for (uint256 i; i < 500; ++i) {
            vm.prank(stranger);
            uint256 id = vault.requestDeposit(1, stranger, 0);  // 1 wei -> 0 spUSDC shares: ghost
            assertEq(id, 3 + i);
        }
        assertEq(vault.pendingDepositSavingsShares(), 9_545_326);

        uint256 idA = _deposit(alice, 100e6);
        assertEq(idA, 503);
        _setCapacity(type(uint128).max);

        _cool();
        vm.prank(operator);
        gas = gasleft();
        vault.processPendingDeposits(type(uint256).max, 502);
        uint256 withGhosts = gas - gasleft();

        assertEq(vault.balanceOf(carol), 2 * 9_904_050);
        assertEq(vault.balanceOf(alice), 2 * SH_100);
        assertEq(vault.firstPendingDepositId(),    504);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        emit log_named_uint("processPendingDeposits gas, 2 real requests",             baseline);
        emit log_named_uint("processPendingDeposits gas, 2 real + 500 ghost requests", withGhosts);
        emit log_named_uint("gas per ghost entry",                                  (withGhosts - baseline) / 500);

        assertGt(withGhosts, baseline + 500 * 2_000);  // at least one cold SLOAD per ghost

        // A ghost cannot be cancelled (and is below the head now anyway).
        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(3, stranger, 1);
    }

    // R5-15 / R5-9 ghosts: `requestDeposit(0)` is `BelowMinDeposit` now, but 1 wei of USDC still
    // mints 0 spUSDC shares (chi_s > RAY) and pushes a zero entry. Every ghost satisfies the
    // instant-fill predicate (`0 == 0`, :400) and the budget-0 walk now advances the head over
    // zero entries (:875-878), so ghosts at the head are self-clearing even with capacity 0; they
    // only cost when a live entry sits in front of them.
    function test_requestDeposit_walksGhostsAtHead() public {
        _setCapacity(0);
        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vault.requestDeposit(0, stranger, 0);

        _fund(stranger, 10);
        for (uint256 i; i < 10; ++i) {
            vm.prank(stranger);
            vault.requestDeposit(1, stranger, 0);
            assertEq(vault.firstPendingDepositId(), i + 1);  // walked immediately, capacity 0
        }
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(usdc.balanceOf(address(spUsdc)) - spUsdc.totalAssets(), 10);  // donated to spUSDC
        _setCapacity(type(uint128).max);

        uint256 id = _deposit(alice, 100e6);
        assertEq(id, 10);
        assertEq(vault.balanceOf(alice), SH_100);
        assertEq(vault.firstPendingDepositId(), 11);
    }

    function test_processPendingRedeems_gasWith500GhostEntries() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 100e6);
        _deposit(bob,   100e6);

        // Baseline: one real request.
        _requestRedeem(bob, SH_100);
        _cool();
        vm.prank(operator);
        uint256 gas = gasleft();
        vault.processPendingRedeems(type(uint256).max, 501);
        uint256 baseline = gas - gasleft();
        assertEq(usdc.balanceOf(bob), 98_999_997);  // 98_050_111 net shares
        assertEq(vault.firstPendingRedeemId(),  1);

        // 500 one-wei redeems: fee = ceil(1 * 0.01) = 1, queued 0.
        for (uint256 i; i < 500; ++i) {
            uint256 id = _requestRedeem(alice, 1);
            (, , uint256 q) = _redeemRequest(id);
            assertEq(q, 0);
        }
        assertEq(vault.balanceOf(alice),      SH_100 - 500);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.totalSupply(),         SH_100 - 500);

        _deposit(bob, 100e6);
        _requestRedeem(bob, SH_100);

        _cool();
        vm.prank(operator);
        gas = gasleft();
        vault.processPendingRedeems(type(uint256).max, 501);
        uint256 withGhosts = gas - gasleft();

        assertEq(usdc.balanceOf(bob), 2 * 98_999_997);
        assertEq(vault.firstPendingRedeemId(),  502);

        emit log_named_uint("processPendingRedeems gas, 1 real request",              baseline);
        emit log_named_uint("processPendingRedeems gas, 1 real + 500 ghost requests", withGhosts);
        emit log_named_uint("gas per ghost entry",                                 (withGhosts - baseline) / 500);

        // c512609: the redeem loop has no `continue` for zero entries (:950-973), so every ghost
        // is a zero-share "fill" with an external `withdraw(0)` on spUSDC and two events: ~37k
        // gas per ghost (was ~2.4k at 0ebb452 with the `continue`). 500 ghosts: ~18.8M gas.
        assertGt((withGhosts - baseline) / 500, 30_000);
        assertLt((withGhosts - baseline) / 500, 45_000);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(1, alice);
    }

    /**********************************************************************************************/
    /*** 9. Donated shares: closed                                                              ***/
    /**********************************************************************************************/

    // `transfer` / `transferFrom` reject `to == address(this)` and `to == address(0)`
    // (src/SparkPrimeVault.sol:549, :557), so shares can no longer be donated into the vault's
    // own balance (the escrow), and `vault.balanceOf(vault)` stays exactly `pendingRedeemShares`.
    function test_fixed_transfer_toVaultRejected() public {
        _deposit(alice, 100e6);
        _deposit(bob,   100e6);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transfer(address(vault), 1_000_000);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transfer(address(0), 1_000_000);

        vm.prank(alice);
        vault.approve(bob, 1_000_000);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transferFrom(alice, address(vault), 1_000_000);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transferFrom(alice, address(0), 1_000_000);

        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.balanceOf(alice),          SH_100);
        assertEq(vault.allowance(alice, bob),     1_000_000);  // nothing consumed on revert

        // The escrow is exactly the queued shares, before and after a fill.
        uint256 id = _requestRedeem(bob, SH_100);
        assertEq(vault.balanceOf(address(vault)), SH_100);
        assertEq(vault.balanceOf(address(vault)), vault.pendingRedeemShares());

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),             99_999_998);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.totalSupply(),             SH_100);

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(id, bob);
    }

    /**********************************************************************************************/
    /*** 10. F-8 closed by removal: no cancel, so no "fee kept on cancel"                       ***/
    /**********************************************************************************************/

    // Round 3's F-8 (pauser cancel of a 1% redeem returned 980_501_132_267 shares and kept the
    // 9_904_051_842-share fee) has no code path left. The same request is now paid in full net
    // of the fee, to the owner-chosen recipient, and the shares never come back as shares.
    function test_requestRedeem_noCancel_feeOnlyChargedOnceAndNetIsPaid() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);

        uint256 id = _requestRedeem(alice, SH_1M);
        assertEq(vault.totalSupply(), SH_1M - 9_904_051_842);

        vm.prank(pauser);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(id, alice);

        assertEq(vault.balanceOf(alice), 0);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 989_999_999_997);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(),    0);
    }

    /**********************************************************************************************/
    /*** 11. Fee locked at request                                                              ***/
    /**********************************************************************************************/

    function test_processPendingRedeems_feeChangeAfterRequestHasNoEffect() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);
        _deposit(bob,   1_000_000e6);

        uint256 idA = _requestRedeem(alice, SH_1M);
        (, , uint256 queuedA) = _redeemRequest(idA);
        assertEq(queuedA, 980_501_132_267);

        _setRedeemFeeRate(0);

        // Bob requests at 0% after the change.
        uint256 idB = _requestRedeem(bob, SH_1M);
        (, , uint256 queuedB) = _redeemRequest(idB);
        assertEq(queuedB, SH_1M);

        _processRedeems(type(uint256).max, 2);

        assertEq(usdc.balanceOf(alice), 989_999_999_997);  // 1% already burned
        assertEq(usdc.balanceOf(bob),   999_999_999_998);
    }

    /**********************************************************************************************/
    /*** 12. Fee setters                                                                        ***/
    /**********************************************************************************************/

    function test_setRedeemFee_revertsAboveMax() public {
        vm.prank(redeemFeeSetter);
        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
        vault.setRedeemFeeRate(0.01e18 + 1);

        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.01e18);
        assertEq(vault.redeemFeeRate(), 0.01e18);
    }

    function test_setMaxRedeemFee_revertsAboveOnePercent() public {
        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.MaxFeeTooHigh.selector);
        vault.setMaxRedeemFeeRate(0.01e18 + 1);

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.01e18);
        assertEq(vault.maxRedeemFeeRate(), 0.01e18);
    }

    // C-7 / R5-11 (open at c512609): `setMaxRedeemFeeRate` (src/SparkPrimeVault.sol:219-222) only
    // bounds future `setRedeemFeeRate` calls; the live `redeemFeeRate` is not clamped, so a max
    // lowered to 0.1% (or to 0) leaves a 1% fee in force until the fee setter acts.
    function test_BUG_setMaxRedeemFeeRate_belowCurrentFeeDoesNotClamp() public {
        _setRedeemFeeRate(0.01e18);

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.001e18);
        assertEq(vault.maxRedeemFeeRate(), 0.001e18);
        assertEq(vault.redeemFeeRate(),    0.01e18);  // unchanged, above the new max

        // New requests keep paying 1%.
        _deposit(alice, 1_000_000e6);
        uint256 id = _requestRedeem(alice, SH_1M);
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, SH_1M - 9_904_051_842);

        // Risk manager can no longer set anything above 0.1%, including the value in force.
        vm.prank(redeemFeeSetter);
        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
        vault.setRedeemFeeRate(0.01e18);

        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.001e18);
        assertEq(vault.redeemFeeRate(), 0.001e18);
    }

    /**********************************************************************************************/
    /*** 13. Pause                                                                              ***/
    /**********************************************************************************************/

    // R5-B (round 4) FIXED at c512609: `requestDepositCancellation` has no `whenNotPaused`
    // (src/SparkPrimeVault.sol:405-446). A queued depositor can leave during a pause, partially
    // too, and the self-skip walk it triggers (:445) runs with budget 0 and mints nothing. The
    // pause still blocks new deposits, redeems and the two minting / paying planners.
    function test_fixed_requestDepositCancellation_worksWhilePaused() public {
        _setCapacity(0);
        uint256 id  = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        _pause();

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDeposit(1, alice, 0);
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingDeposits(type(uint256).max, 1);
        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingRedeems(type(uint256).max, 1);

        // Partial cancel while paused.
        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 0, bob, 40_000_000);
        uint256 cid0 = _cancelDepositPartial(alice, id, bob, 40_000_000);
        assertEq(cid0, 0);
        (, , uint256 left) = _depositRequest(id);
        assertEq(left, SS_100 - 40_000_000);
        assertEq(vault.firstPendingDepositId(), id);  // still live: head unchanged

        // Full cancel of the remainder while paused: the head walks to bob.
        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 1, alice, SS_100 - 40_000_000);
        uint256 cid1 = _cancelDeposit(alice, id, alice);
        assertEq(cid1, 1);
        assertEq(vault.firstPendingDepositId(), idB);
        assertEq(vault.pendingDepositSavingsShares(),          SS_100);
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100);
        assertEq(vault.totalSupply(), 0);  // nothing minted by the budget-0 walk
        assertTrue(vault.paused());

        // take() is not gated by pause (F-7): backing can still leave during the freeze.
        _take(SS_100);
        assertEq(_vaultSpUsdc(), SS_100);
        _returnToVault(SS_100);

        // Settlement while paused too (next test); here: after the unpause.
        _unpause();
        _settleCancelled();
        assertEq(usdc.balanceOf(bob),   41_905_322);  // 40_000_000 * chi_s / RAY
        assertEq(usdc.balanceOf(alice), 58_094_677);  // 55_453_269 * chi_s / RAY
        assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob), 99_999_999);
    }

    // `processPendingDepositCancellations` has no `whenNotPaused` either (:326-332): refunds
    // keep flowing during a pause, FIFO, clamped to spUSDC liquidity, with the blacklist
    // fallback intact. `take()` is not gated either.
    function test_fixed_processPendingDepositCancellations_worksWhilePaused() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        uint256 idC = _deposit(carol, 100e6);
        uint256 cidA = _cancelDeposit(alice, idA, alice);
        uint256 cidB = _cancelDeposit(bob,   idB, bob);
        _pause();
        _blacklist(bob);

        vm.expectEmit(address(vault));
        emit DepositCancellation(cidA, alice, alice, SS_100, 99_999_999);
        vm.expectEmit(address(vault));
        emit ClaimableAssetsIncreased(bob, 99_999_999);
        vm.expectEmit(address(vault));
        emit DepositCancellation(cidB, bob, bob, SS_100, 99_999_999);
        _processCancelledDeposits(type(uint256).max, 10);

        assertTrue(vault.paused());
        assertEq(usdc.balanceOf(alice),          99_999_999);
        assertEq(usdc.balanceOf(bob),            0);
        assertEq(vault.claimableAssets(bob),     99_999_999);
        assertEq(vault.totalClaimable(),         99_999_999);
        assertEq(usdc.balanceOf(address(vault)), 99_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 2);
        assertEq(_vaultSpUsdc(), SS_100);  // carol's queued backing

        // `claim` is not pause-gated either.
        _unblacklist(bob);
        vault.claim(bob);
        assertEq(usdc.balanceOf(bob),    99_999_999);
        assertEq(vault.totalClaimable(), 0);

        // take() during the pause.
        _cancelDeposit(carol, idC, carol);
        _take(SS_100);
        assertEq(_vaultSpUsdc(), 0);
        _settleCancelled();  // no-op: budget 0
        assertEq(usdc.balanceOf(carol), 0);
        assertEq(vault.firstPendingDepositCancellationId(), 2);

        _returnToVault(SS_100);
        _settleCancelled();
        assertEq(usdc.balanceOf(carol), 99_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
        _unpause();
    }

    // Pause freezes new redeem requests and the planner; it does not freeze the owner's repoint
    // (`updateRedeemRecipient` has no `whenNotPaused`, src/SparkPrimeVault.sol:508).
    function test_requestRedeem_revertsWhilePaused_repointDoesNot() public {
        _deposit(alice, 200e6);
        uint256 id = _requestRedeem(alice, SH_100);
        _pause();

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestRedeem(SH_100, alice);

        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingRedeems(type(uint256).max, 1);

        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);
        (, address recipient, ) = _redeemRequest(id);
        assertEq(recipient, bob);

        _unpause();
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob), 99_999_998);
    }

    // `adjustTotalAssets` (paused only, src/SparkPrimeVault.sol:278-295) with a negative delta
    // hits escrowed redeem shares (no way out of the queue after the loss); cancelled deposits
    // waiting for settlement are spUSDC and take no loss.
    function test_adjustTotalAssets_escrowedRedeemTakesLoss_cancelledDepositDoesNot() public {
        _deposit(alice, 100e6);
        uint256 rid = _requestRedeem(alice, SH_100);

        uint256 did = _queueDeposit(bob, 100e6);
        _cancelDeposit(bob, did, bob);

        _pause();
        assertEq(vault.totalAssets(), 99_999_998);

        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.ZeroDeltaTotalAssets.selector);
        vault.adjustTotalAssets(0);

        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.LossTooHigh.selector);
        vault.adjustTotalAssets(-99_999_998);  // result 0: rejected; -99_999_997 is the max loss

        _adjustTotalAssets(-50e6);  // chi halves: 50e6 of 99_999_998 notional
        _unpause();

        // alice cannot step out of the queue; her fill is paid at the reduced chi.
        assertEq(vault.nowChi(), (99_999_998 - 50e6) * RAY / SH_100);
        _processRedeems(type(uint256).max, 1);
        (, , uint256 left) = _rawRedeemRequest(rid);
        assertEq(left,                  0);
        assertEq(usdc.balanceOf(alice), 49_999_997);  // floor(SH_100 * chi / RAY): 1 wei under half

        _settleCancelled();
        assertEq(usdc.balanceOf(bob), 99_999_999);
    }

    /**********************************************************************************************/
    /*** 14. adjustTotalAssets: distributing the fee surplus                                   ***/
    /**********************************************************************************************/

    // The burned redeem fee leaves spUSDC in the vault that chi does not count (I-2). With
    // `adjustTotalAssets(+surplus)` (paused only, src/SparkPrimeVault.sol:278-295) the admin can
    // credit that surplus to the remaining holders: chi is re-anchored to
    // `(totalAssets + delta) / totalSupply` and `totalAssets` lands within 1 wei of the real
    // backing. The gain is a pure chi move, it does not touch spUSDC.
    function test_adjustTotalAssets_distributesFeeSurplusToRemainingHolders() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(bob,   100e6);
        _deposit(alice, 1_000_000e6);

        _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, 1);

        // Bob is the only holder; the 1% fee on alice's redeem sits in the vault uncounted.
        assertEq(vault.totalSupply(),  SH_100);
        assertEq(vault.assetsOf(bob),  99_999_998);
        assertEq(vault.totalAssets(),  99_999_998);
        uint256 backing = spUsdc.convertToAssets(_vaultSpUsdc());
        assertEq(backing, 10_100_000_001);
        uint256 surplus = backing - vault.totalAssets();
        assertEq(surplus, 10_000_000_003);

        uint256 spUsdcBefore = _vaultSpUsdc();
        uint192 expectedChi  = uint192((99_999_998 + surplus) * RAY / SH_100);
        assertEq(expectedChi, 101.978466055462937456192802386e27);

        // Not paused: rejected.
        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(int256(surplus));

        _pause();
        vm.expectEmit(address(vault));
        emit TotalAssetsAdjusted(expectedChi, int256(surplus));
        _adjustTotalAssets(int256(surplus));
        _unpause();

        assertEq(vault.nowChi(),      expectedChi);
        assertEq(vault.totalSupply(), SH_100);               // shares unchanged
        assertEq(vault.assetsOf(bob), 10_100_000_000);       // bob credited ~10_000 USDC
        assertEq(vault.totalAssets(), 10_100_000_000);
        assertEq(_vaultSpUsdc(),      spUsdcBefore);         // backing untouched
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()) - vault.totalAssets(), 1);  // 1 wei

        // Bob can actually redeem the credited amount: the backing is real.
        _setRedeemFeeRate(0);
        uint256 id = _requestRedeem(bob, SH_100);
        _processRedeems(type(uint256).max, 1);
        (, , uint256 left) = _rawRedeemRequest(id);
        assertEq(left,                 0);
        assertEq(usdc.balanceOf(bob),  10_100_000_000);
        assertEq(vault.totalSupply(),  0);
        assertEq(_vaultSpUsdc(),       1);  // 1 spUSDC wei of dust
    }

    // Exact per-holder gain when the fee surplus is distributed over two holders of different
    // size: the gain is pro-rata to shares (bob 100e6, carol 1_000_000e6 -> 1:10_000 of the
    // 9_904_051_842-share fee value), with floor rounding against each holder.
    function test_adjustTotalAssets_feeSurplusIsProRataToRemainingHolders() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(bob,   100e6);
        _deposit(carol, 1_000_000e6);
        _deposit(alice, 1_000_000e6);

        _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, 1);

        assertEq(vault.totalSupply(), SH_100 + SH_1M);
        uint256 bobBefore   = vault.assetsOf(bob);
        uint256 carolBefore = vault.assetsOf(carol);
        assertEq(bobBefore,   99_999_998);
        assertEq(carolBefore, 999_999_999_998);

        uint256 surplus = spUsdc.convertToAssets(_vaultSpUsdc()) - vault.totalAssets();
        assertEq(surplus, 10_000_000_003);
        assertEq(vault.totalAssets(), 1_000_099_999_997);

        _adjustTotalAssetsWhilePaused(int256(surplus));
        assertEq(vault.nowChi(), 1.019783636340772882610822844e27);

        uint256 bobGain   = vault.assetsOf(bob)   - bobBefore;
        uint256 carolGain = vault.assetsOf(carol) - carolBefore;
        assertEq(bobGain,   999_900);          // 100e6 / 1_000_100e6 of the surplus
        assertEq(carolGain, 9_999_000_103);    // 1_000_000e6 / 1_000_100e6 of the surplus
        assertEq(bobGain + carolGain, surplus);
        assertEq(vault.totalAssets(), 1_010_099_999_999);  // floor: 1 wei under the target
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()) - vault.totalAssets(), 1);

        // Pro-rata to shares within 1 wei of floor rounding.
        assertLe(bobGain   - SH_100 * surplus / (SH_100 + SH_1M), 1);
        assertLe(carolGain - SH_1M  * surplus / (SH_100 + SH_1M), 1);
    }

    // With nobody left holding shares the surplus cannot be distributed: `adjustTotalAssets`
    // divides by `totalSupply == 0` (src/SparkPrimeVault.sol:289, panic 0x12) and the only way
    // out for the 10_000_000_001 USDC of fee is `take()`.
    function test_adjustTotalAssets_panicsWithNoHolders() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);
        _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, 1);

        assertEq(vault.totalSupply(), 0);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 10_000_000_001);

        _pause();
        vm.prank(lossManager);
        vm.expectRevert(stdError.divisionError);
        vault.adjustTotalAssets(10_000_000_001);

        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.ZeroDeltaTotalAssets.selector);
        vault.adjustTotalAssets(0);

        vm.prank(redeemFeeSetter);
        vm.expectRevert(_unauthorized(redeemFeeSetter, LOSS_MANAGER_ROLE));  // LOSS_MANAGER only
        vault.adjustTotalAssets(1);

        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, LOSS_MANAGER_ROLE));  // the admin lost this one
        vault.adjustTotalAssets(1);
        _unpause();

        _take(9_545_326_913);
        assertEq(_vaultSpUsdc(), 0);
    }

    // The mirror: `adjustTotalAssets` is not checked against backing. A gain with nothing behind
    // it is purely notional; the redeem queue then clamps to real liquidity and the excess claim
    // waits forever. R3-1: it now requires `paused`, and while paused no deposit can be
    // instant-filled to capture the gain (`requestDeposit` is `whenNotPaused`, :391).
    function test_adjustTotalAssets_withoutBackingIsNotional() public {
        _deposit(alice, 100e6);
        assertEq(vault.totalAssets(), 99_999_998);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 99_999_999);

        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(100e6);

        _pause();
        _fund(bob, 100e6);
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestDeposit(100e6, bob, 0);

        _adjustTotalAssets(100e6);
        _unpause();

        assertEq(vault.nowChi(),       2.019375545061017805470462154e27);
        assertEq(vault.totalAssets(),  199_999_997);
        assertEq(vault.assetsOf(alice), 199_999_997);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 99_999_999);  // unchanged
        assertEq(vault.availableLiquidAssets(),          99_999_999);

        // Alice redeems everything: half her shares are paid from the real 99_999_999, the other
        // half (worth exactly 100_000_000 on paper) sits at the head with 2 spUSDC wei behind it.
        uint256 id = _requestRedeem(alice, SH_100);
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice), 99_999_997);
        (, , uint256 left) = _redeemRequest(id);
        assertEq(left,                       49_520_259);
        assertEq(vault.convertToAssets(left), 100_000_000);
        assertEq(_vaultSpUsdc(),              2);
        assertEq(vault.firstPendingRedeemId(),          id);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 99_999_997);  // no progress without new backing
    }

    // R3-1 residual: the gain is public (governance payload) before the pauser pauses. A deposit
    // that instant-fills in that window captures its pro-rata share of the gain. Quantified for
    // the fee-surplus distribution above: bob deposits 1_000_000e6 just before the pause and
    // takes 9_999_000_104 of the 10_000_000_005 surplus that alice's fee produced.
    function test_adjustTotalAssets_depositBeforePauseCapturesGain() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(carol, 100e6);
        _deposit(alice, 1_000_000e6);
        _requestRedeem(alice, SH_1M);
        _processRedeems(type(uint256).max, 1);

        uint256 surplus = spUsdc.convertToAssets(_vaultSpUsdc()) - vault.totalAssets();
        assertEq(surplus, 10_000_000_003);

        // Bob front-runs the pause; his deposit fills instantly at the pre-gain chi.
        _deposit(bob, 1_000_000e6);
        assertEq(vault.balanceOf(bob), SH_1M);
        surplus = spUsdc.convertToAssets(_vaultSpUsdc()) - vault.totalAssets();
        assertEq(surplus, 10_000_000_003);  // bob's deposit adds 1 wei of its own rounding

        _adjustTotalAssetsWhilePaused(int256(surplus));

        assertEq(vault.assetsOf(bob)   - 999_999_999_998, 9_999_000_103);  // 99.99% of the gain
        assertEq(vault.assetsOf(carol) - 99_999_998,      999_900);        // carol keeps 0.01%

        // Bob exits with the 1% fee: at the launch fee the capture is not profitable on its own
        // (fee 10_000e6 > gain 9_999e6); at fee 0 it is 9_999_000_103 USDC of free money.
        uint256 id = _requestRedeem(bob, SH_1M);
        _processRedeems(type(uint256).max, 1);
        (, , uint256 left) = _rawRedeemRequest(id);
        assertEq(left, 0);
        assertEq(usdc.balanceOf(bob), 999_899_010_099);
        assertLt(usdc.balanceOf(bob), 1_000_000e6);
    }

    /**********************************************************************************************/
    /*** 15. Yield while queued, cancel / re-request cycles                                     ***/
    /**********************************************************************************************/

    // A queued depositor earns spUSDC yield on the full amount with no fee, exactly as if they held
    // spUSDC directly, while spPRIME holders earn the (lower) VSR. The same holds while the refund
    // sits unsettled in the cancelled queue.
    function test_requestDepositCancellation_queuedDepositEarnsSpUsdcYield() public {
        _deposit(carol, 1_000_000e6);  // holder, VSR stays at RAY

        // Bob holds spUSDC directly for comparison.
        usdc.mint(bob, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(spUsdc), 1_000_000e6);
        spUsdc.deposit(1_000_000e6, bob);
        vm.stopPrank();
        assertEq(spUsdc.balanceOf(bob), SS_1M);

        uint256 id = _queueDeposit(alice, 1_000_000e6);
        (, , uint256 ss) = _depositRequest(id);
        assertEq(ss, SS_1M);

        _setSpUsdcVsr(FIVE_PCT_VSR);
        _warpAndDrip(182 days);

        // Cancel half-way, settle at the end of the year: the cancelled queue earns the same rate.
        _cancelDeposit(alice, id, alice);
        _warpAndDrip(183 days);

        uint256 chiS = spUsdc.nowChi();
        uint256 expected = SS_1M * chiS / RAY;

        _settleCancelled();
        vm.prank(bob);
        spUsdc.redeem(SS_1M, bob, bob);

        assertEq(usdc.balanceOf(alice), expected);
        assertEq(usdc.balanceOf(bob),   expected);
        assertEq(usdc.balanceOf(alice), 1_049_999_999_998);  // 5% on 1_000_000e6, 2 wei of rounding
        assertEq(vault.assetsOf(carol), 999_999_999_998);    // holder earned nothing (VSR = RAY)

        emit log_named_uint("queued+cancelled depositor USDC after 1y at 5% spUSDC VSR", usdc.balanceOf(alice));
        emit log_named_uint("direct spUSDC holder USDC after 1y",                       usdc.balanceOf(bob));
        emit log_named_uint("spPRIME holder claim after 1y (VSR 0)",                    vault.assetsOf(carol));
    }

    // The same yield is credited at fill: a late fill mints more shares than an early one.
    function test_processPendingDeposits_fillCreditsSpUsdcYieldAccruedWhileQueued() public {
        _deposit(carol, 1_000_000e6);
        assertEq(vault.balanceOf(carol), SH_1M);

        uint256 id = _queueDeposit(alice, 1_000_000e6);

        _setSpUsdcVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);

        _processDeposits(type(uint256).max, 1);
        (, , uint256 left) = _rawDepositRequest(id);
        assertEq(left, 0);

        uint256 expectedAssets = spUsdc.convertToAssets(SS_1M);
        uint256 expectedShares = vault.convertToShares(expectedAssets);
        assertEq(vault.balanceOf(alice), expectedShares);
        assertEq(vault.balanceOf(alice), 1_039_925_443_313);
        assertEq(vault.assetsOf(alice),  1_049_999_999_997);
        assertEq(vault.assetsOf(carol),  999_999_999_998);

        // Alice ends with ~5% more shares than carol for the same USDC in.
        assertEq(vault.balanceOf(alice) - vault.balanceOf(carol), 49_520_259_204);
    }

    // Escrowed redeem shares keep accruing VSR until the fill; the fill pays the accrued value
    // (net of the fee burned at request) out of the common backing.
    function test_requestRedeem_escrowAccruesVsrUntilFill() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);
        _deposit(bob,   1_000_000e6);  // backing for alice's accrual

        uint256 id = _requestRedeem(alice, SH_1M);
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, 980_501_132_267);

        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);

        assertEq(vault.convertToAssets(queued), 1_039_499_999_997);  // 989_999_999_997 * 1.05

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice),  1_039_499_999_997);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(),    SH_1M);
        assertEq(vault.assetsOf(bob),    1_049_999_999_998);
    }

    // Deposit / cancel / settle cycles only lose spUSDC rounding dust: 1 wei per cycle. With
    // capacity 0 the request's instant walk breaks at the live entry (head unchanged), and the
    // cancel's self-skip walks past it (head i + 1): no dead entries pile up at the head.
    function test_requestDepositCancellation_cycleLosesOneWeiPerRound() public {
        _setCapacity(0);
        _fund(alice, 100e6);

        uint256 amount = 100e6;
        for (uint256 i; i < 10; ++i) {
            vm.prank(alice);
            uint256 id = vault.requestDeposit(amount, alice, 0);
            assertEq(id, i);
            assertEq(vault.firstPendingDepositId(), i);

            (, , uint256 ss) = _depositRequest(id);
            assertEq(ss, amount * RAY / CHI_S);

            uint256 cid = _cancelDeposit(alice, id, alice);
            assertEq(cid, i);
            assertEq(vault.firstPendingDepositId(), i + 1);
            _settleCancelled();
            assertEq(vault.firstPendingDepositCancellationId(), i + 1);

            uint256 refunded = usdc.balanceOf(alice);
            assertEq(refunded, ss * CHI_S / RAY);
            assertEq(refunded, amount - 1);
            amount = refunded;
        }
        assertEq(usdc.balanceOf(alice), 100e6 - 10);
        assertEq(_vaultSpUsdc(),        0);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(),                10);
        assertEq(vault.getPendingDepositRequests().length,     0);
    }

    // N-1 re-measured. Request / cancel cycles behind a live head entry still leave dead deposit
    // entries that consume maxRequests_ budget and gas. Each cycle now also appends an entry to
    // the cancelled queue that the operator must settle (one spUSDC redeem each), and the
    // griefer can only recycle the same 100e6 if the operator settles between cycles.
    function test_requestDepositCancellation_cancelledEntriesConsumeRequestBudget() public {
        _setMinDeposit(100e6);
        _setCapacity(0);
        uint256 idB = _deposit(bob, 100e6);  // live head entry keeps the head from walking
        assertEq(idB, 0);

        _fund(stranger, 100e6);
        for (uint256 i; i < 50; ++i) {
            vm.prank(stranger);
            uint256 id = vault.requestDeposit(100e6, stranger, 0);
            assertEq(id, 1 + i);
            uint256 cid = _cancelDeposit(stranger, id, stranger);
            assertEq(cid, i);
            assertEq(vault.firstPendingDepositId(), 0);
            _settleCancelled();  // operator co-operates; otherwise 50 x 100e6 of capital is needed
            // Top up the single wei lost per cycle so the request stays above minDeposit.
            usdc.mint(stranger, 100e6 - usdc.balanceOf(stranger));
        }
        _deposit(alice, 100e6);  // id 51
        _setCapacity(type(uint128).max);

        // 50 dead entries sit between bob and alice; a 50-request batch fills bob only.
        _processDeposits(type(uint256).max, 50);
        assertEq(vault.balanceOf(bob),   SH_100);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.firstPendingDepositId(),    50);

        _processDeposits(type(uint256).max, 1);  // skips dead entry 50
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.firstPendingDepositId(),    51);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(alice), SH_100);
        assertEq(vault.firstPendingDepositId(),    52);

        // Griefer paid 50 wei of USDC plus gas for 50 dead entries and 50 settlements.
        assertEq(usdc.balanceOf(stranger), 100e6);
        assertEq(vault.firstPendingDepositCancellationId(), 50);
    }

    // Gas the operator pays per cancelled entry it settles, cold.
    function test_processPendingDepositCancellations_gasPerEntry() public {
        _setCapacity(0);
        uint256 id0 = _deposit(stranger, 100e6);
        _cancelDeposit(stranger, id0, stranger);

        _cool();
        vm.prank(operator);
        uint256 gas = gasleft();
        vault.processPendingDepositCancellations(type(uint256).max, 1);
        uint256 one = gas - gasleft();

        for (uint256 i; i < 50; ++i) {
            uint256 id = _deposit(stranger, 100e6);
            _cancelDeposit(stranger, id, stranger);
        }
        assertEq(vault.pendingCancelledDepositSavingsShares(), 50 * SS_100);

        _cool();
        vm.prank(operator);
        gas = gasleft();
        vault.processPendingDepositCancellations(type(uint256).max, 50);
        uint256 fifty = gas - gasleft();

        assertEq(vault.firstPendingDepositCancellationId(), 51);
        assertEq(usdc.balanceOf(stranger), 51 * 99_999_999);

        emit log_named_uint("processPendingDepositCancellations gas, 1 entry",   one);
        emit log_named_uint("processPendingDepositCancellations gas, 50 entries", fifty);
        emit log_named_uint("marginal gas per settled entry",              (fifty - one) / 49);

        assertGt((fifty - one) / 49, 10_000);  // each settlement is a full spUSDC redeem
    }

    // The redeem / cancel cycle no longer exists: a second request for the same shares is only
    // possible after the first one has been paid, and the fee is charged on each request.
    function test_requestRedeem_noCycleWithoutAFill() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);

        _requestRedeem(alice, SH_1M);
        assertEq(vault.balanceOf(alice), 0);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.requestRedeem(1, alice);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 989_999_999_997);
        assertEq(_vaultSpUsdc(),        SS_1M - 944_987_364_230);  // 1 fee's worth of surplus left
    }


    /**********************************************************************************************/
    /*** 16. Round 5: fee math at the edges                                                     ***/
    /**********************************************************************************************/

    // `requestRedeem(1)` at any non-zero fee: `_divUp(1 * fee, WAD)` is 1 for every fee in
    // (0, 1%] (src/SparkPrimeVault.sol:460), so the single share is a 100% fee and the queue gets
    // a ghost entry (shares 0) that nobody can update and the planner has to step over.
    function testFuzz_requestRedeem_oneShareAtAnyNonzeroFeeIsFullyBurnedGhost(uint256 feeRate) public {
        feeRate = bound(feeRate, 1, 0.01e18);
        _setRedeemFeeRate(feeRate);
        _deposit(alice, 100e6);

        vm.expectEmit(address(vault));
        emit RedeemRequest(0, alice, alice, 1, 1);
        uint256 id = _requestRedeem(alice, 1);

        (address owner, address recipient, uint256 queued) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(queued,    0);

        assertEq(vault.balanceOf(alice),          SH_100 - 1);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(),             SH_100 - 1);
        assertEq(vault.pendingRedeemShares(),     0);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(id, bob);

        // Two shares at the 1% cap: fee 1 (50%); 100 shares: fee 1 (1%, exact).
        _setRedeemFeeRate(0.01e18);
        uint256 id2 = _requestRedeem(alice, 2);
        (, , queued) = _redeemRequest(id2);
        assertEq(queued, 1);
        uint256 id3 = _requestRedeem(alice, 100);
        (, , queued) = _redeemRequest(id3);
        assertEq(queued, 99);
    }

    // The effective fee is never below the nominal rate and over-charges by at most 1 wei of
    // share: `shares * rate <= fee * WAD < shares * rate + WAD`.
    function testFuzz_requestRedeem_feeOverchargesAtMostOneWei(uint256 shares, uint256 feeRate) public {
        shares  = bound(shares,  1, 1e30);
        feeRate = bound(feeRate, 0, 0.01e18);
        _setRedeemFeeRate(feeRate);
        _deposit(alice, vault.convertToAssets(shares) + 10);

        uint256 id = _requestRedeem(alice, shares);
        (, , uint256 queued) = _redeemRequest(id);
        uint256 fee = shares - queued;

        assertGe(fee * WAD, shares * feeRate);
        assertLt(fee * WAD, shares * feeRate + WAD);
        assertEq(fee, _ceil(shares * feeRate, WAD));
    }

    // Splitting a redeem into many requests never reduces the total fee (`_divUp` per request)
    // and can increase it by at most one share per extra request; at the limit of 1-share
    // requests the fee is 100%. Single request of SH_1M at 1%: 9_904_051_842 shares.
    function test_requestRedeem_splittingIntoManyRequestsNeverReducesFee() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);
        _deposit(bob,   1_000_000e6);

        _requestRedeem(alice, SH_1M);
        uint256 singleFee = SH_1M - vault.pendingRedeemShares();
        assertEq(singleFee, 9_904_051_842);

        // Bob: 1000 requests; 999 of 990_405_184 shares and one of the 109_109 remainder.
        uint256 supplyBefore = vault.totalSupply();
        uint256 chunk = SH_1M / 1000;
        assertEq(chunk, 990_405_184);
        uint256 remainder = SH_1M - 999 * chunk;
        assertEq(remainder, 990_405_293);  // chunk + 109
        for (uint256 i; i < 999; ++i) _requestRedeem(bob, chunk);
        _requestRedeem(bob, remainder);
        assertEq(vault.balanceOf(bob), 0);

        uint256 splitFee = supplyBefore - vault.totalSupply();
        assertEq(splitFee, 999 * 9_904_052 + 9_904_053);  // ceil(9_904_051.84) x 999 + ceil(9_904_052.93)
        assertEq(splitFee, 9_904_052_001);
        assertGt(splitFee, singleFee);
        assertEq(splitFee - singleFee, 159);           // < 1000 extra shares (1 per request max)
        assertLe(splitFee - singleFee, 1000 - 1);

        // Carol: 1-share requests are a 100% fee.
        _deposit(carol, 100e6);
        supplyBefore = vault.totalSupply();
        for (uint256 i; i < 100; ++i) _requestRedeem(carol, 1);
        assertEq(supplyBefore - vault.totalSupply(), 100);
        assertEq(vault.balanceOf(carol), SH_100 - 100);
    }

    function testFuzz_requestRedeem_splitFeeBoundedBySingleFeePlusRequests(uint256 shares, uint256 n, uint256 feeRate) public {
        shares  = bound(shares,  1, 1e30);
        n       = bound(n,       1, 64);
        feeRate = bound(feeRate, 0, 0.01e18);
        if (n > shares) n = shares;
        _setRedeemFeeRate(feeRate);
        _deposit(alice, vault.convertToAssets(shares) + 10);

        uint256 single = _ceil(shares * feeRate, WAD);
        uint256 supplyBefore = vault.totalSupply();
        uint256 chunk = shares / n;
        for (uint256 i; i + 1 < n; ++i) _requestRedeem(alice, chunk);
        _requestRedeem(alice, shares - chunk * (n - 1));

        uint256 split = supplyBefore - vault.totalSupply();
        assertGe(split, single);
        assertLe(split, single + n - 1);
    }

    // Transferring shares to a fresh address does not change the fee: it is charged per request
    // on the shares requested, whoever requests them. Spread across addresses it is the split
    // case above (never less, at most one share more per request).
    function test_requestRedeem_feeCannotBeAvoidedByTransfer() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);
        _deposit(carol, 1_000_000e6);  // control

        vm.prank(alice);
        vault.transfer(bob, SH_1M);
        assertEq(vault.balanceOf(bob), SH_1M);

        uint256 idB = _requestRedeem(bob, SH_1M);
        uint256 idC = _requestRedeem(carol, SH_1M);
        (, , uint256 queuedB) = _redeemRequest(idB);
        (, , uint256 queuedC) = _redeemRequest(idC);
        assertEq(queuedB, queuedC);
        assertEq(queuedB, SH_1M - 9_904_051_842);

        _processRedeems(type(uint256).max, 2);
        assertEq(usdc.balanceOf(bob),   989_999_999_997);
        assertEq(usdc.balanceOf(carol), 989_999_999_997);

        // Ten addresses, a tenth each: 10 * ceil(99_040_518_410 * 1%) = 9_904_051_850 (8 more).
        _deposit(alice, 1_000_000e6);
        uint256 supplyBefore = vault.totalSupply();
        uint256 tenth = SH_1M / 10;
        assertEq(tenth * 10, SH_1M - 9);
        for (uint256 i; i < 10; ++i) {
            address who = makeAddr(string(abi.encodePacked("split", i)));
            uint256 amt = i == 9 ? SH_1M - 9 * tenth : tenth;
            vm.prank(alice);
            vault.transfer(who, amt);
            vm.prank(who);
            vault.requestRedeem(amt, who);
        }
        assertEq(supplyBefore - vault.totalSupply(), 9_904_051_850);
    }

    // The fee burn lowers `totalSupply`, so it frees exactly `fee` shares of capacity: with the
    // vault full, a fee-paying redeem request lets a deposit of that size fill instantly.
    function test_requestRedeem_feeBurnFreesCapacity() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 1_000_000e6);
        _setCapacity(vault.totalSupply());
        assertEq(vault.availableCapacity(), 0);

        _requestRedeem(alice, SH_1M);
        assertEq(vault.availableCapacity(), 9_904_051_842);

        // 10_000e6 USDC = 9_904_051_841 shares after both floors: fits, fills instantly.
        uint256 id = _deposit(bob, 10_000e6);
        (, , uint256 left) = _rawDepositRequest(id);
        assertEq(left,                  0);
        assertEq(vault.balanceOf(bob),  9_904_051_840);
        assertEq(vault.availableCapacity(), 2);
    }

    // `setRedeemFeeRate` is REDEEM_FEE_SETTER_ROLE only (src/SparkPrimeVault.sol:375): the admin,
    // the pauser and a stranger cannot set it. With `maxRedeemFeeRate == 0` every non-zero
    // fee is rejected and 0 is accepted.
    function test_setRedeemFeeRate_accessAndZeroMax() public {
        address[4] memory callers = [admin, pauser, operator, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert();  // AccessControlUnauthorizedAccount
            vault.setRedeemFeeRate(0.001e18);
        }

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0);

        vm.prank(redeemFeeSetter);
        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
        vault.setRedeemFeeRate(1);

        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0);
        assertEq(vault.redeemFeeRate(), 0);

        // Fee setter cannot raise the max.
        vm.prank(redeemFeeSetter);
        vm.expectRevert();
        vault.setMaxRedeemFeeRate(0.01e18);
    }

    // At the 1% cap the fee on SH_1M is exactly 9_904_051_842 shares worth 10_000_000_001 USDC
    // at request time; the payout is 989_999_999_997.
    function test_requestRedeem_feeAtCapExact() public {
        _setRedeemFeeRate(vault.MAX_REDEEM_FEE());
        assertEq(vault.redeemFeeRate(), 0.01e18);
        _deposit(alice, 1_000_000e6);

        vm.expectEmit(address(vault));
        emit RedeemRequest(0, alice, alice, SH_1M, 9_904_051_842);
        _requestRedeem(alice, SH_1M);

        assertEq(vault.convertToAssets(9_904_051_842), 10_000_000_000);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 989_999_999_997);
    }

    /**********************************************************************************************/
    /*** 17. Round 5: cancel permissions, blacklist, ghosts                                     ***/
    /**********************************************************************************************/

    // Full revert matrix of `requestDepositCancellation` in check order
    // (src/SparkPrimeVault.sol:414-423): `ZeroRecipient`, `VaultIsRecipient`, `InvalidRequestId`
    // (id >= length), `NoRequest` (zero entry), `NotRequestOwner`, `BelowMinDepositCancellation`,
    // `SavingsSharesTooHigh`. A blacklisted recipient is no longer a reason to revert. Nothing
    // moves on any failed call; the boundaries (exactly `minDepositCancellation`, exactly the
    // entry's shares) succeed.
    function test_requestDepositCancellation_revertMatrix_checkOrder() public {
        _setMinDepositCancellation(10_000_000);
        _setCapacity(0);
        uint256 id = _deposit(alice, 100e6);        // live, at the head
        _fund(stranger, 1);
        vm.prank(stranger);
        uint256 ghost = vault.requestDeposit(1, stranger, 0);  // zero entry behind alice
        uint256 len = ghost + 1;
        _blacklist(bob);

        // 1. ZeroRecipient wins over everything (bad id, stranger, zero amount).
        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.requestDepositCancellation(len + 9, address(0), 0);

        // 2. VaultIsRecipient, before the id is read.
        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestDepositCancellation(len + 9, address(vault), 0);

        // 3. InvalidRequestId: id == length and above, before NoRequest / owner / amount checks.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.requestDepositCancellation(len, bob, 0);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.requestDepositCancellation(type(uint256).max, bob, 0);

        // 4. NoRequest on a zero entry, before NotRequestOwner and the amount checks.
        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(ghost, bob, 0);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(ghost, bob, 0);

        // 5. NotRequestOwner, before the amount checks (zero and oversized amounts alike).
        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id, bob, 0);
        vm.prank(stranger);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.requestDepositCancellation(id, bob, type(uint256).max);

        // 6. BelowMinDepositCancellation: 0 and min - 1, before SavingsSharesTooHigh is reachable.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, bob, 0);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, bob, 10_000_000 - 1);

        // 7. SavingsSharesTooHigh: shares + 1 and max.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, bob, SS_100 + 1);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, bob, type(uint256).max);

        // Nothing moved.
        (, , uint256 shares) = _depositRequest(id);
        assertEq(shares, SS_100);
        assertEq(vault.pendingDepositSavingsShares(),          SS_100);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_cancelledDepositQueueLength(),               0);
        assertEq(vault.firstPendingDepositId(),                id);

        // Boundaries: exactly the minimum (to the blacklisted bob: accepted), then exactly the rest.
        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 0, bob, 10_000_000);
        uint256 cid0 = _cancelDepositPartial(alice, id, bob, 10_000_000);
        (, , shares) = _depositRequest(id);
        assertEq(shares, SS_100 - 10_000_000);
        assertEq(vault.firstPendingDepositId(), id);  // still live

        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 1, alice, SS_100 - 10_000_000);
        uint256 cid1 = _cancelDepositPartial(alice, id, alice, SS_100 - 10_000_000);
        assertEq(cid0, 0);
        assertEq(cid1, 1);
        assertEq(vault.firstPendingDepositId(), len);  // self-skip over alice's and the ghost's entries
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100);

        // Settlement: bob is blacklisted so his chunk is parked as claimable, alice is paid.
        _settleCancelled();
        assertEq(usdc.balanceOf(bob),         0);
        assertEq(vault.claimableAssets(bob),  10_476_330);  // 10_000_000 * chi_s / RAY
        assertEq(vault.totalClaimable(),      10_476_330);
        assertEq(usdc.balanceOf(alice),       89_523_669);  // 85_453_269 * chi_s / RAY
        assertEq(usdc.balanceOf(alice) + vault.claimableAssets(bob), 99_999_999);
    }

    // A ghost deposit entry (1 wei of USDC, shares 0) is `NoRequest` for a cancel and for a
    // recipient update, for its owner too. Queued behind a live head so it stays readable.
    function test_requestDepositCancellation_revertsNoRequest_ghost() public {
        _setCapacity(0);
        _deposit(bob, 100e6);
        _fund(alice, 1);
        vm.prank(alice);
        uint256 id = vault.requestDeposit(1, alice, 0);
        (address owner, , uint256 shares) = _depositRequest(id);
        assertEq(owner,  alice);
        assertEq(shares, 0);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, alice, 1);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositRecipient(id, bob);
    }

    // Nobody is blacklist-checked any more (no `isBlacklisted` call left at c512609). A
    // depositor blacklisted after queuing can cancel to a clean address and is paid there, or
    // to themselves and the refund parks as `claimableAssets` until they are clean again; the
    // same on the redeem side. The vault never moves USDC to or from the blacklisted owner, so
    // USDC's own checks do not fire on the request. Information: blacklisting a depositor does
    // not freeze their queued capital, only the final USDC leg.
    function test_requestDepositCancellation_blacklistedOwnerRoutesRefundToCleanRecipient() public {
        _deposit(carol, 100e6);
        _setCapacity(0);
        uint256 id  = _deposit(alice, 100e6);
        uint256 id2 = _deposit(alice, 100e6);
        _setCapacity(type(uint128).max);
        _blacklist(alice);

        // To a clean recipient: paid directly.
        uint256 cid = _cancelDeposit(alice, id, bob);
        (address owner, address recipient, ) = _cancelledDepositRequest(cid);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        _settleCancelled();
        assertEq(usdc.balanceOf(bob),   99_999_999);
        assertEq(usdc.balanceOf(alice), 0);

        // To herself: accepted at request time, parked at settlement.
        uint256 cid2 = _cancelDeposit(alice, id2, alice);
        vm.expectEmit(address(vault));
        emit ClaimableAssetsIncreased(alice, 99_999_999);
        vm.expectEmit(address(vault));
        emit DepositCancellation(cid2, alice, alice, SS_100, 99_999_999);
        _settleCancelled();
        assertEq(usdc.balanceOf(alice),        0);
        assertEq(vault.claimableAssets(alice), 99_999_999);
        assertEq(vault.totalClaimable(),       99_999_999);

        // Redeem side: carol blacklisted, to herself (parked) and to bob (paid).
        _blacklist(carol);
        vm.prank(carol);
        vault.requestRedeem(SH_100 / 2, carol);
        vm.prank(carol);
        vault.requestRedeem(SH_100 - SH_100 / 2, bob);
        _processRedeems(type(uint256).max, 2);
        assertEq(vault.claimableAssets(carol), 49_999_998);
        assertEq(usdc.balanceOf(bob),          99_999_999 + 49_999_999);
        assertEq(vault.totalClaimable(),       99_999_999 + 49_999_998);
        assertEq(usdc.balanceOf(address(vault)), vault.totalClaimable());
    }

    // R4-B FIXED (now by try/catch at c512609): a cancellation recipient blacklisted between
    // the cancel and the settlement no longer blocks the queue. `_redeemSavings`
    // (src/SparkPrimeVault.sol:978-995) tries the payout, and on the USDC revert redeems to the
    // vault itself and credits `claimableAssets[recipient]` + `totalClaimable`; the queue keeps
    // moving (bob behind alice is paid in the same call); `claim` reverts in USDC while
    // blacklisted and pays the exact amount once un-blacklisted.
    function test_fixed_processPendingDepositCancellations_recipientBlacklistedAfterCancel() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        uint256 cidA = _cancelDeposit(alice, idA, alice);
        uint256 cidB = _cancelDeposit(bob,   idB, bob);

        _blacklist(alice);

        // Repointing to a blacklisted address (herself) is accepted; the fallback handles it.
        vm.prank(alice);
        vault.updateDepositCancellationRecipient(cidA, alice);
        assertEq(vault.totalClaimable(), 0);

        vm.expectEmit(address(vault));
        emit ClaimableAssetsIncreased(alice, 99_999_999);
        vm.expectEmit(address(vault));
        emit DepositCancellation(cidA, alice, alice, SS_100, 99_999_999);
        vm.expectEmit(address(vault));
        emit DepositCancellation(cidB, bob, bob, SS_100, 99_999_999);
        _settleCancelled();

        assertEq(usdc.balanceOf(alice),          0);
        assertEq(usdc.balanceOf(bob),            99_999_999);
        assertEq(usdc.balanceOf(address(vault)), 99_999_999);  // alice's refund parked in the vault
        assertEq(vault.claimableAssets(alice),   99_999_999);
        assertEq(vault.claimableAssets(bob),     0);
        assertEq(vault.totalClaimable(),         99_999_999);
        assertEq(_vaultSpUsdc(),                 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),    2);
        (, , uint256 leftA) = _rawCancelledDepositRequest(cidA);
        (, , uint256 leftB) = _rawCancelledDepositRequest(cidB);
        assertEq(leftA, 0);
        assertEq(leftB, 0);

        // Parked USDC is invisible to the vault's accounting and cannot be repointed.
        assertEq(vault.availableLiquidAssets(), 0);
        assertEq(vault.totalAssets(),           0);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateDepositCancellationRecipient(cidA, bob);

        // claim: reverts in USDC while blacklisted (state untouched), pays after.
        vm.expectRevert(BLACKLISTED);
        vault.claim(alice);
        assertEq(vault.claimableAssets(alice), 99_999_999);

        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(bob);

        _unblacklist(alice);
        vm.expectEmit(address(vault));
        emit Claim(alice, 99_999_999);
        vm.prank(stranger);  // permissionless
        uint256 paid = vault.claim(alice);
        assertEq(paid,                           99_999_999);
        assertEq(usdc.balanceOf(alice),          99_999_999);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.claimableAssets(alice),   0);
        assertEq(vault.totalClaimable(),         0);

        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(alice);
    }

    // A cancellation partially settled before the blacklist and completed after it: the first
    // chunk is paid directly, the rest is credited as claimable; the two sum to the one-shot
    // refund exactly (38_181_306 + 57_271_963 shares -> 39_999_998 + 60_000_001 USDC).
    function test_processPendingDepositCancellations_partialThenBlacklistSplitsPayout() public {
        uint256 id  = _queueDeposit(alice, 100e6);
        uint256 cid = _cancelDeposit(alice, id, alice);

        _processCancelledDeposits(38_181_306, 10);
        assertEq(usdc.balanceOf(alice), 39_999_998);
        (, , uint256 left) = _cancelledDepositRequest(cid);
        assertEq(left, 57_271_963);

        _blacklist(alice);
        vm.expectEmit(address(vault));
        emit ClaimableAssetsIncreased(alice, 60_000_001);
        _settleCancelled();

        assertEq(usdc.balanceOf(alice),          39_999_998);
        assertEq(vault.claimableAssets(alice),   60_000_001);
        assertEq(usdc.balanceOf(address(vault)), 60_000_001);
        assertEq(vault.firstPendingDepositCancellationId(), 1);

        _unblacklist(alice);
        vault.claim(alice);
        assertEq(usdc.balanceOf(alice), 99_999_999);
    }

    // Claimable USDC parked in the vault is not touched by deposits (`requestDeposit` pulls and
    // forwards exactly `assets_`, :400-402), by `take` (spUSDC only) or by fills; a second
    // blacklisted payout accumulates on top of it.
    function test_claim_parkedUsdcIsIsolatedFromDepositsAndTake() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, alice);
        _blacklist(alice);
        _settleCancelled();
        assertEq(usdc.balanceOf(address(vault)), 99_999_999);

        _deposit(bob, 1_000_000e6);  // instant fill through the vault's USDC balance
        assertEq(usdc.balanceOf(address(vault)), 99_999_999);
        assertEq(_vaultSpUsdc(),                 SS_1M);

        _takeAll();
        assertEq(usdc.balanceOf(address(vault)), 99_999_999);
        _returnToVault(SS_1M);

        // A redeem paid to blacklisted alice stacks onto the same claimable slot.
        vm.prank(bob);
        vault.transfer(alice, SH_100);
        vm.prank(alice);
        vault.requestRedeem(SH_100, bob);  // recipient clean at request time
        _blacklist(bob);
        _processRedeems(type(uint256).max, 1);
        assertEq(vault.claimableAssets(bob),     99_999_998);
        assertEq(usdc.balanceOf(address(vault)), 99_999_999 + 99_999_998);

        _unblacklist(alice);
        _unblacklist(bob);
        vault.claim(alice);
        vault.claim(bob);
        assertEq(usdc.balanceOf(alice),          99_999_999);
        assertEq(usdc.balanceOf(bob),            99_999_998);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // If USDC blacklists the prime vault itself, the cancellation and redeem queues keep paying
    // clean recipients (the USDC moves spUSDC -> recipient, never through the vault), but a
    // blacklisted recipient's fallback (redeem to the vault) and `claim` revert, and new
    // deposits revert in USDC. The planner can still clear the queue for clean recipients.
    function test_processPendingDepositCancellations_vaultBlacklistedStillPaysCleanRecipients() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        _cancelDeposit(alice, idA, alice);
        _cancelDeposit(bob,   idB, bob);
        _setCapacity(type(uint128).max);
        _deposit(carol, 100e6);
        _requestRedeem(carol, SH_100);

        _fund(stranger, 1e6);  // approve before the blacklist (USDC rejects a blacklisted spender)
        _blacklist(address(vault));

        vm.prank(stranger);
        vm.expectRevert(BLACKLISTED);
        vault.requestDeposit(1e6, stranger, 0);

        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(usdc.balanceOf(bob),   99_999_999);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(carol), 99_999_998);

        // A blacklisted recipient would need the vault to receive USDC: blocked, entry stays.
        _unblacklist(address(vault));
        uint256 idD = _queueDeposit(alice, 100e6);
        uint256 cidD = _cancelDeposit(alice, idD, alice);
        _blacklist(alice);
        _blacklist(address(vault));
        vm.prank(operator);
        vm.expectRevert(BLACKLISTED);
        vault.processPendingDepositCancellations(type(uint256).max, 1);
        (, , uint256 leftD) = _cancelledDepositRequest(cidD);
        assertEq(leftD, SS_100);
    }

    // V2-13 (open): the spUSDC address passes the blacklist check, so a cancel (or redeem) to
    // it donates the refund to spUSDC's own USDC balance; nothing in either vault credits it.
    function test_BUG_requestDepositCancellation_recipientSpUsdcDonatesRefund() public {
        uint256 id = _queueDeposit(alice, 100e6);
        uint256 spUsdcBefore = usdc.balanceOf(address(spUsdc));
        uint256 spTotalAssetsBefore = spUsdc.totalAssets();

        _cancelDeposit(alice, id, address(spUsdc));
        _settleCancelled();

        assertEq(usdc.balanceOf(address(spUsdc)), spUsdcBefore);  // spUSDC paid itself: no USDC moved
        assertEq(usdc.balanceOf(alice),           0);
        assertEq(_vaultSpUsdc(),                  0);
        assertEq(spUsdc.totalAssets(),            spTotalAssetsBefore - 99_999_999);  // liability dropped
        assertEq(usdc.balanceOf(address(spUsdc)) - spUsdc.totalAssets(), 100_000_000);  // unaccounted liquidity
    }

    /**********************************************************************************************/
    /*** 18. Round 5: cancel economics                                                          ***/
    /**********************************************************************************************/

    // Deposit / cancel / settle round trip at the ugly spUSDC index, any amount, with up to ten
    // years of spUSDC accrual while queued: the refund is `floor(floor(a * RAY / chi) * chi' / RAY)`,
    // never more than the deposit plus accrual, and with no accrual never more than 2 wei
    // under the deposit (chi_s < 2 RAY).
    function testFuzz_requestDepositCancellation_roundTripExact(uint256 amount, uint256 yrs) public {
        amount = bound(amount, 1, 1e15);  // up to 1e9 USDC
        yrs    = bound(yrs,    0, 10);
        _setCapacity(0);
        uint256 id = _deposit(alice, amount);
        (, , uint256 ss) = _rawDepositRequest(id);
        assertEq(ss, amount * RAY / CHI_S);

        if (ss == 0) {
            // C-11: 1 wei of USDC mints 0 spUSDC shares; the entry is a ghost and the wei is
            // donated to spUSDC (nothing to cancel, nothing to refund).
            assertEq(amount, 1);
            vm.prank(alice);
            vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
            vault.requestDepositCancellation(id, alice, 1);
            assertEq(usdc.balanceOf(alice), 0);
            assertEq(usdc.balanceOf(address(spUsdc)) - spUsdc.totalAssets(), 1);
            return;
        }

        if (yrs != 0) {
            _setSpUsdcVsr(UGLY_SP_VSR);
            _warpAndDrip(yrs * 365 days);
        }
        uint256 chiS = spUsdc.nowChi();
        // Fund spUSDC's notional accrual so the settlement is not liquidity-clamped.
        _returnSpUsdcLiquidity(spUsdc.totalAssets() + 1);

        _cancelDeposit(alice, id, alice);
        _settleCancelled();

        uint256 refund = usdc.balanceOf(alice);
        assertEq(refund, ss * chiS / RAY);
        assertLe(refund, amount * chiS / CHI_S);
        if (yrs == 0) {
            assertLe(refund, amount);
            assertLe(amount - refund, 2);
        }
        assertEq(_vaultSpUsdc(), 0);
        assertEq(vault.pendingDepositSavingsShares(),          0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
    }

    // `pendingCancelledDepositSavingsShares` is the sum of open cancelled entries after every
    // step of a mixed sequence (three cancels, two partial settlements, a completion).
    function test_pendingCancelledDepositSavingsShares_tracksOpenEntries() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   1_000_000e6);
        uint256 idC = _deposit(carol, 100e6);

        uint256 cidA = _cancelDeposit(alice, idA, alice);
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100);
        uint256 cidB = _cancelDeposit(bob, idB, bob);
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100 + SS_1M);
        uint256 cidC = _cancelDeposit(carol, idC, carol);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 2 * SS_100 + SS_1M);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        _processCancelledDeposits(SS_100 + 1, 10);  // alice in full, bob 1 wei
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100 + SS_1M - 1);
        assertEq(_sumOpenCancelled(cidA, cidC), SS_100 + SS_1M - 1);
        assertEq(vault.firstPendingDepositCancellationId(), cidB);
        assertEq(usdc.balanceOf(bob), 1);

        _processCancelledDeposits(SS_1M - 1 + 1_000, 1);  // bob completes; carol out of budget by requests
        assertEq(vault.pendingCancelledDepositSavingsShares(), SS_100);
        assertEq(_sumOpenCancelled(cidA, cidC), SS_100);
        assertEq(usdc.balanceOf(bob), 999_999_999_998);  // 1 wei + remainder: chunking cost 1 wei

        _settleCancelled();
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(_sumOpenCancelled(cidA, cidC), 0);
        assertEq(usdc.balanceOf(carol), 99_999_999);
        assertEq(_vaultSpUsdc(), 0);
    }

    function _sumOpenCancelled(uint256 from, uint256 to) internal view returns (uint256 sum) {
        for (uint256 i = from; i <= to; ++i) {
            (, , uint256 sh) = _rawCancelledDepositRequest(i);
            sum += sh;
        }
    }

    // The "free option" after `adjustTotalAssets`: a queued deposit is spUSDC, not spPRIME, so a
    // loss realised while it is queued does not touch it, and the cancel (now allowed during the
    // pause) returns the same 99_999_999 before, during and after the loss. Filled after the
    // loss, the same entry mints twice the shares for the same value. There is no option value
    // in the cancel: the refund is index-independent, and nothing a queued depositor does
    // between the loss and the unpause changes what they get.
    function test_requestDepositCancellation_queuedDepositIsImmuneToLoss() public {
        _deposit(carol, 100e6);  // the holder who takes the loss
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        uint256 idD = _deposit(stranger, 100e6);

        _cancelDeposit(alice, idA, alice);
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);

        _pause();
        _adjustTotalAssets(-50e6);
        assertEq(vault.assetsOf(carol), 49_999_997);  // floor of (99_999_998 - 50e6) through chi

        // Bob cancels and is settled during the pause, after the loss: identical refund.
        _cancelDeposit(bob, idB, bob);
        _settleCancelled();
        assertEq(usdc.balanceOf(bob), 99_999_999);
        _unpause();

        // Stranger is filled after the loss instead: same value, at the new (lower) chi.
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        (, , uint256 leftD) = _rawDepositRequest(idD);
        assertEq(leftD, 0);
        assertEq(vault.assetsOf(stranger),  99_999_998);
        assertEq(vault.balanceOf(stranger), 198_081_039);  // ~2x SH_100
        assertEq(vault.nowChi(), 0.504843871119937711956814603e27);
    }

    // The mirror with a gain: a queued deposit does not share in a gain either (it is filled at
    // the higher chi for fewer shares of the same value), while a cancel before or after the
    // gain refunds the same amount. Escrowed redeem shares DO take both the loss and the gain.
    function test_requestDepositCancellation_queuedDepositDoesNotShareGain() public {
        _deposit(carol, 100e6);
        uint256 rid = _requestRedeem(carol, SH_100 / 2);  // half escrowed
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);

        _pause();
        _adjustTotalAssets(100e6);  // doubles chi: 99_999_998 -> 199_999_998 notional
        assertEq(vault.totalAssets(), 199_999_997);
        _cancelDeposit(alice, idA, alice);
        _settleCancelled();
        _unpause();
        assertEq(usdc.balanceOf(alice), 99_999_999);  // no share of the gain

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);
        (, , uint256 leftB) = _rawDepositRequest(idB);
        assertEq(leftB, 0);
        assertEq(vault.balanceOf(bob), 49_520_258);  // half the shares...
        assertEq(vault.assetsOf(bob),  99_999_997);  // ...for the same value (1 wei of floor)

        // The escrow doubled in value: carol's half-redeem now pays ~100e6 (liquidity permitting).
        assertEq(vault.convertToAssets(SH_100 / 2), 99_999_997);
        (, , uint256 escrow) = _redeemRequest(rid);
        assertEq(escrow, SH_100 / 2);
    }

    // The ordering between a cancel and a fill is the operator's: `processPendingDeposits`
    // in the same block (or the instant fill of a later request walking the queue) fills the
    // entry first and the owner's cancel then fails `no-request`. Forced into shares, the owner's
    // only exit is the redeem queue: 1% fee (1_000_001 USDC on 100e6), no cancel, and a wait
    // bounded by spUSDC liquidity. The owner has no parameter to defend with.
    function test_processPendingDeposits_frontRunsCancel_ownerHasNoDefence() public {
        _setRedeemFeeRate(0.01e18);
        uint256 id = _queueDeposit(alice, 100e6);
        // alice decides to leave; before her cancel lands the planner processes the queue.
        _processDeposits(type(uint256).max, 1);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.requestDepositCancellation(id, alice, 1);
        assertEq(vault.balanceOf(alice), SH_100);

        // Cheapest exit now: redeem request, 1% fee, wait for liquidity.
        _drainAllSpUsdcLiquidity();
        uint256 rid = _requestRedeem(alice, SH_100);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 0);  // nothing liquid: waits
        (, , uint256 left) = _redeemRequest(rid);
        assertEq(left, SH_100 - 990_406);

        _returnSpUsdcLiquidity(200e6);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 98_999_997);
        assertEq(99_999_999 - usdc.balanceOf(alice), 1_000_002);  // cost of losing the race

        // Second shape: a later instant-fill request walks the queue and fills alice's entry.
        uint256 id2 = _queueDeposit(alice, 100e6);
        _fund(bob, 1e6);
        vm.prank(bob);
        vault.requestDeposit(1e6, bob, 0);  // bob's request is queued (alice ahead), no walk
        (, , uint256 leftA) = _depositRequest(id2);
        assertEq(leftA, SS_100);  // predicate false (two live entries), alice still cancellable
        _cancelDeposit(alice, id2, alice);
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 98_999_997 + 99_999_999);
    }

    // Cancel of the head after a partial fill then a refill of the next entry: the dead head
    // slot is skipped, the next live entry is filled, nothing is double-counted in
    // `pendingDepositSavingsShares`.
    function test_requestDepositCancellation_partialFillCancelThenRefillOrdering() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);

        _setCapacity(39_616_207);
        _processDeposits(type(uint256).max, 10);
        assertEq(vault.balanceOf(alice), 39_616_205);
        assertEq(vault.firstPendingDepositId(), idA);
        assertEq(vault.pendingDepositSavingsShares(), 57_271_963 + SS_100);

        _cancelDeposit(alice, idA, alice);
        assertEq(vault.pendingDepositSavingsShares(),          SS_100);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 57_271_963);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 2);
        assertEq(vault.balanceOf(bob),   SH_100);
        assertEq(vault.balanceOf(alice), 39_616_205);
        assertEq(vault.firstPendingDepositId(), idB + 1);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 60_000_001);
        assertEq(_vaultSpUsdc(), 38_181_306 + SS_100);
    }


    // The cancellation queue's mirror of C-1 holds: the budget `spUSDC.maxRedeem(vault)`
    // (src/SparkPrimeVault.sol:870) floors shares once and every `redeem` floors assets, so with
    // any spUSDC liquidity L the settlement never reverts, pays at most L in total across any
    // number of entries, and the unpaid shortfall is at most `n + 2` wei of rounding.
    function testFuzz_processPendingDepositCancellations_liquidityClampNeverReverts(
        uint256 liquidity, uint256 n
    ) public {
        n = bound(n, 1, 8);
        _setCapacity(0);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            address who = makeAddr(string(abi.encodePacked("c", i)));
            uint256 amt = 1e6 * (i + 1) + 12_345 * i;
            uint256 id = _deposit(who, amt);
            _cancelDeposit(who, id, who);
            total += amt;
        }
        liquidity = bound(liquidity, 0, usdc.balanceOf(address(spUsdc)));
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - liquidity);

        uint256 budget = spUsdc.maxRedeem(address(vault));
        uint256 vaultSharesBefore = _vaultSpUsdc();
        _settleCancelled();  // must not revert

        uint256 paid = liquidity - usdc.balanceOf(address(spUsdc));
        assertLe(paid, liquidity);
        assertEq(vaultSharesBefore - _vaultSpUsdc(), _min(budget, vaultSharesBefore));
        assertEq(
            vault.pendingCancelledDepositSavingsShares(),
            vaultSharesBefore - _min(budget, vaultSharesBefore)
        );
        // When clamped, the unpaid shortfall is rounding only: the `maxRedeem` floor (< chi_s / RAY
        // + 1 wei) plus one floored `redeem` per entry touched.
        if (budget < vaultSharesBefore) assertLe(liquidity - paid, n + 2);
    }


    /**********************************************************************************************/
    /*** 19. Round 6: roles, fee boundaries, the all-fee ghost (R5-14)                          ***/
    /**********************************************************************************************/

    function _unauthorized(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, who, role
        );
    }

    // Every role boundary on the cancel / fee surface with the exact AccessControl error:
    // `processPendingDepositCancellations` OPERATOR only; `setRedeemFeeRate` REDEEM_FEE_SETTER
    // only; `setMaxRedeemFeeRate` / `setMinDepositCancellation` / `setMinRedeem` DEFAULT_ADMIN
    // only; `pause` PAUSER only (the unpauser cannot pause); `unpause` UNPAUSER only (neither the
    // pauser nor the admin can unpause); `adjustTotalAssets` LOSS_MANAGER only (not the admin).
    function test_roles_cancelAndFeeSurface() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, alice);

        address[8] memory notOperator =
            [admin, lossManager, pauser, unpauser, redeemFeeSetter, taker, stranger, alice];
        for (uint256 i; i < notOperator.length; ++i) {
            vm.prank(notOperator[i]);
            vm.expectRevert(_unauthorized(notOperator[i], OPERATOR_ROLE));
            vault.processPendingDepositCancellations(type(uint256).max, 1);
        }

        address[7] memory notFeeSetter =
            [admin, lossManager, operator, pauser, unpauser, taker, stranger];
        for (uint256 i; i < notFeeSetter.length; ++i) {
            vm.prank(notFeeSetter[i]);
            vm.expectRevert(_unauthorized(notFeeSetter[i], REDEEM_FEE_SETTER_ROLE));
            vault.setRedeemFeeRate(1);
        }

        address[7] memory notAdmin =
            [lossManager, operator, pauser, unpauser, redeemFeeSetter, taker, stranger];
        for (uint256 i; i < notAdmin.length; ++i) {
            vm.startPrank(notAdmin[i]);
            vm.expectRevert(_unauthorized(notAdmin[i], DEFAULT_ADMIN_ROLE));
            vault.setMaxRedeemFeeRate(0);
            vm.expectRevert(_unauthorized(notAdmin[i], DEFAULT_ADMIN_ROLE));
            vault.setMinDepositCancellation(1);
            vm.expectRevert(_unauthorized(notAdmin[i], DEFAULT_ADMIN_ROLE));
            vault.setMinRedeem(1);
            vm.stopPrank();
        }

        vm.prank(unpauser);
        vm.expectRevert(_unauthorized(unpauser, PAUSER_ROLE));
        vault.pause();
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, PAUSER_ROLE));
        vault.pause();
        _pause();

        vm.prank(pauser);
        vm.expectRevert(_unauthorized(pauser, UNPAUSER_ROLE));
        vault.unpause();
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, UNPAUSER_ROLE));
        vault.unpause();

        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, LOSS_MANAGER_ROLE));
        vault.adjustTotalAssets(1);
        vm.prank(operator);
        vm.expectRevert(_unauthorized(operator, LOSS_MANAGER_ROLE));
        vault.adjustTotalAssets(1);
        _unpause();

        assertFalse(vault.paused());
        assertEq(vault.redeemFeeRate(),         0);
        assertEq(vault.maxRedeemFeeRate(),      0.01e18);
        assertEq(vault.minDepositCancellation(), 1);
        assertEq(vault.minRedeem(),             1);
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 99_999_999);
    }

    // Cap boundaries with events: `setRedeemFeeRate` accepts exactly `maxRedeemFeeRate` and
    // rejects one wei more (`FeeTooHigh`); `setMaxRedeemFeeRate` accepts exactly `MAX_REDEEM_FEE`
    // (1%) and rejects one wei more (`MaxFeeTooHigh`); with max 0 only 0 is accepted.
    function test_setRedeemFeeRate_boundariesAndEvents() public {
        assertEq(vault.MAX_REDEEM_FEE(),   0.01e18);
        assertEq(vault.maxRedeemFeeRate(), 0.01e18);

        vm.expectEmit(address(vault));
        emit RedeemFeeRateSet(0.01e18);
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.01e18);
        assertEq(vault.redeemFeeRate(), 0.01e18);

        vm.prank(redeemFeeSetter);
        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
        vault.setRedeemFeeRate(0.01e18 + 1);

        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.MaxFeeTooHigh.selector);
        vault.setMaxRedeemFeeRate(0.01e18 + 1);

        vm.expectEmit(address(vault));
        emit MaxRedeemFeeRateSet(0.01e18);
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.01e18);

        vm.expectEmit(address(vault));
        emit MaxRedeemFeeRateSet(0.005e18);
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0.005e18);
        assertEq(vault.redeemFeeRate(), 0.01e18);  // C-7: the live fee is not clamped

        vm.prank(redeemFeeSetter);
        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
        vault.setRedeemFeeRate(0.005e18 + 1);
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0.005e18);
        assertEq(vault.redeemFeeRate(), 0.005e18);

        vm.expectEmit(address(vault));
        emit MaxRedeemFeeRateSet(0);
        vm.prank(admin);
        vault.setMaxRedeemFeeRate(0);
        vm.prank(redeemFeeSetter);
        vm.expectRevert(ISparkPrimeVault.FeeTooHigh.selector);
        vault.setRedeemFeeRate(1);
        vm.expectEmit(address(vault));
        emit RedeemFeeRateSet(0);
        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0);
        assertEq(vault.redeemFeeRate(), 0);
    }

    // R5-14 (open at c512609): with `minRedeem == 1` a 1-share `requestRedeem` at any non-zero
    // fee is an all-fee request (`_divUp(1 * fee, WAD) == 1`, :463): the queued entry has 0
    // shares, `pendingRedeemShares` does not move, nobody can update it (`NoRequest`), and the
    // redeem planner "fills" it with a zero burn, a `withdraw(0)` on spUSDC and a
    // `Redeem(id, owner, recipient, 0, 0, 0)`, spending one request slot per ghost. 1 share is
    // the only all-fee amount (ceil(n / 100) >= n only for n == 1), so `minRedeem >= 2` makes
    // the ghost unreachable; it is a launch-parameter question, not a code fix.
    function test_BUG_requestRedeem_minRedeemAllFeeLeavesZeroShareEntry() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, 100e6);
        _deposit(bob,   100e6);
        assertEq(vault.minRedeem(), 1);

        vm.expectEmit(address(vault));
        emit RedeemRequest(0, alice, alice, 1, 1);
        uint256 id = _requestRedeem(alice, 1);

        (address owner, address recipient, uint256 queued) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(queued,    0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.balanceOf(alice),          SH_100 - 1);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(),             2 * SH_100 - 1);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(id, bob);

        // Two shares: fee 1, queued 1 (not a ghost). minRedeem 2 makes the ghost unreachable.
        uint256 id2 = _requestRedeem(alice, 2);
        (, , queued) = _redeemRequest(id2);
        assertEq(queued, 1);
        _setMinRedeem(2);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(1, alice);
        _setMinRedeem(1);

        // The planner walks the ghost as a zero fill: one slot, nothing paid, no revert.
        vm.expectEmit(address(vault));
        emit Redeem(id, alice, alice, 0, 0, 0);
        _processRedeems(type(uint256).max, 1);
        assertEq(vault.firstPendingRedeemId(), 1);
        assertEq(usdc.balanceOf(alice),        0);

        // Bloat: 100 one-share requests cost alice 100 shares (a 100% fee) and the operator 100
        // request slots; the 2-share entry behind them pays 1 wei.
        for (uint256 i; i < 100; ++i) _requestRedeem(alice, 1);
        assertEq(_redeemQueueLength(),        102);
        assertEq(vault.balanceOf(alice),      SH_100 - 103);
        assertEq(vault.pendingRedeemShares(), 1);
        _processRedeems(type(uint256).max, 101);
        assertEq(vault.firstPendingRedeemId(), 102);
        assertEq(usdc.balanceOf(alice),        1);
        assertEq(vault.pendingRedeemShares(),  0);
        assertEq(vault.assetsOf(bob),          99_999_998);  // untouched
    }

    // The fee burn never changes what any other holder can claim (chi is index-based), the
    // surplus spUSDC it leaves equals the fee's value within rounding, and `adjustTotalAssets`
    // credits that surplus to the remaining holder within 1 wei, for any amounts and any fee.
    function testFuzz_requestRedeem_feeBurnLeavesOtherHoldersUnchanged(
        uint256 aliceAmt, uint256 bobAmt, uint256 feeRate
    ) public {
        aliceAmt = bound(aliceAmt, 1e6, 1e15);
        bobAmt   = bound(bobAmt,   1e6, 1e15);
        feeRate  = bound(feeRate,  1,   0.01e18);
        _setRedeemFeeRate(feeRate);
        _deposit(bob,   bobAmt);
        _deposit(alice, aliceAmt);

        uint256 bobBefore    = vault.assetsOf(bob);
        uint256 chiBefore    = vault.nowChi();
        uint256 shares       = vault.balanceOf(alice);
        uint256 fee          = _ceil(shares * feeRate, WAD);
        uint256 supplyBefore = vault.totalSupply();

        _requestRedeem(alice, shares);
        assertEq(vault.totalSupply(),  supplyBefore - fee);
        assertEq(vault.assetsOf(bob),  bobBefore);
        assertEq(vault.nowChi(),       chiBefore);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), vault.convertToAssets(shares - fee));
        assertEq(vault.assetsOf(bob),   bobBefore);
        assertEq(vault.totalSupply(),   vault.balanceOf(bob));

        // Surplus == fee value up to the floors on the way (two deposits, one fill, one ceil on
        // the spUSDC withdraw, one floor on each conversion): at most 6 wei apart.
        uint256 surplus  = spUsdc.convertToAssets(_vaultSpUsdc()) - vault.totalAssets();
        uint256 feeValue = vault.convertToAssets(fee);
        assertLe(surplus,  feeValue + 6);
        assertGe(surplus + 6, feeValue);

        if (surplus == 0) return;
        _adjustTotalAssetsWhilePaused(int256(surplus));
        assertLe(vault.assetsOf(bob), bobBefore + surplus);
        assertLe(bobBefore + surplus - vault.assetsOf(bob), 1);
        assertLe(spUsdc.convertToAssets(_vaultSpUsdc()) - vault.totalAssets(), 1);
    }

    /**********************************************************************************************/
    /*** 20. Round 6: partial cancels                                                           ***/
    /**********************************************************************************************/

    // Several partial cancels of one request, each to its own recipient and its own cancelled
    // entry; the entry stays live (head unchanged) until it is fully cancelled or filled. When
    // the remainder drops below `minDepositCancellation` it can no longer be cancelled at all
    // (`BelowMinDepositCancellation` on the remainder, `SavingsSharesTooHigh` on the minimum):
    // info / low, the remainder is simply filled later. Total value out across 3 chunks + the
    // fill is 99_999_996 vs 99_999_999 for a one-shot refund (one floor per leg).
    function test_requestDepositCancellation_partialCancels_remainderBelowMinIsStuck() public {
        _setMinDepositCancellation(30_000_000);
        uint256 id = _queueDeposit(alice, 100e6);

        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 0, alice, 30_000_000);
        uint256 cid0 = _cancelDepositPartial(alice, id, alice, 30_000_000);
        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 1, bob, 30_000_000);
        uint256 cid1 = _cancelDepositPartial(alice, id, bob, 30_000_000);
        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 2, carol, 30_000_000);
        uint256 cid2 = _cancelDepositPartial(alice, id, carol, 30_000_000);
        assertEq(cid0, 0);
        assertEq(cid1, 1);
        assertEq(cid2, 2);

        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    5_453_269);
        assertEq(vault.firstPendingDepositId(),                id);  // still live
        assertEq(vault.pendingDepositSavingsShares(),          5_453_269);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 90_000_000);
        assertEq(_vaultSpUsdc(),                               SS_100);

        ISparkPrimeVault.Request[] memory q = vault.getPendingDepositCancellationRequests();
        assertEq(q.length,       3);
        assertEq(q[0].owner,     alice);
        assertEq(q[0].recipient, alice);
        assertEq(q[1].recipient, bob);
        assertEq(q[2].recipient, carol);
        assertEq(q[0].shares + q[1].shares + q[2].shares, 90_000_000);

        // The remainder is stuck below the minimum.
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, 5_453_269);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, alice, 30_000_000);

        // It is still a live entry: repointable, and filled like any other.
        vm.prank(alice);
        vault.updateDepositRecipient(id, bob);

        vm.expectEmit(address(vault));
        emit DepositCancellation(cid0, alice, alice, 30_000_000, 31_428_991);
        vm.expectEmit(address(vault));
        emit DepositCancellation(cid1, alice, bob,   30_000_000, 31_428_991);
        vm.expectEmit(address(vault));
        emit DepositCancellation(cid2, alice, carol, 30_000_000, 31_428_991);
        _settleCancelled();
        assertEq(usdc.balanceOf(alice), 31_428_991);
        assertEq(usdc.balanceOf(bob),   31_428_991);
        assertEq(usdc.balanceOf(carol), 31_428_991);
        assertEq(vault.firstPendingDepositCancellationId(), 3);
        assertEq(_vaultSpUsdc(), 5_453_269);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.firstPendingDepositId(), id + 1);
        assertEq(vault.balanceOf(bob),  5_658_208);  // 5_713_024 USDC -> shares
        assertEq(vault.assetsOf(bob),   5_713_023);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(3 * 31_428_991 + vault.assetsOf(bob), 99_999_996);

        // Lowering the minimum would have freed the remainder.
        uint256 id2 = _queueDeposit(alice, 100e6);
        _cancelDepositPartial(alice, id2, alice, 90_000_000);
        _setMinDepositCancellation(1);
        _cancelDepositPartial(alice, id2, alice, 5_453_269);
        assertEq(vault.firstPendingDepositId(), id2 + 1);
    }

    // `minDepositCancellation` is denominated in spUSDC shares (:133), not USDC: at the harness
    // index a minimum of 100e6 means 104_763_305 USDC, so a 100 USDC deposit (95_453_269 shares)
    // cannot be cancelled at all, and the smallest cancellable deposit is 104_763_306 USDC. The
    // USDC value of the minimum drifts up with spUSDC's chi. Zero is rejected; event exact.
    function test_setMinDepositCancellation_isInSpUsdcShareUnits() public {
        vm.prank(admin);
        vm.expectRevert(ISparkPrimeVault.ZeroMinDepositCancellation.selector);
        vault.setMinDepositCancellation(0);

        vm.expectEmit(address(vault));
        emit MinDepositCancellationSet(100e6);
        _setMinDepositCancellation(100e6);
        assertEq(spUsdc.convertToAssets(100e6), 104_763_305);

        _setCapacity(0);
        uint256 id = _deposit(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, SS_100);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, alice, 100e6);

        uint256 idB = _deposit(bob, 104_763_305);
        (, , uint256 ssB) = _depositRequest(idB);
        assertEq(ssB, 99_999_999);  // one wei short of the minimum
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(idB, bob, ssB);

        uint256 idC = _deposit(carol, 104_763_306);
        (, , uint256 ssC) = _depositRequest(idC);
        assertEq(ssC, 100e6);
        _cancelDeposit(carol, idC, carol);
        _settleCancelled();
        assertEq(usdc.balanceOf(carol), 104_763_305);

        // Drift: a year of 5% spUSDC accrual raises the USDC value of the same share minimum.
        _setSpUsdcVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);
        assertEq(spUsdc.convertToAssets(100e6), 100e6 * spUsdc.nowChi() / RAY);
        assertGt(spUsdc.convertToAssets(100e6), 110_000_000);
        // Alice's 95_453_269 shares are now worth more than 100 USDC but still below the minimum.
        assertGt(spUsdc.convertToAssets(SS_100), 100e6);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
        vault.requestDepositCancellation(id, alice, SS_100);
    }

    // Cancel-vs-fill race with a partial fill in between: a cancel for the full original amount
    // lands after the planner filled part of it and fails `SavingsSharesTooHigh` (not
    // `NoRequest`); the owner must re-read the entry and cancel the remainder.
    function test_requestDepositCancellation_raceWithPartialFill_amountTooHigh() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _setCapacity(39_616_207);
        _processDeposits(type(uint256).max, 1);  // 38_181_306 shares filled
        assertEq(vault.balanceOf(alice), 39_616_205);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
        vault.requestDepositCancellation(id, alice, SS_100);

        (, , uint256 left) = _depositRequest(id);
        assertEq(left, 57_271_963);
        vm.expectEmit(address(vault));
        emit DepositCancellationRequest(id, 0, alice, 57_271_963);
        _cancelDepositPartial(alice, id, alice, left);
        assertEq(vault.firstPendingDepositId(), id + 1);

        _settleCancelled();
        assertEq(usdc.balanceOf(alice),  60_000_001);
        assertEq(vault.balanceOf(alice), 39_616_205);
        assertEq(vault.assetsOf(alice) + usdc.balanceOf(alice), 99_999_998);
    }

    // Partial-cancel accounting, fuzzed: up to three partial cancels of random size (each >=
    // `minDepositCancellation`) of one deposit of any size. After every step
    // `pendingDepositSavingsShares + pendingCancelledDepositSavingsShares == ss`, the entry holds
    // exactly the remainder and stays at the head while live, each cancelled entry holds its
    // chunk, settlement pays `sum floor(chunk * chi_s / RAY)` (at most k wei under the one-shot
    // refund), and the remainder fills for its value. Nothing is double counted or lost beyond
    // one wei per leg.
    function testFuzz_requestDepositCancellation_partialCancelsAccounting(
        uint256 amount, uint256 c1, uint256 c2, uint256 c3, uint256 minCancel
    ) public {
        amount = bound(amount, 10e6, 1e15);
        _setCapacity(0);
        uint256 id = _deposit(alice, amount);
        (, , uint256 ss) = _depositRequest(id);
        assertEq(ss, amount * RAY / CHI_S);
        minCancel = bound(minCancel, 1, ss / 4);
        _setMinDepositCancellation(minCancel);

        uint256[3] memory chunks = [c1, c2, c3];
        uint256 remaining = ss;
        uint256 cancelled;
        uint256 expectedPaid;
        uint256 k;
        for (uint256 i; i < 3; ++i) {
            if (remaining < minCancel) break;
            uint256 c = bound(chunks[i], minCancel, remaining);

            vm.expectEmit(address(vault));
            emit DepositCancellationRequest(id, k, alice, c);
            uint256 cid = _cancelDepositPartial(alice, id, alice, c);
            assertEq(cid, k);

            remaining    -= c;
            cancelled    += c;
            expectedPaid += c * CHI_S / RAY;
            ++k;

            assertEq(vault.pendingDepositSavingsShares(),          remaining);
            assertEq(vault.pendingCancelledDepositSavingsShares(), cancelled);
            (, , uint256 csh) = _cancelledDepositRequest(cid);
            assertEq(csh, c);
            if (remaining == 0) {
                assertEq(vault.firstPendingDepositId(), id + 1);
                (address o, , uint256 sh) = _rawDepositRequest(id);
                assertEq(o,  address(0));
                assertEq(sh, 0);
            } else {
                assertEq(vault.firstPendingDepositId(), id);
                (, , uint256 sh) = _depositRequest(id);
                assertEq(sh, remaining);
            }
        }
        assertEq(cancelled + remaining, ss);

        if (remaining != 0) {
            if (minCancel > 1) {
                vm.prank(alice);
                vm.expectRevert(ISparkPrimeVault.BelowMinDepositCancellation.selector);
                vault.requestDepositCancellation(id, alice, minCancel - 1);
            }
            uint256 tooHigh = remaining + 1 > minCancel ? remaining + 1 : minCancel;
            vm.prank(alice);
            vm.expectRevert(ISparkPrimeVault.SavingsSharesTooHigh.selector);
            vault.requestDepositCancellation(id, alice, tooHigh);
        }

        _settleCancelled();
        assertEq(usdc.balanceOf(alice), expectedPaid);
        assertLe(expectedPaid, cancelled * CHI_S / RAY);
        assertLe(cancelled * CHI_S / RAY - expectedPaid, k);
        assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositCancellationId(),    k);
        assertEq(_vaultSpUsdc(),                               remaining);

        if (remaining != 0) {
            _setCapacity(type(uint128).max);
            _processDeposits(type(uint256).max, 1);
            assertEq(vault.firstPendingDepositId(), id + 1);
            uint256 remainderValue = remaining * CHI_S / RAY;
            assertLe(vault.assetsOf(alice), remainderValue);
            assertLe(remainderValue - vault.assetsOf(alice), 2);  // shares floor + assets floor
        }
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertLe(expectedPaid + vault.assetsOf(alice), amount);
        assertLe(amount - expectedPaid - vault.assetsOf(alice), k + 3);
    }

    /**********************************************************************************************/
    /*** 21. Round 6: the self-skip walk as a griefing surface (R5-9 residual)                  ***/
    /**********************************************************************************************/

    // R5-9 residual (open, low / liveness): every cancel ends with `_processPendingDeposits(0,
    // type(uint256).max)` (:445) and every request whose predicate holds (:400) with a full walk,
    // both unbounded in `maxRequests_`. Dead entries (full cancels, or 1-wei ghosts) behind a
    // live head are walked by whoever cancels that head or deposits once it is gone. A griefer
    // who parks N dead entries behind a queued depositor makes that depositor's full cancel cost
    // ~N x 2_270 gas (cold SLOAD per entry): ~13_000 entries exceed a 30M block. The depositor
    // can still partially cancel everything but `minDepositCancellation` (the walk breaks at
    // their own live remainder), and the operator clears dead entries in bounded batches with
    // budget 0. Cost to the griefer: minDeposit of capital (recycled if settled) and ~150k gas
    // per entry. Here minDeposit = 1e6 and the operator settles each cycle.
    function test_BUG_requestDepositCancellation_deadEntriesBehindHeadMakeCancelUnboundedGas() public {
        _setMinDeposit(1e6);
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);

        // Baseline: alice (head) cancels with bob live right behind: the walk skips 1, breaks at 1.
        _cool();
        vm.prank(alice);
        uint256 gas = gasleft();
        vault.requestDepositCancellation(idA, alice, SS_100);
        uint256 baseline = gas - gasleft();
        assertEq(vault.firstPendingDepositId(), idB);

        // Griefer: 1000 request / cancel cycles behind bob; each cancel's walk breaks at bob.
        // (Settled in one batch here to stay inside the test gas limit; settling each cycle
        // recycles the same 1e6 and costs the griefer 1 wei per cycle.)
        uint256 n = 1000;
        _fund(stranger, n * 1e6);
        for (uint256 i; i < n; ++i) {
            vm.prank(stranger);
            uint256 gid = vault.requestDeposit(1e6, stranger, 0);
            assertEq(gid, idB + 1 + i);
            vm.prank(stranger);
            vault.requestDepositCancellation(gid, stranger, 954_532);  // 1e6 * RAY / chi_s
            assertEq(vault.firstPendingDepositId(), idB);
        }
        _settleCancelled();
        assertEq(usdc.balanceOf(stranger), n * 1e6 - n);  // 1 wei per cycle
        uint256 idC = _deposit(carol, 100e6);
        assertEq(idC, idB + 1 + n);

        // Bob's full cancel must now walk his own entry plus the 1000 dead ones to reach carol.
        _cool();
        vm.prank(bob);
        gas = gasleft();
        vault.requestDepositCancellation(idB, bob, SS_100);
        uint256 withDead = gas - gasleft();
        assertEq(vault.firstPendingDepositId(), idC);

        uint256 perEntry = (withDead - baseline) / n;
        emit log_named_uint("cancel gas, 1 dead entry walked",     baseline);
        emit log_named_uint("cancel gas, 1001 dead entries walked", withDead);
        emit log_named_uint("gas per dead entry",                   perEntry);
        emit log_named_uint("dead entries for a 30M-gas cancel",    (30_000_000 - baseline) / perEntry);
        assertGt(perEntry, 2_100);  // at least one cold SLOAD per entry
        assertLt(perEntry, 2_600);

        // Escape hatch: a partial cancel of all but `minDepositCancellation` breaks at the
        // owner's own live remainder, whatever sits behind it.
        _setMinDepositCancellation(900_000);
        _fund(stranger, n * 1e6);
        for (uint256 i; i < n; ++i) {
            vm.prank(stranger);
            uint256 gid = vault.requestDeposit(1e6, stranger, 0);
            vm.prank(stranger);
            vault.requestDepositCancellation(gid, stranger, 954_532);
        }
        _settleCancelled();
        _cool();
        vm.prank(carol);
        gas = gasleft();
        vault.requestDepositCancellation(idC, carol, SS_100 - 900_000);
        uint256 partialGas = gas - gasleft();
        assertLt(partialGas, baseline + 20_000);  // no walk beyond carol's own entry
        (, , uint256 leftC) = _depositRequest(idC);
        assertEq(leftC, 900_000);
        assertEq(vault.firstPendingDepositId(), idC);

        // Deposit side: once carol's remainder is filled the dead entries are at the head and
        // the next request's instant walk pays for all of them...
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.firstPendingDepositId(), idC + 1);
        assertEq(vault.getPendingDepositRequests().length, n);
        _cool();
        _fund(stranger, 100e6);
        vm.prank(stranger);
        gas = gasleft();
        vault.requestDeposit(100e6, stranger, 0);
        uint256 depositWalk = gas - gasleft();
        assertEq(vault.firstPendingDepositId(), idC + 2 + n);
        assertGt(depositWalk, n * 2_100);
        emit log_named_uint("requestDeposit gas walking 1000 dead entries", depositWalk);

        // ...while the operator can always clear them in bounded batches with budget 0.
        _setCapacity(0);
        uint256 idD = _deposit(alice, 100e6);
        _fund(stranger, 300e6);
        for (uint256 i; i < 300; ++i) {
            vm.prank(stranger);
            uint256 gid = vault.requestDeposit(1e6, stranger, 0);
            vm.prank(stranger);
            vault.requestDepositCancellation(gid, stranger, 954_532);
        }
        _settleCancelled();
        _processDeposits(0, 1);   // budget 0, live head: no progress
        assertEq(vault.firstPendingDepositId(), idD);
        _cancelDepositPartial(alice, idD, alice, SS_100 - 900_000);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 1);  // fills alice's remainder: head on the dead run
        assertEq(vault.firstPendingDepositId(), idD + 1);
        _processDeposits(0, 100);
        assertEq(vault.firstPendingDepositId(), idD + 101);
        _processDeposits(0, 100);
        assertEq(vault.firstPendingDepositId(), idD + 201);
        _processDeposits(0, 100);
        assertEq(vault.firstPendingDepositId(), idD + 301);
        assertEq(vault.getPendingDepositRequests().length, 0);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }

}
