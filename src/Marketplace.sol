// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Marketplace
/// @notice A minimal escrowed order book for selling ERC20 tokens for ETH. It is
///         generic, but the intended use is listing the P (stable) and N (upside)
///         legs minted by a Series so that the two halves of a split can be sold to
///         different buyers.
///
///         A seller escrows tokens into the contract when listing; buyers pay ETH
///         and receive tokens. Orders support partial fills and can be cancelled by
///         the maker at any time to reclaim the unsold remainder.
/// @dev    `pricePerToken` is wei per ONE whole token (1e18 base units).
contract Marketplace is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;

    struct Order {
        address maker;
        address token;
        uint256 amount; // remaining token base units for sale
        uint256 pricePerToken; // wei per 1e18 tokens
        bool active;
    }

    Order[] public orders;

    /// @notice ETH credited to a recipient when a push payment failed (they rejected ETH).
    ///         Pull it with `withdraw()`. Keeps a maker/buyer that can't receive ETH from
    ///         blocking fills for everyone else.
    mapping(address => uint256) public proceeds;

    event Listed(
        uint256 indexed id, address indexed maker, address indexed token, uint256 amount, uint256 pricePerToken
    );
    event Bought(uint256 indexed id, address indexed buyer, uint256 amount, uint256 cost);
    event Cancelled(uint256 indexed id, uint256 refundedAmount);
    event Withdrawn(address indexed who, uint256 amount);

    error ZeroAmount();
    error ZeroPrice();
    error NotActive();
    error NotMaker();
    error InsufficientPayment();
    error ExceedsAvailable();
    error DustTrade();
    error EthTransferFailed();
    error NothingToWithdraw();

    /// @notice List `amount` of `token` for sale at `pricePerToken` wei per whole token.
    /// @dev    Caller must `approve` this contract for `amount` first. Tokens are
    ///         pulled into escrow immediately.
    function list(address token, uint256 amount, uint256 pricePerToken) external nonReentrant returns (uint256 id) {
        if (amount == 0) revert ZeroAmount();
        if (pricePerToken == 0) revert ZeroPrice();
        // Escrow and record the amount ACTUALLY received, not the requested amount, so a
        // fee-on-transfer token can't list more than it delivers and dip into the pooled
        // balance backing other makers' orders.
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        if (received == 0) revert ZeroAmount();
        id = orders.length;
        orders.push(Order({maker: msg.sender, token: token, amount: received, pricePerToken: pricePerToken, active: true}));
        emit Listed(id, msg.sender, token, received, pricePerToken);
    }

    /// @notice Buy `amount` token base units from order `id`. Supports partial fills.
    /// @dev    Send at least `cost = amount * pricePerToken / 1e18` wei; any excess
    ///         is refunded. Maker is paid immediately.
    function buy(uint256 id, uint256 amount) external payable nonReentrant {
        Order storage o = orders[id];
        if (!o.active) revert NotActive();
        if (amount == 0) revert ZeroAmount();
        if (amount > o.amount) revert ExceedsAvailable();

        uint256 cost = _costOf(amount, o.pricePerToken);
        if (cost == 0) revert DustTrade(); // unreachable with ceil rounding (amount,price > 0 => cost >= 1); kept defensively
        if (msg.value < cost) revert InsufficientPayment();

        // Effects
        o.amount -= amount;
        if (o.amount == 0) o.active = false;
        address maker = o.maker;
        address token = o.token;

        // Interactions. Push proceeds, but a maker/buyer that rejects ETH must never be
        // able to block the fill — fall back to a withdrawable credit (pull payment).
        IERC20(token).safeTransfer(msg.sender, amount);
        _payOrCredit(maker, cost);
        if (msg.value > cost) _payOrCredit(msg.sender, msg.value - cost);

        emit Bought(id, msg.sender, amount, cost);
    }

    /// @notice Cancel order `id` and return the unsold tokens to the maker.
    function cancel(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        if (!o.active) revert NotActive();
        if (o.maker != msg.sender) revert NotMaker();
        uint256 refund = o.amount;
        o.amount = 0;
        o.active = false;
        IERC20(o.token).safeTransfer(msg.sender, refund);
        emit Cancelled(id, refund);
    }

    // --- Views ---

    function ordersCount() external view returns (uint256) {
        return orders.length;
    }

    /// @notice The wei required to buy `amount` base units of order `id`.
    function quoteCost(uint256 id, uint256 amount) external view returns (uint256) {
        return _costOf(amount, orders[id].pricePerToken);
    }

    /// @notice Return a bounded page of orders, `orders[from .. from+limit)`, clamped to the
    ///         end of the book. Returning the whole unbounded array in a single `eth_call`
    ///         eventually exhausts the node's call memory/gas (MemoryOOG) as the book grows,
    ///         so callers page through with `from`/`limit`. The order id of `page[i]` is
    ///         `from + i`; use `ordersCount()` for the total. (Demo-scale convenience;
    ///         front-end filters active.)
    function allOrders(uint256 from, uint256 limit) external view returns (Order[] memory page) {
        uint256 n = orders.length;
        if (from >= n || limit == 0) return new Order[](0);
        // `n - from` is safe (from < n) and avoids any `from + limit` overflow.
        uint256 count = n - from;
        if (count > limit) count = limit;
        page = new Order[](count);
        for (uint256 i = 0; i < count; i++) {
            page[i] = orders[from + i];
        }
    }

    /// @notice Withdraw ETH proceeds credited when a fill's push payment failed.
    function withdraw() external nonReentrant {
        uint256 amt = proceeds[msg.sender];
        if (amt == 0) revert NothingToWithdraw();
        proceeds[msg.sender] = 0; // effects before interaction
        _sendEth(msg.sender, amt);
        emit Withdrawn(msg.sender, amt);
    }

    /// @dev Try to push ETH; if the recipient rejects it, credit a withdrawable balance
    ///      so one bad recipient can't brick a fill. Caller must follow checks-effects.
    function _payOrCredit(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) proceeds[to] += amount;
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev Cost of `amount` base units, rounded UP to the nearest wei. Flooring per fill would
    ///      let a buyer split a purchase into many sub-buys and shave up to `<1` wei off the
    ///      maker on each (the sum of many floors is less than one floor of the total); rounding
    ///      toward the maker makes splitting a fill never cheaper than buying it in one go and
    ///      keeps escrow conservative. (UltraFuzz audit UF-1.)
    function _costOf(uint256 amount, uint256 pricePerToken) internal pure returns (uint256) {
        uint256 num = amount * pricePerToken;
        return num == 0 ? 0 : (num - 1) / WAD + 1; // ceil(num / WAD), overflow-safe
    }
}
