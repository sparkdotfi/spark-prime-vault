// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl } from "../../lib/oz/contracts/access/IAccessControl.sol";
import { IERC20 }         from "../../lib/oz/contracts/token/ERC20/IERC20.sol";

import { LocalTestBase }    from "./LocalTestBase.t.sol";
import { ISparkPrimeVault } from "../../src/ISparkPrimeVault.sol";

interface IERC4626WithdrawLike {
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
}

/// @dev Redeem-queue campaign, round 6 (`master` @ c512609): `requestRedeem`,
///      `updateRedeemRecipient`, `processPendingRedeems`, `_withdrawSavings` and `claim`.
///
///      Harness state after setUp (both VSRs frozen at RAY):
///        chi_s (spUSDC)  = 1.047633055711877768967605062e27
///        chi_p (spPRIME) = 1.009687768242461209408770821e27
///      A 1_000_000e6 deposit gives the vault 954_532_691_143 spUSDC and mints 990_405_184_109
///      spPRIME; a 100_000e6 deposit gives 95_453_269_114 spUSDC / 99_040_518_410 spPRIME.
///
///      Notation in comments: L = USDC held by spUSDC, S = spUSDC held by the vault,
///      A = spUSDC.maxWithdraw(vault) = min(L, floor(S * chi_s / RAY)),
///      fillable = min(maxShares_ left, floor(A * RAY / chi_p)), recomputed for EVERY entry
///      (src/SparkPrimeVault.sol:953), which is the C-1 fix.
///
///      Line map on c512609: `requestRedeem` :448-476 (`whenNotPaused` :451, `ZeroRecipient`
///      :454, `VaultIsRecipient` :455, `BelowMinRedeem` :456, `drip` :458, escrow `_transfer`
///      :460, fee :463-465, push :471, `RedeemRequest` :475); `updateRedeemRecipient` :514-525;
///      `claim` :531-543; `_processPendingRedeems` :942-976 (loop :950, bound :953, `break`
///      :955, `_burn` :964, `_withdrawSavings` :966, `Redeem` :968, partial `break` :970,
///      `delete` :972); `_withdrawSavings` :997-1014 (try :1001, fallback :1011, credit :1013);
///      `_incrementClaimableAssets` :1100-1105; `adjustTotalAssets` :262-283; `take` :289-298;
///      getters :764-809.
abstract contract RedeemQueueTestBase is LocalTestBase {

    address internal alice = makeAddr("alice");
    address internal bob   = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant CHI_S = 1.047633055711877768967605062e27;
    uint256 internal constant CHI_P = 1.009687768242461209408770821e27;

    uint256 internal constant DEPOSIT_100K_SPUSDC = 95_453_269_114;
    uint256 internal constant DEPOSIT_100K_SHARES = 99_040_518_410;
    uint256 internal constant DEPOSIT_1M_SPUSDC   = 954_532_691_143;
    uint256 internal constant DEPOSIT_1M_SHARES   = 990_405_184_109;

    // One 100_000e6 fill at the harness indexes: USDC paid and spUSDC burned (ceil).
    uint256 internal constant FILL_100K_ASSETS = 99_999_999_998;
    uint256 internal constant FILL_100K_SPUSDC = 95_453_269_113;

    function setUp() public virtual override {
        super.setUp();
        assertEq(spUsdc.nowChi(), CHI_S, "harness chi_s drifted");
        assertEq(vault.nowChi(),  CHI_P, "harness chi_p drifted");
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _requestRedeemTo(address who, uint256 shares, address to)
        internal returns (uint256 id)
    {
        vm.prank(who);
        id = vault.requestRedeem(shares, to);
    }

    /// @dev Raw read of `_redeemRequests[id]` (storage slot 2), valid below the head too.
    function _rawRedeem(uint256 id)
        internal view returns (address owner, address recipient, uint256 shares)
    {
        uint256 base = uint256(keccak256(abi.encode(uint256(2)))) + 3 * id;
        owner     = address(uint160(uint256(vm.load(address(vault), bytes32(base)))));
        recipient = address(uint160(uint256(vm.load(address(vault), bytes32(base + 1)))));
        shares    = uint256(vm.load(address(vault), bytes32(base + 2)));
    }

    function _queued(uint256 id) internal view returns (uint256 shares) {
        ( , , shares ) = _rawRedeem(id);
    }

    function _queueLength() internal view returns (uint256) {
        return _redeemQueueLength();
    }

    function _divUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / y + 1;
    }

    /// @dev One fill's arithmetic at the current indexes: USDC paid and spUSDC burned.
    function _fillMath(uint256 shares) internal view returns (uint256 assets, uint256 burned) {
        assets = shares * vault.nowChi() / RAY;
        burned = _divUp(assets * RAY, spUsdc.nowChi());
    }

    /// @dev The share budget one iteration of `_processPendingRedeems` sees right now.
    function _liquidShares() internal view returns (uint256) {
        return vault.convertToShares(vault.availableLiquidAssets());
    }

    /// @dev R5-14: a 1-share request at any non-zero fee burns the share and pushes a 0-share
    ///      entry (fee = divUp(1 * rate, WAD) = 1). The only way to get a dead entry on c512609.
    function _zeroShareEntry(address who) internal returns (uint256 id) {
        uint256 fee = vault.redeemFeeRate();
        _setRedeemFeeRate(0.01e18);
        vm.prank(who);
        id = vault.requestRedeem(1, who);
        _setRedeemFeeRate(fee);
        assertEq(_queued(id), 0);
    }

    function _threeDepositorsQueued() internal returns (uint256 idA, uint256 idB, uint256 idC) {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _deposit(carol, 100_000e6);
        idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        idB = _requestRedeem(bob,   DEPOSIT_100K_SHARES);
        idC = _requestRedeem(carol, DEPOSIT_100K_SHARES);
        assertEq(idA, 0);
        assertEq(idB, 1);
        assertEq(idC, 2);
        assertEq(vault.pendingRedeemShares(), 3 * DEPOSIT_100K_SHARES);
        assertEq(_vaultSpUsdc(),              3 * DEPOSIT_100K_SPUSDC);
    }

}

/**************************************************************************************************/
/*** requestRedeem                                                                              ***/
/**************************************************************************************************/

contract RequestRedeemFailureTests is RedeemQueueTestBase {

    function test_requestRedeem_isPaused() external {
        _deposit(alice, 100_000e6);
        _pause();

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestRedeem(1, alice);

        _unpause();
        vm.prank(alice);
        vault.requestRedeem(1, alice);
    }

    function test_requestRedeem_zeroRecipient() external {
        _deposit(alice, 100_000e6);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.requestRedeem(1, address(0));
    }

    function test_requestRedeem_vaultIsRecipient() external {
        _deposit(alice, 100_000e6);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestRedeem(1, address(vault));
    }

    // `minRedeem` is denominated in SHARES (:456): minRedeem - 1 reverts, exactly minRedeem passes.
    function test_requestRedeem_belowMinRedeemBoundary() external {
        _deposit(alice, 100_000e6);
        _setMinRedeem(1_000e6);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(1_000e6 - 1, alice);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(1_000e6, alice);

        assertEq(_queued(id), 1_000e6);

        // In asset terms the floor is chi-dependent: 1_000e6 shares = 1_009_687_768 USDC today.
        assertEq(vault.convertToAssets(1_000e6), 1_009_687_768);

        // The minimum is gross of fee: with a 1% fee the queued amount is below it.
        _setRedeemFeeRate(0.01e18);
        vm.prank(alice);
        uint256 id2 = vault.requestRedeem(1_000e6, alice);
        assertEq(_queued(id2), 990_000_000);
    }

    function test_requestRedeem_insufficientBalanceBoundary() external {
        _deposit(alice, 100_000e6);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.requestRedeem(DEPOSIT_100K_SHARES + 1, alice);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(DEPOSIT_100K_SHARES, alice);

        assertEq(_queued(id),            DEPOSIT_100K_SHARES);
        assertEq(vault.balanceOf(alice), 0);
    }

    // Check order: pause (:451) > zero recipient (:454) > vault recipient (:455) > minimum
    // (:456) > balance (:1037).
    function test_requestRedeem_checkOrder() external {
        _deposit(alice, 100_000e6);
        _setMinRedeem(10);

        _pause();
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestRedeem(1, address(0));
        _unpause();

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.requestRedeem(1, address(0));

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.requestRedeem(1, address(vault));

        vm.prank(bob);  // bob holds nothing: the minimum is checked before the balance
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(9, bob);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.requestRedeem(10, bob);
    }

}

