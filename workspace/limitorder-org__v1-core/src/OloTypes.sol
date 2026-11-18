// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

import {C_TOKEN_ID_MASK, TOKEN_ID_BITS} from "./types/Market.sol";
import {MarketWord} from "./interfaces/MarketWord.sol";

// The layouts of the OLO EVM contract's words and slots, as file-level constants these libraries and OloBook and
// OloBookExt share (and literals, which is what OloSlots' assembly can read).

// OloSlots' slot tags: the byte that ends each slot's hash preimage.
uint256 constant TAG_ORDER = 0x01;
uint256 constant TAG_BATCH = 0x02;
uint256 constant TAG_LISTING = 0x04;

// An account key is its token id, TOKEN_ID_BITS (32), and its owner above it in the accounts mapping's key
// (OloSlots.ownedKey); the caller's two keys of a market travel packed, quote << KEY_BITS | base, as C holds the two
// ids (C_BASE_ID). The three refer to Market.sol's constants rather than repeat them.
uint256 constant KEY_OWNER_SHIFT = TOKEN_ID_BITS;
uint256 constant KEY_BITS = TOKEN_ID_BITS;
uint256 constant KEY_MASK = C_TOKEN_ID_MASK;

// A balance account's word (AccountLib): amount 0-127 | USED 255; the fee pot's (owner 0's account): amount 0-254 |
// USED 255.
uint256 constant ACCOUNT_AMOUNT_MASK = 0xffffffffffffffffffffffffffffffff;
uint256 constant ACCOUNT_USED = 0x8000000000000000000000000000000000000000000000000000000000000000;
uint256 constant POT_AMOUNT_MASK = 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

// A pool position's word (PoolWord): tick 0-25 | q 26-32 | open 33-62 | filled 63-92 | isBid 93 | USED 94 | 95
// unused (zero) | owner 96-255. open and filled are units of 10^q base wei.
uint256 constant POOL_Q = 26;
uint256 constant POOL_OPEN = 33;
uint256 constant POOL_FILLED = 63;
uint256 constant POOL_BID = 93;
uint256 constant POOL_USED = 94;
uint256 constant POOL_OWNER = 96;
/// @dev A pool word's q, 7 bits.
uint256 constant POOL_Q_MASK = 0x7f;
/// @dev Open and filled units, 30 bits each (a batch sub-order's open units and base too).
uint256 constant UNITS_MASK = 0x3fffffff;
/// @dev A pool position number, 32 bits.
uint256 constant POS_MASK = 0xffffffff;
/// @dev A 26-bit tick field: a pool word's tick, a batch sub-order's, a params word's (ticks run 1 ..
/// PriceGrid.MAX_TICK < 2^26).
uint256 constant TICK_FIELD = 0x3ffffff;
/// @dev A 112-bit amount field of a params word or a batch order: every amount an order or a take is given is below
/// 2^112 (a deposit's and a withdrawal's amounts, and an account's balance, AccountLib.AMOUNT_MASK, are 128 bits).
uint256 constant AMOUNT_FIELD = 0xffffffffffffffffffffffffffff;
/// @dev Open and filled, once shifted down by POOL_OPEN: nonzero while the position holds an order.
uint256 constant POOL_LIVE_MASK = 0xfffffffffffffff;
/// @dev Tick, q, open and filled (bits 0-92): what a dead word clears, keeping the side, USED and the owner.
uint256 constant POOL_ORDER_MASK = 0x1fffffffffffffffffffffff;

