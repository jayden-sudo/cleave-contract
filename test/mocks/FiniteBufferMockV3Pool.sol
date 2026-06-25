// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A Uniswap V3 pool mock that, unlike `MockV3Pool`, models a FINITE observation
///         buffer: it can only serve observations within the last `maxAge` seconds and
///         reverts "OLD" (exactly as real V3 `observe`/`observeSingle` does) for anything
///         older. This is the rolling horizon an actively-written pool of bounded
///         cardinality actually exposes — old observations get overwritten, so the
///         servable window walks forward with the chain.
///
///         Used to regression-test UF-4: a maturity-anchored TWAP read whose target window
///         ages out of the buffer makes `settle()` revert permanently.
contract FiniteBufferMockV3Pool {
    address public token0;
    address public token1;
    int24 public tick;
    /// @notice Oldest observation age the pool can serve, in seconds. observe() reverts
    ///         "OLD" for any secondsAgo strictly greater than this.
    uint32 public maxAge;

    constructor(address t0, address t1, int24 tick_, uint32 maxAge_) {
        token0 = t0;
        token1 = t1;
        tick = tick_;
        maxAge = maxAge_;
    }

    function setTick(int24 t) external {
        tick = t;
    }

    function setMaxAge(uint32 a) external {
        maxAge = a;
    }

    /// @dev Constant-tick cumulatives (same convention as MockV3Pool) for in-buffer reads;
    ///      a request older than the buffer reverts "OLD", matching real Uniswap V3.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128)
    {
        uint256 n = secondsAgos.length;
        tickCumulatives = new int56[](n);
        secondsPerLiquidityCumulativeX128 = new uint160[](n);
        int56 base = 100_000_000;
        for (uint256 i = 0; i < n; i++) {
            require(secondsAgos[i] <= maxAge, "OLD");
            tickCumulatives[i] = int56(tick) * (base - int56(uint56(secondsAgos[i])));
        }
    }
}
