// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {RolePolicy} from "./OloProprietary.t.sol";
import {OloBook} from "../src/OloBook.sol";
import {C_TAG_FIELD, MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {BatchLib} from "../src/OloTypes.sol";

using MarketLib for MarketWord;

/// Every change to the OLO EVM contract must be in a log that can be applied without simulating the contract. This test
/// is the replay: from the logs alone it rebuilds every pool position's word (tick, q, open and filled units, side,
/// USED, owner) and every batch slot's two words (the main word: side, USED, each sub-order's tick, q and open units;
/// the settlement word: each sub-order's base), then compares them with the chain (`orderWord`, `batchOf`), positions
/// and slots the logs never named included. An order's q comes from the logs too: the maker events carry it (bits
/// 27-31), a multicall's PLACE and MODIFY carry the amount as given, which the replay stores as the contract does (the
/// smallest q with fewer than 2^30 units), and a take's records carry the q of the order they filled. On the way it
/// checks that the logs agree with what it holds: a Claimed amount is the order's fills, a Cancelled amount its open
/// units, a record's q its order's, and a Take's records count its fills and add up to its base amount. Every event
/// names the market and the version it acted in, the market key (id << 16 | version: C's top 48 bits), and the replay
/// keys positions and slots by it; a version's C (its fee and share) is the MarketListed's or MarketConfigSet's, and a
/// multicall header that is a market's key K names the version current then. Balances, the fee pots included, are not
/// rebuilt: they are read from the chain (`balanceOf(id, owner)`).
contract OloReplayTest is OloBase {
    /// The market's significant figures; the subclasses below run the same tests at 5, 4 and 3.
    function _sigFigs() internal pure virtual returns (uint8) {
        return PriceGrid.MAX_SIG_FIGS;
    }

    uint256 S; // the maker tick spacing: every maker tick below is T +- k x S, asks and bids on both sides of T

    // A pool word: tick 0-25 | q 26-32 | open 33-62 | filled 63-92 | isBid 93 | USED 94 | owner 96-255.
    uint256 internal constant USED = 1 << 94;
    uint256 internal constant ORDER = (1 << 93) - 1; // tick, q, open, filled: what a dead word clears
    uint256 internal constant UNITS = (1 << 30) - 1; // open, filled, a sub-order's open units and base
    uint256 internal constant TICK = (1 << 26) - 1;
    uint256 internal constant AMOUNT = (1 << 112) - 1; // the maker events' amount, a multicall op's

    // ----------------------------------------------------------------- the replay's state
    mapping(uint256 marketKey => MarketWord) cOf; // each version's C, by its market key (id << 16 | version)
    uint256[] markets; // market keys, as listed or made
    mapping(uint256 marketId => uint256) currentKey; // each market's current version, as the logs have it
    // coverage, the replay's: events in an older version than its market's current one (a take's fills, a claim, a
    // cancel, a batch operation, a multicall op under a header C), and multicall header entries that are a key K
    uint256 oldEvents;
    uint256 keyHeaders;
    uint256 feeVersions; // MarketConfigSet events whose version moved the fee (the others moved the share)

    mapping(bytes32 => uint256) word; // keccak(marketId, pos)
    bytes32[] touched;
    mapping(bytes32 => bool) seen;
    mapping(bytes32 => uint256) posOfKey;
    mapping(bytes32 => uint256) marketOfKey;

    mapping(bytes32 => uint256) slotWord; // the main word, keccak(marketId, maker, slot, "slot")
    mapping(bytes32 => uint256) slotSet; // the settlement word
    bytes32[] touchedSlots;
    mapping(bytes32 => bool) seenSlot;
    mapping(bytes32 => uint256) slotOfKey;
    mapping(bytes32 => address) makerOfKey;

    // ---------------------------------------------------------------- reading packed bytes
    /// The `bits`-bit big-endian field of `b` from byte `offset`.
    function _rd(bytes memory b, uint256 offset, uint256 bits) internal pure returns (uint256 v) {
        assembly ("memory-safe") {
            v := shr(sub(256, bits), mload(add(add(b, 0x20), offset)))
        }
    }

    /// An amount as an order stores it, worked out from the docs rather than with the contract's OloMath: the smallest
    /// q with floor(amount / 10^q) below 2^30, and those units.
    function _toUnits(uint256 amount) internal pure returns (uint256 q, uint256 units) {
        units = amount;
        while (units >= 1 << 30) {
            units /= 10;
            ++q;
        }
    }

    function _key(uint256 market, uint256 pos) internal returns (bytes32 k) {
        k = keccak256(abi.encode(market, pos));
        if (!seen[k]) {
            seen[k] = true;
            touched.push(k);
            posOfKey[k] = pos;
            marketOfKey[k] = market;
        }
    }

    /// A batch slot: the maker's own, keyed by (marketId, maker, slot).
    function _skey(uint256 market, address maker, uint256 slot) internal returns (bytes32 k) {
        k = keccak256(abi.encode(market, maker, slot, "slot"));
        if (!seenSlot[k]) {
            seenSlot[k] = true;
            touchedSlots.push(k);
            slotOfKey[k] = slot;
            makerOfKey[k] = maker;
            marketOfKey[k] = market;
        }
    }

    // ---------------------------------------------------------------- applying the logs
    function _place(uint256 market, address maker, uint256 tick, bool isBid, uint256 q, uint256 units, uint256 pos)
        internal
    {
        word[_key(market, pos)] =
            tick | (q << 26) | (units << 33) | (isBid ? 1 << 93 : 0) | USED | (uint256(uint160(maker)) << 96);
    }

    /// A claim: filled cleared; nothing open left, the word dead.
    function _claimed(uint256 market, uint256 pos) internal {
        bytes32 k = _key(market, pos);
        uint256 w = word[k] & ~(UNITS << 63);
        if ((w >> 33) & UNITS == 0) w &= ~ORDER;
        word[k] = w;
    }

    /// A cancel: the word dead, its side, USED and owner kept.
    function _cancelled(uint256 market, uint256 pos) internal {
        bytes32 k = _key(market, pos);
        word[k] &= ~ORDER;
    }

    /// A modify: the new tick, q and units, nothing filled (its fills were claimed), the side and owner kept.
    function _modified(uint256 market, uint256 pos, uint256 tick, uint256 q, uint256 units) internal {
        bytes32 k = _key(market, pos);
        word[k] = (word[k] & ~ORDER) | tick | (q << 26) | (units << 33);
    }

    /// A take's fill of the order in `pos`: `units` move from open to filled. The record's q is the order's.
    function _poolFill(uint256 market, uint256 pos, uint256 q, uint256 units) internal {
        bytes32 k = _key(market, pos);
        assertEq((word[k] >> 26) & 0x7f, q, "a pool fill's q is its order's");
        word[k] = word[k] - (units << 33) + (units << 63);
    }

    function _warmPool(uint256 market, uint256 from, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            bytes32 k = _key(market, (from + i) & 0xffffffff);
            if (word[k] == 0) word[k] = USED;
        }
    }

    /// A batch operation: its event carries the slot's two words after it.
    function _batchUpdated(uint256 market, address maker, uint256 slot, uint256 w, uint256 set) internal {
        bytes32 k = _skey(market, maker, slot);
        slotWord[k] = w;
        slotSet[k] = set;
    }

    /// A take's fill of sub-order `i`: `units` come off its open units (bits 31-60 of its 61, from 2 + 61 i); the
    /// settlement word keeps its base, so its fills are base - open. The record's q is the sub-order's.
    function _batchFill(uint256 market, address maker, uint256 slot, uint256 i, uint256 q, uint256 units) internal {
        bytes32 k = _skey(market, maker, slot);
        uint256 lowBit = 2 + 61 * i;
        assertEq((slotWord[k] >> (lowBit + 26)) & 0x1f, q, "a batch fill's q is its sub-order's");
        slotWord[k] -= units << (lowBit + 31);
    }

    /// The Ops event's stream: the header's markets, then each op as it ran. A PLACE's and a MODIFY's amount is the
    /// amount as given, which the replay stores as the contract does; a PLACE's pos is where it landed.
    function _ops(address maker, bytes memory d) internal {
        uint256 nM = uint8(d[0]);
        uint256[] memory ms = new uint256[](nM);
        uint256 p = 1;
        for (uint256 i; i < nM; ++i) {
            // a C names its version (its top 48 bits); a market's key K, no tag, the version current then
            uint256 hw = _rd(d, p, 256);
            ms[i] = hw & C_TAG_FIELD == 0 ? currentKey[hw >> 224] : hw >> 208;
            if (hw & C_TAG_FIELD == 0) ++keyHeaders;
            p += 32;
        }
        while (p < d.length) {
            uint256 op = uint8(d[p]);
            if (op <= 4) _noteOld(ms[uint8(d[p + 1])]);
            if (op == 1) {
                // PLACE: op 1 | c 1 | tick 4 | side 1 | amount 14 | pos 4
                (uint256 q, uint256 units) = _toUnits(_rd(d, p + 7, 112));
                _place(
                    ms[uint8(d[p + 1])],
                    maker,
                    _rd(d, p + 2, 32),
                    uint8(d[p + 6]) & 1 == 1,
                    q,
                    units,
                    _rd(d, p + 21, 32)
                );
                p += 25;
            } else if (op == 2) {
                _cancelled(ms[uint8(d[p + 1])], _rd(d, p + 2, 32));
                p += 6;
            } else if (op == 3) {
                _claimed(ms[uint8(d[p + 1])], _rd(d, p + 2, 32));
                p += 6;
            } else if (op == 4) {
                // MODIFY: op 1 | c 1 | pos 4 | newTick 4 | newAmount 14
                (uint256 q, uint256 units) = _toUnits(_rd(d, p + 10, 112));
                _modified(ms[uint8(d[p + 1])], _rd(d, p + 2, 32), _rd(d, p + 6, 32), q, units);
                p += 24;
            } else {
                p += 21; // DEPOSIT, WITHDRAW: balances, read from the chain
            }
        }
    }

    /// The Take event's fills: segments of kind 1 | length 3 | records. A pool record is pos 4 | q 1 | units 4; a batch
    /// segment holds per slot maker 20 | slot 2 | n 1, then n records of index 1 | q 1 | units 4. The records count the
    /// fills and add up to the base filled.
    function _take(uint256 market, uint256 packed, uint256 baseAmount, bytes memory f) internal {
        uint256 p;
        uint256 n;
        uint256 sum;
        while (p < f.length) {
            uint256 kind = uint8(f[p]);
            uint256 end = p + 4 + _rd(f, p + 1, 24);
            p += 4;
            while (p < end) {
                if (kind == 0) {
                    uint256 q = uint8(f[p + 4]);
                    uint256 units = _rd(f, p + 5, 32);
                    _poolFill(market, _rd(f, p, 32), q, units);
                    sum += units * 10 ** q;
                    ++n;
                    p += 9;
                } else {
                    address maker = address(uint160(_rd(f, p, 160)));
                    uint256 slot = _rd(f, p + 20, 16);
                    uint256 records = uint8(f[p + 22]);
                    p += 23;
                    for (uint256 j; j < records; ++j) {
                        uint256 q = uint8(f[p + 1]);
                        uint256 units = _rd(f, p + 2, 32);
                        _batchFill(market, maker, slot, uint8(f[p]), q, units);
                        sum += units * 10 ** q;
                        ++n;
                        p += 6;
                    }
                }
            }
        }
        assertEq(n, packed >> 8, "a record per fill");
        assertEq(sum, baseAmount, "the records add up to the base filled");
    }

    /// The maker events' packed word: tick 0-25 | isBid 26 | q 27-31 | amount 32-143 | pos 144-175 | market key
    /// 176-223.
    function _fields(uint256 pk)
        internal
        pure
        returns (uint256 market, uint256 pos, uint256 tick, bool isBid, uint256 q, uint256 amount)
    {
        return (
            (pk >> 176) & 0xffffffffffff,
            (pk >> 144) & 0xffffffff,
            pk & TICK,
            (pk >> 26) & 1 == 1,
            (pk >> 27) & 0x1f,
            (pk >> 32) & AMOUNT
        );
    }

    /// Counts an event of `market` (a market key) in an older version than its market's current one.
    function _noteOld(uint256 market) internal {
        if (currentKey[market >> 16] != market) ++oldEvents;
    }

    /// A version's C from its MarketListed or MarketConfigSet: kept under its market key, and its market's current one.
    function _version(uint256 config) internal {
        uint256 key = config >> 208;
        cOf[key] = MarketWord.wrap(config);
        markets.push(key);
        currentKey[config >> 224] = key;
    }

    function _replay(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(book)) continue;
            bytes32 t = l.topics[0];
            address maker = address(uint160(uint256(l.topics.length > 1 ? l.topics[1] : bytes32(0))));
            if (t == keccak256("MarketListed(uint32,address,address,uint256)")) {
                (,, uint256 config) = abi.decode(l.data, (address, address, uint256));
                _version(config);
            } else if (t == keccak256("MarketConfigSet(uint32,uint16,uint256)")) {
                (uint16 version, uint256 config) = abi.decode(l.data, (uint16, uint256));
                assertEq(MarketWord.wrap(config).version(), version, "MarketConfigSet's version is its C's");
                assertEq(config >> 224, uint256(l.topics[1]), "MarketConfigSet's id is its C's");
                if (MarketWord.wrap(config).feePpm() != cOf[currentKey[config >> 224]].feePpm()) ++feeVersions;
                _version(config);
            } else if (t == keccak256("PoolWarmed(uint48,uint32,uint256)")) {
                (uint32 from, uint256 n) = abi.decode(l.data, (uint32, uint256));
                _warmPool(uint256(l.topics[1]), from, n);
            } else if (t == keccak256("Placed(address,uint256)")) {
                (uint256 market, uint256 pos, uint256 tick, bool isBid, uint256 q, uint256 amount) =
                    _fields(abi.decode(l.data, (uint256)));
                assertEq(amount % 10 ** q, 0, "an amount as stored: whole units");
                _place(market, maker, tick, isBid, q, amount / 10 ** q, pos);
            } else if (t == keccak256("Modified(address,uint256)")) {
                uint256 pk = abi.decode(l.data, (uint256));
                (uint256 market, uint256 pos, uint256 tick,, uint256 q, uint256 amount) = _fields(pk);
                // the old tick, unless the order was filled whole: its Claimed came first and left the word dead
                uint256 w = word[_key(market, pos)];
                if (w & ORDER != 0) assertEq(w & TICK, (pk >> 224) & TICK, "Modified's old tick");
                assertEq(amount % 10 ** q, 0, "an amount as stored: whole units");
                _modified(market, pos, tick, q, amount / 10 ** q);
            } else if (t == keccak256("Claimed(address,uint256,uint256)")) {
                (uint256 pk,) = abi.decode(l.data, (uint256, uint256));
                (uint256 market, uint256 pos,,, uint256 q, uint256 amount) = _fields(pk);
                _noteOld(market);
                uint256 w = word[_key(market, pos)];
                assertEq((w >> 26) & 0x7f, q, "Claimed's q");
                assertEq(((w >> 63) & UNITS) * 10 ** q, amount, "Claimed's amount: the fills");
                _claimed(market, pos);
            } else if (t == keccak256("Cancelled(address,uint256)")) {
                (uint256 market, uint256 pos,,,, uint256 amount) = _fields(abi.decode(l.data, (uint256)));
                _noteOld(market);
                uint256 w = word[_key(market, pos)];
                assertEq(((w >> 33) & UNITS) * 10 ** ((w >> 26) & 0x7f), amount, "Cancelled's amount: the open");
                _cancelled(market, pos);
            } else if (t == keccak256("Ops(address,bytes)")) {
                _ops(maker, abi.decode(l.data, (bytes)));
            } else if (t == keccak256("Take(uint48,address,uint256,uint256,uint256,uint256,bytes)")) {
                (uint256 packed, uint256 baseAmount,,, bytes memory fills) =
                    abi.decode(l.data, (uint256, uint256, uint256, uint256, bytes));
                _noteOld(uint256(l.topics[1]));
                _take(uint256(l.topics[1]), packed, baseAmount, fills);
            } else if (t == keccak256("BatchUpdated(address,uint256,uint256,uint256)")) {
                (uint256 pk, uint256 w, uint256 set) = abi.decode(l.data, (uint256, uint256, uint256));
                _noteOld((pk >> 144) & 0xffffffffffff);
                _batchUpdated((pk >> 144) & 0xffffffffffff, maker, (pk >> 128) & 0xffff, w, set);
            }
        }
    }

    // ---------------------------------------------------------------- comparing with the chain
    function _compare() internal view {
        for (uint256 i; i < touched.length; ++i) {
            bytes32 k = touched[i];
            assertEq(book.orderWord(cOf[marketOfKey[k]], uint32(posOfKey[k])), word[k], "a position's word");
        }
        for (uint256 i; i < touchedSlots.length; ++i) {
            bytes32 k = touchedSlots[i];
            (uint256 w, uint256 set) = book.batchOf(cOf[marketOfKey[k]], makerOfKey[k], uint16(slotOfKey[k]));
            assertEq(w, slotWord[k], "a slot's main word");
            assertEq(set, slotSet[k], "a slot's settlement word");
        }
        for (uint256 i; i < markets.length; ++i) {
            MarketWord mc = cOf[markets[i]];
            // the current version reads its share; an older one reads (0, listed, not active)
            (uint16 bps, bool listed, bool active) = book.makerShareOf(mc);
            bool current = currentKey[markets[i] >> 16] == markets[i];
            assertEq(bps, current ? mc.makerBps() : 0, "the version's share, the current one's only");
            assertTrue(listed, "a version's key is listed");
            assertEq(active, current, "only the current version is active");
            // positions 0-15 of every market, named in the logs or not: an order the logs never named shows here
            for (uint256 p; p < 16; ++p) {
                bytes32 k = keccak256(abi.encode(markets[i], p));
                assertEq(book.orderWord(mc, uint32(p)), word[k], "a position the logs never named");
            }
            // and slots 0-3 of every maker
            for (uint256 x; x < makers.length; ++x) {
                for (uint256 s; s < 4; ++s) {
                    bytes32 k = keccak256(abi.encode(markets[i], makers[x], s, "slot"));
                    (uint256 w, uint256 set) = book.batchOf(mc, makers[x], uint16(s));
                    assertEq(w, slotWord[k], "a slot the logs never named: main word");
                    assertEq(set, slotSet[k], "a slot the logs never named: settlement word");
                }
            }
        }
    }

    // ---------------------------------------------------------------- scenarios
    /// A market listed (warming positions 0-7) while the logs record, so the replay sees it from its first event.
    function _freshMarket() internal {
        vm.recordLogs();
        m = book.listMarketQuote(address(base), address(quote), 60, _sigFigs(), 1, 8);
        c = book.configOf(m);
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    /// A second market on the same pair (another fee, so another market id), listed while the logs record.
    function _secondMarket() internal returns (MarketWord) {
        return book.configOf(book.listMarketQuote(address(base), address(quote), 70, _sigFigs(), 1, 0));
    }

    /// A multicall header with both markets (index 0: `c`, 1: `c2`).
    function _hdr2(MarketWord c2) internal view returns (bytes memory) {
        return abi.encodePacked(uint8(2), c, c2);
    }

    /// The maker tick T + (k - 4) S for k = r % 9: T - 4S .. T + 4S, decade 37 below T and decade 38 from it.
    function _tickAt(uint256 r) internal view returns (uint256) {
        return T - 4 * S + (r % 9) * S;
    }

    /// An order's or a take's amount: a few LOTs, give or take a few wei (q 0), or one of the larger amounts: 1e10
    /// (1e9 units of 10), 1,234,567,891 (q 1, stores ...890), 1,073,741,829 (q 1, stores 1,073,741,820, which alone
    /// reads as q 0) or 12,345,678,901 (q 2, stores ...900).
    function _amount(uint256 r) internal pure returns (uint256) {
        uint256 k = r % 10;
        if (k == 6) return 1e10;
        if (k == 7) return 1_234_567_891;
        if (k == 8) return 1_073_741_829;
        if (k == 9) return 12_345_678_901;
        return (1 + k) * LOT + (r >> 8) % 7;
    }

    /// What the fuzz knows of one maker's pool orders, read from the chain before a step: positions 0-11 of the two
    /// versions the step's header names (`_mine`'s m0 and m1) as bit 16 ci + p (ci 0 the first market, 1 the second). A stream keeps it up to date as it adds ops,
    /// so its CANCELs, CLAIMs and MODIFYs name the maker's own orders and most streams run. The driver's, not the
    /// replay's: the replay reads nothing from the chain.
    struct Mine {
        uint256 busy; // anyone's live order
        uint256 live; // the maker's live orders
        uint256 open; // those with open units
        uint256 filled; // those with fills to claim
    }

    uint256 internal constant NONE = type(uint256).max;

    function _mine(MarketWord m0, MarketWord m1, address who) internal view returns (Mine memory s) {
        for (uint256 ci; ci < 2; ++ci) {
            for (uint32 p; p < 12; ++p) {
                (uint256 t, uint256 open, uint256 filled,, address owner) = book.orderOf(ci == 0 ? m0 : m1, p);
                if (t == 0) continue; // no live order
                uint256 bit = 1 << (16 * ci + p);
                s.busy |= bit;
                if (owner != who) continue;
                s.live |= bit;
                if (open != 0) s.open |= bit;
                if (filled != 0) s.filled |= bit;
            }
        }
    }

    /// The `r`-th (mod their count) of the bits set in `mask`, NONE when none is.
    function _pick(uint256 mask, uint256 r) internal pure returns (uint256 b) {
        uint256 n;
        for (b = 0; b < 32; ++b) {
            n += (mask >> b) & 1;
        }
        if (n == 0) return NONE;
        r %= n;
        for (b = 0;; ++b) {
            if ((mask >> b) & 1 == 0) continue;
            if (r == 0) return b;
            --r;
        }
    }

    /// Where a place asking for bit `first` with `probes` probes lands: the first of first .. first + probes not
    /// busy, NONE when all are.
    function _land(uint256 busy, uint256 first, uint256 probes) internal pure returns (uint256) {
        for (uint256 k; k <= probes; ++k) {
            if ((busy >> (first + k)) & 1 == 0) return first + k;
        }
        return NONE;
    }

    /// A random stream over both markets: places with or without probes on positions 0-7, so they run into each other
    /// (often the stream's previous place again, alike in market, position, tick, amount and side, which lands past
    /// it), cancels, claims and modifies of the maker's own orders, and deposits. An op `s` says would fail (a place
    /// with every probe busy, a cancel with no order to name) is left out, and so are the places and modifies on a
    /// header entry `frozen` names (bit ci: an older version's C, where they are MarketFrozen).
    function _randomOps(uint256 seed, Mine memory s, uint256 frozen) internal view returns (bytes memory ops) {
        uint256 n = 2 + seed % 5;
        bytes memory last;
        uint256 lastAt; // the last place's bit and probes
        uint256 lastProbes;
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 tick = _tickAt(seed >> 16);
            uint256 amount = _amount(seed >> 88);
            uint256 kind = (seed >> 40) % 8;
            bytes memory op;
            uint256 b;
            if (kind <= 2) {
                if (kind != 2 || last.length == 0) {
                    lastAt = (seed % 2) * 16 + (seed >> 8) % 8;
                    lastProbes = (seed >> 32) % 4;
                    last = OloOps.placeProbe(
                        uint8(lastAt / 16), tick, (seed >> 48) & 1 == 1, amount, uint32(lastAt % 16), uint8(lastProbes)
                    );
                }
                op = last;
                if ((frozen >> (lastAt / 16)) & 1 == 1) continue;
                b = _land(s.busy, lastAt, lastProbes);
                if (b == NONE) continue;
                s.busy |= 1 << b;
                s.live |= 1 << b;
                s.open |= 1 << b;
            } else if (kind == 7) {
                op = OloOps.deposit(baseId, 1);
            } else {
                b = _pick(kind == 4 ? s.filled : s.live, seed >> 56);
                if (b == NONE) continue;
                if (kind == 3) {
                    op = OloOps.cancel(uint8(b / 16), uint32(b % 16));
                    s.busy &= ~(1 << b);
                    s.live &= ~(1 << b);
                    s.open &= ~(1 << b);
                } else if (kind == 4) {
                    op = OloOps.claim(uint8(b / 16), uint32(b % 16));
                    if (s.open & (1 << b) == 0) {
                        s.busy &= ~(1 << b); // nothing open: the claim leaves it dead
                        s.live &= ~(1 << b);
                    }
                } else {
                    if ((frozen >> (b / 16)) & 1 == 1) continue;
                    op = OloOps.modify(uint8(b / 16), uint32(b % 16), tick, amount);
                    s.open |= 1 << b;
                }
                s.filled &= ~(1 << b);
            }
            ops = bytes.concat(ops, op);
        }
    }

    /// A post or a replace of `n` orders into slot `s`, from tick `from` a spacing apart (asks up, bids down), each of
    /// its own amount.
    function _ladder(uint8 kind, bool bid, uint16 s, uint256 from, uint256 n, uint256 r)
        internal
        view
        returns (uint256[3] memory)
    {
        uint256[4] memory o;
        for (uint256 i; i < n; ++i) {
            o[i] = OloOps.sub(bid ? from - i * S : from + i * S, _amount(r >> (8 * i)));
        }
        return OloOps.batchW(kind, bid, s, 0, 0, o);
    }

    /// A modify, a cancel or a claim by mask in one of the maker's slots 0-2 of `mc`: one with a live sub-order (a
    /// claim: one with fills to pay) when the maker has one, a cancel's mask cut to the live sub-orders.
    function _batchStep(MarketWord mc, address who, uint256 seed) internal {
        uint256 k = (seed >> 56) % 3;
        uint256 slots;
        for (uint16 i; i < 3; ++i) {
            (uint256 w, uint256 set) = book.batchOf(mc, who, i);
            if ((k == 1 ? BatchLib.filledMask(w, set) : BatchLib.liveMask(w)) != 0) slots |= 1 << i;
        }
        uint256 picked = _pick(slots, seed >> 120);
        uint16 s = picked == NONE ? uint16((seed >> 40) % 3) : uint16(picked);
        (uint256 word_,) = book.batchOf(mc, who, s);
        uint8 mask = uint8(1 + (seed >> 48) % 15);
        if (k == 0 && mask & BatchLib.liveMask(word_) == 0) mask = uint8(BatchLib.liveMask(word_));
        uint256[4] memory o;
        for (uint256 i; i < 4; ++i) {
            o[i] = OloOps.sub(_tickAt(seed >> (96 + 8 * i)), _amount(seed >> (128 + 8 * i)));
        }
        _tryMb(
            mc,
            k == 0
                ? OloOps.maskW(OloOps.CANCEL, s, 0, mask)
                : k == 1 ? OloOps.maskW(OloOps.CLAIM, s, 0, 0) : OloOps.batchW(OloOps.MODIFY, false, s, 0, mask, o)
        );
    }

    /// `manageBatchSubs` as `_mb`, a refusal ignored (it changes nothing and logs nothing).
    function _tryMb(MarketWord mc, uint256[3] memory w) internal returns (bool ok) {
        (ok,) = address(book).call(OloOps.batchCalldata(OloBook.manageBatchSubs.selector, mc, w));
    }

    /// A take list over market `mc`: every position 0-11 holding an order, at its tick, then a segment per maker of its
    /// slots 0-2, every sub-order bounded by a tick every maker tick passes (a buy's T + 8S, a sell's T - 8S).
    function _takeList(MarketWord mc, address[3] memory mk, bool buy) internal view returns (bytes memory list) {
        bytes memory entries;
        for (uint32 p; p < 12; ++p) {
            (uint256 t,,,,) = book.orderOf(mc, p);
            if (t != 0) entries = bytes.concat(entries, OloOps.poolEntry(p, t));
        }
        if (entries.length != 0) list = OloOps.poolList(entries);
        uint256 bound = buy ? T + 8 * S : T - 8 * S;
        for (uint256 x; x < 3; ++x) {
            list = bytes.concat(
                list,
                OloOps.batchList(
                    bytes.concat(
                        OloOps.slotGroupAt(mk[x], 0, 0xf, bound),
                        OloOps.slotGroupAt(mk[x], 1, 0xf, bound),
                        OloOps.slotGroupAt(mk[x], 2, 0xf, bound)
                    )
                )
            );
        }
    }

    function setUp() public {
        _deployWith(_sigFigs());
        S = _spacing();
    }

    /// Every operation that changes the contract, with amounts of q 0, 1 and 2 and ticks on both sides of the decade
    /// boundary at T, then the logs replayed.
    function test_replay_scenario() public {
        _freshMarket();
        address a = _maker();
        address b = _maker();
        address z = _maker();
        // a share change first: the market's second version, where every order below rests (version 1 keeps only
        // the listing's warmed positions)
        book.setMarketMakerShare(m, 8_000);
        c = book.configOf(m);
        // places: a position, probing past a busy one, a fresh one; the q ambiguity; warming
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1 * S, 5 * LOT, 2, 0));
        vm.prank(b);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 2 * S, 1e10, 2, 0x20)); // 2 busy: lands on 3, 1e9 units of 10
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(true, T - 1 * S, 1_234_567_891, 500, 0)); // never written; stores ...890 at q 1
        vm.prank(b);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 3 * S, 1_073_741_829, 4, 0)); // stores 1,073,741,820 at q 1
        book.warmPool(m, 8, 8);
        // the q ambiguity again, in a warmed position, resting to the end: 107,374,182 units of 10, two of them filled
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(true, T - 2 * S, 1_073_741_829, 9, 0));
        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(9, T - 2 * S)), OloOps.tagW(c, OloOps.takeW(false, 25, 0))
        );
        // takes over positions, part fills in whole units, a claim, a modify, a cancel, a quote-mode take; first 2
        // whole, then 200,000 units of 10 of 3, 5 wei left
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(bytes.concat(OloOps.poolEntry(2, T + 1 * S), OloOps.poolEntry(3, T + 2 * S))),
            OloOps.tagW(c, OloOps.takeW(true, 7 * LOT + 5, 0))
        );
        vm.prank(a);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(2, 0))); // filled whole: dead
        vm.prank(b);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(3, T + 5 * S, 1e10 + 7, 0))); // its fills claimed, 1e9 units of 10 again
        vm.prank(b);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(4, 0))); // 4 dead, b's
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 6 * S, 2 * LOT, 4, 0)); // a's now
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntry(500, T - 1 * S)),
            OloOps.tagW(c, OloOps.takeW(false, 2 * LOT + 9, 0))
        );
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntry(4, T + 6 * S)),
            OloOps.tagW(c, OloOps.quoteW(true, 1_500_000, 0))
        );
        vm.prank(a);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(500, 0))); // Claimed, then Cancelled
        // a multicall: a probing PLACE, a PLACE at q 1, a MODIFY to q 2, a CANCEL, a DEPOSIT
        vm.prank(b);
        book.multicall(
            0,
            _mc(
                bytes.concat(
                    OloOps.placeProbe(0, T + 7 * S, false, 3 * LOT, 3, 4), // 3 and 4 busy: lands on 5
                    OloOps.place(0, T + 8 * S, false, 1_073_741_829, 6),
                    OloOps.modify(0, 3, T + 4 * S, 12_345_678_901),
                    OloOps.cancel(0, 6),
                    OloOps.deposit(baseId, 1e6)
                )
            )
        );
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntry(5, T + 7 * S)),
            OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0))
        );
        vm.prank(b);
        book.multicall(0, _mc(OloOps.claim(0, 5)));
        // batches: posts into two of z's slots, part fills, a cancel by mask, a claim, a replace, a modify
        uint256[4] memory o = [
            OloOps.sub(T + 10 * S, 4 * LOT), OloOps.sub(T + 11 * S, 1_073_741_829), OloOps.sub(T + 12 * S, 4 * LOT), 0
        ];
        vm.prank(z);
        _mb(c, OloOps.batchW(OloOps.POST, false, 1, 0, 0, o));
        vm.prank(z);
        _mb(c, OloOps.ladderW(OloOps.POST, true, 40, 0, T - 10 * S, 1e10, 2, S)); // bids in decade 37, q 1
        // 3 whole (123,456,789 units of 100), sub-order 0 whole, 123 units of 10 of sub-order 1, 4 wei of 2
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            bytes.concat(
                OloOps.poolList(OloOps.poolEntry(3, T + 4 * S)),
                OloOps.batchList(OloOps.slotGroup(z, 1, 0x7, [T + 10 * S, T + 11 * S, T + 12 * S, 0]))
            ),
            OloOps.tagW(c, OloOps.takeW(true, 12_345_678_900 + 4 * LOT + 1_234, 0))
        );
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CANCEL, 1, 0, 0x2));
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CLAIM, 1, 0, 0)); // sub-order 0 filled whole: emptied; 2 rests on
        vm.prank(z);
        _mb(c, OloOps.ladderW(OloOps.REPLACE, false, 1, 0, T + 20 * S, 3 * LOT, 4, S));
        o = [OloOps.sub(T + 22 * S, 1e10), 0, 0, 0];
        vm.prank(z);
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, 1, 0, 0x1, o));
        // sub-order 0 whole (1e9 units of 10), then 1,000,005 of sub-order 1
        bytes memory list = OloOps.batchList(OloOps.slotGroupAt(z, 1, 0xf, T + 23 * S));
        vm.prank(taker);
        book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, 1e10 + LOT + 5, 0)));
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 40, 0x3, T - 11 * S)),
            OloOps.tagW(c, OloOps.quoteW(false, 3 * LOT, 0))
        );
        // a take that rests its remainder: an ask in decade 37, probing past b's order in 5 to 6 (dead)
        vm.prank(taker);
        book.takeThenRest(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 40, 0x3, T - 11 * S)),
            OloOps.tagW(c, OloOps.restW(false, 3e10, T - 12 * S, 0x20, 5))
        );
        // a take across the decade boundary: what is left of a's ask at T + 6S, then the rest at T - 12S
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(bytes.concat(OloOps.poolEntry(4, T + 6 * S), OloOps.poolEntry(6, T - 12 * S))),
            OloOps.tagW(c, OloOps.takeW(true, LOT, 0))
        );
        // a's slot 1 is not z's slot 1: the replay keys a slot by (market, maker, slot)
        vm.prank(a);
        _mb(c, OloOps.ladderW(OloOps.POST, false, 1, 0, T + 15 * S, 2 * LOT, 2, S));
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(a, 1, 0x3, T + 16 * S)),
            OloOps.tagW(c, OloOps.fokW(true, 3 * LOT, 0, 0))
        );
        // orders that rest on in version 2 once version 3 is made: b's ask in 7, z's two bids in slot 2
        vm.prank(b);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 31 * S, 4 * LOT, 7, 0));
        vm.prank(z);
        _mb(c, OloOps.ladderW(OloOps.POST, true, 2, 0, T - 20 * S, 2 * LOT, 2, S));
        // a second share change, the market's third version: an order there, positions warmed there; the orders above
        // rest on in version 2
        book.setMarketMakerShare(m, 6_000);
        MarketWord c3 = book.configOf(m);
        vm.prank(a);
        book.place(OloOps.key(c3), OloOps.placeW(false, T + 30 * S, LOT, 2, 0));
        book.warmPool(m, 0, 4);
        // version 2's orders after version 3: a take fills b's ask there (its Take names version 2), a takeThenRest
        // fills z's bids there and rests the rest in version 3, a multicall under version 2's C claims and cancels
        // b's ask, a batch claim settles z's slot there; then a multicall under the key K, which names version 3,
        // places and cancels there
        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(7, T + 31 * S)), OloOps.tagW(c, OloOps.takeW(true, LOT, 0))
        );
        vm.prank(taker);
        (uint256 sold,, uint256 rested, uint256 restId) = book.takeThenRest(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 2, 0x3, T - 21 * S)),
            OloOps.tagW(c, OloOps.restW(false, 5 * LOT, T + 32 * S, 0, 3))
        );
        assertEq(sold, 4 * LOT, "z's two bids in version 2");
        assertEq(rested, LOT, "the rest, in version 3");
        assertEq(restId, ((MarketWord.unwrap(c3) >> 174) << 206) | 3, "its id: version 3's tag above position 3");
        vm.prank(b);
        book.multicall(0, bytes.concat(OloOps.header(c), OloOps.claim(0, 7), OloOps.cancel(0, 7)));
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CLAIM, 2, 0, 0));
        vm.prank(a);
        book.multicall(
            0,
            bytes.concat(OloOps.header(OloOps.key(c3)), OloOps.place(0, T + 33 * S, false, LOT, 5), OloOps.cancel(0, 2))
        );
        _replay(vm.getRecordedLogs());
        _compare();
        assertGt(touched.length, 16);
        assertEq(touchedSlots.length, 4, "z's slots 1, 2 and 40, a's slot 1");
        // version 2's events after version 3: two Takes, the multicall's CLAIM and CANCEL, the BatchUpdated
        assertEq(oldEvents, 5, "version 2's events after version 3");
        assertEq(keyHeaders, 1, "the multicall under K");
        (, uint256 open5,,, address owner5) = book.orderOf(c3, 5);
        assertEq(owner5, a, "K's PLACE in version 3");
        assertEq(open5, LOT);
        (uint256 tick7,,,,) = book.orderOf(c, 7);
        assertEq(tick7, 0, "b's ask in version 2: claimed and cancelled");
        // the scenario reached the q it means to: 9 at q 1 with 2 units filled, 3 filled whole at q 2 (unclaimed), the
        // rest in 6 at q 1
        assertEq(book.orderWord(c, 9) & ORDER, (T - 2 * S) | (1 << 26) | (107_374_180 << 33) | (2 << 63));
        assertEq((book.orderWord(c, 3) >> 26) & 0x7f, 2);
        assertEq((book.orderWord(c, 6) >> 26) & 0x7f, 1);
        assertEq(book.orderWord(c, 6) & TICK, T - 12 * S);
    }

    /// Random operations by three makers on a few positions and slots of two markets and their versions, then the logs
    /// replayed. A share change or a fee change makes a market's next version; from then on a step acts a third of the
    /// time in one of the market's older versions (a take's or a takeThenRest's fills, a cancel, a claim, a batch
    /// cancel or claim, a multicall's ops under its C: a place, a post and a takeThenRest's rest land in the current
    /// version whichever version the step names, a modify or a replace there is MarketFrozen), and a multicall's header
    /// names a current version by its key K half the time.
    function testFuzz_replay(uint256 seed) public {
        _fuzzRun(seed);
    }

    /// Over eight seeds the fuzz's steps reach events in older versions (fills, settles, batch operations, multicall
    /// ops under a header C), multicall headers that are a key K and fee changes' versions, and the replay follows
    /// them.
    function test_replay_fuzz_reaches_older_versions_and_key_headers() public {
        uint256 old;
        uint256 keys;
        uint256 fees;
        for (uint256 i; i < 8; ++i) {
            uint256 snap = vm.snapshotState();
            _fuzzRun(uint256(keccak256(abi.encode("replay reach", i))));
            old += oldEvents;
            keys += keyHeaders;
            fees += feeVersions;
            vm.revertToState(snap);
        }
        emit log_named_uint("events in older versions", old);
        emit log_named_uint("header entries that are a key", keys);
        emit log_named_uint("fee versions replayed", fees);
        assertGt(old, 0, "events in older versions");
        assertGt(keys, 0, "header keys");
        assertGt(fees, 0, "fee versions");
    }

    MarketWord[] olderC; // the fuzz's older versions, both markets'

    /// One of `mc`'s market's older versions, picked by `r`; `mc` when the market has none.
    function _older(MarketWord mc, uint256 r) internal view returns (MarketWord) {
        uint256 n;
        for (uint256 i; i < olderC.length; ++i) {
            if (olderC[i].marketId() == mc.marketId()) ++n;
        }
        if (n == 0) return mc;
        r %= n;
        for (uint256 i;; ++i) {
            if (olderC[i].marketId() != mc.marketId()) continue;
            if (r == 0) return olderC[i];
            --r;
        }
    }

    /// A multicall header entry for version `x`: its key K when it is its market's current version and `r` is even,
    /// else its C.
    function _hw(MarketWord x, uint256 r) internal view returns (MarketWord) {
        bool current = MarketWord.unwrap(book.configOf(x.marketId())) == MarketWord.unwrap(x);
        return current && r & 1 == 0 ? OloOps.key(x) : x;
    }

    function _fuzzRun(uint256 seed) internal {
        _freshMarket();
        MarketWord c2 = _secondMarket();
        address[3] memory mk = [_maker(), _maker(), _maker()];
        for (uint256 step; step < 40; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 ci = (seed >> 80) & 1;
            MarketWord mc = ci == 0 ? c : c2;
            address who = mk[seed % 3];
            uint32 pos = uint32((seed >> 8) % 12);
            uint256 tick = _tickAt(seed >> 16);
            bool bid = (seed >> 24) & 1 == 1; // either side at either decade: the contract does not keep them apart
            uint256 amount = _amount(seed >> 88);
            uint256 action = (seed >> 32) % 12;
            if ((seed >> 64) % 8 == 0) {
                // a share change: the market's next version, which the steps after act in (the orders before rest on
                // in theirs, and the replay keeps both)
                uint16 bps = uint16((seed >> 72) % 10_001);
                if (bps != book.configOf(mc.marketId()).makerBps()) {
                    olderC.push(mc);
                    book.setMarketMakerShare(mc.marketId(), bps);
                    mc = book.configOf(mc.marketId());
                    if (ci == 0) c = mc;
                    else c2 = mc;
                }
            } else if ((seed >> 64) % 8 == 1) {
                // a fee change, up to 1% either way, with 0 to 3 positions of the new version warmed (PoolWarmed under
                // its key): the market's next version too
                uint256 from = mc.feePpm();
                uint256 step = (seed >> 72) % 10_001;
                uint256 fee = (seed >> 100) & 1 == 0 ? from + step : (step > from ? 0 : from - step);
                if (fee != from && fee <= 1_000_000) {
                    olderC.push(mc);
                    book.setMarketFee(mc.marketId(), uint24(fee), uint64((seed >> 104) % 4));
                    mc = book.configOf(mc.marketId());
                    if (ci == 0) c = mc;
                    else c2 = mc;
                }
            }
            // a third of the time one of the market's older versions, if it has one
            if ((seed >> 160) % 3 == 0) mc = _older(mc, seed >> 168);
            MarketWord m0 = ci == 0 ? mc : c;
            MarketWord m1 = ci == 1 ? mc : c2;
            Mine memory s = _mine(m0, m1, who);
            if (action >= 1 && action <= 3) {
                // a cancel or a modify names one of the maker's orders in the market, a claim one with fills, if any
                uint256 own = _pick(((action == 2 ? s.filled : s.live) >> (16 * ci)) & 0xfff, seed >> 120);
                if (own != NONE) pos = uint32(own);
            }
            vm.startPrank(who);
            if (action == 0) {
                try book.place(OloOps.key(mc), OloOps.placeW(bid, tick, amount, pos, uint8(((seed >> 40) % 4) << 4))) {}
                    catch {}
            } else if (action == 1) {
                try book.cancel(OloOps.key(mc), OloOps.tagW(mc, OloOps.posW(pos, 0))) {} catch {}
            } else if (action == 2) {
                try book.claim(OloOps.key(mc), OloOps.tagW(mc, OloOps.posW(pos, 0))) {} catch {}
            } else if (action == 3) {
                try book.modify(OloOps.key(mc), OloOps.tagW(mc, OloOps.modifyW(pos, tick, amount, 0))) {} catch {}
            } else if (action == 4) {
                // a PLACE or MODIFY under an older version's C would be MarketFrozen: the stream leaves them out there
                uint256 frozen = (MarketWord.unwrap(m0) != MarketWord.unwrap(c) ? 1 : 0)
                    | (MarketWord.unwrap(m1) != MarketWord.unwrap(c2) ? 2 : 0);
                bytes memory hdr = abi.encodePacked(uint8(2), _hw(m0, seed >> 200), _hw(m1, seed >> 201));
                try book.multicall(0, bytes.concat(hdr, _randomOps(seed >> 40, s, frozen))) {} catch {}
            } else if (action == 5) {
                // a post or a replace of 1 to 4 orders into slot 0-2, a ladder from T - 2S .. T + 2S
                uint8 kind = (seed >> 56) & 1 == 1 ? OloOps.REPLACE : OloOps.POST;
                uint256 from = T - 2 * S + ((seed >> 52) % 5) * S;
                _tryMb(mc, _ladder(kind, bid, uint16((seed >> 40) % 3), from, 1 + (seed >> 50) % 4, seed >> 96));
            } else if (action == 6) {
                _batchStep(mc, who, seed);
            } else if (action == 7) {
                // anyone may warm positions
                book.warmPool(mc.marketId(), uint32((seed >> 40) % 16), 1 + (seed >> 48) % 4);
            } else {
                vm.stopPrank();
                vm.startPrank(taker);
                bool buy = (seed >> 40) & 1 == 1;
                bytes memory list = _takeList(mc, mk, buy);
                if (action <= 9) {
                    try book.take(OloOps.key(mc), list, OloOps.tagW(mc, OloOps.takeW(buy, amount, 0))) {} catch {}
                } else if (action == 10) {
                    try book.take(OloOps.key(mc), list, OloOps.tagW(mc, OloOps.quoteW(buy, amount, 0))) {} catch {}
                } else {
                    // the rest at a maker tick, with 0-3 probes, in position 0-11
                    uint8 probes = uint8(((seed >> 44) % 4) << 4);
                    try book.takeThenRest(
                        OloOps.key(mc), list, OloOps.tagW(mc, OloOps.restW(buy, amount, tick, probes, pos))
                    ) {}
                        catch {}
                }
            }
            vm.stopPrank();
        }
        _replay(vm.getRecordedLogs());
        _compare();
        _solvent();
    }

    // ---------------------------------------------------------------- the Ops event's rewritten positions
    // A probing PLACE's note names its own op (by the op's first byte), not the first PLACE alike in requested
    // position, tick, amount and side: these two streams have PLACEs alike, and each replays at its own position.

    /// Two PLACEs alike in market, position, tick, amount and side, the first landing where it asks and the second
    /// probing past it: the Ops event shows the first at 6 and the second at 7 (matched by parameters, the first
    /// would be rewritten and the second left at 6). The amount is the q ambiguity's: each stores 1,073,741,820 at q 1.
    function test_replay_alike_places() public {
        _freshMarket();
        address a = _maker();
        bytes memory ops = bytes.concat(
            OloOps.placeProbe(0, T + 1 * S, false, 1_073_741_829, 6, 4), // lands 6
            OloOps.placeProbe(0, T + 1 * S, false, 1_073_741_829, 6, 4) // 6 busy: lands 7
        );
        vm.prank(a);
        book.multicall(0, _mc(ops));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory logged;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("Ops(address,bytes)")) logged = abi.decode(logs[i].data, (bytes));
        }
        // the header is 1 + 32 = 33 bytes; a PLACE's pos is bytes 21-24 of its 25
        assertEq(_rd(logged, 33 + 21, 32), 6, "the first PLACE as asked");
        assertEq(_rd(logged, 33 + 25 + 21, 32), 7, "the second PLACE where it landed");
        _replay(logs);
        _compare();
        assertEq((book.orderWord(c, 7) >> 26) & 0x7f, 1, "q 1, from the amount as given");
    }

    /// A proprietary market beside the open one of the same parameters: its logs are the same events (its C carries
    /// the bit, which the replay keys positions and slots by, as any C; the listing's ProprietaryMarketListed changes
    /// no order), so a place, a multicall over both markets, a batch post, a take, a claim and a cancel replay as in an
    /// open market.
    function test_replay_a_proprietary_market() public {
        _freshMarket();
        RolePolicy policy = new RolePolicy();
        book.setProprietaryListingAllowed(address(this), true);
        MarketWord pc = book.configOf(
            book.listMarketQuoteProprietary(address(base), address(quote), 60, _sigFigs(), 1, 4, address(policy))
        );
        MarketWord pk = OloOps.key(pc);
        address a = _maker();
        policy.set(a, true, false);
        policy.set(taker, false, true);
        vm.startPrank(a);
        book.place(pk, OloOps.placeW(false, T + 1 * S, 5 * LOT, 1, 0));
        book.multicall(
            0,
            bytes.concat(
                abi.encodePacked(uint8(2), c, pc),
                OloOps.place(0, T + 2 * S, false, LOT, 2),
                OloOps.place(1, T + 2 * S, false, LOT, 2)
            )
        );
        vm.stopPrank();
        vm.prank(a);
        _mb(pc, OloOps.ladderW(OloOps.POST, true, 0, 0, T - 1 * S, LOT, 2, S));
        vm.prank(taker);
        book.take(pk, OloOps.poolList(OloOps.poolEntry(1, T + 1 * S)), OloOps.tagW(pc, OloOps.takeW(true, 2 * LOT, 0)));
        vm.startPrank(a);
        book.claim(pk, OloOps.tagW(pc, OloOps.posW(1, 0)));
        book.cancel(pk, OloOps.tagW(pc, OloOps.posW(2, 0)));
        vm.stopPrank();
        _replay(vm.getRecordedLogs());
        _compare();
    }

    /// The same PLACE in two markets, the second probing past another maker's order: the second market's op is
    /// rewritten, so the other maker's order stays in the replayed OLO Book (matched by parameters, the first market's
    /// op would be rewritten and the second replayed over the other maker's order).
    function test_replay_alike_places_in_two_markets() public {
        _freshMarket();
        MarketWord c2 = _secondMarket();
        address a = _maker();
        address b = _maker();
        vm.prank(b);
        book.place(OloOps.key(c2), OloOps.placeW(false, T + 7 * S, 5 * LOT, 5, 0)); // the second market's position 5 busy
        bytes memory ops = bytes.concat(
            OloOps.place(0, T + 1 * S, false, 1e10, 5), // lands 5
            OloOps.placeProbe(1, T + 1 * S, false, 1e10, 5, 4) // 5 busy: lands 6
        );
        vm.prank(a);
        book.multicall(0, bytes.concat(_hdr2(c2), ops));
        (, uint256 open,,, address owner) = book.orderOf(c2, 5);
        assertEq(owner, b);
        assertEq(open, 5 * LOT);
        _replay(vm.getRecordedLogs());
        _compare();
    }
}

/// The replay on a 5-significant-figure market: every maker tick a multiple of 10.
contract OloReplay5Test is OloReplayTest {
    function _sigFigs() internal pure override returns (uint8) {
        return 5;
    }
}

/// The same at 4 figures (a multiple of 100).
contract OloReplay4Test is OloReplayTest {
    function _sigFigs() internal pure override returns (uint8) {
        return 4;
    }
}

/// The same at 3 figures (a multiple of 1000).
contract OloReplay3Test is OloReplayTest {
    function _sigFigs() internal pure override returns (uint8) {
        return 3;
    }
}
