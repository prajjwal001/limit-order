// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

// The grid's numbers: the decade d = t / PX_PER_DECADE, the mantissa PX_MANTISSA_BASE + t % PX_PER_DECADE, and the
// price per base wei in quote wei P = mantissa x 10^(d - PX_EXP_OFFSET).
uint256 constant PX_MANTISSA_BASE = 100_000;
uint256 constant PX_PER_DECADE = 900_000;
uint256 constant PX_EXP_OFFSET = 43;

/// @title PriceGrid: one significant-figures price grid for every market
/// @notice What a tick is worth. A tick is `d x 900_000 + j`, decade d in 0 .. 73 and step j in 0 .. 899_999; its
/// price is P(tick) = (100_000 + j) x 10^(d - 43) quote wei per base wei: a 6-significant-figure mantissa 1.00000 ..
/// 9.99999 (written 100_000 .. 999_999) times a power of ten from 10^-43 to 10^30. Consecutive ticks are consecutive
/// 6-figure prices, across a decade too, so P is strictly increasing and the OLO EVM contract's compares of ticks are
/// compares of prices. One step is one unit of the 6th figure, 0.1 bp of the price at the bottom of a decade and 0.01
/// bp at its top. The grid is the same in every market: P(tick 1) is about 10^-38 and P(MAX_TICK) about 10^36, so a
/// market needs no price range of its own (BTC/USDC at $100,000 is P = 1,000, tick 36,900,000; ETH/USDC at $2,500 is P
/// = 2.5e-9, tick 26,250,000).
///
/// Money. `amount` base wei at `tick` is worth amount x mantissa x 10^(d - 43) quote wei: exact in decades 43 and up,
/// a fraction below. The single-order operations round each order's amount (`quoteDown`, `quoteUp`, `feeDown`); a take
/// sums its fills exactly, aligned to the lowest decade it met, and rounds once (OloBookTakes).
///
/// Bounds. MAX_TICK < 2^26: a tick fits the 26-bit tick field of a pool word and of a batch sub-order. An order's
/// amount is units x 10^q with units below 2^30 and q at most 25 (the contract's inputs are below 2^112), so below
/// 2^114; the mantissa is below 2^20, the fee (at most 10^6 ppm) below 2^20 and 10^(d - 43) at most 10^30 < 2^100:
/// every product here stays below 2^254.
library PriceGrid {
    /// @notice Ticks start at 1: tick 0 stays unused, so a zero tick is never a live price.
    uint256 internal constant MIN_TICK = 1;

    /// @notice The lowest tick a maker may rest at: decade 4's first, P = 100_000 x 10^-39 = 10^-34 quote wei a base
    /// wei. Takes fill only at makers' ticks, so no fill is ever in a decade below 4, and a take's exact sum, aligned
    /// to the lowest decade it meets (OloBookTakes, note 3), is at most Q x 10^39: a maker repricing a listed order to
    /// the grid's bottom cannot push a take worth less than about 5.5e31 quote wei to AmountOverflow. A multiple of every spacing (1,000 divides 3,600,000). Taker entry ticks are not held to it.
    uint256 internal constant MIN_MAKER_TICK = 3_600_000;

    /// @notice d = 73, j = 899_999: P = 999_999e30.
    uint256 internal constant MAX_TICK = 66_599_999;

    /// @notice Ticks per decade (j's range).
    uint256 internal constant PER_DECADE = PX_PER_DECADE;

    /// @notice The mantissa of j = 0 (1.00000).
    uint256 internal constant MANTISSA_BASE = PX_MANTISSA_BASE;

    /// @notice Decades 0 .. 73.
    uint256 internal constant DECADES = 74;

    /// @notice P = mantissa x 10^(d - EXP_OFFSET).
    uint256 internal constant EXP_OFFSET = PX_EXP_OFFSET;

    /// @notice The significant figures of the full grid (every tick a maker tick) and the fewest a market may keep.
    uint8 internal constant MAX_SIG_FIGS = 6;
    uint8 internal constant MIN_SIG_FIGS = 3;

    uint256 private constant PPM = 1_000_000;

    /// @notice A market of `sigFigs` significant figures keeps its makers on every 10^(6 - sigFigs)th tick: a spacing
    /// of 1, 10, 100 or 1000 for 6, 5, 4 or 3 figures. 900_000 is a multiple of 1000, so a spacing never splits a
    /// decade: tick % spacing is j % spacing, and the maker ticks are the prices of `sigFigs` figures. Takers fill
    /// whatever rests, so a spacing costs a take nothing.
    function spacingOf(uint8 sigFigs) internal pure returns (uint16) {
        return uint16(10 ** uint256(MAX_SIG_FIGS - sigFigs));
    }

    /// @notice Whether a maker may rest at `tick` on a market of `spacing`: a multiple of it. The plain form for tests;
    /// the contract checks MarketLib.makerTick.
    function aligned(uint256 tick, uint256 spacing) internal pure returns (bool) {
        return tick % spacing == 0;
    }

    /// @notice `tick` rounded down (`up` false) or up to a multiple of `spacing`, as a maker's tick must be.
    function snap(uint256 tick, uint256 spacing, bool up) internal pure returns (uint256) {
        uint256 r = tick % spacing;
        if (r == 0) return tick;
        return up ? tick - r + spacing : tick - r;
    }

    /// @notice The tick's decade d and mantissa 100_000 + j (P = mantissa x 10^(d - 43)).
    function split(uint256 tick) internal pure returns (uint256 decade, uint256 mantissa) {
        return (decadeOf(tick), mantissaOf(tick));
    }

    /// @notice The tick's decade d (P = mantissa x 10^(d - 43)).
    function decadeOf(uint256 tick) internal pure returns (uint256) {
        return tick / PER_DECADE;
    }

    /// @notice The tick's mantissa, 100_000 + j: 100_000 .. 999_999 (P = mantissa x 10^(d - 43)).
    function mantissaOf(uint256 tick) internal pure returns (uint256) {
        unchecked {
            // below 100_000 + 900_000
            return MANTISSA_BASE + tick % PER_DECADE;
        }
    }

    /// @notice The tick of mantissa `mantissa` (100_000 .. 999_999) in decade `decade` (0 .. 73).
    function tickOf(uint256 decade, uint256 mantissa) internal pure returns (uint256) {
        require(decade < DECADES && mantissa >= MANTISSA_BASE && mantissa < 10 * MANTISSA_BASE, "PriceGrid: off grid");
        return decade * PER_DECADE + mantissa - MANTISSA_BASE;
    }

    /// @notice The tick of price `mantissa` x 10^`exp10` quote wei per base wei (mantissa 100_000 .. 999_999, exp10
    /// -43 .. 30): a price in decimal form (BTC/USDC $100,000: 100_000e-2, tick 36,900,000).
    function tickAt(uint256 mantissa, int256 exp10) internal pure returns (uint256) {
        return tickOf(uint256(exp10 + int256(EXP_OFFSET)), mantissa);
    }

    /// @notice `amount` base wei at `tick` in quote wei, rounded down: what an order pays out (a claim's proceeds, a
    /// bid's refund). `amount` below 2^114 and `tick` at most MAX_TICK (PriceGrid's bounds): no overflow.
    function quoteDown(uint256 amount, uint256 tick) internal pure returns (uint256) {
        unchecked {
            // amount below 2^114, mantissa below 2^20, 10^(d - 43) at most 10^30: below 2^234
            uint256 decade = tick / PER_DECADE;
            uint256 v = amount * (MANTISSA_BASE + tick % PER_DECADE);
            if (decade >= EXP_OFFSET) return v * 10 ** (decade - EXP_OFFSET);
            return v / 10 ** (EXP_OFFSET - decade);
        }
    }

    /// @notice `amount` base wei at `tick` in quote wei, rounded up: what an order takes in (a bid's escrow). Bounds as
    /// `quoteDown`.
    function quoteUp(uint256 amount, uint256 tick) internal pure returns (uint256) {
        unchecked {
            // as quoteDown: below 2^234
            uint256 decade = tick / PER_DECADE;
            uint256 v = amount * (MANTISSA_BASE + tick % PER_DECADE);
            if (decade >= EXP_OFFSET) return v * 10 ** (decade - EXP_OFFSET);
            uint256 div = 10 ** (EXP_OFFSET - decade);
            uint256 out = v / div;
            return v % div == 0 ? out : out + 1;
        }
    }

    /// @notice The fee of `amount` base wei at `tick` at `feePpm`, rounded down: what a maker's settle splits (the
    /// takes collected it rounded up). `feePpm` below 2^20; bounds as `quoteDown`.
    function feeDown(uint256 amount, uint256 tick, uint256 feePpm) internal pure returns (uint256) {
        unchecked {
            // amount below 2^114, mantissa below 2^20, feePpm below 2^20, 10^(d - 43) at most 10^30: below 2^254
            uint256 decade = tick / PER_DECADE;
            uint256 v = amount * (MANTISSA_BASE + tick % PER_DECADE) * feePpm;
            if (decade >= EXP_OFFSET) return v * 10 ** (decade - EXP_OFFSET) / PPM;
            return v / (PPM * 10 ** (EXP_OFFSET - decade));
        }
    }

    /// @notice The highest tick whose price is at most `mantissa` x 10^`exp10` for any positive integer `mantissa`
    /// (clamped to MIN_TICK .. MAX_TICK): the inverse of P, for tests and callers (the contract never calls it). It
    /// clamps to the grid, not to the makers' part of it: a caller snapping a maker's price clamps the result up to
    /// MIN_MAKER_TICK (decade 4) and to the market's spacing, or the contract refuses the order TickOutOfRange.
    function tickAtOrBelow(uint256 mantissa, int256 exp10) internal pure returns (uint256) {
        require(mantissa != 0, "PriceGrid: zero");
        // normalize the mantissa to 6 figures, moving the exponent
        while (mantissa >= 10 * MANTISSA_BASE) {
            mantissa /= 10;
            ++exp10;
        }
        while (mantissa < MANTISSA_BASE) {
            mantissa *= 10;
            --exp10;
        }
        int256 d = exp10 + int256(EXP_OFFSET);
        if (d < 0 || (d == 0 && mantissa == MANTISSA_BASE)) return MIN_TICK;
        if (d >= int256(DECADES)) return MAX_TICK;
        return uint256(d) * PER_DECADE + mantissa - MANTISSA_BASE;
    }
}