contract RequestRedeemSuccessTests is RedeemQueueTestBase {

    function test_requestRedeem_escrowsSharesAndEmits() external {
        _deposit(alice, 100_000e6);

        assertEq(vault.balanceOf(alice),          DEPOSIT_100K_SHARES);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(),             DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(_queueLength(),                  0);

        vm.expectEmit(address(vault));
        emit IERC20.Transfer(alice, address(vault), DEPOSIT_100K_SHARES);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRequest(0, alice, bob, DEPOSIT_100K_SHARES, 0);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(DEPOSIT_100K_SHARES, bob);

        assertEq(id, 0);

        ( address owner, address recipient, uint256 shares ) = vault.getPendingRedeemRequest(0);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    DEPOSIT_100K_SHARES);

        assertEq(vault.balanceOf(alice),          0);
        assertEq(vault.balanceOf(address(vault)), DEPOSIT_100K_SHARES);
        assertEq(vault.totalSupply(),             DEPOSIT_100K_SHARES);  // no fee, nothing burned
        assertEq(vault.pendingRedeemShares(),     DEPOSIT_100K_SHARES);
        assertEq(vault.firstPendingRedeemId(),    0);
        assertEq(_queueLength(),                  1);
        assertEq(_vaultSpUsdc(),                  DEPOSIT_100K_SPUSDC);  // backing untouched

        // Ids are sequential.
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.requestRedeem(1, bob);
        _deposit(bob, 100_000e6);
        assertEq(_requestRedeem(bob, 1), 1);
        assertEq(_queueLength(),         2);
    }

    // `requestRedeem` drips (:458): rho moves to now and the queued shares are worth today's chi.
    function test_requestRedeem_dripsFirst() external {
        _deposit(alice, 100_000e6);
        _setPrimeVsr(FIVE_PCT_VSR);
        _warp(365 days);

        assertEq(vault.rho(), block.timestamp - 365 days);
        assertEq(vault.chi(), CHI_P);
        assertEq(vault.nowChi(), 1.060172156654584269839902363e27);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Drip(uint192(1.060172156654584269839902363e27), 5_000_000_000);
        _requestRedeem(alice, DEPOSIT_100K_SHARES);

        assertEq(vault.rho(), block.timestamp);
        assertEq(vault.chi(), 1.060172156654584269839902363e27);
        assertEq(vault.convertToAssets(DEPOSIT_100K_SHARES), 104_999_999_998);
    }

    function test_requestRedeem_feeOnePercent_exactAmounts() external {
        _deposit(alice, 1_100_000e6);
        assertEq(vault.balanceOf(alice), 1_089_445_702_520);
        _setRedeemFeeRate(0.01e18);

        vm.expectEmit(address(vault));
        emit IERC20.Transfer(alice, address(vault), 1_000_000e6);
        vm.expectEmit(address(vault));
        emit IERC20.Transfer(address(vault), address(0), 10_000_000_000);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRequest(0, alice, alice, 1_000_000e6, 10_000_000_000);
        uint256 id = _requestRedeem(alice, 1_000_000e6);

        assertEq(vault.balanceOf(alice),          89_445_702_520);
        assertEq(vault.balanceOf(address(vault)), 990_000_000_000);
        assertEq(vault.totalSupply(),             1_079_445_702_520);  // 10_000_000_000 burned
        assertEq(_queued(id),                     990_000_000_000);
        assertEq(vault.pendingRedeemShares(),     990_000_000_000);

        // The burned fee is value left in the vault for the remaining holders.
        assertEq(vault.totalAssets(), 1_089_903_122_316);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 1_099_999_999_999);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),           999_590_890_560);
        assertEq(_vaultSpUsdc(),                  95_843_777_448);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.totalSupply(),             89_445_702_520);
    }

    // Fee rounds up (:463): 999_999_999_999 * 1% = 9_999_999_999.99 -> 10_000_000_000.
    function test_requestRedeem_feeRoundsUp() external {
        _deposit(alice, 1_100_000e6);
        _setRedeemFeeRate(0.01e18);

        uint256 id = _requestRedeem(alice, 999_999_999_999);

        assertEq(_queued(id),         989_999_999_999);
        assertEq(vault.totalSupply(), 1_089_445_702_520 - 10_000_000_000);

        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 999_590_890_559);
    }

    // The fee is burned from escrow, so a request of the full balance with a 1% fee is accepted.
    function test_requestRedeem_fullBalanceWithFee() external {
        _deposit(alice, 100_000e6);
        _setRedeemFeeRate(0.01e18);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRequest(0, alice, alice, DEPOSIT_100K_SHARES, 990_405_185);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(_queued(id),            98_050_113_225);
        assertEq(vault.totalSupply(),    98_050_113_225);
    }

    // The share-denominated minimum drifts in asset terms: after a year at 5% the same
    // `minRedeem` of 1_000e6 shares is worth 1_060_172_156 USDC and a request worth 1_050e6 USDC
    // is still rejected.
    function test_requestRedeem_minRedeemDriftsInAssetTerms() external {
        _deposit(alice, 100_000e6);
        _setMinRedeem(1_000e6);
        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);

        assertEq(vault.nowChi(),                 1.060172156654584269839902363e27);
        assertEq(vault.convertToAssets(1_000e6), 1_060_172_156);
        assertEq(vault.convertToShares(1_050e6), 990_405_184);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vault.requestRedeem(990_405_184, alice);

        uint256 id = _requestRedeem(alice, 1_000e6);
        assertEq(_queued(id), 1_000e6);
    }

    // Blacklisted recipients are ACCEPTED at request time on c512609 (no `isBlacklisted` check
    // anywhere); the fallback handles them at fill time (see the fallback tests).
    function test_requestRedeem_blacklistedRecipientAccepted() external {
        _deposit(alice, 100_000e6);
        _blacklist(bob);
        _blacklist(alice);  // a blacklisted owner can request too: no USDC moves here

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRequest(0, alice, bob, DEPOSIT_100K_SHARES, 0);
        uint256 id = _requestRedeemTo(alice, DEPOSIT_100K_SHARES, bob);

        ( address owner, address recipient, uint256 shares ) = vault.getPendingRedeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, bob);
        assertEq(shares,    DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(), DEPOSIT_100K_SHARES);
    }

    // R5-14 (open, Info): a 1-share request at any non-zero fee burns the share and leaves a
    // 0-share entry: `RedeemRequest(id, owner, recipient, 1, 1)`, nothing escrowed, the updater
    // rejects it (`NoRequest`) and it costs one `maxRequests_` slot (see the processing tests).
    // Only reachable with `minRedeem == 1`.
    function test_requestRedeem_oneShareAtAnyFee_zeroShareEntry_R5_14() external {
        _deposit(alice, 100_000e6);
        _setRedeemFeeRate(1);  // smallest non-zero fee: divUp(1 * 1, WAD) = 1

        vm.expectEmit(address(vault));
        emit IERC20.Transfer(alice, address(vault), 1);
        vm.expectEmit(address(vault));
        emit IERC20.Transfer(address(vault), address(0), 1);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRequest(0, alice, alice, 1, 1);
        uint256 id = _requestRedeem(alice, 1);

        ( address owner, address recipient, uint256 shares ) = vault.getPendingRedeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.balanceOf(alice),          DEPOSIT_100K_SHARES - 1);
        assertEq(vault.totalSupply(),             DEPOSIT_100K_SHARES - 1);
        assertEq(_queueLength(),                  1);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(id, bob);

        // `minRedeem = 2` closes it: at the maximum fee (1%) a 2-share request queues 1 share.
        _setMinRedeem(2);
        _setRedeemFeeRate(0.01e18);
        uint256 id2 = _requestRedeem(alice, 2);
        assertEq(_queued(id2), 1);
    }

    // With `minRedeem >= 2` no fee up to `MAX_REDEEM_FEE` can burn a request to zero:
    // queued = shares - divUp(shares * rate, WAD) >= 1 for every shares >= 2, rate <= 1%.
    function testFuzz_requestRedeem_zeroShareEntryOnlyWhenSharesIsOne(uint256 shares, uint256 rate)
        external
    {
        shares = bound(shares, 2, 1e30);
        rate   = bound(rate, 0, vault.MAX_REDEEM_FEE());
        _setRedeemFeeRate(rate);

        uint256 fee = _divUp(shares * rate, WAD);
        assertLt(fee, shares);

        // Mint `shares` to alice directly (slot 25: balanceOf; slot 17: totalSupply).
        vm.store(address(vault), keccak256(abi.encode(alice, uint256(25))), bytes32(shares));
        vm.store(address(vault), bytes32(uint256(17)),                        bytes32(shares));

        uint256 id = _requestRedeem(alice, shares);
        assertEq(_queued(id), shares - fee);
        assertGe(_queued(id), 1);
    }

    // Design property (closes E-2 "free option" and C-10 "free capacity hog"): once queued, the
    // shares sit at `address(vault)` and nothing but a fill moves them. No ERC20 path, no
    // signature, no role, no pause, no time releases them.
    function test_requestRedeem_isFinal_noPathRecoversEscrow() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        assertEq(vault.balanceOf(address(vault)), DEPOSIT_100K_SHARES);
        assertEq(vault.balanceOf(alice),          0);

        // ERC20 paths: the vault never approves anyone, and nobody can sign for it. The balance
        // check (`_transfer`, :1037) runs before the allowance check on c512609.
        assertEq(vault.allowance(address(vault), alice), 0);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/insufficient-allowance");
        vault.transferFrom(address(vault), alice, 1);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/insufficient-allowance");
        vault.transferFrom(address(vault), alice, DEPOSIT_100K_SHARES);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vault.transferFrom(address(vault), alice, DEPOSIT_100K_SHARES + 1);

        ( uint8 v, bytes32 r_, bytes32 s ) = vm.sign(1, keccak256("anything"));
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(address(vault), alice, type(uint256).max, block.timestamp + 1, v, r_, s);
        assertEq(vault.allowance(address(vault), alice), 0);

        // The updater moves the recipient, never the shares.
        vm.prank(alice);
        vault.updateRedeemRecipient(id, alice);
        assertEq(vault.balanceOf(address(vault)), DEPOSIT_100K_SHARES);

        // Roles: `take` moves spUSDC only; pause freezes, releases nothing.
        _takeAll();
        assertEq(vault.balanceOf(address(vault)), DEPOSIT_100K_SHARES);
        _returnToVault(2 * DEPOSIT_100K_SPUSDC);
        _pause();
        assertEq(vault.balanceOf(address(vault)), DEPOSIT_100K_SHARES);
        _unpause();

        // Time: a year without an operator call leaves the escrow in place (and accruing).
        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);
        assertEq(vault.balanceOf(address(vault)),            DEPOSIT_100K_SHARES);
        assertEq(_queued(id),                                DEPOSIT_100K_SHARES);
        assertEq(vault.convertToAssets(DEPOSIT_100K_SHARES), 104_999_999_998);
        assertEq(usdc.balanceOf(alice),                      0);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice),           104_999_999_998);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(_queued(id),                     0);
    }

    // C-10 closed: escrowed shares stay in `totalSupply` (:460 transfers, :465 burns only the
    // fee), so a redeem request keeps the capacity it occupies until the fill burns it (:964).
    function test_requestRedeem_capacityStaysOccupiedUntilFill() external {
        _deposit(alice, 100_000e6);
        _setCapacity(vault.totalSupply());
        assertEq(vault.availableCapacity(), 0);

        _requestRedeem(alice, DEPOSIT_100K_SHARES);
        assertEq(vault.totalSupply(),       DEPOSIT_100K_SHARES);
        assertEq(vault.availableCapacity(), 0);

        uint256 did = _deposit(bob, 100_000e6);  // queued: capacity is full
        assertEq(vault.balanceOf(bob), 0);
        ( , , uint256 bobQueued ) = _depositRequest(did);
        assertEq(bobQueued, DEPOSIT_100K_SPUSDC);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice),     FILL_100K_ASSETS);
        assertEq(vault.totalSupply(),       0);
        assertEq(vault.availableCapacity(), DEPOSIT_100K_SHARES);

        _processDeposits(type(uint256).max, 1);
        // The capacity round-trip (shares -> USDC -> spUSDC, two floors) admits 2 spUSDC wei
        // less than bob's request (deposit-side rounding, not this area).
        assertEq(vault.balanceOf(bob), 99_040_518_408);
        ( , , uint256 bobLeft ) = _depositRequest(did);
        assertEq(bobLeft, 2);
    }

}

/**************************************************************************************************/
/*** processPendingRedeems                                                                      ***/
/**************************************************************************************************/

contract ProcessPendingRedeemsFailureTests is RedeemQueueTestBase {

    function test_processPendingRedeems_isPaused() external {
        _deposit(alice, 100_000e6);
        _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _pause();

        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingRedeems(type(uint256).max, 10);

        _unpause();
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), FILL_100K_ASSETS);
    }

    function test_processPendingRedeems_notOperator() external {
        address[6] memory others = [admin, lossManager, pauser, unpauser, redeemFeeSetter, taker];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, others[i], OPERATOR_ROLE
            ));
            vault.processPendingRedeems(type(uint256).max, 10);
        }
    }

}

