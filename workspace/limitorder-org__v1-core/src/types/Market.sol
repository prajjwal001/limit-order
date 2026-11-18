// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

import {PriceGrid} from "../libraries/PriceGrid.sol";
import {MarketWord} from "../interfaces/MarketWord.sol";

/// @notice A market's listing parameters, as `listMarketQuote` encodes them into the market's config word.
struct Market {
    uint32 baseId; // token ids from the OLO EVM contract's registry
    uint32 quoteId;
    uint24 feePpm; // taker fee, parts per million of the quote amount
    uint16 spacing; // maker tick spacing 1 / 10 / 100 / 1000: 6 / 5 / 4 / 3 significant figures (PriceGrid.spacingOf)
    // the least a resting order (a pool order, a batch sub-order, a takeThenRest's rest) is worth at its tick, in
    // quote wei (0: no minimum)
    uint96 minQuote;
}

/// @dev A token id's bits, the width of C's two token fields, of an account key's id (OloTypes' KEY_BITS,
/// KEY_OWNER_SHIFT, KEY_MASK) and of the registry (MarketLib.MAX_TOKEN_ID). It names the width, it is not a parameter:
/// C's other fields (C_SPACING and after) are literals placed after two ids of 32 bits, and the uint32 types and a
/// multicall op's byte layout are written for it too. The constants that use it refer to it or hold a literal: a
/// constant defined by an expression changes the contract's code (`(1 << TOKEN_ID_BITS) - 1` for the mask costs every
/// take 8 to 9 gas, measured), so C_TOKEN_ID_MASK is a literal and a test holds the two to each other
/// (`test_config_word_fields_fit`).
uint256 constant TOKEN_ID_BITS = 32;

// The config word's fields: each one's lowest bit, file-level so code outside MarketLib can read C directly (the
// account keys at C_BASE_ID, the id at C_MARKET_ID, the tag at C_TAG), and the masks the getters and MAX_TOKEN_ID use.
// The quote id follows the base id, which starts at bit 0: C_QUOTE_ID is C_BASE_ID + TOKEN_ID_BITS, written as the
// reference.
uint256 constant C_BASE_ID = 0;
uint256 constant C_QUOTE_ID = TOKEN_ID_BITS;
uint256 constant C_SPACING = 64;
uint256 constant C_MIN_QUOTE = 74;
/// @dev A proprietary market's bit, a key bit (MarketLib.isProprietary); bits 171-173 are zero.
uint256 constant C_PROPRIETARY = 170;
uint256 constant C_MAKER_BPS = 174;
uint256 constant C_FEE_PPM = 188;
uint256 constant C_VERSION = 208;
uint256 constant C_MARKET_ID = 224;
uint256 constant C_FEE_PPM_MASK = 0xfffff;
uint256 constant C_TOKEN_ID_MASK = 0xffffffff;
uint256 constant C_SPACING_MASK = 0x3ff;
uint256 constant C_MIN_QUOTE_MASK = 0xffffffffffffffffffffffff;
uint256 constant C_MAKER_BPS_MASK = 0x3fff;
/// @dev C_PROPRIETARY's bit in place, 1 << 170, written out (a constant defined by an expression can change the
/// contract's code).
uint256 constant C_PROPRIETARY_FLAG = 0x4000000000000000000000000000000000000000000;
/// @dev The tag's lowest bit: the tag is makerBps, feePpm and version, bits 174-223, 50 bits (C_MAKER_BPS is its
/// first field).
uint256 constant C_TAG = 174;
/// @dev The tag in place, bits 174-223: what a fee or share change rewrites (C_TAG_FIELD), what the key keeps
/// (C_KEY_MASK, every other bit).
uint256 constant C_TAG_FIELD = 0x00000000ffffffffffffc0000000000000000000000000000000000000000000;
uint256 constant C_KEY_MASK = 0xffffffff0000000000003fffffffffffffffffffffffffffffffffffffffffff;
/// @dev The fee and the maker share in place, each its own field of the tag (the extension rewrites one at a time).
uint256 constant C_FEE_PPM_FIELD = 0x000000000000fffff00000000000000000000000000000000000000000000000;
uint256 constant C_MAKER_BPS_FIELD = 0x00000000000000000fffc0000000000000000000000000000000000000000000;
/// @dev Where a word that carries a tag holds it: its top 50 bits, 206-255 (the params of a take, a takeThenRest, a
/// cancel, a claim, a modify and a batch operation other than a post; an order id; MarketLib.withTag).
uint256 constant TAG_CARRIED = 206;

