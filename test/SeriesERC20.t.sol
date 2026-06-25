// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Series} from "../src/Series.sol";
import {SplitFactory} from "../src/SplitFactory.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

/// A throwaway 18-decimal ERC20 standing in for any non-ETH collateral (BTC, an LST, …).
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock BTC", "mBTC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Proves the generalization is real: the SAME split/settle/redeem machinery
///         works for an arbitrary ERC20 collateral + arbitrary oracle, not just ETH.
contract SeriesERC20Test is Test {
    SplitFactory factory;
    MockERC20 token;
    MockOracle oracle;

    address alice = address(0xA11CE);
    uint256 constant STRIKE = 50_000e18; // $50k per token (BTC-like)
    uint256 maturity;

    function setUp() public {
        factory = new SplitFactory();
        token = new MockERC20();
        oracle = new MockOracle(60_000e18); // $60k spot
        maturity = block.timestamp + 30 days;
    }

    function _newSeries() internal returns (Series s) {
        s = factory.createSeriesWithCollateral(
            address(token),
            "BTC split @ $50k",
            STRIKE,
            maturity,
            IPriceOracle(address(oracle)),
            "Cleave BTC cash",
            "cBTC",
            "Cleave BTC upside",
            "uBTC"
        );
    }

    function test_factory_records_collateral() public {
        Series s = _newSeries();
        assertEq(address(s.collateralToken()), address(token));
        // dedups per (collateral, strike, maturity, oracle)
        assertEq(address(_newSeries()), address(s));
        assertEq(
            address(factory.seriesForCollateral(address(token), STRIKE, maturity, IPriceOracle(address(oracle)))),
            address(s)
        );
        // a native-ETH market with the same strike/maturity/oracle is a DISTINCT market
        assertEq(address(factory.seriesFor(STRIKE, maturity, IPriceOracle(address(oracle)))), address(0));
    }

    function test_split_mints_equal_legs_and_escrows_token() public {
        Series s = _newSeries();
        token.mint(alice, 10e18);
        vm.startPrank(alice);
        token.approve(address(s), 10e18);
        s.splitERC20(4e18);
        vm.stopPrank();

        assertEq(s.P().balanceOf(alice), 4e18);
        assertEq(s.N().balanceOf(alice), 4e18);
        assertEq(s.collateral(), 4e18);
        assertEq(token.balanceOf(alice), 6e18);
        assertEq(token.balanceOf(address(s)), 4e18);
    }

    function test_combine_returns_token() public {
        Series s = _newSeries();
        token.mint(alice, 5e18);
        vm.startPrank(alice);
        token.approve(address(s), 5e18);
        s.splitERC20(5e18);
        s.combine(2e18);
        vm.stopPrank();

        assertEq(s.P().balanceOf(alice), 3e18);
        assertEq(s.N().balanceOf(alice), 3e18);
        assertEq(token.balanceOf(alice), 2e18); // 5 - 5 + 2 back
        assertEq(s.collateral(), 3e18);
    }

    function test_settle_above_strike_pays_legs_in_token() public {
        Series s = _newSeries();
        token.mint(alice, 1e18);
        vm.startPrank(alice);
        token.approve(address(s), 1e18);
        s.splitERC20(1e18);
        vm.stopPrank();

        // settle at $60k > $50k strike: f = S/x = 50/60
        vm.warp(maturity + 1);
        s.settle();
        assertApproxEqAbs(s.f(), (STRIKE * 1e18) / 60_000e18, 1);

        // redeeming 1 P + 1 N returns the whole token (f + (1-f) == 1)
        vm.prank(alice);
        s.redeem(1e18, 1e18);
        assertApproxEqAbs(token.balanceOf(alice), 1e18, 2);
        assertEq(s.collateral(), 0);
    }

    function test_settle_below_strike_cash_leg_takes_all() public {
        Series s = _newSeries();
        token.mint(alice, 1e18);
        vm.startPrank(alice);
        token.approve(address(s), 1e18);
        s.splitERC20(1e18);
        vm.stopPrank();

        // settle BELOW strike: x=$40k < $50k -> f = min(1, S/x) = 1; cash leg holds the asset
        oracle.setPrice(40_000e18);
        vm.warp(maturity + 1);
        s.settle();
        assertEq(s.f(), 1e18);

        vm.startPrank(alice);
        s.redeem(1e18, 0); // P alone redeems the full token
        assertEq(token.balanceOf(alice), 1e18);
        // N is worthless below strike
        s.redeem(0, 1e18);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1e18);
        assertEq(s.collateral(), 0);
    }

    function test_native_split_reverts_on_token_series() public {
        Series s = _newSeries();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Series.NotNativeSeries.selector);
        s.split{value: 1 ether}();
    }
}
