// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {OloSentinelBase} from "./OloSentinelBase.sol";
import {IOloSentinel} from "../sentinel/IOloSentinel.sol";
import {IOloBookBase} from "../src/interfaces/IOloBookBase.sol";
import {IOloBookExt} from "../src/interfaces/IOloBookExt.sol";
import {IOwned2Step} from "../src/interfaces/IOwned2Step.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

/// OloSentinel's ops: how they decode, each of the thirteen run, a revert, the delay's change, the rate a fee moves at,
/// a scenario and the events.
contract OloSentinelOpsTest is OloSentinelBase {
    using MarketLib for MarketWord;

    uint256 constant STEP = 10_000; // MarketLib.MAX_FEE_STEP_PPM

    function setUp() public {
        _deploySentinelFixture();
    }

    // ------------------------------------------------------------ decoding ops

    /// Only the thirteen: no other entry of the OLO EVM contract (a listing, open or proprietary, a fee collection, a
    /// warming, its acceptOwnership), no entry of the sentinel's own but its three settings, and nothing shorter than a
    /// selector.
    function test_unknown_ops() public {
        bytes[] memory bad = new bytes[](9);
        bad[0] = abi.encodeCall(IOloBookExt.listMarketQuote, (address(base), address(quote), 60, 6, 1, 0));
        bad[1] = abi.encodeCall(IOloBookExt.collectFees, (address(base)));
        bad[2] = abi.encodeCall(IOloBookExt.warmPool, (m, 0, 1));
        bad[3] = abi.encodeCall(IOwned2Step.acceptOwnership, ());
        bad[4] = abi.encodeCall(IOloSentinel.schedule, (_one(_fee(m, 60))));
        bad[5] = abi.encodeCall(IOloSentinel.acceptAdmin, ());
        bad[6] = abi.encodeCall(IOloSentinel.acceptBookOwnership, ());
        bad[7] = abi.encodeCall(IOloSentinel.cancel, (_keys(bytes32(0))));
        bad[8] = abi.encodeCall(
            IOloBookExt.listMarketQuoteProprietary, (address(base), address(quote), 60, 6, 1, 0, address(1))
        );
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IOloSentinel.UnknownOp.selector, bytes4(bad[i])));
            sentinel.keyOf(bad[i]);
            vm.prank(ADMIN);
            vm.expectRevert(abi.encodeWithSelector(IOloSentinel.UnknownOp.selector, bytes4(bad[i])));
            sentinel.schedule(_one(bad[i]));
        }
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.UnknownOp.selector, bytes4(0)));
        sentinel.keyOf(hex"fe3172");
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.UnknownOp.selector, bytes4(0)));
        sentinel.keyOf("");
    }

    /// An op's length is exactly its arguments': a word short or a byte long is MalformedOp.
    function test_lengths() public {
        bytes[] memory ops = _allOps();
        for (uint256 i; i < ops.length; ++i) {
            bytes memory longer = bytes.concat(ops[i], hex"00");
            vm.expectRevert(IOloSentinel.MalformedOp.selector);
            sentinel.keyOf(longer);
            bytes memory shorter = new bytes(ops[i].length - 32);
            for (uint256 j; j < shorter.length; ++j) {
                shorter[j] = ops[i][j];
            }
            vm.expectRevert(IOloSentinel.MalformedOp.selector);
            sentinel.keyOf(shorter);
            // a selector alone
            vm.expectRevert(IOloSentinel.MalformedOp.selector);
            sentinel.keyOf(bytes.concat(bytes4(ops[i])));
        }
    }

    /// Each typed argument fits its type: a bit above it is MalformedOp, as the OLO EVM contract's decoder would refuse
    /// it. A market's id and the delay are uint256 (the OLO EVM contract refuses an id not listed, setDelay a delay out
    /// of its bounds).
    function test_argument_widths() public {
        // (op, the word, its width)
        _widthCase(_fee(m, 60), 1, 24);
        _widthCase(_fee(m, 60), 2, 64);
        _widthCase(_share(m, 60), 1, 48);
        _widthCase(_pairFloor(address(base), address(quote), 60, true), 0, 160);
        _widthCase(_pairFloor(address(base), address(quote), 60, true), 1, 160);
        _widthCase(_pairFloor(address(base), address(quote), 60, true), 2, 32);
        _widthCase(_pairFloor(address(base), address(quote), 60, true), 3, 1);
        _widthCase(_pairShare(address(base), address(quote), 60, true), 0, 160);
        _widthCase(_pairShare(address(base), address(quote), 60, true), 1, 160);
        _widthCase(_pairShare(address(base), address(quote), 60, true), 2, 40);
        _widthCase(_pairShare(address(base), address(quote), 60, true), 3, 1);
        _widthCase(_globalFloor(60), 0, 32);
        _widthCase(_globalShare(60), 0, 24);
        _widthCase(_listingFee(60), 0, 80);
        _widthCase(_recipient(address(1)), 0, 160);
        _widthCase(_bookOwner(address(1)), 0, 160);
        _widthCase(_guardian(address(1)), 0, 160);
        _widthCase(_admin(address(1)), 0, 160);
        _widthCase(_lister(address(1), true), 0, 160);
        _widthCase(_lister(address(1), true), 1, 1);
        // the full words take any value
        bytes memory id = _fee(type(uint256).max, 60);
        sentinel.keyOf(id);
        sentinel.keyOf(_share(type(uint256).max, 60));
        sentinel.keyOf(_delay(type(uint256).max));
    }

    /// Word `w` of `op` with each bit from `bits` up set alone is MalformedOp; its widest value passes.
    function _widthCase(bytes memory op, uint256 w, uint256 bits) internal {
        bytes memory widest = _withWord(op, w, bits == 256 ? type(uint256).max : (uint256(1) << bits) - 1);
        sentinel.keyOf(widest);
        for (uint256 bit = bits; bit < 256; bit += 7) {
            vm.expectRevert(IOloSentinel.MalformedOp.selector);
            sentinel.keyOf(_withWord(op, w, uint256(1) << bit));
        }
        vm.expectRevert(IOloSentinel.MalformedOp.selector);
        sentinel.keyOf(_withWord(op, w, uint256(1) << 255));
    }

    function testFuzz_argument_widths(uint256 word) public {
        // a market fee op's fee word: valid exactly below 2^24
        bytes memory op = _withWord(_fee(m, 60), 1, word);
        if (word >> 24 != 0) vm.expectRevert(IOloSentinel.MalformedOp.selector);
        sentinel.keyOf(op);
        // a pair op's token words: valid exactly below 2^160, and either order one key
        op = _withWord(_pairFloor(address(base), address(quote), 60, true), 0, word);
        if (word >> 160 != 0) {
            vm.expectRevert(IOloSentinel.MalformedOp.selector);
            sentinel.keyOf(op);
        } else {
            address t = address(uint160(word));
            assertEq(
                sentinel.keyOf(_pairFloor(t, address(quote), 0, false)),
                sentinel.keyOf(_pairFloor(address(quote), t, 5, true))
            );
        }
    }

    function _withWord(bytes memory op, uint256 w, uint256 value) internal pure returns (bytes memory out) {
        out = bytes.concat(op);
        assembly ("memory-safe") {
            mstore(add(add(out, 0x24), mul(w, 0x20)), value)
        }
    }

    /// One op of each of the thirteen kinds.
    function _allOps() internal view returns (bytes[] memory ops) {
        ops = new bytes[](13);
        ops[0] = _fee(m, 60);
        ops[1] = _share(m, 60);
        ops[2] = _pairFloor(address(base), address(quote), 60, true);
        ops[3] = _pairShare(address(base), address(quote), 60, true);
        ops[4] = _globalFloor(60);
        ops[5] = _globalShare(60);
        ops[6] = _listingFee(60);
        ops[7] = _recipient(address(1));
        ops[8] = _bookOwner(address(1));
        ops[9] = _delay(2 days);
        ops[10] = _guardian(address(1));
        ops[11] = _admin(address(1));
        ops[12] = _lister(address(1), true);
    }

    // -------------------------------------------------------- every owner op of the OLO EVM contract

    /// Each of the OLO EVM contract's ten owner ops, scheduled and run: the OLO EVM contract changes as the owner's own
    /// call would change it.
    function test_every_book_op() public {
        address a = address(base);
        address b = address(quote);
        _scheduleAndRun(_fee(m, 60));
        assertEq(book.configOf(m).feePpm(), 60);
        _scheduleAndRun(_share(m, 2500));
        assertEq(book.configOf(m).makerBps(), 2500);
        _scheduleAndRun(_globalFloor(STEP));
        (, uint24 globalFloor,,,,) = book.pairDefaultsOf(a, b);
        assertEq(globalFloor, STEP);
        _scheduleAndRun(_globalShare(3000));
        (,,,, uint16 globalBps,) = book.pairDefaultsOf(a, b);
        assertEq(globalBps, 3000);
        _scheduleAndRun(_pairFloor(b, a, 2 * STEP, true));
        (uint24 pairFloor,, bool floorSet,,,) = book.pairDefaultsOf(a, b);
        assertEq(pairFloor, 2 * STEP);
        assertTrue(floorSet);
        _scheduleAndRun(_pairShare(a, b, 7000, true));
        (,,, uint16 pairBps,, bool shareSet) = book.pairDefaultsOf(a, b);
        assertEq(pairBps, 7000);
        assertTrue(shareSet);
        // and the lifts
        _scheduleAndRun(_pairFloor(a, b, 0, false));
        _scheduleAndRun(_pairShare(b, a, 0, false));
        (,, floorSet,,, shareSet) = book.pairDefaultsOf(a, b);
        assertFalse(floorSet);
        assertFalse(shareSet);
        _scheduleAndRun(_listingFee(1 ether));
        assertEq(book.listingFeeCurrent(), 1 ether);
        _scheduleAndRun(_recipient(address(0xFEE)));
        assertEq(book.feeRecipient(), address(0xFEE));
        // a lister allowed, then stopped: one key, run twice
        _scheduleAndRun(_lister(address(0x1157), true));
        assertTrue(book.canListProprietaryMarkets(address(0x1157)));
        _scheduleAndRun(_lister(address(0x1157), false));
        assertFalse(book.canListProprietaryMarkets(address(0x1157)));
        // the OLO EVM contract's ownership: proposed by an op, taken by the new owner's accept
        _scheduleAndRun(_bookOwner(address(0x0E)));
        assertEq(book.pendingOwner(), address(0x0E));
        assertEq(book.owner(), address(sentinel));
        vm.prank(address(0x0E));
        book.acceptOwnership();
        assertEq(book.owner(), address(0x0E));
    }

    /// The sentinel's own three settings, as ops: run on the sentinel.
    function test_every_own_op() public {
        _scheduleAndRun(_delay(3 days));
        assertEq(sentinel.delay(), 3 days);
        _scheduleAndRun(_guardian(address(0x6A2E)));
        assertEq(sentinel.guardian(), address(0x6A2E));
        _scheduleAndRun(_admin(address(0xAD32)));
        assertEq(sentinel.pendingAdmin(), address(0xAD32));
    }

    /// An op's revert is the call's, as the OLO EVM contract gave it: nothing runs, and the ops stay scheduled.
    function test_a_revert_is_the_books() public {
        // the OLO EVM contract refuses a fee step past 1%
        bytes memory tooFar = _fee(m, 50 + STEP + 1);
        bytes32 key = sentinel.keyOf(tooFar);
        uint256 eta = _schedule(tooFar);
        vm.warp(eta);
        vm.prank(ADMIN);
        vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        sentinel.execute(_one(tooFar));
        (bytes32 h,) = sentinel.pending(key);
        assertEq(h, keccak256(tooFar));
        // a list fails whole: its first op is undone and stays scheduled too
        bytes memory fine = _globalShare(4000);
        _schedule(fine);
        vm.warp(vm.getBlockTimestamp() + DAY);
        vm.prank(ADMIN);
        vm.expectRevert(IOloBookBase.FeeStepTooLarge.selector);
        sentinel.execute(_two(fine, tooFar));
        (,,,, uint16 globalBps,) = book.pairDefaultsOf(address(base), address(quote));
        assertEq(globalBps, 10_000);
        (h,) = sentinel.pending(sentinel.keyOf(fine));
        assertEq(h, keccak256(fine));
        // the sentinel's own setting's revert too
        _schedule(_delay(1 days - 1));
        vm.warp(vm.getBlockTimestamp() + DAY);
        vm.prank(ADMIN);
        vm.expectRevert(IOloSentinel.BadDelay.selector);
        sentinel.execute(_one(_delay(1 days - 1)));
        // a recipient the OLO EVM contract refuses
        _schedule(_recipient(address(book)));
        vm.warp(vm.getBlockTimestamp() + DAY);
        vm.prank(ADMIN);
        vm.expectRevert(IOloBookBase.BadAddress.selector);
        sentinel.execute(_one(_recipient(address(book))));
    }

    // ------------------------------------------------------------------- delay

    /// A delay change waits the delay before it; ops scheduled before keep their eta, ops after take the new delay.
    function test_delay_change() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 etaFee = _schedule(_fee(m, 60));
        uint256 etaDelay = _schedule(_delay(3 days));
        assertEq(etaDelay, t0 + DAY);
        vm.warp(etaDelay);
        _execute(_delay(3 days));
        assertEq(sentinel.delay(), 3 days);
        // the fee op keeps its eta
        (, uint64 kept) = sentinel.pending(sentinel.keyOf(_fee(m, 60)));
        assertEq(kept, etaFee);
        _execute(_fee(m, 60));
        // a new op waits three days
        uint256 eta = _schedule(_fee(m, 70));
        assertEq(eta, vm.getBlockTimestamp() + 3 days);
        // and a shorter delay waits the longer one before it
        uint256 etaBack = _schedule(_delay(1 days));
        assertEq(etaBack, vm.getBlockTimestamp() + 3 days);
    }

    function test_delay_bounds() public {
        bytes[] memory bad = _two(_delay(1 days - 1), _delay(30 days + 1));
        for (uint256 i; i < 2; ++i) {
            uint256 eta = _schedule(bad[i]);
            vm.warp(eta);
            vm.prank(ADMIN);
            vm.expectRevert(IOloSentinel.BadDelay.selector);
            sentinel.execute(_one(bad[i]));
            bytes32 key = sentinel.keyOf(bad[i]);
            vm.prank(ADMIN);
            sentinel.cancel(_keys(key));
        }
        _scheduleAndRun(_delay(30 days));
        assertEq(sentinel.delay(), 30 days);
        _scheduleAndRun(_delay(1 days));
        assertEq(sentinel.delay(), 1 days);
    }

    // -------------------------------------------------------------------- rate

    /// A market's fee moves at most 1% a delay: the next step waits for the last one to run, then a delay more. From
    /// 0.005% to 5.005% takes five steps, four delays apart at least.
    function test_fee_moves_one_percent_a_delay() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 fee = 50;
        for (uint256 i; i < 5; ++i) {
            uint256 eta = _schedule(_fee(m, fee + STEP));
            // the step after it waits
            bytes32 key = sentinel.keyOf(_fee(m, 0));
            vm.prank(ADMIN);
            vm.expectRevert(abi.encodeWithSelector(IOloSentinel.KeyPending.selector, key));
            sentinel.schedule(_one(_fee(m, fee + 2 * STEP)));
            vm.warp(eta);
            _execute(_fee(m, fee + STEP));
            fee += STEP;
        }
        assertEq(book.configOf(m).feePpm(), 50 + 5 * STEP);
        assertEq(vm.getBlockTimestamp(), t0 + 5 * DAY);
    }

    /// What a pair's next listing meets (its own floor, else the global one) is fed by two keys: from a pair with no
    /// floor of its own it moves 2% in one transaction (the global floor 1%, then the pair's first floor 1% above it).
    /// Accepted: listings only, no market's fee moves. The pair's next step waits a delay.
    function test_global_and_pair_floor_in_one_transaction() public {
        address a = address(base);
        address b = address(quote);
        vm.prank(ADMIN);
        uint256 eta = sentinel.schedule(_two(_globalFloor(STEP), _pairFloor(a, b, 2 * STEP, true)));
        vm.warp(eta);
        vm.prank(ADMIN);
        sentinel.execute(_two(_globalFloor(STEP), _pairFloor(a, b, 2 * STEP, true)));
        (uint24 pairFloor, uint24 globalFloor, bool set,,,) = book.pairDefaultsOf(a, b);
        assertEq(globalFloor, STEP);
        assertEq(pairFloor, 2 * STEP);
        assertTrue(set);
        // the market listed before keeps its fee
        assertEq(book.configOf(m).feePpm(), 50);
        // the pair's next step waits a delay
        _schedule(_pairFloor(a, b, 3 * STEP, true));
        bytes32 key = sentinel.keyOf(_pairFloor(a, b, 0, false));
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.KeyPending.selector, key));
        sentinel.schedule(_one(_pairFloor(a, b, 0, false)));
    }

    /// From an own floor 1% under the global one, two 2% moves follow each other a delay apart: a lift then the
    /// global floor (the pair meets the global floor, +1%, which then moves +1%), and a delay later the global floor
    /// then the pair's first floor 1% above it. 4% in two runs of each key, the most (n + 2)% allows for n = 2.
    /// Listings only: the market listed before keeps its fee.
    function test_pair_listing_floor_moves_4_percent_in_two_delays() public {
        address a = address(base);
        address b = address(quote);
        (, uint256 g0,,,,) = book.pairDefaultsOf(a, b);
        // set-up, two delays: the global floor two steps up, the pair's own floor one step up (1% under it)
        _runTwo(_globalFloor(g0 + STEP), _pairFloor(a, b, g0 + STEP, true));
        _scheduleAndRun(_globalFloor(g0 + 2 * STEP));
        (uint256 meets, uint256 g, bool set,,,) = book.pairDefaultsOf(a, b);
        assertEq(g, g0 + 2 * STEP);
        assertEq(meets, g0 + STEP);
        assertTrue(set);

        uint256 t0 = vm.getBlockTimestamp();
        uint256 start = meets;
        // delay 1: the lift (the pair meets the global floor: +1%), then the global floor (+1%)
        _runTwo(_pairFloor(a, b, 0, false), _globalFloor(g0 + 3 * STEP));
        (meets,,,,,) = book.pairDefaultsOf(a, b);
        assertEq(meets, start + 2 * STEP, "2% in the first transaction");
        // delay 2: the global floor (+1%), then the pair's first floor 1% above it
        _runTwo(_globalFloor(g0 + 4 * STEP), _pairFloor(a, b, g0 + 5 * STEP, true));
        (meets,,,,,) = book.pairDefaultsOf(a, b);
        assertEq(meets, start + 4 * STEP, "and 2% again a delay later");
        assertEq(vm.getBlockTimestamp(), t0 + 2 * DAY, "in two delays");
        assertEq(book.configOf(m).feePpm(), 50);
    }

    /// The admin schedules `a` and `b` in one call and runs them in one call, a delay later.
    function _runTwo(bytes memory a, bytes memory b) internal {
        vm.prank(ADMIN);
        uint256 eta = sentinel.schedule(_two(a, b));
        vm.warp(eta);
        vm.prank(ADMIN);
        sentinel.execute(_two(a, b));
    }

    // -------------------------------------------------------------- scenarios

    /// An admin gone wrong: it schedules the OLO EVM contract's ownership away and a guardian of its own. The guardian
    /// cancels the first; it cannot cancel the second, which runs a delay later; a new ownership op then waits another
    /// delay, so everyone has a delay's notice of each, and the OLO EVM contract's owner stays the sentinel throughout.
    function test_admin_gone_wrong() public {
        address thief = address(0x7E1F);
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(ADMIN);
        sentinel.schedule(_two(_bookOwner(thief), _guardian(thief)));
        bytes32 ownerKey = sentinel.keyOf(_bookOwner(thief));
        bytes32 guardianKey = sentinel.keyOf(_guardian(thief));
        vm.prank(GUARDIAN);
        sentinel.cancel(_keys(ownerKey));
        vm.prank(GUARDIAN);
        vm.expectRevert(IOloSentinel.NotCanceller.selector);
        sentinel.cancel(_keys(guardianKey));
        vm.warp(t0 + DAY);
        _execute(_guardian(thief));
        assertEq(sentinel.guardian(), thief);
        uint256 eta = _schedule(_bookOwner(thief));
        assertEq(eta, t0 + 2 * DAY);
        assertEq(book.owner(), address(sentinel));
    }

    // ------------------------------------------------------------------ events

    function test_events() public {
        bytes memory op = _fee(m, 60);
        bytes32 key = sentinel.keyOf(op);
        vm.expectEmit(address(sentinel));
        emit IOloSentinel.Scheduled(key, vm.getBlockTimestamp() + DAY, op);
        uint256 eta = _schedule(op);
        vm.warp(eta);
        vm.expectEmit(address(sentinel));
        emit IOloSentinel.Executed(key, op);
        _execute(op);
        _schedule(op);
        vm.expectEmit(address(sentinel));
        emit IOloSentinel.Cancelled(key, GUARDIAN);
        vm.prank(GUARDIAN);
        sentinel.cancel(_keys(key));
        eta = _schedule(_delay(2 days));
        _schedule(_guardian(address(0)));
        _schedule(_admin(address(0xAD32)));
        vm.warp(eta);
        vm.expectEmit(address(sentinel));
        emit IOloSentinel.DelaySet(2 days);
        _execute(_delay(2 days));
        vm.expectEmit(address(sentinel));
        emit IOloSentinel.GuardianSet(address(0));
        _execute(_guardian(address(0)));
        vm.expectEmit(address(sentinel));
        emit IOloSentinel.AdminProposed(address(0xAD32));
        _execute(_admin(address(0xAD32)));
        vm.expectEmit(address(sentinel));
        emit IOloSentinel.AdminSet(address(0xAD32));
        vm.prank(address(0xAD32));
        sentinel.acceptAdmin();
    }

    /// The selectors the sentinel tells apart: the thirteen ops' and its own entries' are distinct.
    function test_selectors_distinct() public pure {
        bytes4[18] memory s = [
            IOloBookExt.setMarketFee.selector,
            IOloBookExt.setMarketMakerShare.selector,
            IOloBookExt.setPairFeeFloor.selector,
            IOloBookExt.setPairMakerShare.selector,
            IOloBookExt.setGlobalFeeFloor.selector,
            IOloBookExt.setGlobalMakerShare.selector,
            IOloBookExt.setCurrentListingFee.selector,
            IOloBookExt.setFeeRecipient.selector,
            IOloBookExt.setProprietaryListingAllowed.selector,
            IOwned2Step.transferOwnership.selector,
            IOloSentinel.setDelay.selector,
            IOloSentinel.setGuardian.selector,
            IOloSentinel.transferAdmin.selector,
            IOloSentinel.schedule.selector,
            IOloSentinel.execute.selector,
            IOloSentinel.cancel.selector,
            IOloSentinel.acceptBookOwnership.selector,
            IOloSentinel.acceptAdmin.selector
        ];
        for (uint256 i; i < s.length; ++i) {
            for (uint256 j = i + 1; j < s.length; ++j) {
                assertTrue(s[i] != s[j]);
            }
        }
    }
}
