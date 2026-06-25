// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Series} from "../src/Series.sol";
import {SplitToken} from "../src/SplitToken.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

/// @notice Ports of the formally proven obligations in
///         verify/cleave-verity/verity/spec/CleaveVerity/Spec/SeriesCoreSpec.lean,
///         checked against the REAL Series.sol (native-ETH series).
///
///         Lean model (slot)         Solidity reality checked here
///         ------------------        -----------------------------
///         pSupply / nSupply         P.totalSupply() / N.totalSupply()
///         collateral                address(series).balance
///         f                         series.f()
///
///         Obligation -> test map:
///           split_preserves_backing,
///           combine_preserves_backing      -> invariant_backing_identity_pre_settle
///           settle_establishes_solvency,
///           combine_preserves_solvency,
///           redeem_preserves_solvency      -> invariant_solvency_post_settle (+ fuzz below)
///           combine_effect (liveness),
///           redeem_never_insolvent         -> invariant_proven_paths_never_revert
///           settle_effect, settle_only_once -> testFuzz_settle_effect_oneShot_fCapped
///           pair_redeem_near_exact         -> testFuzz_pair_redeem_dust_bound
///           redeem_effect,
///           redeem_never_insolvent,
///           redeem_preserves_solvency      -> testFuzz_redeem_exact_and_solvent
contract SeriesVerityHandler is Test {
    uint256 internal constant WAD = 1e18;

    Series public series;
    SplitToken public P;
    SplitToken public N;
    MockOracle public oracle;
    uint256 public maturity;

    /// @dev Ghost flags: set when a call the Lean proofs guarantee succeeds (with an
    ///      exact payout) reverts or pays the wrong amount. The invariant asserts
    ///      they stay false, so violations are caught even with fail_on_revert off.
    bool public combineBroken;
    bool public redeemBroken;

    constructor(Series s, MockOracle o) {
        series = s;
        oracle = o;
        P = s.P();
        N = s.N();
        maturity = s.maturity();
        vm.deal(address(this), 1_000_000 ether);
    }

    receive() external payable {}

    function doSplit(uint96 amt) public {
        if (block.timestamp >= maturity) return;
        uint256 a = bound(uint256(amt), 0, 1000 ether);
        if (a == 0 || address(this).balance < a) return;
        series.split{value: a}();
    }

    /// @dev combine_effect: burning `a` of BOTH legs returns exactly `a` collateral
    ///      (no rounding loss), at any time, settled or not.
    function combine(uint96 amt) public {
        uint256 a = bound(uint256(amt), 0, _min(P.balanceOf(address(this)), N.balanceOf(address(this))));
        if (a == 0) return;
        uint256 balBefore = address(this).balance;
        try series.combine(a) {
            if (address(this).balance != balBefore + a) combineBroken = true;
        } catch {
            combineBroken = true;
        }
    }

    /// @dev settle_effect precondition: any oracle price > 0. Unlike the older
    ///      handler this fuzzes the settlement price across the full uint256 range,
    ///      so the post-settle invariants are checked for every reachable f.
    function settleAt(uint256 priceX) public {
        if (series.settled()) return;
        oracle.setPrice(bound(priceX, 1, type(uint256).max));
        if (block.timestamp < maturity) vm.warp(maturity);
        series.settle();
    }

    /// @dev redeem_never_insolvent + redeem_effect: while the solvency invariant
    ///      holds, a redemption covered by the caller's balances must succeed and
    ///      pay exactly floor(p*f/WAD) + floor(n*(WAD-f)/WAD).
    function redeemBoth(uint96 pAmt, uint96 nAmt) public {
        if (!series.settled()) return;
        uint256 p = bound(uint256(pAmt), 0, P.balanceOf(address(this)));
        uint256 n = bound(uint256(nAmt), 0, N.balanceOf(address(this)));
        if (p == 0 && n == 0) return;
        uint256 f = series.f();
        uint256 expected = (p * f) / WAD + (n * (WAD - f)) / WAD;
        uint256 balBefore = address(this).balance;
        try series.redeem(p, n) {
            if (address(this).balance != balBefore + expected) redeemBroken = true;
        } catch {
            redeemBroken = true;
        }
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }
}

