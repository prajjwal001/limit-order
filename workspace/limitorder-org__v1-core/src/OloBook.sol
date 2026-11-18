// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 YOU LI. Patent pending.
pragma solidity 0.8.38;

import {OloBookBase} from "./base/OloBookBase.sol";
import {IOloBook} from "./interfaces/IOloBook.sol";
import {IOloBookExt} from "./interfaces/IOloBookExt.sol";
import {AMOUNT_FIELD, AccountLib, KEY_BITS, OloSlots, PoolWord, TICK_FIELD} from "./OloTypes.sol";
import {C_KEY_MASK, C_TAG_FIELD, MarketLib} from "./types/Market.sol";
import {MarketWord} from "./interfaces/MarketWord.sol";
import {SettleFlags} from "./libraries/Flags.sol";
import {OloMath} from "./libraries/OloMath.sol";

using MarketLib for MarketWord;

/// @title OloBook
/// @notice The OLO EVM contract: accounts, pool orders, batch slots, takes and the multicall (see IOloBook).
/// @dev Everything cold (listing, admin, pre-warming, flash) runs in OloBookExt by delegatecall on this storage; its
/// selectors are forwarded here.
contract OloBook is IOloBook, OloBookBase {
    /// @inheritdoc IOloBook
    address public immutable ext;

    /// @dev The owner is the deployer, `msg.sender`: a contract that deploys the OLO EVM contract (a factory, a CREATE2
    /// deployer) owns it, and hands it on (`transferOwnership`) itself or keeps it. The deploy script deploys from its
    /// account by a plain CREATE.
    /// @param feeRecipient_ The wallet `collectFees` pays, not zero and not the OLO EVM contract (BadAddress)
    /// @param ext_ The extension the OLO EVM contract forwards its listing, admin and pre-warming entries to, an
    /// address with code (BadAddress)
    /// @param globalFeeFloor_ The global fee floor the contract is born with, in ppm (10 bps = 1,000; 0: none), at most
    /// 1,000,000 (BadMarketConfig): every listing meets it from the first block, so no market can be listed below it
    /// before the owner sets one. Logged as GlobalFeeFloorSet, 0 included
    constructor(address feeRecipient_, address ext_, uint256 globalFeeFloor_) {
        // zero, the OLO EVM contract itself (no code while it is being made) or any other address without code: a
        // delegatecall to it would succeed with nothing, and every listing and admin entry would do nothing
        if (ext_.code.length == 0) revert BadAddress();
        ext = ext_;
        owner = msg.sender;
        // the global maker share starts at 0: the protocol takes the whole fee of every market listed until the owner
        // sets a share (`setGlobalMakerShare`, `setPairMakerShare`, `setMarketMakerShare`); the global fee floor is
        // the one given, by the rule `setGlobalFeeFloor` applies
        _setFeeRecipient(feeRecipient_);
        _setGlobalFeeFloor(globalFeeFloor_);
    }

    // --------------------------------------------------------------- accounts

    /// @inheritdoc IOloBook
    function deposit(address token, uint256 amount) external lock {
        _deposit(token, amount);
    }

    /// @inheritdoc IOloBook
    function withdraw(address token, uint256 amount) external lock {
        _withdraw(token, amount, msg.sender);
    }

    /// @inheritdoc IOloBook
    function withdrawTo(address token, uint256 amount, address to) external lock {
        if (to == address(0) || to == address(this)) revert BadAddress();
        _withdraw(token, amount, to);
    }

    // ----------------------------------------------------------------- makers
    // Every entry takes its scalars in one packed word: seven ABI words of calldata cost about 1.1k gas, one word
    // about 0.4k. IOloBook gives the layouts.

    // multicall op codes
    uint256 private constant OP_PLACE = 1;
    uint256 private constant OP_CANCEL = 2;
    uint256 private constant OP_CLAIM = 3;
    uint256 private constant OP_MODIFY = 4;
    uint256 private constant OP_DEPOSIT = 5;
    uint256 private constant OP_WITHDRAW = 6;

    /// @dev Byte k = op k's length: 1 PLACE 25, 2 CANCEL 6, 3 CLAIM 6, 4 MODIFY 24, 5 DEPOSIT 21, 6 WITHDRAW 21.
    uint256 private constant OP_LENGTHS = 0x15151806061900;

    /// @dev A stream's market index before any market entry.
    uint256 private constant NONE = type(uint256).max;

    // Where each field starts (bit 0 is a place's and a take's side, the order's position a cancel's, a claim's and a
    // modify's, and the kind a batch operation's):
    uint256 private constant PLACE_TICK = 1;
    uint256 private constant PLACE_AMOUNT = 27;
    uint256 private constant PLACE_POS = 139;
    uint256 private constant PLACE_FLAGS = 171;
    uint256 private constant ORDER_FLAGS = 32; // cancel and claim
    uint256 private constant MODIFY_TICK = 32;
    uint256 private constant MODIFY_AMOUNT = 58;
    uint256 private constant MODIFY_FLAGS = 170;
    uint256 private constant REST_TICK = 121; // takeThenRest
    uint256 private constant REST_POS = 147;

    /// @inheritdoc IOloBook
    function place(MarketWord k, uint256 params)
        external
        lockIf(uint8(params >> PLACE_FLAGS) & SettleFlags.MASK != 0)
        returns (uint256 orderId, uint256 stored)
    {
        // a proprietary market's policy admits the maker (K carries the bit, `_current` checks K below)
        if (k.isProprietary()) _admit(k.marketId(), true);
        bool isBid = params & 1 != 0;
        uint256 tick = (params >> PLACE_TICK) & TICK_FIELD;
        uint8 flags = uint8(params >> PLACE_FLAGS);
        // the tick and the size are checked on the key's spacing and minQuote (the current C's: `_current` checks the
        // key)
        if (!k.makerTick(tick)) revert TickOutOfRange();
        (uint256 q, uint256 units, uint256 stored_) = _restAmount(k, tick, (params >> PLACE_AMOUNT) & AMOUNT_FIELD);
        stored = stored_;
        // the order rests in the market's current version
        MarketWord c = _current(k);
        uint256 landed;
        uint256 key;
        uint256 escrow;
        uint256 placed;
        (landed, key, escrow, placed) = _placeOp(
            c,
            isBid,
            tick,
            q,
            units,
            stored_,
            uint32(params >> PLACE_POS),
            flags & ~SettleFlags.MASK, // the probes, and the bits that mean nothing for `_placeOp` to refuse
            _acctKeys(c)
        );
        if (flags & SettleFlags.MASK == 0) _debit(key, escrow);
        else _fund(key, escrow, flags);
        emit Placed(msg.sender, _eventWord(c.marketKey(), placed, stored, landed));
        // the position and the version's tag in the params' shape: a cancel or a claim of the order passes it back
        orderId = c.tagCarried() | landed;
    }

    /// @inheritdoc IOloBook
    function cancel(MarketWord k, uint256 params)
        external
        lockIf(uint8(params >> ORDER_FLAGS) & SettleFlags.WALLET != 0)
    {
        // the version the order rests in: the key and the tag the params carry
        MarketWord c = k.withTag(params);
        uint32 pos = uint32(params);
        uint256 settle = _checkSettleFlags(uint8(params >> ORDER_FLAGS));
        (PoolWord word, uint256 open, uint256 filled, uint256 proceeds, int256 quoteFlow, int256 baseFlow) =
            _cancelOp(c, OloSlots.orderSlot(c, pos));
        uint256 market = c.marketKey();
        if (filled != 0) emit Claimed(msg.sender, _eventWord(market, PoolWord.unwrap(word), filled, pos), proceeds);
        emit Cancelled(msg.sender, _eventWord(market, PoolWord.unwrap(word), open, pos));
        _settleFlows(_acctKeys(c), quoteFlow, baseFlow, settle);
    }

    /// @inheritdoc IOloBook
    function claim(MarketWord k, uint256 params)
        external
        lockIf(uint8(params >> ORDER_FLAGS) & SettleFlags.WALLET != 0)
        returns (uint256 proceeds)
    {
        // the version the order rests in: the key and the tag the params carry
        MarketWord c = k.withTag(params);
        uint32 pos = uint32(params);
        uint256 settle = _checkSettleFlags(uint8(params >> ORDER_FLAGS));
        PoolWord word;
        uint256 filled;
        int256 quoteFlow;
        int256 baseFlow;
        (word, filled, proceeds, quoteFlow, baseFlow) = _claimOp(c, OloSlots.orderSlot(c, pos));
        emit Claimed(msg.sender, _eventWord(c.marketKey(), PoolWord.unwrap(word), filled, pos), proceeds);
        _settleFlows(_acctKeys(c), quoteFlow, baseFlow, settle);
    }

    /// @inheritdoc IOloBook
    function modify(MarketWord k, uint256 params)
        external
        lockIf(uint8(params >> MODIFY_FLAGS) & SettleFlags.MASK != 0)
        returns (uint256 stored)
    {
        // a proprietary market's policy admits the maker; the version the order rests in, the key and the tag the
        // params carry, which must be the current one (`_modifyEntry`)
        if (k.isProprietary()) _admit(k.marketId(), true);
        return _modifyEntry(
            k.withTag(params),
            uint32(params),
            (params >> MODIFY_TICK) & TICK_FIELD,
            (params >> MODIFY_AMOUNT) & AMOUNT_FIELD,
            uint8(params >> MODIFY_FLAGS)
        );
    }

    // ------------------------------------------------------------------ takers

    /// @inheritdoc IOloBook
    /// @dev Each position's word and each batch slot's word is read once and written once.
    function take(MarketWord k, bytes calldata list, uint256 params)
        external
        lockIf(uint8(params >> TAKE_MODE) & TAKE_WALLET != 0)
        returns (uint256 baseAmount, uint256 quoteAmount)
    {
        // a proprietary market's policy admits the taker, once for the whole list (the makers it fills were admitted
        // when they rested); the version whose orders fill: the key and the tag the params carry, whose bit a word
        // must carry to reach a proprietary market's orders
        if (k.isProprietary()) _admit(k.marketId(), false);
        return _take(_newWalk(k, params), list);
    }

    /// @inheritdoc IOloBook
    /// @dev Named for its selector (0x315cf9dc), which sorts fifth, between `orderOf` and `balanceOf`: the dispatcher
    /// compares selectors in order, so an entry sorted earlier pays less to reach (takeAndRest's 0x4fd9c7a7 sorted
    /// tenth).
    function takeThenRest(MarketWord k, bytes calldata list, uint256 params)
        external
        lockIf(uint8(params >> TAKE_MODE) & TAKE_WALLET != 0)
        returns (uint256 baseAmount, uint256 quoteAmount, uint256 rested, uint256 restOrderId)
    {
        // the fills in the version the params' tag names, as `take`'s, the taker admitted as there; the rest in the
        // market's current version, the caller admitted again, as a maker, when anything rests
        if (k.isProprietary()) _admit(k.marketId(), false);
        Walk memory walk = _newWalk(k, params);
        // base mode only, no fill-or-kill: WALLET and the probes mean something here, the quote and FOK bits do not
        if (walk.mode & ~(TAKE_WALLET | TAKE_PROBES) != 0) revert BadFlags();
        _takeFills(walk, list);
        uint256 rest = walk.remaining;
        uint256 tick = (params >> REST_TICK) & TICK_FIELD;
        bool isBid = params & 1 != 0;
        // what is left rests when its stored amount (its own units and q) is worth at least minQuote at the limit;
        // less than that stays with the taker. A remainder is a maker's order either way, so its limit is checked
        // whatever it is worth: an invalid limit with anything left reverts TickOutOfRange (a take that
        // filled everything rests nothing and needs no limit). The remainder is sized once, and valued at the limit
        // before the limit is checked, which cannot fail: a tick below 2^26 is decade 74 at most, so `_worthMin`'s
        // products stay below 2^240.
        (uint256 q, uint256 units, uint256 stored, bool rests) = _restsAt(k, tick, rest);
        if (rest != 0 && !k.makerTick(tick)) revert TickOutOfRange();
        uint256 landed;
        uint256 escrow;
        uint256 placed;
        MarketWord c;
        if (rests) {
            // what did not fill rests at the limit, placed between the fills and their settlement so its escrow
            // settles with them (one pull or debit of the token the take pays); here in the entry, not inside the
            // take, whose frame is deep and pays more for it. It rests in the market's current version, whichever
            // version the fills were in (an older version's orders fill, but rest no new ones)
            if (k.isProprietary()) _admit(k.marketId(), true);
            c = _current(k);
            (landed,, escrow, placed) = _placeOp(
                c,
                isBid,
                tick,
                q,
                units,
                stored,
                uint32(params >> REST_POS),
                uint8(params >> TAKE_MODE) & TAKE_PROBES,
                _acctKeys(c)
            );
        }
        (baseAmount, quoteAmount) = _finishTake(walk, escrow);
        if (rests) {
            emit Placed(msg.sender, _eventWord(c.marketKey(), placed, stored, landed));
            rested = stored;
            restOrderId = c.tagCarried() | landed;
        }
    }

    /// @notice `amount` as it would rest at `tick`: its q and units (OloMath.toUnits), the amount stored, units x 10^q,
    /// and whether that is worth at least the market's minQuote there (`_worthMin`; `_restAmount` for an order that
    /// must rest). The tick is not checked here: one off the makers' grid is valued like any other (a tick below 2^26
    /// cannot overflow `_worthMin`), and `takeThenRest` refuses it whenever anything is left. `c` is read for minQuote
    /// only, a key field: `takeThenRest` passes K.
    function _restsAt(MarketWord c, uint256 tick, uint256 amount)
        internal
        pure
        returns (uint256 q, uint256 units, uint256 stored, bool rests)
    {
        (q, units) = OloMath.toUnits(amount);
        unchecked {
            stored = units * OloMath.pow10(q); // at most `amount`
        }
        rests = _worthMin(c, tick, stored);
    }

    // ---------------------------------------------------------------- batches
    // A maker's batch slot holds up to four sub-orders, bids, asks or both, in two words, every one on chain: the main
    // word (ticks, q, open units and each sub-order's absolute side) and the settlement word (bases). Batch
    // slots are the maker's own, keyed by (C, maker, slot): only the maker rests, modifies, cancels or claims there,
    // and nobody else can take the slot or exhaust it (a take writes the main word, filling sub-orders as it does pool
    // orders), so a maker names a fixed slot per group of orders (0 for one) and works on it in place.

    /// @inheritdoc IOloBook
    /// @dev Named for its selector (0x9101d2b1), which sorts where `manageBatch(uint256,uint256)`'s 0x95d3c37d did,
    /// between `owner` and `tokenCount`: the dispatcher compares selectors in order, so every hot entry keeps its cost.
    function manageBatchSubs(MarketWord k, uint256 params, uint256[2] calldata amountWords)
        external
        lockIf(uint8(params >> BP_FLAGS) & SettleFlags.MASK != 0)
    {
        // the slot's version: a post's is the market's current one (`_current`: k must be the key); every other kind
        // names the version the slot rests in by the params' tag (a replace and a modify check it is current in
        // `_manageBatch`). One call, its C chosen before it: with a call on each path, via-IR's inliner copied
        // `_manageBatch` into both or kept it out of line depending on the order it met the functions, which any edit
        // of src moves (the contract about 3.8 KB larger, past EIP-170's limit, in builds that copied it). The C held
        // on the shared path costs a batch operation about 11 to 17 gas a sub-order. In a proprietary market a post, a
        // replace or a modify needs the maker admitted; a cancel or a claim does not
        if (k.isProprietary() && params & BP_KIND_MASK <= BATCH_MODIFY) _admit(k.marketId(), true);
        _manageBatch(params & BP_KIND_MASK == BATCH_POST ? _current(k) : k.withTag(params), params, amountWords);
    }

    // --------------------------------------------------------------- multicall

    // A multicall's header: a count byte (the top byte of the word read at 0) and that many 32-byte config words.
    uint256 private constant HEADER_COUNT = 1;
    uint256 private constant HEADER_COUNT_AT = 248;
    uint256 private constant HEADER_MARKET = 32;

    // An op as its first 32 bytes load: the op code (byte 0) and the market's index in the header (byte 1); a PLACE's
    // tick (bytes 2-5), side byte (6), amount (7-20) and pos (21-24); a CANCEL's, CLAIM's or MODIFY's pos (2-5) and a
    // MODIFY's new tick (6-9) and new amount (10-23); a DEPOSIT's or WITHDRAW's token id (1-4) and amount (5-20). Where
    // each starts:
    uint256 private constant OP_CODE_AT = 248;
    uint256 private constant OP_MARKET_AT = 240;
    uint256 private constant OP_TICK_AT = 208;
    uint256 private constant OP_SIDE_AT = 200;
    uint256 private constant OP_SIZE_AT = 88;
    uint256 private constant OP_POS_AT = 56;
    uint256 private constant OP_POS_BYTE = 21;
    uint256 private constant OP_ORDER_POS_AT = 208;
    uint256 private constant OP_NEW_TICK_AT = 176;
    uint256 private constant OP_NEW_SIZE_AT = 64;
    uint256 private constant OP_TOKEN_AT = 216;
    uint256 private constant OP_AMOUNT_AT = 88;

    /// @notice A multicall's header and its current market, in memory so the loop runs with few live stack values.
    struct Stream {
        uint256 marketIndex; // the current market entry (NONE: none yet), its C and accounts
        MarketWord c;
        uint256 acctKeys;
        bool active; // the run may rest orders: its C is its market's current one, a header K resolved to it
        // (`_current`) when the stream switched to it, or a header C checked (`_checkCurrent`) at the run's first PLACE
        // or MODIFY; in a proprietary market the caller admitted as a maker too, at that first PLACE or MODIFY, so a
        // run of CANCELs and CLAIMs never asks the policy
        bytes ops; // empty until a PLACE probes past busy positions; then a copy of the ops with each such PLACE's pos
        // rewritten to where it landed, which the Ops event logs instead of the calldata (`_noteLanded`)
    }

    /// @inheritdoc IOloBook
    function multicall(uint8 settle, bytes calldata data) external lock {
        if (settle & ~SettleFlags.MASK != 0) revert BadFlags();
        Ledger memory ledger = _newLedger();
        Stream memory stream;
        // the header, then the ops from `cursor` to the end; every read is a word of `data` at a byte index,
        // uint256(bytes32(data[at:])), zero past the end, written out at each site (via-IR inlines the sites and keeps
        // the conversion out of line; a helper function for it cost a multicall 6 gas an op)
        uint256 numMarkets = uint256(bytes32(data[0:])) >> HEADER_COUNT_AT;
        uint256 cursor = HEADER_COUNT + numMarkets * HEADER_MARKET;
        uint256 end = data.length;
        if (cursor > end) revert BadOp();
        stream.marketIndex = NONE;
        while (cursor < end) {
            uint256 opWord = uint256(bytes32(data[cursor:]));
            uint256 op = opWord >> OP_CODE_AT;
            uint256 len = (OP_LENGTHS >> (op << 3)) & 0xff;
            if (len == 0 || cursor + len > end) revert BadOp();
            if (op == OP_DEPOSIT || op == OP_WITHDRAW) {
                _tokenOp(ledger, opWord, op);
            } else {
                uint256 i = (opWord >> OP_MARKET_AT) & 0xff;
                if (i != stream.marketIndex) _switchMarket(stream, data, i);
                uint256 landed = _marketOp(stream, ledger, opWord, op);
                if (op == OP_PLACE && landed != uint32(opWord >> OP_POS_AT)) _noteLanded(stream, data, cursor, landed);
            }
            cursor += len;
        }
        if (stream.ops.length == 0) emit Ops(msg.sender, data);
        else emit Ops(msg.sender, stream.ops);
        _commit(ledger, settle);
    }

    /// @notice Notes a PLACE that probed past busy positions: in a memory copy of the ops, made at the first such
    /// PLACE and logged by the Ops event instead of the calldata, the op's pos (its bytes 21-24, big-endian) is
    /// rewritten to where it landed. The op is named by its byte index, whatever other ops in any market look alike.
    function _noteLanded(Stream memory stream, bytes calldata data, uint256 opAt, uint256 landed) internal pure {
        if (stream.ops.length == 0) stream.ops = data;
        bytes memory ops = stream.ops;
        uint256 posAt = opAt + OP_POS_BYTE;
        ops[posAt] = bytes1(uint8(landed >> 24));
        ops[posAt + 1] = bytes1(uint8(landed >> 16));
        ops[posAt + 2] = bytes1(uint8(landed >> 8));
        ops[posAt + 3] = bytes1(uint8(landed));
    }

    /// @notice A DEPOSIT or WITHDRAW op: the amount moves between the wallet and the caller's account of the token, one
    /// a listing registered (its address is set: ids 1 .. tokenCount; `_commit` reads it again, warm, to move it).
    function _tokenOp(Ledger memory ledger, uint256 opWord, uint256 op) internal view {
        uint256 id = uint32(opWord >> OP_TOKEN_AT);
        if (tokenAddr[id] == address(0)) revert BadOp();
        int256 signed = int256(uint256(uint128(opWord >> OP_AMOUNT_AT)));
        if (op == OP_DEPOSIT) _ledgerAdd(ledger, id, signed, -signed);
        else _ledgerAdd(ledger, id, -signed, signed);
    }

    /// @notice A PLACE, CANCEL, CLAIM or MODIFY op, as its word, on the stream's current market (`multicall` switched
    /// to the one the op names). Returns where a PLACE landed (its own pos unless it probed past busy positions), 0
    /// for the other ops.
    function _marketOp(Stream memory stream, Ledger memory ledger, uint256 opWord, uint256 op)
        internal
        returns (uint256 landed)
    {
        if (op == OP_PLACE) {
            uint256 tick = uint32(opWord >> OP_TICK_AT);
            if (!stream.c.makerTick(tick)) revert TickOutOfRange();
            (uint256 q, uint256 units, uint256 stored) = _restAmount(stream.c, tick, uint112(opWord >> OP_SIZE_AT));
            if (!stream.active) {
                _checkCurrent(stream.c);
                if (stream.c.isProprietary()) _admit(stream.c.marketId(), true);
                stream.active = true;
            }
            uint8 side = uint8(opWord >> OP_SIDE_AT);
            uint256 key;
            uint256 escrow;
            (landed, key, escrow,) = _placeOp(
                stream.c,
                side & 1 != 0,
                tick,
                q,
                units,
                stored,
                uint32(opWord >> OP_POS_AT),
                side & 0xfe, // the probes, and bits 1-3, which mean nothing, for `_placeOp` to refuse
                stream.acctKeys
            );
            _entryOf(ledger, key).maker -= int256(escrow);
        } else {
            uint256 slot = OloSlots.orderSlot(stream.c, uint32(opWord >> OP_ORDER_POS_AT));
            int256 quoteFlow;
            int256 baseFlow;
            if (op == OP_CANCEL) {
                (,,,, quoteFlow, baseFlow) = _cancelOp(stream.c, slot);
            } else if (op == OP_CLAIM) {
                (,,, quoteFlow, baseFlow) = _claimOp(stream.c, slot);
            } else {
                // OP_MODIFY: the one code left, as `multicall` refused every code OP_LENGTHS gives no length
                if (!stream.active) {
                    _checkCurrent(stream.c);
                    if (stream.c.isProprietary()) _admit(stream.c.marketId(), true);
                    stream.active = true;
                }
                (,,,,, quoteFlow, baseFlow) =
                    _modifyOp(stream.c, slot, uint32(opWord >> OP_NEW_TICK_AT), uint112(opWord >> OP_NEW_SIZE_AT));
            }
            _ledgerFlows(ledger, stream.acctKeys, quoteFlow, baseFlow);
        }
    }

    /// @notice The stream's market `i`: its C from the header and the caller's account keys of its two tokens. A
    /// header word that is a market's key K (no tag) names the market's current version, read here, for every op of
    /// the run; a C (a tag) names that version, whose first PLACE or MODIFY from here checks it is the current one
    /// (a CANCEL or a CLAIM settles any version's orders). In a proprietary market that first PLACE or MODIFY admits
    /// the caller as a maker, whichever word the header gives, so the run starts inactive.
    function _switchMarket(Stream memory stream, bytes calldata data, uint256 i) internal view {
        if (i >= uint256(bytes32(data[0:])) >> HEADER_COUNT_AT) revert BadOp(); // the header's count
        MarketWord c = MarketWord.wrap(uint256(bytes32(data[HEADER_COUNT + i * HEADER_MARKET:])));
        bool isKey = MarketWord.unwrap(c) & C_TAG_FIELD == 0;
        if (isKey) c = _current(c);
        stream.marketIndex = i;
        stream.c = c;
        stream.acctKeys = _acctKeys(c);
        stream.active = isKey && !c.isProprietary();
    }

    // ------------------------------------------------------------------- views

    /// @inheritdoc IOloBook
    function balanceOf(uint256 id, address owner) external view returns (uint256) {
        // an id past the registry's 32 bits would spill into the owner's bits and read another owner's account
        if (id >> KEY_BITS != 0) revert UnknownToken();
        // every bit but USED: an owner's word never has bits 128-254 set, so this reads the pot and an account alike
        return AccountLib.potOf(_accounts[OloSlots.ownedKey(id, owner)]);
    }

    /// @inheritdoc IOloBook
    function orderOf(MarketWord c, uint32 pos)
        external
        view
        returns (uint256 tick, uint256 open, uint256 filled, bool isBid, address owner)
    {
        PoolWord word = PoolWord.wrap(OloSlots.load(OloSlots.orderSlot(c, pos)));
        if (!word.isLive()) return (0, 0, 0, false, address(0));
        uint256 unit = OloMath.pow10(word.qOf());
        return (word.tickOf(), word.openOf() * unit, word.filledOf() * unit, word.isBidOf(), word.ownerOf());
    }

    /// @inheritdoc IOloBook
    function makerShareOf(MarketWord c) external view returns (uint16 makerBps, bool listed, bool active) {
        MarketWord cur = _market(c.marketId());
        if (!cur.isSet() || (MarketWord.unwrap(cur) ^ MarketWord.unwrap(c)) & C_KEY_MASK != 0) {
            return (0, false, false);
        }
        // K or the current C: the current share; any other tag (an older version's, or one no version had) is not the
        // current version, and its share bits are not echoed back
        if (MarketWord.unwrap(c) & C_TAG_FIELD == 0 || MarketWord.unwrap(c) == MarketWord.unwrap(cur)) {
            return (cur.makerBps(), true, true);
        }
        return (0, true, false);
    }

    /// @inheritdoc IOloBook
    /// @dev Named for its selector (0xfae51ae8), which sorts after every hot entry's.
    function pairDefaultsOf(address tokenA, address tokenB)
        external
        view
        returns (
            uint24 floorPpm,
            uint24 globalFloorPpm,
            bool floorSet,
            uint16 makerBps,
            uint16 globalBps,
            bool shareSet
        )
    {
        uint256 pair = _pairWord(tokenA, tokenB);
        uint256 floor;
        uint256 share;
        (floor, floorSet) = _pairFeeFloor(pair);
        (share, shareSet) = _pairMakerBps(pair);
        return (uint24(floor), globalFeeFloor, floorSet, uint16(share), globalMakerBps, shareSet);
    }

    /// @inheritdoc IOloBook
    function orderWord(MarketWord c, uint32 pos) external view returns (uint256) {
        return OloSlots.load(OloSlots.orderSlot(c, pos));
    }

    /// @inheritdoc IOloBook
    function batchOf(MarketWord c, address maker, uint16 slot) external view returns (uint256 word, uint256 set) {
        uint256 key = OloSlots.batchSlot(c, maker, slot);
        unchecked {
            // a hash: never the last slot
            return (OloSlots.load(key), OloSlots.load(key + 1));
        }
    }

    /// @inheritdoc IOloBook
    function configOf(uint32 marketId) external view returns (MarketWord) {
        return _market(marketId);
    }

    /// @inheritdoc IOloBook
    function marketIdGivenListingWord(MarketWord params) external view returns (uint32) {
        return uint32(OloSlots.load(OloSlots.listingSlot(params)));
    }

    /// @inheritdoc IOloBook
    function listingFeeCurrent() external view returns (uint80) {
        return listingFee;
    }

    // ====================================================== run in OloBookExt

    /// @inheritdoc IOloBookExt
    function listMarketQuote(address, address, uint24, uint8, uint96, uint16) external payable returns (uint32) {
        _delegate();
    }

    /// @inheritdoc IOloBookExt
    function setCurrentListingFee(uint80) external {
        _delegate();
    }

    /// @inheritdoc IOloBookExt
    function setFeeRecipient(address) external {
        _delegate();
    }

    /// @inheritdoc IOloBookExt
    function collectFees(address) external returns (uint256) {
        _delegate();
    }

    /// @inheritdoc IOloBookExt
    function warmPool(uint32, uint32, uint256) external {
        _delegate();
    }

    /// @inheritdoc IOloBookExt
    function setMarketFee(uint256, uint24, uint64) external {
        _delegate();
    }

    /// @inheritdoc IOloBookExt
    function setGlobalFeeFloor(uint32) external {
        _delegate();
    }

    /// @inheritdoc IOloBookExt
    function setPairFeeFloor(address, address, uint32, bool) external {
        _delegate();
    }

    /// @inheritdoc IOloBookExt
    function setGlobalMakerShare(uint24) external {
        _delegate();
    }

    /// @inheritdoc IOloBookExt
    function setPairMakerShare(address, address, uint40, bool) external {
        _delegate();
    }

    /// @inheritdoc IOloBookExt
    function setMarketMakerShare(uint256, uint48) external {
        _delegate();
    }

    /// @inheritdoc IOloBookExt
    function listMarketQuoteProprietary(address, address, uint24, uint8, uint96, uint16, address)
        external
        payable
        returns (uint32)
    {
        _delegate();
    }

    /// @inheritdoc IOloBookExt
    function setProprietaryListingAllowed(address, bool) external {
        _delegate();
    }

    /// @inheritdoc IOloBookExt
    function flash(address, uint256, bytes calldata) external {
        _delegate();
    }

    /// @notice Forwards the call to `ext` in this contract's storage and returns (or reverts) with its result. The
    /// calldata and the return data go through the free memory, not address 0: the block is memory-safe, so via-IR
    /// may keep variables it spills in the reserve below the free pointer (the default build has one, 64 bytes at
    /// 0x80) and read `impl` from there inside the block, which a copy to 0 of a listing's 196 bytes would overwrite.
    function _delegate() internal {
        address impl = ext;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := delegatecall(gas(), impl, ptr, calldatasize(), 0, 0)
            returndatacopy(ptr, 0, returndatasize())
            if iszero(ok) { revert(ptr, returndatasize()) }
            return(ptr, returndatasize())
        }
    }
}
