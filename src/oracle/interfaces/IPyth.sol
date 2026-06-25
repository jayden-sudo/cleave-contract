// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PythStructs} from "./PythStructs.sol";

/// @notice Minimal Pyth interface, hand-vendored from `@pythnetwork/pyth-sdk-solidity` (only the
///         methods this adapter needs). Signatures match the canonical IPyth so a real Pyth
///         deployment is a drop-in. https://www.pyth.network/
interface IPyth {
    /// Fee (wei) required to submit `updateData` to `updatePriceFeeds`/`parsePriceFeedUpdates`.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

    /// Current price for `id`, reverting if it is older than `age` seconds.
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythStructs.Price memory price);

    /// Verify `updateData` (signed by Pyth) and return, for each requested id, the price whose
    /// publishTime is within [minPublishTime, maxPublishTime]. Reverts if no such update is present.
    /// Note: this accepts ANY in-window update the caller submits, so it is NOT suitable for
    /// deterministic settlement — use parsePriceFeedUpdatesUnique for that.
    function parsePriceFeedUpdates(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythStructs.PriceFeed[] memory priceFeeds);

    /// Like parsePriceFeedUpdates but returns, per id, the UNIQUE first update whose publishTime is in
    /// [minPublishTime, maxPublishTime] AND whose immediately-preceding update is strictly before
    /// minPublishTime. Reverts if no such update is present. This makes the result a deterministic
    /// function of (id, minPublishTime) — the canonical first benchmark at/after a timestamp — so it
    /// is the correct primitive for settling at a historical maturity.
    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythStructs.PriceFeed[] memory priceFeeds);
}
