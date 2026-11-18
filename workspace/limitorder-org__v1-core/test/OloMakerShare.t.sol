// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {OloBook} from "../src/OloBook.sol";
import {IOloBook} from "../src/interfaces/IOloBook.sol";
import {Vm} from "forge-std/Vm.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {IOloBookExt} from "../src/interfaces/IOloBookExt.sol";
import {IOwned2Step} from "../src/interfaces/IOwned2Step.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

using MarketLib for MarketWord;

/// The maker share's three levels, as the fee's: the global share (0 as deployed: the protocol takes the whole fee),
/// a pair's share, which takes the global one's place for the pair's listings (0 included, which is not the same as
/// none) until it is lifted, and a market's own share, in its C, which a listing sets from the pair's or the global one
/// and `setMarketMakerShare` changes in place as the market's next version (the market keeps its id and key; orders
/// placed before keep their version's share, orders placed after rest in the new version). The global and the pair's
/// shares reach listings only: a market listed already keeps its share. A pair's share and its fee floor share one word
/// and never touch each other. `setMarketFee` keeps the market's share in its next version, not the pair's or the
/// global one.
contract OloMakerShareTest is OloBase {
    uint256 constant TK = T + 1; // 100,001: a lot is 1,000,010 quote wei
    address constant STRANGER = address(0xBAD);

    function setUp() public {
        _deploy();
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    function _token(string memory name) internal returns (MockERC20) {
        return new MockERC20(name, name, 6);
    }

    function _list(MockERC20 b, MockERC20 q) internal returns (uint32) {
        return book.listMarketQuote(address(b), address(q), 50, 6, 1, 0);
    }

    function _shareOf(uint32 id) internal view returns (uint16 bps) {
        (bps,,) = book.makerShareOf(book.configOf(id));
    }

    /// The share in the C a MarketListed logs, the one recorded since `recordLogs`.
    function _listedShare() internal returns (uint16) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IOloBookBase.MarketListed.selector) continue;
            (,, uint256 config) = abi.decode(logs[i].data, (address, address, uint256));
            return MarketWord.wrap(config).makerBps();
        }
        revert("no MarketListed");
    }

    function _sorted(address x, address y) internal pure returns (address, address) {
        return x < y ? (x, y) : (y, x);
    }

    /// The maker share half of `pairDefaultsOf`.
    function _sharesOf(address x, address y) internal view returns (uint16 bps, uint16 globalBps, bool pairSet) {
        (,,, bps, globalBps, pairSet) = book.pairDefaultsOf(x, y);
    }

    // ================================================================ global

    /// An OLO EVM contract as deployed has a global share of 0 and no fee floor: a listing gives its market a share of
    /// 0, so the protocol takes the whole fee. (The fixture sets 10,000 before its listing; this OLO EVM contract is
    /// deployed bare.)
    function test_deployed_global_share_is_zero() public {
        bool hirun = vm.exists(BOOK) && vm.exists(EXT);
        address ext = hirun ? vm.deployCode(EXT) : vm.deployCode("OloBookExt.sol:OloBookExt");
        OloBook bare = OloBook(
            hirun
                ? vm.deployCode(BOOK, abi.encode(address(this), ext, 0))
                : vm.deployCode("OloBook.sol:OloBook", abi.encode(address(this), ext, 0))
        );
        (uint24 floorPpm, uint24 globalFloorPpm, bool floorSet, uint16 bps, uint16 globalBps, bool shareSet) =
            bare.pairDefaultsOf(address(base), address(quote));
        assertEq(floorPpm, 0);
        assertEq(globalFloorPpm, 0);
        assertFalse(floorSet);
        assertEq(bps, 0);
        assertEq(globalBps, 0);
        assertFalse(shareSet);
        vm.recordLogs();
        uint32 id = bare.listMarketQuote(address(base), address(quote), 50, 6, 1, 0);
        assertEq(_listedShare(), 0, "MarketListed's C carries the share");
        (uint16 listed,,) = bare.makerShareOf(bare.configOf(id));
        assertEq(listed, 0);
    }

    /// A listing gives its market the global share; changing the global share reaches later listings only.
    function test_global_share_reaches_listings_only() public {
        vm.expectEmit(address(book));
        emit IOloBookBase.GlobalMakerShareSet(2_500);
        book.setGlobalMakerShare(2_500);
        MockERC20 a = _token("A");
        uint32 first = book.marketCount() + 1;
        vm.recordLogs();
        assertEq(_list(a, quote), first);
        assertEq(_listedShare(), 2_500, "MarketListed's C carries the share");
        book.setGlobalMakerShare(7_000);
        assertEq(_shareOf(first), 2_500, "listed already: keeps its share");
        assertEq(_shareOf(m), 10_000, "the fixture's market too");
        assertEq(_shareOf(_list(_token("B"), quote)), 7_000);
        (uint16 bps, uint16 globalBps, bool pairSet) = _sharesOf(address(a), address(quote));
        assertEq(bps, 7_000);
        assertEq(globalBps, 7_000);
        assertFalse(pairSet);
    }

    // ================================================================ pair

    /// A pair's share takes the global share's place, above it and below it, for both of its markets' sides (either
    /// token as base), set with the tokens in either order; a share of 0 holds against a global share above it, which
    /// no share does not (the global one applies).
    function test_pair_share_overrides_global() public {
        book.setGlobalMakerShare(3_000);
        MockERC20 a = _token("A");
        MockERC20 b = _token("B");
        MockERC20 d = _token("D");
        (address t0, address t1) = _sorted(address(a), address(quote));
        vm.expectEmit(address(book));
        emit IOloBookBase.PairMakerShareSet(t0, t1, 0);
        book.setPairMakerShare(address(quote), address(a), 0, true);
        book.setPairMakerShare(address(b), address(quote), 9_000, true);
        assertEq(_shareOf(_list(a, quote)), 0, "a pair's 0");
        assertEq(_shareOf(_list(quote, a)), 0, "the other side");
        assertEq(_shareOf(_list(b, quote)), 9_000, "above the global share");
        assertEq(_shareOf(_list(d, quote)), 3_000, "no pair share: the global one");
        (uint16 bps, uint16 globalBps, bool pairSet) = _sharesOf(address(a), address(quote));
        assertEq(bps, 0);
        assertEq(globalBps, 3_000);
        assertTrue(pairSet);
        (bps,, pairSet) = _sharesOf(address(quote), address(b));
        assertEq(bps, 9_000);
        assertTrue(pairSet);
        (bps,, pairSet) = _sharesOf(address(d), address(quote));
        assertEq(bps, 3_000);
        assertFalse(pairSet);
    }

    /// Lifting a pair's share falls back to the global share, for listings after it; a market listed under the pair's
    /// share keeps it.
    function test_lift_pair_share() public {
        book.setGlobalMakerShare(3_000);
        MockERC20 a = _token("A");
        book.setPairMakerShare(address(a), address(quote), 0, true);
        uint32 before = _list(a, quote);
        (address t0, address t1) = _sorted(address(a), address(quote));
        vm.expectEmit(address(book));
        emit IOloBookBase.PairMakerShareLifted(t0, t1);
        book.setPairMakerShare(address(quote), address(a), 0, false);
        (uint16 bps,, bool pairSet) = _sharesOf(address(a), address(quote));
        assertEq(bps, 3_000);
        assertFalse(pairSet);
        assertEq(_shareOf(_list(quote, a)), 3_000);
        assertEq(_shareOf(before), 0);
        // lifted, the pair follows the global share as it moves
        book.setGlobalMakerShare(4_000);
        (bps,,) = _sharesOf(address(a), address(quote));
        assertEq(bps, 4_000);
    }

    /// Pair shares are keyed by address: one set before either token was ever listed holds for the pair's first
    /// listing.
    function test_pair_share_before_registration() public {
        MockERC20 a = _token("A");
        MockERC20 b = _token("B");
        assertEq(book.tokenId(address(a)), 0);
        assertEq(book.tokenId(address(b)), 0);
        book.setPairMakerShare(address(a), address(b), 1_500, true);
        assertEq(_shareOf(_list(b, a)), 1_500);
    }

    /// A pair's fee floor and maker share live in one word, each with its own SET bit: setting, changing or lifting
    /// one leaves the other as it was, in either order.
    function test_pair_floor_and_share_are_independent() public {
        book.setGlobalFeeFloor(300);
        book.setGlobalMakerShare(3_000);
        MockERC20 a = _token("A");
        book.setPairFeeFloor(address(a), address(quote), 100, true);
        book.setPairMakerShare(address(a), address(quote), 6_000, true);
        _expectPair(a, 100, true, 6_000, true);
        book.setPairMakerShare(address(quote), address(a), 7_000, true); // changed
        _expectPair(a, 100, true, 7_000, true);
        book.setPairFeeFloor(address(quote), address(a), 0, false); // the floor lifted
        _expectPair(a, 300, false, 7_000, true);
        book.setPairFeeFloor(address(a), address(quote), 0, true); // a floor of 0
        _expectPair(a, 0, true, 7_000, true);
        book.setPairMakerShare(address(a), address(quote), 0, false); // the share lifted
        _expectPair(a, 0, true, 3_000, false);
        book.setPairMakerShare(address(a), address(quote), 0, true); // a share of 0
        _expectPair(a, 0, true, 0, true);
        book.setPairFeeFloor(address(a), address(quote), 0, false);
        book.setPairMakerShare(address(a), address(quote), 0, false);
        _expectPair(a, 300, false, 3_000, false);
        // and a listing reads both from the one word
        book.setPairFeeFloor(address(a), address(quote), 120, true);
        book.setPairMakerShare(address(a), address(quote), 4_500, true);
        vm.expectRevert(IOloBookBase.FeeTooLow.selector);
        book.listMarketQuote(address(a), address(quote), 119, 6, 1, 0);
        uint32 id = book.listMarketQuote(address(a), address(quote), 120, 6, 1, 0);
        assertEq(_shareOf(id), 4_500);
    }

    function _expectPair(MockERC20 a, uint24 floor, bool floorSet, uint16 bps, bool shareSet) internal view {
        (uint24 f, uint24 gf, bool fs, uint16 s, uint16 gs, bool ss) = book.pairDefaultsOf(address(a), address(quote));
        assertEq(f, floor, "floor");
        assertEq(fs, floorSet, "floorSet");
        assertEq(s, bps, "share");
        assertEq(ss, shareSet, "shareSet");
        assertEq(gf, 300, "global floor");
        assertEq(gs, 3_000, "global share");
    }

    function test_pair_share_guards() public {
        vm.startPrank(STRANGER);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setGlobalMakerShare(1);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setPairMakerShare(address(base), address(quote), 1, true);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setPairMakerShare(address(base), address(quote), 0, false);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setMarketMakerShare(m, 1);
        vm.stopPrank();
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setPairMakerShare(address(base), address(base), 1, true);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setPairMakerShare(address(base), address(base), 0, false);
        // a lift names no share
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setPairMakerShare(address(base), address(quote), 1, false);
        vm.expectRevert(IOloBookBase.MakerShareTooHigh.selector);
        book.setPairMakerShare(address(base), address(quote), 10_001, true);
        // the bound is checked first: a lift naming a value above it is MakerShareTooHigh, not BadMarketConfig
        vm.expectRevert(IOloBookBase.MakerShareTooHigh.selector);
        book.setPairMakerShare(address(base), address(quote), 20_000, false);
    }

    /// The events carry the values set: a pair's share (PairMakerShareSet) and floor (PairFeeFloorSet), and a listing's
    /// share when it is its pair's, not the global one (in MarketListed's C), so the logs give what the contract holds.
    function test_pair_events_carry_their_values() public {
        book.setGlobalMakerShare(3_000);
        MockERC20 a = _token("A");
        (address t0, address t1) = _sorted(address(a), address(quote));
        vm.expectEmit(address(book));
        emit IOloBookBase.PairMakerShareSet(t0, t1, 9_000);
        book.setPairMakerShare(address(a), address(quote), 9_000, true);
        vm.expectEmit(address(book));
        emit IOloBookBase.PairFeeFloorSet(t0, t1, 501);
        book.setPairFeeFloor(address(quote), address(a), 501, true);
        uint32 next = book.marketCount() + 1;
        vm.recordLogs();
        assertEq(book.listMarketQuote(address(a), address(quote), 501, 6, 1, 0), next);
        assertEq(_listedShare(), 9_000);
        assertEq(_shareOf(next), 9_000);
    }

    /// Odd values keep their lowest bit through the pair's word (the share's field is 14 bits wide at bit 32, the
    /// floor's PAIR_FLOOR_MASK at bit 0): a share of 4,501 reads and lists as 4,501, a floor of 501 refuses 500.
    function test_odd_values_keep_their_lowest_bit() public {
        MockERC20 a = _token("A");
        book.setPairMakerShare(address(a), address(quote), 4_501, true);
        book.setPairFeeFloor(address(a), address(quote), 501, true);
        (uint24 floor,, bool floorSet, uint16 bps,, bool shareSet) = book.pairDefaultsOf(address(quote), address(a));
        assertEq(floor, 501);
        assertTrue(floorSet);
        assertEq(bps, 4_501);
        assertTrue(shareSet);
        vm.expectRevert(IOloBookBase.FeeTooLow.selector);
        book.listMarketQuote(address(a), address(quote), 500, 6, 1, 0);
        assertEq(_shareOf(book.listMarketQuote(address(a), address(quote), 501, 6, 1, 0)), 4_501);
        // a market's share keeps its lowest bit too
        book.setMarketMakerShare(m, 4_501);
        assertEq(_shareOf(m), 4_501);
    }

    /// Every setter checks its value against the bound before it narrows it to the stored width: a value whose low bits
    /// would fit (2^16, 2^24, 2^32, 2^40 as the parameter's type allows) is refused, and nothing is stored. Narrowed
    /// first, 2^16 would store as a share of 0.
    function test_bounds_are_checked_before_narrowing() public {
        vm.expectRevert(IOloBookBase.MakerShareTooHigh.selector);
        book.setGlobalMakerShare(uint24(1) << 16);
        for (uint256 k = 16; k <= 32; k += 8) {
            vm.expectRevert(IOloBookBase.MakerShareTooHigh.selector);
            book.setPairMakerShare(address(base), address(quote), uint40(1 << k), true);
        }
        for (uint256 k = 16; k <= 40; k += 8) {
            vm.expectRevert(IOloBookBase.MakerShareTooHigh.selector);
            book.setMarketMakerShare(m, uint48(1 << k));
        }
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setPairFeeFloor(address(base), address(quote), uint32(1) << 24, true);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setGlobalFeeFloor(uint32(1) << 24);
        // nothing stored
        (uint24 floor, uint24 globalFloor, bool floorSet, uint16 bps, uint16 globalBps, bool shareSet) =
            book.pairDefaultsOf(address(base), address(quote));
        assertEq(floor, 0);
        assertEq(globalFloor, 0);
        assertFalse(floorSet);
        assertEq(bps, 10_000, "the fixture's global share");
        assertEq(globalBps, 10_000);
        assertFalse(shareSet);
        assertEq(_shareOf(m), 10_000);
    }

    /// Any share 0 .. 10,000 and any floor 0 .. 1,000,000 go through the pair's word whole, set in either order and with
    /// the tokens in either order: both read back as set, and a listing of the pair is refused just below that floor,
    /// lists at it, and gets that share (one property for the word's masks, shifts and two fields).
    /// The floor is reached 1% a call (FeeStepTooLarge past it), each call keeping the share.
    function testFuzz_pair_word_round_trip(uint16 share, uint24 floor, bool floorFirst) public {
        share = uint16(bound(share, 0, 10_000));
        floor = uint24(bound(floor, 0, 1_000_000));
        MockERC20 a = _token("A");
        if (floorFirst) {
            _walkPairFloor(address(a), address(quote), floor);
            book.setPairMakerShare(address(quote), address(a), share, true);
        } else {
            book.setPairMakerShare(address(quote), address(a), share, true);
            _walkPairFloor(address(a), address(quote), floor);
        }
        (uint24 f,, bool floorSet, uint16 s,, bool shareSet) = book.pairDefaultsOf(address(a), address(quote));
        assertEq(f, floor, "floor");
        assertEq(s, share, "share");
        assertTrue(floorSet && shareSet);
        if (floor != 0) {
            vm.expectRevert(IOloBookBase.FeeTooLow.selector);
            book.listMarketQuote(address(a), address(quote), floor - 1, 6, 1, 0);
        }
        assertEq(_shareOf(book.listMarketQuote(address(a), address(quote), floor, 6, 1, 0)), share, "listed share");
    }

    // ================================================================ market

    /// `setMarketMakerShare` changes a market's share in place, as its next version: the id and the key stay, no
    /// market is listed, C's share field and version change (MarketConfigSet). The order placed before rests on in its
    /// version and fills there, and its fills, taken before the change or after, settle at its version's share; an
    /// order placed after rests in the new version and settles at the new share.
    function test_market_share_in_place() public {
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, TK, 10 * LOT, 600, 0));
        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(600, TK)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0))
        );
        uint256 word = book.orderWord(c, 600);
        uint256 count = book.marketCount();
        MarketWord v1 = c;
        uint256 next = (MarketWord.unwrap(c) & ~(uint256(0x3fff) << 174)) + (uint256(2_000) << 174) + (1 << 208);
        vm.expectEmit(address(book));
        emit IOloBookBase.MarketConfigSet(m, 2, next);
        book.setMarketMakerShare(m, 2_000);
        assertEq(MarketWord.unwrap(book.configOf(m)), next, "the share and the version, nothing else");
        assertEq(MarketWord.unwrap(OloOps.key(book.configOf(m))), MarketWord.unwrap(OloOps.key(v1)), "the key stays");
        assertEq(book.marketCount(), count, "no market listed");
        assertEq(book.orderWord(v1, 600), word, "the order untouched");
        (uint16 bps, bool listed, bool active) = book.makerShareOf(book.configOf(m));
        assertEq(bps, 2_000);
        assertTrue(listed && active);
        (bps, listed, active) = book.makerShareOf(v1);
        assertEq(bps, 0, "an older version: no share read back");
        assertTrue(listed && !active);
        vm.expectRevert(IOloBookBase.NoChange.selector);
        book.setMarketMakerShare(m, 2_000);
        // the fill's fee floor(5 x 1_000_010 x 50 ppm) = 250, all of it to the maker at the first version's 100%
        uint256 qa = _bal(a, quote);
        vm.prank(a);
        book.claim(OloOps.key(v1), OloOps.tagW(v1, OloOps.posW(600, 0)));
        assertEq(_bal(a, quote), qa + 5 * 1_000_010 + 250);
        assertEq(_pot(quote), 0);
        // the order rests on in its version and fills again, settled at its version's share
        vm.prank(taker);
        book.take(
            OloOps.key(v1), OloOps.poolList(OloOps.poolEntry(600, TK)), OloOps.tagW(v1, OloOps.takeW(true, 5 * LOT, 0))
        );
        vm.prank(a);
        book.claim(OloOps.key(v1), OloOps.tagW(v1, OloOps.posW(600, 0)));
        assertEq(_bal(a, quote), qa + 2 * (5 * 1_000_010 + 250));
        assertEq(_pot(quote), 0);
        // an order placed now rests in the new version: 50 to the maker at 20%, 200 to the pot
        c = book.configOf(m);
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, TK, 5 * LOT, 601, 0));
        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(601, TK)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0))
        );
        vm.prank(a);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(601, 0)));
        assertEq(_bal(a, quote), qa + 3 * 5 * 1_000_010 + 2 * 250 + 50);
        assertEq(_pot(quote), 200);
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 0, "no base left");
        assertEq(quoteLeft, 3, "three takes' fees, ceil(250.0025) = 251, past their settles' floors, 250");
    }

    /// The market id is checked before it names a market: 0, one past the last and an id past 32 bits (which a cast
    /// would fold onto a listed market) are UnknownMarket.
    function test_market_share_unknown_ids() public {
        uint256 last = book.marketCount();
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.setMarketMakerShare(0, 1);
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.setMarketMakerShare(last + 1, 1);
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.setMarketMakerShare(uint256(m) + (1 << 32), 1);
        assertEq(_shareOf(m), 10_000, "the market the cast would fold onto is untouched");
    }

    /// `setMarketFee` keeps the market's share in its next version, whatever the pair's and the global shares are then.
    function test_market_fee_carries_the_market_s_share() public {
        book.setMarketMakerShare(m, 1_234);
        book.setGlobalMakerShare(500);
        book.setPairMakerShare(address(base), address(quote), 9_000, true);
        uint32 count = book.marketCount();
        book.setMarketFee(m, 300, 0);
        assertEq(book.marketCount(), count, "no market listed");
        assertEq(book.configOf(m).feePpm(), 300);
        assertEq(book.configOf(m).version(), 3, "the third version");
        assertEq(_shareOf(m), 1_234);
        // a fresh listing of the pair takes the pair's share
        assertEq(_shareOf(book.listMarketQuote(address(base), address(quote), 400, 6, 1, 0)), 9_000);
    }

    // ================================================================ selectors

    /// Every cold entry these levels add or rename, and every fee level's, sorts after every hot entry's: the
    /// dispatcher compares selectors in order, so a cold selector sorting before a hot entry costs it about 22 gas a
    /// call. Pinned, so a rename that moves one is seen.
    function test_cold_selectors_sort_after_hot_entries() public pure {
        bytes4[11] memory hot = [
            IOloBook.cancel.selector,
            IOloBook.place.selector,
            IOloBook.deposit.selector,
            IOloBook.takeThenRest.selector,
            IOloBook.modify.selector,
            IOloBook.manageBatchSubs.selector,
            IOloBook.take.selector,
            IOloBook.multicall.selector,
            IOloBook.claim.selector,
            IOloBook.withdrawTo.selector,
            IOloBook.withdraw.selector
        ];
        uint32 lastHot;
        for (uint256 i; i < hot.length; ++i) {
            if (uint32(hot[i]) > lastHot) lastHot = uint32(hot[i]);
        }
        assertEq(lastHot, uint32(0xf3fef3a3), "withdraw sorts last of the hot entries");
        bytes4[8] memory cold = [
            IOloBookExt.setGlobalMakerShare.selector,
            IOloBookExt.setPairMakerShare.selector,
            IOloBookExt.setMarketMakerShare.selector,
            IOloBookExt.setGlobalFeeFloor.selector,
            IOloBookExt.setPairFeeFloor.selector,
            IOloBookExt.setMarketFee.selector,
            IOloBook.pairDefaultsOf.selector,
            IOloBookExt.listMarketQuote.selector
        ];
        bytes4[8] memory pinned = [
            bytes4(0xf461c1f5),
            bytes4(0xf7f5cbd8),
            bytes4(0xfb8d7721),
            bytes4(0xf4ea73bb),
            bytes4(0xffacda61),
            bytes4(0xfe317271),
            bytes4(0xfae51ae8),
            bytes4(0xfb2f1996)
        ];
        for (uint256 i; i < cold.length; ++i) {
            assertEq(cold[i], pinned[i]);
            assertGt(uint32(cold[i]), lastHot);
        }
    }
}
