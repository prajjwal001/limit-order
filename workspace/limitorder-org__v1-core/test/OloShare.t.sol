// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {OloOps} from "./OloOps.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {MockERC20} from "./utils/MockERC20.sol";

/// The maker share is the version's, in its C: a share change makes the market's next version, and an order settles at
/// the share of the version it rests in, whenever it settles. A take holds the whole fee, and a settle that pays fills
/// (claim, a cancel or modify with fills, a batch claim, cancel, modify or replace) gives the maker floor(fee x share)
/// and the pot the rest, the fee being floor(amount x P x feePpm) per order. Every path that rests an order rests it in
/// the market's current version, so its fills settle at the share current when it was placed; a path that would rest
/// an order again in an older version (a modify, a batch replace or modify, a multicall PLACE or MODIFY under that
/// version's C) reverts MarketFrozen, and the maker cancels (at the old share) and places again.
contract OloShareTest is OloBase {
    uint256 constant TK = T + 1; // 100,001: a lot is 1,000,010 quote wei

    function setUp() public {
        _deploy();
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    /// The fee `lots` earned at `tick` (floored, as a settle takes it), and what the pot gets of it at `bps`.
    function _fee(uint256 lots, uint256 tick) internal pure returns (uint256) {
        return lots * _lq(tick) * 50 / 1e6;
    }

    function _potPart(uint256 fee, uint256 bps) internal pure returns (uint256) {
        return fee - fee * bps / 10_000;
    }

    function _takeAt(uint32 pos, uint256 tick, uint256 lots) internal {
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntry(pos, tick)),
            OloOps.tagW(c, OloOps.takeW(true, lots * LOT, 0))
        );
    }

    /// A modify splits its fills' fee inline, the split `_splitFee` makes for a claim: two like orders filled alike,
    /// one settled by a modify that adds a lot and one by a claim, pay the maker the same proceeds and fee part (the
    /// modify also escrows the lot it adds) and the pot the same rest, at any share, size, fill and side.
    function testFuzz_modify_splits_as_claim(uint16 share, uint48 lots, uint48 fill, bool isBid) public {
        share = uint16(bound(share, 0, 10_000));
        lots = uint48(bound(lots, 2, 1e6));
        fill = uint48(bound(fill, 1, lots - 1));
        _setMarketShare(share);
        address a = _maker();
        address b = _maker();
        uint32[2] memory pos = [_pos(), _pos()];
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(isBid, TK, lots * LOT, pos[0], 0));
        vm.prank(b);
        book.place(OloOps.key(c), OloOps.placeW(isBid, TK, lots * LOT, pos[1], 0));
        for (uint256 i; i < 2; ++i) {
            vm.prank(taker);
            book.take(
                OloOps.key(c),
                OloOps.poolList(OloOps.poolEntry(pos[i], TK)),
                OloOps.tagW(c, OloOps.takeW(!isBid, fill * LOT, 0))
            );
        }
        uint256 pot0 = _pot(quote);
        (uint256 qa, uint256 ba) = (_bal(a, quote), _bal(a, base));
        vm.prank(a);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pos[0], TK, (lots - fill + 1) * LOT, 0)));
        uint256 potByModify = _pot(quote) - pot0;
        pot0 = _pot(quote);
        (uint256 qb, uint256 bb) = (_bal(b, quote), _bal(b, base));
        vm.prank(b);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos[1], 0)));
        assertEq(_pot(quote) - pot0, potByModify, "the pot: the same rest");
        assertEq(potByModify, _potPart(_fee(fill, TK), share), "the pot: fee - floor(fee x share)");
        // the one lot more the modify escrows: an ask's base, a bid's quote (one lot at TK, exact)
        if (isBid) {
            assertEq(int256(_bal(a, quote)) - int256(qa) + int256(_lq(TK)), int256(_bal(b, quote) - qb));
            assertEq(_bal(a, base) - ba, _bal(b, base) - bb, "the bid's proceeds");
        } else {
            assertEq(_bal(a, quote) - qa, _bal(b, quote) - qb, "the ask's proceeds and fee part");
            assertEq(ba - _bal(a, base), 1e6, "the lot added");
        }
    }

    /// An order's fills are paid at its version's share when it settles, whatever the market's share is by then: a
    /// share change after the fills reprices none of them. A place on a never-written position proves the listing from
    /// the market's registry word.
    function test_share_is_the_version_s_at_the_settle() public {
        book.warmPool(m, 600, 1);
        address a = _maker();
        vm.startPrank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, TK, 5 * LOT, 600, 0)); // a pre-warmed position
        book.place(OloOps.key(c), OloOps.placeW(false, TK, 5 * LOT, 650, 0)); // a never-written one
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.place(OloOps.key(_wrongC()), OloOps.placeW(false, TK, 5 * LOT, 700, 0)); // a word that is no market's
        vm.stopPrank();
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(bytes.concat(OloOps.poolEntry(600, TK), OloOps.poolEntry(650, TK))),
            OloOps.tagW(c, OloOps.takeW(true, 10 * LOT, 0))
        );
        assertEq(_pot(quote), 0, "the take holds the fee");
        MarketWord v1 = c;
        _setMarketShare(8_000);
        (uint16 share, bool listed, bool active) = book.makerShareOf(c);
        assertEq(share, 8_000);
        assertTrue(listed && active);
        (share, listed, active) = book.makerShareOf(OloOps.key(c));
        assertEq(share, 8_000, "a key names the current version");
        assertTrue(listed && active);
        (share, listed, active) = book.makerShareOf(v1);
        assertEq(share, 0, "an older version's share is not read back (it is in its C)");
        assertTrue(listed);
        assertFalse(active, "it rests no new order");
        (, listed,) = book.makerShareOf(_wrongC());
        assertFalse(listed);
        // each fill's fee floor(5 x 1_000_010 x 50 ppm) = 250, all of it to the maker at the first version's 100%
        uint256 qa = _bal(a, quote);
        vm.startPrank(a);
        book.claim(OloOps.key(v1), OloOps.tagW(v1, OloOps.posW(600, 0)));
        book.cancel(OloOps.key(v1), OloOps.tagW(v1, OloOps.posW(650, 0)));
        vm.stopPrank();
        assertEq(_bal(a, quote), qa + 2 * (5 * 1_000_010 + 250));
        assertEq(_pot(quote), 0);
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 0, "no base left");
        assertEq(quoteLeft, 1, "quote: the take's fee ceil(500.005) = 501 less its two orders' floors, 250 each");
    }

    /// A place or a post names its market by its key, K: the id and the key bits (the tokens, the spacing, minQuote)
    /// must be the registry's C's, and the tag bits must be zero (a word with any of them set is UnknownMarket: K and
    /// nothing else; the order rests in the current version). A word whose key bits name no listed market (no id, an id
    /// not listed, the largest, another market's id with this market's key bits, this id with another market's) is
    /// UnknownMarket, so a place or post on a never-written position or slot refuses it and the share view reads it
    /// unlisted. A share of zero, set or by default, keeps the market listed: it still proves its listing, and its
    /// listing parameters still list once.
    function test_a_key_names_its_market_by_its_id() public {
        // another market of the pair, another minQuote: its key differs from the fixture's in minQuote and the id
        uint32 m2 = book.listMarketQuote(address(base), address(quote), 60, 6, 2, 0);
        uint256 params = MarketWord.unwrap(c) & ((1 << 224) - 1);
        uint256[6] memory forged = [
            params,
            params | (uint256(m2) << 224),
            params | (uint256(m2 + 1) << 224),
            params | (uint256(type(uint32).max) << 224),
            (MarketWord.unwrap(book.configOf(m2)) & ((1 << 224) - 1)) | (uint256(m) << 224), // m2's under m's id
            MarketWord.unwrap(c) ^ 1 // a base id never listed, under m's id
        ];
        address a = _maker();
        vm.startPrank(a);
        for (uint256 i; i < forged.length; ++i) {
            MarketWord f = MarketWord.wrap(forged[i]);
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            book.place(OloOps.key(f), OloOps.placeW(false, TK, 5 * LOT, 700, 0));
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            _mb(f, OloOps.ladderW(OloOps.POST, false, 50, 0, TK, 5 * LOT, 2, 1));
            (uint16 share, bool listed,) = book.makerShareOf(f);
            assertEq(share, 0);
            assertFalse(listed);
        }
        // a place takes K and nothing else: the key with any tag bit set is UnknownMarket
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.place(
            MarketWord.wrap(MarketWord.unwrap(OloOps.key(c)) | (uint256(0x2_0001_0000) << 174)),
            OloOps.placeW(false, TK, 5 * LOT, 701, 0)
        );
        vm.stopPrank();
        _setMarketShare(0);
        book.setGlobalMakerShare(0);
        MarketWord c3 = book.configOf(book.listMarketQuote(address(base), address(quote), 70, 6, 1, 0));
        vm.expectRevert(IOloBookBase.MarketExists.selector);
        book.listMarketQuote(address(base), address(quote), 50, 6, 1, 0);
        vm.expectRevert(IOloBookBase.MarketExists.selector);
        book.listMarketQuote(address(base), address(quote), 70, 6, 1, 0);
        vm.startPrank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, TK, 5 * LOT, 700, 0));
        book.place(OloOps.key(c3), OloOps.placeW(false, TK, 5 * LOT, 700, 0));
        _mb(c, OloOps.ladderW(OloOps.POST, false, 50, 0, TK, 5 * LOT, 2, 1));
        _mb(c3, OloOps.ladderW(OloOps.POST, false, 50, 0, TK, 5 * LOT, 2, 1));
        vm.stopPrank();
        (uint16 s1, bool l1,) = book.makerShareOf(c);
        (uint16 s3, bool l3,) = book.makerShareOf(c3);
        assertEq(s1, 0);
        assertEq(s3, 0);
        assertTrue(l1 && l3);
        // the four orders placed above still rest (5 + 5 lots placed, 2 x 5 posted twice): their base stays in the
        // OLO EVM contract; nothing was taken, so no quote
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 30 * LOT, "the resting orders' base");
        assertEq(quoteLeft, 0, "no quote");
    }

    /// A share is at most the whole fee, 10,000 bps, for a market, a pair and the global one. Above it a settle would
    /// owe the maker more than its fills' fee: at 15,000 a modify would pay the maker 1.5 times the fee, half of it out
    /// of other balances, and a claim or a cancel would revert on the pot's part.
    function test_share_at_most_the_whole_fee() public {
        vm.expectRevert(IOloBookBase.MakerShareTooHigh.selector);
        book.setMarketMakerShare(m, 10_001);
        vm.expectRevert(IOloBookBase.MakerShareTooHigh.selector);
        book.setGlobalMakerShare(10_001);
        vm.expectRevert(IOloBookBase.MakerShareTooHigh.selector);
        book.setPairMakerShare(address(base), address(quote), 10_001, true);
        vm.expectRevert(IOloBookBase.MakerShareTooHigh.selector);
        book.setMarketMakerShare(m, type(uint48).max);
        vm.expectRevert(IOloBookBase.MakerShareTooHigh.selector);
        book.setGlobalMakerShare(type(uint24).max);
        vm.expectRevert(IOloBookBase.MakerShareTooHigh.selector);
        book.setPairMakerShare(address(base), address(quote), type(uint40).max, true);
        _setMarketShare(0);
        book.setMarketMakerShare(m, 10_000);
        book.setGlobalMakerShare(10_000);
        book.setPairMakerShare(address(base), address(quote), 10_000, true);
        (uint16 share,,) = book.makerShareOf(OloOps.key(c));
        assertEq(share, 10_000);
        (,,, uint16 pairBps, uint16 globalBps, bool shareSet) = book.pairDefaultsOf(address(base), address(quote));
        assertEq(pairBps, 10_000);
        assertEq(globalBps, 10_000);
        assertTrue(shareSet);
    }

    /// Fills taken before a share change are paid at their version's share, either way: a cut does not take the
    /// maker's part of a fill already made, and a raise does not give it more of one. The contract held their whole
    /// fee, so neither owes more than the takers paid.
    function test_change_between_the_fill_and_the_settle() public {
        _setMarketShare(5_000);
        MarketWord v2 = c;
        address a = _plain(TK, false, 40 * LOT);
        address b = _plain(TK, false, 40 * LOT);
        _takeAt(posOf[a], TK, 40);
        _takeAt(posOf[b], TK, 40);
        uint256 fee = _fee(40, TK); // floor(40 x 1_000_010 x 50 ppm) = 2_000
        // a cut to 20% before a settles: a's fills keep 50%
        _setMarketShare(2_000);
        uint256 qa = _bal(a, quote);
        vm.prank(a);
        book.claim(OloOps.key(v2), OloOps.tagW(v2, OloOps.posW(posOf[a], 0)));
        assertEq(_bal(a, quote) - qa, 40 * 1_000_010 + fee * 5_000 / 10_000);
        assertEq(_pot(quote), _potPart(fee, 5_000));
        // a raise to 90% before b settles: b's fills keep 50%
        _setMarketShare(9_000);
        uint256 qb = _bal(b, quote);
        vm.prank(b);
        book.cancel(OloOps.key(v2), OloOps.tagW(v2, OloOps.posW(posOf[b], 0)));
        assertEq(_bal(b, quote) - qb, 40 * 1_000_010 + fee * 5_000 / 10_000);
        assertEq(_pot(quote), 2 * _potPart(fee, 5_000));
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 0, "no base left");
        assertEq(quoteLeft, 2, "two takes' fees, ceil(2,000.02) = 2,001, past their settles' floors, 2,000");
    }

    /// After a cut from 100% to 50% the requote paths split by the version they name: a place (a new position or a dead
    /// one), a multicall cancel (the old version's C) and place (the market's key: the current version) and a batch
    /// post rest in the new version and settle their fills at 50%; a modify, a batch replace or modify of an order in
    /// the old version reverts MarketFrozen, and its cancel pays the old version's 100%.
    function test_requote_paths_split_by_version() public {
        address a = _plain(TK, false, 10 * LOT); // to modify
        address b = _plain(TK, false, 10 * LOT); // to cancel and place in one multicall
        address d = _plain(TK, false, 10 * LOT); // to leave a dead position
        vm.prank(d);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[d], 0)));
        address z = _maker(); // a batch slot to replace
        address y = _maker(); // a batch sub-order to modify
        uint256[4] memory o;
        o[0] = OloOps.sub(TK, 10 * LOT);
        vm.prank(z);
        _mb(c, OloOps.batchW(OloOps.POST, false, 3, 0, 0, o));
        vm.prank(y);
        _mb(c, OloOps.batchW(OloOps.POST, false, 4, 0, 0, o));

        MarketWord v1 = c;
        _setMarketShare(5_000);
        uint256 t2 = TK + 1;
        // the old version's orders rest nothing again
        vm.prank(a);
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.modify(OloOps.key(v1), OloOps.tagW(v1, OloOps.modifyW(posOf[a], t2, 10 * LOT, 0)));
        o[0] = OloOps.sub(t2, 10 * LOT);
        vm.prank(z);
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        _mb(v1, OloOps.batchW(OloOps.REPLACE, false, 3, 0, 0, o));
        vm.prank(y);
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        _mb(v1, OloOps.batchW(OloOps.MODIFY, false, 4, 0, 0x1, o));
        // the maker's way: cancel there (nothing filled: no fee), rest again by the key
        vm.startPrank(a);
        book.cancel(OloOps.key(v1), OloOps.tagW(v1, OloOps.posW(posOf[a], 0)));
        book.place(OloOps.key(c), OloOps.placeW(false, t2, 10 * LOT, posOf[a], 0));
        vm.stopPrank();
        vm.prank(b);
        book.multicall(
            0,
            bytes.concat(
                abi.encodePacked(uint8(2), MarketWord.unwrap(v1), MarketWord.unwrap(OloOps.key(c))),
                OloOps.cancel(0, posOf[b]),
                OloOps.place(1, t2, false, 10 * LOT, posOf[b])
            )
        );
        vm.prank(d);
        book.place(OloOps.key(c), OloOps.placeW(false, t2, 10 * LOT, posOf[d], 0));
        vm.startPrank(z);
        _mb(v1, OloOps.maskW(OloOps.CANCEL, 3, 0, 0x1));
        _mb(c, OloOps.batchW(OloOps.POST, false, 3, 0, 0, o));
        vm.stopPrank();
        vm.startPrank(y);
        _mb(v1, OloOps.maskW(OloOps.CANCEL, 4, 0, 0x1));
        _mb(c, OloOps.batchW(OloOps.POST, false, 4, 0, 0, o));
        vm.stopPrank();

        uint256 fee = _fee(10, t2);
        address[3] memory pool = [a, b, d];
        for (uint256 i; i < 3; ++i) {
            address who = pool[i];
            _takeAt(posOf[who], t2, 10);
            uint256 pot0 = _pot(quote);
            vm.prank(who);
            book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[who], 0)));
            assertEq(_pot(quote) - pot0, _potPart(fee, 5_000), "a pool path");
        }
        address[2] memory makers = [z, y];
        uint16[2] memory slots = [uint16(3), uint16(4)];
        for (uint256 i; i < 2; ++i) {
            vm.prank(taker);
            book.take(
                OloOps.key(c),
                OloOps.batchList(OloOps.slotGroupAt(makers[i], slots[i], 0x1, t2)),
                OloOps.tagW(c, OloOps.takeW(true, 10 * LOT, 0))
            );
            uint256 pot0 = _pot(quote);
            vm.prank(makers[i]);
            _mb(c, OloOps.maskW(OloOps.CLAIM, slots[i], 0, 0));
            assertEq(_pot(quote) - pot0, _potPart(fee, 5_000), "a batch path");
        }
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 0, "no base left");
        assertEq(quoteLeft, 5, "five takes' fees each rounded up a wei past its settle's floor");
    }

    /// Property: an order filled before a share change settles at its version's share s0, and every path that rests an
    /// order after it rests in the new version and settles its next fill at s1: a place on a never-written, pre-warmed
    /// or dead position, a modify, a cancel and place in one multicall, a takeThenRest's rest, a batch sub-order
    /// posted, replaced or modified. A path on the old version's order that would rest it again (a modify, a batch
    /// replace or modify) reverts MarketFrozen when the share moved, and the maker cancels and rests by the key.
    /// Exactly: the pot gets fee - floor(fee x share), the maker its proceeds and floor(fee x share).
    function testFuzz_every_path_settles_at_its_version_s_share(uint8 path, uint16 s0, uint16 s1, uint48 lots) public {
        path = uint8(bound(path, 0, 8));
        s0 = uint16(bound(s0, 0, 10_000));
        s1 = uint16(bound(s1, 0, 10_000));
        lots = uint48(bound(lots, 1, 1e6));
        _setMarketShare(s0);
        MarketWord v0 = c;
        address a = _maker();
        uint32 pos = _pos();
        uint256 t2 = TK + 2;
        bool isBatch = path >= 6;
        uint256[4] memory data;
        data[0] = OloOps.sub(t2, lots * LOT);
        uint256[4] memory old;
        old[0] = OloOps.sub(TK, lots * LOT);
        // what exists before the share changes; an old order is filled by a lot, to settle at s0
        if (path == 1) book.warmPool(m, pos, 1);
        if (path == 2 || path == 3 || path == 4) {
            vm.prank(a);
            book.place(OloOps.key(c), OloOps.placeW(false, TK, lots * LOT, pos, 0));
            _takeAt(pos, TK, 1);
        }
        if (path == 2) {
            vm.prank(a);
            book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        }
        if (path == 7 || path == 8) {
            vm.prank(a);
            _mb(c, OloOps.batchW(OloOps.POST, false, 9, 0, 0, old));
            vm.prank(taker);
            book.take(
                OloOps.key(c),
                OloOps.batchList(OloOps.slotGroupAt(a, 9, 0x1, TK)),
                OloOps.tagW(c, OloOps.takeW(true, LOT, 0))
            );
        }
        _setMarketShare(s1);
        bool moved = s1 != s0;
        // the path itself: an order at t2, in the current version
        uint256 pot0 = _pot(quote);
        vm.startPrank(a);
        if (path <= 2) {
            book.place(OloOps.key(c), OloOps.placeW(false, t2, lots * LOT, pos, 0));
        } else if (path == 3) {
            if (moved) {
                vm.expectRevert(IOloBookBase.MarketFrozen.selector);
                book.modify(OloOps.key(v0), OloOps.tagW(v0, OloOps.modifyW(pos, t2, lots * LOT, 0)));
                book.cancel(OloOps.key(v0), OloOps.tagW(v0, OloOps.posW(pos, 0)));
                book.place(OloOps.key(c), OloOps.placeW(false, t2, lots * LOT, pos, 0));
            } else {
                book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pos, t2, lots * LOT, 0)));
            }
        } else if (path == 4) {
            book.multicall(
                0,
                bytes.concat(
                    abi.encodePacked(uint8(2), MarketWord.unwrap(v0), MarketWord.unwrap(OloOps.key(c))),
                    OloOps.cancel(0, pos),
                    OloOps.place(1, t2, false, lots * LOT, pos)
                )
            );
        } else if (path == 5) {
            book.takeThenRest(OloOps.key(c), "", OloOps.tagW(c, OloOps.restW(false, lots * LOT, t2, 0, pos)));
        } else if (path == 6) {
            _mb(c, OloOps.batchW(OloOps.POST, false, 9, 0, 0, data));
        } else {
            uint256[3] memory w = path == 7
                ? OloOps.batchW(OloOps.REPLACE, false, 9, 0, 0, data)
                : OloOps.batchW(OloOps.MODIFY, false, 9, 0, 0x1, data);
            if (moved) {
                vm.expectRevert(IOloBookBase.MarketFrozen.selector);
                _mb(v0, w);
                _mb(v0, OloOps.maskW(OloOps.CANCEL, 9, 0, 0x1));
                _mb(c, OloOps.batchW(OloOps.POST, false, 9, 0, 0, data));
            } else {
                _mb(c, w);
            }
        }
        vm.stopPrank();
        // the old order's lot settled at s0 (paths 3, 4, 7, 8 settle it here)
        if (path == 3 || path == 4 || path == 7 || path == 8) {
            assertEq(_pot(quote) - pot0, _potPart(_fee(1, TK), s0), "the old order's fill at its version's share");
        }
        // the new order's fill, then its settle
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            isBatch ? OloOps.batchList(OloOps.slotGroupAt(a, 9, 0x1, t2)) : OloOps.poolList(OloOps.poolEntry(pos, t2)),
            OloOps.tagW(c, OloOps.takeW(true, lots * LOT, 0))
        );
        pot0 = _pot(quote);
        uint256 qa = _bal(a, quote);
        vm.prank(a);
        if (isBatch) _mb(c, OloOps.maskW(OloOps.CLAIM, 9, 0, 0));
        else book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        uint256 fee = _fee(lots, t2);
        assertEq(_pot(quote) - pot0, _potPart(fee, s1), "the pot: fee - floor(fee x the version's share)");
        assertEq(_bal(a, quote) - qa, uint256(lots) * _lq(t2) + fee * s1 / 10_000, "the maker");
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 0);
        // a wei of rounding a take: the paths with an older order take twice
        bool oldOrder = path == 2 || path == 3 || path == 4 || path == 7 || path == 8;
        assertLe(quoteLeft, oldOrder ? 2 : 1, "at most the takes' rounding");
    }

    /// A fill's fee too large for an owner's account still settles: at the top tick (P =
    /// 999,999e30 quote wei per base wei), 1e14 base wei and a 50% fee one fill's fee is about 5 x 10^49, past 2^128 -
    /// 1. At a share of 0 the pot takes it whole, so the maker settles through the wallet (the proceeds pass an account
    /// too), and `collectFees` pays it out.
    function test_pot_holds_a_fee_past_an_account() public {
        MockERC20 big = new MockERC20("Big", "BIG", 18);
        uint256 top = PriceGrid.MAX_TICK;
        uint32 mBig = book.listMarketQuote(address(base), address(big), 500_000, 6, 1, 0);
        book.setMarketMakerShare(mBig, 0);
        MarketWord cBig = book.configOf(mBig); // the version at a share of 0
        big.mint(taker, 1e51);
        vm.prank(taker);
        big.approve(address(book), type(uint256).max);
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(cBig), OloOps.placeW(false, top, 1e14, 7, 0));
        vm.prank(taker);
        (uint256 filled, uint256 paid) = book.take(
            OloOps.key(cBig),
            OloOps.poolList(OloOps.poolEntry(7, top)),
            OloOps.tagW(cBig, OloOps.takeW(true, 1e14, 0x01))
        );
        uint256 quote = 1e14 * 999_999e30;
        uint256 fee = quote / 2;
        assertEq(filled, 1e14);
        assertEq(paid, quote + fee);
        assertGt(fee, type(uint128).max, "the fee alone is past an account");
        // the account would pass 2^128 - 1 with the proceeds: through the wallet
        vm.prank(a);
        vm.expectRevert(IOloBookBase.AmountOverflow.selector);
        book.claim(OloOps.key(cBig), OloOps.tagW(cBig, OloOps.posW(7, 0)));
        uint256 wallet = big.balanceOf(a);
        vm.prank(a);
        uint256 proceeds = book.claim(OloOps.key(cBig), OloOps.tagW(cBig, OloOps.posW(7, 0x02)));
        assertEq(proceeds, quote);
        assertEq(big.balanceOf(a), wallet + quote, "the proceeds to the wallet; the maker's part of the fee is 0");
        uint256 bigId = book.tokenId(address(big));
        assertEq(book.balanceOf(bigId, address(0)), fee, "the pot holds the whole fee");
        uint256 recipient = big.balanceOf(address(this));
        assertEq(book.collectFees(address(big)), fee);
        assertEq(big.balanceOf(address(this)), recipient + fee);
        assertEq(book.balanceOf(bigId, address(0)), 0);
        // the same fee again, into the emptied pot, and a cancel with fills settles too
        vm.prank(a);
        book.place(OloOps.key(cBig), OloOps.placeW(false, top, 1e14, 8, 0));
        vm.prank(taker);
        book.take(
            OloOps.key(cBig),
            OloOps.poolList(OloOps.poolEntry(8, top)),
            OloOps.tagW(cBig, OloOps.takeW(true, 1e14, 0x01))
        );
        vm.prank(a);
        book.cancel(OloOps.key(cBig), OloOps.tagW(cBig, OloOps.posW(8, 0x02)));
        assertEq(book.balanceOf(bigId, address(0)), fee);
    }
}
