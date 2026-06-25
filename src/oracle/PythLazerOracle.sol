// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {PythLazerLib} from "./lazer/PythLazerLib.sol";
import {PythLazerStructs} from "./lazer/PythLazerStructs.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title PythLazerOracle
/// @notice Trust-minimized `IPriceOracle` for Cleave backed by a **Pyth Lazer** feed. Lazer is
///         Pyth's low-latency, signed price channel — distinct from Pyth Core (Hermes). Many
///         underlyings (e.g. newly-listed equities like HK.2513/HKD, Zhipu AI) are Lazer-only:
///         they have a numeric Lazer feed id but NO Core hex price-feed-id, so the Core-based
///         `PythBenchmarkOracle` cannot serve them. This adapter can.
///
///         Lazer is pull-based: a relayer fetches a Pyth-signed update off-chain and submits it.
///         This contract verifies the ECDSA signature on-chain against an IMMUTABLE trusted signer
///         (the same check Pyth's canonical `PythLazer` verifier performs) before trusting any
///         price, then parses the payload with Pyth's own `PythLazerLib`. So a relayer can only
///         relay prices Pyth already signed for `feedId` — it cannot forge or alter a price.
///
///         - `update()` pushes the latest signed price for display / pre-settlement marks (`price()`).
///         - `pin()` locks the settlement price for a maturity from a signed update whose publish
///           time is in `[maturity, maturity + pinTolerance]`; `priceAt()` then returns it and
///           `Series.settle()` works. First pin wins.
///
/// @dev    No admin, no proxy, no fee: immutable like the rest of Cleave. The trusted signer is set
///         once at construction (vs. the canonical verifier's rotatable registry). If Pyth rotates
///         its Lazer signing key, deploy a fresh oracle. Output is 1e18-scaled units of the feed's
///         quote currency (e.g. HKD per share for HK.2513/HKD), matching IPriceOracle.
///
///         Verification mirrors `PythLazer.verifyUpdate`: the EVM `update` is
///         `magic(4) | r(32) | s(32) | v(1) | payloadLen(2) | payload`, signed over keccak256(payload).
contract PythLazerOracle is IPriceOracle {
    using PythLazerLib for PythLazerStructs.Feed;

    /// EVM update envelope magic (Pyth Lazer "EVM" delivery format).
    uint32 internal constant EVM_FORMAT_MAGIC = 706910618;

    address public immutable trustedSigner; // Pyth Lazer payload signer (ECDSA / secp256k1)
    uint32 public immutable feedId; // Lazer feed id (e.g. 3258 = Equity.HK.2513/HKD)
    uint256 public immutable maxStaleness; // max age (s) for a live price() read
    uint64 public immutable pinTolerance; // max seconds after maturity a settlement update may be

    /// Latest pushed live price (1e18) and its publish time (unix seconds).
    uint256 public lastPrice;
    uint256 public lastPublishTime;

    /// endTimestamp (series maturity) => final settled price (1e18). 0 = not yet pinned.
    mapping(uint256 => uint256) public pinned;

    error InvalidMagic();
    error InputTooShort();
    error InvalidSignature();
    error UntrustedSigner();
    error FeedNotFound();
    error NonPositivePrice();
    error BadExponent();
    error StalePrice();
    error NoPrice();
    error NotPinned();
    error AlreadyPinned();
    error FutureTimestamp();
    error OutOfWindow();

    event Updated(uint256 price, uint256 publishTime);
    event Pinned(uint256 indexed endTimestamp, uint256 publishTime, uint256 price);

    constructor(address trustedSigner_, uint32 feedId_, uint256 maxStaleness_, uint64 pinTolerance_) {
        require(trustedSigner_ != address(0), "signer=0");
        trustedSigner = trustedSigner_;
        feedId = feedId_;
        maxStaleness = maxStaleness_;
        pinTolerance = pinTolerance_;
    }

    // --------------------------------------------------------------------------
    // Live price (push)
    // --------------------------------------------------------------------------

    /// @notice Verify a Pyth-signed Lazer update and cache the latest price for `feedId`.
    ///         Permissionless: the on-chain signature check is the only trust. Stale (older)
    ///         updates are ignored rather than reverting, so a late relay is a no-op.
    function update(bytes calldata lazerUpdate) external {
        bytes memory payload = _verify(lazerUpdate);
        (uint256 price1e18, uint256 publishSec) = _extract(payload);
        if (publishSec > lastPublishTime) {
            lastPrice = price1e18;
            lastPublishTime = publishSec;
            emit Updated(price1e18, publishSec);
        }
    }

    /// @inheritdoc IPriceOracle
    /// @dev Live cached price for display / pre-settlement marks. Reverts if never set, or if the
    ///      cached update is older than `maxStaleness`. A publish time AHEAD of `block.timestamp`
    ///      (e.g. on a mainnet fork whose clock lags real time) is accepted, not treated as stale.
    function price() external view returns (uint256) {
        if (lastPublishTime == 0) revert NoPrice();
        if (block.timestamp > lastPublishTime && block.timestamp - lastPublishTime > maxStaleness) {
            revert StalePrice();
        }
        return lastPrice;
    }

    // --------------------------------------------------------------------------
    // Settlement
    // --------------------------------------------------------------------------

    /// @notice Pin the final settlement price for `endTimestamp` (a series maturity) from a
    ///         Pyth-signed Lazer update whose publish time is in `[endTimestamp, endTimestamp +
    ///         pinTolerance]`. Permissionless, signature-verified on-chain, final once set.
    /// @dev    Unlike Pyth Core's `parsePriceFeedUpdatesUnique`, Lazer has no historical "unique
    ///         first benchmark" primitive, so determinism is bounded by `pinTolerance` (and
    ///         first-pin-wins), not guaranteed unique. Keep `pinTolerance` tight on mainnet.
    function pin(uint256 endTimestamp, bytes calldata lazerUpdate) external returns (uint256 price1e18) {
        if (endTimestamp > block.timestamp) revert FutureTimestamp();
        if (pinned[endTimestamp] != 0) revert AlreadyPinned();
        bytes memory payload = _verify(lazerUpdate);
        uint256 publishSec;
        (price1e18, publishSec) = _extract(payload);
        if (publishSec < endTimestamp || publishSec > endTimestamp + pinTolerance) revert OutOfWindow();
        pinned[endTimestamp] = price1e18;
        emit Pinned(endTimestamp, publishSec, price1e18);
    }

    /// @inheritdoc IPriceOracle
    /// @dev Returns the pinned settlement price; reverts NotPinned until `pin()` has run.
    function priceAt(uint256 endTimestamp) external view returns (uint256) {
        uint256 p = pinned[endTimestamp];
        if (p == 0) revert NotPinned();
        return p;
    }

    // --------------------------------------------------------------------------
    // Internals
    // --------------------------------------------------------------------------

    /// @dev Verify the ECDSA signature over the inner payload against `trustedSigner` and return
    ///      the verified payload bytes. Mirrors `PythLazer.verifyUpdate` (no fee; immutable signer).
    function _verify(bytes calldata update_) internal view returns (bytes memory payload) {
        if (update_.length < 71) revert InputTooShort();
        if (uint32(bytes4(update_[0:4])) != EVM_FORMAT_MAGIC) revert InvalidMagic();
        uint16 payloadLen = uint16(bytes2(update_[69:71]));
        if (update_.length < 71 + payloadLen) revert InputTooShort();
        payload = update_[71:71 + payloadLen];
        bytes32 hash = keccak256(payload);
        (address signer,,) =
            ECDSA.tryRecover(hash, uint8(update_[68]) + 27, bytes32(update_[4:36]), bytes32(update_[36:68]));
        if (signer == address(0)) revert InvalidSignature();
        if (signer != trustedSigner) revert UntrustedSigner();
    }

    /// @dev Parse the verified payload, find `feedId`, and return (price 1e18, publishTime seconds).
    ///      The Lazer payload timestamp is microseconds since epoch.
    function _extract(bytes memory payload) internal view returns (uint256 price1e18, uint256 publishSec) {
        PythLazerStructs.Update memory u = PythLazerLib.parseUpdateFromPayload(payload);
        publishSec = uint256(u.timestamp) / 1_000_000;
        uint256 n = u.feeds.length;
        for (uint256 i = 0; i < n; i++) {
            if (u.feeds[i].feedId == feedId) {
                int64 p = PythLazerLib.getPrice(u.feeds[i]); // reverts if price not present
                int16 expo = PythLazerLib.getExponent(u.feeds[i]); // reverts if exponent not present
                return (_to1e18(p, expo), publishSec);
            }
        }
        revert FeedNotFound();
    }

    /// @dev Convert a Lazer (price, expo) to a 1e18-scaled value. Lazer expos are <= 0.
    function _to1e18(int64 rawPrice, int16 expo) internal pure returns (uint256) {
        if (rawPrice <= 0) revert NonPositivePrice();
        if (expo > 0 || expo < -18) revert BadExponent();
        uint256 e = uint256(int256(18) + int256(expo)); // expo in [-18,0] => e in [0,18]
        return uint256(uint64(rawPrice)) * (10 ** e);
    }
}
