// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {OloSentinelBase} from "./OloSentinelBase.sol";
import {IOloSentinel} from "../sentinel/IOloSentinel.sol";
import {IOloBookExt} from "../src/interfaces/IOloBookExt.sol";
import {OloBook} from "../src/OloBook.sol";
import {MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

/// The admin, at random: schedules fee, share, floor and delay ops (some the OLO EVM contract refuses when they run),
/// runs what is due, one or all at once, cancels as the admin or the guardian, and lets time pass. It records each run
/// of each key, and each market's fee and the global floor as they move.
contract SentinelHandler is Test {
    using MarketLib for MarketWord;

    uint256 constant STEP = 10_000;

    IOloSentinel immutable sentinel;
    OloBook immutable book;
    address immutable guardian;
    address immutable tokenA;
    address immutable tokenB;
    uint32[] markets;

    /// Ops scheduled and not run or cancelled (expired ones too).
    bytes[] open;
    /// Each key's last run, and the least time between two runs of one key.
    mapping(bytes32 => uint256) lastRun;
    uint256 public minGap = type(uint256).max;
    uint256 public runs;
    /// The fee's (or floor's) largest move in one run, ppm.
    uint256 public maxStep;

    constructor(IOloSentinel s, OloBook b, address g, address ta, address tb, uint32[] memory ms) {
        sentinel = s;
        book = b;
        guardian = g;
        tokenA = ta;
        tokenB = tb;
        markets = ms;
    }

    function marketsOf() external view returns (uint32[] memory) {
        return markets;
    }

    // --------------------------------------------------------------- actions

    function warp(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 3 days));
    }

    /// A fee op on a market, a step of `step` from its fee now (above 1% at times: the OLO EVM contract refuses it when
    /// it runs).
    function scheduleFee(uint256 mi, uint256 step, bool up) external {
        uint32 id = markets[mi % markets.length];
        uint256 fee = book.configOf(id).feePpm();
        uint256 to = _moved(fee, bound(step, 1, STEP + STEP / 10), up);
        if (to == fee) return;
        _schedule(abi.encodeCall(IOloBookExt.setMarketFee, (id, uint24(to), 0)));
    }

    function scheduleShare(uint256 mi, uint256 bps) external {
        uint32 id = markets[mi % markets.length];
        _schedule(abi.encodeCall(IOloBookExt.setMarketMakerShare, (id, uint48(bound(bps, 0, 10_000)))));
    }

    function scheduleGlobalFloor(uint256 step, bool up) external {
        (, uint24 floor,,,,) = book.pairDefaultsOf(tokenA, tokenB);
        uint256 to = _moved(floor, bound(step, 1, STEP + STEP / 10), up);
        _schedule(abi.encodeCall(IOloBookExt.setGlobalFeeFloor, (uint32(to))));
    }

    function schedulePairFloor(uint256 step, bool up, bool set) external {
        (uint24 floor,,,,,) = book.pairDefaultsOf(tokenA, tokenB);
        uint256 to = set ? _moved(floor, bound(step, 0, STEP + STEP / 10), up) : 0;
        _schedule(abi.encodeCall(IOloBookExt.setPairFeeFloor, (tokenB, tokenA, uint32(to), set)));
    }

    function scheduleDelay(uint256 d) external {
        _schedule(abi.encodeCall(IOloSentinel.setDelay, (bound(d, 1 days, 3 days))));
    }

    /// Runs one open op, picked by `i`.
    function execute(uint256 i) external {
        if (open.length == 0) return;
        i %= open.length;
        bytes[] memory one = new bytes[](1);
        one[0] = open[i];
        _run(one);
    }

    /// Runs every open op that is due, in one transaction.
    function executeDue() external {
        uint256 n;
        bytes[] memory due = new bytes[](open.length);
        for (uint256 i; i < open.length; ++i) {
            (, uint64 eta) = sentinel.pending(sentinel.keyOf(open[i]));
            uint256 now_ = vm.getBlockTimestamp();
            if (eta != 0 && now_ >= eta && now_ <= eta + 7 days) due[n++] = open[i];
        }
        assembly ("memory-safe") {
            mstore(due, n)
        }
        if (n != 0) _run(due);
    }

    function cancel(uint256 i, bool byGuardian) external {
        if (open.length == 0) return;
        i %= open.length;
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = sentinel.keyOf(open[i]);
        vm.prank(byGuardian ? guardian : address(this));
        try sentinel.cancel(keys) {
            _drop(i);
        } catch {}
    }

    // -------------------------------------------------------------- internal

    function _schedule(bytes memory op) internal {
        bytes[] memory one = new bytes[](1);
        one[0] = op;
        bytes32 key = sentinel.keyOf(op);
        try sentinel.schedule(one) {
            // an expired op of the key, overwritten, leaves the open list
            for (uint256 i; i < open.length; ++i) {
                if (sentinel.keyOf(open[i]) == key) {
                    _drop(i);
                    break;
                }
            }
            open.push(op);
        } catch {}
    }

    /// Runs `ops`; on success records each key's run, and how far each fee or floor moved.
    function _run(bytes[] memory ops) internal {
        uint256[] memory before = _fees();
        try sentinel.execute(ops) {
            uint256 now_ = vm.getBlockTimestamp();
            for (uint256 i; i < ops.length; ++i) {
                bytes32 key = sentinel.keyOf(ops[i]);
                uint256 last = lastRun[key];
                if (last != 0 && now_ - last < minGap) minGap = now_ - last;
                lastRun[key] = now_;
                ++runs;
                for (uint256 j; j < open.length; ++j) {
                    if (keccak256(open[j]) == keccak256(ops[i])) {
                        _drop(j);
                        break;
                    }
                }
            }
            uint256[] memory after_ = _fees();
            for (uint256 j; j < before.length; ++j) {
                uint256 d = after_[j] > before[j] ? after_[j] - before[j] : before[j] - after_[j];
                if (d > maxStep) maxStep = d;
            }
        } catch {}
    }

    /// Each market's fee, then the global floor. What the pair's next listing meets is not here: fed by two keys (its
    /// own floor, else the global one), it moves up to 2% in one transaction (accepted; `invariant_pair_listing_floor`
    /// bounds it).
    function _fees() internal view returns (uint256[] memory f) {
        f = new uint256[](markets.length + 1);
        for (uint256 i; i < markets.length; ++i) {
            f[i] = book.configOf(markets[i]).feePpm();
        }
        (, uint24 floor,,,,) = book.pairDefaultsOf(tokenA, tokenB);
        f[markets.length] = floor;
    }

    function _moved(uint256 from, uint256 step, bool up) internal pure returns (uint256) {
        if (up) return from + step > 1_000_000 ? 1_000_000 : from + step;
        return step > from ? 0 : from - step;
    }

    function _drop(uint256 i) internal {
        open[i] = open[open.length - 1];
        open.pop();
    }
}

