// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface IMedianOracle {
    function feedCount() external view returns (uint256);
    function feedAt(uint256 i) external view returns (address pool, address quote, uint256 scale);
    function twapWindow() external view returns (uint32);
}

interface IUniV3PoolSlot0 {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

/// @notice Pre-launch GATE for SECURITY.md R-3 (settlement liveness). Asserts every Uniswap V3
///         pool behind the median oracle carries enough observation buffer that `settle()` can
///         still read its maturity-anchored TWAP up to MAX_SETTLE_DELAY after maturity. This is
///         the enforceable half of the "keeper + cardinality" mitigation: `GrowCardinality.s.sol`
///         grows the buffer; this script FAILS LOUDLY (non-zero exit) if any pool is still short,
///         so CI or the launch runbook can block on it instead of relying on tribal knowledge.
///         `OracleLiveness.t.sol` proves what happens when this gate is skipped: once the window
///         ages out of the buffer, `settle()` reverts "OLD" forever and single-leg holders freeze.
///
///         required cardinalityNext = (twapWindow + MAX_SETTLE_DELAY) / OBS_INTERVAL  ×  safety.
///         OBS_INTERVAL is the assumed avg seconds between a pool's recorded observations (~12s on
///         an active mainnet pool, ≈ 1 obs/block). NECESSARY, not sufficient: it assumes the pool
///         stays active enough to actually record ~1 observation per interval.
///
///   ORACLE=0x.. MAX_SETTLE_DELAY=21600 forge script script/CheckCardinality.s.sol --rpc-url $RPC
contract CheckCardinality is Script {
    function run() external view {
        IMedianOracle oracle = IMedianOracle(vm.envAddress("ORACLE"));
        uint256 maxDelay = vm.envOr("MAX_SETTLE_DELAY", uint256(6 hours));
        uint256 obsInterval = vm.envOr("OBS_INTERVAL", uint256(12));
        // Safety margin as a fraction num/den (default 3/2 = 1.5x headroom).
        uint256 safetyNum = vm.envOr("SAFETY_NUM", uint256(3));
        uint256 safetyDen = vm.envOr("SAFETY_DEN", uint256(2));

        uint32 window = oracle.twapWindow();
        uint256 span = uint256(window) + maxDelay; // history the maturity read must reach back over
        uint256 required = (span * safetyNum) / (safetyDen * obsInterval);
        require(required > 0, "required=0: check OBS_INTERVAL");
        require(required <= type(uint16).max, "required exceeds uint16 cardinality ceiling: lower MAX_SETTLE_DELAY");

        console2.log("== settlement-liveness gate (R-3) ==");
        console2.log("  twapWindow (s):       ", uint256(window));
        console2.log("  max settle delay (s): ", maxDelay);
        console2.log("  obs interval (s):     ", obsInterval);
        console2.log("  required cardinality: ", required);

        uint256 n = oracle.feedCount();
        uint256 short;
        for (uint256 i = 0; i < n; i++) {
            (address pool,,) = oracle.feedAt(i);
            // Gate on the LIVE observationCardinality (slot0 index 3), NOT observationCardinalityNext
            // (index 4). observe() can only serve as deep as the LIVE buffer; Next is merely the
            // requested target that the live value catches up to lazily (one slot per swap that
            // crosses into a new slot). Gating on Next would FALSE-PASS a freshly-grown or low-activity
            // pool whose live buffer is still tiny — the exact unsafe state this gate must catch.
            (,,, uint16 card, uint16 next,,) = IUniV3PoolSlot0(pool).slot0();
            console2.log("  pool:", pool);
            console2.log("    observationCardinality (live):", uint256(card));
            console2.log("    observationCardinalityNext:   ", uint256(next));
            if (card < required) {
                console2.log("    -> SHORT (live buffer below required)");
                short++;
            }
        }
        require(
            short == 0,
            "R-3 GATE FAILED: a pool's observation buffer is too small; run GrowCardinality.s.sol before launch"
        );
        console2.log("R-3 gate PASSED: every oracle pool has sufficient observation buffer.");
    }
}
