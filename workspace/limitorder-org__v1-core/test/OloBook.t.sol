// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloBase} from "./OloBase.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {IOwned2Step} from "../src/interfaces/IOwned2Step.sol";
import {AccountLib, KEY_BITS, KEY_MASK, KEY_OWNER_SHIFT, PoolLib, PoolWord} from "../src/OloTypes.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {BatchView} from "./BatchView.sol";
import {OloOps} from "./OloOps.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {BonusToken, FailingToken, FeeToken, ReentrantToken, SilentToken} from "./utils/HostileTokens.sol";
import {SafeTransfer} from "../src/libraries/SafeTransfer.sol";
import {
    C_BASE_ID,
    C_FEE_PPM,
    C_FEE_PPM_FIELD,
    C_FEE_PPM_MASK,
    C_KEY_MASK,
    C_MAKER_BPS,
    C_MAKER_BPS_FIELD,
    C_MAKER_BPS_MASK,
    C_MARKET_ID,
    C_MIN_QUOTE,
    C_MIN_QUOTE_MASK,
    C_QUOTE_ID,
    C_SPACING,
    C_SPACING_MASK,
    C_TAG,
    C_TAG_FIELD,
    C_TOKEN_ID_MASK,
    C_VERSION,
    MarketLib,
    TAG_CARRIED,
    TOKEN_ID_BITS
} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

using MarketLib for MarketWord;

