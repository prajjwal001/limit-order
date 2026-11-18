// SPDX-License-Identifier: MIT
// Copyright (c) 2026 YOU LI.
pragma solidity ^0.8.8;

/// @title Two-step ownership: the proposed owner must accept
interface IOwned2Step {
    /// @notice Emitted when an owner is proposed, or a proposal withdrawn (address(0))
    /// @param pending The proposed owner
    event OwnerProposed(address indexed pending);

    /// @notice Emitted when the proposed owner accepts
    /// @param owner The new owner
    event OwnerSet(address indexed owner);

    /// @notice Thrown when the caller is not the owner
    error NotOwner();

    /// @notice Thrown when the caller is not the proposed owner
    error NotPendingOwner();

    /// @notice The owner
    function owner() external view returns (address);

    /// @notice The proposed owner, until it accepts (address(0) if none)
    function pendingOwner() external view returns (address);

    /// @notice Owner only. Proposes a new owner; address(0) withdraws a pending proposal.
    /// @param newOwner The proposed owner
    function transferOwnership(address newOwner) external;

    /// @notice The proposed owner takes over
    function acceptOwnership() external;
}
