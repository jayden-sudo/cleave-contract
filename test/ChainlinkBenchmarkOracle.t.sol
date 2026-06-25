// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Series} from "../src/Series.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ChainlinkBenchmarkOracle} from "../src/oracle/ChainlinkBenchmarkOracle.sol";
import {AggregatorV3Interface} from "../src/oracle/interfaces/AggregatorV3Interface.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

contract ChainlinkBenchmarkOracleTest is Test {
    uint8 constant DEC = 8; // Chainlink USD feeds are 8 decimals
    uint256 constant MAX_STALENESS = 1 days;
    uint256 constant SUCCESSOR_GRACE = 3 days;

    MockChainlinkAggregator feed;
    ChainlinkBenchmarkOracle oracle;

    uint256 maturity;
    address alice = address(0xA11CE);

    function setUp() public {
        vm.warp(1_000_000);
        feed = new MockChainlinkAggregator(DEC);
        oracle = new ChainlinkBenchmarkOracle(AggregatorV3Interface(address(feed)), MAX_STALENESS, SUCCESSOR_GRACE);
        maturity = block.timestamp + 30 days;
    }

    function _usd(uint256 dollars) internal pure returns (int256) {
        return int256(dollars * (10 ** DEC)); // feed-decimals answer for $`dollars`
    }

    // Chainlink (phase<<64)|aggregatorRound packed id.
    function _packed(uint16 phase, uint64 agg) internal pure returns (uint80) {
        return uint80((uint256(phase) << 64) | agg);
    }

    // --- price() (live) ---

    function test_price_returns_scaled_latest() public {
        feed.setRound(5, _usd(2000), block.timestamp);
        assertEq(oracle.price(), 2000e18, "price scales 8->18 decimals");
    }

    function test_price_reverts_when_stale() public {
        feed.setRound(5, _usd(2000), block.timestamp);
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        vm.expectRevert(ChainlinkBenchmarkOracle.StalePrice.selector);
        oracle.price();
    }

    function test_price_reverts_on_nonpositive() public {
        feed.setRound(5, int256(0), block.timestamp);
        vm.expectRevert(ChainlinkBenchmarkOracle.NonPositivePrice.selector);
        oracle.price();
    }

    // --- pin() / priceAt() ---

    function test_priceAt_reverts_before_pin() public {
        vm.expectRevert(ChainlinkBenchmarkOracle.NotPinned.selector);
        oracle.priceAt(maturity);
    }

    function test_pin_then_priceAt() public {
        feed.setRound(10, _usd(1800), maturity - 100); // last round at/before maturity
        feed.setRound(11, _usd(1850), maturity + 100); // immediate successor after maturity
        vm.warp(maturity + 1 hours);

        uint256 px = oracle.pin(maturity, 10, 11);
        assertEq(px, 1800e18, "pins the at-maturity round price");
        assertEq(oracle.priceAt(maturity), 1800e18, "priceAt returns the pinned value");
        assertEq(oracle.pinned(maturity), 1800e18);
    }

    function test_pin_reverts_future_maturity() public {
        feed.setRound(10, _usd(1800), block.timestamp);
        vm.expectRevert(ChainlinkBenchmarkOracle.FutureTimestamp.selector);
        oracle.pin(block.timestamp + 1, 10, 11);
    }

    function test_pin_double_reverts() public {
        feed.setRound(10, _usd(1800), maturity - 100);
        feed.setRound(11, _usd(1850), maturity + 100);
        vm.warp(maturity + 1 hours);
        oracle.pin(maturity, 10, 11);
        vm.expectRevert(ChainlinkBenchmarkOracle.AlreadyPinned.selector);
        oracle.pin(maturity, 10, 11);
    }

    function test_pin_reverts_round_after_maturity() public {
        feed.setRound(10, _usd(1800), maturity + 50); // round is AFTER maturity
        feed.setRound(11, _usd(1850), maturity + 100);
        vm.warp(maturity + 1 hours);
        vm.expectRevert(ChainlinkBenchmarkOracle.RoundAfterMaturity.selector);
        oracle.pin(maturity, 10, 11);
    }

    function test_pin_reverts_when_successor_not_after_maturity() public {
        feed.setRound(10, _usd(1800), maturity - 200);
        feed.setRound(11, _usd(1850), maturity - 100); // successor still <= maturity
        feed.setRound(12, _usd(1900), maturity + 100);
        vm.warp(maturity + 1 hours);
        vm.expectRevert(ChainlinkBenchmarkOracle.SuccessorNotAfterMaturity.selector);
        oracle.pin(maturity, 10, 11); // 10 is not the LAST round before maturity (12 is)
    }

    function test_pin_reverts_when_successor_round_missing() public {
        feed.setRound(10, _usd(1800), maturity - 100); // no round 11 exists yet
        vm.warp(maturity + 1 hours);
        vm.expectRevert(ChainlinkBenchmarkOracle.RoundNotFound.selector);
        oracle.pin(maturity, 10, 11);
    }

    /// A griefer cannot pin an earlier (favorable) round by supplying a far-future "successor" that
    /// skips intervening at/before-maturity rounds — adjacency is enforced.
    function test_pin_reverts_when_successor_not_immediate() public {
        feed.setRound(10, _usd(1700), maturity - 300);
        feed.setRound(11, _usd(1750), maturity - 200);
        feed.setRound(12, _usd(1800), maturity - 100); // the true last round at/before maturity
        feed.setRound(13, _usd(1850), maturity + 100);
        vm.warp(maturity + 1 hours);
        // Try to pin round 10 using 13 as a fake "successor", skipping 11 and 12.
        vm.expectRevert(ChainlinkBenchmarkOracle.NotImmediateSuccessor.selector);
        oracle.pin(maturity, 10, 13);
        // Only the genuine bracket (12, 13) works, and it pins the correct $1800.
        assertEq(oracle.pin(maturity, 12, 13), 1800e18);
    }

    /// A maturity that lands across a Chainlink aggregator phase migration can still be pinned: the
    /// successor is the first round of the next phase, not roundId+1.
    function test_pin_across_phase_boundary() public {
        uint80 lastOfPhase1 = _packed(1, 5);
        uint80 firstOfPhase2 = _packed(2, 1);
        feed.setRound(lastOfPhase1, _usd(1800), maturity - 100);
        feed.setRound(firstOfPhase2, _usd(1850), maturity + 100);
        vm.warp(maturity + 1 hours);

        uint256 px = oracle.pin(maturity, lastOfPhase1, firstOfPhase2);
        assertEq(px, 1800e18, "pins across the phase boundary");
        assertEq(oracle.priceAt(maturity), 1800e18);
    }

    // --- pinSilent() (deprecated/paused feed fallback) ---

    function test_pinSilent_finalizes_dead_feed() public {
        feed.setRound(10, _usd(1800), maturity - 100); // last round, then the feed goes silent
        vm.warp(maturity + SUCCESSOR_GRACE + 1); // silent longer than the grace
        uint256 px = oracle.pinSilent(maturity);
        assertEq(px, 1800e18, "finalizes to the last round at/before maturity");
        assertEq(oracle.priceAt(maturity), 1800e18);
    }

    function test_pinSilent_reverts_when_not_yet_silent() public {
        feed.setRound(10, _usd(1800), maturity - 100);
        vm.warp(maturity + 1 hours); // silent only ~1h, well under the 3-day grace
        vm.expectRevert(ChainlinkBenchmarkOracle.FeedNotSilent.selector);
        oracle.pinSilent(maturity);
    }

    function test_pinSilent_reverts_when_latest_after_maturity() public {
        feed.setRound(10, _usd(1800), maturity + 100); // feed produced a round AFTER maturity -> use pin()
        vm.warp(maturity + SUCCESSOR_GRACE + 1);
        vm.expectRevert(ChainlinkBenchmarkOracle.LatestNotBeforeMaturity.selector);
        oracle.pinSilent(maturity);
    }

    // --- integration: a Chainlink-priced Series settles via pin() then settle() ---

    function test_integration_pin_then_settle_then_redeem() public {
        Series series = new Series(
            "XAU benchmark", 1700e18, maturity, IPriceOracle(address(oracle)), address(0), "P", "P", "N", "N"
        );

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        series.split{value: 10 ether}();

        // settle() must fail before the price is pinned (the pinned-record contract is the point).
        vm.warp(maturity + 1 hours);
        feed.setRound(10, _usd(1800), maturity - 100);
        feed.setRound(11, _usd(1850), maturity + 100);

        vm.expectRevert(ChainlinkBenchmarkOracle.NotPinned.selector);
        series.settle();

        // Pin the at-maturity round, then settle succeeds.
        oracle.pin(maturity, 10, 11);
        series.settle();
        assertTrue(series.settled(), "settles once the Chainlink price is pinned");

        // P + N still redeems the full deposit regardless of the settled price.
        uint256 before = alice.balance;
        vm.startPrank(alice);
        series.redeem(series.P().balanceOf(alice), series.N().balanceOf(alice));
        vm.stopPrank();
        assertApproxEqAbs(alice.balance - before, 10 ether, 2, "P+N redeems ~ deposit");
    }
}
