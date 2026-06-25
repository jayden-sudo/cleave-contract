// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Series} from "../../src/Series.sol";
import {SplitToken} from "../../src/SplitToken.sol";
import {MockOracle} from "../../src/MockOracle.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {SeriesHarness} from "./SeriesHarness.sol";

/// @title Series symbolic specification (halmos)
/// @notice Formal, all-inputs proofs of the Series safety properties. Unlike the
///         fuzz/invariant suite (which samples random inputs), every `check_*`
///         function here is explored symbolically by halmos: a pass means the
///         property holds for EVERY input satisfying the `vm.assume` premises,
///         or halmos produces a concrete counterexample.
///
///         Run with:  halmos --contract SeriesSymbolicTest
///
///         QUANTIFICATION BOUND: amounts are `uint96` throughout this suite
///         (= 2^96-1 wei ~ 7.9e10 ETH, beyond ETH's total supply). The bound
///         keeps the SMT queries tractable; ERC20 collaterals with supplies
///         above 2^96 base units are OUTSIDE the proof envelope of this file.
///         Change a bound here only together with the soundness notes in
///         ../../VERIFICATION.md ("Harness & soundness notes").
///
///         The solvency argument is compositional (see also SeriesHarness and
///         VERIFICATION.md). Machine-checked pieces:
///           Lemma 1  settle() can only ever store f = min(1e18, S*1e18/x) <= 1e18
///                    (check_fraction_*, check_settle_stores_bounded_fraction).
///           Thm A    for EVERY state (P supply, N supply, f <= 1e18), redeem(p,n)
///                    pays EXACTLY floor(p*f/1e18) + floor(n*(1e18-f)/1e18) and
///                    burns exactly p and n (check_redeem_pays_spec_exactly).
///           Lemma 2  the payout formula is subadditive in the amounts:
///                    spec(p1) + spec(p2) <= spec(p1+p2) per leg
///                    (check_lemma_distributivity + check_lemma_floor_div_subadditive).
///           Lemma 3  a matched pair redeems for its deposit minus at most 1 wei
///                    (check_lemma_pair_conserves, check_full_redeem_*).
///           Lemma 4  combine keeps paying exactly 1:1 AFTER settlement, removing a
///                    pair's full claim potential f + (1e18-f) = 1e18 per unit along
///                    with its collateral (check_combine_after_settle_returns_exactly).
///         Composition (simple induction, spelled out in VERIFICATION.md): split
///         escrows deposits 1:1 and mints pairs; redemptions of total (Σp, Σn) pay
///         Σ spec <= spec(Σp) + spec(Σn) <= escrow (Lemmas 2-3); combine reduces the
///         escrow and the outstanding claim potential by exactly the same amount
///         (Lemma 4). Hence no sequence of split/combine/settle/redeem can make the
///         series insolvent, at any price, for any amounts.
contract SeriesSymbolicTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant STRIKE = 1500e18;

    MockOracle internal oracle;
    SeriesHarness internal series;
    SplitToken internal P;
    SplitToken internal N;
    uint256 internal maturity;

    /// @dev Receive combine/redeem payouts.
    receive() external payable {}

    function setUp() public {
        oracle = new MockOracle(2000e18);
        maturity = block.timestamp + 30 days;
        series = new SeriesHarness(STRIKE, maturity, IPriceOracle(address(oracle)));
        P = series.P();
        N = series.N();
    }

    // ------------------------------------------------------------------
    // Lemma 1 — settlement math: f = min(1, S/x) and is always <= 1e18
    // ------------------------------------------------------------------

    /// @notice ∀ x > 0: the fraction the real `settle()` path computes never
    ///         exceeds 1e18, so `WAD - f` in redeem can never underflow and a
    ///         P unit can never claim more than the whole collateral unit.
    function check_fraction_bounded(uint256 x) public view {
        vm.assume(x > 0);
        assertLe(series.fraction(x), WAD, "f > 1e18");
    }

    /// @notice ∀ x > 0: f is exactly min(1e18, S*1e18/x) — full collateral to P
    ///         at or below the strike, S/x above it.
    function check_fraction_is_min_of_ratio_and_one(uint256 x) public view {
        vm.assume(x > 0);
        uint256 f = series.fraction(x);
        if (x <= STRIKE) {
            assertEq(f, WAD, "price <= strike must give f == 1");
        } else {
            assertEq(f, (STRIKE * WAD) / x, "price > strike must give f == S/x");
        }
    }

    /// @notice ∀ x > 0: the real `settle()` stores exactly `_fraction(x)` (and
    ///         therefore, by check_fraction_bounded, a value <= 1e18), plus the
    ///         oracle price it read. This links Lemma 2's `f <= 1e18` premise to
    ///         every state `settle()` can actually reach.
    function check_settle_stores_bounded_fraction(uint256 x) public {
        vm.assume(x > 0);
        oracle.setPrice(x);
        vm.warp(maturity);
        series.settle();
        assertTrue(series.settled(), "not settled");
        assertEq(series.settledPrice(), x, "stored price != oracle price");
        assertEq(series.f(), series.fraction(x), "stored f != _fraction(x)");
        assertLe(series.f(), WAD, "stored f > 1e18");
    }

    /// @notice ∀ strike in (0, 2^256/1e18], ∀ x > 0: settle() SUCCEEDS at maturity
    ///         and stores f <= 1e18 — settlement liveness, not just correctness.
    ///         Strikes above 2^256/1e18 overflow `strike * 1e18` in `_fraction` and
    ///         would brick settle() forever (funds then exit only via matched-pair
    ///         combine). Every realistic USD strike is ~40 orders of magnitude below
    ///         the bound, but deployers/factories must respect it.
    function check_settle_liveness_for_bounded_strike(uint256 strike, uint256 x) public {
        vm.assume(strike > 0 && strike <= type(uint256).max / WAD);
        vm.assume(x > 0);
        uint256 mat = block.timestamp + 7 days;
        SeriesHarness s = new SeriesHarness(strike, mat, IPriceOracle(address(oracle)));
        oracle.setPrice(x);
        vm.warp(mat);
        // External call so a revert surfaces as ok == false instead of ending the
        // path (halmos ignores reverting paths in the test body — vacuous truth).
        (bool ok,) = address(s).call(abi.encodeWithSignature("settle()"));
        assertTrue(ok, "settle reverted within the strike bound");
        assertTrue(s.settled(), "not settled");
        assertLe(s.f(), WAD, "stored f > 1e18");
    }

    // ------------------------------------------------------------------
    // Split / combine: 1:1 backing is exact
    // ------------------------------------------------------------------

    /// @notice ∀ a: splitting `a` wei mints exactly `a` of each leg to the caller
    ///         and escrows exactly `a` — supply is fully backed from the start.
    function check_split_backs_supply_exactly(uint96 a) public {
        vm.assume(a > 0);
        vm.deal(address(this), a);
        series.split{value: a}();
        assertEq(P.totalSupply(), a, "P supply != deposit");
        assertEq(N.totalSupply(), a, "N supply != deposit");
        assertEq(P.balanceOf(address(this)), a, "P not minted to caller");
        assertEq(N.balanceOf(address(this)), a, "N not minted to caller");
        assertEq(address(series).balance, a, "escrow != deposit");
    }

    /// @notice ∀ a, 0 < b <= a: combining `b` pairs returns exactly `b` wei (no
    ///         fee, no rounding) and burns exactly `b` of each leg.
    function check_combine_returns_exactly(uint96 a, uint96 b) public {
        vm.assume(a > 0);
        vm.assume(b > 0 && b <= a);
        vm.deal(address(this), a);
        series.split{value: a}();

        uint256 ethBefore = address(this).balance;
        series.combine(b);

        assertEq(address(this).balance - ethBefore, b, "combine payout != amount");
        assertEq(P.totalSupply(), uint256(a) - b, "P not burned 1:1");
        assertEq(N.totalSupply(), uint256(a) - b, "N not burned 1:1");
        assertEq(address(series).balance, uint256(a) - b, "escrow mismatch after combine");
    }

    /// @notice Lemma 4. ∀ a, 0 < b <= a, f <= 1e18: combine still pays exactly 1:1
    ///         AFTER settlement. This is the induction step the redeem lemmas don't
    ///         cover: a combine removes b·f (P) + b·(1e18−f) (N) = b·1e18 of claim
    ///         potential and exactly b of collateral, so escrow minus outstanding
    ///         claims never decreases when combine interleaves with redemptions.
    function check_combine_after_settle_returns_exactly(uint96 a, uint96 b, uint256 f) public {
        vm.assume(a > 0);
        vm.assume(b > 0 && b <= a);
        vm.assume(f <= WAD);
        vm.deal(address(this), a);
        series.split{value: a}();
        series.forceSettle(f, 1);

        uint256 ethBefore = address(this).balance;
        series.combine(b);

        assertEq(address(this).balance - ethBefore, b, "post-settle combine payout != amount");
        assertEq(P.totalSupply(), uint256(a) - b, "P not burned 1:1");
        assertEq(N.totalSupply(), uint256(a) - b, "N not burned 1:1");
        assertEq(address(series).balance, uint256(a) - b, "escrow mismatch after post-settle combine");
    }

    /// @notice ∀ a: an ERC20-collateral series mints exactly the amount received
    ///         and escrows it (standard-transfer token case).
    function check_splitERC20_backs_supply_exactly(uint96 a) public {
        vm.assume(a > 0);
        // Test contract deployed this token, so it controls mint (acts as its "series").
        SplitToken coll = new SplitToken("COLL", "COLL");
        Series ts = new Series(
            "t", STRIKE, block.timestamp + 30 days, IPriceOracle(address(oracle)), address(coll), "P", "P", "N", "N"
        );
        coll.mint(address(this), a);
        coll.approve(address(ts), a);
        ts.splitERC20(a);
        assertEq(ts.P().totalSupply(), a, "P supply != received");
        assertEq(ts.N().totalSupply(), a, "N supply != received");
        assertEq(coll.balanceOf(address(ts)), a, "escrow != received");
    }

    // ------------------------------------------------------------------
    // Lemma 2 — the solvency theorem, for EVERY possible settlement state
    // ------------------------------------------------------------------

    /// @notice Theorem A. ∀ supplies (sp, sn) — including asymmetric states only
    ///         reachable through prior redemptions — ∀ f <= 1e18 (a superset of
    ///         everything settle() can store, by Lemma 1), ∀ p <= sp, n <= sn:
    ///         redeem(p, n) pays the caller EXACTLY
    ///             floor(p*f/1e18) + floor(n*(1e18-f)/1e18)
    ///         (no path pays more), the escrow decreases by exactly that amount,
    ///         and exactly p of P and n of N are burned.
    function check_redeem_pays_spec_exactly(uint96 sp, uint96 sn, uint256 f, uint96 p, uint96 n)
        public
    {
        vm.assume(f <= WAD);
        vm.assume(p <= sp && n <= sn);
        vm.assume(p > 0 || n > 0);

        vm.deal(address(series), uint256(sp) + sn); // ample escrow; exactness is the claim
        series.forceMint(address(this), sp, sn);
        series.forceSettle(f, 1);

        uint256 ethBefore = address(this).balance;
        uint256 escrowBefore = address(series).balance;
        series.redeem(p, n);

        uint256 spec = (uint256(p) * f) / WAD + (uint256(n) * (WAD - f)) / WAD;
        assertEq(address(this).balance - ethBefore, spec, "payout != spec formula");
        assertEq(escrowBefore - address(series).balance, spec, "escrow delta != spec formula");
        assertEq(P.totalSupply(), uint256(sp) - p, "P burned != p");
        assertEq(N.totalSupply(), uint256(sn) - n, "N burned != n");
    }

    /// @notice Lemma 2a. ∀ u, v, f <= 1e18: multiplying the summed amounts
    ///         distributes (no overflow at these widths), linking Theorem A's
    ///         per-redemption payouts to the aggregate claim of a leg's supply.
    function check_lemma_distributivity(uint96 u, uint96 v, uint256 f) public pure {
        if (f > WAD) return;
        assert((uint256(u) + v) * f == uint256(u) * f + uint256(v) * f);
    }

    /// @notice Lemma 2b. ∀ products t1, t2 (160 bits covers every amount*f at
    ///         these widths): floor division is subadditive —
    ///             floor(t1/W) + floor(t2/W) <= floor((t1+t2)/W) <= floor(t1/W) + floor(t2/W) + 1.
    ///         With Lemma 2a: redeeming a leg in ANY number of chunks never pays
    ///         more than redeeming it at once, so per-leg claims never exceed
    ///         spec(supply) — rounding dust only ever favors the escrow.
    function check_lemma_floor_div_subadditive(uint160 t1, uint160 t2) public pure {
        uint256 whole = (uint256(t1) + t2) / WAD;
        uint256 parts = uint256(t1) / WAD + uint256(t2) / WAD;
        assert(parts <= whole);
        assert(whole <= parts + 1);
    }

    /// @notice Lemma 3. ∀ a, f <= 1e18: a matched pair's claims sum to the
    ///         deposit minus at most 1 wei — P and N exactly partition the
    ///         collateral at every settlement.
    function check_lemma_pair_conserves(uint96 a, uint256 f) public pure {
        if (f > WAD) return;
        uint256 out = (uint256(a) * f) / WAD + (uint256(a) * (WAD - f)) / WAD;
        assert(out <= a);
        assert(a == 0 || out >= uint256(a) - 1);
    }

    /// @notice ∀ a, f <= 1e18: redeeming the entire supply pays out the whole
    ///         deposit minus at most 1 wei of rounding dust (which stays escrowed,
    ///         never owed to anyone).
    function check_full_redeem_pays_deposit_minus_dust(uint96 a, uint256 f) public {
        vm.assume(a > 0);
        vm.assume(f <= WAD);
        vm.deal(address(this), a);
        series.split{value: a}();
        series.forceSettle(f, 1);

        uint256 ethBefore = address(this).balance;
        series.redeem(a, a);
        uint256 paid = address(this).balance - ethBefore;

        assertLe(paid, a, "paid more than deposit");
        assertGe(paid, uint256(a) - 1, "lost more than 1 wei dust");
        assertEq(P.totalSupply(), 0, "P supply not fully burned");
        assertEq(N.totalSupply(), 0, "N supply not fully burned");
    }

    // ------------------------------------------------------------------
    // State-machine guards (proved unreachable for ALL inputs)
    // ------------------------------------------------------------------

    /// @notice ∀ a, dt >= 0: no P/N can ever be minted at or after maturity.
    function check_no_split_at_or_after_maturity(uint96 a, uint64 dt) public {
        vm.assume(a > 0);
        vm.deal(address(this), a);
        vm.warp(maturity + dt);
        (bool ok,) = address(series).call{value: a}(abi.encodeWithSignature("split()"));
        assertFalse(ok, "minted after maturity");
    }

    /// @notice ∀ t < maturity: settle is impossible before maturity.
    function check_no_settle_before_maturity(uint256 t) public {
        vm.assume(t < maturity);
        vm.warp(t);
        (bool ok,) = address(series).call(abi.encodeWithSignature("settle()"));
        assertFalse(ok, "settled before maturity");
    }

    /// @notice Settlement is final: a second settle always reverts, so `f` and
    ///         `settledPrice` can never change once locked — even if the oracle
    ///         later reports a different price.
    function check_settle_is_final(uint256 x, uint256 x2) public {
        vm.assume(x > 0);
        oracle.setPrice(x);
        vm.warp(maturity);
        series.settle();
        uint256 fLocked = series.f();

        oracle.setPrice(x2);
        (bool ok,) = address(series).call(abi.encodeWithSignature("settle()"));
        assertFalse(ok, "settled twice");
        assertEq(series.f(), fLocked, "f changed after settlement");
    }

    /// @notice ∀ p, n: redeem is impossible before settlement.
    function check_no_redeem_before_settle(uint96 p, uint96 n) public {
        (bool ok,) =
            address(series).call(abi.encodeWithSignature("redeem(uint256,uint256)", uint256(p), uint256(n)));
        assertFalse(ok, "redeemed before settlement");
    }

    /// @notice ∀ caller != series, to, amount: nobody but the Series can mint or
    ///         burn the legs — supply is exclusively governed by escrowed collateral.
    function check_only_series_controls_supply(address caller, address to, uint256 amount) public {
        vm.assume(caller != address(series));

        vm.prank(caller);
        (bool okMintP,) = address(P).call(abi.encodeWithSelector(SplitToken.mint.selector, to, amount));
        assertFalse(okMintP, "non-series minted P");

        vm.prank(caller);
        (bool okBurnP,) = address(P).call(abi.encodeWithSelector(SplitToken.burn.selector, to, amount));
        assertFalse(okBurnP, "non-series burned P");

        vm.prank(caller);
        (bool okMintN,) = address(N).call(abi.encodeWithSelector(SplitToken.mint.selector, to, amount));
        assertFalse(okMintN, "non-series minted N");

        vm.prank(caller);
        (bool okBurnN,) = address(N).call(abi.encodeWithSelector(SplitToken.burn.selector, to, amount));
        assertFalse(okBurnN, "non-series burned N");
    }

    /// @notice An ETH series can never accept ERC20 deposits.
    function check_eth_series_rejects_erc20_path(uint256 amount) public {
        (bool ok,) = address(series).call(abi.encodeWithSignature("splitERC20(uint256)", amount));
        assertFalse(ok, "ETH series accepted ERC20 split");
        (bool ok2,) = address(series).call(
            abi.encodeWithSignature("splitToERC20(address,uint256)", address(this), amount)
        );
        assertFalse(ok2, "ETH series accepted ERC20 splitTo");
    }

    /// @notice The other exclusivity direction: an ERC20-collateral series can
    ///         never accept native-ETH deposits (the NotNativeSeries guard) —
    ///         ETH sent there would not be counted as collateral.
    function check_erc20_series_rejects_eth_path(uint96 a, address to) public {
        vm.assume(a > 0);
        SplitToken coll = new SplitToken("COLL", "COLL");
        Series ts = new Series(
            "t", STRIKE, block.timestamp + 30 days, IPriceOracle(address(oracle)), address(coll), "P", "P", "N", "N"
        );
        vm.deal(address(this), uint256(a) * 2);
        (bool ok,) = address(ts).call{value: a}(abi.encodeWithSignature("split()"));
        assertFalse(ok, "ERC20 series accepted ETH split");
        (bool ok2,) = address(ts).call{value: a}(abi.encodeWithSignature("splitTo(address)", to));
        assertFalse(ok2, "ERC20 series accepted ETH splitTo");
    }

    /// @notice ∀ a, dt: the maturity gate holds on EVERY deposit entrypoint,
    ///         not just split(): splitTo, splitERC20, and splitToERC20 can all
    ///         never mint at or after maturity.
    function check_no_mint_after_maturity_any_entrypoint(uint96 a, uint64 dt, address to) public {
        vm.assume(a > 0);
        SplitToken coll = new SplitToken("COLL", "COLL");
        Series ts = new Series(
            "t", STRIKE, block.timestamp + 30 days, IPriceOracle(address(oracle)), address(coll), "P", "P", "N", "N"
        );
        coll.mint(address(this), a);
        coll.approve(address(ts), a);
        vm.deal(address(this), a);

        vm.warp(maturity + dt);
        (bool okTo,) = address(series).call{value: a}(abi.encodeWithSignature("splitTo(address)", to));
        assertFalse(okTo, "splitTo minted after maturity");
        (bool okErc,) = address(ts).call(abi.encodeWithSignature("splitERC20(uint256)", uint256(a)));
        assertFalse(okErc, "splitERC20 minted after maturity");
        (bool okToErc,) =
            address(ts).call(abi.encodeWithSignature("splitToERC20(address,uint256)", to, uint256(a)));
        assertFalse(okToErc, "splitToERC20 minted after maturity");
    }
}
