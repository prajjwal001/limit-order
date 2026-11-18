// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {U512, Wide} from "./utils/Wide.sol";

/// A take's money by brute force, for the differential fuzz (OloQuoteRef.t.sol) to hold the OLO EVM contract to: every
/// fill's exact quote as a 512-bit numerator over one fixed denominator, 10^43 (the finest decade of the grid), so
/// nothing is aligned, scaled or rounded on the way; quote mode's units found by binary search against the budget
/// written as it is specified (a buy: the quote and the fee, each rounded up, within the amount), not as the contract
/// computes it (no closed-form budget, no cap, no re-alignment, no nested floors). The contract's walk (skips, entry
/// ticks, the order of the list) is mirrored by the test; this library does the arithmetic.
library TakeRef {
    using Wide for U512;

    uint256 internal constant PPM = 1e6;
    uint256 internal constant PER_DECADE = 900_000;
    uint256 internal constant MANTISSA_BASE = 100_000;
    uint256 internal constant DEN_EXP = 43; // the denominator 10^43
    /// The largest whole budget a quote-mode sell may carry: one past it the OLO EVM contract refuses (AmountOverflow)
    /// at the first order its walk reaches that is open, on the other side and within its entry's tick.
    uint256 internal constant BUDGET_LIMIT = 1 << 126;

    struct Take {
        bool buy;
        bool inQuote;
        uint256 amount; // base wei, or quote wei in quote mode
        uint256 feePpm;
    }

    /// The running state: the exact quote x 10^43, the base filled, the fills, and (quote mode) the cheapest unit
    /// whose order the budget stopped short of its open units, as its exact quote x 10^43 (zero while none).
    struct Walk {
        U512 num;
        uint256 base;
        uint256 count;
        U512 minStopUnit;
        bool stopped;
    }

    /// A unit of 10^q base wei at `tick`, its exact quote x 10^43: 10^q x mantissa x 10^d.
    function unitNum(uint256 q, uint256 tick) internal pure returns (U512 memory) {
        uint256 d = tick / PER_DECADE;
        uint256 mant = MANTISSA_BASE + tick % PER_DECADE;
        return Wide.pow10(d).mul(10 ** q * mant);
    }

    /// A sell's 1 - f in ppm, its budget's divisor: 10^6 - feePpm, and 1 at a fee of 100% (a sell there receives
    /// nothing whatever it fills; its budget is taken as at 1 ppm below).
    function sellRate(uint256 feePpm) internal pure returns (uint256) {
        return feePpm < PPM ? PPM - feePpm : 1;
    }

    /// Whether an exact quote (x 10^43) is within the budget as specified: a buy pays ceil(Q) + ceil(Q f), at most A,
    /// computed so (both roundings, in 512 bits); a sell receives floor(Q) - ceil(Q f), held to Q (1 - f) <= A, in
    /// integers num x (10^6 - feePpm) <= A x 10^6 x 10^43 (`sellRate` for 10^6 - feePpm). The budget is exact, a
    /// fraction: never rounded before it is compared.
    function withinBudget(Take memory t, U512 memory num) internal pure returns (bool) {
        if (t.buy) {
            U512 memory paid = num.divUp(10 ** DEN_EXP).add(num.mul(t.feePpm).divUp(10 ** (DEN_EXP + 6)));
            return paid.le(Wide.from(t.amount));
        }
        return num.mul(sellRate(t.feePpm)).le(Wide.pow10(DEN_EXP).mul(t.amount * PPM));
    }

    /// Whether the OLO EVM contract refuses this take's budget: a quote-mode sell whose budget's whole part,
    /// floor(A x 10^6 / sellRate), passes 2^126. The test mirroring the walk checks it at the first order the walk
    /// reaches that is open, on the other side and within its entry's tick, before it fills anything there: the take
    /// reverts AmountOverflow there, whether or not a unit of that order is within the budget.
    function budgetRefused(Take memory t) internal pure returns (bool) {
        return t.inQuote && !t.buy && t.amount * PPM / sellRate(t.feePpm) > BUDGET_LIMIT;
    }

    /// The units an order of `open` units of 10^q at `tick` fills: base mode min(open, floor(left / 10^q)); quote mode
    /// the largest x <= open whose exact quote, added, stays within the budget (binary search: the budget's test is
    /// monotone in x). Adds them to the walk.
    function fill(Walk memory w, Take memory t, uint256 open, uint256 q, uint256 tick)
        internal
        pure
        returns (uint256 x)
    {
        uint256 unit = 10 ** q;
        U512 memory per = unitNum(q, tick);
        if (!t.inQuote) {
            x = (t.amount - w.base) / unit;
            if (x > open) x = open;
        } else {
            uint256 lo;
            uint256 hi = open;
            while (lo < hi) {
                uint256 mid = (lo + hi + 1) / 2;
                if (withinBudget(t, w.num.add(per.mul(mid)))) lo = mid;
                else hi = mid - 1;
            }
            x = lo;
            if (x < open && (!w.stopped || per.lt(w.minStopUnit))) {
                w.minStopUnit = per;
                w.stopped = true;
            }
        }
        if (x == 0) return 0;
        w.num = w.num.add(per.mul(x));
        w.base += x * unit;
        ++w.count;
    }

    /// The end of the take as specified: the quote rounded once (a buy up, a sell down), the fee on the exact quote
    /// rounded up, and what the taker pays (a buy: quote + fee) or receives (a sell: quote - fee; `belowFee` when the
    /// fee is not less than the quote, a sell that would receive nothing, which the contract refuses).
    function finish(Walk memory w, Take memory t)
        internal
        pure
        returns (uint256 quote, uint256 fee, uint256 quoteAmount, bool belowFee)
    {
        quote = (t.buy ? w.num.divUp(10 ** DEN_EXP) : w.num.divDown(10 ** DEN_EXP)).toUint();
        fee = w.num.mul(t.feePpm).divUp(10 ** (DEN_EXP + 6)).toUint();
        if (t.buy) {
            quoteAmount = quote + fee;
        } else if (fee >= quote) {
            belowFee = true;
        } else {
            quoteAmount = quote - fee;
        }
    }

    /// Quote mode's promise on what is left of the amount when the budget stopped the walk short at some order: less
    /// than that order's unit with its fee, plus 1 wei (a buy: the roundings up of the unit that did not fit) or 2 wei
    /// (a sell: its two roundings down); checked against the cheapest such unit. True when the walk never stopped
    /// short, and for a sell at a fee of 100%.
    function leftWithinOneUnit(Walk memory w, Take memory t, uint256 left) internal pure returns (bool) {
        if (!w.stopped) return true;
        // a sell at a fee of 100% promises nothing here: one that fills reverts SellBelowFee
        if (!t.buy && t.feePpm >= PPM) return true;
        uint256 slack = t.buy ? 1 : 2;
        if (left <= slack) return true;
        uint256 rate = t.buy ? PPM + t.feePpm : PPM - t.feePpm;
        // left - slack < unit x (1 +- f), in integers: (left - slack) x 10^49 < unitNum x (10^6 +- feePpm)
        return Wide.pow10(DEN_EXP + 6).mul(left - slack).lt(w.minStopUnit.mul(rate));
    }
}
