// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

/// @notice The OLO EVM contract's arithmetic: powers of ten, and an order's units. Named, so a call site says what it
/// does.
library OloMath {
    /// @notice An order stores its amount as units x 10^q with units below 2^30 (UNITS_LIMIT).
    uint256 internal constant UNITS_LIMIT = 1 << 30;

    /// @notice 10^exponent; `exponent` at most 77 (10^77 < 2^256), so no overflow: one EXP, where checked `**` loops.
    function pow10(uint256 exponent) internal pure returns (uint256) {
        unchecked {
            // exponent <= 77: 10^77 < 2^256
            return 10 ** exponent;
        }
    }

    /// @notice An amount as an order stores it: the smallest q with amount / 10^q below 2^30, and the units
    /// floor(amount / 10^q). The order holds units x 10^q (rounded down to a multiple of 10^q) and escrows only that.
    /// Every amount an order or a take is given is below 2^112, so q is at most 25 (2^112 / 10^25 < 2^30). An amount
    /// below 2^30 is itself (q 0, exact to the wei); a larger one keeps 9 or 10 significant figures (units from 2^30 /
    /// 10, rounded down 107,374,182, to 2^30 - 1).
    /// @dev floor(floor(a / 10^i) / 10^j) = floor(a / 10^(i + j)), so the divisions go in steps: by 10^4 while the
    /// units are at least 2^30 x 10^4 (then q must grow by at least 4: floor(units / 10^3) is still at least 2^30),
    /// then by 10.
    function toUnits(uint256 amount) internal pure returns (uint256 q, uint256 units) {
        units = amount;
        if (units < UNITS_LIMIT) return (0, units);
        unchecked {
            // divisions only, and q at most 25 (amounts below 2^112)
            while (units >= UNITS_LIMIT * 1e4) {
                units /= 1e4;
                q += 4;
            }
            while (units >= UNITS_LIMIT) {
                units /= 10;
                ++q;
            }
        }
    }

    /// @notice x / d rounded up, without the overflow of x + d - 1; `d` not zero.
    function divUp(uint256 x, uint256 d) internal pure returns (uint256) {
        unchecked {
            // out = x / d <= x, and out + 1 only when x % d != 0, so out < x
            uint256 out = x / d;
            return x % d == 0 ? out : out + 1;
        }
    }
}
