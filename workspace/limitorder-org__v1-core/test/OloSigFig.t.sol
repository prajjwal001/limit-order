// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {IOloBookExt} from "../src/interfaces/IOloBookExt.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

using MarketLib for MarketWord;

/// A market's significant figures: 6, 5, 4 or 3, a maker tick spacing of 1, 10, 100 or 1000 (PriceGrid.spacingOf) in C.
/// The listing (the figures, one market per set of parameters), every maker entry on the
/// spacing (place, modify, the multicall's ops, a batch post, replace and modify, a takeThenRest's rest), takers
/// unaffected (entry ticks and limits off the spacing), the four cases of a takeThenRest's limit, the money on spaced
/// markets across a decade boundary, the library's snap, and the entry's selector.
contract OloSigFigTest is OloBase {
    function setUp() public {
        _deploy();
    }

    /// The fixture at `sf` figures, its taker funded in both accounts.
    function _onFigures(uint8 sf) internal {
        _deployWith(sf);
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    function _list(uint8 sigFigs, uint24 fee) internal returns (uint32) {
        return book.listMarketQuote(address(base), address(quote), fee, sigFigs, 1, 0);
    }

    function _refused(uint8 sigFigs) internal {
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        _list(sigFigs, 50);
    }

    // --------------------------------------------------------------- listing

    /// 6 .. 3 list with their spacing at C's bits 64-73; 2, 7 and 0 do not; the figures are part of the parameters
    /// (another market), and the same figures twice is the same market.
    function test_listing_significant_figures() public {
        for (uint8 sf = 3; sf <= 5; ++sf) {
            uint32 id = _list(sf, 50);
            MarketWord cw = book.configOf(id);
            uint256 spacing = 10 ** uint256(6 - sf);
            assertEq(cw.spacing(), spacing, "spacing");
            assertEq((MarketWord.unwrap(cw) >> 64) & 0x3ff, spacing, "bits 64-73");
            assertEq(PriceGrid.spacingOf(sf), spacing);
            assertTrue(MarketWord.unwrap(cw) != MarketWord.unwrap(c), "another market than the fixture's at 6");
        }
        assertEq(c.spacing(), 1, "the fixture: every tick");
        vm.expectRevert(IOloBookBase.MarketExists.selector);
        _list(6, 50); // the fixture's parameters
        vm.expectRevert(IOloBookBase.MarketExists.selector);
        _list(4, 50); // listed above
        _refused(2);
        _refused(7);
        _refused(0);
    }

    // ---------------------------------------------------------------- makers

    /// On a market of `sf` figures (spacing `s`): a place, a modify, a multicall's PLACE and MODIFY off the spacing
    /// revert TickOutOfRange; on it they rest; a take fills them from entries off the spacing.
    function _makersOn(uint8 sf) internal {
        _onFigures(sf);
        uint256 s = _spacing();
        assertEq(s, 10 ** uint256(6 - sf));
        address a = _maker();
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.place(OloOps.key(c), OloOps.placeW(true, T - 1, 1 * LOT, 1, 0));
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.place(OloOps.key(c), OloOps.placeW(false, T + s + 1, 1 * LOT, 1, 0));
        book.place(OloOps.key(c), OloOps.placeW(true, T - s, 2 * LOT, 1, 0));
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(1, T - s - 1, 2 * LOT, 0)));
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(1, T - 2 * s, 3 * LOT, 0)));
        book.place(OloOps.key(c), OloOps.placeW(false, T, 2 * LOT, 2, 0));
        book.place(OloOps.key(c), OloOps.placeW(false, T + s, 2 * LOT, 3, 0));
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.multicall(0, _mc(OloOps.place(0, T + 1, false, 1 * LOT, 4)));
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.multicall(0, _mc(OloOps.modify(0, 2, T + 1, 2 * LOT)));
        book.multicall(
            0, _mc(bytes.concat(OloOps.place(0, T + 2 * s, false, 1 * LOT, 4), OloOps.modify(0, 2, T, 3 * LOT)))
        );
        vm.stopPrank();
        (uint256 tick, uint256 lots,,,) = book.orderOf(c, 4);
        assertEq(tick, T + 2 * s);
        assertEq(lots, 1 * LOT);
        (tick, lots,,,) = book.orderOf(c, 2);
        assertEq(lots, 3 * LOT, "modified in the multicall");
        // a take fills the spaced levels from entries off the spacing (the entry is the taker's own bound)
        vm.prank(taker);
        (uint256 f, uint256 q) = book.take(
            OloOps.key(c),
            OloOps.poolList(bytes.concat(OloOps.poolEntry(2, T + 1), OloOps.poolEntry(3, T + s + 1))),
            OloOps.tagW(c, OloOps.takeW(true, 4 * LOT, 0))
        );
        assertEq(f, 4 * LOT, "three at T, one at T + s");
        uint256 exact = 3 * _lq(T) + _lq(T + s);
        assertEq(q, exact + (exact * 50 + 999_999) / 1_000_000, "the quote and the fee, rounded up");
        vm.prank(taker);
        (f,) = book.take(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntry(1, T - 2 * s - 1)),
            OloOps.tagW(c, OloOps.takeW(false, 3 * LOT, 0))
        );
        assertEq(f, 3 * LOT, "the bid at T - 2 s");
        _solvent();
    }

    function test_makers_on_5_figures() public {
        _makersOn(5);
    }

    function test_makers_on_4_figures() public {
        _makersOn(4);
    }

    function test_makers_on_3_figures() public {
        _makersOn(3);
    }

    /// A batch post, replace and modify with an order off the spacing revert TickOutOfRange; on it they rest; a take
    /// fills the slot from entries and a limit off the spacing (no rest).
    function _batchesOn(uint8 sf) internal {
        _onFigures(sf);
        uint256 s = _spacing();
        address z = _maker();
        uint256[3] memory d = OloOps.ladderW(OloOps.POST, false, 0, 0, T + s, 4 * LOT, 2, s); // asks at T + s, T + 2 s
        uint256[3] memory off = OloOps.ladderW(OloOps.POST, false, 0, 0, T + s, 4 * LOT, 2, 1); // the second at T + s + 1
        uint256[3] memory offReplace = OloOps.ladderW(OloOps.REPLACE, false, 0, 0, T + s, 4 * LOT, 2, 1);
        uint256[4] memory o;
        vm.startPrank(z);
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        _mb(c, off);
        _mb(c, d);
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        _mb(c, offReplace); // a replace with an order off the spacing
        o[1] = OloOps.sub(T + 3 * s + 1, 4 * LOT);
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, 0, 0, 0x2, o)); // a modify off it
        o[1] = OloOps.sub(T + 3 * s, 4 * LOT);
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, 0, 0, 0x2, o)); // on it
        _mb(c, OloOps.ladderW(OloOps.REPLACE, true, 0, 0, T - s, 4 * LOT, 2, s)); // bids at T - s, T - 2 s
        vm.stopPrank();
        vm.prank(taker);
        (uint256 f,,,) = book.takeThenRest(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 0, 0x3, T - 2 * s - 1)),
            OloOps.tagW(c, OloOps.restW(false, 8 * LOT, T - 2 * s - 1, 0, 9))
        );
        assertEq(f, 8 * LOT, "both bids, from an entry and a limit off the spacing: nothing left to rest");
        _solvent();
    }

    function test_batches_on_5_figures() public {
        _batchesOn(5);
    }

    function test_batches_on_4_figures() public {
        _batchesOn(4);
    }

    function test_batches_on_3_figures() public {
        _batchesOn(3);
    }

    /// A takeThenRest's limit off the spacing: fine while nothing is left to rest (filled whole, or the rest below
    /// minQuote), TickOutOfRange with the fills undone when something is; on the spacing the rest rests.
    function test_take_then_rest_limit_on_the_spacing() public {
        _onFigures(5); // spacing 10
        address a = _maker();
        vm.startPrank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T, 2 * LOT, 1, 0));
        book.place(OloOps.key(c), OloOps.placeW(false, T, 1 * LOT, 2, 0));
        book.place(OloOps.key(c), OloOps.placeW(false, T, 1 * LOT, 3, 0));
        vm.stopPrank();
        vm.startPrank(taker);
        // filled whole at a limit off the spacing: no rest, no check
        (uint256 f,,,) = book.takeThenRest(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntry(1, T)),
            OloOps.tagW(c, OloOps.restW(true, 2 * LOT, T + 1, 0, 50))
        );
        assertEq(f, 2 * LOT);
        (uint256 tick,,,,) = book.orderOf(c, 50);
        assertEq(tick, 0, "nothing rested");
        // one left at a limit on the spacing: it rests there
        (f,,,) = book.takeThenRest(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntry(2, T)),
            OloOps.tagW(c, OloOps.restW(true, 2 * LOT, T + 10, 0, 51))
        );
        assertEq(f, 1 * LOT);
        uint256 lots;
        (tick, lots,,,) = book.orderOf(c, 51);
        assertEq(tick, T + 10);
        assertEq(lots, 1 * LOT, "the rest");
        // one left at a limit off the spacing: the whole call reverts, the fill with it
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.takeThenRest(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntry(3, T)),
            OloOps.tagW(c, OloOps.restW(true, 2 * LOT, T + 1, 0, 52))
        );
        (, lots,,,) = book.orderOf(c, 3);
        assertEq(lots, 1 * LOT, "the ask untouched");
        vm.stopPrank();
        // a market of minQuote 1.5 LOT's worth: an ask of 2 with 1 already taken leaves 1, so a buy of 2 fills 1 and
        // leaves 1 LOT, worth less than minQuote: at a limit off the spacing the limit is still checked first and the
        // call reverts; at one on the spacing nothing rests and the LOT stays with the taker
        MarketWord cm = book.configOf(book.listMarketQuote(address(base), address(quote), 50, 5, 1_500_000, 0));
        vm.prank(a);
        book.place(OloOps.key(cm), OloOps.placeW(false, T, 2 * LOT, 1, 0));
        vm.startPrank(taker);
        book.take(
            OloOps.key(cm), OloOps.poolList(OloOps.poolEntry(1, T)), OloOps.tagW(cm, OloOps.takeW(true, 1 * LOT, 0))
        );
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.takeThenRest(
            OloOps.key(cm),
            OloOps.poolList(OloOps.poolEntry(1, T)),
            OloOps.tagW(cm, OloOps.restW(true, 2 * LOT, T + 1, 0, 53))
        );
        (f,,,) = book.takeThenRest(
            OloOps.key(cm),
            OloOps.poolList(OloOps.poolEntry(1, T)),
            OloOps.tagW(cm, OloOps.restW(true, 2 * LOT, T + 10, 0, 53))
        );
        assertEq(f, 1 * LOT, "the LOT left");
        (tick,,,,) = book.orderOf(cm, 53);
        assertEq(tick, 0, "below minQuote: nothing rested");
        vm.stopPrank();
        _solvent();
    }

    // ------------------------------------------------------------------ money

    uint8[3] decs = [6, 8, 18];

    /// Spaced markets (6 / 5 / 4 / 3 figures) on 6 / 8 / 18-decimal tokens with a fee, three makers at boundary - s,
    /// boundary, boundary + s of a decade boundary (bids mirrored) for decades 31 to 50 (P from 1e-12 to 1e7), a take
    /// of a random size; the taker pays the exact value rounded up plus the fee on it rounded up (a buy) or receives
    /// it rounded down less the fee (a sell, or SellBelowFee when the fee would take it all); every maker settles
    /// and leaves, the OLO EVM contract stays solvent, base comes out to the wei, the pot only grows.
    function testFuzz_spaced_rounding_and_solvency(
        uint8 bdSel,
        uint8 qdSel,
        uint8 sfSel,
        uint8 decade,
        uint256 lots,
        uint256 want,
        bool buy,
        uint24 fee
    ) public {
        uint8 sf = 3 + sfSel % 4;
        uint256 s = PriceGrid.spacingOf(sf);
        uint256 boundary = (31 + decade % 20) * PriceGrid.PER_DECADE;
        MockERC20 b = new MockERC20("B", "B", decs[bdSel % 3]);
        MockERC20 q = new MockERC20("Q", "Q", decs[qdSel % 3]);
        fee = uint24(bound(fee, 0, 1_000_000));
        MarketWord cg = book.configOf(book.listMarketQuote(address(b), address(q), fee, sf, 0, 0));
        lots = bound(lots, 1, (1 << 30) - 1); // q 0: every fill exact to the wei
        address[3] memory mk;
        uint256[3] memory ts = buy ? [boundary - s, boundary, boundary + s] : [boundary, boundary - s, boundary - 2 * s];
        bytes memory entries;
        for (uint256 i; i < 3; ++i) {
            mk[i] = address(uint160(0xA000 + i));
            b.mint(mk[i], 1e36);
            q.mint(mk[i], 1e36);
            vm.startPrank(mk[i]);
            b.approve(address(book), type(uint256).max);
            q.approve(address(book), type(uint256).max);
            book.deposit(address(b), 1e36);
            book.deposit(address(q), 1e36);
            book.place(OloOps.key(cg), OloOps.placeW(!buy, ts[i], lots, uint32(i + 1), 0));
            vm.stopPrank();
            entries = bytes.concat(entries, OloOps.poolEntry(uint32(i + 1), ts[i]));
        }
        b.mint(taker, 1e36);
        q.mint(taker, 1e36);
        vm.startPrank(taker);
        b.approve(address(book), type(uint256).max);
        q.approve(address(book), type(uint256).max);
        book.deposit(address(b), 1e36);
        book.deposit(address(q), 1e36);
        vm.stopPrank();
        want = bound(want, 1, 3 * lots);
        // the exact value: sum of n x mantissa x 10^(d - 30) over 10^13 (every decade here is above 30)
        uint256 num;
        uint256 rest = want;
        for (uint256 i; i < 3 && rest != 0; ++i) {
            uint256 n = rest < lots ? rest : lots;
            (uint256 d, uint256 mant) = PriceGrid.split(ts[i]);
            num += n * mant * 10 ** (d - 30);
            rest -= n;
        }
        uint256 exact = buy ? (num + 1e13 - 1) / 1e13 : num / 1e13;
        uint256 feeUp = (num * fee + 1e19 - 1) / 1e19;
        uint256 qId = book.tokenId(address(q));
        uint256 pot0 = book.balanceOf(qId, address(0));
        vm.prank(taker);
        if (!buy && feeUp >= exact) vm.expectRevert(IOloBookBase.SellBelowFee.selector);
        (uint256 f, uint256 qa) =
            book.take(OloOps.key(cg), OloOps.poolList(entries), OloOps.tagW(cg, OloOps.takeW(buy, want, 0)));
        if (buy || feeUp < exact) {
            assertEq(f, want, "filled in full");
            assertEq(qa, buy ? exact + feeUp : exact - feeUp, "the exact value and the fee, each rounded once");
        }
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(mk[i]);
            book.cancel(OloOps.key(cg), OloOps.tagW(cg, OloOps.posW(uint32(i + 1), 0)));
            book.withdraw(address(b), book.balanceOf(book.tokenId(address(b)), mk[i]));
            book.withdraw(address(q), book.balanceOf(qId, mk[i]));
            vm.stopPrank();
        }
        vm.startPrank(taker);
        book.withdraw(address(b), book.balanceOf(book.tokenId(address(b)), taker));
        book.withdraw(address(q), book.balanceOf(qId, taker));
        vm.stopPrank();
        assertGe(book.balanceOf(qId, address(0)), pot0, "the fee pot only grows");
        assertGe(q.balanceOf(address(book)), book.balanceOf(qId, address(0)), "solvent: the pot is covered");
        assertEq(b.balanceOf(address(book)), 0, "base exact");
    }

    // ---------------------------------------------------------------- library

    function testFuzz_snap_and_aligned(uint256 t, uint8 sfSel) public pure {
        uint8 sf = 3 + sfSel % 4;
        uint256 sp = PriceGrid.spacingOf(sf);
        t = bound(t, 0, PriceGrid.MAX_TICK - 1000);
        uint256 dn = PriceGrid.snap(t, sp, false);
        uint256 up = PriceGrid.snap(t, sp, true);
        assertTrue(PriceGrid.aligned(dn, sp) && PriceGrid.aligned(up, sp));
        assertLe(dn, t);
        assertGe(up, t);
        assertLt(t - dn, sp);
        assertLt(up - t, sp);
        if (PriceGrid.aligned(t, sp)) assertTrue(dn == t && up == t);
        // a spacing never splits a decade: aligned ticks keep their alignment across a boundary
        assertTrue(PriceGrid.aligned(PriceGrid.PER_DECADE, sp));
    }

    /// The listing's selector sorts after every other entry of the contract (the dispatcher compares selectors in
    /// order; a cold entry sorting early costs every hot entry after it).
    function test_listMarketQuote_selector_sorts_last() public pure {
        assertEq(IOloBookExt.listMarketQuote.selector, bytes4(0xfb2f1996));
        assertGt(
            uint32(IOloBookExt.listMarketQuote.selector), uint32(0xf5c030c2), "past listingFeeCurrent, the last before"
        );
    }
}
