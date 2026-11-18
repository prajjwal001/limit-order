// SPDX-License-Identifier: MIT
// Copyright (c) 2026 YOU LI.
pragma solidity ^0.8.8;

/// @title The policy of a proprietary market
/// @notice Who may trade in a proprietary market: its lister names a policy at the listing
/// (`listMarketQuoteProprietary`) and the OLO EVM contract keeps it for good. The OLO EVM contract asks it, by a static
/// call, before an entry that makes (rests an order or changes a resting one) or takes in the market; the entries that
/// only leave (a cancel, a claim, a batch cancel or claim, a multicall's CANCEL and CLAIM, deposits and withdrawals)
/// never ask, so a policy cannot hold anyone's funds. Only an answer whose first word is 1 (true) admits (the bytes
/// after its first 32 are not read): a call that reverts or runs out of gas, an answer of fewer than 32 bytes or any
/// other first word refuses (NotAdmitted). The OLO EVM contract's state read from here while it asks may be mid-call (a
/// multicall's accounts are written at its end; inside a flash the caller's account holds the credit until the callback
/// returns), so a policy decides on its own state. The listing does not call the policy, and the market's id is the
/// listing's next id, which any listing before it takes: so a policy is not written for an id fixed before its
/// listing. It reads `marketId` from each call (one policy may serve several markets), or learns its market after the
/// listing (the id the listing returns, MarketListed, `marketIdGivenListingWord`). A policy at a wrong address or one
/// that refuses everyone leaves a market nobody can make or take in, and its parameters stay listed (MarketExists): a
/// new listing changes one of them (minQuote plus or minus 1).
interface IOloMarketPolicy {
    /// @notice Whether `who` may trade in market `marketId` now
    /// @param marketId The proprietary market
    /// @param who The caller of the OLO EVM contract's entry: the maker or the taker of record
    /// @param isMaker True for an entry that rests an order or changes a resting one (a place, a modify, a batch post,
    /// replace or modify, the first PLACE or MODIFY of each run of a multicall's ops in the market, a takeThenRest's
    /// rest); false for a take and a takeThenRest's fills
    /// @return Whether the OLO EVM contract lets the call go on
    function admitted(uint32 marketId, address who, bool isMaker) external view returns (bool);
}
