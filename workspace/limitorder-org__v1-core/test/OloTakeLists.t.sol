// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

/// How a list builder writes a take's list, on the fixture: P = 1 at T, one step 0.00001, fee 50 ppm, LOT 1e6 base wei.
/// - A ladder: the entries from the best price, each entry's tick the tick seen at the next entry, the last entry's
///   the taker's limit. A pool position is anyone's once its order is gone, and a take fills in the list's order: with
///   the limit in every entry, whoever places at a dead position the list names first fills there at the limit, ahead
///   of the cheaper orders behind it. A ladder skips that order and still fills a requote no worse than the next.
/// - A dust bid: what a fill leaves of a bid can be worth under 2 quote wei. A sell whose fills are worth Q receives
///   floor(Q) - ceil(Q x fee), so a sell that fills only the dust reverts SellBelowFee, a takeThenRest's rest with it.
///   The builder leaves the dust out when it would be the only fill; beside a real bid it is swept.
contract OloTakeListsTest is OloBase {
    /// The taker's limit: P = 1.01.
    uint256 constant LIMIT = T + 1000;

    function setUp() public {
        _deploy();
    }

    /// Ask A, 1 LOT at P = 1.00000, and ask B, 10 LOT at P = 1.00001, each in its own position.
    function _twoAsks() internal returns (address a, uint32 posA, uint32 posB) {
        a = _plain(T, false, LOT);
        address b = _plain(T + 1, false, 10 * LOT);
        (posA, posB) = (posOf[a], posOf[b]);
    }

    /// The taker buys 1 LOT over `list` from its wallet; returns what it paid, quote and fee.
    function _buyLot(bytes memory list) internal returns (uint256 paid) {
        vm.prank(taker);
        (uint256 got, uint256 q) =
            book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, LOT, OloOps.WALLET)));
        assertEq(got, LOT, "1 LOT bought");
        return q;
    }

    /// A's order goes before the take lands, and someone else places 1 LOT at the taker's limit in A's position. With
    /// the limit in every entry the take fills that order first: 1,010,000 and a fee of 51, where B would have filled
    /// the LOT for 1,000,010 and 51 (9,990 more, 1%). A ladder bounds A's entry by B's tick: the order in A's position
    /// is skipped and B fills.
    function test_a_ladder_skips_an_order_placed_at_a_dead_position() public {
        (address a, uint32 posA, uint32 posB) = _twoAsks();
        vm.prank(a);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posA, 0)));
        address other = _maker();
        vm.prank(other);
        book.place(OloOps.key(c), OloOps.placeW(false, LIMIT, LOT, posA, 0));
        uint256 snap = vm.snapshotState();
        bytes memory limitList =
            OloOps.poolList(bytes.concat(OloOps.poolEntry(posA, LIMIT), OloOps.poolEntry(posB, LIMIT)));
        assertEq(_buyLot(limitList), 1_010_051, "the limit in every entry: the order at the limit fills first");
        vm.revertToState(snap);
        bytes memory ladder =
            OloOps.poolList(bytes.concat(OloOps.poolEntry(posA, T + 1), OloOps.poolEntry(posB, LIMIT)));
        assertEq(_buyLot(ladder), 1_000_061, "a ladder: B fills");
        (, uint256 open,,,) = book.orderOf(c, posA);
        assertEq(open, LOT, "the order at the limit untouched");
    }

    /// A ladder still fills a requote no worse than the next entry's tick: A requoted to 1.00001 fills there; requoted
    /// to 1.00002 it is skipped and B fills at 1.00001.
    function test_a_ladder_fills_a_requote_up_to_the_next_entry() public {
        (address a, uint32 posA, uint32 posB) = _twoAsks();
        bytes memory ladder =
            OloOps.poolList(bytes.concat(OloOps.poolEntry(posA, T + 1), OloOps.poolEntry(posB, LIMIT)));
        for (uint256 step = 1; step <= 2; ++step) {
            uint256 snap = vm.snapshotState();
            vm.prank(a);
            book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posA, T + step, LOT, 0)));
            assertEq(_buyLot(ladder), 1_000_061, "1 LOT at 1.00001");
            (, uint256 open,,,) = book.orderOf(c, posA);
            assertEq(open, step == 1 ? 0 : LOT, step == 1 ? "A filled at 1.00001" : "A at 1.00002 skipped");
            vm.revertToState(snap);
        }
    }

    /// A dust bid: a sell of 999,999 into a bid of 1 LOT at P = 1 leaves 1 base wei open, worth 1 quote wei. A sell
    /// that fills only it receives floor(1) - ceil(0.00005) = 0: SellBelowFee. A takeThenRest whose list names only the
    /// dust reverts whole, its rest with it; with an empty list the same call rests all of it.
    function test_a_dust_bid_refuses_a_sell_that_fills_only_it() public {
        address mk = _plain(T, true, LOT);
        bytes memory list = OloOps.poolList(_poolEntry(mk));
        vm.prank(taker);
        book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(false, LOT - 1, OloOps.WALLET)));
        (, uint256 open,,,) = book.orderOf(c, posOf[mk]);
        assertEq(open, 1, "the dust left");
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.SellBelowFee.selector);
        book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(false, 1, OloOps.WALLET)));
        address seller = _maker();
        uint256 params = OloOps.tagW(c, OloOps.restW(false, 5 * LOT, T + 10, 0, _pos()));
        vm.prank(seller);
        vm.expectRevert(IOloBookBase.SellBelowFee.selector);
        book.takeThenRest(OloOps.key(c), list, params);
        vm.prank(seller);
        (,, uint256 rested,) = book.takeThenRest(OloOps.key(c), "", params);
        assertEq(rested, 5 * LOT, "an empty list rests all of it");
    }

    /// The dust on a market of the deploy script's tMEME/tUSDC parameters (1,300 ppm, 4 figures, minQuote 1e6; the
    /// tokens' decimals do not enter): a bid of 1e22 base wei at P = 1.001e-16 escrows 1,001,000 quote wei (1.001 USDC),
    /// and a sell leaves it units of 1e13 base wei, 0.001001 quote wei each. 1,998 units left (1.999998 quote wei)
    /// refuse a sell that fills only them; 1,999 (2.000999) are sold for 2 less a fee of 1.
    function test_the_dust_threshold_on_a_meme_market() public {
        MarketWord mc = book.configOf(book.listMarketQuote(address(base), address(quote), 1300, 4, 1e6, 0));
        uint256 tick = 19_800_100; // decade 22, mantissa 100,100: P = 1.001e-16
        for (uint256 left = 1998; left <= 1999; ++left) {
            address mk = _maker();
            uint32 pos = _pos();
            vm.prank(mk);
            book.place(OloOps.key(mc), OloOps.placeW(true, tick, 1e22, pos, 0));
            bytes memory list = OloOps.poolList(OloOps.poolEntry(pos, tick));
            vm.prank(taker);
            book.take(OloOps.key(mc), list, OloOps.tagW(mc, OloOps.takeW(false, 1e22 - left * 1e13, OloOps.WALLET)));
            vm.prank(taker);
            if (left == 1998) vm.expectRevert(IOloBookBase.SellBelowFee.selector);
            (uint256 b, uint256 q) =
                book.take(OloOps.key(mc), list, OloOps.tagW(mc, OloOps.takeW(false, 1e24, OloOps.WALLET)));
            if (left == 1999) {
                assertEq(b, 1999 * 1e13, "the 1,999 units sold");
                assertEq(q, 1, "quote 2 less the fee of 1");
            }
        }
    }

    /// Beside a real bid the dust is swept: 3 LOT and the dust's 1 wei sold, quote 3,000,001 less its fee 151.
    function test_a_dust_bid_is_swept_with_a_real_bid() public {
        address mk = _plain(T, true, LOT);
        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(_poolEntry(mk)), OloOps.tagW(c, OloOps.takeW(false, LOT - 1, OloOps.WALLET))
        );
        address mk2 = _plain(T, true, 3 * LOT);
        bytes memory list = OloOps.poolList(bytes.concat(_poolEntry(mk), _poolEntry(mk2)));
        vm.prank(taker);
        (uint256 b, uint256 q) =
            book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(false, 5 * LOT, OloOps.WALLET)));
        assertEq(b, 3 * LOT + 1, "the dust and the real bid");
        assertEq(q, 3 * LOT + 1 - 151, "quote less the fee: ceil(3,000,001 x 50 / 1e6) = 151");
    }
}
