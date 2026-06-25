// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPyth} from "../../src/oracle/interfaces/IPyth.sol";
import {PythStructs} from "../../src/oracle/interfaces/PythStructs.sol";

/// @notice Minimal Pyth mock for tests. `updateData[i]` is
///         `abi.encode(int64 price, uint64 conf, int32 expo, uint64 publishTime, uint64 prevPublishTime)`
///         standing in for a real signed update; the mock enforces the publish-time window like
///         parsePriceFeedUpdates, and additionally the "predecessor strictly before the window"
///         uniqueness rule like parsePriceFeedUpdatesUnique.
contract MockPyth is IPyth {
    uint256 public fee = 1;

    // Current price served by getPriceNoOlderThan.
    int64 internal curPrice;
    uint64 internal curConf;
    int32 internal curExpo;
    uint256 internal curPublish;

    function setFee(uint256 f) external {
        fee = f;
    }

    function setCurrent(int64 price, int32 expo, uint256 publishTime) external {
        curPrice = price;
        curExpo = expo;
        curPublish = publishTime;
    }

    /// Helper for tests: build one update blob.
    function encode(int64 price, uint64 conf, int32 expo, uint64 publishTime, uint64 prevPublishTime)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(price, conf, expo, publishTime, prevPublishTime);
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return fee;
    }

    function getPriceNoOlderThan(bytes32, uint256 age) external view returns (PythStructs.Price memory p) {
        require(block.timestamp - curPublish <= age, "StalePrice");
        p = PythStructs.Price(curPrice, curConf, curExpo, curPublish);
    }

    function parsePriceFeedUpdates(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythStructs.PriceFeed[] memory feeds) {
        return _parse(updateData, priceIds, minPublishTime, maxPublishTime, false);
    }

    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythStructs.PriceFeed[] memory feeds) {
        return _parse(updateData, priceIds, minPublishTime, maxPublishTime, true);
    }

    function _parse(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime,
        bool requireUnique
    ) internal view returns (PythStructs.PriceFeed[] memory feeds) {
        require(msg.value >= fee, "InsufficientFee");
        feeds = new PythStructs.PriceFeed[](priceIds.length);
        for (uint256 i = 0; i < priceIds.length; i++) {
            (int64 price, uint64 conf, int32 expo, uint64 publishTime, uint64 prevPublishTime) =
                abi.decode(updateData[i], (int64, uint64, int32, uint64, uint64));
            require(publishTime >= minPublishTime && publishTime <= maxPublishTime, "PriceFeedNotFoundWithinRange");
            // Uniqueness: the immediately-preceding update must be strictly before the window, proving
            // this is the FIRST update at/after minPublishTime — so the caller cannot pick a later one.
            if (requireUnique) require(prevPublishTime < minPublishTime, "PriceFeedNotUnique");
            PythStructs.Price memory pr = PythStructs.Price(price, conf, expo, uint256(publishTime));
            feeds[i] = PythStructs.PriceFeed(priceIds[i], pr, pr);
        }
    }
}
