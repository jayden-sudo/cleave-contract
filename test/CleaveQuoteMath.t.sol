// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CleaveQuoteMath} from "../src/amm/CleaveQuoteMath.sol";

contract CleaveQuoteMathTest is Test {
    uint256 constant WAD = 1e18;

    // --- clampGuide: model-free no-arb band (0, min(spotFast, strike)] ---

    function test_clamp_in_band_unchanged() public pure {
        // spot 1650, strike 1400 -> cap 1400; i=1000 is inside.
        assertEq(CleaveQuoteMath.clampGuide(1000e18, 1650e18, 1400e18), 1000e18);
    }

    function test_clamp_capped_by_strike() public pure {
        // i above min(spot,strike)=1400 is clamped down to 1400.
        assertEq(CleaveQuoteMath.clampGuide(1500e18, 1650e18, 1400e18), 1400e18);
    }

    function test_clamp_capped_by_spot_when_spot_below_strike() public pure {
        // spot 1300 < strike 1400 -> cap 1300.
        assertEq(CleaveQuoteMath.clampGuide(1500e18, 1300e18, 1400e18), 1300e18);
    }

    function test_clamp_floors_a_near_zero_guide() public pure {
        // A dust guide is pinned UP to the defensive floor (25% of cap = $350), not passed through,
        // so the buy side can't be swept for dust. (Audit regression for the one-sided-clamp bug.)
        assertEq(CleaveQuoteMath.clampGuide(1, 1650e18, 1400e18), 350e18);
        assertEq(CleaveQuoteMath.clampGuide(100e18, 1650e18, 1400e18), 350e18);
    }

    function test_clamp_zero_cap_returns_zero() public pure {
        // Paused spot (cap 0) -> 0, which the hook rejects with GuideZero.
        assertEq(CleaveQuoteMath.clampGuide(1000e18, 0, 1400e18), 0);
    }

    function test_clamp_deep_itm_never_exceeds_cap() public pure {
        // spot > 2*strike: the old floor term max(0, spot-strike) (N's intrinsic, not P's) exceeded the
        // cap and made clampGuide return > cap, violating P <= min(spot,strike). Now floor = cap/4 only,
        // so the result is ALWAYS <= cap. (Lean-FV regression.)
        uint256 cap = 100e18; // = min(1650, 100)
        assertLe(CleaveQuoteMath.clampGuide(50e18, 1650e18, 100e18), cap);
        assertEq(CleaveQuoteMath.clampGuide(50e18, 1650e18, 100e18), 50e18); // in [25, 100] -> i
        assertLe(CleaveQuoteMath.clampGuide(999e18, 1650e18, 100e18), cap); // huge i -> cap
    }

    // --- usdcOutForP: SELL P at i*(1-fee), 18->6 decimals ---

    function test_sellP_no_fee() public pure {
        // 1 P at $1343, no spread -> 1343 USDC (6-dec).
        assertEq(CleaveQuoteMath.usdcOutForP(1e18, 1343e18, 0), 1343e6);
    }

    function test_sellP_one_percent_fee() public pure {
        // 1 P at $1343, 1% spread -> 1329.57 USDC.
        assertEq(CleaveQuoteMath.usdcOutForP(1e18, 1343e18, 1e16), 1329_570000);
    }

    // external wrapper so vm.expectRevert sees the revert at a lower call depth (lib fn is inlined)
    function sellPExt(uint256 pIn, uint256 iWad, uint256 feeWad) external pure returns (uint256) {
        return CleaveQuoteMath.usdcOutForP(pIn, iWad, feeWad);
    }

    function test_sellP_reverts_fee_ge_one() public {
        vm.expectRevert(CleaveQuoteMath.FeeTooHigh.selector);
        this.sellPExt(1e18, 1343e18, WAD);
    }

    // --- pOutForUsdc: BUY P at i*(1+fee), 6->18 decimals ---

    function test_buyP_no_fee() public pure {
        // $1343 at $1343/P, no spread -> exactly 1 P.
        assertEq(CleaveQuoteMath.pOutForUsdc(1343e6, 1343e18, 0), 1e18);
    }

    function test_buyP_one_percent_fee_pays_more() public pure {
        // 1% spread -> slightly less than 1 P for the same USDC.
        uint256 pOut = CleaveQuoteMath.pOutForUsdc(1343e6, 1343e18, 1e16);
        assertLt(pOut, 1e18);
        assertApproxEqRel(pOut, 0.990099e18, 1e15); // ~1/1.01, within 0.1%
    }

    // --- round trip: buy then immediately sell loses ~2x the spread, never gains ---

    function testFuzz_buy_then_sell_never_profits(uint256 usdcIn, uint256 iWad, uint256 feeWad) public pure {
        usdcIn = bound(usdcIn, 1e6, 1_000_000e6); // $1 .. $1M
        iWad = bound(iWad, 1e18, 5000e18); // $1 .. $5000 per P
        feeWad = bound(feeWad, 0, 0.05e18); // 0 .. 5%
        uint256 pOut = CleaveQuoteMath.pOutForUsdc(usdcIn, iWad, feeWad);
        uint256 usdcBack = CleaveQuoteMath.usdcOutForP(pOut, iWad, feeWad);
        // A round trip can never return more USDC than went in (no value creation; spread is a cost).
        assertLe(usdcBack, usdcIn);
    }
}
