// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {BatchView} from "./BatchView.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {BatchLib} from "../src/OloTypes.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";

/// A batch slot holding both sides: sub-order i rests on its side D_i (bit 246 + i, 1 a bid), set from the params'
/// side s_i (bit 136 + i) by a post, a replace and a modify for each order it rests. A take skips a named sub-order on
/// its own side, as a pool word on it; a settle pays each sub-order on its own side.
///
/// The example, on the fixture market at a maker share of 70%: one slot holds a bid of 5,000,001 at T - 2 (P =
/// 0.999998; s_0 set) and asks of 3, 4 and 2 LOT at T + 1, T + 2, T + 3 (P = 1.00001, 1.00002, 1.00003). It
/// escrows 9,000,000 base and ceil(5,000,001 x 0.999998) = ceil(4,999,990.999998) = 4,999,991 quote. A buy naming all
/// four fills the asks only: 9,000,000 base for 3,000,030 + 4,000,080 + 2,000,060 = 9,000,170 quote and a fee of
/// ceil(450.0085) = 451. A sell naming all four fills the bid only: 5,000,001 base for floor(4,999,990.999998) =
/// 4,999,990 quote less a fee of ceil(249.99954999990) = 250. The claim pays the asks' 9,000,170 quote, the bid's
/// 5,000,001 base, and of the fee floored per sub-order, 150 + 200 + 100 + 249 = 699, the maker's 70% floored, 489, and
/// the pot 210.
contract OloBatchMixedTest is OloBase {
    uint256 constant BID = 5_000_001;
    uint16 constant SLOT = 3;
    uint256 constant USED = 2;
    uint256 constant SET_USED = 1 << 255;

    address mk;

    function setUp() public {
        _deploy();
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
        _setMarketShare(7_000);
        mk = _maker();
    }

    // ------------------------------------------------------------------ helpers

    /// A sub-order's 61 bits: tick 0-25 | q 26-30 | open 31-60.
    function _bits(uint256 tick, uint256 q, uint256 units) internal pure returns (uint256) {
        return tick | (q << 26) | (units << 31);
    }

    /// The example's four orders: a bid at T - 2, asks at T + 1, T + 2 and T + 3.
    function _orders() internal pure returns (uint256[4] memory) {
        uint256 bid = OloOps.sub(T - 2, BID);
        return [bid, OloOps.sub(T + 1, 3 * LOT), OloOps.sub(T + 2, 4 * LOT), OloOps.sub(T + 3, 2 * LOT)];
    }

    /// The example's main word as posted, D_0 set (sub-order 0 a bid), and its settlement word.
    function _postedWords() internal pure returns (uint256 word, uint256 set) {
        word = USED | (uint256(1) << 246) | (_bits(T - 2, 0, BID) << 2) | (_bits(T + 1, 0, 3 * LOT) << 63)
            | (_bits(T + 2, 0, 4 * LOT) << 124) | (_bits(T + 3, 0, 2 * LOT) << 185);
        set = SET_USED | BID | (3 * LOT << 30) | (4 * LOT << 60) | (2 * LOT << 90);
    }

    function _packed(uint256 kind, uint256 acted, uint16 slot) internal view returns (uint256) {
        return kind | (acted << 8) | (uint256(slot) << 128) | ((MarketWord.unwrap(c) >> 208) << 144);
    }

    function _post() internal {
        vm.prank(mk);
        _mb(c, OloOps.withSides(OloOps.batchW(OloOps.POST, false, SLOT, 0, 0, _orders()), 0x1));
    }

    function _take(bool buy, uint256 amount, uint8 mask, uint256 bound) internal returns (uint256 got, uint256 paid) {
        vm.prank(taker);
        (got, paid) = book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(mk, SLOT, mask, bound)),
            OloOps.tagW(c, OloOps.takeW(buy, amount, 0))
        );
    }

    /// A batch fill record at q 0: index 1 | q 1 | units 4.
    function _rec(uint256 i, uint256 units) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(i), uint8(0), uint32(units));
    }

    /// The one Take event's fills.
    function _takeFills() internal view returns (bytes memory fills) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IOloBookBase.Take.selector) continue;
            ++seen;
            (,,,, fills) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bytes));
        }
        assertEq(seen, 1, "one Take");
    }

    // ------------------------------------------------------------------ directed

    /// The post escrows both tokens, each sub-order on its own side, and writes the words with D_0 set; BatchUpdated
    /// carries them. The pattern has one encoding: the helper's other spelling of it (every order a bid, 1-3 turned)
    /// sends the same params, so it escrows the same and writes the same words (under the earlier encoding the two
    /// spellings were two encodings, S a bid with F 1110 and S an ask with F 0001).
    function test_post_one_bid_three_asks() public {
        (uint256 word, uint256 set) = _postedWords();
        uint256 b0 = _bal(mk, base);
        uint256 q0 = _bal(mk, quote);
        vm.expectEmit(true, false, false, true, address(book));
        emit IOloBookBase.BatchUpdated(mk, _packed(OloOps.POST, 0xf, SLOT), word, set);
        _post();
        assertEq(b0 - _bal(mk, base), 9_000_000, "the asks' base: 3 + 4 + 2 LOT");
        assertEq(q0 - _bal(mk, quote), 4_999_991, "the bid's quote: ceil(5,000,001 x 0.999998)");
        (uint256 w, uint256 s) = _slotWords(c, mk, SLOT);
        assertEq(w, word, "the main word: D_0 set");
        assertEq(s, set, "the settlement word");
        assertEq(w >> 246, 1, "the sides: sub-order 0 a bid");
        assertEq(BatchLib.bidMask(w), 1, "sub-order 0 a bid, 1-3 asks");
        // the helper's other spelling: every order a bid, then 1-3 turned to asks
        address m2 = _maker();
        b0 = _bal(m2, base);
        q0 = _bal(m2, quote);
        vm.prank(m2);
        _mb(c, OloOps.withFlips(OloOps.batchW(OloOps.POST, true, SLOT, 0, 0, _orders()), 0xe));
        assertEq(b0 - _bal(m2, base), 9_000_000, "the same base");
        assertEq(q0 - _bal(m2, quote), 4_999_991, "the same quote");
        (uint256 w2,) = _slotWords(c, m2, SLOT);
        assertEq(w2, word, "the same words: one encoding of the sides");
        assertEq(BatchLib.bidMask(w2), 1, "the same sides");
    }

    /// A buy naming all four sub-orders at a bound every one passes fills the three asks only, at their own ticks,
    /// and skips the bid (on the taker's own side); the main word is written, the settlement word is not.
    function test_buy_naming_all_four_fills_only_the_asks() public {
        _post();
        (uint256 word0, uint256 set0) = _slotWords(c, mk, SLOT);
        uint256 qt = _bal(taker, quote);
        uint256 bt = _bal(taker, base);
        vm.recordLogs();
        (uint256 got, uint256 paid) = _take(true, 20 * LOT, 0xf, T + 10);
        assertEq(got, 9_000_000, "the asks' base");
        assertEq(paid, 9_000_170 + 451, "3,000,030 + 4,000,080 + 2,000,060 and a fee of ceil(450.0085)");
        assertEq(qt - _bal(taker, quote), 9_000_621);
        assertEq(_bal(taker, base) - bt, 9_000_000);
        bytes memory recs =
            bytes.concat(abi.encodePacked(mk, SLOT, uint8(3)), _rec(1, 3 * LOT), _rec(2, 4 * LOT), _rec(3, 2 * LOT));
        assertEq(_takeFills(), bytes.concat(abi.encodePacked(uint8(1), uint24(recs.length)), recs), "the records");
        (uint256 word, uint256 set) = _slotWords(c, mk, SLOT);
        uint256 asksOpen = (uint256(3 * LOT) << 94) | (uint256(4 * LOT) << 155) | (uint256(2 * LOT) << 216);
        assertEq(word, word0 - asksOpen, "the asks' open units taken; the bid and the sides as they were");
        assertEq(set, set0, "the settlement word untouched");
    }

    /// A sell naming all four at a bound every one passes fills the bid only.
    function test_sell_naming_all_four_fills_only_the_bid() public {
        _post();
        (uint256 word0,) = _slotWords(c, mk, SLOT);
        vm.recordLogs();
        (uint256 got, uint256 paid) = _take(false, 10 * LOT, 0xf, 1);
        assertEq(got, BID, "the bid's base");
        assertEq(paid, 4_999_990 - 250, "floor(4,999,990.999998) less a fee of ceil(249.99954999990)");
        bytes memory recs = bytes.concat(abi.encodePacked(mk, SLOT, uint8(1)), _rec(0, BID));
        assertEq(_takeFills(), bytes.concat(abi.encodePacked(uint8(1), uint24(recs.length)), recs), "the records");
        (uint256 word,) = _slotWords(c, mk, SLOT);
        assertEq(word, word0 - (BID << 33), "the bid's open units taken");
    }

    /// The claim after both takes pays each sub-order on its own side: the asks' quote, the bid's base, the fee
    /// floored per sub-order and split once; every sub-order filled whole is emptied with its side, so the word is USED
    /// alone, and the settlement word, its bases left over, is not written.
    function test_claim_pays_both_sides() public {
        _post();
        _take(true, 20 * LOT, 0xf, T + 10);
        _take(false, 10 * LOT, 0xf, 1);
        (, uint256 set0) = _slotWords(c, mk, SLOT);
        uint256 b0 = _bal(mk, base);
        uint256 q0 = _bal(mk, quote);
        uint256 pot0 = _pot(quote);
        assertEq(
            PriceGrid.feeDown(3 * LOT, T + 1, 50) + PriceGrid.feeDown(4 * LOT, T + 2, 50)
                + PriceGrid.feeDown(2 * LOT, T + 3, 50) + PriceGrid.feeDown(BID, T - 2, 50),
            699,
            "150 + 200 + 100 + 249"
        );
        vm.expectEmit(true, false, false, true, address(book));
        emit IOloBookBase.BatchUpdated(mk, _packed(OloOps.CLAIM, 0xf, SLOT), USED, set0);
        vm.prank(mk);
        _mb(c, OloOps.maskW(OloOps.CLAIM, SLOT, 0, 0));
        assertEq(_bal(mk, base) - b0, BID, "the bid's fills in base");
        assertEq(_bal(mk, quote) - q0, 9_000_170 + 489, "the asks' fills in quote and 70% of 699, floored");
        assertEq(_pot(quote) - pot0, 210, "the pot the rest of the fee");
        (uint256 word, uint256 set) = _slotWords(c, mk, SLOT);
        assertEq(word, USED, "every sub-order emptied, its side with it");
        assertEq(set, set0, "the bases left over");
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 0, "no base left");
        // the takes' fee 451 + 250 against the settles' 699, and the bid's escrow, ceil(4,999,990.999998), against
        // the sell's quote, floor(4,999,990.999998): three wei of rounding kept
        assertEq(quoteLeft, 3, "three wei of rounding kept");
    }

    /// A claim of part-filled sub-orders on both sides: each rests on with its open units, its side kept, its base
    /// moved to them.
    function test_claim_part_filled_keeps_the_side() public {
        _post();
        _take(true, 2 * LOT, 0x2, T + 1); // 2 of sub-order 1's 3 LOT
        _take(false, 2 * LOT, 0x1, T - 2); // 2 LOT of the bid
        uint256 b0 = _bal(mk, base);
        uint256 q0 = _bal(mk, quote);
        vm.prank(mk);
        _mb(c, OloOps.maskW(OloOps.CLAIM, SLOT, 0, 0));
        // the bid's 2 LOT of base; the ask's 2,000,020 quote; fees floor(99.9998) = 99 and floor(100.001) = 100,
        // 70% of 199 = 139
        assertEq(_bal(mk, base) - b0, 2 * LOT);
        assertEq(_bal(mk, quote) - q0, 2_000_020 + 139);
        (uint256 word, uint256 set) = _slotWords(c, mk, SLOT);
        (uint256 posted,) = _postedWords();
        assertEq(word, posted - ((2 * LOT) << 33) - ((2 * LOT) << 94), "both rest on, D_0 kept");
        assertEq(BatchView.baseOf(set, 0), BID - 2 * LOT, "the bid's base: its open units");
        assertEq(BatchView.baseOf(set, 1), LOT, "the ask's base: its open units");
    }

    /// A modify adds a bid at an empty index of an ask slot (s_2 set), escrowing its quote; the same modify reprices
    /// the live ask at index 0 with s_0 = 0, its current side: it rests again an ask. A sell then fills the new bid
    /// only.
    function test_modify_adds_an_order_on_the_other_side() public {
        uint256[4] memory asks = [OloOps.sub(T + 1, 3 * LOT), OloOps.sub(T + 2, 4 * LOT), 0, 0];
        vm.prank(mk);
        _mb(c, OloOps.batchW(OloOps.POST, false, SLOT, 0, 0, asks));
        (uint256 word,) = _slotWords(c, mk, SLOT);
        assertEq(word >> 246, 0, "asks only: no side bit");
        assertEq(word, USED | (_bits(T + 1, 0, 3 * LOT) << 2) | (_bits(T + 2, 0, 4 * LOT) << 63), "the two asks");
        uint256[4] memory o;
        o[0] = OloOps.sub(T + 5, 3 * LOT); // the live ask repriced on its side (s_0 = 0)
        o[2] = OloOps.sub(T - 1, 3 * LOT); // a bid at the empty index 2
        uint256 b0 = _bal(mk, base);
        uint256 q0 = _bal(mk, quote);
        uint256 expected = USED | (uint256(1) << 248) | (_bits(T + 5, 0, 3 * LOT) << 2)
            | (_bits(T + 2, 0, 4 * LOT) << 63) | (_bits(T - 1, 0, 3 * LOT) << 124);
        uint256 expectedSet = SET_USED | (3 * LOT) | (4 * LOT << 30) | (3 * LOT << 60);
        vm.expectEmit(true, false, false, true, address(book));
        emit IOloBookBase.BatchUpdated(mk, _packed(OloOps.MODIFY, 0x5, SLOT), expected, expectedSet);
        vm.prank(mk);
        _mb(c, OloOps.withSides(OloOps.batchW(OloOps.MODIFY, false, SLOT, 0, 0x5, o), 0x4));
        assertEq(_bal(mk, base), b0, "the ask's 3 LOT refunded and escrowed again: no base moves");
        assertEq(q0 - _bal(mk, quote), 2_999_997, "the bid's quote: 3 LOT at 0.999999");
        (word,) = _slotWords(c, mk, SLOT);
        assertEq(word, expected, "D_2 set, sub-order 0 still an ask");
        assertEq(BatchLib.bidMask(word), 0x4, "sub-order 2 a bid");
        (uint256 got, uint256 paid) = _take(false, 10 * LOT, 0x7, 1);
        assertEq(got, 3 * LOT, "the sell fills the bid only");
        assertEq(paid, 2_999_997 - 150, "2,999,997 less a fee of ceil(149.99985)");
    }

    /// A replace changes the side pattern: bids at 0 and 2, an ask at 1, index 3 left empty. Every live sub-order is
    /// settled on its old side (the bid's quote refunded rounded down, the asks' base) and the orders rest on their new
    /// sides.
    function test_replace_changes_the_side_pattern() public {
        _post();
        uint256[4] memory o = [OloOps.sub(T - 1, 2 * LOT), OloOps.sub(T + 4, 6 * LOT), OloOps.sub(T - 3, LOT), 0];
        uint256 b0 = _bal(mk, base);
        uint256 q0 = _bal(mk, quote);
        uint256 expected = USED | (uint256(0x5) << 246) | (_bits(T - 1, 0, 2 * LOT) << 2)
            | (_bits(T + 4, 0, 6 * LOT) << 63) | (_bits(T - 3, 0, LOT) << 124);
        // the bases of 0-2 rewritten; index 3's, settled and not rested, left as it was
        uint256 expectedSet = SET_USED | (2 * LOT) | (6 * LOT << 30) | (LOT << 60) | (2 * LOT << 90);
        vm.expectEmit(true, false, false, true, address(book));
        emit IOloBookBase.BatchUpdated(mk, _packed(OloOps.REPLACE, 0x7, SLOT), expected, expectedSet);
        vm.prank(mk);
        _mb(c, OloOps.withSides(OloOps.batchW(OloOps.REPLACE, false, SLOT, 0, 0, o), 0x5));
        // base: 9 LOT refunded, 6 LOT escrowed; quote: floor(4,999,990.999998) = 4,999,990 refunded, 1,999,998 and
        // 999,997 escrowed
        assertEq(_bal(mk, base) - b0, 3 * LOT, "base: 9 LOT back, 6 LOT out");
        assertEq(_bal(mk, quote) - q0, 4_999_990 - 1_999_998 - 999_997, "quote: the bid's refund less two bids'");
        (uint256 word, uint256 set) = _slotWords(c, mk, SLOT);
        assertEq(word, expected, "D_0 and D_2 set, index 3 empty with no side");
        assertEq(set, expectedSet);
        assertEq(BatchLib.bidMask(word), 0x5, "0 and 2 bids, 1 an ask, 3 empty");
        (uint256 got,) = _take(true, 20 * LOT, 0xf, T + 10);
        assertEq(got, 6 * LOT, "a buy fills the ask only");
        (got,) = _take(false, 20 * LOT, 0xf, 1);
        assertEq(got, 3 * LOT, "a sell fills the two bids");
    }

    /// A modify's NoChange: the same tick, stored amount and side with no fills to pay. The bid (D_0 set) named with
    /// s_0 = 1 and the ask at index 3 with s_3 = 0, their current sides, are NoChange; with the other side each is
    /// turned, a changed order (`test_modify_turns_a_live_bid_to_an_ask`).
    function test_modify_same_order_same_side_is_no_change() public {
        _post();
        uint256[4] memory o;
        o[0] = OloOps.sub(T - 2, BID);
        vm.prank(mk);
        vm.expectRevert(IOloBookBase.NoChange.selector);
        _mb(c, OloOps.withSides(OloOps.batchW(OloOps.MODIFY, false, SLOT, 0, 0x1, o), 0x1));
        o[0] = 0;
        o[3] = OloOps.sub(T + 3, 2 * LOT);
        vm.prank(mk);
        vm.expectRevert(IOloBookBase.NoChange.selector);
        _mb(c, OloOps.withSides(OloOps.batchW(OloOps.MODIFY, false, SLOT, 0, 0x8, o), 0x1));
        (uint256 word,) = _slotWords(c, mk, SLOT);
        (uint256 posted,) = _postedWords();
        assertEq(word, posted, "untouched");
        // with the other side: turned, not NoChange
        vm.prank(mk);
        _mb(c, OloOps.withSides(OloOps.batchW(OloOps.MODIFY, false, SLOT, 0, 0x8, o), 0x9));
        (word,) = _slotWords(c, mk, SLOT);
        assertEq(word, posted | (uint256(1) << 249), "the ask at index 3 a bid now, D_3 set");
    }

    /// (d) An empty index's zero order is NoChange whatever its side (an empty sub-order's side is 0): the walk
    /// compares it with the empty sub-order's tick and amount, both zero, and NoChange outranks the tick's check.
    function test_modify_zero_order_at_an_empty_index_is_no_change_whatever_the_side() public {
        uint256[4] memory asks = [OloOps.sub(T + 1, 3 * LOT), OloOps.sub(T + 2, 4 * LOT), 0, 0];
        vm.prank(mk);
        _mb(c, OloOps.batchW(OloOps.POST, false, SLOT, 0, 0, asks));
        uint256[4] memory none;
        for (uint8 f; f < 16; ++f) {
            vm.prank(mk);
            vm.expectRevert(IOloBookBase.NoChange.selector);
            _mb(c, OloOps.withSides(OloOps.batchW(OloOps.MODIFY, false, SLOT, 0, 0x4, none), f));
        }
    }

    // ------------------------------------------------------------------ a modify turning a sub-order

    /// (a) A modify turns the live bid (D_0 set) to an ask at the same tick and amount (s_0 = 0): a changed order, not
    /// NoChange. With no fills: its quote refunded on the old side, floor(4,999,990.999998) = 4,999,990 (it escrowed
    /// ceil, 4,999,991: the wei of rounding stays, as a cancel and a new ask would leave it), and 5,000,001 base
    /// escrowed on the new side; the word's sub-order bits unchanged, D_0 cleared; its base the same units, so the
    /// settlement word is not written. A buy then fills it as an ask, a sell finds it on its own side.
    function test_modify_turns_a_live_bid_to_an_ask() public {
        _post();
        (uint256 posted, uint256 set0) = _postedWords();
        uint256[4] memory o;
        o[0] = OloOps.sub(T - 2, BID);
        uint256 b0 = _bal(mk, base);
        uint256 q0 = _bal(mk, quote);
        uint256 expected = posted & ~(uint256(1) << 246);
        vm.expectEmit(true, false, false, true, address(book));
        emit IOloBookBase.BatchUpdated(mk, _packed(OloOps.MODIFY, 0x1, SLOT), expected, set0);
        vm.prank(mk);
        _mb(c, OloOps.withSides(OloOps.batchW(OloOps.MODIFY, false, SLOT, 0, 0x1, o), 0));
        assertEq(_bal(mk, quote) - q0, 4_999_990, "the bid's open quote refunded, rounded down");
        assertEq(b0 - _bal(mk, base), BID, "the ask's base escrowed");
        (uint256 word, uint256 set) = _slotWords(c, mk, SLOT);
        assertEq(word, expected, "D_0 cleared, the sub-order's bits as they were");
        assertEq(set, set0);
        (uint256 got,) = _take(false, 10 * LOT, 0x1, 1);
        assertEq(got, 0, "a sell: an ask now, its own side");
        uint256 paid;
        (got, paid) = _take(true, 10 * LOT, 0x1, T - 2);
        assertEq(got, BID, "a buy fills it");
        assertEq(paid, 4_999_991 + 250, "ceil(4,999,990.999998) and a fee of ceil(249.99954999990)");
    }

    /// (a) The same turn with fills: a sell took 2,000,000 of the bid (1,999,996 quote, a fee of ceil(99.9998) = 100),
    /// then the bid is turned to an ask at its tick and open amount, 3,000,001. Its fills are paid on the old side:
    /// 2,000,000 base and of the fee floor(99.9998) = 99 the maker's 70%, floor(69.3) = 69, the pot 30; its open
    /// quote refunded, floor(3,000,001 x 0.999998) = floor(2,999,994.999998) = 2,999,994; 3,000,001 base escrowed on
    /// the new side. Not the kept path (a bid's fills paid and nothing escrowed): the side changed.
    function test_modify_turns_a_part_filled_bid_to_an_ask() public {
        _post();
        (uint256 posted,) = _postedWords();
        _take(false, 2 * LOT, 0x1, T - 2);
        uint256[4] memory o;
        o[0] = OloOps.sub(T - 2, BID - 2 * LOT);
        uint256 b0 = _bal(mk, base);
        uint256 q0 = _bal(mk, quote);
        uint256 pot0 = _pot(quote);
        vm.prank(mk);
        _mb(c, OloOps.withSides(OloOps.batchW(OloOps.MODIFY, false, SLOT, 0, 0x1, o), 0));
        assertEq(int256(_bal(mk, base)) - int256(b0), 2_000_000 - 3_000_001, "the fills' base in, the ask's out");
        assertEq(_bal(mk, quote) - q0, 2_999_994 + 69, "the open quote refunded and the fee's maker part");
        assertEq(_pot(quote) - pot0, 30, "the pot");
        (uint256 word, uint256 set) = _slotWords(c, mk, SLOT);
        assertEq(word, (posted - ((2 * LOT) << 33)) & ~(uint256(1) << 246), "3,000,001 open, an ask: D_0 cleared");
        assertEq(BatchView.baseOf(set, 0), BID - 2 * LOT, "its base its units");
    }

    /// (b) A turn that moves the tick and the amount too: a buy took 1 LOT of the ask at T + 1 (1,000,010 quote, a fee
    /// of ceil(50.0005) = 51), then index 1 rests as a bid of 4 LOT at T - 5 (s_1 = 1). Its fills paid on the old
    /// side, 1,000,010 quote and of the fee floor(50.0005) = 50 the maker's floor(35) = 35, the pot 15; its open 2 LOT
    /// refunded in base; 4 LOT at 0.999995 = 3,999,980 quote escrowed on the new side.
    function test_modify_turns_an_ask_to_a_bid_elsewhere() public {
        _post();
        (uint256 posted,) = _postedWords();
        _take(true, LOT, 0x2, T + 1);
        uint256[4] memory o;
        o[1] = OloOps.sub(T - 5, 4 * LOT);
        uint256 b0 = _bal(mk, base);
        uint256 q0 = _bal(mk, quote);
        uint256 pot0 = _pot(quote);
        vm.prank(mk);
        _mb(c, OloOps.withSides(OloOps.batchW(OloOps.MODIFY, false, SLOT, 0, 0x2, o), 0x2));
        assertEq(_bal(mk, base) - b0, 2 * LOT, "the ask's open base refunded");
        assertEq(
            int256(_bal(mk, quote)) - int256(q0),
            int256(1_000_010 + 35) - 3_999_980,
            "the fills' quote and the fee's maker part in, the bid's escrow out"
        );
        assertEq(_pot(quote) - pot0, 15, "the pot");
        (uint256 word, uint256 set) = _slotWords(c, mk, SLOT);
        uint256 sub1 = ((uint256(1) << 61) - 1) << 63;
        assertEq(word, (posted & ~sub1) | (_bits(T - 5, 0, 4 * LOT) << 63) | (uint256(1) << 247), "a bid at T - 5");
        assertEq(BatchView.baseOf(set, 1), 4 * LOT);
        assertEq(BatchLib.bidMask(word), 0x3, "0 and 1 bids, 2 and 3 asks");
    }

    /// (c) A modify naming a live sub-order with its current side is the one-sided modify, number for number: the mixed
    /// slot's bid (s_0 = 1, its side) and a bid slot's same bid (M2, every order a bid), each part-filled by the same
    /// sell and kept at its tick and open amount: the fills' 2,000,000 base, the fee's maker part 69 (the pot 30), and
    /// the quote refund and escrow cancelling to the wei (2,999,994 back, 2,999,995 out, the kept correction 1). Then
    /// the mixed slot's ask at index 2 repriced on its side (s_2 = 0): 4 LOT back, 5 LOT out.
    function test_modify_on_the_current_side_is_todays_modify() public {
        _post();
        address m2 = _maker();
        uint256[4] memory bidOnly;
        bidOnly[0] = OloOps.sub(T - 2, BID);
        vm.prank(m2);
        _mb(c, OloOps.batchW(OloOps.POST, true, SLOT, 0, 0, bidOnly));
        _take(false, 2 * LOT, 0x1, T - 2);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(m2, SLOT, 0x1, T - 2)),
            OloOps.tagW(c, OloOps.takeW(false, 2 * LOT, 0))
        );
        uint256[4] memory o;
        o[0] = OloOps.sub(T - 2, BID - 2 * LOT);
        address[2] memory who = [mk, m2];
        for (uint256 j; j < 2; ++j) {
            (uint256 word0,) = _slotWords(c, who[j], SLOT);
            uint256 b0 = _bal(who[j], base);
            uint256 q0 = _bal(who[j], quote);
            uint256 pot0 = _pot(quote);
            vm.prank(who[j]);
            _mb(c, OloOps.withSides(OloOps.batchW(OloOps.MODIFY, false, SLOT, 0, 0x1, o), 0x1));
            assertEq(_bal(who[j], base) - b0, 2 * LOT, "the fills' base");
            assertEq(_bal(who[j], quote) - q0, 69, "the fee's maker part only: refund and escrow cancel");
            assertEq(_pot(quote) - pot0, 30, "the pot");
            (uint256 word, uint256 set) = _slotWords(c, who[j], SLOT);
            assertEq(word, word0, "kept: the word as it was, D_0 too");
            assertEq(BatchView.baseOf(set, 0), BID - 2 * LOT, "its base its open units");
        }
        o[0] = 0;
        o[2] = OloOps.sub(T + 4, 5 * LOT);
        uint256 b1 = _bal(mk, base);
        uint256 q1 = _bal(mk, quote);
        vm.prank(mk);
        _mb(c, OloOps.withSides(OloOps.batchW(OloOps.MODIFY, false, SLOT, 0, 0x4, o), 0));
        assertEq(b1 - _bal(mk, base), LOT, "4 LOT refunded, 5 LOT escrowed");
        assertEq(_bal(mk, quote), q1, "no quote");
        (uint256 w,) = _slotWords(c, mk, SLOT);
        assertEq(w >> 246, 1, "the sides as they were");
    }

    /// A cancel of the bid empties it with its side: the slot left holds asks only (no side bit), and a take finds it
    /// as a slot of asks. A cancel and a claim read no sides.
    function test_cancel_of_the_other_side_leaves_a_one_sided_slot() public {
        _post();
        uint256 q0 = _bal(mk, quote);
        vm.prank(mk);
        _mb(c, OloOps.withSides(OloOps.maskW(OloOps.CANCEL, SLOT, 0, 0x1), 0xf));
        assertEq(_bal(mk, quote) - q0, 4_999_990, "the bid's quote refunded, rounded down");
        (uint256 word,) = _slotWords(c, mk, SLOT);
        (uint256 posted,) = _postedWords();
        assertEq(word, posted & ~(SUB_BITS_0 | (uint256(1) << 246)), "sub-order 0 and its side cleared");
        assertEq(word >> 246, 0, "no side bit: asks only");
        (uint256 got,) = _take(false, 10 * LOT, 0xf, 1);
        assertEq(got, 0, "a sell finds the ask slot on its own side");
        (got,) = _take(true, 10 * LOT, 0xf, T + 10);
        assertEq(got, 9 * LOT, "a buy fills the three asks");
    }

    uint256 constant SUB_BITS_0 = ((uint256(1) << 61) - 1) << 2;

    // ------------------------------------------------------------------ fuzz: one mixed slot = two one-sided slots

    /// One maker's orders on both sides in one slot (M1), another's same orders as a bid slot and an ask slot (M2; the
    /// same indices), then the same takes against each (a buy names M1's slot or M2's two, each sub-order at the same
    /// bound, base or quote mode), and the same claims, modifies and cancels: the same taker amounts every time and
    /// the same maker balance changes, at a maker share of 100% (the fee split once an operation: 100% splits none).
    struct Eq {
        address m1;
        address m2;
        uint256 bids; // the sub-orders posted as bids
        uint256 live; // the sub-orders posted and not cancelled
        int256 d1b; // M1's base and quote changes, all operations
        int256 d1q;
        int256 d2b; // M2's
        int256 d2q;
    }

    function testFuzz_mixed_slot_equals_two_one_sided_slots(uint256 seed) public {
        _setMarketShare(10_000);
        Eq memory e;
        e.m1 = _maker();
        e.m2 = _maker();
        _eqRest(e, seed, OloOps.POST);
        _eqCheck(e, "post");
        for (uint256 step; step < 12; ++step) {
            uint256 r = _rnd(seed, 100 + step);
            if (r % 3 != 0) _eqTake(e, r >> 8);
            else _eqMaker(e, r >> 8);
        }
        // everything cancelled: the totals equal
        _eqOp(e, true, OloOps.maskW(OloOps.CANCEL, 1, 0, 0xf));
        _eqOp(e, false, OloOps.maskW(OloOps.CANCEL, 2, 0, 0xf));
        _eqOp(e, false, OloOps.maskW(OloOps.CANCEL, 3, 0, 0xf));
        _eqCheck(e, "the end");
        (uint256 baseLeft,) = _everyoneLeaves();
        assertEq(baseLeft, 0, "no base left");
    }

    /// Up to four orders on random sides (at least one), rested by M1 in one slot (each order's side its own) and by
    /// M2 as its bids in slot 2 and its asks in slot 3, each at its own index: a post, or a replace (M2 cancels a slot
    /// whose side the new orders leave empty).
    function _eqRest(Eq memory e, uint256 r, uint8 kind) internal {
        uint256[4] memory o;
        uint256[4] memory ob;
        uint256[4] memory oa;
        e.live = 0;
        e.bids = 0;
        for (uint256 i; i < 4; ++i) {
            uint256 ri = _rnd(r, i);
            if (ri % 4 == 0 && !(i == 3 && e.live == 0)) continue;
            bool bid = (ri >> 8) & 1 == 1;
            o[i] = OloOps.sub(bid ? T - 1 - (ri >> 16) % 40 : T + 1 + (ri >> 16) % 40, _amount(ri >> 32));
            e.live |= 1 << i;
            if (bid) {
                e.bids |= 1 << i;
                ob[i] = o[i];
            } else {
                oa[i] = o[i];
            }
        }
        assertTrue(_eqOp(e, true, OloOps.withSides(OloOps.batchW(kind, false, 1, 0, 0, o), uint8(e.bids))), "M1 rested");
        if (e.bids != 0) assertTrue(_eqOp(e, false, OloOps.batchW(kind, true, 2, 0, 0, ob)), "M2's bids");
        else if (kind == OloOps.REPLACE) _eqOp(e, false, OloOps.maskW(OloOps.CANCEL, 2, 0, 0xf));
        if (e.live & ~e.bids != 0) assertTrue(_eqOp(e, false, OloOps.batchW(kind, false, 3, 0, 0, oa)), "M2's asks");
        else if (kind == OloOps.REPLACE) _eqOp(e, false, OloOps.maskW(OloOps.CANCEL, 3, 0, 0xf));
    }

    /// An amount of base wei: 10 .. about 10^12 (q 0 to 3 past 2^30), worth at least a quote wei at a price near 1.
    function _amount(uint256 r) internal pure returns (uint256) {
        return 10 + (r >> 8) % 10 ** (1 + r % 12);
    }

    function _rnd(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    /// An operation by M1 (`one`) or M2, its balance changes added to the maker's; whether it went through.
    function _eqOp(Eq memory e, bool one, uint256[3] memory w) internal returns (bool ok) {
        address a = one ? e.m1 : e.m2;
        uint256 b0 = _bal(a, base);
        uint256 q0 = _bal(a, quote);
        vm.prank(a);
        (ok,) = address(book).call(OloOps.batchCalldata(book.manageBatchSubs.selector, c, w));
        int256 db = int256(_bal(a, base)) - int256(b0);
        int256 dq = int256(_bal(a, quote)) - int256(q0);
        if (one) {
            e.d1b += db;
            e.d1q += dq;
        } else {
            e.d2b += db;
            e.d2q += dq;
        }
    }

    function _eqCheck(Eq memory e, string memory when) internal pure {
        assertEq(e.d1b, e.d2b, string.concat(when, ": the makers' base"));
        assertEq(e.d1q, e.d2q, string.concat(when, ": the makers' quote"));
    }

    /// The same take against M1's slot and M2's two: a mask and a bound per index, buy or sell, base or quote mode.
    function _eqTake(Eq memory e, uint256 r) internal {
        // the side: three times in four one M1 has units open on (when it has any), else random
        bool buy = r & 1 == 1;
        (uint256 w1,) = _slotWords(c, e.m1, 1);
        uint256 bidsOpen;
        uint256 asksOpen;
        for (uint256 i; i < 4; ++i) {
            if (BatchView.openOf(w1, i) == 0) continue;
            if ((BatchLib.bidMask(w1) >> i) & 1 == 1) bidsOpen |= 1 << i;
            else asksOpen |= 1 << i;
        }
        if ((r >> 2) % 4 != 0 && (bidsOpen == 0) != (asksOpen == 0)) buy = asksOpen != 0;
        bool quoteMode = (r >> 3) % 4 == 0;
        uint256 amount = (r >> 5) % 10 == 0 ? (1 << 100) : _amount(r >> 8) * (1 + (r >> 60) % 30);
        // every sub-order named half the time, else a random mask
        uint8 mask = (r >> 99) & 1 == 0 ? 0xf : uint8(1 + (r >> 100) % 15);
        // per index: a bound every order of the taker's wanted side passes (two thirds of the time), one that cuts
        // that side halfway (T +- 20), or one none passes
        uint256[4] memory ticks;
        for (uint256 i; i < 4; ++i) {
            uint256 x = (r >> (120 + 8 * i)) % 6;
            if (x < 3) ticks[i] = buy ? PriceGrid.MAX_TICK : 1;
            else if (x == 3) ticks[i] = buy ? T + 20 : T - 20;
            else if (x == 4) ticks[i] = buy ? T - 20 : T + 20;
            else ticks[i] = buy ? T + 40 : T - 40;
        }
        uint256 params = quoteMode ? OloOps.quoteW(buy, amount, 0) : OloOps.takeW(buy, amount, 0);
        bytes memory list1 = OloOps.batchList(OloOps.slotGroup(e.m1, 1, mask, ticks));
        bytes memory groups;
        if (mask & e.bids != 0) groups = OloOps.slotGroup(e.m2, 2, uint8(mask & e.bids), ticks);
        if (mask & e.live & ~e.bids != 0) {
            groups = bytes.concat(groups, OloOps.slotGroup(e.m2, 3, uint8(mask & e.live & ~e.bids), ticks));
        }
        (bool ok1, bytes memory ret1, int256 b1, int256 q1) = _takeCall(list1, params);
        if (groups.length == 0) {
            // M2 has no slot the mask names: M1's take fills nothing either
            assertTrue(ok1, "M1: nothing to fill, no revert");
            (uint256 got,) = abi.decode(ret1, (uint256, uint256));
            assertEq(got, 0, "M1: nothing filled");
            return;
        }
        (bool ok2, bytes memory ret2, int256 b2, int256 q2) = _takeCall(OloOps.batchList(groups), params);
        assertEq(ok1, ok2, "the same verdict");
        assertEq(ret1, ret2, "the same amounts (or the same error)");
        assertEq(b1, b2, "the taker's base");
        assertEq(q1, q2, "the taker's quote");
    }

    function _takeCall(bytes memory list, uint256 params)
        internal
        returns (bool ok, bytes memory ret, int256 db, int256 dq)
    {
        uint256 b0 = _bal(taker, base);
        uint256 q0 = _bal(taker, quote);
        vm.prank(taker);
        (ok, ret) = address(book).call(abi.encodeCall(book.take, (OloOps.key(c), list, OloOps.tagW(c, params))));
        db = int256(_bal(taker, base)) - int256(b0);
        dq = int256(_bal(taker, quote)) - int256(q0);
    }

    /// The same maker operation by M1 and M2: a claim, a cancel of one sub-order, a modify of one live sub-order on its
    /// own side (a new tick and amount; an index a claim emptied is not modified: M1's slot has no order there), or a
    /// replace by new orders on new sides.
    function _eqMaker(Eq memory e, uint256 r) internal {
        uint256 what = r % 4;
        if (what == 3) {
            _eqRest(e, r >> 2, OloOps.REPLACE);
            _eqCheck(e, "a replace");
            return;
        }
        uint256 i = (r >> 4) % 4;
        (uint256 word1,) = _slotWords(c, e.m1, 1);
        if ((e.live >> i) & 1 == 0 || (what == 2 && BatchView.tickOf(word1, i) == 0)) what = 0;
        bool bid = (e.bids >> i) & 1 == 1;
        uint16 slot2 = bid ? 2 : 3;
        if (what == 0) {
            bool ok1 = _eqOp(e, true, OloOps.maskW(OloOps.CLAIM, 1, 0, 0));
            bool any = _eqOp(e, false, OloOps.maskW(OloOps.CLAIM, 2, 0, 0));
            any = _eqOp(e, false, OloOps.maskW(OloOps.CLAIM, 3, 0, 0)) || any;
            assertEq(ok1, any, "a claim: fills to pay in both or neither");
        } else if (what == 1) {
            bool ok1 = _eqOp(e, true, OloOps.maskW(OloOps.CANCEL, 1, 0, uint8(1 << i)));
            bool ok2 = _eqOp(e, false, OloOps.maskW(OloOps.CANCEL, slot2, 0, uint8(1 << i)));
            assertEq(ok1, ok2, "a cancel: the same verdict");
            // a sub-order cancelled is gone in both, for the takes after
            if (ok1) e.live &= ~(1 << i);
        } else {
            uint256[4] memory o;
            o[i] = OloOps.sub(bid ? T - 1 - (r >> 16) % 40 : T + 1 + (r >> 16) % 40, _amount(r >> 32));
            // M1 passes the slot's sides: the sub-order keeps its side (a modify rests each index it names on s_i)
            uint256[3] memory w1 =
                OloOps.withSides(OloOps.batchW(OloOps.MODIFY, false, 1, 0, uint8(1 << i), o), uint8(word1 >> 246));
            bool ok1 = _eqOp(e, true, w1);
            bool ok2 = _eqOp(e, false, OloOps.batchW(OloOps.MODIFY, bid, slot2, 0, uint8(1 << i), o));
            assertEq(ok1, ok2, "a modify: the same verdict");
        }
        _eqCheck(e, "a maker operation");
    }

    // ------------------------------------------------------------------ fuzz: solvency

    /// Random mixed posts, replaces, modifies (some adding an order at an empty index on either side), cancels and
    /// claims by three makers on two slots each, with random takes over all six (base and quote mode, buys and
    /// sells), then every slot cancelled and everyone leaving: nothing reverts, no base is left, and quote keeps at
    /// most the roundings (2 wei a take, 16 an operation).
    function testFuzz_mixed_slots_stay_solvent(uint256 seed) public {
        address[3] memory ms = [_maker(), _maker(), _maker()];
        uint256 okOps;
        uint256 takes;
        for (uint256 step; step < 40; ++step) {
            uint256 r = _rnd(seed, step);
            if (r % 5 < 2) {
                if (_soTake(ms, r >> 8)) ++takes;
            } else {
                address a = ms[(r >> 8) % 3];
                uint16 slot = uint16(1 + (r >> 10) % 2);
                vm.prank(a);
                (bool ok,) =
                    address(book).call(OloOps.batchCalldata(book.manageBatchSubs.selector, c, _soOp(r >> 16, slot)));
                if (ok) ++okOps;
            }
        }
        for (uint256 k; k < 3; ++k) {
            for (uint16 slot = 1; slot <= 2; ++slot) {
                (uint256 word,) = _slotWords(c, ms[k], slot);
                if (BatchLib.liveMask(word) == 0) continue;
                vm.prank(ms[k]);
                _mb(c, OloOps.maskW(OloOps.CANCEL, slot, 0, 0xf));
                ++okOps;
            }
        }
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 0, "no base left");
        assertLe(quoteLeft, 2 * takes + 16 * okOps, "quote: at most a wei per rounding left");
    }

    /// A random operation's words: post, replace, modify, cancel or claim; random sides; each order priced for the side
    /// it rests on, s_i (a modify's too: a live sub-order named with the other side is turned).
    function _soOp(uint256 r, uint16 slot) internal pure returns (uint256[3] memory) {
        uint8 kind = uint8(r % 5);
        uint8 sides = uint8((r >> 4) % 16);
        uint8 mask = uint8(1 + (r >> 8) % 15);
        uint256[4] memory o;
        for (uint256 i; i < 4; ++i) {
            uint256 ri = uint256(keccak256(abi.encode(r, i)));
            if (ri % 4 == 0) continue;
            bool bid = (sides >> i) & 1 == 1;
            o[i] = OloOps.sub(bid ? T - 1 - (ri >> 8) % 40 : T + 1 + (ri >> 8) % 40, _amount(ri >> 16));
        }
        return OloOps.withSides(OloOps.batchW(kind, false, slot, 0, mask, o), sides);
    }

    /// A random take over the six slots: 1 to 3 groups, random masks and bounds.
    function _soTake(address[3] memory ms, uint256 r) internal returns (bool filled) {
        bool buy = r & 1 == 1;
        bool quoteMode = (r >> 1) % 4 == 0;
        uint256 amount = (r >> 4) % 4 == 0 ? (1 << 100) : _amount(r >> 8) * (1 + (r >> 60) % 30);
        bytes memory groups;
        uint256 n = 1 + (r >> 70) % 3;
        for (uint256 g; g < n; ++g) {
            uint256 rg = uint256(keccak256(abi.encode(r, g)));
            uint256 off = (rg >> 8) % 40;
            uint256 bound = rg % 3 == 0 ? (buy ? PriceGrid.MAX_TICK : 1) : buy ? T + off : T - off;
            groups = bytes.concat(
                groups,
                OloOps.slotGroupAt(ms[(rg >> 16) % 3], uint16(1 + (rg >> 18) % 2), uint8(1 + (rg >> 20) % 15), bound)
            );
        }
        uint256 params = quoteMode ? OloOps.quoteW(buy, amount, 0) : OloOps.takeW(buy, amount, 0);
        vm.prank(taker);
        (bool ok, bytes memory ret) = address(book)
            .call(abi.encodeCall(book.take, (OloOps.key(c), OloOps.batchList(groups), OloOps.tagW(c, params))));
        if (ok) {
            (uint256 got,) = abi.decode(ret, (uint256, uint256));
            filled = got != 0;
        } else {
            // the one refusal a take over valid groups meets: a sell whose fee reaches its quote
            assertEq(bytes4(ret), IOloBookBase.SellBelowFee.selector, "a take refused only as SellBelowFee");
        }
    }
}
