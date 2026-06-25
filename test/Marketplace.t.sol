// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {Series} from "../src/Series.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MarketplaceTest is Test {
    Marketplace market;
    MockOracle oracle;
    Series series;

    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");

    receive() external payable {}

    function setUp() public {
        market = new Marketplace();
        oracle = new MockOracle(2000e18);
        series = new Series(
            "ETH split @ $1500",
            1500e18,
            block.timestamp + 30 days,
            IPriceOracle(address(oracle)),
            address(0),
            "Cleave Stable",
            "sETH",
            "Cleave Upside",
            "uETH"
        );
        // seller splits 1 ETH -> holds 1 P + 1 N
        vm.deal(seller, 1 ether);
        vm.prank(seller);
        series.split{value: 1 ether}();
    }

    function _listN(uint256 amount, uint256 price) internal returns (uint256 id) {
        vm.startPrank(seller);
        series.N().approve(address(market), amount);
        id = market.list(address(series.N()), amount, price);
        vm.stopPrank();
    }

    function test_list_escrows_tokens() public {
        uint256 id = _listN(1 ether, 0.3 ether);
        assertEq(series.N().balanceOf(address(market)), 1 ether, "escrowed");
        assertEq(series.N().balanceOf(seller), 0, "left seller");
        (address maker, address token, uint256 amount, uint256 price, bool active) = market.orders(id);
        assertEq(maker, seller);
        assertEq(token, address(series.N()));
        assertEq(amount, 1 ether);
        assertEq(price, 0.3 ether);
        assertTrue(active);
    }

    function test_buy_full_transfers_and_pays_maker() public {
        uint256 id = _listN(1 ether, 0.3 ether); // 0.3 ETH per whole token

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        market.buy{value: 0.3 ether}(id, 1 ether);

        assertEq(series.N().balanceOf(buyer), 1 ether, "buyer got tokens");
        assertEq(seller.balance, 0.3 ether, "maker paid");
        assertEq(buyer.balance, 0.7 ether, "buyer spent exactly cost");
        (,, uint256 amount,, bool active) = market.orders(id);
        assertEq(amount, 0);
        assertFalse(active, "order closed");
    }

    function test_buy_partial_then_remainder() public {
        uint256 id = _listN(1 ether, 0.5 ether);
        vm.deal(buyer, 1 ether);

        vm.prank(buyer);
        market.buy{value: 0.2 ether}(id, 0.4 ether); // cost = 0.4 * 0.5 = 0.2
        assertEq(series.N().balanceOf(buyer), 0.4 ether);
        assertEq(seller.balance, 0.2 ether);
        (,, uint256 amount,, bool active) = market.orders(id);
        assertEq(amount, 0.6 ether, "remaining");
        assertTrue(active);

        vm.prank(buyer);
        market.buy{value: 0.3 ether}(id, 0.6 ether); // cost = 0.3
        assertEq(series.N().balanceOf(buyer), 1 ether);
        assertEq(seller.balance, 0.5 ether);
        (,,,, bool active2) = market.orders(id);
        assertFalse(active2);
    }

    function test_buy_refunds_excess_payment() public {
        uint256 id = _listN(1 ether, 0.3 ether);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        market.buy{value: 1 ether}(id, 1 ether); // overpays by 0.7
        assertEq(buyer.balance, 0.7 ether, "refunded the excess");
        assertEq(seller.balance, 0.3 ether);
    }

    function test_buy_reverts_on_underpayment() public {
        uint256 id = _listN(1 ether, 0.3 ether);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(Marketplace.InsufficientPayment.selector);
        market.buy{value: 0.2 ether}(id, 1 ether);
    }

    function test_buy_reverts_exceeds_available() public {
        uint256 id = _listN(1 ether, 0.3 ether);
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        vm.expectRevert(Marketplace.ExceedsAvailable.selector);
        market.buy{value: 1 ether}(id, 2 ether);
    }

    function test_cancel_returns_remainder() public {
        uint256 id = _listN(1 ether, 0.3 ether);
        vm.prank(seller);
        market.cancel(id);
        assertEq(series.N().balanceOf(seller), 1 ether, "tokens returned");
        (,,,, bool active) = market.orders(id);
        assertFalse(active);
    }

    function test_cancel_only_maker() public {
        uint256 id = _listN(1 ether, 0.3 ether);
        vm.prank(buyer);
        vm.expectRevert(Marketplace.NotMaker.selector);
        market.cancel(id);
    }

    function test_list_reverts_zero_price() public {
        address n = address(series.N()); // cache before arming expectRevert
        vm.startPrank(seller);
        IERC20(n).approve(address(market), 1 ether);
        vm.expectRevert(Marketplace.ZeroPrice.selector);
        market.list(n, 1 ether, 0);
        vm.stopPrank();
    }

    // --- pull-payment fallback (maker that rejects ETH can't grief fills) ---

    function test_buy_credits_maker_that_rejects_eth_then_withdraw() public {
        TogglableMaker m = new TogglableMaker(market);
        address n = address(series.N()); // cache before prank (a getter call would consume it)
        // fund the maker contract with N tokens to list
        vm.prank(seller);
        IERC20(n).transfer(address(m), 1 ether);
        uint256 id = m.listN(n, 1 ether, 0.3 ether);

        // maker currently rejects ETH — the buy must still succeed
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        market.buy{value: 0.3 ether}(id, 1 ether);

        assertEq(series.N().balanceOf(buyer), 1 ether, "buyer still gets tokens");
        assertEq(address(m).balance, 0, "no ETH pushed to a rejecting maker");
        assertEq(market.proceeds(address(m)), 0.3 ether, "proceeds credited instead");

        // once the maker can accept ETH, it pulls its proceeds
        m.setAccept(true);
        m.withdraw();
        assertEq(address(m).balance, 0.3 ether, "maker withdrew proceeds");
        assertEq(market.proceeds(address(m)), 0, "credit cleared");
    }

    function test_normal_maker_is_paid_by_push_not_credit() public {
        uint256 id = _listN(1 ether, 0.3 ether); // seller is a plain EOA
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        market.buy{value: 0.3 ether}(id, 1 ether);
        assertEq(seller.balance, 0.3 ether, "pushed instantly");
        assertEq(market.proceeds(seller), 0, "no credit for a normal maker");
    }

    function test_withdraw_reverts_when_nothing() public {
        vm.prank(buyer);
        vm.expectRevert(Marketplace.NothingToWithdraw.selector);
        market.withdraw();
    }

    // --- paginated allOrders ---

    /// @dev List `k` distinct orders so the book has several entries to page over.
    function _listMany(uint256 k) internal {
        vm.startPrank(seller);
        for (uint256 i = 0; i < k; i++) {
            series.N().approve(address(market), 1);
            market.list(address(series.N()), 1, (i + 1) * 1e15);
        }
        vm.stopPrank();
    }

    function test_allOrders_pages_in_order() public {
        _listMany(5);
        assertEq(market.ordersCount(), 5, "count");

        // First page of 2.
        Marketplace.Order[] memory p0 = market.allOrders(0, 2);
        assertEq(p0.length, 2);
        assertEq(p0[0].pricePerToken, 1e15, "id 0 price");
        assertEq(p0[1].pricePerToken, 2e15, "id 1 price");

        // Middle page of 2 — global id of page[i] is from + i.
        Marketplace.Order[] memory p1 = market.allOrders(2, 2);
        assertEq(p1.length, 2);
        assertEq(p1[0].pricePerToken, 3e15, "id 2 price");
        assertEq(p1[1].pricePerToken, 4e15, "id 3 price");
    }

    function test_allOrders_clamps_limit_to_end() public {
        _listMany(5);
        // Ask for more than remain past `from`: clamped to the last element only.
        Marketplace.Order[] memory page = market.allOrders(4, 100);
        assertEq(page.length, 1, "clamped to one");
        assertEq(page[0].pricePerToken, 5e15);
    }

    function test_allOrders_from_beyond_end_is_empty() public {
        _listMany(3);
        assertEq(market.allOrders(3, 10).length, 0, "from == length");
        assertEq(market.allOrders(99, 10).length, 0, "from past end");
    }

    function test_allOrders_zero_limit_is_empty() public {
        _listMany(3);
        assertEq(market.allOrders(0, 0).length, 0, "zero limit");
    }

    function test_allOrders_empty_book() public view {
        assertEq(market.allOrders(0, 10).length, 0, "no orders yet");
    }
}

/// @dev A maker contract that can be toggled to reject incoming ETH, to exercise the
///      marketplace's pull-payment fallback.
contract TogglableMaker {
    Marketplace market;
    bool public accept;

    constructor(Marketplace m) {
        market = m;
    }

    function setAccept(bool a) external {
        accept = a;
    }

    function listN(address token, uint256 amount, uint256 price) external returns (uint256) {
        IERC20(token).approve(address(market), amount);
        return market.list(token, amount, price);
    }

    function withdraw() external {
        market.withdraw();
    }

    receive() external payable {
        if (!accept) revert("reject ETH");
    }
}
