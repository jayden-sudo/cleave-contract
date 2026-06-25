// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Series} from "../src/Series.sol";
import {SplitToken} from "../src/SplitToken.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

/// @notice Drives a Series through random sequences of split / combine / settle /
///         redeem and asserts it can never become insolvent.
contract SeriesHandler is Test {
    Series public series;
    SplitToken public P;
    SplitToken public N;
    uint256 public maturity;

    constructor(Series s) {
        series = s;
        P = s.P();
        N = s.N();
        maturity = s.maturity();
        vm.deal(address(this), 1_000_000 ether);
    }

    receive() external payable {}

    function doSplit(uint96 amt) public {
        if (block.timestamp >= maturity) return;
        uint256 a = bound(uint256(amt), 0, 1000 ether);
        if (a == 0 || address(this).balance < a) return;
        series.split{value: a}();
    }

    function combine(uint96 amt) public {
        uint256 maxAmt = _min(P.balanceOf(address(this)), N.balanceOf(address(this)));
        uint256 a = bound(uint256(amt), 0, maxAmt);
        if (a == 0) return;
        series.combine(a);
    }

    function settle() public {
        if (series.settled()) return;
        vm.warp(maturity + 1);
        series.settle();
    }

    function redeemP(uint96 amt) public {
        if (!series.settled()) return;
        uint256 a = bound(uint256(amt), 0, P.balanceOf(address(this)));
        if (a == 0) return;
        series.redeem(a, 0);
    }

    function redeemN(uint96 amt) public {
        if (!series.settled()) return;
        uint256 a = bound(uint256(amt), 0, N.balanceOf(address(this)));
        if (a == 0) return;
        series.redeem(0, a);
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }
}

contract SeriesInvariantTest is Test {
    MockOracle oracle;
    Series series;
    SeriesHandler handler;

    function setUp() public {
        oracle = new MockOracle(2000e18);
        series = new Series(
            "inv", 1500e18, block.timestamp + 30 days, IPriceOracle(address(oracle)), address(0), "P", "P", "N", "N"
        );
        handler = new SeriesHandler(series);

        // Only fuzz the meaningful actions.
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = SeriesHandler.doSplit.selector;
        selectors[1] = SeriesHandler.combine.selector;
        selectors[2] = SeriesHandler.settle.selector;
        selectors[3] = SeriesHandler.redeemP.selector;
        selectors[4] = SeriesHandler.redeemN.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The core safety property: the series can always pay what it owes.
    ///      Pre-settle: ETH held == P supply == N supply (1:1 backing).
    ///      Post-settle: ETH held >= P*f + N*(1-f) (every leg fully redeemable).
    function invariant_solvent() public view {
        uint256 bal = address(series).balance;
        uint256 ps = series.P().totalSupply();
        uint256 ns = series.N().totalSupply();

        if (!series.settled()) {
            assertEq(bal, ps, "pre-settle: balance != P supply");
            assertEq(bal, ns, "pre-settle: balance != N supply");
        } else {
            uint256 f = series.f();
            uint256 owed = (ps * f) / 1e18 + (ns * (1e18 - f)) / 1e18;
            assertGe(bal, owed, "post-settle: insolvent");
        }
    }
}
