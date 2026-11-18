// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloBook} from "../src/OloBook.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {OloOps} from "./OloOps.sol";

/// The batch executor an EIP-7702 account delegates to: the account calls itself with a list of calls. The shape of
/// Simple7702Account's self path and of the minimal batch executors wallets ship.
contract BatchExecutor {
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    function execute(Call[] calldata calls) external payable {
        require(msg.sender == address(this), "not self");
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

/// What OloBook calls cost from an EIP-7702 account that batches them (run with --isolate --evm-version prague):
/// the account's delegation is set beforehand (an `etch` of the designator; the one-off authorization is 12.5k on
/// an existing account), so each row is one transaction from the account to itself.
contract GasBench7702 is OloBase {
    BatchExecutor exec;

    function setUp() public {
        // the delegation designator only resolves under Prague: `forge test --isolate --evm-version prague`
        vm.skip(!vm.envOr("EIP7702", false));
        _deploy();
        exec = new BatchExecutor();
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    function _delegate(address a) internal {
        vm.etch(a, abi.encodePacked(hex"ef0100", address(exec)));
    }

    function _run(address a, BatchExecutor.Call[] memory calls) internal {
        vm.prank(a, a);
        (bool ok, bytes memory ret) = a.call(abi.encodeCall(BatchExecutor.execute, (calls)));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// One cancel through the account against a direct cancel: the delegation's overhead.
    function test_one_call_overhead() public {
        address z = _plain(T + 2, false, 5 * LOT);
        _delegate(z);
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](1);
        calls[0] = BatchExecutor.Call(
            address(book), 0, abi.encodeCall(OloBook.cancel, (OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[z], 0))))
        );
        _run(z, calls);
        _log("cancel_via_7702", _gas());
        address y = _plain(T + 3, false, 5 * LOT);
        vm.prank(y);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[y], 0)));
        _log("cancel_direct", _gas());
    }

    /// `n` asks and `n` bids (four a slot) each moved one tick up: a replace call per slot in one transaction.
    function _twoSided7702(uint256 n) internal {
        address z = _maker();
        _delegate(z);
        uint256 slots = (n + 3) / 4;
        vm.startPrank(z);
        for (uint256 s; s < slots; ++s) {
            uint256 k = n - 4 * s < 4 ? n - 4 * s : 4;
            uint256 off = 4 * s;
            _mb(c, OloOps.ladderW(OloOps.POST, false, uint16(s), 0, T + 2 + off, 5 * LOT, k, 1));
            _mb(c, OloOps.ladderW(OloOps.POST, true, uint16(100 + s), 0, T - 2 - off, 5 * LOT, k, 1));
        }
        vm.stopPrank();
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2 * slots);
        for (uint256 s; s < slots; ++s) {
            uint256 k = n - 4 * s < 4 ? n - 4 * s : 4;
            uint256 off = 4 * s;
            calls[2 * s] = BatchExecutor.Call(
                address(book),
                0,
                OloOps.batchCalldata(
                    OloBook.manageBatchSubs.selector,
                    c,
                    OloOps.ladderW(OloOps.REPLACE, false, uint16(s), 0, T + 3 + off, 5 * LOT, k, 1)
                )
            );
            calls[2 * s + 1] = BatchExecutor.Call(
                address(book),
                0,
                OloOps.batchCalldata(
                    OloBook.manageBatchSubs.selector,
                    c,
                    OloOps.ladderW(OloOps.REPLACE, true, uint16(100 + s), 0, T - 1 - off, 5 * LOT, k, 1)
                )
            );
        }
        _run(z, calls);
        _log(string.concat("batch_requote_two_sided_", vm.toString(2 * n), "_7702"), _receipt());
    }

    function test_two_sided_8() public {
        _twoSided7702(4);
    }

    function test_two_sided_24() public {
        _twoSided7702(12);
    }

    function test_two_sided_48() public {
        _twoSided7702(24);
    }

    /// A new user's first order: approve and place from the wallet in one transaction, against the two.
    function test_retail_approve_place() public {
        address r = address(0xABCD02);
        base.mint(r, 1e30);
        _delegate(r);
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] =
            BatchExecutor.Call(address(base), 0, abi.encodeCall(MockERC20.approve, (address(book), type(uint256).max)));
        calls[1] = BatchExecutor.Call(
            address(book),
            0,
            abi.encodeCall(OloBook.place, (OloOps.key(c), OloOps.placeW(false, T + 5, 5 * LOT, nextPos++, 2)))
        );
        _run(r, calls);
        _log("retail_approve_place_wallet_7702", _gas());
        address q = address(0xABCD03);
        base.mint(q, 1e30);
        vm.prank(q);
        base.approve(address(book), type(uint256).max);
        uint256 g = _gas();
        vm.prank(q);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 6, 5 * LOT, nextPos++, 2));
        _log("retail_approve_place_wallet_two_txs", g + _gas());
    }

    /// A taker's take and withdrawal of the proceeds in one transaction.
    function test_take_withdraw() public {
        address a = _plain(T + 1, false, 5 * LOT);
        address t = address(0xABCD04);
        quote.mint(t, 1e30);
        vm.startPrank(t);
        quote.approve(address(book), type(uint256).max);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
        _delegate(t);
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](2);
        calls[0] = BatchExecutor.Call(
            address(book),
            0,
            abi.encodeCall(
                OloBook.take,
                (OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0)))
            )
        );
        calls[1] = BatchExecutor.Call(address(book), 0, abi.encodeCall(OloBook.withdraw, (address(base), 5e6)));
        _run(t, calls);
        _log("take_withdraw_7702", _gas());
        address b2 = _plain(T + 2, false, 5 * LOT);
        address u = address(0xABCD05);
        quote.mint(u, 1e30);
        vm.startPrank(u);
        quote.approve(address(book), type(uint256).max);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
        vm.prank(u);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(b2)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0)));
        uint256 g = _gas();
        vm.prank(u);
        book.withdraw(address(base), 5e6);
        _log("take_withdraw_two_txs", g + _gas());
    }
}
