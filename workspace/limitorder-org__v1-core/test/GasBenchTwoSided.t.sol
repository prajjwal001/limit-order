// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloOps} from "./OloOps.sol";
import {TwoSidedBench} from "./TwoSidedBench.sol";
import {BatchExecutor} from "./GasBench7702.t.sol";

/// Today's way: one side a slot, one manageBatchSubs call a slot, each call its own transaction from an EOA
/// (run with --isolate). `_calls_n` is the number of transactions.
contract GasBenchTwoSided is TwoSidedBench {
    function test_requote_calls() public {
        uint256[2][6] memory s = _scenarios();
        for (uint256 k; k < s.length; ++k) {
            (uint256 nb, uint256 na) = (s[k][0], s[k][1]);
            address z = _maker();
            _perSlotCalls(z, _oneSided(OloOps.POST, nb, na, 0));
            uint256[3][] memory ws = _oneSided(OloOps.REPLACE, nb, na, 1);
            _log(_name("calls", nb, na), _perSlotCalls(z, ws));
            _log(_name("calls_n", nb, na), ws.length);
        }
    }

    /// A slot of three asks taken whole, and a slot of one bid sold into: the one-sided rows the mixed slot's are
    /// read against.
    function test_take_one_sided() public {
        address z = _maker();
        uint256[4] memory o;
        o[0] = OloOps.sub(T + 1, AMT);
        o[1] = OloOps.sub(T + 2, AMT);
        o[2] = OloOps.sub(T + 3, AMT);
        vm.prank(z);
        _mb(c, OloOps.batchW(OloOps.POST, false, 0, 0, 0, o));
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 0, 7, T + 5)),
            OloOps.tagW(c, OloOps.takeW(true, 3 * AMT, 0))
        );
        _log("ts_take_3asks_onesided", _receipt());
        uint256[4] memory b;
        b[0] = OloOps.sub(T - 1, AMT);
        vm.prank(z);
        _mb(c, OloOps.batchW(OloOps.POST, true, 1, 0, 0, b));
        vm.prank(taker);
        book.take(
            OloOps.key(c),
            OloOps.batchList(OloOps.slotGroupAt(z, 1, 1, T - 5)),
            OloOps.tagW(c, OloOps.takeW(false, AMT, 0))
        );
        _log("ts_take_1bid_onesided", _receipt());
    }
}

/// Today's way through an EIP-7702 account: one transaction sending a manageBatchSubs call a slot (run with --isolate
/// --evm-version prague and EIP7702=true, as GasBench7702).
contract GasBenchTwoSided7702 is TwoSidedBench {
    BatchExecutor exec;

    function setUp() public override {
        vm.skip(!vm.envOr("EIP7702", false));
        super.setUp();
        exec = new BatchExecutor();
    }

    function test_requote_calls_7702() public {
        uint256[2][6] memory s = _scenarios();
        for (uint256 k; k < s.length; ++k) {
            (uint256 nb, uint256 na) = (s[k][0], s[k][1]);
            address z = _maker();
            vm.etch(z, abi.encodePacked(hex"ef0100", address(exec)));
            _perSlotCalls(z, _oneSided(OloOps.POST, nb, na, 0));
            uint256[3][] memory ws = _oneSided(OloOps.REPLACE, nb, na, 1);
            BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](ws.length);
            for (uint256 i; i < ws.length; ++i) {
                calls[i] = BatchExecutor.Call(address(book), 0, OloOps.batchCalldata(_bookSel(), c, ws[i]));
            }
            vm.prank(z, z);
            (bool ok,) = z.call(abi.encodeCall(BatchExecutor.execute, (calls)));
            require(ok, "7702 batch");
            _log(_name("calls7702", nb, na), _receipt());
        }
    }
}
