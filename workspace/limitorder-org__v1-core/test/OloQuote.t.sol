// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {TakeRef} from "./TakeRef.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";

/// Quote-mode takes (mode bit 0x02: the amount is quote wei) by worked example, with every number derived by hand from
/// the specification: a buy fills, order by order, the most whole units whose quote and fee (each rounded up, once,
/// over the whole take) stay within the amount; a sell the most whose quote less fee (the exact value) stays within
/// it. Exact budgets fill to the wei; where the budget stops the walk short at an order, less than one of its units with
/// the fee is left, plus 1 wei for a buy and 2 for a sell. Then the never-exceed property fuzzed over the whole grid
/// (decades 0 to 73) and every fee from 0 to 50%, held to the brute-force reference (TakeRef.sol).
contract OloQuoteTest is OloBase {
    MockERC20 btc;
    MockERC20 eth;
    MockERC20 usdc;
    MarketWord cb; // BTC/USDC, 200 ppm, 6 figures, minQuote 1 USDC
    MarketWord ce; // ETH/USDC, 200 ppm, 6 figures, minQuote 1 USDC

    /// BTC at $100,000: P = 1,000 quote wei per sat (decade 41).
    uint256 constant BTC_100K = 36_900_000;
    /// ETH at $2,345.67: P = 2.34567e-9 quote wei per wei (decade 29).
    uint256 constant ETH_2345 = 26_234_567;

    function setUp() public {
        _deploy();
        btc = new MockERC20("Bitcoin", "BTC", 8);
        eth = new MockERC20("Ether", "ETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        cb = book.configOf(book.listMarketQuote(address(btc), address(usdc), 200, 6, 1e6, 0));
        ce = book.configOf(book.listMarketQuote(address(eth), address(usdc), 200, 6, 1e6, 0));
        _fund(taker);
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

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

    function _one(uint32 pos, uint256 tick) internal pure returns (bytes memory) {
        return OloOps.poolList(OloOps.poolEntry(pos, tick));
    }

    // ------------------------------------------------------------------ buys

    /// A buy of 1 BTC resting at $100,000 (1,000 quote wei a sat, 1,000.2 with the fee). 50,010 USDC is exactly the
    /// quote and fee of 0.5 BTC: it fills 50,000,000 sat and nothing is left. 999 quote wei more do not buy another sat
    /// (it costs 1,000 + a fee rounded up to 1): 999 left, less than a sat with its fee and 1 wei. 1,001 more do. 1 wei
    /// fills nothing (no Take, nothing moves), and an amount past the order fills it whole and leaves the rest.
    function test_buy_fills_the_most_units_within_the_amount() public {
        address a = _trader();
        vm.prank(a);
        book.place(OloOps.key(cb), OloOps.placeW(false, BTC_100K, 1e8, 1, 0));
        uint256 snap = vm.snapshotState();
        uint256[5] memory amounts = [uint256(50_010_000_000), 50_010_000_999, 50_010_001_001, 1, 100_020_000_005];
        uint256[5] memory sats = [uint256(50_000_000), 50_000_000, 50_000_001, 0, 100_000_000];
        uint256[5] memory paid = [uint256(50_010_000_000), 50_010_000_000, 50_010_001_001, 0, 100_020_000_000];
        for (uint256 i; i < 5; ++i) {
            uint256 u0 = _bal(taker, usdc);
            uint256 b0 = _bal(taker, btc);
            vm.recordLogs();
            vm.prank(taker);
            (uint256 got, uint256 cost) =
                book.take(OloOps.key(cb), _one(1, BTC_100K), OloOps.tagW(cb, OloOps.quoteW(true, amounts[i], 0)));
            assertEq(got, sats[i], "sats");
            assertEq(cost, paid[i], "quote and fee");
            assertLe(cost, amounts[i], "never more than the amount");
            assertEq(u0 - _bal(taker, usdc), cost, "the account pays what the take returns");
            assertEq(_bal(taker, btc) - b0, got);
            assertEq(vm.getRecordedLogs().length, got == 0 ? 0 : 1, "a Take iff fills");
            vm.revertToState(snap);
        }
    }

    // ----------------------------------------------------------------- sells

    /// A sell into a 1 BTC bid at $100,000 (a sat brings 1,000 quote wei less a fee of 0.2): at most 49,990 USDC
    /// sells exactly 0.5 BTC and receives exactly that. 999 quote wei more sell no further sat, although it would
    /// bring exactly 999 (1,000 less the fee's step from 10,000,000 to ceil(10,000,000.2) = 10,000,001) and so reach
    /// the amount to the wei: the budget bounds the exact quote, Q x 0.9998 <= A, and 50,000,001 sat put it 0.8 past
    /// (a quote-mode sell is not exact-out). 1 wei sells nothing.
    function test_sell_receives_at_most_the_amount() public {
        address a = _trader();
        vm.prank(a);
        book.place(OloOps.key(cb), OloOps.placeW(true, BTC_100K, 1e8, 1, 0));
        uint256 snap = vm.snapshotState();
        uint256[3] memory amounts = [uint256(49_990_000_000), 49_990_000_999, 1];
        uint256[3] memory sats = [uint256(50_000_000), 50_000_000, 0];
        uint256[3] memory received = [uint256(49_990_000_000), 49_990_000_000, 0];
        for (uint256 i; i < 3; ++i) {
            uint256 u0 = _bal(taker, usdc);
            uint256 b0 = _bal(taker, btc);
            vm.prank(taker);
            (uint256 sold, uint256 got) =
                book.take(OloOps.key(cb), _one(1, BTC_100K), OloOps.tagW(cb, OloOps.quoteW(false, amounts[i], 0)));
            assertEq(sold, sats[i], "sats");
            assertEq(got, received[i], "quote less fee");
            assertLe(got, amounts[i], "never more than the amount");
            assertEq(_bal(taker, usdc) - u0, got);
            assertEq(b0 - _bal(taker, btc), sold);
            vm.revertToState(snap);
        }
    }

    /// A dust sell whose exact quote is below a wei: 1 base wei at 0.999999 quote wei brings floor(0.999999) = 0 and
    /// owes a fee of 1 (rounded up): SellBelowFee, as for a base-mode sell of the same.
    function test_sell_below_its_fee_reverts() public {
        address b = _plain(T - 1, true, 5 * LOT);
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.SellBelowFee.selector);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(b)), OloOps.tagW(c, OloOps.quoteW(false, 1, 0)));
    }

    // -------------------------------------------------------------- decades

    /// Two asks of 5 LOT either side of decade 38's bottom (T - 1 at 0.999999 quote wei a base wei, T + 1 at
    /// 1.00001; 50 ppm), a buy of at most 7,000,000 quote wei: the first fills whole (4,999,995, exact), the second
    /// 1,999,635 base wei, the most whose quote and fee keep the total within the amount: the exact quote
    /// 6,999,649.99635 rounds up to 6,999,650 and its fee 349.98... to 350, 7,000,000 to the wei. The sell the other way
    /// (the higher decade first, the sum re-aligned on the second fill): 5 LOT and 2,000,302 base wei, receiving
    /// 7,000,349 - 351 = 6,999,998, 2 wei short (the two roundings down).
    function test_quote_mode_across_a_decade() public {
        address x = _plain(T - 1, false, 5 * LOT);
        address y = _plain(T + 1, false, 5 * LOT);
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(taker);
        (uint256 got, uint256 cost) = book.take(
            OloOps.key(c),
            OloOps.poolList(bytes.concat(_poolEntry(x), _poolEntry(y))),
            OloOps.tagW(c, OloOps.quoteW(true, 7_000_000, 0))
        );
        assertEq(got, 5_000_000 + 1_999_635);
        assertEq(cost, 7_000_000);
        (, uint256 baseAmt, uint256 q, uint256 fee,) = _takeLog(vm.getRecordedLogs());
        assertEq(baseAmt, got);
        assertEq(q, 6_999_650);
        assertEq(fee, 350);
        vm.revertToState(snap);
        address u = _plain(T + 1, true, 5 * LOT);
        address v = _plain(T - 1, true, 5 * LOT);
        vm.recordLogs();
        vm.prank(taker);
        uint256 recv;
        (got, recv) = book.take(
            OloOps.key(c),
            OloOps.poolList(bytes.concat(_poolEntry(u), _poolEntry(v))),
            OloOps.tagW(c, OloOps.quoteW(false, 7_000_000, 0))
        );
        assertEq(got, 5_000_000 + 2_000_302);
        assertEq(recv, 6_999_998);
        (, baseAmt, q, fee,) = _takeLog(vm.getRecordedLogs());
        assertEq(q, 7_000_349);
        assertEq(fee, 351);
    }

    // ------------------------------------------------------------- q orders

    /// 1.234567891234 ETH resting as 123,456,789 units of 10^10 wei (23.4567 quote wei a unit): 1 USDC buys 42,623
    /// units, the quote 999,795 and fee 200 rounded up, 5 quote wei left, less than a unit with its fee (23.46) and 1
    /// wei. The walk goes on past the order it stopped short at: a q 0 order after it (1e9 wei, units of one wei)
    /// fills whole with what is left, and 2 quote wei remain. (On an ETH/USDC market with no minQuote: the q 0 order
    /// is worth 2.3 quote wei.)
    function test_q_order_and_the_walk_after_it() public {
        ce = book.configOf(book.listMarketQuote(address(eth), address(usdc), 200, 6, 0, 0));
        address a = _trader();
        vm.startPrank(a);
        book.place(OloOps.key(ce), OloOps.placeW(false, ETH_2345, 1_234_567_891_234_000_000, 1, 0));
        book.place(OloOps.key(ce), OloOps.placeW(false, ETH_2345, 1e9, 2, 0));
        vm.stopPrank();
        uint256 snap = vm.snapshotState();
        vm.prank(taker);
        (uint256 got, uint256 cost) =
            book.take(OloOps.key(ce), _one(1, ETH_2345), OloOps.tagW(ce, OloOps.quoteW(true, 1_000_000, 0)));
        assertEq(got, 42_623 * 1e10);
        assertEq(cost, 999_995);
        vm.revertToState(snap);
        bytes memory list = OloOps.poolList(bytes.concat(OloOps.poolEntry(1, ETH_2345), OloOps.poolEntry(2, ETH_2345)));
        vm.prank(taker);
        (got, cost) = book.take(OloOps.key(ce), list, OloOps.tagW(ce, OloOps.quoteW(true, 1_000_000, 0)));
        assertEq(got, 42_623 * 1e10 + 1e9, "the q 0 order whole");
        assertEq(cost, 999_998);
    }

    // ---------------------------------------------------------------- races

    /// A quote-mode list built from a view that changed before it ran: the first ask was taken by someone else, the
    /// second repriced worse (both skipped), the third repriced better (it fills at its own, lower price: more units for
    /// the same amount), the fourth as seen. What the take returns is all a router needs to check its slippage.
    function test_orders_eaten_or_repriced_before_the_take() public {
        address a1 = _plain(T + 1, false, 5 * LOT);
        address a2 = _plain(T + 2, false, 5 * LOT);
        address a3 = _plain(T + 3, false, 5 * LOT);
        address a4 = _plain(T + 4, false, 5 * LOT);
        bytes memory list =
            OloOps.poolList(bytes.concat(_poolEntry(a1), _poolEntry(a2), _poolEntry(a3), _poolEntry(a4)));
        // the races: a1 taken whole by another taker, a2 moved up a tick, a3 moved down two
        address other = _maker();
        vm.prank(other);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a1)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0)));
        vm.prank(a2);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[a2], T + 3, 5 * LOT, 0)));
        vm.prank(a3);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[a3], T + 1, 5 * LOT, 0)));
        // 7,000,000 quote wei: a3's 5 LOT at T + 1 (5,000,050) and what is left at T + 4 (1.00004 a base wei)
        vm.prank(taker);
        (uint256 got, uint256 cost) = book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.quoteW(true, 7_000_000, 0)));
        (, uint256 open,,,) = book.orderOf(c, posOf[a3]);
        assertEq(open, 0, "a3 at its better tick, whole");
        (, open,,,) = book.orderOf(c, posOf[a2]);
        assertEq(open, 5 * LOT, "a2 repriced worse: skipped");
        assertLe(cost, 7_000_000);
        // the reference's view of the same walk: a3 then a4
        TakeRef.Take memory t = TakeRef.Take(true, true, 7_000_000, 50);
        TakeRef.Walk memory w;
        TakeRef.fill(w, t, 5 * LOT, 0, T + 1);
        TakeRef.fill(w, t, 5 * LOT, 0, T + 4);
        (,, uint256 qa,) = TakeRef.finish(w, t);
        assertEq(got, w.base);
        assertEq(cost, qa);
    }

    // ---------------------------------------------------------- batch slots

    /// A quote-mode buy over a batch slot's four asks (5 LOT each at T + 1 .. T + 4): the first three whole, the
    /// fourth the most the rest affords; the slot's settlement word untouched; the maker's claim pays the fills.
    function test_quote_mode_over_a_batch_slot() public {
        address z = _maker();
        vm.prank(z);
        _mb(c, OloOps.postW(false, 7, T + 1, 5 * LOT, 4));
        (, uint256 set0) = book.batchOf(c, z, 7);
        bytes memory list = OloOps.batchList(OloOps.slotGroupAt(z, 7, 0xf, T + 4));
        vm.prank(taker);
        (uint256 got, uint256 cost) = book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.quoteW(true, 18_000_000, 0)));
        TakeRef.Take memory t = TakeRef.Take(true, true, 18_000_000, 50);
        TakeRef.Walk memory w;
        uint256[4] memory xs;
        for (uint256 i; i < 4; ++i) {
            xs[i] = TakeRef.fill(w, t, 5 * LOT, 0, T + 1 + i);
        }
        (,, uint256 qa,) = TakeRef.finish(w, t);
        assertEq(xs[0] + xs[1] + xs[2], 15 * LOT, "three whole");
        assertGt(xs[3], 0);
        assertLt(xs[3], 5 * LOT, "the fourth stopped short");
        assertEq(got, w.base);
        assertEq(cost, qa);
        assertLe(cost, 18_000_000);
        (uint256 word, uint256 set1) = book.batchOf(c, z, 7);
        assertEq(set1, set0, "a take writes the main word only");
        assertEq((word >> (2 + 61 * 3 + 31)) & ((1 << 30) - 1), 5 * LOT - xs[3], "the fourth's open units");
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CLAIM, 7, 0, 0));
        _solvent();
    }

    // -------------------------------------------------------------- wallets

    /// Through the wallet: the buy pulls exactly the quote and fee it returns and pushes the base; the sell pulls the
    /// base and pushes exactly the quote less fee.
    function test_quote_mode_through_the_wallet() public {
        address a = _trader();
        vm.startPrank(a);
        book.place(OloOps.key(cb), OloOps.placeW(false, BTC_100K, 1e8, 1, 0));
        book.place(OloOps.key(cb), OloOps.placeW(true, BTC_100K - 100, 1e8, 2, 0));
        vm.stopPrank();
        uint256 u0 = usdc.balanceOf(taker);
        uint256 b0 = btc.balanceOf(taker);
        vm.prank(taker);
        (uint256 got, uint256 cost) = book.take(
            OloOps.key(cb), _one(1, BTC_100K), OloOps.tagW(cb, OloOps.quoteW(true, 12_345_678_901, OloOps.WALLET))
        );
        assertEq(u0 - usdc.balanceOf(taker), cost);
        assertEq(btc.balanceOf(taker) - b0, got);
        assertLe(cost, 12_345_678_901);
        u0 = usdc.balanceOf(taker);
        b0 = btc.balanceOf(taker);
        vm.prank(taker);
        uint256 sold;
        (sold, got) = book.take(
            OloOps.key(cb), _one(2, BTC_100K - 100), OloOps.tagW(cb, OloOps.quoteW(false, 9_876_543_210, OloOps.WALLET))
        );
        assertEq(usdc.balanceOf(taker) - u0, got);
        assertEq(b0 - btc.balanceOf(taker), sold);
        assertLe(got, 9_876_543_210);
        _solvent();
    }

    // ------------------------------------------------------- fill-or-kill

    /// Fill-or-kill in quote mode on a sell: what is left is the amount less what the sell receives. 49,990,000,999
    /// receives 49,990,000,000 (999 left): maxLeft 999 passes, 998 reverts.
    function test_sell_fill_or_kill_in_quote() public {
        address a = _trader();
        vm.prank(a);
        book.place(OloOps.key(cb), OloOps.placeW(true, BTC_100K, 1e8, 1, 0));
        uint256 snap = vm.snapshotState();
        vm.prank(taker);
        (, uint256 got) = book.take(
            OloOps.key(cb),
            _one(1, BTC_100K),
            OloOps.tagW(cb, OloOps.takeW(false, 49_990_000_999, OloOps.QUOTE | OloOps.FOK, 999))
        );
        assertEq(got, 49_990_000_000);
        vm.revertToState(snap);
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.FokNotFilled.selector);
        book.take(
            OloOps.key(cb),
            _one(1, BTC_100K),
            OloOps.tagW(cb, OloOps.takeW(false, 49_990_000_999, OloOps.QUOTE | OloOps.FOK, 998))
        );
    }

    // ------------------------------------------------------------- the grid

    /// The largest amount, 2^112 - 1 quote wei (about 5.19e33), buys near the top of the grid (decade 70, P = 1e32
    /// quote wei a base wei, 1.5e32 with a 50% fee) the most it affords: 34 base wei, 5.1e33, within the amount and
    /// with less than one base wei's quote and fee left.
    function test_largest_amount_near_the_top_of_the_grid() public {
        MarketWord top = book.configOf(book.listMarketQuote(address(base), address(quote), 500_000, 6, 0, 0));
        uint256 tick = 70 * PriceGrid.PER_DECADE; // mantissa 100,000 x 10^27
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(top), OloOps.placeW(false, tick, 1e6, 1, 0));
        uint256 amount = (1 << 112) - 1;
        quote.mint(taker, 1 << 113);
        vm.prank(taker);
        (uint256 got, uint256 cost) =
            book.take(OloOps.key(top), _one(1, tick), OloOps.tagW(top, OloOps.quoteW(true, amount, OloOps.WALLET)));
        assertEq(got, 34);
        assertEq(cost, 34 * 15e31);
        assertLt(amount - cost, 15e31, "less than a base wei with its fee left");
    }

    /// Never more than the amount, over the whole grid and every fee up to 100%: one to three orders at random ticks
    /// around a random decade boundary (decades 4 to 73, the makers' part of the grid) and random sizes (q 0 to 10), a
    /// random amount, a buy or a sell; the OLO EVM contract's units equal the reference's (the largest whole units the
    /// specification allows, order by order), it pays or receives what the reference says and at most the amount, and
    /// where the budget stopped the walk less than a unit with its fee (and 1 or 2 wei) is left (below a fee of 100%).
    /// A sell whose budget passes 2^126 (TakeRef.budgetRefused) is refused AmountOverflow at its first order.
    function testFuzz_quote_mode_never_exceeds(uint256 seed, uint8 feeSel, bool buy) public {
        uint24[10] memory fees = [uint24(0), 1, 50, 3_000, 499_999, 500_000, 999_938, 999_939, 999_999, 1_000_000];
        uint24 ppm = fees[feeSel % 10];
        MarketWord mc = book.configOf(book.listMarketQuote(address(base), address(quote), ppm, 6, 0, 0));
        uint256 d = 5 + seed % 69; // a boundary from decade 4 / 5 up: every tick around it at or above the floor
        address a = _maker();
        base.mint(a, 1e40);
        quote.mint(a, 1e40);
        quote.mint(taker, 1e40);
        base.mint(taker, 1e40);
        uint256 n = 1 + (seed >> 8) % 3;
        bytes memory entries;
        TakeRef.Take memory t;
        t.buy = buy;
        t.inQuote = true;
        t.feePpm = ppm;
        uint256[3] memory ticks;
        uint256[3] memory amounts;
        uint256 worth;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            ticks[i] = d * PriceGrid.PER_DECADE - 3 + r % 7;
            if (ticks[i] > PriceGrid.MAX_TICK) ticks[i] = PriceGrid.MAX_TICK - r % 3;
            amounts[i] = (1 + (r >> 8) % 999_999) * 10 ** ((r >> 32) % 11);
            // a bid at the top of the grid escrows its quote: keep it within the wallet
            if (!buy && PriceGrid.quoteUp(amounts[i], ticks[i]) > 1e39) amounts[i] = 1 + (r >> 8) % 1_000;
            vm.prank(a);
            book.place(OloOps.key(mc), OloOps.placeW(!buy, ticks[i], amounts[i], uint32(i), 0x02));
            entries = bytes.concat(entries, OloOps.poolEntry(uint32(i), ticks[i]));
            worth += PriceGrid.quoteDown(amounts[i], ticks[i]);
        }
        // an amount from a wei to about twice what the orders are worth, below 2^112
        t.amount = 1 + (worth == 0 ? 0 : uint256(keccak256(abi.encode(seed, "amount"))) % (2 * worth + 2));
        if (t.amount >= 1 << 112) t.amount = (1 << 112) - 1;
        TakeRef.Walk memory w;
        if (TakeRef.budgetRefused(t)) {
            // every order is open, on the other side and at its entry's tick: the first one refuses the budget
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.AmountOverflow.selector);
            book.take(
                OloOps.key(mc), OloOps.poolList(entries), OloOps.tagW(mc, OloOps.quoteW(buy, t.amount, OloOps.WALLET))
            );
            return;
        }
        for (uint256 i; i < n; ++i) {
            (uint256 tick, uint256 open,,,) = book.orderOf(mc, uint32(i));
            uint256 word = book.orderWord(mc, uint32(i));
            uint256 q = (word >> 26) & 0x7f;
            TakeRef.fill(w, t, open / 10 ** q, q, tick);
        }
        (,, uint256 qa, bool below) = TakeRef.finish(w, t);
        vm.prank(taker);
        if (w.count != 0 && below) {
            vm.expectRevert(IOloBookBase.SellBelowFee.selector);
            book.take(
                OloOps.key(mc), OloOps.poolList(entries), OloOps.tagW(mc, OloOps.quoteW(buy, t.amount, OloOps.WALLET))
            );
            return;
        }
        (uint256 got, uint256 amt) = book.take(
            OloOps.key(mc), OloOps.poolList(entries), OloOps.tagW(mc, OloOps.quoteW(buy, t.amount, OloOps.WALLET))
        );
        assertEq(got, w.base, "the reference's units");
        assertEq(amt, qa, "the reference's quote amount");
        assertLe(amt, t.amount, "never more than the amount");
        assertTrue(TakeRef.leftWithinOneUnit(w, t, t.amount - amt), "less than a unit left where it stopped");
    }

    /// With no fee a buy's budget is the amount itself: 1,000,000 quote wei buys exactly 1,000,000 base wei at P = 1
    /// (tick T, decade 38's bottom) and pays exactly the amount; 999,999 buys one less.
    function test_no_fee_buy_fills_exactly_the_amount() public {
        MarketWord free = book.configOf(book.listMarketQuote(address(base), address(quote), 0, 6, 1, 0));
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(free), OloOps.placeW(false, T, 5e6, 1, 0));
        uint256 snap = vm.snapshotState();
        vm.prank(taker);
        (uint256 got, uint256 paid) =
            book.take(OloOps.key(free), _one(1, T), OloOps.tagW(free, OloOps.quoteW(true, 1_000_000, 0)));
        assertEq(got, 1_000_000);
        assertEq(paid, 1_000_000);
        vm.revertToState(snap);
        vm.prank(taker);
        (got, paid) = book.take(OloOps.key(free), _one(1, T), OloOps.tagW(free, OloOps.quoteW(true, 999_999, 0)));
        assertEq(got, 999_999);
        assertEq(paid, 999_999);
    }

    /// A walk that drops six decades re-aligns its budget there, and the finer alignment holds what the coarser one
    /// floored away: a sell of at most 1,001,953 quote wei (50 ppm, Q* = 1,001,953 / 0.99995 = 1,002,003.1001...) into a
    /// bid of 10 base wei at P = 100,000 (decade 43, whole wei) and one at P = 0.1 (decade 37): the first fills whole
    /// (1,000,000), the second 20,031 base wei (2,003.1 quote wei), the most within Q*. A cap carried down from decade
    /// 43 instead (floor(Q*) x 10^6) would stop at 20,030.
    function test_a_lower_decade_refines_the_budget() public {
        address b1 = _maker();
        vm.startPrank(b1);
        book.place(OloOps.key(c), OloOps.placeW(true, 38_700_000, 10, 1, 0));
        book.place(OloOps.key(c), OloOps.placeW(true, 33_300_000, 1e7, 2, 0));
        vm.stopPrank();
        bytes memory list =
            OloOps.poolList(bytes.concat(OloOps.poolEntry(1, 38_700_000), OloOps.poolEntry(2, 33_300_000)));
        vm.prank(taker);
        (uint256 sold, uint256 got) = book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.quoteW(false, 1_001_953, 0)));
        assertEq(sold, 10 + 20_031);
        assertEq(got, 1_001_952);
    }

    /// The largest base-mode amount, 2^112 - 1, is base mode: the walk tells quote mode by `remaining` above 2^112 - 1
    /// (quote mode starts it at 2^256 - 1), not at it. A buy of everything listed fills one base wei at the top of the
    /// grid, which costs 999,999e30 quote wei, more than 2^112 - 1: read as a quote budget it would fill nothing.
    function test_the_largest_base_amount_is_base_mode() public {
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, PriceGrid.MAX_TICK, 1, 1, 0));
        quote.mint(taker, 2e36);
        vm.prank(taker);
        (uint256 got, uint256 paid) = book.take(
            OloOps.key(c),
            _one(1, PriceGrid.MAX_TICK),
            OloOps.tagW(c, OloOps.takeW(true, (1 << 112) - 1, OloOps.WALLET))
        );
        assertEq(got, 1);
        assertEq(paid, 999_999e30 + 999_999e30 * 50 / 1e6);
    }

    /// The Take event's numbers from recorded logs.
    function _takeLog(Vm.Log[] memory logs)
        internal
        pure
        returns (uint256 packed, uint256 baseAmt, uint256 q, uint256 fee, bytes memory fills)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IOloBookBase.Take.selector) {
                return abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bytes));
            }
        }
        revert("no Take");
    }
}