// A maker's batch slot (BatchLib): two words, up to four sub-orders. The main word, at the slot's key: bit 0 zero |
// USED 1 | four sub-orders of 61 bits at 2, 63, 124 and 185, each, from its own lowest bit, tick 0-25 | q 26-30 | open
// 31-60 (units of 10^q base wei) | side D_i at 246 + i (sub-order i's side, 1 a bid; 0 while it is empty) | bits
// 250-255 zero. The settlement word, at key + 1: base i at 30 x i (sub-order i's open units as of its last maker
// settlement) | USED 255. A take writes the main word only (open -= fill); sub-order i's fills are base i - open i,
// which a maker's settle pays and moves base i to open i. A sub-order is empty when its 61 bits are zero (its base is
// then left over and counts for nothing), live otherwise: one filled to no open units is live, its side kept.
uint256 constant BATCH_USED = 2;
uint256 constant BATCH_SUBS = 4;
/// @dev Sub-order i's side bit (1 a bid) is BATCH_SIDES + i; the main word shifted down by it is the four sides
/// (bits 250-255 are zero), an empty sub-order's 0.
uint256 constant BATCH_SIDES = 246;
/// @dev Where sub-order 0 starts; sub-order i starts at BATCH_SUB_BASE + i x SUB_BITS.
uint256 constant BATCH_SUB_BASE = 2;
uint256 constant SUB_BITS = 61;
/// @dev A sub-order's 61 bits, once shifted down to its lowest bit.
uint256 constant SUB_MASK = 0x1fffffffffffffff;
uint256 constant SUB_Q = 26;
/// @dev A sub-order's q, 5 bits.
uint256 constant SUB_Q_MASK = 0x1f;
uint256 constant SUB_OPEN = 31;
/// @dev The settlement word: base i at SET_BASE_BITS x i (30 bits, units); USED keeps it nonzero.
uint256 constant SET_BASE_BITS = 30;
uint256 constant SET_USED = 0x8000000000000000000000000000000000000000000000000000000000000000;

/// @notice Where OloBook keeps things. Every hot-path key is derived from the market's config word `C`, one version of
/// the market (its key and its tag): the caller supplies C and the contract hashes it into the storage slot, so a wrong
/// C finds nothing and no market slot has to be read to check it.
/// The slots are raw keccak256 slots (not Solidity mappings), domain-separated by a trailing byte, one hash each.
library OloSlots {
    /// @notice The storage slot of pool position `pos` of market C: keccak256(C | pos u32 | 0x01).
    function orderSlot(MarketWord c, uint256 pos) internal pure returns (uint256 slot) {
        assembly ("memory-safe") {
            mstore(0x00, c)
            mstore(0x20, or(shl(224, and(pos, POS_MASK)), shl(216, TAG_ORDER)))
            slot := keccak256(0x00, 0x25)
        }
    }

    /// @notice The storage slot of `maker`'s batch slot `slot` of market C: keccak256(C | maker 20 | slot u16 | 0x02).
    /// Batch slots are the maker's own: only its operations rest, move or settle orders there (a take writes the main
    /// word, filling them), so none can be taken or exhausted by anyone else.
    function batchSlot(MarketWord c, address maker, uint256 slot) internal pure returns (uint256 word) {
        assembly ("memory-safe") {
            mstore(0x00, c)
            mstore(0x20, or(shl(96, maker), or(shl(80, and(slot, 0xffff)), shl(72, TAG_BATCH))))
            word := keccak256(0x00, 0x37)
        }
    }

    /// @notice The slot of a listing word: keccak256(the word's bytes 4-31 | 0x04), the listing's parameters without
    /// the id (MarketLib.encode: the tokens, the fee, the spacing and minQuote, and the proprietary bit a proprietary
    /// listing adds; no maker share or version), so one set of parameters is listed once. It holds the market's id,
    /// written by the listing and never again: a fee or share change neither frees the parameters it listed at nor
    /// takes the ones it moves to.
    function listingSlot(MarketWord params) internal pure returns (uint256 slot) {
        assembly ("memory-safe") {
            mstore(0x00, params)
            mstore8(0x20, TAG_LISTING)
            slot := keccak256(0x04, 0x1d)
        }
    }

    /// @notice The key of `owner`'s account of token `key` in the accounts mapping: owner 160 | tokenId 32. Every
    /// owner has its own account of each token, so nobody can open, take or squat another's; owner 0's account of a
    /// token is the protocol's fee pot.
    function ownedKey(uint256 key, address owner) internal pure returns (uint256) {
        return key | (uint256(uint160(owner)) << KEY_OWNER_SHIFT);
    }

    /// @notice The key of the protocol's fee pot of token `key`: owner 0's account of it.
    function potKey(uint256 key) internal pure returns (uint256) {
        return ownedKey(key, address(0));
    }

    function load(uint256 slot) internal view returns (uint256 word) {
        assembly ("memory-safe") {
            word := sload(slot)
        }
    }

    function store(uint256 slot, uint256 word) internal {
        assembly ("memory-safe") {
            sstore(slot, word)
        }
    }
}

