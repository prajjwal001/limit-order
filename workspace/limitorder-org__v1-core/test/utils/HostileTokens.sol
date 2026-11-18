// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {MockERC20} from "./MockERC20.sol";

/// Keeps 1% of every transferFrom (a fee-on-transfer token).
contract FeeToken is MockERC20 {
    constructor() MockERC20("Fee", "FEE", 6) {}

    function transferFrom(address f, address to, uint256 a) public override returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[to] += a - a / 100;
        totalSupply -= a / 100;
        return true;
    }
}

/// Delivers 1 wei more than every transferFrom asks (a positive rebase, a bonus on transfer).
contract BonusToken is MockERC20 {
    constructor() MockERC20("Bonus", "BON", 6) {}

    function transferFrom(address f, address to, uint256 a) public override returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[to] += a + 1;
        totalSupply += 1;
        return true;
    }
}

/// Re-enters a target with a stored call from inside transfer and transferFrom, and records the revert. A plain
/// ERC-20 otherwise (standalone, so MockERC20's bytecode and the gas bench stay as they are).
contract ReentrantToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 6;
    address public target;
    bytes public payload;
    bytes public lastRevert;
    uint256 public attempts;
    bool public lastOk;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function arm(address t, bytes calldata p) external {
        target = t;
        payload = p;
    }

    function _hook() internal {
        if (target == address(0)) return;
        address t = target;
        target = address(0); // once
        attempts++;
        (bool ok, bytes memory ret) = t.call(payload);
        lastOk = ok;
        lastRevert = ret;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _hook();
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        _hook();
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// Moves nothing and returns nothing (no revert, no false) on a transfer of more than the sender holds: the book must
/// not count on a token to stop a transfer it cannot make. A plain ERC-20 otherwise.
contract SilentToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 6;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (balanceOf[msg.sender] < a) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// Fails its transfers once switched to: 1 returns false and moves nothing, 2 reverts with no data. transferFrom
/// always works, so a balance can be deposited first. A plain ERC-20 otherwise.
contract FailingToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 6;
    uint8 public failure;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function fail(uint8 how) external {
        failure = how;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (failure == 1) return false;
        if (failure == 2) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}
