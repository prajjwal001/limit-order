// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {IOloBookExt} from "../src/interfaces/IOloBookExt.sol";
import {IOloSentinel} from "./IOloSentinel.sol";
import {IOwned2Step} from "../src/interfaces/IOwned2Step.sol";

/// @title OloSentinel: an OloBook's owner, every owner call behind a delay
/// @notice See IOloSentinel. The OLO EVM contract is unchanged: the sentinel is its owner, so the OLO EVM contract's
/// owner calls are the sentinel's ops. The admin is meant to be a multisig, the guardian another one, of other signers.
contract OloSentinel is IOloSentinel {
    /// @inheritdoc IOloSentinel
    uint256 public constant override MIN_DELAY = 1 days;
    /// @inheritdoc IOloSentinel
    uint256 public constant override MAX_DELAY = 30 days;
    /// @inheritdoc IOloSentinel
    uint256 public constant override GRACE = 7 days;

    /// @inheritdoc IOloSentinel
    address public immutable override book;
    /// @inheritdoc IOloSentinel
    address public override admin;
    /// @inheritdoc IOloSentinel
    address public override pendingAdmin;
    /// @inheritdoc IOloSentinel
    address public override guardian;
    /// @inheritdoc IOloSentinel
    uint256 public override delay;

    /// An op scheduled: the hash of its calldata, its eta (0: none) and when it was scheduled.
    struct Op {
        bytes32 opHash;
        uint64 eta;
        uint64 scheduledAt;
    }

    /// When the sentinel's last stretch of ownership began: when it last took the OLO EVM contract over from another
    /// owner (its own proposal of itself accepted begins none). An op scheduled before it is stale: it neither runs nor
    /// holds its key, so an op runs only in the stretch of ownership it was scheduled in (`_live`).
    uint64 internal _ownedSince;

    /// Each key's op, the last scheduled; deleted when it runs or is cancelled, overwritten once it has expired.
    mapping(bytes32 key => Op) internal _ops;

    /// @param book_ The OLO EVM contract; the sentinel owns it once its owner proposes it and `acceptBookOwnership`
    /// runs
    /// @param admin_ The admin, not zero
    /// @param guardian_ The guardian, zero for none
    /// @param delay_ The delay, MIN_DELAY to MAX_DELAY
    constructor(address book_, address admin_, address guardian_, uint256 delay_) {
        if (book_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (delay_ < MIN_DELAY || delay_ > MAX_DELAY) revert BadDelay();
        book = book_;
        admin = admin_;
        guardian = guardian_;
        delay = delay_;
        emit AdminSet(admin_);
        emit GuardianSet(guardian_);
        emit DelaySet(delay_);
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    // ---------------------------------------------------------------------- ops

    /// @inheritdoc IOloSentinel
    function schedule(bytes[] calldata ops) external returns (uint256 eta) {
        if (msg.sender != admin) revert NotAdmin();
        // the owner alone schedules, and an op runs only in the stretch of ownership it was scheduled in (`_live`): a
        // successor holds no op for the handover's transaction, nor a sentinel one from an earlier stretch, so a chain
        // of sentinels moves a setting no faster than the one owning it
        if (IOwned2Step(book).owner() != address(this)) revert NotBookOwner();
        eta = block.timestamp + delay;
        for (uint256 i; i < ops.length; ++i) {
            // keyOf is the allowlist and the strict decoding: an op not one of the thirteen, or not exactly encoded,
            // reverts here and is never scheduled
            bytes32 key = keyOf(ops[i]);
            Op storage op = _ops[key];
            if (_live(op)) revert KeyPending(key);
            op.opHash = keccak256(ops[i]);
            op.eta = uint64(eta);
            op.scheduledAt = uint64(block.timestamp);
            emit Scheduled(key, eta, ops[i]);
        }
    }

    /// @inheritdoc IOloSentinel
    function execute(bytes[] calldata ops) external {
        if (msg.sender != admin) revert NotAdmin();
        for (uint256 i; i < ops.length; ++i) {
            bytes calldata data = ops[i];
            bytes32 key = keyOf(data);
            Op storage op = _ops[key];
            uint256 eta = op.eta;
            // none, another op, or one scheduled before the sentinel's last stretch of ownership began
            if (eta == 0 || op.opHash != keccak256(data) || op.scheduledAt < _ownedSince) revert NotScheduled(key);
            if (block.timestamp < eta) revert NotReady(key, eta);
            if (block.timestamp > eta + GRACE) revert Expired(key, eta);
            delete _ops[key];
            // the sentinel's own settings to itself, every other op to the OLO EVM contract: keyOf, run above on this
            // very op, lets only the OLO EVM contract's ten owner ops by, so nothing else reaches the OLO EVM contract
            // through here
            address target = _isOwn(bytes4(data)) ? address(this) : book;
            (bool ok, bytes memory ret) = target.call(data);
            if (!ok) {
                // the target's revert, as it gave it
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            emit Executed(key, data);
        }
    }

    /// @inheritdoc IOloSentinel
    function cancel(bytes32[] calldata keys) external {
        bool byAdmin = msg.sender == admin;
        // the guardian, when there is one
        if (!byAdmin && (msg.sender != guardian || msg.sender == address(0))) revert NotCanceller();
        for (uint256 i; i < keys.length; ++i) {
            bytes32 key = keys[i];
            // a guardian change is the admin's to cancel alone: the guardian cannot hold its own replacement off
            if (!byAdmin && key == _globalKey(IOloSentinel.setGuardian.selector)) revert NotCanceller();
            if (!_live(_ops[key])) revert NotScheduled(key);
            delete _ops[key];
            emit Cancelled(key, msg.sender);
        }
    }

    /// @inheritdoc IOloSentinel
    function acceptBookOwnership() external {
        // the owner already: its own proposal of itself accepted, it held the OLO EVM contract throughout
        bool held = IOwned2Step(book).owner() == address(this);
        IOwned2Step(book).acceptOwnership();
        // taken over from another owner: a new stretch of ownership, every op scheduled before it stale
        if (!held) _ownedSince = uint64(block.timestamp);
    }

    /// @inheritdoc IOloSentinel
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminSet(msg.sender);
    }

    // --------------------------------------------------------- own settings, ops

    /// @inheritdoc IOloSentinel
    function setDelay(uint256 newDelay) external onlySelf {
        if (newDelay < MIN_DELAY || newDelay > MAX_DELAY) revert BadDelay();
        delay = newDelay;
        emit DelaySet(newDelay);
    }

    /// @inheritdoc IOloSentinel
    function setGuardian(address newGuardian) external onlySelf {
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    /// @inheritdoc IOloSentinel
    function transferAdmin(address newAdmin) external onlySelf {
        pendingAdmin = newAdmin;
        emit AdminProposed(newAdmin);
    }

    // -------------------------------------------------------------------- views

    /// @inheritdoc IOloSentinel
    function keyOf(bytes calldata op) public pure returns (bytes32 key) {
        if (op.length < 4) revert UnknownOp(bytes4(0));
        bytes4 sel = bytes4(op);
        bytes calldata args = op[4:];
        // each op's arguments, word by word: a market's id any uint256 (the OLO EVM contract refuses one not listed),
        // an address 160 bits, a bool 1 bit, every other value its type's bits
        if (sel == IOloBookExt.setMarketFee.selector) {
            _requireArgs(args, 3);
            _requireBits(args, 1, 24);
            _requireBits(args, 2, 64);
            return keccak256(abi.encode(sel, _arg(args, 0)));
        }
        if (sel == IOloBookExt.setMarketMakerShare.selector) {
            _requireArgs(args, 2);
            _requireBits(args, 1, 48);
            return keccak256(abi.encode(sel, _arg(args, 0)));
        }
        if (sel == IOloBookExt.setPairFeeFloor.selector || sel == IOloBookExt.setPairMakerShare.selector) {
            _requireArgs(args, 4);
            _requireBits(args, 0, 160);
            _requireBits(args, 1, 160);
            _requireBits(args, 2, sel == IOloBookExt.setPairFeeFloor.selector ? 32 : 40);
            _requireBits(args, 3, 1);
            return _pairKey(sel, address(uint160(_arg(args, 0))), address(uint160(_arg(args, 1))));
        }
        // a lister's right to list proprietary markets: one key a lister, an allow and a stop alike
        if (sel == IOloBookExt.setProprietaryListingAllowed.selector) {
            _requireArgs(args, 2);
            _requireBits(args, 0, 160);
            _requireBits(args, 1, 1);
            return keccak256(abi.encode(sel, address(uint160(_arg(args, 0)))));
        }
        // the global settings: one argument, no object
        uint256 bits;
        if (sel == IOloBookExt.setGlobalFeeFloor.selector) {
            bits = 32;
        } else if (sel == IOloBookExt.setGlobalMakerShare.selector) {
            bits = 24;
        } else if (sel == IOloBookExt.setCurrentListingFee.selector) {
            bits = 80;
        } else if (
            sel == IOloBookExt.setFeeRecipient.selector || sel == IOwned2Step.transferOwnership.selector
                || sel == IOloSentinel.setGuardian.selector || sel == IOloSentinel.transferAdmin.selector
        ) {
            bits = 160;
        } else if (sel == IOloSentinel.setDelay.selector) {
            bits = 256;
        } else {
            revert UnknownOp(sel);
        }
        _requireArgs(args, 1);
        if (bits < 256) _requireBits(args, 0, bits);
        return _globalKey(sel);
    }

    /// @inheritdoc IOloSentinel
    function pending(bytes32 key) external view returns (bytes32 opHash, uint64 eta) {
        Op storage op = _ops[key];
        if (op.scheduledAt < _ownedSince) return (0, 0); // stale
        return (op.opHash, op.eta);
    }

    // ----------------------------------------------------------------- internal

    /// Whether `op` is scheduled, has not expired and is not stale (scheduled before the sentinel's last stretch of
    /// ownership began): its key is taken.
    function _live(Op storage op) internal view returns (bool) {
        uint256 eta = op.eta;
        return eta != 0 && block.timestamp <= eta + GRACE && op.scheduledAt >= _ownedSince;
    }

    /// Whether `sel` is one of the sentinel's own settings, which an op runs on the sentinel.
    function _isOwn(bytes4 sel) internal pure returns (bool) {
        return sel == IOloSentinel.setDelay.selector || sel == IOloSentinel.setGuardian.selector
            || sel == IOloSentinel.transferAdmin.selector;
    }

    /// Reverts MalformedOp unless `args` is exactly `n` words: one value of one setting has one encoding.
    function _requireArgs(bytes calldata args, uint256 n) internal pure {
        if (args.length != n * 32) revert MalformedOp();
    }

    /// Reverts MalformedOp unless word `i` of `args` fits in `bits` bits, as the OLO EVM contract's decoder requires of
    /// its type.
    function _requireBits(bytes calldata args, uint256 i, uint256 bits) internal pure {
        if (_arg(args, i) >> bits != 0) revert MalformedOp();
    }

    /// Word `i` of `args`, which holds it.
    function _arg(bytes calldata args, uint256 i) internal pure returns (uint256) {
        return uint256(bytes32(args[i * 32:i * 32 + 32]));
    }

    /// The key of a global setting's op: its selector alone.
    function _globalKey(bytes4 sel) internal pure returns (bytes32) {
        return keccak256(abi.encode(sel));
    }

    /// The key of a pair setting's op: its selector and the pair's tokens in the OLO EVM contract's order, the lower
    /// address first, so either order names one key.
    function _pairKey(bytes4 sel, address tokenA, address tokenB) internal pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(sel, token0, token1));
    }
}
