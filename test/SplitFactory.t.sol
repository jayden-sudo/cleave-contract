// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SplitFactory} from "../src/SplitFactory.sol";
import {Series} from "../src/Series.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

contract SplitFactoryTest is Test {
    SplitFactory factory;
    MockOracle oracle;
    uint256 maturity;

    receive() external payable {}

    function setUp() public {
        factory = new SplitFactory();
        oracle = new MockOracle(2000e18);
        maturity = block.timestamp + 7 days;
    }

    function _create() internal returns (Series) {
        return factory.createSeries("ETH @ $2000", 2000e18, maturity, IPriceOracle(address(oracle)), "P", "P", "N", "N");
    }

    function test_createSeries_tracks_and_wires_tokens() public {
        Series s = _create();
        assertEq(factory.seriesCount(), 1);
        assertEq(address(factory.allSeries()[0]), address(s));
        assertEq(s.strike(), 2000e18);
        assertEq(s.P().series(), address(s), "P owned by series");
        assertEq(s.N().series(), address(s), "N owned by series");
    }

    function test_createSeriesWithMockOracle_sets_caller_as_oracle_owner() public {
        (Series s, MockOracle o) =
            factory.createSeriesWithMockOracle("ETH @ $1800", 1800e18, maturity, 1900e18, "P", "P", "N", "N");
        assertEq(o.owner(), address(this), "caller owns oracle");
        assertEq(o.price(), 1900e18);
        assertEq(address(s.oracle()), address(o));
        assertEq(factory.seriesCount(), 1);
    }

    // --- get-or-create dedupe ---

    function test_createSeries_dedupes_same_market() public {
        Series a = _create();
        Series b = _create(); // identical (strike, maturity, oracle)
        assertEq(address(a), address(b), "same market returns the same series");
        assertEq(factory.seriesCount(), 1, "no duplicate deployed");
        assertEq(
            address(factory.seriesFor(2000e18, maturity, IPriceOracle(address(oracle)))),
            address(a),
            "seriesFor resolves the canonical series"
        );
    }

    function test_createSeries_distinct_markets_are_separate() public {
        Series a = _create();
        Series byStrike =
            factory.createSeries("x", 2500e18, maturity, IPriceOracle(address(oracle)), "P", "P", "N", "N");
        Series byMaturity =
            factory.createSeries("x", 2000e18, maturity + 1 days, IPriceOracle(address(oracle)), "P", "P", "N", "N");
        MockOracle o2 = new MockOracle(2000e18);
        Series byOracle = factory.createSeries("x", 2000e18, maturity, IPriceOracle(address(o2)), "P", "P", "N", "N");

        assertEq(factory.seriesCount(), 4, "four distinct markets");
        assertTrue(address(a) != address(byStrike), "different strike => different series");
        assertTrue(address(a) != address(byMaturity), "different maturity => different series");
        assertTrue(address(a) != address(byOracle), "different oracle => different series");
    }

    function test_seriesFor_zero_before_create() public view {
        assertEq(address(factory.seriesFor(2000e18, maturity, IPriceOracle(address(oracle)))), address(0));
    }

    // --- createAndSplit ---

    function test_createAndSplit_creates_and_mints_to_caller() public {
        vm.deal(address(this), 2 ether);
        Series s = factory.createAndSplit{value: 2 ether}(
            "ETH @ $2000", 2000e18, maturity, IPriceOracle(address(oracle)), "P", "P", "N", "N"
        );
        assertEq(factory.seriesCount(), 1);
        assertEq(s.P().balanceOf(address(this)), 2 ether, "caller receives P");
        assertEq(s.N().balanceOf(address(this)), 2 ether, "caller receives N");
        assertEq(address(s).balance, 2 ether, "collateral escrowed in series");
        assertEq(s.P().balanceOf(address(factory)), 0, "factory holds no tokens");
        assertEq(s.N().balanceOf(address(factory)), 0, "factory holds no tokens");
    }

    function test_createAndSplit_routes_to_existing_market() public {
        Series first = _create();
        vm.deal(address(this), 1 ether);
        Series s = factory.createAndSplit{value: 1 ether}(
            "ETH @ $2000", 2000e18, maturity, IPriceOracle(address(oracle)), "P", "P", "N", "N"
        );
        assertEq(address(s), address(first), "adds liquidity to the existing market");
        assertEq(factory.seriesCount(), 1, "no new series deployed");
        assertEq(s.P().balanceOf(address(this)), 1 ether, "caller receives the minted halves");
    }

    // --- paginated allSeriesPaged (UF-12) ---

    function _createMany(uint256 k) internal {
        for (uint256 i = 0; i < k; i++) {
            // distinct strike => distinct market => distinct series
            factory.createSeries("x", (i + 1) * 1000e18, maturity, IPriceOracle(address(oracle)), "P", "P", "N", "N");
        }
    }

    function test_allSeriesPaged_pages_in_order() public {
        _createMany(5);
        assertEq(factory.seriesCount(), 5, "count");

        Series[] memory p0 = factory.allSeriesPaged(0, 2);
        assertEq(p0.length, 2);
        assertEq(address(p0[0]), address(factory.series(0)));
        assertEq(address(p0[1]), address(factory.series(1)));

        Series[] memory p1 = factory.allSeriesPaged(2, 2);
        assertEq(p1.length, 2);
        assertEq(address(p1[0]), address(factory.series(2)));
        assertEq(address(p1[1]), address(factory.series(3)));
    }

    function test_allSeriesPaged_clamps_and_edges() public {
        _createMany(3);
        assertEq(factory.allSeriesPaged(2, 100).length, 1, "clamped to one");
        assertEq(factory.allSeriesPaged(3, 10).length, 0, "from == length");
        assertEq(factory.allSeriesPaged(99, 10).length, 0, "from past end");
        assertEq(factory.allSeriesPaged(0, 0).length, 0, "zero limit");
    }
}
