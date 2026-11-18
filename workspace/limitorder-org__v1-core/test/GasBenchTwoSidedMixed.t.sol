// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloOps} from "./OloOps.sol";
import {TwoSidedMixedBench} from "./TwoSidedMixedBench.sol";

/// Both sides in a slot (a side bit a sub-order): the orders packed four a slot, bids first, one manageBatchSubs call a
/// slot, each its own transaction (run with --isolate).
contract GasBenchTwoSidedMixed is TwoSidedMixedBench {
    function test_requote_mixed() public {
        uint256[2][6] memory s = _scenarios();
        for (uint256 k; k < s.length; ++k) {
            (uint256 nb, uint256 na) = (s[k][0], s[k][1]);
            address z = _maker();
            _perSlotCalls(z, _mixed(OloOps.POST, nb, na, 0));
            uint256[3][] memory ws = _mixed(OloOps.REPLACE, nb, na, 1);
            _log(_name("mixed", nb, na), _perSlotCalls(z, ws));
            _log(_name("mixed_n", nb, na), ws.length);
        }
    }

    function test_take_mixed() public {
        address z = _maker();
        _postMixed(z, 0);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 0, 14, T + 5)),
            OloOps.tagW(c, OloOps.takeW(true, 3 * AMT, 0))
        );
        _log("ts_take_3asks_mixed", _receipt());
        _postMixed(z, 1);
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroup(z, 1, 15, [T - 5, T + 5, T + 5, T + 5])),
            OloOps.tagW(c, OloOps.takeW(true, 3 * AMT, 0))
        );
        _log("ts_take_3asks_mixed_named4", _receipt());
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 0, 1, T - 5)),
            OloOps.tagW(c, OloOps.takeW(false, AMT, 0))
        );
        _log("ts_take_1bid_mixed", _receipt());
    }
}
