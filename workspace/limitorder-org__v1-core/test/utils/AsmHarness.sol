// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBook} from "../../src/OloBook.sol";
import {MarketWord} from "../../src/interfaces/MarketWord.sol";
import {OloSlots} from "../../src/OloTypes.sol";
import {Brutalizer} from "./Brutalizer.sol";

/// The OLO EVM contract with its two memory-writing assembly leaves (`_put`, `_trim`) and the take that uses them
/// reachable from tests. Each `h_` wrapper runs the internal function after `_arm` when `brutal` is set, `_checkMemory`
/// after it, and returns what the function wrote. The harness lists nothing: the words, accounts and tokens a wrapper
/// needs are set by hand (`setWord`, `setAccount`, `setToken`).
contract AsmHarness is OloBook, Brutalizer {
    /// `ext_` is any contract: the OLO EVM contract's constructor requires code there, and the harness never forwards
    /// to it.
    constructor(address ext_) OloBook(address(0xFEE), ext_, 0) {}

    // ------------------------------------------------------------------- state

    function setToken(uint256 id, address token) external {
        tokenAddr[id] = token;
        tokenId[token] = id;
        if (tokenCount < id) tokenCount = id;
    }

    function setAccount(uint256 key, address owner_, uint256 word) external {
        _accounts[OloSlots.ownedKey(key, owner_)] = word;
    }

    function accountOf(uint256 key, address owner_) external view returns (uint256) {
        return _accounts[OloSlots.ownedKey(key, owner_)];
    }

    function setWord(uint256 slot, uint256 word) external {
        OloSlots.store(slot, word);
    }

    function wordAt(uint256 slot) external view returns (uint256) {
        return OloSlots.load(slot);
    }

    // ------------------------------------------------------------ the calldata reader

    /// `_word` of `b` from byte `start`; `tail` is calldata after `b`'s, so a read past `b`'s end meets it.
    function h_word(bytes calldata b, uint256 start, bytes calldata tail) external pure returns (bytes32) {
        tail;
        return _word(b, start);
    }

    // ------------------------------------------------------------ the two byte writers

    /// `_put` of `word` at `offset` into a memory copy of `before`: the copy after.
    function h_put(bool brutal, uint256 seed, bytes calldata before, uint256 offset, bytes32 word)
        external
        pure
        returns (bytes memory b)
    {
        b = before;
        Armed memory armed;
        if (brutal) armed = _arm(seed);
        _put(b, offset, word);
        if (brutal) _checkMemory(armed);
    }

    /// `_trim` of a memory copy of `before` to `length`: the copy after, and a hash of the copy's whole original
    /// region (its length word and all its bytes as allocated) taken before and after, so a trim that touched
    /// anything but the length word shows.
    function h_trim(bool brutal, uint256 seed, bytes calldata before, uint256 length)
        external
        pure
        returns (bytes memory b, bytes32 regionBefore, bytes32 regionAfter)
    {
        b = before;
        uint256 size = b.length;
        regionBefore = _region(b, size);
        Armed memory armed;
        if (brutal) armed = _arm(seed);
        _trim(b, length);
        if (brutal) _checkMemory(armed);
        // the length word back for the hash, then set again: the region's bytes must be as they were
        uint256 trimmed = b.length;
        _trim(b, size);
        regionAfter = _region(b, size);
        _trim(b, trimmed);
    }

    /// keccak of `b`'s length word and its `size` bytes.
    function _region(bytes memory b, uint256 size) internal pure returns (bytes32 h) {
        assembly ("memory-safe") {
            h := keccak256(b, add(size, 0x20))
        }
    }

    // ------------------------------------------------------------------- a take

    /// A whole take from `list` for the caller: `_newWalk`, then `_take` (the walk, the fills, the settlement on the
    /// caller's accounts, the Take event); the walk after and what `_take` returned.
    function h_take(bool brutal, uint256 seed, MarketWord c, uint256 params, bytes calldata list)
        external
        returns (Walk memory walk, uint256 baseAmount, uint256 quoteAmount)
    {
        walk = _newWalk(c, params);
        Armed memory armed;
        if (brutal) armed = _arm(seed);
        (baseAmount, quoteAmount) = _take(walk, list);
        if (brutal) _checkMemory(armed);
    }
}
