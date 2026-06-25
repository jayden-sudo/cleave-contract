// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISeries
/// @notice Minimal view of a `Series` for the periphery (zaps, routers). Deliberately narrow: it
///         declares ONLY the members the periphery actually touches — the native-ETH `split`, the
///         always-available `combine`, the two legs, and the collateral discriminator. Settlement,
///         redemption, ERC20 deposits, quotes and term metadata are intentionally omitted; consumers
///         that need them depend on the concrete `Series` instead.
/// @dev    Token-typed members return the bare `address` rather than `IERC20`, so importing this
///         interface pulls in no external dependency (e.g. OpenZeppelin). Callers wrap the address in
///         whatever token interface they already use. The values are ABI-identical to the concrete
///         `Series` getters (both encode as a 32-byte address), so casting a `Series` to `ISeries`
///         and calling these is safe.
interface ISeries {
    /// @notice Native-ETH deposit: send ETH and mint an equal amount of P and N to the caller.
    function split() external payable;

    /// @notice Burn an equal amount of P and N to reclaim the underlying collateral 1:1.
    function combine(uint256 amount) external;

    /// @notice The cash leg (P) token address (an ERC20 `SplitToken`).
    function P() external view returns (address);

    /// @notice The upside leg (N) token address (an ERC20 `SplitToken`).
    function N() external view returns (address);

    /// @notice The collateral asset. `address(0)` == native ETH; otherwise an ERC20 token address.
    function collateralToken() external view returns (address);
}
