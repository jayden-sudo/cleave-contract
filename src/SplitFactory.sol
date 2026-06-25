// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Series} from "./Series.sol";
import {MockOracle} from "./MockOracle.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title SplitFactory
/// @notice Deploys and tracks Series. A market is uniquely identified by
///         (collateral, strike, maturity, oracle): the factory keeps a registry and
///         deploys at most ONE Series per market. Repeated creates for the same terms
///         return the existing Series, so all liquidity shares a single fungible pair of
///         P/N tokens (concentrated liquidity) instead of fragmenting across duplicate
///         contracts.
///
///         Collateral is native ETH (`address(0)`) or any ERC20 — the protocol splits
///         *any* asset against *any* oracle into a cash leg + an upside leg.
contract SplitFactory {
    Series[] public series;

    /// @notice market key => Series. address(0) until the market is created.
    mapping(bytes32 => Series) public marketOf;

    event SeriesCreated(
        address indexed series,
        address indexed creator,
        string name,
        uint256 strike,
        uint256 maturity,
        address oracle,
        address p,
        address n
    );

    /// @notice Canonical identifier for a market, collateral-aware.
    function marketKeyFor(address collateralToken, uint256 strike, uint256 maturity, IPriceOracle oracle)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(collateralToken, strike, maturity, address(oracle)));
    }

    /// @notice Canonical identifier for a native-ETH market (collateral == address(0)).
    function marketKey(uint256 strike, uint256 maturity, IPriceOracle oracle) public pure returns (bytes32) {
        return marketKeyFor(address(0), strike, maturity, oracle);
    }

    /// @notice The Series for a native-ETH market, or address(0) if not created yet.
    function seriesFor(uint256 strike, uint256 maturity, IPriceOracle oracle) public view returns (Series) {
        return marketOf[marketKey(strike, maturity, oracle)];
    }

    /// @notice The Series for an ERC20-collateral market, or address(0) if not created yet.
    function seriesForCollateral(address collateralToken, uint256 strike, uint256 maturity, IPriceOracle oracle)
        public
        view
        returns (Series)
    {
        return marketOf[marketKeyFor(collateralToken, strike, maturity, oracle)];
    }

    // --------------------------------------------------------------------------
    // Create (get-or-create, idempotent per market)
    // --------------------------------------------------------------------------

    function _create(
        address collateralToken,
        string memory name,
        uint256 strike,
        uint256 maturity,
        IPriceOracle oracle,
        string memory pName,
        string memory pSym,
        string memory nName,
        string memory nSym
    ) internal returns (Series s) {
        bytes32 key = marketKeyFor(collateralToken, strike, maturity, oracle);
        s = marketOf[key];
        if (address(s) != address(0)) return s;

        s = new Series(name, strike, maturity, oracle, collateralToken, pName, pSym, nName, nSym);
        marketOf[key] = s;
        series.push(s);
        emit SeriesCreated(
            address(s), msg.sender, name, strike, maturity, address(oracle), address(s.P()), address(s.N())
        );
    }

    /// @notice Get-or-create a native-ETH market.
    /// @dev    Idempotent. The name / token metadata is only used on first creation; on a
    ///         later call for the same market it is ignored and the existing Series is
    ///         returned. This is what keeps liquidity fungible per market.
    function createSeries(
        string memory name,
        uint256 strike,
        uint256 maturity,
        IPriceOracle oracle,
        string memory pName,
        string memory pSym,
        string memory nName,
        string memory nSym
    ) public returns (Series s) {
        return _create(address(0), name, strike, maturity, oracle, pName, pSym, nName, nSym);
    }

    /// @notice Get-or-create a market collateralized by an ERC20. Same primitive as
    ///         `createSeries`, for any asset with a price oracle (BTC, LSTs, stables, …).
    function createSeriesWithCollateral(
        address collateralToken,
        string memory name,
        uint256 strike,
        uint256 maturity,
        IPriceOracle oracle,
        string memory pName,
        string memory pSym,
        string memory nName,
        string memory nSym
    ) public returns (Series s) {
        require(collateralToken != address(0), "use createSeries for ETH");
        return _create(collateralToken, name, strike, maturity, oracle, pName, pSym, nName, nSym);
    }

    /// @notice Get-or-create the native-ETH market and split `msg.value` ETH into it in one
    ///         tx, minting both halves directly to the caller.
    function createAndSplit(
        string memory name,
        uint256 strike,
        uint256 maturity,
        IPriceOracle oracle,
        string memory pName,
        string memory pSym,
        string memory nName,
        string memory nSym
    ) external payable returns (Series s) {
        s = createSeries(name, strike, maturity, oracle, pName, pSym, nName, nSym);
        s.splitTo{value: msg.value}(msg.sender);
    }

    /// @notice Convenience: deploy a fresh MockOracle (owned by the caller) and a native-ETH
    ///         Series wired to it. Handy for demos and testnets.
    /// @dev    Each call deploys a distinct oracle, so it always opens a new market.
    function createSeriesWithMockOracle(
        string memory name,
        uint256 strike,
        uint256 maturity,
        uint256 initialPrice,
        string memory pName,
        string memory pSym,
        string memory nName,
        string memory nSym
    ) external returns (Series s, MockOracle oracle) {
        oracle = new MockOracle(initialPrice);
        oracle.transferOwnership(msg.sender);
        s = createSeries(name, strike, maturity, oracle, pName, pSym, nName, nSym);
    }

    function seriesCount() external view returns (uint256) {
        return series.length;
    }

    /// @notice Return every deployed series address (fine for demo-scale lists).
    function allSeries() external view returns (Series[] memory) {
        return series;
    }

    /// @notice A bounded page of deployed series, `series[from .. from+limit)`, clamped to the
    ///         end of the registry. `allSeries()` returns the WHOLE array and will eventually
    ///         exceed a node's `eth_call` gas budget as the (permissionless) registry grows;
    ///         keepers and front-ends should page through with this instead. The global index
    ///         of `page[i]` is `from + i`; use `seriesCount()` for the total. (UltraFuzz UF-12.)
    function allSeriesPaged(uint256 from, uint256 limit) external view returns (Series[] memory page) {
        uint256 n = series.length;
        if (from >= n || limit == 0) return new Series[](0);
        uint256 count = n - from;
        if (count > limit) count = limit;
        page = new Series[](count);
        for (uint256 i = 0; i < count; i++) {
            page[i] = series[from + i];
        }
    }
}
