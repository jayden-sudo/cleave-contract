// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniV3OracleLib} from "../src/oracle/libraries/UniV3OracleLib.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract UniV3OracleLibTest is Test {
    address constant A = address(uint160(0xA)); // "lower" token (smaller address)
    address constant B = address(uint160(0xB)); // "higher" token (larger address)

    // --- consult: recovers the mean tick from cumulatives ---

    function test_consult_constant_positive_tick() public {
        MockV3Pool pool = new MockV3Pool(A, B, 1000);
        assertEq(UniV3OracleLib.consult(address(pool), 3600), int24(1000));
    }

    function test_consult_constant_negative_tick() public {
        MockV3Pool pool = new MockV3Pool(A, B, -50000);
        assertEq(UniV3OracleLib.consult(address(pool), 1800), int24(-50000));
    }

    function test_consult_window_independent() public {
        MockV3Pool pool = new MockV3Pool(A, B, 12345);
        assertEq(UniV3OracleLib.consult(address(pool), 60), int24(12345));
        assertEq(UniV3OracleLib.consult(address(pool), 7200), int24(12345));
    }

    function test_consultWindow_anchored() public {
        MockV3Pool pool = new MockV3Pool(A, B, 7777);
        // mean tick over [7200, 3600) ago == the constant tick
        assertEq(UniV3OracleLib.consultWindow(address(pool), 7200, 3600), int24(7777));
    }

    // --- getQuoteAtTick: tick -> price (validates TickMath + FullMath) ---

    function test_quote_at_tick_zero_is_parity() public pure {
        assertEq(UniV3OracleLib.getQuoteAtTick(0, 1e18, A, B), 1e18); // base < quote
        assertEq(UniV3OracleLib.getQuoteAtTick(0, 1e18, B, A), 1e18); // base > quote
    }

    function test_quote_at_tick_price_two() public pure {
        // 1.0001^6932 ~= 2.0  (token1/token0)
        uint256 q = UniV3OracleLib.getQuoteAtTick(6932, 1e18, A, B); // A=token0 base
        assertApproxEqRel(q, 2e18, 1e15); // within 0.1%
    }

    function test_quote_at_tick_price_half_when_base_is_higher() public pure {
        uint256 q = UniV3OracleLib.getQuoteAtTick(6932, 1e18, B, A); // base is the "1/x" side
        assertApproxEqRel(q, 0.5e18, 1e15);
    }

    function test_quote_inverse_symmetry() public pure {
        int24 tick = 45000;
        uint256 up = UniV3OracleLib.getQuoteAtTick(tick, 1e18, A, B);
        uint256 down = UniV3OracleLib.getQuoteAtTick(tick, 1e18, B, A);
        // up * down ~= 1e36  (they're reciprocals)
        assertApproxEqRel(up * down, 1e36, 1e15);
    }

    function test_quote_realistic_eth_usdc_tick() public pure {
        // A real USDC/WETH pool has USDC=token0 (lower addr, 6dp) and WETH=token1
        // (18dp), so its tick is positive (~+198000: raw WETH/raw USDC ~= 4e8).
        // Quote WETH (base) in USDC (quote): 1e18 raw WETH -> ~2.5e9 raw USDC = ~$2,500.
        uint256 raw = UniV3OracleLib.getQuoteAtTick(198000, 1e18, B, A); // base=WETH(B,"higher"), quote=USDC(A)
        assertGt(raw, 1e9); // > ~$1,000 (6dp)
        assertLt(raw, 1e10); // < ~$10,000 (6dp)
    }

    function test_quote_extreme_tick_uses_other_branch() public pure {
        // Ticks beyond ~443636 push sqrtRatioX96 above uint128.max, exercising the
        // ratioX128 branch of getQuoteAtTick. Just check it stays monotonic & sane.
        uint256 q400 = UniV3OracleLib.getQuoteAtTick(400000, 1e18, A, B); // first branch
        uint256 q500 = UniV3OracleLib.getQuoteAtTick(500000, 1e18, A, B); // ratioX128 branch
        assertGt(q500, q400);
        assertGt(q500, 1e39); // ~ e^50 * 1e18
    }
}
