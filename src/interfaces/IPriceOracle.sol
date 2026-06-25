// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPriceOracle
/// @notice A "slow oracle" in the sense of Vitalik's options-based design: it only
///         needs to report a correct price *at or after maturity*. There is no
///         real-time price requirement and no liquidation path, so the oracle's
///         job is dramatically simpler (and safer) than in debt-based systems.
/// @dev    Price is denominated as USD per 1 ETH, scaled by 1e18.
///         e.g. an ETH price of $2,500.00 is reported as 2500e18.
interface IPriceOracle {
    /// @return usdPerEth The price of 1 ETH in USD, scaled by 1e18. Must be > 0.
    function price() external view returns (uint256 usdPerEth);

    /// @notice The price anchored to a window ENDING at `endTimestamp` — e.g. a TWAP over
    ///         [endTimestamp - window, endTimestamp]. Settlement passes the series maturity
    ///         here so the settled price is fixed by maturity and cannot be gamed by *when*
    ///         `settle()` happens to be called.
    /// @dev    `endTimestamp` must be <= block.timestamp. Oracles without a window may ignore
    ///         it and return the current price.
    /// @return usdPerEth USD per ETH, 1e18-scaled. Must be > 0.
    function priceAt(uint256 endTimestamp) external view returns (uint256 usdPerEth);
}
