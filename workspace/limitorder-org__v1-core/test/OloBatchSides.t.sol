// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {BatchLib, OloSlots} from "../src/OloTypes.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";

/// A batch sub-order's side is one bit of its own, D_i at main-word bit 246 + i (1 a bid), and an operation's order i
/// rests on the side s_i its params give (bit 136 + i), in a post, a replace and a modify alike.
/// The earlier encoding had a slot side S at bit 0 and these bits as flips against it: one pattern of sides had two
/// encodings, and a modify, which kept S and read its flips against it, turned every sub-order it named to the other
/// side when its caller used the other encoding. Here that encoding's two cases, now as written; a kept ask paid as a
/// claim pays (the kept path's correction is a bid's alone); a sub-order filled to no open units keeping its side until
/// a settle empties it; an index's side cleared before it rests, whatever bit an empty index held; and the old rule's
/// callers: bit 3 set (its slot side, a bid) is BadBatch for every kind, and its modify of bit 3 clear is read as sides
/// (the residual a deployment's encoding rule covers).
///
/// The fixture market: T is P = 1, T + k = 1 + k x 10^-5 and T - k = 1 - k x 10^-6 (6 significant figures), LOT = 10^6
/// base wei, a fee of 50 ppm, the maker share 70%.
contract OloBatchSidesTest is OloBase {
    uint16 constant SLOT = 5;

    function setUp() public {
        _deploy();
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
        _setMarketShare(7_000);
    }

    function _op(address m, uint8 kind, uint8 mask, uint8 sides, uint256[4] memory o) internal {
        vm.prank(m);
        _mb(c, OloOps.withSides(OloOps.batchW(kind, false, SLOT, 0, mask, o), sides));
    }

    function _take(address m, bool buy, uint256 amount, uint8 mask, uint256 bound)
        internal
        returns (uint256 got, uint256 paid)
    {
        vm.prank(taker);
        (got, paid) = book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(m, SLOT, mask, bound)),
            OloOps.tagW(c, OloOps.takeW(buy, amount, 0))
        );
    }

    function _word(address m) internal view returns (uint256 w) {
        (w,) = _slotWords(c, m, SLOT);
    }

    /// An ask at T + 1 and bids at T - 1 .. T - 3, a LOT each: 1,000,000 base and 999,999 + 999,998 + 999,997 =
    /// 2,999,994 quote escrowed.
    function _postAskAndThreeBids(address m) internal {
        _op(
            m,
            OloOps.POST,
            0,
            0xe,
            [OloOps.sub(T + 1, LOT), OloOps.sub(T - 1, LOT), OloOps.sub(T - 2, LOT), OloOps.sub(T - 3, LOT)]
        );
        assertEq(BatchLib.bidMask(_word(m)), 0xe, "an ask, three bids");
        assertEq(_word(m) & 1, 0, "bit 0 zero");
    }

    // ------------------------------------------------------------------ the earlier encoding's two cases, as written

    /// The first case: the requote one tick out (the ask to T + 2, the bids to T - 2 .. T - 4) with the sides the
    /// orders have, 1110. Under the earlier encoding the other spelling of that pattern (S a bid, f 0001) turned every
    /// sub-order; now there is one: the ask's LOT back and out (no base moves), the bids' 2,999,994 back and 999,998 +
    /// 999,997 + 999,996 = 2,999,991 out (quote +3), and a buy at T finds no ask below it.
    function test_requote_rests_each_order_on_its_side() public {
        address m = _maker();
        _postAskAndThreeBids(m);
        uint256 b0 = _bal(m, base);
        uint256 q0 = _bal(m, quote);
        _op(
            m,
            OloOps.MODIFY,
            0xf,
            0xe,
            [OloOps.sub(T + 2, LOT), OloOps.sub(T - 2, LOT), OloOps.sub(T - 3, LOT), OloOps.sub(T - 4, LOT)]
        );
        assertEq(BatchLib.bidMask(_word(m)), 0xe, "an ask at T + 2, bids at T - 2 .. T - 4");
        assertEq(_bal(m, base), b0, "the ask's LOT back and out");
        assertEq(_bal(m, quote) - q0, 2_999_994 - 2_999_991, "the bids' quote back and out");
        (uint256 got,) = _take(m, true, 3 * LOT, 0xf, T);
        assertEq(got, 0, "a buy at T: the ask is at T + 2, the bids its own side");
    }

    /// The second case: a slot turned to four bids by a modify (its ask turned to a bid at T - 4) holds sides 1111,
    /// whatever it was posted as, so the plain requote of four bids, sides 1111, rests four bids: 999,996 + 999,999 +
    /// 999,998 + 999,997 = 3,999,990 quote back, 999,995 + 999,998 + 999,997 + 999,996 = 3,999,986 out, no base. The
    /// sides are read as written: 0000 on the same slot would rest four asks (the case's old outcome, now only on the
    /// caller's word).
    function test_a_slot_turned_to_bids_is_requoted_as_bids() public {
        address m = _maker();
        _postAskAndThreeBids(m);
        uint256[4] memory one;
        one[0] = OloOps.sub(T - 4, LOT);
        _op(m, OloOps.MODIFY, 0x1, 0x1, one);
        assertEq(_word(m) >> 246, 0xf, "four bids: D 1111");
        uint256 b0 = _bal(m, base);
        uint256 q0 = _bal(m, quote);
        uint256[4] memory n =
            [OloOps.sub(T - 5, LOT), OloOps.sub(T - 2, LOT), OloOps.sub(T - 3, LOT), OloOps.sub(T - 4, LOT)];
        _op(m, OloOps.MODIFY, 0xf, 0xf, n);
        assertEq(BatchLib.bidMask(_word(m)), 0xf, "four bids still");
        assertEq(_bal(m, base), b0, "no base");
        assertEq(_bal(m, quote) - q0, 3_999_990 - 3_999_986, "the bids' quote back and out");
        (uint256 got,) = _take(m, true, 4 * LOT, 0xf, T);
        assertEq(got, 0, "a buy at T fills no bid");
        // the same slot, the sides 0000: four asks, as written
        address m2 = _maker();
        _postAskAndThreeBids(m2);
        _op(m2, OloOps.MODIFY, 0x1, 0x1, one);
        b0 = _bal(m2, base);
        q0 = _bal(m2, quote);
        _op(m2, OloOps.MODIFY, 0xf, 0x0, n);
        assertEq(BatchLib.bidMask(_word(m2)), 0, "four asks: the sides as written");
        assertEq(b0 - _bal(m2, base), 4 * LOT, "4 LOT of base escrowed");
        assertEq(_bal(m2, quote) - q0, 3_999_990, "the bids' quote back");
    }

    // ------------------------------------------------------------------ the kept path

    /// A kept ask pays as a claim pays. Two makers post a bid of a LOT at T - 1 and an ask of 3,000,001 at T + 1; a buy
    /// takes a LOT of each ask. Maker A claims; maker B modifies the ask to the order it is (T + 1, 2,000,001 open, an
    /// ask), a kept modify: its fills paid, no escrow moved. Both get floor(10^6 x 1.00001) = 1,000,010 and 70% of the
    /// fee floor(50.0005) = 50, 35: 1,000,045, and keep the same words. The kept path's rounding correction,
    /// quoteUp - quoteDown, is a bid's alone: an ask given it would take ceil - floor of 2,000,021.00001 = 1 wei the
    /// book never took.
    function test_a_kept_ask_pays_as_a_claim() public {
        uint256 open = 3_000_001 - LOT;
        assertEq(PriceGrid.quoteUp(open, T + 1) - PriceGrid.quoteDown(open, T + 1), 1, "the open quote is not whole");
        address a = _maker();
        address b = _maker();
        uint256[4] memory o = [OloOps.sub(T - 1, LOT), OloOps.sub(T + 1, 3_000_001), 0, 0];
        _op(a, OloOps.POST, 0, 0x1, o);
        _op(b, OloOps.POST, 0, 0x1, o);
        _take(a, true, LOT, 0x2, T + 1);
        _take(b, true, LOT, 0x2, T + 1);
        uint256 aq = _bal(a, quote);
        uint256 bq = _bal(b, quote);
        uint256 ab = _bal(a, base);
        uint256 bb = _bal(b, base);
        vm.prank(a);
        _mb(c, OloOps.maskW(OloOps.CLAIM, SLOT, 0, 0));
        uint256[4] memory kept;
        kept[1] = OloOps.sub(T + 1, open);
        _op(b, OloOps.MODIFY, 0x2, 0x1, kept);
        assertEq(_bal(a, quote) - aq, 1_000_045, "the claim: the fill and the fee's maker part");
        assertEq(_bal(b, quote) - bq, 1_000_045, "the kept ask: the same, no wei more");
        assertEq(_bal(a, base), ab, "no base for A");
        assertEq(_bal(b, base), bb, "no base for B");
        (uint256 wa, uint256 sa) = _slotWords(c, a, SLOT);
        (uint256 wb, uint256 sb) = _slotWords(c, b, SLOT);
        assertEq(wb, wa, "the same main word");
        assertEq(sb, sa, "the same settlement word");
    }

    // ------------------------------------------------------------------ sides kept and cleared

    /// A sub-order filled to no open units is live (its tick kept) and keeps its side until a settle empties it, so
    /// the settle pays its fills on that side: a bid of a LOT at T - 1 and an ask of a LOT at T + 1, each filled
    /// whole. Before the claim D is 0001 with no unit open; the claim pays the bid's LOT in base and the ask's
    /// 1,000,010 in quote, with 70% of the fees floor(49.99995) = 49 and floor(50.0005) = 50, 69; and empties both,
    /// their sides with them.
    function test_a_filled_sub_order_keeps_its_side_until_settled() public {
        address m = _maker();
        _op(m, OloOps.POST, 0, 0x1, [OloOps.sub(T - 1, LOT), OloOps.sub(T + 1, LOT), 0, 0]);
        _take(m, false, LOT, 0x1, T - 1);
        _take(m, true, LOT, 0x2, T + 1);
        uint256 w = _word(m);
        assertEq(BatchLib.liveMask(w), 0x3, "both live: their ticks kept");
        assertEq((w >> 33) & ((1 << 30) - 1), 0, "the bid: no unit open");
        assertEq(BatchLib.bidMask(w), 0x1, "the bid's side kept, the ask's 0");
        uint256 b0 = _bal(m, base);
        uint256 q0 = _bal(m, quote);
        vm.prank(m);
        _mb(c, OloOps.maskW(OloOps.CLAIM, SLOT, 0, 0));
        assertEq(_bal(m, base) - b0, LOT, "the bid's fills in base");
        assertEq(_bal(m, quote) - q0, 1_000_010 + 69, "the ask's fills in quote and the fees' maker part");
        assertEq(_word(m), 2, "both emptied, their sides with them: USED alone");
    }

    /// An index's side is cleared before it rests, whatever bit the empty index held: the contract never leaves a side
    /// on an empty sub-order, and the word it writes does not lean on that. A side bit stored by hand on the empty
    /// index 2 of an ask slot, then a modify resting an ask there (s_2 = 0): the word says an ask, as its 3 LOT of base
    /// escrowed says, and a buy fills it.
    function test_a_stale_side_bit_is_cleared_when_the_index_rests() public {
        address m = _maker();
        _op(m, OloOps.POST, 0, 0, [OloOps.sub(T + 1, LOT), OloOps.sub(T + 2, LOT), 0, 0]);
        uint256 key = OloSlots.batchSlot(c, m, SLOT);
        vm.store(address(book), bytes32(key), bytes32(_word(m) | (uint256(1) << 248)));
        uint256 b0 = _bal(m, base);
        uint256[4] memory o;
        o[2] = OloOps.sub(T + 3, 3 * LOT);
        _op(m, OloOps.MODIFY, 0x4, 0, o);
        assertEq(b0 - _bal(m, base), 3 * LOT, "an ask's base escrowed");
        assertEq(BatchLib.bidMask(_word(m)), 0, "an ask: the stale bit cleared");
        (uint256 got,) = _take(m, true, 3 * LOT, 0x4, T + 3);
        assertEq(got, 3 * LOT, "a buy fills it");
    }

    // ------------------------------------------------------------------ callers of the old rule

    /// The kind is params bits 0-3, 0 to 4: bit 3, the earlier encoding's slot side S, makes every kind BadBatch, so
    /// the old rule's commonest call, a bid slot's post (isBid 1, no flips), is refused rather than rested as asks:
    /// nothing escrowed, the slot untouched; the same words with bit 3 clear go through. A replace, a modify, a cancel
    /// and a claim of a live slot with fills are refused alike.
    function test_bit_3_set_is_bad_batch_for_every_kind() public {
        address m = _maker();
        uint256[4] memory asks = [OloOps.sub(T + 1, LOT), OloOps.sub(T + 2, LOT), 0, 0];
        _op(m, OloOps.POST, 0, 0, asks);
        _take(m, true, LOT / 2, 0x1, T + 1);
        uint256[4] memory bids = [OloOps.sub(T - 1, LOT), OloOps.sub(T - 2, LOT), 0, 0];
        uint256 b0 = _bal(m, base);
        uint256 q0 = _bal(m, quote);
        uint256[3] memory oldBidPost = OloOps.batchW(OloOps.POST, false, SLOT + 1, 0, 0, bids);
        oldBidPost[0] |= 1 << 3;
        vm.prank(m);
        vm.expectRevert(IOloBookBase.BadBatch.selector);
        _mb(c, oldBidPost);
        assertEq(_bal(m, base), b0, "no base moved");
        assertEq(_bal(m, quote), q0, "no quote moved");
        (uint256 w1,) = _slotWords(c, m, SLOT + 1);
        assertEq(w1, 0, "the slot untouched");
        uint256[3][4] memory others = [
            OloOps.batchW(OloOps.REPLACE, false, SLOT, 0, 0, asks),
            OloOps.batchW(OloOps.MODIFY, false, SLOT, 0, 0x2, [uint256(0), OloOps.sub(T + 3, LOT), 0, 0]),
            OloOps.maskW(OloOps.CANCEL, SLOT, 0, 0x1),
            OloOps.maskW(OloOps.CLAIM, SLOT, 0, 0)
        ];
        for (uint256 i; i < 4; ++i) {
            others[i][0] |= 1 << 3;
            vm.prank(m);
            vm.expectRevert(IOloBookBase.BadBatch.selector);
            _mb(c, others[i]);
        }
        oldBidPost[0] &= ~uint256(1 << 3);
        vm.prank(m);
        _mb(c, oldBidPost);
        (w1,) = _slotWords(c, m, SLOT + 1);
        assertEq(BatchLib.bidMask(w1), 0, "bit 3 clear, no sides: two asks, as written");
    }

    /// The residual a deployment's encoding rule covers: a caller of the old rule that believes a slot's S is a bid
    /// passes bit 3 clear and f_0 0 to reprice its bid (keeping its side under that rule, which read no isBid in a
    /// modify). Here s_0 0 is an ask: the bid of a LOT at T - 1 settled (999,999 quote back) and an ask of a LOT at
    /// T - 2 escrowed (10^6 base out), as the params say. Callers pick the encoding by the deployment (IOloBook).
    function test_an_old_rule_modify_with_bit_3_clear_is_read_as_sides() public {
        address m = _maker();
        _op(m, OloOps.POST, 0, 0x1, [OloOps.sub(T - 1, LOT), 0, 0, 0]);
        uint256 b0 = _bal(m, base);
        uint256 q0 = _bal(m, quote);
        vm.prank(m);
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, SLOT, 0, 0x1, [OloOps.sub(T - 2, LOT), 0, 0, 0]));
        assertEq(BatchLib.bidMask(_word(m)), 0, "an ask now");
        assertEq(_bal(m, quote) - q0, 999_999, "the bid's quote back");
        assertEq(b0 - _bal(m, base), LOT, "the ask's base out");
    }
}
