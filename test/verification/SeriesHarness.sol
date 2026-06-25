// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Series} from "../../src/Series.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @title SeriesHarness — verification harness for the symbolic specs
/// @notice Inherits the real Series unchanged (every verified code path is the
///         production bytecode) and adds two hooks that make the proofs
///         compositional:
///
///         * `forceSettle(f)` writes an ARBITRARY settlement state. The redeem
///           solvency theorem is then proven for every `f <= 1e18`, a superset
///           of everything `settle()` can ever store (which
///           `check_settle_stores_bounded_fraction` proves separately). Splitting
///           the proof this way keeps each SMT query tractable: the solver never
///           has to reason about `min(1e18, S*1e18/x)` and `amount * f / 1e18`
///           in the same query.
///
///         * `fraction(x)` exposes the internal `_fraction` so the settlement
///           math lemma can be stated directly against the real implementation.
contract SeriesHarness is Series {
    constructor(uint256 strike_, uint256 maturity_, IPriceOracle oracle_)
        Series("harness", strike_, maturity_, oracle_, address(0), "P", "P", "N", "N")
    {}

    function forceSettle(uint256 f_, uint256 price_) external {
        settled = true;
        f = f_;
        settledPrice = price_;
    }

    /// @dev Mint the two legs asymmetrically — unreachable in production (split
    ///      always mints pairs) but lets the inductive solvency step quantify
    ///      over EVERY state, including ones prior redemptions could create.
    function forceMint(address to, uint256 pAmount, uint256 nAmount) external {
        if (pAmount > 0) P.mint(to, pAmount);
        if (nAmount > 0) N.mint(to, nAmount);
    }

    function fraction(uint256 x) external view returns (uint256) {
        return _fraction(x);
    }
}
