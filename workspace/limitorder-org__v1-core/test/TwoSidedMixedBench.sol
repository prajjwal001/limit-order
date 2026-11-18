// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloOps} from "./OloOps.sol";
import {TwoSidedBench} from "./TwoSidedBench.sol";

/// The mixed slots' packing for GasBenchTwoSidedMixed and GasBenchTwoSidedMixedGroup.
abstract contract TwoSidedMixedBench is TwoSidedBench {
    /// Four a slot, the bids then the asks, each order on its own side: `batchW`'s isBid the slot's first order's side,
    /// `withFlips` turning the orders on the other one.
    function _mixed(uint8 kind, uint256 nb, uint256 na, uint256 shift) internal pure returns (uint256[3][] memory ws) {
        uint256 n = nb + na;
        ws = new uint256[3][]((n + 3) / 4);
        for (uint256 s; s < ws.length; ++s) {
            uint256[4] memory o;
            uint8 flips;
            bool slotBid = 4 * s < nb;
            for (uint256 i; i < 4 && 4 * s + i < n; ++i) {
                uint256 j = 4 * s + i;
                bool isBid = j < nb;
                o[i] = OloOps.sub(_tickOf(isBid, isBid ? j : j - nb, shift), AMT);
                if (isBid != slotBid) flips |= uint8(1 << i);
            }
            ws[s] = OloOps.withFlips(OloOps.batchW(kind, slotBid, uint16(s), 0, 0, o), flips);
        }
    }

    /// A mixed slot, one bid (index 0) and three asks (1-3): the asks taken whole naming them, then naming all four
    /// (the bid skipped), and the bid sold into.
    function _postMixed(address z, uint16 slot) internal {
        uint256[4] memory o;
        o[0] = OloOps.sub(T - 1, AMT);
        o[1] = OloOps.sub(T + 1, AMT);
        o[2] = OloOps.sub(T + 2, AMT);
        o[3] = OloOps.sub(T + 3, AMT);
        vm.prank(z);
        _mb(c, OloOps.withFlips(OloOps.batchW(OloOps.POST, true, slot, 0, 0, o), 14));
    }
}