contract ProcessPendingRedeemsTests is RedeemQueueTestBase {

    /**********************************************************************************************/
    /*** Basic fills, events, FIFO, bounds                                                      ***/
    /**********************************************************************************************/

    function test_processPendingRedeems_emptyQueue_noop() external {
        _deposit(alice, 100_000e6);
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(vault.pendingRedeemShares(),  0);
        assertEq(_vaultSpUsdc(),               DEPOSIT_100K_SPUSDC);
    }

    function test_processPendingRedeems_maxSharesZero_noop() external {
        _threeDepositorsQueued();
        uint256 spBefore = _vaultSpUsdc();

        _processRedeems(0, 10);

        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(vault.pendingRedeemShares(),  3 * DEPOSIT_100K_SHARES);
        assertEq(_vaultSpUsdc(),               spBefore);
        assertEq(usdc.balanceOf(alice),        0);
    }

    // Event on c512609 (:968): Redeem(requestId, owner, recipient, sharesBurned,
    // savingsSharesBurned, assetsReceived), preceded by the share burn and spUSDC's own events.
    function test_processPendingRedeems_fullFill_eventsAndBalances() external {
        _deposit(alice, 100_000e6);
        _requestRedeemTo(alice, DEPOSIT_100K_SHARES, bob);

        uint256 liqBefore = usdc.balanceOf(address(spUsdc));

        vm.expectEmit(address(vault));
        emit IERC20.Transfer(address(vault), address(0), DEPOSIT_100K_SHARES);
        vm.expectEmit(address(usdc));
        emit IERC20.Transfer(address(spUsdc), bob, FILL_100K_ASSETS);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(
            0, alice, bob, DEPOSIT_100K_SHARES, FILL_100K_SPUSDC, FILL_100K_ASSETS
        );
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(bob),             FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(alice),           0);
        assertEq(usdc.balanceOf(address(spUsdc)), liqBefore - FILL_100K_ASSETS);
        assertEq(_vaultSpUsdc(),                  1);  // ceil burn leaves 1 wei
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(),             0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.firstPendingRedeemId(),    1);
        assertEq(vault.claimableAssets(bob),      0);
        assertEq(vault.totalClaimable(),          0);
    }

    // A fully filled entry is `delete`d (:972): the raw slot is zero; a partially filled head
    // keeps owner and recipient.
    function test_processPendingRedeems_fullFillDeletesEntry() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeemTo(alice, DEPOSIT_100K_SHARES, carol);
        uint256 idB = _requestRedeem(bob, DEPOSIT_100K_SHARES);

        _processRedeems(DEPOSIT_100K_SHARES + 1, 10);  // alice full, bob 1 share

        ( address o, address r, uint256 sh ) = _rawRedeem(idA);
        assertEq(o,  address(0));
        assertEq(r,  address(0));
        assertEq(sh, 0);
        assertEq(usdc.balanceOf(carol), FILL_100K_ASSETS);

        ( o, r, sh ) = vault.getPendingRedeemRequest(idB);
        assertEq(o,  bob);
        assertEq(r,  bob);
        assertEq(sh, DEPOSIT_100K_SHARES - 1);
        assertEq(usdc.balanceOf(bob), 1);
        assertEq(vault.firstPendingRedeemId(), 1);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(idA, alice);
        assertEq(_queueLength(), 2);
    }

    // FIFO with the liquidity bound recomputed per entry: alice in full, bob with what is left
    // (50_000_000_002 USDC of liquidity -> 49_520_259_207 shares -> 50_000_000_001 USDC: one wei
    // MORE than the old single budget would have given), carol nothing.
    function test_processPendingRedeems_fifo_liquidityBound() external {
        ( uint256 idA, uint256 idB, uint256 idC ) = _threeDepositorsQueued();
        _drainSpUsdcLiquidity(150_000e6);

        assertEq(_liquidShares(), 148_560_777_616);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),           FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(bob),             50_000_000_001);
        assertEq(usdc.balanceOf(carol),           0);
        assertEq(usdc.balanceOf(address(spUsdc)), 1);
        assertEq(_queued(idA),                    0);
        assertEq(_queued(idB),                    49_520_259_203);
        assertEq(_queued(idC),                    DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(),     49_520_259_203 + DEPOSIT_100K_SHARES);
        assertEq(vault.balanceOf(address(vault)), 49_520_259_203 + DEPOSIT_100K_SHARES);
        assertEq(vault.firstPendingRedeemId(),    idB);
        assertEq(_vaultSpUsdc(),                  143_179_903_670);

        _returnSpUsdcLiquidity(150_000e6);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(bob),             FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(carol),           FILL_100K_ASSETS);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.firstPendingRedeemId(),    3);
        assertEq(_vaultSpUsdc(),                  2);
        assertEq(vault.totalSupply(),             0);
    }

    function test_processPendingRedeems_maxRequests() external {
        ( uint256 idA, uint256 idB, uint256 idC ) = _threeDepositorsQueued();

        _processRedeems(type(uint256).max, 0);
        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(usdc.balanceOf(alice),        0);

        _processRedeems(type(uint256).max, 2);

        assertEq(usdc.balanceOf(alice),        FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(bob),          FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(carol),        0);
        assertEq(_queued(idA),                 0);
        assertEq(_queued(idB),                 0);
        assertEq(_queued(idC),                 DEPOSIT_100K_SHARES);
        assertEq(vault.firstPendingRedeemId(), 2);
        assertEq(vault.pendingRedeemShares(),  DEPOSIT_100K_SHARES);

        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(carol),        FILL_100K_ASSETS);
        assertEq(vault.firstPendingRedeemId(), 3);
        assertEq(vault.pendingRedeemShares(),  0);

        // maxRequests_ beyond the queue length is clamped (:948).
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingRedeemId(), 3);
    }

    function test_processPendingRedeems_maxShares() external {
        ( uint256 idA, uint256 idB, uint256 idC ) = _threeDepositorsQueued();

        // One share short of alice's request: alice partial, head stays.
        _processRedeems(DEPOSIT_100K_SHARES - 1, 10);

        assertEq(usdc.balanceOf(alice),        99_999_999_997);
        assertEq(_queued(idA),                 1);
        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(vault.pendingRedeemShares(),  2 * DEPOSIT_100K_SHARES + 1);
        assertEq(_vaultSpUsdc(),               3 * DEPOSIT_100K_SPUSDC - 95_453_269_112);

        // 1 + 10 shares: alice's last share, then 10 of bob's.
        _processRedeems(11, 10);

        assertEq(usdc.balanceOf(alice),        FILL_100K_ASSETS);  // 1 share -> 1 wei USDC
        assertEq(usdc.balanceOf(bob),          10);
        assertEq(_queued(idA),                 0);
        assertEq(_queued(idB),                 DEPOSIT_100K_SHARES - 10);
        assertEq(_queued(idC),                 DEPOSIT_100K_SHARES);
        assertEq(vault.firstPendingRedeemId(), 1);
        assertEq(vault.pendingRedeemShares(),  2 * DEPOSIT_100K_SHARES - 10);
        assertEq(_vaultSpUsdc(),               3 * DEPOSIT_100K_SPUSDC - 95_453_269_112 - 1 - 10);
    }

    // `fillable_ = min(remaining_, liquid shares)` (:953): whichever is smaller binds, and the
    // liquidity leg is re-read after every fill.
    function test_processPendingRedeems_maxSharesVsLiquidity() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idB = _requestRedeem(bob,   DEPOSIT_100K_SHARES);
        _drainSpUsdcLiquidity(50_000e6);

        assertEq(_liquidShares(), 148_560_777_616);  // 150_000e6 of liquidity

        // maxShares_ (120e9) binds: alice full, bob 20_959_481_590 shares.
        _processRedeems(120_000_000_000, 10);

        assertEq(usdc.balanceOf(alice),           FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(bob),             21_162_532_190);
        assertEq(_queued(idA),                    0);
        assertEq(_queued(idB),                    78_081_036_820);
        assertEq(vault.firstPendingRedeemId(),    idB);
        assertEq(usdc.balanceOf(address(spUsdc)), 28_837_467_812);
        assertEq(_vaultSpUsdc(),                  75_252_940_312);

        // Now the liquidity (28_837_467_812 USDC) binds under a large maxShares_.
        assertEq(_liquidShares(), 28_560_777_617);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(bob),             21_162_532_190 + 28_837_467_811);
        assertEq(_queued(idB),                    78_081_036_820 - 28_560_777_617);
        assertEq(usdc.balanceOf(address(spUsdc)), 1);
        assertEq(vault.firstPendingRedeemId(),    idB);

        // And maxShares_ smaller than the liquidity again.
        _returnSpUsdcLiquidity(100_000e6);
        _processRedeems(1_000, 10);
        assertEq(usdc.balanceOf(bob), 21_162_532_190 + 28_837_467_811 + 1_009);
        assertEq(_queued(idB),        78_081_036_820 - 28_560_777_617 - 1_000);
    }

    // A big head request blocks a small later one even when the small one would fit: FIFO.
    function test_processPendingRedeems_headBlocksLaterSmallerRequests() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idB = _requestRedeem(bob,   1_000e6);
        _drainSpUsdcLiquidity(150_000e6);  // 50_000e6 left: fits bob, not alice

        assertEq(_liquidShares(), 49_520_259_205);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),        49_999_999_999);
        assertEq(usdc.balanceOf(bob),          0);
        assertEq(_queued(idA),                 49_520_259_205);
        assertEq(_queued(idB),                 1_000e6);
        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(vault.pendingRedeemShares(),  49_520_259_205 + 1_000e6);
    }

    /**********************************************************************************************/
    /*** Liquidity-limited fills                                                                ***/
    /**********************************************************************************************/

    // (a) spUSDC has 300_000e6 USDC against the vault's 999_999_999_999 claim.
    function test_processPendingRedeems_partialFill_spUsdcLiquidityBound() external {
        _deposit(alice, 1_000_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_1M_SHARES);
        _drainSpUsdcLiquidity(700_000e6);

        assertEq(usdc.balanceOf(address(spUsdc)), 300_000e6);
        assertEq(vault.availableLiquidAssets(),   300_000e6);
        assertEq(_liquidShares(),                 297_121_555_233);
        assertEq(vault.balanceOf(address(vault)), DEPOSIT_1M_SHARES);
        assertEq(vault.totalSupply(),             DEPOSIT_1M_SHARES);
        assertEq(_vaultSpUsdc(),                  DEPOSIT_1M_SPUSDC);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, alice, 297_121_555_233, 286_359_807_343, 299_999_999_999);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),           299_999_999_999);
        assertEq(usdc.balanceOf(address(spUsdc)), 1);
        assertEq(_vaultSpUsdc(),                  DEPOSIT_1M_SPUSDC - 286_359_807_343);
        assertEq(_queued(id),                     693_283_628_876);
        assertEq(vault.pendingRedeemShares(),     693_283_628_876);
        assertEq(vault.balanceOf(address(vault)), 693_283_628_876);
        assertEq(vault.totalSupply(),             693_283_628_876);
        assertEq(vault.firstPendingRedeemId(),    0);  // partial entry stays at the head

        // Liquidity returns; the remainder is paid, now the vault's spUSDC claim binds
        // (668_172_883_800 spUSDC = 699_999_999_999 USDC < 700_000_000_001 liquidity).
        _returnSpUsdcLiquidity(700_000e6);
        assertEq(vault.availableLiquidAssets(), 699_999_999_999);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),           999_999_999_997);
        assertEq(_vaultSpUsdc(),                  1);
        assertEq(_queued(id),                     0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.totalSupply(),             0);
        assertEq(vault.firstPendingRedeemId(),    1);

        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), 1);
    }

    // (b) spUSDC is fully liquid, but the vault only holds 300_000e6 spUSDC after take().
    function test_processPendingRedeems_partialFill_vaultSharesBound() external {
        _deposit(alice, 1_000_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_1M_SHARES);
        _take(DEPOSIT_1M_SPUSDC - 300_000e6);

        assertEq(_vaultSpUsdc(),                  300_000e6);
        assertEq(usdc.balanceOf(address(spUsdc)), 1_000_000e6);
        assertEq(vault.availableLiquidAssets(),   314_289_916_713);
        assertEq(_liquidShares(),                 311_274_362_826);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),           314_289_916_712);
        assertEq(_vaultSpUsdc(),                  1);  // 299_999_999_999 burned
        assertEq(usdc.balanceOf(address(spUsdc)), 1_000_000e6 - 314_289_916_712);
        assertEq(_queued(id),                     679_130_821_283);
        assertEq(vault.pendingRedeemShares(),     679_130_821_283);
        assertEq(vault.firstPendingRedeemId(),    0);

        // 1 wei of spUSDC is worth 1 wei USDC, which converts to 0 prime shares: no-op (R5-10).
        assertEq(vault.availableLiquidAssets(), 1);
        assertEq(_liquidShares(),               0);
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 314_289_916_712);

        _returnToVault(DEPOSIT_1M_SPUSDC - 300_000e6);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),        314_289_916_712 + 685_710_083_285);
        assertEq(_queued(id),                  0);
        assertEq(vault.pendingRedeemShares(),  0);
        assertEq(vault.firstPendingRedeemId(), 1);
    }

    function test_processPendingRedeems_zeroLiquidity_noop() external {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _drainAllSpUsdcLiquidity();

        assertEq(vault.availableLiquidAssets(), 0);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),        0);
        assertEq(_queued(id),                  DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(),  DEPOSIT_100K_SHARES);
        assertEq(vault.firstPendingRedeemId(), 0);
    }

    function test_processPendingRedeems_afterFullTake_noop() external {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _takeAll();

        assertEq(_vaultSpUsdc(),                0);
        assertEq(vault.availableLiquidAssets(), 0);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),        0);
        assertEq(_queued(id),                  DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(),  DEPOSIT_100K_SHARES);
        assertEq(vault.firstPendingRedeemId(), 0);

        _returnToVault(1);
        assertEq(vault.availableLiquidAssets(), 1);
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(_vaultSpUsdc(),        1);
    }

    // F-2 / R5-5 (open): `take` is not pause-gated and spends the backing of queued redeems.
    function test_BUG_processPendingRedeems_pausedBlocksRedeemsNotTake_R5_5() external {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        _pause();

        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.processPendingRedeems(type(uint256).max, 10);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestRedeem(1, alice);

        // `updateRedeemRecipient` is not pause-gated.
        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);
        ( , address r, ) = vault.getPendingRedeemRequest(id);
        assertEq(r, bob);
        vm.prank(alice);
        vault.updateRedeemRecipient(id, alice);

        assertEq(_vaultSpUsdc(), DEPOSIT_100K_SPUSDC);
        _takeAll();
        assertEq(_vaultSpUsdc(),                0);
        assertEq(spUsdc.balanceOf(taker),       DEPOSIT_100K_SPUSDC);
        assertEq(vault.availableLiquidAssets(), 0);

        _unpause();
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),                      0);
        assertEq(_queued(id),                                DEPOSIT_100K_SHARES);
        assertEq(vault.pendingRedeemShares(),                DEPOSIT_100K_SHARES);
        assertEq(vault.convertToAssets(DEPOSIT_100K_SHARES), FILL_100K_ASSETS);
    }

    /**********************************************************************************************/
    /*** C-1 fixed: the liquidity bound is recomputed per entry                                 ***/
    /**********************************************************************************************/

    // FIXED (C-1 / R5-4). Round 5: the vault holds S = 1_002_833 spUSDC (A = 1_050_601 USDC,
    // 1_040_520 shares), two requests of 520_260 shares each pay 525_300 USDC and burn 501_417
    // spUSDC each; the old single budget let both through and the second burn reverted
    // `SparkVault/insufficient-balance`. Now the bound is re-read after alice's fill
    // (501_416 spUSDC = 525_299 USDC = 520_258 shares), bob is partially filled for 520_258
    // shares / 525_298 USDC in the SAME call, and 2 shares stay queued behind 1 wei of spUSDC.
    function test_fixed_C1_twoEntriesVaultSharesBound_settleInOneCall() external {
        _deposit(alice, 1_000_000e6);
        _take(DEPOSIT_1M_SPUSDC - 1_002_833);

        assertEq(_vaultSpUsdc(),                1_002_833);
        assertEq(vault.availableLiquidAssets(), 1_050_601);
        assertEq(_liquidShares(),               1_040_520);

        uint256 id1 = _requestRedeemTo(alice, 520_260, alice);
        uint256 id2 = _requestRedeemTo(alice, 520_260, bob);

        ( uint256 assets1, uint256 burn1 ) = _fillMath(520_260);
        assertEq(assets1,   525_300);
        assertEq(burn1,     501_417);
        assertEq(burn1 * 2, 1_002_834);  // > 1_002_833 held: the round-5 revert

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id1, alice, alice, 520_260, 501_417, 525_300);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id2, alice, bob,   520_258, 501_415, 525_298);
        _processRedeems(type(uint256).max, 2);

        assertEq(usdc.balanceOf(alice),         525_300);
        assertEq(usdc.balanceOf(bob),           525_298);
        assertEq(_vaultSpUsdc(),                1);
        assertEq(vault.availableLiquidAssets(), 1);
        assertEq(_liquidShares(),               0);
        assertEq(_queued(id1),                  0);
        assertEq(_queued(id2),                  2);
        assertEq(vault.pendingRedeemShares(),   2);
        assertEq(vault.firstPendingRedeemId(),  id2);

        // The dust is paid as soon as 1 more spUSDC wei is there (2 USDC wei -> 1 share).
        _returnToVault(1);
        assertEq(_liquidShares(), 1);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),          525_299);
        assertEq(_queued(id2),                 1);
        _returnToVault(2);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),          525_300);
        assertEq(_queued(id2),                 0);
        assertEq(vault.firstPendingRedeemId(), 2);
    }

    // FIXED (C-1, liquidity-bound variant). spUSDC holds L = 999_999_999_998 USDC, one wei
    // below the vault's claim; three requests summing to 990_405_184_108 shares pay
    // 999_999_999_997 USDC (fits L) but burn 954_532_691_144 spUSDC against 954_532_691_143.
    // One call now pays alice and bob in full and carol 674_340_790_631 (2 wei less than her
    // full fill), 2 shares stay queued behind 1 wei of spUSDC.
    function test_fixed_C1_threeEntriesLiquidityBound_settleInOneCall() external {
        _deposit(alice, 1_000_000e6);
        _drainSpUsdcLiquidity(2);

        assertEq(usdc.balanceOf(address(spUsdc)),         999_999_999_998);
        assertEq(_vaultSpUsdc(),                          954_532_691_143);
        assertEq(spUsdc.convertToAssets(954_532_691_143), 999_999_999_999);
        assertEq(vault.availableLiquidAssets(),           999_999_999_998);
        assertEq(_liquidShares(),                         990_405_184_108);

        _requestRedeemTo(alice, 22_947_880_715,  alice);
        _requestRedeemTo(alice, 299_586_688_493, bob);
        _requestRedeemTo(alice, 667_870_614_900, carol);

        ( uint256 a1, uint256 b1 ) = _fillMath(22_947_880_715);
        ( uint256 a2, uint256 b2 ) = _fillMath(299_586_688_493);
        ( uint256 a3, uint256 b3 ) = _fillMath(667_870_614_900);
        assertEq(a1 + a2 + a3, 999_999_999_997);
        assertEq(b1 + b2 + b3, 954_532_691_144);  // > S by exactly 1 wei

        _processRedeems(type(uint256).max, 3);

        assertEq(usdc.balanceOf(alice),           a1);
        assertEq(usdc.balanceOf(alice),           23_170_194_465);
        assertEq(usdc.balanceOf(bob),             a2);
        assertEq(usdc.balanceOf(bob),             302_489_014_899);
        assertEq(usdc.balanceOf(carol),           a3 - 2);
        assertEq(usdc.balanceOf(carol),           674_340_790_631);
        assertEq(_vaultSpUsdc(),                  1);
        assertEq(usdc.balanceOf(address(spUsdc)), 3);
        assertEq(_queued(2),                      2);
        assertEq(vault.pendingRedeemShares(),     2);
        assertEq(vault.firstPendingRedeemId(),    2);
        assertEq(vault.balanceOf(alice),          1);  // never requested
    }

    // The (11, 11, rest) case on a perfectly liquid vault: 11 shares pay 11 USDC and burn
    // ceil(11 / 1.0476) = 11 spUSDC each, and the three ceil burns add up to EXACTLY the
    // backing (95_453_269_114), so the old single budget would have settled all three. The
    // per-entry bound re-floors A after the two 11-fills (95_453_269_092 spUSDC ->
    // 99_999_999_975 USDC -> 99_040_518_387 shares) and under-fills carol by 1 share: she is
    // paid 99_999_999_975 instead of 99_999_999_976 and 1 share sticks at the head behind 1 wei
    // of spUSDC (R6-1 / R5-10). One call, no revert, exact dust.
    function test_fixed_C1_elevenElevenRest_settleInOneCall() external {
        _deposit(alice, 100_000e6);
        uint256 rest = DEPOSIT_100K_SHARES - 22;
        _requestRedeemTo(alice, 11,   alice);
        _requestRedeemTo(alice, 11,   bob);
        _requestRedeemTo(alice, rest, carol);

        assertEq(vault.availableLiquidAssets(), 99_999_999_999);
        assertEq(_liquidShares(),               DEPOSIT_100K_SHARES);  // everything fits the budget

        ( uint256 a1, uint256 b1 ) = _fillMath(11);
        ( uint256 a3, uint256 b3 ) = _fillMath(rest);
        assertEq(a1, 11);
        assertEq(b1, 11);
        assertEq(a3, 99_999_999_976);
        assertEq(2 * b1 + b3, DEPOSIT_100K_SPUSDC);  // an aggregate fill uses the backing exactly

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(0, alice, alice, 11, 11, 11);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(1, alice, bob,   11, 11, 11);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(2, alice, carol, rest - 1, 95_453_269_091, 99_999_999_975);
        _processRedeems(type(uint256).max, 3);

        assertEq(usdc.balanceOf(alice),           11);
        assertEq(usdc.balanceOf(bob),             11);
        assertEq(usdc.balanceOf(carol),           99_999_999_975);
        assertEq(_vaultSpUsdc(),                  1);
        assertEq(usdc.balanceOf(address(spUsdc)), 3);
        assertEq(_queued(2),                      1);
        assertEq(vault.pendingRedeemShares(),     1);
        assertEq(vault.firstPendingRedeemId(),    2);
        assertEq(vault.totalSupply(),             1);
    }

    // The per-entry bound makes a batch of N identical to N single-entry calls: here the same
    // three-entry case, (max, 1) three times, lands on the identical state.
    function test_fixed_C1_batchEqualsOnePerCall() external {
        _deposit(alice, 1_000_000e6);
        _drainSpUsdcLiquidity(2);
        _requestRedeemTo(alice, 22_947_880_715,  alice);
        _requestRedeemTo(alice, 299_586_688_493, bob);
        _requestRedeemTo(alice, 667_870_614_900, carol);

        uint256 snap = vm.snapshotState();
        _processRedeems(type(uint256).max, 3);
        uint256 a = usdc.balanceOf(alice);
        uint256 b = usdc.balanceOf(bob);
        uint256 c = usdc.balanceOf(carol);
        uint256 s = _vaultSpUsdc();
        uint256 q = _queued(2);
        vm.revertToState(snap);

        _processRedeems(type(uint256).max, 1);
        _processRedeems(type(uint256).max, 1);
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice), a);
        assertEq(usdc.balanceOf(bob),   b);
        assertEq(usdc.balanceOf(carol), c);
        assertEq(_vaultSpUsdc(),        s);
        assertEq(_queued(2),            q);
        assertEq(q,                     2);
    }

    /**********************************************************************************************/
    /*** R5-10: unpayable dust at the head                                                      ***/
    /**********************************************************************************************/

    // BUG (R5-10, Info, still open with the per-entry bound): when the vault's backing is down
    // to 1 spUSDC wei (`maxWithdraw` floors it to 1 USDC wei, which converts to 0 shares) the
    // head entry's remaining shares are unpayable and the whole queue behind it is frozen until
    // ANY new backing arrives (1 extra spUSDC wei is enough). Reached with `take` here: the
    // taker leaves S = 95_453_269_113, one wei short of alice's claim; alice is paid
    // 99_999_999_997 and her last share, worth 1 USDC wei, blocks bob.
    function test_BUG_processPendingRedeems_unpayableDustAtHeadFreezesQueue_R5_10() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idB = _requestRedeem(bob,   DEPOSIT_100K_SHARES);
        _take(DEPOSIT_100K_SPUSDC + 1);

        assertEq(_vaultSpUsdc(),                95_453_269_113);
        assertEq(vault.availableLiquidAssets(), 99_999_999_998);
        assertEq(_liquidShares(),               99_040_518_409);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),         99_999_999_997);
        assertEq(usdc.balanceOf(bob),           0);
        assertEq(_queued(idA),                  1);
        assertEq(_queued(idB),                  DEPOSIT_100K_SHARES);
        assertEq(vault.firstPendingRedeemId(),  idA);
        assertEq(_vaultSpUsdc(),                1);
        assertEq(vault.availableLiquidAssets(), 1);
        assertEq(_liquidShares(),               0);
        assertEq(vault.convertToAssets(1),      1);  // the share IS worth 1 wei, just not payable

        // Stuck: calls are no-ops, bob behind is frozen, time does not help.
        _processRedeems(type(uint256).max, 10);
        _warpAndDrip(30 days);
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice),        99_999_999_997);
        assertEq(usdc.balanceOf(bob),          0);
        assertEq(vault.firstPendingRedeemId(), idA);

        // Self-healing: one more spUSDC wei makes A = 2 USDC wei = 1 share.
        _returnToVault(1);
        assertEq(_liquidShares(), 1);
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice),        FILL_100K_ASSETS);
        assertEq(_queued(idA),                 0);
        assertEq(vault.firstPendingRedeemId(), idB);
        assertEq(usdc.balanceOf(bob),          0);  // bob still waits for his own backing

        _returnToVault(DEPOSIT_100K_SPUSDC);
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(bob),          FILL_100K_ASSETS);
        assertEq(vault.firstPendingRedeemId(), 2);
    }

    // Chunking cost (operator-chosen `maxShares_`): each piece pays floor(piece * chi_p / RAY)
    // and burns ceil, so 13 chunks of 7_777_777_777 shares yield 99_999_999_990 instead of
    // 99_999_999_998 in one fill (6 wei of floors), and the ceil burns eat the backing of the
    // last 2 shares, which stick at the head (R5-10) until 2 spUSDC wei arrive.
    function test_processPendingRedeems_manyPartialFills_sumNeverExceedsOneFill() external {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        uint256 piece = 7_777_777_777;
        for (uint256 calls; calls < 13; ++calls) {
            assertEq(_queued(id), DEPOSIT_100K_SHARES - calls * piece);
            _processRedeems(piece, 1);
        }

        assertEq(usdc.balanceOf(alice), 99_999_999_990);
        assertEq(_queued(id),           2);
        assertEq(_vaultSpUsdc(),        1);
        assertEq(_liquidShares(),       0);
        _processRedeems(type(uint256).max, 1);
        assertEq(_queued(id), 2);

        _returnToVault(2);
        _processRedeems(type(uint256).max, 1);
        assertEq(_queued(id),                  0);
        assertEq(usdc.balanceOf(alice),        99_999_999_992);  // 2 shares -> 2 wei
        assertEq(vault.firstPendingRedeemId(), 1);
    }

    /**********************************************************************************************/
    /*** Zero-share entries (R5-14)                                                             ***/
    /**********************************************************************************************/

    // A 0-share entry is no longer `continue`d: it is "filled" for 0 (burn 0, `withdraw(0)`,
    // `Redeem(id, owner, recipient, 0, 0, 0)`) and deleted, costing one `maxRequests_` slot and
    // one spUSDC call. It needs `fillable_ != 0` to be walked: with `maxShares_ == 0` the loop
    // does not run, and with no liquidity the `break` (:955) fires before it.
    function test_processPendingRedeems_zeroShareEntry_filledForZeroAndDeleted() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idZ = _zeroShareEntry(alice);
        uint256 idB = _requestRedeem(bob, DEPOSIT_100K_SHARES);

        assertEq(idZ, 0);
        assertEq(idB, 1);
        assertEq(vault.pendingRedeemShares(), DEPOSIT_100K_SHARES);

        // (0, 10): `remaining_ == 0`, nothing walks.
        _processRedeems(0, 10);
        assertEq(vault.firstPendingRedeemId(), 0);

        // No liquidity: `fillable_ == 0` -> break before the zero entry.
        _drainAllSpUsdcLiquidity();
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.firstPendingRedeemId(), 0);
        _returnSpUsdcLiquidity(200_000e6);

        // One slot: the zero entry is filled for 0 and deleted, bob is not reached.
        ( address o, address r, ) = _rawRedeem(idZ);
        assertEq(o, alice);
        assertEq(r, alice);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(idZ, alice, alice, 0, 0, 0);
        _processRedeems(type(uint256).max, 1);

        ( o, r, ) = _rawRedeem(idZ);
        assertEq(o, address(0));
        assertEq(r, address(0));
        assertEq(vault.firstPendingRedeemId(), 1);
        assertEq(usdc.balanceOf(bob),          0);
        assertEq(_vaultSpUsdc(),               2 * DEPOSIT_100K_SPUSDC);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),          FILL_100K_ASSETS);
        assertEq(vault.firstPendingRedeemId(), 2);
    }

    // Two zero entries then bob: (max, 2) pays nobody and moves the head past both.
    function test_processPendingRedeems_zeroShareEntries_countTowardMaxRequests() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _zeroShareEntry(alice);                                    // 0
        _zeroShareEntry(alice);                                    // 1
        uint256 idB = _requestRedeem(bob, DEPOSIT_100K_SHARES);    // 2
        assertEq(idB, 2);
        assertEq(vault.balanceOf(alice), DEPOSIT_100K_SHARES - 2);

        _processRedeems(type(uint256).max, 2);
        assertEq(usdc.balanceOf(bob),          0);
        assertEq(vault.firstPendingRedeemId(), 2);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),          FILL_100K_ASSETS);
        assertEq(vault.firstPendingRedeemId(), 3);
    }

    // A zero entry aimed at a blacklisted recipient goes through the fallback for 0:
    // `ClaimableAssetsIncreased(recipient, 0)` is emitted and nothing is credited.
    function test_processPendingRedeems_zeroShareEntry_blacklistedRecipient_creditsZero() external {
        _deposit(alice, 100_000e6);
        uint256 idZ = _zeroShareEntry(alice);
        _blacklist(alice);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(alice, 0);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(idZ, alice, alice, 0, 0, 0);
        _processRedeems(type(uint256).max, 1);

        assertEq(vault.claimableAssets(alice), 0);
        assertEq(vault.totalClaimable(),       0);
        assertEq(vault.firstPendingRedeemId(), 1);
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(alice);
    }

    /**********************************************************************************************/
    /*** Yield while queued                                                                     ***/
    /**********************************************************************************************/

    // Escrowed shares keep accruing at the prime VSR; the redeemer is paid at fill-time chi.
    function test_processPendingRedeems_primeYieldAccruesWhileQueued() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);  // extra backing so alice's accrued claim is payable
        _setPrimeVsr(FIVE_PCT_VSR);

        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        assertEq(vault.convertToAssets(DEPOSIT_100K_SHARES), FILL_100K_ASSETS);

        _warpAndDrip(365 days);

        assertEq(vault.nowChi(), 1.060172156654584269839902363e27);
        assertEq(vault.convertToAssets(DEPOSIT_100K_SHARES), 104_999_999_998);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, alice, DEPOSIT_100K_SHARES, 100_225_932_569, 104_999_999_998);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),       104_999_999_998);
        assertEq(_queued(id),                 0);
        assertEq(vault.pendingRedeemShares(), 0);

        // Paid out of the common backing: bob's notional claim is now backed by 95_000_000_000.
        assertEq(vault.assetsOf(bob),                    104_999_999_998);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 95_000_000_000);
    }

    // spUSDC yields while the prime index is flat: the redeemer gets the prime value only; the
    // surplus stays in the vault as unassigned backing.
    function test_processPendingRedeems_spUsdcYieldStaysInVault() external {
        _deposit(alice, 100_000e6);
        _setSpUsdcVsr(FIVE_PCT_VSR);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        _warpAndDrip(365 days);

        assertEq(vault.nowChi(), CHI_P);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 104_999_999_999);
        assertEq(vault.availableLiquidAssets(), 100_000e6);  // USDC liquidity binds, not the claim

        _returnSpUsdcLiquidity(5_000e6);
        assertEq(vault.availableLiquidAssets(), 104_999_999_999);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),       FILL_100K_ASSETS);
        assertEq(_queued(id),                 0);
        assertEq(vault.totalSupply(),         0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 5_000_000_000);
        assertEq(vault.totalAssets(),                    0);
    }

    /**********************************************************************************************/
    /*** Large queue, batched processing, gas                                                   ***/
    /**********************************************************************************************/

    function test_processPendingRedeems_200UsersIn4BatchesOf50() external {
        uint256 n = 200;
        address[] memory users = new address[](n);
        for (uint256 i; i < n; ++i) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
            _deposit(users[i], 5_000e6);
            assertEq(vault.balanceOf(users[i]), 4_952_025_919);
            _requestRedeem(users[i], 4_952_025_919);
        }

        assertEq(vault.pendingRedeemShares(),     n * 4_952_025_919);
        assertEq(vault.balanceOf(address(vault)), n * 4_952_025_919);
        assertEq(_vaultSpUsdc(),                  n * 4_772_663_455);
        assertEq(_queueLength(),                  n);

        uint256 totalGas;
        for (uint256 b; b < 4; ++b) {
            uint256 g = gasleft();
            _processRedeems(type(uint256).max, 50);
            totalGas += g - gasleft();
            assertEq(vault.firstPendingRedeemId(), (b + 1) * 50);
        }
        emit log_named_uint("gas for 200 fills (4 calls of 50)", totalGas);
        emit log_named_uint("gas per fill",                      totalGas / n);
        // Round 5 was < 60k per fill; the per-entry `maxWithdraw` re-read costs ~6k more.
        assertLt(totalGas / n, 70_000);

        for (uint256 i; i < n; ++i) {
            assertEq(usdc.balanceOf(users[i]), 4_999_999_998);
            assertEq(_queued(i),               0);
        }
        assertEq(vault.firstPendingRedeemId(),    200);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(),             0);
        assertEq(_vaultSpUsdc(),                  n);  // 1 ceil wei per fill
        assertEq(usdc.balanceOf(address(spUsdc)), n * 5_000e6 - n * 4_999_999_998);
    }

}

