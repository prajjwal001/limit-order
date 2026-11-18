// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {BatchView} from "./BatchView.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid, PX_EXP_OFFSET, PX_MANTISSA_BASE, PX_PER_DECADE} from "../src/libraries/PriceGrid.sol";

using MarketLib for MarketWord;

/// The one price grid (PriceGrid: tick t is decade t / 900,000 and mantissa 100,000 + t % 900,000, worth P = mantissa
/// x 10^(d - 43) quote wei per base wei in every market) and the OLO EVM contract's money on it. Every tick of decades
/// 0, 42, 43 and 73 against a decade and mantissa counted tick by tick; the bounds; every decade boundary; the inverse
/// of any price as an exact rational inequality (both normalizations, figures past the 6th truncated, the clamps at
/// either end); strictly increasing prices for any pair; tickOf's refusals; the significant figures' maker ticks; the
/// per-order roundings (quoteDown, quoteUp, feeDown) against exact rationals at every decade and within a take's one
/// rounding. Then the contract: takes at random ticks, at the grid's bottom and top and across decade boundaries, the
/// quote the exact sum rounded once, every settle exact, the contract left with exactly the roundings; and a pool order
/// and a batch slot at MAX_TICK with the largest amounts, whose fees pass 2^128 into the pot and whose proceeds go
/// through the wallet. (OloPrecise holds the worked ticks, quoteDown and quoteUp against the exact rational for amounts
/// below 2^112, and each tick's own price inverted; OloSigFig the snap's distances.)
contract OloPriceGridTest is OloBase {
    uint256 constant MIN = PriceGrid.MIN_TICK;
    uint256 constant FLOOR = PriceGrid.MIN_MAKER_TICK;
    uint256 constant MAX = PriceGrid.MAX_TICK;

    function setUp() public {
        _deploy();
    }

    // ------------------------------------------------------------------ every tick

    /// Every tick of decade `d`, in quarters of 225,000 ticks (a test's gas limit holds less than half a decade),
    /// from the step into it (the boundary step is swept with the decade above it), against a decade and mantissa
    /// counted tick by tick (not divided out of the tick): `split` gives them; `tickOf`, `tickAt` and `tickAtOrBelow`
    /// give the tick back; the price is exact: D = 10^(44 - d) base wei (1 from decade 44 up) are worth mantissa x
    /// 10^(d' - 43) x D quote wei at a tick of decade d' (d - 1 or d), an integer, by `quoteDown` and `quoteUp` alike.
    /// Consecutive ticks are consecutive 6-figure prices, one unit of the 6th figure apart, across the boundary too
    /// (999,999 x 10^(d - 44), then 100,000 x 10^(d - 43)): P strictly increases. Each quarter starts at the last tick
    /// of the one before, so every step is checked.
    function _sweep(uint256 d, uint256 part) internal pure {
        uint256 from = d * 900_000 + part * 225_000 - (d == 0 && part == 0 ? 0 : 1);
        uint256 to = d * 900_000 + (part + 1) * 225_000 - 1;
        // the decade and mantissa of `from`, then of each tick
        uint256 dd = part == 0 && d != 0 ? d - 1 : d;
        uint256 mm = part == 0 ? (d == 0 ? 100_000 : 999_999) : 99_999 + part * 225_000;
        if (from == 0) (from, mm) = (MIN, 100_001); // tick 0 is unused
        uint256 shift = d <= 44 ? 44 - d : 0;
        uint256 amt = 10 ** shift;
        // one unit of the 6th figure in D's terms: in decade d - 1 (uLo) and in decade d (uHi)
        uint256 uHi = 10 ** (d + shift - 43);
        uint256 uLo = d == 0 ? 0 : 10 ** (d - 1 + shift - 43);
        uint256 prev;
        for (uint256 t = from; t <= to; ++t) {
            (uint256 gd, uint256 gm) = PriceGrid.split(t);
            require(gd == dd && gm == mm, "split");
            require(PriceGrid.tickOf(dd, mm) == t, "tickOf");
            int256 e = int256(dd) - 43;
            require(PriceGrid.tickAt(mm, e) == t, "tickAt");
            require(PriceGrid.tickAtOrBelow(mm, e) == t, "tickAtOrBelow");
            uint256 u = dd == d ? uHi : uLo;
            uint256 p = mm * u;
            require(PriceGrid.quoteDown(amt, t) == p && PriceGrid.quoteUp(amt, t) == p, "the price, exact");
            // the step from the tick before: a unit of the 6th figure of the lower decade (at d's bottom, d - 1's)
            if (t != from) require(p - prev == (mm == 100_000 ? uLo : u), "consecutive 6-figure prices");
            prev = p;
            if (++mm == 1_000_000) {
                mm = 100_000;
                ++dd;
            }
        }
    }

    function test_every_tick_d0_part0() public pure {
        _sweep(0, 0);
    }

    function test_every_tick_d0_part1() public pure {
        _sweep(0, 1);
    }

    function test_every_tick_d0_part2() public pure {
        _sweep(0, 2);
    }

    function test_every_tick_d0_part3() public pure {
        _sweep(0, 3);
    }

    function test_every_tick_d42_part0() public pure {
        _sweep(42, 0);
    }

    function test_every_tick_d42_part1() public pure {
        _sweep(42, 1);
    }

    function test_every_tick_d42_part2() public pure {
        _sweep(42, 2);
    }

    function test_every_tick_d42_part3() public pure {
        _sweep(42, 3);
    }

    function test_every_tick_d43_part0() public pure {
        _sweep(43, 0);
    }

    function test_every_tick_d43_part1() public pure {
        _sweep(43, 1);
    }

    function test_every_tick_d43_part2() public pure {
        _sweep(43, 2);
    }

    function test_every_tick_d43_part3() public pure {
        _sweep(43, 3);
    }

    function test_every_tick_d73_part0() public pure {
        _sweep(73, 0);
    }

    function test_every_tick_d73_part1() public pure {
        _sweep(73, 1);
    }

    function test_every_tick_d73_part2() public pure {
        _sweep(73, 2);
    }

    function test_every_tick_d73_part3() public pure {
        _sweep(73, 3);
    }

    // ------------------------------------------------------------------ bounds and boundaries

    /// The grid's constants and ends: ticks 1 .. 66,599,999 (74 decades of 900,000, tick 0 unused) below 2^26 (a pool
    /// word's and a sub-order's tick field); P(1) = 100,001e-43, P(MAX) = 999,999e30; the largest order (units below
    /// 2^30 at q 25: below 2^114 base wei) at MAX_TICK and the largest fee field (2^20 - 1) computed exactly, with no
    /// overflow; at a listed fee (at most 1,000,000) every product below 2^254.
    function test_bounds() public pure {
        assertEq(MIN, 1);
        assertEq(MAX, 66_599_999);
        assertEq(MAX + 1, PriceGrid.DECADES * PriceGrid.PER_DECADE);
        assertLt(MAX, 1 << 26, "a pool word's and a sub-order's 26-bit tick field");
        assertEq(PriceGrid.PER_DECADE, 900_000);
        assertEq(PriceGrid.PER_DECADE, PX_PER_DECADE);
        assertEq(PriceGrid.MANTISSA_BASE, 100_000);
        assertEq(PriceGrid.MANTISSA_BASE, PX_MANTISSA_BASE);
        assertEq(PriceGrid.EXP_OFFSET, 43);
        assertEq(PriceGrid.EXP_OFFSET, PX_EXP_OFFSET);
        assertEq(PriceGrid.DECADES, 74);
        (uint256 d, uint256 m) = PriceGrid.split(0);
        assertEq(d, 0, "tick 0, unused");
        assertEq(m, 100_000);
        (d, m) = PriceGrid.split(MIN);
        assertEq(d, 0);
        assertEq(m, 100_001);
        (d, m) = PriceGrid.split(MAX);
        assertEq(d, 73);
        assertEq(m, 999_999);
        // P(1) = 100,001 x 10^-43
        assertEq(PriceGrid.quoteDown(1e43, MIN), 100_001);
        assertEq(PriceGrid.quoteUp(1e43, MIN), 100_001);
        assertEq(PriceGrid.quoteDown(1e43 - 1, MIN), 100_000, "rounded down");
        assertEq(PriceGrid.quoteDown(1, MIN), 0);
        assertEq(PriceGrid.quoteUp(1, MIN), 1, "rounded up");
        // P(MAX) = 999,999 x 10^30
        assertEq(PriceGrid.quoteDown(1, MAX), 999_999e30);
        assertEq(PriceGrid.quoteUp(1, MAX), 999_999e30);
        // the largest products, checked arithmetic here (an overflow would revert the test)
        uint256 big = (1 << 114) - 1;
        uint256 v = big * 999_999 * 1e30;
        assertEq(PriceGrid.quoteDown(big, MAX), v);
        assertEq(PriceGrid.quoteUp(big, MAX), v);
        uint256 vf = big * 999_999 * ((1 << 20) - 1) * 1e30;
        assertEq(PriceGrid.feeDown(big, MAX, (1 << 20) - 1), vf / 1e6, "the fee field's largest value, exact");
        uint256 vl = big * 999_999 * 1_000_000 * 1e30;
        assertLt(vl, 1 << 254, "at a listed fee the products stay below 2^254");
        assertEq(PriceGrid.feeDown(big, MAX, 1_000_000), vl / 1e6);
    }

    /// Across each of the 73 decade boundaries: 999,999 x 10^(k-44) then 100,000 x 10^(k-43), the step below one unit
    /// of decade k - 1's 6th figure and the step above one of decade k's (ten times it); `split` either side; `tickAt`
    /// of both prices; `tickAtOrBelow` of the boundary's price written with one figure (1 x 10^(k-38): normalized up),
    /// with seven (10,000,000 x 10^(k-45)), and of the price just below it (9,999,999 x 10^(k-45): the 7th figure
    /// truncated, the tick below).
    function test_decade_boundaries() public pure {
        for (uint256 k = 1; k < PriceGrid.DECADES; ++k) {
            uint256 bt = k * 900_000;
            (uint256 d, uint256 m) = PriceGrid.split(bt - 1);
            assertEq(d, k - 1);
            assertEq(m, 999_999);
            (d, m) = PriceGrid.split(bt);
            assertEq(d, k);
            assertEq(m, 100_000);
            (d, m) = PriceGrid.split(bt + 1);
            assertEq(d, k);
            assertEq(m, 100_001);
            uint256 shift = k <= 44 ? 44 - k : 0;
            uint256 u = 10 ** (k - 1 + shift - 43); // one unit of decade k - 1's 6th figure, at 10^shift base wei
            assertEq(PriceGrid.quoteDown(10 ** shift, bt - 1), 999_999 * u, "top of decade k - 1");
            assertEq(PriceGrid.quoteDown(10 ** shift, bt), 1_000_000 * u, "bottom of decade k");
            assertEq(PriceGrid.quoteDown(10 ** shift, bt + 1), 1_000_010 * u, "a step of decade k is ten");
            int256 e = int256(k) - 43;
            assertEq(PriceGrid.tickAt(100_000, e), bt);
            assertEq(PriceGrid.tickAt(999_999, e - 1), bt - 1);
            assertEq(PriceGrid.tickAtOrBelow(1, e + 5), bt, "one figure, normalized up");
            assertEq(PriceGrid.tickAtOrBelow(10_000_000, e - 2), bt, "seven figures, exactly the boundary");
            assertEq(PriceGrid.tickAtOrBelow(9_999_999, e - 2), bt - 1, "just below: the 7th figure truncated");
        }
    }

    // ------------------------------------------------------------------ the inverse

    /// m1 x 10^e1 against m2 x 10^e2, exactly: -1, 0 or 1. Mantissas from 1 to 2^128 - 1 (fewer than 39 digits), so a
    /// power of ten that puts one side past the other's digits decides it, and otherwise the product is below 2^255.
    function _cmp(uint256 m1, int256 e1, uint256 m2, int256 e2) internal pure returns (int256) {
        require(m1 != 0 && m2 != 0 && m1 < 1 << 128 && m2 < 1 << 128, "_cmp: mantissas");
        if (e1 >= e2) {
            uint256 k = uint256(e1 - e2);
            if (k >= 39) return 1;
            uint256 a = m1 * 10 ** k;
            return a > m2 ? int256(1) : a == m2 ? int256(0) : -1;
        }
        return -_cmp(m2, e2, m1, e1);
    }

    /// P(t) as a mantissa and a power of ten (the definition, divided here rather than split).
    function _p(uint256 t) internal pure returns (uint256 m, int256 e) {
        return (100_000 + t % 900_000, int256(t / 900_000) - 43);
    }

    /// The inverse of any price X = mantissa x 10^exp10 (any positive mantissa below 2^128, exponents -100 .. 100: from
    /// far below the grid to far above): the tick returned is the highest whose price is at most X, compared as exact
    /// rationals, clamped to MIN_TICK below P(1) and to MAX_TICK from P(MAX) up.
    function testFuzz_inverse_of_any_price(uint256 mantissa, int256 exp10) public pure {
        mantissa = bound(mantissa, 1, (1 << 128) - 1);
        exp10 = bound(exp10, -100, 100);
        uint256 t = PriceGrid.tickAtOrBelow(mantissa, exp10);
        assertGe(t, MIN);
        assertLe(t, MAX);
        (uint256 m1, int256 e1) = _p(MIN);
        if (_cmp(mantissa, exp10, m1, e1) < 0) {
            assertEq(t, MIN, "below P(1): clamped to MIN_TICK");
            return;
        }
        (uint256 m, int256 e) = _p(t);
        assertLe(_cmp(m, e, mantissa, exp10), 0, "P(t) <= X");
        if (t < MAX) {
            (m, e) = _p(t + 1);
            assertGt(_cmp(m, e, mantissa, exp10), 0, "P(t + 1) > X: the highest such tick");
        }
    }

    /// Any price inside a tick's step maps back to it: mantissa x 10^j + r (r below 10^j, j up to 30 figures past the
    /// 6th) at 10^(d - 43 - j) is P(t) plus less than one unit of its 6th figure.
    function testFuzz_inverse_inside_the_step(uint256 t, uint256 j, uint256 r) public pure {
        t = bound(t, MIN, MAX);
        j = bound(j, 1, 30);
        r = bound(r, 0, 10 ** j - 1);
        (uint256 m, int256 e) = _p(t);
        assertEq(PriceGrid.tickAtOrBelow(m * 10 ** j + r, e - int256(j)), t);
    }

    /// The clamps and the refusals: nothing below P(1) (P(0) = 1e-38 itself included, as tick 0 is no price) maps
    /// below MIN_TICK, nothing from P(MAX) up past MAX_TICK, whatever the exponent or the mantissa's length; a zero
    /// mantissa is refused.
    function test_inverse_clamps() public {
        assertEq(PriceGrid.tickAtOrBelow(1, -44), MIN, "1e-44");
        assertEq(PriceGrid.tickAtOrBelow(100_000, -43), MIN, "P(0) = 1e-38: no tick, clamped");
        assertEq(PriceGrid.tickAtOrBelow(100_001, -43), 1);
        assertEq(PriceGrid.tickAtOrBelow(100_002, -43), 2);
        assertEq(PriceGrid.tickAtOrBelow(1_000_019, -44), 1, "P(1) and a 7th figure");
        assertEq(PriceGrid.tickAtOrBelow(1, -1000), MIN);
        assertEq(PriceGrid.tickAtOrBelow(999_998, 30), MAX - 1);
        assertEq(PriceGrid.tickAtOrBelow(999_999, 30), MAX);
        assertEq(PriceGrid.tickAtOrBelow(9_999_999, 29), MAX, "P(MAX) and a 7th figure");
        assertEq(PriceGrid.tickAtOrBelow(1, 35), 73 * 900_000, "1e35: decade 73's first tick");
        assertEq(PriceGrid.tickAtOrBelow(1, 36), MAX, "1e36: past P(MAX), clamped");
        assertEq(PriceGrid.tickAtOrBelow(1, 1000), MAX);
        assertEq(PriceGrid.tickAtOrBelow(type(uint256).max, -1000), MIN, "78 figures, normalized down");
        assertEq(PriceGrid.tickAtOrBelow(type(uint256).max, 0), MAX);
        // 2^256 - 1 is 1.15792... x 10^77: at 10^-110 it is 115,792.08... x 10^-38, decade 5
        assertEq(PriceGrid.tickAtOrBelow(type(uint256).max, -110), PriceGrid.tickOf(5, 115_792));
        vm.expectRevert(bytes("PriceGrid: zero"));
        this.tickAtOrBelowExt(0, 0);
    }

    function tickAtOrBelowExt(uint256 mantissa, int256 exp10) external pure returns (uint256) {
        return PriceGrid.tickAtOrBelow(mantissa, exp10);
    }

    /// Any two ticks: the higher one's price is strictly higher, compared as exact rationals.
    function testFuzz_monotonic_pairs(uint256 x, uint256 y) public pure {
        uint256 lo = bound(x, MIN, MAX);
        uint256 hi = bound(y, MIN, MAX);
        if (lo > hi) (lo, hi) = (hi, lo);
        (uint256 m1, int256 e1) = _p(lo);
        (uint256 m2, int256 e2) = _p(hi);
        int256 c = _cmp(m1, e1, m2, e2);
        if (lo == hi) assertEq(c, 0);
        else assertEq(c, -1, "a higher tick is a higher price");
        (uint256 gd, uint256 gm) = PriceGrid.split(lo);
        assertEq(gm, m1);
        assertEq(int256(gd) - 43, e1);
    }

    /// tickOf and tickAt refuse a decade past 73 and a mantissa outside 100,000 .. 999,999 (and tickAt an exponent
    /// outside -43 .. 30); the grid's two ends and the unused tick 0 are what they give at the edges.
    function test_tickOf_rejects_off_grid() public {
        vm.expectRevert(bytes("PriceGrid: off grid"));
        this.tickOfExt(74, 100_000);
        vm.expectRevert(bytes("PriceGrid: off grid"));
        this.tickOfExt(0, 99_999);
        vm.expectRevert(bytes("PriceGrid: off grid"));
        this.tickOfExt(0, 1_000_000);
        vm.expectRevert(bytes("PriceGrid: off grid"));
        this.tickOfExt(type(uint256).max, 100_000);
        vm.expectRevert(bytes("PriceGrid: off grid"));
        this.tickAtExt(100_000, -44);
        vm.expectRevert(bytes("PriceGrid: off grid"));
        this.tickAtExt(100_000, 31);
        vm.expectRevert(bytes("PriceGrid: off grid"));
        this.tickAtExt(1_000_000, 0);
        assertEq(this.tickOfExt(73, 999_999), MAX);
        assertEq(this.tickAtExt(999_999, 30), MAX);
        assertEq(this.tickAtExt(100_001, -43), MIN);
        assertEq(this.tickOfExt(0, 100_000), 0, "tick 0: a price, but never a maker's tick");
    }

    function tickOfExt(uint256 decade, uint256 mantissa) external pure returns (uint256) {
        return PriceGrid.tickOf(decade, mantissa);
    }

    function tickAtExt(uint256 mantissa, int256 exp10) external pure returns (uint256) {
        return PriceGrid.tickAt(mantissa, exp10);
    }

    // ------------------------------------------------------------------ significant figures

    /// 6, 5, 4 and 3 figures keep makers on every 1st, 10th, 100th and 1000th tick; a decade is 900,000 ticks, a
    /// multiple of every spacing. At the grid's top MAX_TICK (mantissa 999,999) is a maker tick at 6 figures only:
    /// below, the last maker tick is MAX_TICK less its remainder, and a snap up from above it leaves the grid
    /// (74 x 900,000, which a place refuses TickOutOfRange), so a caller snaps down there.
    function test_spacing_and_the_top() public pure {
        assertEq(PriceGrid.MAX_SIG_FIGS, 6);
        assertEq(PriceGrid.MIN_SIG_FIGS, 3);
        uint256[4] memory spacings = [uint256(1), 10, 100, 1000];
        for (uint8 sf = 6; sf >= 3; --sf) {
            uint256 sp = PriceGrid.spacingOf(sf);
            assertEq(sp, spacings[6 - sf]);
            assertEq(PriceGrid.PER_DECADE % sp, 0, "a spacing never splits a decade");
            uint256 last = MAX - MAX % sp;
            assertTrue(PriceGrid.aligned(last, sp));
            assertEq(PriceGrid.snap(MAX, sp, false), last);
            if (sf == 6) {
                assertEq(last, MAX);
                assertEq(PriceGrid.snap(MAX, sp, true), MAX);
            } else {
                assertEq(last, 66_600_000 - sp);
                assertEq(PriceGrid.snap(MAX, sp, true), 66_600_000, "past the grid");
            }
        }
    }

    /// The significant figures of a 6-figure mantissa: 6 less its trailing zeros.
    function _figs(uint256 m) internal pure returns (uint256 n) {
        n = 6;
        while (m % 10 == 0) {
            m /= 10;
            --n;
        }
    }

    /// A market of `sf` figures keeps its makers on the prices of `sf` significant figures: a tick is aligned exactly
    /// when its mantissa has at most `sf` figures, and the snaps go to the mantissa rounded down or up to a multiple of
    /// the spacing, in the tick's decade or (rounded up from a decade's top) the next decade's first tick.
    function testFuzz_maker_ticks_are_sig_fig_prices(uint256 t, uint8 sfSel) public pure {
        uint8 sf = uint8(3 + sfSel % 4);
        uint256 sp = PriceGrid.spacingOf(sf);
        t = bound(t, MIN, MAX);
        uint256 d = t / 900_000;
        uint256 m = 100_000 + t % 900_000;
        assertEq(PriceGrid.aligned(t, sp), _figs(m) <= sf, "aligned: at most sf figures");
        uint256 down = m / sp * sp;
        uint256 up = (m + sp - 1) / sp * sp;
        assertEq(PriceGrid.snap(t, sp, false), d * 900_000 + down - 100_000, "snap down");
        uint256 upTick = up == 1_000_000 ? (d + 1) * 900_000 : d * 900_000 + up - 100_000;
        assertEq(PriceGrid.snap(t, sp, true), upTick, "snap up");
        assertLe(_figs(down), sf);
        if (up < 1_000_000) assertLe(_figs(up), sf);
    }

    // ------------------------------------------------------------------ roundings

    /// quoteDown, quoteUp and feeDown at every decade against the exact rational N / D, as floor and ceiling
    /// inequalities: amounts below 2^114 (the largest an order stores), any tick, any fee the 20-bit field holds. N =
    /// amount x mantissa x 10^(d - 43) and D = 1 from decade 43 up, N = amount x mantissa and D = 10^(43 - d) below
    /// (N below 2^234, times the fee below 2^254).
    function testFuzz_roundings_against_exact_rationals(uint256 amount, uint256 tick, uint256 ppm) public pure {
        amount = bound(amount, 0, (1 << 114) - 1);
        tick = bound(tick, MIN, MAX);
        ppm = bound(ppm, 0, (1 << 20) - 1);
        uint256 d = tick / 900_000;
        uint256 n = amount * (100_000 + tick % 900_000) * (d >= 43 ? 10 ** (d - 43) : 1);
        uint256 den = d >= 43 ? 1 : 10 ** (43 - d);
        uint256 down = PriceGrid.quoteDown(amount, tick);
        uint256 up = PriceGrid.quoteUp(amount, tick);
        assertTrue(down * den <= n && n < (down + 1) * den, "quoteDown = floor(N / D)");
        assertTrue(up * den >= n && (up == 0 || (up - 1) * den < n), "quoteUp = ceil(N / D)");
        assertLe(up - down, 1);
        uint256 fee = PriceGrid.feeDown(amount, tick, ppm);
        uint256 nf = n * ppm;
        uint256 df = den * 1e6;
        assertTrue(fee * df <= nf && nf < (fee + 1) * df, "feeDown = floor(N x ppm / (D x 10^6))");
    }

    /// The per-order roundings sit within a take's one rounding, which is what keeps the contract solvent: over up to 8
    /// fills in a window of 4 decades anywhere on the grid, the makers' quotes rounded down sum to at most the exact
    /// sum rounded down (what a sell receives, before the fee), the escrows rounded up to at least it rounded up (what
    /// a buy pays), and the makers' fees floored to at most the fee the take collects (the exact sum's, rounded up).
    /// Exact sum: amounts x mantissa x 10^(d - L) over the window's bottom decade L, below 2^134.
    function testFuzz_per_order_rounding_within_the_take(uint256 seed, uint256 ppm) public pure {
        ppm = bound(ppm, 0, 1_000_000);
        uint256 n = 1 + seed % 8;
        uint256 low = (seed >> 8) % 71; // decades low .. low + 3
        uint256 sum;
        uint256 downs;
        uint256 ups;
        uint256 fees;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 tick = bound(low * 900_000 + r % 3_600_000, MIN, MAX);
            uint256 amount = (1 + (r >> 32) % (1 << 30)) * 10 ** ((r >> 64) % 22); // below 2^104
            sum += amount * (100_000 + tick % 900_000) * 10 ** (tick / 900_000 - low);
            downs += PriceGrid.quoteDown(amount, tick);
            ups += PriceGrid.quoteUp(amount, tick);
            fees += PriceGrid.feeDown(amount, tick, ppm);
        }
        uint256 qDown;
        uint256 qUp;
        uint256 feeUp;
        if (low >= 43) {
            qDown = sum * 10 ** (low - 43);
            qUp = qDown;
            feeUp = _divUp(qDown * ppm, 1e6);
        } else {
            uint256 den = 10 ** (43 - low);
            qDown = sum / den;
            qUp = _divUp(sum, den);
            feeUp = _divUp(sum * ppm, den * 1e6);
        }
        assertLe(downs, qDown, "proceeds rounded down per order: at most the sum rounded down");
        assertGe(ups, qUp, "escrows rounded up per order: at least the sum rounded up");
        assertLe(qUp - downs, n, "less than a wei per order");
        assertLe(fees, feeUp, "the fees floored per order: at most the take's fee");
    }

    function _divUp(uint256 x, uint256 d) internal pure returns (uint256) {
        return x / d + (x % d == 0 ? 0 : 1);
    }

    // ------------------------------------------------------------------ money on the contract

    uint8[3] decs = [6, 8, 18];
    MockERC20 b;
    MockERC20 q;
    MarketWord cg;

    /// A market of `bd` / `qd`-decimal mocks at 6 figures, a fee of `fee` ppm, no minQuote (an order of one unit rests
    /// anywhere on the grid), the makers' share `share` bps.
    function _grid(uint8 bd, uint8 qd, uint24 fee, uint16 share) internal {
        b = new MockERC20("B", "B", bd);
        q = new MockERC20("Q", "Q", qd);
        uint32 id = book.listMarketQuote(address(b), address(q), fee, 6, 0, 0);
        if (share != book.configOf(id).makerBps()) book.setMarketMakerShare(id, share);
        cg = book.configOf(id); // the version at `share`
        _wallet(taker);
    }

    /// `a` with 2^250 of each grid token in its wallet, approved: every flow here settles through the wallet, as an
    /// account holds at most 2^128 - 1 and the top of the grid moves more.
    function _wallet(address a) internal {
        b.mint(a, 1 << 250);
        q.mint(a, 1 << 250);
        vm.startPrank(a);
        b.approve(address(book), type(uint256).max);
        q.approve(address(book), type(uint256).max);
        vm.stopPrank();
    }

    /// The exact quote of `amount` at `tick` as N / D (D = 1 from decade 43 up).
    function _nd(uint256 amount, uint256 tick) internal pure returns (uint256 n, uint256 den) {
        uint256 d = tick / 900_000;
        n = amount * (100_000 + tick % 900_000) * (d >= 43 ? 10 ** (d - 43) : 1);
        den = d >= 43 ? 1 : 10 ** (43 - d);
    }

    struct Fill {
        uint256 tick;
        uint256 stored; // the order's amount as stored (units x 10^q)
        uint256 unit;
        uint256 filled;
    }

    /// A take's expected fills and money: three orders in list order, each min(open, floor(remaining / 10^q)) whole
    /// units; the exact sum over the lowest decade met, rounded once (a buy up, a sell down), the fee on it rounded up.
    function _expect(Fill[3] memory f, uint256 want, uint256 ppm, bool buy)
        internal
        pure
        returns (uint256 filled, uint256 quoteX, uint256 feeX)
    {
        uint256 low = type(uint256).max;
        for (uint256 i; i < 3; ++i) {
            uint256 d = f[i].tick / 900_000;
            if (d < low) low = d;
        }
        uint256 rem = want;
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            uint256 x = rem / f[i].unit;
            if (x > f[i].stored / f[i].unit) x = f[i].stored / f[i].unit;
            f[i].filled = x * f[i].unit;
            rem -= f[i].filled;
            filled += f[i].filled;
            sum += f[i].filled * (100_000 + f[i].tick % 900_000) * 10 ** (f[i].tick / 900_000 - low);
        }
        if (low >= 43) {
            quoteX = sum * 10 ** (low - 43);
            feeX = _divUp(quoteX * ppm, 1e6);
        } else {
            uint256 den = 10 ** (43 - low);
            quoteX = buy ? _divUp(sum, den) : sum / den;
            feeX = _divUp(sum * ppm, den * 1e6);
        }
    }

    /// Three makers at t0, t0 +- 1, t0 +- 2 (at the makers' floor, decade 4's first tick, at the grid's top, straddling
    /// a decade boundary, or anywhere), on 6 / 8 / 18-decimal tokens, amounts up to 2^100 base wei (q 0 to 21), a random fee and maker share;
    /// a take of a random size, everything through the wallet. The take fills whole units in list order and pays (a
    /// buy) or receives (a sell, or SellBelowFee) the exact sum rounded once and the fee on it rounded up; every
    /// maker's cancel pays its fills' quote rounded down (a bid: refunds its open quote rounded down) and its part of
    /// the floored fee, the pot the rest; base comes out to the wei and the contract keeps exactly the roundings: what
    /// the take and the escrows brought in less every per-order payout, never less than zero.
    function testFuzz_take_rounding_and_solvency(
        uint8 bdSel,
        uint8 qdSel,
        uint256 tickSeed,
        uint256 amtSeed,
        uint256 want,
        bool buy,
        uint24 fee,
        uint16 share
    ) public {
        fee = uint24(bound(fee, 0, 1_000_000));
        share = uint16(bound(share, 0, 10_000));
        _grid(decs[bdSel % 3], decs[qdSel % 3], fee, share);
        uint256 t0;
        uint256 k = tickSeed % 4;
        if (k == 0) {
            t0 = buy ? FLOOR : FLOOR + 2; // the makers' floor (no maker rests below it)
        } else if (k == 1) {
            t0 = buy ? MAX - 2 : MAX; // the top
        } else if (k == 2) {
            uint256 bt = (5 + (tickSeed >> 8) % 69) * 900_000; // across a decade boundary, above the floor
            t0 = buy ? bt - 1 : bt + 1;
        } else {
            t0 = bound(tickSeed >> 8, FLOOR + 2, MAX - 2);
        }
        Fill[3] memory f;
        address[3] memory mk;
        bytes memory entries;
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            uint256 r = uint256(keccak256(abi.encode(amtSeed, i)));
            uint256 amount = (1 + r % (1 << 20)) << ((r >> 32) % 81); // 1 .. below 2^101
            if (amount >= 1 << 100) amount >>= 1;
            f[i].tick = buy ? t0 + i : t0 - i;
            (uint256 qq, uint256 units) = _units(amount);
            f[i].unit = 10 ** qq;
            f[i].stored = units * f[i].unit;
            total += f[i].stored;
            mk[i] = address(uint160(0xA000 + i));
            _wallet(mk[i]);
            vm.prank(mk[i]);
            book.place(OloOps.key(cg), OloOps.placeW(!buy, f[i].tick, amount, uint32(i + 1), 0x02));
            entries = bytes.concat(entries, OloOps.poolEntry(uint32(i + 1), f[i].tick));
        }
        want = bound(want, 1, total + total / 8 + 1);
        (uint256 filled, uint256 quoteX, uint256 feeX) = _expect(f, want, fee, buy);
        uint256 qBook = q.balanceOf(address(book)); // the bids' escrows
        vm.prank(taker);
        if (!buy && filled != 0 && feeX >= quoteX) {
            vm.expectRevert(IOloBookBase.SellBelowFee.selector);
            book.take(OloOps.key(cg), OloOps.poolList(entries), OloOps.tagW(cg, OloOps.takeW(buy, want, 0x01)));
            filled = 0;
        } else {
            (uint256 got, uint256 qa) =
                book.take(OloOps.key(cg), OloOps.poolList(entries), OloOps.tagW(cg, OloOps.takeW(buy, want, 0x01)));
            assertEq(got, filled, "whole units in list order");
            assertEq(qa, buy ? quoteX + feeX : quoteX - feeX, "the exact sum rounded once, the fee on it rounded up");
            qBook = buy ? qBook + qa : qBook - qa;
        }
        if (filled == 0) {
            for (uint256 i; i < 3; ++i) {
                f[i].filled = 0;
            }
        }
        // every maker cancels through the wallet: exact per-order payouts, the floored fee split by the share
        uint256 potX;
        for (uint256 i; i < 3; ++i) {
            uint256 open = f[i].stored - f[i].filled;
            uint256 feeI = PriceGrid.feeDown(f[i].filled, f[i].tick, fee);
            (uint256 n, uint256 den) = _nd(f[i].filled, f[i].tick);
            (uint256 no, uint256 deno) = _nd(open, f[i].tick);
            uint256 quoteOut = buy ? n / den : no / deno;
            uint256 makerFee = feeI * share / 10_000;
            potX += feeI - makerFee;
            uint256 wb = b.balanceOf(mk[i]);
            uint256 wq = q.balanceOf(mk[i]);
            vm.prank(mk[i]);
            book.cancel(OloOps.key(cg), OloOps.tagW(cg, OloOps.posW(uint32(i + 1), 0x02)));
            assertEq(b.balanceOf(mk[i]) - wb, buy ? open : f[i].filled, "the maker's base");
            assertEq(q.balanceOf(mk[i]) - wq, quoteOut + makerFee, "the maker's quote and its part of the fee");
            qBook -= quoteOut + makerFee;
        }
        uint256 pot = book.balanceOf(book.tokenId(address(q)), address(0));
        assertEq(pot, potX, "the pot: the fees less the makers' parts");
        book.collectFees(address(q));
        qBook -= potX;
        assertEq(b.balanceOf(address(book)), 0, "base to the wei");
        assertEq(q.balanceOf(address(book)), qBook, "the book keeps exactly the roundings");
    }

    /// An order's q and units (the smallest q with amount / 10^q below 2^30).
    function _units(uint256 amount) internal pure returns (uint256 qq, uint256 units) {
        while (amount / 10 ** qq >= 1 << 30) {
            ++qq;
        }
        units = amount / 10 ** qq;
    }

    /// The largest order the contract takes at the grid's top: 2^112 - 1 base wei (stored as units of 10^25) at
    /// MAX_TICK, about 2^232 quote wei. A bid escrows exactly amount x P through the wallet and its cancel refunds it
    /// exactly; an ask of the same size, bought whole, pays its quote and a 50% fee (both past 2^128); the maker's
    /// claim through its accounts reverts AmountOverflow and through the wallet pays the proceeds; at a share of 0 the
    /// pot holds the whole fee and `collectFees` pays it out; the contract keeps nothing (the top decade's quotes are
    /// integers, and the fee rounds once).
    function test_extreme_top_of_grid() public {
        _grid(18, 6, 500_000, 0);
        uint256 amount = (1 << 112) - 1;
        (uint256 qq, uint256 units) = _units(amount);
        assertEq(qq, 25);
        uint256 stored = units * 10 ** qq;
        uint256 value = stored * 999_999e30; // checked: no overflow
        assertGt(value, 1 << 231);
        address a = address(0xA11CE);
        _wallet(a);
        uint256 w0 = q.balanceOf(a);
        vm.startPrank(a);
        book.place(OloOps.key(cg), OloOps.placeW(true, MAX, amount, 1, 0x02));
        assertEq(w0 - q.balanceOf(a), value, "escrowed exactly stored x P");
        book.cancel(OloOps.key(cg), OloOps.tagW(cg, OloOps.posW(1, 0x02)));
        assertEq(q.balanceOf(a), w0, "refunded in full");
        book.place(OloOps.key(cg), OloOps.placeW(false, MAX, amount, 2, 0x02));
        vm.stopPrank();
        uint256 tq = q.balanceOf(taker);
        vm.prank(taker);
        (uint256 got, uint256 paid) = book.take(
            OloOps.key(cg), OloOps.poolList(OloOps.poolEntry(2, MAX)), OloOps.tagW(cg, OloOps.takeW(true, amount, 0x01))
        );
        uint256 feeX = _divUp(value, 2);
        assertEq(got, stored);
        assertEq(paid, value + feeX);
        assertEq(tq - q.balanceOf(taker), paid);
        assertGt(feeX, type(uint128).max, "the fee alone is past an account");
        vm.prank(a);
        vm.expectRevert(IOloBookBase.AmountOverflow.selector);
        book.claim(OloOps.key(cg), OloOps.tagW(cg, OloOps.posW(2, 0)));
        uint256 wq = q.balanceOf(a);
        vm.prank(a);
        assertEq(book.claim(OloOps.key(cg), OloOps.tagW(cg, OloOps.posW(2, 0x02))), value);
        assertEq(q.balanceOf(a) - wq, value, "the proceeds through the wallet; the maker's part of the fee is 0");
        uint256 qId = book.tokenId(address(q));
        assertEq(book.balanceOf(qId, address(0)), value / 2, "the pot holds the whole floored fee");
        assertEq(book.collectFees(address(q)), value / 2);
        assertEq(b.balanceOf(address(book)), 0);
        assertEq(q.balanceOf(address(book)), feeX - value / 2, "the fee's one rounding up");
    }

    /// A sell of `amount` into sub-order `k` of `z`'s slot 0 at MAX_TICK, through the wallet: it receives the exact
    /// quote less the 0.3% fee rounded up. Returns the fee floored (what the sub-order's settle splits) and the take's
    /// rounding up past it.
    function _sellAtTheTop(address z, uint256 k, uint256 amount) internal returns (uint256 floored, uint256 rounding) {
        uint256 tq = q.balanceOf(taker);
        vm.prank(taker);
        (uint256 f, uint256 got) = book.take(
            OloOps.key(cg),
            OloOps.batchList(OloOps.slotGroupAt(z, 0, uint8(1 << k), MAX)),
            OloOps.tagW(cg, OloOps.takeW(false, amount, 0x01))
        );
        uint256 quoteX = amount * 999_999e30;
        uint256 feeX = _divUp(quoteX * 3000, 1e6);
        assertEq(f, amount);
        assertEq(got, quoteX - feeX, "the exact quote less the fee rounded up");
        assertEq(q.balanceOf(taker) - tq, got);
        floored = quoteX * 3000 / 1e6;
        rounding = feeX - floored;
    }

    /// A batch slot at the grid's top: four bids at MAX_TICK of the largest amounts (2^112 - 1, 10^33 + 7,
    /// 1.23456789e28, 2^100; q 25, 24, 20 and 22), posted through the wallet at a 0.3% fee and a maker share of 0. The
    /// post escrows exactly stored x P each; two sells of one unit part-fill sub-orders 0 and 1, a third fills
    /// sub-order 2 whole; every sell receives its exact quote less the fee rounded up. Cancelling all through the
    /// accounts would refund more than an account holds (AmountOverflow); through the wallet it refunds the open
    /// amounts and pays the fills' base exactly, the fees floored per sub-order go to the pot (past 2^128), and the
    /// contract keeps the takes' fee roundings alone.
    function test_batch_at_the_top() public {
        _grid(6, 6, 3000, 0);
        uint256 px = 999_999e30;
        uint256[4] memory amounts = [uint256((1 << 112) - 1), 1e33 + 7, 123_456_789e20, 1 << 100];
        uint256[4] memory stored;
        uint256[4] memory unit;
        uint256[4] memory subs;
        uint256 escrow;
        for (uint256 i; i < 4; ++i) {
            (uint256 qq, uint256 units) = _units(amounts[i]);
            unit[i] = 10 ** qq;
            stored[i] = units * unit[i];
            subs[i] = OloOps.sub(MAX, amounts[i]);
            escrow += stored[i] * px;
        }
        address z = address(0xBA7C4);
        _wallet(z);
        uint256 w0 = q.balanceOf(z);
        vm.prank(z);
        _mb(cg, OloOps.batchW(OloOps.POST, true, 0, 0x02, 0, subs));
        assertEq(w0 - q.balanceOf(z), escrow, "the post escrows stored x P per sub-order, exactly");
        // two part fills of one unit, then a whole one
        uint256[3] memory sold = [unit[0], unit[1], stored[2]];
        uint256 feeRounding;
        uint256 feeFloored;
        for (uint256 k; k < 3; ++k) {
            (uint256 floored, uint256 rounding) = _sellAtTheTop(z, k, sold[k]);
            feeFloored += floored;
            feeRounding += rounding;
        }
        (uint256 word, uint256 set) = book.batchOf(cg, z, 0);
        assertEq(BatchView.openOf(word, 0), stored[0] - unit[0]);
        assertEq(BatchView.filledOf(word, set, 1), unit[1]);
        assertEq(BatchView.filledOf(word, set, 2), stored[2]);
        assertEq(BatchView.openOf(word, 3), stored[3]);
        // the cancel of all: through the accounts the refunds pass 2^128 - 1; through the wallet they are paid
        vm.prank(z);
        vm.expectRevert(IOloBookBase.AmountOverflow.selector);
        _mb(cg, OloOps.maskW(OloOps.CANCEL, 0, 0, 0xf));
        uint256 q0 = q.balanceOf(z);
        uint256 b0 = b.balanceOf(z);
        vm.prank(z);
        _mb(cg, OloOps.maskW(OloOps.CANCEL, 0, 0x02, 0xf));
        uint256 refunds = (stored[0] - unit[0] + stored[1] - unit[1] + stored[3]) * px;
        assertEq(q.balanceOf(z) - q0, refunds, "the open amounts' quote, exactly; the maker's part of the fee is 0");
        assertEq(b.balanceOf(z) - b0, unit[0] + unit[1] + stored[2], "the fills' base");
        uint256 qId = book.tokenId(address(q));
        assertEq(book.balanceOf(qId, address(0)), feeFloored, "the pot: the fees floored per sub-order");
        assertGt(feeFloored, type(uint128).max, "past an account");
        book.collectFees(address(q));
        assertEq(b.balanceOf(address(book)), 0);
        assertEq(q.balanceOf(address(book)), feeRounding, "the takes' fee roundings alone");
    }
}
