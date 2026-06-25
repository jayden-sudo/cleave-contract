// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IUniswapV3PoolMinimal, UniV3OracleLib} from "./libraries/UniV3OracleLib.sol";
import {Median} from "./libraries/Median.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title UniswapV3MedianOracle
/// @notice A trustless ETH/USD price feed for Cleave's `IPriceOracle`. It reads the
///         price of ETH from several Uniswap V3 ETH/stablecoin pools as a
///         time-weighted average (TWAP) and returns the MEDIAN across them.
///
///         Two layers of manipulation resistance:
///           1. TWAP — each pool is read as a time-weighted average over `twapWindow`
///              seconds, so a single-block / flash-loan price push barely moves it.
///              This dovetails with Cleave's "slow oracle": settlement reads the
///              price once at maturity, so a long, hard-to-game window is ideal.
///           2. Median of N pools — if one stablecoin de-pegs (e.g. USDT to $0.97,
///              making ETH/USDT read ~3% high) or one pool is thin/manipulated, the
///              median discards that outlier.
///
///         Intended starting set: ETH priced in USDC, USDT, and DAI (3 feeds) — but heed the
///         feed-independence caveat below: DAI is USDC-correlated via the PSM, so prefer
///         swapping it for a more independent stable (e.g. USDS) before relying on the median
///         to survive a correlated USDC/DAI depeg, not just a single isolated one.
/// @dev    Output is USD per ETH, 1e18-scaled, matching IPriceOracle.
/// @dev    Outlier rejection only protects against a SINGLE *uncorrelated* depeg. Choose feeds
///         for asset independence: avoid pairing USDC with a heavily-USDC-collateralized stable
///         (e.g. DAI via the PSM), since a correlated depeg can move two of three feeds the same
///         way and drag the median with them. Prefer feeds that don't share collateral backing.
///         (UltraFuzz audit UF-10.)
contract UniswapV3MedianOracle is IPriceOracle {
    uint128 internal constant ONE_ETH = 1e18; // 1 WETH in raw units (18 decimals)

    address public immutable weth;
    uint32 public immutable twapWindow; // seconds

    struct Feed {
        address pool; // Uniswap V3 pool (WETH/stable)
        address quote; // the stablecoin
        uint256 scale; // 10**(18 - quoteDecimals): normalizes the quote to 1e18
    }

    Feed[] private feeds;

    error LengthMismatch();
    error TooFewFeeds();
    error EvenFeedCount();
    error NotWethPair();
    error DecimalsTooLarge();

    /// @param weth_       The WETH address (the base asset of every pool).
    /// @param twapWindow_ TWAP averaging window in seconds (e.g. 3600 for 1 hour).
    /// @param pools       Uniswap V3 pools, one per stablecoin.
    /// @param quotes      The stablecoin in each pool (same index as `pools`).
    constructor(address weth_, uint32 twapWindow_, address[] memory pools, address[] memory quotes) {
        require(weth_ != address(0), "weth=0");
        require(twapWindow_ > 0, "window=0");
        if (pools.length != quotes.length) revert LengthMismatch();
        // Require at least 3 feeds. With a single feed the median IS that feed, so the second
        // manipulation-resistance layer ("median discards a de-pegged/manipulated pool") is
        // vacuous and a 1-feed config silently degrades the documented threat model. (UltraFuzz
        // audit UF-9.) Combined with the odd-count rule below, the smallest valid set is 3.
        if (pools.length < 3) revert TooFewFeeds();
        // An odd feed count guarantees the median is a single middle element, so one
        // de-pegged stablecoin is always discarded (an even count averages the two
        // middle values, re-admitting an outlier's influence).
        if (pools.length % 2 == 0) revert EvenFeedCount();

        weth = weth_;
        twapWindow = twapWindow_;

        for (uint256 i = 0; i < pools.length; i++) {
            address t0 = IUniswapV3PoolMinimal(pools[i]).token0();
            address t1 = IUniswapV3PoolMinimal(pools[i]).token1();
            bool ok = (t0 == weth_ && t1 == quotes[i]) || (t1 == weth_ && t0 == quotes[i]);
            if (!ok) revert NotWethPair();

            uint8 d = IERC20Metadata(quotes[i]).decimals();
            if (d > 18) revert DecimalsTooLarge();

            // Probe the TWAP at deploy: reverts if the pool can't serve `twapWindow`
            // (insufficient observation cardinality), so a non-TWAP-capable pool can't
            // be wired in. The window read is always available thereafter for an
            // actively-traded pool.
            UniV3OracleLib.consult(pools[i], twapWindow_);

            feeds.push(Feed({pool: pools[i], quote: quotes[i], scale: 10 ** (18 - d)}));
        }
    }

    function feedCount() external view returns (uint256) {
        return feeds.length;
    }

    function feedAt(uint256 i) external view returns (address pool, address quote, uint256 scale) {
        Feed memory f = feeds[i];
        return (f.pool, f.quote, f.scale);
    }

    /// @notice The per-pool ETH/USD prices (1e18) feeding the median, for a TWAP window
    ///         ENDING at `endTimestamp`. Settlement anchors this to maturity.
    function priceComponentsAt(uint256 endTimestamp) public view returns (uint256[] memory out) {
        require(endTimestamp <= block.timestamp, "future");
        uint32 endAgo = uint32(block.timestamp - endTimestamp);
        uint256 n = feeds.length;
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            Feed memory f = feeds[i];
            // TWAP tick over [endTimestamp - twapWindow, endTimestamp].
            int24 meanTick = UniV3OracleLib.consultWindow(f.pool, endAgo + twapWindow, endAgo);
            // quote stablecoin for 1 ETH (its own decimals), then normalize to 1e18 USD/ETH.
            uint256 quoteRaw = UniV3OracleLib.getQuoteAtTick(meanTick, ONE_ETH, weth, f.quote);
            out[i] = quoteRaw * f.scale;
        }
    }

    /// @notice The per-pool ETH/USD prices right now (window ending at the current block).
    ///         Useful for front-ends and for spotting a de-pegging stablecoin.
    function priceComponents() public view returns (uint256[] memory) {
        return priceComponentsAt(block.timestamp);
    }

    /// @inheritdoc IPriceOracle
    function priceAt(uint256 endTimestamp) public view returns (uint256 usdPerEth) {
        usdPerEth = Median.calc(priceComponentsAt(endTimestamp));
        require(usdPerEth > 0, "px=0");
    }

    /// @inheritdoc IPriceOracle
    /// @dev NOTE: this is the median of each pool's `twapWindow` TWAP ending at the current
    ///      block (e.g. a 1-hour average), NOT an instantaneous spot quote. It is intended
    ///      for display and pre-settlement marks and can lag a fast spot move by design
    ///      (the same averaging that makes settlement manipulation-resistant). Consumers
    ///      should label it as an average, not a live price.
    function price() external view returns (uint256 usdPerEth) {
        usdPerEth = priceAt(block.timestamp);
    }
}