/**************************************************************************************************/
/*** _withdrawSavings try/catch fallback (R4-A / R4-B fixed)                                    ***/
/**************************************************************************************************/

contract ProcessPendingRedeemsFallbackTests is RedeemQueueTestBase {

    // FIXED (R4-A): a recipient blacklisted AFTER queueing no longer jams the queue. The fill
    // burns the shares (:964), the first `withdraw` to alice reverts inside USDC and is caught
    // (:1001-1005), the vault withdraws to itself (:1011) and credits `claimableAssets` +
    // `totalClaimable` (:1100-1105); bob behind is paid directly in the same call.
    function test_fixed_R4A_blacklistedAfterRequest_queueKeepsMoving_claimableExact() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idB = _requestRedeem(bob,   DEPOSIT_100K_SHARES);

        _blacklist(alice);

        assertEq(vault.claimableAssets(alice),   0);
        assertEq(vault.totalClaimable(),         0);
        assertEq(usdc.balanceOf(address(vault)), 0);

        vm.expectEmit(address(usdc));
        emit IERC20.Transfer(address(spUsdc), address(vault), FILL_100K_ASSETS);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(alice, FILL_100K_ASSETS);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(idA, alice, alice, DEPOSIT_100K_SHARES, FILL_100K_SPUSDC, FILL_100K_ASSETS);
        vm.expectEmit(address(usdc));
        emit IERC20.Transfer(address(spUsdc), bob, FILL_100K_ASSETS);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(idB, bob, bob, DEPOSIT_100K_SHARES, FILL_100K_SPUSDC, FILL_100K_ASSETS);
        _processRedeems(type(uint256).max, 10);

        assertEq(vault.claimableAssets(alice),    FILL_100K_ASSETS);
        assertEq(vault.totalClaimable(),          FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(address(vault)),  FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(alice),           0);
        assertEq(usdc.balanceOf(bob),             FILL_100K_ASSETS);
        assertEq(_queued(idA),                    0);
        assertEq(_queued(idB),                    0);
        assertEq(vault.firstPendingRedeemId(),    2);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(),             0);
        assertEq(_vaultSpUsdc(),                  2);
        assertEq(vault.availableLiquidAssets(),   2);  // the parked USDC is not vault backing
        assertEq(vault.totalAssets(),             0);

        vm.expectRevert(BLACKLISTED);
        vault.claim(alice);
        assertEq(vault.claimableAssets(alice), FILL_100K_ASSETS);

        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(bob);

        _unblacklist(alice);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Claim(alice, FILL_100K_ASSETS);
        vm.prank(carol);  // permissionless
        uint256 claimed = vault.claim(alice);

        assertEq(claimed,                        FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(alice),          FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(carol),          0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.claimableAssets(alice),   0);
        assertEq(vault.totalClaimable(),         0);

        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(alice);
    }

    // NEW on c512609: a recipient blacklisted AT request time is accepted (no check) and handled
    // by the same fallback at fill time; the owner can also claim-repoint later.
    function test_fixed_blacklistedAtRequest_acceptedAndCreditedAtFill() external {
        _deposit(alice, 100_000e6);
        _blacklist(bob);
        uint256 id = _requestRedeemTo(alice, DEPOSIT_100K_SHARES, bob);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, FILL_100K_ASSETS);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, bob, DEPOSIT_100K_SHARES, FILL_100K_SPUSDC, FILL_100K_ASSETS);
        _processRedeems(type(uint256).max, 1);

        assertEq(vault.claimableAssets(bob),     FILL_100K_ASSETS);
        assertEq(vault.totalClaimable(),         FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(address(vault)), FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(bob),            0);
        assertEq(vault.firstPendingRedeemId(),   1);

        _unblacklist(bob);
        assertEq(vault.claim(bob), FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(bob), FILL_100K_ASSETS);
    }

    // FIXED: a blacklisted recipient in the middle of a batch does not roll the batch back.
    function test_fixed_blacklistedRecipient_midBatch_noRollback() external {
        _threeDepositorsQueued();
        _blacklist(bob);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),          FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(bob),            0);
        assertEq(vault.claimableAssets(bob),     FILL_100K_ASSETS);
        assertEq(vault.totalClaimable(),         FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(carol),          FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(address(vault)), FILL_100K_ASSETS);
        assertEq(vault.firstPendingRedeemId(),   3);
        assertEq(vault.pendingRedeemShares(),    0);
        assertEq(_vaultSpUsdc(),                 3);
    }

    // Credits accumulate (`+=` at :1101-1102) across partial fills and entries; the vault's USDC
    // equals `totalClaimable` equals the sum of credits at every step.
    function test_fixed_blacklistedRecipients_accumulateAcrossPartialFillsAndEntries() external {
        _deposit(alice, 100_000e6);
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _requestRedeem(alice, DEPOSIT_100K_SHARES);         // 0
        _requestRedeem(alice, DEPOSIT_100K_SHARES);         // 1
        _requestRedeemTo(bob, DEPOSIT_100K_SHARES, carol);  // 2
        _blacklist(alice);
        _blacklist(carol);

        _processRedeems(50_000_000_000, 10);
        assertEq(vault.claimableAssets(alice),   50_484_388_412);
        assertEq(vault.totalClaimable(),         50_484_388_412);
        assertEq(usdc.balanceOf(address(vault)), 50_484_388_412);
        assertEq(_vaultSpUsdc(),                 3 * DEPOSIT_100K_SPUSDC - 48_188_999_132);
        assertEq(vault.firstPendingRedeemId(),   0);

        _processRedeems(type(uint256).max, 10);
        assertEq(vault.claimableAssets(alice),   199_999_999_996);
        assertEq(vault.claimableAssets(carol),   FILL_100K_ASSETS);
        assertEq(vault.totalClaimable(),         199_999_999_996 + FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(address(vault)), 199_999_999_996 + FILL_100K_ASSETS);
        assertEq(_vaultSpUsdc(),                 3);
        assertEq(vault.firstPendingRedeemId(),   3);
        assertEq(vault.pendingRedeemShares(),    0);
        assertEq(vault.totalSupply(),            0);

        _unblacklist(alice);
        vault.claim(alice);
        assertEq(usdc.balanceOf(alice),          199_999_999_996);
        assertEq(usdc.balanceOf(address(vault)), FILL_100K_ASSETS);
        assertEq(vault.totalClaimable(),         FILL_100K_ASSETS);
        assertEq(vault.claimableAssets(carol),   FILL_100K_ASSETS);

        _unblacklist(carol);
        vault.claim(carol);
        assertEq(usdc.balanceOf(carol),          FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalClaimable(),         0);
    }

    function test_fixed_blacklistedThenUnblacklistedBeforeFill_paidDirectly() external {
        _deposit(alice, 100_000e6);
        _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _blacklist(alice);
        _unblacklist(alice);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),          FILL_100K_ASSETS);
        assertEq(vault.claimableAssets(alice),   0);
        assertEq(vault.totalClaimable(),         0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(alice);
    }

    // The honest-victim shape: no role needed, bob behind is paid, alice's credit waits; a year
    // of accrual adds nothing to a USDC credit.
    function test_fixed_blacklistedOwnerNoLongerNeedsToSelfRescue() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idB = _requestRedeem(bob,   DEPOSIT_100K_SHARES);
        _blacklist(alice);

        _processRedeems(type(uint256).max, 1);
        assertEq(vault.claimableAssets(alice), FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(bob),          0);
        assertEq(vault.firstPendingRedeemId(), 1);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),          FILL_100K_ASSETS);
        assertEq(vault.firstPendingRedeemId(), 2);
        assertEq(_queued(idA), 0);
        assertEq(_queued(idB), 0);

        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);
        _unblacklist(alice);
        assertEq(vault.claim(alice), FILL_100K_ASSETS);
    }

    // The parked USDC is inert: `adjustTotalAssets` (LOSS_MANAGER) reprices shares, not
    // credits; `take` moves spUSDC only; `requestDeposit` passes through; `claim` works paused.
    function test_fixed_claimableAssets_unaffectedByAdjustTotalAssetsTakeDepositsAndPause() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _blacklist(alice);
        _processRedeems(type(uint256).max, 10);
        assertEq(vault.claimableAssets(alice),   FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(address(vault)), FILL_100K_ASSETS);
        assertEq(vault.totalAssets(),            FILL_100K_ASSETS);  // bob only

        _pause();
        _adjustTotalAssets(-99_000_000_000);
        assertEq(vault.totalAssets(),            999_999_997);
        assertEq(vault.assetsOf(bob),            999_999_997);
        assertEq(vault.claimableAssets(alice),   FILL_100K_ASSETS);
        assertEq(vault.totalClaimable(),         FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(address(vault)), FILL_100K_ASSETS);

        _takeAll();
        assertEq(_vaultSpUsdc(),                 0);
        assertEq(usdc.balanceOf(address(vault)), FILL_100K_ASSETS);
        _unpause();

        _deposit(carol, 100_000e6);
        assertEq(usdc.balanceOf(address(vault)), FILL_100K_ASSETS);
        assertEq(vault.claimableAssets(alice),   FILL_100K_ASSETS);

        _pause();
        _unblacklist(alice);
        assertEq(vault.claim(alice), FILL_100K_ASSETS);  // not pause-gated
        assertEq(usdc.balanceOf(alice),          FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalClaimable(),         0);
    }

    // A recipient that is a contract which reverts on everything is paid directly: an ERC20
    // transfer never calls the receiver, so only the token's own checks (the blacklist) can
    // trigger the fallback.
    function test_processPendingRedeems_revertingContractRecipient_paidDirectly() external {
        RevertingRecipient sink = new RevertingRecipient();
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeemTo(alice, DEPOSIT_100K_SHARES, address(sink));

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, address(sink), DEPOSIT_100K_SHARES, FILL_100K_SPUSDC, FILL_100K_ASSETS);
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(address(sink)),         FILL_100K_ASSETS);
        assertEq(vault.claimableAssets(address(sink)),  0);
        assertEq(vault.totalClaimable(),                0);
    }

    // R4-B: a revert that is NOT recipient-specific hits both branches of the try/catch and
    // propagates: with every spUSDC `withdraw` mocked to revert `SparkVault/insufficient-
    // liquidity`, the fallback `withdraw` to the vault reverts too, the call reverts with that
    // reason and nothing moves (no burn, no credit, no head advance).
    function test_processPendingRedeems_nonRecipientRevert_propagatesThroughBothBranches() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _requestRedeem(bob,   DEPOSIT_100K_SHARES);

        vm.mockCallRevert(
            address(spUsdc),
            IERC4626WithdrawLike.withdraw.selector,
            abi.encodeWithSignature("Error(string)", "SparkVault/insufficient-liquidity")
        );

        vm.prank(operator);
        vm.expectRevert("SparkVault/insufficient-liquidity");
        vault.processPendingRedeems(type(uint256).max, 10);

        assertEq(vault.firstPendingRedeemId(),    0);
        assertEq(vault.pendingRedeemShares(),     2 * DEPOSIT_100K_SHARES);
        assertEq(vault.balanceOf(address(vault)), 2 * DEPOSIT_100K_SHARES);
        assertEq(vault.totalSupply(),             2 * DEPOSIT_100K_SHARES);
        assertEq(vault.claimableAssets(alice),    0);
        assertEq(vault.totalClaimable(),          0);
        assertEq(_vaultSpUsdc(),                  2 * DEPOSIT_100K_SPUSDC);

        vm.clearMockedCalls();
        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(bob),   FILL_100K_ASSETS);
    }

    // The natural version of the same: the VAULT itself blacklisted. Direct payouts still work
    // (USDC moves spUSDC -> recipient, the vault is not a party), but a blacklisted recipient at
    // the head reverts in BOTH branches (the fallback transfers to the blacklisted vault) and
    // jams the queue until the owner repoints. Info: needs Circle to blacklist the vault.
    function test_processPendingRedeems_vaultBlacklisted_directPayoutWorks_fallbackJams() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _requestRedeem(bob, DEPOSIT_100K_SHARES);
        _blacklist(address(vault));

        vm.prank(carol);
        vm.expectRevert(BLACKLISTED);
        vault.requestDeposit(1, carol, 0);

        _processRedeems(type(uint256).max, 1);  // alice paid directly
        assertEq(usdc.balanceOf(alice),        FILL_100K_ASSETS);
        assertEq(vault.firstPendingRedeemId(), 1);

        _blacklist(bob);
        vm.prank(operator);
        vm.expectRevert(BLACKLISTED);
        vault.processPendingRedeems(type(uint256).max, 1);
        assertEq(vault.firstPendingRedeemId(), 1);
        assertEq(vault.totalClaimable(),       0);

        vm.prank(bob);
        vault.updateRedeemRecipient(1, carol);
        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(carol),        FILL_100K_ASSETS);
        assertEq(vault.firstPendingRedeemId(), 2);
        assertEq(_queued(idA), 0);
    }

    // BUG (V2-13 remnant, Low, open): `savings` (spUSDC) is still accepted as recipient (only
    // the vault is rejected, :455). spUSDC transfers the USDC to itself, the vault's spUSDC is
    // burned and the value is donated to spUSDC holders. Self-inflicted; one more address check.
    function test_BUG_processPendingRedeems_recipientIsSpUsdc_donatesToSpUsdc_V2_13() external {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeemTo(alice, DEPOSIT_100K_SHARES, address(spUsdc));

        uint256 spUsdcLiq = usdc.balanceOf(address(spUsdc));

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, address(spUsdc), DEPOSIT_100K_SHARES, FILL_100K_SPUSDC, FILL_100K_ASSETS);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(address(spUsdc)),        spUsdcLiq);  // unchanged
        assertEq(_vaultSpUsdc(),                         1);
        assertEq(spUsdc.totalSupply(),                   1);
        assertEq(usdc.balanceOf(alice),                  0);
        assertEq(vault.claimableAssets(address(spUsdc)), 0);
        assertEq(vault.totalClaimable(),                 0);
        assertEq(vault.totalSupply(),                    0);
    }

    // The fallback uses the same `withdraw(assets_)` as the direct path: credit ==
    // floor(fill * chi_p / RAY), burn == ceil(credit * RAY / chi_s), under random indexes,
    // liquidity and take().
    function testFuzz_processPendingRedeems_blacklistFallback_sameMathAsDirectPayout(
        uint256 vsrS, uint256 vsrP, uint256 warp, uint256 depositAmt, uint256 drain, uint256 take_
    ) external {
        vsrS       = bound(vsrS, RAY, MAX_VSR);
        vsrP       = bound(vsrP, RAY, MAX_VSR);
        warp       = bound(warp, 0, 5 * 365 days);
        depositAmt = bound(depositAmt, 1, 1_000_000_000e6);

        _setSpUsdcVsr(vsrS);
        _setPrimeVsr(vsrP);
        _deposit(alice, depositAmt);
        _warpAndDrip(warp);

        uint256 shares = vault.balanceOf(alice);
        vm.assume(shares != 0);
        _requestRedeem(alice, shares);
        _blacklist(alice);

        drain = bound(drain, 0, usdc.balanceOf(address(spUsdc)));
        take_ = bound(take_, 0, _vaultSpUsdc());
        _drainSpUsdcLiquidity(drain);
        _take(take_);

        uint256 spUsdcBefore = _vaultSpUsdc();
        uint256 liqBefore    = usdc.balanceOf(address(spUsdc));
        uint256 rem          = _liquidShares();
        uint256 fill         = rem < shares ? rem : shares;
        ( uint256 assets, uint256 burned ) = _fillMath(fill);

        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice),           0);
        assertEq(vault.claimableAssets(alice),    assets);
        assertEq(vault.totalClaimable(),          assets);
        assertEq(usdc.balanceOf(address(vault)),  assets);
        assertEq(_vaultSpUsdc(),                  spUsdcBefore - burned);
        assertEq(usdc.balanceOf(address(spUsdc)), liqBefore - assets);
        assertEq(vault.pendingRedeemShares(),     shares - fill);

        if (assets != 0) {
            _unblacklist(alice);
            assertEq(vault.claim(alice), assets);
            assertEq(usdc.balanceOf(alice),          assets);
            assertEq(usdc.balanceOf(address(vault)), 0);
            assertEq(vault.totalClaimable(),         0);
        }
    }

    // Random ops with blacklist toggles, requests aimed at blacklisted recipients, claims,
    // drains and takes: the vault's USDC == totalClaimable == sum of credits after every step;
    // escrow == pendingRedeemShares; credits only grow outside `claim`; processing never
    // reverts.
    function testFuzz_blacklistFallback_vaultUsdcEqualsTotalClaimable(uint256 seed) external {
        address[3] memory users = [alice, bob, carol];
        _setSpUsdcVsr(FOUR_PCT_VSR);
        _setPrimeVsr(ONE_PCT_VSR);
        _setRedeemFeeRate(0.001e18);

        for (uint256 step; step < 24; ++step) {
            uint256 r      = uint256(keccak256(abi.encode(seed, step)));
            address u      = users[r % 3];
            address to     = users[(r >> 72) % 3];
            uint256 action = (r >> 8) % 8;
            uint256 amt    = (r >> 16) % 1_000_000e6 + 1;

            if (action == 0) {
                if (!usdc.isBlacklisted(u)) _deposit(u, amt);
            } else if (action == 1) {
                uint256 bal = vault.balanceOf(u);
                if (bal != 0) _requestRedeemTo(u, bound(amt, 1, bal), to);  // blacklisted ok
            } else if (action == 2) {
                uint256[3] memory credit;
                for (uint256 i; i < 3; ++i) credit[i] = vault.claimableAssets(users[i]);
                _processRedeems((r >> 40) % 2 == 0 ? type(uint256).max : amt, (r >> 48) % 4);
                for (uint256 i; i < 3; ++i) {
                    assertGe(vault.claimableAssets(users[i]), credit[i]);
                    if (!usdc.isBlacklisted(users[i])) assertEq(vault.claimableAssets(users[i]), credit[i]);
                }
            } else if (action == 3) {
                usdc.setBlacklisted(u, !usdc.isBlacklisted(u));
            } else if (action == 4) {
                uint256 credit = vault.claimableAssets(u);
                uint256 before = usdc.balanceOf(u);
                if (credit == 0) {
                    vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
                    vault.claim(u);
                } else if (usdc.isBlacklisted(u)) {
                    vm.expectRevert(BLACKLISTED);
                    vault.claim(u);
                    assertEq(vault.claimableAssets(u), credit);
                } else {
                    assertEq(vault.claim(u), credit);
                    assertEq(usdc.balanceOf(u), before + credit);
                    assertEq(vault.claimableAssets(u), 0);
                }
            } else if (action == 5) {
                uint256 liq = usdc.balanceOf(address(spUsdc));
                if (liq != 0) _drainSpUsdcLiquidity(bound(amt, 1, liq));
            } else if (action == 6) {
                _returnSpUsdcLiquidity(amt);
            } else {
                uint256 held = _vaultSpUsdc();
                if (held != 0) _take(bound(amt, 1, held));
            }
            _warpAndDrip((r >> 64) % 7 days);

            uint256 credits;
            for (uint256 i; i < 3; ++i) credits += vault.claimableAssets(users[i]);
            assertEq(usdc.balanceOf(address(vault)),  credits);
            assertEq(vault.totalClaimable(),          credits);
            assertEq(vault.balanceOf(address(vault)), vault.pendingRedeemShares());
        }
    }

}

