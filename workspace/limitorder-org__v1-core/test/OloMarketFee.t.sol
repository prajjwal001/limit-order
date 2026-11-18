// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IOloBook} from "../src/interfaces/IOloBook.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {IOwned2Step} from "../src/interfaces/IOwned2Step.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";

using MarketLib for MarketWord;

/// Fee floors and fee moves. A listing's fee is at least its pair's floor when the owner set one (above or below the
/// global floor, 0 included), else the global floor. `setMarketFee` moves a market's fee in place, as its next version:
/// the id and the key K stay, C's fee and version change. An older version's orders still fill at its fee and settle at
/// its share (take, takeThenRest that rests nothing, cancel, claim, batch cancel and claim, multicall CANCEL and
/// CLAIM), and nothing rests there again (modify, batch replace and modify, multicall PLACE and MODIFY under its C
/// revert MarketFrozen), while every entry naming the market by K rests in the current version.
contract OloMarketFeeTest is OloBase {
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

    function _listAt(MockERC20 b, MockERC20 q, uint24 ppm) internal returns (uint32) {
        return book.listMarketQuote(address(b), address(q), ppm, 6, 1, 0);
    }

    function _sorted(address x, address y) internal pure returns (address, address) {
        return x < y ? (x, y) : (y, x);
    }

    function _active(MarketWord mc) internal view returns (bool active) {
        (,, active) = book.makerShareOf(mc);
    }

    /// The fee floor half of `pairDefaultsOf`.
    function _floorsOf(address x, address y) internal view returns (uint24 floor, uint24 global, bool pairSet) {
        (floor, global, pairSet,,,) = book.pairDefaultsOf(x, y);
    }

    // ================================================================ fee floors

    /// The fixture's OLO EVM contract is born with no floor (its constructor's 0): any fee lists, 0 included.
    function test_floors_start_at_zero() public {
        (uint24 floor, uint24 global, bool pairSet) = _floorsOf(address(base), address(quote));
        assertEq(floor, 0);
        assertEq(global, 0);
        assertFalse(pairSet);
        _listAt(_token("A"), quote, 0);
    }

    /// The global floor: a listing below it reverts, at or above it lists; a market listed before it keeps its fee and
    /// keeps resting orders.
    function test_global_floor() public {
        vm.expectEmit(address(book));
        emit IOloBookBase.GlobalFeeFloorSet(300);
        book.setGlobalFeeFloor(300);
        MockERC20 a = _token("A");
        vm.expectRevert(IOloBookBase.FeeTooLow.selector);
        _listAt(a, quote, 299);
        _listAt(a, quote, 300);
        _listAt(quote, a, 301);
        (uint24 floor, uint24 global, bool pairSet) = _floorsOf(address(a), address(quote));
        assertEq(floor, 300);
        assertEq(global, 300);
        assertFalse(pairSet);
        assertEq(c.feePpm(), 50);
        address mk = _maker();
        vm.prank(mk);
        book.place(OloOps.key(c), OloOps.placeW(false, TK, LOT, _pos(), 0));
    }

    /// A pair's floor holds for both of its markets' sides (either token as base), set with the tokens in either order.
    function test_pair_floor_both_sides() public {
        MockERC20 a = _token("A");
        (address t0, address t1) = _sorted(address(a), address(quote));
        vm.expectEmit(address(book));
        emit IOloBookBase.PairFeeFloorSet(t0, t1, 500);
        book.setPairFeeFloor(address(quote), address(a), 500, true);
        vm.expectRevert(IOloBookBase.FeeTooLow.selector);
        _listAt(a, quote, 499);
        vm.expectRevert(IOloBookBase.FeeTooLow.selector);
        _listAt(quote, a, 499);
        _listAt(a, quote, 500);
        _listAt(quote, a, 500);
        (uint24 floor,, bool pairSet) = _floorsOf(address(a), address(quote));
        assertEq(floor, 500);
        assertTrue(pairSet);
        (floor,, pairSet) = _floorsOf(address(quote), address(a));
        assertEq(floor, 500);
        assertTrue(pairSet);
    }

    /// A pair's floor takes the global floor's place, above it and below it, and a floor of 0 makes the pair free,
    /// which no floor does not (the global one applies).
    function test_pair_floor_overrides_global() public {
        book.setGlobalFeeFloor(300);
        MockERC20 a = _token("A");
        MockERC20 b = _token("B");
        MockERC20 d = _token("D");
        book.setPairFeeFloor(address(a), address(quote), 0, true);
        book.setPairFeeFloor(address(b), address(quote), 1_000, true);
        _listAt(a, quote, 0);
        vm.expectRevert(IOloBookBase.FeeTooLow.selector);
        _listAt(b, quote, 999);
        _listAt(b, quote, 1_000);
        vm.expectRevert(IOloBookBase.FeeTooLow.selector);
        _listAt(d, quote, 0);
        (uint24 floor, uint24 global, bool pairSet) = _floorsOf(address(a), address(quote));
        assertEq(floor, 0);
        assertEq(global, 300);
        assertTrue(pairSet);
        (floor, global, pairSet) = _floorsOf(address(d), address(quote));
        assertEq(floor, 300);
        assertFalse(pairSet);
    }

    /// Lifting a pair's floor falls back to the global floor.
    function test_lift_pair_floor() public {
        book.setGlobalFeeFloor(300);
        MockERC20 a = _token("A");
        book.setPairFeeFloor(address(a), address(quote), 0, true);
        (address t0, address t1) = _sorted(address(a), address(quote));
        vm.expectEmit(address(book));
        emit IOloBookBase.PairFeeFloorLifted(t0, t1);
        book.setPairFeeFloor(address(quote), address(a), 0, false);
        (uint24 floor,, bool pairSet) = _floorsOf(address(a), address(quote));
        assertEq(floor, 300);
        assertFalse(pairSet);
        vm.expectRevert(IOloBookBase.FeeTooLow.selector);
        _listAt(a, quote, 0);
    }

    /// Floors are keyed by address: one set before either token was ever listed holds for the pair's first listing.
    function test_pair_floor_before_registration() public {
        MockERC20 a = _token("A");
        MockERC20 b = _token("B");
        assertEq(book.tokenId(address(a)), 0);
        assertEq(book.tokenId(address(b)), 0);
        book.setPairFeeFloor(address(a), address(b), 700, true);
        vm.expectRevert(IOloBookBase.FeeTooLow.selector);
        _listAt(a, b, 699);
        _listAt(a, b, 700);
    }

    function test_floor_guards() public {
        vm.startPrank(STRANGER);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setGlobalFeeFloor(1);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setPairFeeFloor(address(base), address(quote), 1, true);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setPairFeeFloor(address(base), address(quote), 0, false);
        vm.stopPrank();
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setGlobalFeeFloor(1_000_001);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setGlobalFeeFloor(type(uint32).max);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setPairFeeFloor(address(base), address(quote), 1_000_001, true);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setPairFeeFloor(address(base), address(quote), type(uint32).max, true);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setPairFeeFloor(address(base), address(base), 1, true);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setPairFeeFloor(address(base), address(base), 0, false);
        // a lift names no floor
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setPairFeeFloor(address(base), address(quote), 1, false);
        // the largest fee is a floor too (reached 1% a call: FeeStepTooLarge past it, "Fee steps" below)
        _walkGlobalFloor(1_000_000);
        _walkPairFloor(address(base), address(quote), 1_000_000);
        (uint24 floor, uint24 global, bool pairSet) = _floorsOf(address(base), address(quote));
        assertEq(floor, 1_000_000);
        assertEq(global, 1_000_000);
        assertTrue(pairSet);
    }

    // ================================================================ the floor an OLO EVM contract is born with

    /// An OLO EVM contract's init code with the global fee floor `floorPpm`, the fixture's artifact (hirun when built).
    function _bookInit(address ext, uint256 floorPpm) internal view returns (bytes memory) {
        return bytes.concat(
            vm.getCode(vm.exists(BOOK) ? BOOK : "OloBook.sol:OloBook"), abi.encode(address(this), ext, floorPpm)
        );
    }

    /// Creates an OLO EVM contract born with `floorPpm`; returns it, or zero and the selector it reverted with.
    function _bornWith(uint256 floorPpm) internal returns (address made, bytes4 err) {
        bytes memory init = _bookInit(book.ext(), floorPpm);
        assembly ("memory-safe") {
            made := create(0, add(init, 0x20), mload(init))
            if iszero(made) {
                returndatacopy(0x00, 0x00, 4)
                err := and(mload(0x00), shl(224, 0xffffffff))
            }
        }
    }

    /// The contract's GlobalFeeFloorSet events since `vm.recordLogs`, and the last one's floor.
    function _floorLogs(address made) internal returns (uint256 n, uint24 last) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != made || logs[i].topics[0] != IOloBookBase.GlobalFeeFloorSet.selector) continue;
            ++n;
            last = abi.decode(logs[i].data, (uint24));
        }
    }

    /// An OLO EVM contract born with a floor of 1,000 ppm (10 bps) holds it from its first
    /// block and logs it at its birth: a listing below it is FeeTooLow, at it lists; a pair's own floor still takes its
    /// place, below it too; and the owner moves it later as before, back to 0 included.
    function test_born_with_a_floor() public {
        vm.recordLogs();
        (address made,) = _bornWith(1000);
        (uint256 n, uint24 logged) = _floorLogs(made);
        assertEq(n, 1, "logged once, at the birth");
        assertEq(logged, 1000);
        IOloBook b = IOloBook(made);
        (uint24 floor, uint24 global, bool pairSet,,,) = b.pairDefaultsOf(address(base), address(quote));
        assertEq(floor, 1000);
        assertEq(global, 1000);
        assertFalse(pairSet);
        MockERC20 a = _token("A");
        vm.expectRevert(IOloBookBase.FeeTooLow.selector);
        b.listMarketQuote(address(a), address(quote), 999, 6, 1, 0);
        b.listMarketQuote(address(a), address(quote), 1000, 6, 1, 0);
        // a pair's own floor below the global one: the pair lists at it
        MockERC20 d = _token("D");
        b.setPairFeeFloor(address(d), address(quote), 200, true);
        vm.expectRevert(IOloBookBase.FeeTooLow.selector);
        b.listMarketQuote(address(d), address(quote), 199, 6, 1, 0);
        b.listMarketQuote(address(d), address(quote), 200, 6, 1, 0);
        // the owner moves the global floor up, and back to 0
        b.setGlobalFeeFloor(1500);
        MockERC20 e = _token("E");
        vm.expectRevert(IOloBookBase.FeeTooLow.selector);
        b.listMarketQuote(address(e), address(quote), 1499, 6, 1, 0);
        b.setGlobalFeeFloor(0);
        b.listMarketQuote(address(e), address(quote), 0, 6, 1, 0);
    }

    /// An OLO EVM contract born with no floor logs that too, so the logs give the floor from the first block.
    function test_born_with_no_floor_logs_it() public {
        vm.recordLogs();
        (address made,) = _bornWith(0);
        (uint256 n, uint24 logged) = _floorLogs(made);
        assertEq(n, 1);
        assertEq(logged, 0);
        (, uint24 global,,,,) = IOloBook(made).pairDefaultsOf(address(base), address(quote));
        assertEq(global, 0);
    }

    /// The floor an OLO EVM contract is born with is bounded as `setGlobalFeeFloor` bounds it, the bound checked before
    /// the value is narrowed to its uint24: 1,000,000 is the largest, 1,000,001 and 2^24 (whose low 24 bits are 0)
    /// deploy nothing.
    function test_born_with_a_floor_within_the_bound() public {
        (address made, bytes4 err) = _bornWith(1_000_001);
        assertEq(made, address(0), "no book above the largest fee");
        assertEq(err, IOloBookBase.BadMarketConfig.selector);
        (made, err) = _bornWith(1 << 24);
        assertEq(made, address(0), "the bound checked before the narrowing");
        assertEq(err, IOloBookBase.BadMarketConfig.selector);
        (made,) = _bornWith(1_000_000);
        (, uint24 global,,,,) = IOloBook(made).pairDefaultsOf(address(base), address(quote));
        assertEq(global, 1_000_000);
    }

    // ================================================================ setMarketFee

    /// The fixture market's C at another fee and id.
    function _potPart(uint256 fee, uint256 shareBps) internal pure returns (uint256) {
        return fee - fee * shareBps / 10_000;
    }

    /// The fixture market's C at fee `ppm` and version `v` (its key and share as they are).
    function _at(uint24 ppm, uint16 v) internal view returns (MarketWord) {
        uint256 w = MarketWord.unwrap(c) & ~(uint256(0xfffff) << 188) & ~(uint256(0xffff) << 208);
        return MarketWord.wrap(w | (uint256(ppm) << 188) | (uint256(v) << 208));
    }

    /// `setMarketFee` makes the market's next version in place: the id and the key stay, C's fee and version change
    /// (MarketConfigSet), the share is kept, no market is listed. The version before is current no more.
    function test_setMarketFee_makes_the_next_version() public {
        _setMarketShare(6_000); // version 2
        MarketWord v2 = c;
        MarketWord v3 = _at(300, 3);
        uint32 count = book.marketCount();
        vm.recordLogs();
        book.setMarketFee(m, 300, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one event");
        assertEq(logs[0].topics[0], IOloBookBase.MarketConfigSet.selector);
        assertEq(uint256(logs[0].topics[1]), m);
        assertEq(logs[0].data, abi.encode(uint16(3), MarketWord.unwrap(v3)));
        assertEq(book.marketCount(), count, "no market listed");
        assertEq(MarketWord.unwrap(book.configOf(m)), MarketWord.unwrap(v3));
        assertEq(MarketWord.unwrap(OloOps.key(v3)), MarketWord.unwrap(OloOps.key(v2)), "the key stays");
        assertEq(v3.feePpm(), 300);
        assertEq(v3.makerBps(), 6_000, "the share kept");
        assertEq(v3.spacing(), c.spacing());
        assertEq(v3.minQuote(), c.minQuote());
        (uint16 bps, bool listed, bool active) = book.makerShareOf(v2);
        assertEq(bps, 0, "an older version: no share read back");
        assertTrue(listed);
        assertFalse(active);
        (bps, listed, active) = book.makerShareOf(v3);
        assertEq(bps, 6_000);
        assertTrue(listed && active);
    }

    /// An older version rests nothing new: every entry that rests an order in the version a C names reverts
    /// MarketFrozen there (a modify, a batch replace or modify, a multicall PLACE or MODIFY under its C), and every entry
    /// that names the market by its key rests in the current version instead (a place on any position, a batch post,
    /// a takeThenRest's rest, a multicall PLACE under the key).
    function test_old_version_rests_nothing() public {
        address a = _maker();
        uint32 live = _pos();
        uint32 dead = _pos();
        vm.startPrank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, TK, 5 * LOT, live, 0));
        book.place(OloOps.key(c), OloOps.placeW(false, TK, LOT, dead, 0));
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(dead, 0)));
        _mb(c, OloOps.postW(false, 0, TK, LOT, 2));
        vm.stopPrank();
        MarketWord v1 = c;
        _setMarketFee(300);
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.modify(OloOps.key(v1), OloOps.tagW(v1, OloOps.modifyW(live, TK + 1, 5 * LOT, 0)));
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        _mb(v1, OloOps.ladderW(OloOps.REPLACE, false, 0, 0, TK + 1, LOT, 2, 1));
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        _mb(
            v1,
            OloOps.batchW(
                OloOps.MODIFY, false, 0, 0, 0x1, [OloOps.sub(TK + 2, LOT), uint256(0), uint256(0), uint256(0)]
            )
        );
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.multicall(0, bytes.concat(OloOps.header(v1), OloOps.place(0, TK, false, LOT, 9_998)));
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.multicall(0, bytes.concat(OloOps.header(v1), OloOps.modify(0, live, TK + 1, 5 * LOT)));
        // by the key: the current version, where the old version's positions and slot are fresh
        book.place(OloOps.key(v1), OloOps.placeW(false, TK, LOT, live, 0));
        book.place(OloOps.key(v1), OloOps.placeW(false, TK, LOT, dead, 0));
        _mb(OloOps.key(v1), OloOps.postW(false, 0, TK, LOT, 1));
        book.multicall(0, bytes.concat(OloOps.header(OloOps.key(v1)), OloOps.place(0, TK, false, LOT, 9_998)));
        vm.stopPrank();
        (, uint256 open,,, address owner) = book.orderOf(c, live);
        assertEq(open, LOT, "the new version's order in the old one's position number");
        assertEq(owner, a);
        (, open,,,) = book.orderOf(v1, live);
        assertEq(open, 5 * LOT, "the old order rests on in its version");
        (, open,,,) = book.orderOf(c, 9_998);
        assertEq(open, LOT, "the multicall's PLACE by the key");
        (uint256 word,) = book.batchOf(c, a, 0);
        assertTrue(word >> 2 != 0, "the post by the key");
        // a takeThenRest's rest: in the current version, whatever version its fills were in
        uint256 q0 = _bal(taker, quote);
        vm.recordLogs();
        vm.prank(taker);
        (, uint256 paid, uint256 rested, uint256 restId) = book.takeThenRest(
            OloOps.key(v1),
            OloOps.poolList(OloOps.poolEntry(live, TK)),
            OloOps.tagW(v1, OloOps.restW(true, 100 * LOT, TK, 0, 9_997))
        );
        assertEq(rested, 95 * LOT, "5 lots filled in the old version, the rest rests");
        // the fills at version 1's 50 ppm: 5 lots at TK, 5,000,050 quote wei, fee ceil(250.0025) = 251
        assertEq(paid, 5_000_050 + 251, "the fills and their fee, version 1's");
        assertEq(
            q0 - _bal(taker, quote), paid + 95 * 1_000_010, "one debit: the fills, their fee and the rest's escrow"
        );
        assertEq(restId, _orderId(c, 9_997), "the rest's id: the current version's tag");
        (, open,,,) = book.orderOf(c, 9_997);
        assertEq(open, 95 * LOT, "rested in the current version");
        (, open,,,) = book.orderOf(v1, 9_997);
        assertEq(open, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IOloBookBase.Take.selector) {
                assertEq(uint256(logs[i].topics[1]), MarketWord.unwrap(v1) >> 208, "Take: version 1");
                seen |= 1;
            } else if (logs[i].topics[0] == IOloBookBase.Placed.selector) {
                uint256 packed = abi.decode(logs[i].data, (uint256));
                assertEq((packed >> 176) & 0xffffffffffff, MarketWord.unwrap(c) >> 208, "Placed: version 2");
                seen |= 2;
            }
        }
        assertEq(seen, 3, "a Take and a Placed");
    }

    /// An older version's orders fill at its fee and settle at its share, whatever the market's are now: take, a
    /// takeThenRest that rests nothing, claim, cancel, multicall CANCEL and CLAIM under its C, batch claim and cancel;
    /// a later share change reprices none of it.
    function test_old_version_fills_and_settles() public {
        _setMarketShare(4_000); // version 2: the orders below rest here
        address a = _maker();
        uint32[4] memory pos = [_pos(), _pos(), _pos(), _pos()];
        vm.startPrank(a);
        for (uint256 i; i < 4; ++i) {
            book.place(OloOps.key(c), OloOps.placeW(false, TK, 5 * LOT, pos[i], 0));
        }
        _mb(c, OloOps.postW(false, 0, TK, 5 * LOT, 2));
        vm.stopPrank();
        MarketWord v2 = c;
        _setMarketFee(300); // version 3
        // a take of version 2: 5 lots at TK, 5,000,050 quote wei, and its fee: ceil(5,000,050 x 50 / 1e6) = 251
        uint256 q0 = _bal(taker, quote);
        vm.prank(taker);
        book.take(
            OloOps.key(v2),
            OloOps.poolList(OloOps.poolEntry(pos[0], TK)),
            OloOps.tagW(v2, OloOps.takeW(true, 5 * LOT, 0))
        );
        assertEq(q0 - _bal(taker, quote), 5_000_050 + 251);
        // a takeThenRest that fills everything rests nothing
        vm.prank(taker);
        (,, uint256 rested,) = book.takeThenRest(
            OloOps.key(v2),
            OloOps.poolList(OloOps.poolEntry(pos[1], TK)),
            OloOps.tagW(v2, OloOps.restW(true, 2 * LOT, TK, 0, 0))
        );
        assertEq(rested, 0);
        // a share change now (version 4) reprices none of version 2's fills
        _setMarketShare(10_000);
        // the claim: proceeds, and the maker's 40% of the fee floored (250), version 2's share
        uint256 m0 = _bal(a, quote);
        uint256 pot0 = _pot(quote);
        vm.prank(a);
        book.claim(OloOps.key(v2), OloOps.tagW(v2, OloOps.posW(pos[0], 0)));
        uint256 fee = PriceGrid.feeDown(5 * LOT, TK, 50);
        assertEq(fee, 250);
        assertEq(_bal(a, quote) - m0, 5_000_050 + fee * 4_000 / 10_000);
        assertEq(_pot(quote) - pot0, fee - fee * 4_000 / 10_000, "the pot: version 2's 60%");
        // a fill of pos 3 for the multicall's CLAIM below
        vm.prank(taker);
        book.take(
            OloOps.key(v2), OloOps.poolList(OloOps.poolEntry(pos[3], TK)), OloOps.tagW(v2, OloOps.takeW(true, LOT, 0))
        );
        vm.startPrank(a);
        book.cancel(OloOps.key(v2), OloOps.tagW(v2, OloOps.posW(pos[1], 0)));
        // a multicall under version 2's C: a CANCEL of an unfilled order (its 5 lots back), a CLAIM of a lot (its
        // proceeds and version 2's 40% of the fee, 50 ppm), a CANCEL of the rest (4 lots back)
        uint256 bq = _bal(a, quote);
        uint256 bb = _bal(a, base);
        pot0 = _pot(quote);
        book.multicall(
            0,
            bytes.concat(OloOps.header(v2), OloOps.cancel(0, pos[2]), OloOps.claim(0, pos[3]), OloOps.cancel(0, pos[3]))
        );
        fee = PriceGrid.feeDown(LOT, TK, 50); // 50
        assertEq(_bal(a, quote) - bq, 1_000_010 + fee * 4_000 / 10_000, "the claim at version 2's fee and share");
        assertEq(_bal(a, base) - bb, 5 * LOT + 4 * LOT, "the two cancels' refunds");
        assertEq(_pot(quote) - pot0, _potPart(fee, 4_000), "the pot: version 2's 60%");
        vm.stopPrank();
        vm.prank(taker);
        book.take(
            OloOps.key(v2),
            OloOps.batchList(OloOps.slotGroupAt(a, 0, 0x1, TK)),
            OloOps.tagW(v2, OloOps.takeW(true, 3 * LOT, 0))
        );
        vm.startPrank(a);
        _mb(v2, OloOps.maskW(OloOps.CLAIM, 0, 0, 0));
        _mb(v2, OloOps.maskW(OloOps.CANCEL, 0, 0, 0x3));
        vm.stopPrank();
        for (uint256 i; i < 4; ++i) {
            assertEq(book.orderWord(v2, pos[i]) >> 33 & ((1 << 60) - 1), 0, "settled");
        }
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 0, "no base left");
        assertEq(quoteLeft, 4, "quote: the four takes' fee roundings, a wei each");
    }

    /// The new version rests orders and fills them at its own fee.
    function test_new_version_takes_at_new_fee() public {
        _setMarketFee(300);
        address a = _maker();
        uint32 p = _pos();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, TK, 5 * LOT, p, 0));
        uint256 q0 = _bal(taker, quote);
        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(p, TK)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0))
        );
        // ceil(5,000,050 x 300 / 1e6) = 1,501
        assertEq(q0 - _bal(taker, quote), 5_000_050 + 1_501);
    }

    /// A fee set back to an earlier value is a new version, not the old one again: version 1's orders stay in version
    /// 1, which rests nothing new, and new orders rest in version 3 at the same fee.
    function test_fee_set_back_is_a_new_version() public {
        address a = _maker();
        uint32 p = _pos();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, TK, 5 * LOT, p, 0));
        MarketWord v1 = c;
        _setMarketFee(300);
        _setMarketFee(50);
        assertEq(c.version(), 3);
        assertEq(c.feePpm(), 50);
        assertTrue(MarketWord.unwrap(c) != MarketWord.unwrap(v1), "a new C");
        assertFalse(_active(v1));
        vm.prank(a);
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.modify(OloOps.key(v1), OloOps.tagW(v1, OloOps.modifyW(p, TK + 1, 5 * LOT, 0)));
        (, uint256 open,,,) = book.orderOf(v1, p);
        assertEq(open, 5 * LOT, "the order rests on in version 1");
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, TK, LOT, p, 0));
        (, open,,,) = book.orderOf(c, p);
        assertEq(open, LOT, "a new order in version 3");
    }

    function test_setMarketFee_guards() public {
        vm.prank(STRANGER);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setMarketFee(m, 300, 0);
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.setMarketFee(0, 300, 0);
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.setMarketFee(m + 1, 300, 0);
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.setMarketFee(uint256(m) + (1 << 32), 300, 0); // not cut down to m
        vm.expectRevert(IOloBookBase.NoChange.selector);
        book.setMarketFee(m, 50, 0);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setMarketFee(m, 1_000_001, 0);
        // the owner's move meets no floor
        book.setGlobalFeeFloor(1_000);
        book.setMarketFee(m, 10, 0);
        // and moves the market's current version, whichever it is
        book.setMarketFee(m, 300, 0);
        assertEq(book.configOf(m).version(), 3);
    }

    /// The listing parameters are the listing's: the market at its new fee keeps the parameters it listed at taken
    /// (MarketExists) and takes none others, so anyone may list the pair at the fee the market moved to (another
    /// market, another id).
    function test_listing_parameters_stay_the_listing_s() public {
        book.setMarketFee(m, 300, 0);
        vm.expectRevert(IOloBookBase.MarketExists.selector);
        book.listMarketQuote(address(base), address(quote), 50, 6, 1, 0);
        uint32 other = book.listMarketQuote(address(base), address(quote), 300, 6, 1, 0);
        assertEq(other, m + 1, "another market at the fee the first moved to");
        assertEq(book.configOf(other).feePpm(), 300);
        assertEq(book.configOf(other).version(), 1);
        vm.expectRevert(IOloBookBase.MarketExists.selector);
        book.listMarketQuote(address(base), address(quote), 300, 6, 1, 0);
    }

    /// The warming is the new version's.
    function test_setMarketFee_warms_the_new_version() public {
        MarketWord next = _at(300, 2);
        vm.expectEmit(address(book));
        emit IOloBookBase.PoolWarmed(uint48(MarketWord.unwrap(next) >> 208), 0, 3);
        book.setMarketFee(m, 300, 3);
        for (uint32 p; p < 3; ++p) {
            assertEq(book.orderWord(next, p), 1 << 94);
        }
        assertEq(book.orderWord(next, 3), 0);
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(next), OloOps.placeW(false, TK, LOT, 1, 0));
    }

    /// A word whose key bits no listing gave is UnknownMarket, before and after a fee change: other parameters, a listed
    /// market's parameters with another id, the id zero; a place, a multicall PLACE, a batch post.
    function test_unknown_config_still_unknown() public {
        address a = _maker();
        for (uint256 moved; moved < 2; ++moved) {
            if (moved == 1) _setMarketFee(300);
            MarketWord otherId = MarketWord.wrap(MarketWord.unwrap(c) ^ (uint256(7) << 224));
            MarketWord idZero = MarketWord.wrap(MarketWord.unwrap(c) & ~(uint256(0xffffffff) << 224));
            MarketWord noneZero = MarketWord.wrap(MarketWord.unwrap(_wrongC()) & ~(uint256(0xffffffff) << 224));
            vm.startPrank(a);
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            book.place(OloOps.key(_wrongC()), OloOps.placeW(false, TK, LOT, _pos(), 0));
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            book.place(OloOps.key(otherId), OloOps.placeW(false, TK, LOT, _pos(), 0));
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            book.place(OloOps.key(idZero), OloOps.placeW(false, TK, LOT, _pos(), 0));
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            book.place(OloOps.key(noneZero), OloOps.placeW(false, TK, LOT, _pos(), 0));
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            book.place(OloOps.key(MarketWord.wrap(0)), OloOps.placeW(false, TK, LOT, _pos(), 0));
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            book.multicall(0, bytes.concat(OloOps.header(otherId), OloOps.place(0, TK, false, LOT, _pos())));
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            book.multicall(0, bytes.concat(OloOps.header(MarketWord.wrap(0)), OloOps.place(0, TK, false, LOT, _pos())));
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            _mb(otherId, OloOps.postW(false, 0, TK, LOT, 1));
            vm.expectRevert(IOloBookBase.UnknownMarket.selector);
            _mb(MarketWord.wrap(0), OloOps.postW(false, 0, TK, LOT, 1));
            vm.stopPrank();
        }
    }

    /// A multicall checks each market when it switches to it: with the current version and an older one in its
    /// header, it rests on the current one and settles on the older one in any order, and a PLACE or MODIFY on the
    /// older one reverts whatever the stream did first. A header word that is the market's key names the current
    /// version for every op of its run, cancels and claims included.
    function test_multicall_checks_each_market() public {
        address a = _maker();
        uint32 old1 = _pos();
        uint32 old2 = _pos();
        vm.startPrank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, TK, LOT, old1, 0));
        book.place(OloOps.key(c), OloOps.placeW(false, TK, LOT, old2, 0));
        vm.stopPrank();
        MarketWord v1 = c;
        _setMarketFee(300);
        bytes memory hdr = abi.encodePacked(uint8(2), MarketWord.unwrap(c), MarketWord.unwrap(v1));
        uint32 fresh = _pos();
        // version 1's order filled by a lot first, so its CANCEL under the older C pays the fill too
        vm.prank(taker);
        book.take(
            OloOps.key(v1), OloOps.poolList(OloOps.poolEntry(old1, TK)), OloOps.tagW(v1, OloOps.takeW(true, LOT / 2, 0))
        );
        uint256 bq = _bal(a, quote);
        uint256 bb = _bal(a, base);
        vm.startPrank(a);
        book.multicall(
            0,
            bytes.concat(
                hdr,
                OloOps.place(0, TK, false, LOT, fresh),
                OloOps.cancel(1, old1),
                OloOps.place(0, TK, false, LOT, _pos())
            )
        );
        // the CANCEL under version 1's C: half a lot of proceeds and the fee whole at version 1's 100%, the other half
        // back; the two PLACEs escrow two lots in the current version
        uint256 halfQuote = PriceGrid.quoteDown(LOT / 2, TK);
        assertEq(_bal(a, quote) - bq, halfQuote + PriceGrid.feeDown(LOT / 2, TK, 50), "the cancel's proceeds and fee");
        assertEq(bb - _bal(a, base), 2 * LOT - LOT / 2, "two lots escrowed, half a lot back");
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.multicall(
            0, bytes.concat(hdr, OloOps.place(0, TK, false, LOT, _pos()), OloOps.place(1, TK, false, LOT, _pos()))
        );
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.multicall(
            0, bytes.concat(hdr, OloOps.place(0, TK, false, LOT, _pos()), OloOps.modify(1, old2, TK + 1, LOT))
        );
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.multicall(
            0,
            bytes.concat(
                hdr,
                OloOps.place(0, TK, false, LOT, _pos()),
                OloOps.cancel(1, old2),
                OloOps.place(0, TK, false, LOT, _pos()),
                OloOps.place(1, TK, false, LOT, _pos())
            )
        );
        // the key: the current version's order cancels, and a PLACE rests there
        book.multicall(
            0,
            bytes.concat(OloOps.header(OloOps.key(c)), OloOps.cancel(0, fresh), OloOps.place(0, TK, false, LOT, fresh))
        );
        vm.stopPrank();
        (, uint256 open,,,) = book.orderOf(c, fresh);
        assertEq(open, LOT);
        (, open,,,) = book.orderOf(v1, old2);
        assertEq(open, LOT, "the older version's order untouched");
    }

    /// Moves among three fees in any order: each is the market's next version, in place, the id and the key kept and
    /// no market listed; the same fee is NoChange.
    function testFuzz_fee_moves(uint8[12] memory picks) public {
        uint24[3] memory fees = [uint24(50), 300, 1_000];
        uint24 current = 50;
        uint16 version = 1;
        MarketWord k = OloOps.key(c);
        for (uint256 i; i < picks.length; ++i) {
            uint24 fee = fees[picks[i] % 3];
            if (fee == current) {
                vm.expectRevert(IOloBookBase.NoChange.selector);
                book.setMarketFee(m, fee, 0);
                continue;
            }
            book.setMarketFee(m, fee, 0);
            current = fee;
            ++version;
            MarketWord now_ = book.configOf(m);
            assertEq(now_.feePpm(), fee);
            assertEq(now_.version(), version, "one version a move");
            assertEq(MarketWord.unwrap(OloOps.key(now_)), MarketWord.unwrap(k), "the key stays");
            assertTrue(_active(now_));
        }
        assertEq(book.marketCount(), m, "no market listed");
    }

    /// A market has 65,535 versions: the change to the last goes through, the one after reverts TooManyVersions (fee
    /// or share), and the market stays as it was.
    function test_version_cap() public {
        // the registry word of market m (MARKETS_SLOT + m) at version 65,534
        bytes32 slot = bytes32(MARKETS_SLOT + m);
        uint256 w = (MarketWord.unwrap(c) & ~(uint256(0xffff) << 208)) | (uint256(65_534) << 208);
        assertEq(vm.load(address(book), slot), bytes32(MarketWord.unwrap(c)), "the registry slot");
        vm.store(address(book), slot, bytes32(w));
        book.setMarketFee(m, 300, 0);
        assertEq(book.configOf(m).version(), 65_535);
        MarketWord last = book.configOf(m);
        vm.expectRevert(IOloBookBase.TooManyVersions.selector);
        book.setMarketFee(m, 50, 0);
        vm.expectRevert(IOloBookBase.TooManyVersions.selector);
        book.setMarketMakerShare(m, 1);
        assertEq(MarketWord.unwrap(book.configOf(m)), MarketWord.unwrap(last), "unchanged");
        // the last version works as any other
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(last), OloOps.placeW(false, TK, LOT, 5, 0));
        (, uint256 open,,,) = book.orderOf(last, 5);
        assertEq(open, LOT);
    }

    // ================================================================ fee steps
    // Each owner call moves a fee by at most 1% of the quote, MarketLib.MAX_FEE_STEP_PPM (10,000 ppm), up or down:
    // a market's fee by `setMarketFee`, the global floor by `setGlobalFeeFloor`, and the floor a pair's listings meet
    // by `setPairFeeFloor` (its own when set, else the global one; a first set and a lift included). The step is
    // checked after the call's other checks: a bound, an unknown or frozen market and the same fee keep their errors.

    uint256 constant STEP = 10_000;

    function test_fee_step_is_one_percent() public pure {
        assertEq(MarketLib.MAX_FEE_STEP_PPM, STEP);
    }

    /// A market's fee moves 1% a move, up or down, to the ppm: 50 goes to 10,050 and not 10,051; from 10,050 back to 50
    /// and not to 49; several moves go further, each a version.
    function test_market_fee_step() public {
        vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        book.setMarketFee(m, uint24(50 + STEP + 1), 0);
        book.setMarketFee(m, uint24(50 + STEP), 0);
        assertEq(book.configOf(m).feePpm(), 50 + STEP);
        assertFalse(_active(c));
        // 50 - 1 is a step of 10,001 down; 50 is one of 10,000
        vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        book.setMarketFee(m, 49, 0);
        book.setMarketFee(m, 50, 0);
        assertEq(book.configOf(m).feePpm(), 50);
        // a larger change is several moves
        book.setMarketFee(m, uint24(50 + STEP), 0);
        book.setMarketFee(m, uint24(50 + 2 * STEP), 0);
        assertEq(book.configOf(m).feePpm(), 50 + 2 * STEP);
        assertEq(book.configOf(m).version(), 5);
        assertEq(book.marketCount(), m, "no market listed");
    }

    /// The step is the last check of a move: a fee above the bound, an unknown market and the same fee keep their own
    /// errors, however far the fee asked is.
    function test_market_fee_step_after_other_checks() public {
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setMarketFee(m, 1_000_001, 0);
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.setMarketFee(m + 1, 400_000, 0);
        vm.expectRevert(IOloBookBase.NoChange.selector);
        book.setMarketFee(m, 50, 0);
        book.setMarketFee(m, 300, 0);
        vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        book.setMarketFee(m, 400_000, 0);
    }

    /// The global floor moves 1% a call, up or down, to the ppm; a floor above the bound is BadMarketConfig, checked
    /// first; nothing is written or logged by a refused call.
    function test_global_floor_step() public {
        vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        book.setGlobalFeeFloor(uint32(STEP + 1));
        book.setGlobalFeeFloor(uint32(STEP));
        book.setGlobalFeeFloor(uint32(2 * STEP));
        vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        book.setGlobalFeeFloor(uint32(STEP - 1));
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setGlobalFeeFloor(1_000_001);
        (, uint24 global,) = _floorsOf(address(base), address(quote));
        assertEq(global, 2 * STEP, "the refused calls wrote nothing");
        book.setGlobalFeeFloor(uint32(STEP));
        book.setGlobalFeeFloor(0);
    }

    /// The floor an OLO EVM contract is born with takes no step (its constructor's): an OLO EVM contract
    /// born at 1,000,000 is; its owner then moves it 1% a call like any other.
    function test_born_floor_takes_no_step() public {
        (address made,) = _bornWith(1_000_000);
        IOloBook b = IOloBook(made);
        vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        b.setGlobalFeeFloor(0);
        b.setGlobalFeeFloor(uint32(1_000_000 - STEP));
        (, uint24 global,,,,) = b.pairDefaultsOf(address(base), address(quote));
        assertEq(global, 1_000_000 - STEP);
    }

    /// A pair's floor: a first set steps from the global floor, an update from the pair's own, and a lift to the global
    /// floor from the pair's own, so a pair further than 1% from the global floor is stepped toward it before its
    /// lift. A lift naming a value and a floor above the bound keep their BadMarketConfig.
    function test_pair_floor_step() public {
        MockERC20 a = _token("A");
        // a first set, against the global floor (0)
        vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        book.setPairFeeFloor(address(a), address(quote), uint32(STEP + 1), true);
        book.setPairFeeFloor(address(a), address(quote), uint32(STEP), true);
        // an update, against the pair's own floor
        book.setPairFeeFloor(address(quote), address(a), uint32(2 * STEP), true);
        vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        book.setPairFeeFloor(address(a), address(quote), uint32(STEP - 1), true);
        // a lift: from the pair's 20,000 to the global 0 is too far; one step down, then the lift
        vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        book.setPairFeeFloor(address(a), address(quote), 0, false);
        book.setPairFeeFloor(address(a), address(quote), uint32(STEP), true);
        book.setPairFeeFloor(address(a), address(quote), 0, false);
        (uint24 floor,, bool pairSet) = _floorsOf(address(a), address(quote));
        assertEq(floor, 0);
        assertFalse(pairSet);
        // with the global floor at 10,000 a first set reaches 0 and 20,000, not 20,001
        book.setGlobalFeeFloor(uint32(STEP));
        MockERC20 b = _token("B");
        MockERC20 d = _token("D");
        book.setPairFeeFloor(address(b), address(quote), 0, true);
        vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        book.setPairFeeFloor(address(d), address(quote), uint32(2 * STEP + 1), true);
        book.setPairFeeFloor(address(d), address(quote), uint32(2 * STEP), true);
        // a lift of a pair with no floor of its own moves nothing
        book.setPairFeeFloor(address(a), address(quote), 0, false);
        // BadMarketConfig before the step
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setPairFeeFloor(address(d), address(quote), 1, false);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.setPairFeeFloor(address(d), address(quote), 1_000_001, true);
    }

    /// The global floor moves the floor of every pair with no floor of its own by its own step, and leaves a pair's own
    /// floor where it is (the pair's next set or lift steps from that).
    function test_global_step_moves_pairs_without_their_own() public {
        MockERC20 a = _token("A");
        MockERC20 b = _token("B");
        book.setPairFeeFloor(address(b), address(quote), 0, true);
        book.setGlobalFeeFloor(uint32(STEP));
        book.setGlobalFeeFloor(uint32(2 * STEP));
        (uint24 floor,,) = _floorsOf(address(a), address(quote));
        assertEq(floor, 2 * STEP, "the global floor");
        (floor,,) = _floorsOf(address(b), address(quote));
        assertEq(floor, 0, "the pair's own");
        vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        book.setPairFeeFloor(address(b), address(quote), 0, false);
    }

    /// Any market fee to any other: a move passes when the two are at most 10,000 ppm apart (the next version, at the
    /// new fee), and is FeeStepTooLarge (the version and the fee as they were) when they are further.
    function testFuzz_market_fee_step(uint24 fromPpm, uint24 toPpm) public {
        fromPpm = uint24(bound(fromPpm, 0, 1_000_000));
        toPpm = uint24(bound(toPpm, 0, 1_000_000));
        uint32 id = _listAt(_token("A"), quote, fromPpm);
        uint32 count = book.marketCount();
        uint256 apart = fromPpm > toPpm ? fromPpm - toPpm : toPpm - fromPpm;
        if (apart == 0) {
            vm.expectRevert(IOloBookBase.NoChange.selector);
        } else if (apart > STEP) {
            vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        }
        book.setMarketFee(id, toPpm, 0);
        assertEq(book.marketCount(), count, "no market listed");
        if (apart == 0 || apart > STEP) {
            assertEq(book.configOf(id).version(), 1);
            assertEq(book.configOf(id).feePpm(), fromPpm);
        } else {
            assertEq(book.configOf(id).version(), 2);
            assertEq(book.configOf(id).feePpm(), toPpm);
        }
    }

    /// Any global floor to any other: set when the two are at most 10,000 ppm apart, refused otherwise.
    function testFuzz_global_floor_step(uint24 fromPpm, uint24 toPpm) public {
        fromPpm = uint24(bound(fromPpm, 0, 1_000_000));
        toPpm = uint24(bound(toPpm, 0, 1_000_000));
        _walkGlobalFloor(fromPpm);
        uint256 apart = fromPpm > toPpm ? fromPpm - toPpm : toPpm - fromPpm;
        if (apart > STEP) vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        book.setGlobalFeeFloor(toPpm);
        (, uint24 global,) = _floorsOf(address(base), address(quote));
        assertEq(global, apart > STEP ? fromPpm : toPpm);
    }

    /// Any pair floor change, a set or a lift, with or without a floor of the pair's own, at any global floor: it
    /// passes when the floor the pair's listings meet moves by at most 10,000 ppm (from the pair's own, else the global
    /// one, to the floor set, or for a lift the global one), and is refused otherwise, nothing changed.
    function testFuzz_pair_floor_step(uint24 globalPpm, uint24 ownPpm, bool hasOwn, uint24 toPpm, bool lift) public {
        globalPpm = uint24(bound(globalPpm, 0, 1_000_000));
        ownPpm = uint24(bound(ownPpm, 0, 1_000_000));
        toPpm = uint24(bound(toPpm, 0, 1_000_000));
        _walkGlobalFloor(globalPpm);
        MockERC20 a = _token("A");
        if (hasOwn) _walkPairFloor(address(a), address(quote), ownPpm);
        uint256 fromPpm = hasOwn ? ownPpm : globalPpm;
        uint256 target = lift ? globalPpm : toPpm;
        uint256 apart = fromPpm > target ? fromPpm - target : target - fromPpm;
        if (apart > STEP) vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        book.setPairFeeFloor(address(quote), address(a), lift ? 0 : toPpm, !lift);
        (uint24 floor,, bool pairSet) = _floorsOf(address(a), address(quote));
        if (apart > STEP) {
            assertEq(floor, fromPpm, "refused: the floor as it was");
            assertEq(pairSet, hasOwn);
        } else {
            assertEq(floor, target);
            assertEq(pairSet, !lift);
        }
    }
}
