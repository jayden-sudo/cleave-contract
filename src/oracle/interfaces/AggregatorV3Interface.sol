// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Chainlink AggregatorV3Interface, hand-vendored. The full `@chainlink/contracts`
///         package is not a dependency of this repo; we only need these read methods and vendoring
///         the canonical signatures avoids pulling the whole package. Signatures match Chainlink's
///         AggregatorV3Interface exactly so any real feed/proxy is a drop-in.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