contract RevertingRecipient {
    fallback() external payable { revert("RevertingRecipient"); }
    receive()  external payable { revert("RevertingRecipient"); }
}

/**************************************************************************************************/
/*** adjustTotalAssets while queued                                                             ***/
/**************************************************************************************************/

contract ProcessPendingRedeemsAdjustTotalAssetsTests is RedeemQueueTestBase {

    // `adjustTotalAssets` (:262-283, LOSS_MANAGER, paused only) sets chi for everyone, escrowed
    // shares included: a queued redeemer is paid at the reduced chi and takes the loss pro rata.
    function test_processPendingRedeems_lossWhileQueued_escrowTakesLossProRata() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        assertEq(vault.totalAssets(), 199_999_999_997);

        _pause();

        vm.prank(admin);  // the admin lost this power
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, admin, LOSS_MANAGER_ROLE
        ));
        vault.adjustTotalAssets(-10_000e6);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.TotalAssetsAdjusted(uint192(0.959203379825079411152892409e27), -10_000e6);
        _adjustTotalAssets(-10_000e6);  // 5% of the book
        _unpause();

        assertEq(vault.nowChi(), (199_999_999_997 - 10_000e6) * RAY / (2 * DEPOSIT_100K_SHARES));
        assertEq(vault.nowChi(), 0.959203379825079411152892409e27);
        assertEq(vault.totalAssets(), 189_999_999_996);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, alice, DEPOSIT_100K_SHARES, 90_680_605_657, 94_999_999_998);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),       94_999_999_998);
        assertEq(_queued(id),                 0);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.assetsOf(bob),         94_999_999_998);

        // The backing did not shrink: 105_000_000_000 USDC of spUSDC backs bob's 94_999_999_998.
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 105_000_000_000);
    }

    // A gain while queued is paid out of the common backing too.
    function test_processPendingRedeems_gainWhileQueued_escrowSharesGainProRata() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        vm.prank(lossManager);
        vm.expectRevert(ISparkPrimeVault.IsNotPaused.selector);
        vault.adjustTotalAssets(10_000e6);

        _pause();

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vault.requestRedeem(1, bob);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.TotalAssetsAdjusted(uint192(1.060172156650366224592543507e27), 10_000e6);
        _adjustTotalAssets(10_000e6);
        _unpause();

        assertEq(vault.nowChi(),      1.060172156650366224592543507e27);
        assertEq(vault.totalAssets(), 209_999_999_996);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, alice, DEPOSIT_100K_SHARES, 100_225_932_569, 104_999_999_998);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),                  104_999_999_998);
        assertEq(vault.assetsOf(bob),                    104_999_999_998);
        assertEq(_vaultSpUsdc(),                         90_680_605_659);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 95_000_000_000);
    }

    // BUG (C-3 / R5-3, High, open; worse on c512609: a hot-wallet LOSS_MANAGER_ROLE instead of
    // the admin): the only floors are `totalAssets_ > 0` (:274) and `updatedChi_ != 0` (:279).
    // `adjustTotalAssets(-(totalAssets - 1))` sets chi to 5_048_438_841_264_340; the next fill
    // burns alice's escrow for 0 USDC (`Redeem(0, alice, alice, 99_040_518_410, 0, 0)`), the
    // backing is left unassigned and `take` removes it all. Irreversible for alice.
    function test_BUG_adjustTotalAssets_wipesQueuedRedeemer_C3() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        assertEq(vault.totalAssets(), 199_999_999_997);

        _pause();
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.TotalAssetsAdjusted(uint192(5_048_438_841_264_340), -199_999_999_996);
        _adjustTotalAssets(-199_999_999_996);
        _unpause();

        assertEq(vault.nowChi(),                             5_048_438_841_264_340);
        assertEq(vault.totalAssets(),                        0);
        assertEq(vault.convertToAssets(DEPOSIT_100K_SHARES), 0);
        assertEq(_liquidShares(),                            39_616_207_363_801_924_236_374);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, alice, DEPOSIT_100K_SHARES, 0, 0);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),                  0);
        assertEq(_queued(id),                            0);
        assertEq(vault.firstPendingRedeemId(),           1);
        assertEq(vault.pendingRedeemShares(),            0);
        assertEq(vault.totalSupply(),                    DEPOSIT_100K_SHARES);
        assertEq(_vaultSpUsdc(),                         2 * DEPOSIT_100K_SPUSDC);
        assertEq(spUsdc.convertToAssets(_vaultSpUsdc()), 199_999_999_999);

        _takeAll();
        assertEq(spUsdc.balanceOf(taker), 2 * DEPOSIT_100K_SPUSDC);

        _pause();
        _adjustTotalAssets(199_999_999_996);
        _unpause();
        assertEq(vault.assetsOf(bob),    199_999_999_995);
        assertEq(vault.balanceOf(alice), 0);
    }

    // Asymmetry: the redeem escrow is in spPRIME shares and takes the loss; a queued deposit is
    // in spUSDC shares and does not.
    function test_adjustTotalAssets_queuedRedeemTakesLoss_queuedDepositDoesNot() external {
        _deposit(alice, 100_000e6);
        _setCapacity(DEPOSIT_100K_SHARES);
        uint256 idR = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        uint256 idD = _deposit(bob, 100_000e6);  // queued: capacity is full
        ( , , uint256 bobQueued ) = _depositRequest(idD);
        assertEq(bobQueued,            DEPOSIT_100K_SPUSDC);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.totalAssets(),  FILL_100K_ASSETS);

        _adjustTotalAssetsWhilePaused(-10_000e6);
        assertEq(vault.nowChi(), 908_718_991_407_387_565_591_802_519);

        _processRedeems(type(uint256).max, 10);
        assertEq(usdc.balanceOf(alice), 89_999_999_997);  // alice bore the whole loss
        assertEq(_queued(idR),          0);
        assertEq(vault.totalSupply(),   0);
        assertEq(_vaultSpUsdc(),        2 * DEPOSIT_100K_SPUSDC - 85_907_942_201);

        assertEq(vault.availableCapacity(), DEPOSIT_100K_SHARES);
        _processDeposits(type(uint256).max, 10);

        ( , , uint256 bobLeft ) = _depositRequest(idD);
        assertEq(vault.balanceOf(bob),            99_040_518_407);
        assertEq(vault.assetsOf(bob),             89_999_999_995);
        assertEq(bobLeft,                         9_545_326_914);
        assertEq(spUsdc.convertToAssets(bobLeft), 10_000_000_002);
    }

    // R5-2 residual: a request queued before the pause captures nothing on a gain and cannot
    // escape a loss.
    function test_adjustTotalAssets_queueingBeforePauseCapturesNothing() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        _requestRedeem(alice, DEPOSIT_100K_SHARES);

        _adjustTotalAssetsWhilePaused(-10_000e6);
        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice), 94_999_999_998);
        assertEq(vault.assetsOf(bob),   94_999_999_998);
    }

    // After a loss chi_p < RAY, so a 1-share chunk pays floor(1 * 0.959) = 0 USDC: chunking
    // by tiny `maxShares_` burns shares for nothing (bounded by 1 wei per call).
    function test_processPendingRedeems_oneShareChunksAfterLossPayZero() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _adjustTotalAssetsWhilePaused(-10_000e6);

        assertEq(vault.convertToAssets(1), 0);
        for (uint256 i; i < 5; ++i) _processRedeems(1, 1);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(_queued(id),           DEPOSIT_100K_SHARES - 5);
        assertEq(vault.totalSupply(),   2 * DEPOSIT_100K_SHARES - 5);
    }

}

