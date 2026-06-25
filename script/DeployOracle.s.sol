// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {UniswapV3MedianOracle} from "../src/oracle/UniswapV3MedianOracle.sol";

/// @notice Deploys the production ETH/USD oracle: the median of three Uniswap V3
///         TWAPs (ETH priced in USDC, USDT, DAI). Point a Series at the resulting
///         address to make settlement fully trustless.
///
///         Mainnet:  forge script script/DeployOracle.s.sol \
///                     --rpc-url $MAINNET_RPC_URL --broadcast --private-key $PK
///         The script logs the live median price as an on-deploy sanity check.
contract DeployOracle is Script {
    // Ethereum mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant POOL_USDC = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // USDC/WETH 0.05%
    address constant POOL_USDT = 0x11b815efB8f581194ae79006d24E0d814B7697F6; // USDT/WETH 0.05%
    address constant POOL_DAI = 0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8; // DAI/WETH 0.30%

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint32 window = uint32(vm.envOr("TWAP_WINDOW", uint256(3600))); // default 1 hour

        address[] memory pools = new address[](3);
        pools[0] = POOL_USDC;
        pools[1] = POOL_USDT;
        pools[2] = POOL_DAI;
        address[] memory quotes = new address[](3);
        quotes[0] = USDC;
        quotes[1] = USDT;
        quotes[2] = DAI;

        vm.startBroadcast(pk);
        UniswapV3MedianOracle oracle = new UniswapV3MedianOracle(WETH, window, pools, quotes);
        vm.stopBroadcast();

        console2.log("UniswapV3MedianOracle:", address(oracle));
        console2.log("TWAP window (s):      ", window);
        console2.log("median USD/ETH (1e18):", oracle.price());
    }
}
