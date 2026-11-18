// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {BatchLib} from "../src/OloTypes.sol";

/// Reads a batch slot's two words as the OLO EVM contract writes them (BatchLib's comment has the layout).
library BatchView {
    /// The sub-orders' sides as a mask, bit i set for a bid (an empty sub-order's bit is 0).
    function bidMask(uint256 word) internal pure returns (uint256) {
        return BatchLib.bidMask(word);
    }

    /// Sub-order `i` rests on the bid side.
    function isBidAt(uint256 word, uint256 i) internal pure returns (bool) {
        return (BatchLib.bidMask(word) >> i) & 1 == 1;
    }

    /// Sub-order `i`: its tick, q and open units (all zero: empty).
    function subOf(uint256 word, uint256 i) internal pure returns (uint256 tick, uint256 q, uint256 open) {
        uint256 s = BatchLib.subAt(word, i);
        return (BatchLib.tickOf(s), BatchLib.qOf(s), BatchLib.openOf(s));
    }

    function tickOf(uint256 word, uint256 i) internal pure returns (uint256) {
        return BatchLib.tickOf(BatchLib.subAt(word, i));
    }

    /// Sub-order `i`'s open amount in base wei.
    function openOf(uint256 word, uint256 i) internal pure returns (uint256) {
        uint256 s = BatchLib.subAt(word, i);
        return BatchLib.openOf(s) * 10 ** BatchLib.qOf(s);
    }

    /// Sub-order `i`'s filled and unclaimed amount in base wei: (base - open) x 10^q, nothing for an empty one (its
    /// base is left over and counts for nothing).
    function filledOf(uint256 word, uint256 set, uint256 i) internal pure returns (uint256) {
        uint256 s = BatchLib.subAt(word, i);
        if (s == 0) return 0;
        return (BatchLib.baseAt(set, i) - BatchLib.openOf(s)) * 10 ** BatchLib.qOf(s);
    }

    function baseOf(uint256 set, uint256 i) internal pure returns (uint256) {
        return BatchLib.baseAt(set, i);
    }
}
