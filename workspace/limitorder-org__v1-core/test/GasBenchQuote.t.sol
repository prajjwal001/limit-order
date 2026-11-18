// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

/// Gas of quote-mode takes and of fill-or-kill with a tolerance (frame gas; `forge test --isolate --match-contract
/// GasBenchQuote -vv | grep GAS`), each beside its base-mode twin on the same OLO EVM contract: the fixture market
/// warmed as in GasBenchOlo (a past round, so the fee pot is written), orders of 5 LOT, taken from the account.
/// Quote-mode amounts are sized to stop short inside the last order, the case its arithmetic is for; the base-mode
/// twins take the same orders whole or to the same unit. Rows: one order and four, one decade and two (T - 1 and T + 1
/// straddle decade 38's bottom), a batch slot of four, an ETH-like market's q 6 orders (1e11 wei lots), fill-or-kill
/// with maxLeft.
contract GasBenchQuote is OloBase {
    MockERC20 weth;
    MarketWord ce;
    uint256 constant P = 26_232_912; // $2,329.12 on an 18/6 market
    uint256 constant L = 1e11;

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
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        ce = book.configOf(book.listMarketQuote(address(weth), address(quote), 50, 6, 1, 0));
        weth.mint(taker, 1e24);
        vm.startPrank(taker);
        weth.approve(address(book), type(uint256).max);
        book.deposit(address(weth), 1e22);
        vm.stopPrank();
    }

    /// `n` orders of 5 LOT from fresh makers at `tick`, `tick + step`, ... (asks for a buy, bids for a sell).
    function _orders(uint256 n, bool asks, uint256 tick, int256 step) internal returns (bytes memory entries) {
        for (uint256 i; i < n; ++i) {
            uint256 t = uint256(int256(tick) + step * int256(i));
            address a = _plain(t, !asks, 5 * LOT);
            entries = bytes.concat(entries, _poolEntry(a));
        }
    }

    /// A take of `entries` in base mode and in quote mode, each from the same state: the base row takes `baseAmt`, the
    /// quote row spends (or receives) `quoteAmt`.
    function _pair(string memory name, bool buy, bytes memory entries, uint256 baseAmt, uint256 quoteAmt) internal {
        uint256 s = vm.snapshotState();
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(buy, baseAmt, 0)));
        _log(string.concat("take_base_", name), _gas());
        vm.revertToState(s);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.quoteW(buy, quoteAmt, 0)));
        _log(string.concat("take_quote_", name), _gas());
        vm.revertToState(s);
    }

    /// One order: 3 LOT (base) against 3,000,123 quote wei (quote mode, stopping inside the order).
    function test_one_order() public {
        _pair("buy_1_order", true, _orders(1, true, T + 1, 0), 3 * LOT, 3_000_123);
        _pair("sell_1_order", false, _orders(1, false, T - 1, 0), 3 * LOT, 3_000_123);
    }

    /// Four orders a tick apart, the last one part-filled.
    function test_four_orders() public {
        _pair("buy_4_orders", true, _orders(4, true, T + 1, 1), 18 * LOT, 18_000_456);
        _pair("sell_4_orders", false, _orders(4, false, T - 1, -1), 18 * LOT, 17_900_456);
    }

    /// Two orders either side of decade 38's bottom: the quote-mode buy aligns its cap to decade 37 on the first fill,
    /// the sell re-aligns it there on the second.
    function test_two_decades() public {
        bytes memory e = bytes.concat(_orders(1, true, T - 1, 0), _orders(1, true, T + 1, 0));
        _pair("buy_2_decades", true, e, 8 * LOT, 8_000_123);
        e = bytes.concat(_orders(1, false, T + 1, 0), _orders(1, false, T - 1, 0));
        _pair("sell_2_decades", false, e, 8 * LOT, 7_990_123);
    }

    /// A batch slot of four asks a tick apart, taken in base mode and in quote mode.
    function test_batch_slot() public {
        address z = _maker();
        vm.prank(z);
        _mb(c, OloOps.postW(false, 0, T + 1, 5 * LOT, 4));
        bytes memory list = OloOps.batchList(OloOps.slotGroupAt(z, 0, 0xf, T + 4));
        uint256 s = vm.snapshotState();
        vm.prank(taker);
        book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, 18 * LOT, 0)));
        _log("take_base_batch4_buy", _gas());
        vm.revertToState(s);
        vm.prank(taker);
        book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.quoteW(true, 18_000_456, 0)));
        _log("take_quote_batch4_buy", _gas());
        vm.revertToState(s);
    }

    /// q 6 orders on the ETH-like market (two of 3,000 lots), a quote-mode buy of 10,000 USDC ending inside the second.
    function test_q_orders_eth() public {
        address a = _maker();
        weth.mint(a, 1e24);
        vm.startPrank(a);
        weth.approve(address(book), type(uint256).max);
        book.deposit(address(weth), 1e22);
        book.place(OloOps.key(ce), OloOps.placeW(false, P + 1, 3_000 * L, 1, 0));
        book.place(OloOps.key(ce), OloOps.placeW(false, P + 2, 3_000 * L, 2, 0));
        vm.stopPrank();
        bytes memory list = OloOps.poolList(bytes.concat(OloOps.poolEntry(1, P + 1), OloOps.poolEntry(2, P + 2)));
        uint256 s = vm.snapshotState();
        vm.prank(taker);
        book.take(OloOps.key(ce), list, OloOps.tagW(ce, OloOps.takeW(true, 4_500 * L, 0)));
        _log("take_base_buy_2_orders_eth", _gas());
        vm.revertToState(s);
        vm.prank(taker);
        book.take(OloOps.key(ce), list, OloOps.tagW(ce, OloOps.quoteW(true, 1e9, 0)));
        _log("take_quote_buy_2_orders_eth", _gas());
        vm.revertToState(s);
    }

    /// Fill-or-kill with a tolerance: base mode leaving 2 LOT of 20 within maxLeft, and quote mode leaving what a
    /// budget past the orders leaves, within maxLeft; each beside the same take without the bit.
    function test_fill_or_kill_max_left() public {
        bytes memory e = _orders(4, true, T + 1, 1);
        uint256 s = vm.snapshotState();
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(e), OloOps.tagW(c, OloOps.takeW(true, 20 * LOT, 0)));
        _log("take_base_buy_4_orders_whole", _gas());
        vm.revertToState(s);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(e), OloOps.tagW(c, OloOps.fokW(true, 22 * LOT, 0, 2 * LOT)));
        _log("take_fok_maxleft_base_buy_4_orders", _gas());
        vm.revertToState(s);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(e),
            OloOps.tagW(c, OloOps.takeW(true, 21_000_000, OloOps.QUOTE | OloOps.FOK, 1_000_000))
        );
        _log("take_fok_maxleft_quote_buy_4_orders", _gas());
        vm.revertToState(s);
    }
}
