// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {BatchView} from "./BatchView.sol";
import {OloBook} from "../src/OloBook.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {OloMath} from "../src/libraries/OloMath.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {OloSlots, SET_USED} from "../src/OloTypes.sol";

using MarketLib for MarketWord;

/// The two-word batch slot: the main word (side | USED | 4 x (tick 26 | q 5 | open 30)) a take reads and writes, the
/// settlement word (4 x base 30 | USED) only a maker's operation touches; each sub-order stores its own units and q,
/// fills as a pool order, and settles as one (proceeds base - open). `manageBatchSubs` carries 26-bit ticks and base-wei
/// amounts in its params word and up to two raw words after it.
contract OloPreciseBatchTest is OloBase {
    function setUp() public {
        _deploy();
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    function _slotKey(address maker, uint16 s) internal view returns (uint256) {
        return OloSlots.batchSlot(c, maker, s);
    }

    /// Whether `slot` was written in the recorded accesses.
    function _wrote(uint256 slot) internal returns (bool) {
        (, bytes32[] memory writes) = vm.accesses(address(book));
        for (uint256 i; i < writes.length; ++i) {
            if (uint256(writes[i]) == slot) return true;
        }
        return false;
    }

    /// A post of four asks of different sizes, two of them q > 0: the main word holds each sub-order's tick, q and
    /// open units, the settlement word their bases, the escrow is what is stored, and BatchUpdated logs both words.
    function test_post_two_words_and_units() public {
        address z = _maker();
        uint256[4] memory o = [
            OloOps.sub(T + 1, 5 * LOT),
            OloOps.sub(T + 2, 1_234_567_891), // q 1: 123,456,789 units of 10, 1 wei dropped
            OloOps.sub(T + 3, 7),
            OloOps.sub(T + 4, 1e15 + 3) // q 6: 1e9 units of 1e6
        ];
        uint256[3] memory w = OloOps.batchW(OloOps.POST, false, 9, 0, 0, o);
        uint256 b0 = _bal(z, base);
        vm.recordLogs();
        vm.prank(z);
        _mb(c, w);
        (uint256 word, uint256 set) = _slotWords(c, z, 9);
        _sub(word, set, 0, T + 1, 0, 5 * LOT);
        _sub(word, set, 1, T + 2, 1, 123_456_789);
        _sub(word, set, 2, T + 3, 0, 7);
        _sub(word, set, 3, T + 4, 6, 1e9);
        assertEq(word & 3, 2, "an ask, USED");
        assertEq(set >> 255, 1, "settlement USED");
        assertEq(b0 - _bal(z, base), 5 * LOT + 1_234_567_890 + 7 + 1e15, "the stored amounts escrowed");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.topics[0], IOloBookBase.BatchUpdated.selector);
        (uint256 packed, uint256 lw, uint256 ls) = abi.decode(last.data, (uint256, uint256, uint256));
        assertEq(packed, 0 | (0xf << 8) | (uint256(9) << 128) | (uint256(1) << 144) | (uint256(m) << 160));
        assertEq(lw, word);
        assertEq(ls, set);
    }

    function _sub(uint256 word, uint256 set, uint256 i, uint256 tick, uint256 q, uint256 open) internal pure {
        (uint256 t, uint256 gq, uint256 go) = BatchView.subOf(word, i);
        assertEq(t, tick, "sub tick");
        assertEq(gq, q, "sub q");
        assertEq(go, open, "sub open units");
        assertEq(BatchView.baseOf(set, i), open, "sub base");
    }

    /// Every operation's calldata is the selector, K, the params word and the two amount words: 132 bytes whatever the
    /// number of orders (a static array has no offset or length). The four orders' amounts travel in them, two a word,
    /// so a typed encoder (`abi.encodeCall`, as ethers or viem build a contract call) sends one to four orders, and a
    /// field left at zero with its tick is an order left out.
    function test_calldata_words() public {
        address z = _maker();
        for (uint256 n = 1; n <= 4; ++n) {
            uint256[3] memory w = OloOps.postW(false, uint16(n), T + 1, 5 * LOT, n);
            assertEq(OloOps.batchCalldata(OloBook.manageBatchSubs.selector, c, w).length, 4 + 4 * 32);
            vm.prank(z);
            book.manageBatchSubs(OloOps.key(c), w[0], OloOps.wordsOf(w));
            for (uint256 i; i < 4; ++i) {
                assertEq(BatchView.openOf(_word(z, uint16(n)), i), i < n ? 5 * LOT : 0);
            }
        }
    }

    /// Bytes a wallet appends after the arguments lie past the ABI's two words and are not read: a suffix of 4, 20 or
    /// 32 bytes posts the one order as asked (until 2026-11-09 the amounts were two raw words after the arguments,
    /// which a suffix was read as). Bits of either amount word past its second amount's field (224-255) are no order's
    /// and are not read.
    function test_trailing_bytes_and_unread_bits() public {
        address z = _maker();
        uint256 b0 = _bal(z, base);
        bytes[3] memory suffixes = [
            abi.encodePacked(bytes4(0xdeadbeef)),
            abi.encodePacked(address(0xA77B1B)),
            abi.encodePacked(keccak256("a suffix"))
        ];
        for (uint256 k; k < 3; ++k) {
            uint16 slot = uint16(6 + k);
            bytes memory data =
                OloOps.batchCalldata(OloBook.manageBatchSubs.selector, c, OloOps.postW(false, slot, T + 1, 5 * LOT, 1));
            vm.prank(z);
            (bool posted,) = address(book).call(bytes.concat(data, suffixes[k]));
            assertTrue(posted, "the suffix is not read");
            assertEq(BatchView.openOf(_word(z, slot), 0), 5 * LOT);
            assertEq(BatchView.openOf(_word(z, slot), 1), 0, "nothing the params did not name");
        }
        assertEq(_bal(z, base), b0 - 15 * LOT, "three orders' escrow");
        uint256[3] memory two = OloOps.postW(false, 9, T + 1, 5 * LOT, 2);
        vm.prank(z);
        book.manageBatchSubs(OloOps.key(c), two[0], [two[1] | (uint256(1) << 224), uint256(1) << 224]);
        assertEq(BatchView.openOf(_word(z, 9), 1), 5 * LOT, "order 1 as asked");
        assertEq(BatchView.openOf(_word(z, 9), 2), 0, "no order 2");
        assertEq(BatchView.openOf(_word(z, 9), 3), 0, "no order 3: the bits past the fields are not read");
        assertEq(_bal(z, base), b0 - 25 * LOT, "two more orders' escrow");
    }

    function _word(address z, uint16 s) internal view returns (uint256 word) {
        (word,) = book.batchOf(c, z, s);
    }

    /// A take reads and writes the slot's main word only; the settlement word is not touched. A claim then pays base -
    /// open and moves base to open (writing the settlement word); a second claim has nothing to pay.
    function test_take_writes_the_main_word_only_and_claim_pays_base_minus_open() public {
        address z = _maker();
        vm.prank(z);
        _mb(c, OloOps.postW(false, 3, T + 1, 5 * LOT, 2));
        uint256 key = _slotKey(z, 3);
        vm.record();
        vm.prank(taker);
        (uint256 got,) = book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 3, 3, T + 2)),
            OloOps.tagW(c, OloOps.takeW(true, 7 * LOT, 0))
        );
        assertEq(got, 7 * LOT);
        assertTrue(_wrote(key), "the main word");
        assertFalse(_wrote(key + 1), "not the settlement word");
        (uint256 word, uint256 set) = _slotWords(c, z, 3);
        assertEq(BatchView.filledOf(word, set, 0), 5 * LOT);
        assertEq(BatchView.filledOf(word, set, 1), 2 * LOT);
        uint256 q0 = _bal(z, quote);
        vm.record();
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CLAIM, 3, 0, 0));
        assertTrue(_wrote(key + 1), "the claim writes the settlement word");
        uint256 proceeds = _qd(5 * LOT, T + 1) + _qd(2 * LOT, T + 2);
        uint256 fee = PriceGrid.feeDown(5 * LOT, T + 1, 50) + PriceGrid.feeDown(2 * LOT, T + 2, 50);
        assertEq(_bal(z, quote) - q0, proceeds + fee);
        (word, set) = _slotWords(c, z, 3);
        assertEq(BatchLibView.sub0(word), 0, "sub-order 0 filled whole and claimed: emptied");
        assertEq(BatchView.filledOf(word, set, 0), 0, "sub-order 0: nothing left to claim");
        assertEq(BatchView.baseOf(set, 1), 3 * LOT, "base moved to open");
        assertEq(BatchView.filledOf(word, set, 1), 0);
        vm.prank(z);
        vm.expectRevert(IOloBookBase.NothingToClaim.selector);
        _mb(c, OloOps.maskW(OloOps.CLAIM, 3, 0, 0));
    }

    /// A modify's order equal to its sub-order's tick and open amount is NoChange only while the sub-order has no
    /// fills to pay; with fills it rests again and they are paid, as a claim pays them: a take
    /// that brings a sub-order down to the size its maker is modifying it to must not revert the maker's requote of
    /// the slot. Asks of 100 LOT at T + 10 and at T + 20; a buy of 40 LOT of the first; the maker's modify names both,
    /// 60 LOT at T + 10 (what is open now) and 100 LOT at T + 30, and goes through: 40,004,000 quote of proceeds and
    /// the fee's maker part, floor(2000.2) = 2,000. An order the same as a sub-order with no fills still refuses the
    /// whole modify, and so does an empty order naming an empty index, whatever base an earlier order left there.
    function test_modify_to_what_is_open_pays_the_fills() public {
        address z = _maker();
        uint256[4] memory two = [OloOps.sub(T + 10, 100 * LOT), OloOps.sub(T + 20, 100 * LOT), 0, 0];
        uint256[4] memory same = [OloOps.sub(T + 10, 100 * LOT), 0, 0, 0];
        vm.startPrank(z);
        _mb(c, OloOps.batchW(OloOps.POST, false, 3, 0, 0, two));
        vm.expectRevert(IOloBookBase.NoChange.selector); // nothing filled: nothing to pay, nothing to change
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x1, same));
        vm.stopPrank();
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 3, 1, T + 10)),
            OloOps.tagW(c, OloOps.takeW(true, 40 * LOT, 0))
        );
        // sub-order 0 is paid as it is; sub-order 1, the same with no fills, still refuses the whole modify
        uint256[4] memory both = [OloOps.sub(T + 10, 60 * LOT), OloOps.sub(T + 20, 100 * LOT), 0, 0];
        vm.prank(z);
        vm.expectRevert(IOloBookBase.NoChange.selector);
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x3, both));
        uint256 q0 = _bal(z, quote);
        uint256 b0 = _bal(z, base);
        uint256[4] memory requote = [OloOps.sub(T + 10, 60 * LOT), OloOps.sub(T + 30, 100 * LOT), 0, 0];
        vm.prank(z);
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x3, requote));
        (uint256 word, uint256 set) = _slotWords(c, z, 3);
        assertEq(BatchView.tickOf(word, 0), T + 10);
        assertEq(BatchView.openOf(word, 0), 60 * LOT, "what was open rests on");
        assertEq(BatchView.baseOf(set, 0), 60 * LOT, "the fills paid: the base is the open units");
        assertEq(BatchView.tickOf(word, 1), T + 30, "the other sub-order moved");
        assertEq(_qd(40 * LOT, T + 10) + PriceGrid.feeDown(40 * LOT, T + 10, 50), 40_004_000 + 2_000);
        assertEq(_bal(z, quote) - q0, 40_004_000 + 2_000, "the fills' proceeds and the fee's maker part");
        assertEq(_bal(z, base), b0, "no base moves");
        same[0] = OloOps.sub(T + 10, 60 * LOT);
        uint256[4] memory none;
        vm.startPrank(z);
        vm.expectRevert(IOloBookBase.NoChange.selector); // paid: the same again changes nothing
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x1, same));
        // sub-order 1 cancelled: the index is empty and its base, 100 LOT, is left over
        _mb(c, OloOps.maskW(OloOps.CANCEL, 3, 0, 0x2));
        (word, set) = _slotWords(c, z, 3);
        assertEq(BatchView.tickOf(word, 1), 0);
        assertEq(BatchView.baseOf(set, 1), 100 * LOT);
        vm.expectRevert(IOloBookBase.NoChange.selector);
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, 3, 0, 0x2, none));
        vm.stopPrank();
        _solvent();
    }

    /// The settlement word is written only when it changes: a modify that moves a sub-order with no fills and keeps
    /// its amount leaves it; one that changes the amount, or settles fills, writes it; so does a cancel.
    function test_settlement_word_written_only_when_it_changes() public {
        address z = _maker();
        vm.prank(z);
        _mb(c, OloOps.postW(false, 4, T + 1, 5 * LOT, 4));
        uint256 key = _slotKey(z, 4);
        uint256[4] memory o;
        o[1] = OloOps.sub(T + 9, 5 * LOT);
        vm.record();
        vm.prank(z);
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, 4, 0, 0x2, o));
        assertTrue(_wrote(key));
        assertFalse(_wrote(key + 1), "a move at the same amount: the settlement word unchanged");
        o[1] = OloOps.sub(T + 9, 6 * LOT);
        vm.record();
        vm.prank(z);
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, 4, 0, 0x2, o));
        assertTrue(_wrote(key + 1), "a new amount: a new base");
        // a fill on sub-order 2 (open 4 LOT, base 5 LOT); a modify back to 5 LOT pays the fill and leaves base 5 LOT:
        // the settlement word unchanged
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 4, 0x4, T + 3)),
            OloOps.tagW(c, OloOps.takeW(true, LOT, 0))
        );
        o[1] = 0;
        o[2] = OloOps.sub(T + 8, 5 * LOT);
        uint256 q0 = _bal(z, quote);
        vm.record();
        vm.prank(z);
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, 4, 0, 0x4, o));
        assertFalse(_wrote(key + 1), "base 5 LOT before and after");
        assertEq(_bal(z, quote) - q0, _qd(LOT, T + 3) + PriceGrid.feeDown(LOT, T + 3, 50), "the fill paid");
        // to 4 LOT: base moves
        o[2] = OloOps.sub(T + 8, 4 * LOT);
        vm.record();
        vm.prank(z);
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, 4, 0, 0x4, o));
        assertTrue(_wrote(key + 1));
        vm.record();
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CANCEL, 4, 0, 0x1));
        assertFalse(
            _wrote(key + 1), "a cancel leaves the settlement word (an emptied sub-order's base counts for nothing)"
        );
    }

    /// A batch sub-order settles exactly as the same pool order does: maker A holds four sub-orders (sizes with q 0 and
    /// q > 0), maker B the same four as pool positions; the same takes hit both; every settle moves the same amounts on
    /// A and B. Both sides.
    function test_asks_settle_as_pool() public {
        _settleAsPool(false);
    }

    function test_bids_settle_as_pool() public {
        _settleAsPool(true);
    }

    address a;
    address b;
    uint32 p0;

    function _same(string memory what) internal view {
        assertEq(
            int256(_bal(a, base)) - int256(1e24), int256(_bal(b, base)) - int256(1e24), string.concat(what, " base")
        );
        assertEq(
            int256(_bal(a, quote)) - int256(1e24), int256(_bal(b, quote)) - int256(1e24), string.concat(what, " quote")
        );
    }

    function _takeBoth(bool buy, uint256 amount, uint8 mask, uint256 bound) internal {
        vm.prank(taker);
        (uint256 ga,) = book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(a, 0, mask, bound)),
            OloOps.tagW(c, OloOps.takeW(buy, amount, 0))
        );
        bytes memory entries;
        for (uint256 i; i < 4; ++i) {
            if ((mask >> i) & 1 != 0) entries = bytes.concat(entries, OloOps.poolEntry(p0 + uint32(i), bound));
        }
        vm.prank(taker);
        (uint256 gb,) = book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(buy, amount, 0)));
        assertEq(ga, gb, "the same fills");
    }

    function _amounts() internal pure returns (uint256[4] memory) {
        return [uint256(5_000 * LOT), 1_234_567_891, 2e15 + 17, 333_333];
    }

    function _postBoth(bool isBid, uint256 t0, uint256 step, uint256[4] memory amts) internal {
        uint256[4] memory o;
        for (uint256 i; i < 4; ++i) {
            o[i] = OloOps.sub(isBid ? t0 - step * i : t0 + step * i, amts[i]);
        }
        vm.prank(a);
        _mb(c, OloOps.batchW(OloOps.POST, isBid, 0, 0, 0, o));
        for (uint256 i; i < 4; ++i) {
            vm.prank(b);
            book.place(
                OloOps.key(c), OloOps.placeW(isBid, isBid ? t0 - step * i : t0 + step * i, amts[i], p0 + uint32(i), 0)
            );
        }
    }

    function _settleAsPool(bool isBid) internal {
        a = _maker();
        b = _maker();
        uint256 t0 = isBid ? T - 2 : T + 2;
        uint256 step = 700_000; // the four sub-orders over two decades
        p0 = nextPos;
        nextPos += 4;
        _postBoth(isBid, t0, step, _amounts());
        _same("post");
        uint256 far = isBid ? 1 : PriceGrid.MAX_TICK;
        _takeBoth(!isBid, 5_000 * LOT + 1_000_000_007, 0xf, far);
        _same("take");
        vm.prank(a);
        _mb(c, OloOps.maskW(OloOps.CLAIM, 0, 0, 0));
        vm.startPrank(b);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(p0, 0)));
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(p0 + 1, 0)));
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(p0 + 3, 0)));
        vm.stopPrank();
        _same("claim");
        // more fills on sub-orders 1 and 2, then a modify of sub-order 1 (it settles its fills)
        _takeBoth(!isBid, 3e14 + 12_345, 0x6, far);
        uint256[4] memory o;
        uint256 t1 = isBid ? t0 - 3 * step : t0 + 3 * step;
        o[1] = OloOps.sub(t1 + (isBid ? 0 : 1), 9 * LOT + 1);
        vm.prank(a);
        _mb(c, OloOps.batchW(OloOps.MODIFY, isBid, 0, 0, 0x2, o));
        vm.prank(b);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(p0 + 1, t1 + (isBid ? 0 : 1), 9 * LOT + 1, 0)));
        _same("modify");
        // fills, then a cancel of everything
        _takeBoth(!isBid, 6e14, 0xf, far);
        vm.prank(a);
        _mb(c, OloOps.maskW(OloOps.CANCEL, 0, 0, 0xf));
        vm.startPrank(b);
        for (uint256 i = 1; i < 4; ++i) {
            book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(p0 + uint32(i), 0)));
        }
        vm.stopPrank();
        _same("cancel");
        // a replace over fills: post again, fill, replace (B: claim or cancel, and place)
        uint256[4] memory amts = _amounts();
        p0 = nextPos;
        nextPos += 8;
        _postBoth(isBid, t0, step, amts);
        _takeBoth(!isBid, 5_000 * LOT + 999_999_999, 0xf, far);
        uint256[4] memory r;
        for (uint256 i; i < 4; ++i) {
            r[i] = OloOps.sub(isBid ? t0 - 1 - i : t0 + 1 + i, 3_000 * LOT + i);
        }
        vm.prank(a);
        _mb(c, OloOps.batchW(OloOps.REPLACE, isBid, 0, 0, 0, r));
        vm.startPrank(b);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(p0, 0)));
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(p0 + 1, 0)));
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(p0 + 2, 0)));
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(p0 + 3, 0)));
        for (uint256 i; i < 4; ++i) {
            book.place(
                OloOps.key(c),
                OloOps.placeW(isBid, isBid ? t0 - 1 - i : t0 + 1 + i, 3_000 * LOT + i, p0 + 4 + uint32(i), 0)
            );
        }
        vm.stopPrank();
        _same("replace");
        _solvent();
    }

    /// The checks of a batch operation: a sub-order below minQuote, at a tick off the grid or the spacing, a modify
    /// keeping a sub-order's tick and open amount, a post into a live slot, an unknown kind, a mask naming nothing
    /// live, a post of no order.
    function test_batch_checks() public {
        MarketWord c2 = book.configOf(book.listMarketQuote(address(base), address(quote), 50, 5, 1e6, 0));
        address z = _maker();
        vm.startPrank(z);
        // minQuote 1e6: 999,999 base wei at P = 1 is worth 999,999
        vm.expectRevert(IOloBookBase.SizeOutOfRange.selector);
        _mb(c2, OloOps.postW(false, 0, T, 999_999, 1));
        vm.expectRevert(IOloBookBase.SizeOutOfRange.selector);
        _mb(c2, OloOps.batchW(OloOps.POST, false, 0, 0, 0, [OloOps.sub(T, 1e6), OloOps.sub(T + 10, 0), 0, 0]));
        // spacing 10: T + 1 is off it; 0 and past MAX_TICK are off the grid
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        _mb(c2, OloOps.postW(false, 0, T + 1, 1e6, 1));
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        _mb(c2, OloOps.batchW(OloOps.POST, false, 0, 0, 0, [OloOps.sub(T, 1e6), OloOps.sub(66_600_000, 1e6), 0, 0]));
        vm.expectRevert(IOloBookBase.ZeroSize.selector);
        _mb(c2, OloOps.maskW(OloOps.POST, 0, 0, 0));
        _mb(c2, OloOps.ladderW(OloOps.POST, false, 0, 0, T, 2e6, 2, 10));
        vm.expectRevert(IOloBookBase.SlotBusy.selector);
        _mb(c2, OloOps.ladderW(OloOps.POST, false, 0, 0, T, 2e6, 2, 10));
        uint256[4] memory o;
        o[1] = OloOps.sub(T + 10, 2e6);
        vm.expectRevert(IOloBookBase.NoChange.selector);
        _mb(c2, OloOps.batchW(OloOps.MODIFY, false, 0, 0, 0x2, o));
        vm.expectRevert(IOloBookBase.BadBatch.selector);
        _mb(c2, OloOps.maskW(5, 0, 0, 1));
        vm.expectRevert(IOloBookBase.BadBatch.selector);
        _mb(c2, OloOps.maskW(OloOps.CANCEL, 0, 0, 0));
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        _mb(c2, OloOps.maskW(OloOps.CANCEL, 0, 0, 0x8));
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        _mb(c2, OloOps.maskW(OloOps.CANCEL, 1, 0, 0x1));
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        _mb(_wrongC(), OloOps.postW(false, 0, T, 5 * LOT, 1));
        vm.stopPrank();
    }

    /// A post into a never-used slot writes both words fresh; after a cancel both keep USED, so the next post rewrites
    /// nonzero words.
    function test_never_used_and_used_slot() public {
        address z = _maker();
        uint256 key = _slotKey(z, 7);
        assertEq(uint256(vm.load(address(book), bytes32(key))), 0);
        assertEq(uint256(vm.load(address(book), bytes32(key + 1))), 0);
        vm.prank(z);
        _mb(c, OloOps.postW(true, 7, T - 1, 5 * LOT, 4));
        assertEq(uint256(vm.load(address(book), bytes32(key))) >> 246, 0xf, "four bids: each its side bit");
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CANCEL, 7, 0, 0xf));
        assertEq(uint256(vm.load(address(book), bytes32(key))), 2, "USED, no sub-order and no side");
        assertEq(uint256(vm.load(address(book), bytes32(key + 1))) & SET_USED, SET_USED, "USED (the bases left over)");
    }

    /// The take list is read a word at a time (`_word`), so a group short of the ticks its mask names must be refused
    /// before its ticks are read, not read on into what follows: as the list's last group (its padding after it), and
    /// followed by a pool segment whose bytes, read as the missing tick, would let the slot's sub-order 1 fill. A group
    /// short of its header, and a list ending in one or two stray bytes, are refused too.
    function test_a_group_short_of_its_ticks_reads_nothing_past_it() public {
        address z = _maker();
        vm.prank(z);
        _mb(c, OloOps.postW(false, 0, T + 1, 5 * LOT, 4)); // asks of 5 LOT at T + 1 .. T + 4
        address a = _plain(T + 1, false, 5 * LOT);
        bytes memory short = OloOps.batchList(abi.encodePacked(z, uint16(0), uint8(3), uint32(T + 6)));
        bytes[5] memory lists = [
            short,
            bytes.concat(short, OloOps.poolList(_poolEntry(a))),
            OloOps.batchList(abi.encodePacked(z, uint16(0))),
            bytes.concat(OloOps.poolList(_poolEntry(a)), hex"00"),
            bytes.concat(OloOps.poolList(_poolEntry(a)), hex"0000")
        ];
        (uint256 slotBefore,) = book.batchOf(c, z, 0);
        for (uint256 i; i < lists.length; ++i) {
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.BadTakeList.selector);
            book.take(OloOps.key(c), lists[i], OloOps.tagW(c, OloOps.takeW(true, 20 * LOT, 0)));
        }
        (uint256 slotAfter,) = book.batchOf(c, z, 0);
        assertEq(slotAfter, slotBefore, "nothing filled");
    }

    /// An emptied sub-order keeps its base, which counts for nothing: a cancel of a partly filled sub-order pays the
    /// fill and refunds the rest without writing the settlement word; its left-over base is never claimable; the index
    /// rested again gets a new base, and its next claim pays exactly that order's fill; a claim emptying it leaves the
    /// settlement word alone too.
    function test_an_emptied_sub_order_keeps_its_base_and_it_counts_for_nothing() public {
        address z = _maker();
        uint256 key = _slotKey(z, 9);
        vm.prank(z);
        _mb(c, OloOps.postW(false, 9, T + 2, 5 * LOT, 4)); // asks of 5 LOT at T + 2 .. T + 5
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 9, 0x1, T + 2)),
            OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0))
        );
        // the cancel of sub-order 0 (open 3 LOT, base 5 LOT): the fill paid, the rest refunded, the settlement word not
        // written; the left-over base stays
        uint256 q0 = _bal(z, quote);
        uint256 b0 = _bal(z, base);
        vm.record();
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CANCEL, 9, 0, 0x1));
        assertFalse(_wrote(key + 1), "a cancel leaves the settlement word");
        assertEq(_bal(z, quote) - q0, _qd(2 * LOT, T + 2) + PriceGrid.feeDown(2 * LOT, T + 2, 50), "the fill paid");
        assertEq(_bal(z, base) - b0, 3 * LOT, "the rest refunded");
        (uint256 word, uint256 set) = book.batchOf(c, z, 9);
        assertEq(BatchView.tickOf(word, 0), 0, "sub-order 0 empty");
        assertEq(BatchView.baseOf(set, 0), 5 * LOT, "its base left over");
        assertEq(BatchView.filledOf(word, set, 0), 0, "counting for nothing");
        // nothing to claim: the left-over base is not a fill
        vm.prank(z);
        vm.expectRevert(IOloBookBase.NothingToClaim.selector);
        _mb(c, OloOps.maskW(OloOps.CLAIM, 9, 0, 0));
        // index 0 rested again with 1 LOT: a new base; taken whole; the claim pays that fill alone and empties it,
        // leaving the settlement word alone
        uint256[4] memory o;
        o[0] = OloOps.sub(T + 2, LOT);
        vm.prank(z);
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, 9, 0, 0x1, o));
        (, set) = book.batchOf(c, z, 9);
        assertEq(BatchView.baseOf(set, 0), LOT, "a new base");
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 9, 0x1, T + 2)),
            OloOps.tagW(c, OloOps.takeW(true, LOT, 0))
        );
        q0 = _bal(z, quote);
        vm.record();
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CLAIM, 9, 0, 0));
        assertFalse(_wrote(key + 1), "a claim emptying its sub-orders leaves the settlement word");
        assertEq(_bal(z, quote) - q0, _qd(LOT, T + 2) + PriceGrid.feeDown(LOT, T + 2, 50), "exactly the new fill");
        (word,) = book.batchOf(c, z, 9);
        assertEq(BatchView.tickOf(word, 0), 0, "emptied by its claim");
        assertEq(BatchView.openOf(word, 1), 5 * LOT, "the others untouched");
    }

    /// The Take event's batch records: per group maker 20 | slot 2 | n 1, then index 1 | q 1 | units 4; a group whose
    /// slot filled nothing is left out, a segment of no fills too.
    function test_take_event_batch_records() public {
        address z = _maker();
        uint256[4] memory o = [OloOps.sub(T + 1, 5 * LOT), OloOps.sub(T + 2, 2e15), 0, 0];
        vm.prank(z);
        _mb(c, OloOps.batchW(OloOps.POST, false, 5, 0, 0, o));
        address y = _maker();
        bytes memory groups = bytes.concat(
            OloOps.slotGroupAt(y, 1, 1, T + 9), // nothing there
            OloOps.slotGroupAt(z, 5, 3, T + 9)
        );
        vm.recordLogs();
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.batchList(groups), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT + 1e7 + 5, 0)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,,,, bytes memory fills) = abi.decode(logs[logs.length - 1].data, (uint256, uint256, uint256, uint256, bytes));
        // sub-order 1 is 2e15 at q 7 (units of 1e7): 1e7 fills as 1 unit, 5 wei left
        bytes memory recs = abi.encodePacked(
            z, uint16(5), uint8(2), uint8(0), uint8(0), uint32(5 * LOT), uint8(1), uint8(7), uint32(1)
        );
        assertEq(fills, bytes.concat(abi.encodePacked(uint8(1), uint24(recs.length)), recs));
    }

    /// Both sides through the wallet: a bid slot posted and claimed through the wallet (WALLET), a sell filling it.
    function test_bid_slot_wallet() public {
        address z = address(0xB1D);
        quote.mint(z, 1e30);
        vm.startPrank(z);
        quote.approve(address(book), type(uint256).max);
        _mb(c, OloOps.ladderW(OloOps.POST, true, 0, 0x02, T - 1, 3 * LOT + 1, 2, 1));
        vm.stopPrank();
        uint256 escrow = _qu(3 * LOT + 1, T - 1) + _qu(3 * LOT + 1, T - 2);
        assertEq(1e30 - quote.balanceOf(z), escrow);
        vm.prank(taker);
        (uint256 sold,) = book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 0, 3, T - 5)),
            OloOps.tagW(c, OloOps.takeW(false, 4 * LOT, 0))
        );
        assertEq(sold, 4 * LOT);
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CANCEL, 0, 0x02, 0x3));
        assertEq(base.balanceOf(z), 4 * LOT, "the fills paid to the wallet");
        _solvent();
    }

    /// A batch segment holds as many groups as its 16-bit length allows: 1,680 full slots (39 bytes a group, 65,520
    /// bytes), and their fills, 47 bytes a slot (maker 20 | slot 2 | n 1 | four records of 6), 78,960 bytes, are logged
    /// under the Take event's 3-byte segment length (a 16-bit one would read 13,424): the fills buffer, sized at twice
    /// the list (`_openFills`), holds a batch segment's records as it holds a position segment's.
    function test_batch_segment_longest() public {
        uint256 n = 1_680;
        address a = _maker();
        bytes memory groups;
        vm.pauseGasMetering();
        vm.startPrank(a);
        for (uint256 s; s < n; ++s) {
            _mb(c, OloOps.postW(false, uint16(s), T + 1, 1 * LOT, 4)); // asks at T + 1 .. T + 4, a LOT each
        }
        vm.stopPrank();
        for (uint256 s; s < n; ++s) {
            groups = bytes.concat(groups, OloOps.slotGroupAt(a, uint16(s), 0xf, T + 4));
        }
        vm.resumeGasMetering();
        assertEq(groups.length, 65_520, "the longest batch segment");
        vm.recordLogs();
        vm.prank(taker);
        (uint256 filled,) =
            book.take(OloOps.key(c), OloOps.batchList(groups), OloOps.tagW(c, OloOps.takeW(true, 4 * n * LOT, 0)));
        assertEq(filled, 4 * n * LOT, "every sub-order filled");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory fills;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IOloBookBase.Take.selector) {
                (,,,, fills) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bytes));
            }
        }
        assertEq(fills.length, 4 + 47 * n, "one segment");
        assertEq(uint8(fills[0]), 1, "of batch groups");
        assertEq(_u24(fills, 1), 78_960, "its length, past 16 bits");
        // the last group: the maker, slot 1,679, four records, the last index 3, q 0, a LOT
        uint256 last = 4 + 47 * (n - 1);
        bytes memory tail = new bytes(47);
        for (uint256 k; k < 47; ++k) {
            tail[k] = fills[last + k];
        }
        assertEq(tail, bytes.concat(abi.encodePacked(a, uint16(n - 1), uint8(4)), _records()));
    }

    /// Four batch fill records of a LOT at q 0, indices 0 .. 3.
    function _records() internal pure returns (bytes memory r) {
        for (uint256 i; i < 4; ++i) {
            r = bytes.concat(r, abi.encodePacked(uint8(i), uint8(0), uint32(LOT)));
        }
    }
}

library BatchLibView {
    function sub0(uint256 word) internal pure returns (uint256) {
        return (word >> 2) & ((1 << 61) - 1);
    }
}
