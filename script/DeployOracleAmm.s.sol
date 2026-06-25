// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {OracleAnchoredHook, IFastOracle} from "../src/amm/OracleAnchoredHook.sol";

interface ISeries {
    function split() external payable;
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice End-to-end deploy + smoke of the OracleAnchoredHook against the CANONICAL v4 PoolManager on
///         the Cleave testnet fork. Acquires USDC (ETH->USDC v3 swap) + P (Series.split), deploys the
///         hook at a mined address, initializes the P/USDC v4 pool, seeds the hook via deposit(), posts
///         a keeper quote, then sells P through a v4 router and prints the oracle-anchored fill.
///
///   PRIVATE_KEY=$PK forge script script/DeployOracleAmm.s.sol --rpc-url $RPC --broadcast --slow
contract DeployOracleAmm is Script {
    address constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90; // canonical v4 PoolManager
    address constant SERIES = 0x9f1ac54BEF0DD2f6f3462EA0fa94fC62300d3a8e;
    address constant P = 0x2d2c18F63D2144161B38844dCd529124Fbb93cA2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant ORACLE = 0x5FbDB2315678afecb367f032d93F642f64180aa3; // median oracle (spotFast)
    address constant SWAP_ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint24 constant WETH_USDC_FEE = 500;

    uint256 constant STRIKE = 1400e18;
    uint256 constant MAX_FEE = 0.05e18;
    uint256 constant MAX_AGE = 1 hours;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);

        _acquireTokens(me);
        OracleAnchoredHook hook = _deployHook(me);
        PoolKey memory key = _poolKey(address(hook));
        IPoolManager(MANAGER).initialize(key, SQRT_PRICE_1_1);
        _seed(hook);
        hook.updateQuote(1343e18, 0.003e18); // keeper quote: P at $1,343, 30 bps
        uint256 got = _smokeSwap(hook, key, me);

        vm.stopBroadcast();

        console2.log("hook:", address(hook));
        console2.log("sold 0.5 P -> USDC (1e6):", got);
        console2.log("implied $/P (1e6):", (got * 1e18) / 0.5e18); // expect ~1338.97e6 = $1343 * (1-0.003)
    }

    /// Acquire USDC (3 ETH -> USDC via the fork pool) and P (split 3 ETH -> 3 P + 3 N).
    function _acquireTokens(address me) internal {
        ISwapRouter02(SWAP_ROUTER02).exactInputSingle{value: 3 ether}(
            ISwapRouter02.ExactInputSingleParams(WETH, USDC, WETH_USDC_FEE, me, 3 ether, 0, 0)
        );
        ISeries(SERIES).split{value: 3 ether}();
    }

    function _deployHook(address me) internal returns (OracleAnchoredHook hook) {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(
            IPoolManager(MANAGER), IFastOracle(ORACLE), Currency.wrap(P), Currency.wrap(USDC), STRIKE, MAX_FEE, MAX_AGE, me, me
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(OracleAnchoredHook).creationCode, args);
        hook = new OracleAnchoredHook{salt: salt}(
            IPoolManager(MANAGER), IFastOracle(ORACLE), Currency.wrap(P), Currency.wrap(USDC), STRIKE, MAX_FEE, MAX_AGE, me, me
        );
        require(address(hook) == hookAddr, "hook addr mismatch");
    }

    function _poolKey(address hook) internal pure returns (PoolKey memory) {
        (Currency c0, Currency c1) =
            P < USDC ? (Currency.wrap(P), Currency.wrap(USDC)) : (Currency.wrap(USDC), Currency.wrap(P));
        return PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hook)});
    }

    /// Seed 2 P + 2,000 USDC as ERC-6909 claim inventory via deposit().
    function _seed(OracleAnchoredHook hook) internal {
        IERC20(P).transfer(address(hook), 2e18);
        IERC20(USDC).transfer(address(hook), 2_000e6);
        hook.deposit(Currency.wrap(P), 2e18);
        hook.deposit(Currency.wrap(USDC), 2_000e6);
    }

    /// Sell 0.5 P through a v4 router; return USDC received (1e6).
    function _smokeSwap(OracleAnchoredHook hook, PoolKey memory key, address me) internal returns (uint256) {
        PoolSwapTest router = new PoolSwapTest(IPoolManager(MANAGER));
        IERC20(P).approve(address(router), type(uint256).max);
        bool zeroForOne = P < USDC; // selling P
        uint256 usdcBefore = IERC20(USDC).balanceOf(me);
        router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -0.5e18,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        return IERC20(USDC).balanceOf(me) - usdcBefore;
    }
}
