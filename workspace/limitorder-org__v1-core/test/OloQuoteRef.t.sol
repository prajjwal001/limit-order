// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {TakeRef} from "./TakeRef.sol";
import {U512, Wide} from "./utils/Wide.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";

/// The take's money held to a brute-force reference (TakeRef.sol: every fill's exact quote over one denominator,
/// 10^43, in 512-bit integers; quote mode's units by binary search on the budget as specified). Random pool orders and
/// batch slots of both sides, q 0 to 13, on both sides of five decade boundaries (decades 11/12, 28/29, 37/38, 42/43
/// and 49/50: fractions of a quote wei below 43, whole numbers from it), on six markets (fees 0, 50, 3,000, 500,000,
/// 999,939 and 1,000,000 ppm: the largest the OLO EVM contract lists); then random takes, base and quote mode, buys and sells, over
/// lists that mix pool entries and batch groups, name orders at their tick, either side of it, past every price, at a
/// stale tick, dead or never used, and twice; fill-or-kill with random tolerances. After every take: the same verdict
/// (FokNotFilled, SellBelowFee, AmountOverflow where a sell's budget passes 2^126 (TakeRef.budgetRefused), or success), the same base, quote, fee and quote amount, the same fill records, the same
/// words; quote mode never pays or receives more than its amount, and leaves less than one unit with its fee where the
/// budget stopped the walk (plus 1 wei for a buy, 2 for a sell). A take's decades span at most 39 here (the contract
/// reverts AmountOverflow only past some 25 decades of the largest amounts; amounts here are below 2^50).
contract OloQuoteRefTest is OloBase {
    uint256 constant NPOS = 10;
    uint256 constant NSLOT = 2;
    uint256 constant STEPS = 36;
    uint256[6] FEES = [uint256(0), 50, 3_000, 500_000, 999_939, 1_000_000];
    uint256[5] DECADES = [uint256(12), 29, 38, 43, 50];

    MarketWord[6] cs;
    address[3] mk;

    // the reference's view of the OLO EVM contract during a take: each market's pool words and each maker's slots' main
    // words
    uint256[NPOS + 1] pw;
    uint256[NSLOT][3] sw;

    // coverage
    uint256 quoteFills;
    uint256 quoteStops;
    uint256 multiDecade;
    uint256 fokReverts;
    uint256 belowFee;
    uint256 batchFills;
    uint256 fullFeeSells; // sells refused SellBelowFee on the 100% market
    uint256 fullFeeEmptySells; // quote-mode sells there that filled nothing and succeeded
    uint256 budgetRefusals;

    function setUp() public {
        _deploy();
        for (uint256 i; i < 6; ++i) {
            cs[i] = book.configOf(book.listMarketQuote(address(base), address(quote), uint24(FEES[i]), 6, 0, 0));
        }
        _fund(taker);
        for (uint256 i; i < 3; ++i) {
            mk[i] = _maker();
            _fund(mk[i]);
        }
    }

    /// Half of what an account holds, of both tokens, so proceeds have room: bids at decade 50 escrow up to about 10^31
    /// quote wei each.
    function _fund(address a) internal {
        base.mint(a, 1e39);
        quote.mint(a, 1e39);
        vm.startPrank(a);
        base.approve(address(book), type(uint256).max);
        quote.approve(address(book), type(uint256).max);
        book.deposit(address(base), (1 << 127) - book.balanceOf(baseId, a));
        book.deposit(address(quote), (1 << 127) - book.balanceOf(quoteId, a));
        vm.stopPrank();
    }

    function _rnd(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    /// A tick within 8 of a decade boundary, on either side.
    function _tick(uint256 r) internal view returns (uint256) {
        return DECADES[r % 5] * PriceGrid.PER_DECADE - 8 + (r >> 8) % 17;
    }

    /// 1 to 9,999 times 10^0 .. 10^13: q 0 to about 13.
    function _amount(uint256 r) internal pure returns (uint256) {
        return (1 + r % 9_999) * 10 ** ((r >> 16) % 14);
    }

    /// A maker's operation: a place, modify or cancel in a pool position, or a post, replace or cancel in a slot.
    function _makerOp(uint256 r) internal {
        MarketWord cc = cs[(r >> 200) % 6];
        address a = mk[r % 3];
        uint256 k = (r >> 4) % 6;
        bool bid = (r >> 8) & 1 == 1;
        vm.startPrank(a);
        if (k <= 1) {
            try book.place(
                OloOps.key(cc), OloOps.placeW(bid, _tick(r >> 16), _amount(r >> 40), uint32((r >> 80) % NPOS), 0)
            ) {}
                catch {}
        } else if (k == 2) {
            try book.modify(
                OloOps.key(cc),
                OloOps.tagW(cc, OloOps.modifyW(uint32((r >> 80) % NPOS), _tick(r >> 16), _amount(r >> 40), 0))
            ) {}
                catch {}
        } else if (k == 3) {
            try book.cancel(OloOps.key(cc), OloOps.tagW(cc, OloOps.posW(uint32((r >> 80) % NPOS), 0))) {} catch {}
        } else {
            uint256[4] memory o;
            for (uint256 i; i < 4; ++i) {
                uint256 ri = _rnd(r, i);
                if (ri % 5 != 0) o[i] = OloOps.sub(_tick(ri), _amount(ri >> 32));
            }
            uint8 kind = k == 4 ? OloOps.REPLACE : OloOps.CANCEL;
            uint16 slot = uint16((r >> 90) % NSLOT);
            uint256[3] memory w =
                kind == OloOps.CANCEL ? OloOps.maskW(kind, slot, 0, 0xf) : OloOps.batchW(kind, bid, slot, 0, 0, o);
            (bool ok,) = address(book).call(OloOps.batchCalldata(book.manageBatchSubs.selector, cc, w));
            if (!ok && kind == OloOps.REPLACE) {
                (ok,) = address(book)
                    .call(
                        OloOps.batchCalldata(
                            book.manageBatchSubs.selector, cc, OloOps.batchW(OloOps.POST, bid, slot, 0, 0, o)
                        )
                    );
            }
        }
        vm.stopPrank();
    }

    /// An entry's tick: mostly the order's own; else either side of it, past every price, 0, or another order's.
    function _seen(uint256 r, uint256 tick, bool buy) internal view returns (uint256) {
        uint256 k = r % 12;
        if (tick == 0) tick = _tick(r >> 8);
        if (k == 0) return buy ? PriceGrid.MAX_TICK : 1;
        if (k == 1) return tick - 1;
        if (k == 2) return tick + 1;
        if (k == 3) return 0;
        if (k == 4) return _tick(r >> 8);
        return tick;
    }

    struct Exp {
        bytes poolFills; // the open pool segment's records
        bytes batchFills; // the open batch segment's groups
        bytes fills; // the closed segments
        bytes list;
        uint256 lastDecade;
        bool decades;
        bool refused; // a sell's budget past 2^126, refused at the first order the walk reaches (nothing fills after)
    }

    function _closePool(Exp memory e) internal pure {
        if (e.poolFills.length != 0) {
            e.fills = bytes.concat(e.fills, abi.encodePacked(uint8(0), uint24(e.poolFills.length)), e.poolFills);
        }
        e.poolFills = "";
    }

    function _closeBatch(Exp memory e) internal pure {
        if (e.batchFills.length != 0) {
            e.fills = bytes.concat(e.fills, abi.encodePacked(uint8(1), uint24(e.batchFills.length)), e.batchFills);
        }
        e.batchFills = "";
    }

    /// A pool segment of `n` entries, filled by the reference as the OLO EVM contract walks it.
    function _poolSegment(uint256 r, uint256 n, TakeRef.Walk memory w, TakeRef.Take memory t, Exp memory e) internal {
        bytes memory entries;
        for (uint256 j; j < n; ++j) {
            uint256 rj = _rnd(r, j);
            // mostly a live order on the other side, else any position (NPOS: never used)
            uint32 pos = uint32(rj % (NPOS + 1));
            if ((rj >> 200) % 4 != 0) {
                for (uint256 k; k < NPOS; ++k) {
                    uint32 p = uint32((pos + k) % NPOS);
                    if ((pw[p] >> 33) & ((1 << 30) - 1) != 0 && ((pw[p] >> 93) & 1 == 1) != t.buy) {
                        pos = p;
                        break;
                    }
                }
            }
            uint256 word = pw[pos];
            uint256 tick = word & 0x3ffffff;
            uint256 seen = _seen(rj >> 8, tick, t.buy);
            entries = bytes.concat(entries, OloOps.poolEntry(pos, seen));
            uint256 open = (word >> 33) & ((1 << 30) - 1);
            bool isBid = (word >> 93) & 1 == 1;
            if (open == 0 || isBid == t.buy || (t.buy ? tick > seen : tick < seen)) continue;
            if (_refused(t, e)) continue;
            uint256 q = (word >> 26) & 0x7f;
            uint256 x = TakeRef.fill(w, t, open, q, tick);
            if (x == 0) continue;
            pw[pos] = word - (x << 33) + (x << 63);
            e.poolFills = bytes.concat(e.poolFills, abi.encodePacked(pos, uint8(q), uint32(x)));
            _noteDecade(e, tick);
        }
        e.list = bytes.concat(e.list, OloOps.poolList(entries));
        _closePool(e);
    }

    /// A batch segment of `n` groups.
    function _batchSegment(uint256 r, uint256 n, TakeRef.Walk memory w, TakeRef.Take memory t, Exp memory e) internal {
        bytes memory groups;
        for (uint256 j; j < n; ++j) {
            uint256 rj = _rnd(r, 100 + j);
            uint256 mi = rj % 3;
            uint16 slot = uint16((rj >> 4) % NSLOT);
            uint8 mask = uint8(1 + (rj >> 8) % 15);
            uint256 word = sw[mi][slot];
            uint256[4] memory ticks;
            for (uint256 i; i < 4; ++i) {
                ticks[i] = _seen(_rnd(rj, i), (word >> (2 + 61 * i)) & 0x3ffffff, t.buy);
            }
            groups = bytes.concat(groups, OloOps.slotGroup(mk[mi], slot, mask, ticks));
            bytes memory recs;
            for (uint256 i; i < 4; ++i) {
                if ((mask >> i) & 1 == 0) continue;
                if (((word >> (246 + i)) & 1 == 1) == t.buy) continue; // on the taker's own side: its side bit D_i
                uint256 sub = (word >> (2 + 61 * i)) & ((1 << 61) - 1);
                uint256 open = sub >> 31;
                uint256 tick = sub & 0x3ffffff;
                if (open == 0 || (t.buy ? tick > ticks[i] : tick < ticks[i])) continue;
                if (_refused(t, e)) continue;
                uint256 q = (sub >> 26) & 0x1f;
                uint256 x = TakeRef.fill(w, t, open, q, tick);
                if (x == 0) continue;
                word -= x << (2 + 61 * i + 31);
                recs = bytes.concat(recs, abi.encodePacked(uint8(i), uint8(q), uint32(x)));
                _noteDecade(e, tick);
                ++batchFills;
            }
            sw[mi][slot] = word;
            if (recs.length != 0) {
                e.batchFills = bytes.concat(e.batchFills, abi.encodePacked(mk[mi], slot, uint8(recs.length / 6)), recs);
            }
        }
        e.list = bytes.concat(e.list, OloOps.batchList(groups));
        _closeBatch(e);
    }

    /// What the pool orders a take of this side consumes hold: their open base, or (quote) its quote rounded down.
    function _held(MarketWord cc, bool buy, bool inQuote) internal view returns (uint256 total) {
        for (uint32 p; p < NPOS; ++p) {
            uint256 word = book.orderWord(cc, p);
            uint256 open = (word >> 33) & ((1 << 30) - 1);
            if (open == 0 || ((word >> 93) & 1 == 1) == buy) continue;
            uint256 amount = open * 10 ** ((word >> 26) & 0x7f);
            total += inQuote ? PriceGrid.quoteDown(amount, word & 0x3ffffff) : amount;
        }
    }

    /// Whether the walk has met a budget the OLO EVM contract refuses (TakeRef.budgetRefused), checked at each order
    /// it reaches: the first one decides, and nothing fills after it.
    function _refused(TakeRef.Take memory t, Exp memory e) internal pure returns (bool) {
        if (!e.refused && TakeRef.budgetRefused(t)) e.refused = true;
        return e.refused;
    }

    function _noteDecade(Exp memory e, uint256 tick) internal pure {
        uint256 d = tick / PriceGrid.PER_DECADE + 1; // + 1: 0 is "none yet"
        if (e.lastDecade != 0 && e.lastDecade != d) e.decades = true;
        e.lastDecade = d;
    }

    function _take(uint256 r) internal {
        uint256 mi = (r >> 200) % 6;
        MarketWord cc = cs[mi];
        TakeRef.Take memory t;
        t.buy = r & 1 == 1;
        t.inQuote = (r >> 1) % 2 == 0;
        t.feePpm = FEES[mi];
        // the reference's view of the market before the take
        for (uint32 p; p <= NPOS; ++p) {
            pw[p] = book.orderWord(cc, p);
        }
        // the amount: mostly 1% to 150% of what the other side's pool orders hold (base) or are worth (quote, rounded
        // down per order), so takes fill and stop short; else any size, base up to about 10^14 and quote up to about
        // 10^33 (below 2^112)
        uint256 held = _held(cc, t.buy, t.inQuote);
        if ((r >> 8) % 4 != 0 && held != 0) {
            t.amount = 1 + held * (1 + (r >> 16) % 150) / 100;
            if (t.amount >= 1 << 112) t.amount = (1 << 112) - 1;
        } else {
            t.amount = (1 + (r >> 8) % 9_999) * 10 ** ((r >> 24) % (t.inQuote ? 30 : 11));
        }
        bool fok = (r >> 40) % 5 == 0;
        uint256 maxLeft = (r >> 44) % 4 == 0 ? 0 : (r >> 48) % (t.amount + 1);
        if (maxLeft >= 1 << 77) maxLeft = (1 << 77) - 1;
        for (uint256 i; i < 3; ++i) {
            for (uint256 s; s < NSLOT; ++s) {
                (sw[i][s],) = book.batchOf(cc, mk[i], uint16(s));
            }
        }
        TakeRef.Walk memory w;
        Exp memory e;
        uint256 segs = 1 + (r >> 120) % 3;
        for (uint256 s; s < segs; ++s) {
            uint256 rs = _rnd(r, 1000 + s);
            if (rs % 2 == 0) _poolSegment(rs, 1 + (rs >> 8) % 8, w, t, e);
            else _batchSegment(rs, 1 + (rs >> 8) % 3, w, t, e);
        }
        (uint256 q, uint256 fee, uint256 qa, bool below) = TakeRef.finish(w, t);
        uint256 left;
        if (w.count == 0) left = t.amount;
        else if (!t.inQuote) left = t.amount - w.base;
        else if (!below) left = t.amount - qa; // reverts (a failed test) if the reference itself overran the amount
        uint8 mode = (fok ? OloOps.FOK : 0) | (t.inQuote ? OloOps.QUOTE : 0);
        uint256 params = OloOps.takeW(t.buy, t.amount, mode, maxLeft);
        if (e.refused) {
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.AmountOverflow.selector);
            book.take(OloOps.key(cc), e.list, OloOps.tagW(cc, params));
            ++budgetRefusals;
            return;
        }
        if (w.count != 0 && below) {
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.SellBelowFee.selector);
            book.take(OloOps.key(cc), e.list, OloOps.tagW(cc, params));
            ++belowFee;
            if (t.feePpm == 1_000_000) ++fullFeeSells;
            return;
        }
        if (fok && left > maxLeft) {
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.FokNotFilled.selector);
            book.take(OloOps.key(cc), e.list, OloOps.tagW(cc, params));
            ++fokReverts;
            return;
        }
        uint256 b0 = _bal(taker, base);
        uint256 q0 = _bal(taker, quote);
        vm.recordLogs();
        vm.prank(taker);
        (uint256 gotBase, uint256 gotQuote) = book.take(OloOps.key(cc), e.list, OloOps.tagW(cc, params));
        assertEq(gotBase, w.base, "base");
        assertEq(gotQuote, qa, "quote amount");
        if (t.buy) {
            assertEq(_bal(taker, base) - b0, gotBase, "base in");
            assertEq(q0 - _bal(taker, quote), gotQuote, "quote out");
        } else {
            assertEq(b0 - _bal(taker, base), gotBase, "base out");
            assertEq(_bal(taker, quote) - q0, gotQuote, "quote in");
        }
        if (t.inQuote) {
            assertLe(gotQuote, t.amount, "quote mode: never more than the amount");
            assertTrue(TakeRef.leftWithinOneUnit(w, t, t.amount - gotQuote), "quote mode: less than a unit left");
            if (w.count != 0) ++quoteFills;
            if (w.stopped) ++quoteStops;
            if (!t.buy && t.feePpm == 1_000_000) ++fullFeeEmptySells;
        } else {
            assertLe(gotBase, t.amount, "base mode: never more than the amount");
        }
        if (e.decades) ++multiDecade;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seenTake;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IOloBookBase.Take.selector) continue;
            (uint256 packed, uint256 b_, uint256 q_, uint256 fee_, bytes memory fills) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bytes));
            assertEq(packed, (t.buy ? 1 : 0) | (w.count << 8), "packed");
            assertEq(b_, w.base, "the event's base");
            assertEq(q_, q, "the quote: the exact sum rounded once");
            assertEq(fee_, fee, "the fee: on the exact sum, rounded up");
            assertEq(fills, e.fills, "the fill records");
            seenTake = true;
        }
        assertEq(seenTake, w.count != 0, "a Take iff fills");
        for (uint32 p; p <= NPOS; ++p) {
            assertEq(book.orderWord(cc, p), pw[p], "a position's word");
        }
        for (uint256 i; i < 3; ++i) {
            for (uint256 s; s < NSLOT; ++s) {
                (uint256 word,) = book.batchOf(cc, mk[i], uint16(s));
                assertEq(word, sw[i][s], "a slot's main word");
            }
        }
    }

    /// The fuzz reaches what it means to: quote-mode takes that fill and that stop short on the budget, takes across
    /// decades, batch fills, fill-or-kill reverts (sells below their fee are rare here: OloQuote.t.sol has them).
    function test_reference_reaches_everything() public {
        for (uint256 s; s < 12; ++s) {
            testFuzz_takes_match_the_reference(uint256(keccak256(abi.encode("quote-ref", s))));
        }
        emit log_named_uint("quote-mode takes that filled", quoteFills);
        emit log_named_uint("quote-mode takes stopped short by the budget", quoteStops);
        emit log_named_uint("takes across decades", multiDecade);
        emit log_named_uint("batch sub-order fills", batchFills);
        emit log_named_uint("fill-or-kill reverts", fokReverts);
        emit log_named_uint("sells below their fee", belowFee);
        emit log_named_uint("sells refused at a fee of 100%", fullFeeSells);
        emit log_named_uint("quote-mode sells at 100% that filled nothing", fullFeeEmptySells);
        emit log_named_uint("budgets past 2^126 refused", budgetRefusals);
        assertGt(quoteFills, 15);
        assertGt(quoteStops, 8);
        assertGt(multiDecade, 10);
        assertGt(batchFills, 15);
        assertGt(fokReverts, 5);
        assertGt(fullFeeSells, 0);
        assertGt(fullFeeEmptySells, 0);
    }

    /// The reference's 512-bit arithmetic against itself and 256-bit arithmetic: a full product divided back, sums
    /// and differences undone, small products as Solidity computes them, 10^e step by step.
    function testFuzz_wide_arithmetic(uint256 a, uint256 b, uint256 e) public pure {
        U512 memory p = Wide.mul(a, b);
        if (b != 0 && b < 1 << 255) {
            (U512 memory back, uint256 r) = Wide.divRem(p, b);
            assertTrue(Wide.eq(back, Wide.from(a)), "a x b / b");
            assertEq(r, 0);
        }
        if (a < 1 << 128 && b < 1 << 128) {
            assertEq(p.hi, 0);
            assertEq(p.lo, a * b);
        }
        U512 memory s = Wide.add(p, Wide.from(b));
        assertTrue(Wide.eq(Wide.sub(s, Wide.from(b)), p), "(p + b) - b");
        assertTrue(Wide.lt(p, s) || b == 0, "p < p + b");
        e = bound(e, 1, 150);
        assertTrue(Wide.eq(Wide.mul(Wide.pow10(e - 1), 10), Wide.pow10(e)), "10^e");
        if (e <= 76) assertEq(Wide.toUint(Wide.pow10(e)), 10 ** e);
    }

    function testFuzz_takes_match_the_reference(uint256 seed) public {
        for (uint256 step; step < STEPS; ++step) {
            uint256 r = _rnd(seed, step);
            if (r % 3 == 0) _take(r >> 2);
            else _makerOp(r >> 2);
        }
        _solvent();
    }
}
