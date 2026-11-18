// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {IOloMarketPolicy} from "../src/interfaces/IOloMarketPolicy.sol";
import {IOwned2Step} from "../src/interfaces/IOwned2Step.sol";
import {C_KEY_MASK, C_PROPRIETARY, C_PROPRIETARY_FLAG, MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

using MarketLib for MarketWord;

/// A policy by role: each address may make, take, both or neither. It answers by the OLO EVM contract's question
/// (`isMaker`).
contract RolePolicy is IOloMarketPolicy {
    mapping(address => bool) public maker;
    mapping(address => bool) public taker;

    function set(address who, bool canMake, bool canTake) external {
        maker[who] = canMake;
        taker[who] = canTake;
    }

    function admitted(uint32, address who, bool isMaker) external view returns (bool) {
        return isMaker ? maker[who] : taker[who];
    }
}

/// A policy that answers whatever its mode says, for the OLO EVM contract's handling of every answer: 0 true, 1 a
/// revert, 2 no data, 3 31 bytes, 4 the word 2, 5 true then a second word, 6 true in 64 KiB of data, 7 a loop that
/// burns the gas it gets, 8 a write (which a static call refuses), 9 false, 10 a revert whose data is the word 1.
contract RawPolicy {
    uint256 public mode;
    uint256 internal sink;

    function setMode(uint256 m) external {
        mode = m;
    }

    fallback() external {
        uint256 m = mode;
        if (m == 1) revert("no");
        if (m == 7) {
            while (true) {}
        }
        if (m == 8) sink = 1;
        assembly ("memory-safe") {
            switch m
            case 2 { return(0, 0) }
            case 3 {
                mstore(0, 1)
                return(1, 31)
            }
            case 4 {
                mstore(0, 2)
                return(0, 32)
            }
            case 5 {
                mstore(0, 1)
                mstore(32, 7)
                return(0, 64)
            }
            case 6 {
                mstore(0, 1)
                return(0, 65536)
            }
            case 9 {
                mstore(0, 0)
                return(0, 32)
            }
            case 10 {
                mstore(0, 1)
                revert(0, 32)
            }
            default {
                mstore(0, 1)
                return(0, 32)
            }
        }
    }
}

/// Proprietary markets: listed by a lister the owner allows, with a policy (IOloMarketPolicy) the OLO EVM contract asks
/// before an entry that makes or takes there, never before one that only leaves. The fixture's open market (`m`, `c`)
/// and a proprietary market of the same parameters (`pm`, `pc`, key `pk`) side by side.
contract OloProprietaryTest is OloBase {
    address lister = address(0x1157);
    RolePolicy policy;
    uint32 pm;
    MarketWord pc;
    MarketWord pk;

    function setUp() public {
        _deploy();
        policy = new RolePolicy();
        book.setProprietaryListingAllowed(lister, true);
        vm.prank(lister);
        pm = book.listMarketQuoteProprietary(address(base), address(quote), 50, 6, 1, 0, address(policy));
        pc = book.configOf(pm);
        pk = OloOps.key(pc);
        policy.set(taker, false, true);
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    /// A fresh maker the policy admits as a maker (and not as a taker).
    function _admittedMaker() internal returns (address a) {
        a = _maker();
        policy.set(a, true, false);
    }

    /// `a` places `amount` at `tick` in the proprietary market, in a fresh position, which it returns.
    function _placeP(address a, uint256 tick, bool isBid, uint256 amount) internal returns (uint32 pos) {
        pos = _pos();
        vm.prank(a);
        book.place(pk, OloOps.placeW(isBid, tick, amount, pos, 0));
    }

    function _takeCall(MarketWord k, MarketWord cv, uint32 pos, uint256 tick, bool buyBase, uint256 amount)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            book.take,
            (k, OloOps.poolList(OloOps.poolEntry(pos, tick)), OloOps.tagW(cv, OloOps.takeW(buyBase, amount, 0)))
        );
    }

    /// `who` calls the OLO EVM contract with `data`, expecting it to revert with `selector`.
    function _refused(address who, bytes memory data, bytes4 selector) internal {
        vm.prank(who);
        (bool ok, bytes memory ret) = address(book).call(data);
        assertFalse(ok, "refused");
        assertEq(bytes4(ret), selector, "the error");
    }

    /// `who` calls the OLO EVM contract with `data`, which must succeed.
    function _ok(address who, bytes memory data) internal returns (bytes memory ret) {
        vm.prank(who);
        bool ok;
        (ok, ret) = address(book).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function _admittedCall(address who, bool isMaker) internal view returns (bytes memory) {
        return abi.encodeCall(IOloMarketPolicy.admitted, (pm, who, isMaker));
    }

    // ============================================================== the listing

    /// The listing sets the key bit and the policy for good, logs MarketListed (C with the bit) and then
    /// ProprietaryMarketListed; the open market of the same parameters, listed before, is another market.
    function test_listing_sets_the_bit_and_the_policy() public {
        assertTrue(pc.isProprietary(), "the bit");
        assertTrue(pk.isProprietary(), "a key bit: K carries it");
        assertEq((MarketWord.unwrap(pc) >> C_PROPRIETARY) & 1, 1);
        assertEq(MarketWord.unwrap(pk), MarketWord.unwrap(pc) & C_KEY_MASK);
        assertEq(book.proprietaryMarketPolicy(pm), address(policy));
        assertEq(book.proprietaryMarketPolicy(m), address(0), "an open market has none");
        assertFalse(c.isProprietary());
        // the same tokens, fee, spacing, minQuote, share and version: only the bit and the id differ
        uint256 idBits = uint256(type(uint32).max) << 224;
        assertEq(
            (MarketWord.unwrap(pc) ^ MarketWord.unwrap(c)) & ~idBits,
            C_PROPRIETARY_FLAG,
            "the open twin differs by the bit"
        );
        assertTrue(pm != m);

        // a second one, with its events
        address p2 = address(new RolePolicy());
        vm.recordLogs();
        vm.prank(lister);
        uint32 id2 = book.listMarketQuoteProprietary(address(base), address(quote), 60, 6, 1, 0, p2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[0], IOloBookBase.MarketListed.selector);
        assertEq(uint256(logs[0].topics[1]), id2);
        (,, uint256 config) = abi.decode(logs[0].data, (address, address, uint256));
        assertEq(config, MarketWord.unwrap(book.configOf(id2)));
        assertTrue(MarketWord.wrap(config).isProprietary());
        assertEq(logs[1].topics[0], IOloBookBase.ProprietaryMarketListed.selector);
        assertEq(uint256(logs[1].topics[1]), id2);
        assertEq(address(uint160(uint256(logs[1].topics[2]))), lister);
        assertEq(abi.decode(logs[1].data, (address)), p2);
    }

    /// Only a lister the owner allows lists one; the policy must have code; the same parameters list once; only the
    /// owner allows a lister, and logs it.
    function test_listing_refusals() public {
        address other = address(0xABCD);
        vm.prank(other);
        vm.expectRevert(IOloBookBase.NotProprietaryLister.selector);
        book.listMarketQuoteProprietary(address(base), address(quote), 70, 6, 1, 0, address(policy));

        vm.startPrank(lister);
        vm.expectRevert(IOloBookBase.BadPolicy.selector);
        book.listMarketQuoteProprietary(address(base), address(quote), 70, 6, 1, 0, address(0));
        vm.expectRevert(IOloBookBase.BadPolicy.selector);
        book.listMarketQuoteProprietary(address(base), address(quote), 70, 6, 1, 0, address(0xF00D));
        // the proprietary market's parameters, listed once, by any lister
        vm.expectRevert(IOloBookBase.MarketExists.selector);
        book.listMarketQuoteProprietary(address(base), address(quote), 50, 6, 1, 0, address(policy));
        // the listing's own checks still apply (a fee above 100%)
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.listMarketQuoteProprietary(address(base), address(quote), 1_000_001, 6, 1, 0, address(policy));
        vm.stopPrank();

        vm.prank(other);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setProprietaryListingAllowed(other, true);

        vm.expectEmit(address(book));
        emit IOloBookBase.ProprietaryListerSet(other, true);
        book.setProprietaryListingAllowed(other, true);
        assertTrue(book.canListProprietaryMarkets(other));
        vm.prank(other);
        vm.expectRevert(IOloBookBase.MarketExists.selector);
        book.listMarketQuoteProprietary(address(base), address(quote), 50, 6, 1, 0, address(policy));
        vm.prank(other);
        book.listMarketQuoteProprietary(address(base), address(quote), 70, 6, 1, 0, address(policy));
    }

    /// A lister the owner stops allowing lists no more; its market trades on under its policy.
    function test_a_removed_lister_s_market_trades_on() public {
        vm.expectEmit(address(book));
        emit IOloBookBase.ProprietaryListerSet(lister, false);
        book.setProprietaryListingAllowed(lister, false);
        assertFalse(book.canListProprietaryMarkets(lister));
        vm.prank(lister);
        vm.expectRevert(IOloBookBase.NotProprietaryLister.selector);
        book.listMarketQuoteProprietary(address(base), address(quote), 70, 6, 1, 0, address(policy));

        address a = _admittedMaker();
        uint32 pos = _placeP(a, T, false, 5 * LOT);
        (uint256 got,) = abi.decode(_ok(taker, _takeCall(pk, pc, pos, T, true, 2 * LOT)), (uint256, uint256));
        assertEq(got, 2 * LOT);
    }

    // ============================================================== who is asked

    /// Every entry that rests an order or changes a resting one asks the policy for the caller as a maker: a place, a
    /// modify, a batch post, replace and modify, a multicall's PLACE and MODIFY (a K header and a C header), a
    /// takeThenRest's rest. Refused, NotAdmitted; admitted, it goes on.
    function test_making_needs_the_maker_admitted() public {
        address a = _maker(); // not admitted
        uint32 pos = _pos();
        bytes memory placeCall = abi.encodeCall(book.place, (pk, OloOps.placeW(false, T, LOT, pos, 0)));
        _refused(a, placeCall, IOloBookBase.NotAdmitted.selector);
        // a taker-only role is not a maker
        policy.set(a, false, true);
        _refused(a, placeCall, IOloBookBase.NotAdmitted.selector);
        policy.set(a, true, false);
        _ok(a, placeCall);

        // modify, batch post / replace / modify, multicall PLACE / MODIFY: refused once the maker is revoked
        uint256[3] memory post = OloOps.postW(true, 0, T - 10, LOT, 2);
        vm.prank(a);
        _mb(pc, post);
        policy.set(a, false, false);
        _refused(
            a,
            abi.encodeCall(book.modify, (pk, OloOps.tagW(pc, OloOps.modifyW(pos, T + 1, LOT, 0)))),
            IOloBookBase.NotAdmitted.selector
        );
        _refused(
            a,
            OloOps.batchCalldata(book.manageBatchSubs.selector, pc, OloOps.postW(true, 1, T - 10, LOT, 2)),
            IOloBookBase.NotAdmitted.selector
        );
        _refused(
            a,
            OloOps.batchCalldata(
                book.manageBatchSubs.selector, pc, OloOps.ladderW(OloOps.REPLACE, true, 0, 0, T - 20, LOT, 2, 1)
            ),
            IOloBookBase.NotAdmitted.selector
        );
        _refused(
            a,
            OloOps.batchCalldata(
                book.manageBatchSubs.selector,
                pc,
                OloOps.batchW(OloOps.MODIFY, true, 0, 0, 0x1, [OloOps.sub(T - 30, LOT), uint256(0), 0, 0])
            ),
            IOloBookBase.NotAdmitted.selector
        );
        bytes memory kPlace = bytes.concat(OloOps.header(pk), OloOps.place(0, T + 2, false, LOT, _pos()));
        bytes memory cPlace = bytes.concat(OloOps.header(pc), OloOps.place(0, T + 2, false, LOT, _pos()));
        bytes memory kModify = bytes.concat(OloOps.header(pk), OloOps.modify(0, pos, T + 3, LOT));
        _refused(a, abi.encodeCall(book.multicall, (0, kPlace)), IOloBookBase.NotAdmitted.selector);
        _refused(a, abi.encodeCall(book.multicall, (0, cPlace)), IOloBookBase.NotAdmitted.selector);
        _refused(a, abi.encodeCall(book.multicall, (0, kModify)), IOloBookBase.NotAdmitted.selector);

        // admitted again (as a maker only), each goes through
        policy.set(a, true, false);
        _ok(a, abi.encodeCall(book.modify, (pk, OloOps.tagW(pc, OloOps.modifyW(pos, T + 1, LOT, 0)))));
        _ok(a, OloOps.batchCalldata(book.manageBatchSubs.selector, pc, OloOps.postW(true, 1, T - 10, LOT, 2)));
        _ok(
            a,
            OloOps.batchCalldata(
                book.manageBatchSubs.selector, pc, OloOps.ladderW(OloOps.REPLACE, true, 0, 0, T - 20, LOT, 2, 1)
            )
        );
        _ok(
            a,
            OloOps.batchCalldata(
                book.manageBatchSubs.selector,
                pc,
                OloOps.batchW(OloOps.MODIFY, true, 0, 0, 0x1, [OloOps.sub(T - 30, LOT), uint256(0), 0, 0])
            )
        );
        _ok(a, abi.encodeCall(book.multicall, (0, kPlace)));
        _ok(a, abi.encodeCall(book.multicall, (0, cPlace)));
    }

    /// A take asks the policy once, for the caller as a taker, whatever the list; a maker-only role cannot take. The
    /// makers filled are not asked.
    function test_taking_needs_the_taker_admitted() public {
        address a = _admittedMaker();
        address b = _admittedMaker();
        uint32 pa = _placeP(a, T, false, 3 * LOT);
        uint32 pb = _placeP(b, T + 1, false, 3 * LOT);
        bytes memory list = OloOps.poolList(bytes.concat(OloOps.poolEntry(pa, T), OloOps.poolEntry(pb, T + 1)));
        bytes memory takeCall = abi.encodeCall(book.take, (pk, list, OloOps.tagW(pc, OloOps.takeW(true, 5 * LOT, 0))));

        address c2 = _maker(); // a maker-only role
        policy.set(c2, true, false);
        _refused(c2, takeCall, IOloBookBase.NotAdmitted.selector);
        _refused(address(0x7777), takeCall, IOloBookBase.NotAdmitted.selector);

        vm.expectCall(address(policy), _admittedCall(taker, false), 1);
        vm.expectCall(address(policy), _admittedCall(a, true), 0);
        vm.expectCall(address(policy), _admittedCall(b, true), 0);
        (uint256 got,) = abi.decode(_ok(taker, takeCall), (uint256, uint256));
        assertEq(got, 5 * LOT);
    }

    /// takeThenRest asks for the taker before the fills, and for the maker only when something rests: a take that
    /// fills all of its amount asks once, as a taker.
    function test_take_then_rest_that_rests_nothing_asks_the_taker() public {
        address a = _admittedMaker();
        uint32 pa = _placeP(a, T, false, 2 * LOT);
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pa, T));
        uint256 params = OloOps.tagW(pc, OloOps.restW(true, LOT, T, 0, _pos()));
        vm.expectCall(address(policy), _admittedCall(taker, false), 1);
        vm.expectCall(address(policy), _admittedCall(taker, true), 0);
        bytes memory ret = _ok(taker, abi.encodeCall(book.takeThenRest, (pk, list, params)));
        (uint256 got,, uint256 rested,) = abi.decode(ret, (uint256, uint256, uint256, uint256));
        assertEq(got, LOT);
        assertEq(rested, 0);
    }

    /// A takeThenRest whose remainder would rest needs the caller admitted as a maker too: a taker-only role is
    /// refused, the whole call undone (nothing filled).
    function test_take_then_rest_that_rests_needs_the_maker_admitted() public {
        address a = _admittedMaker();
        uint32 pa = _placeP(a, T, false, LOT);
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pa, T));
        uint256 params = OloOps.tagW(pc, OloOps.restW(true, 3 * LOT, T, 0, _pos()));
        _refused(taker, abi.encodeCall(book.takeThenRest, (pk, list, params)), IOloBookBase.NotAdmitted.selector);
        (, uint256 open,,,) = book.orderOf(pc, pa);
        assertEq(open, LOT, "nothing filled");
    }

    /// Admitted both ways, a takeThenRest fills and rests, asked once as a taker and once as a maker.
    function test_take_then_rest_asks_the_taker_then_the_maker() public {
        address a = _admittedMaker();
        uint32 pa = _placeP(a, T, false, LOT);
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pa, T));
        uint256 params = OloOps.tagW(pc, OloOps.restW(true, 3 * LOT, T, 0, _pos()));
        policy.set(taker, true, true);
        vm.expectCall(address(policy), _admittedCall(taker, false), 1);
        vm.expectCall(address(policy), _admittedCall(taker, true), 1);
        bytes memory ret = _ok(taker, abi.encodeCall(book.takeThenRest, (pk, list, params)));
        (uint256 got,, uint256 rested,) = abi.decode(ret, (uint256, uint256, uint256, uint256));
        assertEq(got, LOT);
        assertEq(rested, 2 * LOT);
    }

    /// The entries that only leave never ask: with the policy refusing the maker either way, it cancels and claims pool orders and batch sub-orders, by the entries and the multicall, and withdraws.
    function test_leaving_never_asks() public {
        address a = _admittedMaker();
        uint32 p1 = _placeP(a, T, false, 4 * LOT);
        uint32 p2 = _placeP(a, T + 1, false, 4 * LOT);
        uint32 p3 = _placeP(a, T + 2, false, 4 * LOT);
        vm.prank(a);
        _mb(pc, OloOps.postW(false, 0, T + 5, LOT, 2));
        policy.set(taker, false, true);
        _ok(taker, _takeCall(pk, pc, p1, T, true, LOT));
        _ok(taker, _takeCall(pk, pc, p2, T + 1, true, LOT));
        _ok(
            taker,
            abi.encodeCall(
                book.take,
                (
                    pk,
                    OloOps.batchList(OloOps.slotGroupAt(a, 0, 0x1, T + 5)),
                    OloOps.tagW(pc, OloOps.takeW(true, LOT / 2, 0))
                )
            )
        );

        // the policy now refuses everyone, and is not asked by any of these
        policy.set(a, false, false);
        vm.expectCall(address(policy), _admittedCall(a, true), 0);
        vm.expectCall(address(policy), _admittedCall(a, false), 0);
        _ok(a, abi.encodeCall(book.claim, (pk, OloOps.tagW(pc, OloOps.posW(p1, 0)))));
        _ok(a, abi.encodeCall(book.cancel, (pk, OloOps.tagW(pc, OloOps.posW(p1, 0)))));
        _ok(
            a,
            abi.encodeCall(
                book.multicall,
                (0, bytes.concat(OloOps.header(pk), OloOps.claim(0, p2), OloOps.cancel(0, p2), OloOps.cancel(0, p3)))
            )
        );
        _ok(a, OloOps.batchCalldata(book.manageBatchSubs.selector, pc, OloOps.maskW(OloOps.CLAIM, 0, 0, 0)));
        _ok(a, OloOps.batchCalldata(book.manageBatchSubs.selector, pc, OloOps.maskW(OloOps.CANCEL, 0, 0, 0x3)));
        uint256 qb = _bal(a, quote);
        uint256 bb = _bal(a, base);
        _ok(a, abi.encodeCall(book.withdraw, (address(quote), qb)));
        _ok(a, abi.encodeCall(book.withdraw, (address(base), bb)));
        assertEq(_bal(a, quote), 0);
        assertEq(_bal(a, base), 0);
    }

    /// A maker's resting order fills after the policy stops admitting it (makers are asked when they rest, not when
    /// they fill), until it cancels; it cannot rest anything new or change the order.
    function test_a_revoked_maker_s_orders_still_fill() public {
        address a = _admittedMaker();
        uint32 pa = _placeP(a, T, false, 4 * LOT);
        policy.set(a, false, false); // revoked
        (uint256 got,) = abi.decode(_ok(taker, _takeCall(pk, pc, pa, T, true, LOT)), (uint256, uint256));
        assertEq(got, LOT, "it fills");
        _refused(
            a,
            abi.encodeCall(book.modify, (pk, OloOps.tagW(pc, OloOps.modifyW(pa, T + 1, LOT, 0)))),
            IOloBookBase.NotAdmitted.selector
        );
        _refused(
            a,
            abi.encodeCall(book.place, (pk, OloOps.placeW(false, T, LOT, _pos(), 0))),
            IOloBookBase.NotAdmitted.selector
        );
        _ok(a, abi.encodeCall(book.cancel, (pk, OloOps.tagW(pc, OloOps.posW(pa, 0)))));
        (, uint256 open,,,) = book.orderOf(pc, pa);
        assertEq(open, 0);
    }

    /// A multicall asks once per market run, at its first PLACE or MODIFY; a run of CANCELs and CLAIMs never asks.
    function test_multicall_asks_once_a_run() public {
        address a = _admittedMaker();
        uint32 p1 = _pos();
        uint32 p2 = _pos();
        // once in all: the first multicall's first PLACE, then nothing for the second's CANCELs
        vm.expectCall(address(policy), _admittedCall(a, true), 1);
        _ok(
            a,
            abi.encodeCall(
                book.multicall,
                (
                    0,
                    bytes.concat(
                        OloOps.header(pk),
                        OloOps.place(0, T, false, LOT, p1),
                        OloOps.place(0, T + 1, false, LOT, p2),
                        OloOps.modify(0, p1, T + 2, LOT)
                    )
                )
            )
        );
        _ok(
            a,
            abi.encodeCall(
                book.multicall, (0, bytes.concat(OloOps.header(pk), OloOps.cancel(0, p1), OloOps.cancel(0, p2)))
            )
        );
    }

    /// The open market next door never asks: its entries test the bit only.
    function test_an_open_market_never_asks() public {
        vm.expectCall(address(policy), bytes(""), 0);
        address a = _plain(T, false, 3 * LOT);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, LOT, 0)));
        vm.prank(a);
        book.multicall(0, bytes.concat(OloOps.header(c), OloOps.place(0, T + 1, false, LOT, _pos())));
    }

    // ============================================================== the policy's answers

    /// Only one word, true, admits: a revert (one whose data is the word 1 too), no data, 31 bytes, the word 2, a gas
    /// burner and a write (a static call refuses it) all refuse, and so does false; true with more data after it admits, 64 KiB of it too (copied
    /// whole: the market's own callers pay for a policy that answers at length).
    function test_only_true_admits() public {
        RawPolicy raw = new RawPolicy();
        vm.prank(lister);
        uint32 id = book.listMarketQuoteProprietary(address(base), address(quote), 80, 6, 1, 0, address(raw));
        MarketWord k = OloOps.key(book.configOf(id));
        address a = _maker();
        bytes4 refused = IOloBookBase.NotAdmitted.selector;
        uint256[8] memory refusing = [uint256(1), 2, 3, 4, 7, 8, 9, 10];
        for (uint256 i; i < refusing.length; ++i) {
            raw.setMode(refusing[i]);
            bytes memory placeCall = abi.encodeCall(book.place, (k, OloOps.placeW(false, T, LOT, _pos(), 0)));
            vm.prank(a);
            (bool ok, bytes memory ret) = address(book).call{gas: 2_000_000}(placeCall);
            assertFalse(ok, "refused");
            assertEq(bytes4(ret), refused);
        }
        uint256[3] memory admitting = [uint256(0), 5, 6];
        for (uint256 i; i < admitting.length; ++i) {
            raw.setMode(admitting[i]);
            uint32 pos = _pos();
            vm.prank(a);
            book.place(k, OloOps.placeW(false, T, LOT, pos, 0));
            (, uint256 open,,,) = book.orderOf(book.configOf(id), pos);
            assertEq(open, LOT, "admitted");
        }
    }

    // ============================================================== the bit is the market's

    /// The bit is part of the key: a word without it is not the proprietary market's (its orders' slots are other
    /// slots, a take there fills nothing, an entry that rests reads the registry and refuses it), and a word with it
    /// set on the open market's key asks a policy no market has (zero), which refuses.
    function test_the_bit_names_the_market() public {
        address a = _admittedMaker();
        uint32 pa = _placeP(a, T, false, 3 * LOT);
        MarketWord noBitK = MarketWord.wrap(MarketWord.unwrap(pk) & ~C_PROPRIETARY_FLAG);
        MarketWord noBitC = MarketWord.wrap(MarketWord.unwrap(pc) & ~C_PROPRIETARY_FLAG);
        // the bit cleared: the take finds nothing (and asks no policy), a place is UnknownMarket
        vm.expectCall(address(policy), bytes(""), 0);
        (uint256 got,) =
            abi.decode(_ok(address(0x7777), _takeCall(noBitK, noBitC, pa, T, true, LOT)), (uint256, uint256));
        assertEq(got, 0);
        _refused(
            a,
            abi.encodeCall(book.place, (noBitK, OloOps.placeW(false, T, LOT, _pos(), 0))),
            IOloBookBase.UnknownMarket.selector
        );
        // the bit set on the open market's key: no policy there, refused
        MarketWord bitK = MarketWord.wrap(MarketWord.unwrap(OloOps.key(c)) | C_PROPRIETARY_FLAG);
        MarketWord bitC = MarketWord.wrap(MarketWord.unwrap(c) | C_PROPRIETARY_FLAG);
        _refused(taker, _takeCall(bitK, bitC, pa, T, true, LOT), IOloBookBase.NotAdmitted.selector);
        _refused(
            a,
            abi.encodeCall(book.place, (bitK, OloOps.placeW(false, T, LOT, _pos(), 0))),
            IOloBookBase.NotAdmitted.selector
        );
    }

    /// A fee change keeps the bit (a key bit) and the policy: the next version asks as the first did, and the older
    /// version's orders fill at their fee.
    function test_a_fee_change_keeps_the_bit() public {
        address a = _admittedMaker();
        uint32 pa = _placeP(a, T, false, 3 * LOT);
        book.setMarketFee(pm, 70, 0);
        MarketWord pc2 = book.configOf(pm);
        assertTrue(pc2.isProprietary());
        assertEq(MarketWord.unwrap(OloOps.key(pc2)), MarketWord.unwrap(pk), "the key stays");
        assertEq(pc2.version(), 2);
        // the older version's order fills, the taker asked
        vm.expectCall(address(policy), _admittedCall(taker, false), 1);
        _ok(taker, _takeCall(pk, pc, pa, T, true, LOT));
        // a place rests in version 2, the maker asked; a stranger is refused
        uint32 p2 = _placeP(a, T, false, LOT);
        (, uint256 open,,,) = book.orderOf(pc2, p2);
        assertEq(open, LOT);
        _refused(
            address(0x7777),
            abi.encodeCall(book.place, (pk, OloOps.placeW(false, T, LOT, _pos(), 0))),
            IOloBookBase.NotAdmitted.selector
        );
    }
}