/**************************************************************************************************/
/*** updateRedeemRecipient                                                                      ***/
/**************************************************************************************************/

contract UpdateRedeemRecipientFailureTests is RedeemQueueTestBase {

    uint256 internal id;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 100_000e6);
        id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
    }

    function test_updateRedeemRecipient_zeroRecipient() external {
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vault.updateRedeemRecipient(id, address(0));
    }

    function test_updateRedeemRecipient_vaultIsRecipient() external {
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vault.updateRedeemRecipient(id, address(vault));
    }

    function test_updateRedeemRecipient_invalidRequestIdBoundary() external {
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.updateRedeemRecipient(id + 1, bob);

        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);
    }

    function test_updateRedeemRecipient_noRequest_filled() external {
        _processRedeems(type(uint256).max, 1);

        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(id, bob);
    }

    function test_updateRedeemRecipient_noRequest_zeroShareEntry() external {
        _deposit(bob, 100_000e6);
        uint256 idZ = _zeroShareEntry(bob);

        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(idZ, carol);
    }

    function test_updateRedeemRecipient_notRequestOwner() external {
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(id, bob);

        vm.prank(operator);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(id, bob);

        // Repointing to bob does not make bob the owner.
        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);
        vm.prank(bob);
        vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
        vault.updateRedeemRecipient(id, carol);
    }

}

