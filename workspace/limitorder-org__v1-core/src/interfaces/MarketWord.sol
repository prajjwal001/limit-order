// SPDX-License-Identifier: MIT
// Copyright (c) 2026 YOU LI.
pragma solidity ^0.8.8;

/// @notice A market's config word C: baseId 0-31 | quoteId 32-63 | spacing 64-73 | minQuote 74-169 | proprietary 170
/// | bits 171-173 zero | makerBps 174-187 | feePpm 188-207 | version 208-223 | marketId 224-255. Two parts:
///   - the key K, every bit but 174-223: the tokens, the spacing, minQuote, whether the market is proprietary and the
///     id, fixed at the listing. An upstream names its market by K, the same word for the market's whole life.
///   - the tag, bits 174-223: the maker share, the fee and the version they belong to. `setMarketFee` and
///     `setMarketMakerShare` rewrite their field in place and add 1 to the version: the id and K stay, and the contract
///     stores the market's current C under its id (`configOf`).
/// C = K | tag names one version of one market. Every slot of the market's orders is hashed from C (OloSlots), so
/// each version keeps its own pool positions and batch slots: an order rests in the version current when it was
/// placed, and fills and settles there, at that version's fee and share, read from the C the caller supplies (K and
/// the tag its params carry): no storage read. An entry that rests a new order reads the market's current C and rests
/// there only; one that rests an order again in place (a modify, a batch replace or modify) reads it to check that the
/// version it names is the current one. The events carry C's top 48 bits, the id and the version (the
/// market key, `C >> C_VERSION`). Prices are not the market's: every market shares one grid (PriceGrid), a tick is a
/// price per base wei in quote wei, and amounts are base wei.
/// @dev In src/interfaces/, MIT like every file there: IOloBook takes it, and an integration that imports IOloBook
/// compiles that folder and nothing else. MarketLib (types/Market.sol) reads and builds it; a file that calls
/// MarketLib's functions on a MarketWord binds them with `using MarketLib for MarketWord;`.
type MarketWord is uint256;
