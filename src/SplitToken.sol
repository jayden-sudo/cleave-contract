// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SplitToken
/// @notice A plain ERC20 whose supply is fully controlled by its `series` (the
///         contract that deploys it). The Series mints tokens on `split` and burns
///         them on `combine` / `redeem`. Holders can otherwise transfer and trade
///         these tokens freely — that is what makes the two legs independently
///         sellable on the Marketplace.
/// @dev    18 decimals; balances are denominated 1:1 with the wei of ETH that was
///         split to create them (1 ETH split -> 1.0 P + 1.0 N).
contract SplitToken is ERC20 {
    address public immutable series;

    error OnlySeries();

    modifier onlySeries() {
        if (msg.sender != series) revert OnlySeries();
        _;
    }

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        series = msg.sender;
    }

    function mint(address to, uint256 amount) external onlySeries {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlySeries {
        _burn(from, amount);
    }
}
