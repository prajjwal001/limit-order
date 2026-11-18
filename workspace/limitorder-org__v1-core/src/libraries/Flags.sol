// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

/// @notice Settlement bits of `place`, `cancel`, `claim`, `modify`, `manageBatchSubs` and `multicall`. With no bit set
/// every flow stays in the caller's accounts in the OLO EVM contract.
library SettleFlags {
    /// @notice Every flow moves through the caller's wallet: escrow is pulled from it, refunds and proceeds are pushed
    /// to it.
    uint8 internal constant WALLET = 0x02;
    /// @notice Escrow is funded from the caller's account first and the shortfall is pulled from the wallet; refunds
    /// and proceeds still go to the account unless WALLET is set too.
    uint8 internal constant AUTO = 0x04;
    uint8 internal constant MASK = WALLET | AUTO;
}
