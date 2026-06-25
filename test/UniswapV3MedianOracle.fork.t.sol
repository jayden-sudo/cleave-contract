// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV3MedianOracle} from "../src/oracle/UniswapV3MedianOracle.sol";

/// @notice End-to-end validation against REAL Uniswap V3 pools on Ethereum mainnet.
///         This is the strongest check that the vendored TickMath/FullMath/TWAP math
///         is correct: it must produce a believable ETH/USD price from live pools.
///
///         Runs only when a mainnet RPC is provided:
///           MAINNET_RPC_URL=https://... forge test --match-contract Fork -vv
contract UniswapV3MedianOracleForkTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6dp
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6dp
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // 18dp

    // Deepest WETH pairs
    address constant POOL_USDC = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // USDC/WETH 0.05%
    address constant POOL_USDT = 0x11b815efB8f581194ae79006d24E0d814B7697F6; // USDT/WETH 0.05%
    address constant POOL_DAI = 0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8; // DAI/WETH 0.30%

    function test_fork_median_eth_usd_is_believable() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("SKIP: set MAINNET_RPC_URL to run the mainnet-fork oracle test");
            return;
        }
        vm.createSelectFork(rpc);

        address[] memory pools = new address[](3);
        pools[0] = POOL_USDC;
        pools[1] = POOL_USDT;
        pools[2] = POOL_DAI;
        address[] memory quotes = new address[](3);
        quotes[0] = USDC;
        quotes[1] = USDT;
        quotes[2] = DAI;

        UniswapV3MedianOracle oracle = new UniswapV3MedianOracle(WETH, 3600, pools, quotes);

        uint256[] memory comps = oracle.priceComponents();
        emit log_named_decimal_uint("ETH/USDC", comps[0], 18);
        emit log_named_decimal_uint("ETH/USDT", comps[1], 18);
        emit log_named_decimal_uint("ETH/DAI ", comps[2], 18);

        // Each leg must be a sane ETH price (wide band so the test is durable over time).
        for (uint256 i = 0; i < 3; i++) {
            assertGt(comps[i], 300e18, "leg below $300");
            assertLt(comps[i], 50000e18, "leg above $50k");
        }

        uint256 p = oracle.price();
        emit log_named_decimal_uint("median  ", p, 18);
        assertGt(p, 300e18);
        assertLt(p, 50000e18);

        // The three stablecoin legs should agree closely (pegs hold) -> within 5%.
        for (uint256 i = 0; i < 3; i++) {
            assertApproxEqRel(comps[i], p, 0.05e18, "leg diverges >5% from median");
        }
    }
}
