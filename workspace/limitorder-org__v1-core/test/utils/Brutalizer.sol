// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

/// Runs a function under what inline assembly must not care about: junk in the scratch space and in the free memory,
/// the free memory pointer off a word boundary, arguments with dirty high bits. `_arm` sets that up and notes the
/// frame; `_checkMemory` after the call holds the free memory pointer sane and not moved back, the zero slot zero, and
/// a canary word just below the free memory intact. After the idea of Solady's test Brutalizer (MIT); written for
/// this repository, no Solady code copied.
abstract contract Brutalizer {
    error FreeMemoryPointerOverflow(uint256 fmp);
    error FreeMemoryPointerMovedBack(uint256 armedAt, uint256 found);
    error ZeroSlotDirty(uint256 word);
    error CanaryOverwritten(uint256 word);

    /// What `_arm` noted, for `_checkMemory`.
    struct Armed {
        uint256 fmp; // the free memory pointer once armed: the callee's allocations start there
        uint256 canary; // the word just below it, holding CANARY
    }

    uint256 internal constant CANARY = 0xc0ffee5ca1ab1ec0ffee5ca1ab1ec0ffee5ca1ab1ec0ffee5ca1ab1ec0ffee5c;

    /// A canary, junk from the free memory pointer on and in the scratch space, the free memory pointer moved up by
    /// `seed` mod 32 bytes (0: left on its word boundary).
    function _arm(uint256 seed) internal pure returns (Armed memory armed) {
        armed.canary = _canary();
        _brutalizeMemory(seed);
        _misalignFreeMemoryPointer(seed);
        armed.fmp = _freeMemoryPointer();
    }

    /// Holds what `_arm` set up: the free memory pointer at most 0xffffffff and not below where it was, the zero slot
    /// 0x60 zero, the canary intact.
    function _checkMemory(Armed memory armed) internal pure {
        uint256 fmp = _freeMemoryPointer();
        if (fmp > 0xffffffff) revert FreeMemoryPointerOverflow(fmp);
        if (fmp < armed.fmp) revert FreeMemoryPointerMovedBack(armed.fmp, fmp);
        uint256 zero;
        uint256 canary;
        uint256 canaryAt = armed.canary;
        assembly ("memory-safe") {
            zero := mload(0x60)
            canary := mload(canaryAt)
        }
        if (zero != 0) revert ZeroSlotDirty(zero);
        if (canary != CANARY) revert CanaryOverwritten(canary);
    }

    function _freeMemoryPointer() internal pure returns (uint256 fmp) {
        assembly ("memory-safe") {
            fmp := mload(0x40)
        }
    }

    /// One word allocated at the free memory pointer with CANARY in it: a callee that writes below what it
    /// allocated overwrites it.
    function _canary() internal pure returns (uint256 slot) {
        assembly ("memory-safe") {
            slot := mload(0x40)
            mstore(slot, CANARY)
            mstore(0x40, add(slot, 0x20))
        }
    }

    /// Junk from `seed` over the scratch space 0x00 .. 0x3f and the 2 KB from the free memory pointer on (temporary
    /// use of the free memory, nothing allocated): no word a function may expect to read zero.
    function _brutalizeMemory(uint256 seed) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(0x00, xor(seed, 0x9e3779b97f4a7c15f39cc0605cedc8341082276bf3a27251f86c6a11d0c18e95))
            mstore(0x20, keccak256(0x00, 0x20))
            for { let i := 0 } lt(i, 0x800) { i := add(i, 0x20) } {
                let x := keccak256(0x00, 0x40)
                mstore(0x20, x)
                mstore(add(fmp, i), x)
            }
        }
    }

    /// The free memory pointer moved up by `seed` mod 32: off its word boundary unless that is 0.
    function _misalignFreeMemoryPointer(uint256 seed) internal pure {
        assembly ("memory-safe") {
            mstore(0x40, add(mload(0x40), and(seed, 0x1f)))
        }
    }

    // ---------------------------------------------------------------- dirty values
    // Each returns its argument with the bits above its width set from `seed`, assigned in assembly so the compiler
    // inserts no cleaning: the callee's assembly sees them.

    function _dirtyAddress(address a, uint256 seed) internal pure returns (address r) {
        assembly ("memory-safe") {
            r := or(and(a, 0xffffffffffffffffffffffffffffffffffffffff), shl(160, seed))
        }
    }

    /// A true bool as any nonzero word (bit 0 from the seed), a false one as 0.
    function _dirtyBool(bool b, uint256 seed) internal pure returns (bool r) {
        assembly ("memory-safe") {
            r := mul(iszero(iszero(b)), or(shl(1, seed), or(and(seed, 1), shl(200, 1))))
        }
    }

    /// A tick's 24 bits kept (not sign-extended), the bits above from the seed.
    function _dirtyTick(int24 t, uint256 seed) internal pure returns (int24 r) {
        assembly ("memory-safe") {
            r := or(and(t, 0xffffff), shl(24, seed))
        }
    }

    function _dirtyUint8(uint8 x, uint256 seed) internal pure returns (uint8 r) {
        assembly ("memory-safe") {
            r := or(and(x, 0xff), shl(8, seed))
        }
    }

    function _dirtyUint16(uint16 x, uint256 seed) internal pure returns (uint16 r) {
        assembly ("memory-safe") {
            r := or(and(x, 0xffff), shl(16, seed))
        }
    }

    function _dirtyUint32(uint32 x, uint256 seed) internal pure returns (uint32 r) {
        assembly ("memory-safe") {
            r := or(and(x, 0xffffffff), shl(32, seed))
        }
    }

    function _dirtyUint48(uint48 x, uint256 seed) internal pure returns (uint48 r) {
        assembly ("memory-safe") {
            r := or(and(x, 0xffffffffffff), shl(48, seed))
        }
    }

    function _dirtyUint64(uint64 x, uint256 seed) internal pure returns (uint64 r) {
        assembly ("memory-safe") {
            r := or(and(x, 0xffffffffffffffff), shl(64, seed))
        }
    }
}
