// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";

/// The OLO EVM contract reserves no memory for stack values. A function whose values do not fit via-IR's sixteen
/// reachable stack slots has some moved to memory, which the compiler then reserves from 0x80 for the whole contract:
/// every entry's free memory pointer starts past it, so one function's spills cost every call of the contract about 3
/// gas a word. The take loops, inlined into one frame, once reserved 11 words (about 34 gas a call); they are kept out
/// of line since (OloBookTakes._fillSegments). A change that brings a spill back fails here and says what it costs.
contract OloNoSpillTest is OloBase {
    function test_book_reserves_no_memory_for_stack_values() public view {
        if (!vm.exists(BOOK)) return; // the shipped (hirun) build only
        _requireFresh(BOOK);
        bytes memory code = vm.getDeployedCode(BOOK);
        // the runtime code opens with mstore(0x40, 0x80): PUSH1 0x80 PUSH1 0x40 MSTORE; a reserve makes it PUSH2 or a
        // larger PUSH1
        assertEq(bytes32(bytes5(code)), bytes32(bytes5(0x6080604052)), "the free memory pointer starts at 0x80");
    }
}
