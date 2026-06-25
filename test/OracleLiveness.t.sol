// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Series} from "../src/Series.sol";
import {UniswapV3MedianOracle} from "../src/oracle/UniswapV3MedianOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {FiniteBufferMockV3Pool} from "./mocks/FiniteBufferMockV3Pool.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// @notice Regression test for UF-4 (UltraFuzz audit, High):
///         `settle()`'s only price source is `oracle.priceAt(maturity)` with no try/catch and
///         no fallback. The maturity-anchored TWAP reads the FIXED absolute window
///         [maturity - twapWindow, maturity] as `secondsAgos = [endAgo + twapWindow, endAgo]`,
///         where `endAgo = block.timestamp - maturity` grows without bound after maturity.
///         Once that window predates the oldest observation a Uniswap V3 pool still stores,
///         `observe` reverts "OLD" — which is NOT the `BadPrice` guard — so `settle()` reverts
///         on every future call, permanently. Because `redeem()` is gated on `settled` and
///         `combine()` only helps holders of BOTH legs, anyone who sold one leg (the product's
///         entire purpose) is then frozen out of their collateral forever.
///
///         The default `MockV3Pool` models an infinite buffer and never reverts on stale
///         reads, so this path was previously untested. `FiniteBufferMockV3Pool` reverts
///         "OLD" beyond a rolling horizon, exactly as a real bounded-cardinality pool does.
contract OracleLivenessTest is Test {
    uint32 constant WINDOW = 3600; // 1h TWAP
    uint32 constant HORIZON = 1 days; // pool can only serve the last ~1 day of observations
    uint256 constant MATURITY_IN = 30 days;

    MockToken weth;
    MockToken usdc;
    MockToken usdt;
    MockToken dai;
    FiniteBufferMockV3Pool pUSDC;
    FiniteBufferMockV3Pool pUSDT;
    FiniteBufferMockV3Pool pDAI;
    UniswapV3MedianOracle oracle;
    Series series;
    uint256 maturity;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_000_000); // start well past genesis so warps are clean

        weth = new MockToken(18);
        usdc = new MockToken(6);
        usdt = new MockToken(6);
        dai = new MockToken(18);
        pUSDC = new FiniteBufferMockV3Pool(address(weth), address(usdc), 1000, HORIZON);
        pUSDT = new FiniteBufferMockV3Pool(address(weth), address(usdt), 1100, HORIZON);
        pDAI = new FiniteBufferMockV3Pool(address(weth), address(dai), 900, HORIZON);

        address[] memory pools = new address[](3);
        pools[0] = address(pUSDC);
        pools[1] = address(pUSDT);
        pools[2] = address(pDAI);
        address[] memory quotes = new address[](3);
        quotes[0] = address(usdc);
        quotes[1] = address(usdt);
        quotes[2] = address(dai);

        // Constructor probes the CURRENT window [now - WINDOW, now]; WINDOW <= HORIZON so it builds.
        oracle = new UniswapV3MedianOracle(address(weth), WINDOW, pools, quotes);

        maturity = block.timestamp + MATURITY_IN;
        series = new Series(
            "ETH liveness", 1500e18, maturity, IPriceOracle(address(oracle)), address(0), "P", "P", "N", "N"
        );

        vm.deal(alice, 100 ether);
    }

    /// Positive control: while the maturity-anchored window still sits inside the pool's
    /// horizon, settle() works and the legs redeem 1:1.
    function test_settle_succeeds_within_horizon() public {
        vm.prank(alice);
        series.split{value: 100 ether}();

        // endAgo + WINDOW = 3600 + 3600 = 7200 <= HORIZON (86400): the window is still servable.
        vm.warp(maturity + 1 hours);
        series.settle();
        assertTrue(series.settled(), "settle should succeed within the observation horizon");

        uint256 balBefore = alice.balance;
        vm.startPrank(alice);
        series.redeem(series.P().balanceOf(alice), series.N().balanceOf(alice));
        vm.stopPrank();
        // P + N always redeems exactly the deposit, independent of the settled price.
        assertApproxEqAbs(alice.balance - balBefore, 100 ether, 2, "P+N must redeem ~ deposit");
    }

    /// UF-4: warp past the observation horizon and settle() reverts "OLD" forever, freezing a
    /// holder who sold one leg.
    function test_settle_bricks_after_observation_horizon() public {
        // Alice splits and sells her P leg to Bob — she is now a single-leg (N-only) holder,
        // which is the entire point of the protocol (sell the cash leg, keep the upside).
        vm.startPrank(alice);
        series.split{value: 100 ether}();
        series.P().transfer(bob, 100 ether);
        vm.stopPrank();

        // No keeper settles in the post-maturity window; the chain advances past the buffer.
        // endAgo + WINDOW = 172800 + 3600 = 176400 > HORIZON (86400): the window is evicted.
        vm.warp(maturity + 2 days);

        // settle() reverts with the pool's "OLD", which is NOT caught by the BadPrice guard.
        vm.expectRevert(bytes("OLD"));
        series.settle();
        assertFalse(series.settled(), "settle is permanently bricked once the window ages out");

        // The N-only holder is frozen: redeem is gated on settlement...
        uint256 aliceN = series.N().balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(Series.NotSettled.selector);
        series.redeem(0, aliceN);

        // ...and combine() cannot rescue her — she no longer holds the matching P leg.
        vm.prank(alice);
        vm.expectRevert(); // SplitToken burn of P reverts: alice holds 0 P
        series.combine(aliceN);

        // Collateral is stranded in the Series with no path out for single-leg holders.
        assertEq(address(series).balance, 100 ether, "100 ETH frozen in the bricked series");
    }

    /// Boundary (upper edge): the latest settle that still works is endAgo + WINDOW == HORIZON,
    /// i.e. block.timestamp == maturity + (HORIZON - WINDOW). Confirms the failure is precisely
    /// the observation-buffer edge and nothing else.
    function test_settle_works_at_horizon_edge() public {
        vm.prank(alice);
        series.split{value: 1 ether}();

        vm.warp(maturity + (HORIZON - WINDOW)); // oldest endpoint age == HORIZON exactly
        series.settle();
        assertTrue(series.settled(), "settle works at exactly the horizon edge");
    }

    /// Boundary (one second past): a single second beyond the edge evicts the oldest endpoint
    /// and settle() reverts "OLD".
    function test_settle_reverts_one_second_past_horizon() public {
        vm.prank(alice);
        series.split{value: 1 ether}();

        vm.warp(maturity + (HORIZON - WINDOW) + 1); // oldest endpoint age == HORIZON + 1
        vm.expectRevert(bytes("OLD"));
        series.settle();
    }
}
