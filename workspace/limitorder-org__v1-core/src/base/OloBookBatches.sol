// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

import {OloBookOrders} from "./OloBookOrders.sol";
import {OloMath} from "../libraries/OloMath.sol";
import {PriceGrid} from "../libraries/PriceGrid.sol";
import {MarketLib} from "../types/Market.sol";
import {MarketWord} from "../interfaces/MarketWord.sol";
import {
    AMOUNT_FIELD,
    BATCH_SIDES,
    BATCH_SUB_BASE,
    BATCH_USED,
    BatchLib,
    OloSlots,
    SET_USED,
    SUB_BITS,
    SUB_MASK,
    SUB_OPEN,
    SUB_Q,
    SUB_Q_MASK,
    TICK_FIELD
} from "../OloTypes.sol";

using MarketLib for MarketWord;

/// @title OloBookBatches
/// @notice A maker's batch slots: up to four sub-orders, each a bid or an ask, in two storage words (BatchLib), every
/// one on chain, and the maker's five operations on a slot (`_manageBatch`). A take's walk of a list segment of slots
/// (`_fillBatches`) is OloBookTakes', beside the position segment's.
abstract contract OloBookBatches is OloBookOrders {
    // --------------------------------------------------------------- batch slots
    // A maker names a slot (C, maker, slot u16) and keeps up to four sub-orders there, bids, asks or both. A take names
    // the slot and, per sub-order it wants, its bound for it (the tick it saw, or its limit), as a position entry
    // does: a sub-order on the taker's own side or repriced worse since is skipped, one repriced better fills there.
    // A take writes only the slot's main word, the sub-orders' open units; each sub-order's fills are its base in the
    // settlement word less its open units, settled as a pool order's (its proceeds and refund rounded down, its fee
    // floored, its escrow rounded up); an operation sums them per token and moves one net amount on each of the
    // maker's two accounts.

    // `manageBatchSubs`'s kinds.
    uint256 internal constant BATCH_POST = 0;

    uint256 internal constant BATCH_REPLACE = 1;

    uint256 internal constant BATCH_MODIFY = 2;

    uint256 internal constant BATCH_CANCEL = 3;

    uint256 internal constant BATCH_CLAIM = 4;

    // `manageBatchSubs`'s params: kind 0-3 (0 post .. 4 claim; 5 to 15 BadBatch: bit 3 carried the slot's side S in the
    // earlier encoding, so a caller of that encoding setting it for a bid is refused, not read as asks) | slot 4-19 |
    // flags 20-27 | mask 28-31 | four ticks of 26 bits at 32, 58, 84 and 110 (orders 0-3) | sides 136-139 (s_i: order
    // i's side, 1 a bid) | bits 140-205 not read | the tag of the slot's version 206-255 (as a cancel's;
    // MarketLib.withTag). The four orders' amounts (base wei, 112 bits each) are the entry's two words `amountWords`,
    // two a word: [0] amount 0 at 0-111 | amount 1 at 112-223, [1] amount 2 at 0-111 | amount 3 at 112-223.
    uint256 internal constant BP_KIND_MASK = 0xf;

    uint256 internal constant BP_SLOT = 4;

    uint256 internal constant BP_FLAGS = 20;

    uint256 internal constant BP_MASK = 28;

    uint256 internal constant BP_TICKS = 32;

    uint256 internal constant BP_TICK_BITS = 26;

    uint256 internal constant BP_SIDES = 136;

    uint256 internal constant BP_AMOUNT_BITS = 112;

    /// @dev A sub-order mask, 4 bits.
    uint256 internal constant SUBS_MASK = 0xf;

    /// @notice What an operation on a slot moves, summed over its sub-orders by `_slotWalk`, and the words it leaves.
    struct SlotSums {
        uint256 next; // the slot's main word: in, the one the walk starts from; out, the word after
        uint256 set; // the settlement word: in, the one the walk starts from; out, the word after
        uint256 quoteIn; // proceeds and refunds in quote, each rounded down, and a kept bid's quoteUp - quoteDown
        uint256 baseIn; // proceeds and refunds in base
        uint256 quoteOut; // escrow in quote, each rounded up
        uint256 baseOut; // escrow in base
        uint256 fee; // the settled fills' fee, floored per sub-order
        uint256 bad; // what was wrong with an order rested: BAD_SAME, BAD_TICK, BAD_SIZE
    }

    // What the walk finds wrong with an order it rests: the same tick, open amount and side with no fills to pay (a
    // modify's NoChange), a tick off the grid or the market's spacing, a size of no unit or worth less than minQuote.
    uint256 internal constant BAD_SAME = 1;

    uint256 internal constant BAD_TICK = 2;

    uint256 internal constant BAD_SIZE = 4;

    /// @notice What an operation does to each sub-order, for `_slotWalk`: in each 4-bit mask bit i is sub-order i.
    /// What `_manageBatch` sets, by kind (live: the sub-orders holding an order; filled: those with fills to pay;
    /// orders: the params' nonzero orders; mask: the params' mask; s: the params' sides):
    ///
    ///   post     rest = orders                                   newSides = s & orders
    ///   replace  settle = live, rest = orders                    newSides = s & orders
    ///   modify   settle = mask & live, rest = mask, same = true  newSides = s & mask
    ///   cancel   settle = mask & live
    ///   claim    claim = filled
    struct SlotMasks {
        uint256 settle; // the sub-order is settled: its fills paid with their fee, its open units refunded, emptied
        uint256 claim; // its fills are paid with their fee; its open units rest on (nothing open: it is emptied)
        uint256 rest; // the order i is checked as a maker's order, escrowed, and becomes the sub-order
        // NoChange is checked: an order equal to the sub-order's tick, open amount and side is refused when the
        // sub-order has no fills to pay (a modify)
        bool same;
        // the side each rested order takes, D_i (1 a bid), which decides its escrow (a settled or claimed sub-order's
        // side, which decides what its fills and open units pay, is the one in the slot's word)
        uint256 newSides;
    }

    /// @notice One of the caller's operations on its batch slot of version `c` (the entry chose it: a post's the
    /// current one, the other kinds' the one the params' tag names), the slot `params` names (kind 0-3 | slot 4-19 |
    /// flags 20-27 | mask 28-31 | the orders' ticks: BP_TICKS | sides: BP_SIDES), with the orders' amounts in the two
    /// words `amountWords`. Every order rests on its own side s_i (1 a bid), whichever kind rests it.
    /// post: the slot must hold no live sub-order (SlotBusy); the orders, 1 to 4 (a zero order leaves its index
    /// empty), rest each on its side. replace: every live sub-order settled (its fills paid, its open units refunded,
    /// on its own side), then the orders rest as a post's. modify: each sub-order the mask names is settled and rests
    /// again as its order gives, on s_i, live or empty (an empty one is added; a live one keeps its side only when s_i
    /// is its side, so a caller passes each named live sub-order's side to keep it, and the other side settles it on
    /// its old side and escrows it on the new one, a changed order even at the same tick and amount); the others are
    /// untouched; an order the same as the sub-order's tick, open amount and side is NoChange when the sub-order has no
    /// fills to pay (with fills it rests again and they are paid, as a claim pays them, and no escrow moves for it),
    /// and an empty index's zero order is NoChange whatever its side.
    /// cancel: each live sub-order the mask names is settled and emptied. claim: every sub-order's fills are paid, and
    /// one with no open units left is emptied. A settle pays the fills' proceeds and the maker's part of their fee, at
    /// the share of `c`, the slot's version (the rest to the pot). A replace and a modify rest orders again in `c`, so
    /// `c` must be the market's current version (`_checkCurrent`). Each order
    /// rests as its own units and q (OloMath.toUnits), at least one unit and worth at least the market's minQuote. Here
    /// the operation's checks and its sub-orders as masks; `_slotWalk` does the per-sub-order work. The settlement word
    /// is read unless the slot holds no live sub-order to settle and the operation rewrites every base (a post, a
    /// replace of an empty slot), and written only when it changes.
    function _manageBatch(MarketWord c, uint256 params, uint256[2] calldata amountWords) internal {
        uint256 kind = params & BP_KIND_MASK;
        if (kind > BATCH_CLAIM) revert BadBatch();
        uint256 settle = _checkSettleFlags(uint8(params >> BP_FLAGS));
        uint256 slotNo = uint16(params >> BP_SLOT);
        uint256 slot = OloSlots.batchSlot(c, msg.sender, slotNo);
        uint256 setSlot;
        unchecked {
            setSlot = slot + 1; // a hash: never the last slot
        }
        uint256 word = OloSlots.load(slot);
        uint256 live = BatchLib.liveMask(word);
        SlotSums memory sums;
        // for the event: the orders rested (post, replace), named (modify), settled (cancel), paid (claim)
        uint256 acted;
        SlotMasks memory masks;
        uint256 set; // the settlement word as stored: read when needed, else 0 (and then always rewritten)
        if (kind <= BATCH_REPLACE) {
            if (kind == BATCH_POST && live != 0) revert SlotBusy();
            if (kind == BATCH_REPLACE) _checkCurrent(c);
            acted = _orderMask(params, amountWords);
            if (acted == 0) revert ZeroSize();
            masks.settle = live; // a replace settles every live sub-order; a post has none
            masks.rest = acted;
            masks.newSides = (params >> BP_SIDES) & acted; // order i on s_i
            // a fresh main word: USED, no sub-order and no side (`_slotWalk` sets the rested orders')
            sums.next = BATCH_USED;
            if (live != 0) set = OloSlots.load(setSlot);
            // the rested orders' bases rewritten; a replace of a live slot leaves a settled sub-order's base as it was,
            // and a post (or a replace of an empty slot), which read no settlement word, writes the others zero
            sums.set = set | SET_USED;
        } else {
            set = OloSlots.load(setSlot);
            sums.next = word;
            sums.set = set | SET_USED;
            if (kind == BATCH_CLAIM) {
                acted = BatchLib.filledMask(word, set);
                if (acted == 0) revert NothingToClaim();
                masks.claim = acted;
            } else {
                uint256 mask = (params >> BP_MASK) & SUBS_MASK;
                if (mask == 0) revert BadBatch();
                if (live == 0) revert NoOrder();
                if (kind == BATCH_CANCEL) {
                    acted = mask & live;
                    if (acted == 0) revert NoOrder();
                    masks.settle = acted;
                } else {
                    _checkCurrent(c);
                    acted = mask;
                    masks.settle = mask & live;
                    masks.rest = mask;
                    masks.same = true;
                    // every index the mask names, live or empty, rests on s_i (a live sub-order keeps its side only
                    // when s_i is its side)
                    masks.newSides = (params >> BP_SIDES) & mask;
                }
            }
        }
        _slotWalk(sums, c, params, amountWords, word, set, masks);
        if (sums.bad != 0) {
            if (sums.bad & BAD_SAME != 0) revert NoChange();
            if (sums.bad & BAD_TICK != 0) revert TickOutOfRange();
            revert SizeOutOfRange();
        }
        OloSlots.store(slot, sums.next);
        if (sums.set != set) OloSlots.store(setSlot, sums.set);
        emit BatchUpdated(msg.sender, _batchEventWord(c.marketKey(), kind, acted, slotNo), sums.next, sums.set);
        (int256 quoteFlow, int256 baseFlow) = _batchFlows(c, sums);
        _settleFlows(_acctKeys(c), quoteFlow, baseFlow, settle);
    }

    /// @notice Order `i` of a post, a replace or a modify: its tick (26 bits at 32 + 26 i of `params`) and amount
    /// (orders 0 and 1 in `amountWords[0]`, orders 2 and 3 in `amountWords[1]`, the even one at 0-111 and the odd one
    /// at 112-223), read from the calldata where it is used, so a cancel or a claim never reads the amount words.
    function _orderAt(uint256 params, uint256[2] calldata amountWords, uint256 i)
        internal
        pure
        returns (uint256 tick, uint256 amount)
    {
        unchecked {
            // i is 0 .. 3
            tick = (params >> (BP_TICKS + i * BP_TICK_BITS)) & TICK_FIELD;
            amount = ((i < 2 ? amountWords[0] : amountWords[1]) >> ((i & 1) * BP_AMOUNT_BITS)) & AMOUNT_FIELD;
        }
    }

    /// @notice The orders that are not zero (a tick or an amount), as a mask: bit i for order i.
    function _orderMask(uint256 params, uint256[2] calldata amountWords) internal pure returns (uint256 mask) {
        uint256 amounts01 = amountWords[0];
        uint256 amounts23 = amountWords[1];
        // order i is zero when its tick and its amount both are: the two fields or-ed, one test (no branch between)
        if ((((params >> BP_TICKS) & TICK_FIELD) | (amounts01 & AMOUNT_FIELD)) != 0) mask = 1;
        if (
            (((params >> (BP_TICKS + BP_TICK_BITS)) & TICK_FIELD) | ((amounts01 >> BP_AMOUNT_BITS) & AMOUNT_FIELD)) != 0
        ) {
            mask |= 2;
        }
        if ((((params >> (BP_TICKS + 2 * BP_TICK_BITS)) & TICK_FIELD) | (amounts23 & AMOUNT_FIELD)) != 0) mask |= 4;
        if (
            (((params >> (BP_TICKS + 3 * BP_TICK_BITS)) & TICK_FIELD) | ((amounts23 >> BP_AMOUNT_BITS) & AMOUNT_FIELD))
                != 0
        ) {
            mask |= 8;
        }
    }

    /// @notice The per-sub-order work of an operation on a slot, in two passes over the sub-orders `masks` names (each
    /// in index order, visiting only the named ones): first what the slot holds is paid out (settled or claimed), then
    /// the orders rest. Each on its own side (a settled or claimed sub-order's D_i in `word`, a rested order's new
    /// side), priced as a pool order is (proceeds and refunds rounded down, the fee floored per sub-order, a bid's
    /// escrow rounded up), summed into `sums`. A sub-order's fills are its base in the settlement word `set` less its
    /// open units (a take lowers only the open units); a claim moves its base to its open units, a rest sets both to
    /// the order's units, and a sub-order emptied (settled, or claimed with nothing open) keeps its base, which counts
    /// for nothing until the index rests again, and loses its side; a rested order's side is set after the passes
    /// (`masks.newSides`). A rested order is checked as a maker's (its tick on the grid and the spacing,
    /// at least one unit, worth at least minQuote), and a modify's against the sub-order's tick, open amount, side and
    /// fills as the operation found them; what fails is noted in `sums.bad` for the caller to revert with.
    /// Nothing here overflows: units below 2^30, q at most 25 (amounts below 2^112), PriceGrid's bounds.
    function _slotWalk(
        SlotSums memory sums,
        MarketWord c,
        uint256 params,
        uint256[2] calldata amountWords,
        uint256 word,
        uint256 set,
        SlotMasks memory masks
    ) internal pure {
        // the words being built: `_manageBatch` put the ones to start from in the sums (USED and USED for a post or a
        // replace, the slot's words for the others)
        uint256 next = sums.next;
        uint256 nextSet = sums.set;
        uint256 feePpm = c.feePpm();
        unchecked {
            // units below 2^30 x 10^q, q at most 25; base >= open (BatchLib); PriceGrid's bounds; four sub-orders
            // ---- 1. pay out what the slot holds: each sub-order settled or claimed has its fills (base - open) paid
            // with their fee, the side it rests on (D_i in `word`) deciding the token (an ask quote rounded down, a
            // bid base)
            for (uint256 m = masks.settle | masks.claim; m != 0; m &= m - 1) {
                uint256 i = BatchLib.lowestSub(m);
                uint256 old = BatchLib.subAt(word, i);
                uint256 tick = old & TICK_FIELD;
                uint256 unit = OloMath.pow10((old >> SUB_Q) & SUB_Q_MASK);
                uint256 open = old >> SUB_OPEN;
                bool bid = (word >> (BATCH_SIDES + i)) & 1 == 1; // D_i
                // base >= open: a take only lowers open, a maker's operation sets both
                uint256 filled = (BatchLib.baseAt(set, i) - open) * unit;
                if (filled != 0) {
                    // the fee floored per sub-order (the takes collected it rounded up)
                    sums.fee += PriceGrid.feeDown(filled, tick, feePpm);
                    if (!bid) sums.quoteIn += PriceGrid.quoteDown(filled, tick);
                    else sums.baseIn += filled;
                }
                if ((masks.settle >> i) & 1 == 1) {
                    // a settle: the open units refunded too (an ask base, a bid quote rounded down), and the sub-order
                    // emptied (its base left as it was: it counts for nothing until the index rests again; its side
                    // cleared after the walk)
                    if (open != 0) {
                        uint256 openAmt = open * unit;
                        if (!bid) sums.baseIn += openAmt;
                        else sums.quoteIn += PriceGrid.quoteDown(openAmt, tick);
                    }
                    next = _withSub(next, i, 0);
                } else if (open == 0) {
                    // a claim of a sub-order with nothing open: emptied, its side with it, its base left as a settle
                    // leaves it
                    next = _emptied(next, i);
                } else {
                    // a claim: the open units rest on, the base drops to them
                    nextSet = BatchLib.withBase(nextSet, i, open);
                }
            }
            // ---- 2. rest the orders: order i checked as a maker's order and escrowed, the side it takes (s_i)
            // deciding the token (an ask base, a bid quote rounded up); it becomes sub-order i, its base its units
            for (uint256 m = masks.rest; m != 0; m &= m - 1) {
                uint256 i = BatchLib.lowestSub(m);
                (uint256 tick, uint256 amount) = _orderAt(params, amountWords, i);
                (uint256 q, uint256 units) = OloMath.toUnits(amount); // q at most 25: fits the 5-bit field
                uint256 stored = units * OloMath.pow10(q);
                // a modify's order the same as the sub-order was (its tick and open amount in `word`, and its side: D_i
                // in `word` against s_i): with no fills to pay it is wrong (a live sub-order has none when its base is
                // its open units: base i in `nextSet` is still the one the walk found, as pass 1 leaves a settled
                // sub-order's base as it was and this pass writes it only below); with fills it is kept, its fills
                // paid as a claim pays them. An empty index's zero order is wrong whatever its side. A live
                // sub-order turned to the other side is a changed order: settled on its old side above, escrowed on its
                // new one below. Wrong too: a tick off the grid or the spacing; no unit, or worth less than minQuote
                if (masks.same) {
                    uint256 old = BatchLib.subAt(word, i);
                    if (
                        tick == (old & TICK_FIELD)
                            && stored == (old >> SUB_OPEN) * OloMath.pow10((old >> SUB_Q) & SUB_Q_MASK)
                    ) {
                        if (old == 0) {
                            sums.bad |= BAD_SAME;
                        } else if (((word >> (BATCH_SIDES + i)) ^ (masks.newSides >> i)) & 1 == 0) {
                            // the same side too
                            if (BatchLib.baseAt(nextSet, i) == old >> SUB_OPEN) {
                                sums.bad |= BAD_SAME;
                            } else if ((masks.newSides >> i) & 1 == 1) {
                                // kept, a bid: it moves no escrow, as a claim moves none. Pass 1
                                // refunded its open amount's quote rounded down and below it is escrowed again rounded
                                // up, so the wei of rounding between the two goes back with the refund, and they cancel
                                sums.quoteIn += PriceGrid.quoteUp(stored, tick) - PriceGrid.quoteDown(stored, tick);
                            }
                        }
                    }
                }
                if (!c.makerTick(tick)) sums.bad |= BAD_TICK;
                else if (!_worthMin(c, tick, stored)) sums.bad |= BAD_SIZE;
                if ((masks.newSides >> i) & 1 == 0) sums.baseOut += stored; // s_i 0: an ask
                else sums.quoteOut += PriceGrid.quoteUp(stored, tick);
                // (an order of tick 0 and no amount would leave the index empty with its base rewritten; it never
                // stands: on an empty sub-order it is BAD_SAME, on a live one BAD_TICK)
                next = _withSub(next, i, tick | (q << SUB_Q) | (units << SUB_OPEN));
                nextSet = BatchLib.withBase(nextSet, i, units);
            }
            // the sides: each settled or rested index's cleared (a claim cleared the ones it emptied), then each rested
            // order's set, so an index never keeps a side it held before, whatever an empty index's side bit was; a
            // post's or a replace's word started with none
            next = (next & ~((masks.settle | masks.rest) << BATCH_SIDES)) | (masks.newSides << BATCH_SIDES);
        }
        // the words after, for `_manageBatch` to store
        sums.next = next;
        sums.set = nextSet;
    }

    /// @notice The sums' net flows to the caller's quote and base accounts of the market: the fee's maker part with
    /// the quote, the rest of it to the pot.
    function _batchFlows(MarketWord c, SlotSums memory sums) internal returns (int256 quoteFlow, int256 baseFlow) {
        uint256 quoteIn = sums.quoteIn;
        unchecked {
            // each sum is far below 2^255: four sub-orders, PriceGrid's bounds
            if (sums.fee != 0) quoteIn += _splitFee(c, sums.fee);
            quoteFlow = int256(quoteIn) - int256(sums.quoteOut);
            baseFlow = int256(sums.baseIn) - int256(sums.baseOut);
        }
    }

    /// @notice BatchUpdated's packed word: kind 0-2 | the sub-orders acted on 8-11 (IOloBookBase.BatchUpdated has the
    /// mask by kind) | slot 128-143 | market key 144-191 (the version 144-159, the id 160-191: MarketLib.marketKey).
    function _batchEventWord(uint256 marketKey, uint256 kind, uint256 acted, uint256 slotNo)
        internal
        pure
        returns (uint256)
    {
        return kind | (acted << 8) | (slotNo << 128) | (marketKey << 144);
    }

    /// @notice The word with sub-order `i`'s 61 bits replaced by `sub` (its side as it was).
    function _withSub(uint256 word, uint256 i, uint256 sub) internal pure returns (uint256) {
        unchecked {
            // i is 0 .. 3
            uint256 lowBit = BATCH_SUB_BASE + i * SUB_BITS;
            return (word & ~(SUB_MASK << lowBit)) | (sub << lowBit);
        }
    }

    /// @notice The word with sub-order `i` emptied: its 61 bits and its side cleared.
    function _emptied(uint256 word, uint256 i) internal pure returns (uint256) {
        unchecked {
            // i is 0 .. 3
            return word & ~((SUB_MASK << (BATCH_SUB_BASE + i * SUB_BITS)) | (1 << (BATCH_SIDES + i)));
        }
    }
}