contract UpdateRedeemRecipientSuccessTests is RedeemQueueTestBase {

    function test_updateRedeemRecipient_ownerRepointsAndFillPaysNewRecipient() external {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRecipientUpdated(id, bob);
        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);

        ( address o, address r, uint256 sh ) = vault.getPendingRedeemRequest(id);
        assertEq(o,  alice);
        assertEq(r,  bob);
        assertEq(sh, DEPOSIT_100K_SHARES);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),   FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(alice), 0);
    }

    // Works while paused (not gated).
    function test_updateRedeemRecipient_whilePaused() external {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _pause();

        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);
        ( , address r, ) = vault.getPendingRedeemRequest(id);
        assertEq(r, bob);
    }

    // NEW on c512609: a blacklisted recipient is accepted by the updater; the fill credits it.
    function test_updateRedeemRecipient_blacklistedRecipientAccepted_creditedAtFill() external {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _blacklist(bob);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRecipientUpdated(id, bob);
        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);

        _processRedeems(type(uint256).max, 1);
        assertEq(vault.claimableAssets(bob), FILL_100K_ASSETS);
        assertEq(vault.totalClaimable(),     FILL_100K_ASSETS);
        assertEq(usdc.balanceOf(bob),        0);
    }

    // BUG (V2-13 remnant, Low): repointing to spUSDC is accepted; the fill donates to spUSDC.
    function test_BUG_updateRedeemRecipient_spUsdcAccepted_V2_13() external {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);

        vm.prank(alice);
        vault.updateRedeemRecipient(id, address(spUsdc));

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(_vaultSpUsdc(),        1);
        assertEq(spUsdc.totalSupply(),  1);
    }

    // The owner is never blacklist-checked: a blacklisted owner can repoint a live entry to a
    // clean address after a first chunk was credited; the rest is paid directly, and the two
    // parts sum to one full fill to the wei. On c512609 she may also repoint to herself.
    function test_updateRedeemRecipient_blacklistedOwnerRepoints_mixedCreditAndDirectPayout() external {
        _deposit(alice, 100_000e6);
        uint256 id = _requestRedeem(alice, DEPOSIT_100K_SHARES);
        _blacklist(alice);

        _processRedeems(50_000_000_000, 1);
        assertEq(vault.claimableAssets(alice), 50_484_388_412);
        assertEq(_queued(id),                  49_040_518_410);

        vm.prank(alice);
        vault.updateRedeemRecipient(id, alice);  // herself, still blacklisted: accepted now

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRecipientUpdated(id, bob);
        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(id, alice, bob, 49_040_518_410, 47_264_269_981, 49_515_611_586);
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(bob),            49_515_611_586);
        assertEq(vault.claimableAssets(alice),   50_484_388_412);
        assertEq(vault.claimableAssets(bob),     0);
        assertEq(vault.totalClaimable(),         50_484_388_412);
        assertEq(usdc.balanceOf(address(vault)), 50_484_388_412);
        assertEq(_queued(id),                    0);
        assertEq(vault.firstPendingRedeemId(),   1);
        assertEq(uint256(50_484_388_412 + 49_515_611_586), FILL_100K_ASSETS);
    }

    // Partial fill (liquidity bound) leaves the entry at the head with owner, recipient and the
    // remainder; the owner repoints mid-fill: the part already paid stays with the old
    // recipient, the rest goes to the new one, and the two parts sum to one full fill.
    function test_updateRedeemRecipient_midFillRepoint_splitsOneFillToTheWei() external {
        _deposit(alice, 1_000_000e6);
        _deposit(carol, 100_000e6);
        uint256 idA = _requestRedeem(alice, DEPOSIT_1M_SHARES);    // 0
        uint256 idC = _requestRedeem(carol, DEPOSIT_100K_SHARES);  // 1
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 300_000e6);

        _processRedeems(type(uint256).max, 10);

        assertEq(usdc.balanceOf(alice),        299_999_999_999);
        assertEq(_queued(idA),                 693_283_628_876);
        assertEq(vault.firstPendingRedeemId(), 0);

        ( address o, address r, ) = vault.getPendingRedeemRequest(idA);
        assertEq(o, alice);
        assertEq(r, alice);

        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.RedeemRecipientUpdated(idA, bob);
        vm.prank(alice);
        vault.updateRedeemRecipient(idA, bob);

        _returnSpUsdcLiquidity(800_000e6);
        vm.expectEmit(address(vault));
        emit ISparkPrimeVault.Redeem(idA, alice, bob, 693_283_628_876, 668_172_883_799, 699_999_999_998);
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(bob),                         699_999_999_998);
        assertEq(usdc.balanceOf(alice),                       299_999_999_999);
        assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob), 999_999_999_997);
        assertEq(_queued(idA),                                0);
        assertEq(vault.firstPendingRedeemId(),                1);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(carol),        FILL_100K_ASSETS);
        assertEq(_queued(idC),                 0);
        assertEq(vault.firstPendingRedeemId(), 2);
    }

}

/**************************************************************************************************/
/*** Getters                                                                                    ***/
/**************************************************************************************************/

contract RedeemQueueGetterTests is RedeemQueueTestBase {

    // `getPendingRedeemRequest(id)` (:764-778) requires `head <= id < length`; a filled id below
    // the head reverts even though the slot still exists; a partially filled head is readable.
    function test_getPendingRedeemRequest_rangeAndContents() external {
        _deposit(alice, 100_000e6);
        _deposit(bob,   100_000e6);
        uint256 idA = _requestRedeemTo(alice, DEPOSIT_100K_SHARES, carol);
        uint256 idB = _requestRedeem(bob, DEPOSIT_100K_SHARES);

        ( address o, address r, uint256 sh ) = vault.getPendingRedeemRequest(idA);
        assertEq(o,  alice);
        assertEq(r,  carol);
        assertEq(sh, DEPOSIT_100K_SHARES);

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingRedeemRequest(2);

        _processRedeems(DEPOSIT_100K_SHARES + 1, 10);  // alice full, bob 1 share

        vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
        vault.getPendingRedeemRequest(idA);  // below the head now
        ( o, r, sh ) = vault.getPendingRedeemRequest(idB);
        assertEq(o,  bob);
        assertEq(r,  bob);
        assertEq(sh, DEPOSIT_100K_SHARES - 1);

        ( o, r, sh ) = _rawRedeem(idA);  // deleted slot
        assertEq(o,  address(0));
        assertEq(r,  address(0));
        assertEq(sh, 0);
    }

    // The window getter returns `[head, length)`; the range getter (:795-809) takes
    // `(startId, length)` with `StartIdTooSmall` below the head and `LengthTooLarge` past the end.
    function test_getPendingRedeemRequests_windowAndRange() external {
        _threeDepositorsQueued();
        _processRedeems(type(uint256).max, 1);  // head 1

        ISparkPrimeVault.Request[] memory all = vault.getPendingRedeemRequests();
        assertEq(all.length,    2);
        assertEq(all[0].owner,  bob);
        assertEq(all[0].shares, DEPOSIT_100K_SHARES);
        assertEq(all[1].owner,  carol);

        vm.expectRevert(ISparkPrimeVault.StartIdTooSmall.selector);
        vault.getPendingRedeemRequests(0, 1);

        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingRedeemRequests(1, 3);

        vm.expectRevert(ISparkPrimeVault.LengthTooLarge.selector);
        vault.getPendingRedeemRequests(3, 1);

        ISparkPrimeVault.Request[] memory page = vault.getPendingRedeemRequests(2, 1);
        assertEq(page.length,       1);
        assertEq(page[0].owner,     carol);
        assertEq(page[0].recipient, carol);
        assertEq(page[0].shares,    DEPOSIT_100K_SHARES);

        assertEq(vault.getPendingRedeemRequests(1, 2).length, 2);
        assertEq(vault.getPendingRedeemRequests(3, 0).length, 0);  // empty page at the end
        assertEq(vault.getPendingRedeemRequests(1, 0).length, 0);
    }

}

/**************************************************************************************************/
/*** Fuzz / properties                                                                          ***/
/**************************************************************************************************/

