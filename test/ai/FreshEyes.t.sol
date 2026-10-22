// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl } from "../../lib/oz/contracts/access/IAccessControl.sol";
import { Initializable }  from "../../lib/oz-upgradeable/contracts/proxy/utils/Initializable.sol";
import { ERC1967Proxy }   from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UUPSUpgradeable } from "../../lib/oz/contracts/proxy/utils/UUPSUpgradeable.sol";

import { SparkPrimeVault }       from "../../src/SparkPrimeVault.sol";
import { SparkPrimeVaultV2Mock } from "./mocks/SparkPrimeVaultV2Mock.sol";

import { LocalTestBase } from "./LocalTestBase.t.sol";
import { ISparkPrimeVault } from "src/ISparkPrimeVault.sol";

/// @dev Minimal ERC1271 wallet: accepts exactly one digest.
contract ERC1271Wallet {
    bytes32 public accepted;
    function set(bytes32 d) external { accepted = d; }
    function isValidSignature(bytes32 digest, bytes memory) external view returns (bytes4) {
        return digest == accepted ? bytes4(0x1626ba7e) : bytes4(0);
    }
}

/// @dev Fresh-eyes attacker pass on `src/SparkPrimeVault.sol` @ 0ebb452. Independent of the
///      earlier rounds; every claim in REPORT-fresh-eyes.md is backed by a test here.
///      `test_BUG_*` tests prove real bugs and may fail deliberately (noted in the report).
///      `test_property_*` tests pin attacks that were tried and ruled out.
contract FreshEyesTest is LocalTestBase {

    // Harness index values after setUp (pinned so every expectation below is exact wei).
    uint256 constant CHI_S = 1.047633055711877768967605062e27;  // spUSDC chi
    uint256 constant CHI_P = 1.009687768242461209408770821e27;  // spPRIME chi

    uint256 constant ONE_M = 1_000_000e6;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");
    address mal   = makeAddr("mal");

    function setUp() public override {
        super.setUp();
        assertEq(spUsdc.nowChi(), CHI_S, "chi_s pin");
        assertEq(vault.nowChi(),  CHI_P, "chi_p pin");
    }

    /*** helpers ***/

    function _sShares(uint256 assets) internal pure returns (uint256) { return assets * RAY / CHI_S; }
    function _sAssets(uint256 shares) internal pure returns (uint256) { return shares * CHI_S / RAY; }
    function _pShares(uint256 assets) internal pure returns (uint256) { return assets * RAY / CHI_P; }
    function _pAssets(uint256 shares) internal pure returns (uint256) { return shares * CHI_P / RAY; }
    function _divUp(uint256 x, uint256 y) internal pure returns (uint256) { return x == 0 ? 0 : (x - 1) / y + 1; }

    function _sumDeposits() internal view returns (uint256 s) {
        SparkPrimeVault.Request[] memory r = vault.getPendingDepositRequests();
        for (uint256 i; i < r.length; ++i) s += r[i].shares;
    }
    function _sumCancels() internal view returns (uint256 s) {
        SparkPrimeVault.Request[] memory r = vault.getPendingDepositCancellationRequests();
        for (uint256 i; i < r.length; ++i) s += r[i].shares;
    }
    function _sumRedeems() internal view returns (uint256 s) {
        SparkPrimeVault.Request[] memory r = vault.getPendingRedeemRequests();
        for (uint256 i; i < r.length; ++i) s += r[i].shares;
    }

    /**********************************************************************************************/
    /*** 1. setCapacity above the overflow threshold bricks every deposit fill (:829)           ***/
    /**********************************************************************************************/

    // `convertToAssets(availableCapacity())` is `cap * chi / RAY` in checked uint256. With
    // totalSupply == 0 the threshold is exactly `type(uint256).max / chi`. "Unlimited" capacity
    // (type(uint256).max) makes `requestDeposit` (instant-fill path) and `processPendingDeposits`
    // revert with a Panic(0x11); funds are not lost (the request itself never gets pushed), but no
    // deposit can ever fill until the admin lowers the cap. Deliberate failing proof? No: the
    // assertions below PASS and document the brick.
    function test_BUG_setCapacity_uint256Max_bricksDepositFills() public {
        uint256 threshold = type(uint256).max / CHI_P;  // 114_666_...e..., ~1.147e50 shares

        _setCapacity(threshold);
        _fund(alice, ONE_M);
        vm.prank(alice);
        vault.requestDeposit(ONE_M, alice, 0);      // fills: 1e6 USDC -> exact amounts below
        assertEq(vault.balanceOf(alice), _pShares(_sAssets(_sShares(ONE_M))));
        assertEq(vault.balanceOf(alice), 990_405_184_109);

        _setCapacity(threshold + 1);
        // availableCapacity = threshold + 1 - totalSupply < threshold, so it still works right at
        // the edge; push the cap to "unlimited" and both fill paths panic.
        _setCapacity(type(uint256).max);

        _fund(bob, ONE_M);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));  // Panic: arithmetic overflow
        vault.requestDeposit(ONE_M, bob, 0);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);

        // Exact edge: cap = threshold + totalSupply works, cap = threshold + totalSupply + 1 panics.
        uint256 ts = vault.totalSupply();
        _setCapacity(threshold + ts);
        vm.prank(bob);
        vault.requestDeposit(ONE_M, bob, 0);
        assertEq(vault.balanceOf(bob), 990_405_184_109);

        ts = vault.totalSupply();
        _setCapacity(threshold + ts + 1);
        _fund(carol, 1e6);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11));
        vault.requestDeposit(1e6, carol, 0);
    }

    /**********************************************************************************************/
    /*** 2. Ghost entries: unbounded auto-walk in requestDeposit (:414-416, :837-840)           ***/
    /**********************************************************************************************/

    // While `availableCapacity() == 0` every zero-asset request (minDeposit defaults to 0;
    // spUSDC.deposit(0) returns 0 shares) pushes a ghost entry and the instant-fill walk does not
    // advance the head (`remaining_ == 0`). When capacity returns, the FIRST depositor whose
    // request satisfies the instant-fill predicate pays for walking every ghost with
    // `maxRequests_ = type(uint256).max`. Measured here: ghost creation and per-ghost walk cost.
    function test_BUG_ghostEntries_autoWalkGasGriefsNextDepositor() public {
        // Baseline: one deposit with an empty queue.
        _fund(alice, ONE_M);
        vm.cool(address(vault));
        vm.prank(alice);
        uint256 g0 = gasleft();
        vault.requestDeposit(ONE_M, alice, 0);
        uint256 baseline = g0 - gasleft();

        _setCapacity(vault.totalSupply());  // capacity exhausted: queue mode
        assertEq(vault.availableCapacity(), 0);

        // Attacker pushes N ghosts. No USDC needed, no approval needed.
        uint256 N = 2_000;
        vm.startPrank(mal);
        uint256 g1 = gasleft();
        for (uint256 i; i < N; ++i) vault.requestDeposit(0, mal, 0);
        uint256 ghostCost = (g1 - gasleft()) / N;
        vm.stopPrank();

        assertEq(vault.getPendingDepositRequests().length, N);
        assertEq(vault.firstPendingDepositId(), 1);   // alice's filled slot 0 is behind the head
        assertEq(vault.pendingDepositSavingsShares(), 0);

        // Rebalancer cannot clear them while capacity is zero: the loop needs remaining_ != 0.
        _processDeposits(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingDepositId(), 1);

        // Capacity returns. The next real depositor walks every ghost.
        _setCapacity(type(uint128).max);
        _fund(bob, ONE_M);
        vm.cool(address(vault));   // on-chain every ghost slot is cold (EIP-2929)
        vm.prank(bob);
        uint256 g2 = gasleft();
        vault.requestDeposit(ONE_M, bob, 0);
        uint256 walked = g2 - gasleft();
        uint256 perGhost = (walked - baseline) / N;

        emit log_named_uint("baseline deposit gas",        baseline);
        emit log_named_uint("ghost creation gas (each)",   ghostCost);
        emit log_named_uint("deposit gas after 2000 ghosts", walked);
        emit log_named_uint("walk gas per ghost",          perGhost);

        // Pinned bounds (osaka, optimizer 200, cold slots): ~2.3k gas to walk a ghost vs ~77k to
        // create one, so pushing the walk past a 30M block needs ~1.3e4 ghosts (~1e9 gas).
        // Rebalancer can always chunk the head forward once capacity is > 0.
        assertGt(perGhost, 2_000);
        assertLt(perGhost, 3_000);
        assertGt(ghostCost, 70_000);
        assertEq(vault.balanceOf(bob), 990_405_184_109);
        assertEq(vault.firstPendingDepositId(), N + 2);
    }

    // Same shape with minDeposit > 0: request-then-cancel creates a ghost in the deposit queue
    // (:432) and an entry in the cancellation queue, so minDeposit alone does not close the vector;
    // the attacker's capital is recycled by the cancellation queue.
    function test_BUG_ghostEntries_viaCancelWithMinDeposit() public {
        _setMinDeposit(1_000e6);
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());

        _fund(mal, 1_000e6 + 5);   // +1 wei per cycle: each cancel refund floors 1 wei
        for (uint256 i; i < 5; ++i) {
            vm.prank(mal);
            uint256 id = vault.requestDeposit(1_000e6, mal, 0);
            vm.prank(mal);
            vault.requestDepositCancellation(id, mal);
            _processCancelledDeposits(type(uint256).max, type(uint256).max);  // capital back
        }
        assertEq(usdc.balanceOf(mal), 1_000e6);  // 5 wei lost to rounding over 5 cycles
        assertEq(vault.getPendingDepositRequests().length, 5);
        assertEq(_sumDeposits(), 0);
        assertEq(vault.firstPendingDepositId(), 1);
    }

    // Rebalancer recovery: `processPendingDeposits(1, k)` advances the head over k ghosts once
    // capacity is non-zero, and does not touch live entries when the budget is exhausted on ghosts.
    function test_property_rebalancerCanChunkGhostsOnceCapacityReturns() public {
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());
        vm.startPrank(mal);
        for (uint256 i; i < 30; ++i) vault.requestDeposit(0, mal, 0);
        vm.stopPrank();
        _fund(bob, ONE_M);
        vm.prank(bob);
        vault.requestDeposit(ONE_M, bob, 0);  // live entry at index 30 behind 30 ghosts
        assertEq(vault.pendingDepositSavingsShares(), _sShares(ONE_M));

        // Ghosts count against maxRequests_ (:835): a budget of k advances the head by k ghosts
        // and fills nothing. Head starts at 1 (alice's slot 0 is filled).
        _setCapacity(type(uint128).max);
        _processDeposits(1, 10);
        assertEq(vault.firstPendingDepositId(), 11);
        _processDeposits(1, 20);
        assertEq(vault.firstPendingDepositId(), 31);
        assertEq(vault.balanceOf(bob), 0);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(bob), 990_405_184_109);
        assertEq(vault.firstPendingDepositId(), 32);
    }

    /**********************************************************************************************/
    /*** 3. Instant-fill predicate cannot fill a newcomer ahead of a live entry                 ***/
    /**********************************************************************************************/

    function test_property_instantFill_neverSkipsLiveEntry_partialHeadThenCancel() public {
        _setCapacity(0);
        uint256 idA = _deposit(alice, ONE_M);      // queued
        uint256 idB = _deposit(bob,   500_000e6);  // queued behind alice

        // Capacity for 300k USDC worth of shares: alice partially filled, stays at head.
        _setCapacity(_pShares(300_000e6));
        _processDeposits(type(uint256).max, type(uint256).max);
        ( , , uint256 remA ) = vault.getPendingDepositRequest(idA);
        assertGt(remA, 0);
        assertEq(vault.firstPendingDepositId(), idA);
        assertEq(vault.balanceOf(bob), 0);

        // Alice cancels her remainder: pending == bob's shares exactly now.
        vm.prank(alice);
        vault.requestDepositCancellation(idA, alice);
        assertEq(vault.pendingDepositSavingsShares(), _sShares(500_000e6));

        // Newcomer carol: predicate is `pending == own`, pending = bob + carol != carol -> queued.
        _setCapacity(type(uint128).max);
        uint256 idC = _deposit(carol, 100e6);
        assertEq(vault.balanceOf(carol), 0, "carol must not jump the queue");
        assertEq(idC, 2);

        // Rebalancer fills FIFO: bob first, then carol. A budget of 1 only walks ghost idA.
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.firstPendingDepositId(), idB);
        assertEq(vault.balanceOf(bob), 0);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(bob), _pShares(_sAssets(_sShares(500_000e6))));
        assertEq(vault.balanceOf(carol), 0);
        _processDeposits(type(uint256).max, 1);
        assertEq(vault.balanceOf(carol), _pShares(_sAssets(_sShares(100e6))));
        assertEq(vault.pendingDepositSavingsShares(), 0);
        assertEq(vault.firstPendingDepositId(), 3);
        ( , , uint256 ghostShares ) = _depositRequest(idB);
        assertEq(ghostShares, 0);
    }

    /**********************************************************************************************/
    /*** 4. Queue accounting: counters == array sums under random ops (fuzz)                    ***/
    /**********************************************************************************************/

    function testFuzz_property_queueCountersMatchArrays(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        uint256[] memory open = new uint256[](64);
        uint256 nOpen;

        _setCapacity(0);
        for (uint256 step; step < 24; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address u = users[r % 3];
            uint256 op = (r >> 8) % 7;
            if (op < 3) {
                uint256 amt = ((r >> 16) % 2_000_000e6) + 1;
                uint256 id = _deposit(u, amt);
                if (nOpen < 64) open[nOpen++] = id;
            } else if (op == 3 && nOpen > 0) {
                uint256 k = (r >> 16) % nOpen;
                ( address owner, , uint256 sh ) = _depositRequest(open[k]);
                if (sh != 0) {
                    vm.prank(owner);
                    vault.requestDepositCancellation(open[k], owner);
                }
                open[k] = open[--nOpen];
            } else if (op == 4) {
                _setCapacity(vault.totalSupply() + ((r >> 16) % 1_000_000e6));
                _processDeposits((r >> 64) % 3_000_000e6 + 1, (r >> 128) % 5 + 1);
            } else if (op == 5) {
                _processCancelledDeposits((r >> 64) % 3_000_000e6 + 1, (r >> 128) % 5 + 1);
            } else {
                uint256 bal = vault.balanceOf(u);
                if (bal != 0) {
                    _requestRedeem(u, (r >> 16) % bal + 1);
                    _processRedeems((r >> 64) % bal + 1, 2);
                }
            }
            assertEq(vault.pendingDepositSavingsShares(),          _sumDeposits(), "dep counter");
            assertEq(vault.pendingCancelledDepositSavingsShares(), _sumCancels(),  "cancel counter");
            assertEq(vault.pendingRedeemShares(),                  _sumRedeems(),  "redeem counter");
            assertEq(vault.pendingRedeemShares(), vault.balanceOf(address(vault)), "escrow");
            // Everything the vault owes in spUSDC terms is on its balance (no take in this fuzz).
            assertGe(
                _vaultSpUsdc(),
                vault.pendingDepositSavingsShares() + vault.pendingCancelledDepositSavingsShares(),
                "queue backing"
            );
            assertLe(vault.firstPendingDepositId(), _depositQueueLength());
            assertLe(vault.firstPendingDepositCancellationId(), _cancelledDepositQueueLength());
            assertLe(vault.firstPendingRedeemId(), _redeemQueueLength());
            // Entries below each head are dead.
            for (uint256 i; i < vault.firstPendingDepositId(); ++i) {
                ( , , uint256 sh ) = _depositRequest(i);
                assertEq(sh, 0, "live entry below head");
            }
        }
    }

    /**********************************************************************************************/
    /*** 5. Batched rounding: cancellations never revert, redeems can (C-1 re-proved)           ***/
    /**********************************************************************************************/

    // Cancellation path: bound is spUSDC.maxRedeem (floor), each entry calls spUSDC.redeem which
    // floors assets, so sum(assets) <= liquidity and sum(shares) <= balance always.
    function testFuzz_property_cancellationBatch_neverRevertsOnRounding(uint256 seed) public {
        _setCapacity(0);
        uint256 n = 2 + seed % 6;
        for (uint256 i; i < n; ++i) {
            uint256 amt = uint256(keccak256(abi.encode(seed, i))) % 500_000e6 + 1;
            uint256 id = _deposit(alice, amt);
            vm.prank(alice);
            vault.requestDepositCancellation(id, alice);
        }
        // Make spUSDC liquidity the binding constraint sometimes.
        if (seed % 2 == 0) _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) / 2);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        if (seed % 2 == 1) assertEq(vault.pendingCancelledDepositSavingsShares(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), _sumCancels());
    }

    // Redeem path: `remaining_` is bounded once by convertToShares(maxWithdraw) but each
    // spUSDC.withdraw ceil-burns savings shares, so a batch that drains the vault's whole spUSDC
    // balance can need 1 more savings-share wei than it holds and reverts
    // "SparkVault/insufficient-balance". Search a few share splits; the test asserts the revert
    // exists. Rebalancer workaround: lower maxShares_ by a few wei.
    function test_BUG_redeemBatch_ceilRounding_revertsWhenDrainingAllBacking() public {
        _deposit(alice, ONE_M);
        uint256 total = vault.balanceOf(alice);
        bool found;
        for (uint256 k = 1; k < 40 && !found; ++k) {
            uint256 snap = vm.snapshotState();
            // Split into 3 entries: k wei, k wei, rest.
            _requestRedeem(alice, k);
            _requestRedeem(alice, k);
            _requestRedeem(alice, total - 2 * k);
            vm.prank(operator);
            try vault.processPendingRedeems(type(uint256).max, type(uint256).max) {
                // ok
            } catch (bytes memory err) {
                assertEq(err, abi.encodeWithSignature("Error(string)", "SparkVault/insufficient-balance"));
                found = true;
                emit log_named_uint("reverting split k", k);
            }
            vm.revertToState(snap);
        }
        assertTrue(found, "no reverting split found");
    }

    /**********************************************************************************************/
    /*** 6. adjustTotalAssets gain sandwich (deposit before pause), quantified                   ***/
    /**********************************************************************************************/

    // Holders: alice 1M. Governance payload (+10_000 USDC) is public; mal deposits 1M in the block
    // before GUARDIAN pauses; admin adjusts; unpause; mal redeems. Fee 0: mal captures half the
    // gain minus rounding. Fee 1%: fee (10_000) exceeds the capture (5_000), so a 1% fee protects
    // against gains < 2% of mal's stake... only if the fee is actually set (default 0).
    function test_BUG_adjustTotalAssets_gainSandwich_depositBeforePause() public {
        _deposit(alice, ONE_M);
        _deposit(mal,   ONE_M);
        uint256 malShares = vault.balanceOf(mal);
        assertEq(malShares, 990_405_184_109);

        uint256 ts   = vault.totalSupply();
        uint256 chiN = (vault.totalAssets() + 10_000e6) * RAY / ts;
        _pause();
        _adjustTotalAssets(10_000e6);
        _unpause();
        assertEq(vault.chi(), chiN);

        uint256 malAssets = vault.assetsOf(mal);
        emit log_named_uint("mal assets after +10k adjust", malAssets);
        // Half of the gain (equal stakes) minus floor rounding.
        assertEq(malAssets, malShares * chiN / RAY);
        assertEq(malAssets, 1_004_999_999_998);          // +4_999.999999 USDC on 1M
        assertEq(vault.assetsOf(alice), 1_004_999_999_998);

        // Fee 0 (the default): mal walks away with the gain.
        uint256 snap = vm.snapshotState();
        _requestRedeem(mal, malShares);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(mal), 1_004_999_999_998);
        vm.revertToState(snap);

        // Fee 1%: fee = 9_904_051_842 shares ~ 10_000 USDC > 5_000 gain.
        _setRedeemFeeRate(0.01e18);
        _requestRedeem(mal, malShares);
        _processRedeems(type(uint256).max, type(uint256).max);
        uint256 fee = _divUp(malShares * 0.01e18, WAD);
        assertEq(fee, 9_904_051_842);
        assertEq(usdc.balanceOf(mal), (malShares - fee) * chiN / RAY);
        emit log_named_uint("mal USDC after 1% fee", usdc.balanceOf(mal));
        assertLt(usdc.balanceOf(mal), ONE_M);
    }

    /**********************************************************************************************/
    /*** 7. Redeem liquidity is not ring-fenced from cancellation backing                       ***/
    /**********************************************************************************************/

    // The redeem bound is spUSDC.maxWithdraw(vault): ALL the vault's spUSDC, including the shares
    // that back queued deposits and queued cancellations. A redeemer can be paid out of a queued
    // depositor's money; the depositor's later cancellation then cannot settle until the taker
    // returns funds. No value is created or lost, but a canceller is stuck behind the operator.
    function test_BUG_redeemsConsumeQueuedDepositBacking_cancellerStuck() public {
        _deposit(alice, ONE_M);                 // alice holds shares; vault holds S_1M spUSDC
        _takeAll();                             // operator deployed everything (vault has 0 spUSDC)
        assertEq(_vaultSpUsdc(), 0);

        _setCapacity(vault.totalSupply());      // capacity exhausted
        uint256 idB = _deposit(bob, ONE_M);     // bob queued; his S_1M spUSDC sits in the vault
        uint256 S = _sShares(ONE_M);
        assertEq(_vaultSpUsdc(), S);
        assertEq(vault.availableLiquidAssets(), _sAssets(S));  // bob's money counts as liquidity

        uint256 aliceShares = vault.balanceOf(alice);
        _requestRedeem(alice, aliceShares);
        _processRedeems(type(uint256).max, type(uint256).max);
        uint256 filled = _pShares(_sAssets(S));                // bound = all of bob's backing
        uint256 paidA  = _pAssets(filled);
        assertEq(usdc.balanceOf(alice), paidA);                // paid from bob's backing
        assertEq(paidA, 999_999_999_998);
        assertEq(_vaultSpUsdc(), S - _divUp(paidA * RAY, CHI_S));
        assertEq(_vaultSpUsdc(), 0);                           // bob's backing is fully gone
        assertEq(vault.pendingRedeemShares(), aliceShares - filled);
        assertEq(filled, aliceShares);                         // alice fully paid from bob's money

        vm.prank(bob);
        vault.requestDepositCancellation(idB, bob);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), 0);                      // nothing to refund bob with
        assertEq(vault.firstPendingDepositCancellationId(), 0);
        assertEq(vault.pendingCancelledDepositSavingsShares(), S);

        // Only the taker returning funds frees bob.
        _returnToVault(S);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), _sAssets(S));
        assertEq(usdc.balanceOf(bob), 999_999_999_999);
        assertEq(vault.firstPendingDepositCancellationId(), 1);
    }

    /**********************************************************************************************/
    /*** 8. Referral attribution is emitted at request time and survives cancellation           ***/
    /**********************************************************************************************/

    event Referral(uint16 indexed referral, address indexed recipient, uint256 assets);

    function test_info_referralEmittedOnRequest_notOnFill_cancelLoopInflatesVolume() public {
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());
        _fund(mal, ONE_M + 3);
        for (uint256 i; i < 3; ++i) {
            vm.expectEmit(true, true, true, true);
            emit Referral(777, mal, ONE_M);
            vm.prank(mal);
            uint256 id = vault.requestDeposit(ONE_M, mal, 777);
            vm.prank(mal);
            vault.requestDepositCancellation(id, mal);
            _processCancelledDeposits(type(uint256).max, type(uint256).max);
        }
        // 3M USDC of "referred volume" emitted; zero shares ever minted; cost 3 wei.
        assertEq(vault.balanceOf(mal), 0);
        assertEq(usdc.balanceOf(mal), ONE_M);
        // Also: anyone can attach a referral code to another address for 0 USDC.
        vm.expectEmit(true, true, true, true);
        emit Referral(777, alice, 0);
        vm.prank(mal);
        vault.requestDeposit(0, alice, 777);
    }

    /**********************************************************************************************/
    /*** 9. Fee cannot be bypassed; zero-share redeem entries are harmless                      ***/
    /**********************************************************************************************/

    function test_property_redeemFee_notBypassableByTransferOrRecipient() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, ONE_M);
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(bob, sh);
        vm.prank(bob);
        vault.requestRedeem(sh, carol);
        uint256 fee = _divUp(sh * 0.01e18, WAD);
        assertEq(fee, 9_904_051_842);
        assertEq(vault.totalSupply(), sh - fee);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(carol), _pAssets(sh - fee));
        assertEq(usdc.balanceOf(carol), 989_999_999_997);
    }

    function test_property_oneWeiRedeemWithFee_isAllFee_ghostIsSkipped() public {
        _setRedeemFeeRate(0.01e18);
        _deposit(alice, ONE_M);
        uint256 id = _requestRedeem(alice, 1);
        ( , , uint256 sh ) = _redeemRequest(id);
        assertEq(sh, 0);
        assertEq(vault.pendingRedeemShares(), 0);
        vm.prank(alice);
        vm.expectRevert(ISparkPrimeVault.NoRequest.selector);
        vault.updateRedeemRecipient(id, bob);
        uint256 id2 = _requestRedeem(alice, 1_000);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingRedeemId(), id2 + 1);
        assertEq(usdc.balanceOf(alice), _pAssets(990));
    }

    /**********************************************************************************************/
    /*** 10. Blacklist: owner-side evasion, vault blacklisted, claimable escrow invariants      ***/
    /**********************************************************************************************/

    // The vault only ever checks the RECIPIENT. A USDC-blacklisted share holder can still exit to
    // any clean address (request with clean recipient, update recipient, or transfer shares).
    // spUSDC behaves the same (redeem(shares, cleanReceiver, owner)), so this is consistent, but
    // auditors should know the blacklist handling is a liveness feature, not a compliance gate.
    function test_info_blacklistedOwner_canStillExitViaCleanRecipient() public {
        _deposit(alice, ONE_M);
        uint256 half = vault.balanceOf(alice) / 2;
        uint256 id = _requestRedeem(alice, half);
        _blacklist(alice);

        vm.prank(alice);
        vault.updateRedeemRecipient(id, bob);                 // allowed: bob is clean
        vm.prank(alice);
        vault.requestRedeem(half, carol);                      // allowed: carol is clean
        uint256 rest = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(mal, rest);                             // shares are not blacklist-gated

        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob),   _pAssets(half));
        assertEq(usdc.balanceOf(carol), _pAssets(half));
        assertEq(vault.claimableAssets(alice), 0);
    }

    function test_info_vaultBlacklisted_redeemsAndCancelsStillPay_depositsAndClaimsDont() public {
        _deposit(alice, ONE_M);
        _setCapacity(vault.totalSupply());
        uint256 idB = _deposit(bob, 100e6);
        uint256 idR = _requestRedeem(alice, 1_000_000);
        _fund(carol, 1e6);           // real USDC also rejects approve() of a blacklisted spender
        _blacklist(address(vault));

        vm.prank(carol);
        vm.expectRevert(BLACKLISTED);
        vault.requestDeposit(1e6, carol, 0);

        // spUSDC pushes USDC straight to the recipient: the vault never touches USDC here.
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), _pAssets(1_000_000));
        ( , , uint256 left ) = _redeemRequest(idR);
        assertEq(left, 0);
        vm.prank(bob);
        vault.requestDepositCancellation(idB, bob);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), 99_999_999);
    }

    // Escrow invariant: sum(claimableAssets) <= USDC held by the vault, and requestDeposit (which
    // pulls then re-pushes exactly `assets_`) never touches the escrow.
    function test_property_claimableEscrow_untouchedByDeposits_exactWei() public {
        _deposit(alice, ONE_M);
        uint256 sh = vault.balanceOf(alice);
        _requestRedeem(alice, sh);
        _blacklist(alice);
        _processRedeems(type(uint256).max, type(uint256).max);
        uint256 owed = _pAssets(sh);
        assertEq(owed, 999_999_999_998);
        assertEq(vault.claimableAssets(alice), owed);
        assertEq(usdc.balanceOf(address(vault)), owed);

        _deposit(bob, 123_456e6);   // instant fill: pulls 123_456e6 and deposits 123_456e6
        assertEq(usdc.balanceOf(address(vault)), owed);
        _requestRedeem(bob, vault.balanceOf(bob));
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(address(vault)), owed);

        vm.expectRevert(BLACKLISTED);
        vault.claim(alice);
        _unblacklist(alice);
        vm.prank(mal);                 // permissionless, pays alice regardless of caller
        uint256 paid = vault.claim(alice);
        assertEq(paid, owed);
        assertEq(usdc.balanceOf(alice), owed);
        assertEq(usdc.balanceOf(address(vault)), 0);
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(alice);
    }

    /**********************************************************************************************/
    /*** 11. Take-all stalls every settlement without reverting; returns resume it               ***/
    /**********************************************************************************************/

    function test_property_takeAll_settlementsAreNoOps_notReverts() public {
        _deposit(alice, ONE_M);
        uint256 aliceShares = vault.balanceOf(alice);
        _setCapacity(vault.totalSupply());
        uint256 idB = _deposit(bob, 100e6);
        _setCapacity(type(uint128).max);
        _requestRedeem(alice, aliceShares);
        vm.prank(bob);
        vault.requestDepositCancellation(idB, bob);
        _takeAll();

        _processRedeems(type(uint256).max, type(uint256).max);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(vault.firstPendingDepositCancellationId(), 0);

        // Deposits still FILL (minting needs no spUSDC on hand) even with zero backing.
        _deposit(carol, 10e6);
        assertEq(vault.balanceOf(carol), _pShares(_sAssets(_sShares(10e6))));
        assertEq(_vaultSpUsdc(), _sShares(10e6));

        _returnToVault(_sShares(ONE_M) + _sShares(100e6));
        _processRedeems(type(uint256).max, type(uint256).max);
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(alice), _pAssets(aliceShares));
        assertEq(usdc.balanceOf(alice), 999_999_999_998);
        assertEq(usdc.balanceOf(bob), _sAssets(_sShares(100e6)));
        assertEq(usdc.balanceOf(bob), 99_999_999);
    }

    /**********************************************************************************************/
    /*** 12. spUSDC failure modes: deposit cap, drained liquidity, VSR change while queued      ***/
    /**********************************************************************************************/

    function test_property_spUsdcDepositCap_propagatesAsRevert() public {
        uint256 cap = spUsdc.totalAssets() + 500_000e6;
        vm.prank(spAdmin);
        spUsdc.setDepositCap(cap);
        _fund(alice, ONE_M);
        vm.prank(alice);
        vm.expectRevert("SparkVault/deposit-cap-exceeded");
        vault.requestDeposit(ONE_M, alice, 0);
        vm.prank(alice);
        vault.requestDeposit(500_000e6, alice, 0);
        assertEq(vault.balanceOf(alice), _pShares(_sAssets(_sShares(500_000e6))));
    }

    function test_property_spUsdcLiquidityDrain_partialFillsExact_noRevert() public {
        _deposit(alice, ONE_M);
        uint256 sh = vault.balanceOf(alice);
        _requestRedeem(alice, sh);
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 250_000e6);
        assertEq(vault.availableLiquidAssets(), 250_000e6);

        _processRedeems(type(uint256).max, type(uint256).max);
        uint256 filled = _pShares(250_000e6);
        assertEq(usdc.balanceOf(alice), _pAssets(filled));
        assertEq(usdc.balanceOf(alice), 249_999_999_999);
        assertEq(vault.pendingRedeemShares(), sh - filled);
        assertEq(vault.firstPendingRedeemId(), 0);

        _returnSpUsdcLiquidity(ONE_M);
        _processRedeems(type(uint256).max, type(uint256).max);
        // The first fill ceil-burned spUSDC, so the vault's own backing is now short: the bound
        // `convertToShares(assetsOf(vault))` is 1 share below what is owed and the entry stays at
        // the head with 1 share of dust (see test_BUG_partialFills_leaveUnpayableDust).
        assertEq(usdc.balanceOf(alice), 999_999_999_997);
        assertEq(vault.pendingRedeemShares(), 1);
        assertEq(vault.firstPendingRedeemId(), 0);
        _returnToVault(1);     // 1 spUSDC wei = 1 USDC wei = 0 spPRIME shares: still stuck
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.pendingRedeemShares(), 1);
        _returnToVault(1);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.firstPendingRedeemId(), 1);
        assertEq(usdc.balanceOf(alice), 999_999_999_998);
    }

    // Each partial fill ceil-burns spUSDC (spUSDC.withdraw) while the vault's liability is
    // floored (convertToAssets). With no external spUSDC inflow the vault's backing falls short of
    // its notional by ~1 savings-share wei per fill, so a redeem that is settled in k partial
    // fills can leave a head entry with dust that `processPendingRedeems` can never clear
    // (remaining_ == 0 => the loop does not even run, firstPendingRedeemId stays). Every later
    // redeemer is queued behind that dust until the taker donates spUSDC.
    function test_BUG_partialFills_leaveUnpayableDustAtRedeemHead() public {
        _deposit(alice, ONE_M);
        uint256 S  = _sShares(ONE_M);                  // 954_532_691_143 spUSDC held by the vault
        uint256 sh = vault.balanceOf(alice);           // 990_405_184_109 spPRIME
        _requestRedeem(alice, sh);

        // Slice 1: spUSDC liquidity limited to 250k USDC.
        _drainSpUsdcLiquidity(usdc.balanceOf(address(spUsdc)) - 250_000e6);
        _processRedeems(type(uint256).max, type(uint256).max);
        uint256 f1 = _pShares(250_000e6);
        uint256 a1 = _pAssets(f1);
        uint256 b1 = _divUp(a1 * RAY, CHI_S);          // spUSDC ceil-burned by slice 1
        assertEq(a1, 249_999_999_999);
        assertEq(_vaultSpUsdc(), S - b1);

        // Slice 2: liquidity is back, the only bound is the vault's own spUSDC.
        _returnSpUsdcLiquidity(ONE_M);
        uint256 owedAssets = _pAssets(sh - f1);
        uint256 backing    = _sAssets(S - b1);
        emit log_named_uint("assets owed to the head", owedAssets);
        emit log_named_uint("assets the vault can withdraw", backing);
        // Backing covers the owed assets exactly, but the bound is re-floored into shares
        // (:903 convertToShares(maxWithdraw)) and lands one share below the entry; the fill of
        // (owed - 1) shares then ceil-burns the vault's last spUSDC wei.
        assertEq(backing, owedAssets);
        assertEq(_pShares(backing), sh - f1 - 1);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.pendingRedeemShares(), 1);      // 1 share of dust, head does not move
        assertEq(vault.firstPendingRedeemId(), 0);
        assertEq(usdc.balanceOf(alice), 999_999_999_997);
        assertEq(vault.availableLiquidAssets(), _sAssets(_vaultSpUsdc()));
        assertEq(_vaultSpUsdc(), 0);

        // No amount of calling processPendingRedeems moves it: remaining_ == 0 skips the loop.
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingRedeemId(), 0);

        // The deficit migrates: bob's fresh backing pays alice's dust, bob ends up short instead.
        _deposit(bob, 100e6);
        uint256 shB = vault.balanceOf(bob);
        _requestRedeem(bob, shB);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(vault.firstPendingRedeemId(), 1);     // alice cleared
        assertEq(usdc.balanceOf(alice), 999_999_999_998);
        assertGt(vault.pendingRedeemShares(), 0);      // bob now holds the dust
        assertEq(vault.firstPendingRedeemId(), 1);
        emit log_named_uint("bob shares left unpayable", vault.pendingRedeemShares());
        assertEq(usdc.balanceOf(bob), _pAssets(shB) - 1);      // 1 wei short: alice's dust
    }

    // A queued depositor earns spUSDC yield while waiting (entry is in spUSDC shares); a queued
    // redeemer earns spPRIME yield while waiting (entry is in spPRIME shares). Exact wei.
    function test_property_queuedEntries_accrueTheirOwnIndex() public {
        _setCapacity(0);
        _deposit(alice, ONE_M);
        _setSpUsdcVsr(TEN_PCT_VSR);
        _setPrimeVsr(FIVE_PCT_VSR);
        _warpAndDrip(365 days);
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        uint256 a = vault.assetsOf(alice);
        emit log_named_uint("alice assets after 1y queued @ spUSDC 10%", a);
        assertGt(a, 1_099_999e6);   // ~10% from spUSDC, not 5% from spPRIME
        assertLt(a, 1_100_001e6);
    }

    /**********************************************************************************************/
    /*** 13. adjustTotalAssets is relative: spell lag drifts the target                         ***/
    /**********************************************************************************************/

    function test_info_adjustTotalAssets_relativeDelta_spellLagDrift() public {
        _deposit(alice, 100_000_000e6);
        _setPrimeVsr(FIVE_PCT_VSR);
        uint256 t0 = vault.totalAssets();
        // Spell computed at t0: "set totalAssets to t0 + 1M" => delta = 1M.
        int256 delta = 1_000_000e6;
        _warp(3 days);
        _pause();
        _adjustTotalAssets(delta);
        _unpause();
        uint256 drift = vault.totalAssets() - (t0 + 1_000_000e6);
        emit log_named_uint("overshoot vs intended target (USDC wei)", drift);
        assertGt(drift, 40_000e6);  // ~41k USDC of accrual landed on top of the delta
        assertLt(drift, 42_000e6);
    }

    /**********************************************************************************************/
    /*** 14. ERC20 / permit / ERC1271                                                           ***/
    /**********************************************************************************************/

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal view returns (bytes32)
    {
        return keccak256(abi.encodePacked(
            "\x19\x01",
            vault.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(vault.PERMIT_TYPEHASH(), owner, spender, value, nonce, deadline))
        ));
    }

    function test_property_permit_eoa_nonceOnlyAdvancesOnSuccess() public {
        (address owner, uint256 pk) = makeAddrAndKey("owner");
        bytes32 digest = _permitDigest(owner, bob, 123, 0, block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        // Wrong value -> invalid-permit, nonce untouched.
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner, bob, 124, block.timestamp, v, r, s);
        assertEq(vault.nonces(owner), 0);

        vault.permit(owner, bob, 123, block.timestamp, v, r, s);
        assertEq(vault.allowance(owner, bob), 123);
        assertEq(vault.nonces(owner), 1);

        // Replay blocked by nonce.
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner, bob, 123, block.timestamp, v, r, s);
        _warp(1);
        vm.expectRevert("SparkPrimeVault/permit-expired");
        vault.permit(owner, bob, 123, block.timestamp - 1, v, r, s);
    }

    // ecrecover accepts high-s signatures; the vault does not reject them (no EIP-2 check).
    // Harmless because of the nonce (a signature and its malleated twin share one nonce).
    function test_info_permit_acceptsMalleatedHighS_signature() public {
        (address owner, uint256 pk) = makeAddrAndKey("owner");
        bytes32 digest = _permitDigest(owner, bob, 5, 0, block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        uint256 N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 s2 = bytes32(N - uint256(s));
        uint8 v2 = v == 27 ? 28 : 27;
        vault.permit(owner, bob, 5, block.timestamp, v2, r, s2);
        assertEq(vault.allowance(owner, bob), 5);
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(owner, bob, 5, block.timestamp, v, r, s);  // twin cannot replay
    }

    function test_property_permit_erc1271_contractOwner() public {
        ERC1271Wallet w = new ERC1271Wallet();
        bytes32 digest = _permitDigest(address(w), bob, 9, 0, block.timestamp);
        bytes memory sig = hex"deadbeef";
        vm.expectRevert("SparkPrimeVault/invalid-permit");
        vault.permit(address(w), bob, 9, block.timestamp, sig);
        w.set(digest);
        vault.permit(address(w), bob, 9, block.timestamp, sig);
        assertEq(vault.allowance(address(w), bob), 9);
        // 65-byte garbage on a contract owner falls through to ERC1271 too.
        bytes32 d2 = _permitDigest(address(w), bob, 10, 1, block.timestamp);
        w.set(d2);
        vault.permit(address(w), bob, 10, block.timestamp, 27, bytes32(uint256(1)), bytes32(uint256(2)));
        assertEq(vault.allowance(address(w), bob), 10);
    }

    function test_property_erc20_selfTransfer_andVaultTargets() public {
        _deposit(alice, ONE_M);
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(alice, sh);
        assertEq(vault.balanceOf(alice), sh);
        vm.prank(alice);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transfer(address(vault), 1);
        vm.prank(alice);
        vault.approve(bob, 10);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/invalid-address");
        vault.transferFrom(alice, address(vault), 1);
        vm.prank(bob);
        vm.expectRevert("SparkPrimeVault/insufficient-allowance");
        vault.transferFrom(alice, carol, 11);
        vm.prank(alice);
        vault.transferFrom(alice, carol, sh);   // self path needs no allowance
        assertEq(vault.balanceOf(carol), sh);
        assertEq(vault.allowance(alice, bob), 10);
        assertEq(vault.totalSupply(), sh);
    }

    /**********************************************************************************************/
    /*** 15. Initialization, upgrade authorization, storage layout                              ***/
    /**********************************************************************************************/

    function test_property_initializer_cannotRerun_onProxyOrImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(address(spUsdc), "x", "x", mal);
        SparkPrimeVault impl = SparkPrimeVault(vault.implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(spUsdc), "x", "x", mal);
        address v2 = address(new SparkPrimeVaultV2Mock());
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        impl.upgradeToAndCall(v2, "");
    }

    function test_property_upgrade_adminOnly_statePreserved_slot28Appended() public {
        _deposit(alice, ONE_M);
        address v2 = address(new SparkPrimeVaultV2Mock());
        vm.prank(mal);
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, mal, DEFAULT_ADMIN_ROLE
        ));
        vault.upgradeToAndCall(v2, "");
        vm.prank(admin);
        vault.upgradeToAndCall(v2, abi.encodeCall(SparkPrimeVaultV2Mock.initializeV2, (42)));
        assertEq(vault.implementation(), v2);
        assertEq(SparkPrimeVaultV2Mock(address(vault)).newVar(), 42);
        // NOTE: the mock's own comment says slot 27, but `allowance` is 27 on 0ebb452; the
        //       compiler puts the appended var at 28. Pin the real slot.
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(27)))), 0);
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(28)))), 42);
        assertEq(vault.balanceOf(alice), 990_405_184_109);
        assertEq(vault.chi(), CHI_P);
        assertEq(vault.nowChi(), CHI_P);
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        SparkPrimeVaultV2Mock(address(vault)).initializeV2(43);
    }

    function test_property_storageLayout_0ebb452_pinned() public {
        _deposit(alice, ONE_M);
        uint256 id = _requestRedeem(alice, 1_000);
        assertEq(id, 0);
        address V = address(vault);
        // 0,1,2: the three Request[] arrays (length words).
        assertEq(uint256(vm.load(V, bytes32(uint256(0)))), 1);  // _depositRequests.length
        assertEq(uint256(vm.load(V, bytes32(uint256(1)))), 0);  // _depositCancellationRequests
        assertEq(uint256(vm.load(V, bytes32(uint256(2)))), 1);  // _redeemRequests
        // 3 savings, 4 asset|paused(offset 20)
        assertEq(address(uint160(uint256(vm.load(V, bytes32(uint256(3)))))), address(spUsdc));
        assertEq(uint256(vm.load(V, bytes32(uint256(4)))), uint256(uint160(address(usdc))));
        _pause();
        assertEq(uint256(vm.load(V, bytes32(uint256(4)))), uint256(uint160(address(usdc))) | (1 << 160));
        _unpause();
        // 7: decimals (uint8) | rho (uint64 at offset 1); 8: chi
        assertEq(uint256(vm.load(V, bytes32(uint256(7)))), 6 | (uint256(vault.rho()) << 8));
        assertEq(uint256(vm.load(V, bytes32(uint256(8)))), CHI_P);
        assertEq(uint256(vm.load(V, bytes32(uint256(9)))),  RAY);           // vsr
        assertEq(uint256(vm.load(V, bytes32(uint256(10)))), RAY);           // minVSR
        assertEq(uint256(vm.load(V, bytes32(uint256(11)))), MAX_VSR);       // maxVSR
        assertEq(uint256(vm.load(V, bytes32(uint256(12)))), type(uint128).max);  // maxCapacity
        assertEq(uint256(vm.load(V, bytes32(uint256(16)))), 0.01e18);      // maxRedeemFeeRate
        assertEq(uint256(vm.load(V, bytes32(uint256(17)))), vault.totalSupply());
        assertEq(uint256(vm.load(V, bytes32(uint256(20)))), 1_000);        // pendingRedeemShares
        assertEq(uint256(vm.load(V, bytes32(uint256(23)))), 0);            // firstPendingRedeemId
        // 24 balanceOf, 25 nonces, 26 claimableAssets, 27 allowance
        assertEq(uint256(vm.load(V, keccak256(abi.encode(alice, uint256(24))))), vault.balanceOf(alice));
        assertEq(uint256(vm.load(V, keccak256(abi.encode(V, uint256(24))))), 1_000);
        vm.prank(alice);
        vault.approve(bob, 77);
        assertEq(uint256(vm.load(V, keccak256(abi.encode(bob, keccak256(abi.encode(alice, uint256(27))))))), 77);
        // Redeem entry 0 lives at keccak(2) + 0: owner, recipient, shares.
        bytes32 base = keccak256(abi.encode(uint256(2)));
        assertEq(address(uint160(uint256(vm.load(V, base)))), alice);
        assertEq(address(uint160(uint256(vm.load(V, bytes32(uint256(base) + 1))))), alice);
        assertEq(uint256(vm.load(V, bytes32(uint256(base) + 2))), 1_000);
    }

    /**********************************************************************************************/
    /*** 16. Index math: drip at MAX_VSR over long idle periods                                 ***/
    /**********************************************************************************************/

    function test_property_drip_maxVsr_survives60YearsIdle_overflowsAt77() public {
        _deposit(alice, ONE_M);
        _setPrimeVsr(MAX_VSR);
        uint256 snap = vm.snapshotState();
        _warp(60 * 365 days);
        vault.drip();
        assertGt(vault.chi(), CHI_P * (1 << 59) );   // ~2^60 growth
        vm.revertToState(snap);
        _warp(77 * 365 days);
        vm.expectRevert();  // _rpow internal mul overflow (revert(0,0))
        vault.drip();
    }

    /**********************************************************************************************/
    /*** 17. Loss adjustment: who pays across the three queues (exact wei)                      ***/
    /**********************************************************************************************/

    function test_property_loss_hitsHoldersAndQueuedRedeemers_notQueuedDepositsOrCancels() public {
        _deposit(alice, ONE_M);                       // holder
        _deposit(bob,   ONE_M);
        _requestRedeem(bob, vault.balanceOf(bob));    // queued redeemer (escrowed shares)
        _setCapacity(vault.totalSupply());
        uint256 idC = _deposit(carol, ONE_M);         // queued deposit (spUSDC shares)
        uint256 idD = _deposit(mal,   ONE_M);
        vm.prank(mal);
        vault.requestDepositCancellation(idD, mal);   // queued cancellation
        uint256 ta = vault.totalAssets();
        assertEq(ta, 1_999_999_999_997);
        uint256 sh   = 990_405_184_109;                   // each of alice / bob
        uint256 chiN = (ta - ta / 2) * RAY / (2 * sh);

        _adjustTotalAssetsWhilePaused(-int256(ta / 2));   // 50% loss
        assertEq(vault.chi(), chiN);

        assertEq(vault.assetsOf(alice), sh * chiN / RAY);
        assertEq(vault.assetsOf(alice), 499_999_999_999);
        assertEq(vault.assetsOf(address(vault)), 499_999_999_999);
        _processRedeems(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(bob), 499_999_999_999);   // redeemer ate the loss
        _processCancelledDeposits(type(uint256).max, type(uint256).max);
        assertEq(usdc.balanceOf(mal), 999_999_999_999);   // canceller untouched (1 wei floor)
        _setCapacity(type(uint128).max);
        _processDeposits(type(uint256).max, type(uint256).max);
        uint256 carolShares = _sAssets(_sShares(ONE_M)) * RAY / chiN;
        assertEq(vault.balanceOf(carol), carolShares);
        assertEq(vault.assetsOf(carol), carolShares * chiN / RAY);
        emit log_named_uint("carol assets after fill at post-loss chi", vault.assetsOf(carol));
        assertGe(vault.assetsOf(carol), 999_999_999_996); // depositor untouched (floors only)
        ( , , uint256 left ) = _depositRequest(idC);
        assertEq(left, 0);
    }

    /**********************************************************************************************/
    /*** 18. Misc footguns                                                                      ***/
    /**********************************************************************************************/

    function test_info_redeemRecipientVault_strandsUsdcForever() public {
        _deposit(alice, ONE_M);
        vm.prank(alice);
        vault.requestRedeem(1_000_000, address(vault));   // not rejected (only blacklist-checked)
        _processRedeems(type(uint256).max, type(uint256).max);
        uint256 stuck = _pAssets(1_000_000);
        assertEq(usdc.balanceOf(address(vault)), stuck);
        assertEq(vault.claimableAssets(address(vault)), 0);   // not claimable: vault is "clean"
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        vault.claim(address(vault));
    }

    function test_info_depositRecipientSpUsdc_strandsShares() public {
        _fund(alice, ONE_M);
        vm.prank(alice);
        vault.requestDeposit(ONE_M, address(spUsdc), 0);
        assertEq(vault.balanceOf(address(spUsdc)), 990_405_184_109);
    }

    function test_info_requestDepositCancellation_outOfRange_panics() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x32));
        vault.requestDepositCancellation(0, alice);
    }

}
