// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

import {IOwned2Step} from "../interfaces/IOwned2Step.sol";

/// @notice Owner storage and the two-step transfer. The OLO EVM contract and its extension both inherit it (the
/// extension runs `onlyOwner` entries in the OLO EVM contract's storage); the extension's own copies of the two entries
/// are never reached, as the OLO EVM contract does not forward them.
abstract contract Owned2Step is IOwned2Step {
    /// @inheritdoc IOwned2Step
    address public owner;
    /// @inheritdoc IOwned2Step
    address public pendingOwner;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @inheritdoc IOwned2Step
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnerProposed(newOwner);
    }

    /// @inheritdoc IOwned2Step
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnerSet(msg.sender);
    }
}
