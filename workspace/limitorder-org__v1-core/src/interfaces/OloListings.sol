// SPDX-License-Identifier: MIT
// Copyright (c) 2026 YOU LI.
pragma solidity ^0.8.8;

import {IOloBook} from "./IOloBook.sol";
import {MarketWord} from "./MarketWord.sol";

/// @title OloListings: a market's id from the parameters it was listed with
/// @notice For integrators: packs the arguments `listMarketQuote` (open) or `listMarketQuoteProprietary` took into the
/// listing word, as the OLO EVM contract packs it, and asks `marketIdGivenListingWord` for the id. The parameters are
/// the listing's: a market whose fee was changed since is found by the fee it was listed at, so a caller reads the
/// market's current word with `configOf`. Three calls to the contract: `tokenId` twice and the lookup.
library OloListings {
    /// @notice The id of the market listed with these parameters; 0 when none was, or for parameters no listing takes
    /// (a token never registered, a fee above 1,000,000 ppm, figures outside 3 to 6)
    function marketIdOf(
        IOloBook book,
        address base,
        address quote,
        uint24 feePpm,
        uint8 sigFigs,
        uint96 minQuote,
        bool proprietary
    ) internal view returns (uint32) {
        MarketWord params = paramsOf(book, base, quote, feePpm, sigFigs, minQuote, proprietary);
        if (MarketWord.unwrap(params) == 0) return 0;
        return book.marketIdGivenListingWord(params);
    }

    /// @notice The listing word of these parameters: the base id at bits 0-31, the quote id at 32-63, the spacing
    /// 10^(6 - sigFigs) at 64-73, minQuote at 74-169, the proprietary bit 170, the fee at 188-207 (C's fields,
    /// MarketWord). Zero when there is nothing to pack: a token never registered (no id) or figures outside 3 to 6 (no
    /// spacing). Any other parameters pack, those no listing takes (a fee above 1,000,000 ppm) into a word no listing
    /// wrote.
    function paramsOf(
        IOloBook book,
        address base,
        address quote,
        uint24 feePpm,
        uint8 sigFigs,
        uint96 minQuote,
        bool proprietary
    ) internal view returns (MarketWord) {
        uint256 baseId = book.tokenId(base);
        uint256 quoteId = book.tokenId(quote);
        if (baseId == 0 || quoteId == 0 || sigFigs < 3 || sigFigs > 6) return MarketWord.wrap(0);
        uint256 params = baseId | (quoteId << 32) | ((10 ** (6 - uint256(sigFigs))) << 64) | (uint256(minQuote) << 74)
            | (uint256(feePpm) << 188);
        if (proprietary) params |= 1 << 170;
        return MarketWord.wrap(params);
    }
}
