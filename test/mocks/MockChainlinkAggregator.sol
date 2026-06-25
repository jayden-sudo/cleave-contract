// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "../../src/oracle/interfaces/AggregatorV3Interface.sol";

/// @notice Minimal Chainlink aggregator mock for tests. Rounds are set explicitly; unknown rounds
///         REVERT like a real aggregator (so the adapter's try/catch successor probe is exercised).
contract MockChainlinkAggregator is AggregatorV3Interface {
    uint8 public immutable dec;
    string public desc = "MOCK / USD";

    struct Round {
        int256 answer;
        uint256 updatedAt;
        bool set;
    }

    mapping(uint80 => Round) private rounds;
    uint80 public latest;

    constructor(uint8 dec_) {
        dec = dec_;
    }

    function setRound(uint80 roundId, int256 answer, uint256 updatedAt) external {
        rounds[roundId] = Round(answer, updatedAt, true);
        if (roundId > latest) latest = roundId;
    }

    function decimals() external view returns (uint8) {
        return dec;
    }

    function description() external view returns (string memory) {
        return desc;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = rounds[_roundId];
        require(r.set, "No data present");
        return (_roundId, r.answer, r.updatedAt, r.updatedAt, _roundId);
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = rounds[latest];
        require(r.set, "No data present");
        return (latest, r.answer, r.updatedAt, r.updatedAt, latest);
    }
}
