// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloSentinel} from "../sentinel/OloSentinel.sol";
import {IOloSentinel} from "../sentinel/IOloSentinel.sol";
import {IOloBookExt} from "../src/interfaces/IOloBookExt.sol";
import {IOwned2Step} from "../src/interfaces/IOwned2Step.sol";

/// Fixture for OloSentinel: OloBase's OLO EVM contract and market, then a sentinel (admin ADMIN, guardian GUARDIAN, a
/// delay of one day) that owns the OLO EVM contract. The sentinel is deployed from the `sentinel` profile's artifact
/// when it exists, as it ships, and only if no source it was compiled from has changed since.
abstract contract OloSentinelBase is OloBase {
    string internal constant SENTINEL = "out-sentinel/OloSentinel.sol/OloSentinel.json";

    address internal constant ADMIN = address(0xAD31);
    address internal constant GUARDIAN = address(0x6A2D);
    uint256 internal constant DAY = 1 days;

    IOloSentinel sentinel;

    /// The OLO EVM contract, its market, and a sentinel that owns it.
    function _deploySentinelFixture() internal {
        _deploy();
        sentinel = _newSentinel(address(book), ADMIN, GUARDIAN, DAY);
        book.transferOwnership(address(sentinel));
        // anyone completes the handover
        vm.prank(address(0xA11));
        sentinel.acceptBookOwnership();
    }

    function _newSentinel(address book_, address admin_, address guardian_, uint256 delay_)
        internal
        returns (IOloSentinel)
    {
        if (vm.exists(SENTINEL)) {
            _requireFresh(SENTINEL, "FOUNDRY_PROFILE=sentinel forge build sentinel");
            return IOloSentinel(vm.deployCode(SENTINEL, abi.encode(book_, admin_, guardian_, delay_)));
        }
        return new OloSentinel(book_, admin_, guardian_, delay_);
    }

    function _one(bytes memory op) internal pure returns (bytes[] memory ops) {
        ops = new bytes[](1);
        ops[0] = op;
    }

    function _two(bytes memory a, bytes memory b) internal pure returns (bytes[] memory ops) {
        ops = new bytes[](2);
        ops[0] = a;
        ops[1] = b;
    }

    function _keys(bytes32 k) internal pure returns (bytes32[] memory keys) {
        keys = new bytes32[](1);
        keys[0] = k;
    }

    /// The admin schedules `op`; its eta.
    function _schedule(bytes memory op) internal returns (uint256) {
        vm.prank(ADMIN);
        return sentinel.schedule(_one(op));
    }

    function _execute(bytes memory op) internal {
        vm.prank(ADMIN);
        sentinel.execute(_one(op));
    }

    /// The admin schedules `op`, waits the delay and runs it.
    function _scheduleAndRun(bytes memory op) internal {
        uint256 eta = _schedule(op);
        vm.warp(eta);
        _execute(op);
    }

    // the ops, as the OLO EVM contract (or the sentinel) receives them

    function _fee(uint256 id, uint256 ppm) internal pure returns (bytes memory) {
        return abi.encodeCall(IOloBookExt.setMarketFee, (id, uint24(ppm), 0));
    }

    function _share(uint256 id, uint256 bps) internal pure returns (bytes memory) {
        return abi.encodeCall(IOloBookExt.setMarketMakerShare, (id, uint48(bps)));
    }

    function _globalFloor(uint256 ppm) internal pure returns (bytes memory) {
        return abi.encodeCall(IOloBookExt.setGlobalFeeFloor, (uint32(ppm)));
    }

    function _globalShare(uint256 bps) internal pure returns (bytes memory) {
        return abi.encodeCall(IOloBookExt.setGlobalMakerShare, (uint24(bps)));
    }

    function _pairFloor(address a, address b, uint256 ppm, bool set) internal pure returns (bytes memory) {
        return abi.encodeCall(IOloBookExt.setPairFeeFloor, (a, b, uint32(ppm), set));
    }

    function _pairShare(address a, address b, uint256 bps, bool set) internal pure returns (bytes memory) {
        return abi.encodeCall(IOloBookExt.setPairMakerShare, (a, b, uint40(bps), set));
    }

    function _listingFee(uint256 wei_) internal pure returns (bytes memory) {
        return abi.encodeCall(IOloBookExt.setCurrentListingFee, (uint80(wei_)));
    }

    function _recipient(address r) internal pure returns (bytes memory) {
        return abi.encodeCall(IOloBookExt.setFeeRecipient, (r));
    }

    function _bookOwner(address o) internal pure returns (bytes memory) {
        return abi.encodeCall(IOwned2Step.transferOwnership, (o));
    }

    function _delay(uint256 d) internal pure returns (bytes memory) {
        return abi.encodeCall(IOloSentinel.setDelay, (d));
    }

    function _guardian(address g) internal pure returns (bytes memory) {
        return abi.encodeCall(IOloSentinel.setGuardian, (g));
    }

    function _admin(address a) internal pure returns (bytes memory) {
        return abi.encodeCall(IOloSentinel.transferAdmin, (a));
    }

    function _lister(address lister, bool allowed) internal pure returns (bytes memory) {
        return abi.encodeCall(IOloBookExt.setProprietaryListingAllowed, (lister, allowed));
    }
}