/// The pool path and the OLO EVM contract around it: places, cancels, claims and modifies; takes and takeThenRest;
/// accounts, deposits and withdrawals; listing, the token registry and warming; the multicall; the entries' input
/// checks.
contract OloBookTest is OloBase {
    function setUp() public {
        _deploy();
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    function test_place_cancel_refund_and_pool_reuse() public {
        address a = _maker();
        uint256 before = _bal(a, base);
        vm.prank(a);
        (uint256 id,) = book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, 7, 0));
        assertEq(id, _orderId(c, 7), "id = pos | the version's tag << 206");
        assertEq(_bal(a, base), before - 5e6, "escrow");
        (uint256 tick, uint256 lots, uint256 filled, bool isBid, address owner) = book.orderOf(c, 7);
        assertEq(tick, T + 1);
        assertEq(lots, 5 * LOT);
        assertEq(filled, 0 * LOT);
        assertFalse(isBid);
        assertEq(owner, a);
        // a live position is nobody's to take, and only its owner acts on it
        address b = _maker();
        vm.prank(b);
        vm.expectRevert(IOloBookBase.SlotBusy.selector);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 2, 5 * LOT, 7, 0));
        vm.prank(b);
        vm.expectRevert(IOloBookBase.NotOrderOwner.selector);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(7, 0)));
        vm.prank(a);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(7, 0)));
        assertEq(_bal(a, base), before, "refund");
        assertTrue(book.orderWord(c, 7) != 0, "USED, the last owner kept");
        // the dead position is anyone's: b reuses it, as a bid
        vm.prank(b);
        book.place(OloOps.key(c), OloOps.placeW(true, T - 2, 3 * LOT, 7, 0));
        (tick, lots,, isBid, owner) = book.orderOf(c, 7);
        assertEq(tick, T - 2);
        assertEq(lots, 3 * LOT);
        assertTrue(isBid);
        assertEq(owner, b);
        vm.prank(a);
        vm.expectRevert(IOloBookBase.NotOrderOwner.selector);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(7, 0)));
        // a cancel leaves the word dead (USED, the side and the last owner) for the position's next order to rewrite;
        // bit 3 is no cancel flag
        vm.prank(b);
        vm.expectRevert(IOloBookBase.BadFlags.selector);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(7, 0x08)));
        vm.prank(b);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(7, 0)));
        assertEq(book.orderWord(c, 7), PoolLib.USED | (1 << 93) | (uint256(uint160(b)) << 96), "dead");
        _solvent();
    }

    function test_warm_pool() public {
        book.warmPool(m, 500, 4);
        assertEq(book.orderWord(c, 502), PoolLib.USED, "USED");
        address a = _maker();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, 502, 0));
        book.warmPool(m, 500, 4); // a live position is left alone
        (, uint256 lots,,,) = book.orderOf(c, 502);
        assertEq(lots, 5 * LOT);
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.warmPool(99, 0, 1);
    }

    /// Accounts are each owner's own: the key is owner and token, so two owners' accounts of a token are apart and
    /// nobody can deposit into another's (the fee pot is owner 0's). A zero balance leaves the account usable; an
    /// order's escrow and refunds use the caller's own accounts.
    function test_accounts() public {
        address a = _maker();
        address b = _maker();
        assertEq(book.balanceOf(baseId, a), 1e24);
        // b's deposit is b's own: a's account is untouched
        vm.prank(b);
        book.deposit(address(base), 3);
        assertEq(book.balanceOf(baseId, b), 1e24 + 3);
        assertEq(book.balanceOf(baseId, a), 1e24, "a's untouched");
        // b cannot spend more than b's own account holds
        vm.prank(b);
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        book.withdraw(address(base), 1e24 + 4);
        vm.prank(a);
        book.withdraw(address(base), 1e24);
        assertEq(book.balanceOf(baseId, a), 0);
        // emptied, the word keeps USED: the next credit rewrites a nonzero word
        bytes32 slot = _slotRead(abi.encodeCall(book.balanceOf, (baseId, a)));
        assertEq(uint256(vm.load(address(book), slot)), AccountLib.USED, "USED");
        vm.prank(a);
        book.deposit(address(base), 2);
        assertEq(book.balanceOf(baseId, a), 2, "an emptied account takes deposits again");
        assertEq(book.balanceOf(baseId, address(0)), 0, "the pot is owner 0's");
        vm.prank(a);
        book.deposit(address(base), 5e6 - 2);
        // an order's escrow and refunds use the caller's own account
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 2 * LOT, 9, 0));
        assertEq(book.balanceOf(baseId, a), 3e6);
        vm.prank(a);
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 9 * LOT, 10, 0)); // a's has 3e6
        vm.prank(a);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(9, 0)));
        assertEq(book.balanceOf(baseId, a), 5e6);
        _solvent();
    }

    /// No amount above an account's balance withdraws, however large (one above 2^255 must not read as a credit, and
    /// 2^255 itself reverts InsufficientBalance, not an overflow panic), and a deposit above 2^128 - 1, the most an
    /// account holds, is refused before anything is pulled.
    function test_amounts_past_an_account_revert() public {
        address a = _maker();
        uint256[4] memory tooMuch = [uint256(1e24 + 1), 1 << 128, 1 << 255, type(uint256).max];
        for (uint256 i; i < tooMuch.length; ++i) {
            vm.prank(a);
            vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
            book.withdraw(address(base), tooMuch[i]);
            vm.prank(a);
            vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
            book.withdrawTo(address(base), tooMuch[i], address(0xB0B));
        }
        uint256[3] memory tooBig = [uint256(1) << 128, 1 << 255, type(uint256).max];
        for (uint256 i; i < tooBig.length; ++i) {
            vm.prank(a);
            vm.expectRevert(IOloBookBase.AmountOverflow.selector);
            book.deposit(address(base), tooBig[i]);
        }
        assertEq(_bal(a, base), 1e24, "the account untouched");
        vm.prank(a);
        book.withdraw(address(base), 1e24);
        assertEq(_bal(a, base), 0, "the whole balance withdraws");
        // an empty account takes exactly 2^128 - 1
        address w = address(0xD0D0);
        base.mint(w, type(uint128).max);
        vm.startPrank(w);
        base.approve(address(book), type(uint256).max);
        book.deposit(address(base), type(uint128).max);
        vm.stopPrank();
        assertEq(book.balanceOf(baseId, w), type(uint128).max, "the most an account holds");
    }

    /// The contract does not count on the token to stop a transfer it cannot make. With a token that moves nothing and
    /// says nothing when asked for more than the sender holds, a withdrawal of 2^256 - 500,000 must not credit
    /// 500,000 (a negated amount read as a signed flow) for a later withdrawal to take from the other depositors: it
    /// reverts, the caller gets back only its own deposit, and every other depositor withdraws in full.
    function test_a_huge_withdrawal_takes_nothing_from_others() public {
        SilentToken s = new SilentToken();
        book.listMarketQuote(address(s), address(quote), 50, 6, 1, 0);
        uint256 id = book.tokenId(address(s));
        address victim = address(0x71C7);
        address caller = address(0xA11CE);
        s.mint(victim, 1_000_000);
        s.mint(caller, 100);
        vm.startPrank(victim);
        s.approve(address(book), type(uint256).max);
        book.deposit(address(s), 1_000_000);
        vm.stopPrank();
        vm.startPrank(caller);
        s.approve(address(book), type(uint256).max);
        book.deposit(address(s), 100);
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        book.withdraw(address(s), type(uint256).max - 499_999);
        vm.expectRevert(IOloBookBase.InsufficientBalance.selector);
        book.withdraw(address(s), 101);
        book.withdraw(address(s), 100);
        vm.stopPrank();
        assertEq(book.balanceOf(id, caller), 0);
        assertEq(s.balanceOf(caller), 100, "its own deposit back, no more");
        vm.prank(victim);
        book.withdraw(address(s), 1_000_000);
        assertEq(s.balanceOf(victim), 1_000_000, "the other depositor withdraws in full");
        assertEq(s.balanceOf(address(book)), 0);
    }

    /// A deposit must arrive exact: a token that delivers 1 wei more than asked is refused (FeeOnTransfer) as one that
    /// delivers less is, so an account is credited only what its transfer moved.
    function test_a_token_that_delivers_more_than_asked_is_refused() public {
        address a = address(0xA11CE);
        BonusToken t = new BonusToken();
        book.listMarketQuote(address(t), address(quote), 50, 6, 1, 0);
        t.mint(a, 1000);
        vm.startPrank(a);
        t.approve(address(book), type(uint256).max);
        vm.expectRevert(IOloBookBase.FeeOnTransfer.selector);
        book.deposit(address(t), 100);
        vm.stopPrank();
    }

    /// The contract credits only what arrives and pays only by a transfer that worked. A token that keeps 1% of a
    /// transfer in is refused (FeeOnTransfer): crediting 100 for the 99 that arrived would pay the 1 out of the other
    /// depositors. A withdrawal whose transfer returns false, reverts with no data, or meets no code at the token's
    /// address reverts TransferFailed and leaves the account as it was.
    function test_token_transfers_that_fail() public {
        address a = address(0xA11CE);
        FeeToken fee = new FeeToken();
        FailingToken t = new FailingToken();
        MockERC20 gone = new MockERC20("Gone", "GONE", 6);
        book.listMarketQuote(address(fee), address(quote), 50, 6, 1, 0);
        book.listMarketQuote(address(t), address(quote), 50, 6, 1, 0);
        book.listMarketQuote(address(gone), address(quote), 50, 6, 1, 0);
        fee.mint(a, 100);
        t.mint(a, 1e6);
        gone.mint(a, 1e6);
        vm.startPrank(a);
        fee.approve(address(book), type(uint256).max);
        t.approve(address(book), type(uint256).max);
        gone.approve(address(book), type(uint256).max);
        vm.expectRevert(IOloBookBase.FeeOnTransfer.selector);
        book.deposit(address(fee), 100);
        book.deposit(address(t), 1e6);
        book.deposit(address(gone), 1e6);
        vm.stopPrank();
        for (uint8 how = 1; how <= 2; ++how) {
            t.fail(how);
            vm.prank(a);
            vm.expectRevert(SafeTransfer.TransferFailed.selector);
            book.withdraw(address(t), 1e6);
            assertEq(book.balanceOf(book.tokenId(address(t)), a), 1e6, "the account as it was");
        }
        vm.etch(address(gone), "");
        vm.prank(a);
        vm.expectRevert(SafeTransfer.TransferFailed.selector);
        book.withdraw(address(gone), 1e6);
        assertEq(book.balanceOf(book.tokenId(address(gone)), a), 1e6, "no code, no payout");
        t.fail(0);
        vm.prank(a);
        book.withdraw(address(t), 1e6);
        assertEq(t.balanceOf(a), 1e6, "a working transfer pays out");
    }

    /// AUTO funds an escrow from the caller's own account first and pulls only the shortfall from the wallet, in a
    /// single place (`_fund`) and in a multicall's settlement (`_commit`).
    function test_auto_funding() public {
        address a = _maker();
        uint256 w0 = base.balanceOf(a);
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, 50, 0x04));
        assertEq(book.balanceOf(baseId, a), 1e24 - 5e6, "from the account");
        assertEq(base.balanceOf(a), w0, "nothing pulled");
        // 2e6 left in the account, a 5e6 escrow: 2e6 from it, 3e6 from the wallet
        vm.prank(a);
        book.withdraw(address(base), 1e24 - 7e6);
        w0 = base.balanceOf(a);
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 2, 5 * LOT, 51, 0x04));
        assertEq(book.balanceOf(baseId, a), 0);
        assertEq(w0 - base.balanceOf(a), 3e6, "the shortfall from the wallet");
        // a multicall settled AUTO: two 5e6 escrows with 4e6 in the account, 6e6 from the wallet
        vm.prank(a);
        book.deposit(address(base), 4e6);
        w0 = base.balanceOf(a);
        vm.prank(a);
        book.multicall(
            0x04,
            _mc(bytes.concat(OloOps.place(0, T + 3, false, 5 * LOT, 52), OloOps.place(0, T + 4, false, 5 * LOT, 53)))
        );
        assertEq(book.balanceOf(baseId, a), 0);
        assertEq(w0 - base.balanceOf(a), 6e6, "the multicall's shortfall");
        _solvent();
    }

    /// Listing needs significant figures 3 to 6; its tokens have code
    /// and differ, and a refused listing registers nothing. Only a listing registers a token,
    /// so deposits cannot fill the token registry: a deposit or a withdrawal of a token no listing registered reverts,
    /// and so does a zero deposit.
    function test_listing_and_token_registry() public {
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.listMarketQuote(address(base), address(quote), 50, 7, 1, 0);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.listMarketQuote(address(0), address(quote), 50, 6, 1, 0);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.listMarketQuote(address(base), taker, 50, 6, 1, 0);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.listMarketQuote(address(quote), address(quote), 50, 6, 1, 0);
        MockERC20 fresh = new MockERC20("Fresh", "F", 6);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.listMarketQuote(address(fresh), address(fresh), 50, 6, 1, 0);
        assertEq(book.tokenId(address(fresh)), 0, "a refused listing registers nothing");
        MockERC20 junk = new MockERC20("Junk", "J", 6);
        junk.mint(taker, 1e18);
        uint256 n0 = book.tokenCount();
        vm.startPrank(taker);
        junk.approve(address(book), type(uint256).max);
        vm.expectRevert(IOloBookBase.UnknownToken.selector);
        book.deposit(address(junk), 1e6);
        vm.expectRevert(IOloBookBase.UnknownToken.selector);
        book.withdraw(address(junk), 0);
        vm.expectRevert(IOloBookBase.ZeroSize.selector);
        book.deposit(address(base), 0);
        vm.stopPrank();
        vm.expectRevert(IOloBookBase.UnknownToken.selector);
        book.collectFees(address(junk));
        assertEq(book.tokenCount(), n0, "no token registered by a deposit");
        assertEq(book.tokenId(address(junk)), 0);
    }

    /// The extension's writing entries check the reentrancy lock: a token calling back into warmPool or listMarketQuote
    /// from inside a deposit's transfer is refused with Locked.
    function test_extension_entries_check_the_lock() public {
        ReentrantToken rt = new ReentrantToken();
        uint32 m2 = book.listMarketQuote(address(rt), address(quote), 50, 6, 1, 0);
        rt.mint(taker, 1e18);
        vm.prank(taker);
        rt.approve(address(book), type(uint256).max);
        rt.arm(address(book), abi.encodeCall(book.warmPool, (m2, 0, 1)));
        vm.prank(taker);
        book.deposit(address(rt), 1e6);
        assertEq(rt.attempts(), 1);
        assertFalse(rt.lastOk(), "warmPool refused inside the deposit");
        assertEq(bytes4(rt.lastRevert()), IOloBookBase.Locked.selector);
        rt.arm(address(book), abi.encodeCall(book.listMarketQuote, (address(rt), address(base), 50, 6, 1, 0)));
        vm.prank(taker);
        book.deposit(address(rt), 1e6);
        assertFalse(rt.lastOk(), "listMarketQuote refused inside the deposit");
        assertEq(bytes4(rt.lastRevert()), IOloBookBase.Locked.selector);
        assertEq(book.balanceOf(book.tokenId(address(rt)), taker), 2e6);
    }

    /// A wallet take, and a wallet takeThenRest, hold the reentrancy lock while they move tokens: a token calling back
    /// from inside the payout is refused (warmPool, which only needs the lock clear). The accounts in `p` are 0,
    /// unused by a wallet settlement, so no other bit of `p` stands in for the wallet bit.
    function test_wallet_take_holds_the_lock() public {
        ReentrantToken rt = new ReentrantToken();
        uint32 m2 = book.listMarketQuote(address(rt), address(quote), 50, 6, 1, 0);
        MarketWord c2 = book.configOf(m2);
        address a = _maker();
        rt.mint(a, 1e18);
        vm.startPrank(a);
        rt.approve(address(book), type(uint256).max);
        book.deposit(address(rt), 5e6);
        book.place(OloOps.key(c2), OloOps.placeW(false, T, 5 * LOT, 1, 0));
        book.deposit(address(rt), 5e6);
        book.place(OloOps.key(c2), OloOps.placeW(false, T, 5 * LOT, 2, 0));
        vm.stopPrank();
        rt.arm(address(book), abi.encodeCall(book.warmPool, (m2, 100, 1)));
        vm.prank(taker);
        (uint256 filled,) = book.take(
            OloOps.key(c2), OloOps.poolList(OloOps.poolEntry(1, T)), OloOps.tagW(c2, OloOps.takeW(true, 5 * LOT, 1))
        );
        assertEq(filled, 5 * LOT);
        assertEq(rt.balanceOf(taker), 5e6, "the base paid to the wallet");
        assertEq(rt.attempts(), 1, "the payout called back");
        assertFalse(rt.lastOk(), "refused inside the take");
        assertEq(bytes4(rt.lastRevert()), IOloBookBase.Locked.selector);
        rt.arm(address(book), abi.encodeCall(book.warmPool, (m2, 100, 1)));
        vm.prank(taker);
        (filled,,,) = book.takeThenRest(
            OloOps.key(c2),
            OloOps.poolList(OloOps.poolEntry(2, T)),
            OloOps.tagW(c2, OloOps.restW(true, 5 * LOT, T, 1, 50))
        );
        assertEq(filled, 5 * LOT, "filled in full: nothing rests");
        assertEq(rt.attempts(), 2, "the payout called back");
        assertFalse(rt.lastOk(), "refused inside the takeThenRest");
        assertEq(bytes4(rt.lastRevert()), IOloBookBase.Locked.selector);
    }

    /// The token called back (`attempts` so far) and the contract refused the call with Locked.
    function _refusedInside(ReentrantToken rt, uint256 attempts, string memory what) internal view {
        assertEq(rt.attempts(), attempts, what);
        assertFalse(rt.lastOk(), what);
        assertEq(bytes4(rt.lastRevert()), IOloBookBase.Locked.selector, what);
    }

    /// No entry runs inside another's token transfer. From inside a deposit of a token that calls back, every entry is
    /// refused with Locked: those that move only accounts (a place, cancel, claim, modify, take, takeThenRest or batch
    /// without the wallet flag), those that move tokens themselves (withdraw, withdrawTo, multicall, collectFees), a
    /// proprietary listing (the token an allowed lister and its policy an address with code, so that only the lock can
    /// stop it), and, with the token made the owner for the same reason, every one of the owner's setters.
    function test_no_entry_runs_inside_a_transfer() public {
        ReentrantToken rt = new ReentrantToken();
        uint32 m2 = book.listMarketQuote(address(rt), address(quote), 50, 6, 1, 0);
        MarketWord c2 = book.configOf(m2);
        book.setProprietaryListingAllowed(address(rt), true);
        rt.mint(taker, 1e18);
        vm.prank(taker);
        rt.approve(address(book), type(uint256).max);
        bytes memory list = OloOps.poolList(OloOps.poolEntry(1, T));
        bytes[12] memory calls = [
            abi.encodeCall(book.place, (OloOps.key(c2), OloOps.placeW(false, T, 5 * LOT, 1, 0))),
            abi.encodeCall(book.cancel, (OloOps.key(c2), OloOps.tagW(c2, OloOps.posW(1, 0)))),
            abi.encodeCall(book.claim, (OloOps.key(c2), OloOps.tagW(c2, OloOps.posW(1, 0)))),
            abi.encodeCall(book.modify, (OloOps.key(c2), OloOps.tagW(c2, OloOps.modifyW(1, T + 1, 5 * LOT, 0)))),
            abi.encodeCall(book.take, (OloOps.key(c2), list, OloOps.tagW(c2, OloOps.takeW(true, 5 * LOT, 0)))),
            abi.encodeCall(
                book.takeThenRest, (OloOps.key(c2), list, OloOps.tagW(c2, OloOps.restW(true, 5 * LOT, T, 0, 2)))
            ),
            OloOps.batchCalldata(book.manageBatchSubs.selector, c2, OloOps.postW(false, 0, T, 5 * LOT, 1)),
            abi.encodeCall(book.withdraw, (address(rt), 0)),
            abi.encodeCall(book.withdrawTo, (address(rt), 0, taker)),
            abi.encodeCall(book.multicall, (0, "")),
            abi.encodeCall(book.collectFees, (address(rt))),
            abi.encodeCall(book.listMarketQuoteProprietary, (address(rt), address(base), 50, 6, 1, 0, address(quote)))
        ];
        for (uint256 k; k < calls.length; ++k) {
            rt.arm(address(book), calls[k]);
            vm.prank(taker);
            book.deposit(address(rt), 1e6);
            _refusedInside(rt, k + 1, string(abi.encodePacked("entry ", vm.toString(k))));
        }
        book.transferOwnership(address(rt));
        vm.prank(address(rt));
        book.acceptOwnership();
        bytes[9] memory setters = [
            abi.encodeCall(book.setMarketMakerShare, (m2, 5_000)),
            abi.encodeCall(book.setMarketFee, (m2, 100, 0)),
            abi.encodeCall(book.setGlobalMakerShare, (5_000)),
            abi.encodeCall(book.setPairMakerShare, (address(rt), address(quote), 5_000, true)),
            abi.encodeCall(book.setGlobalFeeFloor, (100)),
            abi.encodeCall(book.setPairFeeFloor, (address(rt), address(quote), 100, true)),
            abi.encodeCall(book.setFeeRecipient, (taker)),
            abi.encodeCall(book.setCurrentListingFee, (1)),
            abi.encodeCall(book.setProprietaryListingAllowed, (taker, true))
        ];
        for (uint256 k; k < setters.length; ++k) {
            rt.arm(address(book), setters[k]);
            vm.prank(taker);
            book.deposit(address(rt), 1e6);
            _refusedInside(rt, calls.length + k + 1, string(abi.encodePacked("setter ", vm.toString(k))));
        }
        assertEq(book.balanceOf(book.tokenId(address(rt)), taker), 21e6, "every deposit went through");
        // and nothing the token asked for took effect
        assertEq(book.marketCount(), m2, "no market listed");
        assertEq(MarketWord.unwrap(book.configOf(m2)), MarketWord.unwrap(c2), "the market's fee and share as listed");
        assertEq(book.listingFeeCurrent(), 0, "the listing fee as it was");
        assertFalse(book.canListProprietaryMarkets(taker), "no lister allowed");
    }

    /// A place, a modify, a cancel, a claim and a batch post settled through the wallet hold the lock while they move
    /// the token: warmPool, which needs the lock clear, called back from inside each transfer is refused. The claim's
    /// is a bid's, whose proceeds are the base.
    function test_wallet_entries_hold_the_lock() public {
        ReentrantToken rt = new ReentrantToken();
        uint32 m2 = book.listMarketQuote(address(rt), address(quote), 50, 6, 1, 0);
        MarketWord c2 = book.configOf(m2);
        address a = _maker();
        rt.mint(a, 1e18);
        rt.mint(taker, 1e18);
        vm.prank(a);
        rt.approve(address(book), type(uint256).max);
        vm.startPrank(taker);
        rt.approve(address(book), type(uint256).max);
        book.deposit(address(rt), 1e8);
        vm.stopPrank();
        bytes memory warm = abi.encodeCall(book.warmPool, (m2, 100, 1));
        rt.arm(address(book), warm);
        vm.prank(a);
        book.place(OloOps.key(c2), OloOps.placeW(false, T, 5 * LOT, 1, 0x02));
        _refusedInside(rt, 1, "place: the escrow pulled");
        rt.arm(address(book), warm);
        vm.prank(a);
        book.modify(OloOps.key(c2), OloOps.tagW(c2, OloOps.modifyW(1, T, 6 * LOT, 0x02)));
        _refusedInside(rt, 2, "modify: the added lot pulled");
        rt.arm(address(book), warm);
        vm.prank(a);
        book.cancel(OloOps.key(c2), OloOps.tagW(c2, OloOps.posW(1, 0x02)));
        _refusedInside(rt, 3, "cancel: the refund paid");
        vm.prank(a);
        book.place(OloOps.key(c2), OloOps.placeW(true, T, 5 * LOT, 2, 0));
        vm.prank(taker);
        book.take(
            OloOps.key(c2), OloOps.poolList(OloOps.poolEntry(2, T)), OloOps.tagW(c2, OloOps.takeW(false, 5 * LOT, 0))
        );
        rt.arm(address(book), warm);
        vm.prank(a);
        book.claim(OloOps.key(c2), OloOps.tagW(c2, OloOps.posW(2, 0x02)));
        _refusedInside(rt, 4, "claim: the bid's base paid");
        rt.arm(address(book), warm);
        vm.prank(a);
        _mb(c2, OloOps.ladderW(OloOps.POST, false, 0, 0x02, T, 5, 1, 1));
        _refusedInside(rt, 5, "batch: the escrow pulled");
    }

    /// No zero address where it would lose tokens. An OLO EVM contract whose extension is address(0) does not deploy:
    /// its listing and admin calls would delegate to no code and quietly do nothing. A withdrawal to address(0), and a
    /// fee recipient of address(0) (which collectFees pays), are refused.
    function test_zero_addresses() public {
        bytes memory init = bytes.concat(
            vm.getCode(vm.exists(BOOK) ? BOOK : "OloBook.sol:OloBook"), abi.encode(address(this), address(0), 0)
        );
        address made;
        bytes4 err;
        assembly ("memory-safe") {
            made := create(0, add(init, 0x20), mload(init))
            if iszero(made) {
                returndatacopy(0x00, 0x00, 4)
                err := and(mload(0x00), shl(224, 0xffffffff))
            }
        }
        assertEq(made, address(0), "no book without an extension");
        assertEq(err, IOloBookBase.BadAddress.selector);
        address a = _maker();
        vm.prank(a);
        vm.expectRevert(IOloBookBase.BadAddress.selector);
        book.withdrawTo(address(base), 1, address(0));
        vm.expectRevert(IOloBookBase.BadAddress.selector);
        book.setFeeRecipient(address(0));
    }

    /// The OLO EVM contract is no recipient: a withdrawal to it would debit the account and move nothing (a standard
    /// ERC-20's transfer to self), stranding the amount; a fee recipient of the contract would have every collection
    /// zero the pot and strand it (collectFees is anyone's to call). Both revert BadAddress and change nothing; the
    /// constructor refuses it too.
    function test_the_book_is_no_recipient() public {
        address a = _maker();
        uint256 held = _bal(a, base);
        uint256 reserve = base.balanceOf(address(book));
        vm.prank(a);
        vm.expectRevert(IOloBookBase.BadAddress.selector);
        book.withdrawTo(address(base), 1, address(book));
        assertEq(_bal(a, base), held, "the account is untouched");
        assertEq(base.balanceOf(address(book)), reserve);
        address recipient = book.feeRecipient();
        vm.expectRevert(IOloBookBase.BadAddress.selector);
        book.setFeeRecipient(address(book));
        assertEq(book.feeRecipient(), recipient, "the recipient is unchanged");
        // the constructor: an OLO EVM contract whose fee recipient would be its own address is not made
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes memory init = bytes.concat(
            vm.getCode(vm.exists(BOOK) ? BOOK : "OloBook.sol:OloBook"), abi.encode(predicted, book.ext(), 0)
        );
        address made;
        bytes4 err;
        assembly ("memory-safe") {
            made := create(0, add(init, 0x20), mload(init))
            if iszero(made) {
                returndatacopy(0x00, 0x00, 4)
                err := and(mload(0x00), shl(224, 0xffffffff))
            }
        }
        assertEq(made, address(0), "no book paying fees to itself");
        assertEq(err, IOloBookBase.BadAddress.selector);
    }

    /// The extension must have code: a delegatecall to an address without code succeeds with empty return data, so an
    /// OLO EVM contract made with a wallet, or with its own address (no code while it is being made), as its extension
    /// would take a listing's fee and list nothing, and no admin entry would do anything, for good (`ext` is
    /// immutable).
    function test_the_extension_must_have_code() public {
        address[2] memory bad = [address(0xE0A), vm.computeCreateAddress(address(this), vm.getNonce(address(this)))];
        for (uint256 i; i < 2; ++i) {
            bytes memory init = bytes.concat(
                vm.getCode(vm.exists(BOOK) ? BOOK : "OloBook.sol:OloBook"), abi.encode(address(this), bad[i], 0)
            );
            address made;
            bytes4 err;
            assembly ("memory-safe") {
                made := create(0, add(init, 0x20), mload(init))
                if iszero(made) {
                    returndatacopy(0x00, 0x00, 4)
                    err := and(mload(0x00), shl(224, 0xffffffff))
                }
            }
            assertEq(made, address(0), "no book on an extension without code");
            assertEq(err, IOloBookBase.BadAddress.selector);
        }
    }

    /// `balanceOf` refuses an id past the registry's 32 bits: the key is id | owner << 32, so such an id would read
    /// another owner's account (here the maker's, asked for as "owner 0's").
    function test_balance_of_refuses_an_id_past_the_registry() public {
        address a = _maker();
        assertEq(book.balanceOf(baseId, a), 1e24);
        uint256 spilled = baseId | (uint256(uint160(a)) << 32); // the maker's key, as an id
        vm.expectRevert(IOloBookBase.UnknownToken.selector);
        book.balanceOf(spilled, address(0));
        vm.expectRevert(IOloBookBase.UnknownToken.selector);
        book.balanceOf(1 << 32, a);
        assertEq(book.balanceOf((1 << 32) - 1, a), 0, "the last id of the registry: an account never written");
    }

    /// An op with nothing to act on reverts rather than doing nothing: a claim of an order nothing filled
    /// (NothingToClaim), a modify of a cancelled order (NoOrder: a dead word keeps its owner, so without the check the
    /// modify would re-open it, logged as Modified rather than Placed), and a take of 0 lots (ZeroSize).
    function test_ops_with_nothing_to_act_on() public {
        address a = _plain(T + 1, false, 5 * LOT);
        uint32 pos = posOf[a];
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.NothingToClaim.selector);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pos, T + 2, 5 * LOT, 0)));
        vm.stopPrank();
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.ZeroSize.selector);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, 0 * LOT, 0)));
    }

    /// Only the owner sets the shares and the fee recipient or proposes a new owner, and only the proposed owner
    /// accepts: a stranger able to set the fee recipient could collect the pot. Once a new owner accepts, the old one
    /// can do none of it.
    function test_owner_entries() public {
        address stranger = address(0x5157);
        address next = address(0x4E87);
        vm.startPrank(stranger);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setMarketMakerShare(m, 5_000);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setGlobalMakerShare(5_000);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setFeeRecipient(stranger);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.transferOwnership(stranger);
        vm.expectRevert(IOwned2Step.NotPendingOwner.selector);
        book.acceptOwnership();
        vm.stopPrank();
        book.transferOwnership(next);
        assertEq(book.pendingOwner(), next);
        vm.prank(stranger);
        vm.expectRevert(IOwned2Step.NotPendingOwner.selector);
        book.acceptOwnership();
        vm.prank(next);
        book.acceptOwnership();
        assertEq(book.owner(), next);
        assertEq(book.pendingOwner(), address(0));
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setFeeRecipient(address(this));
        vm.prank(next);
        book.setFeeRecipient(next);
        assertEq(book.feeRecipient(), next);
    }

    /// A pool order's owner is the maker's whole address, so no twin address sharing its low 128 bits (a CREATE2 pair
    /// a deployer could grind in about 2^64 hashes) can act on the order. The maker's address has its top 32 bits
    /// set (the other tests' makers have them zero, where a 128-bit tag would look whole); its twin, without them,
    /// cannot cancel, claim or modify the order, alone or in a multicall.
    function test_owner_is_the_whole_address() public {
        address a = _makerAt(address(uint160(0x5080) | (uint160(0xdeadbeef) << 128)));
        address twin = address(uint160(a) ^ (uint160(0xdeadbeef) << 128));
        uint32 pos = _pos();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 2, 5 * LOT, pos, 0));
        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(pos, T + 2)), OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0))
        );
        assertEq(uint128(uint160(twin)), uint128(uint160(a)), "the same low 128 bits");
        assertEq(book.orderWord(c, pos) >> 96, uint160(a), "the word holds the whole address");
        vm.startPrank(twin);
        vm.expectRevert(IOloBookBase.NotOrderOwner.selector);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        vm.expectRevert(IOloBookBase.NotOrderOwner.selector);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        vm.expectRevert(IOloBookBase.NotOrderOwner.selector);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pos, T + 3, 3 * LOT, 0)));
        vm.expectRevert(IOloBookBase.NotOrderOwner.selector);
        book.multicall(0, _mc(OloOps.cancel(0, pos)));
        vm.stopPrank();
        (, uint256 lots, uint256 filled,, address owner) = book.orderOf(c, pos);
        assertEq(owner, a);
        assertEq(lots, 3 * LOT);
        assertEq(filled, 2 * LOT);
        vm.prank(a);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        _solvent();
    }

    /// A pool order holds fewer than 2^30 units of 10^q (its open and filled fields are 30 bits): the largest amount
    /// the params carry, 2^112 - 1 base wei, rests as q 25; an order at the units' bound fills in full and claims with
    /// its side and owner intact (its open and filled never sum past the bound, so filled never carries).
    function test_pool_max_units() public {
        uint256 max = (1 << 30) - 1; // units at q 0
        uint32 pos = 9_000_001;
        address a = _maker();
        vm.startPrank(a);
        book.place(OloOps.key(c), OloOps.placeW(true, T, max, pos, 0));
        vm.stopPrank();
        vm.startPrank(taker);
        // in two takes (the second of 2 wei: a sell of 1 wei at P = 1 would receive nothing, SellBelowFee)
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(pos, T)), OloOps.tagW(c, OloOps.takeW(false, max - 2, 0))
        );
        book.take(OloOps.key(c), OloOps.poolList(OloOps.poolEntry(pos, T)), OloOps.tagW(c, OloOps.takeW(false, 2, 0)));
        vm.stopPrank();
        (uint256 tick, uint256 lots, uint256 filled, bool isBid, address owner) = book.orderOf(c, pos);
        assertEq(tick, T);
        assertEq(lots, 0);
        assertEq(filled, max);
        assertTrue(isBid);
        assertEq(owner, a);
        uint256 b0 = _bal(a, base);
        vm.prank(a);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        assertEq(_bal(a, base) - b0, max, "the whole fill");
        assertEq(book.orderWord(c, pos), PoolLib.USED | (1 << 93) | (uint256(uint160(a)) << 96), "dead");
        // one past the units' bound is q 1: 107,374,182 units of 10 (4 wei dropped)
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T, max + 1, pos, 0));
        PoolWord w = PoolWord.wrap(book.orderWord(c, pos));
        assertEq(w.qOf(), 1);
        assertEq(w.openOf(), 107_374_182);
        _solvent();
    }

    /// One error for a size out of range: zero, or under the market's minQuote at its tick (a place, a modify, a batch
    /// sub-order); the fixture's minQuote is 1 quote wei, so 1 base wei at T (P = 1) rests and nothing smaller does.
    function test_size_out_of_range() public {
        uint32 pos = 9_000_002;
        address a = _maker();
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.SizeOutOfRange.selector);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 0, pos, 0));
        // 1 base wei just below T is worth 0.999999 quote wei: under minQuote
        vm.expectRevert(IOloBookBase.SizeOutOfRange.selector);
        book.place(OloOps.key(c), OloOps.placeW(false, T - 1, 1, pos, 0));
        book.place(OloOps.key(c), OloOps.placeW(false, T, 1, pos, 0));
        vm.expectRevert(IOloBookBase.SizeOutOfRange.selector);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pos, T + 2, 0, 0)));
        uint256[4] memory low = [OloOps.sub(T + 1, 5 * LOT), OloOps.sub(T + 2, 0), 0, 0];
        vm.expectRevert(IOloBookBase.SizeOutOfRange.selector);
        _mb(c, OloOps.batchW(OloOps.POST, false, 0, 0, 0, low));
        base.mint(a, 1 << 112);
        book.deposit(address(base), (1 << 112) - 1);
        _mb(c, OloOps.batchW(OloOps.POST, false, 0, 0, 0, [OloOps.sub(T + 1, (1 << 112) - 1), 0, 0, 0]));
        vm.stopPrank();
        (uint256 word,) = book.batchOf(c, a, 0);
        assertEq(BatchView.openOf(word, 0), uint256((1 << 112) - 1) / 1e25 * 1e25, "the largest sub-order posts, q 25");
    }

    /// A tick off the grid (0, past 66,599,999) or off the spacing reverts TickOutOfRange in a place, a modify and a
    /// batch order; the grid's ends rest.
    function test_ticks_out_of_range() public {
        uint256 hi = PriceGrid.MAX_TICK;
        uint32 pos = 9_000_010;
        address a = _maker();
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.place(OloOps.key(c), OloOps.placeW(false, 0, 5 * LOT, pos, 0));
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.place(OloOps.key(c), OloOps.placeW(false, hi + 1, 5 * LOT, pos, 0));
        book.place(OloOps.key(c), OloOps.placeW(false, T, 5 * LOT, pos, 0));
        book.place(OloOps.key(c), OloOps.placeW(false, hi, 5 * LOT, pos + 1, 0));
        vm.stopPrank();
        // the makers' floor, decade 4's first tick (P = 1e-34): 1 wei there rests where minQuote is 0, the tick below
        // it and the grid's bottom do not (OloMakerFloor has every maker entry)
        MarketWord c0 = book.configOf(book.listMarketQuote(address(base), address(quote), 50, 6, 0, 0));
        uint256 floor = PriceGrid.MIN_MAKER_TICK;
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.place(OloOps.key(c0), OloOps.placeW(false, 1, 1, 1, 0));
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.place(OloOps.key(c0), OloOps.placeW(false, floor - 1, 1, 1, 0));
        book.place(OloOps.key(c0), OloOps.placeW(false, floor, 1, 1, 0));
        vm.stopPrank();
        (uint256 t1, uint256 o1,,,) = book.orderOf(c0, 1);
        assertEq(t1, floor);
        assertEq(o1, 1);
        vm.startPrank(a);
        uint256[3] memory outside = [uint256(0), hi + 1, (1 << 26) - 1];
        for (uint256 k; k < outside.length; ++k) {
            vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
            book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pos, outside[k], 5 * LOT, 0)));
        }
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pos, hi, 5 * LOT, 0)));
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pos + 1, T, 5 * LOT, 0)));
        uint256 atT = OloOps.sub(T, 5 * LOT);
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        _mb(c, OloOps.batchW(OloOps.POST, false, 0, 0, 0, [atT, OloOps.sub(0, 5 * LOT), 0, 0]));
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        _mb(c, OloOps.batchW(OloOps.POST, false, 0, 0, 0, [atT, OloOps.sub(hi + 1, 5 * LOT), 0, 0]));
        _mb(c, OloOps.batchW(OloOps.POST, false, 0, 0, 0, [OloOps.sub(hi, 5 * LOT), atT, 0, 0]));
        vm.stopPrank();
        (uint256 word,) = book.batchOf(c, a, 0);
        assertEq(BatchView.tickOf(word, 0), hi, "a batch at the grid's top posts");
        // off the spacing on a 4-figure market
        MarketWord c4 = book.configOf(book.listMarketQuote(address(base), address(quote), 50, 4, 1, 0));
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.place(OloOps.key(c4), OloOps.placeW(false, T + 10, 5 * LOT, 1, 0));
        book.place(OloOps.key(c4), OloOps.placeW(false, T + 100, 5 * LOT, 1, 0));
        vm.stopPrank();
    }

    /// A tick past the grid never reaches a position, so no take prices one: a maker moving the ask a taker listed at
    /// T + 1 past MAX_TICK, or to 0, before the take lands is refused, and the take pays T + 1's price.
    function test_a_tick_off_the_grid_cannot_overcharge_a_taker() public {
        address a = _plain(T + 1, false, 5 * LOT);
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[a], (1 << 26) - 1, 5 * LOT, 0)));
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[a], 0, 5 * LOT, 0)));
        vm.stopPrank();
        uint256 q0 = _bal(taker, quote);
        vm.prank(taker);
        (uint256 filled, uint256 quoteAmount) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0)));
        assertEq(filled, 5 * LOT);
        assertEq(quoteAmount, 5_000_050 + 251, "5 LOT at T + 1 and the fee, ceil(250.0025)");
        assertEq(q0 - _bal(taker, quote), quoteAmount);
    }

    function test_take_buy_partial_and_claim() public {
        address a = _plain(T + 1, false, 5 * LOT);
        uint256 qBefore = _bal(taker, quote);
        uint256 bBefore = _bal(taker, base);
        vm.prank(taker);
        (uint256 filled, uint256 quoteAmount) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0)));
        assertEq(filled, 2 * LOT);
        assertEq(filled, 2e6);
        assertEq(quoteAmount, 2_000_020 + 101); // fee ceil(100.001)
        assertEq(_bal(taker, quote), qBefore - quoteAmount);
        assertEq(_bal(taker, base), bBefore + 2e6);
        (, uint256 lots, uint256 f,,) = book.orderOf(c, posOf[a]);
        assertEq(lots, 3 * LOT);
        assertEq(f, 2 * LOT);
        uint256 mq = _bal(a, quote);
        vm.prank(a);
        uint256 proceeds = book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], 0)));
        assertEq(proceeds, 2_000_020);
        assertEq(_bal(a, quote), mq + 2_000_020 + 100);
        assertEq(_pot(quote), 0, "no protocol share");
        (, lots, f,,) = book.orderOf(c, posOf[a]);
        assertEq(lots, 3 * LOT);
        assertEq(f, 0 * LOT);
        _solvent();
    }

    function test_take_skips_dead_wrong_side_and_repriced() public {
        address a = _plain(T + 1, false, 5 * LOT);
        address b = _plain(T + 2, false, 5 * LOT);
        address cc = _plain(T + 3, false, 5 * LOT);
        address d = _plain(T + 1, false, 5 * LOT);
        address e = _plain(T - 1, true, 5 * LOT); // a bid at its own tick: the wrong side for a buy
        bytes memory entries = bytes.concat(
            _poolEntry(a), _poolEntry(b), _poolEntry(cc), _poolEntry(d), _poolEntry(e), OloOps.poolEntry(9999, T + 1)
        );
        // after the list is built: b cancels, cc moves its price up a tick
        vm.prank(b);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[b], 0)));
        vm.prank(cc);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[cc], T + 4, 5 * LOT, 0)));
        vm.prank(taker);
        (uint256 filled, uint256 quoteAmount) =
            book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(true, 20 * LOT, 0)));
        // a: 5, b dead, cc above the listed tick, d: 5, e wrong side, 9999 never placed
        assertEq(filled, 10 * LOT);
        assertEq(quoteAmount, 10 * _lq(T + 1) + 501);
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.FokNotFilled.selector);
        book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(true, 20 * LOT, 0x80)));
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.BadTakeList.selector);
        book.take(OloOps.key(c), OloOps.poolList(hex"0000"), OloOps.tagW(c, OloOps.takeW(true, 20 * LOT, 0)));
        // a wrong config word finds no orders at all
        vm.prank(taker);
        (filled,) = book.take(
            OloOps.key(_wrongC()), OloOps.poolList(entries), OloOps.tagW(_wrongC(), OloOps.takeW(true, 20 * LOT, 0))
        );
        assertEq(filled, 0 * LOT, "wrong C: nothing matches");
        _solvent();
    }

    function test_take_sell_and_fee_split() public {
        _setMarketShare(8_000);
        address a = _plain(T - 1, true, 5 * LOT);
        vm.prank(taker);
        (uint256 filled, uint256 quoteAmount) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(false, 5 * LOT, 0)));
        assertEq(filled, 5 * LOT);
        assertEq(filled, 5e6);
        assertEq(quoteAmount, 5 * _lq(T - 1) - 250, "5 lots at T - 1 less the fee, ceil(249.99975)");
        assertEq(_pot(quote), 0, "the take holds the fee");
        uint256 q = _bal(a, quote);
        vm.prank(a);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], 0)));
        // the fill's fee floor(249.9975) = 249: the maker floor(249 x 80%) = 199, the pot 50, at the settle
        assertEq(_bal(a, quote), q + 199, "maker share at the settle");
        assertEq(_pot(quote), 50);
        uint256 w = quote.balanceOf(address(this));
        book.collectFees(address(quote));
        assertEq(quote.balanceOf(address(this)), w + 50);
        assertEq(_pot(quote), 0);
        _solvent();
    }

    /// A take names each position with the tick it saw, the most it pays there. A maker who sees the
    /// take coming and reprices its named order worse, or anyone who re-places a dead named position at a worse tick,
    /// is skipped, so the taker pays at most the listed prices; a size-only change or the same tick re-placed still
    /// fills (a takeThenRest's limit does not bound entries either).
    function test_take_entry_bounds_the_price() public {
        address a = _plain(T + 100, false, 5 * LOT);
        address b = _plain(T + 200, false, 5 * LOT);
        bytes memory entries = bytes.concat(_poolEntry(a), _poolEntry(b));
        uint256 worse = T + 2_200; // 2% over the listed prices
        vm.prank(b);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[b], worse, 5 * LOT, 0)));
        vm.prank(taker);
        (uint256 filled, uint256 quoteAmount) =
            book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(true, 10 * LOT, 0)));
        assertEq(filled, 5 * LOT, "b repriced: skipped");
        assertEq(quoteAmount, 5 * _lq(T + 100) + 251, "a at its listed price");
        // b back at the listed tick with fewer lots: the entry fills at the listed price
        vm.prank(b);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[b], T + 200, 3 * LOT, 0)));
        vm.prank(taker);
        (filled, quoteAmount) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(b)), OloOps.tagW(c, OloOps.takeW(true, 10 * LOT, 0)));
        assertEq(filled, 3 * LOT, "same tick, fewer lots");
        assertEq(quoteAmount, 3 * _lq(T + 200) + 151);
        // a's position, dead after its claim, re-placed by x at a worse tick: skipped; at the listed tick: fills
        vm.prank(a);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], 0)));
        address x = _maker();
        vm.prank(x);
        book.place(OloOps.key(c), OloOps.placeW(false, worse, 5 * LOT, posOf[a], 0));
        vm.prank(taker);
        (filled,) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, 10 * LOT, 0)));
        assertEq(filled, 0 * LOT, "re-placed at another tick: skipped");
        vm.prank(x);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[a], T + 100, 5 * LOT, 0)));
        vm.prank(taker);
        (filled,) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, 10 * LOT, 0)));
        assertEq(filled, 5 * LOT, "at the listed tick: fills");
        // the entry's tick bounds the price: a takeThenRest's limit below it does not stop the entry
        address y = _plain(T + 300, false, 5 * LOT);
        vm.prank(taker);
        (filled,,,) = book.takeThenRest(
            OloOps.key(c), OloOps.poolList(_poolEntry(y)), OloOps.tagW(c, OloOps.restW(true, 5 * LOT, T + 50, 0, 88))
        );
        assertEq(filled, 5 * LOT, "entries are priced by the taker");
        _solvent();
    }

    /// An order repriced or re-placed at a better tick than its entry names fills at its own tick, for a buy and a
    /// sell, and the protocol's part follows that tick; one tick worse, or the other side at a better number, is
    /// skipped.
    function test_take_entry_fills_at_a_better_tick() public {
        _setMarketShare(8_000);
        address a = _plain(T + 10_000, false, 5 * LOT);
        address b = _plain(T - 10_000, true, 5 * LOT);
        // after the list is built both move to T: better for a buyer of a's ask and a seller to b's bid
        vm.prank(a);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[a], T, 5 * LOT, 0)));
        vm.prank(b);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[b], T, 5 * LOT, 0)));
        vm.prank(taker);
        (uint256 filled, uint256 quoteAmount) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0)));
        assertEq(filled, 5 * LOT);
        assertEq(quoteAmount, 5 * _lq(T) + 250, "at a's tick, not the listed 110,000");
        vm.prank(taker);
        (filled, quoteAmount) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(b)), OloOps.tagW(c, OloOps.takeW(false, 5 * LOT, 0)));
        assertEq(filled, 5 * LOT);
        assertEq(quoteAmount, 5 * _lq(T) - 250, "at b's tick, not the listed 90,000");
        vm.prank(a);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], 0)));
        vm.prank(b);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[b], 0)));
        assertEq(_pot(quote), 100, "the protocol's parts at the orders' ticks (55 + 45 at the listed ones)");
        // d's position, dead after its cancel, re-placed by x at a better tick: x's order fills there
        address d = _plain(T + 100, false, 5 * LOT);
        vm.prank(d);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[d], 0)));
        address x = _maker();
        vm.prank(x);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 50, 5 * LOT, posOf[d], 0));
        vm.prank(taker);
        (filled, quoteAmount) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(d)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0)));
        assertEq(filled, 5 * LOT);
        assertEq(quoteAmount, 5 * _lq(T + 50) + 251, "x's order at its tick");
        (uint256 t,, uint256 xFilled,, address owner) = book.orderOf(c, posOf[d]);
        assertEq(t, T + 50);
        assertEq(xFilled, 5 * LOT);
        assertEq(owner, x);
        // one tick worse each way: skipped
        address e = _plain(T + 100, false, 5 * LOT);
        address g = _plain(T - 100, true, 5 * LOT);
        vm.prank(e);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[e], T + 101, 5 * LOT, 0)));
        vm.prank(g);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[g], T - 101, 5 * LOT, 0)));
        vm.prank(taker);
        (filled,) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(e)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0)));
        assertEq(filled, 0 * LOT, "an ask a tick above the entry");
        vm.prank(taker);
        (filled,) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(g)), OloOps.tagW(c, OloOps.takeW(false, 5 * LOT, 0)));
        assertEq(filled, 0 * LOT, "a bid a tick below the entry");
        // the other side at a better number: a bid where a buy listed an ask, an ask where a sell listed a bid
        vm.prank(e);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[e], 0)));
        vm.prank(g);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[g], 0)));
        vm.startPrank(x);
        book.place(OloOps.key(c), OloOps.placeW(true, T + 50, 5 * LOT, posOf[e], 0));
        book.place(OloOps.key(c), OloOps.placeW(false, T - 50, 5 * LOT, posOf[g], 0));
        vm.stopPrank();
        vm.prank(taker);
        (filled,) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(e)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 0)));
        assertEq(filled, 0 * LOT, "a bid in an ask's entry");
        vm.prank(taker);
        (filled,) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(g)), OloOps.tagW(c, OloOps.takeW(false, 5 * LOT, 0)));
        assertEq(filled, 0 * LOT, "an ask in a bid's entry");
        _solvent();
    }

    /// Any order against any entry tick, either side each: it fills iff it is on the side the take consumes at the
    /// entry's tick or better, at its own tick. An entry tick is 4 bytes, compared unsigned: an entry below every tick
    /// stops a buy and lets a sell through.
    function testFuzz_take_entry_bounds_the_price(uint256 seed, uint32 entry, bool isBid, bool buy) public {
        uint256 tick = T - 400_000 + seed % 800_001; // decades 37 and 38, exact LOT prices
        if ((seed >> 128) % 2 == 0) entry = uint32(tick + (seed >> 64) % 7 - 3); // near the order's tick
        address a = _plain(tick, isBid, 5 * LOT);
        vm.prank(taker);
        (uint256 filled, uint256 quoteAmount) = book.take(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntry(posOf[a], entry)),
            OloOps.tagW(c, OloOps.takeW(buy, 5 * LOT, 0))
        );
        bool fills = buy ? !isBid && tick <= entry : isBid && tick >= entry;
        assertEq(filled, fills ? 5 * LOT : 0);
        if (fills) {
            uint256 q = 5 * _lq(tick);
            uint256 fee = (q * 50 + 999_999) / 1_000_000;
            assertEq(quoteAmount, buy ? q + fee : q - fee);
        }
        _solvent();
    }

    /// A take collects the fee rounded up and a settle splits the order's fee, floored once over its fills, so an
    /// order filled in pieces pays out no more fee than its takers paid: everyone can withdraw everything after.
    function test_fee_rounding_stays_in_the_book() public {
        _setMarketShare(8_000);
        uint256 t = T + 2_000; // a 1-lot fill's fee is 51 exactly (px 1,020,000 x 50 ppm): no take rounds it up
        address a = _plain(t, false, 5 * LOT);
        address b = _plain(t, true, 5 * LOT);
        for (uint256 i; i < 5; ++i) {
            vm.startPrank(taker);
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, 1 * LOT, 0)));
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(b)), OloOps.tagW(c, OloOps.takeW(false, 1 * LOT, 0)));
            vm.stopPrank();
        }
        // ten fills paid 51 each, held by the contract until the makers settle
        assertEq(_pot(quote), 0, "nothing at the takes");
        uint256 qa = _bal(a, quote);
        uint256 qb = _bal(b, quote);
        uint256 bb = _bal(b, base);
        vm.prank(a);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], 0)));
        vm.prank(b);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[b], 0)));
        // an order's fee 5 x 51 = 255: the maker floor(255 x 80%) = 204, the pot 51
        assertEq(_bal(a, quote), qa + 5 * _lq(T + 2_000) + 204, "ask: proceeds and share");
        assertEq(_bal(b, quote), qb + 204, "bid: share");
        assertEq(_bal(b, base), bb + 5e6, "bid: proceeds");
        assertEq(_pot(quote), 102, "the protocol's parts");
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertEq(baseLeft, 0);
        assertEq(quoteLeft, 510 - 2 * 204 - 102, "nothing owed");
    }

    function test_modify_in_place() public {
        address a = _plain(T + 1, false, 5 * LOT);
        uint256 b0 = _bal(a, base);
        vm.prank(a);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[a], T + 3, 5 * LOT, 0)));
        assertEq(_bal(a, base), b0);
        (uint256 tick, uint256 lots,,,) = book.orderOf(c, posOf[a]);
        assertEq(tick, T + 3);
        assertEq(lots, 5 * LOT);
        (uint16 bps,,) = book.makerShareOf(c);
        assertEq(bps, 10_000);
        vm.prank(a);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[a], T + 3, 8 * LOT, 0)));
        assertEq(_bal(a, base), b0 - 3e6);
        vm.prank(a);
        vm.expectRevert(IOloBookBase.NoChange.selector);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[a], T + 3, 8 * LOT, 0)));
        // a share change makes the market's next version: the order rests in the version it was placed in, whose share
        // its fills settle at, and that version rests no new order (a modify reverts MarketFrozen; a cancel settles)
        MarketWord v1 = c;
        _setMarketShare(8_000);
        vm.prank(a);
        vm.expectRevert(IOloBookBase.MarketFrozen.selector);
        book.modify(OloOps.key(v1), OloOps.tagW(v1, OloOps.modifyW(posOf[a], T + 3, 6 * LOT, 0)));
        (bps,,) = book.makerShareOf(c);
        assertEq(bps, 8_000, "the market's share now");
        (bps,,) = book.makerShareOf(v1);
        assertEq(bps, 0, "an older version: no share read back");
        vm.prank(a);
        book.cancel(OloOps.key(v1), OloOps.tagW(v1, OloOps.posW(posOf[a], 0)));
        a = _plain(T + 3, false, 6 * LOT); // in the new version
        address d = _plain(T - 1, true, 5 * LOT);
        uint256 q0 = _bal(d, quote);
        vm.prank(d);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[d], T - 3, 5 * LOT, 0)));
        assertEq(_bal(d, quote), q0 + 5 * (_lq(T - 1) - _lq(T - 3)), "the bid's escrow shrinks by the step");
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntry(posOf[a], T + 3)),
            OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0))
        );
        uint256 q1 = _bal(a, quote);
        vm.prank(a);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[a], T + 4, 6 * LOT, 0)));
        // the fill's fee floor(100.0015) = 100: the maker 80 at 80%, the pot 20
        assertEq(_bal(a, quote), q1 + 2 * _lq(T + 3) + 80);
        assertEq(_pot(quote), 20);
        (tick, lots,,,) = book.orderOf(c, posOf[a]);
        assertEq(tick, T + 4);
        assertEq(lots, 6 * LOT);
        _solvent();
    }

    /// A modify that keeps the tick and the open amount pays the order's fills, as a claim does, and is NoChange only
    /// when it has none: a take that brings an order down to the size its maker is modifying
    /// it to must not revert the maker's call. Asks of 100 LOT at T + 10 and at T + 20; the maker's multicall resizes
    /// the first to 60 LOT at its tick and moves the second to T + 30, and a buy of 40 LOT of the first lands before
    /// it, leaving the 60 LOT the multicall asks for. The multicall goes through: the first order pays its fills (40
    /// LOT at 1.00010, 40,004,000 quote, and the fee's maker part, floor(2000.2) = 2,000) and rests on with 60 LOT,
    /// the second moves.
    function test_modify_to_what_is_open_pays_the_fills() public {
        address a = _maker();
        uint32 p1 = _pos();
        uint32 p2 = _pos();
        vm.startPrank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 10, 100 * LOT, p1, 0));
        book.place(OloOps.key(c), OloOps.placeW(false, T + 20, 100 * LOT, p2, 0));
        vm.expectRevert(IOloBookBase.NoChange.selector); // nothing filled: nothing to pay, nothing to change
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(p1, T + 10, 100 * LOT, 0)));
        vm.stopPrank();
        bytes memory ops = bytes.concat(OloOps.modify(0, p1, T + 10, 60 * LOT), OloOps.modify(0, p2, T + 30, 100 * LOT));
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntry(p1, T + 10)),
            OloOps.tagW(c, OloOps.takeW(true, 40 * LOT, 0))
        );
        uint256 q0 = _bal(a, quote);
        uint256 b0 = _bal(a, base);
        vm.prank(a);
        book.multicall(0, _mc(ops));
        (uint256 tick, uint256 open, uint256 filled,,) = book.orderOf(c, p1);
        assertEq(tick, T + 10);
        assertEq(open, 60 * LOT, "what was open rests on");
        assertEq(filled, 0, "the fills paid");
        (tick,,,,) = book.orderOf(c, p2);
        assertEq(tick, T + 30, "the other order moved");
        assertEq(_bal(a, quote) - q0, 40_004_000 + 2_000, "the fills' proceeds and the fee's maker part");
        assertEq(_bal(a, base), b0, "no base moves");
        vm.prank(a);
        vm.expectRevert(IOloBookBase.NoChange.selector); // paid: the same again changes nothing
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(p1, T + 10, 60 * LOT, 0)));
        _solvent();
    }

    /// The same for a bid, through the single entry: its fills pay base, and the order rests on with the escrow it holds,
    /// as a claim's does: a refund rounded down and a re-escrow rounded up would be a wei apart here,
    /// the open amount's quote no whole number. A bid of 10,000,001 at T - 3 (0.999997); a sell of 4,000,000 fills it;
    /// the modify to the tick and the 6,000,001 open (5,999,982.999997 quote) pays 4,000,000 base and the fee's maker
    /// part, floor(199.9994) = 199, whole.
    function test_modify_to_what_is_open_pays_a_bids_fills() public {
        address a = _maker();
        uint32 p1 = _pos();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(true, T - 3, 10_000_001, p1, 0));
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntry(p1, T - 3)),
            OloOps.tagW(c, OloOps.takeW(false, 4_000_000, 0))
        );
        uint256 q0 = _bal(a, quote);
        uint256 b0 = _bal(a, base);
        assertEq(_qu(6_000_001, T - 3) - _qd(6_000_001, T - 3), 1, "the open amount's quote is no whole number");
        vm.prank(a);
        uint256 stored = book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(p1, T - 3, 6_000_001, 0)));
        assertEq(stored, 6_000_001);
        (uint256 tick, uint256 open, uint256 filled, bool isBid,) = book.orderOf(c, p1);
        assertEq(tick, T - 3);
        assertEq(open, 6_000_001, "what was open rests on");
        assertEq(filled, 0, "the fills paid");
        assertTrue(isBid);
        assertEq(_bal(a, base) - b0, 4_000_000, "the fills' base");
        assertEq(PriceGrid.feeDown(4_000_000, T - 3, 50), 199);
        assertEq(_bal(a, quote) - q0, 199, "the fee's maker part, whole: no escrow moved");
        vm.prank(a);
        vm.expectRevert(IOloBookBase.NoChange.selector);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(p1, T - 3, 6_000_001, 0)));
        _solvent();
    }

    function test_multicall_ladder() public {
        address a = _maker();
        uint32 from = _pos();
        for (uint256 i = 1; i < 10; ++i) {
            _pos();
        }
        bytes memory ops;
        for (uint32 i; i < 10; ++i) {
            ops = bytes.concat(ops, OloOps.place(0, T + 1 + i, false, 5 * LOT, from + i));
        }
        uint256 b0 = _bal(a, base);
        vm.prank(a);
        book.multicall(0, _mc(ops));
        assertEq(_bal(a, base), b0 - 50e6);
        ops = "";
        for (uint32 i; i < 10; ++i) {
            ops = bytes.concat(ops, OloOps.modify(0, from + i, T + 2 + i, 5 * LOT));
        }
        vm.prank(a);
        book.multicall(0, _mc(ops));
        (uint256 tick,,,,) = book.orderOf(c, from + 9);
        assertEq(tick, T + 11);
        vm.prank(taker);
        (uint256 filled,) = book.take(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntries(from, 3, T + 2, 1)),
            OloOps.tagW(c, OloOps.takeW(true, 12 * LOT, 0))
        );
        assertEq(filled, 12 * LOT);
        ops = "";
        for (uint32 i; i < 10; ++i) {
            ops = bytes.concat(ops, OloOps.cancel(0, from + i));
        }
        uint256 wb = base.balanceOf(a);
        uint256 wq = quote.balanceOf(a);
        vm.prank(a);
        book.multicall(0x02, _mc(ops));
        assertEq(base.balanceOf(a), wb + 38e6, "unfilled base to the wallet");
        assertEq(quote.balanceOf(a), wq + 5 * _lq(T + 2) + 5 * _lq(T + 3) + 2 * _lq(T + 4) + 250 + 250 + 100);
        // another maker's position in the stream is refused
        address b = _plain(T + 20, false, 5 * LOT);
        vm.prank(a);
        vm.expectRevert(IOloBookBase.NotOrderOwner.selector);
        book.multicall(0, _mc(OloOps.cancel(0, posOf[b])));
        // a header with a C that is no market's: a place on a never-written position finds no listing
        bytes memory bad = bytes.concat(OloOps.header(_wrongC()), OloOps.place(0, T + 1, false, 5 * LOT, from));
        vm.prank(a);
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.multicall(0, bad);
        _solvent();
    }

    function test_multicall_deposit_withdraw_ops() public {
        address a = _maker();
        uint256 b0 = _bal(a, base);
        uint256 wb = base.balanceOf(a);
        bytes memory ops = bytes.concat(OloOps.deposit(baseId, 7e6), OloOps.withdraw(quoteId, 3e6));
        uint256 q0 = _bal(a, quote);
        uint256 wq = quote.balanceOf(a);
        vm.prank(a);
        book.multicall(0, _mc(ops));
        assertEq(_bal(a, base), b0 + 7e6);
        assertEq(base.balanceOf(a), wb - 7e6);
        assertEq(_bal(a, quote), q0 - 3e6);
        assertEq(quote.balanceOf(a), wq + 3e6);
        // a token id no listing registered (0, or past tokenCount) is refused
        bytes memory hdr = OloOps.header(c);
        uint256[2] memory unknown = [uint256(0), book.tokenCount() + 1];
        for (uint256 k; k < unknown.length; ++k) {
            vm.prank(a);
            vm.expectRevert(IOloBookBase.BadOp.selector);
            book.multicall(0, bytes.concat(hdr, OloOps.withdraw(unknown[k], 0)));
        }
        _solvent();
    }

    function test_take_wallet_and_rest() public {
        address a = _plain(T + 1, false, 5 * LOT);
        uint256 wq = quote.balanceOf(taker);
        uint256 wb = base.balanceOf(taker);
        vm.prank(taker);
        (, uint256 quoteAmount) =
            book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, 5 * LOT, 1)));
        assertEq(quote.balanceOf(taker), wq - quoteAmount);
        assertEq(base.balanceOf(taker), wb + 5e6);
        address d = _plain(T + 2, false, 5 * LOT);
        uint256 q0 = _bal(taker, quote);
        vm.prank(taker);
        (uint256 filled,,,) = book.takeThenRest(
            OloOps.key(c), OloOps.poolList(_poolEntry(d)), OloOps.tagW(c, OloOps.restW(true, 12 * LOT, T + 2, 0, 77))
        );
        assertEq(filled, 5 * LOT);
        (uint256 tick, uint256 lots,, bool isBid,) = book.orderOf(c, 77);
        assertEq(tick, T + 2);
        assertEq(lots, 7 * LOT);
        assertTrue(isBid, "the rest rests as a bid");
        assertEq(_bal(taker, quote), q0 - 5_000_100 - 251 - 7 * _lq(T + 2));
        // through the wallet: the take and the rest's escrow both come from it, in one pull (one transferFrom of
        // the quote), the base in one push; the account untouched
        address e = _plain(T + 2, false, 5 * LOT);
        q0 = _bal(taker, quote);
        wq = quote.balanceOf(taker);
        vm.expectCall(address(quote), abi.encodeWithSelector(quote.transferFrom.selector, taker, address(book)), 1);
        vm.expectCall(address(base), abi.encodeWithSelector(base.transfer.selector, taker), 1);
        vm.prank(taker);
        (filled, quoteAmount,,) = book.takeThenRest(
            OloOps.key(c), OloOps.poolList(_poolEntry(e)), OloOps.tagW(c, OloOps.restW(true, 12 * LOT, T + 2, 1, 78))
        );
        assertEq(filled, 5 * LOT);
        (, lots,,,) = book.orderOf(c, 78);
        assertEq(lots, 7 * LOT);
        assertEq(quoteAmount, 5_000_100 + 251, "the fills' quote and fee alone, the escrow apart");
        assertEq(quote.balanceOf(taker), wq - quoteAmount - 7 * _lq(T + 2), "the rest's escrow from the wallet");
        assertEq(_bal(taker, quote), q0, "the account untouched");
        _solvent();
    }

    /// A takeThenRest whose list fills nothing (the named ask repriced away) rests the whole size and logs no Take:
    /// by account the escrow is debited, by wallet it is the one pull; a sell's rest is an ask escrowing base. With
    /// FOK the shortfall reverts before anything rests.
    function test_take_then_rest_nothing_filled() public {
        address a = _plain(T + 1, false, 5 * LOT);
        vm.prank(a);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[a], T + 3, 5 * LOT, 0)));
        bytes memory list = OloOps.poolList(_poolEntry(a));
        uint256 q0 = _bal(taker, quote);
        vm.recordLogs();
        vm.prank(taker);
        (uint256 filled, uint256 quoteAmount,,) =
            book.takeThenRest(OloOps.key(c), list, OloOps.tagW(c, OloOps.restW(true, 7 * LOT, T + 1, 0, 91)));
        assertEq(filled, 0 * LOT);
        assertEq(quoteAmount, 0);
        assertEq(filled, 0);
        (, uint256 lots,, bool isBid,) = book.orderOf(c, 91);
        assertEq(lots, 7 * LOT);
        assertTrue(isBid);
        assertEq(_bal(taker, quote), q0 - 7 * _lq(T + 1), "the rest's escrow from the account");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one Placed, no Take");
        assertEq(logs[0].topics[0], keccak256("Placed(address,uint256)"));
        // by wallet: one pull of the escrow, no push
        uint256 wq = quote.balanceOf(taker);
        vm.expectCall(address(quote), abi.encodeWithSelector(quote.transferFrom.selector, taker, address(book)), 1);
        vm.expectCall(address(base), abi.encodeWithSelector(base.transfer.selector, taker), 0);
        vm.prank(taker);
        book.takeThenRest(OloOps.key(c), list, OloOps.tagW(c, OloOps.restW(true, 7 * LOT, T + 1, 1, 92)));
        assertEq(quote.balanceOf(taker), wq - 7 * _lq(T + 1), "the rest's escrow from the wallet");
        // a sell: the rest is an ask, its base from the wallet in one pull
        uint256 wb = base.balanceOf(taker);
        vm.expectCall(address(base), abi.encodeWithSelector(base.transferFrom.selector, taker, address(book)), 1);
        vm.prank(taker);
        book.takeThenRest(OloOps.key(c), "", OloOps.tagW(c, OloOps.restW(false, 3 * LOT, T - 1, 1, 93)));
        assertEq(base.balanceOf(taker), wb - 3e6, "the ask's base from the wallet");
        // no fill-or-kill here: a takeThenRest rests what is left, so the bit is BadFlags, and nothing rests
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.BadFlags.selector);
        book.takeThenRest(OloOps.key(c), list, OloOps.tagW(c, OloOps.restW(true, 7 * LOT, T + 1, 0x80, 94)));
        (, lots,,,) = book.orderOf(c, 94);
        assertEq(lots, 0 * LOT);
        _solvent();
    }

    /// A take list that is not one reverts: a segment of an unknown kind, a segment running past the list (its length a
    /// whole number of entries), a position segment that is not a whole number of entries, a batch group running past
    /// its segment (its mask names more ticks than it holds) or naming no sub-order, or past sub-order 3.
    function test_take_list_malformed() public {
        bytes[6] memory lists = [
            abi.encodePacked(uint8(2), uint16(0)),
            abi.encodePacked(uint8(0), uint16(105), OloOps.poolEntry(1000, T)),
            OloOps.poolList(hex"0000"),
            // mask 5 names two sub-orders, one tick (4 bytes) given: the group runs past its segment
            OloOps.batchList(abi.encodePacked(address(this), uint16(0), uint8(5), uint32(T))),
            OloOps.batchList(abi.encodePacked(address(this), uint16(0), uint8(0))),
            OloOps.batchList(abi.encodePacked(address(this), uint16(0), uint8(0x11), uint32(T), uint32(T)))
        ];
        for (uint256 i; i < lists.length; ++i) {
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.BadTakeList.selector);
            book.take(OloOps.key(c), lists[i], OloOps.tagW(c, OloOps.takeW(true, 20 * LOT, 0)));
        }
    }

    /// A position segment holds as many entries as its 16-bit length allows, 8,191 (65,528 bytes), and their fill
    /// records, 9 bytes each, 73,719 bytes, are logged under the Take event's 3-byte segment length (a 16-bit one would
    /// read 8,183), the next segment's header right after them.
    function test_position_segment_longest() public {
        uint256 n = 8_191;
        address a = _maker();
        bytes memory first = _oneLotAsks(a, 200_000, n);
        bytes memory second = _oneLotAsks(a, 200_000 + uint32(n), 1);
        assertEq(first.length, 65_528, "the longest position segment");
        vm.recordLogs();
        vm.prank(taker);
        (uint256 filled,) = book.take(
            OloOps.key(c),
            bytes.concat(OloOps.poolList(first), OloOps.poolList(second)),
            OloOps.tagW(c, OloOps.takeW(true, (n + 1) * LOT, 0))
        );
        assertEq(filled, (n + 1) * LOT, "every position filled");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory fills;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IOloBookBase.Take.selector) {
                (,,,, fills) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bytes));
            }
        }
        assertEq(fills.length, 4 + 9 * n + 4 + 9, "two segments of records");
        assertEq(_u24(fills, 1), 73_719, "the first segment's length, past 16 bits");
        uint256 secondHeader = 4 + 9 * n;
        assertEq(uint8(fills[secondHeader]), 0, "the second segment is positions");
        assertEq(_u24(fills, secondHeader + 1), 9, "the second segment's length");
    }

    /// `n` one-lot asks of `a` at T + 1 in positions `from` ..: their take list entries.
    function _oneLotAsks(address a, uint32 from, uint256 n) internal returns (bytes memory entries) {
        entries = new bytes(n * 8);
        vm.pauseGasMetering();
        vm.startPrank(a);
        for (uint256 i; i < n; ++i) {
            book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 1 * LOT, from + uint32(i), 0));
            uint256 w = (uint256(from + i) << 224) | (uint256(uint32(T + 1)) << 192); // position 4 | tick 4
            assembly ("memory-safe") {
                let p := add(add(entries, 0x20), mul(i, 8))
                mstore(p, or(w, and(mload(p), sub(shl(192, 1), 1))))
            }
        }
        vm.stopPrank();
        vm.resumeGasMetering();
    }

    /// Flag bits that mean nothing revert BadFlags, whichever entry carries them: a place's bits 0 and 3, a take's or a
    /// takeThenRest's mode bits 1-3 (its wallet bit is bit 0, a maker entry's bit 1), a multicall's settle bits above
    /// WALLET | AUTO.
    function test_bad_flags() public {
        address a = _maker();
        uint32 pos = _pos();
        uint8[2] memory placeFlags = [uint8(0x01), 0x08];
        for (uint256 i; i < placeFlags.length; ++i) {
            vm.prank(a);
            vm.expectRevert(IOloBookBase.BadFlags.selector);
            book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, pos, placeFlags[i]));
        }
        // a take's mode: bits 2-3 mean nothing, and the probes (bits 4-6) are takeThenRest's alone
        uint8[5] memory modes = [uint8(0x04), 0x08, 0x10, 0x20, 0x40];
        for (uint256 i; i < modes.length; ++i) {
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.BadFlags.selector);
            book.take(
                OloOps.key(c),
                OloOps.poolList(OloOps.poolEntry(pos, T + 1)),
                OloOps.tagW(c, OloOps.takeW(true, 1 * LOT, modes[i]))
            );
        }
        // takeThenRest's: bits 2-3 mean nothing, and it takes no quote mode (bit 1) and no fill-or-kill (bit 7)
        uint8[4] memory restModes = [uint8(0x02), 0x04, 0x08, 0x80];
        for (uint256 i; i < restModes.length; ++i) {
            vm.prank(taker);
            vm.expectRevert(IOloBookBase.BadFlags.selector);
            book.takeThenRest(
                OloOps.key(c),
                OloOps.poolList(OloOps.poolEntry(pos, T + 1)),
                OloOps.tagW(c, OloOps.restW(true, 1 * LOT, T, restModes[i], pos))
            );
        }
        vm.prank(a);
        vm.expectRevert(IOloBookBase.BadFlags.selector);
        book.multicall(0x08, _mc(OloOps.place(0, T + 1, false, 5 * LOT, pos)));
        // a PLACE op's side byte bits 1-3 mean nothing either
        uint8[3] memory sides = [uint8(0x02), 0x04, 0x08];
        for (uint256 i; i < sides.length; ++i) {
            vm.prank(a);
            vm.expectRevert(IOloBookBase.BadFlags.selector);
            bytes memory op = abi.encodePacked(uint8(1), uint8(0), uint32(T + 1), sides[i], uint112(5 * LOT), pos);
            book.multicall(0, _mc(op));
        }
        // the same orders with no stray bits go through
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, pos, 0));
        vm.prank(taker);
        (uint256 filled,) = book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(pos, T + 1)), OloOps.tagW(c, OloOps.takeW(true, 1 * LOT, 0))
        );
        assertEq(filled, 1 * LOT);
    }

    /// The entries return what they stored: `place` the order id and the amount it holds
    /// (1,234,567,891 rests as 123,456,789 units of 10, 1,234,567,890), `modify` the new amount it holds,
    /// `takeThenRest` the rest's amount and the position it landed in (past a busy one, by a probe), both 0 when
    /// nothing rests.
    function test_entries_return_what_they_stored() public {
        address a = _maker();
        vm.startPrank(a);
        (uint256 id, uint256 stored) = book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 1_234_567_891, 600, 0));
        assertEq(id, _orderId(c, 600));
        assertEq(stored, 1_234_567_890);
        stored = book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(600, T + 2, 2_000_000_009, 0)));
        assertEq(stored, 2_000_000_000, "200,000,000 units of 10");
        stored = book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(600, T + 2, 7 * LOT, 0)));
        assertEq(stored, 7 * LOT, "below 2^30: exact");
        // a busy position for the rest to probe past
        book.place(OloOps.key(c), OloOps.placeW(true, T - 5, 1 * LOT, 700, 0));
        vm.stopPrank();
        address b = _plain(T + 1, false, 1 * LOT);
        vm.startPrank(taker);
        // 9 LOT against the 7 LOT ask, through the wallet: 2 LOT rest, at 701 (700 busy, one probe)
        (uint256 got, uint256 paid, uint256 rested, uint256 restId) = book.takeThenRest(
            OloOps.key(c),
            OloOps.poolList(OloOps.poolEntry(600, T + 2)),
            OloOps.tagW(c, OloOps.restW(true, 9 * LOT, T + 2, 0x11, 700))
        );
        assertEq(got, 7 * LOT);
        assertGt(paid, 0);
        assertEq(rested, 2 * LOT);
        assertEq(restId, _orderId(c, 701), "the rest's order id: position 701 and the tag");
        (, uint256 open,,, address owner) = book.orderOf(c, 701);
        assertEq(open, rested);
        assertEq(owner, taker);
        // nothing left to rest: both 0
        (got,, rested, restId) = book.takeThenRest(
            OloOps.key(c), OloOps.poolList(_poolEntry(b)), OloOps.tagW(c, OloOps.restW(true, 1 * LOT, T + 1, 0x01, 702))
        );
        assertEq(got, 1 * LOT);
        assertEq(rested, 0);
        assertEq(restId, 0, "no rest, no order id");
        vm.stopPrank();
    }

    /// A rest can land in position 0: its order id is still not 0, the tag above the position (a version is never 0),
    /// so the id alone tells a rest from none. A takeThenRest of 5 base wei with nothing to take, limit T, position 0:
    /// 5 rest there.
    function test_a_rest_in_position_0_has_an_order_id() public {
        vm.prank(taker);
        (uint256 got,, uint256 rested, uint256 restId) =
            book.takeThenRest(OloOps.key(c), "", OloOps.tagW(c, OloOps.restW(true, 5, T, OloOps.WALLET, 0)));
        assertEq(got, 0);
        assertEq(rested, 5);
        assertEq(restId, _orderId(c, 0), "position 0 and the tag");
        assertTrue(restId != 0, "not 0");
        (uint256 tick, uint256 open,, bool isBid, address owner) = book.orderOf(c, 0);
        assertEq(tick, T);
        assertEq(open, 5);
        assertTrue(isBid);
        assertEq(owner, taker);
    }

    /// `place` and `modify` return what the order holds, the Placed event logs the same, and the escrow moved is that
    /// amount (an ask) or its quote rounded up (a bid), net of the old order's refund on a modify: any amount up to
    /// 2^112 - 1 (q 0 to 25) at any maker tick from the floor to decade 44 on a 5-figure market.
    function testFuzz_place_and_modify_return_what_they_hold(uint256 a1, uint256 a2, bool bid, uint256 tk1, uint256 tk2)
        public
    {
        MockERC20 x = new MockERC20("X", "X", 18);
        MockERC20 y = new MockERC20("Y", "Y", 18);
        MarketWord mc = book.configOf(book.listMarketQuote(address(x), address(y), 200, 5, 0, 0));
        address mk = address(0xB0B);
        x.mint(mk, 1e45);
        y.mint(mk, 1e75);
        vm.startPrank(mk);
        x.approve(address(book), type(uint256).max);
        y.approve(address(book), type(uint256).max);
        vm.stopPrank();
        a1 = bound(a1, 1, (1 << 112) - 1);
        a2 = bound(a2, 1, (1 << 112) - 1);
        tk1 = bound(tk1, PriceGrid.MIN_MAKER_TICK / 10, 40_000_000 / 10) * 10;
        tk2 = bound(tk2, PriceGrid.MIN_MAKER_TICK / 10, 40_000_000 / 10) * 10;
        uint256 xb = x.balanceOf(mk);
        uint256 yb = y.balanceOf(mk);
        vm.recordLogs();
        vm.prank(mk);
        (, uint256 s1) = book.place(OloOps.key(mc), OloOps.placeW(bid, tk1, a1, 3, 0x02));
        assertEq(s1, _storedOf(a1), "place: units x 10^q of the amount");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 packed = abi.decode(logs[logs.length - 1].data, (uint256));
        assertEq((packed >> 32) & ((1 << 112) - 1), s1, "Placed logs the returned amount");
        if (bid) assertEq(yb - y.balanceOf(mk), PriceGrid.quoteUp(s1, tk1), "a bid escrows its quote rounded up");
        else assertEq(xb - x.balanceOf(mk), s1, "an ask escrows what it holds");
        if (tk1 == tk2 && _storedOf(a2) == s1) return; // NoChange
        xb = x.balanceOf(mk);
        yb = y.balanceOf(mk);
        vm.prank(mk);
        uint256 s2 = book.modify(OloOps.key(mc), OloOps.tagW(mc, OloOps.modifyW(3, tk2, a2, 0x02)));
        assertEq(s2, _storedOf(a2), "modify: units x 10^q of the new amount");
        (, uint256 open,,,) = book.orderOf(mc, 3);
        assertEq(open, s2);
        if (bid) {
            assertEq(
                int256(yb) - int256(y.balanceOf(mk)),
                int256(PriceGrid.quoteUp(s2, tk2)) - int256(PriceGrid.quoteDown(s1, tk1)),
                "a bid: the new escrow less the old refund"
            );
        } else {
            assertEq(int256(xb) - int256(x.balanceOf(mk)), int256(s2) - int256(s1), "an ask: the base difference");
        }
    }

    /// An amount as an order stores it, written out: the smallest q with fewer than 2^30 units.
    function _storedOf(uint256 a) internal pure returns (uint256) {
        uint256 q;
        uint256 u = a;
        while (u >= 1 << 30) {
            u /= 10;
            ++q;
        }
        return u * 10 ** q;
    }

    /// A warming range is 1 to 512 positions.
    function test_warm_range() public {
        vm.expectRevert(IOloBookBase.BadWarmRange.selector);
        book.warmPool(m, 0, 0);
        vm.expectRevert(IOloBookBase.BadWarmRange.selector);
        book.warmPool(m, 0, 513);
        book.warmPool(m, 0, 512);
        assertEq(book.orderWord(c, 511), PoolLib.USED, "the last position warmed");
    }

    /// A market's config word, field by field, as integrators read it: baseId 0-31 | quoteId 32-63 | feePpm 64-83 |
    /// spacing 84-93 | minQuote 94-189 | marketId 224-255, nothing between; an id never listed reads zero.
    function test_config_word_layout() public {
        MockERC20 b2 = new MockERC20("Bee", "BEE", 6);
        uint32 id = book.listMarketQuote(address(b2), address(quote), 4321, 4, type(uint96).max, 0);
        uint256 w = MarketWord.unwrap(book.configOf(id));
        assertEq(w & 0xffffffff, book.tokenId(address(b2)), "baseId");
        assertEq((w >> 32) & 0xffffffff, book.tokenId(address(quote)), "quoteId");
        assertEq((w >> 64) & 0x3ff, 100, "spacing: every 100th tick at 4 significant figures");
        assertEq((w >> 74) & type(uint96).max, type(uint96).max, "minQuote");
        assertEq((w >> 170) & 0xf, 0, "nothing between minQuote and the tag");
        assertEq((w >> 174) & 0x3fff, 10_000, "makerBps: the fixture's global share");
        assertEq((w >> 188) & 0xfffff, 4321, "feePpm");
        assertEq((w >> 208) & 0xffff, 1, "version 1 at the listing");
        assertEq(w >> 224, id, "marketId");
        assertEq(MarketWord.unwrap(book.configOf(id + 1)), 0, "an id never listed");
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.setMarketMakerShare(id + 1, 100);
    }

    /// The constants that must agree, held to each other: the token-id mask is TOKEN_ID_BITS wide (a literal in the
    /// source, since a constant defined by an expression changes the contract's code), the quote id follows the base
    /// id, the account keys and the registry's cap read the same width, and C's fields, each its mask at its offset,
    /// fit in the word and overlap nowhere. TOKEN_ID_BITS raised alone fails here (the mask is still 32 bits), and
    /// raised with its mask, to 40, fails too: the quote id would run into the spacing, which stays at bit 64.
    function test_config_word_fields_fit() public pure {
        assertEq(C_TOKEN_ID_MASK, (1 << TOKEN_ID_BITS) - 1, "the token-id mask is TOKEN_ID_BITS wide");
        assertEq(C_QUOTE_ID, C_BASE_ID + TOKEN_ID_BITS, "the quote id follows the base id");
        assertEq(KEY_BITS, TOKEN_ID_BITS, "an account key's id bits");
        assertEq(KEY_OWNER_SHIFT, TOKEN_ID_BITS, "an account key's owner above the id");
        assertEq(KEY_MASK, C_TOKEN_ID_MASK, "an account key's id mask");
        assertEq(MarketLib.MAX_TOKEN_ID, C_TOKEN_ID_MASK, "the registry's cap");
        uint256[8] memory masks = [
            C_TOKEN_ID_MASK,
            C_TOKEN_ID_MASK,
            C_SPACING_MASK,
            C_MIN_QUOTE_MASK,
            C_MAKER_BPS_MASK,
            C_FEE_PPM_MASK,
            0xffff, // the version: uint16(C >> C_VERSION) reads it, no mask
            0xffffffff
        ];
        uint256[8] memory offsets =
            [C_BASE_ID, C_QUOTE_ID, C_SPACING, C_MIN_QUOTE, C_MAKER_BPS, C_FEE_PPM, C_VERSION, C_MARKET_ID];
        uint256 tag;
        for (uint256 i; i < 8; ++i) {
            // within the word: shifted up and back down, the field is its whole mask
            assertEq((masks[i] << offsets[i]) >> offsets[i], masks[i], "C's field within the word");
            if (i >= 4 && i <= 6) tag |= masks[i] << offsets[i];
            for (uint256 j = i + 1; j < 8; ++j) {
                assertEq((masks[i] << offsets[i]) & (masks[j] << offsets[j]), 0, "C's fields overlap nowhere");
            }
        }
        // the tag is the share, the fee and the version, bits 174-223; the key every other bit
        assertEq(tag, C_TAG_FIELD, "the tag's three fields");
        assertEq(C_TAG_FIELD >> C_TAG, (1 << 50) - 1, "the tag starts at C_TAG and is 50 bits");
        assertEq(C_KEY_MASK, ~C_TAG_FIELD, "the key is every bit but the tag");
        assertEq(C_FEE_PPM_FIELD, C_FEE_PPM_MASK << C_FEE_PPM, "the fee in place");
        assertEq(C_MAKER_BPS_FIELD, C_MAKER_BPS_MASK << C_MAKER_BPS, "the share in place");
        assertEq(C_MAKER_BPS, C_TAG, "the share is the tag's first field");
        assertEq(TAG_CARRIED, 256 - 50, "a carried tag is a word's top 50 bits");
    }

    /// The taker fee is at most 1,000,000 ppm (100%), which fits its 20-bit field (188-207): no larger fee lists, so
    /// none spills into the version above it (1,048,576 would carry into bit 208).
    function test_listing_fee_bound() public {
        MockERC20 b2 = new MockERC20("Bee", "BEE", 6);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.listMarketQuote(address(b2), address(quote), 1_000_001, 6, 7, 0);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.listMarketQuote(address(b2), address(quote), 1 << 20, 6, 7, 0);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.listMarketQuote(address(b2), address(quote), type(uint24).max, 6, 7, 0);
        uint32 id = book.listMarketQuote(address(b2), address(quote), 1_000_000, 6, 7, 0);
        uint256 w = MarketWord.unwrap(book.configOf(id));
        assertEq(book.configOf(id).feePpm(), 1_000_000, "feePpm");
        assertEq(book.configOf(id).version(), 1, "the version, untouched");
        assertEq(book.configOf(id).spacing(), 1, "spacing");
        assertEq(book.configOf(id).minQuote(), 7, "minQuote");
        assertEq(w >> 224, id, "the id");
    }

    /// The other listing bounds: significant figures 3 to 6; one listing per set of parameters (a different minQuote,
    /// fee or figures is another market); the bounds list, each field read back from C.
    function test_listing_bounds() public {
        MockERC20 b2 = new MockERC20("Bee", "BEE", 6);
        address q = address(quote);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.listMarketQuote(address(b2), q, 50, 2, 7, 0);
        vm.expectRevert(IOloBookBase.BadMarketConfig.selector);
        book.listMarketQuote(address(b2), q, 50, 7, 7, 0);
        uint32 id = book.listMarketQuote(address(b2), q, 50, 3, 0, 0);
        assertEq(book.configOf(id).spacing(), 1000, "3 figures: every 1000th tick");
        vm.expectRevert(IOloBookBase.MarketExists.selector);
        book.listMarketQuote(address(b2), q, 50, 3, 0, 0);
        uint32 id2 = book.listMarketQuote(address(b2), q, 50, 3, 1, 0);
        assertEq(id2, id + 1, "another minQuote, another market");
        uint32 id3 = book.listMarketQuote(address(b2), q, 50, 6, 0, 0);
        assertEq(id3, id + 2, "other figures, another market");
    }

    function test_order_ids_and_configs() public {
        address a = _plain(T + 1, false, 5 * LOT);
        vm.prank(a);
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        book.cancel(OloOps.key(_wrongC()), OloOps.tagW(_wrongC(), OloOps.posW(posOf[a], 0))); // a wrong C derives a key that holds nothing
        vm.prank(a);
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(123_456, 0)));
        vm.prank(a);
        // the last position is a position like any other
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, type(uint32).max, 0));
        // one listing per config
        vm.expectRevert(IOloBookBase.MarketExists.selector);
        book.listMarketQuote(address(base), address(quote), 50, 6, 1, 0);
        uint32 m2 = book.listMarketQuote(address(base), address(quote), 60, 6, 1, 0);
        assertEq(MarketWord.unwrap(book.configOf(m2)) >> 224, m2, "C carries its market id");
        assertEq(MarketWord.unwrap(c) >> 224, m);
    }

    function test_cancel_refund_to_wallet() public {
        address a = _plain(T + 1, false, 5 * LOT);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(a)), OloOps.tagW(c, OloOps.takeW(true, 2 * LOT, 0)));
        uint256 q0 = _bal(a, quote);
        vm.prank(a);
        uint256 proceeds = book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], 0)));
        assertEq(proceeds, 2_000_020);
        assertEq(_bal(a, quote), q0 + 2_000_020 + 100);
        uint256 b0 = _bal(a, base);
        uint256 wb = base.balanceOf(a);
        vm.prank(a);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], 0x02))); // the refund to the wallet
        assertEq(_bal(a, base), b0);
        assertEq(base.balanceOf(a), wb + 3e6);
        assertEq(book.orderWord(c, posOf[a]) & ((1 << 94) - 1), 0, "dead: no tick, lots or fills");
        _solvent();
    }

    function test_probing_place() public {
        address a = _maker();
        address b = _maker();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, 300, 0));
        vm.prank(b);
        vm.expectRevert(IOloBookBase.SlotBusy.selector);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, 300, 0));
        // up to 3 further positions: lands on 301
        vm.prank(b);
        (uint256 id,) = book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, 300, 0x30));
        assertEq(uint32(id), 301);
        (, uint256 lots,,, address owner) = book.orderOf(c, 301);
        assertEq(lots, 5 * LOT);
        assertEq(owner, b);
        // 300 .. 303 busy: 3 probes from 300 fail, 4 land on 304
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, 302, 0));
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, 303, 0));
        vm.prank(b);
        vm.expectRevert(IOloBookBase.SlotBusy.selector);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, 300, 0x30));
        vm.prank(b);
        (id,) = book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, 300, 0x40));
        assertEq(uint32(id), 304);
        // the position space wraps
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, type(uint32).max, 0));
        vm.prank(b);
        (id,) = book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, type(uint32).max, 0x10));
        assertEq(uint32(id), 0);
        // a rest probes with mode bits 4-6: 303 and 304 busy, 305 free
        address d = _plain(T + 2, false, 5 * LOT);
        vm.prank(taker);
        book.takeThenRest(
            OloOps.key(c), OloOps.poolList(_poolEntry(d)), OloOps.tagW(c, OloOps.restW(true, 7 * LOT, T + 2, 0x20, 303))
        );
        bool isBid;
        (, lots,, isBid,) = book.orderOf(c, 305);
        assertEq(lots, 2 * LOT);
        assertTrue(isBid);
        _solvent();
    }

    /// A stream that runs past its data or names what its header lacks reverts BadOp: an op cut short (its last byte
    /// missing, which would otherwise read as a zero past the data), and an op naming a market index the header does
    /// not hold (which would read the next market's C from the ops).
    function test_multicall_stream_bounds() public {
        address a = _maker();
        uint32 pos = _pos();
        vm.prank(a);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 1, 5 * LOT, pos, 0));
        bytes memory cut = OloOps.cancel(0, pos);
        assembly ("memory-safe") {
            mstore(cut, sub(mload(cut), 1))
        }
        vm.prank(a);
        vm.expectRevert(IOloBookBase.BadOp.selector);
        book.multicall(0, _mc(cut));
        vm.prank(a);
        vm.expectRevert(IOloBookBase.BadOp.selector);
        book.multicall(0, _mc(OloOps.cancel(1, pos)));
        vm.prank(a);
        book.multicall(0, _mc(OloOps.cancel(0, pos)));
        (, uint256 lots,,,) = book.orderOf(c, pos);
        assertEq(lots, 0 * LOT, "the whole op cancels");
    }

    /// An op code the multicall does not define (0, 7 and above) reverts the stream.
    function test_multicall_unknown_op() public {
        address a = _maker();
        uint8[3] memory codes = [uint8(0), 7, 0xff];
        for (uint256 i; i < codes.length; ++i) {
            vm.prank(a);
            vm.expectRevert(IOloBookBase.BadOp.selector);
            book.multicall(0, _mc(abi.encodePacked(codes[i], uint8(0), uint32(_pos()))));
        }
    }

    /// The one storage slot the contract reads to answer the view `call`.
    function _slotRead(bytes memory call) internal returns (bytes32) {
        vm.record();
        (bool ok,) = address(book).staticcall(call);
        assertTrue(ok);
        (bytes32[] memory reads,) = vm.accesses(address(book));
        assertEq(reads.length, 1, "one slot read");
        return reads[0];
    }

    /// A multicall settles at most four tokens, its ledger's entries in memory; a fifth reverts TooManyTokens, whether
    /// a DEPOSIT op or an order op brings it. Right past the ledger lies the stream's parsing state, its header
    /// pointers first, which a fifth entry would overwrite.
    function test_multicall_ledger_holds_four_tokens() public {
        address a = _maker();
        bytes memory hdr = abi.encodePacked(uint8(5));
        bytes memory deposits;
        bytes memory places;
        for (uint256 i; i < 5; ++i) {
            MockERC20 t = new MockERC20("Five", "FIVE", 6);
            MarketWord ci = book.configOf(book.listMarketQuote(address(t), address(quote), 50, 6, 1, 0));
            uint256 id = book.tokenId(address(t));
            t.mint(a, 1e24);
            vm.startPrank(a);
            t.approve(address(book), type(uint256).max);
            book.deposit(address(t), 1e12);
            vm.stopPrank();
            hdr = bytes.concat(hdr, abi.encodePacked(MarketWord.unwrap(ci)));
            deposits = bytes.concat(deposits, OloOps.deposit(id, 1e6));
            places = bytes.concat(places, OloOps.place(uint8(i), T + 1, false, 5 * LOT, _pos()));
        }
        // the asks escrow only their bases
        vm.startPrank(a);
        vm.expectRevert(IOloBookBase.TooManyTokens.selector);
        book.multicall(0, bytes.concat(hdr, deposits));
        vm.expectRevert(IOloBookBase.TooManyTokens.selector);
        book.multicall(0, bytes.concat(hdr, places));
        book.multicall(0, bytes.concat(hdr, _cut(deposits, 4 * 21)));
        book.multicall(0, bytes.concat(hdr, _cut(places, 4 * 25)));
        vm.stopPrank();
    }

    /// The first `n` bytes of `b`.
    function _cut(bytes memory b, uint256 n) internal pure returns (bytes memory r) {
        r = new bytes(n);
        for (uint256 i; i < n; ++i) {
            r[i] = b[i];
        }
    }

    /// An owner's account holds at most 2^128 - 1, its word's amount field: a credit past it reverts AmountOverflow
    /// rather than carry into the word's unused bits, where the balance would read as what is left below 2^128. A
    /// deposit onto a full account reverts. The fee pot holds up to 2^255 - 1: a pot at
    /// 2^128 - 1 takes a settle's part and reads whole, and only a pot at 2^255 - 1 refuses one: a claim (the split in
    /// _splitFee) and a modify (the split inline).
    function test_amounts_stop_at_2_128() public {
        address a = _maker();
        base.mint(a, type(uint128).max);
        vm.startPrank(a);
        book.deposit(address(base), type(uint128).max - 1e24); // on top of the maker's 1e24
        vm.expectRevert(IOloBookBase.AmountOverflow.selector);
        book.deposit(address(base), 1);
        vm.stopPrank();
        // the orders rest at a share of 0 (a version of their own): their fees go wholly to the pot
        _setMarketShare(0);
        address b = _plain(T + 1, false, 5 * LOT);
        address d = _plain(T + 1, false, 5 * LOT);
        address e = _plain(T + 1, false, 5 * LOT);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.poolList(bytes.concat(_poolEntry(b), _poolEntry(d), _poolEntry(e))),
            OloOps.tagW(c, OloOps.takeW(true, 15 * LOT, 0))
        );
        uint256 fee = 5 * _lq(T + 1) * 50 / 1e6; // 250: an order's fee, floored
        bytes32 pot = _slotRead(abi.encodeCall(book.balanceOf, (quoteId, address(0))));
        vm.store(address(book), pot, bytes32(AccountLib.USED | type(uint128).max));
        assertEq(_pot(quote), type(uint128).max);
        vm.prank(e);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[e], 0)));
        assertEq(_pot(quote), uint256(type(uint128).max) + fee, "the pot past an account's cap, read whole");
        vm.store(address(book), pot, bytes32(AccountLib.USED | AccountLib.POT_MASK));
        assertEq(_pot(quote), AccountLib.POT_MASK);
        vm.prank(b);
        vm.expectRevert(IOloBookBase.AmountOverflow.selector);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[b], 0)));
        vm.prank(d);
        vm.expectRevert(IOloBookBase.AmountOverflow.selector);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(posOf[d], T + 2, 5 * LOT, 0)));
    }

    /// The token registry holds ids up to 2^32 - 1, C's token fields: once full, a listing that would register a new
    /// token reverts TokenRegistryFull rather than give it 2^32, which C would truncate to 0. Listings of registered
    /// tokens go on.
    function test_token_registry_full() public {
        bytes32 count = _slotRead(abi.encodeCall(book.tokenCount, ()));
        vm.store(address(book), count, bytes32(uint256(0xffffffff - 1)));
        MockERC20 last = new MockERC20("Last", "LAST", 6);
        MockERC20 over = new MockERC20("Over", "OVER", 6);
        book.listMarketQuote(address(last), address(quote), 50, 6, 1, 0);
        assertEq(book.tokenId(address(last)), 0xffffffff, "the last id");
        vm.expectRevert(IOloBookBase.TokenRegistryFull.selector);
        book.listMarketQuote(address(over), address(quote), 50, 6, 1, 0);
        book.listMarketQuote(address(last), address(base), 50, 6, 1, 0);
        assertEq(book.tokenCount(), 0xffffffff);
    }

    /// Token ids at the registry's top, every bit of C's 32-bit fields used: a market of base id 2^32 - 2 and quote id
    /// 2^32 - 1 lists with both in C, and works end to end: a multicall DEPOSIT of each by id and a PLACE in one
    /// stream, a take by wallet, a claim at an 80% share (the pot of id 2^32 - 1), a multicall WITHDRAW by id and the
    /// pot collected; the next new token is TokenRegistryFull.
    function test_token_ids_at_the_registry_top() public {
        bytes32 count = _slotRead(abi.encodeCall(book.tokenCount, ()));
        vm.store(address(book), count, bytes32(uint256(0xffffffff - 2)));
        MockERC20 hb = new MockERC20("High base", "HB", 6);
        MockERC20 hq = new MockERC20("High quote", "HQ", 6);
        uint32 hm = book.listMarketQuote(address(hb), address(hq), 50, 6, 1, 0);
        MarketWord hc = book.configOf(hm);
        uint256 hbId = book.tokenId(address(hb));
        uint256 hqId = book.tokenId(address(hq));
        assertEq(hbId, 0xfffffffe, "base id");
        assertEq(hqId, 0xffffffff, "quote id");
        uint256 w = MarketWord.unwrap(hc);
        assertEq(w & 0xffffffff, hbId, "C's baseId");
        assertEq((w >> 32) & 0xffffffff, hqId, "C's quoteId");
        assertEq(hc.feePpm(), 50, "C's feePpm");
        book.setMarketMakerShare(hm, 8_000);
        hc = book.configOf(hm); // the version at 80%
        address a = address(0xA11CE);
        hb.mint(a, 1e12);
        hq.mint(a, 1e12);
        hq.mint(taker, 1e12);
        vm.startPrank(a);
        hb.approve(address(book), type(uint256).max);
        hq.approve(address(book), type(uint256).max);
        book.multicall(
            0,
            bytes.concat(
                OloOps.header(hc),
                OloOps.deposit(hbId, 5e6),
                OloOps.deposit(hqId, 1e6),
                OloOps.place(0, T, false, 5e6, 3)
            )
        );
        vm.stopPrank();
        assertEq(book.balanceOf(hbId, a), 0, "the ask escrowed its deposit");
        assertEq(book.balanceOf(hqId, a), 1e6, "quote deposited");
        // the key is owner << 32 | id, so an id's top byte never meets the owner's bits: 0xA11CF, an owner one bit
        // from the maker's (owner << 24 would give the two one key for this id), holds nothing of it
        assertEq(book.balanceOf(hqId, address(0xA11CF)), 0, "a neighbour owner's account is its own");
        vm.startPrank(taker);
        hq.approve(address(book), type(uint256).max);
        (uint256 got, uint256 paid) = book.take(
            OloOps.key(hc), OloOps.poolList(OloOps.poolEntry(3, T)), OloOps.tagW(hc, OloOps.takeW(true, 2e6, 0x01))
        );
        vm.stopPrank();
        assertEq(got, 2e6, "base bought");
        assertEq(paid, 2e6 + 100, "quote and fee paid");
        assertEq(hb.balanceOf(taker), 2e6, "base to the taker's wallet");
        vm.prank(a);
        book.claim(OloOps.key(hc), OloOps.tagW(hc, OloOps.posW(3, 0)));
        assertEq(book.balanceOf(hqId, a), 1e6 + 2e6 + 80, "proceeds and 80% of the fee");
        assertEq(book.balanceOf(hqId, address(0)), 20, "the pot of id 2^32 - 1");
        vm.prank(a);
        book.multicall(0, bytes.concat(OloOps.header(hc), OloOps.withdraw(hqId, 3e6 + 80)));
        assertEq(book.balanceOf(hqId, a), 0, "withdrawn by id");
        assertEq(hq.balanceOf(a), 1e12 - 1e6 + 3e6 + 80, "to the wallet");
        uint256 r0 = hq.balanceOf(book.feeRecipient());
        book.collectFees(address(hq));
        assertEq(hq.balanceOf(book.feeRecipient()) - r0, 20, "the pot collected");
        MockERC20 over = new MockERC20("Over", "OVER", 6);
        vm.expectRevert(IOloBookBase.TokenRegistryFull.selector);
        book.listMarketQuote(address(over), address(hq), 50, 6, 1, 0);
    }

    /// A PLACE that probes past busy positions is logged where it landed. The Ops event's copy of the
    /// stream has that PLACE's pos rewritten (and nothing else), so every order's position can be read from the
    /// event alone.
    function test_multicall_probe_logged() public {
        address a = _maker();
        address b = _maker();
        uint32 from = _pos();
        for (uint256 i = 1; i < 8; ++i) {
            _pos();
        }
        vm.startPrank(b);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 9, 5 * LOT, from, 0));
        book.place(OloOps.key(c), OloOps.placeW(false, T + 9, 5 * LOT, from + 1, 0));
        vm.stopPrank();
        bytes memory stream = _mc(
            bytes.concat(
                OloOps.placeProbe(0, T + 1, false, 5 * LOT, from, 4), // from, from + 1 busy: lands at from + 2
                OloOps.place(0, T + 2, false, 5 * LOT, from + 3), // as named
                OloOps.place(0, T + 3, false, 5 * LOT, from + 6) // as named
            )
        );
        vm.recordLogs();
        vm.prank(a);
        book.multicall(0, stream);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory logged;
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != keccak256("Ops(address,bytes)")) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), a);
            logged = abi.decode(logs[i].data, (bytes));
            assertEq(logs[i].data, abi.encode(logged), "canonical encoding: zero padding");
            n++;
        }
        assertEq(n, 1);
        // the header is 1 + 32 = 33 bytes; the first PLACE's pos is bytes 21-24 of its op
        bytes memory expected = stream;
        uint32 landed = from + 2;
        for (uint256 j; j < 4; ++j) {
            expected[33 + 21 + j] = bytes1(uint8(landed >> (24 - 8 * j)));
        }
        assertEq(logged, expected, "only the probing PLACE's pos rewritten");
        (uint256 tick,,,,) = book.orderOf(c, from + 2);
        assertEq(tick, T + 1);
        (tick,,,,) = book.orderOf(c, from + 3);
        assertEq(tick, T + 2);
        (tick,,,,) = book.orderOf(c, from + 6);
        assertEq(tick, T + 3);
        // without a probe the event is the stream itself
        vm.recordLogs();
        bytes memory plain = _mc(OloOps.place(0, T + 4, false, 5 * LOT, from + 7));
        vm.prank(a);
        book.multicall(0, plain);
        logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("Ops(address,bytes)")) {
                assertEq(abi.decode(logs[i].data, (bytes)), plain);
            }
        }
        _solvent();
    }

    /// Two PLACEs of one stream that both probe are both logged where they landed.
    function test_multicall_two_probes_logged() public {
        address a = _maker();
        address b = _maker();
        uint32 from = _pos();
        for (uint256 i = 1; i < 6; ++i) {
            _pos();
        }
        vm.startPrank(b);
        book.place(OloOps.key(c), OloOps.placeW(false, T + 9, 5 * LOT, from, 0));
        book.place(OloOps.key(c), OloOps.placeW(false, T + 9, 5 * LOT, from + 2, 0));
        vm.stopPrank();
        bytes memory stream = _mc(
            bytes.concat(
                OloOps.placeProbe(0, T + 1, false, 5 * LOT, from, 4), // from busy: lands at from + 1
                OloOps.placeProbe(0, T + 2, false, 5 * LOT, from + 2, 4) // from + 2 busy: lands at from + 3
            )
        );
        vm.recordLogs();
        vm.prank(a);
        book.multicall(0, stream);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory logged;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("Ops(address,bytes)")) logged = abi.decode(logs[i].data, (bytes));
        }
        // the header is 33 bytes; a PLACE's pos is bytes 21-24 of its 25
        bytes memory expected = stream;
        for (uint256 j; j < 4; ++j) {
            expected[33 + 21 + j] = bytes1(uint8((from + 1) >> (24 - 8 * j)));
            expected[33 + 25 + 21 + j] = bytes1(uint8((from + 3) >> (24 - 8 * j)));
        }
        assertEq(logged, expected, "both probing PLACEs rewritten");
    }

    /// A sell that would give base and receive nothing is refused: 1 base wei into a bid at P = 1 brings a quote of 1
    /// and owes a fee of ceil(0.00005) = 1, SellBelowFee in base mode and in quote mode (an amount of 1 quote wei
    /// affords that one wei); 2 wei bring 2, pay 1 and receive 1.
    function test_a_sell_that_would_receive_nothing_is_refused() public {
        address b = _plain(T, true, 5 * LOT);
        bytes memory list = OloOps.poolList(_poolEntry(b));
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.SellBelowFee.selector);
        book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(false, 1, OloOps.WALLET)));
        vm.prank(taker);
        vm.expectRevert(IOloBookBase.SellBelowFee.selector);
        book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.quoteW(false, 1, OloOps.WALLET)));
        vm.prank(taker);
        (uint256 sold, uint256 got) =
            book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(false, 2, OloOps.WALLET)));
        assertEq(sold, 2, "2 base wei sold");
        assertEq(got, 1, "quote 2 less a fee of ceil(0.0001) = 1");
        _solvent();
    }
}
