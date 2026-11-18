// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {BatchView} from "./BatchView.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {OloMath} from "../src/libraries/OloMath.sol";
import {BatchLib, PoolWord} from "../src/OloTypes.sol";

using MarketLib for MarketWord;

/// Every event of the OLO EVM contract read from the logs: found by signature, its data decoded with abi.decode
/// against the declared types, the values checked against what the call did. Take is logged by hand from a
/// buffer, so its layout is tested here rather than assumed.
contract OloEventsTest is OloBase {
    function setUp() public {
        _deploy();
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    /// The one log with signature `sig` among `logs`.
    function _only(Vm.Log[] memory logs, string memory sig) internal pure returns (Vm.Log memory l) {
        bytes32 t = keccak256(bytes(sig));
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == t) {
                l = logs[i];
                n++;
            }
        }
        require(n == 1, string.concat("expected exactly one ", sig));
    }

    function _addr(bytes32 t) internal pure returns (address) {
        return address(uint160(uint256(t)));
    }

    /// packed: tick 0-25 | isBid 26 | q 27-31 | amount 32-143 (base wei, as stored) | pos 144-175 | market key 176-223
    /// (the version 176-191, the id 192-223) | (Modified: the old tick 224-249). The amounts here below 2^30 rest at q
    /// 0.
    function _check(uint256 packed, uint256 tick, bool isBid, uint256 amount, uint256 pos) internal view {
        _check(packed, tick, isBid, 0, amount, pos);
    }

    function _check(uint256 packed, uint256 tick, bool isBid, uint256 q, uint256 amount, uint256 pos) internal view {
        assertEq(packed & 0x3ffffff, tick, "packed tick");
        assertEq((packed >> 26) & 1, isBid ? 1 : 0, "packed side");
        assertEq((packed >> 27) & 0x1f, q, "packed q");
        assertEq((packed >> 32) & ((1 << 112) - 1), amount, "packed amount");
        assertEq((packed >> 144) & 0xffffffff, pos, "packed pos");
        assertEq((packed >> 176) & 0xffffffffffff, _key48(), "packed market key: the id and the version");
    }

    /// The fixture market's key as the events carry it: its id << 16 | the version `c` names.
    function _key48() internal view returns (uint256) {
        return MarketWord.unwrap(c) >> 208;
    }

    function test_maker_events() public {
        address a = _maker();
        uint32 pos = _pos();
        vm.recordLogs();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 2, 5 * LOT, pos, 0));
        Vm.Log memory l = _only(vm.getRecordedLogs(), "Placed(address,uint256)");
        assertEq(l.topics.length, 2);
        assertEq(_addr(l.topics[1]), a);
        _check(abi.decode(l.data, (uint256)), T + 2, false, 5 * LOT, pos);

        vm.recordLogs();
        vm.prank(a);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pos, T + 3, 6 * LOT, 0)));
        l = _only(vm.getRecordedLogs(), "Modified(address,uint256)");
        uint256 packed = abi.decode(l.data, (uint256));
        _check(packed & ((1 << 224) - 1), T + 3, false, 6 * LOT, pos);
        assertEq(packed >> 224, T + 2, "the old tick at 224-249");

        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(pos, T + 3)), OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0))
        );
        vm.recordLogs();
        vm.prank(a);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        l = _only(vm.getRecordedLogs(), "Claimed(address,uint256,uint256)");
        uint256 amount;
        (packed, amount) = abi.decode(l.data, (uint256, uint256));
        _check(packed, T + 3, false, 2 * LOT, pos);
        assertEq(amount, 2 * _lq(T + 3), "proceeds without the fee share");

        vm.recordLogs();
        vm.prank(a);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        l = _only(vm.getRecordedLogs(), "Cancelled(address,uint256)");
        _check(abi.decode(l.data, (uint256)), T + 3, false, 4 * LOT, pos);
        // a q > 0 order logs the amount it stored: 1,234,567,891 rests as 123,456,789 units of 10
        vm.recordLogs();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(true, T - 2, 1_234_567_891, pos, 0));
        l = _only(vm.getRecordedLogs(), "Placed(address,uint256)");
        _check(abi.decode(l.data, (uint256)), T - 2, true, 1, 1_234_567_890, pos);
    }

    /// The events name the order's q, which its amount alone does not: 1,073,741,829 base wei rests as 107,374,182
    /// units of 10 (q 1, the smallest q with fewer than 2^30 units), and stores 1,073,741,820, which is also
    /// 1,073,741,820 units of 1 (q 0). A reader of the amount alone would take the order's unit for 1 wei; the
    /// q in the event, the word and every later event say 10. The take after fills whole units of 10.
    function test_maker_events_name_q() public {
        address a = _maker();
        uint32 pos = _pos();
        vm.recordLogs();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 2, 1_073_741_829, pos, 0));
        Vm.Log memory l = _only(vm.getRecordedLogs(), "Placed(address,uint256)");
        _check(abi.decode(l.data, (uint256)), T + 2, false, 1, 1_073_741_820, pos);
        (uint256 q0, uint256 u0) = OloMath.toUnits(1_073_741_820);
        assertEq(q0, 0, "the stored amount alone reads as q 0");
        assertEq(u0, 1_073_741_820);
        assertEq(PoolWord.wrap(book.orderWord(c, pos)).qOf(), 1, "the word's q");
        // a take of 25 wei fills 2 units of 10
        vm.prank(taker);
        (uint256 got,) = book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(pos, T + 2)), OloOps.tagW(c, OloOps.takeW(true, 25, 0))
        );
        assertEq(got, 20, "whole units of 10");
        vm.recordLogs();
        vm.prank(a);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pos, T + 2, 1_073_741_829, 0)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        l = _only(logs, "Claimed(address,uint256,uint256)");
        (uint256 packed,) = abi.decode(l.data, (uint256, uint256));
        _check(packed, T + 2, false, 1, 20, pos);
        l = _only(logs, "Modified(address,uint256)");
        _check(abi.decode(l.data, (uint256)) & ((1 << 224) - 1), T + 2, false, 1, 1_073_741_820, pos);
        vm.recordLogs();
        vm.prank(a);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        l = _only(vm.getRecordedLogs(), "Cancelled(address,uint256)");
        _check(abi.decode(l.data, (uint256)), T + 2, false, 1, 1_073_741_820, pos);
    }

    function test_account_events() public {
        address a = _maker();
        vm.recordLogs();
        vm.prank(a);
        book.deposit(address(quote), 7e6);
        Vm.Log memory l = _only(vm.getRecordedLogs(), "Deposit(address,address,uint256)");
        assertEq(l.topics.length, 3);
        assertEq(_addr(l.topics[1]), a);
        assertEq(_addr(l.topics[2]), address(quote));
        uint256 amount = abi.decode(l.data, (uint256));
        assertEq(amount, 7e6);

        vm.recordLogs();
        vm.prank(a);
        book.withdrawTo(address(quote), 3e6, address(0xD1));
        l = _only(vm.getRecordedLogs(), "Withdraw(address,address,address,uint256)");
        assertEq(_addr(l.topics[1]), a);
        assertEq(_addr(l.topics[2]), address(quote));
        address to;
        (to, amount) = abi.decode(l.data, (address, uint256));
        assertEq(to, address(0xD1));
        assertEq(amount, 3e6);
        assertEq(quote.balanceOf(address(0xD1)), 3e6);
    }

    function test_ops_event() public {
        address a = _plain(T + 2, false, 5 * LOT);
        bytes memory stream = _mc(OloOps.cancel(0, posOf[a]));
        vm.recordLogs();
        vm.prank(a);
        book.multicall(0, stream);
        Vm.Log memory l = _only(vm.getRecordedLogs(), "Ops(address,bytes)");
        assertEq(_addr(l.topics[1]), a);
        assertEq(abi.decode(l.data, (bytes)), stream, "the stream itself");
    }

    function test_take_event() public {
        address a = _plain(T + 1, false, 3 * LOT);
        address z = _maker();
        vm.prank(z);
        _mb(c, OloOps.postW(false, 31, T + 2, 4 * LOT, 2)); // asks at T+2, T+3
        bytes memory list = bytes.concat(
            OloOps.poolList(_poolEntry(a)), OloOps.batchList(OloOps.slotGroup(z, 31, 0x3, [T + 2, T + 3, 0, 0]))
        );
        vm.recordLogs();
        vm.prank(taker);
        (uint256 filled, uint256 quoteAmount) =
            book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, 9 * LOT, 0)));
        Vm.Log memory l = _only(vm.getRecordedLogs(), "Take(uint48,address,uint256,uint256,uint256,uint256,bytes)");
        assertEq(l.topics.length, 3);
        assertEq(uint256(l.topics[1]), _key48(), "the market key: the id and the version");
        assertEq(_addr(l.topics[2]), taker);
        (uint256 packed, uint256 base_, uint256 quote_, uint256 fee, bytes memory fills) =
            abi.decode(l.data, (uint256, uint256, uint256, uint256, bytes));
        assertEq(filled, 9 * LOT);
        assertEq(packed & 1, 1, "buy");
        assertEq(packed >> 8, 3, "three fills");
        assertEq(base_, filled);
        assertEq(base_, 9e6);
        uint256 q = 3 * _lq(T + 1) + 4 * _lq(T + 2) + 2 * _lq(T + 3);
        assertEq(quote_, q, "the exact sum, one rounding");
        assertEq(fee, (q * 50 + 999_999) / 1_000_000, "ceil(quote x feePpm)");
        assertEq(quoteAmount, q + fee);
        // segment 0: kind 0, one record (pos 4 | q 1 | units 4); segment 1: kind 1, one group: maker 20 | slot 2 |
        // n 1 | 2 x (index 1 | q 1 | units 4); each segment's header kind 1 | length 3
        assertEq(
            fills,
            abi.encodePacked(
                abi.encodePacked(uint8(0), uint24(9), posOf[a], uint8(0), uint32(3 * LOT)),
                abi.encodePacked(uint8(1), uint24(35), z, uint16(31), uint8(2)),
                abi.encodePacked(uint8(0), uint8(0), uint32(4 * LOT), uint8(1), uint8(0), uint32(2 * LOT))
            ),
            "two segments"
        );
    }

    /// Every batch operation logs BatchUpdated: kind | the sub-orders acted on << 8 | slot << 128 | market key << 144
    /// (the version 144-159, the id 160-191), and the slot's two words after.
    function test_batch_events() public {
        address z = _maker();
        vm.recordLogs();
        vm.prank(z);
        _mb(c, OloOps.postW(true, 32, T + 2, 4 * LOT, 3)); // bids at T+2, T+1, T
        Vm.Log memory l = _only(vm.getRecordedLogs(), "BatchUpdated(address,uint256,uint256,uint256)");
        assertEq(_addr(l.topics[1]), z);
        (uint256 packed, uint256 word, uint256 set) = abi.decode(l.data, (uint256, uint256, uint256));
        assertEq(packed & 7, 0, "post");
        assertEq((packed >> 8) & 0xf, 0x7, "sub-orders 0-2 rested");
        assertEq(uint16(packed >> 128), 32, "the slot");
        assertEq(uint32(packed >> 160), m, "the market");
        assertEq(uint16(packed >> 144), 1, "its version");
        assertEq(packed & ~(uint256(0xf07) | (uint256(0xffff) << 128) | (uint256(0xffffffffffff) << 144)), 0);
        (uint256 w0, uint256 s0) = book.batchOf(c, z, 32);
        assertEq(word, w0, "the word after");
        assertEq(set, s0, "the settlement word after");
        assertEq(BatchView.bidMask(word), 0x7, "three bids, sub-orders 0-2: an empty sub-order has no side");
        assertEq(BatchView.bidMask(word), BatchLib.liveMask(word), "every live sub-order a bid");
        assertEq(BatchView.openOf(word, 2), 4 * LOT);
        assertEq(BatchView.baseOf(set, 2), 4 * LOT, "the base, units at q 0");

        vm.recordLogs();
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CANCEL, 32, 0, 0x2));
        l = _only(vm.getRecordedLogs(), "BatchUpdated(address,uint256,uint256,uint256)");
        (packed, word, set) = abi.decode(l.data, (uint256, uint256, uint256));
        assertEq(packed & 7, 3, "cancel");
        assertEq((packed >> 8) & 0xf, 0x2, "sub-order 1");
        (w0, s0) = book.batchOf(c, z, 32);
        assertEq(word, w0, "the word after");
        assertEq(set, s0, "the settlement word after");
        assertEq(BatchView.openOf(word, 1), 0);
        assertEq(BatchView.filledOf(word, set, 1), 0, "nothing to claim on it (its base is left over)");
        assertEq(BatchView.openOf(word, 0), 4 * LOT);
    }

    function test_admin_events() public {
        MockERC20 b2 = new MockERC20("Bee", "BEE", 6);
        MockERC20 q2 = new MockERC20("Quu", "QUU", 6);
        vm.recordLogs();
        uint32 id = book.listMarketQuote(address(b2), address(q2), 50, 6, 1, 0);
        Vm.Log memory l = _only(vm.getRecordedLogs(), "MarketListed(uint32,address,address,uint256)");
        assertEq(uint256(l.topics[1]), id);
        (address bb, address qq, uint256 config) = abi.decode(l.data, (address, address, uint256));
        assertEq(bb, address(b2));
        assertEq(qq, address(q2));
        assertEq(config, MarketWord.unwrap(book.configOf(id)), "C");

        vm.recordLogs();
        book.setMarketMakerShare(m, 8000);
        l = _only(vm.getRecordedLogs(), "MarketConfigSet(uint32,uint16,uint256)");
        assertEq(uint256(l.topics[1]), m);
        (uint16 version, uint256 next) = abi.decode(l.data, (uint16, uint256));
        assertEq(version, 2, "the second version");
        assertEq(next, MarketWord.unwrap(book.configOf(m)), "the new C");
        assertEq(book.configOf(m).makerBps(), 8000, "its share");
        assertEq(
            next ^ MarketWord.unwrap(c),
            (uint256(8000 ^ 10_000) << 174) | (uint256(1 ^ 2) << 208),
            "the share, the version"
        );
        c = book.configOf(m);

        vm.recordLogs();
        book.setMarketFee(m, 60, 0);
        l = _only(vm.getRecordedLogs(), "MarketConfigSet(uint32,uint16,uint256)");
        (version, next) = abi.decode(l.data, (uint16, uint256));
        assertEq(version, 3, "the third version");
        assertEq(
            next ^ MarketWord.unwrap(c), (uint256(50 ^ 60) << 188) | (uint256(2 ^ 3) << 208), "the fee, the version"
        );
        c = book.configOf(m);

        vm.recordLogs();
        book.setFeeRecipient(address(0xFEE));
        l = _only(vm.getRecordedLogs(), "FeeRecipientSet(address)");
        assertEq(abi.decode(l.data, (address)), address(0xFEE));

        // at the market's new share, a fill's settle leaves the protocol 20% of its fee
        address a = _maker();
        uint32 pos = 9_000_000;
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 2, 5 * LOT, pos, 0));
        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(pos, T + 2)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0))
        );
        vm.prank(a);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        uint256 pot = _pot(quote);
        assertGt(pot, 0, "protocol fee");
        vm.recordLogs();
        book.collectFees(address(quote));
        l = _only(vm.getRecordedLogs(), "FeesCollected(address,address,uint256)");
        assertEq(_addr(l.topics[1]), address(quote));
        (address to, uint256 amount) = abi.decode(l.data, (address, uint256));
        assertEq(to, address(0xFEE));
        assertEq(amount, pot);
        assertEq(quote.balanceOf(address(0xFEE)), pot);
    }

    /// A cancel always leaves the position's word dead (USED and the last owner), so its next order is a rewrite
    /// and the Cancelled event needs no flag for it: bits 25-31 of its packed word stay clear.
    function test_cancelled_leaves_a_dead_word() public {
        address a = _plain(T + 2, false, 5 * LOT);
        vm.recordLogs();
        vm.prank(a);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], 0)));
        Vm.Log memory l = _only(vm.getRecordedLogs(), "Cancelled(address,uint256)");
        uint256 packed = abi.decode(l.data, (uint256));
        _check(packed, T + 2, false, 5 * LOT, posOf[a]);
        assertTrue(book.orderWord(c, posOf[a]) != 0, "the word stays");
    }

    /// The Take event's fee is what the taker paid, held by the contract whole: its packed word carries no protocol
    /// part and the pot gains nothing until the maker settles, when the fee splits at the market's share then.
    function test_take_event_holds_the_fee() public {
        _setMarketShare(8_000);
        address a = _plain(T + 2_000, false, 5 * LOT);
        uint256 pot0 = _pot(quote);
        vm.recordLogs();
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0)));
        Vm.Log memory l = _only(vm.getRecordedLogs(), "Take(uint48,address,uint256,uint256,uint256,uint256,bytes)");
        (uint256 packed,,, uint256 fee,) = abi.decode(l.data, (uint256, uint256, uint256, uint256, bytes));
        // fee 5 x 102,000 x 10 x 50 ppm = 255 exactly
        assertEq(fee, 255);
        assertEq(packed, 1 | (1 << 8), "buy, one fill, nothing else");
        assertEq(_pot(quote), pot0, "the take holds the fee");
        // the maker's settle: floor(255 x 80%) = 204 to the maker, 51 to the pot
        uint256 qa = _bal(a, quote);
        vm.prank(a);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], 0)));
        assertEq(_bal(a, quote) - qa, 5 * 1_020_000 + 204);
        assertEq(_pot(quote) - pot0, 51);
    }

    /// Warming logs what it wrote, and so do the global share and a listing that warms: every pool position can be
    /// rebuilt from the logs alone.
    function test_warm_events() public {
        vm.recordLogs();
        book.warmPool(m, 100, 4);
        Vm.Log memory l = _only(vm.getRecordedLogs(), "PoolWarmed(uint48,uint32,uint256)");
        assertEq(uint256(l.topics[1]), _key48(), "the market key: the version whose positions were written");
        (uint32 from, uint256 n) = abi.decode(l.data, (uint32, uint256));
        assertEq(from, 100);
        assertEq(n, 4);

        vm.recordLogs();
        book.setGlobalMakerShare(9_000);
        l = _only(vm.getRecordedLogs(), "GlobalMakerShareSet(uint16)");
        assertEq(abi.decode(l.data, (uint16)), 9_000);

        MockERC20 b2 = new MockERC20("Bee", "BEE", 6);
        MockERC20 q2 = new MockERC20("Quu", "QUU", 6);
        vm.recordLogs();
        uint32 id = book.listMarketQuote(address(b2), address(q2), 50, 6, 1, 3);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        MarketWord c2 = book.configOf(id);
        l = _only(logs, "MarketListed(uint32,address,address,uint256)");
        (,, uint256 listedC) = abi.decode(l.data, (address, address, uint256));
        assertEq(MarketWord.wrap(listedC).makerBps(), 9_000, "the global share, in C");
        (uint16 share, bool listed,) = book.makerShareOf(c2);
        assertEq(share, 9_000);
        assertTrue(listed);
        l = _only(logs, "PoolWarmed(uint48,uint32,uint256)");
        assertEq(uint256(l.topics[1]), (uint256(id) << 16) | 1, "the new market's first version");
        (from, n) = abi.decode(l.data, (uint32, uint256));
        assertEq(from, 0);
        assertEq(n, 3);
    }

    /// The Take event's ABI padding is zero when a batch group or a whole segment filled nothing (the walk writes
    /// such a header past the fills, then rolls back): strict decoders reject non-zero padding.
    function test_take_event_zero_padding() public {
        address a = _plain(T + 1, false, 3 * LOT);
        address z = _maker();
        vm.prank(z);
        _mb(c, OloOps.postW(false, 33, T + 2, 4 * LOT, 2)); // asks at T+2, T+3
        bytes memory zero = OloOps.slotGroup(z, 33, 0x1, [T + 2, 0, 0, 0]);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.batchList(zero), OloOps.tagW(c, OloOps.takeW(true, 4 * LOT, 0)));
        // a position that fills, then a batch segment that fills nothing (its sub-order 0 is filled)
        bytes memory list = bytes.concat(OloOps.poolList(_poolEntry(a)), OloOps.batchList(zero));
        vm.recordLogs();
        vm.prank(taker);
        book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, 9 * LOT, 0)));
        Vm.Log memory l = _only(vm.getRecordedLogs(), "Take(uint48,address,uint256,uint256,uint256,uint256,bytes)");
        (uint256 packed, uint256 b_, uint256 q_, uint256 fee, bytes memory fills) =
            abi.decode(l.data, (uint256, uint256, uint256, uint256, bytes));
        assertEq(fills.length, 13, "the position segment only");
        assertEq(l.data, abi.encode(packed, b_, q_, fee, fills), "segment rolled back: zero padding");
        // one batch segment: a group that fills (sub-order 1), then a group that fills nothing (sub-order 0)
        list = OloOps.batchList(bytes.concat(OloOps.slotGroup(z, 33, 0x2, [uint256(0), T + 3, 0, 0]), zero));
        vm.recordLogs();
        vm.prank(taker);
        book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, 9 * LOT, 0)));
        l = _only(vm.getRecordedLogs(), "Take(uint48,address,uint256,uint256,uint256,uint256,bytes)");
        (packed, b_, q_, fee, fills) = abi.decode(l.data, (uint256, uint256, uint256, uint256, bytes));
        assertEq(fills.length, 4 + 23 + 6, "one group of one");
        assertEq(l.data, abi.encode(packed, b_, q_, fee, fills), "empty group past the fills: zero padding");
    }

    /// A market's C carries its id (bits 224-255) and version (208-223), the key its events carry, assigned at the
    /// listing: two listings differing in one parameter get consecutive ids, and the same parameters listed again
    /// revert MarketExists.
    function test_market_id_in_c() public {
        MockERC20 b2 = new MockERC20("Bee", "BEE", 6);
        MockERC20 q2 = new MockERC20("Quu", "QUU", 6);
        uint32 id = book.listMarketQuote(address(b2), address(q2), 50, 6, 1, 0);
        uint32 id3 = book.listMarketQuote(address(b2), address(q2), 70, 6, 1, 0);
        assertEq(id3, id + 1);
        uint256 w2 = MarketWord.unwrap(book.configOf(id));
        uint256 w3 = MarketWord.unwrap(book.configOf(id3));
        assertEq(w2 >> 224, id);
        assertEq(w3 >> 224, id3);
        assertEq(w3 ^ w2, (uint256(50 ^ 70) << 188) | (uint256(id ^ id3) << 224), "only the fee and the id differ");
        vm.expectRevert(bytes4(keccak256("MarketExists()")));
        book.listMarketQuote(address(b2), address(q2), 70, 6, 1, 0);
    }
}
