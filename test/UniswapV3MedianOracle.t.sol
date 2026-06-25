// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV3MedianOracle} from "../src/oracle/UniswapV3MedianOracle.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockToken} from "./mocks/MockToken.sol";

contract UniswapV3MedianOracleTest is Test {
    MockToken weth;
    MockToken usdc;
    MockToken usdt;
    MockToken dai;
    MockV3Pool pUSDC;
    MockV3Pool pUSDT;
    MockV3Pool pDAI;
    UniswapV3MedianOracle oracle;

    function setUp() public {
        weth = new MockToken(18);
        usdc = new MockToken(6);
        usdt = new MockToken(6);
        dai = new MockToken(18);
        pUSDC = new MockV3Pool(address(weth), address(usdc), 1000);
        pUSDT = new MockV3Pool(address(weth), address(usdt), 1100);
        pDAI = new MockV3Pool(address(weth), address(dai), 900);

        address[] memory pools = new address[](3);
        pools[0] = address(pUSDC);
        pools[1] = address(pUSDT);
        pools[2] = address(pDAI);
        address[] memory quotes = new address[](3);
        quotes[0] = address(usdc);
        quotes[1] = address(usdt);
        quotes[2] = address(dai);

        oracle = new UniswapV3MedianOracle(address(weth), 3600, pools, quotes);
    }

    function test_feedCount() public view {
        assertEq(oracle.feedCount(), 3);
    }

    function test_price_is_median_of_components() public view {
        uint256[] memory c = oracle.priceComponents();
        assertEq(c.length, 3);
        assertGt(c[0], 0);
        assertGt(c[1], 0);
        assertGt(c[2], 0);
        assertEq(oracle.price(), _median3(c[0], c[1], c[2]));
    }

    function test_median_excludes_outlier_pool() public {
        // make the DAI pool a wild outlier; median must come from the other two
        pDAI.setTick(800000);
        uint256[] memory c = oracle.priceComponents();
        uint256 p = oracle.price();
        assertEq(p, _median3(c[0], c[1], c[2]));
        assertTrue(p != c[2], "outlier (DAI feed) must not be the reported price");
    }

    function test_priceAt_now_matches_price() public view {
        assertEq(oracle.priceAt(block.timestamp), oracle.price());
    }

    function test_priceAt_anchors_to_past_window() public {
        uint256 nowPrice = oracle.price();
        vm.warp(block.timestamp + 2 days);
        // With constant-tick pools, a window anchored 1 day ago equals the earlier price.
        assertEq(oracle.priceAt(block.timestamp - 1 days), nowPrice);
    }

    function test_priceAt_future_reverts() public {
        vm.expectRevert(bytes("future"));
        oracle.priceAt(block.timestamp + 1);
    }

    function test_feedAt_reports_scale() public view {
        (, address q0, uint256 s0) = oracle.feedAt(0);
        assertEq(q0, address(usdc));
        assertEq(s0, 1e12); // 6-decimal stable normalizes by 1e12
        (,, uint256 s2) = oracle.feedAt(2);
        assertEq(s2, 1); // 18-decimal stable
    }

    function test_constructor_reverts_on_non_weth_pair() public {
        MockToken other = new MockToken(18);
        // Use 3 feeds (the new minimum) so the per-pool WETH-pair check is what reverts:
        // pools[0..1] are valid WETH pairs, pools[2] is not.
        MockV3Pool good0 = new MockV3Pool(address(weth), address(usdc), 1000);
        MockV3Pool good1 = new MockV3Pool(address(weth), address(usdt), 1000);
        MockV3Pool bad = new MockV3Pool(address(other), address(dai), 0);
        address[] memory pools = new address[](3);
        pools[0] = address(good0);
        pools[1] = address(good1);
        pools[2] = address(bad);
        address[] memory quotes = new address[](3);
        quotes[0] = address(usdc);
        quotes[1] = address(usdt);
        quotes[2] = address(dai);
        vm.expectRevert(UniswapV3MedianOracle.NotWethPair.selector);
        new UniswapV3MedianOracle(address(weth), 3600, pools, quotes);
    }

    function test_constructor_reverts_on_too_few_feeds() public {
        // A single feed is odd but defeats median resistance — now rejected (UF-9).
        MockV3Pool only = new MockV3Pool(address(weth), address(usdc), 1000);
        address[] memory pools = new address[](1);
        pools[0] = address(only);
        address[] memory quotes = new address[](1);
        quotes[0] = address(usdc);
        vm.expectRevert(UniswapV3MedianOracle.TooFewFeeds.selector);
        new UniswapV3MedianOracle(address(weth), 3600, pools, quotes);
    }

    function test_constructor_reverts_on_length_mismatch() public {
        address[] memory pools = new address[](2);
        address[] memory quotes = new address[](1);
        vm.expectRevert(UniswapV3MedianOracle.LengthMismatch.selector);
        new UniswapV3MedianOracle(address(weth), 3600, pools, quotes);
    }

    function _median3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        if ((a >= b && a <= c) || (a <= b && a >= c)) return a;
        if ((b >= a && b <= c) || (b <= a && b >= c)) return b;
        return c;
    }
}
