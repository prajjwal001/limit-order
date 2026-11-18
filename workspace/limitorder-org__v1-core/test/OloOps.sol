// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {C_KEY_MASK, C_TAG, TAG_CARRIED} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

/// Packed multicall headers and ops, take lists and packed-word calls of OloBook. Ticks are grid ticks (26 bits),
/// amounts base wei (below 2^112).
library OloOps {
    /// A multicall header with one market (index 0).
    function header(MarketWord c) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), MarketWord.unwrap(c));
    }

    /// PLACE: c u8 | tick u32 | side u8 | amount u112 | pos u32 (25 bytes).
    function place(uint8 ci, uint256 tick, bool isBid, uint256 amount, uint32 pos)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(uint8(1), ci, uint32(tick), uint8(isBid ? 1 : 0), uint112(amount), pos);
    }

    /// PLACE with `k` probes in the side byte's high nibble.
    function placeProbe(uint8 ci, uint256 tick, bool isBid, uint256 amount, uint32 pos, uint8 k)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(uint8(1), ci, uint32(tick), uint8((isBid ? 1 : 0) | (k << 4)), uint112(amount), pos);
    }

    function cancel(uint8 ci, uint32 pos) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(2), ci, pos);
    }

    function claim(uint8 ci, uint32 pos) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(3), ci, pos);
    }

    /// MODIFY: c u8 | pos u32 | newTick u32 | newAmount u112 (24 bytes).
    function modify(uint8 ci, uint32 pos, uint256 newTick, uint256 newAmount) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(4), ci, pos, uint32(newTick), uint112(newAmount));
    }

    function deposit(uint256 tokenId, uint128 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(5), uint32(tokenId), amount);
    }

    function withdraw(uint256 tokenId, uint128 amount) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(6), uint32(tokenId), amount);
    }

    /// The market's key K, the word every entry names its market by: C without its tag.
    function key(MarketWord c) internal pure returns (MarketWord) {
        return MarketWord.wrap(MarketWord.unwrap(c) & C_KEY_MASK);
    }

    /// `word` (a take's, takeThenRest's, cancel's, claim's, modify's or batch operation's params) carrying the tag of
    /// the version `c` names in its top 50 bits.
    function tagW(MarketWord c, uint256 word) internal pure returns (uint256) {
        return word | ((MarketWord.unwrap(c) >> C_TAG) << TAG_CARRIED);
    }

    /// A take list segment of pool entries: kind 0 | len u16 | entries (`poolEntry`).
    function poolList(bytes memory entries) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), uint16(entries.length), entries);
    }

    /// A take list segment of batch groups: kind 1 | len u16 | groups.
    function batchList(bytes memory groups) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), uint16(groups.length), groups);
    }

    /// One pool entry of a take list: the position and the tick the taker saw, the most a buy pays there and the
    /// least a sell takes (8 bytes).
    function poolEntry(uint32 pos, uint256 tick) internal pure returns (bytes memory) {
        return abi.encodePacked(pos, uint32(tick));
    }

    /// The pool entries of positions `from` .. `from + n - 1`, resting at `tick`, `tick + step`, ... (`step` signed).
    function poolEntries(uint32 from, uint256 n, uint256 tick, int256 step) internal pure returns (bytes memory g) {
        for (uint256 i; i < n; ++i) {
            g = bytes.concat(g, poolEntry(from + uint32(i), uint256(int256(tick) + step * int256(i))));
        }
    }

    /// The word of `place`: isBid 0 | tick 1-26 | amount 27-138 | pos 139-170 | flags 171-178.
    function placeW(bool isBid, uint256 tick, uint256 amount, uint32 pos, uint8 flags) internal pure returns (uint256) {
        require(tick < 1 << 26, "OloOps: tick");
        require(amount < 1 << 112, "OloOps: amount");
        return (isBid ? 1 : 0) | (tick << 1) | (amount << 27) | (uint256(pos) << 139) | (uint256(flags) << 171);
    }

    /// The word of `cancel` and `claim`: pos 0-31 | flags 32-39.
    function posW(uint32 pos, uint8 flags) internal pure returns (uint256) {
        return uint256(pos) | (uint256(flags) << 32);
    }

    /// The word of `modify`: pos 0-31 | newTick 32-57 | newAmount 58-169 | flags 170-177.
    function modifyW(uint32 pos, uint256 newTick, uint256 newAmount, uint8 flags) internal pure returns (uint256) {
        require(newTick < 1 << 26, "OloOps: tick");
        require(newAmount < 1 << 112, "OloOps: amount");
        return uint256(pos) | (newTick << 32) | (newAmount << 58) | (uint256(flags) << 170);
    }

    // A take's mode bits.
    uint8 internal constant WALLET = 0x01;
    uint8 internal constant QUOTE = 0x02; // the amount is quote wei
    uint8 internal constant FOK = 0x80;

    /// The word of `take`: buyBase 0 | amount 1-112 | mode 113-120.
    function takeW(bool buyBase, uint256 amount, uint8 mode) internal pure returns (uint256) {
        require(amount < 1 << 112, "OloOps: amount");
        return (buyBase ? 1 : 0) | (amount << 1) | (uint256(mode) << 113);
    }

    /// The word of `take` with fill-or-kill's tolerance: `takeW` plus maxLeft 121-197 (the FOK bit is the caller's).
    function takeW(bool buyBase, uint256 amount, uint8 mode, uint256 maxLeft) internal pure returns (uint256) {
        require(maxLeft < 1 << 77, "OloOps: maxLeft");
        return takeW(buyBase, amount, mode) | (maxLeft << 121);
    }

    /// A fill-or-kill take: what is left of `amount` (in its unit) at most `maxLeft`.
    function fokW(bool buyBase, uint256 amount, uint8 mode, uint256 maxLeft) internal pure returns (uint256) {
        return takeW(buyBase, amount, mode | FOK, maxLeft);
    }

    /// A quote-mode take: `amount` quote wei, what a buy pays with the fee or a sell receives less it, at most.
    function quoteW(bool buyBase, uint256 amount, uint8 mode) internal pure returns (uint256) {
        return takeW(buyBase, amount, mode | QUOTE);
    }

    /// The word of `takeThenRest`: `takeW` plus limitTick 121-146 | pos 147-178.
    function restW(bool buyBase, uint256 amount, uint256 limitTick, uint8 mode, uint32 pos)
        internal
        pure
        returns (uint256)
    {
        require(limitTick < 1 << 26, "OloOps: tick");
        return takeW(buyBase, amount, mode) | (limitTick << 121) | (uint256(pos) << 147);
    }

    // ------------------------------------------------------------ batch slots

    uint8 internal constant POST = 0;
    uint8 internal constant REPLACE = 1;
    uint8 internal constant MODIFY = 2;
    uint8 internal constant CANCEL = 3;
    uint8 internal constant CLAIM = 4;

    /// One order of `manageBatchSubs` as these helpers carry it (not the OLO EVM contract's layout): tick 0-31 | amount
    /// 32-143.
    function sub(uint256 tick, uint256 amount) internal pure returns (uint256) {
        require(tick < 1 << 26, "OloOps: sub tick");
        require(amount < 1 << 112, "OloOps: sub amount");
        return tick | (amount << 32);
    }

    /// `manageBatchSubs`'s params word and its two amount words (`wordsOf` hands the two to the entry): [0] kind 0-2 |
    /// slot 4-19 | flags 20-27 | mask 28-31 | tick i at 32 + 26 i | side s_i at 136 + i (1 a bid; the tag, 206-255,
    /// is `batchCalldata`'s); [1] amount 0 at 0-111 | amount 1 at 112-223; [2] amount 2 at 0-111 | amount 3 at
    /// 112-223. `isBid` sets every order's side (`withSides` sets each one, `withFlips` turns some); bit 3 stays 0.
    function batchW(uint8 kind, bool isBid, uint16 slot, uint8 flags, uint8 mask, uint256[4] memory orders)
        internal
        pure
        returns (uint256[3] memory w)
    {
        w[0] = uint256(kind) | (uint256(slot) << 4) | (uint256(flags) << 20) | (uint256(mask & 0xf) << 28)
            | (isBid ? uint256(0xf) << 136 : 0);
        for (uint256 i; i < 4; ++i) {
            uint256 tick = orders[i] & 0xffffffff;
            uint256 amount = orders[i] >> 32;
            w[0] |= tick << (32 + 26 * i);
            w[1 + i / 2] |= amount << (112 * (i % 2));
        }
    }

    /// `w` (`batchW`'s words) with the orders' sides at params bits 136-139 set to `sides`: bit i rests order i on
    /// the bid side, clear on the ask side, in a post, a replace and a modify alike (a cancel and a claim read none).
    function withSides(uint256[3] memory w, uint8 sides) internal pure returns (uint256[3] memory out) {
        out[0] = (w[0] & ~(uint256(0xf) << 136)) | (uint256(sides & 0xf) << 136);
        out[1] = w[1];
        out[2] = w[2];
    }

    /// `w`, fresh from `batchW`, with the orders `flips` names turned to the side opposite its `isBid`: the sides
    /// become isBid xor flips (bit i for order i), whichever kind the words are. A conversion of fresh words, once: it
    /// xors the sides `w` has, so a second call turns them back (new tests set the sides with `withSides`).
    function withFlips(uint256[3] memory w, uint8 flips) internal pure returns (uint256[3] memory out) {
        out[0] = w[0] ^ (uint256(flips & 0xf) << 136);
        out[1] = w[1];
        out[2] = w[2];
    }

    /// A post (or a replace) of `n` sub-orders of `amount` at `from`, `from` +- `step`, ... (asks up, bids down).
    function ladderW(
        uint8 kind,
        bool isBid,
        uint16 slot,
        uint8 flags,
        uint256 from,
        uint256 amount,
        uint256 n,
        uint256 step
    ) internal pure returns (uint256[3] memory) {
        uint256[4] memory o;
        for (uint256 i; i < n; ++i) {
            o[i] = sub(isBid ? from - step * i : from + step * i, amount);
        }
        return batchW(kind, isBid, slot, flags, 0, o);
    }

    /// A post of `n` sub-orders of `amount`, one tick apart (asks up, bids down).
    function postW(bool isBid, uint16 slot, uint256 from, uint256 amount, uint256 n)
        internal
        pure
        returns (uint256[3] memory)
    {
        return ladderW(POST, isBid, slot, 0, from, amount, n, 1);
    }

    /// A cancel or a claim (no orders) of the sub-orders `mask` names.
    function maskW(uint8 kind, uint16 slot, uint8 flags, uint8 mask) internal pure returns (uint256[3] memory) {
        uint256[4] memory none;
        return batchW(kind, false, slot, flags, mask, none);
    }

    /// `manageBatchSubs`'s calldata as an upstream sends it: the selector, the market's key K (`c` less its tag), the
    /// params word carrying the tag of the version `c` names (but a post's, which reads none: a post rests in the
    /// market's current version) and the two amount words.
    function batchCalldata(bytes4 selector, MarketWord c, uint256[3] memory w)
        internal
        pure
        returns (bytes memory data)
    {
        uint256 params = w[0] & 0xf == POST ? w[0] : tagW(c, w[0]);
        data = abi.encodeWithSelector(selector, key(c), params, wordsOf(w));
    }

    /// `manageBatchSubs`'s `amountWords` from these helpers' words.
    function wordsOf(uint256[3] memory w) internal pure returns (uint256[2] memory a) {
        a[0] = w[1];
        a[1] = w[2];
    }

    /// A batch group of a take list (kind 1 segments): maker 20 | slot 2 | mask 1 | a tick 4 per sub-order named, in
    /// index order (`ticks` holds one per index; the unnamed ones are left out).
    function slotGroup(address maker, uint16 slot, uint8 mask, uint256[4] memory ticks)
        internal
        pure
        returns (bytes memory g)
    {
        g = abi.encodePacked(maker, slot, mask);
        for (uint256 i; i < 4; ++i) {
            if ((mask >> i) & 1 != 0) g = bytes.concat(g, abi.encodePacked(uint32(ticks[i])));
        }
    }

    /// A group naming the sub-orders `mask` names, each bounded by `bound` (a buy's highest tick, a sell's lowest).
    function slotGroupAt(address maker, uint16 slot, uint8 mask, uint256 bound) internal pure returns (bytes memory) {
        return slotGroup(maker, slot, mask, [bound, bound, bound, bound]);
    }
}