/// OloSentinel under random ops: one key runs at most once a MIN_DELAY, and no fee or floor moves more than 1% in a
/// transaction, so a market's fee moves at most 1% a day; the sentinel keeps the OLO EVM contract.
contract OloSentinelInvariantTest is OloSentinelBase {
    using MarketLib for MarketWord;

    SentinelHandler handler;
    uint256 t0;
    /// What the pair's next listing meets at the start: the global floor, the pair having none of its own.
    uint256 pairStart;

    function setUp() public {
        _deploy();
        uint32[] memory ms = new uint32[](2);
        ms[0] = m;
        ms[1] = book.listMarketQuote(address(base), address(quote), 50, 5, 1, 0);
        // the handler is the admin; its sentinel owns the OLO EVM contract
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        handler = new SentinelHandler(IOloSentinel(predicted), book, GUARDIAN, address(base), address(quote), ms);
        sentinel = _newSentinel(address(book), address(handler), GUARDIAN, DAY);
        require(address(sentinel) == predicted, "sentinel address");
        book.transferOwnership(address(sentinel));
        sentinel.acceptBookOwnership();
        t0 = vm.getBlockTimestamp();
        (pairStart,,,,,) = book.pairDefaultsOf(address(base), address(quote));
        targetContract(address(handler));
    }

    function invariant_one_run_a_key_a_day() public view {
        assertGe(handler.minGap(), 1 days);
    }

    function invariant_one_percent_a_run() public view {
        assertLe(handler.maxStep(), 10_000);
    }

    /// From the start: each market's fee within 1% x (days + 1) of 50 ppm.
    function invariant_fee_rate() public view {
        uint256 days_ = (vm.getBlockTimestamp() - t0) / 1 days;
        uint32[] memory ms = handler.marketsOf();
        for (uint256 i; i < ms.length; ++i) {
            uint256 fee = book.configOf(ms[i]).feePpm();
            uint256 d = fee > 50 ? fee - 50 : 50 - fee;
            assertLe(d, 10_000 * (days_ + 1));
        }
    }

    /// What the pair's next listing meets (its own floor, else the global one): within 1% x (days + 2) of the start.
    /// Fed by two keys, it moves at most (n + 1)% over n runs of each from a pair with no floor of its own (the
    /// fixture's), and each key runs at most once a day, so at most days + 1 times.
    function invariant_pair_listing_floor() public view {
        uint256 days_ = (vm.getBlockTimestamp() - t0) / 1 days;
        (uint256 meets,,,,,) = book.pairDefaultsOf(address(base), address(quote));
        uint256 d = meets > pairStart ? meets - pairStart : pairStart - meets;
        assertLe(d, 10_000 * (days_ + 2));
    }

    function invariant_the_sentinel_keeps_the_book() public view {
        assertEq(book.owner(), address(sentinel));
    }

    /// The handler reaches what the invariants watch: ops of every kind run, one at a time and together, a key runs
    /// again after the delay in force, a cancel frees a key, and a refused op stays open. Checked here, not per run: a
    /// random run may run no op at all (an `afterInvariant` check of each run failed on one, and foundry replayed the
    /// persisted failure in every later run).
    function test_handler_reaches_everything() public {
        handler.scheduleFee(0, 10_000, true);
        handler.scheduleShare(1, 5000);
        handler.scheduleGlobalFloor(10_000, true);
        handler.schedulePairFloor(10_000, true, true);
        handler.scheduleDelay(2 days);
        handler.warp(1 days);
        handler.executeDue();
        assertEq(handler.runs(), 5);
        assertEq(sentinel.delay(), 2 days);
        assertEq(book.configOf(m).feePpm(), 10_050);
        // the next step of the fee waits the new delay
        handler.scheduleFee(0, 10_000, true);
        handler.warp(1 days);
        handler.execute(0);
        assertEq(handler.runs(), 5);
        handler.warp(1 days);
        handler.execute(0);
        assertEq(handler.runs(), 6);
        assertEq(handler.minGap(), 2 days);
        assertEq(handler.maxStep(), 10_000);
        // a step past 1% is refused when it runs and stays open; the guardian cancels it
        handler.scheduleFee(0, 11_000, true);
        handler.warp(2 days);
        handler.execute(0);
        assertEq(handler.runs(), 6);
        handler.cancel(0, true);
        handler.scheduleFee(0, 10_000, false);
        handler.warp(2 days);
        handler.executeDue();
        assertEq(handler.runs(), 7);
        assertEq(book.configOf(m).feePpm(), 10_050);
    }
}
