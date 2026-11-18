// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";

/// The extension runs by delegatecall in the OLO EVM contract's storage, so the two must lay their state out alike:
/// every variable at the same slot and offset, with the same label, type and size. Read from the artifacts'
/// storageLayout (foundry.toml's extra_output): the hirun ones when they exist, as the tests deploy them, the default
/// build's otherwise.
contract OloLayoutTest is OloBase {
    string internal constant BOOK_DEFAULT = "out/OloBook.sol/OloBook.json";
    string internal constant EXT_DEFAULT = "out/OloBookExt.sol/OloBookExt.json";

    function test_book_and_extension_share_one_storage_layout() public view {
        bool hirun = vm.exists(BOOK) && vm.exists(EXT);
        if (hirun) {
            _requireFresh(BOOK);
            _requireFresh(EXT);
        }
        string memory bookPath = hirun ? BOOK : BOOK_DEFAULT;
        string memory extPath = hirun ? EXT : EXT_DEFAULT;
        string memory book = vm.readFile(bookPath);
        string memory ext = vm.readFile(extPath);
        uint256 n = _count(book, bookPath);
        assertEq(_count(ext, extPath), n, "as many variables");
        for (uint256 i; i < n; ++i) {
            assertEq(_entry(book, i), _entry(ext, i), string.concat("variable ", vm.toString(i)));
        }
        // the parse read something real: the owner first, at slot 0
        assertEq(_entry(book, 0), "owner 0 0 address 20", "owner at slot 0");
        assertEq(n, 15, "the fifteen variables of Owned2Step and OloBookStorage");
        // the market registry: the last variable, a fixed array of 2^32 words at slot MARKETS_SLOT, which the contract
        // reads at `_markets.slot + id` (OloBookStorage._marketSlot) and the tests at `MARKETS_SLOT + id`
        assertEq(
            _entry(book, n - 1),
            string.concat("_markets ", vm.toString(MARKETS_SLOT), " 0 MarketWord[4294967296] 137438953472"),
            "the registry, last"
        );
    }

    /// The number of variables in `json`'s storage layout.
    function _count(string memory json, string memory path) internal view returns (uint256 n) {
        if (!vm.keyExistsJson(json, ".storageLayout")) {
            revert(string.concat(path, " has no storageLayout: build again (foundry.toml extra_output)"));
        }
        while (vm.keyExistsJson(json, string.concat(".storageLayout.storage[", vm.toString(n), "]"))) {
            ++n;
        }
    }

    /// Variable `i` as "label slot offset type bytes", the type by its label (its name carries an AST id, which the
    /// two builds give differently).
    function _entry(string memory json, uint256 i) internal pure returns (string memory) {
        string memory entry = string.concat(".storageLayout.storage[", vm.toString(i), "]");
        string memory typeAt =
            string.concat(".storageLayout.types['", vm.parseJsonString(json, string.concat(entry, ".type")), "']");
        return string.concat(
            vm.parseJsonString(json, string.concat(entry, ".label")),
            " ",
            vm.parseJsonString(json, string.concat(entry, ".slot")),
            " ",
            vm.toString(vm.parseJsonUint(json, string.concat(entry, ".offset"))),
            " ",
            vm.parseJsonString(json, string.concat(typeAt, ".label")),
            " ",
            vm.parseJsonString(json, string.concat(typeAt, ".numberOfBytes"))
        );
    }
}
