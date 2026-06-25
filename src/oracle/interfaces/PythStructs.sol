// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Pyth data structs, hand-vendored from `@pythnetwork/pyth-sdk-solidity`
///         (the full SDK is not a dependency here). Layouts match the canonical SDK so a real
///         Pyth contract is a drop-in. See https://www.pyth.network/ and docs.pyth.network.
library PythStructs {
    /// A signed price with a confidence interval and a decimal exponent (price = price × 10**expo).
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    struct PriceFeed {
        bytes32 id;
        Price price;
        Price emaPrice;
    }
}
