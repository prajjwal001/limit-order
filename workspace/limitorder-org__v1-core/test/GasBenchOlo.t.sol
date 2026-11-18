// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {console2} from "forge-std/console2.sol";

/// Gas of OloBook (run with --isolate). Rows prefixed `mv_` are receipt gas (the capped refund deducted); every
/// other row is frame gas. A warm OLO EVM contract: one past round so the fee pot is nonzero; 3 makers x 5 lots at T+1
/// (asks) and T-1 (bids).
contract GasBenchOlo is OloBase {
    address[3] asks;
    address[3] bids;

    function setUp() public {
        _deploy();
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
        address w = _plain(T + 1, false, 1 * LOT);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(w)), OloOps.tagW(c, OloOps.takeW(true, 1 * LOT, 0)));
        vm.prank(w);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[w], 0)));
        for (uint256 i; i < 3; ++i) {
            asks[i] = _plain(T + 1, false, 5 * LOT);
            bids[i] = _plain(T - 1, true, 5 * LOT);
        }
    }

    /// The multicall rows' header: the market's C (the default), or its key K when set (the rows then end `_key`).
    bool keyHeader;

    function _logR(string memory k) internal view {
        console2.log(string.concat("GAS mv_", k, keyHeader ? "_key" : ""), _receipt());
    }

    function _logRPer(string memory k, uint256 n) internal view {
        uint256 g = _receipt();
        string memory row = string.concat("GAS mv_", k, keyHeader ? "_key" : "");
        console2.log(row, g);
        console2.log(string.concat(row, "_per_order"), g / n);
    }

    /// A multicall payload on the fixture market: the header (`keyHeader`: K, else C) and `ops`.
    function _hdr(bytes memory ops) internal view returns (bytes memory) {
        return keyHeader ? bytes.concat(OloOps.header(OloOps.key(c)), ops) : _mc(ops);
    }

    /// `n` fresh consecutive positions; the first is returned.
    function _block(uint256 n) internal returns (uint32 from) {
        from = nextPos;
        nextPos += uint32(n);
    }

    // ================================================================ single operations (frame gas)

    /// A maker's order in a position nobody ever used.
    function test_place_new_level() public {
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, _pos(), 0));
        _log("place_new_level", _gas());
        _log("place_join_level", _gas()); // the same thing here: there are no levels
    }

    /// A position pre-warmed by `warmPool` (the market's creator or the protocol paid the fresh write).
    function test_place_warm_position() public {
        uint32 from = _block(8);
        book.warmPool(m, from, 8);
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, from + 3, 0));
        _log("place_warm_position", _gas());
    }

    /// A position another maker's finished order left (the pool's steady state).
    function test_place_other_dead_position() public {
        address b = _plain(T + 5, false, 5 * LOT);
        vm.prank(b);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[b], 0)));
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 6, 5 * LOT, posOf[b], 0));
        _log("place_other_dead_position", _gas());
    }

    /// A maker's own freed position.
    function test_place_reused_slot() public {
        address a = _maker();
        uint32 pos = _pos();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, pos, 0));
        vm.prank(a);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 6, 5 * LOT, pos, 0));
        _log("place_reused_slot", _gas());
    }

    /// A bid: its escrow is the dearer branch (lot-ticks x the tick size, rounded up by the divisor).
    function test_place_bid() public {
        uint32 from = _block(8);
        book.warmPool(m, from, 8);
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(true, T - 5, 5 * LOT, from + 3, 0));
        _log("place_bid_warm_position", _gas());
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(true, T - 5, 5 * LOT, _pos(), 0));
        _log("place_bid_new_position", _gas());
    }

    function test_place_wallet() public {
        address wo = address(0xABCD01);
        base.mint(wo, 1e30);
        vm.startPrank(wo);
        base.approve(address(book), type(uint256).max);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, nextPos++, 2));
        vm.stopPrank();
        _log("place_wallet_new_slot", _gas());
    }

    function test_warm_pool() public {
        uint32 from = _block(100);
        book.warmPool(m, from, 100);
        uint256 g = _gas();
        _log("warm_pool_100", g);
        _log("warm_pool_100_per_position", g / 100);
    }

    /// Probing: a first try that is free (the flag's cost), and two busy positions before the free one.
    function test_probe_rows() public {
        uint32 from = _block(8);
        book.warmPool(m, from, 8);
        address a = _maker();
        address b = _maker();
        vm.prank(b);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, from, 0));
        vm.prank(b);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, from + 1, 0));
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, from + 2, 0x80));
        _log("place_warm_position_probe_hit", _gas());
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, from, 0x80));
        _log("place_warm_position_probe_2_misses", _gas());
    }

    /// A listing that warms 512 positions in the same transaction (batch slots are each maker's own: none to warm).
    function test_list_market_warm() public {
        book.listMarketQuote(address(base), address(quote), 70, 6, 1, 512);
        _log("list_market_warm_512_positions", _gas());
    }

    // ---------------------------------------------------------------- accounts (the balance pool)

    /// A new user's first deposit of a token: a fresh account word, a pre-warmed one, and a later deposit.
    function test_deposit_rows() public {
        address u = address(0xABCD03);
        base.mint(u, 1e30);
        vm.prank(u);
        base.approve(address(book), type(uint256).max);
        vm.prank(u);
        book.deposit(address(base), 1e9);
        _log("deposit_new_account", _gas());
        vm.prank(u);
        book.deposit(address(base), 1e9);
        _log("deposit_existing_account", _gas());
        vm.prank(u);
        book.withdraw(address(base), 1e9);
        _log("withdraw", _gas());
    }

    function test_cancel_tail() public {
        vm.prank(asks[2]);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[asks[2]], 0)));
        _log("cancel_tail", _gas());
        _log("cancel_mid", _gas()); // no queue: a cancel is a cancel
    }

    function test_cancel_part_filled() public {
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(asks[0])), OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0)));
        vm.prank(asks[0]);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[asks[0]], 0)));
        _log("cancel_part_filled", _gas());
    }

    function test_claim_filled() public {
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(asks[0])), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0)));
        vm.prank(asks[0]);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[asks[0]], 0)));
        _log("claim_filled", _gas());
    }

    function test_claim_partial() public {
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(asks[0])), OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0)));
        vm.prank(asks[0]);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[asks[0]], 0)));
        _log("claim_partial", _gas());
    }

    function test_take_internal_buy2() public {
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(asks[0])), OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0)));
        _log("take_internal_buy2", _gas());
    }

    function test_take_wallet_buy2() public {
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(asks[0])), OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 1)));
        _log("take_wallet_buy2", _gas());
    }

    function test_take_internal_sell2() public {
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(bids[0])), OloOps.tagW(c, OloOps.takeW(false, 2 * LOT, 0)));
        _log("take_internal_sell2", _gas());
    }

    /// 17 lots over the 3 asks at T+1 and one at T+2: 4 orders, 2 prices.
    function test_take_buy17_4orders() public {
        address d = _plain(T + 2, false, 5 * LOT);
        bytes memory entries =
            bytes.concat(_poolEntry(asks[0]), _poolEntry(asks[1]), _poolEntry(asks[2]), _poolEntry(d));
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(true, 17 * LOT, 1)));
        _log("take_wallet_buy17_4orders", _gas());
    }

    /// With a protocol share: the take holds the fee, the claim splits it (the maker's part, the rest to the pot).
    /// A first order settles before, so the pot is a written word, as in a running market.
    function test_protocol_share_rows() public {
        book.setMarketMakerShare(m, 8_000);
        c = book.configOf(m); // the new version, where the orders below rest
        address a = _plain(T + 2, false, 5 * LOT);
        address w = _plain(T + 2, false, 1 * LOT);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(w)), OloOps.tagW(c, OloOps.takeW(true, 1 * LOT, 0)));
        vm.prank(w);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[w], 0)));
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0)));
        _log("take_internal_buy2_protocol_share", _gas());
        vm.prank(a);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], 0)));
        _log("claim_partial_protocol_share", _gas());
    }

    /// At the share the contract deploys at, 0 (the protocol takes the whole fee): claim_partial's claim, its fee
    /// wholly to the pot. The first settle that pays fills in a quote token writes that token's pot fresh (zero to
    /// nonzero, once in the contract's life); every later one rewrites it, as at any share below 10,000
    /// (claim_partial_protocol_share).
    function test_share_zero_rows() public {
        book.setMarketMakerShare(m, 0);
        c = book.configOf(m); // the new version, where the orders below rest
        address a = _plain(T + 2, false, 5 * LOT);
        address b = _plain(T + 2, false, 5 * LOT);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0)));
        vm.prank(a);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], 0)));
        _log("claim_partial_share_0_first_pot", _gas());
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(b)), OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0)));
        vm.prank(b);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[b], 0)));
        _log("claim_partial_share_0", _gas());
    }

    /// The owner's pair setters, each on a pair whose word is still zero (a first set) and again (an update); each
    /// reads the pair's word and keeps the other field.
    function test_pair_default_rows() public {
        book.setPairFeeFloor(address(base), address(quote), 100, true);
        _log("set_pair_fee_floor_first", _gas());
        book.setPairFeeFloor(address(base), address(quote), 200, true);
        _log("set_pair_fee_floor_update", _gas());
        book.setPairMakerShare(address(quote), address(this), 2_000, true);
        _log("set_pair_maker_share_first", _gas());
        book.setPairMakerShare(address(quote), address(this), 3_000, true);
        _log("set_pair_maker_share_update", _gas());
    }

    /// The owner's other fee entries: the global floor moved (its slot already written, by the constructor), and a
    /// market's fee moved: its next version, written in place in the registry (main listed a successor market here).
    function test_fee_admin_rows() public {
        book.setGlobalFeeFloor(100);
        _log("set_global_fee_floor", _gas());
        book.setMarketFee(m, 300, 0);
        _log("set_market_fee_new_version", _gas());
    }

    /// A share change makes the market's next version, every position and slot of which is cold: a place in a position
    /// used before (a cancelled order's dead word) and a 4-order post in a slot used before (cancelled), each measured
    /// before the change, where they rewrite written words, and after it, where the same position and slot number are
    /// fresh in the new version (the market's share changed in place on an OLO EVM contract that does not version it:
    /// no such cost).
    function test_rest_again_after_a_share_change() public {
        address z = _maker();
        uint32 pos = _pos();
        uint16 s = _slot();
        vm.startPrank(z);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, pos, 0));
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        _mb(c, _ladderW(OloOps.POST, false, s, T + 2, 4));
        _mb(c, OloOps.maskW(OloOps.CANCEL, s, 0, 0xf));
        vm.stopPrank();
        uint256 snap = vm.snapshotState();
        vm.prank(z);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, pos, 0));
        _log("place_used_position", _gas());
        vm.prank(z);
        _mb(c, _ladderW(OloOps.POST, false, s, T + 2, 4));
        _log("batch_post4_used_slot", _gas());
        vm.revertToState(snap);
        _setMarketShare(5_000);
        vm.prank(z);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, pos, 0));
        _log("place_used_position_after_share_change", _gas());
        vm.prank(z);
        _mb(c, _ladderW(OloOps.POST, false, s, T + 2, 4));
        _log("batch_post4_used_slot_after_share_change", _gas());
    }

    /// The first place and the first batch post after a version change, by K: each reads the market's current C and
    /// rests in the new version, whose positions and slots nobody wrote yet (fresh, as in a market just listed with
    /// nothing warmed). Main's twin: the first place and post in the successor market its fee change listed.
    function test_first_rest_after_a_version_change() public {
        book.setMarketFee(m, 300, 0);
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, _pos(), 0));
        _log("place_first_after_version_change", _gas());
        address z = _maker();
        uint16 s = _slot();
        vm.prank(z);
        _mb(c, _ladderW(OloOps.POST, false, s, T + 2, 4));
        _log("batch_post4_first_after_version_change", _gas());
    }

    /// Buy 7 against a 5-lot ask and rest the 2 at the limit, one call, versus a take and a place.
    function test_take_then_rest() public {
        vm.prank(taker);
        book.takeThenRest(
            OloOps.key(c),
            OloOps.poolList(_poolEntry(asks[0])),
            OloOps.tagW(c, OloOps.restW(true, 7 * LOT, T + 1, 0, _pos()))
        );
        _log("take_and_rest", _gas());
    }

    /// The same through the wallet: the fills' quote and the rest's escrow in one pull, the base in one push.
    function test_take_then_rest_wallet() public {
        vm.prank(taker);
        book.takeThenRest(
            OloOps.key(c),
            OloOps.poolList(_poolEntry(asks[0])),
            OloOps.tagW(c, OloOps.restW(true, 7 * LOT, T + 1, 1, _pos()))
        );
        _log("take_and_rest_wallet", _gas());
    }

    /// A list gone stale (the named ask repriced away): nothing fills, the 7 rest; by account and by wallet.
    function test_take_then_rest_nothing_filled() public {
        vm.prank(asks[0]);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[asks[0]], T + 3, 5 * LOT, 0)));
        vm.prank(taker);
        book.takeThenRest(
            OloOps.key(c),
            OloOps.poolList(_poolEntry(asks[0])),
            OloOps.tagW(c, OloOps.restW(true, 7 * LOT, T + 1, 0, _pos()))
        );
        _log("take_and_rest_nothing_filled", _gas());
        vm.prank(taker);
        book.takeThenRest(
            OloOps.key(c),
            OloOps.poolList(_poolEntry(asks[0])),
            OloOps.tagW(c, OloOps.restW(true, 7 * LOT, T + 1, 1, _pos()))
        );
        _log("take_and_rest_nothing_filled_wallet", _gas());
    }

    function test_take_then_place() public {
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(asks[0])), OloOps.tagW(c, OloOps.takeW(true, 7 * LOT, 0)));
        uint256 g = _gas();
        vm.prank(taker);
        book.place(OloOps.key(c), OloOps.placeW(true, T + 1, 2 * LOT, _pos(), 0));
        _log("take_then_place", g + _gas());
    }

    // ================================================================ maker rows (receipt gas)

    function test_mv_place() public {
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, _pos(), 0));
        _logR("place_join");
        _logR("place_new_slot");
    }

    function test_mv_place_again() public {
        address a = _maker();
        uint32 pos = _pos();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, pos, 0));
        vm.prank(a);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, pos, 0));
        _logR("place_again");
        _logR("place_chosen_slot");
    }

    function test_mv_cancel() public {
        vm.prank(asks[2]);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[asks[2]], 0)));
        _logR("cancel_tail");
        _logR("cancel_mid");
    }

    function test_mv_cancel_part_filled() public {
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(asks[0])), OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0)));
        vm.prank(asks[0]);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[asks[0]], 0)));
        _logR("cancel_part_filled");
    }

    function test_mv_claim_filled() public {
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(asks[0])), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0)));
        vm.prank(asks[0]);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[asks[0]], 0)));
        _logR("claim_filled");
    }

    function test_mv_claim_partial() public {
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(asks[0])), OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0)));
        vm.prank(asks[0]);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[asks[0]], 0)));
        _logR("claim_partial");
    }

    function test_mv_modify_shrink() public {
        vm.prank(asks[1]);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[asks[1]], T + 1, 2 * LOT, 0)));
        _logR("modify_shrink_mid");
        _logR("modify_shrink_tail");
    }

    function test_mv_modify_grow() public {
        vm.prank(asks[2]);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[asks[2]], T + 1, 8 * LOT, 0)));
        _logR("modify_grow_tail");
    }

    /// An ask moved at the same size: the order word only.
    function test_mv_move() public {
        vm.prank(asks[1]);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[asks[1]], T + 2, 5 * LOT, 0)));
        _logR("move_mid");
        _logR("move_tail");
    }

    function test_mv_move_bid() public {
        vm.prank(bids[1]);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[bids[1]], T - 2, 5 * LOT, 0)));
        _logR("move_mid_bid");
    }

    function test_mv_move_wallet() public {
        vm.prank(asks[1]);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[asks[1]], T + 2, 5 * LOT, 0x02)));
        _logR("move_mid_wallet");
    }

    /// A multicall of one PLACE (into a fresh position), then one of its CANCEL, each under a header that is the
    /// market's C and under one that is its key K: K reads the market's current C from the registry when the stream
    /// switches to the market, a CANCEL-only run too (C reads it only at a run's first PLACE or MODIFY).
    function test_mv_multicall_header_rows() public {
        address z = _maker();
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 2; ++i) {
            bytes memory hdr = i == 0 ? OloOps.header(c) : OloOps.header(OloOps.key(c));
            string memory tail = i == 0 ? "" : "_key";
            uint32 pos0 = _block(1);
            vm.prank(z);
            book.multicall(0, bytes.concat(hdr, OloOps.place(0, T + 2, false, 5 * LOT, pos0)));
            _logR(string.concat("multicall_place_one", tail));
            vm.prank(z);
            book.multicall(0, bytes.concat(hdr, OloOps.cancel(0, pos0)));
            _logR(string.concat("multicall_cancel_one", tail));
            vm.revertToState(snap);
        }
    }

    function test_mv_multicall_one_move() public {
        vm.prank(asks[1]);
        book.multicall(0, _mc(OloOps.modify(0, posOf[asks[1]], T + 2, 5 * LOT)));
        _logR("multicall_one_move");
    }

    /// Two PLACEs asking for the same warmed position: the second probes one step, so the Ops event is logged with
    /// its pos rewritten.
    function test_mv_multicall_probe_hit() public {
        address z = _maker();
        uint32 pos0 = _block(4);
        book.warmPool(m, pos0, 4);
        bytes memory ops = bytes.concat(
            OloOps.placeProbe(0, T + 2, false, 5 * LOT, pos0, 2), OloOps.placeProbe(0, T + 3, false, 5 * LOT, pos0, 2)
        );
        vm.prank(z);
        book.multicall(0, _mc(ops));
        _logR("multicall_probe_hit_2");
    }

    // ================================================================ ladders: a maker's N orders in one multicall

    function _ladderOps(uint256 n, bool isBid, uint256 from, uint32 pos0) internal pure returns (bytes memory ops) {
        for (uint256 i; i < n; ++i) {
            uint256 t = isBid ? from - i : from + i;
            ops = bytes.concat(ops, OloOps.place(0, t, isBid, 5 * LOT, pos0 + uint32(i)));
        }
    }

    /// A maker's first ladder: every position is written fresh.
    function _ladderPlaceFresh(uint256 n) internal {
        address z = _maker();
        uint32 pos0 = _block(n);
        vm.prank(z);
        book.multicall(0, _hdr(_ladderOps(n, false, T + 2, pos0)));
        _logRPer(string.concat("ladder", vm.toString(n), "_place_fresh"), n);
    }

    /// The same ladder placed again in the positions the maker's finished orders freed.
    function _ladderPlaceReused(uint256 n) internal {
        address z = _maker();
        uint32 pos0 = _block(n);
        vm.prank(z);
        book.multicall(0, _hdr(_ladderOps(n, false, T + 2, pos0)));
        bytes memory ops;
        for (uint256 i; i < n; ++i) {
            ops = bytes.concat(ops, OloOps.cancel(0, pos0 + uint32(i)));
        }
        vm.prank(z);
        book.multicall(0, _hdr(ops));
        vm.prank(z);
        book.multicall(0, _hdr(_ladderOps(n, false, T + 2, pos0)));
        _logRPer(string.concat("ladder", vm.toString(n), "_place_reused"), n);
    }

    /// N asks moved up one tick in place (no balance moves).
    function _ladderUp1(uint256 n) internal {
        address z = _maker();
        uint32 pos0 = _block(n);
        vm.prank(z);
        book.multicall(0, _hdr(_ladderOps(n, false, T + 2, pos0)));
        bytes memory ops;
        for (uint256 i; i < n; ++i) {
            ops = bytes.concat(ops, OloOps.modify(0, pos0 + uint32(i), T + 3 + i, 5 * LOT));
        }
        vm.prank(z);
        book.multicall(0, _hdr(ops));
        _logRPer(string.concat("ladder", vm.toString(n), "_up1"), n);
    }

    /// N bids moved down one tick in place (the net escrow moves once).
    function _ladderBidsDown1(uint256 n) internal {
        address z = _maker();
        uint32 pos0 = _block(n);
        vm.prank(z);
        book.multicall(0, _hdr(_ladderOps(n, true, T - 2, pos0)));
        bytes memory ops;
        for (uint256 i; i < n; ++i) {
            ops = bytes.concat(ops, OloOps.modify(0, pos0 + uint32(i), T - 3 - i, 5 * LOT));
        }
        vm.prank(z);
        book.multicall(0, _hdr(ops));
        _logRPer(string.concat("ladder", vm.toString(n), "_bids_down1"), n);
    }

    function _ladderCancel(uint256 n) internal {
        address z = _maker();
        uint32 pos0 = _block(n);
        vm.prank(z);
        book.multicall(0, _hdr(_ladderOps(n, false, T + 2, pos0)));
        bytes memory ops;
        for (uint256 i; i < n; ++i) {
            ops = bytes.concat(ops, OloOps.cancel(0, pos0 + uint32(i)));
        }
        vm.prank(z);
        book.multicall(0, _hdr(ops));
        _logRPer(string.concat("ladder", vm.toString(n), "_cancel"), n);
    }

    function _ladders(uint256 n) internal {
        uint256 s = vm.snapshotState();
        _ladderPlaceFresh(n);
        vm.revertToState(s);
        _ladderPlaceReused(n);
        vm.revertToState(s);
        _ladderUp1(n);
        vm.revertToState(s);
        _ladderBidsDown1(n);
        vm.revertToState(s);
        _ladderCancel(n);
        vm.revertToState(s);
    }

    function test_ladder10() public {
        _ladders(10);
    }

    function test_ladder20() public {
        _ladders(20);
    }

    function test_ladder40() public {
        _ladders(40);
    }

    /// The same ladders under a header that is the market's key K: the stream reads the market's current C once, when
    /// it switches to the market (a header C reads it at its first PLACE or MODIFY, and a CANCEL-only run not at all).
    function test_ladder10_key() public {
        keyHeader = true;
        _ladders(10);
    }

    function test_ladder20_key() public {
        keyHeader = true;
        _ladders(20);
    }

    function test_ladder40_key() public {
        keyHeader = true;
        _ladders(40);
    }

    function test_requote_two_sided() public {
        _requoteTwoSided();
    }

    function test_requote_two_sided_key() public {
        keyHeader = true;
        _requoteTwoSided();
    }

    function test_cancel5_place5() public {
        _cancel5Place5();
    }

    function test_cancel5_place5_key() public {
        keyHeader = true;
        _cancel5Place5();
    }

    /// 5 asks and 5 bids each moved one tick up, one multicall.
    function _requoteTwoSided() internal {
        address z = _maker();
        uint32 pa = _block(5);
        uint32 pb = _block(5);
        vm.prank(z);
        book.multicall(0, _hdr(bytes.concat(_ladderOps(5, false, T + 2, pa), _ladderOps(5, true, T - 2, pb))));
        bytes memory ops;
        for (uint256 i; i < 5; ++i) {
            ops = bytes.concat(ops, OloOps.modify(0, pa + uint32(i), T + 3 + i, 5 * LOT));
        }
        for (uint256 i; i < 5; ++i) {
            ops = bytes.concat(ops, OloOps.modify(0, pb + uint32(i), T - 1 - i, 5 * LOT));
        }
        vm.prank(z);
        book.multicall(0, _hdr(ops));
        _logRPer("requote_two_sided_10", 10);
    }

    /// Cancel 5 asks and place 5 new ones a tick higher, one multicall.
    function _cancel5Place5() internal {
        address z = _maker();
        uint32 pa = _block(5);
        vm.prank(z);
        book.multicall(0, _hdr(_ladderOps(5, false, T + 2, pa)));
        bytes memory ops;
        for (uint256 i; i < 5; ++i) {
            ops = bytes.concat(ops, OloOps.cancel(0, pa + uint32(i)));
        }
        for (uint256 i; i < 5; ++i) {
            ops = bytes.concat(ops, OloOps.place(0, T + 3 + i, false, 5 * LOT, pa + uint32(i)));
        }
        vm.prank(z);
        book.multicall(0, _hdr(ops));
        _logRPer("cancel5_place5", 5);
    }

    // ================================================================ takes over N orders (frame gas)

    /// N orders of 5 lots from N makers, one tick apart, in N positions; the take sweeps all of them.
    function _ladderEntries(uint256 n, bool asksSide) internal returns (bytes memory entries) {
        for (uint256 i; i < n; ++i) {
            uint256 t = asksSide ? T + 2 + i : T - 2 - i;
            address a = _plain(t, !asksSide, 5 * LOT);
            entries = bytes.concat(entries, _poolEntry(a));
        }
    }

    /// N orders of 5 lots from one maker in N consecutive positions.
    function _ladderEntriesOneMaker(uint256 n) internal returns (bytes memory entries) {
        address z = _maker();
        uint32 pos0 = _block(n);
        vm.prank(z);
        book.multicall(0, _mc(_ladderOps(n, false, T + 2, pos0)));
        entries = OloOps.poolEntries(pos0, n, T + 2, 1);
    }

    function _takeN(uint256 n) internal {
        uint256 s = vm.snapshotState();
        bytes memory entries = _ladderEntries(n, true);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(true, (5 * n) * LOT, 0)));
        _log(string.concat("take_internal_buy_N", vm.toString(n)), _gas());
        vm.revertToState(s);
        entries = _ladderEntries(n, true);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(true, (5 * n) * LOT, 1)));
        _log(string.concat("take_wallet_buy_N", vm.toString(n)), _gas());
        vm.revertToState(s);
        entries = _ladderEntries(n, false);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(false, (5 * n) * LOT, 0)));
        _log(string.concat("take_internal_sell_N", vm.toString(n)), _gas());
        vm.revertToState(s);
        entries = _ladderEntriesOneMaker(n);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(true, (5 * n) * LOT, 0)));
        _log(string.concat("take_internal_buy_N", vm.toString(n), "_one_maker"), _gas());
        vm.revertToState(s);
    }

    function test_take_N1() public {
        _takeN(1);
    }

    /// Three entries: where round 1's 7-byte list prefix pushed the entries past a word (an extra calldata word read).
    function test_take_N3() public {
        _takeN(3);
    }

    function test_take_N5() public {
        _takeN(5);
    }

    function test_take_N10() public {
        _takeN(10);
    }

    function test_take_N20() public {
        _takeN(20);
    }

    function test_take_N40() public {
        _takeN(40);
    }

    function test_take_N80() public {
        _takeN(80);
    }

    function test_take_N100() public {
        _takeN(100);
    }

    // ================================================================ batch slots (up to four sub-orders, any side)

    /// Each maker in its own slot numbers: a bench maker takes `_slot()` of its own.
    uint16 nextSlot = 1;

    function _slot() internal returns (uint16) {
        return nextSlot++;
    }

    /// `n` asks of 5 lots from T+2 up (bids from T-2 down), one tick apart.
    function _ladderW(uint8 kind, bool isBid, uint16 s, uint256 from, uint256 n)
        internal
        pure
        returns (uint256[3] memory)
    {
        return OloOps.ladderW(kind, isBid, s, 0, from, 5 * LOT, n, 1);
    }

    function _post(address z, uint16 s, bool isBid, uint256 from, uint256 n) internal {
        vm.prank(z);
        _mb(c, _ladderW(OloOps.POST, isBid, s, from, n));
    }

    function _batchPostFresh(uint256 n) internal {
        address z = _maker();
        _post(z, _slot(), false, T + 2, n);
        _logRPer(string.concat("batch", vm.toString(n), "_post_fresh"), n);
    }

    function _batchPostReused(uint256 n) internal {
        address z = _maker();
        uint16 s = _slot();
        _post(z, s, false, T + 2, n);
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CANCEL, s, 0, 0xf));
        _post(z, s, false, T + 2, n);
        _logRPer(string.concat("batch", vm.toString(n), "_post_reused"), n);
    }

    function _batchReplace(uint256 n) internal {
        address z = _maker();
        uint16 s = _slot();
        _post(z, s, false, T + 2, n);
        vm.prank(z);
        _mb(c, _ladderW(OloOps.REPLACE, false, s, T + 3, n));
        _logRPer(string.concat("batch", vm.toString(n), "_replace_up1"), n);
    }

    function _batchBidsReplace(uint256 n) internal {
        address z = _maker();
        uint16 s = _slot();
        _post(z, s, true, T - 2, n);
        vm.prank(z);
        _mb(c, _ladderW(OloOps.REPLACE, true, s, T - 3, n));
        _logRPer(string.concat("batch", vm.toString(n), "_bids_replace_down1"), n);
    }

    /// Every sub-order moved one tick up by a modify naming all of them (the replace's twin, by mask).
    function _batchModifyAll(uint256 n) internal {
        address z = _maker();
        uint16 s = _slot();
        _post(z, s, false, T + 2, n);
        uint256[3] memory w = _ladderW(OloOps.MODIFY, false, s, T + 3, n);
        w[0] |= uint256((1 << n) - 1) << 28;
        vm.prank(z);
        _mb(c, w);
        _logRPer(string.concat("batch", vm.toString(n), "_modify_all_up1"), n);
    }

    function _batchCancelAll(uint256 n) internal {
        address z = _maker();
        uint16 s = _slot();
        _post(z, s, false, T + 2, n);
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CANCEL, s, 0, 0xf));
        _logRPer(string.concat("batch", vm.toString(n), "_cancel_all"), n);
    }

    /// The slot taken whole, then claimed.
    function _batchTakeAll(uint256 n) internal {
        address z = _maker();
        uint16 s = _slot();
        _post(z, s, false, T + 2, n);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, s, uint8((1 << n) - 1), T + 5)),
            OloOps.tagW(c, OloOps.takeW(true, (5 * n) * LOT, 0))
        );
        _log(string.concat("take_batches_N", vm.toString(n), "_one_batch"), _gas());
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CLAIM, s, 0, 0));
        _logRPer(string.concat("batch", vm.toString(n), "_claim_filled"), n);
    }

    function _batches(uint256 n) internal {
        uint256 s = vm.snapshotState();
        _batchPostFresh(n);
        vm.revertToState(s);
        _batchPostReused(n);
        vm.revertToState(s);
        _batchReplace(n);
        vm.revertToState(s);
        _batchBidsReplace(n);
        vm.revertToState(s);
        _batchModifyAll(n);
        vm.revertToState(s);
        _batchCancelAll(n);
        vm.revertToState(s);
        _batchTakeAll(n);
        vm.revertToState(s);
    }

    function test_batches1() public {
        _batches(1);
    }

    function test_batches2() public {
        _batches(2);
    }

    function test_batches3() public {
        _batches(3);
    }

    function test_batches4() public {
        _batches(4);
    }

    /// One sub-order of a full slot: modified (moved up a tick), cancelled; the others untouched.
    function test_batch_one_of_four() public {
        uint256 snap = vm.snapshotState();
        address z = _maker();
        uint16 s = _slot();
        _post(z, s, false, T + 2, 4);
        uint256[4] memory o;
        o[1] = OloOps.sub(T + 7, 5 * LOT);
        vm.prank(z);
        _mb(c, OloOps.batchW(OloOps.MODIFY, false, s, 0, 0x2, o));
        _logR("batch4_modify_1");
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CANCEL, s, 0, 0x2));
        _logR("batch4_cancel_1");
        vm.revertToState(snap);
    }

    /// `n` orders (a multiple of 4) as n / 4 slots, one transaction a slot: posted fresh, moved up a tick by
    /// replaces, cancelled, the receipts summed.
    function _slotsLadder(uint256 n) internal {
        uint256 snap = vm.snapshotState();
        address z = _maker();
        uint16 s0 = _slot();
        nextSlot += uint16(n / 4);
        string memory k = string.concat("batch", vm.toString(n), "_as_", vm.toString(n / 4), "_slots");
        uint256 g;
        for (uint256 j; j < n / 4; ++j) {
            _post(z, s0 + uint16(j), false, T + 2 + 4 * j, 4);
            g += _receipt();
        }
        console2.log(string.concat("GAS mv_", k, "_post_fresh"), g);
        console2.log(string.concat("GAS mv_", k, "_post_fresh_per_order"), g / n);
        g = 0;
        for (uint256 j; j < n / 4; ++j) {
            vm.prank(z);
            _mb(c, _ladderW(OloOps.REPLACE, false, s0 + uint16(j), T + 3 + 4 * j, 4));
            g += _receipt();
        }
        console2.log(string.concat("GAS mv_", k, "_replace_up1"), g);
        console2.log(string.concat("GAS mv_", k, "_replace_up1_per_order"), g / n);
        g = 0;
        for (uint256 j; j < n / 4; ++j) {
            vm.prank(z);
            _mb(c, OloOps.maskW(OloOps.CANCEL, s0 + uint16(j), 0, 0xf));
            g += _receipt();
        }
        console2.log(string.concat("GAS mv_", k, "_cancel_all"), g);
        console2.log(string.concat("GAS mv_", k, "_cancel_all_per_order"), g / n);
        vm.revertToState(snap);
    }

    function test_batch_ladders_as_slots() public {
        _slotsLadder(8);
        _slotsLadder(12);
        _slotsLadder(24);
    }

    /// `n` asks and `n` bids (four a slot) each moved one tick up: a replace a slot, one transaction each, the
    /// receipts summed (a contract wallet or an EIP-7702 account sends them in one transaction: GasBench7702).
    function _twoSided(uint256 n) internal {
        address z = _maker();
        uint16 s0 = _slot();
        nextSlot += uint16(2 * n / 4);
        uint256 slots = n / 4;
        for (uint256 j; j < slots; ++j) {
            _post(z, s0 + uint16(j), false, T + 2 + 4 * j, 4);
            _post(z, s0 + uint16(slots + j), true, T - 2 - 4 * j, 4);
        }
        uint256 g;
        for (uint256 j; j < slots; ++j) {
            vm.prank(z);
            _mb(c, _ladderW(OloOps.REPLACE, false, s0 + uint16(j), T + 3 + 4 * j, 4));
            g += _receipt();
            vm.prank(z);
            uint16 sb = s0 + uint16(slots + j);
            _mb(c, _ladderW(OloOps.REPLACE, true, sb, T - 1 - 4 * j, 4));
            g += _receipt();
        }
        string memory k = string.concat("batch_requote_two_sided_", vm.toString(2 * n));
        console2.log(string.concat("GAS mv_", k), g);
        console2.log(string.concat("GAS mv_", k, "_per_order"), g / (2 * n));
    }

    function test_batch_two_sided() public {
        uint256 snap = vm.snapshotState();
        _twoSided(4);
        vm.revertToState(snap);
        _twoSided(12);
        vm.revertToState(snap);
        _twoSided(24);
        vm.revertToState(snap);
    }

    /// 10 retail asks and a maker's 10 asks in three slots (4, 4, 2), one take across both kinds.
    function test_take_mixed_10_10() public {
        uint32 from = _block(10);
        for (uint256 i; i < 10; ++i) {
            address a = _maker();
            vm.prank(a);
            book.place(OloOps.key(c), OloOps.placeW(false, T + 1 + i, 5 * LOT, from + uint32(i), 0));
        }
        address z = _maker();
        uint16 s = _slot();
        nextSlot += 2;
        _post(z, s, false, T + 11, 4);
        _post(z, s + 1, false, T + 15, 4);
        _post(z, s + 2, false, T + 19, 2);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            bytes.concat(
                OloOps.poolList(OloOps.poolEntries(from, 10, T + 1, 1)),
                OloOps.batchList(
                    bytes.concat(
                        OloOps.slotGroupAt(z, s, 0xf, T + 20),
                        OloOps.slotGroupAt(z, s + 1, 0xf, T + 20),
                        OloOps.slotGroupAt(z, s + 2, 0x3, T + 20)
                    )
                )
            ),
            OloOps.tagW(c, OloOps.takeW(true, 100 * LOT, 0))
        );
        _log("take_mixed_10_pool_10_batch", _gas());
    }

    /// A take naming a full slot whose maker moved every sub-order past the taker's ticks before the take lands: each
    /// sub-order is skipped and the taker pays for the group. Against a take of an empty list, the difference is the
    /// group's cost: its calldata (logged apart, 16 a nonzero byte and 4 a zero one) and its execution.
    function test_take_batches_pulled() public {
        address z = _maker();
        uint16 s = _slot();
        _post(z, s, false, T + 2, 4);
        vm.prank(z);
        _mb(c, _ladderW(OloOps.REPLACE, false, s, T + 10, 4));
        bytes memory list = OloOps.batchList(OloOps.slotGroup(z, s, 0xf, [T + 2, T + 3, T + 4, T + 5]));
        vm.prank(taker);
        (uint256 f,) = book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, 20 * LOT, 0)));
        assertEq(f, 0);
        _log("take_batches_pulled_4", _gas());
        vm.prank(taker);
        book.take(OloOps.key(c), "", OloOps.tagW(c, OloOps.takeW(true, 20 * LOT, 0)));
        _log("take_empty_list", _gas());
        uint256 cd;
        for (uint256 i; i < list.length; ++i) {
            cd += list[i] == 0 ? 4 : 16;
        }
        _log("take_batches_pulled_4_list_calldata", cd);
        _log("take_batches_pulled_4_list_bytes", list.length);
    }

    /// `k` makers with a slot of `per` sub-orders each; the take sweeps all of them.
    function _takeBatchesFrom(uint256 k, uint256 per) internal {
        bytes memory groups;
        for (uint256 i; i < k; ++i) {
            address z = _maker();
            uint16 s = _slot();
            _post(z, s, false, T + 2, per);
            groups = bytes.concat(groups, OloOps.slotGroupAt(z, s, uint8((1 << per) - 1), T + 5));
        }
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.batchList(groups), OloOps.tagW(c, OloOps.takeW(true, (5 * k * per) * LOT, 0)));
        _log(string.concat("take_batches_N", vm.toString(k * per), "_from_", vm.toString(k)), _gas());
    }

    function test_take_batches_spread() public {
        uint256 s = vm.snapshotState();
        _takeBatchesFrom(5, 1);
        vm.revertToState(s);
        _takeBatchesFrom(2, 4);
        vm.revertToState(s);
        _takeBatchesFrom(5, 4);
        vm.revertToState(s);
        _takeBatchesFrom(6, 4);
        vm.revertToState(s);
        _takeBatchesFrom(10, 4);
        vm.revertToState(s);
        _takeBatchesFrom(24, 4);
        vm.revertToState(s);
    }

    /// 2 lots from a slot of 4 (the row take_internal_buy2 compares with), the wallet's twin, and a claim of the two
    /// part-filled sub-orders.
    function test_take_batches_buy2() public {
        address z = _maker();
        uint16 s = _slot();
        _post(z, s, false, T + 2, 4);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, s, 0x1, T + 2)),
            OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0))
        );
        _log("take_batches_buy2", _gas());
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, s, 0x2, T + 3)),
            OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 1))
        );
        _log("take_batches_wallet_buy2", _gas());
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CLAIM, s, 0, 0));
        _log("batch_claim_two_part_filled", _gas());
        _logR("batch_claim_two_part_filled");
    }

    /// A take of all four sub-orders after an earlier take left one part-filled.
    function test_take_batches_after_partial() public {
        address z = _maker();
        uint16 s = _slot();
        _post(z, s, false, T + 2, 4);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, s, 0x1, T + 2)),
            OloOps.tagW(c, OloOps.takeW(true, 1 * LOT, 0))
        );
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, s, 0xf, T + 5)),
            OloOps.tagW(c, OloOps.takeW(true, 19 * LOT, 0))
        );
        _log("take_batches_N4_after_1_partial", _gas());
    }

    /// A single order as a slot of one: the rows the pool single operations compare with.
    function test_batch_of_one_rows() public {
        address z = _maker();
        uint16 s = _slot();
        _post(z, s, false, T + 5, 1);
        _log("batch1_post_fresh", _gas());
        _logR("batch1_post_fresh");
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CANCEL, s, 0, 0x1));
        _log("batch1_cancel_open", _gas());
        _logR("batch1_cancel_open");
        _post(z, s, false, T + 5, 1);
        _log("batch1_post_reused", _gas());
        _logR("batch1_post_reused");
        vm.prank(z);
        _mb(c, _ladderW(OloOps.REPLACE, false, s, T + 6, 1));
        _log("batch1_replace", _gas());
        _logR("batch1_replace");
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, s, 0x1, T + 6)),
            OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0))
        );
        _log("take_batches_N1_one_batch", _gas());
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CLAIM, s, 0, 0));
        _log("batch1_claim_filled", _gas());
        _logR("batch1_claim_filled");
        address wo = address(0xABCD02);
        base.mint(wo, 1e30);
        vm.startPrank(wo);
        base.approve(address(book), type(uint256).max);
        _mb(c, OloOps.ladderW(OloOps.POST, false, _slot(), 2, T + 5, 5 * LOT, 1, 1));
        vm.stopPrank();
        _log("batch1_post_wallet_fresh", _gas());
    }

    function test_batch_extra_cells() public {
        uint256 snap = vm.snapshotState();
        address z = _maker();
        uint16 s = _slot();
        _post(z, s, false, T + 5, 1);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, s, 0x1, T + 5)),
            OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0))
        );
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CANCEL, s, 0, 0x1));
        _log("batch1_cancel_part_filled", _gas());
        vm.revertToState(snap);
        book.setMarketMakerShare(m, 8_000);
        c = book.configOf(m); // the new version, where the orders below rest
        address w = _plain(T + 2, false, 1 * LOT);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(w)), OloOps.tagW(c, OloOps.takeW(true, 1 * LOT, 0)));
        z = _maker();
        s = _slot();
        _post(z, s, false, T + 2, 4);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, s, 0x1, T + 2)),
            OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0))
        );
        _log("take_batches_buy2_protocol_share", _gas());
        vm.prank(z);
        _mb(c, OloOps.maskW(OloOps.CLAIM, s, 0, 0));
        _log("batch_claim_protocol_share", _gas());
        vm.revertToState(snap);
    }
}
