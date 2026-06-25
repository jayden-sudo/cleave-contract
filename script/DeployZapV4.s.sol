// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISeries} from "../src/interfaces/ISeries.sol";
import {CleaveZapV4} from "../src/amm/CleaveZapV4.sol";

/// @notice Deploy CleaveZapV4 to the testnet and run a full Boost end-to-end through the already-
///         deployed OracleAnchoredHook pool. Proves the production flow: zap -> v4 hook -> fill.
///   PRIVATE_KEY=$PK forge script script/DeployZapV4.s.sol --rpc-url $RPC --broadcast --slow
contract DeployZapV4 is Script {
    address constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant SERIES = 0x9f1ac54BEF0DD2f6f3462EA0fa94fC62300d3a8e;
    address constant P = 0x2d2c18F63D2144161B38844dCd529124Fbb93cA2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant HOOK = 0x6634D521e5dd2591638BE6F731366866b2dEC088; // audit-fixed hook redeploy

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);

        CleaveZapV4 zap = new CleaveZapV4(IPoolManager(MANAGER), IERC20(USDC));
        (Currency c0, Currency c1) =
            P < USDC ? (Currency.wrap(P), Currency.wrap(USDC)) : (Currency.wrap(USDC), Currency.wrap(P));
        PoolKey memory key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(HOOK)});

        uint256 usdcBefore = IERC20(USDC).balanceOf(me);
        // minQuoteOut below any clamped fill on 0.5 P (max ~0.5*strike*(1-fee) ~ 665e6); the live quote
        // pays more. (Hardcoding 680e6 reverted Slippage against the $1,343 quote.)
        (uint256 nOut, uint256 quoteOut) =
            zap.boost{value: 0.5 ether}(ISeries(SERIES), key, 600e6, block.timestamp + 600);

        vm.stopBroadcast();

        console2.log("zap:", address(zap));
        console2.log("boosted 0.5 ETH -> N (1e18):", nOut);
        console2.log("            -> USDC (1e6):", quoteOut);
        console2.log("USDC delta to user:", IERC20(USDC).balanceOf(me) - usdcBefore);
        console2.log("implied $/P (1e6):", (quoteOut * 1e18) / 0.5e18);
    }
}
