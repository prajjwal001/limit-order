// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {BatchView} from "./BatchView.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";

/// A modify that keeps an order (its tick and its open amount) with fills to pay moves no escrow, as a claim moves
/// none. Refunding the open amount's quote rounded down and escrowing it again rounded up took a
/// wei from the maker whenever that quote was no whole number: a bid maker with no spare quote in its account then
/// could not make the modify a take had already brought its order to (InsufficientBalance), against the guarantee
/// that a modify to what is open pays the fills, at a share of 0 (the maker's part of the fee no longer covering the
/// wei) or a fee that floors to 0 at any share; through the wallet it cost a pull of 1 wei.
///
/// The example: a bid of 10,000,001 at T - 3 (P = 0.999997) escrows 9,999,971, all its maker holds; a sell of 4,000,000
/// leaves 6,000,001 open, whose quote 5,999,982.999997 refunds as 5,999,982 and would escrow again as 5,999,983. The
/// modify to the tick and the 6,000,001 moves no quote now: the maker gets the fills' 4,000,000 base and the fee's maker
/// part, the pot the rest (floor(199.9994) = 199 at 50 ppm).
contract OloModifyKeptTest is OloBase {
    uint256 constant BID = 10_000_001;
    uint256 constant ESCROW = 9_999_971; // ceil(10,000,001 x 0.999997)
    uint256 constant SOLD = 4_000_000;
    uint256 constant LEFT = 6_000_001;
    address constant MAKER = address(0xB1D);

    function setUp() public {
        _deploy();
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
        // the maker holds exactly the bid's escrow, in its account
        quote.mint(MAKER, ESCROW);
        vm.startPrank(MAKER);
        quote.approve(address(book), type(uint256).max);
        book.deposit(address(quote), ESCROW);
        vm.stopPrank();
    }

    function _example() internal pure {
        assertEq(PriceGrid.quoteUp(BID, T - 3), ESCROW);
        assertEq(
            PriceGrid.quoteUp(LEFT, T - 3) - PriceGrid.quoteDown(LEFT, T - 3), 1, "the open quote is no whole number"
        );
        assertEq(PriceGrid.feeDown(SOLD, T - 3, 50), 199);
    }

    /// A pool bid at a share of 0: the modify goes through with no quote to spare, the fills paid, the order resting on.
    function test_pool_modify_kept_at_share_zero() public {
        _example();
        _setMarketShare(0);
        vm.prank(MAKER);
        book.place(OloOps.key(c), OloOps.placeW(true, T - 3, BID, 7, 0));
        assertEq(_bal(MAKER, quote), 0, "all the maker's quote is escrowed");
        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(7, T - 3)), OloOps.tagW(c, OloOps.takeW(false, SOLD, 0))
        );
        vm.prank(MAKER);
        assertEq(book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(7, T - 3, LEFT, 0))), LEFT);
        (uint256 tick, uint256 open, uint256 filled, bool isBid,) = book.orderOf(c, 7);
        assertEq(tick, T - 3);
        assertEq(open, LEFT, "what was open rests on");
        assertEq(filled, 0, "the fills paid");
        assertTrue(isBid);
        assertEq(_bal(MAKER, base), SOLD, "the fills' base");
        assertEq(_bal(MAKER, quote), 0, "no quote moved: no escrow, and no fee part at a share of 0");
        assertEq(_pot(quote), 199, "the fee whole to the pot");
        _leave();
    }

    /// The same through a multicall MODIFY: its ledger nets no quote.
    function test_multicall_modify_kept_at_share_zero() public {
        _setMarketShare(0);
        vm.prank(MAKER);
        book.place(OloOps.key(c), OloOps.placeW(true, T - 3, BID, 7, 0));
        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(7, T - 3)), OloOps.tagW(c, OloOps.takeW(false, SOLD, 0))
        );
        vm.prank(MAKER);
        book.multicall(0, _mc(OloOps.modify(0, 7, T - 3, LEFT)));
        (, uint256 open, uint256 filled,,) = book.orderOf(c, 7);
        assertEq(open, LEFT);
        assertEq(filled, 0);
        assertEq(_bal(MAKER, base), SOLD);
        assertEq(_bal(MAKER, quote), 0);
        assertEq(_pot(quote), 199);
        _leave();
    }

    /// The same for a batch sub-order: the walk's refund (pass 1) and its re-escrow (pass 2) of the kept sub-order are
    /// the same amount, so the operation nets no quote.
    function test_batch_modify_kept_at_share_zero() public {
        _setMarketShare(0);
        uint256[4] memory post = [OloOps.sub(T - 3, BID), 0, 0, 0];
        uint256[4] memory kept = [OloOps.sub(T - 3, LEFT), 0, 0, 0];
        vm.prank(MAKER);
        _mb(c, OloOps.batchW(OloOps.POST, true, 3, 0, 0, post));
        assertEq(_bal(MAKER, quote), 0);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(MAKER, 3, 1, T - 3)),
            OloOps.tagW(c, OloOps.takeW(false, SOLD, 0))
        );
        vm.prank(MAKER);
        _mb(c, OloOps.batchW(OloOps.MODIFY, true, 3, 0, 0x1, kept));
        (uint256 word, uint256 set) = _slotWords(c, MAKER, 3);
        assertEq(BatchView.tickOf(word, 0), T - 3);
        assertEq(BatchView.openOf(word, 0), LEFT, "what was open rests on");
        assertEq(BatchView.baseOf(set, 0), LEFT, "the fills paid: the base is the open units");
        assertEq(_bal(MAKER, base), SOLD);
        assertEq(_bal(MAKER, quote), 0);
        assertEq(_pot(quote), 199);
        // and cancelled, the sub-order refunds its open quote rounded down
        vm.prank(MAKER);
        _mb(c, OloOps.maskW(OloOps.CANCEL, 3, 0, 0x1));
        assertEq(_bal(MAKER, quote), PriceGrid.quoteDown(LEFT, T - 3));
        _leave();
    }

    /// A kept bid whose open amount's quote is whole gets no wei back: the wei the walk gives back with the refund is
    /// the rounding, quoteUp - quoteDown, here 0, not a constant 1. At T (P = 1) a bid of 9,999,971
    /// escrows 9,999,971; a sell of 4,000,000 leaves 5,999,971 open, its quote whole; the kept modify moves no quote,
    /// and a cancel then refunds the 5,999,971 the OLO EVM contract holds for it, no more: a wei given back here would
    /// come out of other depositors' balances, which a check of the contract's balance against its pots does not see.
    function test_batch_modify_kept_whole_quote_gets_no_wei() public {
        _setMarketShare(0);
        uint256 left = ESCROW - SOLD; // 5,999,971 at T, where the price is 1
        assertEq(PriceGrid.quoteUp(left, T), PriceGrid.quoteDown(left, T), "the open quote is whole");
        assertEq(PriceGrid.quoteUp(ESCROW, T), ESCROW, "the bid escrows all the maker holds");
        uint256[4] memory post = [OloOps.sub(T, ESCROW), 0, 0, 0];
        uint256[4] memory kept = [OloOps.sub(T, left), 0, 0, 0];
        vm.prank(MAKER);
        _mb(c, OloOps.batchW(OloOps.POST, true, 3, 0, 0, post));
        assertEq(_bal(MAKER, quote), 0);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(MAKER, 3, 1, T)),
            OloOps.tagW(c, OloOps.takeW(false, SOLD, 0))
        );
        vm.prank(MAKER);
        _mb(c, OloOps.batchW(OloOps.MODIFY, true, 3, 0, 0x1, kept));
        assertEq(_bal(MAKER, base), SOLD);
        assertEq(_bal(MAKER, quote), 0, "no wei given back: the refund and the escrow are the same amount");
        vm.prank(MAKER);
        _mb(c, OloOps.maskW(OloOps.CANCEL, 3, 0, 0x1));
        assertEq(_bal(MAKER, quote), left, "the open quote refunded, and no more");
    }

    /// Not a share-of-0 matter only: at the fixture's 10,000, a fill whose fee floors to 0 left the maker's part no wei
    /// to cover with. A sell of 10,000 (fee floor(0.4999985) = 0) leaves 9,990,001 open (9,989,971.029997 quote).
    function test_pool_modify_kept_with_no_fee_part() public {
        vm.prank(MAKER);
        book.place(OloOps.key(c), OloOps.placeW(true, T - 3, BID, 7, 0));
        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(7, T - 3)), OloOps.tagW(c, OloOps.takeW(false, 10_000, 0))
        );
        assertEq(PriceGrid.feeDown(10_000, T - 3, 50), 0);
        assertEq(PriceGrid.quoteUp(9_990_001, T - 3) - PriceGrid.quoteDown(9_990_001, T - 3), 1);
        vm.prank(MAKER);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(7, T - 3, 9_990_001, 0)));
        assertEq(_bal(MAKER, base), 10_000);
        assertEq(_bal(MAKER, quote), 0);
        _leave();
    }

    /// Through the wallet nothing is pulled: the maker's wallet has no quote and no allowance, and the modify passes.
    function test_wallet_modify_kept_pulls_nothing() public {
        _setMarketShare(0);
        vm.prank(MAKER);
        book.place(OloOps.key(c), OloOps.placeW(true, T - 3, BID, 7, 0));
        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(7, T - 3)), OloOps.tagW(c, OloOps.takeW(false, SOLD, 0))
        );
        vm.startPrank(MAKER);
        quote.approve(address(book), 0);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(7, T - 3, LEFT, 0x02)));
        vm.stopPrank();
        assertEq(base.balanceOf(MAKER), SOLD, "the fills' base pushed to the wallet");
        assertEq(quote.balanceOf(MAKER), 0);
    }

    /// A modify that changes the order still prices its escrow again: a bid moved a tick escrows its new quote rounded
    /// up, and a resize at the tick refunds the old rounded down and escrows the new rounded up.
    function test_a_changed_order_is_priced_again() public {
        vm.prank(MAKER);
        book.place(OloOps.key(c), OloOps.placeW(true, T - 3, BID, 7, 0));
        vm.prank(taker);
        book.take(
            OloOps.key(c), OloOps.poolList(OloOps.poolEntry(7, T - 3)), OloOps.tagW(c, OloOps.takeW(false, SOLD, 0))
        );
        // a smaller order at the tick: the refund less the new escrow, plus the fee's maker part (the fixture's 10,000)
        uint256 smaller = 3_000_001;
        vm.prank(MAKER);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(7, T - 3, smaller, 0)));
        assertEq(
            _bal(MAKER, quote),
            199 + PriceGrid.quoteDown(LEFT, T - 3) - PriceGrid.quoteUp(smaller, T - 3),
            "refund down, escrow up"
        );
    }

    /// The maker cancels what rests and withdraws; the contract holds at least its pots.
    function _leave() internal {
        (, uint256 open,,,) = book.orderOf(c, 7);
        vm.startPrank(MAKER);
        if (open != 0) book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(7, 0)));
        book.withdraw(address(base), _bal(MAKER, base));
        book.withdraw(address(quote), _bal(MAKER, quote));
        vm.stopPrank();
        _solvent();
    }
}
