// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {OloOps} from "./OloOps.sol";
import {TakeRef} from "./TakeRef.sol";
import {BatchExecutor} from "./GasBench7702.t.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IOloBook} from "../src/interfaces/IOloBook.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {SafeTransfer} from "../src/libraries/SafeTransfer.sol";
import {PoolWord} from "../src/OloTypes.sol";

using MarketLib for MarketWord;

interface IERC20Like {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// A router's four swaps over the OLO EVM contract, the way an aggregator would write them (test-only, not part of the
/// OLO EVM contract): it takes the input from the user, takes from the OLO EVM contract through its wallet (WALLET),
/// checks the user's bound, pays out and refunds what is left. The OLO EVM contract's part is one `take`: base mode for
/// the base-sized swaps, quote mode for the quote-sized ones, fill-or-kill with a tolerance in the amount's unit; the
/// min out / max in is the router's.
contract TestRouter {
    error Slippage();

    IOloBook public immutable book;

    constructor(IOloBook book_) {
        book = book_;
    }

    function _tokens(MarketWord c) internal view returns (IERC20Like b, IERC20Like q) {
        b = IERC20Like(book.tokenAddr(c.baseId()));
        q = IERC20Like(book.tokenAddr(c.quoteId()));
    }

    function _take(MarketWord c, uint256 params, bytes calldata list, IERC20Like tokenIn)
        internal
        returns (uint256 base, uint256 quote)
    {
        tokenIn.approve(address(book), type(uint256).max);
        (base, quote) = book.take(OloOps.key(c), list, OloOps.tagW(c, params));
    }

    /// Sell exactly `baseIn` (up to `maxLeft` base unsold, refunded) for at least `minQuoteOut`.
    function exactInBase(MarketWord c, bytes calldata list, uint256 baseIn, uint256 minQuoteOut, uint256 maxLeft)
        external
        returns (uint256 quoteOut)
    {
        (IERC20Like b, IERC20Like q) = _tokens(c);
        b.transferFrom(msg.sender, address(this), baseIn);
        uint256 sold;
        (sold, quoteOut) = _take(c, OloOps.fokW(false, baseIn, OloOps.WALLET, maxLeft), list, b);
        if (quoteOut < minQuoteOut) revert Slippage();
        q.transfer(msg.sender, quoteOut);
        if (baseIn > sold) b.transfer(msg.sender, baseIn - sold);
    }

    /// Buy exactly `baseOut` (up to `maxLeft` short) for at most `maxQuoteIn`.
    function exactOutBase(MarketWord c, bytes calldata list, uint256 baseOut, uint256 maxQuoteIn, uint256 maxLeft)
        external
        returns (uint256 quoteIn)
    {
        (IERC20Like b, IERC20Like q) = _tokens(c);
        q.transferFrom(msg.sender, address(this), maxQuoteIn);
        uint256 bought;
        (bought, quoteIn) = _take(c, OloOps.fokW(true, baseOut, OloOps.WALLET, maxLeft), list, q);
        if (quoteIn > maxQuoteIn) revert Slippage();
        b.transfer(msg.sender, bought);
        q.transfer(msg.sender, maxQuoteIn - quoteIn);
    }

    /// Spend exactly `quoteIn` (up to `maxLeft` quote unspent, refunded) for at least `minBaseOut`.
    function exactInQuote(MarketWord c, bytes calldata list, uint256 quoteIn, uint256 minBaseOut, uint256 maxLeft)
        external
        returns (uint256 baseOut)
    {
        (IERC20Like b, IERC20Like q) = _tokens(c);
        q.transferFrom(msg.sender, address(this), quoteIn);
        uint256 spent;
        (baseOut, spent) = _take(c, OloOps.fokW(true, quoteIn, OloOps.WALLET | OloOps.QUOTE, maxLeft), list, q);
        if (baseOut < minBaseOut) revert Slippage();
        b.transfer(msg.sender, baseOut);
        if (quoteIn > spent) q.transfer(msg.sender, quoteIn - spent);
    }

    /// Receive up to `quoteOut`, at most `maxLeft` short of it, for at most `maxBaseIn`: a quote-mode sell approximates
    /// its amount from below (a sell that must receive an exact amount is a base-mode take of the base the caller
    /// computes).
    function exactOutQuote(MarketWord c, bytes calldata list, uint256 quoteOut, uint256 maxBaseIn, uint256 maxLeft)
        external
        returns (uint256 baseIn)
    {
        (IERC20Like b, IERC20Like q) = _tokens(c);
        b.transferFrom(msg.sender, address(this), maxBaseIn);
        uint256 received;
        (baseIn, received) = _take(c, OloOps.fokW(false, quoteOut, OloOps.WALLET | OloOps.QUOTE, maxLeft), list, b);
        if (baseIn > maxBaseIn) revert Slippage();
        q.transfer(msg.sender, received);
        b.transfer(msg.sender, maxBaseIn - baseIn);
    }
}

/// The OLO EVM contract end to end: deployed as it ships (the hirun artifacts) and set up as the deploy script sets up
/// BSC testnet (its four markets on mocks of its tokens, a global maker share, then a listing fee), then used the way
/// integrators will: a router's
/// four swaps (exact in and exact out, sized in base and in quote) quoted against the OLO Book and run
/// after the OLO Book moved (orders taken by someone else, repriced worse or better, cancelled), fill-or-kill
/// tolerances, a takeThenRest, and EIP-7702 accounts batching their approvals, takes, rests and withdrawals in one
/// transaction.
contract OloIntegrationTest is Test {
    address constant TBTC = 0x3f1f66C58952D4436d58DE75a6A9578E8a80B36F;
    address constant TUSDC = 0x66c020A86f140f05787A0c2F33499DD16F1a241b;
    address constant TUSDT = 0x924495937391E2a5169548c8e63694523CE5eB4A;
    address constant TMEME = 0x9dB4772FBef97Df68C7fA1324ECc09039F9Feca0;
    uint256 constant DEPLOYER_PK = 0xD3B10E;
    string constant BOOK = "out-hirun/OloBook.sol/OloBook.json";
    string constant EXT = "out-hirun/OloBookExt.sol/OloBookExt.json";
    /// tBTC at $100,000: 1,000 quote wei a sat (decade 41); tMEME at $0.0001: 1e-16 quote wei a wei (decade 22).
    uint256 constant BTC_100K = 36_900_000;
    uint256 constant MEME = 19_800_000;

    IOloBook book;
    TestRouter router;
    MarketWord btcUsdc; // 1,200 ppm, 6 figures, minQuote 1 tUSDC
    MarketWord memeUsdc; // 1,300 ppm, 4 figures, minQuote 1 tUSDC
    address deployer;
    address[3] makers;
    address user = address(0x5E1);
    address rival = address(0x41A1);

    /// MockERC20's code at a fixed address (BSC testnet's) with its decimals (slot 2) set.
    function _token(address where, uint8 decimals) internal {
        MockERC20 m = new MockERC20("t", "t", decimals);
        vm.etch(where, address(m).code);
        vm.store(where, bytes32(uint256(2)), bytes32(uint256(decimals)));
    }

    function setUp() public {
        vm.chainId(97);
        _token(TBTC, 8);
        _token(TUSDC, 6);
        _token(TUSDT, 18);
        _token(TMEME, 18);
        deployer = vm.addr(DEPLOYER_PK);
        // the OLO EVM contract and its extension as they ship, born with the script's global fee floor (1,000 ppm, 10
        // bps), then the deploy script's steps for BSC testnet: the global maker share, its four markets in its order
        // at its fees (64 positions warmed each), and the listing fee last
        bool hirun = vm.exists(BOOK) && vm.exists(EXT);
        vm.startPrank(deployer);
        address ext = hirun ? vm.deployCode(EXT) : vm.deployCode("OloBookExt.sol:OloBookExt");
        book = IOloBook(
            hirun
                ? vm.deployCode(BOOK, abi.encode(deployer, ext, 1000))
                : vm.deployCode("OloBook.sol:OloBook", abi.encode(deployer, ext, 1000))
        );
        book.setGlobalMakerShare(8000);
        book.listMarketQuote(TBTC, TUSDC, 1200, 6, 1e6, 64);
        book.listMarketQuote(TBTC, TUSDT, 1200, 5, 1e18, 64);
        book.listMarketQuote(TMEME, TUSDT, 1300, 6, 1e18, 64);
        book.listMarketQuote(TMEME, TUSDC, 1300, 4, 1e6, 64);
        book.setCurrentListingFee(1e15);
        vm.stopPrank();
        btcUsdc = book.configOf(1);
        memeUsdc = book.configOf(4);
        router = new TestRouter(book);
        for (uint256 i; i < 3; ++i) {
            makers[i] = address(uint160(0x3A0 + i));
            _fund(makers[i]);
        }
        _fund(user);
        _fund(rival);
    }

    function _fund(address a) internal {
        MockERC20(TBTC).mint(a, 1e20);
        MockERC20(TUSDC).mint(a, 1e24);
        MockERC20(TMEME).mint(a, 1e32);
        vm.startPrank(a);
        IERC20Like(TBTC).approve(address(book), type(uint256).max);
        IERC20Like(TUSDC).approve(address(book), type(uint256).max);
        IERC20Like(TMEME).approve(address(book), type(uint256).max);
        IERC20Like(TBTC).approve(address(router), type(uint256).max);
        IERC20Like(TUSDC).approve(address(router), type(uint256).max);
        IERC20Like(TMEME).approve(address(router), type(uint256).max);
        book.deposit(TBTC, 1e19);
        book.deposit(TUSDC, 1e23);
        book.deposit(TMEME, 1e31);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- the OLO Book's side of a quote

    /// Asks on tBTC/tUSDC: 0.1 BTC at $100,000, $100,010, $100,020 (pool), and a batch slot of 0.05 BTC at $100,030 ..
    /// $100,060; bids mirror them below $99,990.
    function _btcBook() internal returns (bytes memory asks, bytes memory bids) {
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(makers[i]);
            book.place(OloOps.key(btcUsdc), OloOps.placeW(false, BTC_100K + 10 * i, 1e7, uint32(i), 0));
            book.place(OloOps.key(btcUsdc), OloOps.placeW(true, BTC_100K - 10 - 10 * i, 1e7, uint32(10 + i), 0));
            vm.stopPrank();
            asks = bytes.concat(asks, OloOps.poolEntry(uint32(i), BTC_100K + 10 * i));
            bids = bytes.concat(bids, OloOps.poolEntry(uint32(10 + i), BTC_100K - 10 - 10 * i));
        }
        vm.startPrank(makers[0]);
        _mb(btcUsdc, OloOps.ladderW(OloOps.POST, false, 1, 0, BTC_100K + 30, 5e6, 4, 10));
        _mb(btcUsdc, OloOps.ladderW(OloOps.POST, true, 2, 0, BTC_100K - 40, 5e6, 4, 10));
        vm.stopPrank();
        asks = bytes.concat(
            OloOps.poolList(asks),
            OloOps.batchList(
                OloOps.slotGroup(
                    makers[0], 1, 0xf, [BTC_100K + 30, BTC_100K + 40, BTC_100K + 50, uint256(BTC_100K + 60)]
                )
            )
        );
        bids = bytes.concat(
            OloOps.poolList(bids),
            OloOps.batchList(
                OloOps.slotGroup(
                    makers[0], 2, 0xf, [BTC_100K - 40, BTC_100K - 50, BTC_100K - 60, uint256(BTC_100K - 70)]
                )
            )
        );
    }

    function _mb(MarketWord mc, uint256[3] memory w) internal {
        (bool ok, bytes memory ret) = address(book).call(OloOps.batchCalldata(book.manageBatchSubs.selector, mc, w));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// The caller's quote: what a take of these orders, in this order, would do now (TakeRef: the exact sum, quote
    /// mode's units by the specification).
    function _quote(TakeRef.Take memory t, uint256[] memory opens, uint256[] memory ticks)
        internal
        pure
        returns (uint256 base, uint256 quoteAmount)
    {
        TakeRef.Walk memory w;
        for (uint256 i; i < opens.length; ++i) {
            TakeRef.fill(w, t, opens[i], 0, ticks[i]);
        }
        (,, quoteAmount,) = TakeRef.finish(w, t);
        base = w.base;
    }

    function _askLadder() internal pure returns (uint256[] memory opens, uint256[] memory ticks) {
        opens = new uint256[](7);
        ticks = new uint256[](7);
        for (uint256 i; i < 3; ++i) {
            opens[i] = 1e7;
            ticks[i] = BTC_100K + 10 * i;
        }
        for (uint256 i; i < 4; ++i) {
            opens[3 + i] = 5e6;
            ticks[3 + i] = BTC_100K + 30 + 10 * i;
        }
    }

    function _bidLadder() internal pure returns (uint256[] memory opens, uint256[] memory ticks) {
        opens = new uint256[](7);
        ticks = new uint256[](7);
        for (uint256 i; i < 3; ++i) {
            opens[i] = 1e7;
            ticks[i] = BTC_100K - 10 - 10 * i;
        }
        for (uint256 i; i < 4; ++i) {
            opens[3 + i] = 5e6;
            ticks[3 + i] = BTC_100K - 40 - 10 * i;
        }
    }

    // ---------------------------------------------------------------- the four swaps, the OLO EVM contract unchanged

    /// Each swap as quoted: exact in base (sell 0.25 BTC), exact out base (buy 0.25 BTC), exact in quote (spend
    /// 30,000.123456 USDC), exact out quote (receive 30,000.123456 USDC). The router's bounds are the quote itself; the
    /// user's balances move by exactly the quote, and a quote-sized swap is within its amount by less than a sat's
    /// worth.
    function test_four_swaps_as_quoted() public {
        (bytes memory asks, bytes memory bids) = _btcBook();
        (uint256[] memory ao, uint256[] memory aTicks) = _askLadder();
        (uint256[] memory bo, uint256[] memory bt) = _bidLadder();
        uint256 snap = vm.snapshotState();
        // exact in base: sell 25,000,000 sat
        (, uint256 qOut) = _quote(TakeRef.Take(false, false, 25e6, 1200), bo, bt);
        uint256 u0 = IERC20Like(TUSDC).balanceOf(user);
        vm.prank(user);
        assertEq(router.exactInBase(btcUsdc, bids, 25e6, qOut, 0), qOut);
        assertEq(IERC20Like(TUSDC).balanceOf(user) - u0, qOut);
        vm.revertToState(snap);
        // exact out base: buy 25,000,000 sat
        (, uint256 qIn) = _quote(TakeRef.Take(true, false, 25e6, 1200), ao, aTicks);
        uint256 b0 = IERC20Like(TBTC).balanceOf(user);
        u0 = IERC20Like(TUSDC).balanceOf(user);
        vm.prank(user);
        assertEq(router.exactOutBase(btcUsdc, asks, 25e6, qIn, 0), qIn);
        assertEq(IERC20Like(TBTC).balanceOf(user) - b0, 25e6);
        assertEq(u0 - IERC20Like(TUSDC).balanceOf(user), qIn);
        vm.revertToState(snap);
        // exact in quote: spend 30,000.123456 USDC, what is left (less than a sat's worth) refunded
        (uint256 bOut, uint256 spent) = _quote(TakeRef.Take(true, true, 30_000_123_456, 1200), ao, aTicks);
        b0 = IERC20Like(TBTC).balanceOf(user);
        u0 = IERC20Like(TUSDC).balanceOf(user);
        vm.prank(user);
        assertEq(router.exactInQuote(btcUsdc, asks, 30_000_123_456, bOut, 30_000_123_456 - spent), bOut);
        assertEq(IERC20Like(TBTC).balanceOf(user) - b0, bOut);
        assertEq(u0 - IERC20Like(TUSDC).balanceOf(user), spent);
        assertLt(30_000_123_456 - spent, 1_100, "less than a sat with its fee and a wei");
        vm.revertToState(snap);
        // exact out quote: receive 30,000.123456 USDC at most, selling the base it takes
        (uint256 bIn, uint256 recv) = _quote(TakeRef.Take(false, true, 30_000_123_456, 1200), bo, bt);
        b0 = IERC20Like(TBTC).balanceOf(user);
        u0 = IERC20Like(TUSDC).balanceOf(user);
        vm.prank(user);
        assertEq(router.exactOutQuote(btcUsdc, bids, 30_000_123_456, bIn, 30_000_123_456 - recv), bIn);
        assertEq(b0 - IERC20Like(TBTC).balanceOf(user), bIn);
        assertEq(IERC20Like(TUSDC).balanceOf(user) - u0, recv);
        assertLe(recv, 30_000_123_456);
        assertLt(30_000_123_456 - recv, 1_002, "less than a sat less its fee and 2 wei");
    }

    // ---------------------------------------------------------------- races

    /// Between the quote and the swap the OLO Book moved: the best ask was taken by a rival, the next repriced worse,
    /// the batch slot's first sub-order repriced better, and the last pool ask cancelled. Each swap with a slippage
    /// bound (0.05%) still runs: the list names more than the quote needs, stale entries are skipped, the better price
    /// fills at its own tick; a swap with no slippage room reverts in the router, and a strict fill-or-kill in the
    /// OLO EVM contract when what is left can no longer fill.
    function test_swaps_after_the_book_moved() public {
        (bytes memory asks,) = _btcBook();
        (uint256[] memory ao, uint256[] memory aTicks) = _askLadder();
        (uint256 bOutQuoted,) = _quote(TakeRef.Take(true, true, 30_000_123_456, 1200), ao, aTicks);
        (, uint256 qInQuoted) = _quote(TakeRef.Take(true, false, 25e6, 1200), ao, aTicks);
        // the races
        vm.prank(rival);
        book.take(
            OloOps.key(btcUsdc),
            OloOps.poolList(OloOps.poolEntry(0, BTC_100K)),
            OloOps.tagW(btcUsdc, OloOps.takeW(true, 1e7, 0))
        );
        vm.prank(makers[1]);
        book.modify(OloOps.key(btcUsdc), OloOps.tagW(btcUsdc, OloOps.modifyW(1, BTC_100K + 100, 1e7, 0)));
        uint256[4] memory o;
        o[0] = OloOps.sub(BTC_100K + 5, 5e6);
        vm.prank(makers[0]);
        _mb(btcUsdc, OloOps.batchW(OloOps.MODIFY, false, 1, 0, 0x1, o));
        vm.prank(makers[2]);
        book.cancel(OloOps.key(btcUsdc), OloOps.tagW(btcUsdc, OloOps.posW(2, 0)));
        uint256 snap = vm.snapshotState();
        // exact out base with 0.05% room: 0.25 BTC from the slot (3 x 0.05 at 30-60 above, one at +5 now) is only 0.2:
        // fill-or-kill (strict) refuses the take
        vm.prank(user);
        vm.expectRevert(IOloBookBase.FokNotFilled.selector);
        router.exactOutBase(btcUsdc, asks, 25e6, qInQuoted * 10_005 / 10_000, 0);
        // a tolerance of 0.05 BTC short lets it through at 0.2 BTC
        vm.prank(user);
        uint256 qIn = router.exactOutBase(btcUsdc, asks, 25e6, qInQuoted * 10_005 / 10_000, 5e6);
        assertLe(qIn, qInQuoted * 10_005 / 10_000);
        vm.revertToState(snap);
        // exact in quote: the same USDC buys from what is left; the router's 0.05% bound on the base refuses it (only
        // 0.2 BTC is left of the 0.3 quoted), a 40% bound with a loose tolerance takes it
        vm.prank(user);
        vm.expectRevert(TestRouter.Slippage.selector);
        router.exactInQuote(btcUsdc, asks, 30_000_123_456, bOutQuoted * 9_995 / 10_000, 30_000_123_456);
        vm.prank(user);
        uint256 bOut = router.exactInQuote(btcUsdc, asks, 30_000_123_456, bOutQuoted * 6_000 / 10_000, 30_000_123_456);
        assertGe(bOut, bOutQuoted * 6_000 / 10_000);
        // the batch sub-order repriced better filled at its own tick: its fill is priced at $100,005
        (uint256 word,) = book.batchOf(btcUsdc, makers[0], 1);
        assertEq((word >> (2 + 31)) & ((1 << 30) - 1), 0, "the improved sub-order filled whole");
        vm.revertToState(snap);
        // a router bound with no room at all on exact out base: the router holds only the user's max in, so the OLO EVM
        // contract's pull of the dearer cost fails (the router's bound is the funds it gives the OLO EVM contract)
        vm.prank(user);
        vm.expectRevert(SafeTransfer.TransferFailed.selector);
        router.exactOutBase(btcUsdc, asks, 2e7, qInQuoted * 2e7 / 25e6 - 1, 0);
    }

    /// Fill-or-kill tolerances on quote-sized swaps: spending exactly the quote's cost leaves 0 (strict passes); a
    /// budget a few wei over the cost of whole sats leaves those wei, which a tolerance of that many accepts and one
    /// less refuses.
    function test_fill_or_kill_tolerance_on_quote_sized_swaps() public {
        (bytes memory asks,) = _btcBook();
        (uint256[] memory ao, uint256[] memory aTicks) = _askLadder();
        // 0.1 BTC at $100,000 with its fee (1,200 ppm): exactly 10,012 USDC
        (, uint256 cost) = _quote(TakeRef.Take(true, false, 1e7, 1200), ao, aTicks);
        assertEq(cost, 10_012_000_000);
        uint256 snap = vm.snapshotState();
        vm.prank(user);
        assertEq(router.exactInQuote(btcUsdc, asks, cost, 1e7, 0), 1e7, "an exact budget: strict passes");
        vm.revertToState(snap);
        vm.prank(user);
        assertEq(router.exactInQuote(btcUsdc, asks, cost + 7, 1e7, 7), 1e7, "7 wei over: 7 left");
        vm.revertToState(snap);
        vm.prank(user);
        vm.expectRevert(IOloBookBase.FokNotFilled.selector);
        router.exactInQuote(btcUsdc, asks, cost + 7, 1e7, 6);
    }

    // ---------------------------------------------------------------- takeThenRest

    /// A limit buy of 0.4 BTC up to $100,020 by the user itself (a router would own the rest): the three pool asks
    /// (listed alone: an entry is bounded by its own tick, not by the limit) fill 0.3 BTC and 0.1 rests as the user's
    /// bid at $100,020, escrowed with the take in one debit; a sell whose remainder is worth less than the market's 1
    /// USDC minimum keeps it.
    function test_take_then_rest() public {
        _btcBook();
        bytes memory asks = OloOps.poolList(OloOps.poolEntries(0, 3, BTC_100K, 10));
        uint256 u0 = book.balanceOf(book.tokenId(TUSDC), user);
        vm.prank(user);
        (uint256 got, uint256 paid,,) = book.takeThenRest(
            OloOps.key(btcUsdc), asks, OloOps.tagW(btcUsdc, OloOps.restW(true, 4e7, BTC_100K + 20, 0, 40))
        );
        assertEq(got, 3e7);
        (uint256 tick, uint256 open,, bool isBid, address owner) = book.orderOf(btcUsdc, 40);
        assertEq(tick, BTC_100K + 20);
        assertEq(open, 1e7);
        assertTrue(isBid);
        assertEq(owner, user);
        assertEq(u0 - book.balanceOf(book.tokenId(TUSDC), user), paid + PriceGrid.quoteUp(1e7, BTC_100K + 20));
        // a sell of 999 sat at $99,990 with nothing to take: worth 0.999 USDC, under the minimum: nothing rests
        vm.prank(user);
        (got,,,) = book.takeThenRest(
            OloOps.key(btcUsdc), "", OloOps.tagW(btcUsdc, OloOps.restW(false, 999, BTC_100K - 10, 0, 41))
        );
        assertEq(got, 0);
        assertFalse(PoolWord.wrap(book.orderWord(btcUsdc, 41)).isLive(), "the dust stays with the taker");
    }

    // ---------------------------------------------------------------- EIP-7702

    /// A wallet that delegates to a batch executor (EIP-7702, Prague) does in one transaction what takes several:
    /// approve, a quote-sized buy through the wallet, and a takeThenRest whose rest it later cancels; and deposit,
    /// take from the account and withdraw.
    function test_eip7702_flows() public {
        vm.setEvmVersion("prague");
        (bytes memory asks,) = _btcBook();
        BatchExecutor exec = new BatchExecutor();
        uint256 pk = 0x7702;
        address eoa = vm.addr(pk);
        MockERC20(TUSDC).mint(eoa, 1e12);
        MockERC20(TBTC).mint(eoa, 1e8);
        vm.signAndAttachDelegation(address(exec), pk);
        // approve, spend 5,000.1 USDC through the wallet, and rest a 0.05 BTC ask at $100,100, in one transaction
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](4);
        calls[0] = BatchExecutor.Call(TUSDC, 0, abi.encodeCall(IERC20Like.approve, (address(book), type(uint256).max)));
        calls[1] = BatchExecutor.Call(TBTC, 0, abi.encodeCall(IERC20Like.approve, (address(book), type(uint256).max)));
        calls[2] = BatchExecutor.Call(
            address(book),
            0,
            abi.encodeCall(
                book.take,
                (OloOps.key(btcUsdc), asks, OloOps.tagW(btcUsdc, OloOps.quoteW(true, 5_000_100_000, OloOps.WALLET)))
            )
        );
        calls[3] = BatchExecutor.Call(
            address(book),
            0,
            abi.encodeCall(
                book.takeThenRest,
                (
                    OloOps.key(btcUsdc),
                    "",
                    OloOps.tagW(btcUsdc, OloOps.restW(false, 5e6, BTC_100K + 100, OloOps.WALLET, 50))
                )
            )
        );
        uint256 u0 = IERC20Like(TUSDC).balanceOf(eoa);
        uint256 b0 = IERC20Like(TBTC).balanceOf(eoa);
        vm.prank(eoa, eoa);
        BatchExecutor(eoa).execute(calls);
        assertLe(u0 - IERC20Like(TUSDC).balanceOf(eoa), 5_000_100_000, "the quote-sized buy within its amount");
        // the rest is the wallet's own ask, escrowed from it; a later transaction cancels it back to the wallet
        (uint256 tick, uint256 open,,, address owner) = book.orderOf(btcUsdc, 50);
        assertEq(owner, eoa);
        assertEq(tick, BTC_100K + 100);
        assertEq(open, 5e6);
        uint256 b1 = IERC20Like(TBTC).balanceOf(eoa);
        calls = new BatchExecutor.Call[](1);
        calls[0] = BatchExecutor.Call(
            address(book),
            0,
            abi.encodeCall(book.cancel, (OloOps.key(btcUsdc), OloOps.tagW(btcUsdc, OloOps.posW(50, 2))))
        );
        vm.prank(eoa, eoa);
        BatchExecutor(eoa).execute(calls);
        assertEq(IERC20Like(TBTC).balanceOf(eoa) - b1, 5e6, "the ask's base back to the wallet");
        assertGt(IERC20Like(TBTC).balanceOf(eoa), b0, "and the bought base with it");
        // deposit, a base-sized buy from the account, and the base withdrawn, in one transaction
        b0 = IERC20Like(TBTC).balanceOf(eoa);
        calls = new BatchExecutor.Call[](3);
        calls[0] = BatchExecutor.Call(address(book), 0, abi.encodeCall(book.deposit, (TUSDC, 3_000_000_000)));
        calls[1] = BatchExecutor.Call(
            address(book),
            0,
            abi.encodeCall(book.take, (OloOps.key(btcUsdc), asks, OloOps.tagW(btcUsdc, OloOps.fokW(true, 2e6, 0, 0))))
        );
        calls[2] = BatchExecutor.Call(address(book), 0, abi.encodeCall(book.withdraw, (TBTC, 2e6)));
        vm.prank(eoa, eoa);
        BatchExecutor(eoa).execute(calls);
        assertEq(IERC20Like(TBTC).balanceOf(eoa) - b0, 2e6);
    }
}
