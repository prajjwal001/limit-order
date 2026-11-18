// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";
import {BatchLib, OloSlots, TAG_BATCH, TAG_ORDER, TAG_LISTING} from "../src/OloTypes.sol";

/// OloSlots' three slot hashes, written in assembly over the scratch space, held to the same preimages spelled out
/// with `abi.encodePacked` (a changed preimage would move every order, slot and share word, and nothing else would
/// notice).
contract OloSlotsHashTest is Test {
    /// keccak256(C | pos u32 | 0x01), 37 bytes.
    function _orderSlotPacked(MarketWord c, uint256 pos) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(MarketWord.unwrap(c), uint32(pos), uint8(TAG_ORDER))));
    }

    /// keccak256(C | maker 20 | slot u16 | 0x02), 55 bytes.
    function _batchSlotPacked(MarketWord c, address maker, uint256 slot) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(MarketWord.unwrap(c), maker, uint16(slot), uint8(TAG_BATCH))));
    }

    /// keccak256(the word's bytes 4-31 | 0x04), 29 bytes: the listing's parameters without an id.
    function _listingSlotPacked(MarketWord c) internal pure returns (uint256) {
        bytes28 params = bytes28(bytes32(MarketWord.unwrap(c) << 32));
        return uint256(keccak256(abi.encodePacked(params, uint8(TAG_LISTING))));
    }

    function testFuzz_orderSlot_preimage(uint256 c, uint256 pos) public pure {
        assertEq(OloSlots.orderSlot(MarketWord.wrap(c), pos), _orderSlotPacked(MarketWord.wrap(c), pos));
    }

    function testFuzz_batchSlot_preimage(uint256 c, address maker, uint256 slot) public pure {
        assertEq(OloSlots.batchSlot(MarketWord.wrap(c), maker, slot), _batchSlotPacked(MarketWord.wrap(c), maker, slot));
    }

    function testFuzz_listingSlot_preimage(uint256 c) public pure {
        assertEq(OloSlots.listingSlot(MarketWord.wrap(c)), _listingSlotPacked(MarketWord.wrap(c)));
    }

    /// Two words that differ only in their id share one listing slot; two that differ in a parameter do not.
    function testFuzz_listingSlot_ignores_the_id(uint256 c, uint32 otherId) public pure {
        uint256 other = (c & ((1 << 224) - 1)) | (uint256(otherId) << 224);
        assertEq(OloSlots.listingSlot(MarketWord.wrap(c)), OloSlots.listingSlot(MarketWord.wrap(other)));
        assertNotEq(OloSlots.listingSlot(MarketWord.wrap(c)), OloSlots.listingSlot(MarketWord.wrap(c ^ 1)));
    }
}

/// BatchLib.lowestSub's table: every nonzero 4-bit mask names its lowest set bit, and the walk `_slotWalk` runs
/// (m &= m - 1) visits exactly the named sub-orders, in index order.
contract BatchLibLowestSubTest is Test {
    function test_lowestSub_every_mask() public pure {
        for (uint256 m = 1; m < 16; ++m) {
            uint256 low;
            while ((m >> low) & 1 == 0) ++low;
            assertEq(BatchLib.lowestSub(m), low, "lowest set bit");
            uint256 seen;
            uint256 last;
            uint256 n;
            for (uint256 r = m; r != 0; r &= r - 1) {
                uint256 i = BatchLib.lowestSub(r);
                if (n != 0) assertGt(i, last, "index order");
                assertEq(seen & (1 << i), 0, "each once");
                seen |= 1 << i;
                last = i;
                ++n;
            }
            assertEq(seen, m, "exactly the named sub-orders");
        }
    }
}
