// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {OloBook} from "../src/OloBook.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {IOloBookExt} from "../src/interfaces/IOloBookExt.sol";
import {IOloFlashCallback} from "../src/interfaces/IOloFlashCallback.sol";
import {IOloMarketPolicy} from "../src/interfaces/IOloMarketPolicy.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {PoolWord} from "../src/OloTypes.sol";

/// A flash's caller for the tests: `run` starts a flash whose callback runs a program of steps, each a call the
/// borrower makes as itself (on the OLO EVM contract when the step's target is zero), a failure reverting the flash
/// unless the step tolerates it (then counted in `caught`); `exec` and `execSteps` make calls outside a flash. It
/// records what the last callback saw, and checks its caller as IOloFlashCallback asks.
contract FlashBorrower is IOloFlashCallback {
    struct Step {
        address target; // zero: the OLO EVM contract
        bool tolerate; // a failure is caught and counted, not bubbled
        bytes call;
    }

    error NotBook();

    OloBook public immutable book;
    address public seenSender;
    address public seenToken;
    uint256 public seenAmount;
    uint256 public seenBalance; // the account's balance of the token inside the callback, before the program
    uint256 public callbacks;
    uint256 public caught;

    constructor(OloBook book_) {
        book = book_;
    }

    function approve(address token) external {
        MockERC20(token).approve(address(book), type(uint256).max);
    }

    function run(address token, uint256 amount, Step[] calldata steps) external {
        book.flash(token, amount, abi.encode(steps));
    }

    function exec(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = address(book).call(data);
        if (!ok) _bubble(ret);
        return ret;
    }

    function execSteps(Step[] calldata steps) external {
        _runSteps(steps);
    }

    function oloFlashCallback(address token, uint256 amount, bytes calldata data) external {
        if (msg.sender != address(book)) revert NotBook();
        ++callbacks;
        seenSender = msg.sender;
        seenToken = token;
        seenAmount = amount;
        seenBalance = book.balanceOf(book.tokenId(token), address(this));
        _runSteps(abi.decode(data, (Step[])));
    }

    function _runSteps(Step[] memory steps) internal {
        for (uint256 i; i < steps.length; ++i) {
            address target = steps[i].target == address(0) ? address(book) : steps[i].target;
            (bool ok, bytes memory ret) = target.call(steps[i].call);
            if (ok) continue;
            if (steps[i].tolerate) ++caught;
            else _bubble(ret);
        }
    }

    function _bubble(bytes memory ret) internal pure {
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }
}

/// A flash's caller that calls the extension directly and takes any callback, noting who made it.
contract ExtFlashCaller is IOloFlashCallback {
    address public seen;

    function go(IOloBookExt ext, address token) external {
        ext.flash(token, 1, "");
    }

    function oloFlashCallback(address, uint256, bytes calldata) external {
        seen = msg.sender;
    }
}

/// A proprietary market's policy that admits nobody.
contract RefuseAll is IOloMarketPolicy {
    function admitted(uint32, address, bool) external pure returns (bool) {
        return false;
    }
}

