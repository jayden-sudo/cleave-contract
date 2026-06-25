// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Series} from "../src/Series.sol";
import {SplitToken} from "../src/SplitToken.sol";
import {ISeries} from "../src/interfaces/ISeries.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {OracleAnchoredHook, IFastOracle} from "../src/amm/OracleAnchoredHook.sol";
import {CleaveZapV4} from "../src/amm/CleaveZapV4.sol";

contract TestOracle is IPriceOracle, IFastOracle {
    uint256 public p;

    function set(uint256 _p) external {
        p = _p;
    }

    function price() external view override(IFastOracle, IPriceOracle) returns (uint256) {
        return p;
    }

    function priceAt(uint256) external view override returns (uint256) {
        return p;
    }
}

contract CleaveZapV4Test is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    PoolManager manager;
    TestOracle oracle;
    Series series;
    SplitToken P;
    MockERC20 USDC;
    OracleAnchoredHook hook;
    CleaveZapV4 zap;
    Currency cP;
    Currency cUSDC;
    bool pIs0;
    PoolKey key;

    address keeper = makeAddr("keeper");
    address user = makeAddr("user");
    uint256 constant STRIKE = 1400e18;

    function setUp() public {
        vm.warp(1_000_000);
        manager = new PoolManager(address(this));
        oracle = new TestOracle();
        oracle.set(1650e18);

        // Native-ETH series; its P trades against USDC.
        series = new Series(
            "flagship", STRIKE, block.timestamp + 30 days, IPriceOracle(address(oracle)), address(0), "P", "P", "N", "N"
        );
        P = series.P();
        USDC = new MockERC20("USD Coin", "USDC", 6);
        cP = Currency.wrap(address(P));
        cUSDC = Currency.wrap(address(USDC));
        pIs0 = address(P) < address(USDC);

        // Hook for P/USDC.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(
            IPoolManager(address(manager)),
            IFastOracle(address(oracle)),
            cP,
            cUSDC,
            STRIKE,
            uint256(0.05e18),
            uint256(1 hours),
            keeper,
            address(this)
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(OracleAnchoredHook).creationCode, args);
        hook = new OracleAnchoredHook{salt: salt}(
            IPoolManager(address(manager)),
            IFastOracle(address(oracle)),
            cP,
            cUSDC,
            STRIKE,
            0.05e18,
            1 hours,
            keeper,
            address(this)
        );
        assertEq(address(hook), hookAddr);

        (Currency c0, Currency c1) = pIs0 ? (cP, cUSDC) : (cUSDC, cP);
        key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(key, SQRT_PRICE_1_1);

        // Seed the hook: get P by splitting ETH, mint USDC.
        series.split{value: 10 ether}(); // mints 10 P + 10 N to this contract
        P.transfer(address(hook), 5e18);
        USDC.mint(address(hook), 1_000_000e6);
        hook.deposit(cP, 5e18);
        hook.deposit(cUSDC, 1_000_000e6);

        vm.prank(keeper);
        hook.updateQuote(1343e18, 0.003e18);

        zap = new CleaveZapV4(IPoolManager(address(manager)), IERC20(address(USDC)));
        vm.deal(user, 100 ether);
    }

    function test_boost_sells_P_into_hook() public {
        uint256 dl = block.timestamp + 600;
        vm.prank(user);
        (uint256 nOut, uint256 quoteOut) = zap.boost{value: 1 ether}(ISeries(address(series)), key, 1338e6, dl);

        assertEq(nOut, 1e18, "user gets 1 N per ETH");
        assertEq(quoteOut, 1338_971000, "P sold at oracle - fee: $1343 * 0.997");
        assertEq(USDC.balanceOf(user), 1338_971000);
        assertEq(series.N().balanceOf(user), 1e18);
    }

    function test_yieldBuy_buys_P_from_hook() public {
        // Give the user USDC and approve the zap.
        USDC.mint(user, 2_000e6);
        uint256 dl = block.timestamp + 600;
        vm.startPrank(user);
        USDC.approve(address(zap), type(uint256).max);
        uint256 pOut = zap.yieldBuy(ISeries(address(series)), key, 1343e6, 0.99e18, dl);
        vm.stopPrank();

        // $1343 at $1343 * 1.003 -> ~0.997 P
        assertApproxEqRel(pOut, 0.997009e18, 1e15);
        assertEq(P.balanceOf(user), pOut);
    }

    function test_boost_slippage_guard() public {
        uint256 dl = block.timestamp + 600;
        vm.prank(user);
        vm.expectRevert(CleaveZapV4.Slippage.selector);
        zap.boost{value: 1 ether}(ISeries(address(series)), key, 1400e6, dl); // demand more than fair -> revert
    }
}
