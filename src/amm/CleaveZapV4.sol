// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {ISeries} from "../interfaces/ISeries.sol";

/// @title CleaveZapV4
/// @notice The v4 repoint of CleaveZap: one-click Boost / Earn on top of a Series whose cash leg (P)
///         trades against USDC on the OracleAnchoredHook's v4 pool (ORACLE_AMM_DESIGN.md). The P<->USDC
///         hop routes through the v4 PoolManager (oracle-anchored, ~size-independent fills) instead of
///         the passive v3 pool. Same shape as CleaveZap (poolFee -> PoolKey), re-deployed not migrated.
///
///         * boost     — split ETH, sell P into the hook pool, keep N + USDC. A self-financed call.
///         * yieldBuy  — buy P from the hook pool at a discount to the strike floor.
///
/// @dev    Stateless/ownerless: custodies funds only within a single tx. Native-ETH series only.
contract CleaveZapV4 is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;
    IERC20 public immutable quote; // USDC

    event Boosted(address indexed user, address indexed series, uint256 ethIn, uint256 nOut, uint256 quoteOut);
    event Yielded(address indexed user, address indexed series, uint256 quoteIn, uint256 pOut);

    error Expired();
    error ZeroAmount();
    error NotNativeSeries();
    error Slippage();
    error NotManager();

    constructor(IPoolManager manager_, IERC20 quote_) {
        require(address(manager_) != address(0) && address(quote_) != address(0), "zero address");
        manager = manager_;
        quote = quote_;
    }

    modifier notExpired(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @notice Split `msg.value` ETH into P + N, sell all P into the hook pool, send N + USDC.
    function boost(ISeries series, PoolKey calldata key, uint256 minQuoteOut, uint256 deadline)
        external
        payable
        nonReentrant
        notExpired(deadline)
        returns (uint256 nOut, uint256 quoteOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (series.collateralToken() != address(0)) revert NotNativeSeries();

        series.split{value: msg.value}();
        quoteOut = _swapExactIn(key, series.P(), msg.value);
        if (quoteOut < minQuoteOut) revert Slippage();
        quote.safeTransfer(msg.sender, quoteOut);

        nOut = msg.value;
        IERC20(series.N()).safeTransfer(msg.sender, nOut);
        emit Boosted(msg.sender, address(series), msg.value, nOut, quoteOut);
    }

    /// @notice Pull `quoteIn` USDC, buy P from the hook pool, send the P to the caller.
    function yieldBuy(ISeries series, PoolKey calldata key, uint256 quoteIn, uint256 minPOut, uint256 deadline)
        external
        nonReentrant
        notExpired(deadline)
        returns (uint256 pOut)
    {
        if (quoteIn == 0) revert ZeroAmount();

        quote.safeTransferFrom(msg.sender, address(this), quoteIn);
        pOut = _swapExactIn(key, address(quote), quoteIn);
        if (pOut < minPOut) revert Slippage();
        IERC20(series.P()).safeTransfer(msg.sender, pOut);
        emit Yielded(msg.sender, address(series), quoteIn, pOut);
    }

    /// @dev Exact-input swap of `amountIn` of `tokenIn` through the v4 pool `key`. The contract must
    ///      already hold `amountIn` of `tokenIn`; it ends holding the output.
    function _swapExactIn(PoolKey calldata key, address tokenIn, uint256 amountIn) internal returns (uint256 out) {
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        out = abi.decode(manager.unlock(abi.encode(key, zeroForOne, amountIn)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));

        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // Settle exactly what we owe (input, negative delta) and take what we're owed (output).
        uint256 out;
        if (zeroForOne) {
            key.currency0.settle(manager, address(this), uint256(int256(-delta.amount0())), false);
            out = uint256(int256(delta.amount1()));
            key.currency1.take(manager, address(this), out, false);
        } else {
            key.currency1.settle(manager, address(this), uint256(int256(-delta.amount1())), false);
            out = uint256(int256(delta.amount0()));
            key.currency0.take(manager, address(this), out, false);
        }
        return abi.encode(out);
    }
}
