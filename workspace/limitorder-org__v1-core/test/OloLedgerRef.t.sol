// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {LedgerRef} from "./LedgerRef.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {ACCOUNT_USED, OloSlots} from "../src/OloTypes.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";

using MarketLib for MarketWord;

/// The ledger (`_ledgerFlows`, `_newLedger`, `_ledgerAdd`, `_commit`) and a single op's settlement (`_settleFlows`) held
/// to their plain reference
/// (LedgerRef.sol), as the loops are held to SlotRef and PoolTakeRef: one maker, five tokens on three markets (so a
/// multicall can touch four accounts, or ask for a fifth), random multicalls of DEPOSIT, WITHDRAW, PLACE and CANCEL
/// ops under every settle flag, and single places and cancels with flags; after every step the maker's five account
/// balances and five wallet balances are the reference's, and a failing step fails with the reference's error
/// (TooManyTokens, InsufficientBalance). No takes, so no fees: the ledger alone is under test. Two directed cases
/// hold what a random run may miss: four accounts in one ledger, every one flowing twice, all four settled.
contract OloLedgerRefTest is OloBase {
    MarketWord[3] cs; // base/quote, t2/t3, t4/quote
    MockERC20[5] toks;
    uint256[5] ids;
    address a;
    uint256 constant STEPS = 24;

    struct Order {
        uint8 mi;
        uint32 pos;
        bool isBid;
        uint256 tick;
        uint256 lots;
    }

    Order[] live;
    uint256[] bal; // the reference's account balances, by token index (`_ix`)
    uint256[] wal; // the maker's wallet balances, by token index
    uint256 idBase; // the registry id before the fixture's first token: 0, or near 2^32 under OLO_HIGH_IDS

    /// A token id as the reference's arrays index it: 1 .. 5 for the five tokens, whatever ids the registry gave.
    function _ix(uint256 id) internal view returns (uint256) {
        return id - idBase;
    }

    function setUp() public {
        _deploy();
        toks[0] = base;
        toks[1] = quote;
        toks[2] = new MockERC20("Two", "T2", 6);
        toks[3] = new MockERC20("Three", "T3", 6);
        toks[4] = new MockERC20("Four", "T4", 6);
        cs[0] = c;
        cs[1] = book.configOf(book.listMarketQuote(address(toks[2]), address(toks[3]), 50, 6, 1, 0));
        cs[2] = book.configOf(book.listMarketQuote(address(toks[4]), address(quote), 50, 6, 1, 0));
        a = _maker();
        for (uint256 k = 2; k < 5; ++k) {
            toks[k].mint(a, 1e30);
            vm.startPrank(a);
            toks[k].approve(address(book), type(uint256).max);
            book.deposit(address(toks[k]), 1e24);
            vm.stopPrank();
        }
        bal = new uint256[](6);
        wal = new uint256[](6);
        idBase = book.tokenId(address(base)) - 1;
        for (uint256 k; k < 5; ++k) {
            ids[k] = book.tokenId(address(toks[k]));
            bal[_ix(ids[k])] = book.balanceOf(ids[k], a);
            wal[_ix(ids[k])] = toks[k].balanceOf(a);
        }
    }

    function _rnd(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    // ---------------------------------------------------------------- the orders' money

    /// A random order on a random market, a tick within 1000 of T and up to 50 lots, in a fresh position.
    function _newOrder(uint256 q) internal returns (Order memory o) {
        o.mi = uint8((q >> 8) % 3);
        o.isBid = (q >> 16) & 1 == 1;
        o.tick = T - 1000 + (q >> 24) % 2001;
        o.lots = (1 + (q >> 40) % 50) * LOT; // base wei: up to 50 of main's lots
        o.pos = _pos();
    }

    /// What `_placeOp` escrows for `o` and on which account: an ask its amount in base, a bid its quote at P(tick)
    /// rounded up.
    function _escrowOf(Order memory o) internal view returns (uint256 key, uint256 amount) {
        MarketWord mc = cs[o.mi];
        if (o.isBid) {
            amount = PriceGrid.quoteUp(o.lots, o.tick);
            key = _ix(MarketLib.quoteId(mc));
        } else {
            amount = o.lots;
            key = _ix(MarketLib.baseId(mc));
        }
    }

    /// What `_cancelOp` refunds for the unfilled `o`: the ask's amount in base, the bid's quote rounded down.
    function _refundOf(Order memory o) internal view returns (uint256 key, uint256 amount) {
        MarketWord mc = cs[o.mi];
        if (o.isBid) {
            amount = PriceGrid.quoteDown(o.lots, o.tick);
            key = _ix(MarketLib.quoteId(mc));
        } else {
            amount = o.lots;
            key = _ix(MarketLib.baseId(mc));
        }
    }

    // ---------------------------------------------------------------- the reference's bookkeeping

    function _copy(uint256[] memory x) internal pure returns (uint256[] memory y) {
        y = new uint256[](x.length);
        for (uint256 i; i < x.length; ++i) {
            y[i] = x[i];
        }
    }

    /// The step succeeded: the reference's balances and wallet moves become the state.
    function _accept(uint256[] memory nb, int256[] memory wd) internal {
        bal = nb;
        for (uint256 k; k < 5; ++k) {
            wal[_ix(ids[k])] = uint256(int256(wal[_ix(ids[k])]) + wd[_ix(ids[k])]);
        }
    }

    /// Every account and wallet balance of the maker is the reference's.
    function _checkState() internal view {
        for (uint256 k; k < 5; ++k) {
            assertEq(book.balanceOf(ids[k], a), bal[_ix(ids[k])], "account balance");
            assertEq(toks[k].balanceOf(a), wal[_ix(ids[k])], "wallet balance");
        }
    }

    /// Removes the `n` live orders whose indices into `live` are `indices`, highest index first so the swaps stay
    /// valid.
    function _drop(uint256[] memory indices, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (indices[j] > indices[i]) (indices[i], indices[j]) = (indices[j], indices[i]);
            }
        }
        for (uint256 i; i < n; ++i) {
            live[indices[i]] = live[live.length - 1];
            live.pop();
        }
    }

    function _header() internal view returns (bytes memory) {
        return abi.encodePacked(uint8(3), MarketWord.unwrap(cs[0]), MarketWord.unwrap(cs[1]), MarketWord.unwrap(cs[2]));
    }

    // ---------------------------------------------------------------- the steps

    /// A multicall of 1 to 6 ops under random settle flags: the reference collects the same flows and commits them;
    /// the OLO EVM contract must end in the same state or fail with the same error.
    function _multicallStep(uint256 r) internal {
        LedgerRef.Ledger memory l;
        uint256 settle = ((r >> 8) % 4) * 2;
        uint256 nOps = 1 + (r >> 16) % 6;
        bytes memory ops;
        bytes4 err;
        Order[] memory placed = new Order[](nOps);
        uint256 nPlaced;
        uint256[] memory cancelled = new uint256[](nOps);
        uint256 nCancelled;
        for (uint256 i; i < nOps && err == 0; ++i) {
            uint256 q = _rnd(r, i + 100);
            uint256 t = q % 100;
            bool full;
            if (t < 20) {
                uint256 id = ids[(q >> 8) % 5];
                uint256 amt = 1 + (q >> 16) % 1e6;
                ops = bytes.concat(ops, OloOps.deposit(id, uint128(amt)));
                full = LedgerRef.addToken(l, _ix(id), int256(amt), -int256(amt));
            } else if (t < 35) {
                uint256 id = ids[(q >> 8) % 5];
                // a third of the withdrawals take the whole balance, so accounts run dry and escrows must fail or
                // fall back to the wallet
                uint256 amt = (q >> 16) % 3 == 0 ? bal[_ix(id)] : 1 + (q >> 24) % 1e6;
                if (amt == 0) amt = 1;
                ops = bytes.concat(ops, OloOps.withdraw(id, uint128(amt)));
                full = LedgerRef.addToken(l, _ix(id), -int256(amt), int256(amt));
            } else if (t < 75 || live.length == nCancelled) {
                Order memory o = _newOrder(q);
                (uint256 key, uint256 escrow) = _escrowOf(o);
                ops = bytes.concat(ops, OloOps.place(o.mi, o.tick, o.isBid, o.lots, o.pos));
                full = LedgerRef.addMaker(l, key, -int256(escrow));
                placed[nPlaced++] = o;
            } else {
                // a live order not already cancelled in this multicall
                uint256 j = (q >> 8) % live.length;
                while (_among(cancelled, nCancelled, j)) {
                    j = (j + 1) % live.length;
                }
                (uint256 key, uint256 refund) = _refundOf(live[j]);
                ops = bytes.concat(ops, OloOps.cancel(live[j].mi, live[j].pos));
                full = LedgerRef.addMaker(l, key, int256(refund));
                cancelled[nCancelled++] = j;
            }
            if (full) err = IOloBookBase.TooManyTokens.selector;
        }
        uint256[] memory nb = _copy(bal);
        int256[] memory wd = new int256[](6);
        if (err == 0) err = LedgerRef.commit(l, settle, nb, wd);
        bytes memory data = bytes.concat(_header(), ops);
        vm.prank(a);
        if (err != 0) {
            vm.expectRevert(err);
            book.multicall(uint8(settle), data);
            return;
        }
        book.multicall(uint8(settle), data);
        _accept(nb, wd);
        _drop(cancelled, nCancelled);
        for (uint256 i; i < nPlaced; ++i) {
            live.push(placed[i]);
        }
    }

    function _among(uint256[] memory xs, uint256 n, uint256 x) internal pure returns (bool) {
        for (uint256 i; i < n; ++i) {
            if (xs[i] == x) return true;
        }
        return false;
    }

    /// A single cancel with settle flags: a one-entry ledger committed with them (none: the account moves now).
    function _singleCancelStep(uint256 r) internal {
        uint256 flags = ((r >> 8) % 4) * 2;
        uint256 j = (r >> 16) % live.length;
        Order memory o = live[j];
        (uint256 key, uint256 refund) = _refundOf(o);
        LedgerRef.Ledger memory l;
        LedgerRef.addMaker(l, key, int256(refund));
        uint256[] memory nb = _copy(bal);
        int256[] memory wd = new int256[](6);
        bytes4 err = LedgerRef.commit(l, flags, nb, wd);
        vm.prank(a);
        if (err != 0) vm.expectRevert(err);
        book.cancel(OloOps.key(cs[o.mi]), OloOps.tagW(cs[o.mi], OloOps.posW(o.pos, uint8(flags))));
        if (err != 0) return;
        _accept(nb, wd);
        live[j] = live[live.length - 1];
        live.pop();
    }

    /// A single place with settle flags: its escrow as a one-entry ledger committed with them (`_fund`: AUTO from
    /// the account first and the rest from the wallet, WALLET from the wallet, none from the account or
    /// InsufficientBalance).
    function _singlePlaceStep(uint256 r) internal {
        uint256 flags = ((r >> 8) % 4) * 2;
        Order memory o = _newOrder(_rnd(r, 7));
        (uint256 key, uint256 escrow) = _escrowOf(o);
        LedgerRef.Ledger memory l;
        LedgerRef.addMaker(l, key, -int256(escrow));
        uint256[] memory nb = _copy(bal);
        int256[] memory wd = new int256[](6);
        bytes4 err = LedgerRef.commit(l, flags, nb, wd);
        vm.prank(a);
        if (err != 0) vm.expectRevert(err);
        book.place(OloOps.key(cs[o.mi]), OloOps.placeW(o.isBid, o.tick, o.lots, o.pos, uint8(flags)));
        if (err != 0) return;
        _accept(nb, wd);
        live.push(o);
    }

    function testFuzz_ledger_vs_reference(uint256 seed) public {
        for (uint256 s; s < STEPS; ++s) {
            uint256 r = _rnd(seed, s);
            uint256 kind = r % 10;
            if (kind < 7 || live.length == 0) _multicallStep(r);
            else if (kind < 9) _singleCancelStep(r);
            else _singlePlaceStep(r);
            _checkState();
        }
    }

    // ---------------------------------------------------------------- directed

    /// An ask and a bid on each of the first two markets: base, quote, t2 and t3 flow, four entries; the same four
    /// again in the same multicall must find their entries (the first and the third recur after others were added)
    /// rather than open a fifth; and all four must settle. A deposit on t4 after them is the fifth account:
    /// TooManyTokens.
    function test_four_accounts_each_twice_settle_as_four_entries() public {
        bytes memory ops;
        LedgerRef.Ledger memory l;
        Order[8] memory os;
        for (uint256 i; i < 8; ++i) {
            Order memory o = _newOrder(_rnd(1, i));
            o.mi = uint8((i >> 1) & 1); // 0, 0, 1, 1, 0, 0, 1, 1
            o.isBid = i & 1 == 1; // ask, bid, ask, bid, ...
            os[i] = o;
            (uint256 key, uint256 escrow) = _escrowOf(o);
            ops = bytes.concat(ops, OloOps.place(o.mi, o.tick, o.isBid, o.lots, o.pos));
            assertFalse(LedgerRef.addMaker(l, key, -int256(escrow)), "four accounts fit");
        }
        assertEq(l.n, 4, "four entries, each used twice");
        uint256[] memory nb = _copy(bal);
        int256[] memory wd = new int256[](6);
        assertEq(LedgerRef.commit(l, 0, nb, wd), bytes4(0));
        vm.prank(a);
        book.multicall(0, bytes.concat(_header(), ops));
        _accept(nb, wd);
        _checkState();
        for (uint256 k; k < 4; ++k) {
            assertLt(bal[_ix(ids[k])], 1e24, "every one of the four accounts paid an escrow");
        }
        // four fresh orders on the same four accounts, then a deposit on the fifth
        bytes memory ops2;
        for (uint256 i; i < 4; ++i) {
            Order memory o = _newOrder(_rnd(2, i));
            o.mi = uint8((i >> 1) & 1);
            o.isBid = i & 1 == 1;
            ops2 = bytes.concat(ops2, OloOps.place(o.mi, o.tick, o.isBid, o.lots, o.pos));
        }
        vm.prank(a);
        vm.expectRevert(IOloBookBase.TooManyTokens.selector);
        book.multicall(0, bytes.concat(_header(), ops2, OloOps.deposit(ids[4], 1)));
        // the eight cancelled in one multicall, to the wallet: four pushes, the accounts untouched
        bytes memory cancels;
        LedgerRef.Ledger memory l2;
        for (uint256 i; i < 8; ++i) {
            (uint256 key, uint256 refund) = _refundOf(os[i]);
            cancels = bytes.concat(cancels, OloOps.cancel(os[i].mi, os[i].pos));
            LedgerRef.addMaker(l2, key, int256(refund));
        }
        nb = _copy(bal);
        wd = new int256[](6);
        assertEq(LedgerRef.commit(l2, 2, nb, wd), bytes4(0));
        vm.prank(a);
        book.multicall(2, bytes.concat(_header(), cancels));
        _accept(nb, wd);
        _checkState();
        for (uint256 k; k < 4; ++k) {
            assertGt(wd[_ix(ids[k])], 0, "every one of the four refunds was pushed");
        }
    }

    /// An escrow that takes an account's whole balance leaves its word USED (nonzero at a zero balance, so the
    /// next credit rewrites it rather than writing a fresh slot): the debit keeps the word's top bit. `_accounts` is
    /// storage slot 6 (OloLayout.t.sol holds the layout).
    function test_account_word_keeps_USED_when_an_escrow_empties_it() public {
        uint256 balance = book.balanceOf(ids[0], a);
        vm.startPrank(a);
        book.withdraw(address(base), balance - 5e6);
        book.place(OloOps.key(cs[0]), OloOps.placeW(false, T, 5 * LOT, _pos(), 0)); // an ask of 5 lots escrows 5e6 base wei
        vm.stopPrank();
        assertEq(book.balanceOf(ids[0], a), 0, "emptied");
        bytes32 slot = keccak256(abi.encode(OloSlots.ownedKey(ids[0], a), uint256(6)));
        assertEq(vm.load(address(book), slot), bytes32(ACCOUNT_USED), "USED stays on the emptied account");
    }

    /// Deposits and withdrawals on four tokens in one multicall settle every entry: the fourth as much as the first.
    function test_four_token_ops_settle_every_entry() public {
        bytes memory ops;
        LedgerRef.Ledger memory l;
        for (uint256 k; k < 4; ++k) {
            ops = bytes.concat(ops, OloOps.deposit(ids[k], uint128(1000 + k)), OloOps.withdraw(ids[k], uint128(1 + k)));
            LedgerRef.addToken(l, _ix(ids[k]), int256(1000 + k), -int256(1000 + k));
            LedgerRef.addToken(l, _ix(ids[k]), -int256(1 + k), int256(1 + k));
        }
        uint256[] memory nb = _copy(bal);
        int256[] memory wd = new int256[](6);
        assertEq(LedgerRef.commit(l, 0, nb, wd), bytes4(0));
        vm.prank(a);
        book.multicall(0, bytes.concat(_header(), ops));
        _accept(nb, wd);
        _checkState();
        for (uint256 k; k < 4; ++k) {
            assertEq(bal[_ix(ids[k])], 1e24 + 999, "deposit less withdrawal on every token");
        }
    }
}
