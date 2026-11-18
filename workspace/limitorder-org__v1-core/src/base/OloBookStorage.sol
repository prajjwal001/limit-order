// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

import {Owned2Step} from "./Owned2Step.sol";
import {IOloBookBase} from "../interfaces/IOloBookBase.sol";
import {IOloMarketPolicy} from "../interfaces/IOloMarketPolicy.sol";
import {C_BASE_ID, C_KEY_MASK, MarketLib} from "../types/Market.sol";
import {MarketWord} from "../interfaces/MarketWord.sol";
import {KEY_BITS, KEY_MASK, OloSlots} from "../OloTypes.sol";

using MarketLib for MarketWord;

/// @title OloBookStorage
/// @notice The OLO EVM contract's state and what every part reads: the shared constants, the storage variables (the
/// layout OloBook and OloBookExt share: the extension runs in the OLO EVM contract's storage), the reentrancy lock, the
/// current-version checks and the caller's account keys. Each part's own constants live with it (a take's mode bits in
/// OloBookTakes, a place's flags in OloBookOrders), and what only the extension runs (the token registry's writes, the
/// pool's warming) in OloBookExt. First in the chain
/// OloBookStorage -> OloBookAssets -> OloBookOrders -> OloBookBatches -> OloBookTakes -> OloBookBase.
abstract contract OloBookStorage is Owned2Step, IOloBookBase {
    // -------------------------------------------------------------- constants

    uint256 internal constant BPS = 10_000;

    // A pair's listing defaults as `_pairDefaults` holds them, two fields each with its own SET bit, so a value of 0 is
    // told apart from no value (where the global one applies): fee floor 0-23 | FLOOR_SET 24 | makerBps 32-45 |
    // SHARE_SET 46. Each setter rewrites its own field and bit and keeps the other's.

    /// @dev The pair's fee floor is set (bits 0-23 hold it).
    uint256 internal constant PAIR_FLOOR_SET = 0x1000000;

    /// @dev The pair's fee floor, in ppm.
    uint256 internal constant PAIR_FLOOR_MASK = 0xffffff;

    /// @dev The pair's maker share is set (bits 32-45 hold it).
    uint256 internal constant PAIR_SHARE_SET = 0x400000000000;

    /// @dev Where the pair's maker share starts; it is 14 bits wide (C_MAKER_BPS_MASK).
    uint256 internal constant PAIR_SHARE_SHIFT = 32;

    /// @dev The pair's maker share in place: C_MAKER_BPS_MASK << PAIR_SHARE_SHIFT, written out (a constant defined by
    /// an expression can change the contract's code).
    uint256 internal constant PAIR_SHARE_FIELD = 0x3fff00000000;

    // ---------------------------------------------------------------- storage
    /// @inheritdoc IOloBookBase
    uint32 public marketCount;

    /// @dev The least fee a listing may carry when its pair has no floor of its own (`_pairFeeFloor`), in ppm; 0: none.
    /// It shares the slot of marketCount, which a listing reads anyway, so the read is warm.
    uint24 internal globalFeeFloor;

    /// @inheritdoc IOloBookBase
    address public feeRecipient;

    /// @dev The maker share a listing gives its market when its pair has no share of its own (`_pairMakerBps`), in
    /// bps; 0 as deployed: the protocol takes the whole fee until the owner sets a share. It shares the slot of
    /// feeRecipient and listingFee, which a listing reads anyway, so the read is warm.
    uint16 internal globalMakerBps;

    /// @dev The native currency a listing pays, in wei; 0 until the owner sets one (`listingFeeCurrent` reads it). It
    /// shares the slot of feeRecipient and globalMakerBps, which a listing reads anyway, so the read is warm.
    uint80 internal listingFee;

    /// @inheritdoc IOloBookBase
    uint256 public tokenCount;

    /// @inheritdoc IOloBookBase
    mapping(address token => uint256) public tokenId;

    /// @inheritdoc IOloBookBase
    mapping(uint256 id => address) public tokenAddr;

    /// @dev Balance accounts (AccountLib) under OloSlots.ownedKey: owner, token. Owner 0's account of a token is the
    /// protocol's fee pot.
    mapping(uint256 key => uint256) internal _accounts;

    /// @dev Each pair's listing defaults (the fee floor and the maker share, each with its SET bit; zero: neither),
    /// under its two token addresses in ascending order: one word for both of a pair's markets' sides (base A quote B,
    /// base B quote A). Keyed by address, not registry id, so a pair's defaults can be set before any listing registers
    /// the tokens.
    mapping(address token0 => mapping(address token1 => uint256)) internal _pairDefaults;

    /// @inheritdoc IOloBookBase
    mapping(address lister => bool) public canListProprietaryMarkets;

    /// @inheritdoc IOloBookBase
    mapping(uint32 marketId => address) public proprietaryMarketPolicy;

    /// @dev The market registry: each market's current config word C (its key and its current tag, the version new
    /// orders rest in), at index = its id; zero for an id never listed. The listing writes it, `setMarketFee` and
    /// `setMarketMakerShare` rewrite its tag, every entry that rests an order reads it (`_current`, `_checkCurrent`).
    /// A fixed array of 2^32 words, so every uint32 id is in range and element id sits at slot `_markets.slot + id`
    /// (Solidity lays a fixed array out in consecutive slots): read and written through `_marketSlot`, never as
    /// `_markets[id]`, whose bound check and slot arithmetic cost each read 52 gas more (measured, the index a uint32
    /// too). The last state variable: its 2^32 slots move no other one.
    MarketWord[1 << 32] internal _markets;

    // Pool orders and batch slots live at raw slots derived from C (OloSlots.orderSlot, and with the maker
    // batchSlot): one hash per access and no market slot to read. Each listing's parameters have a listing word
    // (OloSlots.listingSlot) holding the market's id, read and written by the listing only.

    // ------------------------------------------------------------------- lock

    modifier lock() {
        _lock();
        _;
        _unlock();
    }

    modifier lockIf(bool callsOut) {
        if (callsOut) _lock();
        else _checkUnlocked();
        _;
        if (callsOut) _unlock();
    }

    /// @dev Nonzero for the span of a call that moves tokens (`lock`, `lockIf`); transient, so it costs no storage
    /// and clears itself at the transaction's end. A whole word: a packed bool would be read back before each write.
    uint256 internal transient _locked;

    function _checkUnlocked() internal view {
        if (_locked != 0) revert Locked();
    }

    function _lock() internal {
        _checkUnlocked();
        _locked = 1;
    }

    function _unlock() internal {
        _locked = 0;
    }

    // ---------------------------------------------------------------- listing

    /// @notice The current C of the market `k` names, for an entry that rests an order there (a place, a takeThenRest's
    /// rest, a batch post, and a multicall whose header names the market by its key): `k` must be the market's key K,
    /// the current C without its tag, whole (a word with any tag bit set, an older version's C included, is
    /// UnknownMarket), so a caller names the market by the same word for its whole life and the order rests in the
    /// market's current version. One read of the market's registry word, one compare; a listed C is never zero, so the
    /// zero word is none.
    function _current(MarketWord k) internal view returns (MarketWord c) {
        c = _market(k.marketId());
        if (MarketWord.unwrap(c) & C_KEY_MASK != MarketWord.unwrap(k) || !c.isSet()) revert UnknownMarket();
    }

    /// @notice Refuses a C that is not its market's current one, for an entry that rests an order in the version a
    /// caller names (a modify, a batch replace or modify, a multicall whose header gives a C): MarketFrozen when the
    /// key is a listed market's and the tag another version's (an older one, whose orders fill, cancel and claim, but
    /// rest no new ones), UnknownMarket when the key is no market's. One read of the market's registry word, one
    /// compare; a listed C is never zero, so a zero C is none.
    function _checkCurrent(MarketWord c) internal view {
        MarketWord cur = _market(c.marketId());
        if (MarketWord.unwrap(cur) != MarketWord.unwrap(c) || !cur.isSet()) {
            if (cur.isSet() && (MarketWord.unwrap(cur) ^ MarketWord.unwrap(c)) & C_KEY_MASK == 0) {
                revert MarketFrozen();
            }
            revert UnknownMarket();
        }
    }

    /// @notice Refuses the caller (NotAdmitted) in proprietary market `marketId` unless the market's policy admits it,
    /// as a maker (`isMaker`: an entry that rests an order or changes a resting one) or as a taker (a take, a
    /// takeThenRest's fills). The entries call it for a word whose proprietary bit is set (MarketLib.isProprietary), so
    /// an open market pays one bit test. One read of the market's policy and one static call of
    /// `IOloMarketPolicy.admitted(marketId, msg.sender, isMaker)`: the policy must answer at least one word, the first
    /// exactly 1 (true). A call that reverts or runs out of gas, a shorter answer or any other word refuses, and so does
    /// an address without code, the zero policy of an id no proprietary listing made included (a word with the bit set
    /// that is no proprietary market's: its orders' slots are empty anyway). The answer is copied whole, so a policy
    /// that answers at length makes its own market's callers pay for it. The entries that only leave never call it: a
    /// cancel, a claim, a batch cancel or claim, a multicall's CANCEL and CLAIM, deposits and withdrawals.
    function _admit(uint32 marketId, bool isMaker) internal view {
        (bool ok, bytes memory answer) = proprietaryMarketPolicy[marketId].staticcall(
            abi.encodeCall(IOloMarketPolicy.admitted, (marketId, msg.sender, isMaker))
        );
        if (!ok || answer.length < 32 || abi.decode(answer, (uint256)) != 1) revert NotAdmitted();
    }

    /// @notice Market `id`'s current C from the market registry: zero for an id never listed.
    function _market(uint32 id) internal view returns (MarketWord) {
        return MarketWord.wrap(OloSlots.load(_marketSlot(id)));
    }

    /// @notice The storage slot of market `id`'s word in the registry: `_markets.slot + id`. The assembly reads the
    /// array's slot number, a constant of the layout, and nothing else; the id is added here, in Solidity. A uint32 id
    /// is always within the array's 2^32 elements, so no bound is checked, and the sum stays far below 2^256.
    function _marketSlot(uint32 id) internal pure returns (uint256 slot) {
        assembly ("memory-safe") {
            slot := _markets.slot
        }
        unchecked {
            slot += id; // a small slot number plus an id below 2^32
        }
    }

    /// @notice The listing defaults word of `tokenA` and `tokenB`, either as base (`_pairDefaults`; zero: none set).
    function _pairWord(address tokenA, address tokenB) internal view returns (uint256) {
        return tokenA < tokenB ? _pairDefaults[tokenA][tokenB] : _pairDefaults[tokenB][tokenA];
    }

    /// @notice The least fee a listing of the pair whose defaults word is `pair` may carry, in ppm: the pair's own
    /// floor when the owner set one (it may be below the global floor, 0 included), else the global floor.
    function _pairFeeFloor(uint256 pair) internal view returns (uint256 floorPpm, bool pairSet) {
        if (pair & PAIR_FLOOR_SET != 0) return (pair & PAIR_FLOOR_MASK, true);
        return (globalFeeFloor, false);
    }

    /// @notice The maker share a listing of the pair whose defaults word is `pair` gives its market, in bps: the
    /// pair's own share when the owner set one (above or below the global share, 0 included), else the global share.
    function _pairMakerBps(uint256 pair) internal view returns (uint256 makerBps, bool pairSet) {
        if (pair & PAIR_SHARE_SET != 0) return ((pair & PAIR_SHARE_FIELD) >> PAIR_SHARE_SHIFT, true);
        return (globalMakerBps, false);
    }

    // --------------------------------------------------------------- accounts
    // The caller's two accounts of a market travel packed: quote account key 32-63 | base account key 0-31, the two
    // ids as C holds them.

    function _acctKeys(MarketWord c) internal pure returns (uint256) {
        return (MarketWord.unwrap(c) >> C_BASE_ID) & ((KEY_MASK << KEY_BITS) | KEY_MASK);
    }

    /// @notice The caller's account key of the market's quote token, from its two keys.
    function _quoteKey(uint256 acctKeys) internal pure returns (uint256) {
        return acctKeys >> KEY_BITS;
    }

    /// @notice The caller's account key of the market's base token, from its two keys.
    function _baseKey(uint256 acctKeys) internal pure returns (uint256) {
        return acctKeys & KEY_MASK;
    }

    // -------------------------------------------------------------------- misc

    function _setFeeRecipient(address newFeeRecipient) internal {
        if (newFeeRecipient == address(0) || newFeeRecipient == address(this)) revert BadAddress();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientSet(newFeeRecipient);
    }

    /// @notice Sets the global fee floor, in ppm: the least fee a listing of a pair with no floor of its own may carry
    /// (FeeTooLow below it). At most MarketLib.MAX_FEE_PPM, 1,000,000 (BadMarketConfig above it), checked before the
    /// value is narrowed to the stored `uint24`. The contract's constructor (the floor it is born with) and
    /// `setGlobalFeeFloor` both set it here, and both log GlobalFeeFloorSet, 0 included.
    function _setGlobalFeeFloor(uint256 feePpm) internal {
        if (feePpm > MarketLib.MAX_FEE_PPM) revert BadMarketConfig();
        globalFeeFloor = uint24(feePpm);
        emit GlobalFeeFloorSet(uint24(feePpm));
    }
}
