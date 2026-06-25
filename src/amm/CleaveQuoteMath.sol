// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CleaveQuoteMath
/// @notice Pure oracle-anchored quote math for Cleave's P/USDC venue (the OracleAnchoredHook curve).
///         The maker quotes the cash leg P at a guide price `i` (streamed by the keeper) plus/minus a
///         spread `fee`, instead of off a passive constant-product curve — so it isn't adversely
///         selected and can charge a thin fee (the proPAMM principle; see ORACLE_AMM_DESIGN.md).
///
///         Units: P is 18-decimals, USDC is 6-decimals. `iWad` is USD per 1 P, 1e18-scaled
///         ($1,343.00 => 1343e18). `feeWad` is a spread fraction, 1e18-scaled (30 bps => 3e15).
///
///         Factored out of the hook so the safety-critical pricing + decimal handling is unit-tested
///         and audited independently of the v4 take/settle plumbing.
library CleaveQuoteMath {
    uint256 internal constant WAD = 1e18;
    /// Defensive lower bound on the guide price, as a fraction of the cap. P's model-free floor is
    /// genuinely 0 (P -> 0 deep-OTM / as vol -> inf), so a near-zero guide would otherwise be swept for
    /// dust on the buy side; pin it to this fraction of the cap = min(spot, strike). 25% is always <=
    /// the cap, so the band [floor, cap] is well-formed for every input.
    uint256 internal constant MIN_GUIDE_FRAC_WAD = 0.25e18;

    error FeeTooHigh();

    /// @notice Clamp the keeper guide price into the two-sided no-arb band [floor, min(spotFast, strike)].
    /// @dev    Upper bound (cap): by split/combine parity value(P)+value(N) == spot, and N is a call
    ///         (r=0) with N >= max(0, spot-strike), so P = spot-N <= min(spot, strike). Lower bound
    ///         (floor): P's model-free floor is 0, so we use a DEFENSIVE floor = MIN_GUIDE_FRAC * cap
    ///         (25% of cap, always <= cap) so a wrong/malicious LOW guide cannot be swept for dust (the
    ///         one-sided clamp was a bug). NOTE: max(0, spot-strike) is N's intrinsic, NOT a floor for P
    ///         (using it would let the result exceed the cap when spot > 2*strike) — formally verified.
    ///         Returns 0 only when cap is 0 (paused spot), which the caller rejects.
    function clampGuide(uint256 iWad, uint256 spotFastWad, uint256 strikeWad) internal pure returns (uint256) {
        uint256 cap = spotFastWad < strikeWad ? spotFastWad : strikeWad;
        if (cap == 0) return 0;
        uint256 floor_ = Math.mulDiv(cap, MIN_GUIDE_FRAC_WAD, WAD); // 25% of cap, always <= cap
        uint256 capped = iWad < cap ? iWad : cap;
        return capped < floor_ ? floor_ : capped;
    }

    /// @notice SELL P (Boost side): `pIn` (1e18) of P in -> USDC (1e6) out, executed at i*(1-fee).
    function usdcOutForP(uint256 pIn, uint256 iWad, uint256 feeWad) internal pure returns (uint256) {
        if (feeWad >= WAD) revert FeeTooHigh();
        // USD value (1e18) of the P, less the spread, then 1e18 USD -> 1e6 USDC.
        uint256 valueUsdWad = Math.mulDiv(pIn, iWad, WAD);
        uint256 netUsdWad = Math.mulDiv(valueUsdWad, WAD - feeWad, WAD);
        return netUsdWad / 1e12;
    }

    /// @notice BUY P (Earn side): `usdcIn` (1e6) of USDC in -> P (1e18) out, executed at i*(1+fee).
    function pOutForUsdc(uint256 usdcIn, uint256 iWad, uint256 feeWad) internal pure returns (uint256) {
        uint256 valueUsdWad = usdcIn * 1e12; // 1e6 USDC -> 1e18 USD
        uint256 priceWithFee = Math.mulDiv(iWad, WAD + feeWad, WAD); // USD per P, 1e18, incl. spread
        // pOut(1e18) = valueUsd / priceWithFee  (both 1e18) * 1e18  ==  valueUsdWad * WAD / priceWithFee
        return Math.mulDiv(valueUsdWad, WAD, priceWithFee);
    }
}
