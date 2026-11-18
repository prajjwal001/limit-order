// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI.
pragma solidity 0.8.38;

import {OloBase} from "./OloBase.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {IOloBook} from "../src/interfaces/IOloBook.sol";
import {OloListings} from "../src/interfaces/OloListings.sol";
import {PriceGrid} from "../src/libraries/PriceGrid.sol";
import {C_FEE_PPM_FIELD, C_PROPRIETARY_FLAG, C_TAG_FIELD, Market, MarketLib} from "../src/types/Market.sol";
import {MarketWord} from "../src/interfaces/MarketWord.sol";

using MarketLib for MarketWord;

/// `marketIdGivenListingWord`: a market's id from its listing word, the parameters it was listed with packed as in C;
/// OloListings packs the word from a listing's arguments. The fixture's market is base / quote at 50 ppm, 6 figures,
/// minQuote 1, open.
contract OloMarketIdOfTest is OloBase {
    /// The bits of C a listing word leaves 0 below the id: the maker share's and the version's (the tag less the fee).
    uint256 constant SHARE_AND_VERSION = C_TAG_FIELD & ~C_FEE_PPM_FIELD;

    function setUp() public {
        _deploy();
        book.setProprietaryListingAllowed(address(this), true);
    }

    function _idOf(address b, address q, uint24 fee, uint8 figs, uint96 minQuote, bool proprietary)
        internal
        view
        returns (uint32)
    {
        return OloListings.marketIdOf(IOloBook(address(book)), b, q, fee, figs, minQuote, proprietary);
    }

    /// The bits a listing word uses, 0-223: 224-255 carry a C's id and are not read.
    uint256 constant BELOW_THE_ID = (1 << 224) - 1;

    /// Market `id`'s C less its maker share, version and id: its listing word while its fee is the one it was listed
    /// at.
    function _wordOf(uint32 id) internal view returns (MarketWord) {
        return MarketWord.wrap(MarketWord.unwrap(book.configOf(id)) & ~SHARE_AND_VERSION & BELOW_THE_ID);
    }

    /// Each listing is found by its own parameters: the fixture's market and five more that differ from it in one
    /// parameter each. Any parameter changed names another listing or none.
    function test_each_listing_by_its_parameters() public {
        address b = address(base);
        address q = address(quote);
        uint32 byFee = book.listMarketQuote(b, q, 60, 6, 1, 0);
        uint32 byFigs = book.listMarketQuote(b, q, 50, 5, 1, 0);
        uint32 byMinQuote = book.listMarketQuote(b, q, 50, 6, 2, 0);
        uint32 swapped = book.listMarketQuote(q, b, 50, 6, 1, 0);
        uint32 proprietary = book.listMarketQuoteProprietary(b, q, 50, 6, 1, 0, address(base));
        assertEq(_idOf(b, q, 50, 6, 1, false), m, "the fixture's market");
        assertEq(_idOf(b, q, 60, 6, 1, false), byFee, "another fee");
        assertEq(_idOf(b, q, 50, 5, 1, false), byFigs, "other figures");
        assertEq(_idOf(b, q, 50, 6, 2, false), byMinQuote, "another minQuote");
        assertEq(_idOf(q, b, 50, 6, 1, false), swapped, "the tokens swapped");
        assertEq(_idOf(b, q, 50, 6, 1, true), proprietary, "proprietary");
        assertEq(_idOf(b, q, 70, 6, 1, false), 0, "a fee nobody listed at");
        assertEq(_idOf(b, q, 50, 4, 1, false), 0, "figures nobody listed at");
        assertEq(_idOf(b, q, 50, 6, 3, false), 0, "a minQuote nobody listed at");
        assertEq(_idOf(b, q, 60, 6, 1, true), 0, "proprietary at a fee nobody listed it at");
        assertEq(_idOf(b, b, 50, 6, 1, false), 0, "a token against itself");
        uint32[6] memory ids = [m, byFee, byFigs, byMinQuote, swapped, proprietary];
        for (uint256 i; i < ids.length; ++i) {
            assertEq(book.marketIdGivenListingWord(_wordOf(ids[i])), ids[i], "C less the share and version");
        }
    }

    /// Parameters no listing takes give 0 and never revert: a token never registered or figures outside 3 to 6
    /// (OloListings has nothing to pack and returns 0 without a lookup), a fee above MAX_FEE_PPM or past its 20 bits
    /// (packed into a word no listing wrote). The lookup reads 0 for any word no listing wrote: a zero word, a market's
    /// whole C (its share and version set), a fee carried into the version's bits.
    function test_words_no_listing_wrote_read_zero() public {
        address b = address(base);
        address q = address(quote);
        address stranger = address(new MockERC20("S", "S", 18));
        assertEq(_idOf(stranger, q, 50, 6, 1, false), 0, "a base never registered");
        assertEq(_idOf(b, stranger, 50, 6, 1, false), 0, "a quote never registered");
        assertEq(_idOf(b, q, 1_000_001, 6, 1, false), 0, "a fee above MAX_FEE_PPM");
        assertEq(_idOf(b, q, 50 + (1 << 20), 6, 1, false), 0, "the fixture's fee past its 20 bits");
        assertEq(_idOf(b, q, type(uint24).max, 6, 1, false), 0, "the largest fee");
        IOloBook olo = IOloBook(address(book));
        for (uint256 figs; figs <= type(uint8).max; ++figs) {
            if (figs == 6) continue;
            assertEq(_idOf(b, q, 50, uint8(figs), 1, false), 0, "figures other than the fixture's 6");
            if (figs < 3 || figs > 6) {
                assertEq(MarketWord.unwrap(OloListings.paramsOf(olo, b, q, 50, uint8(figs), 1, false)), 0, "no spacing");
            }
        }
        assertEq(MarketWord.unwrap(OloListings.paramsOf(olo, stranger, q, 50, 6, 1, false)), 0, "no base id");
        assertEq(MarketWord.unwrap(OloListings.paramsOf(olo, b, stranger, 50, 6, 1, false)), 0, "no quote id");
        assertEq(book.marketIdGivenListingWord(MarketWord.wrap(0)), 0, "a zero word");
        assertEq(book.marketIdGivenListingWord(c), 0, "the whole C: its share and version set");
        uint256 word = MarketWord.unwrap(_wordOf(m));
        assertEq(book.marketIdGivenListingWord(MarketWord.wrap(word)), m, "the listing word");
        assertEq(
            book.marketIdGivenListingWord(MarketWord.wrap(word | (type(uint256).max << 224))),
            m,
            "bits 224-255 not read"
        );
        assertEq(book.marketIdGivenListingWord(MarketWord.wrap(word + (1 << 208))), 0, "a fee carried past 20 bits");
    }

    /// A fee change keeps the market's listing: the fee it was listed at still finds it, the fee it moved to does not
    /// (its C less the share and version no longer is its listing word), and a listing at that fee is another market.
    function test_a_fee_change_keeps_the_listing() public {
        address b = address(base);
        address q = address(quote);
        MarketWord listed = _wordOf(m);
        book.setMarketFee(m, 30, 0);
        assertEq(_idOf(b, q, 50, 6, 1, false), m, "the fee it was listed at");
        assertEq(book.marketIdGivenListingWord(listed), m, "its listing word");
        assertEq(book.configOf(m).feePpm(), 30, "its current fee");
        assertEq(_idOf(b, q, 30, 6, 1, false), 0, "the fee it moved to: no listing");
        assertEq(book.marketIdGivenListingWord(_wordOf(m)), 0, "C less the share and version: the moved fee's");
        uint32 at30 = book.listMarketQuote(b, q, 30, 6, 1, 0);
        assertTrue(at30 != m);
        assertEq(_idOf(b, q, 30, 6, 1, false), at30, "a listing at 30 is another market");
        assertEq(_idOf(b, q, 50, 6, 1, false), m, "the first still by its own");
    }

    /// Any listing is found by its parameters: OloListings packs the word the contract packed (MarketLib.encode with
    /// the proprietary bit, the listed market's C less its share and version), the lookup gives the id the listing
    /// returned, and a parameter set one step away names another market or none.
    function testFuzz_a_listing_found_by_its_parameters(uint24 fee, uint8 figs, uint96 minQuote, bool proprietary)
        public
    {
        fee = uint24(bound(fee, 0, MarketLib.MAX_FEE_PPM));
        figs = uint8(bound(figs, 3, 6));
        if (fee == 50 && figs == 6 && minQuote == 1 && !proprietary) minQuote = 2; // the fixture's own
        address b = address(base);
        address q = address(quote);
        uint32 id = proprietary
            ? book.listMarketQuoteProprietary(b, q, fee, figs, minQuote, 0, address(base))
            : book.listMarketQuote(b, q, fee, figs, minQuote, 0);
        uint256 encoded = MarketWord.unwrap(
            Market({
                baseId: uint32(baseId),
                quoteId: uint32(quoteId),
                feePpm: fee,
                spacing: PriceGrid.spacingOf(figs),
                minQuote: minQuote
            }).encode()
        ) | (proprietary ? C_PROPRIETARY_FLAG : 0);
        MarketWord packed = OloListings.paramsOf(IOloBook(address(book)), b, q, fee, figs, minQuote, proprietary);
        assertEq(MarketWord.unwrap(packed), encoded, "OloListings packs as MarketLib.encode");
        assertEq(MarketWord.unwrap(packed), MarketWord.unwrap(_wordOf(id)), "the listed C less the share and version");
        assertEq(_idOf(b, q, fee, figs, minQuote, proprietary), id, "found");
        assertTrue(_idOf(b, q, fee, figs, minQuote, !proprietary) != id, "the other kind is another listing");
        assertTrue(_idOf(b, q, fee, figs, minQuote ^ 4, proprietary) != id, "another minQuote");
        assertTrue(_idOf(b, q, fee ^ 1, figs, minQuote, proprietary) != id, "another fee");
        assertTrue(_idOf(b, q, fee, figs == 6 ? 5 : figs + 1, minQuote, proprietary) != id, "other figures");
    }

    /// What a lookup costs a contract: the lookup alone, and OloListings' three calls (two token ids and the lookup).
    function test_the_lookup_costs() public {
        MarketWord word = _wordOf(m);
        uint256 g = gasleft();
        book.marketIdGivenListingWord(word);
        uint256 lookup = g - gasleft();
        g = gasleft();
        _idOf(address(base), address(quote), 50, 6, 1, false);
        uint256 viaLibrary = g - gasleft();
        emit log_named_uint("marketIdGivenListingWord", lookup);
        emit log_named_uint("OloListings.marketIdOf", viaLibrary);
    }
}
