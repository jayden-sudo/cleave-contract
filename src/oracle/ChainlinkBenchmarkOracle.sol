// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ChainlinkBenchmarkOracle
/// @notice Tier-B `IPriceOracle` for Cleave: prices any asset that has a Chainlink USD feed
///         (gold, metals, equities, non-ETH majors), so Cleave can list "any underlying."
///
///         Chainlink, unlike the Uniswap median oracle, has no clean on-chain "price as of an
///         exact past second" read. So this adapter uses the **pinned-record** settlement pattern:
///         after maturity, anyone calls `pin(maturity, roundId, successorRoundId)` with the
///         Chainlink round that was current at maturity (`roundId`) and its immediate successor
///         (`successorRoundId`). The contract VALIDATES the bracket on-chain — `roundId.updatedAt`
///         is at/before maturity, `successorRoundId` is the *immediate* next round and its
///         `updatedAt` is strictly after maturity — so the pinned price is UNIQUELY determined by
///         maturity (not caller-chosen) and trust-minimized (the caller only points at data the
///         feed already signed). Once pinned the settlement price is final and `priceAt(maturity)`
///         returns it, so `Series.settle()` requires a prior `pin()` for a Chainlink-priced series.
///
///         The successor is supplied EXPLICITLY rather than assumed to be `roundId + 1`. Chainlink
///         round ids are phase-packed `(phaseId << 64) | aggregatorRound`, and the aggregator can
///         migrate (a "phase bump") at an unpredictable time. The true successor across a phase
///         boundary is the first round of the next phase, NOT `roundId + 1`; assuming `roundId + 1`
///         would make a maturity that lands in a phase gap impossible to pin, permanently freezing
///         single-leg holders. Adjacency is validated for both the same-phase and cross-phase case.
///
///         `pinSilent()` is a fallback for a feed that is DEPRECATED/PAUSED at or before maturity
///         and therefore never produces the strictly-later successor `pin()` needs: after a long
///         `successorGrace` of silence, the feed's last round at/before maturity is final.
///
/// @dev    Output is USD per 1 unit of the priced asset, 1e18-scaled, matching IPriceOracle.
contract ChainlinkBenchmarkOracle is IPriceOracle {
    using SafeCast for int256;

    uint256 private constant PHASE_SHIFT = 64;

    AggregatorV3Interface public immutable feed;
    uint256 public immutable scale; // 10**(18 - feedDecimals): normalizes the answer to 1e18
    uint256 public immutable maxStaleness; // max age (s) for the live price() read
    uint256 public immutable successorGrace; // silence (s) before pinSilent() may finalize a dead feed

    /// endTimestamp (series maturity) => final settled price (1e18). 0 = not yet pinned.
    mapping(uint256 => uint256) public pinned;

    error FeedDecimalsTooLarge();
    error MaxStalenessZero();
    error SuccessorGraceZero();
    error FutureTimestamp();
    error AlreadyPinned();
    error RoundNotFound();
    error NonPositivePrice();
    error RoundAfterMaturity();
    error NotImmediateSuccessor();
    error SuccessorNotAfterMaturity();
    error LatestNotBeforeMaturity();
    error FeedNotSilent();
    error NotPinned();
    error StalePrice();

    event Pinned(uint256 indexed endTimestamp, uint80 indexed roundId, uint256 price);

    /// @param feed_           Chainlink USD aggregator (proxy) for the priced asset, e.g. XAU/USD.
    /// @param maxStaleness_   Max age in seconds the live `price()` read will accept before reverting.
    /// @param successorGrace_ Seconds of feed silence after which `pinSilent()` may finalize a dead
    ///                        feed. MUST be set well above the feed's heartbeat so a normal lull
    ///                        cannot trip it while the feed is alive (e.g. >= 3 days).
    constructor(AggregatorV3Interface feed_, uint256 maxStaleness_, uint256 successorGrace_) {
        uint8 d = feed_.decimals();
        if (d > 18) revert FeedDecimalsTooLarge();
        if (maxStaleness_ == 0) revert MaxStalenessZero();
        if (successorGrace_ == 0) revert SuccessorGraceZero();
        feed = feed_;
        scale = 10 ** (18 - d);
        maxStaleness = maxStaleness_;
        successorGrace = successorGrace_;
    }

    function _to1e18(int256 answer) internal view returns (uint256) {
        if (answer <= 0) revert NonPositivePrice();
        return answer.toUint256() * scale; // checked: reverts if negative (already guarded above)
    }

    /// @dev Chainlink (phase<<64)|aggregatorRound id decode, via masking on the widened value (no
    ///      truncating casts). Returns the phase id / the in-phase aggregator round, as uint256.
    function _phase(uint80 id) private pure returns (uint256) {
        return uint256(id) >> PHASE_SHIFT;
    }

    function _agg(uint80 id) private pure returns (uint256) {
        return uint256(id) & type(uint64).max;
    }

    /// @dev Reads a round, treating BOTH a revert and a zero `updatedAt` — the two ways a real
    ///      aggregator signals "no such round" — uniformly as RoundNotFound.
    function _readRound(uint80 roundId) private view returns (int256 answer, uint256 updatedAt) {
        try feed.getRoundData(roundId) returns (uint80, int256 a, uint256, uint256 ua, uint80) {
            if (ua == 0) revert RoundNotFound();
            return (a, ua);
        } catch {
            revert RoundNotFound();
        }
    }

    /// @dev True iff `successor` is the IMMEDIATE next round id after `roundId`, accounting for
    ///      Chainlink's (phase<<64)|aggregatorRound packing. Same phase: successor == roundId+1.
    ///      Across a phase bump: successor is the first round (agg index 1) of phase+1 AND roundId is
    ///      the last round of its phase (its same-phase +1 round does not exist). This prevents a
    ///      caller from skipping an intervening at/before-maturity round to pin an earlier price.
    function _isImmediateSuccessor(uint80 roundId, uint80 successor) private view returns (bool) {
        if (successor <= roundId) return false;
        if (successor == roundId + 1) return true; // same-phase consecutive
        // Cross-phase: successor must be the first round (agg index 1) of phase+1.
        if (_phase(successor) != _phase(roundId) + 1 || _agg(successor) != 1) return false;
        // roundId must be the LAST round of its phase: its same-phase +1 must not exist.
        try feed.getRoundData(roundId + 1) returns (uint80, int256, uint256, uint256 ua, uint80) {
            return ua == 0;
        } catch {
            return true;
        }
    }

    /// @inheritdoc IPriceOracle
    /// @dev Live latest price for display / pre-settlement marks; reverts if the feed is stale.
    function price() external view returns (uint256 usdPerUnit) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (updatedAt == 0) revert RoundNotFound();
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice();
        usdPerUnit = _to1e18(answer);
    }

    /// @notice Pin the final settlement price for `endTimestamp` (a series maturity) to the Chainlink
    ///         round current at maturity. Permissionless; validated on-chain; final once set.
    /// @param endTimestamp     The series maturity to settle (must be at or before now).
    /// @param roundId          The round whose `updatedAt` is the last at/before `endTimestamp`.
    /// @param successorRoundId The immediate next round after `roundId`; its `updatedAt` must be
    ///                         strictly after `endTimestamp`. (= roundId+1 within a phase, or the
    ///                         first round of the next phase across a phase migration.)
    function pin(uint256 endTimestamp, uint80 roundId, uint80 successorRoundId) external returns (uint256 usdPerUnit) {
        if (endTimestamp > block.timestamp) revert FutureTimestamp();
        if (pinned[endTimestamp] != 0) revert AlreadyPinned();

        (int256 answer, uint256 updatedAt) = _readRound(roundId);
        if (updatedAt > endTimestamp) revert RoundAfterMaturity();

        if (!_isImmediateSuccessor(roundId, successorRoundId)) revert NotImmediateSuccessor();
        (, uint256 updatedAtNext) = _readRound(successorRoundId);
        if (updatedAtNext <= endTimestamp) revert SuccessorNotAfterMaturity();

        usdPerUnit = _to1e18(answer);
        pinned[endTimestamp] = usdPerUnit;
        emit Pinned(endTimestamp, roundId, usdPerUnit);
    }

    /// @notice Fallback finalization for a DEPRECATED/PAUSED feed that stopped at or before maturity
    ///         and so will never produce the strictly-later successor `pin()` requires. Once the feed
    ///         has been silent for `successorGrace`, its latest round (which is at/before maturity, so
    ///         it is the last word) is final. Permissionless; deterministic; no settle-timing game
    ///         (the grace exceeds the heartbeat, so a live feed cannot reach this path).
    /// @param endTimestamp The series maturity to settle.
    function pinSilent(uint256 endTimestamp) external returns (uint256 usdPerUnit) {
        if (endTimestamp > block.timestamp) revert FutureTimestamp();
        if (pinned[endTimestamp] != 0) revert AlreadyPinned();

        (uint80 roundId, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (updatedAt == 0) revert RoundNotFound();
        // The latest round must be at/before maturity — proof the feed produced nothing after it.
        if (updatedAt > endTimestamp) revert LatestNotBeforeMaturity();
        // ...and must have been silent long enough to prove the feed is actually dead, not paused.
        if (block.timestamp - updatedAt <= successorGrace) revert FeedNotSilent();

        usdPerUnit = _to1e18(answer);
        pinned[endTimestamp] = usdPerUnit;
        emit Pinned(endTimestamp, roundId, usdPerUnit);
    }

    /// @inheritdoc IPriceOracle
    /// @dev Returns the pinned settlement price; reverts NotPinned until `pin()`/`pinSilent()` has run
    ///      for this maturity. This is what makes `Series.settle()` require a prior pin.
    function priceAt(uint256 endTimestamp) external view returns (uint256 usdPerUnit) {
        usdPerUnit = pinned[endTimestamp];
        if (usdPerUnit == 0) revert NotPinned();
    }
}