contract RedeemQueueFuzzTests is RedeemQueueTestBase {

    // Single-fill bound, now applied to EVERY iteration: assets = floor(shares * chi_p / RAY)
    // <= A and ceil(assets * RAY / chi_s) <= S whenever assets <= floor(S * chi_s / RAY).
    function testFuzz_processPendingRedeems_singleFillNeverReverts(
        uint256 vsrS, uint256 vsrP, uint256 warp, uint256 depositAmt, uint256 drain, uint256 take_
    ) external {
        vsrS       = bound(vsrS, RAY, MAX_VSR);
        vsrP       = bound(vsrP, RAY, MAX_VSR);
        warp       = bound(warp, 0, 5 * 365 days);
        depositAmt = bound(depositAmt, 1, 1_000_000_000e6);

        _setSpUsdcVsr(vsrS);
        _setPrimeVsr(vsrP);
        _deposit(alice, depositAmt);
        _warpAndDrip(warp);

        uint256 shares = vault.balanceOf(alice);
        vm.assume(shares != 0);
        _requestRedeem(alice, shares);

        drain = bound(drain, 0, usdc.balanceOf(address(spUsdc)));
        take_ = bound(take_, 0, _vaultSpUsdc());
        _drainSpUsdcLiquidity(drain);
        _take(take_);

        uint256 spUsdcBefore = _vaultSpUsdc();
        uint256 liqBefore    = usdc.balanceOf(address(spUsdc));
        uint256 a            = vault.availableLiquidAssets();
        uint256 rem          = vault.convertToShares(a);
        uint256 fill         = rem < shares ? rem : shares;
        ( uint256 assets, uint256 burned ) = _fillMath(fill);

        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice),           assets);
        assertEq(_vaultSpUsdc(),                  spUsdcBefore - burned);
        assertEq(usdc.balanceOf(address(spUsdc)), liqBefore - assets);
        assertEq(vault.pendingRedeemShares(),     shares - fill);
        assertLe(assets, a);
        assertLe(burned, spUsdcBefore);
    }

    // FIXED (C-1): a batch of N entries never reverts, pays each recipient exactly
    // floor(filled * chi_p / RAY), and the spUSDC burned is at most N wei above the aggregate
    // ceil. Whatever the backing, the whole queue is processed in one call up to the dust.
    function testFuzz_fixed_C1_batchNeverReverts(
        uint256 vsrS, uint256 vsrP, uint256 warp, uint256 n, uint256 seed, uint256 take_
    ) external {
        n = bound(n, 1, 20);

        _setSpUsdcVsr(bound(vsrS, RAY, MAX_VSR));
        _setPrimeVsr(bound(vsrP, RAY, MAX_VSR));
        _deposit(alice, 10_000_000e6);
        _returnSpUsdcLiquidity(100_000_000e6);
        _warpAndDrip(bound(warp, 0, 5 * 365 days));

        uint256[] memory sizes = _queueSplit(vault.balanceOf(alice), n, seed);
        _take(bound(take_, 0, _vaultSpUsdc()));

        _checkBatch(sizes);
    }

    function _queueSplit(uint256 total, uint256 n, uint256 seed)
        internal returns (uint256[] memory sizes)
    {
        sizes = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            sizes[i] = i == n - 1
                ? total
                : bound(uint256(keccak256(abi.encode(seed, i))), 1, total - (n - 1 - i));
            total -= sizes[i];
            _requestRedeemTo(alice, sizes[i], i % 2 == 0 ? bob : carol);
        }
    }

    function _checkBatch(uint256[] memory sizes) internal {
        uint256 n            = sizes.length;
        uint256 spUsdcBefore = _vaultSpUsdc();
        uint256 chiP         = vault.nowChi();

        _processRedeems(type(uint256).max, n);  // must not revert

        uint256[2] memory expected;  // bob, carol
        uint256 fills;
        for (uint256 i; i < n; ++i) {
            uint256 filled = sizes[i] - _queued(i);
            if (filled == 0) continue;
            ++fills;
            expected[i % 2] += filled * chiP / RAY;
        }
        assertEq(usdc.balanceOf(bob),         expected[0]);
        assertEq(usdc.balanceOf(carol),       expected[1]);
        assertEq(vault.pendingRedeemShares(), vault.balanceOf(address(vault)));

        uint256 burned        = spUsdcBefore - _vaultSpUsdc();
        uint256 aggregateBurn = _divUp((expected[0] + expected[1]) * RAY, spUsdc.nowChi());
        assertGe(burned, aggregateBurn);
        assertLe(burned, aggregateBurn + fills);
        assertLe(burned, spUsdcBefore);

        // Either everything was filled, or the queue stopped on dust: the head entry's
        // remainder is not payable with what is left.
        if (vault.pendingRedeemShares() != 0) {
            uint256 head = vault.firstPendingRedeemId();
            assertLt(head, n);
            assertLt(_liquidShares(), _queued(head));
        } else {
            assertEq(vault.firstPendingRedeemId(), n);
        }
    }

    // Batched vs one-per-call: under the per-entry bound a single `(max, n)` call lands on the
    // identical state as `n` calls of `(max, 1)`, blacklisted recipients included.
    // FOUNDRY_FUZZ_RUNS=20000 for the record.
    function testFuzz_fixed_C1_batchedEqualsOnePerCall(
        uint256 vsrS, uint256 vsrP, uint256 warp, uint256 n, uint256 seed, uint256 take_, uint256 drain
    ) external {
        n = bound(n, 1, 8);

        _setSpUsdcVsr(bound(vsrS, RAY, MAX_VSR));
        _setPrimeVsr(bound(vsrP, RAY, MAX_VSR));
        _deposit(alice, bound(uint256(keccak256(abi.encode(seed, "amt"))), 1e6, 10_000_000e6));
        _warpAndDrip(bound(warp, 0, 3 * 365 days));

        vm.assume(vault.balanceOf(alice) >= n);
        _queueSplitRandomRecipients(n, seed);
        _drainSpUsdcLiquidity(bound(drain, 0, usdc.balanceOf(address(spUsdc))));
        _take(bound(take_, 0, _vaultSpUsdc()));

        _checkBatchedEqualsOnePerCall(n);
    }

    function _queueSplitRandomRecipients(uint256 n, uint256 seed) internal {
        address[3] memory users = [alice, bob, carol];
        uint256 left = vault.balanceOf(alice);
        for (uint256 i; i < n; ++i) {
            uint256 s = i == n - 1
                ? left
                : bound(uint256(keccak256(abi.encode(seed, i))), 1, left - (n - 1 - i));
            left -= s;
            _requestRedeemTo(alice, s, users[uint256(keccak256(abi.encode(seed, i, "to"))) % 3]);
        }
        if (seed % 4 == 0) _blacklist(users[(seed >> 8) % 3]);
    }

    // The batch stops at the first partial fill (:970) or at `fillable_ == 0` (:955); the
    // single-call sequence is cut at the first call that does not advance the head, which is
    // the same point. (Calling again after a partial fill can scrape a few more wei off the
    // head from the floors left in A: that is a further call, not a difference in the batch.)
    function _checkBatchedEqualsOnePerCall(uint256 n) internal {
        address[3] memory users = [alice, bob, carol];

        uint256 snap = vm.snapshotState();
        _processRedeems(type(uint256).max, n);
        bytes32 batched = _stateHash(users, n);
        vm.revertToState(snap);

        for (uint256 i; i < n; ++i) {
            uint256 head = vault.firstPendingRedeemId();
            _processRedeems(type(uint256).max, 1);
            if (vault.firstPendingRedeemId() == head) break;
        }
        assertEq(_stateHash(users, n), batched);
    }

    function _stateHash(address[3] memory users, uint256 n) internal view returns (bytes32) {
        uint256[] memory v = new uint256[](14 + n);
        for (uint256 i; i < 3; ++i) {
            v[i]     = usdc.balanceOf(users[i]);
            v[3 + i] = vault.claimableAssets(users[i]);
        }
        v[6]  = vault.totalClaimable();
        v[7]  = usdc.balanceOf(address(vault));
        v[8]  = vault.firstPendingRedeemId();
        v[9]  = vault.pendingRedeemShares();
        v[10] = vault.totalSupply();
        v[11] = vault.balanceOf(address(vault));
        v[12] = _vaultSpUsdc();
        v[13] = usdc.balanceOf(address(spUsdc));
        for (uint256 i; i < n; ++i) v[14 + i] = _queued(i);
        return keccak256(abi.encode(v));
    }

    // Rounding bounds for one fill: |paid - fill * chi_p / RAY| < 1 wei (floored), burned ==
    // ceil(paid * RAY / chi_s).
    function testFuzz_processPendingRedeems_singleFillRoundingBounds(
        uint256 vsrS, uint256 vsrP, uint256 warp, uint256 depositAmt, uint256 sharesFrac
    ) external {
        vsrS       = bound(vsrS, RAY, MAX_VSR);
        vsrP       = bound(vsrP, RAY, MAX_VSR);
        warp       = bound(warp, 0, 3 * 365 days);
        depositAmt = bound(depositAmt, 2, 100_000_000e6);

        _setSpUsdcVsr(vsrS);
        _setPrimeVsr(vsrP);
        _deposit(alice, depositAmt);
        _deposit(bob,   depositAmt);
        _returnSpUsdcLiquidity(depositAmt * 10);
        _warpAndDrip(warp);

        vm.assume(vault.balanceOf(alice) != 0);
        uint256 shares = bound(sharesFrac, 1, vault.balanceOf(alice));
        _requestRedeem(alice, shares);

        uint256 chiP     = vault.nowChi();
        uint256 chiS     = spUsdc.nowChi();
        uint256 spBefore = _vaultSpUsdc();
        uint256 rem      = _liquidShares();
        uint256 fill     = rem < shares ? rem : shares;

        _processRedeems(type(uint256).max, 1);

        uint256 paid   = usdc.balanceOf(alice);
        uint256 burned = spBefore - _vaultSpUsdc();

        assertEq(vault.pendingRedeemShares(), shares - fill);
        assertLe(paid * RAY, fill * chiP);
        assertLt(fill * chiP - paid * RAY, RAY);
        assertGe(burned * chiS, paid * RAY);
        assertLt(burned * chiS - paid * RAY, chiS);
        assertEq(burned, _divUp(paid * RAY, chiS));
        assertLe(spUsdc.convertToAssets(burned), paid + chiS / RAY + 1);
    }

    // Random sequence of deposits, requests (own and third-party recipient), zero-share
    // entries, owner repoints (strangers and dead entries assert the revert), drains, returns,
    // takes and partial processing (never reverts). After every step:
    // balanceOf(vault) == pendingRedeemShares == sum of open raw entries, every slot below the
    // head is zero, escrow + user balances == totalSupply, and the escrow only shrinks inside
    // `processPendingRedeems`.
    function testFuzz_escrowEqualsPendingRedeemShares_randomSequence(uint256 seed) external {
        address[3] memory users = [alice, bob, carol];
        _setSpUsdcVsr(FOUR_PCT_VSR);
        _setPrimeVsr(ONE_PCT_VSR);
        _setRedeemFeeRate(0.001e18);

        for (uint256 step; step < 24; ++step) {
            uint256 r      = uint256(keccak256(abi.encode(seed, step)));
            address u      = users[r % 3];
            uint256 action = (r >> 8) % 9;
            uint256 amt    = (r >> 16) % 1_000_000e6 + 1;
            uint256 escrowBefore = vault.balanceOf(address(vault));

            if (action == 0) {
                _deposit(u, amt);
            } else if (action == 1 || action == 2) {
                uint256 bal = vault.balanceOf(u);
                if (bal != 0) _requestRedeemTo(u, bound(amt, 1, bal), action == 1 ? u : users[(r >> 72) % 3]);
            } else if (action == 3) {
                _processRedeems((r >> 40) % 2 == 0 ? type(uint256).max : amt, (r >> 48) % 4);
            } else if (action == 4) {
                uint256 liq = usdc.balanceOf(address(spUsdc));
                if (liq != 0) _drainSpUsdcLiquidity(bound(amt, 1, liq));
            } else if (action == 5) {
                _returnSpUsdcLiquidity(amt);
            } else if (action == 6) {
                uint256 held = _vaultSpUsdc();
                if (held != 0) _take(bound(amt, 1, held));
            } else if (action == 7) {
                if (vault.balanceOf(u) != 0) _zeroShareEntry(u);
            } else {
                uint256 qlen = _queueLength();
                if (qlen != 0) {
                    uint256 id = (r >> 40) % qlen;
                    address to = users[(r >> 72) % 3];
                    ( address owner, , uint256 sh ) = _rawRedeem(id);
                    if (sh == 0) {
                        vm.prank(u);
                        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
                        vault.updateRedeemRecipient(id, to);
                    } else {
                        if (u != owner) {
                            vm.prank(u);
                            vm.expectRevert(ISparkPrimeVault.NotRequestOwner.selector);
                            vault.updateRedeemRecipient(id, to);
                        }
                        vm.prank(owner);
                        vault.updateRedeemRecipient(id, to);
                    }
                }
            }
            if (action != 3) assertGe(vault.balanceOf(address(vault)), escrowBefore);
            _warpAndDrip((r >> 64) % 7 days);

            uint256 open;
            uint256 qlen2 = _queueLength();
            uint256 head  = vault.firstPendingRedeemId();
            for (uint256 i; i < qlen2; ++i) open += _queued(i);
            for (uint256 i; i < head; ++i) assertEq(_queued(i), 0);
            assertLe(head, qlen2);
            assertEq(vault.balanceOf(address(vault)), vault.pendingRedeemShares());
            assertEq(vault.pendingRedeemShares(),     open);
            assertEq(vault.balanceOf(address(vault)) + _sumUserBalances(users), vault.totalSupply());
        }
    }

    function _sumUserBalances(address[3] memory users) internal view returns (uint256 sum) {
        for (uint256 i; i < 3; ++i) sum += vault.balanceOf(users[i]);
    }

    // Every fill pays exactly floor(filled * chi / RAY) to its recipient, burns exactly the
    // filled shares, and the spUSDC given up is worth at most 1 wei USDC per fill above what was
    // paid. Processing never reverts.
    function testFuzz_processPendingRedeems_neverPaysMoreThanSharesTimesChi(uint256 seed) external {
        address[3] memory users = [alice, bob, carol];
        _setSpUsdcVsr(FIVE_PCT_VSR);
        _setPrimeVsr(FOUR_PCT_VSR);

        for (uint256 step; step < 16; ++step) {
            uint256 r   = uint256(keccak256(abi.encode(seed, step)));
            address u   = users[r % 3];
            uint256 amt = (r >> 16) % 1_000_000e6 + 1;

            if (step % 2 == 0) {
                _deposit(u, amt);
                _requestRedeemTo(u, bound(r >> 40, 1, vault.balanceOf(u)), users[(r >> 200) % 3]);
                if ((r >> 80) % 3 == 0) {
                    _drainSpUsdcLiquidity(bound(r >> 96, 0, usdc.balanceOf(address(spUsdc))));
                }
                if ((r >> 120) % 3 == 0) _take(bound(r >> 136, 0, _vaultSpUsdc()));
                continue;
            }

            _warpAndDrip((r >> 64) % 30 days);
            _processAndCheckPayouts(users, amt, 5);
        }
    }

    struct Snap {
        uint256 chiP;
        uint256 supply;
        uint256 spBefore;
        uint256 liqBefore;
        uint256 qlen;
    }

    function _processAndCheckPayouts(address[3] memory users, uint256 maxShares, uint256 maxReq)
        internal
    {
        Snap memory s = Snap(
            vault.nowChi(), vault.totalSupply(), _vaultSpUsdc(),
            usdc.balanceOf(address(spUsdc)), _queueLength()
        );
        uint256[]  memory before = new uint256[](s.qlen);
        address[]  memory rcpts  = new address[](s.qlen);
        uint256[3] memory balBefore;
        for (uint256 i; i < s.qlen; ++i) ( , rcpts[i], before[i] ) = _rawRedeem(i);
        for (uint256 i; i < 3; ++i) balBefore[i] = usdc.balanceOf(users[i]);

        _processRedeems(maxShares, maxReq);

        ( uint256[3] memory expected, uint256 filledTotal, uint256 fills ) =
            _expectedPayouts(users, before, rcpts, s.chiP);

        uint256 paidTotal;
        for (uint256 i; i < 3; ++i) {
            assertEq(usdc.balanceOf(users[i]) - balBefore[i], expected[i]);
            paidTotal += expected[i];
        }
        assertEq(s.supply - vault.totalSupply(),                     filledTotal);
        assertLe(filledTotal,                                        maxShares);
        assertEq(s.liqBefore - usdc.balanceOf(address(spUsdc)),      paidTotal);
        assertLe(spUsdc.convertToAssets(s.spBefore - _vaultSpUsdc()), paidTotal + fills);
    }

    function _expectedPayouts(
        address[3] memory users, uint256[] memory before, address[] memory rcpts, uint256 chiP
    )
        internal view returns (uint256[3] memory expected, uint256 filledTotal, uint256 fills)
    {
        for (uint256 i; i < before.length; ++i) {
            uint256 filled = before[i] - _queued(i);
            if (filled == 0) continue;
            uint256 idx = rcpts[i] == users[0] ? 0 : rcpts[i] == users[1] ? 1 : 2;
            expected[idx] += filled * chiP / RAY;
            filledTotal   += filled;
            ++fills;
        }
    }

}
