// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

/// The position segment's loop (OloBookTakes._fillList) in its plainest Solidity, one entry at a time, for reading
/// beside it and for the differential fuzz (OloPoolTakeRef.t.sol) to hold the OLO EVM contract to.
library PoolTakeRef {
    // a pool word: tick 0-25 | q 26-32 | open 33-62 | filled 63-92 | isBid 93 | USED 94 | owner 96-255
    uint256 internal constant UNITS = (1 << 30) - 1;

    /// One entry of a position segment against the word in its position (base mode): the word after, the units
    /// filled, the base amount they are (units x 10^q), and the order's unit 10^q when the walk reached it (live, on
    /// the other side, within the entry's tick; 0 otherwise). `entryTick` is the tick the taker saw the order at, its
    /// bound.
    function fillEntry(uint256 word, uint256 entryTick, bool buy, uint256 remaining)
        internal
        pure
        returns (uint256 next, uint256 x, uint256 amount, uint256 unit)
    {
        next = word;
        uint256 open = (word >> 33) & UNITS;
        bool isBid = (word >> 93) & 1 == 1;
        uint256 tick = word & 0x3ffffff;
        // nothing open (dead, or filled whole)
        if (open == 0) return (next, 0, 0, 0);
        // the taker's own side: a buy takes asks, a sell bids
        if (isBid == buy) return (next, 0, 0, 0);
        // worse than the tick the taker saw: an ask above it for a buy, a bid below it for a sell
        if (buy ? tick > entryTick : tick < entryTick) return (next, 0, 0, 0);
        // whole units: min(open, floor(remaining / 10^q)), at the order's own tick, moved from open to filled
        unit = 10 ** ((word >> 26) & 0x7f);
        x = remaining / unit;
        if (x > open) x = open;
        amount = x * unit;
        next = word - (x << 33) + (x << 63);
    }
}
