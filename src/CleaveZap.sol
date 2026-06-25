// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISeries} from "./interfaces/ISeries.sol";

/// @notice Minimal subset of Uniswap V3 SwapRouter02 (deadline lives on the caller side).
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

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH9 {
    function withdraw(uint256 wad) external;
}

/// @title CleaveZap
/// @notice One-click flows on top of a Series and its P/quote Uniswap V3 pool.
///
///         * `boost`    — split ETH, sell the cash leg (P) into the pool, walk away
///                        holding the upside leg (N) plus the quote token. A self-financed
///                        call: defined-risk upside with no liquidation price.
///         * `yieldBuy` — buy P from the pool at a discount to the strike floor and hold
///                        it to maturity (or sell it back any time).
///
///         The pool is the always-on counterparty that makes both flows one transaction:
///         every boost deposits exactly the P the next yield buyer takes out.
///
/// @dev    Stateless and ownerless: the contract custodies funds only within a single
///         transaction and holds no balances between calls. It works for native-ETH
///         series only (the current flagship shape); the quote token and swap router are
///         fixed at deployment.
contract CleaveZap is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Quote token P trades against (USDC on the flagship pool).
    IERC20 public immutable quote;
    ISwapRouter02 public immutable swapRouter;
    /// @notice Wrapped native token — `boostFull` recycles quote proceeds back to ETH through it.
    IWETH9 public immutable weth;

    event Boosted(
        address indexed user, address indexed series, uint256 ethIn, uint256 nOut, uint256 quoteOut, uint24 poolFee
    );
    event BoostedFull(
        address indexed user, address indexed series, uint256 ethIn, uint256 nOut, uint256 ethBack, uint24 poolFee
    );
    event Yielded(address indexed user, address indexed series, uint256 quoteIn, uint256 pOut, uint24 poolFee);

    error Expired();
    error ZeroAmount();
    error NotNativeSeries();
    error BadRounds();
    error Slippage();
    error EthTransferFailed();

    constructor(IERC20 quote_, ISwapRouter02 swapRouter_, IWETH9 weth_) {
        require(
            address(quote_) != address(0) && address(swapRouter_) != address(0) && address(weth_) != address(0),
            "zero address"
        );
        quote = quote_;
        swapRouter = swapRouter_;
        weth = weth_;
    }

    /// @dev Only `weth.withdraw` pays this contract; anything left is swept to the caller
    ///      before the transaction ends, so the router still holds nothing between calls.
    receive() external payable {}

    modifier notExpired(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @notice Split `msg.value` ETH into P + N, sell all P into the P/quote pool, and
    ///         send the caller N plus the quote-token proceeds.
    /// @param series      The native-ETH Series to split into (must be live, pre-maturity).
    /// @param poolFee     Uniswap V3 fee tier of the P/quote pool (e.g. 10000 = 1%).
    /// @param minQuoteOut Slippage guard on the P sale, in quote-token units.
    /// @param deadline    Unix timestamp after which the call reverts.
    function boost(ISeries series, uint24 poolFee, uint256 minQuoteOut, uint256 deadline)
        external
        payable
        nonReentrant
        notExpired(deadline)
        returns (uint256 nOut, uint256 quoteOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (series.collateralToken() != address(0)) revert NotNativeSeries();

        // Mints msg.value of P and N to this contract; reverts at/after maturity.
        series.split{value: msg.value}();

        IERC20 p = IERC20(series.P());
        p.forceApprove(address(swapRouter), msg.value);
        quoteOut = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(p),
                tokenOut: address(quote),
                fee: poolFee,
                recipient: msg.sender,
                amountIn: msg.value,
                amountOutMinimum: minQuoteOut,
                sqrtPriceLimitX96: 0
            })
        );

        nOut = msg.value;
        IERC20(series.N()).safeTransfer(msg.sender, nOut);
        emit Boosted(msg.sender, address(series), msg.value, nOut, quoteOut, poolFee);
    }

    /// @notice Boost with nothing held back: every round splits the ETH on hand, sells the
    ///         cash leg (P) into the pool, swaps the proceeds back to ETH and splits again.
    ///         The caller ends holding ONLY upside (≈ ethIn / price(N) of it) plus whatever
    ///         small ETH remainder the final round couldn't profitably recycle.
    /// @param series   The native-ETH Series to split into.
    /// @param poolFee  Fee tier of the P/quote pool.
    /// @param wethFee  Fee tier of the quote/WETH pool used to recycle proceeds (e.g. 500).
    /// @param rounds   Recycle iterations (1–16). Each round recovers ~price(P)/spot of its
    ///                 ETH, so total upside approaches ethIn/(1−p) geometrically.
    /// @param minNOut  Aggregate slippage guard on the upside received.
    /// @param deadline Unix timestamp after which the call reverts.
    function boostFull(
        ISeries series,
        uint24 poolFee,
        uint24 wethFee,
        uint256 rounds,
        uint256 minNOut,
        uint256 deadline
    ) external payable nonReentrant notExpired(deadline) returns (uint256 nOut, uint256 ethBack) {
        if (msg.value == 0) revert ZeroAmount();
        if (rounds == 0 || rounds > 16) revert BadRounds();
        if (series.collateralToken() != address(0)) revert NotNativeSeries();

        IERC20 p = IERC20(series.P());
        uint256 eth = msg.value;
        for (uint256 i; i < rounds && eth > 0.005 ether; ++i) {
            series.split{value: eth}();
            p.forceApprove(address(swapRouter), eth);
            // Per-hop minimums stay 0: `minNOut` guards the aggregate outcome below.
            uint256 quoteOut = swapRouter.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(p),
                    tokenOut: address(quote),
                    fee: poolFee,
                    recipient: address(this),
                    amountIn: eth,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            quote.forceApprove(address(swapRouter), quoteOut);
            uint256 wethOut = swapRouter.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(quote),
                    tokenOut: address(weth),
                    fee: wethFee,
                    recipient: address(this),
                    amountIn: quoteOut,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            weth.withdraw(wethOut);
            eth = wethOut;
        }

        nOut = IERC20(series.N()).balanceOf(address(this));
        if (nOut < minNOut) revert Slippage();
        IERC20(series.N()).safeTransfer(msg.sender, nOut);

        ethBack = address(this).balance;
        if (ethBack > 0) {
            (bool ok,) = msg.sender.call{value: ethBack}("");
            if (!ok) revert EthTransferFailed();
        }
        emit BoostedFull(msg.sender, address(series), msg.value, nOut, ethBack, poolFee);
    }

    /// @notice Pull `quoteIn` of the quote token from the caller, buy P from the P/quote
    ///         pool, and send the P to the caller. Requires prior approval on `quote`.
    /// @param series   The Series whose P leg to buy.
    /// @param poolFee  Uniswap V3 fee tier of the P/quote pool.
    /// @param quoteIn  Quote-token amount to spend.
    /// @param minPOut  Slippage guard on the P purchase, in P units (1e18).
    /// @param deadline Unix timestamp after which the call reverts.
    function yieldBuy(ISeries series, uint24 poolFee, uint256 quoteIn, uint256 minPOut, uint256 deadline)
        external
        nonReentrant
        notExpired(deadline)
        returns (uint256 pOut)
    {
        if (quoteIn == 0) revert ZeroAmount();

        quote.safeTransferFrom(msg.sender, address(this), quoteIn);
        quote.forceApprove(address(swapRouter), quoteIn);
        pOut = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(quote),
                tokenOut: series.P(),
                fee: poolFee,
                recipient: msg.sender,
                amountIn: quoteIn,
                amountOutMinimum: minPOut,
                sqrtPriceLimitX96: 0
            })
        );
        emit Yielded(msg.sender, address(series), quoteIn, pOut, poolFee);
    }
}
