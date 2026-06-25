// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Simulates a Uniswap V3 pool sitting at a constant tick, so `observe`
///         returns tick cumulatives consistent with that tick. Lets us drive the
///         TWAP math with exact, known inputs.
contract MockV3Pool {
    address public token0;
    address public token1;
    int24 public tick;

    constructor(address t0, address t1, int24 tick_) {
        token0 = t0;
        token1 = t1;
        tick = tick_;
    }

    function setTick(int24 t) external {
        tick = t;
    }

    /// @dev For a constant tick `c` held since genesis, the cumulative tick at a time
    ///      `s` seconds ago is `c * (BASE - s)`. consult() takes the difference over
    ///      the window, recovering exactly `c` as the arithmetic-mean tick.
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
            tickCumulatives[i] = int56(tick) * (base - int56(uint56(secondsAgos[i])));
        }
    }
}
