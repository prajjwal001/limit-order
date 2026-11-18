// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";

using MarketLib for MarketWord;

/// The makers' floor and takeThenRest's limit check (I-1). Makers rest at decade 4 or above
/// (PriceGrid.MIN_MAKER_TICK, 3,600,000, P = 1e-34): every maker entry refuses a tick below it, takers' entry ticks are
/// not held to it. A take's exact sum is aligned to the lowest decade a fill reaches, and fills are at makers' ticks,
/// so a maker repricing a listed order down can push the alignment to decade 4 and no lower: a take reverts
/// AmountOverflow only once Q x 10^39 reaches 2^235, Q at least 2^235 / 10^39 = 5.52e31 quote wei. Below that a
/// griefer's reprice is harmless; above it, it denies the caller's take (no funds move), the known issue the docs
/// record. `_accrue`'s three bounds each stop the take they alone can stop. And a takeThenRest with a remainder checks
/// its limit as a maker's tick before it values the remainder.
contract OloMakerFloorTest is OloBase {
    uint256 constant FLOOR = 3_600_000;
    uint256 constant TOP = 65_700_000; // decade 73, mantissa 100,000: P = 1e35
    MockERC20 x;
    MockERC20 y;
    MarketWord c0; // X/Y, 18/18 decimals, 200 ppm, 6 figures, minQuote 0
    MarketWord c1; // the same with minQuote 1
    address griefer = address(0xA11CE);
    address honest = address(0xB0B);

    function setUp() public {
        _deploy();
        x = new MockERC20("X", "X", 18);
        y = new MockERC20("Y", "Y", 18);
        c0 = book.configOf(book.listMarketQuote(address(x), address(y), 200, 6, 0, 0));
        c1 = book.configOf(book.listMarketQuote(address(x), address(y), 200, 6, 1, 0));
        _fund(griefer);
        _fund(honest);
        _fund(taker);
    }

    function _fund(address a) internal {
        x.mint(a, 1e40);
        y.mint(a, 1e40);
        vm.startPrank(a);
        x.approve(address(book), type(uint256).max);
        y.approve(address(book), type(uint256).max);
        vm.stopPrank();
    }

    function test_the_floor_is_decade_4() public pure {
        assertEq(PriceGrid.MIN_MAKER_TICK, FLOOR);
        (uint256 d, uint256 m) = PriceGrid.split(FLOOR);
        assertEq(d, 4);
        assertEq(m, 100_000);
        assertEq(PriceGrid.quoteDown(1e34, FLOOR), 1, "1e34 base wei at the floor is a quote wei");
        assertEq(FLOOR % 1000, 0, "on every spacing");
    }

    /// Every maker entry refuses a tick below the floor (tick 1 and the floor's tick less one), with the same order at
    /// the floor resting: place, modify, a multicall's PLACE and MODIFY, a batch post, replace and modify, and a
    /// takeThenRest's rest.
    function test_every_maker_entry_refuses_a_tick_below_the_floor() public {
        uint256[2] memory below = [uint256(1), FLOOR - 1];
        vm.startPrank(griefer);
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
            book.place(OloOps.key(c0), OloOps.placeW(false, below[i], 1, 1, 0x02));
            vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
            book.multicall(0x02, bytes.concat(OloOps.header(c0), OloOps.place(0, below[i], false, 1, 1)));
            vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
            _mb(c0, OloOps.batchW(OloOps.POST, false, 0, 0x02, 0, [OloOps.sub(below[i], 1), 0, 0, 0]));
        }
        // at the floor: a place, a batch post
        book.place(OloOps.key(c0), OloOps.placeW(false, FLOOR, 1, 1, 0x02));
        _mb(c0, OloOps.batchW(OloOps.POST, false, 0, 0x02, 0, [OloOps.sub(FLOOR, 1), 0, 0, 0]));
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
            book.modify(OloOps.key(c0), OloOps.tagW(c0, OloOps.modifyW(1, below[i], 1, 0x02)));
            vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
            book.multicall(0x02, bytes.concat(OloOps.header(c0), OloOps.modify(0, 1, below[i], 1)));
            vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
            _mb(c0, OloOps.batchW(OloOps.REPLACE, false, 0, 0x02, 0, [OloOps.sub(below[i], 1), 0, 0, 0]));
            vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
            _mb(c0, OloOps.batchW(OloOps.MODIFY, false, 0, 0x02, 0x1, [OloOps.sub(below[i], 2), 0, 0, 0]));
        }
        vm.stopPrank();
        // a takeThenRest with nothing to take rests all of its amount: below the floor, refused
        vm.startPrank(taker);
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
            book.takeThenRest(OloOps.key(c0), "", OloOps.tagW(c0, OloOps.restW(true, 5, below[i], OloOps.WALLET, 9)));
        }
        (,, uint256 rested, uint256 restId) =
            book.takeThenRest(OloOps.key(c0), "", OloOps.tagW(c0, OloOps.restW(true, 5, FLOOR, OloOps.WALLET, 9)));
        vm.stopPrank();
        assertEq(rested, 5);
        assertEq(uint32(restId), 9, "the position the rest landed in");
    }

    /// Takers' entry ticks are not held to the floor: a sell naming a bid at tick 1 (the least it accepts) fills it, a
    /// buy naming tick 1 (the most it pays) simply finds no ask that cheap.
    function test_entry_ticks_are_not_held_to_the_floor() public {
        vm.prank(honest);
        book.place(OloOps.key(c0), OloOps.placeW(true, T, 1e18, 1, 0x02));
        vm.prank(honest);
        book.place(OloOps.key(c0), OloOps.placeW(false, T + 1, 1e18, 2, 0x02));
        vm.startPrank(taker);
        (uint256 sold,) = book.take(
            OloOps.key(c0),
            OloOps.poolList(OloOps.poolEntry(1, 1)),
            OloOps.tagW(c0, OloOps.takeW(false, 1e18, OloOps.WALLET))
        );
        assertEq(sold, 1e18);
        (uint256 bought,) = book.take(
            OloOps.key(c0),
            OloOps.poolList(OloOps.poolEntry(2, 1)),
            OloOps.tagW(c0, OloOps.takeW(true, 1e18, OloOps.WALLET))
        );
        assertEq(bought, 0, "an ask above the entry's tick is skipped");
        vm.stopPrank();
    }

    /// The griefing attack the floor answers. The honest maker rests `size` base wei at P = 1 (tick T, decade 38),
    /// the griefer 1 wei beside it; a taker lists both. The griefer reprices to tick 1 (refused now) or to the floor
    /// (decade 4, "a better tick fills there"), which drags the take's alignment to decade 4: the sum is then Q x
    /// 10^39. A take of 5.52e31 quote wei fills, one of 5.53e31 reverts AmountOverflow (2^235 / 10^39 = 5.5214e31),
    /// in base mode and in quote mode, the griefer's order in the list first or last. Nothing moves when it reverts.
    function test_a_reprice_to_the_floor_denies_only_takes_past_the_threshold() public {
        bytes memory list = OloOps.poolList(bytes.concat(OloOps.poolEntry(1, T), OloOps.poolEntry(2, T)));
        bytes memory listRev = OloOps.poolList(bytes.concat(OloOps.poolEntry(2, T), OloOps.poolEntry(1, T)));
        uint256[2] memory sizes = [uint256(5.52e31), 5.53e31];
        for (uint256 k; k < 2; ++k) {
            uint256 snap = vm.snapshotState();
            vm.prank(griefer);
            book.place(OloOps.key(c0), OloOps.placeW(false, T, 1, 1, 0x02));
            vm.prank(honest);
            book.place(OloOps.key(c0), OloOps.placeW(false, T, sizes[k], 2, 0x02));
            // the reprice to the grid's bottom is refused; to the floor it goes through
            vm.prank(griefer);
            vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
            book.modify(OloOps.key(c0), OloOps.tagW(c0, OloOps.modifyW(1, 1, 1, 0x02)));
            vm.prank(griefer);
            book.modify(OloOps.key(c0), OloOps.tagW(c0, OloOps.modifyW(1, FLOOR, 1, 0x02)));
            bytes[2] memory lists = [list, listRev];
            for (uint256 j; j < 2; ++j) {
                uint256 s2 = vm.snapshotState();
                uint256 y0 = y.balanceOf(taker);
                vm.prank(taker);
                if (k == 0) {
                    (uint256 got,) = book.take(
                        OloOps.key(c0), lists[j], OloOps.tagW(c0, OloOps.takeW(true, sizes[k] + 1, OloOps.WALLET))
                    );
                    assertEq(got, sizes[k] + 1, "under the threshold: fills both");
                } else {
                    vm.expectRevert(IOloBookBase.AmountOverflow.selector);
                    book.take(
                        OloOps.key(c0), lists[j], OloOps.tagW(c0, OloOps.takeW(true, sizes[k] + 1, OloOps.WALLET))
                    );
                    assertEq(y.balanceOf(taker), y0, "nothing moves");
                }
                vm.revertToState(s2);
                // quote mode: a budget past both orders' worth
                vm.prank(taker);
                if (k == 0) {
                    (uint256 got,) =
                        book.take(OloOps.key(c0), lists[j], OloOps.tagW(c0, OloOps.quoteW(true, 6e31, OloOps.WALLET)));
                    assertEq(got, sizes[k] + 1, "quote mode: fills both");
                } else {
                    vm.expectRevert(IOloBookBase.AmountOverflow.selector);
                    book.take(OloOps.key(c0), lists[j], OloOps.tagW(c0, OloOps.quoteW(true, 6e31, OloOps.WALLET)));
                }
                vm.revertToState(s2);
            }
            vm.revertToState(snap);
        }
    }

    /// `_accrue`'s last bound, the sum's: behind the floor's 1 wei every fill counts at decade 4. Two fills of 3e31
    /// base wei at T are 3e31 x 10^39 = 3e70 each, below 2^235 (5.52e70) alone, so each passes the fill's own bound;
    /// together they are 6e70 and the take reverts AmountOverflow at `sum >= SUM_LIMIT`. (The reprice test above
    /// meets only the first two bounds, where this one would stop the take too.)
    function test_two_fills_past_the_sum_limit_revert() public {
        vm.prank(griefer);
        book.place(OloOps.key(c0), OloOps.placeW(false, FLOOR, 1, 1, 0x02));
        vm.startPrank(honest);
        book.place(OloOps.key(c0), OloOps.placeW(false, T, 3e31, 2, 0x02));
        book.place(OloOps.key(c0), OloOps.placeW(false, T, 3e31, 3, 0x02));
        vm.stopPrank();
        bytes memory list =
            OloOps.poolList(bytes.concat(OloOps.poolEntry(1, FLOOR), OloOps.poolEntry(2, T), OloOps.poolEntry(3, T)));
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.AmountOverflow.selector);
        book.take(OloOps.key(c0), list, OloOps.tagW(c0, OloOps.takeW(true, 6e31 + 1, OloOps.WALLET)));
    }

    /// `_accrue`'s first two bounds stop a multiply that would wrap: 570,855 base wei at decade 73 (TOP) and the
    /// floor's 1 wei are 69 decades apart. Floor first, the TOP fill is v x 10^69 with v = 5.7e10, past 2^256; TOP
    /// first, aligning its sum down to decade 4 multiplies it by 10^69 alike. Either way the take reverts
    /// AmountOverflow before the multiply, which would wrap to a sum below 2^235 that the last bound lets through.
    function test_a_multiply_that_would_wrap_reverts() public {
        vm.prank(griefer);
        book.place(OloOps.key(c0), OloOps.placeW(false, FLOOR, 1, 1, 0x02));
        vm.prank(honest);
        book.place(OloOps.key(c0), OloOps.placeW(false, TOP, 570_855, 2, 0x02));
        bytes[2] memory lists = [
            OloOps.poolList(bytes.concat(OloOps.poolEntry(1, FLOOR), OloOps.poolEntry(2, TOP))),
            OloOps.poolList(bytes.concat(OloOps.poolEntry(2, TOP), OloOps.poolEntry(1, FLOOR)))
        ];
        for (uint256 j; j < 2; ++j) {
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.AmountOverflow.selector);
            book.take(OloOps.key(c0), lists[j], OloOps.tagW(c0, OloOps.takeW(true, 570_856, OloOps.WALLET)));
        }
    }

    /// With minQuote 1 the floor is out of a griefer's reach: even the largest amount, 2^112 - 1 base wei (stored as
    /// 5.19229685e33), is worth 0.52 quote wei there. The lowest tick it rests at is 3,692,593 (mantissa 192,593,
    /// still decade 4), so the threshold is the same and the griefer posts 5.2e33 base wei of inventory to reach it.
    function test_min_quote_prices_the_griefer_in() public {
        uint256 most = (1 << 112) - 1;
        vm.startPrank(griefer);
        book.place(OloOps.key(c1), OloOps.placeW(false, T, most, 1, 0x02));
        vm.expectRevert(IOloBookBase.SizeOutOfRange.selector);
        book.modify(OloOps.key(c1), OloOps.tagW(c1, OloOps.modifyW(1, FLOOR, most, 0x02)));
        vm.expectRevert(IOloBookBase.SizeOutOfRange.selector);
        book.modify(OloOps.key(c1), OloOps.tagW(c1, OloOps.modifyW(1, 3_692_592, most, 0x02)));
        book.modify(OloOps.key(c1), OloOps.tagW(c1, OloOps.modifyW(1, 3_692_593, most, 0x02)));
        vm.stopPrank();
    }

    // -------------------------------------------------------------- takeThenRest's limit (I-1)

    /// A takeThenRest with a remainder checks its limit first, the same on a minQuote-0 and a minQuote-1 market: a
    /// limit of 0, one below the floor, one past the grid and one off a 5-figure market's spacing revert
    /// TickOutOfRange, the fills with them, whatever the remainder is worth (before the fix the minQuote-1 market kept
    /// the remainder with the taker without a word). A takeThenRest that fills everything checks no limit.
    function test_take_then_rest_checks_its_limit_first() public {
        MarketWord c5 = book.configOf(book.listMarketQuote(address(x), address(y), 200, 5, 1, 0));
        MarketWord[3] memory cs = [c0, c1, c5];
        for (uint256 i; i < 3; ++i) {
            vm.prank(honest);
            book.place(OloOps.key(cs[i]), OloOps.placeW(false, T, 100, 1, 0x02));
        }
        bytes memory list = OloOps.poolList(OloOps.poolEntry(1, T));
        uint256[4] memory bad = [uint256(0), FLOOR - 1, PriceGrid.MAX_TICK + 1, T + 1];
        for (uint256 i; i < 3; ++i) {
            for (uint256 k; k < 4; ++k) {
                if (k == 3 && i != 2) continue; // off the spacing only means something at 5 figures
                vm.prank(taker);
                vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
                book.takeThenRest(
                    OloOps.key(cs[i]), list, OloOps.tagW(cs[i], OloOps.restW(true, 1_000, bad[k], OloOps.WALLET, 7))
                );
            }
            // the remainder (900 wei at P = 1, 900 quote wei) is worth minQuote everywhere here: it rests at a good limit
            vm.prank(taker);
            (uint256 got,, uint256 rested, uint256 restId) = book.takeThenRest(
                OloOps.key(cs[i]), list, OloOps.tagW(cs[i], OloOps.restW(true, 1_000, T - 10, OloOps.WALLET, 7))
            );
            assertEq(got, 100);
            assertEq(rested, 900);
            assertEq(uint32(restId), 7, "the position the rest landed in");
        }
        // a takeThenRest that fills all of its amount rests nothing and needs no limit: limit 0 passes
        vm.prank(honest);
        book.place(OloOps.key(c1), OloOps.placeW(false, T, 100, 2, 0x02));
        vm.prank(taker);
        (uint256 all,, uint256 none,) = book.takeThenRest(
            OloOps.key(c1),
            OloOps.poolList(OloOps.poolEntry(2, T)),
            OloOps.tagW(c1, OloOps.restW(true, 100, 0, OloOps.WALLET, 8))
        );
        assertEq(all, 100);
        assertEq(none, 0);
    }

    /// takeThenRest's limit rule and its returns, fuzzed: a buy of `amount`
    /// against one ask of `askAmt` at T on 5-figure markets of minQuote 0, 1 and 1e18, with a limit anywhere in 26 bits,
    /// around the floor, around the grid's top, or a maker's tick. With anything left and the limit no maker's tick
    /// the call reverts TickOutOfRange; otherwise it rests exactly when the remainder, as stored, is worth minQuote at
    /// the limit, and returns (filled, paid, stored, position) with the rest's escrow, its stored amount's quote
    /// rounded up, pulled on top of what the fills cost, or (filled, paid, 0, 0) with nothing pulled for a rest.
    function testFuzz_take_then_rest_limit_and_returns(uint256 mi, uint256 limitSeed, uint256 amount, uint256 askAmt)
        public
    {
        MarketWord mc =
            book.configOf(book.listMarketQuote(address(x), address(y), 200, 5, [uint96(0), 1, 1e18][mi % 3], 0));
        y.mint(taker, 1e75); // a rest near the grid's top escrows up to about 1e66 quote wei
        askAmt = bound(askAmt, 1e18, 1e30); // worth minQuote 1e18 at P = 1
        amount = bound(amount, 1, 2e30);
        uint256 kind = limitSeed % 4;
        uint256 limit;
        if (kind == 0) limit = (limitSeed >> 8) % (1 << 26);
        else if (kind == 1) limit = FLOOR - 10 + ((limitSeed >> 8) % 3) * 10;
        else if (kind == 2) limit = PriceGrid.MAX_TICK - 9 + ((limitSeed >> 8) % 3) * 10;
        else limit = bound(limitSeed >> 8, FLOOR, PriceGrid.MAX_TICK) / 10 * 10;
        vm.prank(honest);
        book.place(OloOps.key(mc), OloOps.placeW(false, T, askAmt, 1, 0x02));
        // the expected walk: whole units of the ask's q, at most what it holds
        uint256 aq = _qOf(askAmt);
        uint256 units = amount / 10 ** aq;
        if (units > _storedOf(askAmt) / 10 ** aq) units = _storedOf(askAmt) / 10 ** aq;
        uint256 filled = units * 10 ** aq;
        uint256 rest = amount - filled;
        bool bad = rest != 0 && !(limit >= FLOOR && limit <= PriceGrid.MAX_TICK && limit % 10 == 0);
        uint256 stored = _storedOf(rest);
        bool rests = !bad && _worthAt(mc.minQuote(), limit, stored);
        uint256 params = OloOps.restW(true, amount, limit, OloOps.WALLET, 9);
        bytes memory list = OloOps.poolList(OloOps.poolEntry(1, T));
        uint256 y0 = y.balanceOf(taker);
        vm.prank(taker);
        if (bad) {
            vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
            book.takeThenRest(OloOps.key(mc), list, OloOps.tagW(mc, params));
            return;
        }
        (uint256 got, uint256 paid, uint256 rested, uint256 restId) =
            book.takeThenRest(OloOps.key(mc), list, OloOps.tagW(mc, params));
        assertEq(got, filled, "filled");
        if (rests) {
            assertEq(rested, stored, "rested: what the rest holds");
            assertEq(uint32(restId), 9, "the position the rest landed in");
            (uint256 tk, uint256 open,, bool isBid, address owner) = book.orderOf(mc, 9);
            assertEq(tk, limit);
            assertEq(open, stored);
            assertTrue(isBid);
            assertEq(owner, taker);
            assertEq(y0 - y.balanceOf(taker), paid + PriceGrid.quoteUp(stored, limit), "the escrow of what rests");
        } else {
            assertEq(rested, 0);
            assertEq(restId, 0, "no rest, no order id");
            assertEq(book.orderWord(mc, 9), 0, "nothing rested");
            assertEq(y0 - y.balanceOf(taker), paid, "no escrow");
        }
    }

    function _qOf(uint256 a) internal pure returns (uint256 q) {
        while (a >= 1 << 30) {
            a /= 10;
            ++q;
        }
    }

    function _storedOf(uint256 a) internal pure returns (uint256) {
        uint256 q = _qOf(a);
        return a / 10 ** q * 10 ** q;
    }

    /// `stored` base wei at `tick` worth at least `minQuote` quote wei, in integers.
    function _worthAt(uint256 minQuote, uint256 tick, uint256 stored) internal pure returns (bool) {
        if (stored == 0) return false;
        if (minQuote == 0) return true;
        uint256 d = tick / 900_000;
        uint256 v = stored * (100_000 + tick % 900_000);
        if (d >= 43) return v * 10 ** (d - 43) >= minQuote;
        return v >= minQuote * 10 ** (43 - d);
    }
}
