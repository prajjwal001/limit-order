// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {RolePolicy} from "./OloProprietary.t.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

/// Gas of a proprietary market's entries beside the open market's (run with --isolate; frame gas). The fixture's open
/// market and a proprietary market of the same parameters whose policy (RolePolicy: one mapping read) admits the
/// makers and the taker; each row runs the same operation in both, `open_` and `prop_`, so the difference is the
/// policy's read and call, and the policy's own work.
contract GasBenchProprietary is OloBase {
    RolePolicy policy;
    uint32 pm;
    MarketWord pc;
    MarketWord pk;
    address am; // an admitted maker with orders in both markets

    function setUp() public {
        _deploy();
        policy = new RolePolicy();
        book.setProprietaryListingAllowed(address(this), true);
        pm = book.listMarketQuoteProprietary(address(base), address(quote), 50, 6, 1, 0, address(policy));
        pc = book.configOf(pm);
        pk = OloOps.key(pc);
        policy.set(taker, true, true);
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
        am = _maker();
        policy.set(am, true, false);
    }

    /// The market word of the `prop` market or the open one, and its key.
    function _k(bool prop) internal view returns (MarketWord) {
        return prop ? pk : OloOps.key(c);
    }

    function _c(bool prop) internal view returns (MarketWord) {
        return prop ? pc : c;
    }

    function _name(bool prop, string memory k) internal pure returns (string memory) {
        return string.concat(prop ? "prop_" : "open_", k);
    }

    /// A maker's order in a position nobody used.
    function _placeRow(bool prop) internal {
        vm.prank(am);
        book.place(_k(prop), OloOps.placeW(false, T + 5, 5 * LOT, _pos(), 0));
        _log(_name(prop, "place_new_level"), _gas());
    }

    function test_place() public {
        _placeRow(false);
        _placeRow(true);
    }

    /// One fill of a resting ask, the taker's accounts.
    function _takeRow(bool prop) internal {
        uint32 pos = _pos();
        vm.prank(am);
        book.place(_k(prop), OloOps.placeW(false, T + 1, 5 * LOT, pos, 0));
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pos, T + 1));
        uint256 params = OloOps.tagW(_c(prop), OloOps.takeW(true, 2 * LOT, 0));
        MarketWord k = _k(prop);
        vm.prank(taker);
        book.take(k, list, params);
        _log(_name(prop, "take_one_fill"), _gas());
    }

    function test_take() public {
        _takeRow(false);
        _takeRow(true);
    }

    /// A takeThenRest that fills one order and rests the rest: the taker asked as a taker, then as a maker.
    function _takeThenRestRow(bool prop) internal {
        uint32 pos = _pos();
        vm.prank(am);
        book.place(_k(prop), OloOps.placeW(false, T + 1, 2 * LOT, pos, 0));
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pos, T + 1));
        uint256 params = OloOps.tagW(_c(prop), OloOps.restW(true, 5 * LOT, T + 1, 0, _pos()));
        MarketWord k = _k(prop);
        vm.prank(taker);
        book.takeThenRest(k, list, params);
        _log(_name(prop, "take_then_rest"), _gas());
    }

    function test_take_then_rest() public {
        _takeThenRestRow(false);
        _takeThenRestRow(true);
    }

    /// A multicall of two PLACEs under a K header: asked once, at the first.
    function _multicallRow(bool prop) internal {
        bytes memory data = bytes.concat(
            OloOps.header(_k(prop)),
            OloOps.place(0, T + 6, false, LOT, _pos()),
            OloOps.place(0, T + 7, false, LOT, _pos())
        );
        vm.prank(am);
        book.multicall(0, data);
        _log(_name(prop, "multicall_place2_key"), _gas());
    }

    function test_multicall() public {
        _multicallRow(false);
        _multicallRow(true);
    }

    /// A batch post of two sub-orders in a fresh slot.
    function _batchRow(bool prop) internal {
        vm.prank(am);
        _mb(_c(prop), OloOps.postW(false, prop ? 1 : 0, T + 8, LOT, 2));
        _log(_name(prop, "batch_post2_fresh"), _gas());
    }

    function test_batch() public {
        _batchRow(false);
        _batchRow(true);
    }

    /// A cancel: no policy asked in either market.
    function _cancelRow(bool prop) internal {
        uint32 pos = _pos();
        vm.prank(am);
        book.place(_k(prop), OloOps.placeW(false, T + 9, LOT, pos, 0));
        uint256 params = OloOps.tagW(_c(prop), OloOps.posW(pos, 0));
        MarketWord k = _k(prop);
        vm.prank(am);
        book.cancel(k, params);
        _log(_name(prop, "cancel"), _gas());
    }

    function test_cancel() public {
        _cancelRow(false);
        _cancelRow(true);
    }
}
