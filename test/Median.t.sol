// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Median} from "../src/oracle/libraries/Median.sol";

contract MedianTest is Test {
    function _arr(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory x) {
        x = new uint256[](3);
        x[0] = a;
        x[1] = b;
        x[2] = c;
    }

    function test_three_returns_middle() public pure {
        assertEq(Median.calc(_arr(2500e18, 2400e18, 2600e18)), 2500e18);
        assertEq(Median.calc(_arr(2600e18, 2500e18, 2400e18)), 2500e18);
    }

    function test_outlier_is_ignored() public pure {
        // a de-pegged / manipulated pool reads wildly off; median rejects it
        assertEq(Median.calc(_arr(2500e18, 2510e18, 100e18)), 2500e18);
        assertEq(Median.calc(_arr(2500e18, 2510e18, 999999e18)), 2510e18);
    }

    function test_single() public pure {
        uint256[] memory x = new uint256[](1);
        x[0] = 1234e18;
        assertEq(Median.calc(x), 1234e18);
    }

    function test_even_is_average_of_middle_two() public pure {
        uint256[] memory x = new uint256[](4);
        x[0] = 10;
        x[1] = 40;
        x[2] = 20;
        x[3] = 30;
        assertEq(Median.calc(x), 25); // (20 + 30) / 2
    }

    function test_does_not_mutate_input() public pure {
        uint256[] memory x = _arr(30e18, 10e18, 20e18);
        Median.calc(x);
        assertEq(x[0], 30e18);
        assertEq(x[1], 10e18);
        assertEq(x[2], 20e18);
    }

    function testFuzz_three_is_true_middle(uint256 a, uint256 b, uint256 c) public pure {
        uint256 m = Median.calc(_arr(a, b, c));
        // median is >= min and <= max, and equals one of the inputs
        uint256 lo = a < b ? (a < c ? a : c) : (b < c ? b : c);
        uint256 hi = a > b ? (a > c ? a : c) : (b > c ? b : c);
        assertGe(m, lo);
        assertLe(m, hi);
        assertTrue(m == a || m == b || m == c);
    }
}
