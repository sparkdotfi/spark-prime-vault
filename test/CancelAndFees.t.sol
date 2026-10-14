// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdError } from "../lib/forge-std/src/StdError.sol";

import { IERC20Errors } from "../lib/oz/contracts/interfaces/IERC6093.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";

// Cancel permissions, cancel ordering, fee math and fee economics for spPRIME.
//
// Harness indexes at setUp (see LocalTestBase): chi_s = 1.047633055711877768967605062e27,
// chi_p = 1.009687768242461209408770821e27. All hard-coded numbers below derive from them.
//
//   100e6 USDC deposit        -> 95_453_269 spUSDC shares (worth 99_999_999 USDC)
//                             -> 99_040_517 spPRIME shares when filled
//   1_000_000e6 USDC deposit  -> 954_532_691_143 spUSDC shares (worth 999_999_999_999 USDC)
//                             -> 990_405_184_109 spPRIME shares when filled
contract CancelAndFeesTest is LocalTestBase {

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

    function _cancelDeposit(address who, uint256 id, address to) internal {
        vm.prank(who);
        vault.cancelDepositRequest(id, to);
    }

    function _cancelRedeem(address who, uint256 id, address to) internal {
        vm.prank(who);
        vault.cancelRedeemRequest(id, to);
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

    /**********************************************************************************************/
    /*** 1. Cancel permissions: deposits                                                        ***/
    /**********************************************************************************************/

    function test_cancelDepositRequest_ownerCanChooseRecipient() public {
        uint256 id = _queueDeposit(alice, 100e6);

        (address owner, address recipient, uint256 shares) = _depositRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    SS_100);

        assertEq(usdc.balanceOf(alice),               0);
        assertEq(usdc.balanceOf(bob),                 0);
        assertEq(_vaultSpUsdc(),                      SS_100);
        assertEq(vault.pendingDepositSavingsShares(), SS_100);

        _cancelDeposit(alice, id, bob);

        (owner, recipient, shares) = _depositRequest(id);
        assertEq(owner,     address(0));
        assertEq(recipient, address(0));
        assertEq(shares,    0);

        assertEq(usdc.balanceOf(alice),               0);
        assertEq(usdc.balanceOf(bob),                 99_999_999);  // 1 wei lost to spUSDC rounding
        assertEq(_vaultSpUsdc(),                      0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    function test_cancelDepositRequest_revertsNotAuthorized() public {
        uint256 id = _queueDeposit(alice, 100e6);

        vm.prank(stranger);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelDepositRequest(id, stranger);

        // The recipient of the fill is not the owner either.
        _setCapacity(0);
        _fund(alice, 100e6);
        vm.prank(alice);
        uint256 id2 = vault.requestDeposit(100e6, bob);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelDepositRequest(id2, bob);
    }

    function test_cancelDepositRequest_guardianRefundsOwnerIgnoringRecipient() public {
        uint256 id = _queueDeposit(alice, 100e6);

        assertEq(usdc.balanceOf(alice),    0);
        assertEq(usdc.balanceOf(guardian), 0);

        _cancelDeposit(guardian, id, guardian);  // REVIEW PATCH F-1: recipient_ ignored

        assertEq(usdc.balanceOf(alice),    99_999_999);
        assertEq(usdc.balanceOf(guardian), 0);
        assertEq(_vaultSpUsdc(),           0);
    }

    function test_cancelDepositRequest_revertsNoRequest_alreadyCancelled() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, alice);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelDepositRequest(id, alice);

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelDepositRequest(id, alice);
    }

    function test_cancelDepositRequest_revertsNoRequest_alreadyFilled() public {
        uint256 id = _deposit(alice, 100e6);  // instant fill
        assertEq(vault.balanceOf(alice), SH_100);

        (, , uint256 shares) = _depositRequest(id);
        assertEq(shares, 0);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelDepositRequest(id, alice);
    }

    function test_cancelDepositRequest_revertsOutOfRange() public {
        uint256 id = _queueDeposit(alice, 100e6);

        vm.prank(alice);
        vm.expectRevert(stdError.indexOOBError);
        vault.cancelDepositRequest(id + 1, alice);
    }

    /**********************************************************************************************/
    /*** 1. Cancel permissions: redeems                                                         ***/
    /**********************************************************************************************/

    function test_cancelRedeemRequest_ownerCanChooseRecipient() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);

        (address owner, address recipient, uint256 shares) = _redeemRequest(id);
        assertEq(owner,     alice);
        assertEq(recipient, alice);
        assertEq(shares,    SH_100);

        assertEq(vault.balanceOf(alice),          0);
        assertEq(vault.balanceOf(bob),            0);
        assertEq(vault.balanceOf(address(vault)), SH_100);
        assertEq(vault.pendingRedeemShares(),     SH_100);

        _cancelRedeem(alice, id, bob);

        (owner, recipient, shares) = _redeemRequest(id);
        assertEq(owner,     address(0));
        assertEq(recipient, address(0));
        assertEq(shares,    0);

        assertEq(vault.balanceOf(alice),          0);
        assertEq(vault.balanceOf(bob),            SH_100);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.totalSupply(),             SH_100);
    }

    function test_cancelRedeemRequest_revertsNotAuthorized() public {
        _deposit(alice, 100e6);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(SH_100, bob);  // bob is the fill recipient, not the owner

        vm.prank(stranger);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelRedeemRequest(id, stranger);

        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/not-authorized");
        vault.cancelRedeemRequest(id, bob);
    }

    function test_cancelRedeemRequest_guardianRefundsOwnerIgnoringRecipient() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);

        _cancelRedeem(guardian, id, guardian);  // REVIEW PATCH F-1

        assertEq(vault.balanceOf(alice),          SH_100);
        assertEq(vault.balanceOf(guardian),       0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRedeemShares(),     0);
    }

    function test_cancelRedeemRequest_revertsNoRequest_alreadyCancelled() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);
        _cancelRedeem(alice, id, alice);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(id, alice);

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(id, alice);
    }

    function test_cancelRedeemRequest_revertsNoRequest_alreadyFilled() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);
        _processRedeems(type(uint256).max, 1);

        assertEq(usdc.balanceOf(alice), 99_999_998);  // 99_040_517 * chi_p / RAY
        (, , uint256 shares) = _redeemRequest(id);
        assertEq(shares, 0);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(id, alice);
    }

    function test_cancelRedeemRequest_revertsOutOfRange() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);

        vm.prank(alice);
        vm.expectRevert(stdError.indexOOBError);
        vault.cancelRedeemRequest(id + 1, alice);
    }

    // Unlike requestRedeem (line 423) and transfer (line 485), cancelRedeemRequest does not reject
    // recipient_ == address(0): the escrowed shares land on address(0) with totalSupply unchanged.
    function test_cancelRedeemRequest_zeroRecipientNotRejected() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);

        _cancelRedeem(alice, id, address(0));

        assertEq(vault.balanceOf(address(0)),     SH_100);
        assertEq(vault.balanceOf(alice),          0);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(),             SH_100);  // still counts against capacity
        assertEq(vault.pendingRedeemShares(),     0);
    }

    // cancelDepositRequest with recipient_ == address(0) is caught by the asset token, not spPRIME.
    function test_cancelDepositRequest_zeroRecipientRevertsInAsset() public {
        uint256 id = _queueDeposit(alice, 100e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vault.cancelDepositRequest(id, address(0));
    }

    // Owner-chosen recipient == vault strands the shares (see section 8).
    function test_cancelRedeemRequest_recipientVaultStrandsShares() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);

        _cancelRedeem(alice, id, address(vault));

        assertEq(vault.balanceOf(address(vault)), SH_100);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.balanceOf(alice),          0);
    }

    /**********************************************************************************************/
    /*** 2. Cancel ordering and partial fills                                                   ***/
    /**********************************************************************************************/

    function test_cancelDepositRequest_partialFillRefundsRemainder() public {
        uint256 id = _queueDeposit(alice, 100e6);
        assertEq(vault.pendingDepositSavingsShares(), SS_100);

        // Capacity worth 40e6: 40e6 * RAY / chi_p = 39_616_207 shares.
        _setCapacity(39_616_207);
        _processDeposits(type(uint256).max, 1);

        // Capacity -> 39_999_999 USDC -> 38_181_306 spUSDC shares -> 39_999_998 USDC -> 39_616_205 shares.
        assertEq(vault.balanceOf(alice), 39_616_205);
        assertEq(vault.totalSupply(),    39_616_205);
        assertEq(vault.depositHead(),    id);  // partial: head stays

        (, , uint256 shares) = _depositRequest(id);
        assertEq(shares, SS_100 - 38_181_306);
        assertEq(shares, 57_271_963);
        assertEq(vault.pendingDepositSavingsShares(), 57_271_963);
        assertEq(_vaultSpUsdc(),                      SS_100);  // fills do not move spUSDC

        _cancelDeposit(alice, id, alice);

        assertEq(usdc.balanceOf(alice),               60_000_001);  // 57_271_963 * chi_s / RAY
        assertEq(vault.balanceOf(alice),              39_616_205);
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(_vaultSpUsdc(),                      38_181_306);

        // Minted value (39_999_997) + refund == 99_999_998: 1 wei lost at deposit, 1 at the fill.
        assertEq(vault.assetsOf(alice), 39_999_997);
        assertEq(vault.assetsOf(alice) + usdc.balanceOf(alice), 99_999_998);
    }

    function test_cancelRedeemRequest_partialFillRefundsRemainder() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);

        // Leave exactly 40e6 USDC of liquidity inside spUSDC.
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 40e6);
        assertEq(vault.availableLiquidAssets(), 40e6);

        _processRedeems(type(uint256).max, 1);

        // convertToShares(40e6) = 39_616_207 shares -> 39_999_999 USDC paid.
        assertEq(usdc.balanceOf(alice),       39_999_999);
        assertEq(vault.totalSupply(),         SH_100 - 39_616_207);
        assertEq(vault.pendingRedeemShares(), 59_424_310);
        assertEq(vault.redeemHead(),          id);

        (, , uint256 shares) = _redeemRequest(id);
        assertEq(shares, 59_424_310);

        _cancelRedeem(alice, id, alice);

        assertEq(vault.balanceOf(alice),          59_424_310);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.totalSupply(),             59_424_310);
    }

    function test_cancelDepositRequest_headEntryThenProcessSkipsIt() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        assertEq(idA, 0);
        assertEq(idB, 1);
        assertEq(vault.depositHead(), 0);
        assertEq(vault.pendingDepositSavingsShares(), 2 * SS_100);

        _cancelDeposit(alice, idA, alice);
        assertEq(vault.depositHead(), 0);  // cancel does not touch the head
        assertEq(vault.pendingDepositSavingsShares(), SS_100);

        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, 10);

        assertEq(vault.depositHead(),    2);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob),   SH_100);
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    function test_cancelRedeemRequest_headEntryThenProcessSkipsIt() public {
        _deposit(alice, 100e6);
        _deposit(bob,   100e6);
        uint256 idA = _requestRedeem(alice, SH_100);
        uint256 idB = _requestRedeem(bob,   SH_100);
        assertEq(idA, 0);
        assertEq(idB, 1);

        _cancelRedeem(alice, idA, alice);
        assertEq(vault.redeemHead(), 0);
        assertEq(vault.pendingRedeemShares(), SH_100);

        _processRedeems(type(uint256).max, 10);

        assertEq(vault.redeemHead(),      2);
        assertEq(usdc.balanceOf(alice),   0);
        assertEq(usdc.balanceOf(bob),     99_999_998);
        assertEq(vault.balanceOf(alice),  SH_100);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    function test_cancelDepositRequest_thenReRequestFillsInstantlyWhenQueueEmpty() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _cancelDeposit(alice, id, alice);
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        // Queue empty again: the re-request fills instantly and resets the head to its own index.
        vm.prank(alice);
        uint256 id2 = vault.requestDeposit(99_999_999, alice);
        assertEq(id2, 1);
        assertEq(vault.depositHead(), 2);  // reset to 1, then advanced past the full fill
        assertEq(vault.balanceOf(alice), 99_040_516);  // 99_999_999 -> 95_453_268 spUSDC -> 99_999_998 -> shares
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    function test_cancelDepositRequest_thenReRequestQueuesBehindOthers() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        _cancelDeposit(alice, idA, alice);

        vm.prank(alice);
        uint256 id2 = vault.requestDeposit(99_999_999, alice);
        assertEq(id2, 2);
        assertEq(vault.depositHead(), 0);
        assertEq(vault.pendingDepositSavingsShares(), SS_100 + 95_453_268);

        _setCapacity(type(uint128).max);

        // A cancelled entry consumes one unit of maxRequests_: this call fills nothing.
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(bob),   0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.depositHead(),    1);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(bob),   SH_100);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.depositHead(),    2);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(alice), 99_040_516);
        assertEq(vault.depositHead(),    3);
    }

    /**********************************************************************************************/
    /*** 3. F-2: cancel after take() spent the queue backing                                   ***/
    /**********************************************************************************************/

    function test_cancelDepositRequest_revertsAfterTakeSpentBacking() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);
        assertEq(_vaultSpUsdc(), 2 * SS_100);

        // Taker pulls 100e6 worth: exactly alice's backing by amount, but spUSDC is fungible.
        _take(SS_100);
        assertEq(_vaultSpUsdc(),                      SS_100);
        assertEq(vault.pendingDepositSavingsShares(), 2 * SS_100);  // not reduced by take

        // Alice cancels first and consumes what was bob's backing.
        _cancelDeposit(alice, idA, alice);
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(_vaultSpUsdc(),        0);

        // Bob is stuck: spUSDC has no shares to redeem from the vault.
        vm.prank(bob);
        vm.expectRevert("SparkVault/insufficient-balance");
        vault.cancelDepositRequest(idB, bob);

        // Guardian cannot help either.
        vm.prank(guardian);
        vm.expectRevert("SparkVault/insufficient-balance");
        vault.cancelDepositRequest(idB, bob);

        // Returning exactly the shortfall unblocks bob.
        _returnToVault(SS_100);
        _cancelDeposit(bob, idB, bob);
        assertEq(usdc.balanceOf(bob), 99_999_999);
        assertEq(_vaultSpUsdc(),      0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    function test_cancelDepositRequest_bothStuckWhenTakeExceedsOneRequest() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, 100e6);
        uint256 idB = _deposit(bob,   100e6);

        // 150e6 worth = 143_179_903 spUSDC shares; 47_726_635 remain (< one request).
        _take(143_179_903);
        assertEq(_vaultSpUsdc(), 47_726_635);

        vm.prank(alice);
        vm.expectRevert("SparkVault/insufficient-balance");
        vault.cancelDepositRequest(idA, alice);

        vm.prank(bob);
        vm.expectRevert("SparkVault/insufficient-balance");
        vault.cancelDepositRequest(idB, bob);

        // Shortfall for one cancel is 95_453_269 - 47_726_635 = 47_726_634 spUSDC shares.
        _returnToVault(47_726_634);
        _cancelDeposit(alice, idA, alice);
        assertEq(usdc.balanceOf(alice), 99_999_999);
        assertEq(_vaultSpUsdc(),        0);

        vm.prank(bob);
        vm.expectRevert("SparkVault/insufficient-balance");
        vault.cancelDepositRequest(idB, bob);
    }

    function test_processDepositQueue_stillMintsAfterTakeSpentBacking() public {
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
    /*** 4. Fee math                                                                            ***/
    /**********************************************************************************************/

    function testFuzz_requestRedeem_feeIsCeil(uint256 shares, uint256 feeRate) public {
        shares  = bound(shares,  1, 1e30);
        feeRate = bound(feeRate, 0, 0.01e18);

        _setRedeemFee(feeRate);

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

    function test_requestRedeem_revertsZeroShares() public {
        _deposit(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(0, alice);
    }

    function test_requestRedeem_feeRoundsUpToOneWei() public {
        _setRedeemFee(1);  // 1e-18
        _deposit(alice, 100e6);

        uint256 id = _requestRedeem(alice, SH_100);
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, SH_100 - 1);
        assertEq(vault.totalSupply(), SH_100 - 1);
    }

    /**********************************************************************************************/
    /*** 5. Fee economics                                                                       ***/
    /**********************************************************************************************/

    function test_requestRedeem_feeLeavesChiUnchangedAndRaisesBackingPerShare() public {
        _setRedeemFee(0.01e18);
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
        _setRedeemFee(0.01e18);
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

    /**********************************************************************************************/
    /*** 6. Minimums: gross vs net                                                              ***/
    /**********************************************************************************************/

    function test_requestRedeem_minWithdrawIsGrossOfFee() public {
        _setRedeemFee(0.01e18);
        _setMinimums(0, 100e6);
        _deposit(alice, 1_000_000e6);

        // convertToShares(100e6) = 99_040_518 -> 99_999_999 USDC: below minimum.
        assertEq(vault.convertToAssets(99_040_518), 99_999_999);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestRedeem(99_040_518, alice);

        // 99_040_519 shares -> exactly 100_000_000 USDC gross: passes.
        assertEq(vault.convertToAssets(99_040_519), 100e6);
        uint256 id = _requestRedeem(alice, 99_040_519);

        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, 99_040_519 - 990_406);
        assertEq(queued, 98_050_113);

        _processRedeems(type(uint256).max, 1);

        // Net payout is 98_999_999 USDC: 1_000_001 wei below the configured minimum.
        assertEq(usdc.balanceOf(alice), 98_999_999);
        assertEq(100e6 - usdc.balanceOf(alice), 1_000_001);
    }

    function test_requestDeposit_minDepositBoundary() public {
        _setMinimums(100e6, 0);
        _fund(alice, 200e6);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/below-minimum");
        vault.requestDeposit(100e6 - 1, alice);

        vm.prank(alice);
        vault.requestDeposit(100e6, alice);
        assertEq(vault.balanceOf(alice), SH_100);
    }

    /**********************************************************************************************/
    /*** 7. Ghost entries and gas                                                               ***/
    /**********************************************************************************************/

    function test_processDepositQueue_gasWith500GhostEntries() public {
        // Baseline: carol queued, alice behind her, no ghosts.
        _setCapacity(0);
        _deposit(carol, 10e6);
        _deposit(alice, 100e6);
        _setCapacity(type(uint128).max);

        _cool();
        vm.prank(rebalancer);
        uint256 gas = gasleft();
        vault.processDepositQueue(type(uint256).max, 502);
        uint256 baseline = gas - gasleft();

        assertEq(vault.balanceOf(carol), 9_904_050);
        assertEq(vault.balanceOf(alice), SH_100);
        assertEq(vault.depositHead(),    2);

        // Ghosts: carol queued first (so the head cannot be reset), then 500 zero-asset requests.
        _setCapacity(0);
        uint256 idC = _deposit(carol, 10e6);
        assertEq(idC, 2);

        for (uint256 i; i < 500; ++i) {
            vm.prank(stranger);
            uint256 id = vault.requestDeposit(0, stranger);
            assertEq(id, 3 + i);
        }
        assertEq(vault.pendingDepositSavingsShares(), 9_545_326);

        uint256 idA = _deposit(alice, 100e6);
        assertEq(idA, 503);
        _setCapacity(type(uint128).max);

        _cool();
        vm.prank(rebalancer);
        gas = gasleft();
        vault.processDepositQueue(type(uint256).max, 502);
        uint256 withGhosts = gas - gasleft();

        assertEq(vault.balanceOf(carol), 2 * 9_904_050);
        assertEq(vault.balanceOf(alice), 2 * SH_100);
        assertEq(vault.depositHead(),    504);
        assertEq(vault.pendingDepositSavingsShares(), 0);

        emit log_named_uint("processDepositQueue gas, 2 real requests",             baseline);
        emit log_named_uint("processDepositQueue gas, 2 real + 500 ghost requests", withGhosts);
        emit log_named_uint("gas per ghost entry",                                  (withGhosts - baseline) / 500);

        assertGt(withGhosts, baseline + 500 * 2_000);  // at least one cold SLOAD per ghost

        // A ghost cannot be cancelled.
        vm.prank(stranger);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelDepositRequest(3, stranger);
    }

    function test_processRedeemQueue_gasWith500GhostEntries() public {
        _setRedeemFee(0.01e18);
        _deposit(alice, 100e6);
        _deposit(bob,   100e6);

        // Baseline: one real request.
        _requestRedeem(bob, SH_100);
        _cool();
        vm.prank(rebalancer);
        uint256 gas = gasleft();
        vault.processRedeemQueue(type(uint256).max, 501);
        uint256 baseline = gas - gasleft();
        assertEq(usdc.balanceOf(bob), 98_999_997);  // 98_050_111 net shares
        assertEq(vault.redeemHead(),  1);

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
        vm.prank(rebalancer);
        gas = gasleft();
        vault.processRedeemQueue(type(uint256).max, 501);
        uint256 withGhosts = gas - gasleft();

        assertEq(usdc.balanceOf(bob), 2 * 98_999_997);
        assertEq(vault.redeemHead(),  502);

        emit log_named_uint("processRedeemQueue gas, 1 real request",              baseline);
        emit log_named_uint("processRedeemQueue gas, 1 real + 500 ghost requests", withGhosts);
        emit log_named_uint("gas per ghost entry",                                 (withGhosts - baseline) / 500);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(1, alice);
    }

    /**********************************************************************************************/
    /*** 8. Donated shares                                                                      ***/
    /**********************************************************************************************/

    function test_transfer_toVaultStrandsSharesWithoutBreakingQueues() public {
        _deposit(alice, 100e6);
        _deposit(bob,   100e6);

        vm.prank(alice);
        vault.transfer(address(vault), 1_000_000);

        assertEq(vault.balanceOf(address(vault)), 1_000_000);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.totalSupply(),             2 * SH_100);

        // Bob's redeem request and fill behave exactly as without the donation.
        uint256 id = _requestRedeem(bob, SH_100);
        assertEq(vault.balanceOf(address(vault)), 1_000_000 + SH_100);
        assertEq(vault.pendingRedeemShares(),     SH_100);

        _processRedeems(type(uint256).max, 1);
        assertEq(usdc.balanceOf(bob),             99_999_998);
        assertEq(vault.balanceOf(address(vault)), 1_000_000);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.totalSupply(),             SH_100);  // alice's remainder + donation

        // Cancel paths only move request.shares, never the donation.
        uint256 id2 = _requestRedeem(alice, SH_100 - 1_000_000);
        _cancelRedeem(alice, id2, alice);
        assertEq(vault.balanceOf(alice),          SH_100 - 1_000_000);
        assertEq(vault.balanceOf(address(vault)), 1_000_000);

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/no-request");
        vault.cancelRedeemRequest(id, alice);

        // Donation keeps consuming capacity: with capacity == totalSupply nothing can be deposited.
        _setCapacity(vault.totalSupply());
        assertEq(vault.availableCapacity(), 0);
        uint256 id3 = _deposit(carol, 100e6);
        (, , uint256 queued) = _depositRequest(id3);
        assertEq(queued, SS_100);  // stuck in queue behind 1_000_000 dead shares
    }

    function test_transferFrom_toVaultStrandsShares() public {
        _deposit(alice, 100e6);

        vm.prank(alice);
        vault.approve(bob, 1_000_000);

        vm.prank(bob);
        vault.transferFrom(alice, address(vault), 1_000_000);

        assertEq(vault.balanceOf(address(vault)), 1_000_000);
        assertEq(vault.balanceOf(alice),          SH_100 - 1_000_000);
        assertEq(vault.pendingRedeemShares(),     0);
        assertEq(vault.allowance(alice, bob),     0);
    }

    /**********************************************************************************************/
    /*** 9. Fee kept on guardian cancel (F-8)                                                   ***/
    /**********************************************************************************************/

    function test_cancelRedeemRequest_guardianCancelKeepsFee() public {
        _setRedeemFee(0.01e18);
        _deposit(alice, 1_000_000e6);

        uint256 id = _requestRedeem(alice, SH_1M);
        assertEq(vault.totalSupply(), SH_1M - 9_904_051_842);

        _cancelRedeem(guardian, id, guardian);

        assertEq(vault.balanceOf(alice), SH_1M - 9_904_051_842);
        assertEq(vault.balanceOf(alice), 980_501_132_267);
        assertEq(vault.assetsOf(alice),  989_999_999_997);

        // Alice lost 9_904_051_842 shares = 10_000_000_001 USDC of claim for a cancelled request.
        assertEq(999_999_999_998 - vault.assetsOf(alice), 10_000_000_001);
    }

    /**********************************************************************************************/
    /*** 10. Fee locked at request                                                              ***/
    /**********************************************************************************************/

    function test_processRedeemQueue_feeChangeAfterRequestHasNoEffect() public {
        _setRedeemFee(0.01e18);
        _deposit(alice, 1_000_000e6);
        _deposit(bob,   1_000_000e6);

        uint256 idA = _requestRedeem(alice, SH_1M);
        (, , uint256 queuedA) = _redeemRequest(idA);
        assertEq(queuedA, 980_501_132_267);

        _setRedeemFee(0);

        // Bob requests at 0% after the change.
        uint256 idB = _requestRedeem(bob, SH_1M);
        (, , uint256 queuedB) = _redeemRequest(idB);
        assertEq(queuedB, SH_1M);

        _processRedeems(type(uint256).max, 2);

        assertEq(usdc.balanceOf(alice), 989_999_999_997);  // 1% already burned
        assertEq(usdc.balanceOf(bob),   999_999_999_998);
    }

    /**********************************************************************************************/
    /*** 11. Fee setters                                                                        ***/
    /**********************************************************************************************/

    function test_setRedeemFee_revertsAboveMax() public {
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFee(0.01e18 + 1);

        vm.prank(riskManager);
        vault.setRedeemFee(0.01e18);
        assertEq(vault.redeemFee(), 0.01e18);
    }

    function test_setMaxRedeemFee_revertsAboveOnePercent() public {
        vm.prank(admin);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setMaxRedeemFee(0.01e18 + 1);

        vm.prank(admin);
        vault.setMaxRedeemFee(0.01e18);
        assertEq(vault.maxRedeemFee(), 0.01e18);
    }

    function test_setMaxRedeemFee_belowCurrentFeeLeavesFeeInForce() public {
        _setRedeemFee(0.01e18);

        vm.prank(admin);
        vault.setMaxRedeemFee(0.001e18);
        assertEq(vault.maxRedeemFee(), 0.001e18);
        assertEq(vault.redeemFee(),    0.01e18);  // unchanged, above the new max

        // New requests keep paying 1%.
        _deposit(alice, 1_000_000e6);
        uint256 id = _requestRedeem(alice, SH_1M);
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, SH_1M - 9_904_051_842);

        // Risk manager can no longer set anything above 0.1%, including the value in force.
        vm.prank(riskManager);
        vm.expectRevert("SparkPrimeVault/fee-too-high");
        vault.setRedeemFee(0.01e18);

        vm.prank(riskManager);
        vault.setRedeemFee(0.001e18);
        assertEq(vault.redeemFee(), 0.001e18);
    }

    /**********************************************************************************************/
    /*** 12. Pause                                                                              ***/
    /**********************************************************************************************/

    function test_cancelDepositRequest_revertsWhilePaused() public {
        uint256 id = _queueDeposit(alice, 100e6);
        _pause();

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelDepositRequest(id, alice);

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelDepositRequest(id, alice);

        // take() is not gated by pause (F-7): backing can still leave during the freeze.
        _take(SS_100);
        assertEq(_vaultSpUsdc(), 0);
        _returnToVault(SS_100);

        _unpause();
        _cancelDeposit(alice, id, alice);
        assertEq(usdc.balanceOf(alice), 99_999_999);
    }

    function test_cancelRedeemRequest_revertsWhilePaused() public {
        _deposit(alice, 100e6);
        uint256 id = _requestRedeem(alice, SH_100);
        _pause();

        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelRedeemRequest(id, alice);

        vm.prank(guardian);
        vm.expectRevert("SparkPrimeVault/paused");
        vault.cancelRedeemRequest(id, alice);

        _unpause();
        _cancelRedeem(alice, id, alice);
        assertEq(vault.balanceOf(alice), SH_100);
    }

    /**********************************************************************************************/
    /*** 13. Yield while queued, cancel / re-request cycles                                     ***/
    /**********************************************************************************************/

    // A queued depositor earns spUSDC yield on the full amount with no fee, exactly as if they held
    // spUSDC directly, while spPRIME holders earn the (lower) VSR.
    function test_cancelDepositRequest_queuedDepositEarnsSpUsdcYield() public {
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
        _warpAndDrip(365 days);

        uint256 chiS = spUsdc.nowChi();
        uint256 expected = SS_1M * chiS / RAY;

        _cancelDeposit(alice, id, alice);
        vm.prank(bob);
        spUsdc.redeem(SS_1M, bob, bob);

        assertEq(usdc.balanceOf(alice), expected);
        assertEq(usdc.balanceOf(bob),   expected);
        assertEq(usdc.balanceOf(alice), 1_049_999_999_998);  // 5% on 1_000_000e6, 2 wei of rounding
        assertEq(vault.assetsOf(carol), 999_999_999_998);    // holder earned nothing (VSR = RAY)

        emit log_named_uint("queued depositor USDC after 1y at 5% spUSDC VSR", usdc.balanceOf(alice));
        emit log_named_uint("direct spUSDC holder USDC after 1y",              usdc.balanceOf(bob));
        emit log_named_uint("spPRIME holder claim after 1y (VSR 0)",           vault.assetsOf(carol));
    }

    // The same yield is credited at fill: a late fill mints more shares than an early one.
    function test_processDepositQueue_fillCreditsSpUsdcYieldAccruedWhileQueued() public {
        _deposit(carol, 1_000_000e6);
        assertEq(vault.balanceOf(carol), SH_1M);

        uint256 id = _queueDeposit(alice, 1_000_000e6);

        _setSpUsdcVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);

        _processDeposits(type(uint256).max, 1);
        (, , uint256 left) = _depositRequest(id);
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

    // Escrowed redeem shares keep accruing VSR; cancel returns them intact minus the fee.
    function test_cancelRedeemRequest_afterChiGrowthReturnsSharesIntact() public {
        _setRedeemFee(0.01e18);
        _deposit(alice, 1_000_000e6);

        uint256 id = _requestRedeem(alice, SH_1M);
        (, , uint256 queued) = _redeemRequest(id);
        assertEq(queued, 980_501_132_267);

        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);

        _cancelRedeem(alice, id, alice);

        assertEq(vault.balanceOf(alice), 980_501_132_267);
        assertEq(vault.assetsOf(alice),  1_039_499_999_997);  // 989_999_999_997 * 1.05
        assertEq(vault.totalSupply(),    980_501_132_267);
    }

    // Deposit / cancel cycles only lose spUSDC rounding dust: 1 wei per cycle.
    function test_cancelDepositRequest_cycleLosesOneWeiPerRound() public {
        _setCapacity(0);
        _fund(alice, 100e6);

        uint256 amount = 100e6;
        for (uint256 i; i < 10; ++i) {
            vm.prank(alice);
            uint256 id = vault.requestDeposit(amount, alice);

            (, , uint256 ss) = _depositRequest(id);
            assertEq(ss, amount * RAY / CHI_S);

            _cancelDeposit(alice, id, alice);

            uint256 refunded = usdc.balanceOf(alice);
            assertEq(refunded, ss * CHI_S / RAY);
            assertEq(refunded, amount - 1);
            amount = refunded;
        }
        assertEq(usdc.balanceOf(alice), 100e6 - 10);
        assertEq(_vaultSpUsdc(),        0);
        assertEq(vault.pendingDepositSavingsShares(), 0);
    }

    // Request / cancel cycles leave dead entries that consume maxRequests_ budget and gas, even with
    // a non-zero minDeposit (which blocks F-5 zero-asset ghosts): the same 100e6 is recycled.
    function test_cancelDepositRequest_cancelledEntriesConsumeRequestBudget() public {
        _setMinimums(100e6, 0);
        _setCapacity(0);
        uint256 idB = _deposit(bob, 100e6);  // real request at the head keeps the head from resetting
        assertEq(idB, 0);

        _fund(stranger, 100e6);
        uint256 amount = 100e6;
        for (uint256 i; i < 50; ++i) {
            vm.prank(stranger);
            uint256 id = vault.requestDeposit(amount, stranger);
            assertEq(id, 1 + i);
            _cancelDeposit(stranger, id, stranger);
            amount = usdc.balanceOf(stranger);
            // Top up the single wei lost per cycle so the request stays above minDeposit.
            usdc.mint(stranger, 100e6 - amount);
            amount = 100e6;
        }
        _deposit(alice, 100e6);  // id 51
        _setCapacity(type(uint128).max);

        // 50 dead entries sit between bob and alice; a 50-request batch fills bob only.
        _processDeposits(type(uint256).max, 50);
        assertEq(vault.balanceOf(bob),   SH_100);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.depositHead(),    50);

        _processDeposits(type(uint256).max, 1);  // skips dead entry 50
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.depositHead(),    51);

        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(alice), SH_100);
        assertEq(vault.depositHead(),    52);

        // Griefer paid 50 wei of USDC plus gas for 50 dead entries.
        assertEq(usdc.balanceOf(stranger), 100e6);
    }

    // Redeem / cancel cycles cost the fee each time; nothing else moves.
    function test_cancelRedeemRequest_cycleLosesFeeEachRound() public {
        _setRedeemFee(0.01e18);
        _deposit(alice, 1_000_000e6);

        uint256 shares = SH_1M;
        for (uint256 i; i < 3; ++i) {
            uint256 id  = _requestRedeem(alice, shares);
            uint256 fee = _ceil(shares * 0.01e18, WAD);
            _cancelRedeem(alice, id, alice);
            shares -= fee;
            assertEq(vault.balanceOf(alice), shares);
            assertEq(vault.totalSupply(),    shares);
        }
        assertEq(shares, 960_989_159_734);  // 3 fees: 9_904_051_842 + 9_805_011_323 + 9_706_961_210
        assertEq(_vaultSpUsdc(), SS_1M);  // backing untouched, surplus now 3 fees
    }

}
