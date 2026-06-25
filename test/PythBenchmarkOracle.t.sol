// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Series} from "../src/Series.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {PythBenchmarkOracle} from "../src/oracle/PythBenchmarkOracle.sol";
import {IPyth} from "../src/oracle/interfaces/IPyth.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract PythBenchmarkOracleTest is Test {
    bytes32 constant PRICE_ID = bytes32(uint256(0xABCD));
    uint256 constant MAX_STALENESS = 1 days;
    uint64 constant PIN_TOLERANCE = 1 hours;

    MockPyth pyth;
    PythBenchmarkOracle oracle;
    uint256 maturity;
    address alice = address(0xA11CE);

    receive() external payable {} // to receive pin() refunds

    function setUp() public {
        vm.warp(1_000_000);
        pyth = new MockPyth();
        oracle = new PythBenchmarkOracle(IPyth(address(pyth)), PRICE_ID, MAX_STALENESS, PIN_TOLERANCE);
        maturity = block.timestamp + 30 days;
        vm.deal(address(this), 100 ether);
    }

    // $`dollars` as a Pyth (price, expo=-8) pair.
    function _px(uint256 dollars) internal pure returns (int64) {
        return int64(uint64(dollars * 1e8));
    }

    function _update(int64 price, int32 expo, uint64 publishTime, uint64 prevPublishTime)
        internal
        pure
        returns (bytes[] memory data)
    {
        data = new bytes[](1);
        data[0] = abi.encode(price, uint64(0), expo, publishTime, prevPublishTime);
    }

    // A valid "first benchmark at/after maturity": in-window publishTime, predecessor before maturity.
    function _firstAfterMaturity(int64 price) internal view returns (bytes[] memory) {
        return _update(price, -8, uint64(maturity), uint64(maturity - 10));
    }

    // --- price() (live) ---

    function test_price_returns_scaled_current() public {
        pyth.setCurrent(_px(2000), -8, block.timestamp);
        assertEq(oracle.price(), 2000e18, "scales price*10^expo to 1e18");
    }

    function test_price_reverts_when_stale() public {
        pyth.setCurrent(_px(2000), -8, block.timestamp);
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        vm.expectRevert(bytes("StalePrice"));
        oracle.price();
    }

    // --- pin() / priceAt() ---

    function test_priceAt_reverts_before_pin() public {
        vm.expectRevert(PythBenchmarkOracle.NotPinned.selector);
        oracle.priceAt(maturity);
    }

    function test_pin_then_priceAt() public {
        vm.warp(maturity + 1 hours);
        uint256 px = oracle.pin{value: 1}(maturity, _firstAfterMaturity(_px(1800)));
        assertEq(px, 1800e18);
        assertEq(oracle.priceAt(maturity), 1800e18);
    }

    /// The settled price is the UNIQUE first update at/after maturity: a later in-window update whose
    /// predecessor is ALSO in the window (i.e. it is not the first) is rejected, so a griefer cannot
    /// cherry-pick a more favorable price from the tolerance window.
    function test_pin_cannot_cherrypick_later_update() public {
        vm.warp(maturity + 1 hours);
        bytes[] memory later = _update(_px(1800), -8, uint64(maturity + 30 minutes), uint64(maturity + 20 minutes));
        vm.expectRevert(bytes("PriceFeedNotUnique"));
        oracle.pin{value: 1}(maturity, later);
    }

    function test_pin_refunds_overpayment() public {
        vm.warp(maturity + 1 hours);
        oracle.pin{value: 5}(maturity, _firstAfterMaturity(_px(1800))); // fee is 1
        assertEq(address(oracle).balance, 0, "oracle keeps nothing");
        assertEq(address(pyth).balance, 1, "only the fee reached pyth");
    }

    function test_pin_reverts_insufficient_fee() public {
        pyth.setFee(3);
        vm.warp(maturity + 1 hours);
        vm.expectRevert(PythBenchmarkOracle.InsufficientFee.selector);
        oracle.pin{value: 2}(maturity, _firstAfterMaturity(_px(1800)));
    }

    function test_pin_reverts_publishTime_after_window() public {
        vm.warp(maturity + 3 hours);
        // publishTime maturity + 2h is past maturity + PIN_TOLERANCE (1h) -> Pyth rejects.
        bytes[] memory data = _update(_px(1800), -8, uint64(maturity + 2 hours), uint64(maturity - 10));
        vm.expectRevert(bytes("PriceFeedNotFoundWithinRange"));
        oracle.pin{value: 1}(maturity, data);
    }

    function test_pin_reverts_publishTime_before_maturity() public {
        vm.warp(maturity + 1 hours);
        bytes[] memory data = _update(_px(1800), -8, uint64(maturity - 1), uint64(maturity - 20));
        vm.expectRevert(bytes("PriceFeedNotFoundWithinRange"));
        oracle.pin{value: 1}(maturity, data);
    }

    function test_pin_reverts_future_maturity() public {
        vm.expectRevert(PythBenchmarkOracle.FutureTimestamp.selector);
        oracle.pin{value: 1}(block.timestamp + 1, _update(_px(1800), -8, uint64(block.timestamp), 0));
    }

    function test_pin_double_reverts() public {
        vm.warp(maturity + 1 hours);
        oracle.pin{value: 1}(maturity, _firstAfterMaturity(_px(1800)));
        vm.expectRevert(PythBenchmarkOracle.AlreadyPinned.selector);
        oracle.pin{value: 1}(maturity, _firstAfterMaturity(_px(1800)));
    }

    function test_pin_reverts_nonpositive_price() public {
        vm.warp(maturity + 1 hours);
        vm.expectRevert(PythBenchmarkOracle.NonPositivePrice.selector);
        oracle.pin{value: 1}(maturity, _firstAfterMaturity(int64(0)));
    }

    function test_pin_reverts_bad_exponent() public {
        vm.warp(maturity + 1 hours);
        bytes[] memory data = _update(_px(1800), -19, uint64(maturity), uint64(maturity - 10)); // expo below -18
        vm.expectRevert(PythBenchmarkOracle.BadExponent.selector);
        oracle.pin{value: 1}(maturity, data);
    }

    // --- integration: a Pyth-priced Series settles via pin() then settle() ---

    function test_integration_pin_then_settle_then_redeem() public {
        Series series = new Series(
            "SOL benchmark", 150e18, maturity, IPriceOracle(address(oracle)), address(0), "P", "P", "N", "N"
        );

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        series.split{value: 10 ether}();

        vm.warp(maturity + 1 hours);
        vm.expectRevert(PythBenchmarkOracle.NotPinned.selector);
        series.settle();

        oracle.pin{value: 1}(maturity, _firstAfterMaturity(_px(160)));
        series.settle();
        assertTrue(series.settled(), "settles once the Pyth price is pinned");

        uint256 before = alice.balance;
        vm.startPrank(alice);
        series.redeem(series.P().balanceOf(alice), series.N().balanceOf(alice));
        vm.stopPrank();
        assertApproxEqAbs(alice.balance - before, 10 ether, 2, "P+N redeems ~ deposit");
    }
}
