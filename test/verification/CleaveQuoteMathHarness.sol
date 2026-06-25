// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CleaveQuoteMath} from "../../src/amm/CleaveQuoteMath.sol";

/// @title CleaveQuoteMathHarness — verification harness for the pure quote math
/// @notice `CleaveQuoteMath` is a library whose functions are `internal pure`, so
///         they cannot be called across the ABI boundary directly. This harness
///         is the thinnest possible shim: each method forwards verbatim to the
///         library, so halmos symbolically executes the PRODUCTION bytecode of
///         `clampGuide` / `usdcOutForP` / `pOutForUsdc` (no reimplementation, no
///         behavioural drift). The `external pure` wrappers also let a property
///         observe a revert as `ok == false` via a low-level `call` instead of
///         aborting the symbolic path (halmos drops reverting bodies as vacuous).
///
///         Pinned to 0.8.26 to match the library and the rest of `src/amm`.
contract CleaveQuoteMathHarness {
    function clampGuide(uint256 iWad, uint256 spotFastWad, uint256 strikeWad) external pure returns (uint256) {
        return CleaveQuoteMath.clampGuide(iWad, spotFastWad, strikeWad);
    }

    function usdcOutForP(uint256 pIn, uint256 iWad, uint256 feeWad) external pure returns (uint256) {
        return CleaveQuoteMath.usdcOutForP(pIn, iWad, feeWad);
    }

    function pOutForUsdc(uint256 usdcIn, uint256 iWad, uint256 feeWad) external pure returns (uint256) {
        return CleaveQuoteMath.pOutForUsdc(usdcIn, iWad, feeWad);
    }

    /// @dev Expose the library's WAD/floor-fraction constants so the band-shape
    ///      properties are stated against the real numbers, not magic literals.
    function WAD() external pure returns (uint256) {
        return CleaveQuoteMath.WAD;
    }

    function MIN_GUIDE_FRAC_WAD() external pure returns (uint256) {
        return CleaveQuoteMath.MIN_GUIDE_FRAC_WAD;
    }
}
