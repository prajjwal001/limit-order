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

/// OloSentinel: the fixture and the deployment, the roles, an op's window, and one op a key (OloSentinelOps: the ops).
contract OloSentinelTest is OloSentinelBase {
    using MarketLib for MarketWord;

    uint256 constant STEP = 10_000; // MarketLib.MAX_FEE_STEP_PPM

    function setUp() public {
        _deploySentinelFixture();
    }

    // ------------------------------------------------------------------ fixture

    function test_fixture() public view {
        assertEq(book.owner(), address(sentinel));
        assertEq(book.pendingOwner(), address(0));
        assertEq(sentinel.book(), address(book));
        assertEq(sentinel.admin(), ADMIN);
        assertEq(sentinel.guardian(), GUARDIAN);
        assertEq(sentinel.delay(), DAY);
        assertEq(sentinel.MIN_DELAY(), 1 days);
        assertEq(sentinel.MAX_DELAY(), 30 days);
        assertEq(sentinel.GRACE(), 7 days);
    }

    /// `_newSentinel` as an external call: a constructor's revert is then this call's, which `expectRevert` catches,
    /// and the test goes on (a revert of the deployment inside the test's own frame would end it there, passing).
    function newSentinel(address book_, address admin_, address guardian_, uint256 delay_)
        external
        returns (IOloSentinel)
    {
        return _newSentinel(book_, admin_, guardian_, delay_);
    }

    function test_constructor_checks() public {
        vm.expectRevert(IOloSentinel.ZeroAddress.selector);
        this.newSentinel(address(0), ADMIN, GUARDIAN, DAY);
        vm.expectRevert(IOloSentinel.ZeroAddress.selector);
        this.newSentinel(address(book), address(0), GUARDIAN, DAY);
        vm.expectRevert(IOloSentinel.BadDelay.selector);
        this.newSentinel(address(book), ADMIN, GUARDIAN, 1 days - 1);
        vm.expectRevert(IOloSentinel.BadDelay.selector);
        this.newSentinel(address(book), ADMIN, GUARDIAN, 30 days + 1);
        // the bounds themselves, and no guardian
        assertEq(this.newSentinel(address(book), ADMIN, address(0), 1 days).delay(), 1 days);
        assertEq(this.newSentinel(address(book), ADMIN, address(0), 30 days).guardian(), address(0));
        // the checks ran to here
        assertEq(this.newSentinel(address(book), ADMIN, GUARDIAN, 30 days).delay(), 30 days);
    }

    function test_constructor_events() public {
        vm.recordLogs();
        IOloSentinel s = _newSentinel(address(book), ADMIN, GUARDIAN, 2 days);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        assertEq(logs[0].emitter, address(s));
        assertEq(logs[0].topics[0], IOloSentinel.AdminSet.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(ADMIN))));
        assertEq(logs[1].topics[0], IOloSentinel.GuardianSet.selector);
        assertEq(logs[1].topics[1], bytes32(uint256(uint160(GUARDIAN))));
        assertEq(logs[2].topics[0], IOloSentinel.DelaySet.selector);
        assertEq(abi.decode(logs[2].data, (uint256)), 2 days);
    }

    /// The OLO EVM contract answers its old owner NotOwner once the sentinel owns it: every owner call goes through an
    /// op.
    function test_the_old_owner_is_out() public {
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.setMarketFee(m, 60, 0);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        book.transferOwnership(address(this));
    }

    /// acceptBookOwnership: anyone may call it, and it takes the OLO EVM contract only when the OLO EVM contract's
    /// owner proposed the sentinel.
    function test_accept_book_ownership_needs_the_proposal() public {
        IOloSentinel other = _newSentinel(address(book), ADMIN, GUARDIAN, DAY);
        vm.expectRevert(IOwned2Step.NotPendingOwner.selector);
        other.acceptBookOwnership();
    }

    // -------------------------------------------------------------------- roles

    function test_only_admin_schedules() public {
        bytes[] memory ops = _one(_fee(m, 60));
        vm.prank(GUARDIAN);
        vm.expectRevert(IOloSentinel.NotAdmin.selector);
        sentinel.schedule(ops);
        vm.expectRevert(IOloSentinel.NotAdmin.selector);
        sentinel.schedule(ops);
    }

    /// A sentinel schedules only while it owns the OLO EVM contract (NotBookOwner): one proposed as the next owner, and
    /// one the contract has left, schedule nothing. So a chain of sentinels of one admin, each proposed by an op of the
    /// one before, moves a market's fee as one sentinel does, 1% a delay: a successor schedules once it has accepted,
    /// a delay ahead. (Without the check, steps scheduled on the successors before the handover all ran in its
    /// transaction: 50 to 30,050 ppm through three sentinels one delay after they were scheduled.)
    function test_only_the_owner_schedules() public {
        IOloSentinel s2 = _newSentinel(address(book), ADMIN, GUARDIAN, DAY);
        vm.prank(ADMIN);
        vm.expectRevert(IOloSentinel.NotBookOwner.selector);
        s2.schedule(_one(_fee(m, STEP + 50)));
        // a delay later: the first step and the proposal
        vm.prank(ADMIN);
        uint256 eta = sentinel.schedule(_two(_fee(m, STEP + 50), _bookOwner(address(s2))));
        vm.warp(eta);
        vm.prank(ADMIN);
        sentinel.execute(_two(_fee(m, STEP + 50), _bookOwner(address(s2))));
        vm.prank(ADMIN);
        vm.expectRevert(IOloSentinel.NotBookOwner.selector);
        s2.schedule(_one(_fee(m, 2 * STEP + 50))); // proposed, not yet the owner
        s2.acceptBookOwnership();
        vm.prank(ADMIN);
        vm.expectRevert(IOloSentinel.NotBookOwner.selector);
        sentinel.schedule(_one(_fee(m, 2 * STEP + 50))); // the sentinel the contract left
        // the successor's step: a delay from its acceptance
        vm.prank(ADMIN);
        uint256 eta2 = s2.schedule(_one(_fee(m, 2 * STEP + 50)));
        assertEq(eta2, eta + DAY);
        bytes32 key = s2.keyOf(_fee(m, 2 * STEP + 50));
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotReady.selector, key, eta2));
        s2.execute(_one(_fee(m, 2 * STEP + 50)));
        vm.warp(eta2);
        vm.prank(ADMIN);
        s2.execute(_one(_fee(m, 2 * STEP + 50)));
        assertEq(book.configOf(m).feePpm(), 2 * STEP + 50, "two steps in two delays");
    }

    /// An op runs only in the stretch of ownership it was scheduled in: once the sentinel has handed the OLO EVM
    /// contract on and accepted it back, every op scheduled before is stale. It does not run (NotScheduled), reads as
    /// none (`pending`), holds no key (a new op takes it) and cannot be cancelled. So a sentinel banks no op across a
    /// handover: neither one held back from an earlier stretch nor one scheduled after its transfer ran, while the
    /// successor had not accepted yet.
    function test_an_op_runs_only_in_its_stretch_of_ownership() public {
        IOloSentinel s2 = _newSentinel(address(book), ADMIN, GUARDIAN, DAY);
        bytes memory step = _fee(m, STEP + 50);
        vm.prank(ADMIN);
        uint256 eta = sentinel.schedule(_two(step, _bookOwner(address(s2))));
        vm.warp(eta);
        vm.startPrank(ADMIN);
        sentinel.execute(_one(_bookOwner(address(s2)))); // the step held back
        sentinel.schedule(_one(_bookOwner(address(s2)))); // still the owner until s2 accepts: one more, held back
        vm.stopPrank();
        s2.acceptBookOwnership();
        vm.prank(ADMIN);
        uint256 eta2 = s2.schedule(_one(_bookOwner(address(sentinel))));
        vm.warp(eta2);
        vm.prank(ADMIN);
        s2.execute(_one(_bookOwner(address(sentinel))));
        sentinel.acceptBookOwnership();
        assertEq(book.owner(), address(sentinel), "back with the sentinel");
        // both ops it held are stale: neither runs, both read as none
        bytes32 key = sentinel.keyOf(step);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotScheduled.selector, key));
        sentinel.execute(_one(step));
        bytes32 tKey = sentinel.keyOf(_bookOwner(address(s2)));
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotScheduled.selector, tKey));
        sentinel.execute(_one(_bookOwner(address(s2))));
        (bytes32 h, uint64 e) = sentinel.pending(key);
        assertEq(uint256(h) + e, 0, "a stale op reads as none");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotScheduled.selector, key));
        sentinel.cancel(keys);
        assertEq(book.configOf(m).feePpm(), 50, "the fee untouched");
        // the key is free: the step scheduled anew waits a delay from now
        vm.prank(ADMIN);
        uint256 eta3 = sentinel.schedule(_one(step));
        assertEq(eta3, block.timestamp + DAY);
        vm.warp(eta3);
        vm.prank(ADMIN);
        sentinel.execute(_one(step));
        assertEq(book.configOf(m).feePpm(), STEP + 50);
    }

    /// The sentinel's proposal of itself (here withdrawing a proposal to another sentinel) begins no stretch when it is
    /// accepted: the sentinel held the OLO EVM contract throughout. `acceptBookOwnership` is anyone's, at any moment,
    /// and leaves every op as it was, a guardian change too (which the guardian cannot cancel); the proposal withdrawn
    /// is gone.
    function test_own_proposal_accepted_keeps_the_stretch() public {
        IOloSentinel s2 = _newSentinel(address(book), ADMIN, GUARDIAN, DAY);
        _scheduleAndRun(_bookOwner(address(s2)));
        _scheduleAndRun(_bookOwner(address(sentinel)));
        assertEq(book.pendingOwner(), address(sentinel), "the proposal to s2 withdrawn");
        bytes memory g = _guardian(address(0x6A3));
        uint256 eta = _schedule(g);
        // a second before the eta, a stranger accepts the sentinel's proposal of itself
        vm.warp(eta - 1);
        vm.prank(address(0xBAD));
        sentinel.acceptBookOwnership();
        assertEq(book.owner(), address(sentinel));
        assertEq(book.pendingOwner(), address(0));
        (bytes32 h, uint64 e) = sentinel.pending(sentinel.keyOf(g));
        assertEq(h, keccak256(g), "still pending");
        assertEq(e, eta);
        vm.expectRevert(IOwned2Step.NotPendingOwner.selector);
        s2.acceptBookOwnership();
        vm.warp(eta);
        _execute(g);
        assertEq(sentinel.guardian(), address(0x6A3), "the guardian change ran at its eta");
    }

    /// A stretch is read in whole seconds: an op scheduled in the second the sentinel takes the OLO EVM contract back,
    /// before it does, is in the new stretch, and waits its delay there. Here the contract goes to an address and back
    /// in one second (a sentinel successor cannot hand it back so soon: its own ops wait a delay in its stretch).
    function test_an_op_of_the_second_a_stretch_begins_is_in_it() public {
        address y = address(0x7777);
        uint256 eta = _schedule(_bookOwner(y));
        vm.warp(eta);
        bytes memory step = _fee(m, 60);
        uint256 stepEta = _schedule(step);
        _execute(_bookOwner(y));
        vm.prank(y);
        book.acceptOwnership();
        vm.prank(y);
        book.transferOwnership(address(sentinel));
        sentinel.acceptBookOwnership();
        (bytes32 h,) = sentinel.pending(sentinel.keyOf(step));
        assertEq(h, keccak256(step), "scheduled in the stretch's first second: in it");
        assertEq(stepEta, block.timestamp + DAY, "a whole delay inside the stretch");
        vm.warp(stepEta);
        _execute(step);
        assertEq(book.configOf(m).feePpm(), 60);
    }

    /// Once the sentinel has handed the OLO EVM contract on, an op to the OLO EVM contract reverts there (NotOwner),
    /// while an op of the sentinel's own settings scheduled in its last stretch still runs.
    function test_after_a_handover_only_own_settings_run() public {
        address y = address(0x7777);
        bytes memory step = _fee(m, 60);
        vm.prank(ADMIN);
        uint256 eta = sentinel.schedule(_two(_bookOwner(y), _admin(address(0xA2))));
        _schedule(step);
        vm.warp(eta);
        _execute(_bookOwner(y));
        vm.prank(y);
        book.acceptOwnership();
        vm.prank(ADMIN);
        vm.expectRevert(IOwned2Step.NotOwner.selector);
        sentinel.execute(_one(step));
        _execute(_admin(address(0xA2)));
        assertEq(sentinel.pendingAdmin(), address(0xA2));
    }

    function test_only_admin_executes() public {
        uint256 eta = _schedule(_fee(m, 60));
        vm.warp(eta);
        bytes[] memory ops = _one(_fee(m, 60));
        vm.prank(GUARDIAN);
        vm.expectRevert(IOloSentinel.NotAdmin.selector);
        sentinel.execute(ops);
        vm.prank(address(0xBAD));
        vm.expectRevert(IOloSentinel.NotAdmin.selector);
        sentinel.execute(ops);
        _execute(_fee(m, 60));
        assertEq(book.configOf(m).feePpm(), 60);
    }

    function test_cancel_by_admin_or_guardian() public {
        bytes32 feeKey = sentinel.keyOf(_fee(m, 60));
        bytes32 shareKey = sentinel.keyOf(_share(m, 5000));
        vm.startPrank(ADMIN);
        sentinel.schedule(_two(_fee(m, 60), _share(m, 5000)));
        vm.stopPrank();
        vm.prank(address(0xBAD));
        vm.expectRevert(IOloSentinel.NotCanceller.selector);
        sentinel.cancel(_keys(feeKey));
        vm.prank(GUARDIAN);
        sentinel.cancel(_keys(feeKey));
        vm.prank(ADMIN);
        sentinel.cancel(_keys(shareKey));
        (bytes32 h, uint64 eta) = sentinel.pending(feeKey);
        assertEq(h, 0);
        assertEq(eta, 0);
        // nothing is left to cancel, or to run
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotScheduled.selector, feeKey));
        sentinel.cancel(_keys(feeKey));
        vm.warp(vm.getBlockTimestamp() + DAY);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotScheduled.selector, feeKey));
        sentinel.execute(_one(_fee(m, 60)));
    }

    /// The guardian cancels any op but a guardian change: the admin replaces a guardian gone wrong, a delay later.
    function test_guardian_cannot_cancel_a_guardian_change() public {
        address next = address(0x6A2E);
        bytes32 key = sentinel.keyOf(_guardian(next));
        uint256 eta = _schedule(_guardian(next));
        vm.prank(GUARDIAN);
        vm.expectRevert(IOloSentinel.NotCanceller.selector);
        sentinel.cancel(_keys(key));
        // nor within a list of keys
        _schedule(_fee(m, 60));
        bytes32[] memory both = new bytes32[](2);
        both[0] = sentinel.keyOf(_fee(m, 60));
        both[1] = key;
        vm.prank(GUARDIAN);
        vm.expectRevert(IOloSentinel.NotCanceller.selector);
        sentinel.cancel(both);
        vm.warp(eta);
        _execute(_guardian(next));
        assertEq(sentinel.guardian(), next);
        // the old guardian cancels nothing now, the new one does
        vm.prank(GUARDIAN);
        vm.expectRevert(IOloSentinel.NotCanceller.selector);
        sentinel.cancel(_keys(both[0]));
        vm.prank(next);
        sentinel.cancel(_keys(both[0]));
    }

    /// The admin cancels a guardian change.
    function test_admin_cancels_a_guardian_change() public {
        bytes32 key = sentinel.keyOf(_guardian(address(0)));
        _schedule(_guardian(address(0)));
        vm.prank(ADMIN);
        sentinel.cancel(_keys(key));
        (, uint64 eta) = sentinel.pending(key);
        assertEq(eta, 0);
    }

    /// No guardian: the admin alone cancels.
    function test_no_guardian() public {
        _scheduleAndRun(_guardian(address(0)));
        assertEq(sentinel.guardian(), address(0));
        bytes32 key = sentinel.keyOf(_fee(m, 60));
        _schedule(_fee(m, 60));
        vm.prank(GUARDIAN);
        vm.expectRevert(IOloSentinel.NotCanceller.selector);
        sentinel.cancel(_keys(key));
        vm.prank(address(0));
        vm.expectRevert(IOloSentinel.NotCanceller.selector);
        sentinel.cancel(_keys(key));
        vm.prank(ADMIN);
        sentinel.cancel(_keys(key));
    }

    /// The sentinel's own settings run only as ops: not even the admin calls them directly.
    function test_own_settings_only_by_ops() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(IOloSentinel.NotSelf.selector);
        sentinel.setDelay(2 days);
        vm.expectRevert(IOloSentinel.NotSelf.selector);
        sentinel.setGuardian(address(1));
        vm.expectRevert(IOloSentinel.NotSelf.selector);
        sentinel.transferAdmin(address(1));
        vm.stopPrank();
    }

    function test_admin_two_step() public {
        address next = address(0xAD32);
        _scheduleAndRun(_admin(next));
        assertEq(sentinel.pendingAdmin(), next);
        assertEq(sentinel.admin(), ADMIN);
        // the old admin is the admin until the new one accepts
        _schedule(_fee(m, 60));
        vm.prank(address(0xBAD));
        vm.expectRevert(IOloSentinel.NotPendingAdmin.selector);
        sentinel.acceptAdmin();
        vm.prank(next);
        sentinel.acceptAdmin();
        assertEq(sentinel.admin(), next);
        assertEq(sentinel.pendingAdmin(), address(0));
        // the new admin runs what the old one scheduled; the old one is out
        vm.warp(vm.getBlockTimestamp() + DAY);
        vm.prank(ADMIN);
        vm.expectRevert(IOloSentinel.NotAdmin.selector);
        sentinel.execute(_one(_fee(m, 60)));
        vm.prank(next);
        sentinel.execute(_one(_fee(m, 60)));
        assertEq(book.configOf(m).feePpm(), 60);
    }

    /// transferAdmin(0) withdraws a proposal.
    function test_admin_proposal_withdrawn() public {
        address next = address(0xAD32);
        _scheduleAndRun(_admin(next));
        _scheduleAndRun(_admin(address(0)));
        assertEq(sentinel.pendingAdmin(), address(0));
        vm.prank(next);
        vm.expectRevert(IOloSentinel.NotPendingAdmin.selector);
        sentinel.acceptAdmin();
    }

    // ------------------------------------------------------------- the window

    function test_execute_window() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 eta = _schedule(_fee(m, 60));
        assertEq(eta, t0 + DAY);
        bytes32 key = sentinel.keyOf(_fee(m, 60));
        (bytes32 h, uint64 stored) = sentinel.pending(key);
        assertEq(h, keccak256(_fee(m, 60)));
        assertEq(stored, eta);
        uint256 snap = vm.snapshotState();

        vm.warp(eta - 1);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotReady.selector, key, eta));
        sentinel.execute(_one(_fee(m, 60)));

        vm.warp(eta);
        _execute(_fee(m, 60));
        assertEq(book.configOf(m).feePpm(), 60);
        vm.revertToState(snap);

        vm.warp(eta + 7 days);
        _execute(_fee(m, 60));
        assertEq(book.configOf(m).feePpm(), 60);
        vm.revertToState(snap);

        vm.warp(eta + 7 days + 1);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.Expired.selector, key, eta));
        sentinel.execute(_one(_fee(m, 60)));
    }

    /// An expired op frees its key: it cancels no more (NotScheduled), and a new op takes the key.
    function test_expiry_frees_the_key() public {
        uint256 eta = _schedule(_fee(m, 60));
        bytes32 key = sentinel.keyOf(_fee(m, 60));
        vm.warp(eta + 7 days);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.KeyPending.selector, key));
        sentinel.schedule(_one(_fee(m, 70)));
        vm.warp(eta + 7 days + 1);
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotScheduled.selector, key));
        sentinel.cancel(_keys(key));
        // the stale entry stays in storage until a new op overwrites it
        (, uint64 stale) = sentinel.pending(key);
        assertEq(stale, eta);
        uint256 eta2 = _schedule(_fee(m, 70));
        vm.warp(eta2);
        // the expired op is gone: its calldata no longer matches the key's
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotScheduled.selector, key));
        sentinel.execute(_one(_fee(m, 60)));
        _execute(_fee(m, 70));
        assertEq(book.configOf(m).feePpm(), 70);
    }

    // --------------------------------------------------------------------- keys

    /// One op a key: another op on the key waits until the first runs, is cancelled or expires.
    function test_one_op_a_key() public {
        bytes32 key = sentinel.keyOf(_fee(m, 60));
        uint256 eta = _schedule(_fee(m, 60));
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.KeyPending.selector, key));
        sentinel.schedule(_one(_fee(m, 70)));
        // the same op again too
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.KeyPending.selector, key));
        sentinel.schedule(_one(_fee(m, 60)));
        vm.warp(eta);
        _execute(_fee(m, 60));
        // run: the key is free
        _schedule(_fee(m, 70));
        vm.prank(GUARDIAN);
        sentinel.cancel(_keys(key));
        // cancelled: free again
        _schedule(_fee(m, 80));
    }

    /// Two ops of one key in one schedule call: the second is refused, and nothing is scheduled.
    function test_one_key_twice_in_one_call() public {
        bytes32 key = sentinel.keyOf(_fee(m, 60));
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.KeyPending.selector, key));
        sentinel.schedule(_two(_fee(m, 60), _fee(m, 70)));
        (, uint64 eta) = sentinel.pending(key);
        assertEq(eta, 0);
    }

    /// A key names the setting: its setter's selector and its object.
    function test_keys() public view {
        address a = address(base);
        address b = address(quote);
        // a market: its id, any value of its setting
        assertEq(sentinel.keyOf(_fee(m, 60)), keccak256(abi.encode(IOloBookExt.setMarketFee.selector, uint256(m))));
        assertEq(sentinel.keyOf(_fee(m, 60)), sentinel.keyOf(abi.encodeCall(IOloBookExt.setMarketFee, (m, 9, 512))));
        assertEq(sentinel.keyOf(_share(m, 1)), keccak256(abi.encode(IOloBookExt.setMarketMakerShare.selector, m)));
        // a pair: its tokens in the OLO EVM contract's order, so either order; a set and a lift alike
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        bytes32 floorKey = keccak256(abi.encode(IOloBookExt.setPairFeeFloor.selector, t0, t1));
        assertEq(sentinel.keyOf(_pairFloor(a, b, 100, true)), floorKey);
        assertEq(sentinel.keyOf(_pairFloor(b, a, 0, false)), floorKey);
        bytes32 shareKey = keccak256(abi.encode(IOloBookExt.setPairMakerShare.selector, t0, t1));
        assertEq(sentinel.keyOf(_pairShare(b, a, 100, true)), shareKey);
        assertEq(sentinel.keyOf(_pairShare(a, b, 0, false)), shareKey);
        // a global setting: its selector alone
        assertEq(sentinel.keyOf(_globalFloor(5)), keccak256(abi.encode(IOloBookExt.setGlobalFeeFloor.selector)));
        assertEq(sentinel.keyOf(_delay(2 days)), keccak256(abi.encode(IOloSentinel.setDelay.selector)));
        assertEq(sentinel.keyOf(_bookOwner(address(1))), keccak256(abi.encode(IOwned2Step.transferOwnership.selector)));
        // a lister's right: (selector, the lister), an allow and a stop alike
        bytes32 listerKey = keccak256(abi.encode(IOloBookExt.setProprietaryListingAllowed.selector, address(0x1157)));
        assertEq(sentinel.keyOf(_lister(address(0x1157), true)), listerKey);
        assertEq(sentinel.keyOf(_lister(address(0x1157), false)), listerKey);
    }

    /// Every setting has its own key: thirteen kinds, and two objects of each kind that has one.
    function test_keys_are_distinct() public view {
        address a = address(base);
        address b = address(quote);
        address z = address(0xC0FFEE);
        bytes[] memory ops = new bytes[](18);
        ops[0] = _fee(m, 60);
        ops[1] = _fee(m + 1, 60);
        ops[2] = _share(m, 60);
        ops[3] = _share(m + 1, 60);
        ops[4] = _pairFloor(a, b, 60, true);
        ops[5] = _pairFloor(a, z, 60, true);
        ops[6] = _pairShare(a, b, 60, true);
        ops[7] = _pairShare(a, z, 60, true);
        ops[8] = _globalFloor(60);
        ops[9] = _globalShare(60);
        ops[10] = _listingFee(60);
        ops[11] = _recipient(z);
        ops[12] = _bookOwner(z);
        ops[13] = _delay(2 days);
        ops[14] = _guardian(z);
        ops[15] = _admin(z);
        ops[16] = _lister(a, true);
        ops[17] = _lister(z, true);
        for (uint256 i; i < ops.length; ++i) {
            for (uint256 j = i + 1; j < ops.length; ++j) {
                assertTrue(sentinel.keyOf(ops[i]) != sentinel.keyOf(ops[j]));
            }
        }
    }

    /// A market's fee and share are two keys: both scheduled and run in one transaction, the share first and the fee
    /// second (IOloBookExt.setMarketFee), two versions; the fee still steps at most 1%.
    function test_fee_and_share_together() public {
        uint256 v = book.configOf(m).version();
        vm.prank(ADMIN);
        uint256 eta = sentinel.schedule(_two(_share(m, 5000), _fee(m, 50 + STEP)));
        vm.warp(eta);
        vm.prank(ADMIN);
        sentinel.execute(_two(_share(m, 5000), _fee(m, 50 + STEP)));
        MarketWord now_ = book.configOf(m);
        assertEq(now_.makerBps(), 5000);
        assertEq(now_.feePpm(), 50 + STEP);
        assertEq(now_.version(), v + 2);
    }

    /// Two markets are two keys: each moves 1% a delay, both in one transaction.
    function test_markets_are_separate_keys() public {
        uint32 m2 = book.listMarketQuote(address(base), address(quote), 50, 5, 1, 0);
        vm.prank(ADMIN);
        uint256 eta = sentinel.schedule(_two(_fee(m, 50 + STEP), _fee(m2, 50 + STEP)));
        vm.warp(eta);
        vm.prank(ADMIN);
        sentinel.execute(_two(_fee(m, 50 + STEP), _fee(m2, 50 + STEP)));
        assertEq(book.configOf(m).feePpm(), 50 + STEP);
        assertEq(book.configOf(m2).feePpm(), 50 + STEP);
    }

    /// An op runs only as scheduled: the key's op with other calldata is NotScheduled.
    function test_execute_needs_the_exact_op() public {
        bytes32 key = sentinel.keyOf(_fee(m, 60));
        uint256 eta = _schedule(_fee(m, 60));
        vm.warp(eta);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotScheduled.selector, key));
        sentinel.execute(_one(_fee(m, 61)));
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotScheduled.selector, key));
        sentinel.execute(_one(abi.encodeCall(IOloBookExt.setMarketFee, (m, 60, 1))));
        // never scheduled
        bytes32 other = sentinel.keyOf(_globalShare(1));
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotScheduled.selector, other));
        sentinel.execute(_one(_globalShare(1)));
    }
}
