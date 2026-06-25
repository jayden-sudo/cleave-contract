// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Series} from "../src/Series.sol";
import {SplitToken} from "../src/SplitToken.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

contract SeriesTest is Test {
    MockOracle oracle;
    Series series;

    uint256 constant STRIKE = 1500e18; // $1,500 per ETH
    uint256 maturity;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    receive() external payable {}

    function setUp() public {
        oracle = new MockOracle(2000e18);
        maturity = block.timestamp + 30 days;
        series = new Series(
            "ETH split @ $1500", STRIKE, maturity, IPriceOracle(address(oracle)), address(0), "Cleave Stable", "sETH", "Cleave Upside", "uETH"
        );
    }

    // --- split / combine ---

    function test_split_mints_equal_legs() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        series.split{value: 1 ether}();

        assertEq(series.P().balanceOf(alice), 1 ether, "P minted");
        assertEq(series.N().balanceOf(alice), 1 ether, "N minted");
        assertEq(address(series).balance, 1 ether, "collateral held");
        assertEq(series.P().totalSupply(), 1 ether);
        assertEq(series.N().totalSupply(), 1 ether);
    }

    function test_combine_returns_eth_before_settle() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        series.split{value: 1 ether}();
        series.combine(0.4 ether);
        vm.stopPrank();

        assertEq(series.P().balanceOf(alice), 0.6 ether);
        assertEq(series.N().balanceOf(alice), 0.6 ether);
        assertEq(alice.balance, 0.4 ether, "eth back");
        assertEq(address(series).balance, 0.6 ether);
    }

    function test_split_reverts_after_maturity() public {
        vm.deal(alice, 1 ether);
        vm.warp(maturity);
        vm.prank(alice);
        vm.expectRevert(Series.TradingClosed.selector);
        series.split{value: 1 ether}();
    }

    /// @notice combine() must work AFTER maturity even when the series was never settled.
    ///         This is the escape hatch the UI's "Merge" button relies on: if the oracle
    ///         window is missed and settle() can no longer be called, a two-leg holder must
    ///         still be able to recombine P+N back into ETH 1:1. (split closes at maturity,
    ///         but combine never does.)
    function test_combine_works_after_maturity_unsettled() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        series.split{value: 1 ether}();

        // Past maturity, but nobody settled (e.g. the oracle data horizon blew past).
        vm.warp(maturity + 365 days);
        assertFalse(series.settled(), "precondition: not settled");

        vm.prank(alice);
        series.combine(1 ether);

        assertEq(alice.balance, 1 ether, "recombine returns full ETH after maturity, unsettled");
        assertEq(series.P().balanceOf(alice), 0, "P burned");
        assertEq(series.N().balanceOf(alice), 0, "N burned");
        assertEq(address(series).balance, 0, "collateral fully released");
    }

    // --- settlement math: Vitalik's worked example (strike $1500) ---

    function test_settle_example_x2500_P060_N040() public {
        _splitOneEthTo(alice);
        _settleAt(2500e18);

        assertEq(series.f(), 0.6e18, "f = S/x = 0.6");
        assertEq(series.quoteRedeem(2500e18, 1 ether, 0), 0.6 ether, "P -> 0.6 ETH");
        assertEq(series.quoteRedeem(2500e18, 0, 1 ether), 0.4 ether, "N -> 0.4 ETH");
    }

    function test_settle_example_x1500_P1_N0() public {
        _splitOneEthTo(alice);
        _settleAt(1500e18);
        assertEq(series.f(), 1e18, "f capped at 1");
        assertEq(series.quoteRedeem(1500e18, 1 ether, 0), 1 ether, "P -> 1 ETH");
        assertEq(series.quoteRedeem(1500e18, 0, 1 ether), 0, "N -> 0");
    }

    function test_settle_example_x750_P1_N0() public {
        _splitOneEthTo(alice);
        _settleAt(750e18);
        assertEq(series.f(), 1e18, "f capped at 1 below strike");
        assertEq(series.quoteRedeem(750e18, 1 ether, 0), 1 ether, "P -> full 1 ETH");
        assertEq(series.quoteRedeem(750e18, 0, 1 ether), 0, "N worthless below strike");
    }

    // --- redeem actually pays out ---

    function test_redeem_pays_each_leg() public {
        // alice holds P, bob holds N (simulate a sale by transferring N)
        _splitOneEthTo(alice);
        SplitToken n = series.N(); // cache: prank only affects the next external call
        vm.prank(alice);
        n.transfer(bob, 1 ether);

        _settleAt(3000e18); // f = 1500/3000 = 0.5

        vm.prank(alice);
        series.redeem(1 ether, 0);
        vm.prank(bob);
        series.redeem(0, 1 ether);

        assertEq(alice.balance, 0.5 ether, "P holder gets min(1,S/x)=0.5");
        assertEq(bob.balance, 0.5 ether, "N holder gets max(0,1-S/x)=0.5");
        assertLe(address(series).balance, 1, "fully drained (<=1 wei dust)");
    }

    function test_redeem_reverts_before_settle() public {
        _splitOneEthTo(alice);
        vm.prank(alice);
        vm.expectRevert(Series.NotSettled.selector);
        series.redeem(1 ether, 0);
    }

    function test_settle_reverts_before_maturity() public {
        vm.expectRevert(Series.NotMatured.selector);
        series.settle();
    }

    function test_settle_twice_reverts() public {
        _settleAt(2000e18);
        vm.expectRevert(Series.AlreadySettled.selector);
        series.settle();
    }

    function test_combine_works_after_settle() public {
        _splitOneEthTo(alice);
        _settleAt(2500e18);
        // alice still holds both legs -> can recombine 1:1 regardless of price
        vm.prank(alice);
        series.combine(1 ether);
        assertEq(alice.balance, 1 ether, "recombine returns full ETH post-settle");
    }

    function test_redeem_zero_reverts() public {
        _settleAt(2000e18);
        vm.prank(alice);
        vm.expectRevert(Series.NothingToDo.selector);
        series.redeem(0, 0);
    }

    // --- the core invariant: legs always sum to the collateral (no insolvency) ---

    function testFuzz_conservation(uint256 priceX, uint96 amount) public {
        priceX = bound(priceX, 1e18, 1_000_000e18); // $1 .. $1,000,000
        uint256 amt = uint256(amount);
        vm.assume(amt > 0);

        vm.deal(alice, amt);
        vm.prank(alice);
        series.split{value: amt}();

        _settleAt(priceX);

        uint256 pOut = series.quoteRedeem(priceX, amt, 0);
        uint256 nOut = series.quoteRedeem(priceX, 0, amt);

        // P + N must never exceed the collateral, and lose at most 1 wei to rounding.
        assertLe(pOut + nOut, amt, "never pays more than collateral");
        assertGe(pOut + nOut, amt == 0 ? 0 : amt - 1, "loses <=1 wei to rounding");

        // And the contract can actually honour both redemptions.
        vm.prank(alice);
        series.redeem(amt, amt);
        assertEq(alice.balance, pOut + nOut, "received quoted amount");
        assertLe(address(series).balance, 1, "<=1 wei dust remains");
    }

    function testFuzz_combine_is_price_independent(uint256 priceX) public {
        priceX = bound(priceX, 1e18, 1_000_000e18);
        _splitOneEthTo(alice);
        _settleAt(priceX);
        vm.prank(alice);
        series.combine(1 ether);
        assertEq(alice.balance, 1 ether, "combine always returns exactly the ETH in");
    }

    // --- helpers ---

    function _splitOneEthTo(address who) internal {
        vm.deal(who, 1 ether);
        vm.prank(who);
        series.split{value: 1 ether}();
    }

    function _settleAt(uint256 price) internal {
        oracle.setPrice(price);
        vm.warp(maturity);
        series.settle();
    }
}
