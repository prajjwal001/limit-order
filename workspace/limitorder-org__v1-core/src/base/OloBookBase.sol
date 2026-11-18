// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

import {OloBookTakes} from "./OloBookTakes.sol";

/// @title OloBookBase
/// @notice The OLO EVM contract's state and internal operations, shared by OloBook and its extension OloBookExt (which
/// runs in the OLO EVM contract's storage). It has no price levels: every order is one word in a market-wide pool under
/// a position the maker names (the owner is in the word, so dead positions are reusable by anyone and a market can be
/// pre-warmed), or one of up to four sub-orders, bids or asks, in a maker's batch slot, and a take is a list of orders
/// the taker builds from the OLO Book. The contract keeps no best price, no bitmap and no queue; it fills the listed
/// orders in the listed order at each order's own price, skipping dead ones, ones on the taker's side and ones worse
/// than the price the list names. A take collects the fee whole; makers' proceeds settle lazily (claim, cancel, modify,
/// the batch operations), and the fee their fills earned is split there at the maker share of the version their order
/// rests in: the maker's part to the maker, the rest to the protocol's pot.
/// @dev A market is its key K and a run of versions (MarketLib): a version's C, K and its tag (the share, the fee,
/// the version), travels in calldata as K and a tag in the params, and every key is derived from C (OloSlots), so no
/// take and no settle reads a market slot (the fee and the share are C's). An entry that rests an order (a place, a
/// modify, a takeThenRest's rest, a batch post, replace or modify) reads the market's current C from the registry
/// (`_current`, `_checkCurrent`). Balances are accounts (owner, token), each owner's own; batch slots are each maker's
/// own (the maker is in the key). A multicall emits one event, its op stream.
/// The code is a chain of abstract contracts, one concern each, this one last: OloBookStorage (constants, storage,
/// the lock, the current-version checks, the account keys, the token registry) -> OloBookAssets (balances, account
/// flows, escrow, the taker's settlement, fees, transfers, the multicall's ledger) -> OloBookOrders (place, cancel,
/// claim, modify) -> OloBookBatches (the batch slot's operations and walk) -> OloBookTakes (a take's state, the fills
/// buffer, the walk of the list, the position and batch segment loops) -> OloBookBase.
abstract contract OloBookBase is OloBookTakes {}
