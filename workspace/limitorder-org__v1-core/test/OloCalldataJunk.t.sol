// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {OloBook} from "../src/OloBook.sol";

/// The take list is read a word at a time: `OloBookTakes._word` reads 32 bytes from a cursor, on past a segment's or
/// the list's end when fewer are left, and each caller uses only the bytes it checked are within its segment. Here
/// every take and takeThenRest runs twice from the same state: once with the list ABI-encoded as usual, once with
/// random junk in the list's padding and after the calldata's end, which a read past the list's end meets. The
/// outcome, the return data, every log and the balances must be the same: nothing the OLO EVM contract does may depend
/// on a byte outside the list. The lists are random: pool and batch segments in random order, random masks, base and
/// quote mode, buys and sells, orders of q 0 and q > 0.
contract OloCalldataJunkTest is OloBase {
    address[3] asks;
    address[3] bids;
    address slotMaker;

    function setUp() public {
        _deploy();
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
        // pool orders of q 0 and q > 0 on both sides, and a maker with an ask slot (0) and a bid slot (1)
        asks[0] = _plain(T + 1, false, 5 * LOT);
        asks[1] = _plain(T + 2, false, 3_000_000_000_007);
        asks[2] = _plain(T + 4, false, 2_147_483_651);
        bids[0] = _plain(T - 1, true, 5 * LOT);
        bids[1] = _plain(T - 2, true, 3_000_000_000_007);
        bids[2] = _plain(T - 4, true, 2_147_483_651);
        slotMaker = _maker();
        uint256[4] memory o;
        o[0] = OloOps.sub(T + 1, 4 * LOT);
        o[1] = OloOps.sub(T + 2, 2_000_000_123);
        o[2] = OloOps.sub(T + 3, 7_000_000_000_000_005);
        o[3] = OloOps.sub(T + 5, LOT);
        vm.prank(slotMaker);
        _mb(c, OloOps.batchW(OloOps.POST, false, 0, 0, 0, o));
        o[0] = OloOps.sub(T - 1, 4 * LOT);
        o[1] = OloOps.sub(T - 2, 2_000_000_123);
        o[2] = OloOps.sub(T - 3, 7_000_000_000_000_005);
        o[3] = OloOps.sub(T - 5, LOT);
        vm.prank(slotMaker);
        _mb(c, OloOps.batchW(OloOps.POST, true, 1, 0, 0, o));
    }

    /// A random list for a buy (asks) or a sell (bids): up to three segments, pool or batch, in random order; a pool
    /// segment names 1 to 3 of the pool orders, a batch segment the maker's slot with a random mask.
    function _list(uint256 seed, bool buy) internal view returns (bytes memory list) {
        uint256 bound = buy ? T + 6 : T - 6;
        uint256 nSeg = 1 + seed % 3;
        seed /= 3;
        for (uint256 s; s < nSeg; ++s) {
            if (seed & 1 == 0) {
                bytes memory entries;
                uint256 n = 1 + (seed >> 1) % 3;
                for (uint256 k; k < n; ++k) {
                    address a = buy ? asks[((seed >> 3) + k) % 3] : bids[((seed >> 3) + k) % 3];
                    entries = bytes.concat(entries, _poolEntry(a));
                }
                list = bytes.concat(list, OloOps.poolList(entries));
            } else {
                uint8 mask = uint8(1 + (seed >> 1) % 15);
                list = bytes.concat(list, OloOps.batchList(OloOps.slotGroupAt(slotMaker, buy ? 0 : 1, mask, bound)));
            }
            seed >>= 8;
        }
    }

    /// The calldata with junk over the list's padding (the ABI pads it with zeros to a whole word) and `tail` after it.
    function _junked(bytes memory data, uint256 listLength, bytes memory junk, bytes memory tail)
        internal
        pure
        returns (bytes memory out)
    {
        // selector 4 | c | params | the list's offset | its length | its bytes, padded: the list starts at 4 + 4 x 32
        uint256 padFrom = 4 + 128 + listLength;
        out = bytes.concat(data, tail);
        for (uint256 i = padFrom; i < data.length; ++i) {
            out[i] = junk.length == 0 ? bytes1(0xff) : junk[i % junk.length];
        }
    }

    struct Run {
        bool ok;
        bytes ret;
        Vm.Log[] logs;
        uint256 takerBase;
        uint256 takerQuote;
        uint256 slotAsk;
        uint256 slotBid;
    }

    function _run(bytes memory data) internal returns (Run memory r) {
        vm.recordLogs();
        vm.prank(taker);
        (r.ok, r.ret) = address(book).call(data);
        r.logs = vm.getRecordedLogs();
        r.takerBase = _bal(taker, base);
        r.takerQuote = _bal(taker, quote);
        (r.slotAsk,) = book.batchOf(c, slotMaker, 0);
        (r.slotBid,) = book.batchOf(c, slotMaker, 1);
    }

    function _same(Run memory a, Run memory b) internal pure {
        assertEq(a.ok, b.ok, "the same outcome");
        assertEq(a.ret, b.ret, "the same return or revert data");
        assertEq(a.logs.length, b.logs.length, "the same number of logs");
        for (uint256 i; i < a.logs.length; ++i) {
            assertEq(a.logs[i].emitter, b.logs[i].emitter, "a log's emitter");
            assertEq(a.logs[i].topics.length, b.logs[i].topics.length, "a log's topics");
            for (uint256 t; t < a.logs[i].topics.length; ++t) {
                assertEq(a.logs[i].topics[t], b.logs[i].topics[t], "a log's topic");
            }
            assertEq(a.logs[i].data, b.logs[i].data, "a log's data");
        }
        assertEq(a.takerBase, b.takerBase, "the taker's base");
        assertEq(a.takerQuote, b.takerQuote, "the taker's quote");
        assertEq(a.slotAsk, b.slotAsk, "the ask slot");
        assertEq(a.slotBid, b.slotBid, "the bid slot");
    }

    /// A random take or takeThenRest, with and without junk outside its list: everything the same.
    function testFuzz_junk_outside_the_list_changes_nothing(uint256 seed, bytes memory junk, bytes memory tail) public {
        vm.assume(tail.length <= 96);
        bool buy = seed & 1 == 0;
        bool quoteMode = (seed >> 1) & 1 == 1;
        bool andRest = (seed >> 2) & 3 == 0;
        bytes memory list = _list(seed >> 8, buy);
        uint256 amount = 1 + (seed >> 128) % (quoteMode ? 2e16 : 1e16);
        bytes memory data;
        if (andRest) {
            uint256 limit = buy ? T + 6 : T - 6;
            data = abi.encodeCall(
                OloBook.takeThenRest, (OloOps.key(c), list, OloOps.tagW(c, OloOps.restW(buy, amount, limit, 0, 777)))
            );
        } else {
            data = abi.encodeCall(
                OloBook.take, (OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(buy, amount, quoteMode ? 0x02 : 0)))
            );
        }
        uint256 snap = vm.snapshotState();
        Run memory clean = _run(data);
        vm.revertToState(snap);
        Run memory dirty = _run(_junked(data, list.length, junk, tail));
        _same(clean, dirty);
    }
}
