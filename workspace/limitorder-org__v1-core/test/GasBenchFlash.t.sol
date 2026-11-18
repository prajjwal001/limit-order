// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {OloBook} from "../src/OloBook.sol";
import {IOloFlashCallback} from "../src/interfaces/IOloFlashCallback.sol";
import {MockERC20} from "./utils/MockERC20.sol";

/// For the benches: one program loop on both paths (inside a flash, or with no flash) and no state of its own written,
/// so a flash row less its funded twin is the flash alone.
contract BenchBorrower is IOloFlashCallback {
    OloBook public immutable book;

    constructor(OloBook book_) {
        book = book_;
    }

    function approve(address token) external {
        MockERC20(token).approve(address(book), type(uint256).max);
    }

    /// The program with no flash, in one transaction.
    function execute(bytes[] calldata program) external {
        _runProgram(program);
    }

    /// The program inside a flash: `program` is abi.encode(bytes[]).
    function run(address token, uint256 amount, bytes calldata program) external {
        book.flash(token, amount, program);
    }

    function oloFlashCallback(address, uint256, bytes calldata data) external {
        if (msg.sender != address(book)) revert();
        _runProgram(abi.decode(data, (bytes[])));
    }

    function _runProgram(bytes[] memory program) internal {
        for (uint256 i; i < program.length; ++i) {
            (bool ok, bytes memory ret) = address(book).call(program[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

/// Gas of a flash (run with --isolate): each row one transaction, frame gas and (`_receipt`) the capped refund
/// deducted. The borrower's accounts of both tokens are written words (USED) before every row but `flash_empty_first`.
/// A warm OLO EVM contract as GasBenchOlo's: one past round, so the fee pot is a written word.
contract GasBenchFlash is OloBase {
    BenchBorrower bb;

    /// buy 1 LOT at T: 1,000,000 + a fee of 50; sell 1 LOT at T + 1000: 1,010,000 less a fee of 51 (50.5 rounded up)
    uint256 constant BUY_COST = 1_000_050;
    uint256 constant PROFIT = 9_899;

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
        bb = _borrower(true);
    }

    /// A borrower approved to the OLO EVM contract; `used`: its accounts of both tokens written (a deposit of 1 and its
    /// withdrawal), at a balance of 0.
    function _borrower(bool used) internal returns (BenchBorrower b) {
        b = new BenchBorrower(book);
        b.approve(address(base));
        b.approve(address(quote));
        if (used) {
            base.mint(address(b), 1);
            quote.mint(address(b), 1);
            bytes[] memory p = new bytes[](4);
            p[0] = abi.encodeCall(book.deposit, (address(base), 1));
            p[1] = abi.encodeCall(book.withdraw, (address(base), 1));
            p[2] = abi.encodeCall(book.deposit, (address(quote), 1));
            p[3] = abi.encodeCall(book.withdraw, (address(quote), 1));
            b.execute(p);
        }
    }

    function _row(string memory k) internal view {
        _log(k, _gas());
        _log(string.concat(k, "_receipt"), _receipt());
    }

    function _none() internal pure returns (bytes memory) {
        return abi.encode(new bytes[](0));
    }

    /// An ask of 1 LOT at T (P 1.00000) and a bid of 1 LOT at T + 1000 (P 1.01000), crossed by 1%, and the program
    /// that buys the ask and sells to the bid, both on the caller's accounts.
    function _crossed() internal returns (bytes[] memory p) {
        address a = _plain(T, false, LOT);
        address b = _plain(T + 1000, true, LOT);
        p = new bytes[](2);
        p[0] = abi.encodeCall(
            book.take, (OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, LOT, 0)))
        );
        p[1] = abi.encodeCall(
            book.take, (OloOps.key(c), OloOps.poolList(_poolEntry(b)), OloOps.tagW(c, OloOps.takeW(false, LOT, 0)))
        );
    }

    function test_flash_empty() public {
        bb.run(address(quote), LOT, _none());
        _row("flash_empty");
        assertEq(book.balanceOf(quoteId, address(bb)), 0);
    }

    function test_flash_empty_first() public {
        BenchBorrower fresh = _borrower(false);
        fresh.run(address(quote), LOT, _none());
        _row("flash_empty_first");
        assertEq(book.balanceOf(quoteId, address(fresh)), 0);
    }

    /// The borrower's own transaction with an empty program and no flash: what `flash_empty` pays besides the flash.
    function test_execute_empty() public {
        bb.execute(new bytes[](0));
        _row("execute_empty");
    }

    function test_flash_token_loan() public {
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encodeCall(book.withdraw, (address(quote), LOT));
        p[1] = abi.encodeCall(book.deposit, (address(quote), LOT));
        uint256 wallet = quote.balanceOf(address(bb));
        bb.run(address(quote), LOT, abi.encode(p));
        _row("flash_token_loan");
        assertEq(book.balanceOf(quoteId, address(bb)), 0);
        assertEq(quote.balanceOf(address(bb)), wallet);
    }

    /// The crossed pair, with no capital: a flash of the buy's cost.
    function test_flash_cross() public {
        bytes[] memory p = _crossed();
        bb.run(address(quote), BUY_COST, abi.encode(p));
        _row("flash_cross");
        assertEq(book.balanceOf(quoteId, address(bb)), PROFIT);
        assertEq(book.balanceOf(baseId, address(bb)), 0);
    }

    /// The same program with no flash, the buy's cost deposited before: `flash_cross` less this is the flash.
    function test_cross_funded() public {
        bytes[] memory p = _crossed();
        quote.mint(address(bb), BUY_COST);
        bytes[] memory d = new bytes[](1);
        d[0] = abi.encodeCall(book.deposit, (address(quote), BUY_COST));
        bb.execute(d);
        bb.execute(p);
        _row("cross_funded");
        assertEq(book.balanceOf(quoteId, address(bb)), BUY_COST + PROFIT);
        assertEq(book.balanceOf(baseId, address(bb)), 0);
    }

    /// For reference: a funded taker's two takes, two transactions.
    function test_cross_two_txs() public {
        bytes[] memory p = _crossed();
        vm.prank(taker);
        (bool ok,) = address(book).call(p[0]);
        assertTrue(ok);
        _row("cross_two_txs_buy");
        vm.prank(taker);
        (ok,) = address(book).call(p[1]);
        assertTrue(ok);
        _row("cross_two_txs_sell");
    }
}
