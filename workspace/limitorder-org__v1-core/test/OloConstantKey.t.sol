// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {BatchView} from "./BatchView.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {SettleFlags} from "../src/libraries/Flags.sol";
import {C_TAG_FIELD, MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

using MarketLib for MarketWord;

/// The constant market key: an upstream names its market by K (C without its tag) for the market's whole life. A fee
/// or share change makes the market's next version in place (the id and K stay); every entry that rests an order reads
/// the market's current C and rests there, and takes K and nothing else (UnknownMarket for any other word); a take, a
/// cancel, a claim, a modify and a batch operation other than a post name the version they act in by the tag their
/// params carry in their top 50 bits (the order id a place returns is in that shape), and a wrong tag finds no order:
/// a take fills nothing (no revert, but fill-or-kill), a cancel or a claim is NoOrder, a modify MarketFrozen. Every
/// call here is made as an upstream makes it: K, and the tag where the entry takes it.
contract OloConstantKeyTest is OloBase {
    uint256 constant TK = T + 1; // 100,001: a lot is 1,000,010 quote wei
    uint256 constant P = 1_000_010; // a lot at TK, in quote wei

    MarketWord k; // the fixture market's key

    function setUp() public {
        _deploy();
        k = OloOps.key(c);
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    /// A place by K: the order id it returns (the position 0-31 | the version's tag 206-255) and the C of the version
    /// it rested in (K and the id's tag).
    function _placeK(address a, uint256 tick, bool isBid, uint256 amount, uint32 pos)
        internal
        returns (uint256 orderId, MarketWord placedIn)
    {
        vm.prank(a);
        (orderId,) = book.place(k, OloOps.placeW(isBid, tick, amount, pos, 0));
        placedIn = MarketWord.wrap(MarketWord.unwrap(k) | ((orderId >> 206) << 174));
    }

    /// The params of a cancel or a claim of the order `orderId` names: the id itself, its flags at 32-39.
    function _orderParams(uint256 orderId, uint8 flags) internal pure returns (uint256) {
        return orderId | (uint256(flags) << 32);
    }

    /// A buy of `amount` from position `pos` (named at `tick`) in the version `cv` names, by K and its tag.
    function _buyAt(MarketWord cv, uint32 pos, uint256 tick, uint256 amount) internal returns (uint256, uint256) {
        vm.prank(taker);
        return
            book.take(k, OloOps.poolList(OloOps.poolEntry(pos, tick)), OloOps.tagW(cv, OloOps.takeW(true, amount, 0)));
    }

    function _sellAt(MarketWord cv, uint32 pos, uint256 tick, uint256 amount) internal returns (uint256, uint256) {
        vm.prank(taker);
        return
            book.take(k, OloOps.poolList(OloOps.poolEntry(pos, tick)), OloOps.tagW(cv, OloOps.takeW(false, amount, 0)));
    }

    function _ceilFee(uint256 quoteAmt, uint256 ppm) internal pure returns (uint256) {
        return (quoteAmt * ppm + 999_999) / 1_000_000;
    }

    function _potPart(uint256 fee, uint256 shareBps) internal pure returns (uint256) {
        return fee - fee * shareBps / 10_000;
    }

    /// Everyone leaves (`_everyoneLeaves`): no base wei stays, and exactly `dust` quote wei, the roundings'.
    function _leaveClean(uint256 dust) internal {
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 0, "no base left");
        assertEq(quoteLeft, dust, "quote: the roundings' dust, exactly");
    }

    // ================================================================ the key and the versions

    /// K and the id stay through fee and share changes, each one more version; a place by the same K rests in the
    /// version current at each, and its order id names that version.
    function test_key_stays_and_versions_count() public {
        address a = _maker();
        uint32 id = c.marketId();
        MarketWord[4] memory seen;
        for (uint256 i; i < 4; ++i) {
            if (i == 1) book.setMarketFee(m, 300, 0);
            if (i == 2) book.setMarketMakerShare(m, 2_500);
            if (i == 3) book.setMarketFee(m, 50, 0);
            MarketWord now_ = book.configOf(m);
            assertEq(MarketWord.unwrap(OloOps.key(now_)), MarketWord.unwrap(k), "K stays");
            assertEq(now_.marketId(), id, "the id stays");
            assertEq(now_.version(), i + 1, "one version a change");
            (uint256 orderId, MarketWord placedIn) = _placeK(a, TK, false, LOT, uint32(10 + i));
            assertEq(orderId, _orderId(now_, uint32(10 + i)), "the id: the position and the version's tag");
            assertEq(MarketWord.unwrap(placedIn), MarketWord.unwrap(now_), "the version placed in");
            seen[i] = now_;
        }
        assertEq(book.marketCount(), m, "no market listed");
        // each order rests in its own version: four versions, four C's, one market
        for (uint256 i; i < 4; ++i) {
            (, uint256 open,,,) = book.orderOf(seen[i], uint32(10 + i));
            assertEq(open, LOT);
            for (uint256 j; j < 4; ++j) {
                if (j != i) assertTrue(MarketWord.unwrap(seen[i]) != MarketWord.unwrap(seen[j]));
            }
        }
    }

    /// The registry is the array the layout names: market id's current C is at storage slot MARKETS_SLOT + id, read
    /// straight from storage, after listings and after a change (one helper reads and writes it, so an off-by-one both
    /// ways would pass every other test); an id never listed reads zero there and from `configOf`.
    function test_registry_slot_is_the_array_s() public {
        uint32 m2 = book.listMarketQuote(address(base), address(quote), 70, 6, 1, 0);
        uint32 m3 = book.listMarketQuote(address(quote), address(base), 70, 5, 0, 0);
        book.setMarketFee(m2, 80, 0);
        uint32[3] memory ids = [m, m2, m3];
        for (uint256 i; i < 3; ++i) {
            bytes32 raw = vm.load(address(book), bytes32(MARKETS_SLOT + ids[i]));
            assertEq(raw, bytes32(MarketWord.unwrap(book.configOf(ids[i]))), "MARKETS_SLOT + id holds its C");
            assertEq(uint256(raw) >> 224, ids[i], "its id");
        }
        assertEq(book.configOf(m2).version(), 2, "the change written in place");
        assertEq(vm.load(address(book), bytes32(MARKETS_SLOT + m3 + 1)), bytes32(0), "an id never listed");
        assertEq(MarketWord.unwrap(book.configOf(m3 + 1)), 0);
        assertEq(vm.load(address(book), bytes32(MARKETS_SLOT)), bytes32(0), "id 0 is never a market");
    }

    /// An upstream's whole flow by K and order ids: place, fills, a fee and a share change in between, claim and cancel
    /// by the id. The order settles at its version's fee and share to the wei: the takes pay the version's fee, the
    /// maker gets floor(fee x its share) of each settle and the pot the rest.
    function test_order_settles_at_its_version_to_the_wei() public {
        _setMarketShare(7_000); // version 2: 50 ppm, 70%
        MarketWord v2 = c;
        address a = _maker();
        (uint256 orderId,) = _placeK(a, TK, false, 20 * LOT, 7);
        (, uint256 paid) = _buyAt(v2, 7, TK, 5 * LOT);
        assertEq(paid, 5 * P + 251, "version 2's fee: ceil(5,000,050 x 50 ppm)");
        // version 3 at 300 ppm, version 4 at 20%: neither reaches the order
        _setMarketFee(300);
        _setMarketShare(2_000);
        (, paid) = _buyAt(v2, 7, TK, 5 * LOT);
        assertEq(paid, 5 * P + 251, "still version 2's fee");
        uint256 q0 = _bal(a, quote);
        uint256 pot0 = _pot(quote);
        vm.prank(a);
        uint256 proceeds = book.claim(k, _orderParams(orderId, 0));
        uint256 fee = PriceGrid.feeDown(10 * LOT, TK, 50); // the order's fee, floored once: 500
        assertEq(fee, 500);
        assertEq(proceeds, 10 * P);
        assertEq(_bal(a, quote) - q0, 10 * P + fee * 7_000 / 10_000, "the maker: 70%");
        assertEq(_pot(quote) - pot0, fee - fee * 7_000 / 10_000, "the pot: 30%");
        q0 = _bal(a, quote);
        uint256 b0 = _bal(a, base);
        vm.prank(a);
        book.cancel(k, _orderParams(orderId, 0));
        assertEq(_bal(a, base) - b0, 10 * LOT, "the open half refunded");
        assertEq(_bal(a, quote), q0, "nothing filled since");
        // the two takes' fees, ceil(250.0025) = 251 each, less the one settle's floor(500.005) = 500
        _leaveClean(2);
    }

    /// A share change after the fills and before the settle reaches no filled, unclaimed order: a raise does not pay
    /// the maker more of fills already made, a cut does not take its part, for a pool order and a batch sub-order; the
    /// maker gets its proceeds and floor(fee x s0) of each, the pot the rest.
    function testFuzz_share_change_reaches_no_filled_order(uint16 s0, uint16 s1, uint48 lots) public {
        s0 = uint16(bound(s0, 0, 10_000));
        s1 = uint16(bound(s1, 0, 10_000));
        lots = uint48(bound(lots, 1, 1e6));
        _setMarketShare(s0);
        MarketWord v0 = c;
        address a = _maker();
        (uint256 orderId,) = _placeK(a, TK, false, uint256(lots) * LOT, 3);
        vm.prank(a);
        _mb(k, OloOps.postW(false, 0, TK, uint256(lots) * LOT, 1));
        _buyAt(v0, 3, TK, uint256(lots) * LOT);
        vm.prank(taker);
        book.take(
            k,
            OloOps.batchList(OloOps.slotGroupAt(a, 0, 0x1, TK)),
            OloOps.tagW(v0, OloOps.takeW(true, uint256(lots) * LOT, 0))
        );
        _setMarketShare(s1);
        uint256 fee = PriceGrid.feeDown(uint256(lots) * LOT, TK, 50);
        uint256 pot0 = _pot(quote);
        uint256 q0 = _bal(a, quote);
        vm.startPrank(a);
        book.claim(k, _orderParams(orderId, 0));
        _mb(v0, OloOps.maskW(OloOps.CLAIM, 0, 0, 0));
        vm.stopPrank();
        assertEq(_pot(quote) - pot0, 2 * _potPart(fee, s0), "the pot: both at the share they were placed under");
        assertEq(
            _bal(a, quote) - q0,
            2 * (PriceGrid.quoteDown(uint256(lots) * LOT, TK) + fee * s0 / 10_000),
            "the maker: both fills' proceeds and floor(fee x s0) of each"
        );
        // each take's fee, lots x 50.0005 rounded up, less its order's settle, rounded down: a wei each, none when it
        // is whole (lots a multiple of 2,000)
        _leaveClean((uint256(lots) * 500_005) % 10_000 == 0 ? 0 : 2);
    }

    /// Four versions side by side, every flow to the wei: pool asks and bids, a batch slot, a
    /// sell, a wallet cancel, a takeThenRest across versions (the fills in version 2 at its fee, the rest in version 4,
    /// one debit of the fills, their fee and the rest's escrow), every settle after both changes at its own version's
    /// fee and share, the pot to the wei, and everyone leaving.
    function test_versions_side_by_side_to_the_wei() public {
        // ---- version 2: 50 ppm, 70% to the makers
        _setMarketShare(7_000);
        MarketWord v2 = c;
        address a = _maker();
        address b = _maker();
        (uint256 ask2,) = _placeK(a, TK, false, 10 * LOT, 1);
        (uint256 bid2,) = _placeK(b, TK, true, 10 * LOT, 2);
        vm.prank(a);
        _mb(k, OloOps.postW(false, 0, TK + 1, 4 * LOT, 2)); // asks: 4 lots at TK + 1, 4 lots at TK + 2
        uint256 tq = _bal(taker, quote);
        _buyAt(v2, 1, TK, 3 * LOT);
        assertEq(tq - _bal(taker, quote), 3 * P + _ceilFee(3 * P, 50), "a buy in version 2, at 50 ppm");
        tq = _bal(taker, quote);
        _sellAt(v2, 2, TK, 4 * LOT);
        assertEq(_bal(taker, quote) - tq, 4 * P - _ceilFee(4 * P, 50), "a sell in version 2, at 50 ppm");
        // ---- version 3: 300 ppm, 70%
        _setMarketFee(300);
        MarketWord v3 = c;
        (uint256 ask3,) = _placeK(a, TK, false, 10 * LOT, 1); // the same position number, another version
        vm.prank(b);
        _mb(k, OloOps.postW(true, 0, TK - 1, 4 * LOT, 1)); // a bid of 4 lots at TK - 1, slot 0 of version 3
        tq = _bal(taker, quote);
        _buyAt(v3, 1, TK, 2 * LOT);
        assertEq(tq - _bal(taker, quote), 2 * P + _ceilFee(2 * P, 300), "a buy in version 3, at 300 ppm");
        tq = _bal(taker, quote);
        _buyAt(v2, 1, TK, 2 * LOT);
        assertEq(tq - _bal(taker, quote), 2 * P + _ceilFee(2 * P, 50), "version 2 still fills at 50 ppm");
        tq = _bal(taker, quote);
        _sellAt(v2, 2, TK, 1 * LOT);
        assertEq(_bal(taker, quote) - tq, P - _ceilFee(P, 50), "version 2's bid still fills at 50 ppm");
        // the older version's batch slot fills at its fee: 4 lots at TK + 1 and 1 lot at TK + 2
        tq = _bal(taker, quote);
        vm.prank(taker);
        book.take(
            k, OloOps.batchList(OloOps.slotGroupAt(a, 0, 0x3, TK + 2)), OloOps.tagW(v2, OloOps.takeW(true, 5 * LOT, 0))
        );
        uint256 batchQuote = 4 * (P + 10) + (P + 20);
        assertEq(tq - _bal(taker, quote), batchQuote + _ceilFee(batchQuote, 50), "version 2's batch at 50 ppm");
        // version 3's batch bid: a sell of 3 lots at TK - 1 (1,000,000 a lot), its fee 900 exactly at 300 ppm
        vm.prank(taker);
        (uint256 sold, uint256 recv) = book.take(
            k, OloOps.batchList(OloOps.slotGroupAt(b, 0, 0x1, TK - 1)), OloOps.tagW(v3, OloOps.takeW(false, 3 * LOT, 0))
        );
        assertEq(sold, 3 * LOT);
        assertEq(recv, 3_000_000 - 900, "version 3's batch bid at 300 ppm");
        // ---- version 4: 300 ppm, 25%
        _setMarketShare(2_500);
        MarketWord v4 = c;
        (uint256 bid4,) = _placeK(b, TK, true, 10 * LOT, 5);
        (sold, recv) = _sellAt(v4, 5, TK, 3 * LOT);
        assertEq(recv, 3 * P - _ceilFee(3 * P, 300), "a sell in version 4, at 300 ppm: ceil(900.009) = 901");
        // a takeThenRest across versions
        tq = _bal(taker, quote);
        uint256 tb = _bal(taker, base);
        vm.prank(taker);
        (uint256 got, uint256 paid, uint256 rested, uint256 restId) = book.takeThenRest(
            k, OloOps.poolList(OloOps.poolEntry(1, TK)), OloOps.tagW(v2, OloOps.restW(true, 7 * LOT, TK, 0, 9))
        );
        assertEq(got, 5 * LOT);
        assertEq(rested, 2 * LOT);
        assertEq(paid, 5 * P + _ceilFee(5 * P, 50), "the fills and their fee, version 2's");
        assertEq(tq - _bal(taker, quote), 5 * P + _ceilFee(5 * P, 50) + 2 * P, "one debit: fills, fee, rest's escrow");
        assertEq(_bal(taker, base) - tb, 5 * LOT);
        assertEq(restId, _orderId(v4, 9), "the rest's id: version 4");
        (, uint256 openRest,, bool restIsBid, address restOwner) = book.orderOf(v4, 9);
        assertEq(openRest, 2 * LOT, "the rest in version 4");
        assertTrue(restIsBid && restOwner == taker);
        // ---- settles after both changes, each at its version's fee and share
        uint256 pot0 = _pot(quote);
        uint256 expectedPot;
        // version 2's ask: 10 lots filled (3 + 2 + 5), one claim
        uint256 aq = _bal(a, quote);
        vm.prank(a);
        book.claim(k, _orderParams(ask2, 0));
        uint256 fee = PriceGrid.feeDown(10 * LOT, TK, 50);
        assertEq(_bal(a, quote) - aq, 10 * P + fee * 7_000 / 10_000, "version 2's ask: 70% of its fee");
        expectedPot += _potPart(fee, 7_000);
        // version 2's bid: 5 lots filled, cancelled to the wallet
        uint256 wq = quote.balanceOf(b);
        uint256 wb = base.balanceOf(b);
        vm.prank(b);
        book.cancel(k, _orderParams(bid2, SettleFlags.WALLET));
        fee = PriceGrid.feeDown(5 * LOT, TK, 50);
        assertEq(base.balanceOf(b) - wb, 5 * LOT, "the bid's fills, to the wallet");
        assertEq(quote.balanceOf(b) - wq, 5 * P + fee * 7_000 / 10_000, "the open half's escrow and 70% of the fee");
        expectedPot += _potPart(fee, 7_000);
        // version 2's batch slot: the fee floored per sub-order, summed, split once
        aq = _bal(a, quote);
        vm.prank(a);
        _mb(v2, OloOps.maskW(OloOps.CLAIM, 0, 0, 0));
        fee = PriceGrid.feeDown(4 * LOT, TK + 1, 50) + PriceGrid.feeDown(LOT, TK + 2, 50);
        assertEq(_bal(a, quote) - aq, batchQuote + fee * 7_000 / 10_000, "version 2's batch: 70%");
        expectedPot += _potPart(fee, 7_000);
        vm.prank(a);
        _mb(v2, OloOps.maskW(OloOps.CANCEL, 0, 0, 0x2));
        // version 3's ask: 2 lots filled at 300 ppm, 70%
        aq = _bal(a, quote);
        vm.prank(a);
        book.cancel(k, _orderParams(ask3, 0));
        fee = PriceGrid.feeDown(2 * LOT, TK, 300);
        assertEq(_bal(a, quote) - aq, 2 * P + fee * 7_000 / 10_000, "version 3's ask: 300 ppm, 70%");
        expectedPot += _potPart(fee, 7_000);
        // version 3's batch bid: 3 lots filled at TK - 1, 300 ppm, 70%: the base filled, the open lot's escrow back,
        // and 70% of the fee floored (900 -> 630)
        uint256 bq = _bal(b, quote);
        uint256 bb = _bal(b, base);
        vm.prank(b);
        _mb(v3, OloOps.maskW(OloOps.CANCEL, 0, 0, 0x1));
        fee = PriceGrid.feeDown(3 * LOT, TK - 1, 300);
        assertEq(fee, 900);
        assertEq(_bal(b, base) - bb, 3 * LOT, "version 3's batch bid: the base filled");
        assertEq(_bal(b, quote) - bq, 1_000_000 + fee * 7_000 / 10_000, "the open lot back and 70% of the fee");
        expectedPot += _potPart(fee, 7_000);
        // version 4's bid: 3 lots filled at 300 ppm, 25%
        bq = _bal(b, quote);
        vm.prank(b);
        book.cancel(k, _orderParams(bid4, 0));
        fee = PriceGrid.feeDown(3 * LOT, TK, 300);
        assertEq(_bal(b, quote) - bq, 7 * P + fee * 2_500 / 10_000, "version 4's bid: 25%");
        expectedPot += _potPart(fee, 2_500);
        // the taker's rest, by its order id: its escrow back
        tq = _bal(taker, quote);
        vm.prank(taker);
        book.cancel(k, _orderParams(restId, 0));
        assertEq(_bal(taker, quote) - tq, 2 * P, "the rest's escrow back");
        assertEq(_pot(quote) - pot0, expectedPot, "the pot, each settle at its version's fee and share");
        // the dust: the takes' fees, each rounded up on its take (151 + 201 + 601 + 101 + 51 + 251 + 900 + 901 + 251 =
        // 3,408), less the settles' fees, each floored per order (500 + 250 + 250 + 600 + 900 + 900 = 3,400); every
        // quote here is a whole wei
        _leaveClean(8);
    }

    /// Three versions of one market side by side (a fee change, then a share change), pool asks
    /// and bids and a batch slot part filled in each, settled in a mixed order after both changes (a claim before a
    /// cancel of the same order, an older slot's claim then its cancel): every account and both pots withdraw in full
    /// (an OLO EVM contract that owes more than it holds reverts there), no base stays and the quote's dust is the
    /// roundings'.
    function test_three_versions_settle_in_a_mixed_order() public {
        address a = _maker();
        address b = _maker();
        // version 1
        MarketWord v1 = c;
        (uint256 ask1,) = _placeK(a, TK, false, 10 * LOT, 1);
        (uint256 bid1,) = _placeK(b, TK, true, 10 * LOT, 2);
        vm.prank(a);
        _mb(k, OloOps.postW(false, 0, TK + 1, 4 * LOT, 2));
        _buyAt(v1, 1, TK, 3 * LOT);
        _sellAt(v1, 2, TK, 4 * LOT);
        vm.prank(taker);
        book.take(
            k, OloOps.batchList(OloOps.slotGroupAt(a, 0, 0x3, TK + 2)), OloOps.tagW(v1, OloOps.takeW(true, 5 * LOT, 0))
        );
        // version 2: the fee
        _setMarketFee(300);
        MarketWord v2 = c;
        (uint256 ask2,) = _placeK(a, TK, false, 10 * LOT, 1);
        vm.prank(b);
        _mb(k, OloOps.postW(true, 0, TK - 1, 4 * LOT, 1));
        _buyAt(v2, 1, TK, 2 * LOT);
        _buyAt(v1, 1, TK, 2 * LOT); // the older version still fills, at its fee
        vm.prank(taker);
        book.take(
            k, OloOps.batchList(OloOps.slotGroupAt(b, 0, 0x1, TK - 1)), OloOps.tagW(v2, OloOps.takeW(false, 3 * LOT, 0))
        );
        // version 3: the share
        _setMarketShare(2_500);
        MarketWord v3 = c;
        (uint256 bid3,) = _placeK(b, TK, true, 10 * LOT, 5);
        _sellAt(v3, 5, TK, 3 * LOT);
        _sellAt(v1, 2, TK, 1 * LOT);
        // settle in a mixed order, each at its version's fee and share (version 1: 50 ppm, 100%; version 2: 300 ppm,
        // 100%; version 3: 300 ppm, 25%), every flow to the wei
        uint256 pot0 = _pot(quote);
        vm.startPrank(a);
        uint256 aq = _bal(a, quote);
        uint256 ab = _bal(a, base);
        // ask1 (version 1): 5 lots filled (3 + 2): their quote and the whole fee, floor(250.0025) = 250
        assertEq(book.claim(k, _orderParams(ask1, 0)), 5 * P, "ask1's proceeds");
        assertEq(_bal(a, quote) - aq, 5 * P + 250, "ask1: proceeds and all of the fee");
        // ask2 (version 2): 2 lots filled, floor(600.006) = 600 to the maker, its 8 open lots back
        aq = _bal(a, quote);
        book.cancel(k, _orderParams(ask2, 0));
        assertEq(_bal(a, quote) - aq, 2 * P + 600, "ask2: proceeds and version 2's fee");
        assertEq(_bal(a, base) - ab, 8 * LOT, "ask2: the open lots");
        // version 1's slot: 4 lots at TK + 1 and 1 at TK + 2 filled, the fee floored per sub-order (200 + 50)
        aq = _bal(a, quote);
        _mb(v1, OloOps.maskW(OloOps.CLAIM, 0, 0, 0));
        assertEq(_bal(a, quote) - aq, 4 * (P + 10) + (P + 20) + 250, "version 1's slot claimed");
        // ask1 again: nothing filled since its claim, its 5 open lots back
        aq = _bal(a, quote);
        ab = _bal(a, base);
        book.cancel(k, _orderParams(ask1, 0));
        assertEq(_bal(a, quote), aq, "ask1: nothing more to pay");
        assertEq(_bal(a, base) - ab, 5 * LOT, "ask1: the open lots");
        // version 1's slot cancelled: sub-order 0 emptied by the claim, sub-order 1's 3 open lots back
        ab = _bal(a, base);
        _mb(v1, OloOps.maskW(OloOps.CANCEL, 0, 0, 0x3));
        assertEq(_bal(a, base) - ab, 3 * LOT, "version 1's slot: the open lots");
        vm.stopPrank();
        assertEq(_pot(quote), pot0, "version 1 and 2 pay all their fee to the makers");
        vm.startPrank(b);
        uint256 bq = _bal(b, quote);
        uint256 bb = _bal(b, base);
        // bid3 (version 3): 3 lots filled, floor(900.009) = 900, 25% to the maker (225), 675 to the pot; 7 lots back
        book.cancel(k, _orderParams(bid3, 0));
        assertEq(_bal(b, base) - bb, 3 * LOT, "bid3: the base filled");
        assertEq(_bal(b, quote) - bq, 7 * P + 225, "bid3: the open lots' escrow and 25% of the fee");
        assertEq(_pot(quote) - pot0, 675, "bid3: 75% of the fee to the pot");
        // bid1 (version 1): 5 lots filled (4 + 1), floor(250.0025) = 250 to the maker; 5 lots back
        bq = _bal(b, quote);
        bb = _bal(b, base);
        book.cancel(k, _orderParams(bid1, 0));
        assertEq(_bal(b, base) - bb, 5 * LOT, "bid1: the base filled");
        assertEq(_bal(b, quote) - bq, 5 * P + 250, "bid1: the open lots' escrow and the fee");
        // version 2's slot: 3 lots filled at TK - 1, 900 to the maker; the open lot's 1,000,000 back
        bq = _bal(b, quote);
        bb = _bal(b, base);
        _mb(v2, OloOps.maskW(OloOps.CANCEL, 0, 0, 0x1));
        assertEq(_bal(b, base) - bb, 3 * LOT, "version 2's slot: the base filled");
        assertEq(_bal(b, quote) - bq, 1_000_000 + 900, "version 2's slot: the open lot and the fee");
        vm.stopPrank();
        assertEq(_pot(quote) - pot0, 675, "the pot: version 3's 75% only");
        // the takes' fees rounded up (151 + 201 + 251 + 601 + 101 + 900 + 901 + 51 = 3,157) less the settles' floors
        // (250 + 600 + 250 + 900 + 250 + 900 = 3,150)
        _leaveClean(7);
    }

    // ================================================================ the market word: K, exactly

    /// The entries that rest an order take K and nothing else: an older version's C and the current C are both
    /// UnknownMarket for a place, a batch post and a takeThenRest that rests (a stale C never places in the
    /// current version silently). A multicall header names a version by its C: the current one
    /// places, an older one is MarketFrozen at its first PLACE.
    function test_resting_entries_take_k_only() public {
        address a = _maker();
        MarketWord v1 = c;
        _setMarketShare(0); // version 2
        MarketWord[2] memory notKeys = [v1, c];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(a);
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            book.place(notKeys[i], OloOps.placeW(false, TK, 5 * LOT, 1, 0));
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            book.manageBatchSubs(notKeys[i], OloOps.postW(false, 0, TK, LOT, 1)[0], [LOT, uint256(0)]);
            vm.stopPrank();
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            book.takeThenRest(notKeys[i], "", OloOps.restW(true, 5, TK, 0, 3));
        }
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.multicall(0, bytes.concat(OloOps.header(v1), OloOps.place(0, TK, false, LOT, 2)));
        book.multicall(0, bytes.concat(OloOps.header(c), OloOps.place(0, TK, false, LOT, 2)));
        (uint256 orderId,) = book.place(k, OloOps.placeW(false, TK, 5 * LOT, 1, 0));
        vm.expectRevert(IOloBookBase.NoOrder.selector); // a cancel by the older version's tag finds nothing there
        book.cancel(k, OloOps.tagW(v1, 1));
        book.cancel(k, _orderParams(orderId, 0));
        vm.stopPrank();
    }

    /// Every segment of K is compared, and K must carry no tag: a word one bit off in the base id, the quote id, the
    /// spacing, minQuote, the spare bits 170-173 or the id, or with one bit of the tag set (in the maker share, 174;
    /// the fee, 188; the version, 208: each field on its own), is UnknownMarket for a place, a batch post and a
    /// takeThenRest's rest. In a multicall header a key segment off is UnknownMarket too; a tag bit makes the word a C,
    /// a version nobody made, so its first PLACE is MarketFrozen. (A place checks the tick and the size against the
    /// caller's word before it reads the registry, so each flip is one that passes those: the spacing 1 to 0, minQuote
    /// 1 to 0.)
    function test_each_key_segment_is_checked() public {
        uint256 kw = MarketWord.unwrap(k);
        uint256[10] memory bits = [uint256(0), 32, 64, 74, 170, 224, 225, 174, 188, 208];
        address a = _maker();
        for (uint256 i; i < bits.length; ++i) {
            MarketWord off = MarketWord.wrap(kw ^ (uint256(1) << bits[i]));
            bool tagBit = bits[i] >= 174 && bits[i] < 224;
            // bit 170 marks a proprietary market: an entry asks the policy first, and the open market has none (zero),
            // so it is NotAdmitted before any registry read; the multicall reads the header's market first
            bytes4 unknown = bits[i] == 170 ? IOloBookBase.NotAdmitted.selector : IOloBookBase.UnknownMarket.selector;
            vm.startPrank(a);
            vm.expectRevert(unknown);
            book.place(off, OloOps.placeW(false, TK, 5 * LOT, 1, 0));
            vm.expectRevert(unknown);
            book.manageBatchSubs(off, OloOps.postW(false, 0, TK, LOT, 1)[0], [LOT, uint256(0)]);
            vm.expectRevert(tagBit ? IOloBookBase.MarketFrozen.selector : IOloBookBase.UnknownMarket.selector);
            book.multicall(0, bytes.concat(OloOps.header(off), OloOps.place(0, TK, false, LOT, 1)));
            vm.stopPrank();
            vm.prank(taker);
            vm.expectRevert(unknown);
            book.takeThenRest(off, "", OloOps.restW(true, 5 * LOT, TK, 0, 1));
        }
        // and K itself rests in each
        vm.startPrank(a);
        book.place(k, OloOps.placeW(false, TK, 5 * LOT, 1, 0));
        book.manageBatchSubs(k, OloOps.postW(false, 0, TK, LOT, 1)[0], [LOT, uint256(0)]);
        book.multicall(0, bytes.concat(OloOps.header(k), OloOps.place(0, TK, false, LOT, 2)));
        vm.stopPrank();
        vm.prank(taker);
        book.takeThenRest(k, "", OloOps.restW(true, 5 * LOT, TK, 0, 3));
    }

    // ================================================================ tags

    /// A take fills the version its params' tag names, and only it: an older version's tag fills the older orders,
    /// the current one's the current orders; a tag no version has (a forged fee, share or version, the tag left out)
    /// names a C nobody listed and fills nothing, with no revert (fill-or-kill reverts FokNotFilled), and moves nothing.
    function test_take_fills_the_version_its_tag_names() public {
        address a = _maker();
        _placeK(a, TK, false, 5 * LOT, 1); // version 1
        MarketWord v1 = c;
        _setMarketFee(300);
        _placeK(a, TK, false, 5 * LOT, 1); // version 2, the same position number
        uint256 b0 = _bal(taker, base);
        (uint256 got, uint256 paid) = _buyAt(v1, 1, TK, 2 * LOT);
        assertEq(got, 2 * LOT);
        assertEq(paid, 2 * P + 101, "version 1's 50 ppm: ceil(100.001)");
        (got, paid) = _buyAt(c, 1, TK, 2 * LOT);
        assertEq(paid, 2 * P + 601, "version 2's 300 ppm: ceil(600.006)");
        assertEq(_bal(taker, base) - b0, 4 * LOT);
        // tags no version has
        MarketWord[5] memory forged = [
            MarketWord.wrap(MarketWord.unwrap(c) ^ (uint256(300 ^ 0) << 188)), // the fee 0
            MarketWord.wrap(MarketWord.unwrap(c) ^ (uint256(1) << 174)), // the share one bps off
            MarketWord.wrap(MarketWord.unwrap(c) + (uint256(1) << 208)), // the next version, not made yet
            MarketWord.wrap(MarketWord.unwrap(c) & ~C_TAG_FIELD), // no tag: K alone
            MarketWord.wrap(MarketWord.unwrap(c) | C_TAG_FIELD) // every tag bit set
        ];
        uint256 q0 = _bal(taker, quote);
        for (uint256 i; i < forged.length; ++i) {
            (got, paid) = _buyAt(forged[i], 1, TK, LOT);
            assertEq(got, 0, "a forged tag fills nothing");
            assertEq(paid, 0);
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.FokNotFilled.selector);
            book.take(k, OloOps.poolList(OloOps.poolEntry(1, TK)), OloOps.tagW(forged[i], OloOps.fokW(true, LOT, 0, 0)));
        }
        assertEq(_bal(taker, quote), q0, "nothing moved");
        (, uint256 open,,,) = book.orderOf(c, 1);
        assertEq(open, 3 * LOT, "the current order untouched by them");
    }

    /// The take's tag is its params' top 50 bits and the list is main's: a list of 1 or 2 bytes is BadTakeList, an
    /// empty one fills nothing, moves nothing and does not revert; three pool entries (where a 7-byte prefix once
    /// crossed a word) fill; the bits between maxLeft and the tag (198-205) are not read; maxLeft (121-197) is read
    /// whole, its top bit too. The market word must be K: tag bits in it are or-ed with the params' and name a version
    /// only when the or of the two happens to be one.
    function test_take_tag_bits() public {
        address a = _maker();
        _placeK(a, TK, false, 10 * LOT, 1);
        _placeK(a, TK, false, 10 * LOT, 2);
        _placeK(a, TK, false, 10 * LOT, 3);
        uint256 params = OloOps.tagW(c, OloOps.takeW(true, LOT, 0));
        uint256 q0 = _bal(taker, quote);
        vm.startPrank(taker);
        vm.expectRevert(IOloBookBase.BadTakeList.selector);
        book.take(k, hex"00", params);
        vm.expectRevert(IOloBookBase.BadTakeList.selector);
        book.take(k, hex"0000", params);
        (uint256 got, uint256 paid) = book.take(k, "", params);
        assertEq(got + paid, 0, "an empty list fills nothing");
        assertEq(_bal(taker, quote), q0, "and moves nothing");
        // three entries
        (got,) = book.take(
            k, OloOps.poolList(OloOps.poolEntries(1, 3, TK, 0)), OloOps.tagW(c, OloOps.takeW(true, 3 * LOT, 0))
        );
        assertEq(got, 3 * LOT, "a list of three entries (the first order holds the 3 lots)");
        // junk between maxLeft and the tag
        (got,) = book.take(k, OloOps.poolList(OloOps.poolEntry(1, TK)), params | (uint256(0xff) << 198));
        assertEq(got, LOT, "bits 198-205 are not read");
        // fill-or-kill with maxLeft at its top bit: 2^76 left over is within it
        (got,) = book.take(
            k, OloOps.poolList(OloOps.poolEntry(1, TK)), OloOps.tagW(c, OloOps.fokW(true, 20 * LOT, 0, 1 << 76))
        );
        assertEq(got, 6 * LOT, "what was left of the first order (10 - 3 - 1), the rest within maxLeft");
        // another version's tag in the word and the current one in the params: the or of two tags, no version
        MarketWord other = MarketWord.wrap(MarketWord.unwrap(k) | (uint256(0x2_0000_0000) << 174));
        (got,) = book.take(other, OloOps.poolList(OloOps.poolEntry(2, TK)), params);
        assertEq(got, 0, "no version");
        vm.stopPrank();
    }

    /// The or of two different tags can be a third, real version: with the fee moved away and
    /// back, version 1's tag bits are a subset of version 3's, so a word carrying version 1's tag and params carrying
    /// version 3's reach version 3's order. The docs say "pass K"; the call only reaches what the caller could reach
    /// with K, as itself.
    function test_or_of_two_tags_can_name_a_version() public {
        address a = _maker();
        MarketWord v1 = c;
        _setMarketFee(300);
        _setMarketFee(v1.feePpm()); // version 3: version 1's fee and share again
        assertEq(MarketWord.unwrap(v1) | MarketWord.unwrap(c), MarketWord.unwrap(c), "version 1's bits within 3's");
        (uint256 orderId,) = _placeK(a, TK, false, 5 * LOT, 1);
        vm.prank(taker);
        (uint256 got,) =
            book.take(v1, OloOps.poolList(OloOps.poolEntry(1, TK)), OloOps.tagW(c, OloOps.takeW(true, LOT, 0)));
        assertEq(got, LOT, "version 3's order, through version 1's word and version 3's tag");
        vm.prank(a);
        book.cancel(v1, _orderParams(orderId, 0));
        (, uint256 open,,,) = book.orderOf(c, 1);
        assertEq(open, 0, "its owner's cancel, the same way");
    }

    /// A cancel and a claim find the order in the version their params' tag names: an older version's tag settles the
    /// older order; a tag no version has (or none) finds no order. A modify must name the current version: an older
    /// one's tag, a forged one or none is MarketFrozen.
    function test_settles_and_modifies_by_their_tag() public {
        address a = _maker();
        (uint256 oldId,) = _placeK(a, TK, false, 5 * LOT, 1);
        MarketWord v1 = c;
        _buyAt(v1, 1, TK, LOT);
        _setMarketShare(5_000);
        (uint256 newId,) = _placeK(a, TK, false, 5 * LOT, 2);
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        book.cancel(k, 1); // the old order's position with no tag
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        book.claim(k, 1);
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        book.cancel(k, _orderParams(newId, 0) ^ (uint256(1) << 206)); // the new order's tag, one bit off
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        book.cancel(k, _orderParams(oldId, 0) | (uint256(1) << 255)); // junk in the tag's top bit
        // a modify: older, forged, none
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.modify(k, OloOps.tagW(v1, OloOps.modifyW(1, TK + 1, 5 * LOT, 0)));
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.modify(k, OloOps.tagW(c, OloOps.modifyW(2, TK + 1, 5 * LOT, 0)) ^ (uint256(1) << 206));
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.modify(k, OloOps.modifyW(2, TK + 1, 5 * LOT, 0));
        // the right tags: the old order claims and cancels in version 1, the new one modifies in version 2
        book.claim(k, _orderParams(oldId, 0));
        book.cancel(k, _orderParams(oldId, 0));
        assertEq(book.modify(k, OloOps.tagW(c, OloOps.modifyW(2, TK + 1, 4 * LOT, 0))), 4 * LOT);
        vm.stopPrank();
        (, uint256 open,,,) = book.orderOf(c, 2);
        assertEq(open, 4 * LOT);
    }

    /// A batch operation names its slot's version: a post rests in the current one (the key names the market; a tag is
    /// not read), a cancel and a claim settle the version the params' tag names, a replace and a modify of an older
    /// version's slot are MarketFrozen (the tag must be the slot's own version, and that version current). A cancel
    /// sent with amount words [0, 0] (they carry no tag) finds its slot by
    /// the params alone.
    function test_batch_names_its_slot_s_version() public {
        address a = _maker();
        vm.prank(a);
        _mb(k, OloOps.postW(false, 0, TK, 2 * LOT, 2));
        MarketWord v1 = c;
        _setMarketFee(300);
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        _mb(v1, OloOps.ladderW(OloOps.REPLACE, false, 0, 0, TK + 2, LOT, 2, 1));
        // a post with the older tag in its params still rests in the current version: a post reads no tag
        book.manageBatchSubs(k, OloOps.tagW(v1, OloOps.postW(false, 0, TK + 3, LOT, 1)[0]), [LOT, uint256(0)]);
        vm.stopPrank();
        (uint256 oldWord,) = book.batchOf(v1, a, 0);
        (uint256 newWord,) = book.batchOf(c, a, 0);
        assertTrue(oldWord >> 2 != 0 && newWord >> 2 != 0, "two live slots, one per version");
        vm.prank(a);
        book.manageBatchSubs(k, OloOps.tagW(v1, OloOps.maskW(OloOps.CANCEL, 0, 0, 0x3)[0]), [uint256(0), 0]);
        (oldWord,) = book.batchOf(v1, a, 0);
        assertEq(oldWord >> 2, 0, "the old slot cancelled by the params' tag, [0, 0] for the amounts");
    }

    /// The tag (206-255) and sub-order 3's tick (110-135) share the params word and never meet, nor do the amounts at
    /// their largest, 2^112 - 1, two a word: a replace naming the current version rests sub-order 3 at the top maker
    /// tick with the largest amount, every field read back as given.
    function test_tag_and_the_last_order_s_fields_never_meet() public {
        address a = _maker();
        uint256 big = (1 << 112) - 1;
        base.mint(a, 4 * big);
        vm.startPrank(a);
        book.deposit(address(base), 3 * big);
        _mb(k, OloOps.postW(false, 0, TK, LOT, 1));
        uint256 top = PriceGrid.MAX_TICK;
        uint256[4] memory o =
            [OloOps.sub(TK, big), OloOps.sub(TK + 1, LOT), OloOps.sub(TK + 2, big), OloOps.sub(top, big)];
        _mb(c, OloOps.batchW(OloOps.REPLACE, false, 0, 0, 0, o));
        vm.stopPrank();
        (uint256 word,) = book.batchOf(c, a, 0);
        uint256 units = big;
        uint256 unit = 1;
        while (units >= 1 << 30) {
            units /= 10;
            unit *= 10;
        }
        uint256 stored = units * unit;
        assertEq(BatchView.tickOf(word, 3), top, "sub-order 3's tick");
        assertEq(BatchView.openOf(word, 3), stored, "sub-order 3's amount, as stored");
        assertEq(BatchView.openOf(word, 2), stored, "sub-order 2's");
        assertEq(BatchView.openOf(word, 0), stored, "sub-order 0's");
        assertEq(BatchView.openOf(word, 1), LOT, "sub-order 1's");
        assertEq(BatchView.tickOf(word, 1), TK + 1);
    }

    /// takeThenRest: the fills in the version the params' tag names, the rest in the market's current one; the taker
    /// pays the fills, their fee at the fills' version and the rest's escrow in one debit; the Take event names the
    /// fills' version and the Placed event the current one (both must be seen).
    function test_take_then_rest_rests_in_the_current_version() public {
        address a = _maker();
        _placeK(a, TK, false, 3 * LOT, 1);
        MarketWord v1 = c;
        _setMarketFee(300);
        uint256 q0 = _bal(taker, quote);
        vm.recordLogs();
        vm.prank(taker);
        (uint256 got, uint256 paid, uint256 rested, uint256 restId) = book.takeThenRest(
            k, OloOps.poolList(OloOps.poolEntry(1, TK)), OloOps.tagW(v1, OloOps.restW(true, 5 * LOT, TK, 0, 9))
        );
        assertEq(got, 3 * LOT, "the old version's order filled");
        assertEq(paid, 3 * P + _ceilFee(3 * P, 50), "at the old version's fee");
        assertEq(rested, 2 * LOT);
        assertEq(q0 - _bal(taker, quote), paid + 2 * P, "one debit: the fills, their fee, the rest's escrow");
        assertEq(restId, _orderId(c, 9), "the rest's id: the current version");
        (, uint256 open,, bool isBid, address owner) = book.orderOf(c, 9);
        assertEq(open, 2 * LOT, "rested in the current version");
        assertTrue(isBid);
        assertEq(owner, taker);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawTake;
        bool sawPlaced;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IOloBookBase.Take.selector) {
                sawTake = true;
                assertEq(uint256(logs[i].topics[1]), MarketWord.unwrap(v1) >> 208, "Take: version 1");
            }
            if (logs[i].topics[0] == IOloBookBase.Placed.selector) {
                sawPlaced = true;
                uint256 packed = abi.decode(logs[i].data, (uint256));
                assertEq((packed >> 176) & 0xffffffffffff, MarketWord.unwrap(c) >> 208, "Placed: version 2");
            }
        }
        assertTrue(sawTake && sawPlaced, "both events");
    }

    /// The zero word names no market, as K or as a C: a place, a batch post, a multicall header, a modify and a batch
    /// replace of it are UnknownMarket (the registry holds zero for id 0, and a zero C must not pass as the current one
    /// and rest orders in a market nobody listed); a batch modify of it is NoOrder, main's order of errors (its slot is
    /// empty, found before the version is checked).
    function test_the_zero_word_names_no_market() public {
        MarketWord zero = MarketWord.wrap(0);
        address a = _maker();
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.place(zero, OloOps.placeW(false, TK, LOT, 1, 0));
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        _mb(zero, OloOps.postW(false, 0, TK, LOT, 1));
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.multicall(0, bytes.concat(OloOps.header(zero), OloOps.place(0, TK, false, LOT, 1)));
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.modify(zero, OloOps.modifyW(1, TK, LOT, 0));
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        _mb(zero, OloOps.ladderW(OloOps.REPLACE, false, 0, 0, TK, LOT, 1, 1));
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        _mb(zero, OloOps.batchW(OloOps.MODIFY, false, 0, 0, 0x1, [OloOps.sub(TK, LOT), uint256(0), 0, 0]));
        vm.stopPrank();
    }

    /// makerShareOf reads any market word: K or the current C the current share, listed and active; an older version's
    /// C or a tag no version had (a forged share of 16,383 is not echoed back) (0, listed, not
    /// active); a word whose key no market has (0, false, false).
    function test_maker_share_of_a_word() public {
        MarketWord v1 = c;
        _setMarketShare(3_000);
        (uint16 bps, bool listed, bool active) = book.makerShareOf(k);
        assertEq(bps, 3_000);
        assertTrue(listed && active);
        (bps, listed, active) = book.makerShareOf(c);
        assertEq(bps, 3_000);
        assertTrue(listed && active);
        MarketWord forged = MarketWord.wrap(MarketWord.unwrap(k) | (uint256(0x3fff) << 174) | (uint256(9) << 208));
        MarketWord[2] memory notCurrent = [v1, forged];
        for (uint256 i; i < 2; ++i) {
            (bps, listed, active) = book.makerShareOf(notCurrent[i]);
            assertEq(bps, 0, "no share read back");
            assertTrue(listed);
            assertFalse(active);
        }
        (bps, listed, active) = book.makerShareOf(_wrongC());
        assertEq(bps, 0);
        assertFalse(listed || active);
    }

    // ================================================================ the corners

    /// The bits no entry reads change nothing: a take's 198-205, a batch params' 140-205 (136-139 are the orders'
    /// flips), a post's tag bits, and the amount words' bits 224-255.
    function test_unread_bits_change_nothing() public {
        address a = _maker();
        _placeK(a, TK, false, 10 * LOT, 1);
        _placeK(a, TK, false, 10 * LOT, 2);
        uint256 clean = OloOps.tagW(c, OloOps.takeW(true, 3 * LOT, 0));
        vm.prank(taker);
        (uint256 b1, uint256 q1) = book.take(k, OloOps.poolList(OloOps.poolEntry(1, TK)), clean);
        vm.prank(taker);
        (uint256 b2, uint256 q2) =
            book.take(k, OloOps.poolList(OloOps.poolEntry(2, TK)), clean | (uint256(0xff) << 198));
        assertEq(b1, 3 * LOT);
        assertEq(b2, b1, "a take's bits 198-205: the same base");
        assertEq(q2, q1, "the same quote");

        // two slots, the same four orders: one posted clean, one with every unread bit set
        uint256[3] memory w = OloOps.postW(false, 0, TK + 1, 4 * LOT, 4);
        uint256[3] memory d = OloOps.postW(false, 1, TK + 1, 4 * LOT, 4);
        uint256 junk = ((uint256(1) << 66) - 1) << 140; // bits 140-205
        uint256 staleTag = ((uint256(1) << 50) - 1) << 206; // a tag no version has: a post reads none
        uint256 top = uint256(0xffffffff) << 224; // the amount words' top 32 bits
        uint256 ab = _bal(a, base);
        vm.prank(a);
        book.manageBatchSubs(k, w[0], [w[1], w[2]]);
        uint256 escrowClean = ab - _bal(a, base);
        ab = _bal(a, base);
        vm.prank(a);
        book.manageBatchSubs(k, d[0] | junk | staleTag, [d[1] | top, d[2] | top]);
        assertEq(ab - _bal(a, base), escrowClean, "the same escrow");
        assertEq(escrowClean, 16 * LOT, "four asks of 4 lots");
        (uint256 word0, uint256 set0) = book.batchOf(c, a, 0);
        (uint256 word1, uint256 set1) = book.batchOf(c, a, 1);
        assertTrue(word0 != 0, "posted in the current version");
        assertEq(word1, word0, "the same main word");
        assertEq(set1, set0, "the same settlement word");
    }

    /// The order id a place returns is a cancel's, a claim's and a modify's params as it is; after a fee change it
    /// still cancels (its own version), and no longer modifies (MarketFrozen).
    function test_order_id_round_trip() public {
        address a = _maker();
        (uint256 id,) = _placeK(a, TK, false, 10 * LOT, 7);
        assertEq(uint32(id), 7, "the position");
        assertEq(id >> 206, MarketWord.unwrap(c) >> 174 & ((1 << 50) - 1), "the current version's tag");
        assertEq((id << 50) >> 82, 0, "nothing between");
        // modify by the id: 6 lots at TK + 1
        vm.prank(a);
        uint256 stored = book.modify(k, id | OloOps.modifyW(0, TK + 1, 6 * LOT, 0));
        assertEq(stored, 6 * LOT);
        _buyAt(c, 7, TK + 1, 2 * LOT);
        uint256 aq = _bal(a, quote);
        vm.prank(a);
        uint256 proceeds = book.claim(k, id);
        assertEq(proceeds, 2 * (P + 10), "2 lots at TK + 1");
        assertGe(_bal(a, quote) - aq, proceeds);
        // the fee moves: the id is the old version's
        _setMarketFee(MarketWord.unwrap(c) >> 188 & 0xfffff == 300 ? 301 : 300);
        vm.prank(a);
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.modify(k, id | OloOps.modifyW(0, TK + 2, 6 * LOT, 0));
        uint256 wb = base.balanceOf(a);
        vm.prank(a);
        book.cancel(k, id | (uint256(SettleFlags.WALLET) << 32));
        assertEq(base.balanceOf(a) - wb, 4 * LOT, "the open 4 lots, to the wallet");
        // a place by the same K rests in the new version: another id, the same position number free there
        (uint256 id2,) = _placeK(a, TK, false, LOT, 7);
        assertTrue(id2 != id, "another version's id");
        assertEq(uint32(id2), 7);
    }

    /// takeThenRest: a market word with tag bits rests nothing (UnknownMarket), whatever the fills did; the rest's id
    /// is the current version's, and cancels by K.
    function test_take_then_rest_takes_k_for_its_rest() public {
        address a = _maker();
        _placeK(a, TK, false, 5 * LOT, 1);
        MarketWord v1 = c;
        _setMarketFee(MarketWord.unwrap(c) >> 188 & 0xfffff == 300 ? 301 : 300);
        bytes memory list = OloOps.poolList(OloOps.poolEntry(1, TK));
        uint256 params = OloOps.tagW(v1, OloOps.restW(true, 7 * LOT, TK, 0, 9));
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.takeThenRest(c, list, params); // the current C, not K
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.takeThenRest(v1, list, params); // the old C
        vm.prank(taker);
        (uint256 got,, uint256 rested, uint256 restId) = book.takeThenRest(k, list, params);
        assertEq(got, 5 * LOT, "version 1's ask filled");
        assertEq(rested, 2 * LOT);
        assertEq(restId, _orderId(c, 9), "the rest's id: the current version, position 9");
        uint256 tq = _bal(taker, quote);
        vm.prank(taker);
        book.cancel(k, restId);
        assertEq(_bal(taker, quote) - tq, 2 * P, "the rest's escrow back");
    }

    /// One slot number in two versions: the tag picks which one a cancel settles, and the other stays.
    function test_batch_tag_picks_the_version() public {
        address a = _maker();
        vm.prank(a);
        _mb(k, OloOps.postW(false, 0, TK + 1, 4 * LOT, 2));
        MarketWord v1 = c;
        _setMarketFee(MarketWord.unwrap(c) >> 188 & 0xfffff == 300 ? 301 : 300);
        MarketWord v2 = c;
        vm.prank(a);
        _mb(k, OloOps.postW(false, 0, TK + 1, 3 * LOT, 2)); // slot 0 again: free in version 2
        (uint256 w1,) = book.batchOf(v1, a, 0);
        (uint256 w2,) = book.batchOf(v2, a, 0);
        assertTrue(w1 != 0 && w2 != 0 && w1 != w2, "two slots");
        // a replace of version 1's slot rests nothing there
        uint256[3] memory r = OloOps.postW(false, 0, TK + 2, LOT, 1);
        r[0] = (r[0] & ~uint256(7)) | OloOps.REPLACE;
        vm.prank(a);
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.manageBatchSubs(k, OloOps.tagW(v1, r[0]), [r[1], r[2]]);
        // a cancel by version 1's tag, the amount words zero
        uint256 ab = _bal(a, base);
        uint256[3] memory x = OloOps.maskW(OloOps.CANCEL, 0, 0, 0x3);
        vm.prank(a);
        book.manageBatchSubs(k, OloOps.tagW(v1, x[0]), [uint256(0), uint256(0)]);
        assertEq(_bal(a, base) - ab, 8 * LOT, "version 1's two asks of 4 lots refunded");
        (uint256 w2After,) = book.batchOf(v2, a, 0);
        assertEq(w2After, w2, "version 2's slot untouched");
        // the same cancel again finds nothing live there
        vm.prank(a);
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        book.manageBatchSubs(k, OloOps.tagW(v1, x[0]), [uint256(0), uint256(0)]);
    }

    /// A replace naming the current version, after a fee change, finds the current version's own slot, empty for a slot
    /// posted before the change: it rests there as a post, with the full escrow, and leaves the older slot live and
    /// fillable at its old ticks (the rule the docs give: cancel the older slot by its tag, then post under K).
    function test_replace_naming_the_current_version_leaves_the_older_slot_live() public {
        address a = _maker();
        vm.prank(a);
        _mb(k, OloOps.postW(false, 0, TK, 2 * LOT, 2)); // version 1, slot 0: asks of 2 LOT at TK, TK + 1
        MarketWord v1 = c;
        _setMarketFee(300); // version 2; `c` follows
        uint256 baseBefore = _bal(a, base);
        vm.prank(a);
        _mb(c, OloOps.ladderW(OloOps.REPLACE, false, 0, 0, TK + 2, LOT, 2, 1)); // tag = configOf's
        (uint256 oldWord,) = book.batchOf(v1, a, 0);
        (uint256 newWord,) = book.batchOf(c, a, 0);
        assertTrue(oldWord >> 2 != 0, "version 1's quotes are still live");
        assertTrue(newWord >> 2 != 0, "the replace rested beside them, as a post");
        assertEq(baseBefore - _bal(a, base), 2 * LOT, "full escrow: nothing of version 1 refunded");
        vm.prank(taker);
        (uint256 got,) = book.take(
            k, OloOps.batchList(OloOps.slotGroupAt(a, 0, 0x3, TK + 1)), OloOps.tagW(v1, OloOps.takeW(true, 4 * LOT, 0))
        );
        assertEq(got, 4 * LOT, "and they fill at the old ticks");
    }

    /// A batch modify naming a slot with nothing live is NoOrder, checked before the version: a tag no version has (a
    /// version not made yet) finds an empty slot; a replace of the same word is MarketFrozen.
    function test_batch_modify_of_a_tag_no_version_has_is_no_order() public {
        address a = _maker();
        vm.prank(a);
        _mb(k, OloOps.postW(false, 0, TK, 2 * LOT, 2));
        MarketWord notYet = MarketWord.wrap(MarketWord.unwrap(c) + (1 << 208)); // version 2, not made
        uint256[4] memory o;
        o[0] = OloOps.sub(TK + 5, LOT);
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.NoOrder.selector); // a slot with nothing live: NoOrder, found before the version
        _mb(notYet, OloOps.batchW(OloOps.MODIFY, false, 0, 0, 0x1, o));
        vm.expectRevert(IOloBookBase.MarketFrozen.selector); // a replace of the same word is
        _mb(notYet, OloOps.ladderW(OloOps.REPLACE, false, 0, 0, TK + 2, LOT, 1, 1));
        vm.stopPrank();
    }

    // ================================================================ multicall headers

    /// A multicall header K names the current version for its whole run: a CLAIM and a MODIFY of the current version's
    /// order (its fills paid at the current share, the modify resting it again), and a PLACE; the amounts to the wei.
    /// K reaches no older version: a CLAIM of an older version's order under K finds no order; under its own C it
    /// claims, at its version's share.
    function test_multicall_key_header_claims_and_modifies() public {
        address a = _maker();
        _placeK(a, TK, false, 5 * LOT, 3); // version 1, at 100%
        MarketWord v1 = c;
        _buyAt(v1, 3, TK, LOT);
        _setMarketShare(6_000); // version 2
        _placeK(a, TK, false, 5 * LOT, 4);
        _buyAt(c, 4, TK, 2 * LOT);
        uint256 q0 = _bal(a, quote);
        uint256 b0 = _bal(a, base);
        uint256 pot0 = _pot(quote);
        vm.prank(a);
        book.multicall(
            0,
            bytes.concat(
                OloOps.header(k),
                OloOps.claim(0, 4),
                OloOps.modify(0, 4, TK + 1, 4 * LOT),
                OloOps.place(0, TK + 2, false, LOT, 5)
            )
        );
        uint256 fee = PriceGrid.feeDown(2 * LOT, TK, 50);
        assertEq(_bal(a, quote) - q0, 2 * P + fee * 6_000 / 10_000, "the claim: proceeds and 60% of the fee");
        assertEq(_pot(quote) - pot0, _potPart(fee, 6_000), "the pot: 40%");
        assertEq(b0 - _bal(a, base), LOT + LOT, "the modify's lot added (3 open to 4) and the place's lot");
        (uint256 tick, uint256 open,,,) = book.orderOf(c, 4);
        assertEq(tick, TK + 1);
        assertEq(open, 4 * LOT);
        (, open,,,) = book.orderOf(c, 5);
        assertEq(open, LOT, "the PLACE in the current version");
        vm.prank(a);
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        book.multicall(0, bytes.concat(OloOps.header(k), OloOps.claim(0, 3)));
        // under its own C the older order claims, at version 1's share
        q0 = _bal(a, quote);
        vm.prank(a);
        book.multicall(0, bytes.concat(OloOps.header(v1), OloOps.claim(0, 3)));
        assertEq(_bal(a, quote) - q0, P + PriceGrid.feeDown(LOT, TK, 50), "version 1's fill at 100%");
    }
}
