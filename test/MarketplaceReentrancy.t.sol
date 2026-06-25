// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev A malicious ERC20 that re-enters `Marketplace.list()` during its escrow `transferFrom`,
///      modelling an ERC-777 `tokensToSend` hook. Used to pin the `nonReentrant` guard on
///      `list()` (UltraFuzz UF-6): without the guard, the outer `list()`'s
///      `received = balanceAfter - balanceBefore` snapshot would count the re-entrant deposit
///      twice and over-credit the attacker's order, draining a co-maker's escrow.
contract ReentrantListToken is ERC20 {
    Marketplace public market;
    bool public armed;

    constructor() ERC20("Reentrant", "RE") {}

    function setMarket(Marketplace m) external {
        market = m;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm() external {
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false; // one-shot, so the re-entry itself doesn't recurse further
            // Re-enter the order book mid-escrow. The nonReentrant guard must reject this.
            market.list(address(this), amount, 1e18);
        }
        return super.transferFrom(from, to, amount);
    }
}

contract MarketplaceReentrancyTest is Test {
    Marketplace market;
    ReentrantListToken token;
    address attacker = makeAddr("attacker");

    function setUp() public {
        market = new Marketplace();
        token = new ReentrantListToken();
        token.setMarket(market);
        token.mint(attacker, 1_000 ether);
    }

    /// UF-6 regression: a token that re-enters `list()` during its escrow `transferFrom` is
    /// rejected by the `nonReentrant` guard, so escrow can never be double-counted. If the guard
    /// were removed from `list()`, the re-entrant call would succeed and this test would fail.
    function test_list_reentrancy_is_blocked() public {
        vm.startPrank(attacker);
        token.approve(address(market), type(uint256).max);
        token.arm();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        market.list(address(token), 100 ether, 1e18);
        vm.stopPrank();

        // The whole attack reverted: no order exists, no tokens were escrowed, funds intact.
        assertEq(market.ordersCount(), 0, "no order should exist");
        assertEq(token.balanceOf(address(market)), 0, "no escrow taken");
        assertEq(token.balanceOf(attacker), 1_000 ether, "attacker funds intact");
    }

    /// Sanity: a normal (non-re-entrant) listing of the same token still works unchanged.
    function test_list_normal_still_works() public {
        vm.startPrank(attacker);
        token.approve(address(market), 100 ether);
        uint256 id = market.list(address(token), 100 ether, 1e18);
        vm.stopPrank();
        assertEq(id, 0);
        assertEq(token.balanceOf(address(market)), 100 ether, "escrowed");
        assertEq(market.ordersCount(), 1);
    }
}
