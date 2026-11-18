// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {OloBook} from "../src/OloBook.sol";
import {OloBookExt} from "../src/OloBookExt.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {IOwned2Step} from "../src/interfaces/IOwned2Step.sol";
import {SafeTransfer} from "../src/libraries/SafeTransfer.sol";

/// A fee recipient that refuses the native currency, or re-enters the OLO EVM contract from inside the payment.
contract Recipient {
    OloBook book;
    bool refuse;
    bool reenter;
    bytes4 public seen;

    constructor(OloBook book_) {
        book = book_;
    }

    function set(bool refuse_, bool reenter_) external {
        refuse = refuse_;
        reenter = reenter_;
    }

    receive() external payable {
        if (refuse) revert("no");
        if (reenter) {
            try book.collectFees(address(0)) {}
            catch (bytes memory err) {
                seen = bytes4(err);
            }
        }
    }
}

/// The listing fee: the native currency a listing sends, exactly, 0 until the owner sets one; the fees stay in the
/// contract and `collectFees(address(0))` pays them to the fee recipient. A hook against listing abuse.
contract OloListingFeeTest is OloBase {
    uint256 constant FEE = 0.01 ether;
    address recipient = address(0xFEE5);

    function setUp() public {
        _deploy();
        book.setFeeRecipient(recipient);
        vm.deal(address(this), 10 ether);
        vm.deal(taker, 10 ether);
    }

    function _list(address b, uint256 value) internal returns (uint32) {
        return book.listMarketQuote{value: value}(b, address(quote), 50, 6, 1, 0);
    }

    /// Deployed at 0: a listing sends nothing, and one that sends anything is refused.
    function test_fee_starts_at_zero() public {
        assertEq(book.listingFeeCurrent(), 0);
        MockERC20 b2 = new MockERC20("Bee", "BEE", 6);
        vm.expectRevert(IOloBookBase.BadListingFee.selector);
        _list(address(b2), 1);
        _list(address(b2), 0);
        assertEq(address(book).balance, 0);
    }

    /// The owner sets the fee (event, view); then a listing sends exactly it: nothing, less or more is refused, and
    /// a refused listing registers nothing.
    function test_owner_sets_the_fee_and_listings_pay_it_exactly() public {
        vm.prank(taker);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setCurrentListingFee(uint80(FEE));
        vm.expectEmit(address(book));
        emit IOloBookBase.ListingFeeSet(uint80(FEE));
        book.setCurrentListingFee(uint80(FEE));
        assertEq(book.listingFeeCurrent(), FEE);

        MockERC20 b2 = new MockERC20("Bee", "BEE", 6);
        vm.expectRevert(IOloBookBase.BadListingFee.selector);
        _list(address(b2), 0);
        vm.expectRevert(IOloBookBase.BadListingFee.selector);
        _list(address(b2), FEE - 1);
        vm.expectRevert(IOloBookBase.BadListingFee.selector);
        _list(address(b2), FEE + 1);
        assertEq(book.tokenId(address(b2)), 0, "a refused listing registers nothing");
        uint32 id = _list(address(b2), FEE);
        assertEq(id, m + 1);
        assertEq(address(book).balance, FEE, "the fee stays in the book");
        // anyone lists at the fee
        MockERC20 b3 = new MockERC20("Cee", "CEE", 6);
        vm.prank(taker);
        book.listMarketQuote{value: FEE}(address(b3), address(quote), 50, 6, 1, 0);
        assertEq(address(book).balance, 2 * FEE);
        // back to 0: a listing sends nothing again
        book.setCurrentListingFee(0);
        MockERC20 b4 = new MockERC20("Dee", "DEE", 6);
        _list(address(b4), 0);
        assertEq(address(book).balance, 2 * FEE);
    }

    /// `collectFees(address(0))` pays the contract's whole native balance to the fee recipient, with the event; a
    /// second call pays 0 and does not revert.
    function test_collect_native_fees() public {
        book.setCurrentListingFee(uint80(FEE));
        _list(address(new MockERC20("Bee", "BEE", 6)), FEE);
        _list(address(new MockERC20("Cee", "CEE", 6)), FEE);
        uint256 r0 = recipient.balance;
        vm.prank(taker); // anyone
        vm.expectEmit(address(book));
        emit IOloBookBase.FeesCollected(address(0), recipient, 2 * FEE);
        uint256 paid = book.collectFees(address(0));
        assertEq(paid, 2 * FEE);
        assertEq(recipient.balance - r0, 2 * FEE);
        assertEq(address(book).balance, 0);
        assertEq(book.collectFees(address(0)), 0, "nothing left: 0, no revert");
    }

    /// A recipient that refuses the native currency makes the collection revert (the fees stay); one that re-enters
    /// from inside the payment meets the lock, and is paid once.
    function test_native_payment_refused_or_reentered() public {
        Recipient r = new Recipient(book);
        book.setFeeRecipient(address(r));
        book.setCurrentListingFee(uint80(FEE));
        _list(address(new MockERC20("Bee", "BEE", 6)), FEE);
        r.set(true, false);
        vm.expectRevert(SafeTransfer.TransferFailed.selector);
        book.collectFees(address(0));
        assertEq(address(book).balance, FEE, "refused: the fee stays");
        r.set(false, true);
        assertEq(book.collectFees(address(0)), FEE);
        assertEq(r.seen(), IOloBookBase.Locked.selector, "the re-entry met the lock");
        assertEq(address(r).balance, FEE, "paid once");
        assertEq(address(book).balance, 0);
    }

    /// The extension called directly runs in its own storage, where the fee is 0: value sent there is refused, so no
    /// native currency can be stranded in it by a listing.
    function test_extension_called_directly_takes_no_value() public {
        OloBookExt ext = OloBookExt(book.ext());
        vm.expectRevert(IOloBookBase.BadListingFee.selector);
        ext.listMarketQuote{value: 1}(address(base), address(quote), 50, 6, 1, 0);
    }
}
