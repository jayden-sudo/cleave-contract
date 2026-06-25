// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {OracleAnchoredHook, IFastOracle} from "../src/amm/OracleAnchoredHook.sol";

contract MockFastOracle is IFastOracle {
    uint256 public p;

    function set(uint256 _p) external {
        p = _p;
    }

    function price() external view returns (uint256) {
        return p;
    }
}

contract OracleAnchoredHookTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    PoolManager manager;
    PoolSwapTest swapRouter;
    MockFastOracle oracle;
    OracleAnchoredHook hook;

    MockERC20 P;
    MockERC20 USDC;
    Currency cP;
    Currency cUSDC;
    bool pIs0;
    PoolKey key;

    address keeper = makeAddr("keeper");
    address user = makeAddr("user");

    uint256 constant STRIKE = 1400e18;
    uint256 constant MAX_FEE = 0.05e18;
    uint256 constant MAX_AGE = 1 hours;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        oracle = new MockFastOracle();
        oracle.set(1650e18); // fast ETH/USD spot

        P = new MockERC20("Cleave P", "pETH", 18);
        USDC = new MockERC20("USD Coin", "USDC", 6);
        pIs0 = address(P) < address(USDC);
        (cP, cUSDC) = (Currency.wrap(address(P)), Currency.wrap(address(USDC)));

        // Mine a hook address with the BEFORE_SWAP + BEFORE_SWAP_RETURNS_DELTA flags.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(
            IPoolManager(address(manager)), oracle, cP, cUSDC, STRIKE, MAX_FEE, MAX_AGE, keeper, address(this)
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(OracleAnchoredHook).creationCode, args);
        hook = new OracleAnchoredHook{salt: salt}(
            IPoolManager(address(manager)), oracle, cP, cUSDC, STRIKE, MAX_FEE, MAX_AGE, keeper, address(this)
        );
        assertEq(address(hook), hookAddr);

        // Pool: P/USDC, static fee 0 (the hook bakes the spread into the price), with our hook.
        (Currency c0, Currency c1) = pIs0 ? (cP, cUSDC) : (cUSDC, cP);
        key = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(key, SQRT_PRICE_1_1);

        // Seed the hook's claim inventory via its own production deposit(): send real tokens to the
        // hook, then deposit mints the matching ERC-6909 claims. Then fund the user.
        P.mint(address(hook), 1_000e18);
        USDC.mint(address(hook), 2_000_000e6);
        hook.deposit(cP, 1_000e18);
        hook.deposit(cUSDC, 2_000_000e6);
        P.mint(user, 100e18);
        USDC.mint(user, 1_000_000e6);
        vm.startPrank(user);
        P.approve(address(swapRouter), type(uint256).max);
        USDC.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Keeper posts a fair quote: P at $1343, 30 bps spread.
        vm.prank(keeper);
        hook.updateQuote(1343e18, 0.003e18);
    }

    function _swap(bool sellP, uint256 amountIn) internal returns (BalanceDelta) {
        // sell P: input is P. zeroForOne = (P is token0). buy P: input USDC, opposite.
        bool zeroForOne = sellP ? pIs0 : !pIs0;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn), // exact input
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        vm.prank(user);
        return swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    function test_sellP_executes_at_oracle_minus_fee() public {
        uint256 usdcBefore = USDC.balanceOf(user);
        _swap(true, 1e18); // sell 1 P
        uint256 got = USDC.balanceOf(user) - usdcBefore;
        // 1 P * $1343 * (1 - 0.003) = 1338.971 USDC, size-independent at the oracle price.
        assertEq(got, 1338_971000);
    }

    function test_buyP_executes_at_oracle_plus_fee() public {
        uint256 pBefore = P.balanceOf(user);
        _swap(false, 1343e6); // spend $1343
        uint256 got = P.balanceOf(user) - pBefore;
        // $1343 / ($1343 * 1.003) = 0.99700... P
        assertApproxEqRel(got, 0.997009e18, 1e15);
    }

    function test_sellP_is_size_independent() public {
        // same execution price for 1 P and 50 P (no curve slippage within inventory).
        uint256 b1 = USDC.balanceOf(user);
        _swap(true, 1e18);
        uint256 px1 = (USDC.balanceOf(user) - b1) * 1e18 / 1e18; // USDC per 1 P

        uint256 b50 = USDC.balanceOf(user);
        _swap(true, 50e18);
        uint256 px50 = (USDC.balanceOf(user) - b50) * 1e18 / 50e18; // USDC per 1 P

        assertApproxEqRel(px1, px50, 1e12); // within 1e-6
    }

    function test_swap_reverts_on_stale_quote() public {
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert(); // StaleQuote bubbles through the manager/router
        _swap(true, 1e18);
    }

    function test_clamp_caps_an_overquote() public {
        // Quote P above the strike cap ($1400); the clamp pins it to min(spot, strike). (1670 is within
        // the per-update move bound from the $1343 setUp quote; the clamp still caps the swap at 1400.)
        oracle.set(1650e18); // spot 1650, strike 1400 -> cap 1400
        vm.prank(keeper);
        hook.updateQuote(1670e18, 0);
        uint256 usdcBefore = USDC.balanceOf(user);
        _swap(true, 1e18);
        uint256 got = USDC.balanceOf(user) - usdcBefore;
        assertEq(got, 1400e6); // clamped to $1400
    }

    // --- audit regressions: pool-pair check, quote move-bound, zero guards ---

    /// CRITICAL regression: a rogue pool reusing this hook with a worthless token opposite USDC must
    /// not be able to drain the hook's global claim inventory — beforeSwap reverts WrongPool.
    function test_rogue_pool_cannot_swap() public {
        MockERC20 ATK = new MockERC20("Attack", "ATK", 18);
        (Currency rc0, Currency rc1) =
            address(ATK) < address(USDC) ? (Currency.wrap(address(ATK)), cUSDC) : (cUSDC, Currency.wrap(address(ATK)));
        PoolKey memory rogue =
            PoolKey({currency0: rc0, currency1: rc1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(rogue, SQRT_PRICE_1_1);
        ATK.mint(user, 1e18);
        bool zfo = address(ATK) < address(USDC);
        vm.startPrank(user);
        ATK.approve(address(swapRouter), type(uint256).max);
        vm.expectRevert();
        swapRouter.swap(
            rogue,
            IPoolManager.SwapParams({
                zeroForOne: zfo,
                amountSpecified: -1e8,
                sqrtPriceLimitX96: zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function test_updateQuote_rejects_zero() public {
        vm.prank(keeper);
        vm.expectRevert(OracleAnchoredHook.GuideZero.selector);
        hook.updateQuote(0, 0);
    }

    function test_updateQuote_bounds_the_move() public {
        vm.startPrank(keeper);
        vm.expectRevert(OracleAnchoredHook.QuoteMoveTooLarge.selector);
        hook.updateQuote(2000e18, 0); // +49% from $1343 > 25% cap
        vm.expectRevert(OracleAnchoredHook.QuoteMoveTooLarge.selector);
        hook.updateQuote(1e18, 0); // slam to dust > 25% down
        hook.updateQuote(1600e18, 0); // +19% within bound -> ok
        vm.stopPrank();
    }

    function test_swap_rejects_dust_zero_output() public {
        // A P input small enough that usdcOutForP truncates to 0 must revert, not take() for nothing.
        vm.expectRevert();
        _swap(true, 5e8);
    }

    function test_swap_reverts_on_insufficient_inventory() public {
        // Drain the hook's USDC claim inventory, then a sell-P (which pays USDC) must revert.
        uint256 usdcClaims = manager.balanceOf(address(hook), cUSDC.toId());
        hook.withdraw(cUSDC, usdcClaims, address(this));
        vm.expectRevert();
        _swap(true, 1e18);
    }
}
