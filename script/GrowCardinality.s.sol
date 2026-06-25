// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface IUniV3PoolCardinality {
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
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

/// @notice Grow the Uniswap V3 observation ring buffers behind the median oracle so the
///         maturity-anchored TWAP survives a comfortable settle delay. This is the
///         operational half of SECURITY.md R-3 (settlement liveness): a larger buffer means
///         `settle()` can be called longer after maturity before the window's observations
///         are overwritten and `settle()` becomes permanently impossible (freezing
///         single-leg holders).
///
///         The window a buffer covers ≈ cardinality × (avg seconds between the pool's
///         recorded observations). For an active pool (~1 obs/block, ~12s) a target of
///         ~2000 covers ≈ 6–7h; ~7500 covers ≈ 24h+. Pick TARGET for your worst-case
///         keeper delay PLUS the TWAP window.
///
/// @dev    `increaseObservationCardinalityNext` initializes every new slot up-front
///         (~20k gas each), so a large jump from the current value can exceed the block gas
///         limit. If a call reverts on gas, raise TARGET in steps and re-run. Permissionless
///         (anyone can grow a pool's cardinality); only costs gas.
///
///   PRIVATE_KEY=$PK TARGET=2000 forge script script/GrowCardinality.s.sol \
///     --rpc-url $MAINNET_RPC_URL --broadcast
contract GrowCardinality is Script {
    address constant POOL_USDC = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // USDC/WETH 0.05%
    address constant POOL_USDT = 0x11b815efB8f581194ae79006d24E0d814B7697F6; // USDT/WETH 0.05%
    address constant POOL_DAI = 0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8; // DAI/WETH 0.30%

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint16 target = uint16(vm.envOr("TARGET", uint256(2000)));

        address[3] memory pools = [POOL_USDC, POOL_USDT, POOL_DAI];

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < pools.length; i++) {
            (,,, uint16 card, uint16 next,,) = IUniV3PoolCardinality(pools[i]).slot0();
            console2.log("pool:", pools[i]);
            console2.log("  cardinality / next (before):", card, next);
            if (next < target) {
                IUniV3PoolCardinality(pools[i]).increaseObservationCardinalityNext(target);
                console2.log("  requested next ->", target);
            } else {
                console2.log("  already >= TARGET; skipping");
            }
        }
        vm.stopBroadcast();
    }
}
