// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TickMath} from "./TickMath.sol";
import {FullMath} from "./FullMath.sol";

/// @notice Minimal slice of the Uniswap V3 pool interface used for TWAP reads.
interface IUniswapV3PoolMinimal {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128);

    function token0() external view returns (address);

    function token1() external view returns (address);
}

/// @title UniV3OracleLib
/// @notice Port of Uniswap v3-periphery's OracleLibrary (consult + getQuoteAtTick),
///         the canonical way to read a manipulation-resistant time-weighted price.
library UniV3OracleLib {
    /// @notice Arithmetic-mean tick over the last `secondsAgo` seconds (window ends now).
    function consult(address pool, uint32 secondsAgo) internal view returns (int24 arithmeticMeanTick) {
        return consultWindow(pool, secondsAgo, 0);
    }

    /// @notice Arithmetic-mean tick over the window [secondsAgoStart, secondsAgoEnd) ago,
    ///         i.e. ending `secondsAgoEnd` in the past. Lets callers anchor the TWAP to an
    ///         arbitrary end time (e.g. a series' maturity) rather than the call time.
    function consultWindow(address pool, uint32 secondsAgoStart, uint32 secondsAgoEnd)
        internal
        view
        returns (int24 arithmeticMeanTick)
    {
        require(secondsAgoStart > secondsAgoEnd, "OL:win");
        uint32 span = secondsAgoStart - secondsAgoEnd;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgoStart;
        secondsAgos[1] = secondsAgoEnd;

        (int56[] memory tickCumulatives,) = IUniswapV3PoolMinimal(pool).observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];

        arithmeticMeanTick = int24(delta / int56(uint56(span)));
        // Always round towards negative infinity.
        if (delta < 0 && (delta % int56(uint56(span)) != 0)) arithmeticMeanTick--;
    }

    /// @notice Amount of `quoteToken` equivalent to `baseAmount` of `baseToken` at `tick`.
    function getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
