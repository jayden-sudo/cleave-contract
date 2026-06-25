// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SplitFactory} from "../src/SplitFactory.sol";
import {Series} from "../src/Series.sol";
import {SplitToken} from "../src/SplitToken.sol";
import {ISeries} from "../src/interfaces/ISeries.sol";
import {CleaveZap, ISwapRouter02, IWETH9} from "../src/CleaveZap.sol";
import {UniswapV3MedianOracle} from "../src/oracle/UniswapV3MedianOracle.sol";

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IUniswapV3PoolSlot0 {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

/// @notice Boost/Yield zap against REAL mainnet Uniswap V3: deploy the median oracle,
///         a flagship series at 85% of spot, create + seed a P/USDC 1% pool at a
///         strike-anchored price, then exercise boost() and yieldBuy() end to end.
///
///   MAINNET_RPC_URL=https://… forge test --match-contract ZapForkTest -vv
contract ZapForkTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant POOL_USDC = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant POOL_USDT = 0x11b815efB8f581194ae79006d24E0d814B7697F6;
    address constant POOL_DAI = 0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8;
    address constant ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    uint24 constant FEE = 10000; // 1% tier, tick spacing 200

    address founder = makeAddr("founder");
    address bull = makeAddr("bull");
    address saver = makeAddr("saver");

    SplitFactory factory;
    Series series;
    SplitToken P;
    SplitToken N;
    CleaveZap zap;
    uint256 pUsd; // strike-anchored seed price for P, 1e18 USD

    function _ready() internal returns (bool) {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("SKIP: set MAINNET_RPC_URL to run the zap fork test");
            return false;
        }
        vm.createSelectFork(rpc);
        vm.etch(founder, "");
        vm.etch(bull, "");
        vm.etch(saver, "");
        return true;
    }

    function _setUpStack() internal {
        address[] memory pools = new address[](3);
        pools[0] = POOL_USDC;
        pools[1] = POOL_USDT;
        pools[2] = POOL_DAI;
        address[] memory quotes = new address[](3);
        quotes[0] = USDC;
        quotes[1] = USDT;
        quotes[2] = DAI;
        UniswapV3MedianOracle oracle = new UniswapV3MedianOracle(WETH, 3600, pools, quotes);

        uint256 spot = oracle.price();
        uint256 strike = ((spot * 85) / 100 / 1e18) * 1e18; // 85% of spot, whole dollars
        factory = new SplitFactory();
        series = factory.createSeries("zap", strike, block.timestamp + 28 days, oracle, "P", "P", "N", "N");
        P = series.P();
        N = series.N();
        zap = new CleaveZap(IERC20(USDC), ISwapRouter02(ROUTER02), IWETH9(WETH));

        // Strike-anchored seed price: P ~ 97% of the strike floor (discount = the yield).
        pUsd = (strike * 97) / 100;
        _seedPool();
    }

    address token0;
    address token1;
    bool pIsToken0;

    /// @dev Founder splits ETH for P inventory and seeds a concentrated P/USDC 1%
    ///      position (~-25%/+6% around fair — the spec's "moderate range below par").
    function _seedPool() internal {
        vm.deal(founder, 40 ether);
        vm.startPrank(founder);
        series.split{value: 30 ether}();

        (token0, token1) = address(P) < USDC ? (address(P), USDC) : (USDC, address(P));
        pIsToken0 = token0 == address(P);
        address pool =
            INonfungiblePositionManager(NPM).createAndInitializePoolIfNecessary(token0, token1, FEE, _initSqrtPrice());
        (int24 tickLower, int24 tickUpper) = _band(pool);
        _mintPosition(tickLower, tickUpper);
        vm.stopPrank();
    }

    function _usdcPerP() internal view returns (uint256) {
        return pUsd / 1e12; // raw USDC (6dp) per whole P (1e18 raw)
    }

    function _initSqrtPrice() internal view returns (uint160) {
        // raw price = token1 raw units per token0 raw unit, as a num/den rational
        (uint256 num, uint256 den) = pIsToken0 ? (_usdcPerP(), uint256(1e18)) : (uint256(1e18), _usdcPerP());
        return uint160(Math.sqrt((num << 192) / den));
    }

    function _band(address pool) internal view returns (int24 tickLower, int24 tickUpper) {
        (, int24 tick,,,,,) = IUniswapV3PoolSlot0(pool).slot0();
        // More room on the "P gets cheaper" side; tick direction flips with ordering.
        (int24 down, int24 up) = pIsToken0 ? (int24(2800), int24(600)) : (int24(600), int24(2800));
        tickLower = _floorTick(tick - down, 200);
        tickUpper = _floorTick(tick + up, 200);
    }

    function _mintPosition(int24 tickLower, int24 tickUpper) internal {
        uint256 pSeed = 25 ether;
        uint256 usdcSeed = (pSeed * _usdcPerP()) / 1e18;
        deal(USDC, founder, usdcSeed * 2);
        P.approve(NPM, type(uint256).max);
        IERC20(USDC).approve(NPM, type(uint256).max);
        (uint256 amount0Desired, uint256 amount1Desired) = pIsToken0 ? (pSeed, usdcSeed) : (usdcSeed, pSeed);
        INonfungiblePositionManager(NPM)
            .mint(
                INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: founder,
                deadline: block.timestamp + 600
            })
            );
    }

    /// @dev Round a tick down to a multiple of `spacing` (toward negative infinity).
    function _floorTick(int24 t, int24 spacing) internal pure returns (int24) {
        int24 q = t / spacing;
        if (t < 0 && t % spacing != 0) q -= 1;
        return q * spacing;
    }

    function _assertZapStateless() internal view {
        assertEq(address(zap).balance, 0, "zap holds ETH");
        assertEq(P.balanceOf(address(zap)), 0, "zap holds P");
        assertEq(N.balanceOf(address(zap)), 0, "zap holds N");
        assertEq(IERC20(USDC).balanceOf(address(zap)), 0, "zap holds USDC");
    }

    function test_fork_boost_and_yield_roundtrip() public {
        if (!_ready()) return;
        _setUpStack();

        // --- Boost: 2 ETH -> 2 N + ~2 * pUsd of USDC ---
        uint256 ethIn = 2 ether;
        uint256 expectQuote = (ethIn * (pUsd / 1e12)) / 1e18;
        uint256 minQuote = (expectQuote * 95) / 100; // 1% fee + price impact + buffer
        vm.deal(bull, ethIn);
        vm.prank(bull);
        (uint256 nOut, uint256 quoteOut) =
            zap.boost{value: ethIn}(ISeries(address(series)), FEE, minQuote, block.timestamp + 600);

        assertEq(nOut, ethIn, "nOut");
        assertEq(N.balanceOf(bull), ethIn, "bull N");
        assertEq(P.balanceOf(bull), 0, "bull should hold no P");
        assertEq(IERC20(USDC).balanceOf(bull), quoteOut, "bull USDC");
        assertGe(quoteOut, minQuote, "slippage floor");
        emit log_named_decimal_uint("boost: USDC out for 2 ETH", quoteOut, 6);
        _assertZapStateless();

        // --- Yield: spend USDC, receive P at a discount to the floor ---
        uint256 usdcIn = 2000e6;
        deal(USDC, saver, usdcIn);
        // expected P ~ usdcIn / pUsd; require 95% of that
        uint256 expectP = (usdcIn * 1e12 * 1e18) / pUsd;
        uint256 minP = (expectP * 95) / 100;
        vm.startPrank(saver);
        IERC20(USDC).approve(address(zap), usdcIn);
        uint256 pOut = zap.yieldBuy(ISeries(address(series)), FEE, usdcIn, minP, block.timestamp + 600);
        vm.stopPrank();

        assertEq(P.balanceOf(saver), pOut, "saver P");
        assertGe(pOut, minP, "yield slippage floor");
        emit log_named_decimal_uint("yield: P out for 2000 USDC", pOut, 18);
        _assertZapStateless();

        // The saver's P, held to maturity, redeems min(spot, strike): if spot holds,
        // value-at-floor = pOut * strike. Sanity: discount means pOut * pUsd ~ usdcIn.
        assertApproxEqRel((pOut * pUsd) / 1e18, usdcIn * 1e12, 0.05e18, "discount sanity");
    }

    function test_fork_boostFull_all_upside() public {
        if (!_ready()) return;
        _setUpStack();

        uint256 ethIn = 1 ether;
        // Each round recovers ~pUsd/spot of its ETH; 12 rounds ≈ (1 − p^13)/(1 − p) of the
        // theoretical 1/(1−p) multiple. Require at least 2.5× upside net of fees + impact.
        vm.deal(bull, ethIn);
        vm.prank(bull);
        (uint256 nOut, uint256 ethBack) = zap.boostFull{value: ethIn}(
            ISeries(address(series)), FEE, 500, 12, (ethIn * 25) / 10, block.timestamp + 600
        );

        assertEq(N.balanceOf(bull), nOut, "bull N");
        assertGe(nOut, (ethIn * 25) / 10, "should multiply upside at least 2.5x");
        assertEq(P.balanceOf(bull), 0, "no P kept");
        assertEq(IERC20(USDC).balanceOf(bull), 0, "no USDC kept - that's the point");
        assertLt(ethBack, ethIn / 4, "recycle should consume most of the stake");
        emit log_named_decimal_uint("boostFull: upside for 1 ETH", nOut, 18);
        emit log_named_decimal_uint("boostFull: ETH dust back", ethBack, 18);
        _assertZapStateless();

        // guards: zero rounds and absurd minNOut
        vm.deal(bull, 1 ether);
        vm.prank(bull);
        vm.expectRevert(CleaveZap.BadRounds.selector);
        zap.boostFull{value: 0.5 ether}(ISeries(address(series)), FEE, 500, 0, 0, block.timestamp + 600);
        vm.prank(bull);
        vm.expectRevert(CleaveZap.Slippage.selector);
        zap.boostFull{value: 0.5 ether}(ISeries(address(series)), FEE, 500, 8, 100 ether, block.timestamp + 600);
        _assertZapStateless();
    }

    function test_fork_boost_guards() public {
        if (!_ready()) return;
        _setUpStack();
        vm.deal(bull, 5 ether);

        // deadline in the past
        vm.prank(bull);
        vm.expectRevert(CleaveZap.Expired.selector);
        zap.boost{value: 1 ether}(ISeries(address(series)), FEE, 0, block.timestamp - 1);

        // zero value
        vm.prank(bull);
        vm.expectRevert(CleaveZap.ZeroAmount.selector);
        zap.boost{value: 0}(ISeries(address(series)), FEE, 0, block.timestamp + 600);

        // absurd slippage floor must revert inside the router
        vm.prank(bull);
        vm.expectRevert();
        zap.boost{value: 1 ether}(ISeries(address(series)), FEE, type(uint128).max, block.timestamp + 600);

        // ERC20-collateral series is rejected
        Series tokenSeries = factory.createSeriesWithCollateral(
            USDC, "tok", series.strike(), series.maturity(), series.oracle(), "P2", "P2", "N2", "N2"
        );
        vm.prank(bull);
        vm.expectRevert(CleaveZap.NotNativeSeries.selector);
        zap.boost{value: 1 ether}(ISeries(address(tokenSeries)), FEE, 0, block.timestamp + 600);

        // post-maturity boost reverts via Series.TradingClosed
        vm.warp(series.maturity() + 1);
        vm.prank(bull);
        vm.expectRevert(Series.TradingClosed.selector);
        zap.boost{value: 1 ether}(ISeries(address(series)), FEE, 0, block.timestamp + 600);
        _assertZapStateless();
    }
}
