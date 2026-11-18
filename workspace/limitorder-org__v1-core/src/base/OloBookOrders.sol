// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

import {OloBookAssets} from "./OloBookAssets.sol";
import {OloMath} from "../libraries/OloMath.sol";
import {PriceGrid} from "../libraries/PriceGrid.sol";
import {MarketLib} from "../types/Market.sol";
import {MarketWord} from "../interfaces/MarketWord.sol";
import {OloSlots, POOL_BID, POOL_Q, POOL_Q_MASK, PoolLib, PoolWord, TICK_FIELD} from "../OloTypes.sol";

using MarketLib for MarketWord;

/// @title OloBookOrders
/// @notice The pool's single-order operations: place, cancel, claim and modify on one position's word, and the maker
/// events' data word.
abstract contract OloBookOrders is OloBookAssets {
    // ----------------------------------------------------------------- makers
    // The single-order operations read the order's word, write it back changed, and return what they move as two signed
    // flows, to the maker's quote and base accounts: the entry settles them by its flags (`_settleFlows`), the
    // multicall adds them to its ledger (`_ledgerFlows`). An order holds units x 10^q base wei (OloMath.toUnits) at a
    // tick of the grid (PriceGrid); its quote is rounded per order in the OLO EVM contract's favour: up what comes in
    // (a bid's escrow), down what goes out (proceeds, refunds, the fee's split). Nothing here overflows: units below
    // 2^30, q at most 25, PriceGrid's bounds.

    /// @dev Where the probes start in a place's flags (a multicall PLACE's side byte too), bits 4-7: how many further
    /// positions to try when the named one is busy, pos .. pos + k; the order lands on the first free one.
    uint256 internal constant PROBE_SHIFT = 4;

    /// @dev The low bits of what the callers pass `_placeOp` mean nothing: a place's flags bits 0 and 3 (the caller
    /// strips its settle bits 1-2 first), a multicall PLACE's side byte bits 1-3 (its side bit 0 stripped), and a
    /// takeThenRest passes its probes alone.
    uint256 internal constant NOT_PLACE_FLAGS = 0x0f;

    /// @notice An amount as an order rests it: its q and units (OloMath.toUnits) and the amount stored, units x 10^q,
    /// checked to be at least one unit and worth at least the market's minQuote at `tick` (SizeOutOfRange otherwise).
    /// Every order that must rest passes here: a place, a multicall PLACE, a modify (the batch walk checks its
    /// sub-orders the same way). A takeThenRest's rest is measured the same way by `OloBook._restsAt`, which skips the
    /// rest instead of reverting when it is worth too little. `c` is read for minQuote only, a field of the key, so K
    /// (as `place` and `takeThenRest` pass it) and any version's C give the same answer.
    function _restAmount(MarketWord c, uint256 tick, uint256 amount)
        internal
        pure
        returns (uint256 q, uint256 units, uint256 stored)
    {
        (q, units) = OloMath.toUnits(amount);
        unchecked {
            stored = units * OloMath.pow10(q); // at most `amount`
        }
        if (!_worthMin(c, tick, stored)) revert SizeOutOfRange();
    }

    /// @notice Whether `stored` base wei at `tick` is a restable order: not zero, and worth at least the market's
    /// minQuote (floor(amount x P) >= minQuote, which for an integer minQuote is amount x P >= minQuote exactly). `c`
    /// is read for minQuote only, a key field: K or any version's C.
    function _worthMin(MarketWord c, uint256 tick, uint256 stored) internal pure returns (bool) {
        if (stored == 0) return false;
        uint256 minQuote = c.minQuote();
        if (minQuote == 0) return true;
        unchecked {
            // stored x P >= minQuote, as integers: stored x mantissa x 10^(d - 43) >= minQuote in decades 43 and up,
            // stored x mantissa >= minQuote x 10^(43 - d) below (no overflow: stored below 2^114, the mantissa below
            // 2^20, a tick below 2^26 is decade 74 at most, so 10^(d - 43) <= 10^31; minQuote below 2^96, 10^43 <
            // 2^143)
            uint256 decade = tick / PriceGrid.PER_DECADE;
            uint256 v = stored * (PriceGrid.MANTISSA_BASE + tick % PriceGrid.PER_DECADE);
            if (decade >= PriceGrid.EXP_OFFSET) return v * OloMath.pow10(decade - PriceGrid.EXP_OFFSET) >= minQuote;
            return v >= minQuote * OloMath.pow10(PriceGrid.EXP_OFFSET - decade);
        }
    }

    /// @notice Rests an order the caller checked and sized (C its market's current one, `_current` or `_checkCurrent`;
    /// its tick a maker's; `_restAmount` or `_restsAt`: q, units and the amount stored, restable) in position `pos`, or
    /// in the first free one of pos .. pos + k when `flags` asks for k probes; returns where it landed, the escrow the
    /// caller takes for it from the maker's account `key` of the escrow token, and the order's word (for the Placed
    /// event).
    function _placeOp(
        MarketWord c,
        bool isBid,
        uint256 tick,
        uint256 q,
        uint256 units,
        uint256 stored,
        uint32 pos,
        uint8 flags,
        uint256 acctKeys
    ) internal returns (uint256 landed, uint256 key, uint256 escrow, uint256 placed) {
        if (flags & NOT_PLACE_FLAGS != 0) revert BadFlags();
        uint256 probes = flags >> PROBE_SHIFT;
        // the first free position of pos .. pos + probes: no open units and no unclaimed fills (a filled order holds
        // its position until its claim)
        uint256 slot = 0;
        uint256 word = 0;
        while (true) {
            slot = OloSlots.orderSlot(c, pos);
            word = OloSlots.load(slot);
            if (!PoolWord.wrap(word).isLive()) break;
            if (probes == 0) revert SlotBusy();
            unchecked {
                --probes;
                ++pos; // wraps at 2^32, as `orderSlot` masks the position
            }
        }
        placed = PoolLib.fresh(tick, q, units, isBid, msg.sender);
        OloSlots.store(slot, placed);
        // the escrow: an ask its amount in base, a bid its quote rounded up
        if (isBid) {
            escrow = PriceGrid.quoteUp(stored, tick);
            key = _quoteKey(acctKeys);
        } else {
            escrow = stored;
            key = _baseKey(acctKeys);
        }
        landed = pos;
    }

    /// @notice Settles the caller's order at `slot`: fills pay their proceeds and the maker's part of their fee (the
    /// rest of it to the pot), open units refund; the word is dead after (USED and the owner kept). Returns what the
    /// events log: the order's word, the open and filled amounts in base wei, and the proceeds; and the flows to the
    /// maker's quote and base accounts.
    function _cancelOp(MarketWord c, uint256 slot)
        internal
        returns (PoolWord word, uint256 open, uint256 filled, uint256 proceeds, int256 quoteFlow, int256 baseFlow)
    {
        word = PoolWord.wrap(OloSlots.load(slot));
        if (!word.isLive()) revert NoOrder();
        if (word.ownerOf() != msg.sender) revert NotOrderOwner();
        uint256 tick = word.tickOf();
        bool isBid = word.isBidOf();
        OloSlots.store(slot, word.dead());
        uint256 quoteAmt = 0;
        uint256 baseAmt = 0;
        unchecked {
            // units below 2^30 x 10^q, q at most 25: no overflow
            uint256 unit = OloMath.pow10(word.qOf());
            open = word.openOf() * unit;
            filled = word.filledOf() * unit;
            // an ask refunds its open amount in base and is paid its fills' quote; a bid the reverse. Quote going out
            // rounds down: the takes paid it rounded up, a bid escrowed it rounded up
            if (isBid) {
                quoteAmt = PriceGrid.quoteDown(open, tick);
                baseAmt = filled;
                proceeds = filled;
            } else {
                // an unfilled ask, the common cancel, prices nothing
                if (filled != 0) quoteAmt = PriceGrid.quoteDown(filled, tick);
                baseAmt = open;
                proceeds = quoteAmt;
            }
            if (filled != 0) {
                // the fills' fee, floored (the takes collected it rounded up); `_splitFee` pays the maker's part
                uint256 fee = PriceGrid.feeDown(filled, tick, c.feePpm());
                if (fee != 0) quoteAmt += _splitFee(c, fee);
            }
            // both below 2^235 (PriceGrid's bounds)
            quoteFlow = int256(quoteAmt);
            baseFlow = int256(baseAmt);
        }
    }

    /// @notice Pays the caller's order's fills and the maker's part of their fee (the rest of it to the pot); the order
    /// keeps resting with its open units. Returns what the events log: the order's word, the filled amount in base
    /// wei and the proceeds; and the flows to the maker's quote and base accounts.
    function _claimOp(MarketWord c, uint256 slot)
        internal
        returns (PoolWord word, uint256 filled, uint256 proceeds, int256 quoteFlow, int256 baseFlow)
    {
        word = PoolWord.wrap(OloSlots.load(slot));
        if (!word.isLive()) revert NoOrder();
        if (word.ownerOf() != msg.sender) revert NotOrderOwner();
        uint256 filledUnits = word.filledOf();
        if (filledUnits == 0) revert NothingToClaim();
        uint256 tick = word.tickOf();
        bool isBid = word.isBidOf();
        OloSlots.store(slot, word.openOf() == 0 ? word.dead() : word.claimed()); // nothing open: dead
        uint256 quoteAmt = 0;
        uint256 baseAmt = 0;
        unchecked {
            // units below 2^30 x 10^q, q at most 25; PriceGrid's bounds: no overflow
            filled = filledUnits * OloMath.pow10(word.qOf());
            // the fills' fee, floored (the takes collected it rounded up); `_splitFee` pays the maker's part
            uint256 fee = PriceGrid.feeDown(filled, tick, c.feePpm());
            if (fee != 0) quoteAmt = _splitFee(c, fee);
            if (isBid) {
                proceeds = filled;
                baseAmt = filled;
            } else {
                proceeds = PriceGrid.quoteDown(filled, tick);
                quoteAmt += proceeds;
            }
            // both below 2^235 (PriceGrid's bounds)
            quoteFlow = int256(quoteAmt);
            baseFlow = int256(baseAmt);
        }
    }

    /// @notice Changes the caller's order in place (C checked current by the caller, `_checkCurrent`): pays its
    /// fills (and the maker's part of their fee, the rest of it to the pot), then rests `newAmount` (stored as its own
    /// units and q) at `newTick` under the same position, moving only the net escrow. Returns what the events log: the
    /// old order's word, its filled amount and proceeds, and the new order's amount stored and word; and the flows to
    /// the maker's quote and base accounts. An order kept at its tick and open amount is NoChange when it has no fills
    /// to pay; with fills the modify pays them, as a claim does, and the order rests on, moving no escrow: a take that
    /// brings an order down to the size its maker is modifying it to must not revert the maker's call, nor cost the maker a wei of a bid's escrow rounding it cannot pay.
    function _modifyOp(MarketWord c, uint256 slot, uint256 newTick, uint256 newAmount)
        internal
        returns (
            PoolWord word,
            uint256 filled,
            uint256 proceeds,
            uint256 stored,
            uint256 placed,
            int256 quoteFlow,
            int256 baseFlow
        )
    {
        word = PoolWord.wrap(OloSlots.load(slot));
        if (!word.isLive()) revert NoOrder();
        if (word.ownerOf() != msg.sender) revert NotOrderOwner();
        if (!c.makerTick(newTick)) revert TickOutOfRange();
        (uint256 newQ, uint256 newUnits, uint256 stored_) = _restAmount(c, newTick, newAmount);
        stored = stored_;
        uint256 tick = word.tickOf();
        uint256 open;
        unchecked {
            // units below 2^30 x 10^q, q at most 25: below 2^114
            uint256 unit = OloMath.pow10(word.qOf());
            open = word.openOf() * unit;
            filled = word.filledOf() * unit;
        }
        // kept: the same tick and open amount. With no fills to pay that changes nothing; with fills it pays them, as a
        // claim does, and the order rests on with the escrow it holds
        bool kept = newTick == tick && stored == open;
        if (kept && filled == 0) revert NoChange();
        bool isBid = word.isBidOf();
        placed = PoolLib.fresh(newTick, newQ, newUnits, isBid, msg.sender);
        OloSlots.store(slot, placed);
        unchecked {
            // the flows are signed differences far below 2^255 (PriceGrid's bounds)
            uint256 fee;
            if (filled != 0) {
                // the fills' fee, floored (the takes collected it rounded up); `_splitFee` pays the maker's part
                fee = PriceGrid.feeDown(filled, tick, c.feePpm());
                if (fee != 0) fee = _splitFee(c, fee); // the maker's part from here on
                proceeds = isBid ? filled : PriceGrid.quoteDown(filled, tick);
            }
            if (isBid) {
                // bid: base gets the proceeds, quote the fee and the escrow difference (the old open amount's refund
                // rounded down, the new escrow rounded up). A kept order moves no escrow, as a claim moves none: the
                // contract holds at least its open amount's quote for it, and a refund and a re-escrow of the same
                // amount would take a wei of rounding from the maker whenever that quote is not whole
                baseFlow = int256(proceeds);
                quoteFlow = kept
                    ? int256(fee)
                    : int256(fee + PriceGrid.quoteDown(open, tick)) - int256(PriceGrid.quoteUp(stored, newTick));
            } else {
                // ask: quote gets the proceeds and the fee, base the escrow difference
                quoteFlow = int256(proceeds + fee);
                baseFlow = int256(open) - int256(stored);
            }
        }
    }

    /// @notice A modify as an entry: the op on the caller's order at `pos`, its events, and its flows settled by
    /// `flags` (the shape of OloBook's cancel and claim entries). Returns the amount stored.
    function _modifyEntry(MarketWord c, uint32 pos, uint256 newTick, uint256 newAmount, uint8 flags)
        internal
        returns (uint256 stored)
    {
        uint256 settle = _checkSettleFlags(flags);
        // the order's version must be the current one: an older version's orders cancel and claim, but rest no new
        // order
        _checkCurrent(c);
        PoolWord word;
        uint256 filled;
        uint256 proceeds;
        uint256 placed;
        int256 quoteFlow;
        int256 baseFlow;
        (word, filled, proceeds, stored, placed, quoteFlow, baseFlow) =
            _modifyOp(c, OloSlots.orderSlot(c, pos), newTick, newAmount);
        uint256 market = c.marketKey();
        uint256 old = PoolWord.unwrap(word);
        if (filled != 0) emit Claimed(msg.sender, _eventWord(market, old, filled, pos), proceeds);
        // the new order's word, and the old tick at 224-249
        emit Modified(msg.sender, _eventWord(market, placed, stored, pos) | (word.tickOf() << 224));
        _settleFlows(_acctKeys(c), quoteFlow, baseFlow, settle);
    }

    /// @notice Data word of the maker events, from the order's pool word: tick 0-25 | isBid 26 | q 27-31 | amount
    /// 32-143 (base wei: units x 10^q of the order's q) | position 144-175 | the market key 176-223 (the version
    /// 176-191, the id 192-223: C's top 48 bits, MarketLib.marketKey). q is the order's
    /// own (at most 25, so the pool word's 7-bit q fits the event's 5 bits): the amount alone does not always name it
    /// (an order of 107,374,182 units at q stores what 1,073,741,820 units at q - 1 would), and the event carries it
    /// for the order's unit. An amount is below 2^112, the field's width: an order is given an amount below 2^112 and
    /// stores at most what it was given.
    function _eventWord(uint256 marketKey, uint256 word, uint256 amount, uint256 pos) internal pure returns (uint256) {
        return (word & TICK_FIELD) | (((word >> POOL_BID) & 1) << 26) | (((word >> POOL_Q) & POOL_Q_MASK) << 27)
            | (amount << 32) | (pos << 144) | (marketKey << 176);
    }
}
