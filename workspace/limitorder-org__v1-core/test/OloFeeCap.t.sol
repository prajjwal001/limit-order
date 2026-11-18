// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {TakeRef} from "./TakeRef.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

using MarketLib for MarketWord;

/// A taker fee up to 100% (MarketLib.MAX_FEE_PPM, 1,000,000 ppm), on the fixture's tokens:
/// - a version at 100% settles no taker sell that fills: SellBelowFee at the end (a quote-mode sell may revert
///   AmountOverflow first, below). One that fills nothing succeeds, or fails a strict fill-or-kill. A buy there pays
///   2 x ceil(Q). An older version keeps its own fee: its bids still take sells.
/// - a quote-mode sell's budget A / (1 - f), A x 10^6 at 100%, is exact, a fraction. One whose whole part passes 2^126
///   reverts AmountOverflow at the first order the walk reaches that is open, on the other side and within its entry's
///   tick, before a unit there is priced. Only a fee of 999,939 ppm or more reaches it (A below 2^112).
contract OloFeeCapTest is OloBase {
    uint256 constant FLOOR = 3_600_000; // decade 4: P = 1e-34
    uint256 constant HALF = 33_700_000; // decade 37, mantissa 500,000: P = 0.5
    uint256 constant P2_5 = 34_350_000; // decade 38, mantissa 250,000: P = 2.5
    uint256 constant P1E7 = 40_500_000; // decade 45: P = 1e7
    uint256 constant P1E10 = 43_200_000; // decade 48: P = 1e10
    uint256 constant TOP = 65_700_000; // decade 73: P = 1e35
    /// Adjacent amounts at 1 - f = 1 ppm (999,999 ppm, and 100%): A0 x 10^6 = 2^126 - 52,864 passes the limit, A1 x
    /// 10^6 = 2^126 + 947,136 does not.
    uint256 constant A0 = 85_070_591_730_234_615_865_843_651_857_942;
    uint256 constant A1 = A0 + 1;

    address mk;

    function setUp() public {
        _deploy();
        mk = _maker();
        // the escrow of bids up to the top of the grid, through the wallet
        base.mint(mk, 1e40);
        quote.mint(mk, 1e62);
    }

    function _market(uint24 fee) internal returns (MarketWord) {
        return book.configOf(book.listMarketQuote(address(base), address(quote), fee, 6, 0, 0));
    }

    /// An order of `amount` base wei at `tick` in position `pos` of `mc`'s market, escrowed from the maker's wallet.
    function _rest(MarketWord mc, bool bid, uint256 tick, uint256 amount, uint32 pos) internal {
        vm.prank(mk);
        book.place(OloOps.key(mc), OloOps.placeW(bid, tick, amount, pos, 0x02));
    }

    function _one(uint32 pos, uint256 tick) internal pure returns (bytes memory) {
        return OloOps.poolList(OloOps.poolEntry(pos, tick));
    }

    function _take(MarketWord mc, bytes memory list, uint256 params) internal returns (uint256, uint256) {
        vm.prank(taker);
        return book.take(OloOps.key(mc), list, OloOps.tagW(mc, params));
    }

    function _takeReverts(MarketWord mc, bytes memory list, uint256 params, bytes4 err) internal {
        vm.prank(taker);
        vm.expectRevert(err);
        book.take(OloOps.key(mc), list, OloOps.tagW(mc, params));
    }

    // ================================================================ a version at 100%

    /// At 100% a sell that fills is refused: in base mode, in quote mode and as a takeThenRest. One that fills nothing
    /// succeeds: an empty list, or a quote-mode amount of 1 whose budget, 10^6, is below one base wei's quote at P = 1e7.
    /// A strict fill-or-kill refuses that one.
    function test_a_sell_that_fills_at_100_percent_is_refused() public {
        MarketWord mc = _market(1_000_000);
        _rest(mc, true, T, 1e12, 1);
        bytes memory list = _one(1, T);
        _takeReverts(mc, list, OloOps.takeW(false, 1e6, OloOps.WALLET), IOloBookBase.SellBelowFee.selector);
        _takeReverts(mc, list, OloOps.quoteW(false, 1e6, OloOps.WALLET), IOloBookBase.SellBelowFee.selector);
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.SellBelowFee.selector);
        book.takeThenRest(OloOps.key(mc), list, OloOps.tagW(mc, OloOps.restW(false, 1e6, T + 10, OloOps.WALLET, 7)));
        (uint256 got, uint256 amt) = _take(mc, "", OloOps.takeW(false, 1e6, OloOps.WALLET));
        assertEq(got + amt, 0, "an empty list fills nothing and succeeds");
        _rest(mc, true, P1E7, 1, 2);
        (got, amt) = _take(mc, _one(2, P1E7), OloOps.quoteW(false, 1, OloOps.WALLET));
        assertEq(got + amt, 0, "a unit past the budget: nothing fills, the take succeeds");
        _takeReverts(
            mc,
            _one(2, P1E7),
            OloOps.fokW(false, 1, OloOps.WALLET | OloOps.QUOTE, 0),
            IOloBookBase.FokNotFilled.selector
        );
        (, uint256 open,,,) = book.orderOf(mc, 1);
        assertEq(open, 1e12, "the bid untouched");
    }

    /// At 100% a buy pays its quote and a fee of the same, each rounded up: 2 x ceil(Q). 1 LOT at P = 1 pays 2,000,000;
    /// 1 base wei at P = 0.5 (Q = 0.5) pays 2 wei; in quote mode 4,000,000 quote wei buy exactly 2 LOT. The maker's
    /// claim pays its proceeds and the fee whole (the fixture's maker share, 100%); the pot keeps nothing.
    function test_a_buy_at_100_percent_pays_twice_its_rounded_quote() public {
        MarketWord mc = _market(1_000_000);
        _rest(mc, false, T, LOT, 1);
        _rest(mc, false, HALF, 1, 2);
        _rest(mc, false, T, 3 * LOT, 3);
        (uint256 got, uint256 amt) = _take(mc, _one(1, T), OloOps.takeW(true, LOT, OloOps.WALLET));
        assertEq(got, LOT);
        assertEq(amt, 2 * LOT, "the quote and the fee, 1,000,000 each");
        (got, amt) = _take(mc, _one(2, HALF), OloOps.takeW(true, 1, OloOps.WALLET));
        assertEq(got, 1);
        assertEq(amt, 2, "ceil(0.5) twice");
        (got, amt) = _take(mc, _one(3, T), OloOps.quoteW(true, 4 * LOT, OloOps.WALLET));
        assertEq(got, 2 * LOT, "the budget: n1 = A / 2");
        assertEq(amt, 4 * LOT, "the whole amount");
        uint256 before = _bal(mk, quote);
        vm.prank(mk);
        book.claim(OloOps.key(mc), OloOps.tagW(mc, OloOps.posW(1, 0)));
        assertEq(_bal(mk, quote) - before, 2 * LOT, "the proceeds and the fee");
        assertEq(_pot(quote), 0, "the pot's part: none");
    }

    /// A fee change makes the market's next version and leaves the orders where they rest: at 990,000 a bid takes a
    /// sell after its market moved to 100% (one step), at its own fee; a bid in the version at 100% refuses one. A move
    /// past 100% is BadMarketConfig.
    function test_an_older_version_still_sells_at_its_own_fee() public {
        MarketWord v1 = _market(990_000);
        _rest(v1, true, T, 1e12, 1);
        book.setMarketFee(v1.marketId(), 1_000_000, 0);
        MarketWord v2 = book.configOf(v1.marketId());
        assertEq(v2.feePpm(), 1_000_000);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setMarketFee(v1.marketId(), 1_000_001, 0);
        _rest(v2, true, T, 1e12, 2);
        (uint256 got, uint256 amt) = _take(v1, _one(1, T), OloOps.takeW(false, 1e6, OloOps.WALLET));
        assertEq(got, 1e6);
        assertEq(amt, 1e6 - 990_000, "the quote less version 1's fee, 99%");
        _takeReverts(v2, _one(2, T), OloOps.takeW(false, 1e6, OloOps.WALLET), IOloBookBase.SellBelowFee.selector);
    }

    /// SellBelowFee's condition is exact, floor(Q) <= ceil(Q x f), with no threshold of its own: 100 base wei at P =
    /// 1.9899 (Q = 198.99) are refused at 99% (floor 198, fee ceil(197.0001) = 198) and at P = 1.99 (Q = 199) receive 1;
    /// one base wei at P = 2.5 is refused at 50% (floor 2, fee 2) and at P = 3 receives 1, though Q (1 - f) = 1.25.
    function test_the_sell_below_fee_condition_is_exact() public {
        MarketWord m99 = _market(990_000);
        MarketWord m50 = _market(500_000);
        _rest(m99, true, 34_298_990, 100, 1); // P = 1.9899
        _rest(m99, true, 34_299_000, 100, 2); // P = 1.99
        _rest(m50, true, P2_5, 1, 1);
        _rest(m50, true, 34_400_000, 1, 2); // P = 3
        _takeReverts(
            m99, _one(1, 34_298_990), OloOps.takeW(false, 100, OloOps.WALLET), IOloBookBase.SellBelowFee.selector
        );
        (uint256 got, uint256 amt) = _take(m99, _one(2, 34_299_000), OloOps.takeW(false, 100, OloOps.WALLET));
        assertEq(got, 100);
        assertEq(amt, 1, "199 less ceil(197.01) = 198");
        _takeReverts(m50, _one(1, P2_5), OloOps.takeW(false, 1, OloOps.WALLET), IOloBookBase.SellBelowFee.selector);
        (got, amt) = _take(m50, _one(2, 34_400_000), OloOps.takeW(false, 1, OloOps.WALLET));
        assertEq(got, 1);
        assertEq(amt, 1, "3 less ceil(1.5) = 2");
    }

    // ================================================================ a quote-mode sell's budget past 2^126

    /// The limit at adjacent amounts, at 1 - f = 1 ppm: A0's budget passes the check and A1's is refused. At 999,999
    /// ppm A0 sells the 1e12 base wei the bid holds and receives 1e12 - ceil(1e12 x 0.999999) = 1,000,000; at 100% it
    /// fills and is refused SellBelowFee. (n / y = 2^126 exactly is reachable by no amount: no multiple of 10^6 lies in
    /// [2^126 y, 2^126 y + y - 1] for y below 62.)
    function test_the_budget_limit_at_adjacent_amounts() public {
        assertEq(A0 * 1e6, (1 << 126) - 52_864);
        assertEq(A1 * 1e6, (1 << 126) + 947_136);
        MarketWord m9 = _market(999_999);
        MarketWord m10 = _market(1_000_000);
        _rest(m9, true, T, 1e12, 1);
        _rest(m10, true, T, 1e12, 1);
        uint256 snap = vm.snapshotState();
        (uint256 got, uint256 amt) = _take(m9, _one(1, T), OloOps.quoteW(false, A0, OloOps.WALLET));
        assertEq(got, 1e12);
        assertEq(amt, 1_000_000);
        vm.revertToState(snap);
        _takeReverts(m9, _one(1, T), OloOps.quoteW(false, A1, OloOps.WALLET), IOloBookBase.AmountOverflow.selector);
        _takeReverts(m10, _one(1, T), OloOps.quoteW(false, A0, OloOps.WALLET), IOloBookBase.SellBelowFee.selector);
        _takeReverts(m10, _one(1, T), OloOps.quoteW(false, A1, OloOps.WALLET), IOloBookBase.AmountOverflow.selector);
    }

    /// The first fee that reaches the limit: with the largest amount, 2^112 - 1, 999,938 ppm (1 - f = 62 ppm, a budget
    /// of about 8.37e37) passes and receives 1e12 - ceil(1e12 x 0.999938) = 62,000,000; 999,939 ppm (61 ppm, about
    /// 8.51e37) is refused.
    function test_the_budget_limit_starts_at_999_939() public {
        MarketWord m8 = _market(999_938);
        MarketWord m9 = _market(999_939);
        _rest(m8, true, T, 1e12, 1);
        _rest(m9, true, T, 1e12, 1);
        uint256 most = (1 << 112) - 1;
        (uint256 got, uint256 amt) = _take(m8, _one(1, T), OloOps.quoteW(false, most, OloOps.WALLET));
        assertEq(got, 1e12);
        assertEq(amt, 62_000_000);
        _takeReverts(m9, _one(1, T), OloOps.quoteW(false, most, OloOps.WALLET), IOloBookBase.AmountOverflow.selector);
    }

    /// The limit is met at the first order the walk reaches that is open, on the other side and within its entry's
    /// tick, before a unit there is priced: an ask (the taker's own side), a bid named at a tick above its own (worse
    /// for the seller) and a position never used are passed over; a bid of one unit of 10^25 base wei at P = 1e35
    /// (1e60 quote wei, past any budget) still refuses A1. With the passed-over entries alone the take fills nothing and
    /// succeeds; A0's budget passes and, below that one unit, fills nothing either.
    function test_the_budget_limit_meets_the_first_order_the_walk_reaches() public {
        MarketWord mc = _market(1_000_000);
        _rest(mc, false, T, 1e6, 1);
        _rest(mc, true, T, 1e6, 2);
        _rest(mc, true, TOP, 1e25, 4);
        bytes memory passed = bytes.concat(OloOps.poolEntry(1, T), OloOps.poolEntry(2, T + 5), OloOps.poolEntry(3, T));
        (uint256 got, uint256 amt) = _take(mc, OloOps.poolList(passed), OloOps.quoteW(false, A1, OloOps.WALLET));
        assertEq(got + amt, 0, "no order reached: no refusal");
        bytes memory list = OloOps.poolList(bytes.concat(passed, OloOps.poolEntry(4, TOP)));
        _takeReverts(mc, list, OloOps.quoteW(false, A1, OloOps.WALLET), IOloBookBase.AmountOverflow.selector);
        (got, amt) = _take(mc, list, OloOps.quoteW(false, A0, OloOps.WALLET));
        assertEq(got + amt, 0, "a unit past the budget: nothing fills");
    }

    /// Fills 69 decades apart (a 1-wei bid at the makers' floor, decade 4; 1e9 base wei at P = 1; units of 10^4 base
    /// wei at P = 1e35, each 1e39 quote wei), at 999,999 ppm. With A0 the budget passes and stays exact: the unit at the
    /// top is past it (1e39 > A0 x 10^6), so the take sells the first two and receives 1e9 - ceil(999,999,000 + 1e-28)
    /// = 999, as TakeRef has it. With the largest amount, 2^112 - 1 (a budget of about 5.19e39), it is refused at the
    /// first order, and so is the list of the first two alone, which it could have filled: the limit refuses a take
    /// whose budget passes it, whatever the list holds.
    function test_the_budget_limit_across_decades() public {
        MarketWord mc = _market(999_999);
        _rest(mc, true, FLOOR, 1, 1);
        _rest(mc, true, T, 1e9, 2);
        _rest(mc, true, TOP, 1e13, 3);
        bytes memory two = bytes.concat(OloOps.poolEntry(1, FLOOR), OloOps.poolEntry(2, T));
        bytes memory three = OloOps.poolList(bytes.concat(two, OloOps.poolEntry(3, TOP)));
        uint256 most = (1 << 112) - 1;
        _takeReverts(mc, three, OloOps.quoteW(false, most, OloOps.WALLET), IOloBookBase.AmountOverflow.selector);
        _takeReverts(
            mc, OloOps.poolList(two), OloOps.quoteW(false, most, OloOps.WALLET), IOloBookBase.AmountOverflow.selector
        );
        TakeRef.Take memory t = TakeRef.Take({buy: false, inQuote: true, amount: A0, feePpm: 999_999});
        assertFalse(TakeRef.budgetRefused(t));
        TakeRef.Walk memory w;
        TakeRef.fill(w, t, 1, 0, FLOOR);
        TakeRef.fill(w, t, 1e9, 0, T);
        assertEq(TakeRef.fill(w, t, 1e9, 4, TOP), 0, "the unit at the top past the budget");
        (,, uint256 qa, bool below) = TakeRef.finish(w, t);
        assertFalse(below);
        (uint256 got, uint256 amt) = _take(mc, three, OloOps.quoteW(false, A0, OloOps.WALLET));
        assertEq(got, w.base, "the reference's base");
        assertEq(got, 1e9 + 1);
        assertEq(amt, qa, "the reference's quote amount");
        assertEq(amt, 999);
    }

    /// At 100% a quote-mode sell into bids at P = 1e10 (decade 48: whole quotes, the walk's sum aligned at or above 43)
    /// never pays out: a budget within the limit with a unit in reach fills and is refused SellBelowFee; one past it is
    /// refused AmountOverflow; one below a unit's quote fills nothing and succeeds.
    function test_a_full_fee_sell_at_a_high_decade_never_pays_out() public {
        MarketWord mc = _market(1_000_000);
        _rest(mc, true, P1E10, 1e20, 1);
        _rest(mc, true, P1E10, 1e20, 2);
        _rest(mc, true, P1E10 + 7, 1e20, 3);
        bytes memory list = OloOps.poolList(
            bytes.concat(OloOps.poolEntry(1, P1E10), OloOps.poolEntry(2, P1E10), OloOps.poolEntry(3, P1E10 + 7))
        );
        _takeReverts(mc, list, OloOps.quoteW(false, 1e30, OloOps.WALLET), IOloBookBase.SellBelowFee.selector);
        _takeReverts(mc, list, OloOps.quoteW(false, A1, OloOps.WALLET), IOloBookBase.AmountOverflow.selector);
        (uint256 got, uint256 amt) = _take(mc, list, OloOps.quoteW(false, 1e10, OloOps.WALLET));
        assertEq(got + amt, 0, "a budget of 1e16 below a unit's 1e21: nothing fills");
    }

    /// The budget is exact, a fraction: at 333,333 ppm A = 2 gives Q* = 2 x 10^6 / 666,667 = 2.9999985, so one base wei
    /// at P = 2.5 fills and receives floor(2.5) - ceil(0.8333) = 1; a budget floored to 2 would pass it over.
    function test_the_budget_is_exact_not_floored() public {
        MarketWord mc = _market(333_333);
        _rest(mc, true, P2_5, 1, 1);
        (uint256 got, uint256 amt) = _take(mc, _one(1, P2_5), OloOps.quoteW(false, 2, OloOps.WALLET));
        assertEq(got, 1);
        assertEq(amt, 1);
    }
}
