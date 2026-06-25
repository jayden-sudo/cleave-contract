// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title MockOracle
/// @notice A minimal owner-settable price feed implementing the "slow oracle"
///         contract. In production you would point a Series at a Chainlink feed
///         adapter (or an optimistic/UMA-style oracle) that only needs to be
///         correct at maturity. For local development and demos this lets us drive
///         arbitrary settlement prices to see how P and N pay out.
/// @dev    Price is USD per ETH, 1e18 scaled (e.g. 2500e18 == $2,500).
contract MockOracle is IPriceOracle {
    address public owner;
    uint256 public price;

    event PriceSet(uint256 price);
    event OwnerSet(address owner);

    error NotOwner();

    constructor(uint256 initialPrice) {
        owner = msg.sender;
        price = initialPrice;
        emit OwnerSet(msg.sender);
        emit PriceSet(initialPrice);
    }

    /// @dev Dev oracle has no window; ignores `endTimestamp` and returns the current price.
    function priceAt(uint256) external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 newPrice) external {
        if (msg.sender != owner) revert NotOwner();
        price = newPrice;
        emit PriceSet(newPrice);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        owner = newOwner;
        emit OwnerSet(newOwner);
    }
}
