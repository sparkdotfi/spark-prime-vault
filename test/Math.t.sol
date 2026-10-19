// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test, stdError } from "../lib/forge-std/src/Test.sol";

import { SparkPrimeVault } from "../src/SparkPrimeVault.sol";

contract SparkPrimeVaultHarness is SparkPrimeVault {

    function divUp(uint256 x, uint256 y) public pure returns (uint256) {
        return super._divUp(x, y);
    }

    function rpow(uint256 x, uint256 n) public pure returns (uint256) {
        return super._rpow(x, n);
    }

}

contract MathTestBase is Test {

    // NOTE: Don't need to use upgradability pattern because of pure functions
    SparkPrimeVaultHarness harness;

    function setUp() public {
        harness = new SparkPrimeVaultHarness();
    }

}

contract DivupFailureTests is MathTestBase {

    function test_divup_divideByZero() external {
        vm.expectRevert(stdError.divisionError);
        harness.divUp(1, 0);
    }

}

contract DivupSuccessTests is MathTestBase {

    struct TestCase {
        uint256 x;
        uint256 y;
        uint256 expected;
    }

    function fixtureDivision() external pure returns (TestCase[] memory testCases) {
        testCases = new TestCase[](10);

        testCases[0] = TestCase({ x: 1,  y: 1, expected: 1 });  // 1
        testCases[1] = TestCase({ x: 1,  y: 2, expected: 1 });  // 0.5
        testCases[2] = TestCase({ x: 2,  y: 2, expected: 1 });  // 1
        testCases[3] = TestCase({ x: 2,  y: 3, expected: 1 });  // 0.66...
        testCases[4] = TestCase({ x: 3,  y: 2, expected: 2 });  // 1.5
        testCases[5] = TestCase({ x: 5,  y: 2, expected: 3 });  // 2.5
        testCases[6] = TestCase({ x: 10, y: 3, expected: 4 });  // 3.33...

        testCases[7] = TestCase({ x: 1e6, y: 1e6 + 1, expected: 1 });  // 0.999999
        testCases[8] = TestCase({ x: 1e6, y: 1e6,     expected: 1 });  // 1
        testCases[9] = TestCase({ x: 1e6, y: 1e6 - 1, expected: 2 });  // 1.000001
    }

    function table_divup_roundUp(TestCase memory division) external view {
        assertEq(harness.divUp(division.x, division.y), division.expected);
    }

}

contract RpowFailureTests is MathTestBase {

    function test_rpow_squareOverflow() external {
        vm.expectRevert();
        harness.rpow(2 ** 128, 2);
    }

}

contract RpowSuccessTests is MathTestBase {

    struct ApyVsrTestCase {
        uint256 apy;
        uint256 vsr;
    }

    // NOTE: The CSV data was sourced from Sky Ecosystem's VSR conversion table:
    //       https://ipfs.io/ipfs/QmVp4mhhbwWGTfbh2BzwQB9eiBrQBKiqcPRZCaAxNUaar6
    function fixtureApyVsr() external view returns (ApyVsrTestCase[] memory testCases) {
        string memory csv = vm.readFile("test/tables/rpow-apy.csv");
        string[] memory rows = vm.split(csv, "\n");
        testCases = new ApyVsrTestCase[](rows.length);
        for (uint256 i = 0; i < rows.length; i++) {
            testCases[i] = ApyVsrTestCase({
                apy: vm.parseUint(vm.split(rows[i], ",")[0]),
                vsr: vm.parseUint(vm.split(rows[i], ",")[1])
            });
        }
    }

    function table_rpow_apyVsr18Decimals(ApyVsrTestCase memory apyVsr) external view {
        uint256 deposit = 1_000_000e18;

        uint256 depositWithYieldApy = deposit * (10000 + apyVsr.apy) / 10000;
        uint256 depositWithYieldVsr = deposit * harness.rpow(apyVsr.vsr, 365 days) / 1e27;

        assertApproxEqAbs(depositWithYieldApy, depositWithYieldVsr, 150_000);  // 1.5e-13 difference maximum on 1m
    }

    function table_rpow_apyVsr6Decimals(ApyVsrTestCase memory apyVsr) external view {
        uint256 deposit = 1_000_000e6;

        uint256 depositWithYieldApy = deposit * (10000 + apyVsr.apy) / 10000;
        uint256 depositWithYieldVsr = deposit * harness.rpow(apyVsr.vsr, 365 days) / 1e27;

        assertApproxEqAbs(depositWithYieldApy, depositWithYieldVsr, 1);  // 1 unit of rounding error for 6 decimals
    }

    // Adding this test to demonstrate the upper bound values of rpow instead of failure mode testing.
    // MAX_VSR is 100% APY.
    function test_rpow_upperBoundValues() external {
        uint256 maxVsr = harness.MAX_VSR();

        // Reverts between 75 and 80 years
        vm.expectRevert();
        harness.rpow(maxVsr, 80 * 365 days);

        uint256 maxVsrChi = harness.rpow(maxVsr, 75 * 365 days);

        // 37,778,931,862,957,161,634,615,052,296,000,273,248,252,349,772,281% accrued over 75 years at 100% APY
        // without drip getting called.
        assertEq(maxVsrChi, 3.7778931862957161634615052296000273248252349772281e49);
    }

    function test_rpow_lowerBoundValues() external view {
        uint256 minVsr = 1e27;

        uint256 minVsrChi = harness.rpow(minVsr, 1000 * 365 days);

        assertEq(minVsrChi, 1e27);
    }

    function test_rpow_zeroBase() external view {
        assertEq(harness.rpow(0, 0),        1e27);
        assertEq(harness.rpow(0, 1),        0);
        assertEq(harness.rpow(0, 365 days), 0);
    }

    function test_rpow_oddExponent() external view {
        uint256 fivePctVsr = 1.000000001547125957863212448e27;

        assertEq(harness.rpow(2e27, 1), 2e27);
        assertEq(harness.rpow(2e27, 3), 8e27);
        assertEq(harness.rpow(2e27, 5), 32e27);

        assertEq(harness.rpow(fivePctVsr, 1), fivePctVsr);
    }

}
