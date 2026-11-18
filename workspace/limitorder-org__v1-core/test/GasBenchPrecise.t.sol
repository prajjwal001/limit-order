// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

/// Gas of the rows the precise-fills model adds or changes, `forge test --isolate --match-contract GasBenchPrecise -vv
/// | grep GAS`: main's GasBenchSubs on an ETH/USDC-like market (WETH 18 decimals, USDC 6, ETH at $2,329.12; main's lot
/// was 1e11 wei, so k lots are k x 1e11 wei here, and these amounts are q 6 orders), a take ending inside a q 10 order,
/// and takes over two orders in one decade and across a decade boundary. Their twins on the lot model's API measured
/// what precise fills changed.
contract GasBenchPrecise is OloBase {
    MockERC20 weth;
    MarketWord ce;
    uint256 constant P = 26_232_912; // P = 232_912e-14: $2,329.12 (main GasBenchSubs' div3 market)
    uint256 constant L = 1e11; // main's lot there
    address a;

    function setUp() public {
        _deploy();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        ce = book.configOf(book.listMarketQuote(address(weth), address(quote), 50, 6, 1, 0));
        weth.mint(taker, 1e24);
        vm.startPrank(taker);
        weth.approve(address(book), type(uint256).max);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        book.deposit(address(weth), 1e22);
        vm.stopPrank();
        a = _maker();
        weth.mint(a, 1e24);
        vm.startPrank(a);
        weth.approve(address(book), type(uint256).max);
        book.deposit(address(weth), 1e22);
        // a written pot and positions the maker's own orders freed
        book.place(OloOps.key(ce), OloOps.placeW(false, P, 5_000 * L, 1, 0));
        vm.stopPrank();
        vm.prank(taker);
        book.take(
            OloOps.key(ce), OloOps.poolList(OloOps.poolEntry(1, P)), OloOps.tagW(ce, OloOps.takeW(true, 5_000 * L, 0))
        );
        vm.prank(a);
        book.claim(OloOps.key(ce), OloOps.tagW(ce, OloOps.posW(1, 0)));
    }

    /// main GasBenchSubs' `_rows`, the same sizes in wei.
    function test_rows_eth() public {
        MarketWord mc = ce;
        uint256 tk = P;
        string memory sfx = "eth";
        vm.prank(a);
        book.place(OloOps.key(mc), OloOps.placeW(true, tk - 1, 7_000 * L, 1, 0));
        _log(string.concat("place_bid_", sfx), _gas());
        vm.prank(a);
        book.place(OloOps.key(mc), OloOps.placeW(false, tk + 1, 7_000 * L, 2, 0));
        _log(string.concat("place_ask_", sfx), _gas());
        vm.prank(taker);
        book.take(
            OloOps.key(mc),
            OloOps.poolList(OloOps.poolEntry(2, tk + 1)),
            OloOps.tagW(mc, OloOps.takeW(true, 3_000 * L, 0))
        );
        _log(string.concat("take_buy_", sfx), _gas());
        vm.prank(taker);
        book.take(
            OloOps.key(mc),
            OloOps.poolList(OloOps.poolEntry(1, tk - 1)),
            OloOps.tagW(mc, OloOps.takeW(false, 3_000 * L, 0))
        );
        _log(string.concat("take_sell_", sfx), _gas());
        vm.prank(a);
        book.claim(OloOps.key(mc), OloOps.tagW(mc, OloOps.posW(2, 0)));
        _log(string.concat("claim_ask_", sfx), _gas());
        vm.prank(a);
        book.modify(OloOps.key(mc), OloOps.tagW(mc, OloOps.modifyW(1, tk - 2, 6_000 * L, 0)));
        _log(string.concat("modify_bid_filled_", sfx), _gas());
        vm.prank(a);
        book.cancel(OloOps.key(mc), OloOps.tagW(mc, OloOps.posW(1, 0)));
        _log(string.concat("cancel_bid_", sfx), _gas());
        vm.prank(a);
        book.cancel(OloOps.key(mc), OloOps.tagW(mc, OloOps.posW(2, 0)));
        _log(string.concat("cancel_ask_", sfx), _gas());
        vm.prank(a);
        _mb(mc, OloOps.postW(true, 0, tk - 1, 4_000 * L, 4));
        _log(string.concat("batch4_post_bids_", sfx), _gas());
        vm.prank(a);
        _mb(mc, OloOps.postW(false, 1, tk + 1, 4_000 * L, 4));
        _log(string.concat("batch4_post_asks_", sfx), _gas());
        vm.prank(taker);
        book.take(
            OloOps.key(mc),
            OloOps.batchList(OloOps.slotGroupAt(a, 1, 0xf, tk + 4)),
            OloOps.tagW(mc, OloOps.takeW(true, 10_000 * L, 0))
        );
        _log(string.concat("take_batch_buy10_", sfx), _gas());
        vm.prank(taker);
        book.take(
            OloOps.key(mc),
            OloOps.batchList(OloOps.slotGroupAt(a, 0, 0xf, tk - 4)),
            OloOps.tagW(mc, OloOps.takeW(false, 10_000 * L, 0))
        );
        _log(string.concat("take_batch_sell10_", sfx), _gas());
        vm.prank(a);
        _mb(mc, OloOps.maskW(OloOps.CANCEL, 0, 0, 0xf));
        _log(string.concat("batch4_cancel_bids_", sfx), _gas());
        vm.prank(a);
        _mb(mc, OloOps.maskW(OloOps.CANCEL, 1, 0, 0xf));
        _log(string.concat("batch4_cancel_asks_", sfx), _gas());
    }

    /// A take ending inside a q 10 order: 1.234567891234 ETH resting (123,456,789 units of 1e10 wei), a buy of 0.5 ETH
    /// and 7 wei (the 7 wei left), then the order's claim. Main's twin: 12,345,678 lots, a buy of 5,000,000.
    function test_take_inside_q_order_eth() public {
        vm.prank(a);
        book.place(OloOps.key(ce), OloOps.placeW(false, P + 1, 1_234_567_891_234_000_000, 3, 0));
        vm.prank(taker);
        book.take(
            OloOps.key(ce),
            OloOps.poolList(OloOps.poolEntry(3, P + 1)),
            OloOps.tagW(ce, OloOps.takeW(true, 5e17 + 7, 0))
        );
        _log("take_buy_inside_q_order_eth", _gas());
        vm.prank(a);
        book.claim(OloOps.key(ce), OloOps.tagW(ce, OloOps.posW(3, 0)));
        _log("claim_q_order_eth", _gas());
    }

    /// Two asks (bids) of 5 LOT, one in each decade either side of T (T - 1 in decade 37, T + 1 in decade 38), a take of
    /// both; and the same over two ticks of one decade. Main's twin: the same ticks there (decades 0 and 1 of its grid).
    function test_take_two_decades() public {
        uint256 snap = vm.snapshotState();
        address x = _plain(T - 1, false, 5 * LOT);
        address y = _plain(T + 1, false, 5 * LOT);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(bytes.concat(_poolEntry(x), _poolEntry(y))),
            OloOps.tagW(c, OloOps.takeW(true, 10 * LOT, 0))
        );
        _log("take_buy_2_orders_2_decades", _gas());
        vm.revertToState(snap);
        x = _plain(T + 1, false, 5 * LOT);
        y = _plain(T + 2, false, 5 * LOT);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(bytes.concat(_poolEntry(x), _poolEntry(y))),
            OloOps.tagW(c, OloOps.takeW(true, 10 * LOT, 0))
        );
        _log("take_buy_2_orders_1_decade", _gas());
        vm.revertToState(snap);
        // a sell, the higher decade first: the sum scales down a decade on the second fill
        x = _plain(T + 1, true, 5 * LOT);
        y = _plain(T - 1, true, 5 * LOT);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(bytes.concat(_poolEntry(x), _poolEntry(y))),
            OloOps.tagW(c, OloOps.takeW(false, 10 * LOT, 0))
        );
        _log("take_sell_2_orders_2_decades", _gas());
        vm.revertToState(snap);
    }
}