/// @notice One order per word in a market-wide pool: the position is any 32-bit number the maker names, and the owner
/// is in the word, so a dead position is reusable by anyone and a market can be pre-warmed. tick 0-25 | q 26-32 |
/// open 33-62 | filled 63-92 (filled, unclaimed) | isBid 93 | USED 94 | 95 zero | owner 96-255 (the maker's whole
/// address, so no other address can act on the order). open and filled are units of 10^q base wei, q fixed at the
/// place (OloMath.toUnits); they sum to at most 2^30 - 1 (a fill moves units from open to filled, a claim or modify
/// clears filled), so filled never carries.
type PoolWord is uint256;

using PoolLib for PoolWord global;

library PoolLib {
    uint256 internal constant USED = 1 << POOL_USED;
    uint256 private constant LIVE_MASK = POOL_LIVE_MASK << POOL_OPEN; // open and filled

    function tickOf(PoolWord word) internal pure returns (uint256) {
        return PoolWord.unwrap(word) & TICK_FIELD;
    }

    function qOf(PoolWord word) internal pure returns (uint256) {
        return (PoolWord.unwrap(word) >> POOL_Q) & POOL_Q_MASK;
    }

    function openOf(PoolWord word) internal pure returns (uint256) {
        return (PoolWord.unwrap(word) >> POOL_OPEN) & UNITS_MASK;
    }

    function filledOf(PoolWord word) internal pure returns (uint256) {
        return (PoolWord.unwrap(word) >> POOL_FILLED) & UNITS_MASK;
    }

    function isBidOf(PoolWord word) internal pure returns (bool) {
        return (PoolWord.unwrap(word) >> POOL_BID) & 1 != 0;
    }

    function ownerOf(PoolWord word) internal pure returns (address) {
        return address(uint160(PoolWord.unwrap(word) >> POOL_OWNER));
    }

    /// @notice The word dead: tick, q, open and filled cleared, the side, USED and the owner kept (a dead position is
    /// anyone's).
    function dead(PoolWord word) internal pure returns (uint256) {
        return PoolWord.unwrap(word) & ~POOL_ORDER_MASK;
    }

    /// @notice The word with its fills claimed: filled cleared, the open units resting on.
    function claimed(PoolWord word) internal pure returns (uint256) {
        return PoolWord.unwrap(word) & ~(UNITS_MASK << POOL_FILLED);
    }

    /// @notice Open units or unclaimed fills: the position holds an order.
    function isLive(PoolWord word) internal pure returns (bool) {
        return PoolWord.unwrap(word) & LIVE_MASK != 0;
    }

    /// @notice A fresh order's word, as the contract stores it: `tick`, `q`, `units` open, no fills, the side, USED and
    /// the owner.
    function fresh(uint256 tick, uint256 q, uint256 units, bool isBid, address owner) internal pure returns (uint256) {
        uint256 side = isBid ? 1 << POOL_BID : 0;
        return tick | (q << POOL_Q) | (units << POOL_OPEN) | side | USED | (uint256(uint160(owner)) << POOL_OWNER);
    }
}

/// @notice A balance account: (owner, token) -> one word (OloSlots.ownedKey). amount 0-127 |
/// USED 255: the first credit writes the word, USED keeps it nonzero at a zero balance so later credits rewrite it. The
/// owner is in the key, not the word: there is nothing to check and nobody else's to take. Owner 0's account of every
/// token is the protocol's fee pot, and holds amount 0-254 | USED 255: its flows are unsigned (a settle's credit,
/// `collectFees`), and a fee that no owner's account could hold still has somewhere to go, so a settle that pays it
/// is never blocked.
library AccountLib {
    uint256 internal constant USED = ACCOUNT_USED;
    uint256 internal constant AMOUNT_MASK = ACCOUNT_AMOUNT_MASK;
    uint256 internal constant POT_MASK = POT_AMOUNT_MASK;

    function amountOf(uint256 word) internal pure returns (uint256) {
        return word & AMOUNT_MASK;
    }

    /// @notice The pot's balance from its word: every bit but USED. An owner's word never has bits 128-254 set, so
    /// this reads an account too (`balanceOf`).
    function potOf(uint256 word) internal pure returns (uint256) {
        return word & POT_MASK;
    }
}

