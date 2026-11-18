// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

/// An unsigned 512-bit integer, hi x 2^256 + lo, for the tests' exact references: a take's quote over every decade of
/// the grid (amount x mantissa x 10^d reaches 2^114 x 2^20 x 2^243) does not fit 256 bits, and a reference that
/// rounded would not be one. Plain Solidity, no assembly; slow, which a test can afford.
struct U512 {
    uint256 hi;
    uint256 lo;
}

library Wide {
    function from(uint256 x) internal pure returns (U512 memory) {
        return U512(0, x);
    }

    /// The full product of two words: the low word wraps, and the high word is what the wrap dropped, from the
    /// product modulo 2^256 - 1 (mm = hi + lo mod 2^256 - 1).
    function mul(uint256 a, uint256 b) internal pure returns (U512 memory r) {
        unchecked {
            uint256 mm = mulmod(a, b, type(uint256).max);
            r.lo = a * b;
            r.hi = mm - r.lo - (mm < r.lo ? 1 : 0);
        }
    }

    /// a x b, reverting past 2^512.
    function mul(U512 memory a, uint256 b) internal pure returns (U512 memory r) {
        r = mul(a.lo, b);
        uint256 top = a.hi * b; // checked: the product must fit 512 bits
        r.hi += top; // checked
    }

    /// a + b, reverting past 2^512.
    function add(U512 memory a, U512 memory b) internal pure returns (U512 memory r) {
        unchecked {
            r.lo = a.lo + b.lo;
        }
        r.hi = a.hi + b.hi + (r.lo < a.lo ? 1 : 0); // checked
    }

    function add(U512 memory a, uint256 b) internal pure returns (U512 memory) {
        return add(a, from(b));
    }

    /// a - b, which must not be negative.
    function sub(U512 memory a, U512 memory b) internal pure returns (U512 memory r) {
        require(!lt(a, b), "Wide: sub underflow");
        unchecked {
            r.lo = a.lo - b.lo;
            r.hi = a.hi - b.hi - (a.lo < b.lo ? 1 : 0);
        }
    }

    function lt(U512 memory a, U512 memory b) internal pure returns (bool) {
        return a.hi < b.hi || (a.hi == b.hi && a.lo < b.lo);
    }

    function le(U512 memory a, U512 memory b) internal pure returns (bool) {
        return !lt(b, a);
    }

    function eq(U512 memory a, U512 memory b) internal pure returns (bool) {
        return a.hi == b.hi && a.lo == b.lo;
    }

    function isZero(U512 memory a) internal pure returns (bool) {
        return a.hi == 0 && a.lo == 0;
    }

    /// floor(a / d) and a mod d, for a divisor below 2^255 (the remainder doubles below 2^256): bit by bit, from the top.
    function divRem(U512 memory a, uint256 d) internal pure returns (U512 memory q, uint256 r) {
        require(d != 0 && d < 1 << 255, "Wide: divisor");
        for (uint256 i = 512; i > 0; --i) {
            uint256 bitIndex = i - 1;
            uint256 bit = bitIndex >= 256 ? (a.hi >> (bitIndex - 256)) & 1 : (a.lo >> bitIndex) & 1;
            r = (r << 1) | bit;
            if (r >= d) {
                r -= d;
                if (bitIndex >= 256) q.hi |= 1 << (bitIndex - 256);
                else q.lo |= 1 << bitIndex;
            }
        }
    }

    function divDown(U512 memory a, uint256 d) internal pure returns (U512 memory q) {
        (q,) = divRem(a, d);
    }

    function divUp(U512 memory a, uint256 d) internal pure returns (U512 memory q) {
        uint256 r;
        (q, r) = divRem(a, d);
        if (r != 0) q = add(q, 1);
    }

    /// The value as one word; it must fit.
    function toUint(U512 memory a) internal pure returns (uint256) {
        require(a.hi == 0, "Wide: past 2^256");
        return a.lo;
    }

    /// 10^e as a 512-bit integer (e up to 154).
    function pow10(uint256 e) internal pure returns (U512 memory r) {
        r = from(1);
        while (e >= 70) {
            r = mul(r, 10 ** 70);
            e -= 70;
        }
        r = mul(r, 10 ** e);
    }
}
