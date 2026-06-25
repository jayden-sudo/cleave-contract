// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Marketplace} from "../../src/Marketplace.sol";
import {SplitToken} from "../../src/SplitToken.sol";

/// @dev Test double for the pull-payment path: rejects ETH pushes until toggled,
///      so `_payOrCredit`'s credit fallback and `withdraw()` are provable end to end.
contract ToggleReceiver {
    bool public accepting;

    function setAccepting(bool a) external {
        accepting = a;
    }

    receive() external payable {
        require(accepting, "rejecting ETH");
    }
}

/// @title Marketplace symbolic specification (halmos)
/// @notice All-inputs proofs of the order-book escrow accounting. Run with:
///         halmos --contract MarketplaceSymbolicTest
///
///         SplitToken doubles as the listed ERC20 (the test contract deploys it,
///         so it controls mint) — which is also exactly what the Marketplace
///         escrows in production.
contract MarketplaceSymbolicTest is Test {
    uint256 internal constant WAD = 1e18;

    /// @dev A plain EOA maker, so push payments always succeed and the maker's
    ///      ETH delta is observable.
    address internal constant MAKER = address(0xCAFE);

    Marketplace internal market;
    SplitToken internal token;

    receive() external payable {}

    function setUp() public {
        market = new Marketplace();
        token = new SplitToken("LEG", "LEG");
    }

    function _list(uint96 amount, uint96 price) internal returns (uint256 id) {
        vm.assume(amount > 0 && price > 0); // listing preconditions (list() reverts otherwise)
        token.mint(MAKER, amount);
        vm.prank(MAKER);
        token.approve(address(market), amount);
        vm.prank(MAKER);
        id = market.list(address(token), amount, price);
    }

    /// @dev Mirrors Marketplace._costOf (ceil), so these proofs track the contract's rounding.
    function _cost(uint256 amount, uint256 price) internal pure returns (uint256) {
        uint256 num = amount * price;
        return num == 0 ? 0 : (num - 1) / WAD + 1;
    }

    /// @notice ∀ listing (amount, price), fill size, and overpayment: a fill moves
    ///         exactly `buyAmt` tokens to the buyer, pays the maker exactly
    ///         `buyAmt * price / 1e18`, refunds the entire excess to the buyer,
    ///         and leaves no ETH stuck in the contract.
    function check_buy_conserves_tokens_and_eth(uint96 amount, uint96 price, uint96 buyAmt, uint96 sent) public {
        uint256 id = _list(amount, price);

        vm.assume(buyAmt > 0 && buyAmt <= amount);
        uint256 cost = _cost(buyAmt, price);
        vm.assume(cost > 0); // dust fills revert; proven separately below
        vm.assume(sent >= cost);

        vm.deal(address(this), sent);
        uint256 buyerEthBefore = address(this).balance;
        uint256 makerEthBefore = MAKER.balance;

        market.buy{value: sent}(id, buyAmt);

        assertEq(token.balanceOf(address(this)), buyAmt, "buyer token delta != fill");
        assertEq(token.balanceOf(address(market)), uint256(amount) - buyAmt, "escrow != remaining");
        assertEq(MAKER.balance - makerEthBefore, cost, "maker paid != cost");
        assertEq(buyerEthBefore - address(this).balance, cost, "buyer net spend != cost (refund lost)");
        assertEq(address(market).balance, 0, "ETH stuck in marketplace");

        (,, uint256 remaining,, bool active) = market.orders(id);
        assertEq(remaining, uint256(amount) - buyAmt, "order remainder wrong");
        assertEq(active, remaining > 0, "active flag inconsistent with remainder");
    }

    /// @notice ∀ listing and partial fill: cancel returns exactly the unsold
    ///         remainder to the maker and deactivates the order.
    function check_cancel_refunds_exact_remainder(uint96 amount, uint96 price, uint96 buyAmt) public {
        uint256 id = _list(amount, price);

        // Optional partial fill first (single guard; the no-fill arm covers
        // out-of-range and dust-cost fills alike).
        uint256 cost = _cost(buyAmt, price);
        if (buyAmt == 0 || buyAmt > amount || cost == 0) {
            buyAmt = 0;
        } else {
            vm.deal(address(this), cost);
            market.buy{value: cost}(id, buyAmt);
        }
        uint256 remainder = uint256(amount) - buyAmt;
        vm.assume(remainder > 0); // fully-filled orders are inactive; cancel reverts

        uint256 makerTokBefore = token.balanceOf(MAKER);
        vm.prank(MAKER);
        market.cancel(id);

        assertEq(token.balanceOf(MAKER) - makerTokBefore, remainder, "cancel refund != remainder");
        assertEq(token.balanceOf(address(market)), 0, "tokens stuck after cancel");
        (,, uint256 left,, bool active) = market.orders(id);
        assertEq(left, 0, "order amount not zeroed");
        assertFalse(active, "order still active after cancel");
    }

    /// @notice ∀ listing and fill where the maker REJECTS the ETH push: the fill
    ///         still succeeds (one bad recipient can't block trading), exactly
    ///         `cost` is credited to `proceeds[maker]` and held by the contract,
    ///         and a later `withdraw()` pays out exactly the credit, leaving the
    ///         contract empty. Closes the pull-payment half of the escrow story —
    ///         the EOA checks above only cover the push path.
    function check_failed_push_credits_then_withdraw_pays_exactly(uint96 amount, uint96 price, uint96 buyAmt) public {
        vm.assume(amount > 0 && price > 0);
        ToggleReceiver maker = new ToggleReceiver(); // accepting == false: pushes fail
        token.mint(address(maker), amount);
        vm.prank(address(maker));
        token.approve(address(market), amount);
        vm.prank(address(maker));
        uint256 id = market.list(address(token), amount, price);

        vm.assume(buyAmt > 0 && buyAmt <= amount);
        uint256 cost = _cost(buyAmt, price);
        vm.assume(cost > 0);
        vm.deal(address(this), cost);

        market.buy{value: cost}(id, buyAmt);

        assertEq(token.balanceOf(address(this)), buyAmt, "buyer token delta != fill");
        assertEq(market.proceeds(address(maker)), cost, "credit != cost");
        assertEq(address(market).balance, cost, "contract must hold exactly the credit");
        assertEq(address(maker).balance, 0, "rejected push still paid the maker");

        maker.setAccepting(true);
        vm.prank(address(maker));
        market.withdraw();

        assertEq(address(maker).balance, cost, "withdraw payout != credit");
        assertEq(market.proceeds(address(maker)), 0, "credit not cleared");
        assertEq(address(market).balance, 0, "ETH stuck after withdraw");
    }

    /// @notice ∀ fill > remaining: over-buying an order is impossible.
    function check_cannot_buy_more_than_listed(uint96 amount, uint96 price, uint256 buyAmt, uint96 sent) public {
        uint256 id = _list(amount, price);
        vm.assume(buyAmt > amount);

        vm.deal(address(this), sent);
        (bool ok,) = address(market).call{value: sent}(abi.encodeWithSelector(Marketplace.buy.selector, id, buyAmt));
        assertFalse(ok, "bought more than listed");
    }

    /// @notice ∀ underpayment: a fill paying less than cost is impossible, and
    ///         free dust fills (cost rounding to 0) are rejected too.
    function check_cannot_underpay(uint96 amount, uint96 price, uint96 buyAmt, uint96 sent) public {
        uint256 id = _list(amount, price);
        vm.assume(buyAmt > 0 && buyAmt <= amount);

        uint256 cost = _cost(buyAmt, price);
        vm.assume(sent < cost || cost == 0);

        vm.deal(address(this), sent);
        (bool ok,) = address(market).call{value: sent}(abi.encodeWithSelector(Marketplace.buy.selector, id, buyAmt));
        assertFalse(ok, "underpaid or dust fill accepted");
    }

    /// @notice ∀ caller ≠ maker: only the maker can cancel an order.
    function check_only_maker_cancels(uint96 amount, uint96 price, address caller) public {
        uint256 id = _list(amount, price);
        vm.assume(caller != MAKER);

        vm.prank(caller);
        (bool ok,) = address(market).call(abi.encodeWithSelector(Marketplace.cancel.selector, id));
        assertFalse(ok, "non-maker cancelled order");
    }
}
