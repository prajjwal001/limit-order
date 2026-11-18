// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {OloOps} from "./OloOps.sol";
import {PoolTakeRef} from "./PoolTakeRef.sol";

using MarketLib for MarketWord;

/// The position segment's loop held to its plainest reference (PoolTakeRef.sol): random pool orders of both sides,
/// q 0 to 4, on both sides of a decade boundary (T), in a few positions (placed, partly taken, modified, cancelled,
/// re-placed), then random takes whose entries name them at their tick, a tick either side, a tick past every price,
/// tick 0 or a stale one, a dead or never-used position, and the same position twice. After every take: the same
/// words, the same fills in the Take event (pos | q | units), the same quote (the exact sum rounded once) and fee, and
/// fill-or-kill's verdict (what is left at most maxLeft); on two markets (50 and 300 ppm). Quote mode has its own
/// differential suite against a wide-arithmetic reference (OloQuoteRef.t.sol).
contract OloPoolTakeRefTest is OloBase {
    MarketWord[2] cs;
    address[3] mk;
    uint32 constant NPOS = 8;
    uint256 constant STEPS = 40;
    uint256 takesFilled; // takes that filled something, fill-or-kill reverts and q > 0 fills seen (coverage)
    uint256 fokReverts;
    uint256 qFills;

    function setUp() public {
        _deploy();
        cs[0] = c;
        cs[1] = book.configOf(book.listMarketQuote(address(base), address(quote), 300, 6, 1, 0));
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
        for (uint256 i; i < 3; ++i) {
            mk[i] = _maker();
        }
    }

    function _rnd(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    /// A maker's operation on a random position: a place, a modify or a cancel (each skipped when it cannot run).
    function _makerOp(uint256 r) internal {
        MarketWord cc = cs[(r >> 100) % 2];
        address a = mk[r % 3];
        uint32 pos = uint32((r >> 8) % NPOS);
        bool bid = (r >> 16) & 1 == 1;
        uint256 tick = T - 8 + (r >> 20) % 17;
        uint256 amount = (1 + (r >> 32) % 9_999) * 10 ** ((r >> 48) % 10); // up to about 1e13: q 0 to 4
        uint256 k = (r >> 60) % 3;
        vm.prank(a);
        if (k == 0) {
            try book.place(OloOps.key(cc), OloOps.placeW(bid, tick, amount, pos, 0)) {} catch {}
        } else if (k == 1) {
            try book.modify(OloOps.key(cc), OloOps.tagW(cc, OloOps.modifyW(pos, tick, amount, 0))) {} catch {}
        } else {
            try book.cancel(OloOps.key(cc), OloOps.tagW(cc, OloOps.posW(pos, 0))) {} catch {}
        }
    }

    struct Exp {
        bytes entries;
        bytes fills;
        uint256 left;
        uint256 num; // the exact quote x 10^13: sum of amount x mantissa x 10^(d - 30)
        uint256 count;
    }

    function _take(uint256 r) internal {
        MarketWord cc = cs[(r >> 100) % 2];
        bool buy = r & 1 == 1;
        uint256 amount = (1 + (r >> 1) % 9_999) * 10 ** ((r >> 20) % 8);
        bool fok = (r >> 30) % 3 == 0;
        // fill-or-kill's tolerance: strict, or up to about the amount
        uint256 maxLeft = (r >> 32) % 4 == 0 ? 0 : (r >> 40) % (amount + 1);
        uint256 n = 1 + (r >> 8) % 10;
        // the reference's view of the positions, updated as its entries fill (a position named twice reads its fills)
        uint256[NPOS + 1] memory words;
        for (uint32 p; p <= NPOS; ++p) {
            words[p] = book.orderWord(cc, p);
        }
        Exp memory x;
        x.left = amount;
        for (uint256 e; e < n; ++e) {
            uint256 re = _rnd(r, e);
            uint32 pos = uint32(re % (NPOS + 1)); // NPOS: never used
            uint256 t = words[pos] & 0x3ffffff;
            if (t == 0) t = T;
            uint256 q = (re >> 8) % 7;
            uint256 seen = q == 0 ? (buy ? PriceGrid.MAX_TICK : 1) : q == 1 ? t - 1 : q == 2 ? t + 1 : q == 3 ? 0 : t;
            x.entries = bytes.concat(x.entries, OloOps.poolEntry(pos, seen));
            if (x.left == 0) continue; // the OLO EVM contract stops walking once nothing is wanted
            (uint256 next, uint256 units, uint256 got,) = PoolTakeRef.fillEntry(words[pos], seen, buy, x.left);
            words[pos] = next;
            if (units == 0) continue;
            x.left -= got;
            (uint256 d, uint256 mant) = PriceGrid.split(next & 0x3ffffff);
            x.num += got * mant * 10 ** (d - 30);
            x.fills = bytes.concat(x.fills, abi.encodePacked(pos, uint8((next >> 26) & 0x7f), uint32(units)));
            if ((next >> 26) & 0x7f != 0) ++qFills;
            ++x.count;
        }
        if (x.fills.length != 0) x.fills = bytes.concat(abi.encodePacked(uint8(0), uint24(x.fills.length)), x.fills);
        uint256 quoteX = buy ? (x.num + 1e13 - 1) / 1e13 : x.num / 1e13;
        uint256 feeX = (x.num * cc.feePpm() + 1e19 - 1) / 1e19;
        bytes memory list = OloOps.poolList(x.entries);
        uint8 mode = fok ? 0x80 : 0;
        uint256 params = OloOps.takeW(buy, amount, mode, maxLeft);
        if (!buy && x.count != 0 && feeX >= quoteX) {
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.SellBelowFee.selector);
            book.take(OloOps.key(cc), list, OloOps.tagW(cc, params));
            return;
        }
        if (fok && x.left > maxLeft) {
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.FokNotFilled.selector);
            book.take(OloOps.key(cc), list, OloOps.tagW(cc, params));
            ++fokReverts;
            return;
        }
        vm.recordLogs();
        vm.prank(taker);
        (uint256 f, uint256 qa) = book.take(OloOps.key(cc), list, OloOps.tagW(cc, params));
        assertEq(f, amount - x.left, "filled");
        if (x.count != 0) assertEq(qa, buy ? quoteX + feeX : quoteX - feeX, "the quote with the fee");
        for (uint32 p; p <= NPOS; ++p) {
            assertEq(book.orderWord(cc, p), words[p], "a position's word after the take");
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seenTake;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IOloBookBase.Take.selector) continue;
            (uint256 packed, uint256 b_, uint256 q_, uint256 fee_, bytes memory fills) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bytes));
            assertEq(packed >> 8, x.count, "the fills' count");
            assertEq(b_, amount - x.left, "the base");
            assertEq(fills, x.fills, "the fill records");
            assertEq(q_, quoteX, "the quote");
            assertEq(fee_, feeX, "the fee");
            seenTake = true;
        }
        assertEq(seenTake, x.count != 0, "a Take iff fills");
        if (x.count != 0) ++takesFilled;
    }

    /// The fuzz reaches what it means to: takes that fill, q > 0 fills, fill-or-kill reverts.
    function test_reference_reaches_fills() public {
        for (uint256 s; s < 4; ++s) {
            testFuzz_pool_takes_match_the_reference(uint256(keccak256(abi.encode("ref", s))));
        }
        emit log_named_uint("takes that filled", takesFilled);
        emit log_named_uint("q > 0 fills", qFills);
        emit log_named_uint("fill-or-kill reverts", fokReverts);
        assertGt(takesFilled, 10);
        assertGt(qFills, 2);
        assertGt(fokReverts, 2);
    }

    function testFuzz_pool_takes_match_the_reference(uint256 seed) public {
        for (uint256 step; step < STEPS; ++step) {
            uint256 r = _rnd(seed, step);
            if (r % 3 == 0) _take(r >> 2);
            else _makerOp(r >> 2);
        }
        _solvent();
    }
}
