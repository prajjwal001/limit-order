// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloSentinelBase} from "./OloSentinelBase.sol";
import {IOloSentinel} from "../sentinel/IOloSentinel.sol";

/// Gas of OloSentinel (run with --isolate): frame gas of each call, 21,000 and calldata included. An op's run is the
/// sentinel's check and the OLO EVM contract's own call; `book_*` rows are the OLO EVM contract's call made directly by
/// its owner, for the difference.
contract GasBenchSentinel is OloSentinelBase {
    function setUp() public {
        _deploySentinelFixture();
    }

    function _logS(string memory k, uint256 g) internal pure {
        _log(string.concat("sentinel_", k), g);
    }

    function test_sentinel_rows() public {
        // one op: a market's fee
        vm.prank(ADMIN);
        uint256 eta = sentinel.schedule(_one(_fee(m, 60)));
        _logS("schedule_market_fee", _gas());
        vm.warp(eta);
        vm.prank(ADMIN);
        sentinel.execute(_one(_fee(m, 60)));
        _logS("execute_market_fee", _gas());

        // two ops in one call: a market's share, then its fee
        vm.prank(ADMIN);
        eta = sentinel.schedule(_two(_share(m, 5000), _fee(m, 70)));
        _logS("schedule_share_and_fee", _gas());
        vm.warp(eta);
        vm.prank(ADMIN);
        sentinel.execute(_two(_share(m, 5000), _fee(m, 70)));
        _logS("execute_share_and_fee", _gas());

        // a pair's floor (the widest op), and a global one
        vm.prank(ADMIN);
        eta = sentinel.schedule(_one(_pairFloor(address(base), address(quote), 100, true)));
        _logS("schedule_pair_fee_floor", _gas());
        vm.prank(ADMIN);
        sentinel.schedule(_one(_globalFloor(100)));
        _logS("schedule_global_fee_floor", _gas());
        vm.warp(eta);
        vm.prank(ADMIN);
        sentinel.execute(_one(_pairFloor(address(base), address(quote), 100, true)));
        _logS("execute_pair_fee_floor", _gas());
        vm.prank(ADMIN);
        sentinel.execute(_one(_globalFloor(100)));
        _logS("execute_global_fee_floor", _gas());

        // a cancel by the guardian
        vm.prank(ADMIN);
        sentinel.schedule(_one(_fee(m, 80)));
        bytes32[] memory keys = _keys(sentinel.keyOf(_fee(m, 80)));
        vm.prank(GUARDIAN);
        sentinel.cancel(keys);
        _logS("cancel_by_guardian", _gas());

        // a setting of the sentinel's own
        vm.prank(ADMIN);
        eta = sentinel.schedule(_one(_delay(2 days)));
        vm.warp(eta);
        vm.prank(ADMIN);
        sentinel.execute(_one(_delay(2 days)));
        _logS("execute_set_delay", _gas());
    }

    /// `acceptBookOwnership`: taking the OLO EVM contract over from another owner (a sentinel that never owned it,
    /// and one taking it back), and the sentinel's proposal of itself accepted (no new stretch).
    function test_accept_rows() public {
        IOloSentinel s2 = _newSentinel(address(book), ADMIN, GUARDIAN, DAY);
        _scheduleAndRun(_bookOwner(address(s2)));
        s2.acceptBookOwnership();
        _logS("accept_takeover", _gas());
        vm.prank(ADMIN);
        uint256 eta = s2.schedule(_one(_bookOwner(address(sentinel))));
        vm.warp(eta);
        vm.prank(ADMIN);
        s2.execute(_one(_bookOwner(address(sentinel))));
        sentinel.acceptBookOwnership();
        _logS("accept_taken_back", _gas());
        _scheduleAndRun(_bookOwner(address(sentinel)));
        sentinel.acceptBookOwnership();
        _logS("accept_own_proposal", _gas());
    }

    /// The OLO EVM contract's calls made directly by an owner, on the same state the sentinel's rows run them on.
    function test_book_rows() public {
        // the fixture's OLO EVM contract, owned again by this contract
        vm.prank(ADMIN);
        uint256 eta = sentinel.schedule(_one(_bookOwner(address(this))));
        vm.warp(eta);
        vm.prank(ADMIN);
        sentinel.execute(_one(_bookOwner(address(this))));
        book.acceptOwnership();
        book.setMarketFee(m, 60, 0);
        _logS("book_set_market_fee", _gas());
        book.setPairFeeFloor(address(base), address(quote), 100, true);
        _logS("book_set_pair_fee_floor", _gas());
        book.setGlobalFeeFloor(100);
        _logS("book_set_global_fee_floor", _gas());
    }
}
