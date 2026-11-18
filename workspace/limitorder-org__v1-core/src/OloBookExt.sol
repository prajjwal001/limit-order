// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

import {OloBookBase} from "./base/OloBookBase.sol";
import {IOloBookExt} from "./interfaces/IOloBookExt.sol";
import {IOloFlashCallback} from "./interfaces/IOloFlashCallback.sol";
import {AccountLib, OloSlots, PoolLib} from "./OloTypes.sol";
import {PriceGrid} from "./libraries/PriceGrid.sol";
import {SafeTransfer} from "./libraries/SafeTransfer.sol";
import {
    C_FEE_PPM,
    C_FEE_PPM_FIELD,
    C_MAKER_BPS,
    C_MAKER_BPS_FIELD,
    C_MARKET_ID,
    C_PROPRIETARY_FLAG,
    C_VERSION,
    Market,
    MarketLib
} from "./types/Market.sol";
import {MarketWord} from "./interfaces/MarketWord.sol";

using MarketLib for MarketWord;

/// @title OloBookExt
/// @notice Delegatecall extension of OloBook holding the cold entries: listing, admin, pre-warming and flash. It is
/// meant to run in the OLO EVM contract's storage only. Called directly it acts on its own storage, which the contract
/// never reads: its owner is zero, so the admin entries revert; listMarketQuote and warmPool write its own slots,
/// harmlessly; collectFees(address(0)) sends any native coin forced into it to its fee recipient, which is zero; and
/// flash finds no token in its own registry (unless one was listed there) and would call back from its own address,
/// which a callback that checks the OLO EVM contract's refuses.
contract OloBookExt is IOloBookExt, OloBookBase {
    // ------------------------------------------------------------------- admin
    // Every entry that writes checks the reentrancy lock, so none runs inside another call's token transfer.

    /// @inheritdoc IOloBookExt
    function listMarketQuote(
        address base,
        address quote,
        uint24 feePpm,
        uint8 sigFigs,
        uint96 minQuote,
        uint16 positionsToWarm
    ) external payable returns (uint32 marketId) {
        return _list(base, quote, feePpm, sigFigs, minQuote, positionsToWarm, 0);
    }

    /// @inheritdoc IOloBookExt
    function listMarketQuoteProprietary(
        address base,
        address quote,
        uint24 feePpm,
        uint8 sigFigs,
        uint96 minQuote,
        uint16 positionsToWarm,
        address policy
    ) external payable returns (uint32 marketId) {
        if (!canListProprietaryMarkets[msg.sender]) revert NotProprietaryLister();
        if (policy.code.length == 0) revert BadPolicy();
        marketId = _list(base, quote, feePpm, sigFigs, minQuote, positionsToWarm, C_PROPRIETARY_FLAG);
        // the market's policy, for good: no entry changes it (a lister upgrades its rules behind its own address)
        proprietaryMarketPolicy[marketId] = policy;
        emit ProprietaryMarketListed(marketId, msg.sender, policy);
    }

    /// @inheritdoc IOloBookExt
    function setProprietaryListingAllowed(address lister, bool allowed) external onlyOwner {
        _checkUnlocked();
        canListProprietaryMarkets[lister] = allowed;
        emit ProprietaryListerSet(lister, allowed);
    }

    /// @notice Lists a market, open (`proprietary` 0) or proprietary (`proprietary` C_PROPRIETARY_FLAG, its key bit):
    /// the checks and the writes of `listMarketQuote`, the bit in the parameters, so a proprietary market and an open
    /// one of the same parameters are two listings, each listed once.
    function _list(
        address base,
        address quote,
        uint24 feePpm,
        uint8 sigFigs,
        uint96 minQuote,
        uint16 positionsToWarm,
        uint256 proprietary
    ) internal returns (uint32 marketId) {
        _checkUnlocked();
        if (msg.value != listingFee) revert BadListingFee();
        if (sigFigs < PriceGrid.MIN_SIG_FIGS || sigFigs > PriceGrid.MAX_SIG_FIGS) revert BadMarketConfig();
        if (feePpm > MarketLib.MAX_FEE_PPM) revert BadMarketConfig();
        // the pair's defaults, one read: its fee floor (else the global one) and the maker share the market starts
        // with (else the global one)
        uint256 pair = _pairWord(base, quote);
        (uint256 floorPpm,) = _pairFeeFloor(pair);
        if (feePpm < floorPpm) revert FeeTooLow();
        (uint256 makerBps,) = _pairMakerBps(pair);
        MarketWord params = Market({
            baseId: uint32(_registerToken(base)),
            quoteId: uint32(_registerToken(quote)),
            feePpm: feePpm,
            spacing: PriceGrid.spacingOf(sigFigs),
            minQuote: minQuote
        }).encode();
        params = MarketWord.wrap(MarketWord.unwrap(params) | proprietary);
        // a token against itself is refused, by the ids in C
        if (params.baseId() == params.quoteId()) revert BadMarketConfig();
        // one listing per set of parameters: their listing word, keyed by the parameters alone, is written once (a
        // later fee or share change of the market neither frees them nor takes others)
        uint256 listingSlot = OloSlots.listingSlot(params);
        if (OloSlots.load(listingSlot) != 0) revert MarketExists();
        marketId = ++marketCount;
        OloSlots.store(listingSlot, marketId);
        // C: the parameters, the maker share, version 1 and the id
        MarketWord c = MarketWord.wrap(
            MarketWord.unwrap(params) | (makerBps << C_MAKER_BPS) | (1 << C_VERSION)
                | (uint256(marketId) << C_MARKET_ID)
        );
        OloSlots.store(_marketSlot(marketId), MarketWord.unwrap(c));
        emit MarketListed(marketId, base, quote, MarketWord.unwrap(c));
        if (positionsToWarm != 0) _warmPool(c, 0, positionsToWarm);
    }

    /// @inheritdoc IOloBookExt
    function setMarketMakerShare(uint256 marketId, uint48 makerBps) external onlyOwner {
        _checkUnlocked();
        if (makerBps > BPS) revert MakerShareTooHigh();
        MarketWord c = _marketOf(marketId);
        if (c.makerBps() == makerBps) revert NoChange();
        // in place, a new version: the share's field rewritten, the id, the key and the fee kept
        _setVersion(marketId, (MarketWord.unwrap(c) & ~C_MAKER_BPS_FIELD) | (uint256(makerBps) << C_MAKER_BPS), 0);
    }

    /// @inheritdoc IOloBookExt
    function setMarketFee(uint256 marketId, uint24 feePpm, uint64 positionsToWarm) external onlyOwner {
        _checkUnlocked();
        if (feePpm > MarketLib.MAX_FEE_PPM) revert BadMarketConfig();
        MarketWord c = _marketOf(marketId);
        if (c.feePpm() == feePpm) revert NoChange();
        // at most 1% from the market's fee, up or down
        _checkFeeStep(c.feePpm(), feePpm);
        // in place, a new version: the fee's field rewritten, the id, the key and the maker share kept
        _setVersion(
            marketId, (MarketWord.unwrap(c) & ~C_FEE_PPM_FIELD) | (uint256(feePpm) << C_FEE_PPM), positionsToWarm
        );
    }

    /// @inheritdoc IOloBookExt
    function setGlobalFeeFloor(uint32 feePpm) external onlyOwner {
        _checkUnlocked();
        uint256 fromPpm = globalFeeFloor;
        // the bound, at most 1,000,000 (BadMarketConfig), and the write: the rule the constructor's floor meets too
        _setGlobalFeeFloor(feePpm);
        // and a step of at most 1% from the floor it replaced, up or down (the constructor's floor takes no step)
        _checkFeeStep(fromPpm, feePpm);
    }

    /// @inheritdoc IOloBookExt
    function setGlobalMakerShare(uint24 makerBps) external onlyOwner {
        _checkUnlocked();
        if (makerBps > BPS) revert MakerShareTooHigh();
        globalMakerBps = uint16(makerBps);
        emit GlobalMakerShareSet(uint16(makerBps));
    }

    /// @inheritdoc IOloBookExt
    function setPairFeeFloor(address tokenA, address tokenB, uint32 feePpm, bool pairSet) external onlyOwner {
        _checkUnlocked();
        if (feePpm > MarketLib.MAX_FEE_PPM || tokenA == tokenB) revert BadMarketConfig();
        // a lift names no floor
        if (!pairSet && feePpm != 0) revert BadMarketConfig();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        uint256 pair = _pairDefaults[token0][token1];
        // the floor a listing of the pair meets moves at most 1%, up or down: before, the pair's own floor when set,
        // else the global one; after, the floor set, or for a lift the global one (a first set and a lift included)
        (uint256 fromPpm,) = _pairFeeFloor(pair);
        _checkFeeStep(fromPpm, pairSet ? feePpm : globalFeeFloor);
        // the floor's field and SET bit rewritten, the maker share's kept
        uint256 rest = pair & ~(PAIR_FLOOR_SET | PAIR_FLOOR_MASK);
        if (pairSet) {
            _pairDefaults[token0][token1] = rest | PAIR_FLOOR_SET | feePpm;
            emit PairFeeFloorSet(token0, token1, uint24(feePpm));
        } else {
            _pairDefaults[token0][token1] = rest;
            emit PairFeeFloorLifted(token0, token1);
        }
    }

    /// @inheritdoc IOloBookExt
    function setPairMakerShare(address tokenA, address tokenB, uint40 makerBps, bool pairSet) external onlyOwner {
        _checkUnlocked();
        if (tokenA == tokenB) revert BadMarketConfig();
        if (makerBps > BPS) revert MakerShareTooHigh();
        // a lift names no share
        if (!pairSet && makerBps != 0) revert BadMarketConfig();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // the share's field and SET bit rewritten, the fee floor's kept
        uint256 rest = _pairDefaults[token0][token1] & ~(PAIR_SHARE_SET | PAIR_SHARE_FIELD);
        if (pairSet) {
            _pairDefaults[token0][token1] = rest | PAIR_SHARE_SET | (uint256(makerBps) << PAIR_SHARE_SHIFT);
            emit PairMakerShareSet(token0, token1, uint16(makerBps));
        } else {
            _pairDefaults[token0][token1] = rest;
            emit PairMakerShareLifted(token0, token1);
        }
    }

    /// @inheritdoc IOloBookExt
    function setCurrentListingFee(uint80 fee) external onlyOwner {
        _checkUnlocked();
        listingFee = fee;
        emit ListingFeeSet(fee);
    }

    /// @inheritdoc IOloBookExt
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        _checkUnlocked();
        _setFeeRecipient(newFeeRecipient);
    }

    /// @inheritdoc IOloBookExt
    function collectFees(address token) external lock returns (uint256 amount) {
        if (token == address(0)) {
            // the native currency: the listing fees (and anything forced in, which only this moves out)
            amount = address(this).balance;
            if (amount != 0) SafeTransfer.transferNative(feeRecipient, amount);
        } else {
            uint256 id = tokenId[token];
            if (id == 0) revert UnknownToken();
            uint256 pot = OloSlots.potKey(id);
            amount = AccountLib.potOf(_accounts[pot]);
            _accounts[pot] = AccountLib.USED;
            _push(token, feeRecipient, amount);
        }
        emit FeesCollected(token, feeRecipient, amount);
    }

    // ------------------------------------------------------------------- flash

    /// @inheritdoc IOloBookExt
    function flash(address token, uint256 amount, bytes calldata data) external {
        // not inside another call's token transfer; the lock stays open, so the callback may call any entry
        _checkUnlocked();
        uint256 id = tokenId[token];
        if (id == 0) revert UnknownToken();
        if (amount == 0) revert ZeroSize();
        // an account's bound, checked before the credit's add as a deposit checks it
        if (amount > AccountLib.AMOUNT_MASK) revert AmountOverflow();
        // a caller to call back: an address without code (a plain account) has none, and is told so
        if (msg.sender.code.length == 0) revert BadAddress();
        _credit(id, amount);
        // the caller's work, on its accounts; a callback's revert is the flash's
        IOloFlashCallback(msg.sender).oloFlashCallback(token, amount, data);
        // the repayment: the account holds the amount again, or the whole call reverts (InsufficientBalance)
        _debit(id, amount);
        emit Flash(msg.sender, token, amount);
    }

    // ------------------------------------------------------------- pre-warming
    // Anyone may pay for this; a market's creator or the protocol typically does. It writes position words that are
    // still zero so the first order there rewrites a nonzero word (2.9k) instead of a fresh one (20k). Batch slots
    // and accounts are each owner's own: a public warming of them would serve nobody in particular.

    /// @inheritdoc IOloBookExt
    function warmPool(uint32 marketId, uint32 from, uint256 n) external {
        _checkUnlocked();
        if (n == 0 || n > 512) revert BadWarmRange();
        _warmPool(_market(marketId), from, n);
    }

    // ------------------------------------------------------------ the ext's own
    // Run by the entries above only, so the OLO EVM contract's bytecode never holds them.

    /// @notice The token's id, registering it on first sight (a listing's tokens; the registry holds up to 2^32 - 1).
    /// A token has code: address(0) and any other address without code are refused, since every deposit of one would
    /// revert and its market be dead. Nothing else about a token is checked: an address with
    /// code that is no token lists (a wallet that delegates to code, EIP-7702, among them), a dead market too.
    function _registerToken(address token) internal returns (uint256 id) {
        id = tokenId[token];
        if (id == 0) {
            if (token.code.length == 0) revert BadMarketConfig();
            id = ++tokenCount;
            if (id > MarketLib.MAX_TOKEN_ID) revert TokenRegistryFull();
            tokenId[token] = id;
            tokenAddr[id] = token;
        }
    }

    /// @notice The current C of market `marketId`, one listed (UnknownMarket otherwise).
    function _marketOf(uint256 marketId) internal view returns (MarketWord) {
        if (marketId == 0 || marketId > marketCount) revert UnknownMarket();
        return _market(uint32(marketId)); // a listed id, below 2^32
    }

    /// @notice Makes `changed` (the market's current C with a field of its tag rewritten) the market's next version:
    /// its version one more (TooManyVersions past MarketLib.MAX_VERSION; a value set back to an earlier one is a new
    /// version too, never the old one again), stored as the market's current C, and logged; then `positionsToWarm`
    /// pool positions of the new version warmed from 0. Orders resting in the versions before keep their C: they fill
    /// at their fee, settle at their share, and cancel and claim, but no entry rests a new order there.
    function _setVersion(uint256 marketId, uint256 changed, uint256 positionsToWarm) internal {
        MarketWord c = MarketWord.wrap(changed);
        if (c.version() == MarketLib.MAX_VERSION) revert TooManyVersions();
        unchecked {
            // the version below its maximum: one more stays in its 16 bits
            c = MarketWord.wrap(changed + (1 << C_VERSION));
        }
        OloSlots.store(_marketSlot(uint32(marketId)), MarketWord.unwrap(c)); // checked by `_marketOf`
        emit MarketConfigSet(uint32(marketId), c.version(), MarketWord.unwrap(c));
        if (positionsToWarm != 0) _warmPool(c, 0, positionsToWarm);
    }

    /// @notice Refuses an owner's call that moves a fee by more than 1% of the quote, MarketLib.MAX_FEE_STEP_PPM, up or
    /// down (FeeStepTooLarge): `fromPpm` the fee or floor in force, `toPpm` the one the call asks for.
    function _checkFeeStep(uint256 fromPpm, uint256 toPpm) internal pure {
        uint256 step = toPpm > fromPpm ? toPpm - fromPpm : fromPpm - toPpm;
        if (step > MarketLib.MAX_FEE_STEP_PPM) revert FeeStepTooLarge();
    }

    /// @notice Writes USED into the pool positions `from` .. `from + n - 1` that are still untouched (a position number
    /// is 32 bits: past 2^32 - 1 the range goes on from 0), so the first order in each rewrites a nonzero word (2.9k)
    /// instead of a fresh one (20k). Anyone may pay.
    function _warmPool(MarketWord c, uint32 from, uint256 n) internal {
        if (!c.isSet()) revert UnknownMarket();
        uint256 end = from + n;
        for (uint256 pos = from; pos < end; ++pos) {
            uint256 slot = OloSlots.orderSlot(c, pos);
            if (OloSlots.load(slot) == 0) OloSlots.store(slot, PoolLib.USED);
        }
        emit PoolWarmed(uint48(c.marketKey()), from, n);
    }
}