contract SeriesVerityInvariantTest is Test {
    uint256 internal constant WAD = 1e18;

    MockOracle oracle;
    Series series;
    SeriesVerityHandler handler;

    function setUp() public {
        oracle = new MockOracle(2000e18);
        series = new Series(
            "verity", 1500e18, block.timestamp + 30 days, IPriceOracle(address(oracle)), address(0), "P", "P", "N", "N"
        );
        handler = new SeriesVerityHandler(series, oracle);
        // The handler drives the settlement price, so it needs the oracle.
        oracle.transferOwnership(address(handler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = SeriesVerityHandler.doSplit.selector;
        selectors[1] = SeriesVerityHandler.combine.selector;
        selectors[2] = SeriesVerityHandler.settleAt.selector;
        selectors[3] = SeriesVerityHandler.redeemBoth.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev split_preserves_backing / combine_preserves_backing: before settlement,
    ///      collateral == P.totalSupply() == N.totalSupply() on every reachable state.
    function invariant_backing_identity_pre_settle() public view {
        if (series.settled()) return;
        uint256 bal = address(series).balance;
        assertEq(bal, series.P().totalSupply(), "pre-settle: collateral != P supply");
        assertEq(bal, series.N().totalSupply(), "pre-settle: collateral != N supply");
    }

    /// @dev settle_establishes_solvency + redeem_preserves_solvency +
    ///      combine_preserves_solvency, in the exact (undivided) Lean form:
    ///        pSupply*f + nSupply*(WAD - f) <= collateral*WAD,  with f <= WAD.
    ///      Stronger than comparing floor-divided payouts: no precision is lost.
    function invariant_solvency_post_settle() public view {
        if (!series.settled()) return;
        uint256 f = series.f();
        assertLe(f, WAD, "f > WAD");
        uint256 ps = series.P().totalSupply();
        uint256 ns = series.N().totalSupply();
        uint256 bal = address(series).balance;
        assertLe(ps * f + ns * (WAD - f), bal * WAD, "solvency: ps*f + ns*(WAD-f) > collateral*WAD");
    }

    /// @dev combine_effect (liveness + exactness) and redeem_never_insolvent: calls
    ///      the proofs say cannot fail never reverted nor paid a wrong amount.
    function invariant_proven_paths_never_revert() public view {
        assertFalse(handler.combineBroken(), "combine with both legs reverted or paid != amount");
        assertFalse(handler.redeemBroken(), "covered redeem reverted or paid wrong amount");
    }
}

contract SeriesVerityFuzzTest is Test {
    uint256 internal constant WAD = 1e18;
    // Lean settle_effect precondition: strike*WAD must not overflow uint256.
    uint256 internal constant MAX_STRIKE = type(uint256).max / WAD;

    address alice = makeAddr("alice");

    /// @dev Deploy a fresh series with the given terms, split `amount` from alice,
    ///      warp to maturity and settle at `priceX`. Fuzzing the strike (not just the
    ///      price) makes every settlement fraction f in [0, WAD] reachable.
    function _settledSeries(uint256 strikeX, uint256 priceX, uint256 amount) internal returns (Series s) {
        MockOracle o = new MockOracle(priceX);
        uint256 mat = block.timestamp + 30 days;
        s = new Series("verity", strikeX, mat, IPriceOracle(address(o)), address(0), "P", "P", "N", "N");
        vm.deal(alice, amount);
        vm.prank(alice);
        s.split{value: amount}();
        vm.warp(mat);
        s.settle();
    }

    /// @dev settle_effect + settle_only_once: for ANY strike and ANY oracle price > 0,
    ///      settle records the price, sets f to exactly min(strike*WAD/price, WAD)
    ///      (so f <= WAD and the N payout factor WAD-f cannot underflow), flips the
    ///      flag, leaves supplies/collateral untouched, and can never run again.
    function testFuzz_settle_effect_oneShot_fCapped(uint256 strikeX, uint256 priceX) public {
        strikeX = bound(strikeX, 1, MAX_STRIKE);
        priceX = bound(priceX, 1, type(uint256).max);

        MockOracle o = new MockOracle(priceX);
        uint256 mat = block.timestamp + 30 days;
        Series s = new Series("verity", strikeX, mat, IPriceOracle(address(o)), address(0), "P", "P", "N", "N");

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        s.split{value: 1 ether}();

        vm.warp(mat);
        s.settle();

        assertTrue(s.settled(), "settled flag");
        assertEq(s.settledPrice(), priceX, "price recorded");
        uint256 ratio = (strikeX * WAD) / priceX;
        assertEq(s.f(), ratio < WAD ? ratio : WAD, "f != min(strike*WAD/price, WAD)");
        assertLe(s.f(), WAD, "f > WAD");
        assertEq(s.P().totalSupply(), 1 ether, "settle touched P supply");
        assertEq(s.N().totalSupply(), 1 ether, "settle touched N supply");
        assertEq(address(s).balance, 1 ether, "settle touched collateral");

        // settle_establishes_solvency: the handoff from 1:1 backing to the
        // post-settle inequality holds at the moment of settlement.
        assertLe(1 ether * s.f() + 1 ether * (WAD - s.f()), 1 ether * WAD, "settle broke solvency");

        // settle_only_once
        vm.expectRevert(Series.AlreadySettled.selector);
        s.settle();
    }

    /// @dev pair_redeem_near_exact: redeeming a matched pair (a of P plus a of N)
    ///      pays out in [a-1, a] for EVERY reachable f, and the at-most-1-wei
    ///      rounding dust stays in the escrow.
    function testFuzz_pair_redeem_dust_bound(uint96 amount, uint256 strikeX, uint256 priceX) public {
        uint256 a = bound(uint256(amount), 1, type(uint96).max);
        strikeX = bound(strikeX, 1, MAX_STRIKE);
        priceX = bound(priceX, 1, type(uint256).max);

        Series s = _settledSeries(strikeX, priceX, a);

        vm.prank(alice);
        s.redeem(a, a);

        assertLe(alice.balance, a, "pair pays out more than deposited");
        assertGe(alice.balance, a - 1, "pair loses more than 1 wei to rounding");
        assertLe(address(s).balance, 1, "more than 1 wei dust left in escrow");
    }

    /// @dev redeem_effect + redeem_never_insolvent + redeem_preserves_solvency:
    ///      for any p <= pSupply, n <= nSupply held by the caller, the quoted payout
    ///      fits inside the escrow, the call succeeds (no EthTransferFailed), pays
    ///      exactly floor(p*f/WAD) + floor(n*(WAD-f)/WAD), decrements supplies
    ///      exactly, and leaves the solvency inequality intact.
    function testFuzz_redeem_exact_and_solvent(uint96 amount, uint256 strikeX, uint256 priceX, uint256 p, uint256 n)
        public
    {
        uint256 a = bound(uint256(amount), 1, type(uint96).max);
        strikeX = bound(strikeX, 1, MAX_STRIKE);
        priceX = bound(priceX, 1, type(uint256).max);

        Series s = _settledSeries(strikeX, priceX, a);
        uint256 f = s.f();

        p = bound(p, 0, a);
        n = bound(n, 0, a);
        vm.assume(p > 0 || n > 0);

        uint256 expectedOut = (p * f) / WAD + (n * (WAD - f)) / WAD;

        // redeem_never_insolvent: the payout fits inside the escrow.
        assertLe(expectedOut, address(s).balance, "payout exceeds escrow");

        // ...so the redemption must go through (un-wrapped call: a revert fails the test).
        vm.prank(alice);
        s.redeem(p, n);

        // redeem_effect: exact payout and exact supply bookkeeping.
        assertEq(alice.balance, expectedOut, "payout != floor(p*f/WAD) + floor(n*(WAD-f)/WAD)");
        assertEq(s.P().totalSupply(), a - p, "P supply not decremented by p");
        assertEq(s.N().totalSupply(), a - n, "N supply not decremented by n");

        // redeem_preserves_solvency, in the exact Lean form.
        assertLe((a - p) * f + (a - n) * (WAD - f), address(s).balance * WAD, "redeem broke solvency");
    }
}
