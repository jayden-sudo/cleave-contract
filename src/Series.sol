// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SplitToken} from "./SplitToken.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title Series
/// @notice One options-based split of a collateral asset, as described in Vitalik's
///         "Building index-tracking assets on top of options instead of debt".
///
///         A Series escrows a collateral asset and lets anyone split 1 unit of it into
///         two tokens that ALWAYS sum back to 1 unit of collateral:
///
///           * P (the "cash" leg)    — redeems  min(1, S/x) units at maturity
///           * N (the "upside" leg)  — redeems  max(0, 1 - S/x) units at maturity
///
///         where S = strike (USD per collateral unit) and x = the collateral's price
///         at maturity M.
///
///         Because the two payouts are defined to sum to exactly 1 unit for every
///         possible x, neither leg can ever become insolvent. There is no debt, no
///         collateral ratio, and no liquidation — so a *slow* oracle that only resolves
///         at maturity is sufficient.
///
///         Denominated in USD the legs are:
///           * P  ->  min(x, S)        (the asset, with upside above the strike sold off)
///           * N  ->  max(0, x - S)    (a pure call option struck at S)
///
/// @dev    Collateral is native ETH when `collateralToken == address(0)`, otherwise any
///         ERC20. All fixed-point values use 1e18 scaling; token balances are 1:1 with
///         the collateral deposited (split 1 unit -> 1.0 P + 1.0 N), independent of the
///         collateral's own decimals.
contract Series is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;

    // --- Immutable terms of the series ---
    string public name;
    uint256 public immutable strike; // S, USD per collateral unit, 1e18 scaled
    uint256 public immutable maturity; // M, unix timestamp
    IPriceOracle public immutable oracle;
    /// @notice The collateral asset. `address(0)` == native ETH; otherwise an ERC20.
    IERC20 public immutable collateralToken;

    SplitToken public immutable P; // cash leg
    SplitToken public immutable N; // upside leg

    // --- Settlement state ---
    bool public settled;
    uint256 public settledPrice; // x at maturity, 1e18 scaled
    uint256 public f; // collateral fraction (1e18) each P unit redeems = min(1e18, S*1e18/x)

    event Split(address indexed who, uint256 amount);
    event Combined(address indexed who, uint256 amount);
    event Settled(uint256 price, uint256 f);
    event Redeemed(address indexed who, uint256 pAmount, uint256 nAmount, uint256 amountOut);

    error TradingClosed();
    error NotMatured();
    error AlreadySettled();
    error NotSettled();
    error BadPrice();
    error NothingToDo();
    error EthTransferFailed();
    error NotNativeSeries();
    error NotTokenSeries();

    /// @param name_            Human label, e.g. "ETH split @ $1500, Jun 2026".
    /// @param strike_          S in USD per collateral unit, 1e18 scaled (e.g. 1500e18).
    /// @param maturity_        Settlement timestamp.
    /// @param oracle_          Slow oracle reporting USD per collateral unit (1e18) at maturity.
    /// @param collateralToken_ Collateral asset; `address(0)` for native ETH, else an ERC20.
    /// @param pName/pSym/nName/nSym  ERC20 metadata for the two legs.
    constructor(
        string memory name_,
        uint256 strike_,
        uint256 maturity_,
        IPriceOracle oracle_,
        address collateralToken_,
        string memory pName,
        string memory pSym,
        string memory nName,
        string memory nSym
    ) {
        require(strike_ > 0, "strike=0");
        require(maturity_ > block.timestamp, "maturity in past");
        require(address(oracle_) != address(0), "oracle=0");
        name = name_;
        strike = strike_;
        maturity = maturity_;
        oracle = oracle_;
        collateralToken = IERC20(collateralToken_);
        P = new SplitToken(pName, pSym);
        N = new SplitToken(nName, nSym);
    }

    // --------------------------------------------------------------------------
    // Deposits — native ETH (collateralToken == 0) or ERC20 (collateralToken != 0)
    // --------------------------------------------------------------------------

    /// @notice Native-ETH deposit: send ETH and mint an equal amount of P and N to the
    ///         caller. Only valid when this is a native-ETH series.
    function split() external payable {
        _splitEth(msg.sender);
    }

    /// @notice Like `split`, but mint both legs to `to` (used by SplitFactory.createAndSplit).
    function splitTo(address to) external payable {
        _splitEth(to);
    }

    function _splitEth(address to) internal {
        if (address(collateralToken) != address(0)) revert NotNativeSeries();
        _mintPair(to, msg.value);
    }

    /// @notice ERC20 deposit: pull `amount` of the collateral token and mint an equal
    ///         amount of P and N to the caller. Requires prior `approve`. Only valid when
    ///         this is an ERC20-collateral series.
    function splitERC20(uint256 amount) external nonReentrant {
        _splitToken(msg.sender, amount);
    }

    /// @notice Like `splitERC20`, but mint both legs to `to`.
    function splitToERC20(address to, uint256 amount) external nonReentrant {
        _splitToken(to, amount);
    }

    function _splitToken(address to, uint256 amount) internal {
        if (address(collateralToken) == address(0)) revert NotTokenSeries();
        if (amount == 0) revert NothingToDo();
        // Mint against the amount actually received, so fee-on-transfer tokens never
        // mint more P/N than is escrowed (preserves P + N == collateral held).
        uint256 before = collateralToken.balanceOf(address(this));
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = collateralToken.balanceOf(address(this)) - before;
        _mintPair(to, received);
    }

    function _mintPair(address to, uint256 amount) internal {
        if (block.timestamp >= maturity) revert TradingClosed();
        if (amount == 0) revert NothingToDo();
        P.mint(to, amount);
        N.mint(to, amount);
        emit Split(to, amount);
    }

    /// @notice Burn an equal amount of P and N to reclaim the underlying collateral 1:1.
    /// @dev    Always available — before or after settlement — because P+N is worth
    ///         exactly the deposited collateral at every price ("recombine at any time").
    function combine(uint256 amount) external nonReentrant {
        if (amount == 0) revert NothingToDo();
        P.burn(msg.sender, amount);
        N.burn(msg.sender, amount);
        _send(msg.sender, amount);
        emit Combined(msg.sender, amount);
    }

    /// @notice Read the oracle once at/after maturity and lock in the split fraction.
    /// @dev    Permissionless and idempotent-guarded. The price is anchored to `maturity`
    ///         (a TWAP ending at M), so it does NOT depend on *when* settle is called —
    ///         removing any settle-timing game between P and N holders. Settle should still
    ///         happen within the oracle's data horizon (a keeper); `combine()` is the exit
    ///         otherwise. After this, P and N redeem against the fixed price `x`.
    function settle() external {
        if (block.timestamp < maturity) revert NotMatured();
        if (settled) revert AlreadySettled();
        uint256 x = oracle.priceAt(maturity);
        if (x == 0) revert BadPrice();
        settledPrice = x;
        f = _fraction(x);
        settled = true;
        emit Settled(x, f);
    }

    /// @notice After settlement, redeem P and/or N for their share of collateral.
    /// @param pAmount Amount of P to redeem (min(1, S/x) units each).
    /// @param nAmount Amount of N to redeem (max(0, 1 - S/x) units each).
    function redeem(uint256 pAmount, uint256 nAmount) external nonReentrant {
        if (!settled) revert NotSettled();
        if (pAmount == 0 && nAmount == 0) revert NothingToDo();
        uint256 out;
        if (pAmount > 0) {
            P.burn(msg.sender, pAmount);
            out += (pAmount * f) / WAD;
        }
        if (nAmount > 0) {
            N.burn(msg.sender, nAmount);
            out += (nAmount * (WAD - f)) / WAD;
        }
        if (out > 0) _send(msg.sender, out);
        emit Redeemed(msg.sender, pAmount, nAmount, out);
    }

    // --------------------------------------------------------------------------
    // Views / quotes
    // --------------------------------------------------------------------------

    /// @notice The collateral fraction (1e18) a single P unit would redeem at price `x`.
    ///         f = min(1e18, S/x). N's fraction is (1e18 - f).
    function _fraction(uint256 x) internal view returns (uint256) {
        uint256 ratio = (strike * WAD) / x; // S/x, 1e18 scaled
        return ratio < WAD ? ratio : WAD;
    }

    /// @notice Preview the settlement fraction `f` for a hypothetical price `x`.
    function quoteFraction(uint256 x) external view returns (uint256) {
        if (x == 0) revert BadPrice();
        return _fraction(x);
    }

    /// @notice Collateral out for redeeming `pAmount` P and `nAmount` N at a hypothetical price `x`.
    function quoteRedeem(uint256 x, uint256 pAmount, uint256 nAmount)
        external
        view
        returns (uint256 amountOut)
    {
        uint256 frac = _fraction(x);
        amountOut = (pAmount * frac) / WAD + (nAmount * (WAD - frac)) / WAD;
    }

    /// @notice Total collateral currently escrowed by this series.
    function collateral() external view returns (uint256) {
        return _collateralBalance();
    }

    /// @notice Convenience bundle of the series state for front-ends.
    function info()
        external
        view
        returns (
            string memory name_,
            uint256 strike_,
            uint256 maturity_,
            address oracle_,
            address p_,
            address n_,
            bool settled_,
            uint256 settledPrice_,
            uint256 f_,
            uint256 collateral_,
            uint256 pSupply_,
            uint256 nSupply_
        )
    {
        return (
            name,
            strike,
            maturity,
            address(oracle),
            address(P),
            address(N),
            settled,
            settledPrice,
            f,
            _collateralBalance(),
            P.totalSupply(),
            N.totalSupply()
        );
    }

    function _collateralBalance() internal view returns (uint256) {
        return address(collateralToken) == address(0)
            ? address(this).balance
            : collateralToken.balanceOf(address(this));
    }

    /// @dev Pay `amount` of collateral to `to` — native ETH or ERC20 depending on the series.
    function _send(address to, uint256 amount) internal {
        if (address(collateralToken) == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            collateralToken.safeTransfer(to, amount);
        }
    }
}
