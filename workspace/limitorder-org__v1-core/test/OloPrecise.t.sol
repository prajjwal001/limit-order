// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {OloMath} from "../src/libraries/OloMath.sol";
import {PoolLib, PoolWord} from "../src/OloTypes.sol";

/// The precise-fills model on the pool path: amounts in base wei stored as units x 10^q, one grid for every market,
/// takes that fill any amount in whole units and round once, FOK on the last order's unit, takeThenRest with its own q,
/// minQuote. Worked examples of the design on BTC/USDC (8/6 decimals)
/// and ETH/USDC (18/6), plus both sides, wallet and account settlement, and the rounding directions.
contract OloPreciseTest is OloBase {
    MockERC20 btc;
    MockERC20 eth;
    MockERC20 usdc;
    MarketWord cb; // BTC/USDC, 200 ppm, 6 figures, minQuote 1 USDC
    MarketWord ce; // ETH/USDC, 200 ppm, 6 figures, minQuote 1 USDC
    uint32 mb;
    uint32 me;

    /// BTC at $100,000: P = 1,000 quote wei per sat = 100_000 x 10^-2, decade 41.
    uint256 constant BTC_100K = 36_900_000;
    /// $99,990: P = 999.9 = 999_900 x 10^-3, decade 40.
    uint256 constant BTC_99990 = 36_899_900;
    /// $100,010: P = 1,000.1.
    uint256 constant BTC_100010 = 36_900_010;
    /// ETH at $2,345.67: P = 2.34567e-9 = 234_567 x 10^-14, decade 29.
    uint256 constant ETH_2345 = 26_234_567;

    function setUp() public {
        _deploy();
        btc = new MockERC20("Bitcoin", "BTC", 8);
        eth = new MockERC20("Ether", "ETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mb = book.listMarketQuote(address(btc), address(usdc), 200, 6, 1e6, 0);
        me = book.listMarketQuote(address(eth), address(usdc), 200, 6, 1e6, 0);
        cb = book.configOf(mb);
        ce = book.configOf(me);
        _fund(taker);
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    /// `who` holds and has approved and deposited BTC, ETH and USDC.
    function _fund(address who) internal {
        btc.mint(who, 1e20);
        eth.mint(who, 1e30);
        usdc.mint(who, 1e30);
        vm.startPrank(who);
        btc.approve(address(book), type(uint256).max);
        eth.approve(address(book), type(uint256).max);
        usdc.approve(address(book), type(uint256).max);
        book.deposit(address(btc), 1e19);
        book.deposit(address(eth), 1e28);
        book.deposit(address(usdc), 1e28);
        vm.stopPrank();
    }

    function _trader() internal returns (address a) {
        a = _maker();
        _fund(a);
    }

    function _b(address a, MockERC20 t) internal view returns (uint256) {
        return _bal(a, t);
    }

    // ------------------------------------------------------------------ the grid

    /// The design's ticks: BTC/USDC $100,000 is tick 36,900,000, ETH/USDC $2,345.67 26,234,567, ETH/USDC $2,500
    /// 26,250,000; P(tick) at the grid's two ends; consecutive ticks consecutive 6-figure prices across a decade.
    function test_grid_ticks() public pure {
        assertEq(PriceGrid.tickAt(100_000, -2), BTC_100K);
        assertEq(PriceGrid.tickAt(234_567, -14), ETH_2345);
        assertEq(PriceGrid.tickAt(250_000, -14), 26_250_000);
        assertEq(PriceGrid.tickAt(100_000, 23), 59_400_000, "BTC/MEME, P = 1e28");
        assertEq(PriceGrid.tickAt(100_000, -33), 9_000_000, "MEME/BTC, P = 1e-28");
        assertEq(PriceGrid.MAX_TICK, 74 * 900_000 - 1);
        assertLt(PriceGrid.MAX_TICK, 1 << 26);
        // 1 sat at $100,000 is 1,000 quote wei; 1 wei of ETH at $2,345.67 is 2.34567e-9 quote wei
        assertEq(PriceGrid.quoteDown(1, BTC_100K), 1_000);
        assertEq(PriceGrid.quoteDown(1e18, ETH_2345), 2_345_670_000);
        assertEq(PriceGrid.quoteDown(1, ETH_2345), 0);
        assertEq(PriceGrid.quoteUp(1, ETH_2345), 1);
        // across a decade: 999_999 x 10^k then 100_000 x 10^(k+1)
        assertEq(PriceGrid.quoteDown(1e6, T - 1), 999_999);
        assertEq(PriceGrid.quoteDown(1e6, T), 1_000_000);
        assertEq(PriceGrid.quoteDown(1e6, T + 1), 1_000_010);
        // the ends: P(1) = 100_001e-43, P(MAX) = 999_999e30
        assertEq(PriceGrid.quoteDown(1e43, 1), 100_001);
        assertEq(PriceGrid.quoteDown(1, PriceGrid.MAX_TICK), 999_999e30);
        // the inverse
        assertEq(PriceGrid.tickAtOrBelow(1_000, 0), BTC_100K);
        assertEq(PriceGrid.tickAtOrBelow(10_001, -1), BTC_100010, "1,000.1 normalized to 100_010e-2");
        assertEq(PriceGrid.tickAtOrBelow(1_000_109, -3), BTC_100010, "1,000.109 truncated to 6 figures");
    }

    /// quoteDown / quoteUp / feeDown against the exact rational, decades below and above 43, fuzzed.
    function testFuzz_grid_quote_rounding(uint256 amount, uint256 tick, uint24 ppm) public pure {
        amount = bound(amount, 0, (1 << 112) - 1);
        tick = bound(tick, PriceGrid.MIN_TICK, PriceGrid.MAX_TICK);
        ppm = uint24(bound(ppm, 0, 1_000_000));
        (uint256 d, uint256 mant) = PriceGrid.split(tick);
        uint256 down = PriceGrid.quoteDown(amount, tick);
        uint256 up = PriceGrid.quoteUp(amount, tick);
        if (d >= 43) {
            assertEq(down, amount * mant * 10 ** (d - 43));
            assertEq(up, down);
        } else {
            uint256 num = amount * mant;
            uint256 div = 10 ** (43 - d);
            assertEq(down, num / div);
            assertEq(up, num % div == 0 ? down : down + 1);
            assertEq(PriceGrid.feeDown(amount, tick, ppm), num * ppm / (div * 1e6));
        }
    }

    /// Every tick's price is the inverse of its tick, and consecutive ticks are consecutive 6-figure prices, across a
    /// decade boundary too (999_999 x 10^k, then 100_000 x 10^(k+1)): compares of ticks are compares of prices.
    function testFuzz_grid_inverse_and_monotonic(uint256 t) public pure {
        t = bound(t, PriceGrid.MIN_TICK, PriceGrid.MAX_TICK - 1);
        (uint256 d, uint256 mant) = PriceGrid.split(t);
        assertEq(PriceGrid.tickAtOrBelow(mant, int256(d) - 43), t, "inverse");
        assertEq(PriceGrid.tickOf(d, mant), t);
        (uint256 d2, uint256 m2) = PriceGrid.split(t + 1);
        if (d2 == d) {
            assertEq(m2, mant + 1);
        } else {
            assertEq(d2, d + 1);
            assertEq(mant, 999_999);
            assertEq(m2, 100_000);
        }
        // a price between two ticks rounds down to the lower
        assertEq(PriceGrid.tickAtOrBelow(mant * 10 + 9, int256(d) - 44), t, "a 7th figure truncated");
    }

    // ---------------------------------------------------------------- units and q

    /// The chooser: the smallest q with amount / 10^q below 2^30, the design's table and its bounds.
    function test_units_table() public pure {
        _units(50_000_000, 0, 50_000_000); // 0.5 BTC
        _units(1_000_000_000, 0, 1_000_000_000); // 10 BTC
        _units(1_234_567_890, 1, 123_456_789); // 12.3456789 BTC
        _units(1_234_567_891, 1, 123_456_789); // 12.34567891 BTC: 1 sat dropped
        _units(1e10, 1, 1e9); // 100 BTC
        _units(1e11, 2, 1e9); // 1,000 BTC
        _units(1e18, 9, 1e9); // 1 ETH
        _units(1_234_567_891_234_000_000, 10, 123_456_789); // 1.234567891234 ETH
        _units(1e24, 15, 1e9); // 1,000,000 MEME
        _units(1_073_741_824, 1, 107_374_182); // 2^30 sat: the fewest units at q > 0
        _units(10_737_418_230, 1, 1_073_741_823); // the most
        _units(10_737_418_240, 2, 107_374_182);
        _units((1 << 112) - 1, 25, uint256((1 << 112) - 1) / 1e25); // the largest amount: q 25, fits a sub-order's 5 bits
    }

    function _units(uint256 amount, uint256 q, uint256 units) internal pure {
        (uint256 gq, uint256 gu) = OloMath.toUnits(amount);
        assertEq(gq, q, "q");
        assertEq(gu, units, "units");
    }

    function testFuzz_units(uint256 amount) public pure {
        amount = bound(amount, 0, (1 << 112) - 1);
        (uint256 q, uint256 units) = OloMath.toUnits(amount);
        assertLt(units, 1 << 30);
        assertEq(units, amount / 10 ** q);
        if (q > 0) assertGe(amount / 10 ** (q - 1), 1 << 30, "q is the smallest");
        if (q > 0) assertGe(units, uint256(1 << 30) / 10, "at least 2^30 / 10 units above q 0");
        assertLe(q, 25);
    }

    /// 100 BTC rests as 1e9 units of 10 sat, exact; 12.34567891 BTC as 123,456,789 units of 10 sat, the last sat never
    /// escrowed; 1.234567891234 ETH as 123,456,789 units of 1e10 wei. The escrow is what is stored, and the events and
    /// views say so.
    function test_q_orders_store_and_escrow_what_they_hold() public {
        address a = _trader();
        uint256 b0 = _b(a, btc);
        vm.recordLogs();
        vm.prank(a);
        book.place(OloOps.key(cb), OloOps.placeW(false, BTC_100K, 1e10, 1, 0));
        _expectPlaced(a, BTC_100K, false, 1e10, 1, mb);
        PoolWord w = PoolWord.wrap(book.orderWord(cb, 1));
        assertEq(w.qOf(), 1);
        assertEq(w.openOf(), 1e9);
        assertEq(b0 - _b(a, btc), 1e10, "100 BTC escrowed exactly");
        vm.recordLogs();
        vm.prank(a);
        book.place(OloOps.key(cb), OloOps.placeW(false, BTC_100K, 1_234_567_891, 2, 0));
        _expectPlaced(a, BTC_100K, false, 1_234_567_890, 2, mb);
        assertEq(b0 - _b(a, btc), 1e10 + 1_234_567_890, "the dropped sat never left the account");
        (uint256 tick, uint256 open, uint256 filled, bool isBid, address owner) = book.orderOf(cb, 2);
        assertEq(tick, BTC_100K);
        assertEq(open, 1_234_567_890);
        assertEq(filled, 0);
        assertFalse(isBid);
        assertEq(owner, a);
        // ETH: a bid escrows its stored amount's quote, rounded up
        uint256 u0 = _b(a, usdc);
        vm.recordLogs();
        vm.prank(a);
        book.place(OloOps.key(ce), OloOps.placeW(true, ETH_2345, 1_234_567_891_234_000_000, 3, 0));
        _expectPlaced(a, ETH_2345, true, 1_234_567_890_000_000_000, 3, me);
        w = PoolWord.wrap(book.orderWord(ce, 3));
        assertEq(w.qOf(), 10);
        assertEq(w.openOf(), 123_456_789);
        // 1.23456789e18 x 2.34567e-9 = 2,895,888,862.5... quote wei, rounded up
        assertEq(u0 - _b(a, usdc), 2_895_888_863);
        // cancels refund exactly what was stored (a bid's quote rounded down: the 1 wei of rounding stays)
        vm.startPrank(a);
        book.cancel(OloOps.key(cb), OloOps.tagW(cb, OloOps.posW(1, 0)));
        book.cancel(OloOps.key(cb), OloOps.tagW(cb, OloOps.posW(2, 0)));
        book.cancel(OloOps.key(ce), OloOps.tagW(ce, OloOps.posW(3, 0)));
        vm.stopPrank();
        assertEq(_b(a, btc), b0);
        assertEq(u0 - _b(a, usdc), 1, "the bid's escrow rounded up, its refund down");
    }

    function _expectPlaced(address maker, uint256 tick, bool isBid, uint256 amount, uint256 pos, uint32 market)
        internal
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IOloBookBase.Placed.selector) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), maker);
            uint256 p = abi.decode(logs[i].data, (uint256));
            assertEq(p & 0x3ffffff, tick, "Placed tick");
            assertEq((p >> 26) & 1 == 1, isBid, "Placed side");
            assertEq((p >> 32) & ((1 << 112) - 1), amount, "Placed amount, as stored");
            assertEq(uint32(p >> 144), pos, "Placed pos");
            assertEq((p >> 176) & 0xffffffffffff, (uint256(market) << 16) | 1, "Placed market key: the id, version 1");
            seen = true;
        }
        assertTrue(seen, "Placed");
    }

    // ------------------------------------------------------------------ takes

    /// A take ending inside a q > 0 order: 100 BTC at $100,000 (units of 10 sat); a buy of 0.50000007 BTC fills
    /// 50,000,000 sat and leaves 7 (under one unit); the taker pays the exact quote and the fee, rounded up.
    function test_take_ends_inside_a_q_order() public {
        address a = _trader();
        vm.prank(a);
        book.place(OloOps.key(cb), OloOps.placeW(false, BTC_100K, 1e10, 1, 0));
        uint256 u0 = _b(taker, usdc);
        uint256 b0 = _b(taker, btc);
        vm.prank(taker);
        (uint256 got, uint256 paid) = book.take(
            OloOps.key(cb),
            OloOps.poolList(OloOps.poolEntry(1, BTC_100K)),
            OloOps.tagW(cb, OloOps.takeW(true, 50_000_007, 0))
        );
        assertEq(got, 50_000_000, "whole units of 10 sat");
        assertEq(paid, 50_000_000_000 + 10_000_000, "5e10 quote wei and 200 ppm");
        assertEq(u0 - _b(taker, usdc), paid);
        assertEq(_b(taker, btc) - b0, got);
        (, uint256 open, uint256 filled,,) = book.orderOf(cb, 1);
        assertEq(open, 1e10 - 5e7);
        assertEq(filled, 5e7);
        // fill-or-kill with a tolerance of 7 sat passes (7 left); of 6 it reverts
        vm.prank(taker);
        (got,) = book.take(
            OloOps.key(cb),
            OloOps.poolList(OloOps.poolEntry(1, BTC_100K)),
            OloOps.tagW(cb, OloOps.fokW(true, 50_000_007, 0, 7))
        );
        assertEq(got, 50_000_000);
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.FokNotFilled.selector);
        book.take(
            OloOps.key(cb),
            OloOps.poolList(OloOps.poolEntry(1, BTC_100K)),
            OloOps.tagW(cb, OloOps.fokW(true, 50_000_007, 0, 6))
        );
        uint256 a0 = _b(a, usdc);
        vm.prank(a);
        uint256 proceeds = book.claim(OloOps.key(cb), OloOps.tagW(cb, OloOps.posW(1, 0)));
        assertEq(proceeds, 100_000_000_000, "1e8 sat at 1,000");
        assertEq(_b(a, usdc) - a0, proceeds + 20_000_000, "and the fee's maker part (100%)");
    }

    /// The design's rounding example: 10 ETH resting at $2,345.67 (q 10), a buy of 0.12345678 ETH:
    /// the exact quote 289,588,865.1426 rounds up to what the taker pays and down to what the maker claims; the fee is
    /// on the exact quote, rounded up for the taker and down for the maker's share.
    function test_rounding_directions_eth() public {
        address a = _trader();
        vm.prank(a);
        book.place(OloOps.key(ce), OloOps.placeW(false, ETH_2345, 10e18, 1, 0));
        assertEq(PoolWord.wrap(book.orderWord(ce, 1)).qOf(), 10);
        uint256 u0 = _b(taker, usdc);
        vm.prank(taker);
        (uint256 got, uint256 paid) = book.take(
            OloOps.key(ce),
            OloOps.poolList(OloOps.poolEntry(1, ETH_2345)),
            OloOps.tagW(ce, OloOps.takeW(true, 0.12345678e18, 0))
        );
        assertEq(got, 0.12345678e18);
        // fee = ceil(289,588,865.1426 x 200e-6) = ceil(57,917.77...) = 57,918
        assertEq(paid, 289_588_866 + 57_918);
        assertEq(u0 - _b(taker, usdc), paid);
        uint256 a0 = _b(a, usdc);
        vm.prank(a);
        uint256 proceeds = book.claim(OloOps.key(ce), OloOps.tagW(ce, OloOps.posW(1, 0)));
        assertEq(proceeds, 289_588_865, "rounded down");
        assertEq(_b(a, usdc) - a0, 289_588_865 + 57_917, "the fee floored");
        // a sell rounds the other way: 0.12345678 ETH into a bid at the same tick
        address bb = _trader();
        vm.prank(bb);
        book.place(OloOps.key(ce), OloOps.placeW(true, ETH_2345, 1e18, 2, 0));
        u0 = _b(taker, usdc);
        vm.prank(taker);
        (, uint256 received) = book.take(
            OloOps.key(ce),
            OloOps.poolList(OloOps.poolEntry(2, ETH_2345)),
            OloOps.tagW(ce, OloOps.takeW(false, 0.12345678e18, 0))
        );
        assertEq(received, 289_588_865 - 57_918, "the quote rounded down, the fee up");
        assertEq(_b(taker, usdc) - u0, received);
        _leaveAll3();
    }

    /// The design's multi-decade sell: 0.50000007 BTC into Dave's 0.3 BTC bid at $100,000 (decade 41)
    /// and Bob's 100 BTC bid at $99,990 (decade 40, q 1). The sum aligns to decade 40 and rounds once: 49,998 USDC,
    /// fee 9.9996 USDC, 7 sat left. Fill-or-kill passes with a tolerance of 7 sat; without Bob it reverts.
    function test_take_spans_two_decades() public {
        address dave = _trader();
        address bob = _trader();
        vm.prank(dave);
        book.place(OloOps.key(cb), OloOps.placeW(true, BTC_100K, 30_000_000, 1, 0));
        vm.prank(bob);
        book.place(OloOps.key(cb), OloOps.placeW(true, BTC_99990, 1e10, 2, 0));
        assertEq(PoolWord.wrap(book.orderWord(cb, 2)).qOf(), 1);
        bytes memory list = OloOps.poolList(bytes.concat(OloOps.poolEntry(1, BTC_100K), OloOps.poolEntry(2, BTC_99990)));
        uint256 snap = vm.snapshotState();
        vm.prank(taker);
        vm.recordLogs();
        (uint256 sold, uint256 received) =
            book.take(OloOps.key(cb), list, OloOps.tagW(cb, OloOps.fokW(false, 50_000_007, 0, 7)));
        assertEq(sold, 50_000_000);
        assertEq(received, 49_998_000_000 - 9_999_600);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 packed, uint256 baseAmt, uint256 q, uint256 fee, bytes memory fills) =
            abi.decode(logs[logs.length - 1].data, (uint256, uint256, uint256, uint256, bytes));
        assertEq(packed, 2 << 8, "a sell of two fills");
        assertEq(baseAmt, 50_000_000);
        assertEq(q, 49_998_000_000);
        assertEq(fee, 9_999_600);
        // fills: one position segment, kind 0 | length 18 | (pos 4 | q 1 | units 4) x 2
        assertEq(
            fills,
            abi.encodePacked(
                uint8(0), uint24(18), uint32(1), uint8(0), uint32(30_000_000), uint32(2), uint8(1), uint32(2_000_000)
            )
        );
        vm.revertToState(snap);
        // the opposite order: Bob first (decade 40, units of 10 sat: 50,000,000), then Dave (decade 41, q 0) the last
        // 7 sat: 5e7 x 999.9 + 7 x 1,000 = 49,995,007,000, fee ceil(9,999,001.4)
        list = OloOps.poolList(bytes.concat(OloOps.poolEntry(2, BTC_99990), OloOps.poolEntry(1, BTC_100K)));
        vm.prank(taker);
        (sold, received) = book.take(OloOps.key(cb), list, OloOps.tagW(cb, OloOps.fokW(false, 50_000_007, 0, 0)));
        assertEq(sold, 50_000_007, "all of it: strict fill-or-kill passes");
        assertEq(received, 49_995_007_000 - 9_999_002);
        vm.revertToState(snap);
        // without Bob: 0.2 BTC left, more than a tolerance of 7 sat: fill-or-kill reverts
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.FokNotFilled.selector);
        book.take(
            OloOps.key(cb),
            OloOps.poolList(OloOps.poolEntry(1, BTC_100K)),
            OloOps.tagW(cb, OloOps.fokW(false, 50_000_000, 0, 7))
        );
    }

    /// The take's one rounding equals the exact sum over the fills, whatever the decades and the order of the list:
    /// random orders on both sides of a decade boundary, the quote checked against an exact recomputation.
    function testFuzz_take_quote_is_the_exact_sum_rounded_once(uint256 seed, bool buy) public {
        uint256 n = 1 + seed % 6;
        bytes memory entries;
        uint256 want;
        uint256[] memory amts = new uint256[](n);
        uint256[] memory ticks = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            // ticks within 3 decades of T, amounts from 1 wei to 1e15 (q 0 to 6)
            ticks[i] = T - 1_350_000 + (r % 2_700_000);
            amts[i] = 1 + (r >> 64) % 1e15;
            address mk = _maker();
            vm.prank(mk);
            try book.place(OloOps.key(c), OloOps.placeW(!buy, ticks[i], amts[i], uint32(100 + i), 0)) {
                entries = bytes.concat(entries, OloOps.poolEntry(uint32(100 + i), ticks[i]));
                (uint256 q, uint256 u) = OloMath.toUnits(amts[i]);
                amts[i] = u * 10 ** q;
                want += amts[i];
            } catch {
                amts[i] = 0; // below minQuote 1
            }
        }
        if (want == 0) return;
        vm.prank(taker);
        (uint256 got, uint256 qa) =
            book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(buy, want, 0)));
        assertEq(got, want, "every stored amount fills");
        // exact: sum of amount x mantissa x 10^(d - 30) over 10^13 (every decade here is at least 30)
        uint256 num;
        for (uint256 i; i < n; ++i) {
            if (amts[i] == 0) continue;
            (uint256 d, uint256 mant) = PriceGrid.split(ticks[i]);
            num += amts[i] * mant * 10 ** (d - 30);
        }
        uint256 div = 1e13;
        uint256 exact = buy ? OloMath.divUp(num, div) : num / div;
        uint256 fee = OloMath.divUp(num * 50, div * 1e6);
        assertEq(qa, buy ? exact + fee : exact - fee);
        _solvent();
    }

    /// Fill-or-kill is a tolerance: what is left of the amount, in its unit, at most maxLeft (0: strict). A q 2 order
    /// (units of 100 sat) leaves the last 99 sat of a buy; the take passes with maxLeft 99 and reverts with 98. In
    /// quote mode what is left is quote wei: the amount less what the taker paid.
    function test_fok_max_left() public {
        address a = _trader();
        vm.startPrank(a);
        book.place(OloOps.key(cb), OloOps.placeW(false, BTC_100K, 50_000_000, 1, 0)); // q 0
        book.place(OloOps.key(cb), OloOps.placeW(false, BTC_100K, 1e11, 2, 0)); // q 2: units of 100 sat
        vm.stopPrank();
        bytes memory list = OloOps.poolList(bytes.concat(OloOps.poolEntry(1, BTC_100K), OloOps.poolEntry(2, BTC_100K)));
        uint256 snap = vm.snapshotState();
        // 0.5 BTC + 199 sat: the q 0 order takes 0.5 BTC, the q 2 order 100 sat, 99 sat left
        vm.prank(taker);
        (uint256 got,) = book.take(OloOps.key(cb), list, OloOps.tagW(cb, OloOps.fokW(true, 50_000_199, 0, 99)));
        assertEq(got, 50_000_100);
        vm.revertToState(snap);
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.FokNotFilled.selector);
        book.take(OloOps.key(cb), list, OloOps.tagW(cb, OloOps.fokW(true, 50_000_199, 0, 98)));
        // without the bit maxLeft means nothing: the same take passes
        vm.prank(taker);
        (got,) = book.take(OloOps.key(cb), list, OloOps.tagW(cb, OloOps.takeW(true, 50_000_199, 0, 0)));
        assertEq(got, 50_000_100);
        vm.revertToState(snap);
        // strict: exactly what the OLO EVM contract holds there passes, a sat more reverts
        vm.prank(taker);
        (got,) = book.take(
            OloOps.key(cb),
            OloOps.poolList(OloOps.poolEntry(1, BTC_100K)),
            OloOps.tagW(cb, OloOps.fokW(true, 50_000_000, 0, 0))
        );
        assertEq(got, 50_000_000);
        vm.revertToState(snap);
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.FokNotFilled.selector);
        book.take(
            OloOps.key(cb),
            OloOps.poolList(OloOps.poolEntry(1, BTC_100K)),
            OloOps.tagW(cb, OloOps.fokW(true, 50_000_001, 0, 0))
        );
        // nothing filled at all: all of the amount is left, so only maxLeft >= amount passes
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.FokNotFilled.selector);
        book.take(
            OloOps.key(cb), OloOps.poolList(OloOps.poolEntry(9, BTC_100K)), OloOps.tagW(cb, OloOps.fokW(true, 5, 0, 4))
        );
        vm.prank(taker);
        (got,) = book.take(
            OloOps.key(cb), OloOps.poolList(OloOps.poolEntry(9, BTC_100K)), OloOps.tagW(cb, OloOps.fokW(true, 5, 0, 5))
        );
        assertEq(got, 0);
        // quote mode: 1,000.123 USDC at 1,000 quote wei a sat and 200 ppm, 1,000.2 a sat with the fee: the budget
        // holds Q x 1.0002 <= 1,000,122,999 (the 1 wei reserve), so 999,923 sat, Q = 999,923,000, fee
        // ceil(199,984.6) = 199,985: the taker pays 1,000,122,985 and 15 is left, less than a sat with its fee
        vm.prank(taker);
        (uint256 bought, uint256 paid) =
            book.take(OloOps.key(cb), list, OloOps.tagW(cb, OloOps.quoteW(true, 1_000_123_000, 0)));
        assertEq(bought, 999_923);
        assertEq(paid, 1_000_122_985);
        uint256 left = 1_000_123_000 - paid;
        assertEq(left, 15);
        vm.revertToState(snap);
        vm.prank(taker);
        (uint256 bought2,) = book.take(
            OloOps.key(cb), list, OloOps.tagW(cb, OloOps.takeW(true, 1_000_123_000, OloOps.QUOTE | OloOps.FOK, left))
        );
        assertEq(bought2, bought, "fill-or-kill in quote mode passes at maxLeft = what is left");
        vm.revertToState(snap);
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.FokNotFilled.selector);
        book.take(
            OloOps.key(cb),
            list,
            OloOps.tagW(cb, OloOps.takeW(true, 1_000_123_000, OloOps.QUOTE | OloOps.FOK, left - 1))
        );
    }

    /// maxLeft is 77 bits (params 121-197): the most it holds is 2^77 - 1, about 1.51e23 in the amount's unit, while
    /// an amount takes 112. With nothing to fill, all of the amount is left: an amount of
    /// 2^77 - 1 passes fill-or-kill at the widest maxLeft, one of 2^77 does not, however the params are written (a
    /// wider tolerance has no bits to go in). A caller whose tolerance is wider (1% of 1e27) leaves fill-or-kill off
    /// and checks the returned amounts.
    function test_max_left_is_77_bits() public {
        uint256 widest = (1 << 77) - 1;
        vm.startPrank(taker);
        (uint256 got,) = book.take(OloOps.key(cb), "", OloOps.tagW(cb, OloOps.fokW(true, widest, 0, widest)));
        assertEq(got, 0, "all of 2^77 - 1 left, within the widest maxLeft");
        vm.expectRevert(IOloBookBase.FokNotFilled.selector);
        book.take(OloOps.key(cb), "", OloOps.tagW(cb, OloOps.fokW(true, widest + 1, 0, widest)));
        // maxLeft is its 77 bits whole: every bit from 121 to 205 set (maxLeft and the unread 198-205) is still
        // 2^77 - 1, and the real tag above them names the version
        uint256 allSet = OloOps.takeW(true, widest + 1, OloOps.FOK) | ((((uint256(1) << 85) - 1)) << 121);
        vm.expectRevert(IOloBookBase.FokNotFilled.selector);
        book.take(OloOps.key(cb), "", OloOps.tagW(cb, allSet));
        vm.stopPrank();
        uint256 onePercentOf1e27 = 1e25;
        assertGt(onePercentOf1e27, widest, "a 1% tolerance on 1e27 does not fit");
    }

    /// Both sides, both settlements: a buy and a sell through the accounts and through the wallet move what the take
    /// returns, and the makers' settles pay the rest.
    function test_take_both_sides_wallet_and_account() public {
        address a = _trader();
        vm.startPrank(a);
        book.place(OloOps.key(cb), OloOps.placeW(false, BTC_100010, 3e8, 1, 0));
        book.place(OloOps.key(cb), OloOps.placeW(true, BTC_99990, 3e8, 2, 0));
        vm.stopPrank();
        for (uint8 mode; mode < 2; ++mode) {
            uint256 wq = usdc.balanceOf(taker);
            uint256 wb = btc.balanceOf(taker);
            uint256 aq = _b(taker, usdc);
            uint256 ab = _b(taker, btc);
            vm.prank(taker);
            (uint256 got, uint256 paid) = book.take(
                OloOps.key(cb),
                OloOps.poolList(OloOps.poolEntry(1, BTC_100010)),
                OloOps.tagW(cb, OloOps.takeW(true, 1e8 + 7, mode))
            );
            assertEq(got, 1e8 + 7);
            // 100,000,007 sat x 1,000.1 = 100,010,007,000.7 -> rounded up; fee ceil(x 200e-6)
            assertEq(paid, 100_010_007_001 + 20_002_002);
            vm.prank(taker);
            (uint256 sold, uint256 recv) = book.take(
                OloOps.key(cb),
                OloOps.poolList(OloOps.poolEntry(2, BTC_99990)),
                OloOps.tagW(cb, OloOps.takeW(false, 1e8 + 7, mode))
            );
            assertEq(sold, 1e8 + 7);
            // 100,000,007 x 999.9 = 99,990,006,999.3 -> rounded down; fee ceil(19,998,001.39...) = 19,998,002
            assertEq(recv, 99_990_006_999 - 19_998_002);
            if (mode == 0) {
                assertEq(aq + recv - paid, _b(taker, usdc));
                assertEq(ab, _b(taker, btc));
                assertEq(wq, usdc.balanceOf(taker));
            } else {
                assertEq(wq + recv - paid, usdc.balanceOf(taker));
                assertEq(wb, btc.balanceOf(taker));
                assertEq(aq, _b(taker, usdc));
            }
        }
        _leaveAll3();
    }

    /// takeThenRest: buy 2 BTC limit $100,010 against Alice's 1.23456789 BTC at $100,000: the fills pay
    /// 123,456.789 USDC and the fee; 0.76543211 BTC rests as a bid (q 0) escrowing 76,550,865,322 (rounded up); by
    /// wallet, one pull. A rest worth less than minQuote does not rest.
    function test_take_then_rest_with_its_own_q() public {
        address alice = _trader();
        vm.prank(alice);
        book.place(OloOps.key(cb), OloOps.placeW(false, BTC_100K, 123_456_789, 1, 0));
        address r = address(0xA0A0);
        usdc.mint(r, 1e30);
        vm.prank(r);
        usdc.approve(address(book), type(uint256).max);
        uint256 w0 = usdc.balanceOf(r);
        vm.recordLogs();
        vm.prank(r);
        (uint256 got, uint256 paid,,) = book.takeThenRest(
            OloOps.key(cb),
            OloOps.poolList(OloOps.poolEntry(1, BTC_100K)),
            OloOps.tagW(cb, OloOps.restW(true, 2e8, BTC_100010, 1, 77))
        );
        assertEq(got, 123_456_789);
        assertEq(paid, 123_456_789_000 + 24_691_358, "the fills' quote and fee (200 ppm, rounded up)");
        assertEq(btc.balanceOf(r), got, "the base pushed");
        assertEq(w0 - usdc.balanceOf(r), paid + 76_550_865_322, "one pull: the fills and the rest's escrow");
        _expectPlaced(r, BTC_100010, true, 76_543_211, 77, mb);
        (uint256 tick, uint256 open,, bool isBid, address owner) = book.orderOf(cb, 77);
        assertEq(tick, BTC_100010);
        assertEq(open, 76_543_211);
        assertTrue(isBid);
        assertEq(owner, r);
        // a q > 0 rest: 2,000 BTC and 99 sat wanted, nothing to fill (Alice's order is filled whole): rests as 2e8
        // units of 1,000 sat (q 3)
        vm.prank(taker);
        book.takeThenRest(
            OloOps.key(cb),
            OloOps.poolList(OloOps.poolEntry(1, BTC_100K)),
            OloOps.tagW(cb, OloOps.restW(true, 2e11 + 99, BTC_99990, 0, 78))
        );
        PoolWord w = PoolWord.wrap(book.orderWord(cb, 78));
        assertEq(w.qOf(), 3);
        assertEq(w.openOf() * 1000, 2e11, "the rest rounded down to its units");
        // a rest worth less than 1 USDC (999 sat at $99,990 is 998,900.1 quote wei) stays with the taker: nothing
        // rests, nothing reverts
        uint256 b0 = _b(taker, usdc);
        vm.prank(taker);
        book.takeThenRest(OloOps.key(cb), "", OloOps.tagW(cb, OloOps.restW(true, 999, BTC_99990, 0, 79)));
        assertFalse(PoolWord.wrap(book.orderWord(cb, 79)).isLive(), "below minQuote: no rest");
        assertEq(_b(taker, usdc), b0);
        // 1,001 sat at $99,990 is 1,000,899.9 quote wei: rests
        vm.prank(taker);
        book.takeThenRest(OloOps.key(cb), "", OloOps.tagW(cb, OloOps.restW(true, 1_001, BTC_99990, 0, 79)));
        assertTrue(PoolWord.wrap(book.orderWord(cb, 79)).isLive());
    }

    /// minQuote: every resting order is worth at least minQuote at its tick: a place, a modify, a takeThenRest's rest
    /// (above), a batch sub-order (OloPreciseBatch). 1 USDC on BTC/USDC at $100,000 is 1,000 sat.
    function test_min_quote() public {
        address a = _trader();
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.SizeOutOfRange.selector);
        book.place(OloOps.key(cb), OloOps.placeW(false, BTC_100K, 999, 1, 0));
        vm.expectRevert(IOloBookBase.SizeOutOfRange.selector);
        book.place(OloOps.key(cb), OloOps.placeW(true, BTC_100K, 0, 1, 0));
        book.place(OloOps.key(cb), OloOps.placeW(false, BTC_100K, 1_000, 1, 0));
        vm.expectRevert(IOloBookBase.SizeOutOfRange.selector);
        book.modify(OloOps.key(cb), OloOps.tagW(cb, OloOps.modifyW(1, BTC_99990, 1_000, 0))); // 999,900 quote wei
        book.modify(OloOps.key(cb), OloOps.tagW(cb, OloOps.modifyW(1, BTC_99990, 1_001, 0)));
        vm.stopPrank();
        // the minimum follows the quote, not the price: at $10, 1 USDC is 0.1 BTC
        uint256 ten = PriceGrid.tickAt(100_000, -6);
        vm.prank(a);
        vm.expectRevert(IOloBookBase.SizeOutOfRange.selector);
        book.place(OloOps.key(cb), OloOps.placeW(false, ten, 9_999_999, 2, 0));
        vm.prank(a);
        book.place(OloOps.key(cb), OloOps.placeW(false, ten, 10_000_000, 2, 0));
    }

    /// A modify settles the fills and rests the new amount as its own units and q: from 1,000 BTC (q 2) to 0.5 BTC (q
    /// 0). Keeping the tick and the open amount pays the order's fills when it has some, as a claim does, and is
    /// NoChange when it has none.
    function test_modify_changes_q_and_no_change() public {
        address a = _trader();
        vm.prank(a);
        book.place(OloOps.key(cb), OloOps.placeW(false, BTC_100K, 1e11, 1, 0));
        vm.prank(a);
        vm.expectRevert(IOloBookBase.NoChange.selector); // nothing filled: nothing to pay, nothing to change
        book.modify(OloOps.key(cb), OloOps.tagW(cb, OloOps.modifyW(1, BTC_100K, 1e11, 0)));
        vm.prank(taker);
        book.take(
            OloOps.key(cb), OloOps.poolList(OloOps.poolEntry(1, BTC_100K)), OloOps.tagW(cb, OloOps.takeW(true, 5e10, 0))
        );
        uint256 b0 = _b(a, btc);
        uint256 u0 = _b(a, usdc);
        // the tick and what is open now, with fills to pay: they are paid and the order rests on
        vm.prank(a);
        book.modify(OloOps.key(cb), OloOps.tagW(cb, OloOps.modifyW(1, BTC_100K, 5e10, 0)));
        PoolWord w = PoolWord.wrap(book.orderWord(cb, 1));
        assertEq(w.qOf(), 2);
        assertEq(w.openOf(), 5e8);
        assertEq(w.filledOf(), 0);
        assertEq(w.tickOf(), BTC_100K);
        assertEq(_b(a, btc), b0, "no base moves: what was open rests on");
        assertEq(_b(a, usdc) - u0, 5e13 + 1e10, "the fills' proceeds and fee");
        vm.prank(a);
        vm.expectRevert(IOloBookBase.NoChange.selector); // paid: the same again changes nothing
        book.modify(OloOps.key(cb), OloOps.tagW(cb, OloOps.modifyW(1, BTC_100K, 5e10, 0)));
        u0 = _b(a, usdc);
        vm.prank(a);
        book.modify(OloOps.key(cb), OloOps.tagW(cb, OloOps.modifyW(1, BTC_100010, 50_000_001, 0)));
        w = PoolWord.wrap(book.orderWord(cb, 1));
        assertEq(w.qOf(), 0);
        assertEq(w.openOf(), 50_000_001);
        assertEq(w.filledOf(), 0);
        assertEq(w.tickOf(), BTC_100010);
        assertEq(_b(a, btc) - b0, 5e10 - 50_000_001, "the escrow difference");
        assertEq(_b(a, usdc), u0, "no fills left to pay");
    }

    /// The multicall's ops on the new layouts: PLACE (25 bytes) with an amount stored as its units, MODIFY (24 bytes)
    /// to a q > 0 amount, CLAIM and CANCEL, settled once.
    function test_multicall_ops() public {
        address a = _trader();
        bytes memory h = OloOps.header(cb);
        bytes memory ops = bytes.concat(
            OloOps.place(0, BTC_100K, false, 1_234_567_891, 5),
            OloOps.place(0, BTC_99990, true, 7_000, 6),
            OloOps.modify(0, 6, BTC_99990, 1e11 + 55)
        );
        uint256 b0 = _b(a, btc);
        uint256 u0 = _b(a, usdc);
        vm.prank(a);
        book.multicall(0, bytes.concat(h, ops));
        assertEq(b0 - _b(a, btc), 1_234_567_890);
        assertEq(u0 - _b(a, usdc), 99_990_000_000_000, "the bid of 1,000 BTC (q 2) escrowed at 999.9");
        PoolWord w = PoolWord.wrap(book.orderWord(cb, 6));
        assertEq(w.qOf(), 2);
        vm.prank(taker);
        book.take(
            OloOps.key(cb), OloOps.poolList(OloOps.poolEntry(5, BTC_100K)), OloOps.tagW(cb, OloOps.takeW(true, 1e8, 0))
        );
        vm.prank(a);
        book.multicall(0, bytes.concat(h, OloOps.claim(0, 5), OloOps.cancel(0, 6), OloOps.cancel(0, 5)));
        assertEq(_b(a, btc), b0 - 1e8, "the ask's base back but the fill");
        _leaveAll3();
    }

    /// A list spanning absurd decades (a take worth 1e41 quote wei near the grid's top, then an order at the makers'
    /// floor) overflows the sum and reverts AmountOverflow: Q x 10^(43 - 4) is past 2^235.
    function test_absurd_decades_overflow() public {
        MockERC20 x = new MockERC20("X", "X", 18);
        MockERC20 y = new MockERC20("Y", "Y", 18);
        MarketWord cx = book.configOf(book.listMarketQuote(address(x), address(y), 0, 6, 0, 0));
        address a = address(0xF00);
        x.mint(a, 1 << 200);
        y.mint(a, 1 << 200);
        y.mint(taker, 1 << 200);
        vm.prank(taker);
        y.approve(address(book), type(uint256).max);
        vm.startPrank(a);
        x.approve(address(book), type(uint256).max);
        // asks: a large one in decade 70 (P = 1e32) and a large one at the makers' floor (decade 4)
        book.place(OloOps.key(cx), OloOps.placeW(false, 63_000_000, 1e9, 2, 2));
        book.place(OloOps.key(cx), OloOps.placeW(false, PriceGrid.MIN_MAKER_TICK, 1e33, 3, 2));
        vm.stopPrank();
        // decade 70 then decade 4: the quote so far, 1e41, scaled by 10^39 overflows
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.AmountOverflow.selector);
        book.take(
            OloOps.key(cx),
            OloOps.poolList(
                bytes.concat(OloOps.poolEntry(2, 63_000_000), OloOps.poolEntry(3, PriceGrid.MIN_MAKER_TICK))
            ),
            OloOps.tagW(cx, OloOps.takeW(true, 1e9 + 1e33, 1))
        );
    }

    // -------------------------------------------------------------- the end

    /// Every trader cancels its live orders, withdraws everything and the pots are collected; base is conserved to
    /// the wei (amounts are base wei, never rounded in flight), quote keeps at most the roundings.
    function _leaveAll3() internal {
        address[] memory all = makers;
        for (uint256 i; i < all.length; ++i) {
            for (uint32 p = 1; p < 10; ++p) {
                _drain(cb, all[i], p);
                _drain(ce, all[i], p);
            }
        }
        for (uint256 i; i <= all.length; ++i) {
            address who = i < all.length ? all[i] : taker;
            vm.startPrank(who);
            book.withdraw(address(btc), _b(who, btc));
            book.withdraw(address(eth), _b(who, eth));
            book.withdraw(address(usdc), _b(who, usdc));
            vm.stopPrank();
        }
        book.collectFees(address(btc));
        book.collectFees(address(eth));
        book.collectFees(address(usdc));
        assertEq(btc.balanceOf(address(book)), 0, "base conserved: BTC");
        assertEq(eth.balanceOf(address(book)), 0, "base conserved: ETH");
        assertLt(usdc.balanceOf(address(book)), 10, "quote: roundings only");
    }

    function _drain(MarketWord mc, address who, uint32 pos) internal {
        (,,,, address owner) = book.orderOf(mc, pos);
        if (owner != who) return;
        vm.prank(who);
        book.cancel(OloOps.key(mc), OloOps.tagW(mc, OloOps.posW(pos, 0)));
    }
}
