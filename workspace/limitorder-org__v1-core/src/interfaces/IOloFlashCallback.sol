// SPDX-License-Identifier: MIT
// Copyright (c) 2026 YOU LI.
pragma solidity ^0.8.8;

/// @title What the caller of a flash answers
/// @notice `IOloBookExt.flash` credits the caller's account in the OLO EVM contract, calls this function on the caller,
/// and debits the account by as much once it returns: unless the account holds the amount again by then, the flash
/// reverts whole, the callback's work with it. The OLO EVM contract is unlocked for the callback, so the callback may
/// call any of its entries (a take, a place, a withdrawal, a deposit, another flash), each settling on the caller's
/// accounts as it would outside a flash. A token transferred to the OLO EVM contract directly repays nothing: only the
/// account is debited. The OLO EVM contract calls it back only on the address that called `flash`: nobody can start a
/// flash that calls another contract back, so a callback checks only that msg.sender is the OLO EVM contract it trusts.
interface IOloFlashCallback {
    /// @notice Called by the OLO EVM contract inside `flash`, after the credit
    /// @param token The token credited
    /// @param amount The amount credited to the caller's account, debited back once this returns
    /// @param data The bytes the caller passed to `flash`, as given
    function oloFlashCallback(address token, uint256 amount, bytes calldata data) external;
}