/// @notice A maker's batch slot: two storage words holding up to four sub-orders, every one on chain, so a take names
/// the slot and reads the orders there (no data to send, nothing to verify). The main word (the slot's key): bit 0
/// zero | USED 1 | four sub-orders of 61 bits at 2, 63, 124 and 185, each tick 0-25 | q 26-30 | open 31-60 from its
/// own lowest bit | side D_i at 246 + i (1 a bid). The settlement word (key + 1): base i at 30 x i, sub-order i's
/// open units as of its last maker settlement | USED 255. A take reads and writes the main word only, filling each
/// sub-order as a pool order (open -= fill); the sub-order's fills are base - open, which a maker's settle (claim,
/// cancel, modify, replace) pays, moving base to open. A sub-order is empty when its 61 bits are zero and live
/// otherwise (a live one has a tick, and one filled to no open units is live until a settle empties it). A base counts
/// only while its sub-order is live: emptying a sub-order leaves its base as it was, and nothing reads it until the
/// index rests an order again, which rewrites it (so a cancel or a claim that empties sub-orders need not write the
/// settlement word).
/// USED keeps a slot whose sub-orders are all settled nonzero in both words, so its next post rewrites them (2.9k each)
/// instead of writing fresh ones (20k). Sub-order i rests on its side D_i: a post, a replace and a modify set the side
/// of each order they rest (the params' side bits), and an emptied sub-order's side is 0, so the word's sides are its
/// live bids.
library BatchLib {
    /// @dev Nibble m (m = 1 .. 15) is the index of m's lowest set bit (`lowestSub`).
    uint256 private constant LOWEST_SUB = 0x0102010301020100;

    /// @notice Sub-order `i`'s 61 bits, shifted down to bit 0.
    function subAt(uint256 word, uint256 i) internal pure returns (uint256) {
        unchecked {
            return (word >> (BATCH_SUB_BASE + i * SUB_BITS)) & SUB_MASK; // i is 0 .. 3
        }
    }

    function tickOf(uint256 sub) internal pure returns (uint256) {
        return sub & TICK_FIELD;
    }

    function qOf(uint256 sub) internal pure returns (uint256) {
        return (sub >> SUB_Q) & SUB_Q_MASK;
    }

    function openOf(uint256 sub) internal pure returns (uint256) {
        return sub >> SUB_OPEN;
    }

    /// @notice Sub-order `i`'s base in the settlement word.
    function baseAt(uint256 set, uint256 i) internal pure returns (uint256) {
        unchecked {
            return (set >> (i * SET_BASE_BITS)) & UNITS_MASK; // i is 0 .. 3
        }
    }

    /// @notice The settlement word with sub-order `i`'s base replaced by `base` (units, below 2^30).
    function withBase(uint256 set, uint256 i, uint256 base) internal pure returns (uint256) {
        unchecked {
            uint256 baseBit = i * SET_BASE_BITS; // i is 0 .. 3
            return (set & ~(UNITS_MASK << baseBit)) | (base << baseBit);
        }
    }

    /// @notice Each sub-order's side as a mask, bit i set for a bid (an empty sub-order's bit is 0).
    function bidMask(uint256 word) internal pure returns (uint256) {
        return word >> BATCH_SIDES; // bits 250-255 are zero
    }

    /// @notice The lowest sub-order a nonzero 4-bit mask names (bit i for sub-order i). A walk visits the named
    /// sub-orders in index order, and only those, by clearing each in turn: for (m = mask; m != 0; m &= m - 1).
    function lowestSub(uint256 mask) internal pure returns (uint256) {
        return (LOWEST_SUB >> (mask << 2)) & 0xf;
    }

    /// @notice The live sub-orders as a mask: bit i for sub-order i (its 61 bits not zero).
    function liveMask(uint256 word) internal pure returns (uint256 mask) {
        if (subAt(word, 0) != 0) mask |= 1;
        if (subAt(word, 1) != 0) mask |= 2;
        if (subAt(word, 2) != 0) mask |= 4;
        if (subAt(word, 3) != 0) mask |= 8;
    }

    /// @notice The sub-orders with fills to pay as a mask: bit i for a live sub-order i whose base is above its open
    /// units (an empty one's base is left over and counts for nothing).
    function filledMask(uint256 word, uint256 set) internal pure returns (uint256 mask) {
        uint256 sub = subAt(word, 0);
        if (sub != 0 && baseAt(set, 0) != openOf(sub)) mask |= 1;
        sub = subAt(word, 1);
        if (sub != 0 && baseAt(set, 1) != openOf(sub)) mask |= 2;
        sub = subAt(word, 2);
        if (sub != 0 && baseAt(set, 2) != openOf(sub)) mask |= 4;
        sub = subAt(word, 3);
        if (sub != 0 && baseAt(set, 3) != openOf(sub)) mask |= 8;
    }
}
