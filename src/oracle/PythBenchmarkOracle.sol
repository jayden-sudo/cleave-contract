// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IPyth} from "./interfaces/IPyth.sol";
import {PythStructs} from "./interfaces/PythStructs.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title PythBenchmarkOracle
/// @notice Tier-B `IPriceOracle` for Cleave backed by a Pyth price feed — broad cross-asset coverage
///         (SOL and other majors, equities, commodities) to help list "any underlying."
///
///         Pyth is pull-based: prices live off-chain (signed by Pyth) and are submitted on demand.
///         For settlement this adapter uses the **pinned-record** pattern over Pyth Benchmarks: after
///         maturity, anyone calls `pin(maturity, updateData)` with the Pyth-signed update for the
///         maturity moment. It uses `parsePriceFeedUpdatesUnique`, which verifies the signature and
///         returns the UNIQUE FIRST update whose publishTime is in [maturity, maturity+pinTolerance]
///         and whose predecessor is strictly before maturity. So the settled price is a DETERMINISTIC
///         function of (priceId, maturity) — whoever pins cannot cherry-pick a more favorable price
///         from the window — and trust-minimized (the caller only relays a price Pyth already signed).
///         `pinTolerance` bounds only how late the first benchmark may arrive (a liveness window), not
///         which value is chosen. Once set the settlement price is final; `priceAt()` returns it, so
///         `Series.settle()` requires a prior `pin()` for a Pyth-priced series.
///
/// @dev    `pin` is payable: it forwards Pyth's update fee and refunds any overpayment.
/// @dev    Output is USD per 1 unit of the priced asset, 1e18-scaled, matching IPriceOracle.
contract PythBenchmarkOracle is IPriceOracle {
    using SafeCast for int256;
    using SafeCast for uint256;

    IPyth public immutable pyth;
    bytes32 public immutable priceId;
    uint256 public immutable maxStaleness; // max age (s) for the live price() read
    uint64 public immutable pinTolerance; // max seconds after maturity the benchmark update may be

    /// endTimestamp (series maturity) => final settled price (1e18). 0 = not yet pinned.
    mapping(uint256 => uint256) public pinned;

    error FutureTimestamp();
    error AlreadyPinned();
    error InsufficientFee();
    error NonPositivePrice();
    error BadExponent();
    error NotPinned();
    error RefundFailed();

    event Pinned(uint256 indexed endTimestamp, uint256 publishTime, uint256 price);

    constructor(IPyth pyth_, bytes32 priceId_, uint256 maxStaleness_, uint64 pinTolerance_) {
        pyth = pyth_;
        priceId = priceId_;
        maxStaleness = maxStaleness_;
        pinTolerance = pinTolerance_;
    }

    /// Convert a Pyth (price, expo) to a 1e18-scaled USD value. Pyth expos are negative (e.g. -8).
    function _to1e18(int64 rawPrice, int32 expo) internal pure returns (uint256) {
        if (rawPrice <= 0) revert NonPositivePrice();
        if (expo > 0 || expo < -18) revert BadExponent();
        uint256 p = int256(rawPrice).toUint256(); // checked: reverts if negative (guarded above)
        uint256 e = int256(18 + expo).toUint256(); // expo in [-18,0] => e in [0,18]
        return p * (10 ** e);
    }

    /// @inheritdoc IPriceOracle
    /// @dev Live price for display / pre-settlement marks; reverts (inside Pyth) if older than maxStaleness.
    function price() external view returns (uint256 usdPerUnit) {
        PythStructs.Price memory p = pyth.getPriceNoOlderThan(priceId, maxStaleness);
        usdPerUnit = _to1e18(p.price, p.expo);
    }

    /// @notice Pin the final settlement price for `endTimestamp` (a series maturity) from a Pyth
    ///         Benchmarks update for that moment. Permissionless; signature + time-window verified
    ///         on-chain by Pyth; final once set. Forwards Pyth's fee and refunds any excess.
    function pin(uint256 endTimestamp, bytes[] calldata updateData)
        external
        payable
        returns (uint256 usdPerUnit)
    {
        if (endTimestamp > block.timestamp) revert FutureTimestamp();
        if (pinned[endTimestamp] != 0) revert AlreadyPinned();

        uint256 fee = pyth.getUpdateFee(updateData);
        if (msg.value < fee) revert InsufficientFee();

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = priceId;
        // endTimestamp <= block.timestamp (checked above), so the uint64 downcast is checked-safe.
        uint64 minT = endTimestamp.toUint64();
        // parsePriceFeedUpdatesUnique (NOT parsePriceFeedUpdates) returns the UNIQUE first update
        // at/after maturity, so the settled price is a deterministic function of (priceId, maturity)
        // and cannot be cherry-picked by whoever pins. pinTolerance only bounds how late the first
        // benchmark may arrive (liveness), not WHICH value is chosen.
        PythStructs.PriceFeed[] memory feeds =
            pyth.parsePriceFeedUpdatesUnique{value: fee}(updateData, ids, minT, minT + pinTolerance);

        PythStructs.Price memory p = feeds[0].price;
        usdPerUnit = _to1e18(p.price, p.expo);
        pinned[endTimestamp] = usdPerUnit;
        emit Pinned(endTimestamp, p.publishTime, usdPerUnit);

        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @inheritdoc IPriceOracle
    /// @dev Returns the pinned settlement price; reverts NotPinned until `pin()` has run.
    function priceAt(uint256 endTimestamp) external view returns (uint256 usdPerUnit) {
        usdPerUnit = pinned[endTimestamp];
        if (usdPerUnit == 0) revert NotPinned();
    }
}