// MarketWord, the config word C, is defined with its layout in interfaces/MarketWord.sol, MIT like the rest of that
// folder: IOloBook imports it and nothing else, so an integration compiles neither this file nor the price grid.
// MarketLib binds to it here and in each file that calls its functions (`using MarketLib for MarketWord;`): a `global`
// binding would have to sit in MarketWord's own file and import this one.
using MarketLib for Market global;
using MarketLib for MarketWord;

library MarketLib {
    /// @notice The largest taker fee, 100%; the 20-bit field holds up to 1,048,575. A version at 100% settles no taker
    /// sell that fills (SellBelowFee), and a buy there pays its quote twice, each rounded up.
    uint24 internal constant MAX_FEE_PPM = 1_000_000;

    /// @notice The most one owner call moves a fee, up or down: 1% of the quote, in ppm. `setMarketFee` (a market's
    /// fee, from its current version's), `setGlobalFeeFloor` and `setPairFeeFloor` (the floor a listing meets) each
    /// step by at most this (FeeStepTooLarge).
    uint24 internal constant MAX_FEE_STEP_PPM = 10_000;

    /// @notice The last version a market reaches: a fee or share change past it reverts (TooManyVersions).
    uint16 internal constant MAX_VERSION = type(uint16).max;

    /// @notice The largest token id the word holds; the token registry refuses more.
    uint256 internal constant MAX_TOKEN_ID = C_TOKEN_ID_MASK;

    /// @notice The listing's parameters as a word: the tokens, the fee, the spacing and minQuote, with no maker share,
    /// version or id (the listing adds them to make C; its listing word is keyed by these and the proprietary bit a
    /// proprietary listing adds, OloSlots.listingSlot).
    function encode(Market memory market) internal pure returns (MarketWord) {
        return MarketWord.wrap(
            (uint256(market.baseId) << C_BASE_ID) | (uint256(market.quoteId) << C_QUOTE_ID)
                | (uint256(market.feePpm) << C_FEE_PPM) | (uint256(market.spacing) << C_SPACING)
                | (uint256(market.minQuote) << C_MIN_QUOTE)
        );
    }

    function feePpm(MarketWord word) internal pure returns (uint24) {
        return uint24((MarketWord.unwrap(word) >> C_FEE_PPM) & C_FEE_PPM_MASK);
    }

    /// @notice The makers' part of the fee their fills earn, in bps, for the orders of this version: paid when they
    /// settle, the protocol's pot takes the rest.
    function makerBps(MarketWord word) internal pure returns (uint16) {
        return uint16((MarketWord.unwrap(word) >> C_MAKER_BPS) & C_MAKER_BPS_MASK);
    }

    /// @notice The version of the market's fee and share this word carries: 1 at the listing, one more at each change.
    function version(MarketWord word) internal pure returns (uint16) {
        return uint16(MarketWord.unwrap(word) >> C_VERSION);
    }

    /// @notice `k` with the tag `carrier` holds in its top 50 bits (TAG_CARRIED) or-ed in at bits 174-223: the C of
    /// the version the caller names, for an entry that fills or settles orders (a take, a cancel, a claim) or names
    /// the version it rests in again (a modify, a batch replace or modify). `k` must be the market's key, its tag bits
    /// zero, and then C is k's key and the carried tag. Nothing checks it: a word with tag bits of its own is or-ed
    /// with the carried tag, and the or of two tags can happen to be another real version's (a fee moved away and back
    /// gives a version whose tag bits contain the first's), whose orders the call then reaches as their owner could
    /// anyway; it never reaches another owner's order or a fee no version has. No read: the C hashes into the orders'
    /// slots, and only a version's own C finds its orders.
    function withTag(MarketWord k, uint256 carrier) internal pure returns (MarketWord) {
        return MarketWord.wrap(MarketWord.unwrap(k) | ((carrier >> TAG_CARRIED) << C_TAG));
    }

    /// @notice C's tag as a word that carries one holds it, in its top 50 bits (TAG_CARRIED): or-ed with an order's
    /// position it is the order's id, the shape of a cancel's or a claim's params (`withTag` reads it back).
    function tagCarried(MarketWord c) internal pure returns (uint256) {
        return (MarketWord.unwrap(c) >> C_TAG) << TAG_CARRIED;
    }

    /// @notice The market key the events carry: the id and the version, C's top 48 bits (id << 16 | version).
    function marketKey(MarketWord word) internal pure returns (uint256) {
        return MarketWord.unwrap(word) >> C_VERSION;
    }

    function baseId(MarketWord word) internal pure returns (uint32) {
        return uint32(MarketWord.unwrap(word) >> C_BASE_ID);
    }

    function quoteId(MarketWord word) internal pure returns (uint32) {
        return uint32(MarketWord.unwrap(word) >> C_QUOTE_ID);
    }

    function marketId(MarketWord word) internal pure returns (uint32) {
        return uint32(MarketWord.unwrap(word) >> C_MARKET_ID);
    }

    /// @notice The maker tick spacing, 1 / 10 / 100 / 1000 (6 / 5 / 4 / 3 significant figures).
    function spacing(MarketWord word) internal pure returns (uint16) {
        return uint16((MarketWord.unwrap(word) >> C_SPACING) & C_SPACING_MASK);
    }

    /// @notice The least a resting order is worth at its tick, in quote wei (0: any order of at least one unit).
    function minQuote(MarketWord word) internal pure returns (uint256) {
        return (MarketWord.unwrap(word) >> C_MIN_QUOTE) & C_MIN_QUOTE_MASK;
    }

    /// @notice Whether a maker may rest at `tick`: on the makers' part of the grid (PriceGrid.MIN_MAKER_TICK, decade
    /// 4's first tick, .. MAX_TICK) and on the market's spacing (a multiple of it, so a price of the market's
    /// significant figures). Every resting order passes here: a place, a modify, a batch operation's walk per
    /// sub-order, a takeThenRest's limit. The caller may supply the word, so one nobody listed may carry a spacing of
    /// 0: the listing check refuses it, and the spacing test must not panic first. Reads the spacing only, a key field:
    /// K (as `place` and `takeThenRest` pass it) or any version's C.
    function makerTick(MarketWord word, uint256 tick) internal pure returns (bool) {
        unchecked {
            // MIN_MAKER_TICK .. MAX_TICK as one compare: below the floor, tick - MIN_MAKER_TICK wraps past the range
            if (tick - PriceGrid.MIN_MAKER_TICK > PriceGrid.MAX_TICK - PriceGrid.MIN_MAKER_TICK) return false;
        }
        uint256 spacing_ = word.spacing();
        return spacing_ == 0 || tick % spacing_ == 0;
    }

    /// @notice Whether the market is proprietary: listed by a lister the owner allows, with a policy that admits who
    /// trades there (`listMarketQuoteProprietary`, IOloMarketPolicy). A key bit, set at the listing for good: K and
    /// every version's C carry it, and only a word that carries it reaches the market's orders, whose slots it hashes
    /// into.
    function isProprietary(MarketWord word) internal pure returns (bool) {
        return MarketWord.unwrap(word) & C_PROPRIETARY_FLAG != 0;
    }

    /// @notice Whether a word read from the contract's market registry (by id, OloBookStorage._market) is a listed
    /// market's: a listed market's base id is at least 1, so its word is never zero, and an id never listed reads zero.
    /// Not for a word a caller supplies, which any nonzero value passes: OloBookStorage._current and _checkCurrent
    /// check those against the registry.
    function isSet(MarketWord word) internal pure returns (bool) {
        return MarketWord.unwrap(word) != 0;
    }
}
