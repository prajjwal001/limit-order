// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

/// The batch slot's operations and one take group in their plainest Solidity, for reading beside the OLO EVM contract
/// and for the differential fuzz (OloSlotRef.t.sol) to hold the contract to, step for step. `manageBatch` is
/// OloBookBatches._manageBatch with its `_slotWalk` (`slotWalk` here: the same masks and variable names) and the sums
/// `_batchFlows` moves; `fillGroup` is one group of OloBookTakes._fillBatches in base mode; `fillGroupQuote` one in
/// quote mode, written from the budget's definition (OloBookTakes note 4) rather than from the contract's cap. Where
/// the contract packs or shares a helper, this spells it out: each mask as four bools, each sub-order's side as its own
/// bool (its side bit D_i), C's fields read by hand, and the grid's price, an amount's units
/// and the minQuote test written out again instead of called from PriceGrid, OloMath or MarketLib.
library SlotRef {
    // The main word: bit 0 zero | USED 1 | four sub-orders of 61 bits at 2 + 61 i, each tick 0-25 | q 26-30 | open
    // 31-60 (units of 10^q base wei) | side D_i at 246 + i (1 a bid; 0 while the sub-order is empty). The settlement
    // word: base i at 30 i (sub-order i's open units as of its last maker settlement) | USED 255. The params' sides:
    // s_i at 136 + i (1 a bid), read by a post, a replace and a modify for each order they rest; the kind is bits 0-3.
    uint256 internal constant SIDES = 246;
    uint256 internal constant PARAM_SIDES = 136;
    uint256 internal constant USED = 2;
    uint256 internal constant SUB_MASK = (1 << 61) - 1;
    uint256 internal constant TICK_MASK = (1 << 26) - 1;
    uint256 internal constant Q_MASK = 31;
    uint256 internal constant UNITS_MASK = (1 << 30) - 1;
    uint256 internal constant SET_USED = 1 << 255;
    /// An order's amount in the operation's words (OloOps.batchW): 112 bits.
    uint256 internal constant AMOUNT_MASK = (1 << 112) - 1;

    // The grid: P(tick) = (100_000 + tick % 900_000) x 10^(tick / 900_000 - 43) quote wei per base wei, ticks 1 ..
    // MAX_TICK.
    uint256 internal constant MAX_TICK = 66_599_999;

    /// What a market word names, for `manageBatch`: no listed market (V_NONE), an older version of one (V_OLD), its
    /// current version (V_CURRENT).
    uint256 internal constant V_NONE = 0;
    uint256 internal constant V_OLD = 1;
    uint256 internal constant V_CURRENT = 2;

    uint256 internal constant POST = 0;
    uint256 internal constant REPLACE = 1;
    uint256 internal constant MODIFY = 2;
    uint256 internal constant CANCEL = 3;
    uint256 internal constant CLAIM = 4;

    /// The decade the exact quotes here are scaled to: a fill of `amount` base wei at a tick of decade d adds amount x
    /// mantissa x 10^(d - 20) to `num`, so the quote is Q = num / 10^23 exactly, for fills in decades 20 and up.
    uint256 internal constant NUM_DECADE = 20;
    uint256 internal constant NUM_SCALE = 1e23;

    /// The market's numbers the walk reads from C (spacing 64-73 | minQuote 74-169 | feePpm 188-207).
    struct Market {
        uint256 feePpm;
        uint256 spacing;
        uint256 minQuote;
    }

    /// What an operation does to each sub-order (the contract's `SlotMasks`, each mask as four bools).
    struct Masks {
        bool[4] settle; // fills paid with their fee, open units refunded, emptied
        bool[4] claim; // fills paid with their fee, open units resting on (nothing open: emptied)
        bool[4] rest; // order i checked as a maker's order, escrowed, and made the sub-order
        // NoChange checked: an order equal to the sub-order's tick and open amount, the sub-order with no fills to pay
        // (a modify)
        bool same;
        bool[4] oldBid; // the side each settled or claimed sub-order rests on: D_i as the slot holds it
        bool[4] newBid; // the side each rested order takes
    }

    /// The contract's `SlotSums`, its `bad` as three bools.
    struct Sums {
        uint256 next; // the main word after
        uint256 set; // the settlement word after
        uint256 quoteIn; // proceeds and refunds in quote, each rounded down
        uint256 baseIn; // proceeds and refunds in base
        uint256 quoteOut; // escrow in quote, each rounded up
        uint256 baseOut; // escrow in base
        uint256 fee; // the settled fills' fee, floored per sub-order
        bool badSame;
        bool badTick;
        bool badSize;
    }

    /// One fill of a take group: sub-order `index`, `units` of 10^`q` base wei at `tick`, out of `open` units.
    struct Fill {
        uint256 index;
        uint256 tick;
        uint256 q;
        uint256 units;
        uint256 open;
    }

    /// A quote-mode take's budget, `amount` A quote wei, as its rule (OloBookTakes note 4) on the exact quote Q = num /
    /// 10^23 of the fills so far: a buy pays ceil(Q) + ceil(Q x feePpm / 10^6) <= A (the quote and the fee each rounded
    /// up, as the contract charges them), a sell's Q x (10^6 - feePpm) <= A x 10^6 (`sellRate`: 1 at 100%). `minCut`:
    /// the least exact quote of one unit (in num's scale) at a sub-order the budget stopped short of its open units,
    /// for the leftover's bound. `refused`: a sell's budget whose whole part passes 2^126, met at the first sub-order
    /// the walk reaches (open, on the other side, within its entry's tick): the contract reverts AmountOverflow there,
    /// and nothing fills.
    struct Budget {
        uint256 amount;
        uint256 feePpm;
        uint256 num;
        uint256 minCut;
        bool buy;
        bool refused;
    }

    function marketOf(MarketWord c) internal pure returns (Market memory mk) {
        uint256 w = MarketWord.unwrap(c);
        mk.feePpm = (w >> 188) & 0xfffff;
        mk.spacing = (w >> 64) & 0x3ff;
        mk.minQuote = (w >> 74) & ((1 << 96) - 1);
    }

    // ------------------------------------------------------------------ the words

    function subAt(uint256 word, uint256 i) internal pure returns (uint256) {
        return (word >> (2 + 61 * i)) & SUB_MASK;
    }

    function withSub(uint256 word, uint256 i, uint256 sub) internal pure returns (uint256) {
        uint256 lowBit = 2 + 61 * i;
        return (word & ~(SUB_MASK << lowBit)) | (sub << lowBit);
    }

    /// Sub-order i's side: its side bit D_i, set for a bid.
    function bidAt(uint256 word, uint256 i) internal pure returns (bool) {
        return (word >> (SIDES + i)) & 1 == 1;
    }

    function withBid(uint256 word, uint256 i, bool bid) internal pure returns (uint256) {
        return (word & ~(uint256(1) << (SIDES + i))) | (bid ? uint256(1) << (SIDES + i) : 0);
    }

    /// The order i's side in the params: s_i, set for a bid.
    function paramBid(uint256 params, uint256 i) internal pure returns (bool) {
        return (params >> (PARAM_SIDES + i)) & 1 == 1;
    }

    function baseAt(uint256 set, uint256 i) internal pure returns (uint256) {
        return (set >> (30 * i)) & UNITS_MASK;
    }

    function withBase(uint256 set, uint256 i, uint256 base) internal pure returns (uint256) {
        uint256 lowBit = 30 * i;
        return (set & ~(UNITS_MASK << lowBit)) | (base << lowBit);
    }

    /// Order i of the operation's words `w` (OloOps.batchW): its tick at 32 + 26 i of the params; orders 0 and 1's
    /// amounts at 0 and 112 of w[1], orders 2 and 3's at 0 and 112 of w[2] (the entry's `amountWords`).
    function orderAt(uint256[3] memory w, uint256 i) internal pure returns (uint256 tick, uint256 amount) {
        tick = (w[0] >> (32 + 26 * i)) & TICK_MASK;
        // the amounts two a word: orders 0 and 1 in w[1], 2 and 3 in w[2], the even one low, the odd one at 112
        amount = (w[1 + i / 2] >> (112 * (i % 2))) & AMOUNT_MASK;
    }

    /// `_checkCurrent`'s error for a version that is not the current one: UnknownMarket for a key no market has,
    /// MarketFrozen for a listed market's older version.
    function _notCurrent(uint256 v) private pure returns (bytes4) {
        return v == V_NONE ? IOloBookBase.UnknownMarket.selector : IOloBookBase.MarketFrozen.selector;
    }

    // ------------------------------------------------------------------ the grid and an order's units

    function decadeOf(uint256 tick) internal pure returns (uint256) {
        return tick / 900_000;
    }

    function mantissaOf(uint256 tick) internal pure returns (uint256) {
        return 100_000 + tick % 900_000;
    }

    /// `amount` base wei at `tick` in quote wei, rounded down.
    function quoteDown(uint256 amount, uint256 tick) internal pure returns (uint256) {
        uint256 d = decadeOf(tick);
        uint256 v = amount * mantissaOf(tick);
        return d >= 43 ? v * 10 ** (d - 43) : v / 10 ** (43 - d);
    }

    /// `amount` base wei at `tick` in quote wei, rounded up.
    function quoteUp(uint256 amount, uint256 tick) internal pure returns (uint256) {
        uint256 d = decadeOf(tick);
        uint256 v = amount * mantissaOf(tick);
        if (d >= 43) return v * 10 ** (d - 43);
        uint256 div = 10 ** (43 - d);
        return (v + div - 1) / div;
    }

    /// The fee of `amount` base wei at `tick`, rounded down.
    function feeDown(uint256 amount, uint256 tick, uint256 feePpm) internal pure returns (uint256) {
        uint256 d = decadeOf(tick);
        uint256 v = amount * mantissaOf(tick) * feePpm;
        return d >= 43 ? v * 10 ** (d - 43) / 1e6 : v / (1e6 * 10 ** (43 - d));
    }

    /// An amount as an order stores it: the smallest q with floor(amount / 10^q) below 2^30, and those units.
    function toUnits(uint256 amount) internal pure returns (uint256 q, uint256 units) {
        units = amount;
        while (units > UNITS_MASK) {
            units /= 10;
            ++q;
        }
    }

    /// A maker's tick: from the makers' floor (3,600,000, decade 4's first tick) to the grid's top, and a multiple of
    /// the spacing (a spacing of 0, which only a C nobody listed carries, refuses nothing; such a C is UnknownMarket
    /// before the walk).
    function makerTick(Market memory mk, uint256 tick) internal pure returns (bool) {
        if (tick < 3_600_000 || tick > MAX_TICK) return false;
        return mk.spacing == 0 || tick % mk.spacing == 0;
    }

    /// At least one wei, and worth at least minQuote: stored x P >= minQuote, as integers.
    function worthMin(Market memory mk, uint256 tick, uint256 stored) internal pure returns (bool) {
        if (stored == 0) return false;
        uint256 d = decadeOf(tick);
        uint256 v = stored * mantissaOf(tick);
        if (d >= 43) return v * 10 ** (d - 43) >= mk.minQuote;
        return v >= mk.minQuote * 10 ** (43 - d);
    }

    /// A fill of `amount` base wei at `tick` in the exact quote's scale: amount x mantissa x 10^(d - 20).
    function exact(uint256 amount, uint256 tick) internal pure returns (uint256) {
        require(decadeOf(tick) >= NUM_DECADE, "SlotRef: decade");
        return amount * mantissaOf(tick) * 10 ** (decadeOf(tick) - NUM_DECADE);
    }

    /// The exact quote `num` rounded once: up for a buy, down for a sell.
    function quoteOf(uint256 num, bool buy) internal pure returns (uint256) {
        return buy ? (num + NUM_SCALE - 1) / NUM_SCALE : num / NUM_SCALE;
    }

    /// The fee on the exact quote `num`, rounded up.
    function feeOf(uint256 num, uint256 feePpm) internal pure returns (uint256) {
        uint256 div = 1e6 * NUM_SCALE;
        return (num * feePpm + div - 1) / div;
    }

    // ------------------------------------------------------------------ an operation on a slot

    /// OloBookBatches._manageBatch on a slot holding `word` and `set` (both 0: never written), its words `w`
    /// (OloOps.batchW): the error it reverts with before it moves any money (0: none), the sums with the words after,
    /// and the sub-orders acted on (BatchUpdated's). `listed`: C names a listed market. The flows' own errors (an
    /// account short of a debit) are the caller's.
    function manageBatch(MarketWord c, uint256[3] memory w, uint256 word, uint256 set, uint256 v)
        internal
        pure
        returns (bytes4 err, Sums memory sums, uint256 acted)
    {
        uint256 params = w[0];
        uint256 kind = params & 0xf; // 0 to 4; 5 to 15 BadBatch (bit 3 the earlier encoding's slot side)
        // a post's key is resolved first (the entry's `_current`, before anything of the operation's: UnknownMarket for a
        // key no market has; the caller passes the current version's slot); a replace and a modify find their version
        // current where main checked the market active (`_checkCurrent`, below); a cancel and a claim settle any
        // version's slot (a C no market has finds an empty one)
        if (kind == POST && v == V_NONE) return (IOloBookBase.UnknownMarket.selector, sums, 0);
        if (kind > CLAIM) return (IOloBookBase.BadBatch.selector, sums, 0);
        // the settle flags: WALLET 0x02 and AUTO 0x04 mean something, any other bit is BadFlags
        uint256 flags = (params >> 20) & 0xff;
        if (flags & ~uint256(0x06) != 0) return (IOloBookBase.BadFlags.selector, sums, 0);
        bool[4] memory live;
        bool anyLive;
        for (uint256 i; i < 4; ++i) {
            live[i] = subAt(word, i) != 0;
            anyLive = anyLive || live[i];
        }
        Masks memory m;
        for (uint256 i; i < 4; ++i) {
            m.oldBid[i] = bidAt(word, i);
        }
        if (kind == POST || kind == REPLACE) {
            if (kind == POST && anyLive) return (IOloBookBase.SlotBusy.selector, sums, 0);
            if (kind == REPLACE && v != V_CURRENT) return (_notCurrent(v), sums, 0);
            for (uint256 i; i < 4; ++i) {
                (uint256 tick, uint256 amount) = orderAt(w, i);
                if (tick != 0 || amount != 0) {
                    m.rest[i] = true;
                    acted |= 1 << i;
                }
                m.settle[i] = live[i]; // a replace settles every live sub-order; a post has none
            }
            if (acted == 0) return (IOloBookBase.ZeroSize.selector, sums, 0);
            // order i on its side s_i; a fresh main word, USED and nothing else
            for (uint256 i; i < 4; ++i) {
                m.newBid[i] = paramBid(params, i);
            }
            sums.next = USED;
            // the rested orders' bases rewritten; a settled sub-order's left as it was (the contract reads the
            // settlement word only when a sub-order is live, so a post's starts from USED alone)
            sums.set = (anyLive ? set : 0) | SET_USED;
        } else {
            sums.next = word;
            sums.set = set | SET_USED;
            if (kind == CLAIM) {
                for (uint256 i; i < 4; ++i) {
                    uint256 sub = subAt(word, i);
                    // a live sub-order with fills; an empty one's base is left over and counts for nothing
                    if (sub != 0 && baseAt(set, i) != sub >> 31) {
                        m.claim[i] = true;
                        acted |= 1 << i;
                    }
                }
                if (acted == 0) return (IOloBookBase.NothingToClaim.selector, sums, 0);
            } else {
                uint256 mask = (params >> 28) & 0xf;
                if (mask == 0) return (IOloBookBase.BadBatch.selector, sums, 0);
                if (!anyLive) return (IOloBookBase.NoOrder.selector, sums, 0);
                for (uint256 i; i < 4; ++i) {
                    bool named = (mask >> i) & 1 == 1;
                    m.settle[i] = named && live[i];
                    if (kind == CANCEL) {
                        if (m.settle[i]) acted |= 1 << i;
                    } else {
                        m.rest[i] = named;
                    }
                }
                if (kind == CANCEL && acted == 0) return (IOloBookBase.NoOrder.selector, sums, 0);
                if (kind == MODIFY && v != V_CURRENT) return (_notCurrent(v), sums, 0);
                if (kind == MODIFY) {
                    acted = mask;
                    m.same = true;
                    // every index the mask names, live or empty, rests on its side s_i
                    for (uint256 i; i < 4; ++i) {
                        m.newBid[i] = paramBid(params, i);
                    }
                }
            }
        }
        slotWalk(sums, marketOf(c), w, word, set, m);
        if (sums.badSame) return (IOloBookBase.NoChange.selector, sums, acted);
        if (sums.badTick) return (IOloBookBase.TickOutOfRange.selector, sums, acted);
        if (sums.badSize) return (IOloBookBase.SizeOutOfRange.selector, sums, acted);
    }

    /// OloBookBatches._slotWalk: each sub-order the masks touch, lowest index first, building the words after from the
    /// ones `manageBatch` put in `sums`.
    function slotWalk(
        Sums memory sums,
        Market memory mk,
        uint256[3] memory w,
        uint256 word,
        uint256 set,
        Masks memory m
    ) internal pure {
        for (uint256 i; i < 4; ++i) {
            if (!m.settle[i] && !m.claim[i] && !m.rest[i]) continue;
            uint256 old = subAt(word, i);
            uint256 newSub = old;
            uint256 newBase = baseAt(set, i);
            bool newBid = bidAt(word, i); // a claimed sub-order resting on keeps its side
            // ---- settle or claim: the fills (base - open units) paid with their fee; a settle's open units refunded
            if (m.settle[i] || m.claim[i]) {
                uint256 tick = old & TICK_MASK;
                uint256 unit = 10 ** ((old >> 26) & Q_MASK);
                uint256 open = old >> 31;
                uint256 filled = (newBase - open) * unit; // a take lowers open only: base >= open
                if (filled != 0) {
                    sums.fee += feeDown(filled, tick, mk.feePpm); // floored per sub-order
                    if (!m.oldBid[i]) sums.quoteIn += quoteDown(filled, tick); // an ask's fills pay quote, down
                    else sums.baseIn += filled; // a bid's pay base
                }
                // the fills claimed: the base drops to the open units; nothing open, the sub-order is emptied
                newBase = open;
                if (open == 0) newSub = 0;
                // a settle: the open units refunded, the sub-order emptied
                if (m.settle[i]) {
                    if (open != 0) {
                        if (!m.oldBid[i]) sums.baseIn += open * unit; // an ask refunds base
                        else sums.quoteIn += quoteDown(open * unit, tick); // a bid quote, down
                    }
                    newSub = 0;
                }
            }
            // ---- rest: order i, checked as a maker's order and escrowed; it becomes the sub-order
            if (m.rest[i]) {
                (uint256 tick, uint256 amount) = orderAt(w, i);
                (uint256 q, uint256 units) = toUnits(amount);
                uint256 stored = units * 10 ** q;
                uint256 oldStored = (old >> 31) * 10 ** ((old >> 26) & Q_MASK);
                // the same tick and open amount as the sub-order (an empty one's are both zero), and for a live one the
                // same side, with no fills to pay: an empty index has none, a live sub-order none when its base, as the
                // operation found it, is its open units. With fills the order is kept: they are paid above and its
                // escrow stays (a claim's). A live sub-order turned to the other side is a changed order
                bool sameSide = old == 0 || m.newBid[i] == m.oldBid[i];
                bool sameOrder = m.same && tick == (old & TICK_MASK) && stored == oldStored && sameSide;
                bool noFills = old == 0 || baseAt(set, i) == old >> 31;
                if (sameOrder && noFills) sums.badSame = true;
                bool kept = sameOrder && !noFills;
                // a tick off the grid or the spacing; else no unit, or worth less than minQuote
                if (!makerTick(mk, tick)) sums.badTick = true;
                else if (!worthMin(mk, tick, stored)) sums.badSize = true;
                if (!m.newBid[i]) sums.baseOut += stored; // an ask escrows base
                // a bid quote, up; a kept bid's the refund above, down, so the two cancel
                else sums.quoteOut += kept ? quoteDown(stored, tick) : quoteUp(stored, tick);
                newSub = tick | (q << 26) | (units << 31);
                newBase = units;
                newBid = m.newBid[i];
            }
            // an emptied sub-order has no side
            if (newSub == 0) newBid = false;
            sums.next = withBid(withSub(sums.next, i, newSub), i, newBid);
            // the base only while the sub-order is live: an emptied one's is left as it was
            if (newSub != 0) sums.set = withBase(sums.set, i, newBase);
        }
    }

    // ------------------------------------------------------------------ one take group

    /// One group of OloBookTakes._fillBatches in base mode on a slot holding `word`: the sub-orders `mask` names, in
    /// index order, each bounded by its entry's tick in `ticks` (a buy fills an ask at it or below, a sell a bid at it
    /// or above), while `remaining` base wei last: x = min(open, floor(remaining / 10^q)) units at the sub-order's own
    /// tick, taken from its open units. Returns the word after, the base still wanted and the fills; a sub-order on the
    /// taker's own side (D_i: a bid for a buy, an ask for a sell) fills nothing.
    function fillGroup(uint256 word, uint256 mask, uint256[4] memory ticks, bool buy, uint256 remaining)
        internal
        pure
        returns (uint256 next, uint256 left, Fill[] memory fills)
    {
        next = word;
        left = remaining;
        Fill[4] memory found;
        uint256 n;
        for (uint256 i; i < 4 && left != 0; ++i) {
            if ((mask >> i) & 1 == 0) continue;
            if (bidAt(word, i) == buy) continue; // the taker's own side
            uint256 sub = subAt(next, i);
            uint256 tick = sub & TICK_MASK;
            uint256 q = (sub >> 26) & Q_MASK;
            uint256 open = sub >> 31;
            bool worse = buy ? tick > ticks[i] : tick < ticks[i];
            if (open == 0 || worse) continue;
            uint256 unit = 10 ** q;
            uint256 x = left / unit;
            if (x > open) x = open;
            if (x == 0) continue;
            next = withSub(next, i, tick | (q << 26) | ((open - x) << 31));
            left -= x * unit;
            found[n++] = Fill(i, tick, q, x, open);
        }
        fills = new Fill[](n);
        for (uint256 j; j < n; ++j) {
            fills[j] = found[j];
        }
    }

    /// A quote-mode take's budget: `amount` quote wei, what a buy pays with the fee or a sell receives less it.
    function budget(bool buy, uint256 amount, uint256 feePpm) internal pure returns (Budget memory b) {
        b.buy = buy;
        b.amount = amount;
        b.feePpm = feePpm;
        b.minCut = type(uint256).max;
    }

    /// Whether fills of exact quote `num` keep the budget: a buy's quote and fee, each rounded up, at most A; a sell's
    /// Q x (1 - f) at most A, as integers (num x (10^6 - feePpm) <= A x 10^6 x 10^23). Bounds, for the amounts and
    /// decades OloSlotRef.t.sol uses (A below 2^112, fills in decades 20 to 38, a unit at most 10^25): num stays
    /// below 2^195 (2^30 units of a unit's quote below 2^164, a few times over), so num x feePpm, num x (10^6 -
    /// feePpm) and A x 10^29 all fit 256 bits.
    function within(Budget memory b, uint256 num) internal pure returns (bool) {
        if (b.buy) return quoteOf(num, true) + feeOf(num, b.feePpm) <= b.amount;
        return num * sellRate(b.feePpm) <= b.amount * 1e6 * NUM_SCALE;
    }

    /// A sell's 1 - f in ppm, its budget's divisor: 10^6 - feePpm, and 1 at a fee of 100% (a sell there receives
    /// nothing whatever it fills; its budget is taken as at 1 ppm below).
    function sellRate(uint256 feePpm) internal pure returns (uint256) {
        return feePpm < 1e6 ? 1e6 - feePpm : 1;
    }

    /// Whether the contract refuses a sell's budget: its whole part, floor(A x 10^6 / sellRate), past 2^126.
    function budgetRefused(Budget memory b) internal pure returns (bool) {
        return !b.buy && b.amount * 1e6 / sellRate(b.feePpm) > 1 << 126;
    }

    /// One group in quote mode: as `fillGroup` (no base cap: every named sub-order is visited), each sub-order filling
    /// the largest x <= open whose fill keeps the budget (`within`, monotone in x), found by a search over x that
    /// tests the rule itself. `b.num` gains the fills, and `b.minCut` notes a sub-order left with units open.
    function fillGroupQuote(uint256 word, uint256 mask, uint256[4] memory ticks, Budget memory b)
        internal
        pure
        returns (uint256 next, Fill[] memory fills)
    {
        next = word;
        Fill[4] memory found;
        uint256 n;
        for (uint256 i; i < 4; ++i) {
            if (b.refused) break; // the take reverted where the walk met its budget: nothing after it
            if ((mask >> i) & 1 == 0) continue;
            if (bidAt(word, i) == b.buy) continue; // the taker's own side
            uint256 sub = subAt(next, i);
            uint256 tick = sub & TICK_MASK;
            uint256 q = (sub >> 26) & Q_MASK;
            uint256 open = sub >> 31;
            bool worse = b.buy ? tick > ticks[i] : tick < ticks[i];
            if (open == 0 || worse) continue;
            if (budgetRefused(b)) {
                b.refused = true;
                break;
            }
            uint256 perUnit = exact(10 ** q, tick);
            uint256 lo;
            uint256 hi = open;
            while (lo < hi) {
                uint256 mid = (lo + hi + 1) / 2;
                if (within(b, b.num + mid * perUnit)) lo = mid;
                else hi = mid - 1;
            }
            if (lo < open && perUnit < b.minCut) b.minCut = perUnit;
            if (lo == 0) continue;
            next = withSub(next, i, tick | (q << 26) | ((open - lo) << 31));
            b.num += lo * perUnit;
            found[n++] = Fill(i, tick, q, lo, open);
        }
        fills = new Fill[](n);
        for (uint256 j; j < n; ++j) {
            fills[j] = found[j];
        }
    }

    /// A group's fills as the Take event logs them: maker 20 | slot 2 | n 1, then n records of index 1 | q 1 | units
    /// 4; nothing for a group that filled nothing.
    function records(address maker, uint16 slot, Fill[] memory fills) internal pure returns (bytes memory out) {
        if (fills.length == 0) return out;
        out = abi.encodePacked(maker, slot, uint8(fills.length));
        for (uint256 j; j < fills.length; ++j) {
            out = bytes.concat(out, abi.encodePacked(uint8(fills[j].index), uint8(fills[j].q), uint32(fills[j].units)));
        }
    }
}