/// `flash`: a credit to the caller's account, its callback, the debit back (the repayment). On the fixture market (P 1
/// at T, 50 ppm, maker share 100%), a LOT is 1e6 base wei.
contract OloFlashTest is OloBase {
    /// a buy of 1 LOT at T: 1,000,000 and a fee of 50
    uint256 constant BUY_COST = 1_000_050;

    /// The fixture, and a maker's deposit of 1e24 of each token: what the contract holds, which a withdrawal draws on.
    function setUp() public {
        _deploy();
        _maker();
    }

    // ---------------------------------------------------------------- helpers

    /// A borrower approved to the OLO EVM contract, leaving with everyone (`_everyoneLeaves`).
    function _fb() internal returns (FlashBorrower f) {
        f = new FlashBorrower(book);
        f.approve(address(base));
        f.approve(address(quote));
        makers.push(address(f));
    }

    /// `amount` of `t` into `f`'s account (minted to its wallet, then deposited).
    function _fund(FlashBorrower f, MockERC20 t, uint256 amount) internal {
        t.mint(address(f), amount);
        f.exec(abi.encodeCall(book.deposit, (address(t), amount)));
    }

    function _none() internal pure returns (FlashBorrower.Step[] memory) {
        return new FlashBorrower.Step[](0);
    }

    /// Calls on the OLO EVM contract, each failure bubbling.
    function _steps(bytes memory a) internal pure returns (FlashBorrower.Step[] memory s) {
        s = new FlashBorrower.Step[](1);
        s[0] = FlashBorrower.Step(address(0), false, a);
    }

    function _steps(bytes memory a, bytes memory b) internal pure returns (FlashBorrower.Step[] memory s) {
        s = new FlashBorrower.Step[](2);
        s[0] = FlashBorrower.Step(address(0), false, a);
        s[1] = FlashBorrower.Step(address(0), false, b);
    }

    function _wd(MockERC20 t, uint256 amount) internal view returns (bytes memory) {
        return abi.encodeCall(book.withdraw, (address(t), amount));
    }

    function _dep(MockERC20 t, uint256 amount) internal view returns (bytes memory) {
        return abi.encodeCall(book.deposit, (address(t), amount));
    }

    function _flashCall(MockERC20 t, uint256 amount, FlashBorrower.Step[] memory s)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(book.flash, (address(t), amount, abi.encode(s)));
    }

    /// A buy (or a sell) of `amount` from (or to) maker `a`'s `_plain` order, on the caller's accounts.
    function _take(address a, bool buy, uint256 amount) internal view returns (bytes memory) {
        return abi.encodeCall(
            book.take, (OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(buy, amount, 0)))
        );
    }

    function _claim(address a) internal {
        vm.prank(a);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], 0)));
    }

    // ------------------------------------------------------------ the credit

    function test_flash_credits_then_debits_back() public {
        FlashBorrower f = _fb();
        _fund(f, quote, 5);
        uint256 held = quote.balanceOf(address(book));
        f.run(address(quote), LOT, _none());
        assertEq(f.callbacks(), 1);
        assertEq(f.seenSender(), address(book), "called back by the OLO EVM contract");
        assertEq(f.seenToken(), address(quote));
        assertEq(f.seenAmount(), LOT);
        assertEq(f.seenBalance(), LOT + 5, "the credit on the account inside the callback");
        assertEq(_bal(address(f), quote), 5, "debited back");
        assertEq(quote.balanceOf(address(book)), held, "no token moved");
    }

    function test_flash_logs_after_the_callback() public {
        address a = _plain(T, false, LOT);
        address b = _plain(T + 1000, true, LOT);
        FlashBorrower f = _fb();
        vm.recordLogs();
        f.run(address(quote), BUY_COST, _steps(_take(a, true, LOT), _take(b, false, LOT)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.emitter, address(book));
        assertEq(last.topics[0], IOloBookBase.Flash.selector, "the last log is Flash");
        assertEq(last.topics[1], bytes32(uint256(uint160(address(f)))));
        assertEq(last.topics[2], bytes32(uint256(uint160(address(quote)))));
        assertEq(abi.decode(last.data, (uint256)), BUY_COST);
        uint256 takes;
        uint256 flashes;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IOloBookBase.Take.selector) ++takes;
            if (logs[i].topics[0] == IOloBookBase.Flash.selector) ++flashes;
        }
        assertEq(takes, 2, "the callback's takes logged before");
        assertEq(flashes, 1);
    }

    /// Not repaid: the credit withdrawn, spent on a buy never sold back, or withdrawn to another wallet. Each reverts
    /// whole: no order, account or token moves.
    function test_flash_not_repaid_reverts() public {
        address a = _plain(T, false, LOT);
        FlashBorrower f = _fb();
        uint256 heldQ = quote.balanceOf(address(book));
        uint256 heldB = base.balanceOf(address(book));
        uint256 word = book.orderWord(c, posOf[a]);
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        f.run(address(quote), LOT, _steps(_wd(quote, LOT)));
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        f.run(address(quote), BUY_COST, _steps(_take(a, true, LOT)));
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        f.run(address(quote), LOT, _steps(abi.encodeCall(book.withdrawTo, (address(quote), LOT, address(0xCAFE)))));
        assertEq(quote.balanceOf(address(book)), heldQ);
        assertEq(base.balanceOf(address(book)), heldB);
        assertEq(book.orderWord(c, posOf[a]), word, "the ask untouched");
        assertEq(_bal(address(f), quote), 0);
        assertEq(_bal(address(f), base), 0);
        assertEq(quote.balanceOf(address(f)), 0);
        assertEq(quote.balanceOf(address(0xCAFE)), 0);
        assertEq(f.callbacks(), 0);
    }

    /// A flash as a token loan: the credit withdrawn to the wallet and deposited back.
    function test_flash_lends_tokens_withdraw_then_deposit() public {
        FlashBorrower f = _fb();
        uint256 held = quote.balanceOf(address(book));
        f.run(address(quote), LOT, _steps(_wd(quote, LOT), _dep(quote, LOT)));
        assertEq(_bal(address(f), quote), 0);
        assertEq(quote.balanceOf(address(f)), 0);
        assertEq(quote.balanceOf(address(book)), held);
    }

    /// A token transferred to the OLO EVM contract directly repays nothing: with nothing of its own the borrower cannot
    /// repay; with as much of its own, the flash is repaid from it and the transferred tokens are counted nowhere.
    function test_flash_direct_transfer_repays_nothing() public {
        FlashBorrower f = _fb();
        FlashBorrower.Step[] memory s = new FlashBorrower.Step[](2);
        s[0] = FlashBorrower.Step(address(0), false, _wd(quote, LOT));
        s[1] = FlashBorrower.Step(address(quote), false, abi.encodeCall(quote.transfer, (address(book), LOT)));
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        f.run(address(quote), LOT, s);
        _fund(f, quote, LOT);
        uint256 held = quote.balanceOf(address(book));
        f.run(address(quote), LOT, s);
        assertEq(_bal(address(f), quote), 0, "repaid from its own balance");
        assertEq(quote.balanceOf(address(f)), 0, "and the transferred LOT is gone");
        assertEq(quote.balanceOf(address(book)), held, "held by the contract, owed to nobody");
    }

    // ---------------------------------------------------------- a crossed book

    /// An ask of 1 LOT at T (P 1.00000) and a bid of 1 LOT at T + 1000 (P 1.01000): a borrower with nothing buys the
    /// ask and sells to the bid on a flash of the buy's cost. Buy: 1,000,000 + 50; sell: 1,010,000 - 51 (50.5 rounded
    /// up): 9,899 left. The makers settle as after any take, and everyone leaves.
    function test_flash_crosses_a_crossed_book_without_capital() public {
        address a = _plain(T, false, LOT);
        address b = _plain(T + 1000, true, LOT);
        FlashBorrower f = _fb();
        f.run(address(quote), BUY_COST, _steps(_take(a, true, LOT), _take(b, false, LOT)));
        assertEq(_bal(address(f), quote), 9_899);
        assertEq(_bal(address(f), base), 0);
        uint256 aq = _bal(a, quote);
        _claim(a);
        assertEq(_bal(a, quote) - aq, 1_000_000 + 50, "the ask's proceeds and its fee share");
        uint256 bb = _bal(b, base);
        uint256 bq = _bal(b, quote);
        _claim(b);
        assertEq(_bal(b, base) - bb, LOT, "the bid's base");
        assertEq(_bal(b, quote) - bq, 50, "and its fee share, 50.5 floored");
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 0);
        assertEq(quoteLeft, 1, "the sell's fee rounding");
    }

    /// The cross's break-even on the fixture: a bid at T + 10 nets 1,000,100 - 51 = 1,000,049, a wei short of the
    /// buy's 1,000,050; at T + 11, 1,000,110 - 51 = 1,000,059, 9 over.
    function test_flash_cross_break_even_boundary() public {
        address a = _plain(T, false, LOT);
        address b10 = _plain(T + 10, true, LOT);
        FlashBorrower f = _fb();
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        f.run(address(quote), BUY_COST, _steps(_take(a, true, LOT), _take(b10, false, LOT)));
        address b11 = _plain(T + 11, true, LOT);
        f.run(address(quote), BUY_COST, _steps(_take(a, true, LOT), _take(b11, false, LOT)));
        assertEq(_bal(address(f), quote), 9);
        assertEq(_bal(address(f), base), 0);
    }

    // ------------------------------------------------------------------ nesting

    /// A flash of base inside a flash of quote: each repaid. One not repaid reverts the whole call, the outer
    /// callback's work with it.
    function test_flash_nested() public {
        FlashBorrower f = _fb();
        _fund(f, quote, 7);
        _fund(f, base, 3);
        f.run(address(quote), LOT, _steps(_flashCall(base, 2 * LOT, _none())));
        assertEq(f.callbacks(), 2);
        assertEq(f.seenToken(), address(base), "the inner callback recorded last");
        assertEq(f.seenBalance(), 3 + 2 * LOT);
        assertEq(_bal(address(f), quote), 7);
        assertEq(_bal(address(f), base), 3);
        quote.mint(address(f), 11);
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        f.run(address(quote), LOT, _steps(_dep(quote, 11), _flashCall(base, 2 * LOT, _steps(_wd(base, 2 * LOT)))));
        assertEq(_bal(address(f), quote), 7, "the outer deposit undone");
        assertEq(quote.balanceOf(address(f)), 11);
        assertEq(f.callbacks(), 2);
    }

    function test_flash_nested_same_token() public {
        FlashBorrower f = _fb();
        _fund(f, quote, 7);
        f.run(address(quote), LOT, _steps(_flashCall(quote, 3 * LOT, _none())));
        assertEq(f.seenBalance(), 7 + LOT + 3 * LOT, "both credits inside the inner callback");
        assertEq(_bal(address(f), quote), 7);
    }

    /// An inner credit cannot hide what the outer one owes: each level is debited as it returns. Withdrawn outside the
    /// inner flash, the outer debit fails; withdrawn inside it, the inner debit fails first when the account cannot
    /// cover it, and the outer one when the inner repaid with the outer's credit.
    function test_flash_inner_credit_cannot_cover_outer_debt() public {
        FlashBorrower f = _fb();
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        f.run(address(quote), LOT, _steps(_wd(quote, LOT), _flashCall(quote, LOT, _none())));
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        f.run(address(quote), LOT, _steps(_flashCall(quote, LOT, _steps(_wd(quote, LOT)))));
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        f.run(address(quote), LOT, _steps(_flashCall(quote, LOT, _steps(_wd(quote, 2 * LOT)))));
        assertEq(quote.balanceOf(address(f)), 0);
        assertEq(_bal(address(f), quote), 0);
    }

    /// An inner flash that fails, caught by the callback, leaves nothing: its credit, its callback's work and its log
    /// are reverted with it, and the outer flash goes on and is repaid.
    function test_flash_caught_inner_failure_leaves_nothing() public {
        FlashBorrower f = _fb();
        uint256 held = quote.balanceOf(address(book));
        FlashBorrower.Step[] memory s = new FlashBorrower.Step[](1);
        // inside: both credits withdrawn, so the inner debit finds nothing
        s[0] = FlashBorrower.Step(address(0), true, _flashCall(quote, LOT, _steps(_wd(quote, 2 * LOT))));
        vm.recordLogs();
        f.run(address(quote), LOT, s);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 flashes;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IOloBookBase.Flash.selector) ++flashes;
        }
        assertEq(flashes, 1, "the outer flash's log alone");
        assertEq(f.caught(), 1);
        assertEq(f.callbacks(), 1, "the inner callback's count reverted with it");
        assertEq(_bal(address(f), quote), 0);
        assertEq(quote.balanceOf(address(f)), 0, "the inner withdrawal reverted");
        assertEq(quote.balanceOf(address(book)), held);
    }

    // ------------------------------------------------------------ the callback

    /// The lock is open for the callback: every entry runs inside it, those that lock (a deposit, a withdrawal, a
    /// wallet takeThenRest, a multicall, a fee collection) included.
    function test_flash_callback_may_call_every_entry() public {
        address a = _plain(T, false, LOT);
        FlashBorrower f = _fb();
        _fund(f, quote, 1e12);
        _fund(f, base, 1e12);
        quote.mint(address(f), 1e12);
        base.mint(address(f), 1e12);
        uint32 p1 = _pos();
        uint32 p2 = _pos();
        MarketWord k = OloOps.key(c);
        bytes[] memory calls = new bytes[](14);
        calls[0] = _dep(quote, 1);
        calls[1] = abi.encodeCall(book.place, (k, OloOps.placeW(false, T + 5, LOT, p1, 0)));
        calls[2] = abi.encodeCall(book.modify, (k, OloOps.tagW(c, OloOps.modifyW(p1, T + 6, 2 * LOT, 0))));
        calls[3] = abi.encodeCall(
            book.take, (k, OloOps.poolList(OloOps.poolEntry(p1, T + 6)), OloOps.tagW(c, OloOps.takeW(true, LOT, 0)))
        );
        calls[4] = abi.encodeCall(book.claim, (k, OloOps.tagW(c, OloOps.posW(p1, 0))));
        calls[5] = abi.encodeCall(book.cancel, (k, OloOps.tagW(c, OloOps.posW(p1, 0))));
        calls[6] = abi.encodeCall(
            book.takeThenRest,
            (k, OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.restW(true, LOT, T, OloOps.WALLET, p2)))
        );
        calls[7] = OloOps.batchCalldata(book.manageBatchSubs.selector, c, OloOps.postW(true, 0, T - 10, LOT, 2));
        calls[8] = OloOps.batchCalldata(book.manageBatchSubs.selector, c, OloOps.maskW(OloOps.CANCEL, 0, 0, 0x3));
        calls[9] = abi.encodeCall(book.multicall, (0, bytes.concat(OloOps.header(c), OloOps.deposit(quoteId, 1))));
        calls[10] = _wd(quote, 1);
        calls[11] = abi.encodeCall(book.collectFees, (address(quote)));
        calls[12] = abi.encodeCall(book.warmPool, (m, 50_000, 1));
        calls[13] = _flashCall(base, LOT, _none());
        FlashBorrower.Step[] memory s = new FlashBorrower.Step[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            s[i] = FlashBorrower.Step(address(0), false, calls[i]);
        }
        uint256 walletBase = base.balanceOf(address(f));
        f.run(address(quote), LOT, s);
        assertEq(f.callbacks(), 2);
        assertEq(base.balanceOf(address(f)) - walletBase, LOT, "the wallet takeThenRest delivered");
        assertFalse(PoolWord.wrap(book.orderWord(c, p1)).isLive(), "the order cancelled");
        assertEq(book.orderWord(c, 50_000), 1 << 94, "the position warmed");
    }

    /// The credit can escrow an order, but the order must be unwound before the callback returns.
    function test_flash_escrowing_an_order_must_unwind() public {
        FlashBorrower f = _fb();
        uint32 p = _pos();
        bytes memory placeBid = abi.encodeCall(book.place, (OloOps.key(c), OloOps.placeW(true, T, LOT, p, 0)));
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        f.run(address(quote), LOT, _steps(placeBid));
        f.run(
            address(quote),
            LOT,
            _steps(placeBid, abi.encodeCall(book.cancel, (OloOps.key(c), OloOps.tagW(c, OloOps.posW(p, 0)))))
        );
        assertEq(_bal(address(f), quote), 0);
        assertFalse(PoolWord.wrap(book.orderWord(c, p)).isLive());
    }

    /// A callback's revert is the flash's, as the callback gave it.
    function test_flash_callback_revert_is_the_flash_revert() public {
        FlashBorrower f = _fb();
        uint32 p = _pos();
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        f.run(
            address(quote), LOT, _steps(abi.encodeCall(book.cancel, (OloOps.key(c), OloOps.tagW(c, OloOps.posW(p, 0)))))
        );
    }

    /// The borrower's own check (IOloFlashCallback asks a callback to check its caller): a call from anyone else is
    /// refused. A test of the fixture, not of the OLO EVM contract.
    function test_flash_callback_checks_its_caller() public {
        FlashBorrower f = _fb();
        vm.expectRevert(FlashBorrower.NotBook.selector);
        f.oloFlashCallback(address(quote), 1, abi.encode(_none()));
    }

    /// The callback goes to the caller of `flash`, not to the transaction's origin.
    function test_flash_calls_back_the_caller_not_the_origin() public {
        FlashBorrower f = _fb();
        vm.prank(address(f), address(0xE0A));
        book.flash(address(quote), LOT, abi.encode(_none()));
        assertEq(f.callbacks(), 1);
    }

    // ---------------------------------------------------------------- refusals

    function test_flash_unknown_token() public {
        FlashBorrower f = _fb();
        vm.expectRevert(IOloBookBase.UnknownToken.selector);
        f.run(address(0xDEAD), 1, _none());
    }

    function test_flash_zero_amount() public {
        FlashBorrower f = _fb();
        vm.expectRevert(IOloBookBase.ZeroSize.selector);
        f.run(address(quote), 0, _none());
    }

    /// An account holds at most 2^128 - 1: a flash past it is AmountOverflow, also where the credit's add would
    /// overflow 256 bits (a balance of 1 and an amount of 2^256 - 1: the check before the add, not a panic).
    function test_flash_amount_past_an_account() public {
        FlashBorrower f = _fb();
        vm.expectRevert(IOloBookBase.AmountOverflow.selector);
        f.run(address(quote), 1 << 128, _none());
        _fund(f, quote, 1);
        vm.expectRevert(IOloBookBase.AmountOverflow.selector);
        f.run(address(quote), type(uint128).max, _none());
        vm.expectRevert(IOloBookBase.AmountOverflow.selector);
        f.run(address(quote), type(uint256).max, _none());
    }

    /// A credit beyond what the OLO EVM contract holds: spent inside it (a bid escrowed and cancelled), but not
    /// withdrawn (the transfer fails, and the whole call with it).
    function test_flash_beyond_holdings_spends_but_cannot_withdraw() public {
        FlashBorrower f = _fb();
        uint32 p = _pos();
        uint256 huge = 1e33; // quote wei, far above what the contract holds
        assertGt(huge, quote.balanceOf(address(book)));
        f.run(
            address(quote),
            type(uint128).max,
            _steps(
                abi.encodeCall(book.place, (OloOps.key(c), OloOps.placeW(true, T, huge, p, 0))),
                abi.encodeCall(book.cancel, (OloOps.key(c), OloOps.tagW(c, OloOps.posW(p, 0))))
            )
        );
        assertEq(_bal(address(f), quote), 0);
        uint256 held = quote.balanceOf(address(book));
        vm.expectRevert();
        f.run(address(quote), type(uint128).max, _steps(_wd(quote, held + 1)));
        assertEq(quote.balanceOf(address(book)), held);
    }

    function test_flash_from_an_address_without_code_reverts() public {
        vm.prank(address(0xE0A));
        vm.expectRevert(IOloBookBase.BadAddress.selector);
        book.flash(address(quote), 1, "");
        assertEq(_bal(address(0xE0A), quote), 0);
    }

    /// A wallet that delegates to code (EIP-7702, Prague) is called back in its own context: the credit is on its
    /// account, the callback's state in its own storage.
    function test_flash_from_a_7702_delegated_account() public {
        vm.setEvmVersion("prague");
        FlashBorrower impl = new FlashBorrower(book);
        uint256 pk = 0x7702F;
        address eoa = vm.addr(pk);
        vm.signAndAttachDelegation(address(impl), pk);
        FlashBorrower(eoa).run(address(quote), LOT, _none());
        assertEq(eoa.code.length, 23, "the delegation designator");
        assertEq(FlashBorrower(eoa).callbacks(), 1);
        assertEq(FlashBorrower(eoa).seenSender(), address(book));
        assertEq(FlashBorrower(eoa).seenBalance(), LOT, "the credit on the wallet's account");
        assertEq(_bal(eoa, quote), 0);
        assertEq(impl.callbacks(), 0, "nothing in the implementation's storage");
    }

    /// A proprietary market's policy is not asked for a flash; the entries the callback calls ask it as usual.
    function test_flash_in_a_proprietary_market_asks_no_policy() public {
        RefuseAll pol = new RefuseAll();
        book.setProprietaryListingAllowed(address(this), true);
        MarketWord pc =
            book.configOf(book.listMarketQuoteProprietary(address(base), address(quote), 60, 6, 1, 0, address(pol)));
        FlashBorrower f = _fb();
        f.run(address(quote), LOT, _none());
        vm.expectRevert(IOloBookBase.NotAdmitted.selector);
        f.run(
            address(quote),
            LOT,
            _steps(abi.encodeCall(book.take, (OloOps.key(pc), "", OloOps.tagW(pc, OloOps.takeW(true, LOT, 0)))))
        );
    }

    /// Called on the extension directly, a flash runs in the extension's own storage, whose registry is empty.
    /// Called on the extension directly, `flash` runs in the extension's own storage: its registry is empty
    /// (UnknownToken) until someone lists a market on the extension itself, and then the credit is in the extension's
    /// storage and the callback comes from the extension's address, which a callback that checks for the OLO EVM
    /// contract refuses (NotBook here). Nothing of the OLO EVM contract's is reached either way.
    function test_flash_on_the_extension_directly() public {
        IOloBookExt ext = IOloBookExt(book.ext());
        vm.expectRevert(IOloBookBase.UnknownToken.selector);
        ext.flash(address(quote), 1, "");
        // a listing in the extension's own storage (its listing fee there is 0) registers the token there
        uint256 tokens = book.tokenCount();
        ext.listMarketQuote(address(base), address(quote), 50, 6, 1, 0);
        assertEq(book.tokenCount(), tokens, "the OLO EVM contract's registry as it was");
        // a callback that checks for the OLO EVM contract refuses the extension's call
        FlashBorrower f = _fb();
        vm.prank(address(f));
        vm.expectRevert(FlashBorrower.NotBook.selector);
        ext.flash(address(quote), 1, abi.encode(_none()));
        // one that does not check is called back by the extension, its credit in the extension's storage
        ExtFlashCaller e = new ExtFlashCaller();
        uint256 held = quote.balanceOf(address(book));
        e.go(ext, address(quote));
        assertEq(e.seen(), address(ext), "called back by the extension");
        assertEq(book.balanceOf(book.tokenId(address(quote)), address(e)), 0, "no credit in the OLO EVM contract");
        assertEq(quote.balanceOf(address(book)), held, "nothing of the OLO EVM contract's moved");
    }

    // ------------------------------------------------------------------- fuzz

    /// A flash of `amount` is a deposit of it, the program, and its withdrawal: the same program succeeds or fails
    /// alike both ways, and leaves the same accounts, orders and holdings (the wallet `amount` richer the second way,
    /// which minted it).
    function testFuzz_flash_is_a_deposit_repaid(uint256 seed) public {
        address a = _plain(T, false, 5 * LOT);
        address b = _plain(T + 1000, true, 5 * LOT);
        FlashBorrower f = _fb();
        quote.mint(address(f), 1e20);
        base.mint(address(f), 1e20);
        uint256 amount = bound(seed, 1, 1e13);
        FlashBorrower.Step[] memory p = _program(seed >> 64, a, b);
        uint256 snap = vm.snapshotState();
        (bool ok1,) = address(f).call(abi.encodeCall(f.run, (address(quote), amount, p)));
        uint256[8] memory s1 = _state(f, a, b);
        vm.revertToState(snap);
        quote.mint(address(f), amount);
        f.exec(_dep(quote, amount));
        FlashBorrower.Step[] memory p2 = new FlashBorrower.Step[](p.length + 1);
        for (uint256 i; i < p.length; ++i) {
            p2[i] = p[i];
        }
        p2[p.length] = FlashBorrower.Step(address(0), false, _wd(quote, amount));
        (bool ok2,) = address(f).call(abi.encodeCall(f.execSteps, (p2)));
        uint256[8] memory s2 = _state(f, a, b);
        assertEq(ok1, ok2, "succeeds alike");
        if (!ok1) return;
        for (uint256 i; i < 8; ++i) {
            if (i == 2) assertEq(s2[i], s1[i] + amount, "the wallet");
            else assertEq(s2[i], s1[i], vm.toString(i));
        }
    }

    /// Up to four steps: withdrawals and deposits of quote, buys from `a`, sells to `b`, a bid placed and cancelled,
    /// withdrawals of base; amounts small against what the contract holds, so no transfer fails on its holdings.
    function _program(uint256 r, address a, address b) internal view returns (FlashBorrower.Step[] memory s) {
        uint256 n = r % 5;
        r >>= 3;
        uint256 len;
        s = new FlashBorrower.Step[](2 * n);
        for (uint256 i; i < n; ++i) {
            uint256 kind = r % 6;
            uint256 x = 1 + (r >> 3) % (2 * LOT);
            r >>= 40;
            if (kind == 0) {
                s[len++] = FlashBorrower.Step(address(0), false, _wd(quote, x));
            } else if (kind == 1) {
                s[len++] = FlashBorrower.Step(address(0), false, _dep(quote, x));
            } else if (kind == 2) {
                s[len++] = FlashBorrower.Step(address(0), false, _take(a, true, x));
            } else if (kind == 3) {
                s[len++] = FlashBorrower.Step(address(0), false, _take(b, false, x));
            } else if (kind == 4) {
                uint32 p = uint32(900_000 + i);
                s[len++] = FlashBorrower.Step(
                    address(0), false, abi.encodeCall(book.place, (OloOps.key(c), OloOps.placeW(true, T - 5, x, p, 0)))
                );
                s[len++] = FlashBorrower.Step(
                    address(0), false, abi.encodeCall(book.cancel, (OloOps.key(c), OloOps.tagW(c, OloOps.posW(p, 0))))
                );
            } else {
                s[len++] = FlashBorrower.Step(address(0), false, _wd(base, x));
            }
        }
        assembly ("memory-safe") {
            mstore(s, len)
        }
    }

    /// The borrower's accounts and quote wallet, the two orders' words, and what the contract holds of each token.
    function _state(FlashBorrower f, address a, address b) internal view returns (uint256[8] memory s) {
        s[0] = _bal(address(f), quote);
        s[1] = _bal(address(f), base);
        s[2] = quote.balanceOf(address(f));
        s[3] = base.balanceOf(address(f));
        s[4] = book.orderWord(c, posOf[a]);
        s[5] = book.orderWord(c, posOf[b]);
        s[6] = quote.balanceOf(address(book));
        s[7] = base.balanceOf(address(book));
    }
}
