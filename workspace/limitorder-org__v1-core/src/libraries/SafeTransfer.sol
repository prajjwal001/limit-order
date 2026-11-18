// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

/// @notice ERC-20 transfers that accept tokens returning nothing (USDT style) and refuse addresses without code, and
/// the native currency's.
library SafeTransfer {
    error TransferFailed();

    function transfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        _check(token, ok, ret);
    }

    function transferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20Minimal.transferFrom, (from, to, amount)));
        _check(token, ok, ret);
    }

    /// @notice Sends `amount` wei of the native currency to `to`, and reverts if `to` refuses it.
    function transferNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _check(address token, bool ok, bytes memory ret) private view {
        if (!ok || (ret.length == 0 ? token.code.length == 0 : !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
