// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal token exposing just `decimals()` — all the oracle reads from a
///         quote token. Lets tests control decimals (6 for USDC/USDT, 18 for DAI).
contract MockToken {
    uint8 public decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}
