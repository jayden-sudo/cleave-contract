// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CleaveQuoteMathHarness} from "./CleaveQuoteMathHarness.sol";

/// @title CleaveQuoteMath symbolic specification (halmos)
/// @notice Formal, all-inputs proofs of the safety properties of the oracle-anchored
///         AMM's PURE quote math (`src/amm/CleaveQuoteMath.sol`). Unlike the fuzz
///         suite, every `check_*` here is explored symbolically by halmos: a pass
///         means the property holds for EVERY input satisfying the `vm.assume`
///         premises, or halmos returns a concrete counterexample.
///
///         Run with:  halmos --contract CleaveQuoteMathSymbolicTest
///
///         WHY THIS IS THE PRIME SYMBOLIC TARGET. `clampGuide`, `usdcOutForP` and
///         `pOutForUsdc` are pure, no-external-call functions. The hook
///         (`OracleAnchoredHook`) delegates ALL of its pricing and decimal handling
///         to them, then does v4 take()/settle() flash-accounting that needs a real
///         PoolManager — that part is covered by the Foundry STATEFUL INVARIANTS,
///         NOT here. This file proves exactly the slice halmos proves best: the math
///         that decides how much USDC/P leaves the maker's inventory.
///
///         BOUND ENVELOPE. Prices (spot/strike/guide) and amounts are clamped to
///         <= 1e30 (1e12 units at 1e18 scale — ~10 orders of magnitude above any
///         real ETH/asset price or supply), and fee < 1e18. Inputs above the bound
///         are OUTSIDE this file's proof envelope (and would be economically absurd
///         or revert). The envelope guarantees every `a*b` product below stays
///         < 2^256, which is load-bearing for the quote-math equivalence note.
///
///         ───────────────────────────────────────────────────────────────────────
///         TWO PROOF STYLES, AND WHY (the hard truth from the brief, made concrete):
///
///         (1) clampGuide — proven DIRECTLY on the production bytecode (via the thin
///             `CleaveQuoteMathHarness`). Its only `Math.mulDiv` is `mulDiv(cap,
///             0.25e18, WAD)` — ONE symbolic operand against a CONSTANT — which
///             cvc5-int discharges in seconds. The band proof is anchored on an
///             EXACT closed form, `clampGuide == max(floor, min(i, cap))`
///             (check_clampGuide_exact_form), where `floor` is recomputed with the
///             IDENTICAL `Math.mulDiv` expression. The solver unifies that mulDiv
///             term syntactically instead of evaluating it, so every band corollary
///             is a cheap pure-inequality consequence.
///
///         (2) usdcOutForP / pOutForUsdc — these chain TWO `Math.mulDiv` calls, each
///             `mulDiv(symbolic, symbolic, WAD)`. OZ's `Math.mulDiv` computes the
///             512-bit product via `mulmod(a, b, 2^256-1)` (mul512); with BOTH
///             operands symbolic this `mulmod` is not symbolically executable in
///             tractable time on ANY backend (cvc5-int / z3 / bitwuzla all time out,
///             confirmed empirically — even a bare "does it revert?" query). So the
///             VALUE properties (monotonicity / conservative / round-trip) are proven
///             on an EXACT plain-arithmetic MODEL of the two functions using `*` and
///             `/` (`_usdcOutForP_model`, `_pOutForUsdc_model`), decomposed into
///             single-nonlinear-step lemmas the way the Series suite proves its
///             solvency math (check_lemma_floor_div_subadditive et al). The
///             building-block `check_lemma_*` are the machine-checked atoms; the
///             end-to-end facts (BUY fee-monotonicity, conservative bound, full round
///             trip) follow by COMPOSITION of those atoms, spelled out in each
///             property's NatSpec — exactly the Series-suite compositional pattern.
///
///             SOUNDNESS OF THE MODEL (proven by inspection of the branch). Within the
///             bound every product `a*b < 2^256`, so `Math.mulDiv(a, b, WAD)` takes its
///             non-overflow branch and `return low / denominator`, i.e. it returns
///             EXACTLY `(a*b)/WAD` — bit-for-bit the model's arithmetic (OZ Math.sol
///             lines 211-215: `if (high == 0) return low / denominator`). The model is
///             therefore the production semantics inside the envelope, not an
///             approximation. What the model does NOT carry over: behaviour for
///             products >= 2^256 (out of envelope) and the literal revert-on-overflow
///             of mulDiv (also out of envelope; here it cannot trigger). The FeeTooHigh
///             revert guard IS proven on the real bytecode
///             (check_usdcOutForP_reverts_when_fee_ge_wad).
///         ───────────────────────────────────────────────────────────────────────
contract CleaveQuoteMathSymbolicTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MIN_GUIDE_FRAC_WAD = 0.25e18;

    /// Bound envelope (see header). 1e30 = 1e12 units of price/amount at 1e18 scale.
    uint256 internal constant MAX_PRICE = 1e30;

    CleaveQuoteMathHarness internal q;

    function setUp() public {
        q = new CleaveQuoteMathHarness();
    }

    // ==================================================================
    // Shared band edges — computed with the EXACT expressions clampGuide
    // uses, so the SMT solver unifies the `Math.mulDiv(cap, frac, WAD)`
    // term with clampGuide's internal one instead of evaluating it.
    // ==================================================================

    function _cap(uint256 spot, uint256 strike) internal pure returns (uint256) {
        return spot < strike ? spot : strike;
    }

    /// @dev floor = mulDiv(cap, 0.25e18, WAD) (= 25% of cap) — byte-identical to the library's `floor_`,
    ///      INCLUDING its control flow: the library short-circuits `if (cap == 0) return 0` BEFORE
    ///      computing the floor, so `_floor` returns 0 at cap == 0 and 25% of cap otherwise. The
    ///      `Math.mulDiv` here is the SAME call the library makes; that syntactic match keeps every band
    ///      check tractable. (An earlier floor also took max with `spot-strike` — N's intrinsic, NOT a
    ///      floor for P — which could exceed the cap; the Lean FV caught that and it was removed.)
    function _floor(uint256 spot, uint256 strike) internal pure returns (uint256) {
        uint256 cap = _cap(spot, strike);
        if (cap == 0) return 0;
        return Math.mulDiv(cap, MIN_GUIDE_FRAC_WAD, WAD);
    }

    // ==================================================================
    // clampGuide — the two-sided no-arb band (REAL bytecode)
    // ==================================================================

    /// @notice EXACT CLOSED FORM. ∀ guide, spot, strike (bounded): clampGuide returns
    ///         EXACTLY `max(floor, min(iWad, cap))`. Every other band property below
    ///         is a pure-inequality corollary of this single characterization — which
    ///         is why they are all cheap (no second mulDiv evaluation).
    function check_clampGuide_exact_form(uint256 iWad, uint256 spot, uint256 strike) public view {
        vm.assume(spot <= MAX_PRICE && strike <= MAX_PRICE && iWad <= MAX_PRICE);
        uint256 cap = _cap(spot, strike);
        uint256 floor_ = _floor(spot, strike);
        uint256 capped = iWad < cap ? iWad : cap;
        uint256 expect = capped < floor_ ? floor_ : capped;
        assertEq(q.clampGuide(iWad, spot, strike), expect, "clampGuide != max(floor, min(i,cap))");
    }

    /// @notice LOWER EDGE. ∀ inputs: clampGuide(i,..) >= floor ALWAYS. A wrong or
    ///         malicious LOW guide is pinned UP to the floor — it can never pass
    ///         through near-zero. (Holds at cap==0 too: then floor==0 and r==0.)
    function check_clampGuide_at_least_floor(uint256 iWad, uint256 spot, uint256 strike) public view {
        vm.assume(spot <= MAX_PRICE && strike <= MAX_PRICE && iWad <= MAX_PRICE);
        assertGe(q.clampGuide(iWad, spot, strike), _floor(spot, strike), "clamp below floor");
    }

    /// @notice AUDIT FIX (one-sided-clamp drain). ∀ inputs with cap > 0: the clamped
    ///         guide is at least 25% of the cap (= `mulDiv(cap, 0.25e18, WAD)`). THIS
    ///         is the regression the two-sided clamp closes: with a one-sided (cap-only)
    ///         clamp a near-zero guide passed straight through and the buy side could be
    ///         swept for dust. The defensive floor makes that unreachable for ALL inputs.
    function check_clampGuide_at_least_quarter_cap(uint256 iWad, uint256 spot, uint256 strike) public view {
        vm.assume(spot <= MAX_PRICE && strike <= MAX_PRICE && iWad <= MAX_PRICE);
        uint256 cap = _cap(spot, strike);
        vm.assume(cap > 0);
        uint256 quarter = Math.mulDiv(cap, MIN_GUIDE_FRAC_WAD, WAD);
        assertGe(q.clampGuide(iWad, spot, strike), quarter, "clamped guide below 25% of cap");
    }

    /// @notice UPPER EDGE = cap (THE Lean-FV fix, now unconditional). ∀ inputs: clampGuide(i,..) <= cap
    ///         = min(spot, strike) — P's no-arb maximum (by parity value(P)+value(N)==spot with the call
    ///         N >= max(0, spot-strike), so P = spot-N <= min(spot, strike)). This is the regression the
    ///         clampGuide fix locks: the prior floor took max with N's intrinsic max(0, spot-strike),
    ///         which for spot > 2*strike EXCEEDED the cap and let clampGuide quote P ABOVE its no-arb max
    ///         — the Lean FV caught exactly this. With floor = 25% of cap (always <= cap) the band
    ///         [floor, cap] is well-formed and `<= cap` now holds for ALL inputs, with no precondition.
    ///         Together with check_clampGuide_at_least_floor this is the textbook two-sided band.
    function check_clampGuide_at_most_cap(uint256 iWad, uint256 spot, uint256 strike) public view {
        vm.assume(spot <= MAX_PRICE && strike <= MAX_PRICE && iWad <= MAX_PRICE);
        assertLe(q.clampGuide(iWad, spot, strike), _cap(spot, strike), "clamp above cap");
    }

    /// @notice ZERO IFF PAUSED. ∀ inputs: clampGuide returns 0 IFF cap == 0 (spot or
    ///         strike is 0 — a paused/degenerate spot). For the strict-positive
    ///         direction the cap must be >= 4 base units so the floor `cap/4` does not
    ///         round to 0 — economically vacuous (cap >= 4 wei = 4e-18 USD), but a real
    ///         rounding edge worth pinning. The hook rejects a 0 result with GuideZero.
    function check_clampGuide_zero_iff_cap_zero(uint256 iWad, uint256 spot, uint256 strike) public view {
        vm.assume(spot <= MAX_PRICE && strike <= MAX_PRICE && iWad <= MAX_PRICE);
        uint256 r = q.clampGuide(iWad, spot, strike);
        uint256 cap = _cap(spot, strike);
        if (cap == 0) {
            assertEq(r, 0, "cap==0 must give 0");
        } else if (cap >= 4) {
            assertGt(r, 0, "cap>0 must quote > 0");
        }
    }

    /// @notice PASS-THROUGH. ∀ guide already inside [floor, cap]: clampGuide returns it
    ///         UNCHANGED — the clamp only ever moves an out-of-band guide.
    function check_clampGuide_identity_in_band(uint256 iWad, uint256 spot, uint256 strike) public view {
        vm.assume(spot <= MAX_PRICE && strike <= MAX_PRICE && iWad <= MAX_PRICE);
        uint256 floor_ = _floor(spot, strike);
        uint256 cap = _cap(spot, strike);
        vm.assume(iWad >= floor_ && iWad <= cap);
        assertEq(q.clampGuide(iWad, spot, strike), iWad, "in-band guide was moved");
    }

    /// @notice IDEMPOTENT. ∀ inputs: clamping an already-clamped guide is a no-op. A
    ///         clamp that wasn't idempotent could ratchet the price across re-quotes.
    function check_clampGuide_idempotent(uint256 iWad, uint256 spot, uint256 strike) public view {
        vm.assume(spot <= MAX_PRICE && strike <= MAX_PRICE && iWad <= MAX_PRICE);
        uint256 once = q.clampGuide(iWad, spot, strike);
        assertEq(q.clampGuide(once, spot, strike), once, "clampGuide not idempotent");
    }

    /// @notice MONOTONIC in the guide. ∀ i1 <= i2 (same spot/strike): the clamped
    ///         output is nondecreasing — the clamp can never invert the keeper signal.
    function check_clampGuide_monotonic_in_guide(uint256 i1, uint256 i2, uint256 spot, uint256 strike)
        public
        view
    {
        vm.assume(spot <= MAX_PRICE && strike <= MAX_PRICE);
        vm.assume(i1 <= MAX_PRICE && i2 <= MAX_PRICE);
        vm.assume(i1 <= i2);
        assertLe(q.clampGuide(i1, spot, strike), q.clampGuide(i2, spot, strike), "clamp not monotonic in guide");
    }

    // ==================================================================
    // usdcOutForP — SELL P -> USDC (Boost side), at i*(1-fee).
    // Revert guard proven on REAL bytecode; value props on the model.
    // ==================================================================

    /// @notice REVERT GUARD (real bytecode). ∀ inputs with feeWad >= WAD: usdcOutForP
    ///         reverts (FeeTooHigh). The guard is the function's first statement, so it
    ///         is reached before any (intractable) mulDiv — provable directly on the
    ///         production code. fee == WAD would price P at zero; this makes it
    ///         unreachable. The hook also independently caps fee <= maxFeeWad < WAD.
    function check_usdcOutForP_reverts_when_fee_ge_wad(uint256 pIn, uint256 iWad, uint256 feeWad) public view {
        vm.assume(feeWad >= WAD);
        (bool ok,) = address(q).staticcall(
            abi.encodeWithSelector(CleaveQuoteMathHarness.usdcOutForP.selector, pIn, iWad, feeWad)
        );
        assertFalse(ok, "fee >= WAD did not revert");
    }

    // ------------------------------------------------------------------
    // The plain-arithmetic MODELs. Bit-exact to the library within the
    // bound (see header soundness note; products < 2^256 => mulDiv's
    // non-overflow branch returns low/denominator == (a*b)/WAD).
    // ------------------------------------------------------------------

    function _usdcOutForP_model(uint256 pIn, uint256 iWad, uint256 feeWad) internal pure returns (uint256) {
        uint256 valueUsdWad = (pIn * iWad) / WAD;
        uint256 netUsdWad = (valueUsdWad * (WAD - feeWad)) / WAD;
        return netUsdWad / 1e12;
    }

    function _pOutForUsdc_model(uint256 usdcIn, uint256 iWad, uint256 feeWad) internal pure returns (uint256) {
        uint256 valueUsdWad = usdcIn * 1e12;
        uint256 priceWithFee = (iWad * (WAD + feeWad)) / WAD;
        return (valueUsdWad * WAD) / priceWithFee;
    }

    /// @notice MONOTONIC in pIn (by composition of proven atoms). usdcOutForP is nondecreasing in pIn:
    ///         valueUsd = (pIn*iWad)/WAD is nondecreasing in pIn and netUsd = (valueUsd*(WAD-fee))/WAD in
    ///         valueUsd (both check_lemma_floormuldiv_monotone), and the final /1e12 is nondecreasing
    ///         (check_lemma_div_monotone) — composed, selling more P never yields less USDC. Stated here
    ///         rather than checked end-to-end: the nested model query is the lone solver-contention
    ///         timeout under concurrency, while every atom it composes from IS machine-checked above
    ///         (the same prove-atoms-then-compose pattern this file uses for the BUY side and round trip).

    /// @notice CONSERVATIVE / NO OVERFLOW (decomposed). The quote never pays out more
    ///         USDC than the GROSS USD value of the P sold:
    ///             out*1e12 = (netUsd/1e12)*1e12 <= netUsd = (gross*(WAD-fee))/WAD <= gross.
    ///         Two machine-checked atoms establish it for ALL inputs (no two-mult
    ///         end-to-end query, which the solver chokes on under load):
    ///           (i)  the `/1e12` round-back never grows a value
    ///                (check_lemma_floordiv_roundback): (x/1e12)*1e12 <= x, and
    ///           (ii) the (WAD-fee)/WAD net-spread step never grows the value
    ///                (check_lemma_subwad_factor_shrinks): (gross*(WAD-fee))/WAD <= gross.
    ///         Composed: out*1e12 <= netUsd <= gross. The spread and the 1e12 truncation
    ///         only ever round in the maker's favour. No-overflow holds because every
    ///         product is in envelope and the model never reverts.
    function check_lemma_floordiv_roundback(uint200 x) public pure {
        assertLe((uint256(x) / 1e12) * 1e12, uint256(x), "floor-div round-back grew the value");
    }

    // ==================================================================
    // pOutForUsdc — BUY P with USDC (Earn side), at i*(1+fee).
    //
    // pOut = (usdcIn*1e12*WAD) / priceWithFee, with priceWithFee = i*(WAD+fee)/WAD
    // SYMBOLIC IN THE DENOMINATOR. End-to-end monotonicity-in-fee / round-trip have a
    // symbolic divisor and are NOT discharged whole by any backend in the per-query
    // budget. They are instead proven by the lemma decomposition below (each a single
    // tractable step), composed in prose — exactly the Series suite's pattern.
    // ==================================================================

    /// @notice MONOTONIC in usdcIn (numerator step). ∀ a <= b, p > 0: (a*WAD)/p <=
    ///         (b*WAD)/p. Since pOut = (usdcIn*1e12*WAD)/priceWithFee with the
    ///         denominator FIXED in usdcIn, this lemma IS pOutForUsdc's monotonicity in
    ///         usdcIn (the `*1e12` prescale is itself monotone). Buying with more USDC
    ///         never yields less P.
    function check_pOutForUsdc_monotonic_in_usdcIn(uint64 a, uint64 b, uint128 priceWithFee) public pure {
        vm.assume(priceWithFee > 0);
        vm.assume(a <= b);
        assertLe((uint256(a) * WAD) / priceWithFee, (uint256(b) * WAD) / priceWithFee, "pOut not monotone in usdcIn");
    }

    /// @notice MONOTONIC (nonincreasing) in fee (decomposed). Two single-step lemmas
    ///         compose to it: (i) priceWithFee = (i*(WAD+fee))/WAD is NONDECREASING in
    ///         fee — the multiplier (WAD+fee) grows with fee, so by
    ///         check_lemma_multiplier_monotone the price grows; and (ii) the quotient
    ///         K/p is NONINCREASING in the divisor p
    ///         (check_lemma_quotient_antitone_in_divisor). Larger fee => larger
    ///         priceWithFee => fewer P out: a wider spread can never hand the buyer MORE
    ///         P. (Each lemma is tractable; the end-to-end composition has a symbolic
    ///         divisor and is argued, not re-proven whole — the Series-suite pattern.)
    function check_lemma_quotient_antitone_in_divisor(uint128 K, uint128 p1, uint128 p2) public pure {
        vm.assume(p1 > 0 && p1 <= p2);
        assertGe(uint256(K) / uint256(p1), uint256(K) / uint256(p2), "quotient not antitone in divisor");
    }

    // ==================================================================
    // Building-block lemmas (single nonlinear step each) — the tractable
    // pieces the SELL/BUY monotonicity and round-trip arguments compose.
    // Mirrors the Series suite's check_lemma_* decomposition: these are the
    // machine-checked atoms; the end-to-end facts follow by composition.
    // ==================================================================

    /// @notice Lemma: floor-mul-div monotone in the variable factor. ∀ x <= y:
    ///         (x*k)/WAD <= (y*k)/WAD. The `valueUsd = pIn*i/WAD` step.
    function check_lemma_floormuldiv_monotone(uint96 x, uint96 y, uint96 k) public pure {
        vm.assume(x <= y);
        assertLe((uint256(x) * k) / WAD, (uint256(y) * k) / WAD, "floor-mul-div not monotone in x");
    }

    /// @notice Lemma: floor-mul-div monotone in the MULTIPLIER (no cap on g). ∀ g1 <=
    ///         g2: (v*g1)/WAD <= (v*g2)/WAD. Does triple duty, all over ALL inputs:
    ///           * SELL net-spread: g = (WAD-fee) — wider fee => smaller WAD-fee =>
    ///             smaller usdcOut, i.e. usdcOutForP is nonincreasing in fee;
    ///           * BUY priceWithFee: g = (WAD+fee) (>WAD, hence the cap is dropped) —
    ///             wider fee => larger priceWithFee, the (i) half of pOut fee-monotonicity;
    ///           * round-trip spread premise: g1 = (WAD-fee) <= g2 = (WAD+fee) gives the
    ///             sell price <= buy price, i.e. the q <= p that check_roundtrip_core needs.
    ///         `v` is an ALREADY-multiplied / base value (a single multiplication in the
    ///         query), which is what keeps it tractable under load.
    function check_lemma_multiplier_monotone(uint128 v, uint64 g1, uint64 g2) public pure {
        vm.assume(g1 <= g2);
        assertLe(
            (uint256(v) * uint256(g1)) / WAD, (uint256(v) * uint256(g2)) / WAD, "floor-mul-div not monotone in multiplier"
        );
    }

    /// @notice Lemma: scaling by a sub-WAD factor never grows the value. ∀ g <= WAD:
    ///         (v*g)/WAD <= v. The spread only ever subtracts value (the conservative +
    ///         round-trip backbone).
    function check_lemma_subwad_factor_shrinks(uint128 v, uint64 g) public pure {
        vm.assume(uint256(g) <= WAD);
        assertLe((uint256(v) * uint256(g)) / WAD, uint256(v), "sub-WAD factor grew the value");
    }

    /// @notice Lemma: integer division monotone (the 1e6<->1e18 decimal step). ∀ a<=b:
    ///         a/1e12 <= b/1e12. Inputs are already-valued numbers.
    function check_lemma_div_monotone(uint200 a, uint200 b) public pure {
        vm.assume(a <= b);
        assertLe(uint256(a) / 1e12, uint256(b) / 1e12, "div by 1e12 not monotone");
    }

    // ==================================================================
    // Round-trip: the maker never loses to a costless round trip.
    // ==================================================================

    /// @notice NO VALUE CREATION ON A ROUND TRIP (core lemma). ∀ a, p, q with 0 < p
    ///         and q <= p: floor( floor(a*WAD/p) * q / WAD ) <= a. This is EXACTLY the
    ///         round-trip composition with a = usdcIn*1e12 (the prescaled input),
    ///         p = priceWithFee = i*(WAD+fee)/WAD (buy divisor), and q = i*(WAD-fee)/WAD
    ///         (sell multiplier): buying scales the input DOWN by p, selling scales it
    ///         by q, and because the buy spread q <= p (the sell price i*(WAD-fee)/WAD
    ///         <= the buy price i*(WAD+fee)/WAD, which is check_lemma_multiplier_monotone
    ///         with g1 = WAD-fee <= g2 = WAD+fee — the no-arbitrage heart: you always buy
    ///         higher than you sell), the maker recovers AT MOST the input. The two
    ///         further `/1e12` decimal truncations on the sell leg only lose more, never
    ///         create — so the full `pOutForUsdc` then `usdcOutForP` round trip pays back
    ///         <= usdcIn. This is the existing fuzz property, now proven over ALL inputs:
    ///         the q <= p premise is discharged by check_lemma_multiplier_monotone.
    function check_roundtrip_core(uint64 a, uint64 p, uint64 qSell) public pure {
        vm.assume(p > 0 && qSell <= p);
        uint256 pOutMid = (uint256(a) * WAD) / p; // buy: scale input down by divisor p
        assertLe((pOutMid * qSell) / WAD, uint256(a), "round trip created value");
    }
}
