// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {AsmHarness} from "./utils/AsmHarness.sol";
import {Brutalizer} from "./utils/Brutalizer.sol";
import {OloOps} from "./OloOps.sol";
import {OloBookTakes} from "../src/base/OloBookTakes.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {Market, MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {
    AccountLib,
    BATCH_SUB_BASE,
    BATCH_SIDES,
    BATCH_USED,
    OloSlots,
    PoolLib,
    SUB_BITS,
    SUB_OPEN,
    SUB_Q
} from "../src/OloTypes.sol";

using MarketLib for MarketWord;

/// The OLO EVM contract's assembly, nine of its ten blocks, under what it must not care about (Brutalizer): the scratch
/// space and the free memory full of junk, the free memory pointer off its word boundary, narrow arguments with dirty
/// high bits. Each block runs twice on the same inputs, clean and armed, and the two runs must agree on everything it
/// produces; the frame must be intact after the armed one (`_checkMemory`: the free memory pointer, the zero slot, a
/// canary below the free memory). The slot hashes and `load`/`store` run in this frame; `_put` and `_trim`, and the
/// take that writes its event through them, run in AsmHarness. `_delegate`, the tenth, is not covered: it never returns
/// to Solidity.
contract OloAsmMemoryTest is Test, Brutalizer {
    AsmHarness h;
    MockERC20 base;
    MockERC20 quote;
    MarketWord c;

    /// The orders' ticks: decades 38 to 48, P from 1 (LO) to below 1e11 quote wei per base wei.
    uint256 constant LO = 38 * 900_000;
    uint256 constant SPAN = 11 * 900_000;
    uint256 constant UNITS_MAX = (1 << 30) - 1;
    /// The orders' q: 0 to 9, so an order holds below 2^60 base wei.
    uint256 constant Q_MAX = 9;
    /// The taker's (this contract's) account balance of each token: room for any take of up to 2^64 base wei at
    /// those prices (below 2^101 quote wei) and for its proceeds.
    uint256 constant HELD = 1 << 126;

    function setUp() public {
        base = new MockERC20("Base", "B", 18);
        quote = new MockERC20("Quote", "Q", 18);
        h = new AsmHarness(address(base)); // any contract serves as the extension the harness never calls
        h.setToken(1, address(base));
        h.setToken(2, address(quote));
        h.setAccount(1, address(this), AccountLib.USED | HELD);
        h.setAccount(2, address(this), AccountLib.USED | HELD);
        c = _market(50, 1, 0);
    }

    /// A config word of market id 1 on tokens 1 (base) and 2 (quote).
    function _market(uint24 feePpm, uint16 spacing, uint96 minQuote) internal pure returns (MarketWord) {
        Market memory mk = Market({baseId: 1, quoteId: 2, feePpm: feePpm, spacing: spacing, minQuote: minQuote});
        // version 1 and the id 1, as a listing makes them
        return MarketWord.wrap(MarketWord.unwrap(mk.encode()) | (uint256(1) << 208) | (uint256(1) << 224));
    }

    function _rnd(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    /// A tick near `tick`: itself, or a few ticks either side.
    function _near(uint256 tick, uint256 r) internal pure returns (uint256) {
        return tick + r % 7 - 3;
    }

    // ============================================================ the slot hashes and the raw slot

    /// OloSlots' three hashes under junk in the scratch space they hash from, with a dirty maker, and with the
    /// position and the slot number above their fields (masked, as documented).
    function testFuzz_slot_hashes_under_junk(uint256 cw, uint256 pos, address maker, uint256 slot, uint256 seed)
        public
    {
        MarketWord mw = MarketWord.wrap(cw);
        uint256 o = OloSlots.orderSlot(mw, pos);
        uint256 b = OloSlots.batchSlot(mw, maker, slot);
        uint256 s = OloSlots.listingSlot(mw);
        Armed memory armed = _arm(seed);
        uint256 o1 = OloSlots.orderSlot(mw, pos);
        uint256 o2 = OloSlots.orderSlot(mw, pos & 0xffffffff);
        uint256 b1 = OloSlots.batchSlot(mw, _dirtyAddress(maker, seed), slot);
        uint256 b2 = OloSlots.batchSlot(mw, maker, slot & 0xffff);
        uint256 s1 = OloSlots.listingSlot(mw);
        _checkMemory(armed);
        assertEq(o1, o, "orderSlot under junk");
        assertEq(o2, o, "orderSlot masks the position");
        assertEq(b1, b, "batchSlot with a dirty maker");
        assertEq(b2, b, "batchSlot masks the slot number");
        assertEq(s1, s, "listingSlot under junk");
    }

    /// OloSlots.store and load on a raw slot of this contract (above the test contract's own variables), under junk.
    function testFuzz_load_store_under_junk(uint256 slot, uint256 word, uint256 seed) public {
        slot |= 1 << 254;
        Armed memory armed = _arm(seed);
        OloSlots.store(slot, word);
        uint256 read = OloSlots.load(slot);
        _checkMemory(armed);
        assertEq(read, word);
    }

    // ============================================================ the calldata reader (OloBookTakes)

    /// `_word` reads calldata only, so there is no memory to arm: the bytes of its word within `b` are `b`'s from
    /// `start`, whatever calldata follows (`tail`). The contract reads from `start` only when the bytes it uses are
    /// within `b`.
    function testFuzz_word_reads_the_bytes_within(bytes calldata b, uint256 startSeed, bytes calldata tail)
        public
        view
    {
        vm.assume(b.length != 0);
        uint256 start = startSeed % b.length;
        bytes32 w = h.h_word(b, start, tail);
        for (uint256 k; k < 32 && start + k < b.length; ++k) {
            assertEq(w[k], b[start + k], "a byte within b");
        }
    }

    // ============================================================ the two byte writers (OloBookTakes)

    /// `_put` under junk and a misaligned free memory pointer: the 32 bytes at the offset are the word, every other
    /// byte and the length as before, the same from both runs.
    function testFuzz_put_under_junk(bytes memory before, uint256 offsetSeed, bytes32 word, uint256 seed) public view {
        if (before.length < 32) before = bytes.concat(before, new bytes(32));
        uint256 offset = offsetSeed % (before.length - 31);
        bytes memory clean = h.h_put(false, 0, before, offset, word);
        bytes memory armed = h.h_put(true, seed, before, offset, word);
        assertEq(armed, clean, "the same bytes from both runs");
        assertEq(armed.length, before.length, "the length");
        for (uint256 i; i < before.length; ++i) {
            if (i >= offset && i < offset + 32) assertEq(armed[i], word[i - offset], "the word's byte");
            else assertEq(armed[i], before[i], "a byte outside the word");
        }
    }

    /// `_trim` under junk: the length set, the bytes kept as they were, and the whole region as allocated (the
    /// length word and every byte, the trimmed ones included) untouched but for the length.
    function testFuzz_trim_under_junk(bytes memory before, uint256 lenSeed, uint256 seed) public view {
        uint256 length = lenSeed % (before.length + 1);
        (bytes memory armed, bytes32 regionBefore, bytes32 regionAfter) = h.h_trim(true, seed, before, length);
        assertEq(armed.length, length, "the length");
        for (uint256 i; i < length; ++i) {
            assertEq(armed[i], before[i], "a byte kept");
        }
        assertEq(regionAfter, regionBefore, "the region but for the length word");
    }

    // ============================================================ a take through them

    /// Up to six pool orders of either side at random ticks and sizes, a take over entries at or near their ticks.
    function _poolList(uint8 n, uint256 rnd) internal returns (bytes memory list, uint256[] memory slots) {
        bytes memory entries;
        slots = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 r = _rnd(rnd, i);
            uint32 pos = uint32(1000 + i);
            uint256 tick = LO + r % SPAN;
            uint256 units = 1 + ((r >> 32) % UNITS_MAX);
            uint256 q = (r >> 72) % (Q_MAX + 1);
            bool isBid = (r >> 80) & 1 == 1;
            slots[i] = OloSlots.orderSlot(c, pos);
            h.setWord(slots[i], PoolLib.fresh(tick, q, units, isBid, address(uint160(0x1000 + i))));
            entries = bytes.concat(entries, OloOps.poolEntry(pos, _near(tick, r >> 100)));
        }
        list = OloOps.poolList(entries);
    }

    /// Up to three batch slots with four random sub-orders each, each on a random side (its side bit D_i), a take over
    /// groups naming random sub-orders at or near their ticks.
    function _batchList(uint8 k, uint256 rnd) internal returns (bytes memory list, uint256[] memory slots) {
        bytes memory groups;
        slots = new uint256[](k);
        for (uint256 j; j < k; ++j) {
            uint256 r = _rnd(rnd, 100 + j);
            address maker = address(uint160(0x2000 + j));
            uint256 word = BATCH_USED;
            uint256[4] memory ticks;
            for (uint256 i; i < 4; ++i) {
                uint256 ri = _rnd(r, i);
                uint256 tick = LO + ri % SPAN;
                uint256 open = (ri >> 32) % (UNITS_MAX + 1);
                uint256 q = (ri >> 72) % (Q_MAX + 1);
                word |= (tick | (q << SUB_Q) | (open << SUB_OPEN)) << (BATCH_SUB_BASE + i * SUB_BITS);
                word |= ((ri >> 120) & 1) << (BATCH_SIDES + i); // a live sub-order: a bid or an ask
                ticks[i] = _near(tick, ri >> 100);
            }
            slots[j] = OloSlots.batchSlot(c, maker, j);
            h.setWord(slots[j], word);
            groups = bytes.concat(groups, OloOps.slotGroup(maker, uint16(j), uint8(1 + ((r >> 8) % 15)), ticks));
        }
        list = OloOps.batchList(groups);
    }

    /// What a take leaves: the words it wrote and the taker's two accounts.
    function _after(uint256[] memory slots) internal view returns (uint256[] memory state) {
        state = new uint256[](slots.length + 2);
        for (uint256 i; i < slots.length; ++i) {
            state[i] = h.wordAt(slots[i]);
        }
        state[slots.length] = h.accountOf(1, address(this));
        state[slots.length + 1] = h.accountOf(2, address(this));
    }

    /// One take, kept from reverting the test: a refusal comes back as `ok` false with its revert data.
    function _tryTake(bool brutal, uint256 seed, uint256 params, bytes memory list)
        internal
        returns (bool ok, OloBookTakes.Walk memory w, uint256 baseAmount, uint256 quoteAmount, bytes memory err)
    {
        try h.h_take(brutal, seed, c, params, list) returns (
            OloBookTakes.Walk memory w_, uint256 base_, uint256 quote_
        ) {
            (ok, w, baseAmount, quoteAmount) = (true, w_, base_, quote_);
        } catch (bytes memory e) {
            err = e;
        }
    }

    /// A take twice over `list`, clean and armed: the walk, the fills, the amounts, the words written, the accounts
    /// and the Take event, data and topics byte for byte, agree; the event decodes to the walk's fills. A take the
    /// clean run refuses, the armed run refuses alike, with the same revert data (a revert writes nothing). The one
    /// refusal these lists can meet is SellBelowFee, a sell whose quote does not pass its fee
    /// (`test_take_a_sell_below_its_fee_refused_alike_under_junk`); any other fails the test.
    function _takeTwice(bytes memory list, uint256[] memory slots, bool buyBase, uint256 amount, uint256 seed)
        internal
    {
        uint256 params = OloOps.takeW(buyBase, amount, 0);
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        (bool ok1, OloBookTakes.Walk memory w1, uint256 base1, uint256 quote1, bytes memory e1) =
            _tryTake(false, 0, params, list);
        Vm.Log[] memory l1 = vm.getRecordedLogs();
        uint256[] memory s1 = _after(slots);
        vm.revertToState(snap);
        vm.recordLogs();
        (bool ok2, OloBookTakes.Walk memory w2, uint256 base2, uint256 quote2, bytes memory e2) =
            _tryTake(true, seed, params, list);
        Vm.Log[] memory l2 = vm.getRecordedLogs();
        uint256[] memory s2 = _after(slots);
        assertEq(ok2, ok1, "taken or refused alike");
        if (!ok1) {
            assertEq(e2, e1, "the same refusal");
            assertEq(e1, abi.encodeWithSelector(IOloBookBase.SellBelowFee.selector), "a sell below its fee");
            return;
        }
        assertEq(w2.remaining, w1.remaining, "remaining");
        assertEq(w2.sum, w1.sum, "sum");
        assertEq(w2.low, w1.low, "low");
        assertEq(w2.cap, w1.cap, "cap");
        assertEq(w2.count, w1.count, "count");
        assertEq(w2.out, w1.out, "out");
        assertEq(w2.seg, w1.seg, "seg");
        assertEq(w2.fills, w1.fills, "the fills");
        assertEq(quote2, quote1, "quote");
        assertEq(base2, base1, "base");
        for (uint256 i; i < s1.length; ++i) {
            assertEq(s2[i], s1[i], "a word or an account after");
        }
        assertEq(l2.length, l1.length, "the events");
        if (l1.length == 0) {
            assertEq(w1.count, 0, "no event only when nothing filled");
            return;
        }
        assertEq(l1.length, 1, "one event");
        assertEq(l2[0].data, l1[0].data, "the event's data, padding included");
        assertEq(l2[0].topics.length, l1[0].topics.length, "the topics");
        for (uint256 i; i < l1[0].topics.length; ++i) {
            assertEq(l2[0].topics[i], l1[0].topics[i], "a topic");
        }
        (uint256 packed, uint256 baseAmount, uint256 quoteAmount, uint256 fee, bytes memory fills) =
            abi.decode(l1[0].data, (uint256, uint256, uint256, uint256, bytes));
        assertEq(packed, (buyBase ? 1 : 0) | (w1.count << 8), "packed");
        assertEq(baseAmount, base1, "baseAmount");
        assertLe(fee, quoteAmount, "the fee within the quote");
        assertEq(fills, w1.fills, "the event's fills are the walk's");
        assertEq(l1[0].topics[0], IOloBookBase.Take.selector, "the topic");
        assertEq(l1[0].topics[1], bytes32((uint256(1) << 16) | 1), "the market key: id 1, version 1");
        assertEq(l1[0].topics[2], bytes32(uint256(uint160(address(this)))), "the taker");
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_take_pool_under_junk(uint8 n, uint256 rnd, bool buyBase, uint256 amount, uint256 seed) public {
        n = uint8(bound(n, 1, 6));
        amount = bound(amount, 1, type(uint64).max);
        (bytes memory list, uint256[] memory slots) = _poolList(n, rnd);
        _takeTwice(list, slots, buyBase, amount, seed);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_take_batches_under_junk(uint8 k, uint256 rnd, bool buyBase, uint256 amount, uint256 seed) public {
        k = uint8(bound(k, 1, 3));
        amount = bound(amount, 1, type(uint64).max);
        (bytes memory list, uint256[] memory slots) = _batchList(k, rnd);
        _takeTwice(list, slots, buyBase, amount, seed);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_take_mixed_under_junk(uint8 n, uint8 k, uint256 rnd, bool buyBase, uint256 amount, uint256 seed)
        public
    {
        n = uint8(bound(n, 1, 4));
        k = uint8(bound(k, 1, 2));
        amount = bound(amount, 1, type(uint64).max);
        (bytes memory pool, uint256[] memory ps) = _poolList(n, rnd);
        (bytes memory batches, uint256[] memory bs) = _batchList(k, _rnd(rnd, 7));
        uint256[] memory slots = new uint256[](n + k);
        for (uint256 i; i < n; ++i) {
            slots[i] = ps[i];
        }
        for (uint256 j; j < k; ++j) {
            slots[n + j] = bs[j];
        }
        _takeTwice(bytes.concat(pool, batches), slots, buyBase, amount, seed);
    }

    /// A take the contract refuses is refused alike, clean and armed. A sell of 1 base wei into a batch bid at P = 1
    /// (LO, q 0, 5 base wei open): the quote floor(1) = 1 does not pass its fee ceil(1 x 50 / 1e6) = 1, so both runs
    /// revert SellBelowFee with the same data and write nothing. The fuzzes above can draw such a take: a sell that
    /// fills 1 base wei at P below 2.
    function test_take_a_sell_below_its_fee_refused_alike_under_junk() public {
        address maker = address(uint160(0x2000));
        uint256 slot = OloSlots.batchSlot(c, maker, 0);
        h.setWord(slot, BATCH_USED | ((LO | (uint256(5) << SUB_OPEN)) << BATCH_SUB_BASE) | (uint256(1) << BATCH_SIDES));
        uint256[4] memory ticks;
        ticks[0] = LO;
        uint256[] memory slots = new uint256[](1);
        slots[0] = slot;
        _takeTwice(OloOps.batchList(OloOps.slotGroup(maker, 0, 0x1, ticks)), slots, false, 1, 7);
    }

    /// The take's BadTakeList under junk: a position segment of partial entries, a group naming no sub-order.
    function test_take_bad_list_refused_under_junk() public {
        uint256 params = OloOps.takeW(true, 5e6, 0);
        bytes memory halfEntries = OloOps.poolList(new bytes(9));
        vm.expectRevert(IOloBookBase.BadTakeList.selector);
        h.h_take(true, 5, c, params, halfEntries);
        bytes memory noSub = OloOps.batchList(abi.encodePacked(address(0x2000), uint16(0), uint8(0)));
        vm.expectRevert(IOloBookBase.BadTakeList.selector);
        h.h_take(true, 6, c, params, noSub);
    }

    /// The Take event's ABI padding is zero whatever memory held past the free memory pointer before the take, and
    /// the data is the clean run's byte for byte. Regression: the fills were once built in assembly at the free
    /// memory pointer with nothing zeroed up front, and `_fillList` zeroed nothing after its last record, so the
    /// padding read whatever memory held (zero on chain only because nothing wrote there before the buffer was
    /// opened). Now `new bytes` zeroes the buffer and `emit` pads. Four fills of 9 bytes after a 4-byte header: 40
    /// bytes, padded to 64.
    function test_take_event_padding_under_junk() public {
        bytes memory entries;
        for (uint32 i; i < 4; ++i) {
            uint256 tick = 38_700_001 + i;
            h.setWord(OloSlots.orderSlot(c, 1000 + i), PoolLib.fresh(tick, 0, 5, false, address(uint160(0x1000 + i))));
            entries = bytes.concat(entries, OloOps.poolEntry(1000 + i, tick));
        }
        bytes memory list = OloOps.poolList(entries);
        uint256 params = OloOps.takeW(true, 20, 0);
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        h.h_take(false, 0, c, params, list);
        bytes memory clean = vm.getRecordedLogs()[0].data;
        vm.revertToState(snap);
        vm.recordLogs();
        h.h_take(true, 0x1234, c, params, list);
        bytes memory data = vm.getRecordedLogs()[0].data;
        (,,,, bytes memory fills) = abi.decode(data, (uint256, uint256, uint256, uint256, bytes));
        assertEq(fills.length, 40, "four records after the segment header");
        assertEq(data.length, 0xc0 + 64, "the fills padded to two words");
        for (uint256 i = 0xc0 + fills.length; i < data.length; ++i) {
            assertEq(uint8(data[i]), 0, "the event's ABI padding under junk past the free memory pointer");
        }
        assertEq(data, clean, "the data as from a clean frame");
    }
}
