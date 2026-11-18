// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {OloOps} from "./OloOps.sol";
import {OloBook} from "../src/OloBook.sol";

/// Two-sided requotes for the GasBenchTwoSided* files (run with --isolate: each row is whole transactions, the 21k
/// and the calldata included). A maker quotes `nb` bids at T - 1, T - 2, ... and `na` asks at T + 1, T + 2, ...,
/// 5 LOT each, then requotes: every order one tick up (a replace of every slot it uses). The files differ in how the
/// slots are packed and sent: one side a slot, a call each (today); one side a slot, one group call; both sides in a
/// slot, a call each; both sides in a slot, one group call.
abstract contract TwoSidedBench is OloBase {
    uint256 internal constant AMT = 5 * LOT;

    function setUp() public virtual {
        _deploy();
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    /// The scenarios: (bids, asks).
    function _scenarios() internal pure returns (uint256[2][6] memory s) {
        s[0] = [uint256(1), 3];
        s[1] = [uint256(2), 2];
        s[2] = [uint256(3), 5];
        s[3] = [uint256(4), 4];
        s[4] = [uint256(6), 6];
        s[5] = [uint256(12), 12];
    }

    function _name(string memory method, uint256 nb, uint256 na) internal pure returns (string memory) {
        return string.concat("ts_", vm.toString(nb), "p", vm.toString(na), "_", method);
    }

    /// Order j of side `isBid`, `shift` ticks up from the post's.
    function _tickOf(bool isBid, uint256 j, uint256 shift) internal pure returns (uint256) {
        return isBid ? T - 1 - j + shift : T + 1 + j + shift;
    }

    /// One side a slot (bids in slots 0.., asks in slots 100..), four a slot: each slot's words (OloOps.batchW).
    function _oneSided(uint8 kind, uint256 nb, uint256 na, uint256 shift)
        internal
        pure
        returns (uint256[3][] memory ws)
    {
        uint256 bSlots = (nb + 3) / 4;
        uint256 aSlots = (na + 3) / 4;
        ws = new uint256[3][](bSlots + aSlots);
        for (uint256 s; s < bSlots + aSlots; ++s) {
            bool isBid = s < bSlots;
            uint256 first = 4 * (isBid ? s : s - bSlots);
            uint256 n = isBid ? nb : na;
            uint256[4] memory o;
            for (uint256 i; i < 4 && first + i < n; ++i) {
                o[i] = OloOps.sub(_tickOf(isBid, first + i, shift), AMT);
            }
            ws[s] = OloOps.batchW(kind, isBid, uint16(isBid ? s : 100 + s - bSlots), 0, 0, o);
        }
    }

    /// The gas the calldata of `data` costs (EIP-2028: 16 a nonzero byte, 4 a zero one), for the rows' notes.
    function _cdGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// One manageBatchSubs call a slot, each its own transaction: the summed gas and the number of calls.
    function _perSlotCalls(address z, uint256[3][] memory ws) internal returns (uint256 total) {
        for (uint256 s; s < ws.length; ++s) {
            vm.prank(z);
            _mb(c, ws[s]);
            total += _receipt();
        }
    }

    function _bookSel() internal pure returns (bytes4) {
        return OloBook.manageBatchSubs.selector;
    }
}
